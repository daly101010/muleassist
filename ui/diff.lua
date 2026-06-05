-- muleassist/ui/diff.lua
-- Pure helpers for the live-apply bridge: detect config changes and debounce flushes.
-- No mq/ImGui dependency so it is unit-testable through tests/run.
local diff = {}

local function oneway(a, b)
  for sec, keys in pairs(a) do
    if type(keys) == 'table' then
      local bk = b[sec]
      if type(bk) ~= 'table' then return true end
      for k, v in pairs(keys) do
        if bk[k] ~= v then return true end
      end
    end
  end
  return false
end

-- True if any leaf value differs between two {section = {key = scalar}} tables.
function diff.changed(a, b)
  return oneway(a, b) or oneway(b, a)
end

-- Shallow 2-level copy (sufficient for the config table: section -> key -> scalar).
function diff.snapshot(cfg)
  local out = {}
  for sec, keys in pairs(cfg) do
    if type(keys) == 'table' then
      local t = {}
      for k, v in pairs(keys) do t[k] = v end
      out[sec] = t
    else
      out[sec] = keys
    end
  end
  return out
end

-- Debouncer: due() returns true once, `delay` seconds after the last touch(now).
function diff.debouncer(delay)
  return {
    delay = delay,
    fire_at = nil,
    touch = function(self, now) self.fire_at = now + self.delay end,
    due = function(self, now)
      if self.fire_at and now >= self.fire_at then self.fire_at = nil; return true end
      return false
    end,
  }
end

return diff
