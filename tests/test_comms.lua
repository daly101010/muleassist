-- muleassist/tests/test_comms.lua
local config = require('muleassist.config')
local state  = require('muleassist.state')
local comms  = require('muleassist.comms')
local buff   = require('muleassist.buff')
local mq     = require('mq')

local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '')
local FIXTURE = here .. 'fixtures/sample.ini'

local function buff_obj(id, name, seconds)
  return {
    ID = function() return id end,
    Name = function() return name end,
    Duration = {
      TotalSeconds = function() return seconds end,
    },
  }
end

local t = {}

function t.run()
  local cfg = config.load(FIXTURE)
  local st = state.new(cfg)

  comms.init(st)
  comms.broadcast('BUFFS', {
    from = 'Peerone',
    name = 'Peerone',
    spawn_id = 123,
    class = 'CLR',
    zone_id = 99,
    buffs = {
      ['symbol of pinzarn'] = 321,
    },
    songs = {
      ['aura of experience'] = 12,
    },
  })
  comms.shutdown()

  local cached = st.buff.peer_buffs_by_name.peerone
  assert(cached, 'peer buff cache was not populated')
  assert(cached.id == 123, 'peer buff cache lost spawn id')
  assert(cached.class == 'CLR', 'peer class was not cached')
  assert(cached.zone_id == 99, 'peer zone was not cached')
  assert(cached.buffs['symbol of pinzarn'] == 321, 'peer buff duration was not cached')
  assert(cached.songs['aura of experience'] == 12, 'peer song duration was not cached')

  local old_buff = mq.TLO.Me.Buff
  local old_song = mq.TLO.Me.Song
  mq.TLO.Me.Buff = function(i)
    if i == 1 then return buff_obj(1, 'Armor of Experience', 250) end
    return buff_obj(0, '', 0)
  end
  mq.TLO.Me.Song = function(i)
    if i == 1 then return buff_obj(2, 'Aura of Experience', 18) end
    return buff_obj(0, '', 0)
  end

  local recorded
  st.comms = {
    broadcast_buffs = function(_, snapshot)
      recorded = snapshot
    end,
  }
  buff.write_buffs(st, true)
  mq.TLO.Me.Buff = old_buff
  mq.TLO.Me.Song = old_song

  assert(recorded, 'buff snapshot was not broadcast')
  assert(recorded.buffs['armor of experience'] == 250, 'buff snapshot missed regular buff')
  assert(recorded.songs['aura of experience'] == 18, 'buff snapshot missed song window')
  assert(type(recorded.pet_buffs) == 'table', 'buff snapshot should include pet buffs table')
  assert(type(recorded.pet_blocked) == 'table', 'buff snapshot should include pet blocked table')

  print('test_comms: PASS')
  return true
end

return t
