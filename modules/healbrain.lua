-- modules/healbrain.lua: the raid heal gap ledger's brain. With [Heals] HealBrainOn on the MA's box it takes
-- every box's modules/healagent snapshot over actors, runs the gap detectors (healledger/ledger.lua) four times
-- a second, writes every gap row and fight boundary to config/MuleAssist/HealingLogs/heal-ledger-YYYY-MM-DD.jsonl
-- and shows them in the "Raid Heal Ledger" window. Passive: it decides nothing and casts nothing. /healbrain.
-- Idle (no mailbox, no heartbeat) while HealBrainOn is off, this box is not the MA, or after /healbrain stop
-- (until /healbrain start or HealBrainOn off -> on).
-- A port of sidekick-next ma_healbrain.lua (origin/feat/heal-ledger @ 6a94070): the ledger, the window, its
-- tabs and buttons and the /healbrain verbs are kept; the loop is Tick (main loop and the cast engine's
-- tick hooks), the macro reads (Defined('HealStats'), CombatStart) are bot state, the exit logic is gone.
-- Spec: muleassist/docs/superpowers/specs/2026-10-03-luaport-healledger-design.md
local mq = require('mq')
local T = require('core.tlo')
local Log = require('core.log')
local State = require('core.state')
local Ledger = require('healledger.ledger')
local Store = require('healledger.store')
local Paths = require('smartheal.util.paths')
local Agent = require('modules.healagent')
local imOk, imgui = pcall(require, 'ImGui')
if not imOk then imgui = nil end

local M = { name = 'healbrain' }

M.LOOP_MS, M.HEARTBEAT_MS, M.OTHER_BRAIN_MS = 250, 1000, 5000
M.MAX_QUEUE = 2000
M.STORE_RETRY_MS = 30000   -- after a failed directory create or write, retry this rarely
M.BRAIN_MAILBOX = 'heal_brain'
M.AGENT_ADDR = { mailbox = Agent.AGENT_MAILBOX, script = Agent.SCRIPT }
M.BRAIN_ADDR = { mailbox = M.BRAIN_MAILBOX, script = Agent.SCRIPT }

local function log(fmt, ...) Log.info('HealBrain: ' .. fmt, ...) end
local function myName() return T.myName() end
local function now() return mq.gettime() end

local function isMA()
    local me = myName()
    return me ~= '' and tostring(State.mainAssist or ''):lower() == me:lower()
end

function M.storeDir() return (mq.configDir or 'config') .. '/MuleAssist/HealingLogs' end

local windowRegistered = false   -- mq.imgui.init once per script, however often the brain re-activates

-- ---------------------------------------------------------------- state
function M.reset()
    if M.dropbox then pcall(function() M.dropbox:unregister() end) end
    if M.store then pcall(Store.close, M.store) end
    M.dropbox, M.active, M.stopped = nil, false, false
    M.ledger = Ledger.newLedger()
    M.store, M.storeErr, M.storeRetryAt = nil, nil, 0
    M.shownOnce, M.showAfterIdle, M.wasOn = false, nil, false
    M.queue, M.qHead, M.qCount, M.qDropped = {}, 1, 0, 0
    M.otherBrains = {}      -- [name] = last heard (ms)
    M.inCombat = false
    M.nextTick, M.lastBeat = 0, 0
    M.hookErr = nil
    M.UI = {
        open = true, show = false, echo = false, paused = false,
        filterKinds = {}, filterText = '', selected = nil, tab = 'live',
        boxes = {}, boxesFresh = 0, boxesStale = 0, lastTickAt = 0,
        healerGaps = {}, healerGapsAt = 0,   -- [box] = { own = n, candidate = n }, rebuilt once a second
    }
    for _, k in ipairs(Ledger.KINDS) do M.UI.filterKinds[k] = true end
end
M.reset()

-- ---------------------------------------------------------------- actors
--- The heal_brain mailbox handler. Non-yieldable: queue the table, Tick ingests it.
function M.receive(message)
    local ok, c = pcall(function() return message() end)
    if not ok or type(c) ~= 'table' then return end
    if M.qCount >= M.MAX_QUEUE then M.qDropped = M.qDropped + 1 return end
    M.queue[M.qHead + M.qCount] = c
    M.qCount = M.qCount + 1
end

function M:register()
    if self.dropbox then return self.dropbox end
    -- never register from a tick hook: the callback would keep a dead coroutine (core/cast.lua Cast.inHook)
    if not require('core.cast').canRegister() then return nil end
    local ok, actors = pcall(require, 'actors')
    if not ok or not actors then
        if not self.registerWarned then Log.warn('HealBrain: actors unavailable - the ledger hears nothing') end
        self.registerWarned = true
        return nil
    end
    local okReg, box = pcall(actors.register, M.BRAIN_MAILBOX, M.receive)
    if not okReg then
        if not self.registerWarned then Log.warn('HealBrain: actors.register failed: %s', tostring(box)) end
        self.registerWarned = true
        return nil
    end
    self.dropbox = box
    return box
end

local function heartbeat(self)
    local box = self.dropbox
    if not box then return end
    pcall(function()
        box:send(M.AGENT_ADDR, { kind = 'brain', from = myName(), ts = now() })
        -- another brain hears this too and reports itself
        box:send(M.BRAIN_ADDR, { kind = 'brain', from = myName(), ts = now() })
    end)
end

-- ---------------------------------------------------------------- the file
-- The directory is made here (lfs first), never by store.lua's os.execute mkdir (a console window in game):
-- before any write that makes store.lua (re)open its file the directory is probed and made writable here.
-- After a failure the brain stops writing and retries every STORE_RETRY_MS.
function M:storeFail(t, err)
    err = tostring(err or 'write failed')
    if err ~= self.storeErr then Log.warn('HealBrain: heal ledger file: %s - retrying every %ds', err, M.STORE_RETRY_MS / 1000) end
    self.storeErr, self.storeRetryAt = err, t + M.STORE_RETRY_MS
    return false
end

local function probe(dir)
    local p = dir .. '/.probe'
    local f = io.open(p, 'w')
    if not f then return false end
    f:close()
    os.remove(p)
    return true
end

--- dir is writable, made here when it is not
local function ensureWritable(dir)
    if probe(dir) then return true end
    local ok, err = Paths.ensureDir(dir)
    if ok and probe(dir) then return true end
    return false, err or ('cannot write ' .. dir)
end

function M:openStore()
    local t = now()
    if self.storeErr and t < self.storeRetryAt then return false end
    if not self.store then
        local ok, err = ensureWritable(M.storeDir())
        if not ok then return self:storeFail(t, err) end
        self.store = Store.new(M.storeDir())
    end
    return true
end

function M:write(record)
    if not self:openStore() then return false end
    local S, t = self.store, now()
    -- store.lua opens its file (and would mkdir) only with no file open or on a new day: probe first then
    if not S.file or S.day ~= S.dateFn() then
        local ok, err = ensureWritable(S.dir)
        if not ok then return self:storeFail(t, err) end
    end
    if Store.write(S, record) then
        self.storeErr = nil
        return true
    end
    return self:storeFail(t, S.failed)
end

-- ---------------------------------------------------------------- rows out
local function emit(self, row)
    self:write({ type = 'gap', brain = myName(), row = row })
    if self.UI.echo then
        print(string.format('\ay[HealLedger]\ax %s', Ledger.formatRow(row)))
    end
end

function M:fightStart(t)
    Ledger.fightStart(self.ledger, t)
    self:write({ type = 'fight_start', brain = myName(), n = self.ledger.fight.n, at = t, clock = os.date('%H:%M:%S') })
end

function M:fightEnd(t)
    local f = Ledger.fightEnd(self.ledger, t)
    if f then
        self:write({ type = 'fight_end', brain = myName(), summary = f, clock = os.date('%H:%M:%S') })
        local kinds = {}
        for _, k in ipairs(Ledger.KINDS) do if (f.byKind[k] or 0) > 0 then kinds[#kinds + 1] = k .. ' ' .. f.byKind[k] end end
        log('fight %d over (%.0fs): %s', f.n, f.durationMs / 1000, #kinds > 0 and table.concat(kinds, ', ') or 'no gaps')
    end
end

function M:report()
    for _, line in ipairs(Store.reportLines(self.ledger, Ledger)) do print('\ag[HealLedger]\ax ' .. line) end
    -- this box's agent: what it sent and the last brain heartbeat it heard
    local okS, st = pcall(Agent.status, Agent)
    if okS and type(st) == 'table' then
        local heard = st.brain and string.format('%s %.0fs ago', st.brain, (now() - (st.seenAt or 0)) / 1000) or 'never'
        print(string.format('\ag[HealLedger]\ax agent here: %d sent, %d failed, brain heard: %s', st.sent or 0, st.sendFails or 0, heard))
    end
    if self.store and self.store.path then print('\ag[HealLedger]\ax file: ' .. self.store.path) end
end
local function report() M:report() end

-- ---------------------------------------------------------------- window
local KIND_COLORS = {
    unhealed = { 1.0, 0.45, 0.45, 1 }, late = { 1.0, 0.75, 0.4, 1 }, duplicate = { 0.8, 0.6, 1.0, 1 },
    uncured = { 0.5, 1.0, 0.5, 1 }, missed_group = { 0.4, 0.8, 1.0, 1 }, interrupted_nothing = { 1.0, 0.9, 0.4, 1 },
    death = { 1.0, 0.2, 0.2, 1 }, withheld = { 0.8, 0.8, 0.8, 1 },
}

local function rowVisible(r)
    local UI = M.UI
    if not UI.filterKinds[r.kind] then return false end
    if UI.filterText ~= '' then
        -- the text is cached per row and rebuilt only when the row closes (its duration changes)
        if r._text == nil or r._textClosed ~= r.closedAt then
            r._text = (Ledger.formatRow(r)):lower()
            r._textClosed = r.closedAt
        end
        if not r._text:find(UI.filterText:lower(), 1, true) then return false end
    end
    return true
end

local function drawCandidates(r)
    if r.candidates and #r.candidates > 0 then
        imgui.Text('Who could have acted:')
        for _, c in ipairs(r.candidates) do
            local bits = { c.box }
            if c.spell then bits[#bits + 1] = c.spell .. ' ready' end
            if c.dist then bits[#bits + 1] = c.dist .. 'u away' end
            if c.mana then bits[#bits + 1] = c.mana .. '% mana' end
            if c.casting then bits[#bits + 1] = 'casting ' .. c.casting end
            if c.whynot then bits[#bits + 1] = 'last /whynot: ' .. c.whynot end
            imgui.BulletText(table.concat(bits, '  |  '))
        end
    end
    if r.members then imgui.Text('Members under the line: ' .. table.concat(r.members, ', ')) end
    if r.history and #r.history > 0 then
        local hs = {}
        for _, s in ipairs(r.history) do hs[#hs + 1] = tostring(s[2]) .. '%' end
        imgui.Text('HP over the last seconds: ' .. table.concat(hs, ' '))
    end
    if r.reason then imgui.Text('Reason: ' .. tostring(r.reason)) end
end

local function drawLive()
    local UI, ledger = M.UI, M.ledger
    if imgui.Button('Reset') then Ledger.reset(ledger) UI.selected = nil end
    imgui.SameLine()
    if imgui.Button('Report to chat') then report() end
    imgui.SameLine()
    UI.echo = imgui.Checkbox('Echo rows to chat', UI.echo)
    imgui.SameLine()
    UI.paused = imgui.Checkbox('Pause', UI.paused)
    for i, k in ipairs(Ledger.KINDS) do
        if i > 1 then imgui.SameLine() end
        UI.filterKinds[k] = imgui.Checkbox(k, UI.filterKinds[k])
    end
    UI.filterText = imgui.InputText('filter', UI.filterText)
    imgui.Separator()
    if imgui.BeginTable('ledger_rows', 5, ImGuiTableFlags.RowBg + ImGuiTableFlags.Borders + ImGuiTableFlags.ScrollY, 0, 320) then
        imgui.TableSetupColumn('Time', ImGuiTableColumnFlags.WidthFixed, 90)
        imgui.TableSetupColumn('Gap', ImGuiTableColumnFlags.WidthFixed, 130)
        imgui.TableSetupColumn('For', ImGuiTableColumnFlags.WidthFixed, 60)
        imgui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed, 110)
        imgui.TableSetupColumn('What happened', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()
        local shown = 0
        for i = #ledger.rows, 1, -1 do
            local r = ledger.rows[i]
            if rowVisible(r) then
                shown = shown + 1
                if shown > 300 then break end
                imgui.TableNextRow()
                imgui.TableNextColumn()
                local sel = UI.selected == r.id
                local _, clicked = imgui.Selectable(Ledger.clock(r.openedAt) .. '##' .. r.id, sel, ImGuiSelectableFlags.SpanAllColumns)
                if clicked then UI.selected = (not sel) and r.id or nil end
                imgui.TableNextColumn()
                local c = KIND_COLORS[r.kind] or { 1, 1, 1, 1 }
                imgui.TextColored(c[1], c[2], c[3], c[4], r.kind .. (r.closedAt and '' or ' (open)'))
                imgui.TableNextColumn()
                imgui.Text(r.durationMs and r.durationMs > 0 and string.format('%.1fs', r.durationMs / 1000) or '')
                imgui.TableNextColumn()
                imgui.Text(r.target and tostring(r.target.name) or (r.healer or ''))
                imgui.TableNextColumn()
                imgui.Text(r.detail or '')
            end
        end
        imgui.EndTable()
    end
    if UI.selected then
        local row = nil
        for _, r in ipairs(ledger.rows) do if r.id == UI.selected then row = r break end end
        if row then
            imgui.Separator()
            imgui.TextWrapped(Ledger.formatRow(row))
            drawCandidates(row)
            if imgui.Button('Print this row to chat') then print('\ay[HealLedger]\ax ' .. Ledger.formatRow(row)) end
        end
    end
end

local function drawSummary()
    local UI, ledger = M.UI, M.ledger
    local night = Ledger.nightSummary(ledger)
    imgui.Text(string.format('%d fights, %d gap rows%s', night.fights, night.rows, ledger.fight and (', fight ' .. ledger.fight.n .. ' in progress') or ''))
    if imgui.BeginTable('ledger_fights', 4, ImGuiTableFlags.RowBg + ImGuiTableFlags.Borders) then
        imgui.TableSetupColumn('Fight', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Length', ImGuiTableColumnFlags.WidthFixed, 60)
        imgui.TableSetupColumn('Gaps by kind', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableSetupColumn('Healers (casting % / idle with a ready heal %)', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()
        for i = #ledger.fights, 1, -1 do
            local f = ledger.fights[i]
            imgui.TableNextRow()
            imgui.TableNextColumn() imgui.Text(tostring(f.n))
            imgui.TableNextColumn() imgui.Text(string.format('%.0fs', f.durationMs / 1000))
            imgui.TableNextColumn()
            local ks = {}
            for _, k in ipairs(Ledger.KINDS) do if (f.byKind[k] or 0) > 0 then ks[#ks + 1] = k .. ' ' .. f.byKind[k] end end
            imgui.Text(#ks > 0 and table.concat(ks, ', ') or 'clean')
            imgui.TableNextColumn()
            local hs = {}
            for name, h in pairs(f.healers) do hs[#hs + 1] = string.format('%s %d/%d', name, h.castingPct, h.idleReadyPct) end
            table.sort(hs)
            imgui.TextWrapped(table.concat(hs, '  '))
        end
        imgui.EndTable()
    end
    imgui.Separator()
    imgui.Text('Boxes reporting:')
    local names = {}
    for name in pairs(UI.boxes) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local b = UI.boxes[name]
        local age = (mq.gettime() - b.at) / 1000
        if age > 1.0 then
            imgui.TextColored(1, 0.5, 0.5, 1, string.format('  %s  stale %.1fs', name, age))
        else
            imgui.Text(string.format('  %s  %s%s', name, b.role or '', b.casting and ('  casting ' .. b.casting) or ''))
        end
    end
end

-- gap rows per healer: rows it caused (healer field) and rows where it could have acted (candidate)
local function rebuildHealerGaps(t)
    local UI, ledger = M.UI, M.ledger
    if (t - UI.healerGapsAt) < 1000 then return end
    UI.healerGapsAt = t
    local out = {}
    for _, r in ipairs(ledger.rows) do
        if r.healer then
            out[r.healer] = out[r.healer] or { own = 0, candidate = 0 }
            out[r.healer].own = out[r.healer].own + 1
        end
        for _, c in ipairs(r.candidates or {}) do
            out[c.box] = out[c.box] or { own = 0, candidate = 0 }
            out[c.box].candidate = out[c.box].candidate + 1
        end
    end
    UI.healerGaps = out
end

local function pct(v) return v < 100 and (tostring(v) .. '%') or '-' end

local function drawHealers()
    local UI, ledger = M.UI, M.ledger
    local night = Ledger.nightSummary(ledger)
    local kinds = {}
    for _, k in ipairs(Ledger.KINDS) do if (night.byKind[k] or 0) > 0 then kinds[#kinds + 1] = k .. ' ' .. night.byKind[k] end end
    imgui.Text(string.format('Ledger: %d fights, %d gap rows%s', night.fights, night.rows, #kinds > 0 and ('  (' .. table.concat(kinds, ', ') .. ')') or ''))
    imgui.Separator()
    imgui.Text('Each box\'s /healreport counters (1Hz), with the ledger rows it caused and the rows where it could have acted:')
    local names = {}
    for name, box in pairs(ledger.boxes) do
        if box.snap and box.snap.stats and (box.snap.macro and ((box.snap.macro.healsOn or 0) > 0 or (box.snap.macro.curesOn or 0) > 0)) then names[#names + 1] = name end
    end
    table.sort(names)
    local last = ledger.fights[#ledger.fights]
    if imgui.BeginTable('healers', 10, ImGuiTableFlags.RowBg + ImGuiTableFlags.Borders + ImGuiTableFlags.ScrollY + ImGuiTableFlags.Resizable, 0, 300) then
        imgui.TableSetupColumn('Box', ImGuiTableColumnFlags.WidthFixed, 90)
        imgui.TableSetupColumn('Heals (tank/grp/self/pet/xtar)', ImGuiTableColumnFlags.WidthFixed, 170)
        imgui.TableSetupColumn('Group heals (withheld)', ImGuiTableColumnFlags.WidthFixed, 110)
        imgui.TableSetupColumn('Cures (held/unready)', ImGuiTableColumnFlags.WidthFixed, 110)
        imgui.TableSetupColumn('Interrupts', ImGuiTableColumnFlags.WidthFixed, 70)
        imgui.TableSetupColumn('DPS cut', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableSetupColumn('Failed', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableSetupColumn('Lowest (tank/anyone)', ImGuiTableColumnFlags.WidthFixed, 130)
        imgui.TableSetupColumn('Gaps (own/could act)', ImGuiTableColumnFlags.WidthFixed, 110)
        imgui.TableSetupColumn('Last fight cast%/idle%', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()
        local tot = { single = 0, group = 0, groupRange = 0, cure = 0, ints = 0, dpsCut = 0, fail = 0 }
        for _, name in ipairs(names) do
            local st = ledger.boxes[name].snap.stats
            local stale = (mq.gettime() - (ledger.boxes[name].receivedAt or 0)) > 1000
            local g = UI.healerGaps[name] or { own = 0, candidate = 0 }
            local ints = st.intHeal + st.intTap + st.intMob + st.intNPC
            tot.single = tot.single + st.single ; tot.group = tot.group + st.group ; tot.groupRange = tot.groupRange + st.groupRange
            tot.cure = tot.cure + st.cure ; tot.ints = tot.ints + ints ; tot.dpsCut = tot.dpsCut + st.dpsCut ; tot.fail = tot.fail + st.fail
            imgui.TableNextRow()
            imgui.TableNextColumn()
            if stale then imgui.TextColored(1, 0.5, 0.5, 1, name .. ' (stale)') else imgui.Text(name) end
            imgui.TableNextColumn() imgui.Text(string.format('%d (%d/%d/%d/%d/%d)', st.single, st.tank, st.groupT, st.self, st.pet, st.oog))
            imgui.TableNextColumn() imgui.Text(string.format('%d (%d)', st.group, st.groupRange))
            imgui.TableNextColumn() imgui.Text(string.format('%d (%d/%d)', st.cure, st.cureHeld, st.cureUnready))
            imgui.TableNextColumn()
            if ints > 0 then imgui.TextColored(1, 0.8, 0.4, 1, tostring(ints)) else imgui.Text('0') end
            imgui.TableNextColumn() imgui.Text(tostring(st.dpsCut))
            imgui.TableNextColumn()
            if st.fail > 0 then imgui.TextColored(1, 0.6, 0.6, 1, tostring(st.fail)) else imgui.Text('0') end
            imgui.TableNextColumn() imgui.Text(string.format('%s / %s%s', pct(st.tankLow), pct(st.lowPct), (st.lowPct < 100 and st.lowName) and (' ' .. st.lowName) or ''))
            imgui.TableNextColumn()
            if g.own + g.candidate > 0 then imgui.TextColored(1, 0.8, 0.4, 1, string.format('%d / %d', g.own, g.candidate)) else imgui.Text('0 / 0') end
            imgui.TableNextColumn()
            local h = last and last.healers[name]
            imgui.Text(h and string.format('%d%% / %d%%', h.castingPct, h.idleReadyPct) or '-')
        end
        imgui.TableNextRow()
        imgui.TableNextColumn() imgui.Text('all')
        imgui.TableNextColumn() imgui.Text(tostring(tot.single))
        imgui.TableNextColumn() imgui.Text(string.format('%d (%d)', tot.group, tot.groupRange))
        imgui.TableNextColumn() imgui.Text(tostring(tot.cure))
        imgui.TableNextColumn() imgui.Text(tostring(tot.ints))
        imgui.TableNextColumn() imgui.Text(tostring(tot.dpsCut))
        imgui.TableNextColumn() imgui.Text(tostring(tot.fail))
        imgui.TableNextColumn() imgui.Text('')
        imgui.TableNextColumn() imgui.Text(tostring(night.rows))
        imgui.TableNextColumn() imgui.Text('')
        imgui.EndTable()
    end
    if #names == 0 then imgui.Text('no healer or curer box is reporting yet') end
    imgui.Separator()
    for _, name in ipairs(names) do
        local st = ledger.boxes[name].snap.stats
        if st.line and st.line ~= '' then imgui.TextWrapped(st.line) end
    end
    if imgui.Button('Reset every box\'s counters (/healreport reset)') then
        mq.cmd('/healreport reset')          -- this box (/dgze reaches the others, not the sender)
        mq.cmd('/dgze /healreport reset')
        Ledger.reset(ledger)
        UI.selected = nil
    end
    imgui.SameLine()
    if imgui.Button('Broadcast every box\'s line (/healreport all)') then mq.cmd('/healreport all') end
end

local function drawWindow()
    local UI, store = M.UI, M.store
    if not UI.show or not imgui then return end
    imgui.SetNextWindowSize(900, 520, ImGuiCond.FirstUseEver)
    local open, show = imgui.Begin('Raid Heal Ledger', UI.show)
    UI.show = open
    if show then
        local file = (store and store.path) and ('writing ' .. store.path)
            or (M.storeErr and ('file: ' .. M.storeErr)) or (store and store.failed and ('file: ' .. store.failed)) or 'no file yet'
        local status = string.format('brain %s%s | %d boxes fresh, %d stale | %s | %s',
            myName(), M.active and '' or ' (idle)', UI.boxesFresh, UI.boxesStale, M.inCombat and 'in combat' or 'out of combat', file)
        imgui.TextWrapped(status)
        if next(M.otherBrains) then
            local names = {}
            for n in pairs(M.otherBrains) do names[#names + 1] = n end
            imgui.TextColored(1, 0.3, 0.3, 1, 'ANOTHER BRAIN IS RUNNING: ' .. table.concat(names, ', ') .. ' - stop one (/healbrain stop)')
        end
        if imgui.BeginTabBar('ledger_tabs') then
            if imgui.BeginTabItem('Live gaps') then drawLive() imgui.EndTabItem() end
            if imgui.BeginTabItem('Healers') then drawHealers() imgui.EndTabItem() end
            if imgui.BeginTabItem('Fights and boxes') then drawSummary() imgui.EndTabItem() end
            imgui.EndTabBar()
        end
    end
    imgui.End()
end

-- ---------------------------------------------------------------- active / idle
local function registerWindow()
    if windowRegistered or not (mq.imgui and type(mq.imgui.init) == 'function') then return end
    if not require('core.cast').canRegister() then return end   -- same rule as register(); Tick retries (windowWanted)
    windowRegistered = true
    pcall(mq.imgui.init, 'RaidHealLedger', drawWindow)
end

function M:activate()
    if not self:register() then return false end
    self.active = true
    -- nothing queued before this activation is fresh
    self.queue, self.qHead, self.qCount = {}, 1, 0
    self:openStore()
    registerWindow()
    -- the window opens on the first activation; later only when it was open on going idle (hide is respected)
    if not self.shownOnce or self.showAfterIdle then self.UI.show = true end
    self.shownOnce, self.showAfterIdle = true, nil
    log('running as %s (%dms). /healbrain show for the window.', myName(), M.LOOP_MS)
    return true
end

--- Idle: close the fight, the file and the mailbox; stop heartbeats. The ledger's rows stay for the window.
function M:deactivate(t)
    if self.inCombat then self:fightEnd(t) end
    self.inCombat = false
    if self.dropbox then pcall(function() self.dropbox:unregister() end) end
    self.dropbox, self.active = nil, false
    if self.store then pcall(Store.close, self.store) end
    -- snapshots queued before going idle are stale by the time it re-activates
    self.queue, self.qHead, self.qCount = {}, 1, 0
    self.otherBrains = {}
    self.showAfterIdle, self.UI.show = self.UI.show, false
    log('idle')
end

-- ---------------------------------------------------------------- the tick
local function drain(self, t)
    local UI = self.UI
    while self.qCount > 0 do
        local snap = self.queue[self.qHead]
        self.queue[self.qHead] = nil
        self.qHead = self.qHead + 1
        self.qCount = self.qCount - 1
        if snap.kind == 'brain' then
            if tostring(snap.from) ~= myName() then self.otherBrains[tostring(snap.from)] = t end
        elseif not UI.paused then
            if Ledger.ingest(self.ledger, snap, t) then
                UI.boxes[snap.from] = { at = t, role = snap.macro and ((snap.macro.healsOn or 0) > 0 and 'healer' or ((snap.macro.curesOn or 0) > 0 and 'curer' or '')) or (UI.boxes[snap.from] and UI.boxes[snap.from].role),
                    casting = snap.me and snap.me.casting and snap.me.casting.spell or nil }
            end
        end
    end
    if self.qHead > 1000 then
        local nq = {}
        for i = 0, self.qCount - 1 do nq[i + 1] = self.queue[self.qHead + i] end
        self.queue, self.qHead = nq, 1
    end
end

function M:Tick()
    if self.windowWanted and not windowRegistered then registerWindow() end
    local t = now()
    -- HealBrainOn off -> on (/healbrainon) clears /healbrain stop
    local on = State.healBrainOn == true
    if on and not self.wasOn then self.stopped = false end
    self.wasOn = on
    -- HealBrainOn first: a box with the brain off reads no TLO here
    if not on or self.stopped then
        if self.active then self:deactivate(t) end
        return
    end
    -- Me not loaded (zoning): unknown, not "someone else is the MA"
    if myName() == '' then return end
    if not isMA() then
        if self.active then self:deactivate(t) end
        return
    end
    if t < self.nextTick then return end
    -- on a 250 ms grid: the main loop's 100 ms passes must not stretch it to 300
    self.nextTick = self.nextTick + M.LOOP_MS
    if self.nextTick <= t then self.nextTick = t + M.LOOP_MS end
    if not self.active and not self:activate() then return end
    drain(self, t)
    for name, seen in pairs(self.otherBrains) do if (t - seen) > M.OTHER_BRAIN_MS then self.otherBrains[name] = nil end end
    -- fight boundaries: the bot's own combat flag, else this box's combat state
    local combat = State.combatStart == true or T.inCombat()
    if combat and not self.inCombat then self:fightStart(t) end
    if not combat and self.inCombat then self:fightEnd(t) end
    self.inCombat = combat
    if not self.UI.paused then
        local opened = Ledger.tick(self.ledger, t)
        for _, row in ipairs(opened) do emit(self, row) end
    end
    -- freshness for the header
    local fresh, stale = 0, 0
    for _, b in pairs(self.UI.boxes) do if (t - b.at) <= 1000 then fresh = fresh + 1 else stale = stale + 1 end end
    self.UI.boxesFresh, self.UI.boxesStale, self.UI.lastTickAt = fresh, stale, t
    rebuildHealerGaps(t)
    if (t - self.lastBeat) >= M.HEARTBEAT_MS then
        heartbeat(self)
        self.lastBeat = self.lastBeat + M.HEARTBEAT_MS
        if (t - self.lastBeat) >= M.HEARTBEAT_MS then self.lastBeat = t end
    end
end

-- ---------------------------------------------------------------- module hooks
function M:LoadSettings()
    -- the cast engine blocks the main loop (cast bar, cooldowns, memorising) and runs its tick hooks from every
    -- one of those waits: tick from there too (Tick shares the 250 ms throttle and never yields)
    require('core.cast').addTickHook('healbrain', function() M:onCastTick() end)
end

--- Never raises, so it cannot break a cast.
function M:onCastTick()
    local ok, err = pcall(function() self:Tick() end)
    if not ok and tostring(err) ~= self.hookErr then
        self.hookErr = tostring(err)
        pcall(Log.error, 'HealBrain: cast-time tick failed: %s', self.hookErr)
    end
end

function M:Shutdown()
    if self.active then
        self:deactivate(now())
        pcall(report)
    end
    if self.dropbox then pcall(function() self.dropbox:unregister() end) end
    self.dropbox = nil
    local Cast = package.loaded['core.cast']
    if Cast and Cast.removeTickHook then Cast.removeTickHook('healbrain') end
end

-- ---------------------------------------------------------------- commands
M.Binds = {
    ['/healbrain'] = function(self, ...)
        local args = { ... }
        local UI, ledger = self.UI, self.ledger
        local a = tostring(args[1] or ''):lower()
        local b = tostring(args[2] or ''):lower()
        if a == 'show' or a == 'on' then
            self.windowWanted = true   -- a bind runs on a throwaway coroutine: Tick registers the window
            registerWindow()
            UI.show = true
            if not self.active then log('idle (needs HealBrainOn and this box as the MA) - the window shows the last rows') end
        elseif a == 'hide' or a == 'off' then UI.show = false self.showAfterIdle = nil
        elseif a == 'report' then self:report()
        elseif a == 'reset' then Ledger.reset(ledger) UI.selected = nil log('ledger reset')
        elseif a == 'echo' then UI.echo = (b ~= 'off') log('echo %s', UI.echo and 'on' or 'off')
        elseif a == 'pause' then UI.paused = (b ~= 'off') log('%s', UI.paused and 'paused' or 'running')
        elseif a == 'set' then
            -- /healbrain set unhealedMs 2000 (any key of Ledger.DEFAULTS)
            local name, val = tostring(args[2] or ''), tonumber(args[3])
            if ledger.opts[name] ~= nil and val then
                ledger.opts[name] = val
                log('%s = %s', name, tostring(val))
            else
                local keys = {}
                for k in pairs(Ledger.DEFAULTS) do keys[#keys + 1] = k end
                table.sort(keys)
                log('unknown setting %s - one of: %s', name, table.concat(keys, ' '))
            end
        elseif a == 'stop' then
            -- the in-process brain cannot exit: it idles until /healbrain start or HealBrainOn off -> on
            self.stopped = true
            if self.active then self:deactivate(now()) end
            self:report()
        elseif a == 'start' then
            self.stopped = false
            if self.active then log('running')
            elseif not State.healBrainOn then log('still idle: HealBrainOn is off (/healbrainon)')
            elseif not isMA() then log('still idle: this box is not the MA (%s is)', tostring(State.mainAssist or 'nobody'))
            else log('resumed') end
        else
            log('/healbrain show|hide|report|reset|echo on|off|pause on|off|set <name> <ms>|stop|start  (%s, window: %s, echo %s, %d rows, file %s)',
                self.active and 'active' or (self.stopped and 'stopped' or 'idle'), UI.show and 'shown' or 'hidden',
                UI.echo and 'on' or 'off', #ledger.rows, tostring(self.store and self.store.path or 'none'))
        end
    end,
}

return M
