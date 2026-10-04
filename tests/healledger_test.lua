-- lua tests/healledger_test.lua   (from lua/muleassist)
package.path = './?.lua;./?/init.lua;' .. package.path

local Ledger = require('healledger.ledger')

-- ---------------------------------------------------------------- fixtures
local function healer(name, id, o)
    o = o or {}
    return {
        v = 1, from = name, id = id, ts = o.ts or 0, seq = 1, zone = 'z',
        me = { hp = 100, mana = o.mana or 80, dead = false, stunned = false, feigned = false,
               x = o.x or 0, y = o.y or 0, z = 0, class = 'CLR', group = o.group or 'g1', inCombat = true,
               casting = o.casting, counters = o.counters },
        lines = {
            direct = o.direct or { { name = 'Remedy', pct = 85, range = 100, castMs = 1000, ready = o.ready ~= false, mana = true } },
            group = o.groupLines or {},
            cures = o.cures or {},
        },
        targets = o.targets or {},
        macro = { healLine = o.healLine or 85, tankLine = 40, healTank = 'Tank', healTankId = 999,
                  healsOn = o.healsOn == nil and 1 or o.healsOn, curesOn = o.curesOn or 0, whynotLast = o.whynot },
        events = o.events or {},
    }
end

local function target(id, name, hp, o)
    o = o or {}
    return { name = name, hp = hp, x = o.x or 10, y = o.y or 0, z = 0, dead = o.dead == true, class = o.class or 'ROG',
             group = o.group or 'g1', pet = o.pet == true, counters = o.counters }
end

local function tickTo(L, t0, t1, step)
    local opened = {}
    for t = t0, t1, step or 250 do
        for _, r in ipairs(Ledger.tick(L, t)) do opened[#opened + 1] = r end
    end
    return opened
end

local function kinds(rows)
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = r.kind end
    return table.concat(out, ',')
end

-- ---------------------------------------------------------------- unhealed
do
    local L = Ledger.newLedger()
    local snap = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) } })
    Ledger.ingest(L, snap, 0)
    assert(#Ledger.tick(L, 0) == 0, 'no row at once')
    Ledger.ingest(L, snap, 1000)
    local rows = tickTo(L, 250, 1600)
    assert(kinds(rows) == 'unhealed', 'unhealed opens after 1.5s, got: ' .. kinds(rows))
    local r = rows[1]
    assert(r.openedAt == 0, 'opened at the first idle-candidate tick')
    assert(r.target.name == 'Rogue' and r.targetHp == 40, 'target recorded')
    assert(#r.candidates == 1 and r.candidates[1].box == 'Cleric1' and r.candidates[1].spell == 'Remedy', 'candidate recorded')
    assert(r.candidates[1].dist == 10, 'distance recorded')
    assert(L.open['unhealed:201'] == r, 'row stays open')
    -- healed: the row closes with its duration
    snap.targets[201].hp = 95
    Ledger.ingest(L, snap, 2000)
    assert(#Ledger.tick(L, 2000) == 0, 'nothing new')
    assert(r.closedAt == 2000 and r.durationMs == 2000, 'closed with duration')
    assert(L.open['unhealed:201'] == nil, 'no longer open')
    local line = Ledger.formatRow(r)
    assert(line:find('UNHEALED') and line:find('Cleric1') and line:find('Remedy ready'), 'formatRow: ' .. line)
end

-- no false positives: covered, out of range, stale, healer casting elsewhere counts as not idle
do
    local L = Ledger.newLedger()
    local covered = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) },
        casting = { spell = 'Remedy', targetId = 201, landsAt = 5000, kind = 'direct', startedAt = 0 } })
    Ledger.ingest(L, covered, 0)
    for t = 0, 3000, 250 do Ledger.ingest(L, covered, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'a heal in flight covers the target')

    L = Ledger.newLedger()
    local far = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40, { x = 500 }) } })
    for t = 0, 3000, 250 do Ledger.ingest(L, far, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'out of range is not a candidate')

    L = Ledger.newLedger()
    local stale = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) } })
    Ledger.ingest(L, stale, 0)
    for t = 0, 3000, 250 do Ledger.tick(L, t) end
    assert(#L.rows == 0, 'a stale box is not trusted')

    L = Ledger.newLedger()
    local busy = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) },
        casting = { spell = 'Remedy', targetId = 202, landsAt = 9000, kind = 'direct', startedAt = 0 } })
    for t = 0, 3000, 250 do Ledger.ingest(L, busy, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'a healer casting elsewhere is not idle')

    L = Ledger.newLedger()
    local above = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 90) } })
    for t = 0, 3000, 250 do Ledger.ingest(L, above, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'above the line is not a gap')
end

-- ---------------------------------------------------------------- late
do
    local L = Ledger.newLedger()
    local snap = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) },
        casting = { spell = 'Remedy', targetId = 202, landsAt = 9000, kind = 'direct', startedAt = 0 } })
    for t = 0, 2250, 250 do Ledger.ingest(L, snap, t) ; Ledger.tick(L, t) end
    snap.me.casting = { spell = 'Remedy', targetId = 201, landsAt = 3500, kind = 'direct', startedAt = 2500 }
    Ledger.ingest(L, snap, 2500)
    local rows = Ledger.tick(L, 2500)
    assert(kinds(rows) == 'late', 'late row when the heal starts 2.5s after the crossing, got: ' .. kinds(rows))
    assert(rows[1].healer == 'Cleric1' and rows[1].durationMs == 2500, 'late duration')
    assert(#Ledger.tick(L, 2750) == 0, 'late rows once per episode')
end

-- ---------------------------------------------------------------- duplicate
do
    local L = Ledger.newLedger()
    local a = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) },
        casting = { spell = 'Remedy', targetId = 201, landsAt = 3000, kind = 'direct', startedAt = 2000 } })
    local b = healer('Cleric2', 112, { casting = { spell = 'Remedy', targetId = 201, landsAt = 3200, kind = 'direct', startedAt = 2200 } })
    Ledger.ingest(L, a, 2200) ; Ledger.ingest(L, b, 2200)
    local rows = Ledger.tick(L, 2200)
    assert(kinds(rows) == 'duplicate', 'duplicate row, got: ' .. kinds(rows))
    assert(rows[1].healer == 'Cleric2' and rows[1].first.box == 'Cleric1', 'second caster is the duplicate')
    Ledger.ingest(L, a, 2450) ; Ledger.ingest(L, b, 2450)
    assert(#Ledger.tick(L, 2450) == 0, 'reported once')
    -- far apart landings are not duplicates
    L = Ledger.newLedger()
    b.me.casting.landsAt = 6000
    Ledger.ingest(L, a, 2200) ; Ledger.ingest(L, b, 2200)
    assert(#Ledger.tick(L, 2200) == 0, 'landings 3s apart are not a duplicate')
end

-- ---------------------------------------------------------------- uncured
do
    local L = Ledger.newLedger()
    local sick = healer('Rogue', 201, { healsOn = 0, direct = {}, counters = { p = 3, d = 0, c = 0, co = 0 }, x = 10 })
    local curer = healer('Cleric1', 111, { curesOn = 1, cures = { { name = 'Cure Poison', types = { poison = true }, range = 100, ready = true } } })
    for t = 0, 4250, 250 do Ledger.ingest(L, sick, t) ; Ledger.ingest(L, curer, t) end
    local rows = tickTo(L, 0, 4250)
    assert(kinds(rows) == 'uncured', 'uncured after 4s, got: ' .. kinds(rows))
    assert(rows[1].types[1] == 'poison' and rows[1].candidates[1].spell == 'Cure Poison', 'type and cure recorded')
    sick.me.counters = { p = 0, d = 0, c = 0, co = 0 }
    Ledger.ingest(L, sick, 4500) ; Ledger.ingest(L, curer, 4500)
    Ledger.tick(L, 4500)
    assert(rows[1].closedAt == 4500, 'closes when clean')
    -- a curer whose cure does not match the type is not a candidate
    L = Ledger.newLedger()
    sick.me.counters = { p = 0, d = 2, c = 0, co = 0 }
    for t = 0, 5000, 250 do Ledger.ingest(L, sick, t) ; Ledger.ingest(L, curer, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'no matching cure, no candidate, no row')
    -- a real player (counters unknown) never rows
    L = Ledger.newLedger()
    local c2 = healer('Cleric1', 111, { curesOn = 1, cures = { { name = 'Cure Poison', types = { poison = true }, range = 100, ready = true } },
        targets = { [300] = target(300, 'RealGuy', 95) } })
    for t = 0, 5000, 250 do Ledger.ingest(L, c2, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'unknown counters are not a gap')
end

-- ---------------------------------------------------------------- missed group
do
    local L = Ledger.newLedger()
    local h = healer('Cleric1', 111, {
        groupLines = { { name = 'Word of Vivification', pct = 70, range = 100, ready = true, mana = true } },
        targets = { [201] = target(201, 'Rogue', 60), [202] = target(202, 'Monk', 55), [203] = target(203, 'Wizard', 65) },
        healLine = 50 })
    for t = 0, 3000, 250 do Ledger.ingest(L, h, t) end
    local rows = tickTo(L, 0, 3000)
    assert(kinds(rows) == 'missed_group', 'missed group after 3s, got: ' .. kinds(rows))
    assert(rows[1].count == 3 and rows[1].spell == 'Word of Vivification', 'count and spell')
    -- a group heal in flight from a groupmate healer suppresses it
    L = Ledger.newLedger()
    local h2 = healer('Cleric2', 112, { casting = { spell = 'Word of Vivification', targetId = 112, landsAt = 9000, kind = 'group', startedAt = 0 } })
    for t = 0, 3000, 250 do Ledger.ingest(L, h, t) ; Ledger.ingest(L, h2, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'group heal in flight')
    -- only two hurt: no row
    L = Ledger.newLedger()
    h.targets[203].hp = 95
    for t = 0, 3000, 250 do Ledger.ingest(L, h, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'two hurt is not a missed group heal')
end

-- ---------------------------------------------------------------- interrupted for nothing
do
    local L = Ledger.newLedger()
    local h = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 50) },
        events = { { kind = 'interrupt', spell = 'Remedy', targetId = 201, targetName = 'Rogue', reason = 'target past the heal line', ts = 0 } },
        casting = { spell = 'Remedy', targetId = 202, landsAt = 9000, kind = 'direct', startedAt = 0 } })
    Ledger.ingest(L, h, 0)
    assert(#Ledger.tick(L, 0) == 0, 'not yet')
    h.events = {}
    for t = 250, 1000, 250 do Ledger.ingest(L, h, t) end
    local rows = tickTo(L, 250, 1000)
    assert(kinds(rows) == 'interrupted_nothing', 'target still under the line a second later, got: ' .. kinds(rows))
    -- target recovered: no row
    L = Ledger.newLedger()
    h.events = { { kind = 'interrupt', spell = 'Remedy', targetId = 201, targetName = 'Rogue', reason = 'past', ts = 0 } }
    Ledger.ingest(L, h, 0) ; Ledger.tick(L, 0)
    h.events = {} ; h.targets[201].hp = 100
    for t = 250, 1250, 250 do Ledger.ingest(L, h, t) ; Ledger.tick(L, t) end
    assert(#L.rows == 0, 'a justified interrupt is not a gap')
end

-- ---------------------------------------------------------------- death
do
    local L = Ledger.newLedger()
    local h = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) } })
    Ledger.ingest(L, h, 0) ; Ledger.tick(L, 0)
    Ledger.ingest(L, h, 250) ; Ledger.tick(L, 250)
    h.targets[201].hp = 0 ; h.targets[201].dead = true
    Ledger.ingest(L, h, 500)
    local rows = Ledger.tick(L, 500)
    assert(rows[1] and rows[1].kind == 'death', 'death with a heal available, got: ' .. kinds(rows))
    assert(#rows[1].history >= 2 and rows[1].history[1][2] == 40, 'hp history kept')
    assert(#Ledger.tick(L, 750) == 0 or kinds(Ledger.tick(L, 750)) ~= 'death', 'death rowed once')
end

-- ---------------------------------------------------------------- withheld
do
    local L = Ledger.newLedger()
    local h = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) },
        events = { { kind = 'withheld', spell = 'Remedy', targetId = 201, reason = 'no line', ts = 100 } } })
    Ledger.ingest(L, h, 100)
    local rows = Ledger.tick(L, 100)
    assert(rows[1] and rows[1].kind == 'withheld' and rows[1].reason == 'no line', 'withheld row, got: ' .. kinds(rows))
    L = Ledger.newLedger()
    h.targets[201].hp = 95
    Ledger.ingest(L, h, 100)
    rows = Ledger.tick(L, 100)
    assert(#rows == 0, 'a withheld cast for a healthy target is not a gap')
end

-- ---------------------------------------------------------------- fights and summary
do
    local L = Ledger.newLedger()
    Ledger.fightStart(L, 0)
    local h = healer('Cleric1', 111, { targets = { [201] = target(201, 'Rogue', 40) } })
    for t = 0, 2000, 250 do Ledger.ingest(L, h, t) ; Ledger.tick(L, t) end
    local f = Ledger.fightEnd(L, 2000)
    assert(f.n == 1 and f.byKind.unhealed == 1 and f.byTarget.Rogue == 1, 'fight summary counts')
    assert(f.healers.Cleric1 and f.healers.Cleric1.idleReadyPct == 100, 'idle with a ready heal all fight')
    local n = Ledger.nightSummary(L)
    assert(n.fights == 1 and n.byKind.unhealed == 1, 'night summary')
    Ledger.reset(L)
    assert(#L.rows == 0 and L.fightCount == 0, 'reset')
end

print('heal_ledger_test OK')
