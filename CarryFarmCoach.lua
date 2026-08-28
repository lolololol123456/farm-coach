if package and package.loaded then package.loaded["lib.carry_farm_coach"] = nil end

-- Dependencies and farming estimates

local Map      = require("lib.map")
local MapData  = require("lib.map_data")
local Farm     = require("lib.farm")
local Lane     = require("lib.lane")
local Draw     = require("lib.draw")
local Coach    = require("lib.carry_farm_coach")

local SUPPORTED_RANGED = { npc_dota_hero_luna = true }
local CAMP_KIND = { [0] = "small", [1] = "medium", [2] = "large", [3] = "ancient" }
local TIER_EST = {
    [0] = { gold=55,  hp=1400 },
    [1] = { gold=85,  hp=1900 },
    [2] = { gold=105, hp=2400 },
    [3] = { gold=160, hp=3600 },
}

local K = {
    SAMPLE_S = 0.35,
    CAMP_CACHE_MAX_S = 45,
    CAMP_NEAREST_FALLBACK_R = 900,
    WAVE_WINDOW_S = 30,
    IMMEDIATE_LEG_CAP_S = 12,
    STABILITY_MARGIN = 0.03,
    CLEAR_START_R = 650,
    CLEAR_LEAVE_R = 950,
    OTHER_HERO_R = 750,
    MIN_PLAN_WINDOW_S = 25,
    TRAVEL_GOLD_PER_S = 8,
    ROUTE_HORIZON_S = 60,
    ROUTE_POOL_CAP = 16,
    ROUTE_STEP_DECAY = 0.60,
    STRUCTURAL_RISK_GOLD = 160,
    ERROR_THROTTLE_S = 5,
}

-- Visual theme and runtime state

local C = {
    panel = Color(12, 17, 24, 218),
    panel_edge = Color(55, 70, 84, 235),
    primary = Color(75, 220, 235, 245),
    secondary = Color(75, 220, 235, 165),
    tertiary = Color(75, 220, 235, 105),
    value = Color(120, 235, 160, 255),
    amber = Color(245, 185, 80, 235),
    text = Color(226, 234, 240, 255),
    muted = Color(145, 160, 172, 255),
    danger = Color(245, 112, 112, 255),
}

local State = {
    menu = nil,
    hero = nil,
    team = nil,
    match_id = nil,
    lifecycle = "loaded",
    camp_seen = {},
    camp_cleared_until = {},
    lane_paths = nil,
    opportunities = {},
    opportunity_by_key = {},
    plan = nil,
    previous_plan = nil,
    calibration = Coach.NewCalibration(),
    clear_sample = nil,
    active_camp = nil,
    next_sample_at = 0,
    last_reason = "initial",
    diag = nil,
    error_at = {},
    visual_pos = {},
    last_draw_at = nil,
    last_log_signature = nil,
    path_cache = {},
    our_fountain = nil,
    enemy_fountain = nil,
}

local LOG = Logger("CarryFarmCoach")

-- Logging and shared helpers

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function now()
    if not (GameRules and GameRules.GetGameTime) then return nil end
    local ok, t = pcall(GameRules.GetGameTime)
    return (ok and finite(t)) and t or nil
end

local function mget(name, fallback)
    local w = State.menu and State.menu[name]
    if not (w and w.Get) then return fallback end
    local ok, value = pcall(w.Get, w)
    return (ok and value ~= nil) and value or fallback
end

local function diagnostics() return mget("diagnostics", false) == true end
local function verbosity() return math.max(0, math.min(3, math.floor(mget("verbosity", 1) or 1))) end

local function logline(level, event, fields)
    if level > 0 and (not diagnostics() or level > verbosity()) then return end
    local parts, keys = { event }, {}
    for key in pairs(fields or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(fields[key]) end
    local line = table.concat(parts, " | ")
    if level == 0 then LOG:error(line)
    elseif level == 1 then LOG:info(line)
    else LOG:debug(line) end
end

local function log_error(key, message)
    local t = now() or 0
    if State.error_at[key] and t - State.error_at[key] < K.ERROR_THROTTLE_S then return end
    State.error_at[key] = t
    logline(0, "error", { key = key, message = message })
end

local function pos_plain(p)
    if not p or not finite(p.x) or not finite(p.y) then return nil end
    return { x = p.x, y = p.y, z = finite(p.z) and p.z or 0 }
end

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- Map safety and pathfinding

local function resolve_fountains(team)
    local ours, enemy
    for _, f in ipairs(MapData.FOUNTAINS or {}) do
        local p = f.pos and {x=f.pos[1],y=f.pos[2]}
        if p then
            if f.team == team then ours = p else enemy = p end
        end
    end
    return ours, enemy
end

local function structural_risk(pos)
    if not (Farm and Farm.StructuralRisk) then return 0 end
    local ok, risk = pcall(Farm.StructuralRisk,pos,{
        our_fountain=State.our_fountain,
        enemy_fountain=State.enemy_fountain,
        half_weight=math.max(0,math.min(1,mget("enemy_side_risk",70)/100)),
    })
    return ok and finite(risk) and math.max(0,math.min(1,risk)) or 0
end

local function path_key(a, b)
    return string.format("%d,%d>%d,%d", math.floor(a.x/128), math.floor(a.y/128),
        math.floor(b.x/128), math.floor(b.y/128))
end

local function walk_distance(a, b)
    local fallback = dist(a, b)
    if not (Map and Map.Path and Vector) then return fallback end
    local key = path_key(a, b)
    local t = now() or 0
    local cached = State.path_cache[key]
    if cached and t - cached.at <= 3 then return cached.length end
    local ok, path = pcall(Map.Path, Vector(a.x,a.y,a.z or 0), Vector(b.x,b.y,b.z or 0))
    if not ok or type(path) ~= "table" or #path < 1 then
        State.path_cache[key] = {at=t,length=fallback}
        return fallback
    end
    local total, previous = 0, a
    for _, point in ipairs(path) do
        local current = pos_plain(point)
        if current then total, previous = total + dist(previous,current), current end
    end
    total = total + dist(previous,b)
    if not finite(total) or total < fallback * 0.95 then total = fallback end
    State.path_cache[key] = {at=t,length=total}
    return total
end

local function camp_key(center)
    if Map.CampKey then
        local ok, key = pcall(Map.CampKey, center)
        if ok and type(key) == "string" and key ~= "" then return key end
    end
    if Coach.CampKey then return Coach.CampKey(center) end
    if not center or not finite(center.x) or not finite(center.y) then return nil end
    return string.format("%d,%d", math.floor(center.x / 100), math.floor(center.y / 100))
end

local function in_game()
    local ok, yes = pcall(function() return Engine and Engine.IsInGame and Engine.IsInGame() end)
    return ok and yes == true
end

local function local_hero()
    local ok, hero = pcall(function() return Heroes and Heroes.GetLocal and Heroes.GetLocal() end)
    return ok and hero or nil
end

local function hero_name(hero)
    local ok, name = pcall(function() return hero and NPC.GetUnitName(hero) end)
    return ok and name or nil
end

local function reset_runtime(lifecycle)
    State.hero, State.team, State.match_id = nil, nil, nil
    State.camp_seen, State.camp_cleared_until = {}, {}
    State.opportunities, State.opportunity_by_key = {}, {}
    State.plan, State.previous_plan, State.clear_sample, State.active_camp = nil, nil, nil, nil
    State.calibration = Coach.ResetMatch(State.calibration)
    State.visual_pos, State.last_draw_at, State.last_log_signature = {}, nil, nil
    State.path_cache = {}
    State.our_fountain, State.enemy_fountain = nil, nil
    State.next_sample_at, State.last_reason, State.diag = 0, "initial", nil
    State.lifecycle = lifecycle or "idle"
end

local function match_identity(hero)
    local start, index = 0, "?"
    pcall(function() start = GameRules.GetGameStartTime and GameRules.GetGameStartTime() or 0 end)
    pcall(function() index = tostring(Entity.GetIndex(hero)) end)
    return tostring(start) .. ":" .. index
end

-- Camp and lane opportunity collection

local function camp_visible(center)
    if not (FogOfWar and FogOfWar.IsPointVisible and Vector) then return false end
    local ok, visible = pcall(FogOfWar.IsPointVisible, Vector(center.x, center.y, center.z or 0))
    return ok and visible == true
end

local function creep_values(creeps)
    local plain = {}
    for _, creep in ipairs(creeps or {}) do
        local ok_hp, hp = pcall(Entity.GetHealth, creep)
        local ok_gold, gold = pcall(NPC.GetGoldBountyMax, creep)
        if ok_hp and finite(hp) and hp > 0 and ok_gold and finite(gold) and gold >= 0 then
            plain[#plain + 1] = { hp = hp, gold = gold }
        end
    end
    return Farm.GoldValue(plain), Farm.EffectiveHP(plain), #plain
end

local function hero_profile(hero)
    if not hero or not Entity.IsAlive(hero) then return nil, "hero_dead" end
    local p = pos_plain(Entity.GetAbsOrigin(hero))
    local ms = NPC.GetMoveSpeed and NPC.GetMoveSpeed(hero)
    local dmin = NPC.GetTrueDamage and NPC.GetTrueDamage(hero)
    local dmax = NPC.GetTrueMaximumDamage and NPC.GetTrueMaximumDamage(hero)
    local attack_t = NPC.GetAttackTime and NPC.GetAttackTime(hero)
    local range = NPC.GetAttackRange and NPC.GetAttackRange(hero) or 350
    if not p or not finite(ms) or ms <= 0 or not finite(dmin) or dmin <= 0
        or not finite(dmax) or dmax < dmin or not finite(attack_t) or attack_t <= 0 then
        return nil, "hero_stats_unavailable"
    end
    return {
        pos = p, move_speed = ms,
        attack_damage = (dmin + dmax) * 0.5,
        attacks_per_second = 1 / attack_t,
        engage_delay = math.max(0.20, 0.65 - math.min(600, range) / 1500),
        reposition_factor = 1.05,
    }
end

local function camp_opportunities(t, profile)
    local out, by_key, activity = {}, {}, {}
    State.confirmed_empty = {}
    local camps = Map.Camps() or {}
    local neutrals = Map.AllNeutrals() or {}
    local centers, nearest_creeps = {}, {}
    for _, cd in ipairs(camps) do
        local center = cd.center and pos_plain(cd.center) or nil
        local key = center and camp_key(center) or nil
        if key and center then centers[#centers+1] = {key=key,pos=center} end
    end
    for _, neutral in ipairs(neutrals) do
        local p = pos_plain(Entity.GetAbsOrigin(neutral))
        local key = p and Coach.NearestCampKey(p, centers, K.CAMP_NEAREST_FALLBACK_R) or nil
        if key then
            nearest_creeps[key] = nearest_creeps[key] or {}
            nearest_creeps[key][#nearest_creeps[key]+1] = neutral
        end
    end
    for _, cd in ipairs(camps) do
        if cd.center and cd.camp and CAMP_KIND[cd.type] then
            local center = pos_plain(cd.center)
            local key = center and camp_key(center)
            local cleared_until = key and State.camp_cleared_until[key]
            local creeps = Map.CampCreeps(cd.camp, neutrals) or {}
            if key and #creeps == 0 and nearest_creeps[key] then creeps = nearest_creeps[key] end
            local observation
            local scan_state = Coach.CampScanState(cleared_until, #creeps, t)
            if key and scan_state == "live" then
                State.camp_cleared_until[key] = nil
                local gold, ehp, count = creep_values(creeps)
                if count > 0 then
                    observation = { key=key, region="jungle", pos=center, gold=gold, ehp=ehp,
                        count=count, source="live", observed_at=t, category=CAMP_KIND[cd.type] }
                    State.camp_seen[key] = observation
                    activity[#activity+1] = {key=key,pos=center,ehp=ehp,count=count,live=true}
                end
            elseif key and scan_state == "cleared" then
            elseif key and center and camp_visible(center) then
                State.camp_seen[key] = nil
                State.camp_cleared_until[key] = Coach.NextRespawnBoundary(t)
                State.confirmed_empty[key] = true
                activity[#activity+1] = {key=key,pos=center,ehp=0,count=0,live=false}
            elseif key then
                local seen = State.camp_seen[key]
                if seen and t - seen.observed_at <= K.CAMP_CACHE_MAX_S then
                    observation = { key=seen.key, region=seen.region, pos=seen.pos, gold=seen.gold,
                        ehp=seen.ehp, count=seen.count, source="cached",
                        observed_at=seen.observed_at, category=seen.category }
                else
                    local estimate = TIER_EST[cd.type] or TIER_EST[1]
                    observation = { key=key, region="jungle", pos=center,
                        gold=estimate.gold, ehp=estimate.hp, count=1, source="clock",
                        observed_at=t, category=CAMP_KIND[cd.type] }
                end
            end
            if observation then
                observation.risk = structural_risk(center)
                local cold = Coach.ColdClearEstimate(observation.ehp, profile)
                local clear = Coach.BlendedClearTime(State.calibration, observation.category, cold)
                observation.clear_t = clear
                local normalized = clear and Coach.NormalizeCamp(observation, t) or nil
                if normalized then
                    normalized.category = observation.category
                    out[#out + 1], by_key[normalized.key] = normalized, normalized
                end
            end
        end
    end
    return out, by_key, activity
end

local function lane_push_dirs(team)
    local ours, theirs
    for _, f in ipairs(MapData.FOUNTAINS or {}) do
        if f.team == team then ours = f.pos else theirs = f.pos end
    end
    if not (ours and theirs) then return {x=1,y=1}, {x=-1,y=-1} end
    return { x=ours[1]-theirs[1], y=ours[2]-theirs[2] },
           { x=theirs[1]-ours[1], y=theirs[2]-ours[2] }
end

local function wave_opportunities(t, profile)
    State.lane_paths = State.lane_paths or Lane.BuildLanePaths(MapData.TOWERS, MapData.SPAWNS)
    local enemy_push, ally_push = lane_push_dirs(State.team)
    local lanes = Lane.ScanLanes({
        team = State.team, enemy_push = enemy_push, ally_push = ally_push,
        hero_pos = {x=profile.pos.x,y=profile.pos.y}, move_speed = profile.move_speed,
        game_time = t, paths = State.lane_paths,
    })
    local expected = Lane.ExpectedWave(t, {})
    local out, by_key = {}, {}
    for _, name in ipairs({"top", "mid", "bot"}) do
        local s = lanes and lanes[name]
        local wave = s and s.enemy_wave
        local wp = Coach.WaveTargetPosition(wave,s and s.clash)
        if wave and wp and finite(wave.gold) and wave.gold > 0 and finite(wave.hp) and wave.hp > 0 then
            local source = "live"
            if wave.estimated then source = wave.est_src == "mirror" and "mirrored" or "clock" end
            local cold = Coach.ColdClearEstimate(wave.hp, profile)
            local clear = Coach.BlendedClearTime(State.calibration, "wave", cold)
            local sample = {
                key="wave:"..name, region=name, pos={x=wp.x,y=wp.y,z=0}, gold=wave.gold,
                ehp=wave.hp, count=math.max(1,wave.count or 1),
                expected_count=math.max(wave.count or 1, expected and expected.count or 1),
                clear_t=clear, source=source, observed_at=t,
                expires_at=t + K.WAVE_WINDOW_S,
            }
            local normalized = Coach.NormalizeWave(sample, t)
            if normalized then
                normalized.category = "wave"
                out[#out + 1], by_key[normalized.key] = normalized, normalized
            end
        end
    end
    return out, by_key, lanes
end

local function other_hero_near(pos)
    for _, hero in ipairs(Heroes.GetAll() or {}) do
        if hero ~= State.hero and Entity.IsAlive(hero) and not Entity.IsDormant(hero) then
            local p = pos_plain(Entity.GetAbsOrigin(hero))
            if p and dist(p, pos) <= K.OTHER_HERO_R then return true end
        end
    end
    return false
end

local function allied_hero_points()
    local out = {}
    for _, hero in ipairs(Heroes.GetAll() or {}) do
        if hero ~= State.hero and Entity.IsAlive(hero) and not Entity.IsDormant(hero)
            and Entity.GetTeamNum(hero) == State.team then
            local illusion = false
            if NPC.IsIllusion then
                local ok, value = pcall(NPC.IsIllusion, hero)
                illusion = ok and value == true
            end
            local p = not illusion and pos_plain(Entity.GetAbsOrigin(hero)) or nil
            if p then out[#out+1] = {pos=p,value=1} end
        end
    end
    return out
end

-- Clear-time learning and route planning

local function update_learning(t, profile)
    local first = State.plan and State.plan.steps and State.plan.steps[1]
    if not State.clear_sample and first and first.kind == "camp" and first.source == "live"
        and dist(profile.pos, first.pos) <= K.CLEAR_START_R then
        State.clear_sample = Coach.BeginClearSample(first.category or first.kind, first.key, t,
            {count=first.count or 1})
        if State.clear_sample then State.clear_sample.pos = first.pos end
        if State.clear_sample then logline(2, "clear_sample_begin", {key=first.key}) end
    end
    local sample = State.clear_sample
    if not sample then return end
    local current = State.opportunity_by_key[sample.source_key]
    local remaining = current and (current.count or 1) or 0
    local source_pos = current and current.pos or sample.pos
    local confirmed_empty = State.confirmed_empty and State.confirmed_empty[sample.source_key] == true
    local event = {
        remaining = remaining,
        coherent_clear = confirmed_empty,
        hero_dead = not Entity.IsAlive(State.hero),
        left_radius = source_pos and dist(profile.pos, source_pos) > K.CLEAR_LEAVE_R or false,
        other_hero_present = source_pos and other_hero_near(source_pos) or false,
        idle_s = 0,
    }
    sample = Coach.UpdateClearSample(sample, t, event)
    State.clear_sample = sample
    if sample and remaining == 0 and confirmed_empty then
        local next_cal, accepted, why = Coach.AcceptClearSample(State.calibration, sample, t)
        State.calibration, State.clear_sample = next_cal, nil
        logline(2, accepted and "clear_sample_accept" or "clear_sample_reject",
            {key=sample.source_key, why=why})
    elseif sample and (event.left_radius or event.hero_dead or event.other_hero_present) then
        local _, _, why = Coach.AcceptClearSample(State.calibration, sample, t)
        State.clear_sample = nil
        logline(2, "clear_sample_reject", {key=sample.source_key, why=why})
    end
end

local function reason_text(plan)
    if not plan then return "Waiting for reliable farm data" end
    local n = plan.reason_delta or 0
    local messages = {
        EXPIRING_VALUE = string.format("Catch %.0f expiring lane gold", n),
        BEST_NEARBY_VALUE = string.format("Best cycle value by %.0f gold", n),
        RESPAWN_SETUP = "Finishes beside the next camp cycle",
        LESS_DEAD_TRAVEL = string.format("Avoids %.1fs dead travel", n),
        HIGHER_CONFIDENCE = "Uses more reliable live information",
        ONLY_VALID_ROUTE = "Only complete route inside this cycle",
    }
    return messages[plan.reason_code] or "Best available farming route"
end

local function recalculate(t, profile)
    local camps, camp_by, activity = camp_opportunities(t, profile)
    local waves, wave_by, lanes = wave_opportunities(t, profile)
    local all, by_key = {}, {}
    for _, o in ipairs(camps) do all[#all+1]=o; by_key[o.key]=o end
    for _, o in ipairs(waves) do all[#all+1]=o; by_key[o.key]=o end
    State.opportunities, State.opportunity_by_key = all, by_key

    local attacking = false
    if NPC.IsAttacking then
        local ok, value = pcall(NPC.IsAttacking, State.hero)
        attacking = ok and value == true
    end
    local active_key, active_reason
    State.active_camp, active_key, active_reason = Farm.UpdateActiveCamp(activity,
        State.active_camp, {
            now=t,
            hero_pos=profile.pos,
            attacking=attacking,
            allies=allied_hero_points(),
        }, {
            start_radius=K.CLEAR_START_R,
            leave_radius=K.CLEAR_LEAVE_R,
            provisional_s=0.8,
            evidence_grace_s=2.25,
            attack_credit_s=1.0,
            ally_radius=K.OTHER_HERO_R,
        })

    local respawn_boundary = Coach.PlanningBoundary(t, K.MIN_PLAN_WINDOW_S)
    if not respawn_boundary then State.plan=nil; return end
    local boundary = t + K.ROUTE_HORIZON_S
    local depth = math.max(2, math.min(4, math.floor(mget("route_depth", 3))))
    local locked_first = active_key
    if not locked_first and State.clear_sample then
        local current = by_key[State.clear_sample.source_key]
        if current and current.kind == "camp" and current.source == "live"
            and dist(profile.pos,current.pos) <= K.CLEAR_LEAVE_R then
            locked_first = current.key
        end
    end
    local plan = Coach.Plan(all, profile, {now=t,boundary=boundary}, {
        max_steps=depth, pool_cap=K.ROUTE_POOL_CAP,
        immediate_leg_cap_s=mget("max_leg",K.IMMEDIATE_LEG_CAP_S),
        end_setup_radius=1100, stability_margin=K.STABILITY_MARGIN,
        step_decay=K.ROUTE_STEP_DECAY, travel_cost_per_s=mget("travel_cost",K.TRAVEL_GOLD_PER_S),
        urgent_weight=0.12, distance_fn=walk_distance,
        risk_gold=K.STRUCTURAL_RISK_GOLD,
        locked_first_key=locked_first,
    }, State.previous_plan)
    State.plan, State.previous_plan = plan, plan
    State.last_reason = plan and plan.reason_code or "no_plan"
    State.diag = {
        at=t, boundary=respawn_boundary, deadline=boundary, horizon=boundary-t,
        camps=#camps, waves=#waves, lanes=lanes,
        candidates=#all, chosen=plan and #plan.steps or 0,
        reason=State.last_reason, calibration=State.calibration,
        locked_first=locked_first,
        active_reason=active_reason,
    }
    local signature = plan and (function()
        local k={}; for i,s in ipairs(plan.steps) do k[i]=s.key end
        return table.concat(k,",") .. ":" .. tostring(plan.reason_code)
    end)() or "none"
    local event_level = signature ~= State.last_log_signature and 1 or 2
    State.last_log_signature = signature
    logline(event_level, "replan", {
        camps=#camps, waves=#waves, now=string.format("%.1f",t),
        respawn=string.format("%.0f",respawn_boundary), deadline=string.format("%.0f",boundary),
        horizon=string.format("%.1f",boundary-t),
        chosen=plan and #plan.steps or 0,
        route=plan and (function() local k={}; for i,s in ipairs(plan.steps) do k[i]=s.key end; return table.concat(k,",") end)() or "none",
        gold=plan and string.format("%.0f",plan.gold) or 0,
        time=plan and string.format("%.1f",plan.total_t) or 0,
        reason=State.last_reason,
        locked=locked_first or "none",
        active=active_reason or "none",
    })
    update_learning(t, profile)
end

local function setup_menu()
    local function group(name)
        return Menu.Find("Heroes", "Hero List", "Carry", "Farm Coach", name)
            or Menu.Create("Heroes", "Hero List", "Carry", "Farm Coach", name)
    end
    local main, visual, diag = group("Coach"), group("Visuals"), group("Diagnostics")
    State.menu = {
        enable = main:Switch("Enable farming coach", true, "\u{f5da}"),
        route_depth = main:Slider("Route steps", 2, 4, 3, "%d"),
        travel_cost = main:Slider("Dead travel cost", 0, 15, K.TRAVEL_GOLD_PER_S,
            function(v) return string.format("%dg/s",v) end),
        max_leg = main:Slider("Maximum travel leg", 6, 20, K.IMMEDIATE_LEG_CAP_S,
            function(v) return string.format("%ds",v) end),
        enemy_side_risk = main:Slider("Enemy-side camp risk", 0, 100, 70, "%d%%"),
        refresh = main:Slider("Refresh rate", 20, 200, 50,
            function(v) return string.format("%.1fs", v / 100) end),
        hud_scale = visual:Slider("Coach size", 70, 140, 100, "%d%%"),
        hud_x = visual:Slider("Coach horizontal position", 5, 95, 78, "%d%%"),
        hud_y = visual:Slider("Coach vertical position", 5, 90, 18, "%d%%"),
        world_opacity = visual:Slider("World route opacity", 20, 100, 90, "%d%%"),
        hud_opacity = visual:Slider("Coach background opacity", 20, 100, 84, "%d%%"),
        diagnostics = diag:Switch("Diagnostics", false, "\u{f188}"),
        verbosity = diag:Slider("Log detail", 0, 3, 1, "%d"),
        candidates = diag:Switch("Show route candidates", false),
    }
end

-- Update lifecycle

local function update()
    if not in_game() then
        if State.lifecycle ~= "outside" then reset_runtime("outside") end
        return
    end
    local hero = local_hero()
    local name = hero_name(hero)
    if not hero or not SUPPORTED_RANGED[name] then
        if State.lifecycle ~= "unsupported" then reset_runtime("unsupported") end
        return
    end
    if not mget("enable", true) then
        State.plan, State.lifecycle = nil, "disabled"
        return
    end
    local id = match_identity(hero)
    if State.match_id ~= id then
        reset_runtime("active")
        State.match_id, State.hero = id, hero
        State.team = Entity.GetTeamNum(hero)
        State.our_fountain, State.enemy_fountain = resolve_fountains(State.team)
        logline(1, "match_start", {hero=name,id=id})
    else
        State.hero = hero
    end
    local t = now()
    if not t or t < 0 or t < State.next_sample_at then return end
    State.next_sample_at = t + math.max(0.2, math.min(2.0, mget("refresh", 50) / 100))
    local profile, why = hero_profile(hero)
    if not profile then
        State.plan = nil
        if why ~= "hero_dead" then log_error("profile", why) end
        return
    end
    recalculate(t, profile)
end

-- World route and coach panel

local function alpha(color, percent)
    return Color(color.r, color.g, color.b, math.floor(color.a * percent / 100))
end

local function vector(p, z) return Vector(p.x, p.y, z or p.z or 0) end

local function route_seg(a, b, color, thickness, pieces)
    pieces = pieces or 14
    local prev, pvis
    for i=0,pieces do
        local f=i/pieces
        local p=Vector(a.x+(b.x-a.x)*f,a.y+(b.y-a.y)*f,a.z)
        local sp,vis=Draw.W2S(p)
        if i>0 and pvis and vis then Render.Line(prev,sp,color,thickness or 2) end
        prev,pvis=sp,vis
    end
end

local function dashed_seg(a, b, color, thickness)
    local pieces = 12
    for i=0,pieces-1,2 do
        local t0, t1 = i/pieces, math.min(1,(i+1)/pieces)
        route_seg(Vector(a.x+(b.x-a.x)*t0,a.y+(b.y-a.y)*t0,a.z),
            Vector(a.x+(b.x-a.x)*t1,a.y+(b.y-a.y)*t1,a.z),color,thickness,2)
    end
end

local function draw_wave_marker(p, color, scale)
    local r = 72 * scale
    Draw.Ring(p,r,color,2.2)
    Draw.Ring(p,r*0.42,alpha(color,58),1.2)
end

local function smooth_step_pos(step, draw_t)
    local desired=step.pos
    local old=State.visual_pos[step.key]
    if not old then
        old={x=desired.x,y=desired.y,z=desired.z or 0}
        State.visual_pos[step.key]=old
        return old
    end
    local dx,dy=desired.x-old.x,desired.y-old.y
    local d=math.sqrt(dx*dx+dy*dy)
    if d>1800 then old.x,old.y=desired.x,desired.y
    elseif d>24 then
        local dt=math.max(0,math.min(0.1,draw_t-(State.last_draw_at or draw_t)))
        local blend=1-math.exp(-7*dt)
        old.x,old.y=old.x+dx*blend,old.y+dy*blend
    end
    old.z=desired.z or old.z or 0
    return old
end

local function target_badge(p,step,index,color)
    local sp,vis=Draw.W2S(p); if not vis then return end
    if index>1 then
        Render.FilledCircle(Vec2(sp.x,sp.y),8,Color(9,13,18,230))
        Render.FilledCircle(Vec2(sp.x,sp.y),5,color)
        Render.Text(Draw.Font(),10,tostring(index),Vec2(sp.x-3,sp.y-6),C.text)
        return
    end
    local name=step.kind=="wave" and ((step.region or "lane").." wave")
        or (step.category or "camp")
    local est=(step.confidence or 1)<0.9 and "  EST" or ""
    local label=string.format("%s  |  %.0fg%s",name,step.value or 0,est)
    local font=Draw.Font(); local size=12
    local ts=Render.TextSize(font,size,label)
    local x,y=sp.x+14,sp.y-18
    Render.FilledRect(Vec2(x-7,y-4),Vec2(x+ts.x+10,y+ts.y+5),Color(9,13,18,220),5)
    Render.FilledRect(Vec2(x-7,y-4),Vec2(x-4,y+ts.y+5),color,3)
    Render.FilledCircle(Vec2(sp.x,sp.y),index==1 and 9 or 7,Color(9,13,18,235))
    Render.FilledCircle(Vec2(sp.x,sp.y),index==1 and 6 or 4,color)
    Render.Text(font,size,label,Vec2(x,y),C.text)
end

local function draw_world_route()
    local plan, hero = State.plan, State.hero
    if not (plan and hero and Entity.IsAlive(hero)) then return end
    local origin = Entity.GetAbsOrigin(hero)
    if not origin then return end
    local opacity = math.max(20, math.min(100, mget("world_opacity",90)))
    local draw_t=now() or 0
    local prev = origin
    for i, step in ipairs(plan.steps or {}) do
        local here = vector(smooth_step_pos(step,draw_t),origin.z)
        local base = (i==1 and C.primary) or (i==2 and C.secondary) or C.tertiary
        local col = alpha((step.confidence or 1) < 0.9 and C.amber or base, opacity)
        local thickness=i==1 and 3.4 or (i==2 and 2.2 or 1.6)
        if (step.confidence or 1) < 0.9 then dashed_seg(prev,here,col,thickness)
        else route_seg(prev,here,col,thickness,18) end
        if step.kind == "wave" then draw_wave_marker(here,col,i==1 and 1.15 or 0.9)
        else
            Draw.Ring(here,i==1 and 105 or 82,col,i==1 and 2.8 or 1.8)
            Draw.Ring(here,i==1 and 42 or 32,alpha(col,55),1.1)
        end
        target_badge(here,step,i,col)
        prev = here
    end
    State.last_draw_at=draw_t
end

local function draw_panel()
    if State.lifecycle == "outside" then return end
    local screen = Render.ScreenSize()
    local scale = math.max(0.7,math.min(1.4,mget("hud_scale",100)/100))
    local w,h = 360*scale,132*scale
    local cx,cy = screen.x*mget("hud_x",78)/100,screen.y*mget("hud_y",18)/100
    local x,y = math.max(8,math.min(screen.x-w-8,cx-w/2)),math.max(8,math.min(screen.y-h-8,cy-h/2))
    local opacity = math.max(20,math.min(100,mget("hud_opacity",84)))
    Render.FilledRect(Vec2(x+4*scale,y+5*scale),Vec2(x+w+4*scale,y+h+5*scale),Color(0,0,0,90),10*scale)
    Render.FilledRect(Vec2(x,y),Vec2(x+w,y+h),alpha(C.panel,opacity),10*scale)
    Render.FilledRect(Vec2(x,y),Vec2(x+4*scale,y+h),C.primary,4*scale)
    pcall(Render.Rect,Vec2(x,y),Vec2(x+w,y+h),C.panel_edge,8*scale,
        Enum and Enum.DrawFlags and Enum.DrawFlags.RoundCornersAll or nil,1.2)
    local font=Draw.Font()
    local function status(text)
        Render.Text(font,math.floor(12*scale),"FARM ROUTE",Vec2(x+18*scale,y+12*scale),C.muted)
        Render.Text(font,math.floor(17*scale),text,Vec2(x+18*scale,y+39*scale),C.amber)
    end
    local plan=State.plan
    if State.lifecycle == "unsupported" then
        status("Waiting for carry data"); return
    end
    if not State.hero or not Entity.IsAlive(State.hero) then
        status("Waiting for respawn"); return
    end
    if not plan or not plan.steps[1] then
        status("Not enough reliable farm data"); return
    end
    local first=plan.steps[1]
    local route={}; for i,s in ipairs(plan.steps) do route[i]=(s.kind=="wave" and s.region.." wave" or (s.category or "camp")) end
    local uncertain=0; for _,s in ipairs(plan.steps) do if (s.confidence or 1)<0.9 then uncertain=uncertain+1 end end
    local next_name=first.kind=="wave" and ((first.region or "lane").." wave") or ((first.category or "camp").." camp")
    local confidence=uncertain==0 and "LIVE" or (uncertain<#plan.steps and "MIXED" or "EST")
    Render.Text(font,math.floor(11*scale),"NEXT FARM",Vec2(x+18*scale,y+10*scale),C.muted)
    Render.Text(font,math.floor(19*scale),string.upper(next_name),Vec2(x+18*scale,y+29*scale),C.primary)

    local chips={
        {string.format("%.0fg",plan.gold or 0),C.value},
        {string.format("%.0fs",plan.total_t or 0),C.text},
        {confidence,uncertain==0 and C.value or C.amber},
    }
    local chip_x=x+18*scale
    for _,chip in ipairs(chips) do
        local ts=Render.TextSize(font,11,chip[1]); local cw=(ts.x+15)*scale
        Render.FilledRect(Vec2(chip_x,y+57*scale),Vec2(chip_x+cw,y+78*scale),Color(27,35,43,220),5*scale)
        Render.Text(font,math.floor(11*scale),chip[1],Vec2(chip_x+7*scale,y+61*scale),chip[2])
        chip_x=chip_x+cw+6*scale
    end
    Render.Text(font,math.floor(11*scale),table.concat(route,"  >  "),Vec2(x+18*scale,y+87*scale),C.muted)
    Render.Text(font,math.floor(12*scale),reason_text(plan),Vec2(x+18*scale,y+108*scale),C.text)
end

-- Diagnostics and protected callbacks

local function draw_diagnostics()
    if not diagnostics() or not State.diag then return end
    local s=Render.ScreenSize(); local x,y=18,s.y*0.28
    local lines={
        string.format("COACH DIAG  camps=%d waves=%d candidates=%d chosen=%d",State.diag.camps,State.diag.waves,State.diag.candidates,State.diag.chosen),
        string.format("reason=%s deadline=%.0f respawn=%.0f sample=%s",State.diag.reason,
            State.diag.deadline or 0,State.diag.boundary,
            State.clear_sample and State.clear_sample.source_key or "none"),
    }
    if mget("candidates",false) then
        local hp=State.hero and pos_plain(Entity.GetAbsOrigin(State.hero))
        local ms=State.hero and NPC.GetMoveSpeed and NPC.GetMoveSpeed(State.hero) or 0
        local chosen={}
        for i,s in ipairs(State.plan and State.plan.steps or {}) do chosen[s.key]=i end
        for _,o in ipairs(State.opportunities) do
            local d=hp and walk_distance(hp,o.pos) or 0
            local travel=ms and ms>0 and d/ms or 0
            local net=o.value-travel*mget("travel_cost",K.TRAVEL_GOLD_PER_S)
                -(o.risk or 0)*K.STRUCTURAL_RISK_GOLD
            lines[#lines+1]=string.format("%s %s %s g%.0f d%.0f tr%.1f clear%.1f net%.0f risk%.2f conf%.2f %s",
                chosen[o.key] and ("CHOSEN#"..chosen[o.key]) or "eligible",
                o.key,o.kind,o.value,d,travel,o.clear_t,net,o.risk or 0,o.confidence,o.source)
        end
    end
    for i,line in ipairs(lines) do
        Render.Text(Draw.Font(),13,line,Vec2(x,y+(i-1)*17),i<=2 and C.text or C.muted)
    end
end

local function draw()
    if not mget("enable",true) or not in_game() then return end
    draw_world_route(); draw_panel(); draw_diagnostics()
end

local function guarded(name, fn)
    return function(...)
        local ok, err = pcall(fn,...)
        if not ok then State.plan=nil; log_error(name,tostring(err)) end
    end
end

setup_menu()

return {
    OnUpdateEx = guarded("update",update),
    OnDraw = guarded("draw",draw),
}
