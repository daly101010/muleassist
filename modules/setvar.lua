-- modules/setvar.lua: the macro's two generic setting binds, Bind_ChangeVarInt and Bind_ToggleVariable.
--   /changevarint <Section> <Name> <Value> [extra]       set a number setting, live and in the INI
--   /togglevariable <Name> [on|off|0|1|<name>] [<name>]   flip an on/off setting for this session
--   /togglevariable conditions [all|dps|heals|burn|buffs|gom] [on|off]
-- MacroQuest.ini [Aliases] route most per-setting commands onto these (/chaseon=/changevarint General
-- ChaseAssist 1, /camphere=/togglevariable ReturnToCamp) and MQ expands an alias before any bind sees it,
-- so without these binds the bot's own /chaseon, /camphere ... never run on an aliased box.
--
-- Generic, not one case per alias: a name resolves to every module whose Settings schema declares it
-- (plus the cast engine and the few keys loaded outside a schema). When a module already has a dedicated
-- bind for the setting (ChaseAssist -> /chase, ReturnToCamp -> /camphere, BuffsOn -> /buffson ...) the
-- change goes through that bind so its side effects run; otherwise the value is set in the module's cfg
-- and its State mirror. Either way every other module holding a copy of the key is synced.
-- /changevarint persists the value to the setting's own section (the macro's /ini write);
-- /togglevariable is session-only (the macro's /varset) unless the dedicated bind persists itself.
-- Macro guards kept: unknown names and the internal combat-state names are refused, togglevariable only
-- flips on/off (number) settings.
local mq = require('mq')
local Config = require('core.config')
local Log = require('core.log')
local State = require('core.state')
local Modules = require('core.modules')

local M = { name = 'setvar' }

local function lower(s) return tostring(s or ''):lower() end

-- the macro's refuse list: internal combat state, never remote-settable
local INTERNAL = { combatstart = true, iamdead = true, mytargetid = true, aggrotargetid2 = true, pulled = true,
    bindactive = true, castresult = true, mainassistid = true }
-- /pethold names PetHold, the ghold/hold command word; the on/off switch is PetHoldOn (macro rename)
local RENAME = { pethold = 'PetHoldOn' }

-- keys a module loads outside its Settings schema
local EXTRA = {
    buffs = { { section = 'Buffs', key = 'BuffsCOn', type = 'int' } },
    rez = { { section = 'Heals', key = 'AutoRezOn', type = 'int' } },
}

-- settings with a dedicated bind: the change goes through it (cfgKey: where the bind keeps the value)
local ROUTES = {
    chaseassist = { mod = 'movement', bind = '/chase' },
    returntocamp = { mod = 'movement', bind = '/camphere' },
    chasedistance = { mod = 'movement', bind = '/chasedistance' },
    campradius = { mod = 'movement', bind = '/campradius' },
    buffson = { mod = 'buffs', bind = '/buffson' },
    xtarbuff = { mod = 'buffs', bind = '/xtarbuff' },
    dannetbuff = { mod = 'buffs', bind = '/dannetbuff' },
    rebuffon = { mod = 'buffs', bind = '/rebuffon' },
    buffwhilechasing = { mod = 'buffs', bind = '/buffwhilechase' },
    assistat = { mod = 'combat', bind = '/assistat' },
    meleedistance = { mod = 'combat', bind = '/meleedistance' },
    meleeon = { mod = 'combat', bind = '/meleeon' },
    autofireon = { mod = 'combat', bind = '/autofireon' },
    cureson = { mod = 'cures', bind = '/cureson' },
    dpson = { mod = 'dps', bind = '/dpson' },
    dpsinterval = { mod = 'dps', bind = '/dpsinterval' },
    dpsskip = { mod = 'dps', bind = '/dpsskip' },
    aeon = { mod = 'dps', bind = '/aeon' },
    healbrainon = { mod = 'healagent', bind = '/healbrainon' },
    healson = { mod = 'heals', bind = '/healson' },
    smarthealson = { mod = 'heals', bind = '/smarthealson' },
    medstart = { mod = 'med', bind = '/medstart' },
    waitformedders = { mod = 'med', bind = '/waitformedders' },
    waitformeddersmax = { mod = 'med', bind = '/waitformeddersmax' },
    waitformeddersskipma = { mod = 'med', bind = '/waitformeddersskipma' },
    pullernoselfmed = { mod = 'med', bind = '/pullernoselfmed' },
    groupwatchresume = { mod = 'med', bind = '/groupwatchresume' },
    mezon = { mod = 'mez', bind = '/mezon' },
    killordermaxdist = { mod = 'modes', bind = '/killordermaxdist' },
    peton = { mod = 'pet', bind = '/peton' },
    petholdon = { mod = 'pet', bind = '/pethold' },
    movewhenhit = { mod = 'pet', bind = '/movewhenhit' },
    maxradius = { mod = 'pull', bind = '/maxradius' },
    maxzrange = { mod = 'pull', bind = '/maxzrange' },
    autorezon = { mod = 'rez', bind = '/autorezon' },
}

-- State mirrors for the generic path (a routed bind sets its own)
local function flag(v) return (tonumber(v) or 0) ~= 0 end
local MIRRORS = {
    buffson = function(v) State.buffsOn = flag(v) end,
    meleeon = function(v) State.meleeOn = flag(v) end,
    dpson = function(v) State.dpsOn = flag(v) end,
    assistat = function(v) State.assistAt = tonumber(v) or State.assistAt end,
    cureson = function(v) State.curesOn = flag(v) end,
    aeon = function(v) State.aeOn = flag(v) end,
    healson = function(v) State.healsOn = flag(v) end,
    smarthealson = function(v) State.smartHealsOn = flag(v) end,
    healbrainon = function(v) State.healBrainOn = flag(v) end,
    mezon = function(v) State.mezOn = flag(v) end,
    ohshiton = function(v) State.ohShitOn = flag(v) end,
    peton = function(v) State.petOn = flag(v) end,
    autorezon = function(v) State.autoRezOn = flag(v) end,
    chainpull = function(v) State.chainPull = tonumber(v) or 0 end,
    xtartanks = function(v) State.xtarTanks = flag(v) end,
    chasedistance = function(v) State.chaseDistance = tonumber(v) or State.chaseDistance end,
    campradius = function(v) State.campRadius = tonumber(v) or State.campRadius end,
}

-- the conditions command word: [General] <x>COn flags
local CFLAGS = { gom = 'GoMCOn', dps = 'DPSCOn', heals = 'HealsCOn', burn = 'BurnCOn', buffs = 'BuffsCOn' }
local CFLAG_ORDER = { 'gom', 'dps', 'heals', 'burn', 'buffs' }

local function onOff(s)
    local l = lower(s)
    if l == '1' or l == 'on' or l == 'true' then return 1 end
    if l == '0' or l == 'off' or l == 'false' then return 0 end
    return nil
end

--- Every declaration of a setting: { { mod = <module table>, spec = { section, key, type } }, ... }
function M.decls(name)
    local lk, out = lower(name), {}
    local function scan(mod, specs)
        for _, s in ipairs(specs or {}) do
            if lower(s.key) == lk then out[#out + 1] = { mod = mod, spec = s } end
        end
    end
    local Cast = package.loaded['core.cast']
    if Cast and Cast.Settings and type(Cast.cfg) == 'table' then scan({ name = 'cast', cfg = Cast.cfg }, Cast.Settings.scalars) end
    for _, mod in ipairs(Modules.list) do
        scan(mod, mod.Settings and mod.Settings.scalars)
        scan(mod, EXTRA[mod.name])
    end
    return out
end

local function isNumberType(t) return t == 'int' or t == 'float' or t == 'bool' end

--- Set a value in every module holding the key (the cfg each module reads live).
local function syncAll(decls, value)
    for _, d in ipairs(decls) do
        if type(d.mod.cfg) == 'table' then d.mod.cfg[d.spec.key] = value end
    end
end

--- A 0/1 switch: a bool, or an int whose default and current value are both 0 or 1 (MeleeOn, AggroOn ...).
local function isFlag(spec, cur)
    if spec.type == 'bool' then return true end
    if spec.type ~= 'int' then return false end
    local d, c = tonumber(spec.default), tonumber(cur)
    return (d == 0 or d == 1) and (c == nil or c == 0 or c == 1)
end

--- A /changevarint value for a number setting: a number, or on/off/true/false for a 0/1 flag only.
local function coerce(spec, value, cur)
    local n = tonumber(value)
    if n == nil and isFlag(spec, cur) then n = onOff(value) end
    if n == nil then return nil end
    if spec.type == 'int' or spec.type == 'bool' then n = math.floor(n) end
    return n
end

local function routedModule(lk)
    local r = ROUTES[lk]
    if not r then return nil end
    local mod = Modules.get(r.mod)
    if mod and mod.Binds and type(mod.Binds[r.bind]) == 'function' then return mod, r end
    return nil
end

--- The value a key holds now (the routed module's cfg first, then any declaring module's).
local function current(lk, decls)
    local mod = routedModule(lk)
    for _, d in ipairs(decls) do
        if mod and d.mod == mod and type(mod.cfg) == 'table' and mod.cfg[d.spec.key] ~= nil then return mod.cfg[d.spec.key] end
    end
    for _, d in ipairs(decls) do
        if type(d.mod.cfg) == 'table' and d.mod.cfg[d.spec.key] ~= nil then return d.mod.cfg[d.spec.key] end
    end
    return nil
end

-- side effects of the macro's subs that have a port equivalent and that the routed bind does not do
local function after(lk, value)
    if lk == 'meleeon' and flag(value) then mq.cmd('/assist on') end
    if lk == 'maxradius' and tonumber(value) then
        local mv = Modules.get('movement')
        if mv and type(mv.cfg) == 'table' then mv.cfg.CampRadiusExceed = tonumber(value) + 200 end
    end
end

--- Apply a value: through the dedicated bind when there is one, else into cfg + State. Returns the value
--- the setting holds afterwards (the bind may refuse or adjust).
local function apply(lk, decls, value, bindArg)
    local mod, r = routedModule(lk)
    if mod then
        mod.Binds[r.bind](mod, bindArg)
        local v = current(lk, decls)
        if v == nil then v = value end
        syncAll(decls, v)
        after(lk, v)
        return v
    end
    syncAll(decls, value)
    if MIRRORS[lk] then MIRRORS[lk](value) end
    after(lk, value)
    return value
end

local function resolve(name, who)
    if RENAME[lower(name)] then name = RENAME[lower(name)] end
    local lk = lower(name)
    if INTERNAL[lk] then
        Log.info('%s: %s is internal combat state - refusing.', who, name)
        return nil
    end
    local decls = M.decls(name)
    if #decls == 0 then
        Log.info('%s: unknown variable %s - ignoring (not a setting of the Lua bot).', who, name)
        return nil
    end
    return decls[1].spec.key, lk, decls
end

local function pickSpec(decls, section)
    for _, d in ipairs(decls) do if lower(d.spec.section) == lower(section) then return d.spec end end
    return decls[1].spec
end

-- ------------------------------------------------------------- /changevarint
function M.changeVarInt(section, name, value, extra)
    section, name = tostring(section or ''), tostring(name or '')
    if section == '' or name == '' then
        Log.info('/changevarint <Section> <Name> <Value> [chase name]')
        return
    end
    local key, lk, decls = resolve(name, 'ChangeVarInt')
    if not key then return end
    local spec = pickSpec(decls, section)
    if value == nil or tostring(value) == '' then
        Log.info('ChangeVarInt: %s is %s - /changevarint %s %s <value>', key, tostring(current(lk, decls)), spec.section, key)
        return
    end
    value = tostring(value)
    if lk == 'chaseassist' then
        local mv = Modules.get('movement')
        if not mv then Log.info('ChangeVarInt: no movement module - ChaseAssist unchanged') return end
        local v = onOff(value) or tonumber(value)
        local chaseName = extra
        if v == nil then v, chaseName = 1, value end   -- /changevarint General ChaseAssist Bob
        Log.info('Changing %s to %s', key, v ~= 0 and 1 or 0)
        if v ~= 0 and chaseName and chaseName ~= '' then mv.Binds['/chaseon'](mv, chaseName)
        else mv.Binds['/chase'](mv, v ~= 0 and 'on' or 'off') end
        local now = current(lk, decls)
        syncAll(decls, now)
        Config.set(spec.section, key, now)
        return
    end
    if not isNumberType(spec.type) then
        -- writing the INI alone would leave the live value (State.mainAssist ...) unchanged: refuse
        Log.info('ChangeVarInt: %s is not a number setting - use its own command or edit the INI and /muleassist reload.', key)
        return
    end
    local v = coerce(spec, value, current(lk, decls))
    if v == nil then
        Log.info('ChangeVarInt: %s takes a number - "%s" ignored.', key, value)
        return
    end
    if lower(section) ~= lower(spec.section) then Log.info('ChangeVarInt: %s lives in [%s] - writing it there', key, spec.section) end
    Log.info('Changing %s to %s', key, tostring(v))
    local now = apply(lk, decls, v, tostring(v))
    Config.set(spec.section, key, now)
end

-- ------------------------------------------------------------- /togglevariable conditions ...
local function conditions(c2, c3)
    local l2 = lower(c2)
    local function setFlag(word, v)
        local decls = M.decls(CFLAGS[word])
        syncAll(decls, v)
    end
    if l2 == 'all' then
        local v = onOff(c3) == 1 and 1 or 0
        for _, word in ipairs(CFLAG_ORDER) do setFlag(word, v) end
        Log.info('>> Setting: (conditions) all to (%s)', v == 1 and 'On' or 'Off')
    elseif CFLAGS[l2] then
        local v = onOff(c3) == 1 and 1 or 0
        setFlag(l2, v)
        Log.info('>> Setting: (conditions) %s to (%d)', l2, v)
    elseif onOff(c2) ~= nil then
        -- the macro sets ConditionsOn 2 for both: conditions stay read; the per-list switches are the toggle
        Log.info('>> conditions stay on (ConditionsOn 2, as the macro) - /conditions all|dps|heals|burn|buffs|gom on|off')
    else
        Log.info('/togglevariable conditions all|dps|heals|burn|buffs|gom on|off')
    end
end

-- ------------------------------------------------------------- /togglevariable
function M.toggleVariable(name, c2, c3)
    name, c2, c3 = tostring(name or ''), tostring(c2 or ''), tostring(c3 or '')
    if name == '' then
        Log.info('/togglevariable <Name> [on|off|0|1]')
        return
    end
    if lower(name) == 'conditions' then conditions(c2, c3) return end
    local key, lk, decls = resolve(name, 'ToggleVariable')
    if not key then return end
    if not isNumberType(decls[1].spec.type) then
        Log.info('ToggleVariable: %s is not an on/off setting - ignoring.', key)
        return
    end
    local want = onOff(c2)
    if lk == 'chaseassist' then
        local mv = Modules.get('movement')
        if not mv then Log.info('ToggleVariable: no movement module - ChaseAssist unchanged') return end
        local chaseName = (want == nil and c2 ~= '') and c2 or (c3 ~= '' and c3 or nil)
        if want ~= 0 and chaseName then mv.Binds['/chaseon'](mv, chaseName)
        elseif want == nil then mv.Binds['/chase'](mv, '')
        else mv.Binds['/chase'](mv, want == 1 and 'on' or 'off') end
        syncAll(decls, current(lk, decls))
        return
    end
    if c2 ~= '' and want == nil then
        Log.info('ToggleVariable: %s takes on|off|1|0 - "%s" ignored.', key, c2)
        return
    end
    if routedModule(lk) then
        apply(lk, decls, want, want ~= nil and tostring(want) or '')   -- the bind reports the new value
        return
    end
    if want == nil then want = flag(current(lk, decls)) and 0 or 1 end
    local v = apply(lk, decls, want)
    Log.info('>> Setting: (%s) to (%s)', key, flag(v) and 'On' or 'Off')
end

M.Binds = {
    ['/changevarint'] = function(self, section, name, value, extra) M.changeVarInt(section, name, value, extra) end,
    ['/togglevariable'] = function(self, name, c2, c3) M.toggleVariable(name, c2, c3) end,
}

return M
