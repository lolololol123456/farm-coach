#!/usr/bin/env lua
package.path = "./?.lua;../?.lua;" .. package.path

local hero = {id=1,pos={x=0,y=0},team=2,name="npc_dota_hero_luna"}
local ally = {id=2,pos={x=120,y=0},team=2,name="npc_dota_hero_sven"}
local creep = {id=3,pos={x=100,y=0},team=4,hp=900}
local captured, planned, errors, debug_lines, menu_paths = nil, nil, {}, {}, {}

local Map = {
    Camps=function() return {{center={x=100,y=0,z=0},camp={},type=0}} end,
    AllNeutrals=function() return {creep} end,
    CampCreeps=function() return {creep} end,
    CampKey=function() return "near" end,
}
local MapData = {
    FOUNTAINS={{team=2,pos={0,0,0}},{team=3,pos={10000,10000,0}}},
    TOWERS={}, SPAWNS={},
}
local Farm = {
    GoldValue=function() return 55 end,
    EffectiveHP=function() return 900 end,
    StructuralRisk=function() return 0 end,
    UpdateActiveCamp=function(samples, state, ctx)
        captured={samples=samples,state=state,ctx=ctx}
        return {key="near",confirmed=false,samples={}}, "near", "attack"
    end,
}
local Lane = {
    BuildLanePaths=function() return {} end,
    ScanLanes=function() return {top={},mid={},bot={}} end,
    ExpectedWave=function() return {count=4} end,
}
local Coach = {
    CampScanState=function(_,live_count) return live_count > 0 and "live" or "scan" end,
    NearestCampKey=function() return "near" end,
    NewCalibration=function() return {} end,
    ResetMatch=function() return {} end,
    ColdClearEstimate=function() return 5 end,
    BlendedClearTime=function(_,_,v) return v end,
    NormalizeCamp=function(sample)
        return {key=sample.key,kind="camp",pos=sample.pos,value=sample.gold,ehp=sample.ehp,
            count=sample.count,clear_t=sample.clear_t,source=sample.source,confidence=1,risk=sample.risk,
            category=sample.category,available_at=100,observed_at=100}
    end,
    WaveTargetPosition=function() return nil end,
    PlanningBoundary=function() return 120 end,
    Plan=function(_,_,_,opts)
        planned=opts
        return {steps={{key="near",kind="camp",pos={x=100,y=0},value=55,clear_t=5,
            source="live",confidence=1,category="small",count=1}},gold=55,total_t=5,
            reason_code="ONLY_VALID_ROUTE"}
    end,
    BeginClearSample=function() return nil end,
}

package.loaded["lib.map"] = Map
package.loaded["lib.map_data"] = MapData
package.loaded["lib.farm"] = Farm
package.loaded["lib.lane"] = Lane
package.loaded["lib.draw"] = {}
package.preload["lib.carry_farm_coach"] = function() return Coach end

Color=function(r,g,b,a) return {r=r,g=g,b=b,a=a} end
Logger=function() return {
    error=function(_,message) errors[#errors+1]=message end,
    info=function() end,
    debug=function(_,message) debug_lines[#debug_lines+1]=message end,
} end
local widget={Get=function() return nil end}
local menu_calls = {}
local function menu_node(path, can_hold_options)
    return {
        Create=function(_, name)
            local child_path = path .. "/" .. name
            menu_calls[#menu_calls+1] = "group:" .. child_path
            return menu_node(child_path, name == "Settings")
        end,
        Switch=function(_,label)
            if not can_hold_options then error("option attached to non-group: " .. path) end
            menu_calls[#menu_calls+1] = "option:" .. path .. "/" .. label
        if label == "Diagnostics" then return {Get=function() return true end} end
        return widget
        end,
        Slider=function(_,label)
            if not can_hold_options then error("option attached to non-group: " .. path) end
            menu_calls[#menu_calls+1] = "option:" .. path .. "/" .. label
        if label == "Log detail" then return {Get=function() return 3 end} end
        return widget
        end,
    }
end
Menu={
    Find=function(...)
        menu_paths[#menu_paths+1] = table.concat({...}, "/")
        return nil
    end,
    Create=function(...)
        local path = table.concat({...}, "/")
        menu_paths[#menu_paths+1] = path
        return menu_node(path, false)
    end,
}
Engine={IsInGame=function() return true end}
GameRules={GetGameTime=function() return 100 end,GetGameStartTime=function() return 10 end}
Heroes={GetLocal=function() return hero end,GetAll=function() return {hero,ally} end}
Entity={
    IsAlive=function() return true end,
    IsDormant=function() return false end,
    GetAbsOrigin=function(unit) return unit.pos end,
    GetHealth=function(unit) return unit.hp or 1000 end,
    GetTeamNum=function(unit) return unit.team end,
    GetIndex=function(unit) return unit.id end,
}
NPC={
    GetUnitName=function(unit) return unit.name or "npc_dota_neutral_test" end,
    GetMoveSpeed=function() return 325 end,
    GetTrueDamage=function() return 100 end,
    GetTrueMaximumDamage=function() return 110 end,
    GetAttackTime=function() return 1.5 end,
    GetAttackRange=function() return 330 end,
    GetGoldBountyMax=function() return 55 end,
    IsAttacking=function(unit) return unit == hero end,
    IsIllusion=function() return false end,
}

local script = dofile("CarryFarmCoach.lua")
script.OnUpdateEx()

local saw_candidates = false
local saw_rejections, saw_plan_id, saw_paths, saw_camp_change = false, false, false, false
for _, line in ipairs(debug_lines) do
    if tostring(line):find("camp_candidates", 1, true) then saw_candidates = true end
    if tostring(line):find("candidate_rejections", 1, true) then saw_rejections = true end
    if tostring(line):find("plan_id=", 1, true) then saw_plan_id = true end
    if tostring(line):find("path_diagnostics", 1, true)
        and tostring(line):find("straight_fallback", 1, true) then saw_paths = true end
    if tostring(line):find("camp_state_change", 1, true)
        and tostring(line):find("cause=box_neutral", 1, true) then saw_camp_change = true end
end
local pass = captured and captured.ctx and captured.ctx.attacking == true
    and #captured.ctx.allies == 1 and captured.ctx.allies[1].pos.x == 120
    and planned and planned.locked_first_key == "near" and saw_candidates
    and saw_rejections and saw_plan_id and saw_paths and saw_camp_change and #errors == 0
    and menu_paths[1] == "Creeps/Main/Farm Coach"
    and menu_paths[2] == "Creeps/Main/Farm Coach"
    and menu_calls[1] == "group:Creeps/Main/Farm Coach/Coach"
    and menu_calls[2] == "group:Creeps/Main/Farm Coach/Coach/Settings"
    and menu_calls[3] == "group:Creeps/Main/Farm Coach/Visuals"
    and menu_calls[4] == "group:Creeps/Main/Farm Coach/Visuals/Settings"
    and menu_calls[5] == "group:Creeps/Main/Farm Coach/Diagnostics"
    and menu_calls[6] == "group:Creeps/Main/Farm Coach/Diagnostics/Settings"
if not pass then
    io.stderr:write(string.format("ACTIVE CAMP WIRING FAIL captured=%s allies=%s locked=%s errors=%d\n",
        tostring(captured ~= nil), tostring(captured and captured.ctx and #captured.ctx.allies),
        tostring(planned and planned.locked_first_key), #errors))
    os.exit(1)
end

print("ACTIVE CAMP WIRING PASS")
