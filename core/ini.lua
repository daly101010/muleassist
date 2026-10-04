-- core/ini.lua: INI read/write. The game backend uses mq.TLO.Ini for reads and /ini for writes, exactly
-- as the macro did (so MQ2Mule/MAUI editors see the same file). Tests inject a table backend.
--
-- A held file (Ini.hold .. Ini.release, one LoadSettings round) is read from disk and parsed once, and
-- reads of it are answered from that parse: a LoadSettings round reads ~470 keys, and each mq.TLO.Ini read
-- through a pcall'd closure costs ~30 Lua VM instructions of MQ's per-frame budget (turbo). The parse
-- answers as GetPrivateProfileString (what mq.TLO.Ini calls) does: section and key names match without
-- case; the first section of a name and the first key of a name in it win; names and values are trimmed;
-- a value wrapped in a matching pair of " or ' loses them; ; comment lines are never a key we look up; an
-- empty value or NULL reads as nil (the TLO returns NULL for both). Writes still go through /ini and also
-- land in the held parse, so a read after a write in the same round sees it.
local M = {}

local backend = nil
local lower, byte, sub = string.lower, string.byte, string.sub

local function gameBackend()
    local mq = require('mq')
    local function iniRead(file, section, key) return mq.TLO.Ini(file, section, key)() end
    return {
        read = function(file, section, key)
            local ok, v = pcall(iniRead, file, section, key)
            if not ok or v == nil then return nil end
            v = tostring(v)
            if v == 'NULL' then return nil end
            return v
        end,
        -- present in the file, whatever its value (NULL and empty values included)
        exists = function(file, section, key)
            local ok, v = pcall(function() return mq.TLO.Ini.File(file).Section(section).Key(key).Exists() end)
            return ok and v == true
        end,
        write = function(file, section, key, value)
            mq.cmdf('/ini "%s" "%s" "%s" "%s"', file, section, key, tostring(value))
        end,
        sections = function(file)
            local ok, v = pcall(function() return mq.TLO.Ini(file)() end)
            if not ok or v == nil then return {} end
            local out = {}
            for s in tostring(v):gmatch('[^|]+') do out[#out + 1] = s end
            return out
        end,
        deleteSection = function(file, section)
            mq.cmdf('/ini "%s" "%s" NULL NULL', file, section)
        end,
        -- the file's text, for Ini.hold; nil (no hold: reads stay on the TLO) unless it is the file MQ
        -- itself reads: a relative name with an extension resolves to the config directory first
        -- (GetMacroIni), so only a file found there is held
        text = function(file)
            file = tostring(file or '')
            if file == '' or not file:find('%.[^/\\]*$') then return nil end
            local path = file
            if not (file:find('^%a:') or file:find('^[/\\]')) then path = (mq.configDir or '.') .. '/' .. file end
            local fh = io.open(path, 'rb')
            if not fh then return nil end
            local data = fh:read('*a')
            fh:close()
            return data
        end,
    }
end

function M.use(b) backend = b M.releaseAll() end
function M.backend() backend = backend or gameBackend() return backend end

--- A table backend for tests: data[file][section][key] = value; writes land in the same table.
function M.tableBackend(data)
    data = data or {}
    return {
        data = data,
        read = function(file, section, key)
            local f = data[file]; if not f then return nil end
            local s = f[section]; if not s then return nil end
            local v = s[key]
            if v == nil or tostring(v) == 'NULL' then return nil end
            return tostring(v)
        end,
        exists = function(file, section, key)
            local f = data[file]
            local s = f and f[section]
            return s ~= nil and s[key] ~= nil
        end,
        write = function(file, section, key, value)
            data[file] = data[file] or {}
            data[file][section] = data[file][section] or {}
            data[file][section][key] = tostring(value)
        end,
        sections = function(file)
            local out = {}
            for s in pairs(data[file] or {}) do out[#out + 1] = s end
            table.sort(out)
            return out
        end,
        deleteSection = function(file, section)
            if data[file] then data[file][section] = nil end
        end,
    }
end

-- ---------------------------------------------------------------- the parse
-- Checked against kernel32 GetPrivateProfileStringA (tests/ini_test.lua has the cases):
--   * a section header is a line whose first non-blank is '[': the name runs to the FIRST ']' (or to the
--     end of the line when there is none: '[Heals' is still the Heals section) and is trimmed; anything
--     after the ']' is ignored;
--   * a key line: the name up to the first '=', the value after it, both trimmed; a line whose first
--     non-blank is ';' is a comment; a value in a matching pair of quotes loses them (the %2
--     backreference; an unmatched or mixed quote stays);
--   * lines before the first header, and lines without '=', are never a key.
-- KEYVAL starts at a line's '\n' and stops before the next one (%f), so it only ever matches whole lines.
local HEADER = '()\n[ \t]*%[([^%]\r\n]*)[^\n]*()'
local KEYVAL = '\n[ \t]*([^\n=;%s][^\n=]-)[ \t]*=[ \t]*(["\']?)([^\n]-)%2[ \t\r]*%f[\n]'
local SECS = 1   -- p[SECS]: the case-insensitive index (a number never collides with a section name)

--- Parse INI text into p: p[section as written] = { [key as written] = value } and
--- p[1] = { [lower section] = { v = { [lower key] = value }, x = <that same as-written table> } }, each name's
--- FIRST occurrence only. Values are trimmed and unquoted; '' and NULL stay as they are and read as nil.
--- Cost: one pattern match per line, a lower() and two stores, about 10 VM instructions a line.
function M.parse(text)
    text = '\n' .. tostring(text or '') .. '\n'
    local secs = {}
    local p = { [SECS] = secs }
    local heads, n = {}, 0
    for at, name, after in text:gmatch(HEADER) do
        heads[n + 1], heads[n + 2], heads[n + 3] = at, name, after
        n = n + 3
    end
    for i = 1, n, 3 do
        local name = heads[i + 1]:match('^%s*(.-)%s*$')
        local ls = lower(name)
        local rec = secs[ls]
        if rec == nil then   -- a later section of the same name is never read (the first one wins)
            local v, x = {}, {}
            rec = { v = v, x = x }
            secs[ls] = rec
            -- the body: from the end of the header line to the '\n' that starts the next header line
            for k, _, val in sub(text, heads[i + 2], heads[i + 3] or #text):gmatch(KEYVAL) do
                local lk = lower(k)
                if v[lk] == nil then
                    v[lk] = val
                    x[k] = val
                end
            end
        end
        if p[name] == nil then p[name] = rec.x end
    end
    return p
end

-- value of a key in a parse, case-insensitive (nil: not in the file); the names asked for are trimmed of
-- spaces, as GetPrivateProfileString does
local function lookup(p, section, key)
    local rec = p[SECS][lower(section):match('^ *(.-) *$')]
    if not rec then return nil end
    local v = rec.x[key]
    if v == nil then v = rec.v[lower(key):match('^ *(.-) *$')] end
    return v
end

--- Read one key from a parse as M.read answers it (tests).
function M.get(p, section, key)
    local v = lookup(p, tostring(section), tostring(key))
    if v == nil or v == '' or v == 'NULL' then return nil end
    return v
end
function M.has(p, section, key) return lookup(p, tostring(section), tostring(key)) ~= nil end

-- ---------------------------------------------------------------- holding a file
local held, holds = {}, {}   -- [file] = parse, [file] = hold count

--- Parse `file` now and answer its reads from the parse until the matching release. Nested holds count.
--- Returns true when the file is held (false: the backend has no text for it, reads stay on the backend).
function M.hold(file)
    if held[file] then holds[file] = holds[file] + 1 return true end
    local b = M.backend()
    local text = b.text and b.text(file)
    if not text then return false end
    held[file], holds[file] = M.parse(text), 1
    return true
end

function M.release(file)
    if not held[file] then return end
    holds[file] = holds[file] - 1
    if holds[file] <= 0 then held[file], holds[file] = nil, nil end
end

function M.releaseAll() held, holds = {}, {} end
function M.isHeld(file) return held[file] ~= nil end

-- ---------------------------------------------------------------- API
-- The held path is written out: it runs ~470 times per round, about 12 VM instructions each.
function M.read(file, section, key)
    local p = held[file]
    if p then
        local x = p[section]
        local v = x and x[key]
        if v == nil then v = lookup(p, section, key) end
        if v == nil or v == '' or v == 'NULL' then return nil end
        return v
    end
    return (backend or M.backend()).read(file, section, key)
end

--- Present in the file (any value, NULL and empty included).
function M.exists(file, section, key)
    local p = held[file]
    if p then return lookup(p, section, key) ~= nil end
    local b = M.backend()
    if b.exists then return b.exists(file, section, key) == true end
    return b.read(file, section, key) ~= nil
end

-- the value a held parse keeps for what /ini writes: trimmed, a matching pair of quotes dropped
local function stored(value)
    local v = (tostring(value):gsub('^[ \t]+', ''):gsub('[ \t\r]+$', ''))
    local b = byte(v, 1)
    if (b == 34 or b == 39) and #v > 1 and byte(v, -1) == b then v = sub(v, 2, -2) end
    return v
end

function M.write(file, section, key, value)
    local p = held[file]
    if p then
        -- WritePrivateProfileString replaces the value of the first key of that name (any case), or adds
        -- the key to the first section of that name, or adds the section
        local ls = lower(section)
        local rec = p[SECS][ls]
        if not rec then
            rec = { v = {}, x = {} }
            p[SECS][ls] = rec
        end
        if p[section] == nil then p[section] = rec.x end
        local v, lk = stored(value), lower(key)
        if rec.v[lk] ~= nil then
            for k in pairs(rec.x) do if lower(k) == lk then rec.x[k] = v end end
        end
        rec.v[lk] = v
        rec.x[key] = v
    end
    return M.backend().write(file, section, key, value)
end

function M.sections(file) return M.backend().sections(file) end

function M.deleteSection(file, section)
    local p = held[file]
    if p then
        local ls = lower(section)
        local rec = p[SECS][ls]
        if rec then
            p[SECS][ls] = nil
            for name, x in pairs(p) do if x == rec.x then p[name] = nil end end
        end
    end
    return M.backend().deleteSection(file, section)
end

return M
