-- Run: luajit tests/test_scan.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path
local F = require('tests.focusswap.fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail ~= nil and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local Fx = require('tests.focusswap.fixtures')
local S = require('focusswap.scan')

local function spell(name, effects) return { name = name, effects = effects } end
local MURK = spell('Murk Blood', Fx.MURK_BLOOD)
local PYR = spell('Pyrilen Fury', Fx.PYRILEN_FURY)

F.inventory = {
  [18] = { name = 'Breeches of Whispered Death', id = 101, focus = MURK, wornSlots = { 18 } },
  [8]  = { name = 'Plain Cloak', id = 102, wornSlots = { 8 } },
  [7]  = { name = 'Plain Sleeves', id = 103, wornSlots = { 7 }, augs = { { name = 'Fire Aug', id = 104, focus = PYR } } },
  [13] = { name = 'Fire Staff', id = 105, focus = PYR, wornSlots = { 13 } },
  [23] = { name = 'Backpack', id = 200, size = 5, container = {
    -- class lists are never read: this one is "WIZ only" on stock data
    [1] = { name = 'Breeches of Phenomenal Power', id = 201, focus = PYR, wornSlots = { 18 }, classes = 'WIZ' },
    [2] = { name = 'Rusty Dagger', id = 202, wornSlots = { 13, 14 } },
    [3] = { name = 'Unattuned Pants', id = 203, focus = MURK, wornSlots = { 18 }, attuneable = true },
    [5] = { name = 'Attuned Pants', id = 204, focus = MURK, wornSlots = { 18 }, attuneable = true, nodrop = true },
  } },
  [24] = { name = 'Loose Fire Bracer', id = 300, focus = PYR, wornSlots = { 9, 10 } },
  [25] = { name = 'Fire Blade', id = 301, focus = PYR, wornSlots = { 13 } },
}

local inv = S.inventory()
check('worn legs read', inv.worn.legs and inv.worn.legs.name == 'Breeches of Whispered Death' and #inv.worn.legs.foci == 1)
check('worn item without a focus still listed', inv.worn.back and #inv.worn.back.foci == 0)
check('augment focus counts toward its item', inv.worn.arms and #inv.worn.arms.foci == 1 and inv.worn.arms.spells[1].name == 'Pyrilen Fury')
check('weapon slot never read', inv.worn.mainhand == nil)
local bag = {}
for _, it in ipairs(inv.bag) do bag[it.name] = it end
check('fire pants in the bag, class list ignored', bag['Breeches of Phenomenal Power'] ~= nil and bag['Breeches of Phenomenal Power'].fits[1] == 'legs')
check('no-focus bag item left out', bag['Rusty Dagger'] == nil)
check('weapon-only bag item left out', bag['Fire Blade'] == nil)
check('unattuned item skipped and reported', bag['Unattuned Pants'] == nil and inv.attune[1] == 'Unattuned Pants', inv.attune[1])
check('attuned (no drop) item kept', bag['Attuned Pants'] ~= nil)
local br = bag['Loose Fire Bracer']
check('loose item in a top-level pack slot fits both wrists', br and #br.fits == 2 and br.fits[1] == 'leftwrist' and br.fits[2] == 'rightwrist')

-- bag items that cannot be worn are dropped before their augments and effects are read
F.inventory[23].container[4] = { name = 'Focus Gem (no slot)', id = 205, focus = PYR, attuneable = true }
local readNames = {}
local realReadItem = S.readItem
S.readItem = function(it, fits)
  local rec = realReadItem(it, fits)
  if rec then readNames[rec.name] = true end
  return rec
end
inv = S.inventory()
S.readItem = realReadItem
bag = {}
for _, it in ipairs(inv.bag) do bag[it.name] = it end
check('non-wearable bag item never read', readNames['Focus Gem (no slot)'] == nil and bag['Focus Gem (no slot)'] == nil)
check('weapon-only bag items never read', readNames['Rusty Dagger'] == nil and readNames['Fire Blade'] == nil)
check('wearable bag items still read and kept', bag['Breeches of Phenomenal Power'] and bag['Loose Fire Bracer'] and bag['Attuned Pants'])
check('non-wearable attuneable item not reported', #inv.attune == 1 and inv.attune[1] == 'Unattuned Pants', #inv.attune)
check('worn items still read in full', inv.worn.back and inv.worn.arms and #inv.worn.arms.foci == 1)
F.inventory[23].container[4] = nil

-- fingerprint: a swap only moves items
local fp1 = S.fingerprint()
check('fingerprint agrees with the guarded walk', fp1 == S._fingerprintGuarded(), fp1)
F.inventory[18], F.inventory[23].container[1] = F.inventory[23].container[1], F.inventory[18]
check('swap leaves the fingerprint alone', S.fingerprint() == fp1)
F.inventory[26] = { name = 'New Loot', id = 400 }
check('new item changes it', S.fingerprint() ~= fp1)
F.inventory[26] = nil
check('removing it again restores it', S.fingerprint() == fp1)
local keep = F.inventory[23].container[2]
F.inventory[23].container[2] = nil
check('an item leaving a bag changes it', S.fingerprint() ~= fp1)
F.inventory[23].container[2] = { name = 'Other Dagger', id = 206, wornSlots = { 13 } }
check('an item replaced in a bag changes it', S.fingerprint() ~= fp1)
F.inventory[23].container[2] = keep
local worn8 = F.inventory[8]
F.inventory[8] = { name = 'Better Cloak', id = 199, wornSlots = { 8 } }
check('a worn item replaced changes it', S.fingerprint() ~= fp1)
F.inventory[8] = worn8
check('back to the start', S.fingerprint() == fp1)
-- a TLO read that raises: the guarded walk answers instead, the same way
local realInventory = F.mq.TLO.Me.Inventory
F.mq.TLO.Me.Inventory = function(id)
  local it = realInventory(id)
  if id == 23 then
    local wrapped = setmetatable({ Item = function(j) if j == 2 then error('TLO read failed') end return it.Item(j) end },
      { __index = it, __call = function() return it() end })
    return wrapped
  end
  return it
end
local fpErr = S.fingerprint()
check('a raising read falls back to the guarded walk', fpErr == S._fingerprintGuarded() and fpErr ~= fp1, fpErr)
F.mq.TLO.Me.Inventory = realInventory

-- readEffects: the unguarded read and the per-field fallback give the same slots
local spMax = F.spellTLO(PYR)
local effOk = S.readEffects(spMax)
local brokenMax = setmetatable({ Max = function() error('no Max') end }, { __index = spMax, __call = function() return spMax() end })
local effBroken = S.readEffects(brokenMax)
local same = effOk and effBroken and #effOk == #effBroken
for i = 1, (effOk and #effOk or 0) do
  same = same and effBroken[i].attrib == effOk[i].attrib and effBroken[i].base == effOk[i].base and effBroken[i].max == 0
end
check('readEffects falls back per field on a raising read', same)
check('readEffects of no spell is nil', S.readEffects(F.spellTLO(nil)) == nil and S.readEffects(nil) == nil)

-- the direct reads give exactly what the per-field guarded reads give (the guarded ones are the reference)
local function deepEq(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
check('inventory: direct walk == guarded walk', deepEq(S.inventory(), S._inventoryGuarded()))
local legs = F.itemTLO(F.inventory[18])
check('readItem: direct == guarded', deepEq(S.readItem(legs), S._readItemGuarded(legs)))
-- an item whose augment read raises: the item is redone through the guards, and the guards make it a
-- missing augment
local brokenAug = setmetatable({ AugSlot = function() error('aug read failed') end },
  { __index = F.itemTLO(F.inventory[7]), __call = function() return 'Plain Sleeves' end })
local recBroken = S.readItem(brokenAug)
check('readItem falls back to the guards on a raising read', recBroken and recBroken.name == 'Plain Sleeves'
  and #recBroken.foci == 0 and deepEq(recBroken, S._readItemGuarded(brokenAug)))
-- a raising walk read (a pack's Container): the whole walk is redone through the guards
F.mq.TLO.Me.Inventory = function(id)
  local it = realInventory(id)
  if id == 23 then
    return setmetatable({ Container = function() error('Container read failed') end }, { __index = it, __call = function() return it() end })
  end
  return it
end
local invErr = S.inventory()
check('inventory falls back to the guarded walk on a raising read', deepEq(invErr, S._inventoryGuarded()) and invErr.worn.legs ~= nil)
F.mq.TLO.Me.Inventory = realInventory

-- a focus with a limit SPA limits.lua does not know
F.inventory[20] = { name = 'Odd Belt', id = 500, wornSlots = { 20 },
  focus = spell('Odd Focus', { { attrib = 124, base = 5 }, { attrib = 999, base = 1 } }) }
inv = S.inventory()
check('unknown limit reported on the item', inv.worn.waist and inv.worn.waist.unknown[1] == 'Odd Focus')

-- spell records
F.spells['Chaos Venom'] = { name = 'Chaos Venom', id = 1001, level = 65, resist = 'Poison', spellType = 'Detrimental',
  targetType = 'Single', durSec = 42, castMs = 3000, effects = { { attrib = 0, base = -200 }, { attrib = 254 } } }
local sp = S.spellInfo('Chaos Venom')
check('spell record read', sp and sp.id == 1001 and sp.level == 65 and sp.resist == 'poison' and sp.beneficial == false)
check('duration in ticks', sp and sp.durTicks == 7, sp and sp.durTicks)
check('cast time in ms', sp and sp.castMs == 3000)
check('HP slot present, blank slot not', sp and sp.spas[0] == true and sp.spas[254] == nil)
check('key falls back to the INI name when there is no rank', sp and sp.key == 'Chaos Venom', sp and sp.key)
check('unknown spell is nil', S.spellInfo('Life Burn') == nil)

F.spells['Ignite Blood'] = { name = 'Ignite Blood', rankName = 'Ignite Blood Rk. II', id = 1002, level = 65,
  resist = 'Fire', effects = { { attrib = 0, base = -200 } } }
check('key is the rank name when the spell has one', S.spellInfo('Ignite Blood').key == 'Ignite Blood Rk. II',
  S.spellInfo('Ignite Blood').key)

io.write(string.format('test_scan: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
