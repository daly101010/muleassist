-- Shared fake mq / actors for necrobrain tests. Load with require('tests.fakes')
-- BEFORE requiring any module under test.
local F = { now = 0, vars = {}, spawns = {}, spells = {}, events = {}, sent = {}, subscribers = {} }

local function callable(v) return setmetatable({}, { __call = function() return v end }) end

local mq = {
  gettime = function() return F.now end,
  delay = function(ms) F.now = F.now + (tonumber(ms) or 0) end,
  doevents = function() end,
  event = function(name, pattern, fn) F.events[name] = { pattern = pattern, fn = fn } end,
  unevent = function(name) F.events[name] = nil end,
  cmd = function(s) F.sent[#F.sent + 1] = s end,
  cmdf = function(fmt, ...) F.sent[#F.sent + 1] = string.format(fmt, ...) end,
  configDir = 'F:/Config',
  TLO = {
    Macro = {
      __call = function() return 'muleassist.mac' end,
      Variable = function(name) return callable(F.vars[name]) end,
    },
    Spawn = function(id)
      local s = F.spawns[id]
      if not s then return callable(nil) end
      return setmetatable({
        ID = callable(s.id), CleanName = callable(s.name), PctHPs = callable(s.pct),
        Type = callable(s.type or 'NPC'), Named = callable(s.named or false),
        Body = { Name = callable(s.body or 'Humanoid') },
      }, { __call = function() return s.id end })
    end,
    Spell = function(name)
      return F.spellTLO(name, F.spells[name])
    end,
    _spellTLO = function(name, sp)
      if not sp then return callable(nil) end
      return setmetatable({
        Mana = callable(sp.mana), MyCastTime = callable(sp.castMs),
        Duration = setmetatable({ TotalSeconds = callable(sp.durSec or 0) }, { __call = function() return (sp.durSec or 0) / 6 end }),
        ResistType = callable(sp.resist), TargetType = callable(sp.targetType or 'Single'),
        Base = function(i) return callable(sp.base and sp.base[i] or 0) end,
        Attrib = function(i) return callable(sp.attrib and sp.attrib[i] or 0) end,
        NumEffects = callable(sp.base and #sp.base or 0),
        RecastTime = callable(sp.recastMs or 1500),
        Level = callable(sp.level), RankName = callable(sp.rankName),
      }, { __call = function() return name end })
    end,
    Me = { CleanName = callable('Calbuss'), Class = { ShortName = callable('NEC') }, ID = callable(1),
      CurrentHPs = function() return F.hp or 0 end,
      -- F.aas[name] = { spell = <same shape as F.spells entries>, reuseSec = n, ready = bool }
      AltAbility = function(name)
        local aa = F.aas and F.aas[name]
        if not aa then return callable(nil) end
        return setmetatable({
          ID = callable(aa.id or 1), ReuseTime = callable(aa.reuseSec or 0),
          Spell = F.spellTLO(name .. ' (aa)', aa.spell),
        }, { __call = function() return name end })
      end,
      AltAbilityReady = function(name) local aa = F.aas and F.aas[name]; return callable(aa and aa.ready == true) end,
      -- F.songs / F.buffs[name] = { id = n, ms = remaining, spell = <F.spells shape> }; matched like MQ:
      -- case-insensitive substring of the effect name. F.tloError = true makes every lookup raise.
      Song = function(name) return F.buffTLO(F.songs, name) end,
      Buff = function(name) return F.buffTLO(F.buffs, name) end,
      -- F.gems[name] = gem slot
      Gem = function(name)
        if F.tloError then error('TLO failure') end
        return callable(F.gems and F.gems[name])
      end,
    },
    Zone = { Name = callable('Dranik'), ShortName = callable('dranik') },
    Lua = { Script = function() return { Status = callable('RUNNING') } end },
    EverQuest = { Server = callable('lethar') },
  },
}
setmetatable(mq.TLO.Macro, { __call = function() return 'muleassist.mac' end })
F.spellTLO = mq.TLO._spellTLO

function F.buffTLO(store, name)
  if F.tloError then error('TLO failure') end
  local want = tostring(name):lower()
  for bn, b in pairs(store or {}) do
    if bn:lower():find(want, 1, true) then
      return setmetatable({
        ID = callable(b.id or 1),
        Duration = { Raw = callable(b.ms), TotalSeconds = callable(b.ms and math.floor(b.ms / 1000)) },
        Spell = F.spellTLO(bn, b.spell),
      }, { __call = function() return bn end })
    end
  end
  return setmetatable({
    ID = callable(nil),
    Duration = { Raw = callable(nil), TotalSeconds = callable(nil) },
    Spell = F.spellTLO(name, nil),
  }, { __call = function() return nil end })
end

local actors = {
  register = function(mailbox, fn)
    F.subscribers[mailbox] = fn
    return { send = function(_, payload) F.sent[#F.sent + 1] = payload end, unregister = function() F.subscribers[mailbox] = nil end }
  end,
}
-- deliver a payload to a subscribed mailbox the way MQ does (message() returns content)
function F.deliver(mailbox, payload)
  local fn = F.subscribers[mailbox]
  if fn then fn(setmetatable({ sender = { character = payload.sender } }, { __call = function() return payload end })) end
end

package.preload['mq'] = function() return mq end
package.preload['actors'] = function() return actors end
-- Keep unit-test diagnostics out of the player's real log files.
F.logs = {}
package.preload['necrobrain.logger'] = function()
  return { write = function(fmt, ...)
    F.logs[#F.logs + 1] = string.format(fmt, ...)
  end }
end
_G.printf = _G.printf or function() end
F.mq = mq
return F
