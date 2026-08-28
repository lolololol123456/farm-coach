#!/usr/bin/env lua
package.path = "./?.lua;../?.lua;" .. package.path

local Lane = require("lib.lane")
local StandaloneRoute = require("lib.route")

local pass, fail = 0, 0
local function check(name, condition, detail)
    if condition then
        pass = pass + 1
        print("  [PASS] " .. name)
    else
        fail = fail + 1
        print("  [FAIL] " .. name .. (detail and (" -- " .. detail) or ""))
    end
end

local hero = { move_speed = 300, anchors = {}, tp = nil }
local from = { x = 0, y = 0 }
local target = { pos = { x = 900, y = 0 } }

for name, planner in pairs({embedded=Lane.Route, standalone=StandaloneRoute}) do
    local path_calls = 0
    local seconds = planner._leg_time(from, target, hero, {
        distance_fn = function(a, b)
            path_calls = path_calls + 1
            check(name .. " receives the real leg endpoints",
                a.x == 0 and a.y == 0 and b.x == 900 and b.y == 0)
            return 1800
        end,
    })
    check(name .. " planner uses supplied walking distance", math.abs(seconds - 6) < 1e-6,
        tostring(seconds))
    check(name .. " planner calls the supplied distance function", path_calls == 1,
        tostring(path_calls))

    local decay_hero = { pos = { x = 0, y = 0 }, move_speed = 300, anchors = {} }
    local first = { pos = { x = 0, y = 0 }, value = 100, clear_t = 0 }
    local wave = {
        pos = { x = 900, y = 0 },
        value = 100,
        clear_t = 0,
        born = 0,
        decay_per_s = 10,
        value_floor = 0,
    }
    local score = planner._score({ first, wave }, decay_hero, {
        now = 0,
        horizon_s = 30,
        step_decay = 0.5,
    })
    check(name .. " step score uses the wave value remaining at arrival",
        math.abs(score.gold - 170) < 1e-6 and math.abs(score.score - 135) < 1e-6,
        string.format("gold=%.2f score=%.2f", score.gold, score.score))
end

print(string.format("RESULT pass=%d fail=%d", pass, fail))
if fail > 0 then os.exit(1) end
