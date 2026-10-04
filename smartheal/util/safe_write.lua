--- Safe file write utility: write to temp then rename for crash safety.
--- Prevents truncated/corrupt files if write fails mid-stream.
---
--- Usage:
---   local safeWrite = require('smartheal.util.safe_write')
---   local ok, err = safeWrite(path, content)

--- Write content to path via temp file + rename.
--- @param path string Target file path
--- @param content string Content to write
--- @return boolean ok
--- @return string|nil err Error message on failure
-- Retry an io.open('w') once after re-ensuring the parent directory. Windows
-- filesystem caches can lag a freshly-created directory: mkdir returns
-- success, but the very next open() in the same process reports ENOENT.
-- Re-issuing ensureDir clears the cached negative and the immediate retry
-- succeeds. Deliberately does NOT use mq.delay — safe_write is called from
-- non-yield-safe contexts (UI draw callbacks, require chains); yielding here
-- would break those callers. If a real persistent failure remains, the
-- second open() returns the real OS error.
local function openWriteWithRetry(tmpPath, parent, Paths)
    local f, openErr = io.open(tmpPath, 'w')
    if f then return f end
    if not openErr or not tostring(openErr):lower():find('no such file') then
        return nil, openErr
    end
    if parent and Paths and Paths.ensureDir then
        pcall(Paths.ensureDir, parent)
    end
    return io.open(tmpPath, 'w')
end

local function safeWrite(path, content)
    path = tostring(path or '')
    local parent = path:match('^(.+)[/\\][^/\\]+$')
    local pathsOk, Paths = pcall(require, 'smartheal.util.paths')
    if not pathsOk then Paths = nil end
    if parent and Paths and Paths.ensureDir then
        -- Treat nil returns as failure the same as an explicit false. A pcall-
        -- failed ensureDir used to fall through and let io.open surface the
        -- generic OS error, hiding the real reason (missing directory).
        local dirOk, dirErr = Paths.ensureDir(parent)
        if not dirOk then
            return false, tostring(dirErr or ('directory_unavailable:' .. parent))
        end
    end

    local tmpPath = path .. '.tmp'
    local bakPath = path .. '.bak'

    local ok, writeErr = pcall(function()
        local f, openErr = openWriteWithRetry(tmpPath, parent, Paths)
        if not f then error(openErr or 'failed to open temp file') end
        f:write(content)
        f:close()
    end)
    if not ok then
        pcall(os.remove, tmpPath)
        return false, tostring(writeErr)
    end

    pcall(os.remove, bakPath)
    local hadExisting = false
    do
        local existing = io.open(path, 'r')
        if existing then
            existing:close()
            hadExisting = true
        end
    end

    if hadExisting then
        local bakOk, bakErr = os.rename(path, bakPath)
        if not bakOk then
            pcall(os.remove, tmpPath)
            return false, tostring(bakErr)
        end
    end

    local renameOk, renameErr = os.rename(tmpPath, path)
    if not renameOk then
        if hadExisting then
            pcall(os.rename, bakPath, path)
        end
        pcall(os.remove, tmpPath)
        return false, tostring(renameErr)
    end

    if hadExisting then
        pcall(os.remove, bakPath)
    end
    return true
end

return safeWrite
