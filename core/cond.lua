-- core/cond.lua: the one condition evaluator every module uses ([DPS] DPSCond, [Heals] HealsCond, ...).
-- Dual mode, as the old Lua bot's cond.lua:
--   * blank, TRUE or NULL passes; FALSE fails
--   * a string with ${ is a macro condition: expanded, NULL read as 0, then ${If[...,1,0]} == '1'
--   * anything else is a native Lua expression (mq.TLO.Me.PctMana() > 80), compiled once into a sandbox
--     with mq in scope and no os / io / load / require / dofile, and cached by string
-- A condition that fails to compile or errors at run time is false and is logged once, never every pass
-- (the macro calculator printed "Unparsable in Calculation" on every pass for the native ones).
local mq = require('mq')
local Log = require('core.log')

local M = {}

-- Sandbox for native conditions. mq and the string / math libs are full references, so mq.cmd stays
-- reachable: conditions come from the player's own INI, the same trust as the macro's ${If[]}.
local ENV = {
    mq = mq, math = math, string = string, table = { concat = table.concat },
    tonumber = tonumber, tostring = tostring, type = type, select = select,
    ipairs = ipairs, pairs = pairs, next = next, pcall = pcall,
}

local cache = {}     -- [string] = compiled function | false (failed to compile)
local logged = {}    -- [string] = true once its failure was logged

local function fail(s, what, err)
    if not logged[s] then
        logged[s] = true
        Log.warn('condition %s - treated as false (logged once): %s (%s)', what, s, tostring(err))
    end
    return false
end

local function native(s)
    local fn = cache[s]
    if fn == nil then
        local compiled, err = load('return (' .. s .. ')', '=cond', 't', ENV)
        if compiled and setfenv then setfenv(compiled, ENV) end   -- LuaJIT (MQ) honours env through setfenv too
        if not compiled then
            cache[s] = false
            return fail(s, 'does not compile', err)
        end
        cache[s] = compiled
        fn = compiled
    elseif fn == false then
        return false
    end
    local ok, res = pcall(fn)
    if not ok then return fail(s, 'errored', res) end
    if type(res) == 'number' then return res ~= 0 end   -- '0' / '1' mean what they meant to the macro
    return res ~= nil and res ~= false
end

--- The condition string passes? nil / blank / TRUE / NULL pass.
function M.ok(cond)
    if cond == nil then return true end
    local s = tostring(cond):match('^%s*(.-)%s*$')
    if s == '' then return true end
    local up = s:upper()
    if up == 'TRUE' or up == 'NULL' then return true end
    if up == 'FALSE' then return false end
    if s:find('${', 1, true) then
        -- expand first, then a NULL (no target, no such buff: ${Target.Named}, !${Me.Buff[x].ID}) counts as 0:
        -- handed to the calculator as is, it prints "Unparsable in Calculation: 'N'" on every evaluation
        local okP, expanded = pcall(mq.parse, s)
        if not okP or expanded == nil then return false end
        expanded = tostring(expanded):gsub('%f[%w]NULL%f[%W]', '0')
        local ok, v = pcall(mq.parse, '${If[' .. expanded .. ',1,0]}')
        return ok and v == '1'
    end
    return native(s)
end

--- Forget the compile cache and the logged set (tests; a settings reload keeps them: same strings).
function M.reset() cache, logged = {}, {} end

return M
