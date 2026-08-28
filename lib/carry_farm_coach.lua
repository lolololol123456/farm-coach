
local Coach = {}

local Lane = require("lib.lane")
local Route = Lane.Route or require("lib.route")

Coach.CONFIDENCE = {
    LIVE = 1.00,
    PARTIAL_LIVE = 0.65,
    MIRRORED = 0.55,
    CLOCK = 0.35,
    CACHED_BASE = 0.80,
    CACHED_HALF_LIFE_S = 30,
}

-- Shared validation and value helpers

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Coach.CampKey(pos)
    if type(pos) ~= "table" or not finite(pos.x) or not finite(pos.y) then return nil end
    return string.format("%d,%d", math.floor(pos.x / 100), math.floor(pos.y / 100))
end

function Coach.CampScanState(cleared_until, live_count, now)
    if type(live_count) == "number" and live_count > 0 then return "live" end
    if finite(cleared_until) and finite(now) and now < cleared_until then return "cleared" end
    return "scan"
end

function Coach.NearestCampKey(pos, camps, max_distance)
    if type(pos) ~= "table" or not finite(pos.x) or not finite(pos.y)
        or not finite(max_distance) or max_distance <= 0 then return nil end
    local best_key, best_d2
    for _, camp in ipairs(camps or {}) do
        local center = type(camp) == "table" and camp.pos or nil
        if type(center) == "table" and finite(center.x) and finite(center.y)
            and type(camp.key) == "string" then
            local dx, dy = center.x - pos.x, center.y - pos.y
            local d2 = dx * dx + dy * dy
            if d2 <= max_distance * max_distance and (not best_d2 or d2 < best_d2) then
                best_key, best_d2 = camp.key, d2
            end
        end
    end
    return best_key
end

local function nonnegative(v)
    return finite(v) and v >= 0
end

local function positive(v)
    return finite(v) and v > 0
end

local function copy_pos(pos)
    if type(pos) ~= "table" or not finite(pos.x) or not finite(pos.y) then return nil end
    local out = { x = pos.x, y = pos.y }
    if finite(pos.z) then out.z = pos.z end
    return out
end

function Coach.WaveTargetPosition(enemy_wave, clash)
    if type(enemy_wave) ~= "table" then return nil end
    if enemy_wave.estimated then return nil end
    local own = copy_pos(enemy_wave.centroid) or copy_pos(enemy_wave.front)
    return own
end

function Coach.Confidence(source, partial, age_s)
    if source == "live" then
        return partial and Coach.CONFIDENCE.PARTIAL_LIVE or Coach.CONFIDENCE.LIVE
    elseif source == "mirrored" then
        return Coach.CONFIDENCE.MIRRORED
    elseif source == "clock" then
        return Coach.CONFIDENCE.CLOCK
    elseif source == "cached" then
        if not nonnegative(age_s) then return nil end
        local halves = age_s / Coach.CONFIDENCE.CACHED_HALF_LIFE_S
        return Coach.CONFIDENCE.CACHED_BASE * (0.5 ^ halves)
    end
    return nil
end

-- Opportunity normalization and cold estimates

local function normalize(sample, now, kind)
    if type(sample) ~= "table" or not finite(now) then return nil end
    if type(sample.key) ~= "string" or sample.key == "" then return nil end
    local pos = copy_pos(sample.pos)
    if not pos then return nil end
    if not nonnegative(sample.gold) or not positive(sample.ehp)
        or not positive(sample.count) or not positive(sample.clear_t)
        or not finite(sample.observed_at) then return nil end

    local expected = sample.expected_count
    if expected ~= nil and (not positive(expected) or expected < sample.count) then return nil end
    local partial = kind == "wave" and expected ~= nil and sample.count < expected or false
    local age_s = math.max(0, now - sample.observed_at)
    local confidence = Coach.Confidence(sample.source, partial, age_s)
    if not confidence then return nil end

    if sample.expires_at ~= nil and not finite(sample.expires_at) then return nil end
    if sample.risk ~= nil and (not nonnegative(sample.risk) or sample.risk > 1) then return nil end
    return {
        key = sample.key,
        kind = kind,
        region = (type(sample.region) == "string" and sample.region ~= "") and sample.region
            or (kind == "camp" and "jungle" or "unknown"),
        pos = pos,
        value = sample.gold,
        ehp = sample.ehp,
        count = sample.count,
        expected_count = expected,
        clear_t = sample.clear_t,
        available_at = finite(sample.available_at) and sample.available_at or now,
        expires_at = sample.expires_at,
        source = sample.source,
        confidence = confidence,
        observed_at = sample.observed_at,
        age_s = age_s,
        partial = partial,
        risk = sample.risk or 0,
    }
end

function Coach.NormalizeCamp(sample, now)
    return normalize(sample, now, "camp")
end

function Coach.NormalizeWave(sample, now)
    return normalize(sample, now, "wave")
end

local CLEAR_CATEGORIES = {
    small = true, medium = true, large = true, ancient = true, wave = true,
}

function Coach.ColdClearEstimate(ehp, profile)
    if not positive(ehp) or type(profile) ~= "table"
        or not positive(profile.attack_damage) or not positive(profile.attacks_per_second) then
        return nil
    end
    local engage = nonnegative(profile.engage_delay) and profile.engage_delay or 0
    local reposition = positive(profile.reposition_factor) and profile.reposition_factor or 1
    return (ehp / (profile.attack_damage * profile.attacks_per_second) + engage) * reposition
end

-- Clear-time calibration

function Coach.NewCalibration()
    return {}
end

function Coach.BeginClearSample(category, source_key, now, snapshot)
    if not CLEAR_CATEGORIES[category] or type(source_key) ~= "string" or source_key == ""
        or not finite(now) or type(snapshot) ~= "table" or not positive(snapshot.count) then
        return nil
    end
    return {
        category = category,
        source_key = source_key,
        started_at = now,
        initial_count = snapshot.count,
        last_at = now,
        remaining = snapshot.count,
        coherent_clear = true,
        left_radius = false,
        hero_dead = false,
        other_hero_present = false,
        idle_s = 0,
    }
end

function Coach.UpdateClearSample(sample, now, event)
    if type(sample) ~= "table" or not finite(now) or now < (sample.last_at or math.huge)
        or type(event) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(sample) do out[k] = v end
    out.last_at = now
    if nonnegative(event.remaining) then out.remaining = event.remaining end
    if event.coherent_clear ~= nil then out.coherent_clear = event.coherent_clear == true end
    out.left_radius = out.left_radius or event.left_radius == true
    out.hero_dead = out.hero_dead or event.hero_dead == true
    out.other_hero_present = out.other_hero_present or event.other_hero_present == true
    if nonnegative(event.idle_s) then out.idle_s = math.max(out.idle_s or 0, event.idle_s) end
    return out
end

function Coach.AcceptClearSample(calibration, sample, now)
    calibration = type(calibration) == "table" and calibration or {}
    if type(sample) ~= "table" or not finite(now) then return calibration, false, "invalid" end
    if sample.left_radius then return calibration, false, "left_radius" end
    if sample.hero_dead then return calibration, false, "hero_dead" end
    if sample.other_hero_present then return calibration, false, "contested" end
    if sample.coherent_clear ~= true or sample.remaining ~= 0 then return calibration, false, "incomplete" end
    if (sample.idle_s or 0) > 3 then return calibration, false, "idle" end
    local duration = now - (sample.started_at or now)
    if duration < 0.5 or duration > 45 or not CLEAR_CATEGORIES[sample.category] then
        return calibration, false, "duration"
    end

    local out = {}
    for k, v in pairs(calibration) do out[k] = v end
    local old = calibration[sample.category]
    local seconds = old and (0.35 * duration + 0.65 * old.seconds) or duration
    out[sample.category] = {
        seconds = seconds,
        samples = (old and old.samples or 0) + 1,
        last_at = now,
    }
    return out, true, "accepted"
end

function Coach.BlendedClearTime(calibration, category, cold_seconds)
    if not positive(cold_seconds) then return nil end
    local learned = type(calibration) == "table" and calibration[category] or nil
    if not learned or not positive(learned.seconds) or not positive(learned.samples) then
        return cold_seconds
    end
    local weight = math.min(0.85, learned.samples * 0.20)
    return cold_seconds * (1 - weight) + learned.seconds * weight
end

function Coach.ResetMatch(_calibration)
    return {}
end

-- Planning windows and route simulation

function Coach.NextRespawnBoundary(now)
    if not finite(now) or now < 0 then return nil end
    return (math.floor(now / 60) + 1) * 60
end

function Coach.PlanningBoundary(now, minimum_window_s)
    local boundary = Coach.NextRespawnBoundary(now)
    if not boundary then return nil end
    local minimum = positive(minimum_window_s) and minimum_window_s or 25
    if boundary - now < minimum then boundary = boundary + 60 end
    return boundary
end

local function distance(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    return math.sqrt(dx * dx + dy * dy)
end

local function route_distance(opts, a, b)
    if type(opts.distance_fn) == "function" then
        local ok, value = pcall(opts.distance_fn, a, b)
        if ok and positive(value) then return value end
    end
    return distance(a, b)
end

local function valid_opportunity(o)
    return type(o) == "table" and type(o.key) == "string" and o.key ~= ""
        and (o.kind == "camp" or o.kind == "wave") and copy_pos(o.pos) ~= nil
        and nonnegative(o.value) and positive(o.clear_t) and finite(o.available_at)
        and (o.expires_at == nil or finite(o.expires_at))
        and nonnegative(o.confidence) and o.confidence <= 1
        and nonnegative(o.risk or 0) and (o.risk or 0) <= 1
end

local function copy_opportunity(o)
    return {
        key = o.key, kind = o.kind, region = o.region, pos = copy_pos(o.pos),
        value = o.value, clear_t = o.clear_t, available_at = o.available_at,
        expires_at = o.expires_at, source = o.source, confidence = o.confidence,
        observed_at = o.observed_at, age_s = o.age_s, partial = o.partial == true,
        category = o.category, count = o.count, ehp = o.ehp,
        risk = o.risk or 0,
    }
end

local function sequence_key(steps)
    local keys = {}
    for i = 1, #steps do keys[i] = steps[i].key end
    return table.concat(keys, ",")
end

local function arrival_value(o, arrive, now)
    if o.kind ~= "wave" or not o.expires_at then return o.value end
    local remaining = o.expires_at - now
    if remaining <= 0 then return 0 end
    local travel_age = math.max(0, arrive - now)
    return math.max(0, o.value * (1 - travel_age / remaining))
end

local function simulate(seq, hero, clock, opts, all)
    local pos = hero.pos
    local t = clock.now
    local travel_t, clear_t, wait_t, gold, urgent, confidence, risk_total = 0, 0, 0, 0, 0, 0, 0
    local steps, timeline = {}, {}
    for i = 1, #seq do
        local o = seq[i]
        local depart = t
        local leg = route_distance(opts, pos, o.pos) / hero.move_speed
        if leg > opts.immediate_leg_cap_s then return nil end
        local arrive = t + leg
        local wait = math.max(0, o.available_at - arrive)
        local finish = arrive + wait + o.clear_t
        if finish > clock.boundary or (o.expires_at and finish > o.expires_at) then return nil end
        local collected_value = arrival_value(o, arrive, clock.now)
        if collected_value <= 0 then return nil end
        travel_t, wait_t, clear_t = travel_t + leg, wait_t + wait, clear_t + o.clear_t
        gold, confidence = gold + collected_value, confidence + o.confidence
        risk_total = risk_total + (o.risk or 0)
        if o.kind == "wave" and o.expires_at then urgent = urgent + collected_value end
        local step = copy_opportunity(o)
        step.value = collected_value
        steps[#steps + 1] = step
        timeline[#timeline+1] = {key=o.key,depart=depart,arrive=arrive,wait=wait,
            clear=o.clear_t,finish=finish,value_at_arrival=collected_value}
        t, pos = finish, o.pos
    end
    if #steps == 0 then return nil end

    local used, missed = {}, 0
    for i = 1, #steps do used[steps[i].key] = true end
    for _, o in ipairs(all) do
        if o.kind == "wave" and o.expires_at and o.expires_at <= clock.boundary
            and not used[o.key] then missed = missed + o.value end
    end

    local setup = 0
    local radius = opts.end_setup_radius
    for _, o in ipairs(all) do
        if o.kind == "camp" and route_distance(opts, pos, o.pos) <= radius then
            setup = math.max(setup, o.value * 0.10)
        end
    end
    local net_gold = gold + setup + urgent * (opts.urgent_weight or 0.15)
        - travel_t * (opts.travel_cost_per_s or 0) - risk_total * (opts.risk_gold or 0)
    local total_t = travel_t + clear_t + wait_t
    return {
        steps = steps, gold = gold, travel_t = travel_t, clear_t = clear_t,
        wait_t = wait_t, total_t = total_t,
        missed_expiring_gold = missed, urgent_gold = urgent,
        uncertain_count = (function()
            local n = 0
            for i = 1, #steps do if steps[i].confidence < 0.999 then n = n + 1 end end
            return n
        end)(),
        confidence_sum = confidence, end_setup_value = setup,
        risk_total = risk_total,
        timeline = timeline,
        net_gold = net_gold,
        utility = net_gold / math.max(1, total_t),
        sequence_key = sequence_key(steps),
    }
end

local function reason_for(best, runner)
    if not runner then return "ONLY_VALID_ROUTE", best.utility end
    if best.steps[1] and best.steps[1].kind == "wave" and best.steps[1].expires_at then
        return "EXPIRING_VALUE", best.steps[1].value
    end
    if best.urgent_gold > runner.urgent_gold then
        return "EXPIRING_VALUE", best.urgent_gold - runner.urgent_gold
    end
    if best.end_setup_value > runner.end_setup_value and best.utility >= runner.utility then
        return "RESPAWN_SETUP", best.end_setup_value - runner.end_setup_value
    end
    if best.gold == runner.gold and best.travel_t < runner.travel_t then
        return "LESS_DEAD_TRAVEL", runner.travel_t - best.travel_t
    end
    if best.uncertain_count < runner.uncertain_count then
        return "HIGHER_CONFIDENCE", runner.uncertain_count - best.uncertain_count
    end
    return "BEST_NEARBY_VALUE", best.utility - runner.utility
end

-- Route stability and public planner

local function same_route_plan(previous, by_key, hero, clock, opts, all)
    if type(previous) ~= "table" or type(previous.steps) ~= "table" or #previous.steps == 0 then return nil end
    local seq = {}
    for i = 1, #previous.steps do
        local current = by_key[previous.steps[i].key]
        if not current then return nil end
        seq[i] = current
    end
    return simulate(seq, hero, clock, opts, all)
end

function Coach.Plan(opportunities, hero, clock, opts, previous)
    opts = opts or {}
    if type(hero) ~= "table" or not copy_pos(hero.pos) or not positive(hero.move_speed)
        or type(clock) ~= "table" or not finite(clock.now) or not finite(clock.boundary)
        or clock.boundary <= clock.now then return nil end
    local max_steps = math.floor(opts.max_steps or 3)
    if max_steps < 1 or max_steps > 4 then return nil end
    local cfg = {
        immediate_leg_cap_s = positive(opts.immediate_leg_cap_s) and opts.immediate_leg_cap_s or 15,
        end_setup_radius = positive(opts.end_setup_radius) and opts.end_setup_radius or 1000,
        travel_cost_per_s = nonnegative(opts.travel_cost_per_s) and opts.travel_cost_per_s or 0,
        urgent_weight = nonnegative(opts.urgent_weight) and opts.urgent_weight or 0.15,
        distance_fn = type(opts.distance_fn) == "function" and opts.distance_fn or nil,
        risk_gold = nonnegative(opts.risk_gold) and opts.risk_gold or 0,
        confidence_weight = positive(opts.confidence_weight) and opts.confidence_weight or 0.01,
    }

    local pool, by_key, rejection_by_key = {}, {}, {}
    for index, o in ipairs(opportunities or {}) do
        local diag_key = type(o) == "table" and type(o.key) == "string" and o.key or ("invalid#" .. index)
        if not valid_opportunity(o) then
            rejection_by_key[diag_key] = "invalid_data"
        elseif o.expires_at and o.expires_at <= clock.now then
            rejection_by_key[diag_key] = "expired"
        elseif not by_key[o.key] then
            local c = copy_opportunity(o)
            pool[#pool + 1], by_key[c.key] = c, c
            rejection_by_key[c.key] = "eligible"
        else
            rejection_by_key[diag_key] = "duplicate"
        end
    end
    local cap = math.floor(opts.pool_cap or 12)
    if #pool > cap then
        table.sort(pool, function(a, b)
            local ta = route_distance(opts, hero.pos, a.pos) / hero.move_speed + a.clear_t
            local tb = route_distance(opts, hero.pos, b.pos) / hero.move_speed + b.clear_t
            return a.value / ta > b.value / tb
        end)
        local kept, selected = {}, {}
        for i=1,math.min(cap,#pool) do
            kept[#kept+1],selected[pool[i].key]=pool[i],true
        end
        for _, old in ipairs(previous and previous.steps or {}) do
            if by_key[old.key] and not selected[old.key] then
                kept[#kept+1],selected[old.key]=by_key[old.key],true
            end
        end
        for _, o in ipairs(pool) do
            if not selected[o.key] then rejection_by_key[o.key] = "pool_cap" end
        end
        pool,by_key=kept,{}
        for _,o in ipairs(pool) do by_key[o.key]=o end
    end
    if #pool == 0 then return nil end

    for _, o in ipairs(pool) do
        local leg = route_distance(opts, hero.pos, o.pos) / hero.move_speed
        local wait = math.max(0, o.available_at - (clock.now + leg))
        if leg > cfg.immediate_leg_cap_s then
            rejection_by_key[o.key] = "leg_too_long"
        elseif clock.now + leg + wait + o.clear_t > clock.boundary then
            rejection_by_key[o.key] = "outside_horizon"
        end
    end

    local targets = {}
    for i, o in ipairs(pool) do
        targets[i] = {
            key = o.key, pos = o.pos, value = o.value, clear_t = o.clear_t,
            window = o.expires_at and { from = o.available_at, to = o.expires_at }
                or { from = o.available_at, to = clock.boundary },
            born = o.observed_at or clock.now,
            decay_per_s = (o.kind == "wave" and o.expires_at)
                and (o.value / math.max(1, o.expires_at - clock.now)) or nil,
            value_floor = 0,
            risk = (o.risk or 0) * cfg.risk_gold
                + (1 - o.confidence) * cfg.confidence_weight,
            ref = o,
        }
    end
    local route_opts = {
        now = clock.now,
        horizon_s = clock.boundary - clock.now,
        max_steps = max_steps,
        max_leg_s = cfg.immediate_leg_cap_s,
        pool_cap = #pool,
        risk_hard = math.huge,
        risk_weight = 1,
        step_decay = positive(opts.step_decay) and math.min(1, opts.step_decay) or 0.92,
        distance_fn = cfg.distance_fn,
    }
    local hero_state = { pos = copy_pos(hero.pos), move_speed = hero.move_speed, anchors = {}, tp = nil }
    local candidates, remaining = {}, {}
    for i,tg in ipairs(targets) do remaining[i]=tg end
    for _=1,math.min(#remaining,8) do
        local routed=Route.Plan(remaining,hero_state,route_opts)
        if not routed or not routed.steps or not routed.steps[1] then break end
        local selected={}
        for _,target in ipairs(routed.steps) do selected[#selected+1]=target.ref end
        local candidate=simulate(selected,hero,clock,cfg,pool)
        if candidate then candidates[#candidates+1]=candidate end
        local first_key=routed.steps[1].key
        local next_remaining={}
        for _,target in ipairs(remaining) do
            if target.key~=first_key then next_remaining[#next_remaining+1]=target end
        end
        remaining=next_remaining
    end
    table.sort(candidates,function(a,b)
        if a.utility~=b.utility then return a.utility>b.utility end
        if a.uncertain_count~=b.uncertain_count then return a.uncertain_count<b.uncertain_count end
        return a.travel_t<b.travel_t
    end)
    local best,runner=candidates[1],candidates[2]
    if not best then return nil end

    local old = same_route_plan(previous, by_key, hero, clock, cfg, pool)
    local change = {stability=previous and (old and "replaced" or "invalidated") or "new"}
    local margin = nonnegative(opts.stability_margin) and opts.stability_margin or 0
    if old then
        local best_metric = best.net_gold or best.utility
        local old_metric = old.net_gold or old.utility
        local denom = math.max(1, math.abs(old_metric))
        change.margin_pct = (best_metric - old_metric) / denom * 100
        if (best_metric - old_metric) / denom < margin then
            best, change.stability = old, "preserved"
        end
    end

    local locked_key = type(opts.locked_first_key) == "string" and opts.locked_first_key or nil
    local locked = locked_key and by_key[locked_key] or nil
    if locked then
        local locked_best = simulate({locked},hero,clock,cfg,pool)
        if locked_best and max_steps > 1 and locked_best.timeline and locked_best.timeline[1] then
            local remaining_targets = {}
            for _, target in ipairs(targets) do
                if target.key ~= locked_key then remaining_targets[#remaining_targets+1] = target end
            end
            local finish = locked_best.timeline[1].finish
            local continuation_opts = {
                now=finish, horizon_s=math.max(0,clock.boundary-finish),
                max_steps=max_steps-1, max_leg_s=cfg.immediate_leg_cap_s,
                pool_cap=#remaining_targets, risk_hard=math.huge, risk_weight=1,
                step_decay=route_opts.step_decay, distance_fn=cfg.distance_fn,
            }
            local continuation = Route.Plan(remaining_targets, {
                pos=copy_pos(locked.pos),move_speed=hero.move_speed,anchors={},tp=nil,
            }, continuation_opts)
            if continuation and continuation.steps and #continuation.steps > 0 then
                local sequence = {locked}
                for _, target in ipairs(continuation.steps) do sequence[#sequence+1] = target.ref end
                local candidate = simulate(sequence,hero,clock,cfg,pool)
                if candidate then locked_best = candidate end
            end
        end
        if locked_best then
            best = locked_best
            change.stability = "locked"
        end
    end

    local alternatives = {}
    for i = 1, math.min(5, #candidates) do
        local c = candidates[i]
        alternatives[i] = {
            route=c.sequence_key, gold=c.gold, travel_t=c.travel_t,
            total_t=c.total_t, net_gold=c.net_gold, utility=c.utility,
        }
    end
    local selected_keys = {}
    for _, step in ipairs(best.steps or {}) do selected_keys[step.key] = true end
    for key, reason in pairs(rejection_by_key) do
        if selected_keys[key] then rejection_by_key[key] = "selected"
        elseif reason == "eligible" then rejection_by_key[key] = "lost_on_score" end
    end
    local rejections = {}
    for key, reason in pairs(rejection_by_key) do rejections[#rejections+1] = {key=key,reason=reason} end
    table.sort(rejections, function(a,b) return a.key < b.key end)
    best.reason_code, best.reason_delta = reason_for(best, runner)
    change.old_route = previous and sequence_key(previous.steps or {}) or "none"
    change.new_route = sequence_key(best.steps or {})
    change.trigger = best.reason_code
    best.change = change
    best.alternatives = alternatives
    best.diagnostics = {rejections=rejections}
    best.net_value = best.net_gold
    best.tempo_value = best.utility
    best.urgent_gold, best.confidence_sum, best.sequence_key, best.utility = nil, nil, nil, nil
    best.net_gold = nil
    return best
end

function Coach.BuildDiagnosticSnapshot(opportunities, plan, hero, opts, active, active_reason)
    opts = opts or {}
    local limit = math.max(1, math.floor(opts.limit or 3))
    local selected, rejected = {}, {}
    for i, step in ipairs(plan and plan.steps or {}) do selected[step.key] = i end
    for _, row in ipairs(plan and plan.diagnostics and plan.diagnostics.rejections or {}) do
        rejected[row.key] = row.reason
    end
    local nearby = {}
    if type(hero) == "table" and copy_pos(hero.pos) and positive(hero.move_speed) then
        for _, opportunity in ipairs(opportunities or {}) do
            if valid_opportunity(opportunity) then
                local distance = route_distance(opts, hero.pos, opportunity.pos)
                local travel_t = distance / hero.move_speed
                local score = opportunity.value
                    - travel_t * (opts.travel_cost_per_s or 0)
                    - (opportunity.risk or 0) * (opts.risk_gold or 0)
                nearby[#nearby + 1] = {
                    key=opportunity.key, kind=opportunity.kind, source=opportunity.source,
                    value=opportunity.value, distance=distance, travel_t=travel_t,
                    clear_t=opportunity.clear_t, score=score,
                    confidence=opportunity.confidence, risk=opportunity.risk or 0,
                    decision=rejected[opportunity.key] or "unranked",
                    selected_rank=selected[opportunity.key],
                }
            end
        end
        table.sort(nearby, function(a, b)
            if a.distance ~= b.distance then return a.distance < b.distance end
            return a.key < b.key
        end)
        while #nearby > limit do nearby[#nearby] = nil end
    end
    local routes = {}
    for i = 1, math.min(limit, #(plan and plan.alternatives or {})) do
        local route = plan.alternatives[i]
        routes[i] = {
            route=route.route, gold=route.gold, travel_t=route.travel_t,
            total_t=route.total_t, net_gold=route.net_gold, utility=route.utility,
        }
    end
    local change = plan and plan.change or {}
    return {
        nearby=nearby,
        routes=routes,
        change={old_route=change.old_route or "none",new_route=change.new_route or "none",
            trigger=change.trigger or "no_plan",stability=change.stability or "none",
            margin_pct=change.margin_pct},
        active={key=active and active.key or "none",confirmed=active and active.confirmed == true,
            reason=active_reason or "none"},
    }
end

function Coach.PushDiagnosticHistory(history, snapshot, at, limit)
    local out = {}
    for i, row in ipairs(history or {}) do out[i] = row end
    if type(snapshot) ~= "table" then return out end
    local change, active = snapshot.change or {}, snapshot.active or {}
    local signature = table.concat({
        change.new_route or "none",
        change.trigger or "no_plan",
        change.stability or "none",
        active.key or "none",
        active.reason or "none",
    }, "|")
    if out[1] and out[1].signature == signature then return out end
    table.insert(out, 1, {
        at=at or 0, signature=signature,
        route=change.new_route or "none", trigger=change.trigger or "no_plan",
        stability=change.stability or "none",
        active_key=active.key or "none", active_reason=active.reason or "none",
    })
    local cap = math.max(1, math.floor(limit or 5))
    while #out > cap do out[#out] = nil end
    return out
end

return Coach
