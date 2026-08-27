#!/usr/bin/env lua
package.path = "./?.lua;../?.lua;" .. package.path

-- Reproduce a UCZone hot session holding the older lib.lane export shape:
-- InterceptETA exists, but the newer Lane.Route mount does not.
package.loaded["lib.carry_farm_coach"] = nil
package.loaded["lib.route"] = nil
package.loaded["lib.lane"] = {
    InterceptETA = function(from, _, move_speed, _, target)
        local dx, dy = target.x - from.x, target.y - from.y
        return { eta = math.sqrt(dx * dx + dy * dy) / move_speed }
    end,
}

local Coach = require("lib.carry_farm_coach")
local plan = Coach.Plan({{
    key="camp", kind="camp", category="large", region="jungle",
    pos={x=300,y=0}, value=100, clear_t=5, available_at=100,
    source="live", confidence=1, observed_at=100, count=3,
}}, {pos={x=0,y=0},move_speed=300}, {now=100,boundary=120}, {max_steps=2})

assert(plan and plan.steps[1] and plan.steps[1].key == "camp",
    "standalone lib.route fallback did not produce a route")
print("COMPAT PASS old Lane without Route")
