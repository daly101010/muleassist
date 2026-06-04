-- muleassist/cond.lua
-- Evaluate MQ TLO condition strings (kept verbatim from the INI) against the live client.
local mq = require('mq')
local cond = {}

-- mq.parse a string containing ${...} tokens, returning the expanded string.
function cond.expand(str)
  if not str or str == '' then return '' end
  return mq.parse(str)
end

-- Evaluate an MQ boolean condition string.
-- Empty / NULL / TRUE => true; FALSE => false; otherwise wrap in ${If[...]} and parse.
function cond.eval(str)
  if not str then return true end
  local s = str:gsub('^%s*(.-)%s*$', '%1')
  if s == '' then return true end
  local up = s:upper()
  if up == 'TRUE' or up == 'NULL' then return true end
  if up == 'FALSE' then return false end
  return mq.parse('${If[' .. s .. ',1,0]}') == '1'
end

return cond
