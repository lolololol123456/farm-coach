#!/usr/bin/env lua
package.path = "./?.lua;../?.lua;" .. package.path

local ok_req, Coach = pcall(require, "lib.carry_farm_coach")
if not ok_req then
    io.stderr:write("cannot require lib.carry_farm_coach: " .. tostring(Coach) .. "\n")
    os.exit(2)
end

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. (detail and (" -- " .. detail) or ""))
    end
end

local function approx(a, b, eps)
    return type(a) == "number" and math.abs(a - b) <= (eps or 1e-6)
end

print("camp normalization")
do
    local camp_state = Coach.CampScanState
    check("camp scan state helper is exposed", type(camp_state) == "function")
    if camp_state then
        check("live creeps override a stale cleared-until latch", camp_state(960, 3, 923) == "live")
        check("an empty scan still honors an active cleared-until latch", camp_state(960, 0, 923) == "cleared")
        check("an expired cleared-until latch allows a fresh scan", camp_state(900, 0, 923) == "scan")
    end
    check("stable camp key matches map-library bucket",
        Coach.CampKey({x=1234,y=-567}) == "12,-6")
    check("camp key rejects malformed positions", Coach.CampKey({x=1}) == nil)
    local input = {
        key = "safe-medium", kind = "camp", region = "safe_jungle",
        pos = { x = 100, y = 200, z = 8 }, gold = 100, ehp = 900, count = 3,
        clear_t = 6, source = "live", observed_at = 10, risk = 0.35,
    }
    local live = Coach.NormalizeCamp(input, 10)
    check("live occupied camp is accepted", live ~= nil)
    check("live occupied camp has full confidence", live and live.confidence == 1)
    check("camp fields survive normalization",
        live and live.key == "safe-medium" and live.kind == "camp"
        and live.region == "safe_jungle" and live.value == 100
        and live.clear_t == 6 and live.source == "live" and live.risk == 0.35)
    check("normalized position is copied", live and live.pos ~= input.pos)
    if live then live.pos.x = -1 end
    check("changing output cannot mutate camp input", input.pos.x == 100)

    local cached = Coach.NormalizeCamp({
        key = "old-large", region = "triangle", pos = { x = 0, y = 0 },
        gold = 150, ehp = 1200, count = 3, clear_t = 9,
        source = "cached", observed_at = 5,
    }, 15)
    check("cached occupied camp is accepted", cached ~= nil)
    check("cached camp confidence is below live",
        cached and live and cached.confidence < live.confidence)
    check("cached camp records observation age",
        cached and approx(cached.age_s, 10))

    check("visible empty camp is excluded", Coach.NormalizeCamp({
        key = "empty", region = "safe", pos = { x = 0, y = 0 },
        gold = 0, ehp = 0, count = 0, clear_t = 0,
        source = "live", observed_at = 10,
    }, 10) == nil)
end

print("wave normalization")
do
    local mirrored_pos = Coach.WaveTargetPosition({
        estimated=true, centroid={x=900,y=100}, front={x=950,y=100},
    }, {settle={x=100,y=100},contact={x=120,y=100}})
    check("estimated enemy wave is diagnostic-only, never an actionable target",
        mirrored_pos == nil, mirrored_pos and mirrored_pos.x)
    local clock_pos = Coach.WaveTargetPosition({estimated=true}, {
        settle={x=100,y=100},contact={x=120,y=100}})
    check("positionless clock wave is excluded instead of targeting our wave",
        clock_pos == nil)
    local live_pos = Coach.WaveTargetPosition({
        estimated=false, centroid={x=300,y=400}, front={x=350,y=400},
    }, {settle={x=700,y=700}})
    check("live enemy wave uses its real creep centroid",
        live_pos and live_pos.x == 300 and live_pos.y == 400)
    local full = Coach.NormalizeWave({
        key = "bot-wave", region = "bot", pos = { x = 300, y = -200 },
        gold = 180, ehp = 1600, count = 4, expected_count = 4,
        clear_t = 8, source = "live", observed_at = 20,
        expires_at = 32,
    }, 20)
    check("complete live wave is accepted", full ~= nil)
    check("complete live wave is not partial", full and full.partial == false)
    check("complete live wave has full confidence", full and full.confidence == 1)
    check("wave expiry survives normalization", full and full.expires_at == 32)

    local partial = Coach.NormalizeWave({
        key = "partial-top", region = "top", pos = { x = -200, y = 400 },
        gold = 80, ehp = 700, count = 2, expected_count = 4,
        clear_t = 5, source = "live", observed_at = 20,
    }, 20)
    check("partially visible wave is accepted", partial ~= nil)
    check("partially visible wave is explicitly marked", partial and partial.partial == true)
    check("partial live confidence is capped",
        partial and partial.confidence <= 0.65)

    local mirrored = Coach.NormalizeWave({
        key = "mirror-mid", region = "mid", pos = { x = 50, y = 50 },
        gold = 180, ehp = 1600, count = 4, expected_count = 4,
        clear_t = 8, source = "mirrored", observed_at = 18,
    }, 20)
    local clock = Coach.NormalizeWave({
        key = "clock-mid", region = "mid", pos = { x = 60, y = 60 },
        gold = 180, ehp = 1600, count = 4, expected_count = 4,
        clear_t = 8, source = "clock", observed_at = 18,
    }, 20)
    check("mirrored prediction is accepted", mirrored ~= nil)
    check("clock prediction is accepted", clock ~= nil)
    check("mirrored prediction outranks clock-only prediction",
        mirrored and clock and mirrored.confidence > clock.confidence)
    check("mirrored confidence is capped", mirrored and mirrored.confidence <= 0.55)
    check("clock confidence is capped", clock and clock.confidence <= 0.35)
end

print("confidence aging and validation")
do
    local newer = Coach.Confidence("cached", false, 5)
    local older = Coach.Confidence("cached", false, 30)
    check("cached confidence decays monotonically",
        type(newer) == "number" and type(older) == "number" and newer > older)
    check("confidence remains bounded",
        older and older >= 0 and newer and newer <= 1)
    check("unknown source is rejected", Coach.Confidence("invented", false, 0) == nil)

    local bad = {
        { key = "", pos = { x = 0, y = 0 }, gold = 1, ehp = 1, count = 1, clear_t = 1, source = "live", observed_at = 0 },
        { key = "x", pos = nil, gold = 1, ehp = 1, count = 1, clear_t = 1, source = "live", observed_at = 0 },
        { key = "x", pos = { x = 0/0, y = 0 }, gold = 1, ehp = 1, count = 1, clear_t = 1, source = "live", observed_at = 0 },
        { key = "x", pos = { x = 0, y = 0 }, gold = -1, ehp = 1, count = 1, clear_t = 1, source = "live", observed_at = 0 },
        { key = "x", pos = { x = 0, y = 0 }, gold = 1, ehp = 1, count = 1, clear_t = 1, source = "bad", observed_at = 0 },
    }
    for i, sample in ipairs(bad) do
        check("malformed opportunity fails closed " .. i,
            Coach.NormalizeCamp(sample, 0) == nil)
    end
end

print("ranged cold clear estimate")
do
    local ranged = {
        attack_damage = 100, attacks_per_second = 1.5,
        engage_delay = 0.5, reposition_factor = 1.05,
    }
    check("cold estimate includes engagement and reposition",
        approx(Coach.ColdClearEstimate(1200, ranged), 8.925, 0.001))
    check("cold estimate rejects zero attack rate",
        Coach.ColdClearEstimate(1200, {attack_damage=100,attacks_per_second=0}) == nil)
    check("cold estimate rejects invalid effective hp",
        Coach.ColdClearEstimate(0, ranged) == nil)
end

print("match-only clear-time learning")
do
    local categories = { "small", "medium", "large", "ancient", "wave" }
    for _, category in ipairs(categories) do
        local sample = Coach.BeginClearSample(category, "source-" .. category, 10, { count = 3 })
        check("begins " .. category .. " sample", sample ~= nil)
    end

    local calibration = Coach.NewCalibration()
    local accepted = Coach.BeginClearSample("large", "large-1", 10, { count = 3 })
    accepted = Coach.UpdateClearSample(accepted, 17, {
        remaining = 0, coherent_clear = true, hero_dead = false,
        left_radius = false, other_hero_present = false, idle_s = 0,
    })
    local ok, why
    calibration, ok, why = Coach.AcceptClearSample(calibration, accepted, 17)
    check("uninterrupted clear is accepted", ok == true, why)
    check("accepted clear records seven seconds",
        calibration.large and approx(calibration.large.seconds, 7))
    check("accepted clear increments category samples",
        calibration.large and calibration.large.samples == 1)

    local rejected = {
        { left_radius = true, coherent_clear = true, remaining = 0, idle_s = 0 },
        { hero_dead = true, coherent_clear = true, remaining = 0, idle_s = 0 },
        { idle_s = 3.1, coherent_clear = true, remaining = 0 },
        { other_hero_present = true, coherent_clear = true, remaining = 0, idle_s = 0 },
        { coherent_clear = false, remaining = 0, idle_s = 0 },
    }
    for i, event in ipairs(rejected) do
        local s = Coach.BeginClearSample("large", "reject-" .. i, 20, { count = 3 })
        s = Coach.UpdateClearSample(s, 27, event)
        local before = calibration.large.samples
        calibration, ok = Coach.AcceptClearSample(calibration, s, 27)
        check("invalid clear sample rejected " .. i, ok == false)
        check("rejected sample does not change learning " .. i,
            calibration.large.samples == before)
    end

    local newer = Coach.BeginClearSample("large", "large-2", 30, { count = 3 })
    newer = Coach.UpdateClearSample(newer, 35, {remaining=0,coherent_clear=true,idle_s=0})
    calibration, ok = Coach.AcceptClearSample(calibration, newer, 35)
    check("second clear is accepted", ok == true)
    check("recent sample pulls learned time toward five seconds",
        calibration.large.seconds < 7 and calibration.large.seconds > 5)

    local blended = Coach.BlendedClearTime(calibration, "large", 10)
    check("learned time blends without fully replacing cold estimate",
        blended < 10 and blended > calibration.large.seconds)
    local cold_only = Coach.BlendedClearTime(calibration, "ancient", 12)
    check("unlearned category uses cold estimate", cold_only == 12)

    local reset = Coach.ResetMatch(calibration)
    check("match reset clears learned categories", next(reset) == nil)
    check("reset returns a new table", reset ~= calibration)
end

local function opp(key, kind, x, value, clear_t, expires_at, confidence)
    return {
        key = key, kind = kind, region = kind == "wave" and "bot" or "jungle",
        category = kind == "wave" and "wave" or "large", count = 3, ehp = 900,
        pos = { x = x, y = 0 }, value = value, clear_t = clear_t,
        available_at = 100, expires_at = expires_at,
        source = confidence and "cached" or "live",
        confidence = confidence or 1, observed_at = 100, age_s = 0,
        partial = false,
    }
end

local function step_keys(plan)
    local out = {}
    for _, step in ipairs(plan and plan.steps or {}) do out[#out + 1] = step.key end
    return table.concat(out, ",")
end

print("two-horizon mixed route planning")
do
    check("next respawn boundary advances from mid-minute",
        Coach.NextRespawnBoundary(125) == 180)
    check("exact respawn boundary advances to following minute",
        Coach.NextRespawnBoundary(180) == 240)
    check("planning horizon rolls past an imminent respawn boundary",
        Coach.PlanningBoundary(294, 25) == 360)
    check("planning horizon keeps a sufficiently distant next boundary",
        Coach.PlanningBoundary(125, 25) == 180)

    local hero = { pos = { x = 0, y = 0 }, move_speed = 300 }
    local opportunities = {
        opp("bottom-wave", "wave", 300, 180, 5, 111),
        opp("large", "camp", 600, 120, 6),
        opp("ancient", "camp", 900, 170, 8),
        opp("far-rich", "camp", 1800, 220, 9),
    }
    local plan = Coach.Plan(opportunities, hero, { now = 100, boundary = 120 }, {
        max_steps = 3, immediate_leg_cap_s = 12, end_setup_radius = 700,
        stability_margin = 0,
    })
    check("mixed route catches expiring wave first",
        plan and plan.steps[1].key == "bottom-wave", step_keys(plan))
    check("mixed route contains lane and jungle steps",
        plan and plan.steps[1].kind == "wave" and plan.steps[2]
        and plan.steps[2].kind == "camp", step_keys(plan))
    check("route gold is accumulated", plan and plan.gold >= 300)
    check("route components sum to total time",
        plan and approx(plan.total_t, plan.travel_t + plan.clear_t + plan.wait_t))
    check("expiring wave produces teaching reason",
        plan and plan.reason_code == "EXPIRING_VALUE", plan and plan.reason_code)
    check("winner exposes runner-up delta", plan and type(plan.reason_delta) == "number")
    check("chosen steps retain source category for learning",
        plan and plan.steps[2] and plan.steps[2].category == "large",
        plan and plan.steps[2] and tostring(plan.steps[2].category))
    check("chosen steps retain observed creep count",
        plan and plan.steps[2] and plan.steps[2].count == 3)

    local decaying_wave = Coach.Plan({
        opp("travel-wave", "wave", 1500, 300, 2, 130),
    }, hero, {now=100,boundary=140}, {
        max_steps=1, immediate_leg_cap_s=10, stability_margin=0,
    })
    check("wave gold decays during travel before arrival",
        decaying_wave and approx(decaying_wave.gold, 250),
        decaying_wave and decaying_wave.gold)
    check("displayed wave step uses arrival-time remaining gold",
        decaying_wave and decaying_wave.steps[1]
        and approx(decaying_wave.steps[1].value, 250),
        decaying_wave and decaying_wave.steps[1] and decaying_wave.steps[1].value)

    local path_aware = Coach.Plan({
        opp("blocked-rich", "camp", 300, 180, 3),
        opp("walkable-near", "camp", 600, 120, 3),
    }, hero, {now=100,boundary=120}, {
        max_steps=1, immediate_leg_cap_s=15, travel_cost_per_s=8,
        stability_margin=0,
        distance_fn=function(_, target)
            return target.x == 300 and 3000 or 600
        end,
    })
    check("walkable path distance can reject a misleading straight-line target",
        path_aware and path_aware.steps[1].key == "walkable-near",
        step_keys(path_aware))

    local alternate_continuation = Coach.Plan({
        opp("best-first", "camp", 300, 200, 1),
        opp("blocked-second", "camp", 600, 190, 1),
        opp("walkable-second", "camp", 300, 100, 1),
    }, hero, {now=100,boundary=120}, {
        max_steps=2, immediate_leg_cap_s=12, travel_cost_per_s=0,
        stability_margin=0,
        distance_fn=function(from, target)
            if from.x == 300 and from.y == 0 and target.x == 600 and target.y == 0 then
                return 6000
            end
            if from.x == 600 and from.y == 0 and target.x == 300 and target.y == 0 then
                return 6000
            end
            local dx, dy = target.x - from.x, target.y - from.y
            return math.sqrt(dx * dx + dy * dy)
        end,
    })
    check("path-aware candidate generation keeps the best first camp with a valid continuation",
        alternate_continuation and step_keys(alternate_continuation) == "best-first,walkable-second",
        step_keys(alternate_continuation))

    local tempo_route = Coach.Plan({
        opp("near-small-a", "camp", 300, 100, 5),
        opp("near-small-b", "camp", 600, 100, 5),
        opp("far-rich-a", "camp", 2400, 150, 5),
        opp("far-rich-b", "camp", 2700, 150, 5),
    }, hero, {now=100,boundary=160}, {
        max_steps=2, immediate_leg_cap_s=15, travel_cost_per_s=8,
        stability_margin=0,
    })
    check("faster nearby chain beats slow raw-gold detour at fixed route depth",
        tempo_route and tempo_route.steps[1].key == "near-small-a",
        step_keys(tempo_route))

    local west = opp("west-camp", "camp", -3000, 140, 5)
    local east = opp("east-camp", "camp", 3000, 140, 5)
    local split_map = Coach.Plan({west,east}, hero, {now=100,boundary=160}, {
        max_steps=2, immediate_leg_cap_s=12, travel_cost_per_s=0,
        stability_margin=1,
    }, {steps={west,east}})
    check("every route leg respects the maximum travel limit",
        split_map and #split_map.steps == 1, step_keys(split_map))

    local safe_a = opp("safe-a", "camp", 300, 100, 5)
    local safe_b = opp("safe-b", "camp", 600, 100, 5)
    local risky_a = opp("risky-a", "camp", 900, 110, 5)
    local risky_b = opp("risky-b", "camp", 1200, 110, 5)
    safe_a.risk, safe_b.risk = 0.1, 0.1
    risky_a.risk, risky_b.risk = 0.8, 0.8
    local structural = Coach.Plan({safe_a,safe_b,risky_a,risky_b}, hero,
        {now=100,boundary=160}, {
            max_steps=2, immediate_leg_cap_s=12, travel_cost_per_s=0,
            risk_gold=100, stability_margin=0,
            distance_fn=function() return 300 end,
        })
    check("structural risk can outweigh a small enemy-side gold advantage",
        structural and structural.steps[1].key:find("safe",1,true) == 1,
        step_keys(structural))

    local active_camp = opp("active-camp", "camp", 300, 120, 6)
    local follow_camp = opp("follow-camp", "camp", 600, 100, 5)
    local active_plan = Coach.Plan({active_camp,follow_camp}, hero,
        {now=100,boundary=160}, {
            max_steps=2, immediate_leg_cap_s=12, stability_margin=0,
        })
    local locked_plan = Coach.Plan({
        active_camp, follow_camp, opp("urgent-wave", "wave", 900, 400, 5, 125),
    }, hero, {now=101,boundary=161}, {
        max_steps=2, immediate_leg_cap_s=12, stability_margin=0,
        locked_first_key="active-camp",
    }, active_plan)
    check("active camp clear stays first when an urgent wave appears",
        locked_plan and locked_plan.steps[1].key == "active-camp",
        step_keys(locked_plan))

    local distant_wave = {
        opp("unreachable-wave", "wave", 6000, 400, 5, 110),
        opp("near-a", "camp", 300, 100, 5),
        opp("near-b", "camp", 600, 100, 5),
    }
    local near_plan = Coach.Plan(distant_wave, hero, {now=100,boundary=120}, {
        max_steps=2, immediate_leg_cap_s=12, end_setup_radius=500,
    })
    check("distant expiring promise cannot hide poor first step",
        near_plan and near_plan.steps[1].kind == "camp", step_keys(near_plan))

    local travel_aware = Coach.Plan({
        opp("far-wave", "wave", 3000, 200, 5, 135),
        opp("near-camp-a", "camp", 300, 110, 5),
        opp("near-camp-b", "camp", 600, 110, 5),
    }, hero, {now=100,boundary=140}, {
        max_steps=2, immediate_leg_cap_s=15, travel_cost_per_s=8,
        stability_margin=0,
    })
    check("dead-travel cost can beat a higher-gold distant lane wave",
        travel_aware and travel_aware.steps[1].kind == "camp", step_keys(travel_aware))
    check("travel-aware plan exposes net route value",
        travel_aware and type(travel_aware.net_value) == "number"
        and travel_aware.net_value < travel_aware.gold)

    local expired = {
        opp("expired", "wave", 300, 500, 2, 100),
        opp("camp-a", "camp", 300, 90, 4),
        opp("camp-b", "camp", 600, 90, 4),
    }
    local expired_plan = Coach.Plan(expired, hero, {now=100,boundary=120}, {max_steps=2})
    check("already expired wave is never collected",
        expired_plan and not step_keys(expired_plan):find("expired"), step_keys(expired_plan))
end

print("route confidence and stability")
do
    local hero = { pos = { x = 0, y = 0 }, move_speed = 300 }
    local equal = {
        opp("live-a", "camp", 300, 100, 5, nil, 1),
        opp("live-b", "camp", 600, 100, 5, nil, 1),
        opp("cached-a", "camp", 300, 100, 5, nil, 0.4),
        opp("cached-b", "camp", 600, 100, 5, nil, 0.4),
    }
    local certain = Coach.Plan(equal, hero, {now=100,boundary=120}, {max_steps=2})
    check("equal routes prefer higher confidence",
        certain and step_keys(certain) == "live-a,live-b", step_keys(certain))

    local previous = Coach.Plan({
        opp("old-a", "camp", 300, 100, 5), opp("old-b", "camp", 600, 100, 5),
    }, hero, {now=100,boundary=120}, {max_steps=2})
    local changed = {
        opp("old-a", "camp", 300, 100, 5), opp("old-b", "camp", 600, 100, 5),
        opp("new-a", "camp", 300, 101, 5), opp("new-b", "camp", 600, 101, 5),
    }
    local stable = Coach.Plan(changed, hero, {now=100,boundary=120}, {
        max_steps=2, stability_margin=0.03,
    }, previous)
    check("tiny improvement preserves valid previous route",
        stable and step_keys(stable) == step_keys(previous), step_keys(stable))

    local capped_stable = Coach.Plan(changed, hero, {now=100,boundary=120}, {
        max_steps=2, pool_cap=2, stability_margin=0.03,
    }, previous)
    check("candidate cap retains a still-valid displayed route for stability",
        capped_stable and step_keys(capped_stable) == step_keys(previous),
        step_keys(capped_stable))

    local invalidated = Coach.Plan({
        opp("old-b", "camp", 600, 100, 5),
        opp("new-a", "camp", 300, 101, 5),
        opp("new-b", "camp", 600, 101, 5),
    }, hero, {now=100,boundary=120}, {
        max_steps=2, stability_margin=0.50,
    }, previous)
    check("missing first target invalidates stable route",
        invalidated and invalidated.steps[1].key ~= "old-a", step_keys(invalidated))
end

print(string.format("RESULT pass=%d fail=%d", pass, fail))
if fail > 0 then os.exit(1) end
