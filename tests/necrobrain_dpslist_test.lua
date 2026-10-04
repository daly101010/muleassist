-- Run: luajit tests/test_dpslist.lua   (from F:\lua\necrobrain)
package.path = './necrobrain/?.lua;./?.lua;' .. package.path
local F = require('tests.necrobrain_fakes')
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1 else fail = fail + 1; io.write('FAIL: ' .. name .. (detail and (' -- ' .. tostring(detail)) or '') .. '\n') end
end
local D = require('dpslist')

local ini = [[
[General]
Role=Assist
[DPS]
DPSOn=2
DPSSize=4
DPS1=Drain Life|99
DPSCond1=${Me.PctHPs} < 80
DPS2=Vakk`dra's Sickly Mists|99
DPSCond2=TRUE
DPS3=Demand for Blood|99
DPSCond3=!${Me.Buff[Chaotic Power II].ID}
DPS4=Annihilate Undead|99
DPSCond4=${Target.Body.Name.Equal[Undead]}
DPS5=Should Be Ignored|99
DPS6=Curse of Mortality|99
DPSCond6=TRUE
DPS7=Severan's Rot|99
DPSCond7=TRUE
DPS8=Fake Buff Spell|99
DPSCond8=TRUE
DPS9=Fake Debuff Only|99
DPSCond9=TRUE
[Heals]
HealsOn=0
]]
local raw = D.parseIni(ini)
check('respects DPSSize', #raw == 4, #raw)
check('entry shape', raw[2].index == 2 and raw[2].spell == "Vakk`dra's Sickly Mists" and raw[2].opts == '99' and raw[2].cond == 'TRUE')

-- Real client data: damage lands in slot 2 (SPA 0, negative base), slot 1 is a
-- non-damage effect (e.g. SPA 36/35/116) on these necro DoTs.
F.spells["Vakk`dra's Sickly Mists"] = { mana = 866, castMs = 3000, durSec = 42, resist = 'Poison', base = { 18, -1010 }, attrib = { 36, 0 } }
F.spells['Demand for Blood'] = { mana = 673, castMs = 6000, durSec = 0, resist = 'Poison', base = { -2214 }, attrib = { 0 } }
F.spells['Annihilate Undead'] = { mana = 368, castMs = 5000, durSec = 0, resist = 'Magic', base = { -2012 }, attrib = { 0 }, targetType = 'Undead' }
F.spells['Drain Life'] = { mana = 667, castMs = 3200, durSec = 0, resist = 'Magic', base = { -1505 }, attrib = { 0 }, targetType = 'Lifetap' }
F.spells['Curse of Mortality'] = { mana = 1432, castMs = 3000, durSec = 30, resist = 'Magic', base = { 30, -1463 }, attrib = { 116, 0 } }
F.spells["Severan's Rot"] = { mana = 947, castMs = 3000, durSec = 72, resist = 'Disease', base = { 18, -734 }, attrib = { 35, 0 } }
-- buff-shaped: single positive-base effect, must not classify as damage.
F.spells['Fake Buff Spell'] = { mana = 100, castMs = 2000, durSec = 600, resist = 'Unresistable', base = { 50 }, attrib = { 1 } }
-- debuff-only: negative bases but no SPA-0 slot, must not classify as damage.
F.spells['Fake Debuff Only'] = { mana = 200, castMs = 2000, durSec = 18, resist = 'Magic', base = { 18, 18 }, attrib = { 35, 36 } }

local e = D.enrich(raw[2])
check('dot enriched', e and e.isDot and e.base == 1010 and e.durSec == 42 and e.castSec == 3 and e.resistType == 'poison', e and e.resistType)
e = D.enrich(raw[3])
check('dfb synergy', e and e.synergy == 'power' and not e.isDot and e.base == 2214)
-- resistTypes: the lines that could land, for the whole-list fallback gate
do
  local list = {
    { spell = 'Vakk', resistType = 'poison' },
    { spell = 'Curse', resistType = 'magic' },
    { spell = 'Ashen', resistType = 'fire' },
    { spell = 'Undead', resistType = 'magic', undeadOnly = true },
    { spell = 'Life Burn', resistType = 'unresistable', hpFraction = 0.75, isAA = true, namedOnly = true },
  }
  local function has(t, x) for _, v in ipairs(t) do if v == x then return true end end return false end
  local rt = D.resistTypes(list, { named = false })
  check('resistTypes: trash leaves out the named-only AA', not has(rt, 'unresistable') and has(rt, 'poison') and #rt == 3, table.concat(rt, ','))
  rt = D.resistTypes(list, { named = true, aaReady = function() return true end, usable = { ['Life Burn'] = true } })
  check('resistTypes: a usable Life Burn on a named counts', has(rt, 'unresistable'))
  rt = D.resistTypes(list, { named = true, aaReady = function() return false end })
  check('resistTypes: a spent Life Burn does not hold the fallback shut', not has(rt, 'unresistable'))
  rt = D.resistTypes(list, { named = true, aaReady = function() return true end, usable = {} })
  check('resistTypes: a ready but unusable Life Burn does not either', not has(rt, 'unresistable'))
  rt = D.resistTypes(list, { named = false, mem = { Curse = false } })
  check('resistTypes: a spell not memorized does not count', not has(rt, 'magic'), table.concat(rt, ','))
  rt = D.resistTypes(list, { named = false, targetUndead = true, mem = { Curse = false } })
  check('resistTypes: undead-only counts on an undead', has(rt, 'magic'))
  -- a line that cannot land in the time left does not hold the gate shut
  local timed = {
    { spell = 'Curse', resistType = 'magic', isDot = true, castSec = 3 },
    { spell = 'Venin', resistType = 'poison', castSec = 6 },
    { spell = 'Ashen', resistType = 'fire', isDot = true, castSec = 3 },
  }
  rt = D.resistTypes(timed, { named = false, ttdSecs = 12 })
  check('resistTypes: a DoT fitting one tick drops out, a nuke that fits stays', not has(rt, 'magic') and has(rt, 'poison'), table.concat(rt, ','))
  rt = D.resistTypes(timed, { named = false, ttdSecs = 5 })
  check('resistTypes: a nuke that cannot finish casting drops out', #rt == 0, table.concat(rt, ','))
  rt = D.resistTypes(timed, { named = true })
  check('resistTypes: no ttd (named) keeps every line', #rt == 3)
end

-- level (Gift of Mana cap), rank name (gem lookup) and the macro tag
check('level 0 when the TLO has none', e and e.level == 0, e and e.level)
check('rankName nil when the TLO has none', e and e.rankName == nil, e and e.rankName)
F.spells['Demand for Blood'].level = 75
F.spells['Demand for Blood'].rankName = 'Demand for Blood Rk. II'
e = D.enrich(raw[3])
check('level from the Spell TLO', e and e.level == 75, e and e.level)
check('rankName from the Spell TLO', e and e.rankName == 'Demand for Blood Rk. II', e and e.rankName)
F.spells['Demand for Blood'].level, F.spells['Demand for Blood'].rankName = nil, nil
e = D.enrich({ index = 20, spell = 'Demand for Blood', opts = '99|spam', cond = 'TRUE' })
check('macro tag kept (lowercased)', e and e.tag == 'spam', e and e.tag)
e = D.enrich({ index = 21, spell = 'Demand for Blood', opts = '99', cond = 'TRUE' })
check('no tag -> nil', e and e.tag == nil, e and e.tag)
e = D.enrich(raw[4])
check('undead only', e and e.undeadOnly == true)
check('unknown spell -> nil', D.enrich({ index = 9, spell = 'Not A Spell', opts = '', cond = '' }) == nil)

e = D.enrich({ index = 6, spell = 'Curse of Mortality', opts = '99', cond = 'TRUE' })
check('curse of mortality slot2 dot', e and e.isDot and e.base == 1463 and e.durSec == 30 and e.resistType == 'magic', e and e.base)
e = D.enrich({ index = 7, spell = "Severan's Rot", opts = '99', cond = 'TRUE' })
check("severan's rot slot2 dot", e and e.isDot and e.base == 734 and e.durSec == 72 and e.resistType == 'disease', e and e.base)
check('buff spell -> nil', D.enrich({ index = 8, spell = 'Fake Buff Spell', opts = '99', cond = 'TRUE' }) == nil)
check('debuff-only spell -> nil', D.enrich({ index = 9, spell = 'Fake Debuff Only', opts = '99', cond = 'TRUE' }) == nil)
check('opts nil does not error', D.enrich({ index = 2, spell = "Vakk`dra's Sickly Mists", opts = nil, cond = 'TRUE' }) ~= nil)
-- |util lines (Mind Wrack, snares) are the macro's own business: excluded even when the spell does damage
local uE, uWhy = D.enrich({ index = 3, spell = "Vakk`dra's Sickly Mists", opts = '99|util', cond = 'TRUE' })
check('util-tagged damage line -> nil', uE == nil and uWhy == 'util', uWhy)
check('util tag is case-insensitive', D.enrich({ index = 3, spell = "Vakk`dra's Sickly Mists", opts = '99|UTIL', cond = 'TRUE' }) == nil)
check('util as a substring of a name does not match', D.enrich({ index = 3, spell = "Vakk`dra's Sickly Mists", opts = '99|Utilio', cond = 'TRUE' }) ~= nil)
-- |Me, |Feign and |MA lines: the macro's live gate never holds them for a pick (its DPSPart3), so the
-- brain must not rank them either
local maE, maWhy = D.enrich({ index = 10, spell = "Vakk`dra's Sickly Mists", opts = '98|MA', cond = 'TRUE' })
check('MA-tagged damage line -> nil', maE == nil and maWhy == 'MA', maWhy)
check('Me / Feign tags excluded, any case', D.enrich({ index = 3, spell = "Vakk`dra's Sickly Mists", opts = '99|me', cond = 'TRUE' }) == nil
  and D.enrich({ index = 3, spell = "Vakk`dra's Sickly Mists", opts = '99|Feign', cond = 'TRUE' }) == nil)
check('tag after an if condition is the 5th field', D.enrich({ index = 3, spell = "Vakk`dra's Sickly Mists", opts = '99|ifme|${Me.PctMana}>40|MA', cond = 'TRUE' }) == nil)
check('if condition without a 5th field keeps the line', D.enrich({ index = 3, spell = "Vakk`dra's Sickly Mists", opts = '99|if|${Target.Named}', cond = 'TRUE' }) ~= nil)
check('tag with no |NN field is not read, like the macro', D.enrich({ index = 3, spell = "Vakk`dra's Sickly Mists", opts = 'MA', cond = 'TRUE' }) ~= nil)

-- M.load(path) now returns entries, err, skipped: one string per raw DPS line
-- that did not become an entry, naming the reason (debuffall / unknown to
-- Spell TLO / no direct damage slot). Write a real INI to disk and load it.
local loadIni = [[
[DPS]
DPSSize=4
DPS1=Vakk`dra's Sickly Mists|99
DPSCond1=TRUE
DPS2=Annul Magic|99|debuffall
DPSCond2=TRUE
DPS3=Distillate of Celestial Healing X|99
DPSCond3=TRUE
DPS4=Fake Debuff Only|99
DPSCond4=TRUE
]]
local tmpPath = 'tests/tmp_dpslist_load.ini'
local wfh = io.open(tmpPath, 'w')
wfh:write(loadIni)
wfh:close()

local entries, loadErr, skipped = D.load(tmpPath)
os.remove(tmpPath)

check('load: no error opening the file', loadErr == nil, loadErr)
check('load: only the real damage spell became an entry', #entries == 1 and entries[1].spell == "Vakk`dra's Sickly Mists", entries and #entries)
check('load: skipped lists one entry per dropped line', skipped and #skipped == 3, skipped and #skipped)
check('load: skipped names the debuffall line', skipped and skipped[1] == 'Annul Magic (debuffall)', skipped and skipped[1])
check('load: skipped names the TLO-unknown line', skipped and skipped[2] == 'Distillate of Celestial Healing X (unknown to Spell TLO)', skipped and skipped[2])
check('load: skipped names the no-damage-slot line', skipped and skipped[3] == 'Fake Debuff Only (no direct damage slot)', skipped and skipped[3])

-- duplicate spell entries (the macro's INI writer can produce them): keep the first, report the rest
do
  local dupIni = '[DPS]\nDPSSize=3\nDPS1=Venin|99\nDPSCond1=TRUE\nDPS2=Annihilate Undead|99\nDPSCond2=TRUE\nDPS3=Venin|99\nDPSCond3=TRUE\n'
  F.spells['Venin'] = { mana = 660, castMs = 6000, durSec = 0, resist = 'Poison', base = { -2279 }, attrib = { 0 } }
  local path = os.tmpname()
  local fh = io.open(path, 'w'); fh:write(dupIni); fh:close()
  local entries, err, skipped = D.load(path)
  os.remove(path)
  check('dup: two entries kept', err == nil and #entries == 2, #entries)
  check('dup: first Venin kept at index 1', entries[1].spell == 'Venin' and entries[1].index == 1)
  local found = false
  for _, sname in ipairs(skipped or {}) do if sname:find('Venin (duplicate of DPS1)', 1, true) then found = true end end
  check('dup: reported in skipped', found, table.concat(skipped or {}, '; '))
end

do
  local e99 = D.enrich({ index = 1, spell = 'Venin', opts = '99', cond = 'TRUE' })
  local e100 = D.enrich({ index = 2, spell = 'Venin', opts = '', cond = 'TRUE' })
  check('maxPct from |99', e99 and e99.maxPct == 99, e99 and e99.maxPct)
  check('maxPct default 100', e100 and e100.maxPct == 100, e100 and e100.maxPct)
end

-- AA entries: no spell called plain "Life Burn" exists, but the AA does. SPA 509 base 750 =
-- 75% of the caster's current HP as unresistable direct damage; 1h54m reuse = named-only burst.
F.aas = { ['Life Burn'] = { id = 1234, reuseSec = 6840, ready = true,
  spell = { mana = 0, castMs = 100, durSec = 0, resist = 'Unresistable', attrib = { 509, 0 }, base = { 750, -600 } } } }
local lb, lbreason = D.enrich({ index = 12, spell = 'Life Burn', opts = '99', cond = '${Target.Named}' })
check('AA resolves when Spell TLO misses', lb ~= nil, lbreason)
check('AA flagged', lb and lb.isAA == true)
check('AA hp fraction 0.75', lb and math.abs(lb.hpFraction - 0.75) < 1e-9, lb and lb.hpFraction)
check('AA mana 0 / cast 0.1 / not a dot', lb and lb.mana == 0 and math.abs(lb.castSec - 0.1) < 1e-9 and lb.isDot == false)
check('AA recast is gem-like, reuse kept aside', lb and lb.recastSec == 1.5 and lb.reuseSec == 6840, lb and lb.reuseSec)
check('long reuse => namedOnly', lb and lb.namedOnly == true)
check('AA unresistable', lb and lb.resistType == 'unresistable', lb and lb.resistType)
F.aas['Short AA'] = { id = 5, reuseSec = 60, ready = true, spell = { mana = 0, castMs = 0, durSec = 0, resist = 'Magic', attrib = { 0 }, base = { -500 } } }
local sa = D.enrich({ index = 13, spell = 'Short AA', opts = '', cond = 'TRUE' })
check('short-reuse AA with plain damage slot: base 500, not namedOnly', sa and sa.base == 500 and not sa.namedOnly and not sa.hpFraction, sa and sa.base)
F.aas['Buff AA'] = { id = 6, reuseSec = 60, ready = true, spell = { mana = 0, castMs = 0, durSec = 30, resist = 'Magic', attrib = { 3 }, base = { 10 } } }
local ba, bareason = D.enrich({ index = 14, spell = 'Buff AA', opts = '', cond = 'TRUE' })
check('AA without damage skipped', ba == nil and bareason == 'no direct damage slot', bareason)
local un, unreason = D.enrich({ index = 15, spell = 'Nonexistent Thing', opts = '', cond = 'TRUE' })
check('unknown to both TLOs', un == nil and unreason == 'unknown to Spell TLO', unreason)

io.write(string.format('test_dpslist: %d passed, %d failed\n', pass, fail))
os.exit(fail == 0 and 0 or 1)
