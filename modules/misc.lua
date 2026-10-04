-- modules/misc.lua: the odds and ends of the main loop. DoMiscStuff (the trade accept, the target-of-target
-- window, the familiar, the stuck cursor), CheckCursor, zombie mode, /groupcheck, the spell-set binds
-- (/writespells /memmyspells, [SpellSet] LoadSpellSet), /iniwrite, the custom hook (/customcall and an
-- optional custom.lua beside this script), the OnStart commands and the small events (joined the party,
-- camping, task updates, AA / level gains, invis fading, locked doors, full bags).
local mq = require('mq')
local T = require('core.tlo')
local Config = require('core.config')
local Timers = require('core.timers')
local Comms = require('core.comms')
local Log = require('core.log')
local State = require('core.state')
local Ini = require('core.ini')

local M = { name = 'misc' }

M.Settings = {
    scalars = {
        { section = 'General', key = 'HoTTOn', type = 'int', default = 0 },
        { section = 'General', key = 'OnStart', type = 'string', default = 'NULL', rank = false },
        { section = 'SpellSet', key = 'LoadSpellSet', type = 'int', default = 0 },
        { section = 'SpellSet', key = 'SpellSetName', type = 'string', default = 'MuleAssist', rank = false },
    },
}
M.cfg = {}
M.custom = nil          -- the optional custom.lua module: { call = function(name, param) end, tick = function() end }
M.pendingCustom = nil

local function lower(s) return tostring(s or ''):lower() end

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
end

-- ------------------------------------------------------------- DoMiscStuff
function M:miscStuff()
    if State.chainPull == 0 and (State.combatStart or T.aggroTargetId() > 0) then return end
    -- a trade from my group or raid is accepted
    local tw = mq.TLO.Window('TradeWnd')
    if T.bool(function() return tw.Open() end) and T.bool(function() return tw.HisTradeReady() end) and T.num(function() return mq.TLO.Cursor.ID() end) == 0 then
        local partner = T.str(function() return tw.Child('TRDW_OtherName').Text() end)
        if partner == '' then partner = T.str(function() return mq.TLO.Target.CleanName() end) end
        if T.num(function() return mq.TLO.Group.Member(partner).ID() end) > 0 or T.num(function() return mq.TLO.Raid.Member(partner).Level() end) > 0 then
            mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
        elseif Timers.expired('misc:tradewarn') then
            Timers.set('misc:tradewarn', 10000)
            Log.info('Not auto-accepting a trade from %s - not in my group or raid.', partner)
        end
    end
    if (self.cfg.HoTTOn or 0) ~= 0 and not T.bool(function() return mq.TLO.Window('TargetOfTargetWindow').Open() end) then mq.cmd('/windowstate TargetOfTargetWindow open') end
    if T.myClass() == 'WIZ' and T.str(function() return mq.TLO.Me.Pet.CleanName() end) == T.myName() .. '`s familiar' then mq.cmd('/pet get lost') end
    if T.num(function() return mq.TLO.Cursor.ID() end) > 0 and Timers.expired('misc:cursor') then
        Timers.set('misc:cursor', 20000)
        if T.num(function() return mq.TLO.Me.FreeInventory() end) > 0 then
            Log.info('%s is stuck on my cursor. Dropping it into inventory in 15s.', T.str(function() return mq.TLO.Cursor.Name() end))
            mq.cmd('/timed 150 /autoinventory')
        else
            Comms.say('t', 'HEY YOUR INVENTORY IS FULL!')
        end
    end
end

--- CheckCursor: put a cursor item away (up to 10 tries); a NoDrop item with no bag space stays.
function M.checkCursor()
    for _ = 1, 10 do
        if T.num(function() return mq.TLO.Cursor.ID() end) == 0 then return end
        if T.num(function() return mq.TLO.Me.FreeInventory() end) == 0 then
            if T.bool(function() return mq.TLO.Cursor.NoDrop() end) then Comms.say('r', 'NoDrop item on my cursor and no bag space - leaving it on the cursor.') return end
            Comms.say('r', 'I have an item and no where to put it! I need help!')
        else
            mq.cmd('/autoinventory')
        end
        mq.delay(2000, function() return T.num(function() return mq.TLO.Cursor.ID() end) == 0 end)
    end
end

-- ------------------------------------------------------------- spell sets
function M:memMySpells(arg)
    local server = T.str(function() return mq.TLO.EverQuest.Server() end)
    local name = (arg and arg ~= '' and not arg:lower():find('%.ini$')) and arg or T.myName()
    local file = (arg and arg:lower():find('%.ini$')) and arg or nil
    if not file then
        local level = T.num(function() return mq.TLO.Me.Level() end)
        for _, f in ipairs({ string.format('MuleAssist_%s_%s_%d.ini', server, name, level), string.format('MuleAssist_%s_%s.ini', server, name), string.format('MuleAssist_%s.ini', name) }) do
            if Ini.read(f, 'General', 'MuleAssistVer') then file = f break end
        end
    end
    if not file or not Ini.read(file, 'General', 'MuleAssistVer') then Log.info('Invalid INI file: %s for memorizing spells. Returning.', tostring(file)) return end
    if not Ini.read(file, 'MySpells', 'Gem1') then Log.info('No Spells found in INI file: %s. Use /writespells and try again. Returning.', file) return end
    for gem = 1, 13 do
        local raw = Ini.read(file, 'MySpells', 'Gem' .. gem)
        if raw and raw ~= '' and raw:upper() ~= 'NULL' then
            local base = raw:gsub(' Rk%..*$', '')
            local spell = T.str(function() return mq.TLO.Spell(base).RankName() end)
            if spell == '' then spell = base end
            if T.num(function() return mq.TLO.Me.Book(spell)() end) == 0 then Log.warn('Could Not find the spell %s in your spell book.', spell)
            elseif T.str(function() return mq.TLO.Me.Gem(gem).Name() end) ~= spell then
                local other = T.num(function() return mq.TLO.Me.Gem(spell)() end)
                if other > 0 then mq.cmdf('/notify CastSpellWnd CSPW_Spell%d rightmouseup', other - 1) mq.delay(2000, function() return T.num(function() return mq.TLO.Me.Gem(spell)() end) == 0 end) end
                mq.cmdf('/memspell %d "%s"', gem, spell)
                require('core.cast').tickDelay(9000, function() return T.str(function() return mq.TLO.Me.Gem(gem).Name() end) == spell end)
            end
        end
    end
    require('core.cast').captureMiscGems()
end

function M:loadSpellSet()
    self:loadSpellSetInner()
    require('core.cast').captureMiscGems()   -- the new loadout is what the scratch gems restore to
end
function M:loadSpellSetInner()
    local c = self.cfg
    if (c.LoadSpellSet or 0) == 1 then
        mq.cmdf('/memspellset %s', c.SpellSetName or 'MuleAssist')
        mq.delay(2000)
        require('core.cast').tickDelay(20000, function() return not T.bool(function() return mq.TLO.Window('SpellBookWnd').Open() end) and T.num(function() return mq.TLO.Me.Casting.ID() end) == 0 end)
    elseif (c.LoadSpellSet or 0) == 2 then
        if not Ini.read(Config.iniFile, 'MySpells', 'Gem1') then
            Log.info('You have no valid spells defined in your ini file [MySpells], load your spells now and do a /writespells command while in MuleAsssist.')
        else self:memMySpells(T.myName()) end
    end
end

--- /iniwrite <Section> spell <gem> | aa <name> | item | disc <1-8>: append one entry to a list section.
function M:iniWrite(section, kind, arg)
    kind = lower(kind)
    local what = nil
    if kind == 'item' then what = T.str(function() return mq.TLO.Cursor.Name() end) if what == '' then Log.info('..SET%s: You need to put the item on your cursor.', section) return end
    elseif kind == 'spell' then what = T.str(function() return mq.TLO.Me.Gem(tonumber(arg) or 0).Name() end) if what == '' then Log.info('..SET%s: You need to mem a spell', section) return end
    elseif kind == 'aa' then if T.num(function() return mq.TLO.Me.AltAbility(arg).ID() end) == 0 then Log.info("..SET%s: You don't have that AA", section) return end what = arg
    elseif kind == 'disc' then
        local n = tonumber(arg) or 0
        if n < 1 or n > 8 then Log.info('..SET%s: Disc # must be a Combat Abilty Button 1-8', section) return end
        what = T.str(function() return mq.TLO.Window('CombatAbilityWnd').Child('CAW_CombatEffectLabel' .. n).Text() end)
        if what == '' then Log.info("..SET%s: You don't have that Disc or Combat Ability button %d is empty.", section, n) return end
    else Log.info('..SET%s: usage /iniwrite %s spell <gem> | aa <name> | item | disc <1-8>', section, section) return end
    local size = tonumber(Ini.read(Config.iniFile, section, section .. 'Size')) or 40
    local entry = what
    if lower(section) == 'dps' then entry = what .. '|90' elseif lower(section) == 'heals' then entry = what .. '|80' end
    for i = 1, size do
        local v = Ini.read(Config.iniFile, section, section .. i)
        if v and lower(v):find(lower(what), 1, true) then Log.info('..SET%s: Duplicate entry %s%d=%s skipping.', section, section, i, v) return end
    end
    for i = 1, size do
        local v = Ini.read(Config.iniFile, section, section .. i)
        if not v or v == '' or lower(v) == 'null' then
            Ini.write(Config.iniFile, section, section .. i, entry)
            Log.info('..SET%s: %s%d is empty writing %s', section, section, i, entry)
            return
        end
    end
    Log.info('..SET%s: No empty slots in %s to write', section, section)
end

-- ------------------------------------------------------------- zombie mode
function M:zombie(arg)
    if not State.zombieMode and not lower(arg):find('off', 1, true) then
        State.zombieMode = true
        Comms.say('r', "I've been turned into a mindless Zombie! All I'm gonna do is follow %s", State.mainAssist)
        Timers.set('misc:zombie', 30000)
    else
        State.zombieMode = false
        Timers.clear('misc:zombie')
        Comms.say('g', 'ZombieMode set to FALSE')
    end
end

-- ------------------------------------------------------------- the custom hook
function M:customCall(name, param)
    self.pendingCustom = { name = name, param = param }
end
function M:customTick()
    local p = self.pendingCustom
    if not p then return end
    self.pendingCustom = nil
    Log.info('CustomFunc %s called.', p.name)
    if self.custom and type(self.custom.call) == 'function' then
        local ok, err = pcall(self.custom.call, p.name, p.param)
        if not ok then Log.error('custom %s: %s', p.name, tostring(err)) end
    else
        Log.info('custom: no custom.lua beside the script handles %s', p.name)
    end
end

function M:onStart()
    local s = self.cfg.OnStart or 'NULL'
    if s == '' or s:upper() == 'NULL' then return end
    for cmd in s:gmatch('[^|]+') do
        cmd = cmd:gsub('^%s+', ''):gsub('%s+$', '')
        if cmd ~= '' and cmd:upper() ~= 'NULL' then
            local script = cmd:match('^lua run (%S+)')
            if script and T.str(function() return mq.TLO.Lua.Script(script).Status() end) == 'RUNNING' then
                Log.info('OnStart: %s is already running', script)
            else
                Log.info('Doing OnStart command /%s', cmd)
                mq.cmdf('/docommand /%s', cmd)
            end
        end
    end
end

-- ------------------------------------------------------------- hooks
function M:Init()
    local ok, custom = pcall(require, 'custom')
    if ok and type(custom) == 'table' then self.custom = custom end
    local Combat = require('modules.combat')
    Combat.hooks.custom = function() M:customTick() if M.custom and type(M.custom.tick) == 'function' then pcall(M.custom.tick) end end
    mq.event('ma_joined', '#*#has joined the party#*#', function() Timers.set('misc:joined', 20000) end)
    mq.event('ma_camping', '#*#seconds to prepare your camp.', function() Log.info('camping - muleassist stops') M.stopRequested = true end)
    mq.event('ma_task', '#*#Your task #1# has been updated#*#', function(_, name) Comms.say('t', 'Task updated...(%s)', name) end)
    mq.event('ma_gain', '#*#You have gained#1#', function(_, text)
        text = tostring(text or '')
        if text:find('ABILITY POINT', 1, true) then Comms.say('w', '%s gained an AA, now has %d unspent', T.myName(), T.num(function() return mq.TLO.Me.AAPoints() end))
        elseif text:find('LEVEL', 1, true) then Comms.say('w', '%s gained a level, now is Level %d', T.myName(), T.num(function() return mq.TLO.Me.Level() end)) end
    end)
    mq.event('ma_appear1', '#*#You feel yourself starting to appear#*#', function() Comms.say('r', '%s invis is going to fall!', T.myName()) end)
    mq.event('ma_appear2', 'You appear.', function() Comms.say('r', '%s No longer invised!', T.myName()) end)
    mq.event('ma_lockeddoor', '#*#This door is locked#*#', function()
        local picks = nil
        for _, n in ipairs({ 'lockpicks', 'mechanized lockpicks', 'fine lockpicks' }) do
            if T.num(function() return mq.TLO.FindItem(n).ID() end) > 0 then picks = T.str(function() return mq.TLO.FindItem(n).Name() end) break end
        end
        Log.info('Door is locked')
        if not picks then return end
        Log.info('I have lockpicks %s. Gonna try to open the door!', picks)
        mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', picks)
        mq.delay(2000, function() return T.num(function() return mq.TLO.Cursor.ID() end) > 0 end)
        mq.cmd('/doortarget')
        mq.cmd('/click left door')
        mq.delay(500)
        mq.cmd('/click left door')
    end)
    mq.event('ma_bagsfull', '#*#Your inventory appears full!#*#', function() Comms.say('r', 'I have something on my cursor and no where to put it! HELP! DO SOMETHING!!!') end)
    mq.event('ma_fullinv', '#*#You cannot purchase this item, your inventory is full#*#', function()
        Log.info('Inventory full - closing the merchant window.')
        if T.bool(function() return mq.TLO.Window('MerchantWnd').Open() end) then mq.cmd('/notify MerchantWnd MW_Done_Button leftmouseup') end
        if T.num(function() return mq.TLO.Cursor.ID() end) > 0 and T.num(function() return mq.TLO.Me.FreeInventory() end) > 0 then mq.cmd('/autoinventory') end
    end)
    mq.event('ma_toosteep', '#*#The ground is too steep#*#', function() require('modules.movement').cfg.CampfireOn = 0 Log.info('Setting CampfireOn to 0. You are on a hill.') end)
end

function M:Shutdown()
    for _, e in ipairs({ 'ma_joined', 'ma_camping', 'ma_task', 'ma_gain', 'ma_appear1', 'ma_appear2', 'ma_lockeddoor', 'ma_bagsfull', 'ma_fullinv', 'ma_toosteep' }) do pcall(mq.unevent, e) end
end

function M:GiveTime(ctx)
    if State.chainPull == 2 or State.getAwayFollow then return end
    if State.zombieMode and Timers.expired('misc:zombie') then Timers.set('misc:zombie', 60000) Comms.say('r', 'Braaaaiiiinnnnssss') end
    if Timers.expired('misc:tick') then
        Timers.set('misc:tick', 1000)
        self:miscStuff()
    end
end

M.Binds = {
    ['/zombiemode'] = function(self, arg) self:zombie(arg or '') end,
    ['/groupcheck'] = function(self)
        if T.groupCount() == 0 then Log.info("I'm not in a group!") return end
        local ma = State.mainAssist ~= '' and T.spawnByName(State.mainAssist, 'pc') or nil
        Comms.say('g', '%s is in %s. %d away from MA. %d bag slots. Level %d', T.myName(), T.str(function() return mq.TLO.Zone.ShortName() end), ma and T.num(function() return ma.Distance() end) or 0, T.num(function() return mq.TLO.Me.FreeInventory() end), T.num(function() return mq.TLO.Me.Level() end))
        for i = 1, T.groupCount() do
            local m = T.groupMember(i)
            if T.num(function() return m.ID() end) == 0 or T.bool(function() return m.OtherZone() end) or T.str(function() return m.Type() end) == 'Corpse' then Log.info("%s isn't in zone with me", T.str(function() return m.CleanName() end)) end
        end
    end,
    ['/writespells'] = function(self)
        for gem = 1, 13 do
            local name = T.str(function() return mq.TLO.Me.Gem(gem).Name() end)
            Log.info('Gem %d: %s', gem, name)
            Ini.write(Config.iniFile, 'MySpells', 'Gem' .. gem, name ~= '' and name or 'NULL')
        end
    end,
    ['/memmyspells'] = function(self, arg) self:memMySpells(arg) end,
    ['/iniwrite'] = function(self, section, kind, arg) if section and section ~= '' then self:iniWrite(section, kind or '', arg or '') end end,
    ['/customcall'] = function(self, name, param) self:customCall(name or '', param or '') end,
    ['/muleedit'] = function(self) mq.cmdf('/notepad %s', Config.iniFile) end,
}

return M
