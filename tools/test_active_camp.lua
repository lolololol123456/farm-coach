#!/usr/bin/env lua
package.path = "./?.lua;../?.lua;" .. package.path

local Farm = require("lib.farm")
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

if type(Farm.UpdateActiveCamp) ~= "function" then
    check("farm library exposes active-camp detection", false, "UpdateActiveCamp missing")
    print(string.format("RESULT pass=%d fail=%d", pass, fail))
    os.exit(1)
end

local function camp(ehp, count, live)
    return {{key="near", pos={x=100,y=0}, ehp=ehp, count=count, live=live ~= false}}
end

local function tick(state, t, samples, attacking, allies, hero_pos)
    return Farm.UpdateActiveCamp(samples, state, {
        now=t,
        hero_pos=hero_pos or {x=0,y=0},
        attacking=attacking == true,
        allies=allies or {},
    }, {
        start_radius=650,
        leave_radius=950,
        provisional_s=0.8,
        evidence_grace_s=2.25,
        attack_credit_s=1.0,
        ally_radius=750,
    })
end

do
    local state, key = tick(nil, 0, camp(1000, 3), true)
    check("attacking beside a live camp creates an immediate provisional lock",
        key == "near" and state and state.confirmed == false, tostring(key))
end

do
    local state, key = tick(nil, 0, camp(1000, 3), false)
    state, key = tick(state, 0.5, camp(900, 3), false)
    check("falling neutral hp confirms Luna is farming without an attack pulse",
        key == "near" and state and state.confirmed == true, tostring(key))
end

do
    local state, key = tick(nil, 0, camp(1000, 3), false)
    state, key = tick(state, 0.5, camp(1000, 3), false)
    check("walking beside an unchanged camp does not create a lock", key == nil, tostring(key))
end

do
    local ally = {{pos={x=120,y=0},value=1}}
    local state, key = tick(nil, 0, camp(1000, 3), false, ally)
    state, key = tick(state, 0.5, camp(800, 3), false, ally)
    check("a nearby teammate's damage is not credited to Luna", key == nil, tostring(key))
end

do
    local ally = {{pos={x=120,y=0},value=1}}
    local state, key = tick(nil, 0, camp(1000, 3), true, ally)
    state, key = tick(state, 0.5, camp(850, 3), false, ally)
    check("recent Luna attack evidence can confirm a shared camp",
        key == "near" and state and state.confirmed == true, tostring(key))
end

do
    local state, key = tick(nil, 0, camp(1000, 3), true)
    state, key = tick(state, 1.0, camp(1000, 3), false)
    check("an attack near a camp without neutral damage expires quickly", key == nil, tostring(key))
end

do
    local state, key = tick(nil, 0, camp(1000, 3), false)
    state, key = tick(state, 0.5, camp(850, 3), false)
    state, key = tick(state, 1.0, camp(0, 0, false), false)
    check("a visibly empty camp releases the active lock", key == nil, tostring(key))
end

do
    local state, key = tick(nil, 0, camp(1000, 3), false)
    state, key = tick(state, 0.5, camp(850, 3), false)
    state, key = tick(state, 1.0, camp(850, 3), false, {}, {x=2000,y=0})
    check("leaving the camp releases the active lock", key == nil, tostring(key))
end

print(string.format("RESULT pass=%d fail=%d", pass, fail))
if fail > 0 then os.exit(1) end
