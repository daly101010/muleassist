-- muleassist/cond.lua
-- Evaluate condition strings against the live client. DUAL-MODE:
--   * strings containing "${" use the legacy MQ parser (mq.parse '${If[...]}')
--   * everything else is a native Lua expression evaluated with mq in scope
--     (e.g. "mq.TLO.Target.PctHPs() < 70 and mq.TLO.Me.PctMana() >= 40")
-- Native chunks are compiled once and cached (conditions evaluate every tick).
local mq    = require('mq')
local Write = require('muleassist.Write')
local cond  = {}

-- mq.parse a string containing ${...} tokens, returning the expanded string.
function cond.expand(str)
  if not str or str == '' then return '' end
  return mq.parse(str)
end

-- Sandbox for native conditions: blocks os/io/load/_G/dofile by name. NOTE: mq and the
-- string lib are full references, so write methods (mq.cmd, string.rep) remain reachable --
-- acceptable here since conditions come from the user's own INI, not untrusted input.
local ENV = {
  mq = mq, math = math, string = string,
  tonumber = tonumber, tostring = tostring, ipairs = ipairs, pairs = pairs,
}

local chunk_cache = {}    -- [exprString] = compiled function | false (compile failed)
local logged_err  = {}    -- dedupe error spam by string

local function native_eval(s)
  local fn = chunk_cache[s]
  if fn == nil then
    local compiled, err = load('return (' .. s .. ')', '@cond', 't', ENV)
    if not compiled then
      chunk_cache[s] = false
      if not logged_err[s] then Write.Error('cond compile failed: %s (%s)', s, tostring(err)); logged_err[s] = true end
      return false
    end
    chunk_cache[s] = compiled
    fn = compiled
  elseif fn == false then
    return false
  end
  local ok, res = pcall(fn)
  if not ok then
    if not logged_err[s] then Write.Error('cond runtime error: %s (%s)', s, tostring(res)); logged_err[s] = true end
    return false
  end
  return not not res
end

-- Evaluate a boolean condition string. Empty/NULL/TRUE => true; FALSE => false.
function cond.eval(str)
  if not str then return true end
  local s = str:gsub('^%s*(.-)%s*$', '%1')
  if s == '' then return true end
  local up = s:upper()
  if up == 'TRUE' or up == 'NULL' then return true end
  if up == 'FALSE' then return false end
  if s:find('${', 1, true) then
    return mq.parse('${If[' .. s .. ',1,0]}') == '1'   -- legacy path
  end
  return native_eval(s)                                  -- native Lua path
end

return cond
