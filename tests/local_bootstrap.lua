-- muleassist/tests/local_bootstrap.lua
-- Minimal host-side MQ shim for running MuleAssist module tests under LuaJIT.
-- This is intentionally not used by the in-game script runtime.

local repo = 'F:/lua'
package.path = table.concat({
  repo .. '/?.lua',
  repo .. '/?/init.lua',
  repo .. '/muleassist/?.lua',
  repo .. '/muleassist/?/init.lua',
  package.path,
}, ';')

local function noop() end

local function value(v)
  local t = {}
  return setmetatable(t, {
    __call = function()
      return v
    end,
    __index = function()
      return value(nil)
    end,
    __tostring = function()
      return tostring(v)
    end,
  })
end

local function object(map)
  map = map or {}
  return setmetatable(map, {
    __call = function(self)
      return rawget(self, '__value')
    end,
    __index = function()
      return value(nil)
    end,
  })
end

local function spawn(defaults)
  defaults = defaults or {}
  return object({
    ID = value(defaults.ID or 0),
    Type = value(defaults.Type or 'NPC'),
    CleanName = value(defaults.CleanName or 'Test Spawn'),
    Distance = value(defaults.Distance or 0),
    PctHPs = value(defaults.PctHPs or 100),
    LineOfSight = value(defaults.LineOfSight ~= false),
    Master = value(defaults.Master),
    Pet = object({ ID = value(0) }),
  })
end

local function spell(name)
  return object({
    ID = value(nil),
    Name = value(name),
    RankName = value(name),
    MaxLevel = value(0),
    Mana = value(0),
    Duration = object({ TotalSeconds = value(0) }),
    TargetType = value('Single'),
    MyCastTime = value(0),
    RecastTime = value(0),
  })
end

local function window()
  return object({
    Open = value(false),
    Child = function()
      return object({ Enabled = value(false), Text = value('') })
    end,
  })
end

local mq = {
  configDir = 'F:/Config',
  cmd = noop,
  cmdf = noop,
  delay = noop,
  event = noop,
  unevent = noop,
  bind = noop,
  unbind = noop,
  doevents = noop,
  flushevents = noop,
  gettime = function()
    return math.floor(os.clock() * 1000)
  end,
}

function mq.parse(expr)
  if type(expr) ~= 'string' then return expr end
  local if_expr = expr:match('^%${If%[(.*),1,0%]}$')
  if if_expr then
    local expanded = mq.parse(if_expr)
    expanded = expanded:gsub('&&', ' and '):gsub('%|%|', ' or ')
    expanded = expanded:gsub('!%s*([%w_%.]+)', ' not %1')
    local fn = load('return (' .. expanded .. ')')
    if fn then
      local ok, res = pcall(fn)
      if ok then return res and '1' or '0' end
    end
    return '0'
  end
  local out = expr
  out = out:gsub('%${Me%.Level}', '125')
  out = out:gsub('%${Me%.PctMana}', '100')
  out = out:gsub('%${Me%.PctHPs}', '100')
  out = out:gsub('%${Me%.CombatState%.Equal%[Combat%]}', 'FALSE')
  out = out:gsub('%${Group%.Injured%[[^%]]+%]}', '0')
  out = out:gsub('%${Target%.PctHPs}', '100')
  out = out:gsub('%${Target%.PctAggro}', '0')
  out = out:gsub('%${Target%.Named}', 'FALSE')
  out = out:gsub('%${Target%.Beneficial%.ID}', '0')
  out = out:gsub('%${Target%.Slowed%.ID}', '0')
  out = out:gsub('%${[^}]+}', '0')
  return out
end

mq.TLO = {
  Me = object({
    Name = value('LocalTester'),
    CleanName = value('LocalTester'),
    Level = value(125),
    PctMana = value(100),
    PctHPs = value(100),
    CombatState = value('ACTIVE'),
    Invis = value(false),
    Moving = value(false),
    Sitting = value(false),
    Standing = value(true),
    Heading = object({ Degrees = value(0) }),
    Casting = object({ ID = value(0) }),
    Class = object({ ShortName = value('CLR'), Name = value('Cleric') }),
    CurrentMana = value(100000),
    CurrentHPs = value(100000),
    MaxHPs = value(100000),
    MaxMana = value(100000),
    Gem = function() return value(nil) end,
    XTarget = function()
      return object({
        ID = value(0),
        Type = value(''),
        TargetType = value(''),
        PctHPs = value(0),
      })
    end,
    XTargetSlots = value(13),
    Song = function() return object({ ID = value(0), Name = value('') }) end,
    Buff = function() return object({ ID = value(0), Name = value(''), Duration = value(0) }) end,
    Ability = function(name) return object({ ID = value(name and 1 or 0), Name = value(name) }) end,
    AltAbility = function() return object({ ID = value(0) }) end,
  }),
  EverQuest = object({ Server = value('LocalServer') }),
  Target = spawn({ ID = 0 }),
  Group = object({
    __value = 0,
    GroupSize = value(1),
    Members = value(0),
    Member = function() return spawn({ ID = 0, Type = 'PC' }) end,
  }),
  Spawn = function() return spawn({ ID = 0 }) end,
  Spell = spell,
  Window = window,
  Plugin = function() return object({ IsLoaded = value(false) }) end,
  FindItem = function() return object({ ID = value(0), Name = value('') }) end,
  FindItemCount = function() return value(0) end,
  Cursor = object({ ID = value(0) }),
  Navigation = object({ Active = value(false), Paused = value(false) }),
  AdvPath = object({ Waypoints = value(0) }),
  Zone = object({ ID = value(1), Name = value('Local Test Zone') }),
  Macro = object({ Name = value('') }),
  SpawnCount = function() return value(0) end,
  Mercenary = object({ State = value('') }),
}

setmetatable(mq.TLO, {
  __index = function()
    return function()
      return object()
    end
  end,
})

package.preload.mq = function()
  return mq
end

package.preload.ImGui = function()
  return setmetatable({}, {
    __index = function()
      return function()
        return false
      end
    end,
  })
end

package.preload.actors = function()
  local handlers = {}

  local function deliver(mailbox, payload, callback)
    local handler = handlers[mailbox or 'muleassist']
    if not handler then return end
    local message = {
      content = payload,
      sender = {},
    }
    function message:reply(status, reply_payload)
      if callback then callback(status or 0, reply_payload) end
    end
    handler(message)
  end

  local actors = {}
  function actors.register(name, handler)
    handlers[name or ''] = handler
    return {
      send = function(_, address_or_payload, payload, callback)
        if payload == nil then
          deliver(name, address_or_payload, callback)
        else
          deliver((address_or_payload or {}).mailbox or name, payload, callback)
        end
      end,
      unregister = function()
        handlers[name or ''] = nil
      end,
    }
  end

  function actors.send(address, payload, callback)
    deliver((address or {}).mailbox, payload, callback)
  end

  return actors
end

return mq
