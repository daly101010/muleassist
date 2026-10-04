-- utils/heal_ledger_store.lua
-- JSON lines writer for the heal gap ledger (ma_healbrain) plus the text report. Pure Lua: the
-- caller hands it the directory and the clock. One file per night: heal-ledger-YYYY-MM-DD.jsonl.

local M = {}

-- ------------------------------------------------------------------ minimal JSON encoder
local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then return false end
        n = n + 1
    end
    return n == #t
end

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode(v, depth)
    depth = depth or 0
    if depth > 12 then return '"<deep>"' end
    local ty = type(v)
    if ty == 'nil' then return 'null' end
    if ty == 'boolean' then return v and 'true' or 'false' end
    if ty == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if math.floor(v) == v then return string.format('%d', v) end
        return string.format('%.3f', v)
    end
    if ty == 'string' then
        return '"' .. v:gsub('[%c"\\]', function(c) return ESC[c] or string.format('\\u%04x', c:byte()) end) .. '"'
    end
    if ty == 'table' then
        local parts = {}
        if isArray(v) then
            for i = 1, #v do parts[i] = encode(v[i], depth + 1) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local val = v[k]
            if val == nil then val = v[tonumber(k)] end
            parts[#parts + 1] = encode(k, depth + 1) .. ':' .. encode(val, depth + 1)
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return '"' .. tostring(v) .. '"'
end
M.encode = encode

-- ------------------------------------------------------------------ file
function M.new(dir, dateFn)
    return { dir = dir, dateFn = dateFn or function() return os.date('%Y-%m-%d') end, file = nil, path = nil, day = nil, written = 0, failed = nil }
end

local function ensureDir(dir)
    local probe = io.open(dir .. '/.probe', 'w')
    if probe then probe:close() os.remove(dir .. '/.probe') return true end
    os.execute('mkdir "' .. dir .. '" 2>nul')
    probe = io.open(dir .. '/.probe', 'w')
    if probe then probe:close() os.remove(dir .. '/.probe') return true end
    return false
end

local function openFor(S)
    local day = S.dateFn()
    if S.file and S.day == day then return S.file end
    if S.file then S.file:close() S.file = nil end
    if not ensureDir(S.dir) then S.failed = 'cannot create ' .. S.dir return nil end
    S.path = string.format('%s/heal-ledger-%s.jsonl', S.dir, day)
    local f, err = io.open(S.path, 'a')
    if not f then S.failed = tostring(err) return nil end
    S.file, S.day, S.failed = f, day, nil
    return f
end

--- Append one record (a row, a fight summary, a note). Returns true when written.
function M.write(S, record)
    local f = openFor(S)
    if not f then return false end
    local ok = pcall(function()
        f:write(encode(record), '\n')
        f:flush()
    end)
    if ok then S.written = S.written + 1 end
    return ok
end

function M.close(S)
    if S.file then S.file:close() S.file = nil end
end

-- ------------------------------------------------------------------ report text
--- The night (or fight) summary as lines of text for /healbrain report.
function M.reportLines(ledger, Ledger)
    local lines = {}
    local night = Ledger.nightSummary(ledger)
    lines[#lines + 1] = string.format('Heal ledger: %d fights, %d gap rows', night.fights, night.rows)
    local kinds = {}
    for _, k in ipairs(Ledger.KINDS) do
        if (night.byKind[k] or 0) > 0 then kinds[#kinds + 1] = string.format('%s %d', k, night.byKind[k]) end
    end
    lines[#lines + 1] = '  by kind: ' .. (#kinds > 0 and table.concat(kinds, ', ') or 'none')
    local targets = {}
    for name, n in pairs(night.byTarget) do targets[#targets + 1] = { name = name, n = n } end
    table.sort(targets, function(a, b) return a.n > b.n end)
    local top = {}
    for i = 1, math.min(6, #targets) do top[#top + 1] = string.format('%s %d', targets[i].name, targets[i].n) end
    lines[#lines + 1] = '  worst: ' .. (#top > 0 and table.concat(top, ', ') or 'none')
    for _, f in ipairs(ledger.fights) do
        local fk = {}
        for _, k in ipairs(Ledger.KINDS) do
            if (f.byKind[k] or 0) > 0 then fk[#fk + 1] = string.format('%s %d', k, f.byKind[k]) end
        end
        local hs = {}
        for name, h in pairs(f.healers) do
            hs[#hs + 1] = string.format('%s casting %d%% idle-with-heal %d%%', name, h.castingPct, h.idleReadyPct)
        end
        table.sort(hs)
        lines[#lines + 1] = string.format('  fight %d (%.0fs): %s%s', f.n, f.durationMs / 1000,
            #fk > 0 and table.concat(fk, ', ') or 'clean', #hs > 0 and (' | ' .. table.concat(hs, '; ')) or '')
    end
    return lines
end

return M
