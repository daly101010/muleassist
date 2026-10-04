-- Fake mq for focusswap tests. require('tests.fakes') BEFORE requiring any module under test.
-- F.inventory[slotId] = item spec; F.spells[name] = spell spec; F.vars = macro variables.
-- item spec:  { name, id, focus, focus2, worn (spell specs), augs = { item spec... },
--               size = bag slots, container = { [j] = item spec }, wornSlots = { slot ids },
--               attuneable = bool, nodrop = bool }
-- spell spec: { name, id, level, resist, spellType, targetType, durSec, castMs, rankName (nil when
--               the rank name matches the INI text; scan falls back to name),
--               effects = { { attrib, base, base2, max }... } }
-- F.cursor = the item ID on the cursor (nil/0 when empty); F.zoning = true while zoning.
local F = { inventory = {}, spells = {}, vars = {}, sent = {}, binds = {}, now = 0, macro = 'muleassist.mac',
  cursor = nil, zoning = false }

local function callable(v) return setmetatable({}, { __call = function() return v end }) end

-- fixture slot names (what the scan publishes); the real names come from InvSlot(id).Name in game
F.slotNames = { [0] = 'charm', [1] = 'leftear', [2] = 'head', [3] = 'face', [4] = 'rightear', [5] = 'neck',
  [6] = 'shoulder', [7] = 'arms', [8] = 'back', [9] = 'leftwrist', [10] = 'rightwrist', [11] = 'ranged',
  [12] = 'hands', [13] = 'mainhand', [14] = 'offhand', [15] = 'leftfinger', [16] = 'rightfinger',
  [17] = 'chest', [18] = 'legs', [19] = 'feet', [20] = 'waist', [21] = 'powersource', [22] = 'ammo' }

function F.spellTLO(spec)
  if not spec then return callable(nil) end
  local eff = spec.effects or {}
  local function slot(field) return function(i) local e = eff[i]; return callable(e and e[field] or 0) end end
  return setmetatable({
    Name = callable(spec.name), ID = callable(spec.id or 0), Level = callable(spec.level or 0),
    RankName = callable(spec.rankName), ResistType = callable(spec.resist or 'Unresistable'),
    SpellType = callable(spec.spellType or 'Detrimental'),
    TargetType = callable(spec.targetType or 'Single'), CastTime = callable(spec.castMs or 0),
    Duration = setmetatable({ TotalSeconds = callable(spec.durSec or 0) },
      { __call = function() return math.floor((spec.durSec or 0) / 6) end }),
    NumEffects = callable(#eff),
    Attrib = slot('attrib'), Base = slot('base'), Base2 = slot('base2'), Max = slot('max'),
  }, { __call = function() return spec.name end })
end

function F.itemTLO(spec)
  if not spec then return setmetatable({ ID = callable(nil), Name = callable(nil) }, { __call = function() return nil end }) end
  local augs = spec.augs or {}
  local bag = spec.container
  return setmetatable({
    Name = callable(spec.name), ID = callable(spec.id or 1),
    Focus = { Spell = F.spellTLO(spec.focus) }, Focus2 = { Spell = F.spellTLO(spec.focus2) },
    Worn = { Spell = F.spellTLO(spec.worn) },
    AugSlot = function(i) return { Item = F.itemTLO(augs[i]) } end,
    Container = callable(spec.size or 0),
    Item = function(j) return F.itemTLO(bag and bag[j]) end,
    WornSlots = callable(spec.wornSlots and #spec.wornSlots or 0),
    WornSlot = function(n) return { ID = callable(spec.wornSlots and spec.wornSlots[n]) } end,
    Attuneable = callable(spec.attuneable == true), NoDrop = callable(spec.nodrop == true),
  }, { __call = function() return spec.name end })
end

local Macro = setmetatable({
  Variable = function(name) return callable(F.vars[name]) end,
}, { __call = function() return F.macro end })

local mq = {
  gettime = function() return F.now end,
  delay = function(ms)
    F.now = F.now + (tonumber(ms) or 0)
    if F.onDelay then F.onDelay() end
  end,
  -- /varset lands in F.vars so the loop reads back what it wrote
  cmd = function(s)
    F.sent[#F.sent + 1] = s
    local k, v = s:match('^/varset (%S+)%s?(.*)$')
    if k then F.vars[k] = v end
  end,
  bind = function(name, fn) F.binds[name] = fn end,
  unbind = function(name) F.binds[name] = nil end,
  configDir = 'F:/Config',
  TLO = {
    Macro = Macro,
    Me = { Inventory = function(id) return F.itemTLO(F.inventory[id]) end,
      Zoning = function() return F.zoning == true end },
    InvSlot = function(id) return { Name = callable(F.slotNames[id]) } end,
    Spell = function(name) return F.spellTLO(F.spells[name]) end,
    Cursor = { ID = function() return F.cursor end },
  },
}
mq.cmdf = function(fmt, ...) mq.cmd(string.format(fmt, ...)) end

package.preload['mq'] = function() return mq end
F.mq = mq
return F
