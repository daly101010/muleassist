-- modules/focusswap.lua: FocusSwap in-process (spec
-- muleassist/docs/superpowers/specs/2026-10-03-luaport-focusswap-design.md). Plans which focus item each
-- [DPS] spell wants (focusswap/plan.lua, copied from F:/lua/focusswap) and, from the cast engine's preCast
-- hook, swaps it in right before the gem cast (a port of the macro's Sub FocusSwapFor): /itemnotify, never
-- /exchange; a swap never blocks a cast; no swap-back.
local mq = require('mq')
local Config = require('core.config')
local Log = require('core.log')
local T = require('core.tlo')
local Cast = require('core.cast')
local Plan = require('focusswap.plan')
local FIni = require('focusswap.ini')

local M = { name = 'focusswap' }

M.Settings = {
    scalars = {
        { section = 'FocusSwap', key = 'FocusSwapOn', type = 'int', default = 0 },
    },
}

M.LOOP_MS, M.CHECK_MS, M.WAIT_MS = 250, 5000, 1000

local function Scan() return require('focusswap.scan') end
-- the map key: no rank suffix, case-insensitive (the macro's FocusMap.Find ignores case)
local function base(name) return (tostring(name or ''):gsub('%s+[Rr][Kk]%.%s*[IVXivx]+$', '')):lower() end

function M.reset()
    M.entries, M.mapString = {}, ''
    M.blocked, M.warned = {}, {}
    M.last = { inv = nil, spells = {}, plan = nil }
    M.lastFp, M.nextCheck, M.pending = nil, 0, 'start'
    M.nextTick, M.stopped, M.dumpWanted = 0, false, false
end
M.reset()

function M:on() return (self.cfg and (tonumber(self.cfg.FocusSwapOn) or 0) ~= 0) and not self.stopped end

function M:warnOnce(key, fmt, ...)
    if self.warned[key] then return end
    self.warned[key] = true
    Log.info('FocusSwap: ' .. fmt, ...)
end

-- the character INI as focusswap reads it: [DPS] spell names in list order, [FocusSwap] MinGain / Weight<SPA>
function M:readIni()
    local name = tostring(Config.iniFile or '')
    local fh = io.open((mq.configDir or 'config') .. '/' .. name, 'r')
    if not fh then return nil, 'cannot open ' .. name end
    local text = fh:read('a')
    fh:close()
    return FIni.parse(text)
end

function M:rebuild(reason)
    local sections, err = self:readIni()
    if not sections then self:warnOnce('ini', '%s', tostring(err)) return end
    local inv = Scan().inventory()
    for _, name in ipairs(inv.attune or {}) do
        self:warnOnce('attune:' .. name, '%s is not attuned yet - equip it by hand once to use it for swaps (then /focusswap rebuild)', name)
    end
    local function unknownOn(it)
        for _, s in ipairs(it.unknown or {}) do
            self:warnOnce('unk:' .. s, '%s (on %s) has a focus limit I do not know - it scores 0 (see /focusswap dump)', s, it.name)
        end
    end
    for _, it in pairs(inv.worn or {}) do unknownOn(it) end
    for _, it in ipairs(inv.bag or {}) do unknownOn(it) end
    local spells = {}
    for _, name in ipairs(FIni.dpsSpells(sections)) do
        local sp = Scan().spellInfo(name)
        if sp then spells[#spells + 1] = sp
        else self:warnOnce('spell:' .. name, '%s is not a spell I can look up (an AA or a typo) - no focus swap for it', name) end
    end
    local cfg = sections.FocusSwap or {}
    local plan = Plan.build(inv, spells, {
        weights = FIni.weights(sections, Plan.DEFAULT_WEIGHTS),
        minGain = tonumber(cfg.FocusSwapMinGain) or 3,
        blocked = self.blocked,
    })
    if plan.truncated then self:warnOnce('trunc', 'the map is over %d characters - later spells left out', Plan.MAX_LEN) end
    self.last = { inv = inv, spells = spells, plan = plan }
    local entries = {}
    for _, e in ipairs(plan.entries) do entries[base(e.spell)] = e end
    self.entries = entries
    if plan.map ~= self.mapString then
        self.mapString = plan.map
        Log.info('FocusSwap: %d spell(s) mapped (%s)', #plan.entries, tostring(reason))
        for _, e in ipairs(plan.entries) do Log.info('FocusSwap:   %s -> %s in %s (+%.1f)', e.spell, e.item, e.slot, e.gain) end
    end
end

function M:dump()
    local inv = self.last.inv or Scan().inventory()
    local function items(list, where)
        for _, it in ipairs(list) do
            Log.info('FocusSwap: %s [%s%s] fits %s', it.name, where, it.slot and (' ' .. it.slot) or '', table.concat(it.fits or {}, ','))
            for _, s in ipairs(it.spells or {}) do
                Log.info('FocusSwap:   focus %s', s.name)
                for i, e in ipairs(s.effects or {}) do
                    Log.info('FocusSwap:     slot %d: attrib %d base %d base2 %d max %d', i, e.attrib, e.base, e.base2, e.max)
                end
            end
        end
    end
    local wornList = {}
    for _, it in pairs(inv.worn or {}) do if #(it.spells or {}) > 0 then wornList[#wornList + 1] = it end end
    table.sort(wornList, function(a, b) return tostring(a.slot) < tostring(b.slot) end)
    items(wornList, 'worn')
    items(inv.bag or {}, 'bag')
    for _, sp in ipairs(self.last.spells or {}) do
        Log.info('FocusSwap: spell %s: id %d level %d resist %s %s target "%s" dur %d ticks cast %d ms',
            tostring(sp.name), tonumber(sp.id) or 0, tonumber(sp.level) or 0, tostring(sp.resist),
            sp.beneficial and 'beneficial' or 'detrimental', tostring(sp.targetType), tonumber(sp.durTicks) or 0, tonumber(sp.castMs) or 0)
    end
    local names = {}
    for name in pairs(self.blocked) do names[#names + 1] = name end
    if #names > 0 then Log.info('FocusSwap: blocked this session: %s', table.concat(names, ', ')) end
    Log.info('FocusSwap: map %s', self.mapString ~= '' and self.mapString or '(empty)')
end

--- Port of Sub FocusSwapFor: put entry.item into entry.slot. Returns what happened; never raises on purpose.
function M:swapFor(spellName, entry)
    local item, slot = entry.item, entry.slot
    local function isWorn() return T.str(function() return mq.TLO.Me.Inventory(slot).Name() end, '') == item end
    local function cursorId() return T.num(function() return mq.TLO.Cursor.ID() end, 0) end
    local function cursorName() return T.str(function() return mq.TLO.Cursor.Name() end, '') end
    if isWorn() then return 'worn' end
    if cursorId() > 0 or T.num(function() return mq.TLO.Me.Casting.ID() end, 0) > 0 then return 'busy' end
    local Pet = package.loaded['modules.pet']
    if Pet and Pet.focusSwapped ~= nil then return 'petfocus' end
    local fi = mq.TLO.FindItem('=' .. item)
    if T.num(function() return fi.ID() end, 0) == 0 then return 'missing' end
    -- only from a bag or a top-level pack slot: an item worn elsewhere stays where it is
    local itemSlot = T.num(function() return fi.ItemSlot() end, 0)
    if itemSlot < 23 then return 'elsewhere' end
    local bag = itemSlot - 22
    local itemSlot2 = T.num(function() return fi.ItemSlot2() end, -1)
    local pick
    if itemSlot2 >= 0 then pick = string.format('/nomodkey /itemnotify in pack%d %d leftmouseup', bag, itemSlot2 + 1)
    else pick = string.format('/nomodkey /itemnotify pack%d leftmouseup', bag) end
    mq.cmd(pick)
    mq.delay(self.WAIT_MS, function() return cursorName() == item end)
    if cursorName() == item then
        mq.cmdf('/nomodkey /itemnotify %s leftmouseup', slot)
        mq.delay(self.WAIT_MS, isWorn)
    end
    -- whatever is on the cursor now (the displaced item, or the focus item if the slot refused it)
    -- goes back where the focus item came from
    if cursorId() > 0 then
        mq.cmd(pick)
        mq.delay(self.WAIT_MS, function() return cursorId() == 0 end)
        if cursorId() > 0 then mq.cmd('/autoinventory') end
        mq.delay(self.WAIT_MS, function() return cursorId() == 0 end)
    end
    if not isWorn() then
        Log.info('FocusSwap: %s did not go into %s - casting %s without it; left out of swaps this session', item, slot, tostring(spellName))
        self.blocked[item] = true
        self.pending = 'swap failed: ' .. item
        return 'failed'
    end
    return 'swapped'
end

--- The cast engine's preCast hook: swap the spell's focus item in. A swap never blocks a cast.
function M:preCast(name)
    if not self:on() then return end
    local entry = self.entries[base(name)]
    if not entry then return end
    local ok, err = pcall(self.swapFor, self, name, entry)
    if not ok then Log.error('FocusSwap: swap for %s failed: %s', tostring(name), tostring(err)) end
end

function M:LoadSettings()
    self.cfg = Config.load(self.Settings)
    self.pending = self.pending or 'settings'
    Cast.hooks.preCast = function(name) M:preCast(name) end
end

function M:Tick()
    if not self:on() then return end
    local now = mq.gettime()
    if now < self.nextTick then return end
    self.nextTick = now + self.LOOP_MS
    if self.pending or now >= self.nextCheck then
        local busy = T.num(function() return mq.TLO.Cursor.ID() end, 0) > 0 or T.bool(function() return mq.TLO.Me.Zoning() end)
        if not busy then
            local fp = Scan().fingerprint()
            if self.pending or fp ~= self.lastFp then
                local ok, err = pcall(self.rebuild, self, self.pending or 'inventory changed')
                if not ok then Log.error('FocusSwap: rebuild failed: %s', tostring(err)) end
                -- either way: a persistent error is retried on the next inventory change or /focusswap rebuild
                self.lastFp, self.pending = fp, nil
            end
            self.nextCheck = mq.gettime() + self.CHECK_MS
        end
        -- busy: leave nextCheck and pending alone, so this is retried next tick
    end
    if self.dumpWanted then self.dumpWanted = false self:dump() end
end

M.Binds = {
    ['/focusswap'] = function(self, cmd)
        cmd = tostring(cmd or ''):lower()
        if cmd == 'dump' then self.dumpWanted = true if not self:on() then self:dump() self.dumpWanted = false end
        elseif cmd == 'rebuild' then self.pending = 'rebuild'
        elseif cmd == 'stop' then
            self.stopped = true
            self.entries, self.mapString = {}, ''
            Log.info('FocusSwap: stopped for this session')
        else Log.info('FocusSwap: /focusswap dump | rebuild | stop') end
    end,
}

return M
