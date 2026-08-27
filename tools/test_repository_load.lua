#!/usr/bin/env lua
package.path = "./?.lua;../?.lua;" .. package.path

Color = function(r, g, b, a) return {r=r, g=g, b=b, a=a} end
Logger = function()
    return {error=function() end, info=function() end, debug=function() end}
end

local widget = {Get=function() return nil end}
local group = {
    Switch=function() return widget end,
    Slider=function() return widget end,
}
Menu = {
    Find=function() return group end,
    Create=function() return group end,
}

local ok, loaded = pcall(dofile, "CarryFarmCoach.lua")
if not ok then
    io.stderr:write("repository load failed: " .. tostring(loaded) .. "\n")
    os.exit(1)
end
if type(loaded) ~= "table" or type(loaded.OnUpdateEx) ~= "function"
    or type(loaded.OnDraw) ~= "function" then
    io.stderr:write("repository load returned an invalid callback table\n")
    os.exit(1)
end

print("REPOSITORY LOAD PASS")
