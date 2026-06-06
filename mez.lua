-- muleassist/mez.lua
-- Phase 6a: crowd-control (mez). Ports MezRadar @10134 / DoMezStuff @10221 / MezMobs @10526
-- / MezMobsAE @10476 as a NON-BLOCKING tick. The macro's parallel MezArray[50,3] + per-index
-- MezTimer/MezCount collapse to a Lua list of {id,level,name,timer,count} structs.
-- ENC/BRD/NEC only (NEC can't AE). No merc branches. No MQ2Melee.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local util  = require('muleassist.util')
local mez   = {}

local function is_bard()    return util.class_short() == 'BRD' end
local function can_ae()     local c = util.class_short(); return c == 'BRD' or c == 'ENC' end

local function parse_list(s)
  if not s or s == '' or s:lower() == 'null' then return nil end
  local t = {}
  for n in (s .. ','):gmatch('([^,]*),') do
    n = n:gsub('^%s+', ''):gsub('%s+$', '')
    if n ~= '' then t[n:lower()] = true end
  end
  return next(t) and t or nil
end

local function find_entry(arr, id)
  for _, e in ipairs(arr) do if e.id == id then return e end end
  return nil
end

----------------------------------------------------------------------
-- setup: resolve AE spell/count + immune list from config.
----------------------------------------------------------------------
function mez.setup(st)
  local m = st.mez
  if m.ae_raw and m.ae_raw ~= '' then
    local sp, cnt = m.ae_raw:match('^(.-)|(%d+)$')
    if sp then
      m.ae_spell, m.ae_count = sp, tonumber(cnt) or 0
    else
      m.ae_spell, m.ae_count = m.ae_raw, 0
    end
  end
  m.immune = parse_list(m.immune_raw)
  Write.Info('mez.setup: on=%d spell=%s ae=%s(%d) radius=%d', m.on or 0,
    tostring(m.spell), tostring(m.ae_spell), m.ae_count or 0, m.radius or 0)
end

----------------------------------------------------------------------
-- radar: populate/clean st.mez.array from XTarget auto-haters (MezRadar @10134).
-- Returns mob_count, ae_closest_id, ae_in_radius.
----------------------------------------------------------------------
function mez.radar(st)
  local m = st.mez
  local count, ae_closest, ae_in_radius, closest = 0, 0, 0, 1e9
  local slots = tonumber(mq.TLO.Me.XTargetSlots()) or 0
  for i = 1, slots do
    local xt = mq.TLO.Me.XTarget(i)
    local id = xt.ID()
    if id and id > 0 and xt.TargetType() == 'Auto Hater' then
      local ty = xt.Type()
      if ty == 'NPC' or ty == 'PET' then
        count = count + 1
        local sp = mq.TLO.Spawn(id)
        local dist = sp.Distance() or 1e9
        if can_ae() and dist <= m.radius then
          ae_in_radius = ae_in_radius + 1
          if dist < closest then closest, ae_closest = dist, id end
        end
        if not find_entry(m.array, id) and #m.array < 13 then
          m.array[#m.array + 1] =
            { id = id, level = sp.Level() or 0, name = sp.CleanName() or '', timer = 0, count = 0 }
        end
      end
    end
  end
  -- cull dead/corpse/no-longer-a-threat entries (macro @10173)
  for i = #m.array, 1, -1 do
    local e  = m.array[i]
    local sp = mq.TLO.Spawn(e.id)
    local gone     = not sp.ID() or sp.Type() == 'Corpse'
    local inactive = not util.mqbool(sp.Aggressive()) and not util.mqbool(sp.Mezzed())
    if gone or inactive then table.remove(m.array, i) end
  end
  return count, ae_closest, ae_in_radius
end

----------------------------------------------------------------------
-- per-mob skip conditions (DoMezStuff @10293 loop, mercs/alerts trimmed).
----------------------------------------------------------------------
local function eligible(st, e)
  local m  = st.mez
  local sp = mq.TLO.Spawn(e.id)
  if not sp.ID() then return false end
  local ty = sp.Type()
  if ty == 'Corpse' then return false end
  if ty == 'PET' and (mq.TLO.Spawn(e.id).Master.Type() == 'PC') then return false end  -- friendly pet
  if e.id == st.combat.my_target_id then return false end          -- don't mez the tank's target
  if (sp.Distance3D() or 9999) >= m.radius then return false end
  if (sp.PctHPs() or 100) < m.stop_hp then return false end        -- already being killed
  if e.level > m.max_level or e.level < m.min_level then return false end
  if not util.mqbool(sp.LineOfSight()) then
    if m.move_los and util.nav_loaded() and st.main_assist_id ~= 0 then
      local mad = mq.TLO.Spawn(st.main_assist_id).Distance3D()
      if mad and mad < 150 and not util.mqbool(mq.TLO.Navigation.Active()) then
        mq.cmdf('/nav id %d', st.main_assist_id)                   -- move into LOS; re-eval next tick
      end
    end
    return false
  end
  if (sp.Body.Name() or '') == 'Giant' then return false end       -- giants are unmezzable
  local nm = (e.name or ''):lower()
  if m.immune and m.immune[nm] then return false end
  if m.immune_ids[e.id] then return false end
  if (mq.TLO.Me.CurrentMana() or 0) < (mq.TLO.Spell(m.spell).Mana() or 0) then return false end
  if os.clock() < (e.timer or 0) and util.mqbool(sp.Mezzed()) then return false end  -- still mezzed
  return true
end

----------------------------------------------------------------------
-- single mez (MezMobs @10526) with double-mez protection.
----------------------------------------------------------------------
function mez.cast(st, e)
  local m = st.mez
  if util.mqbool(mq.TLO.Me.Combat()) then
    mq.cmd('/attack off')
    mq.delay(250, function() return not util.mqbool(mq.TLO.Me.Combat()) end)
  end
  if mq.TLO.Target.ID() ~= e.id then
    mq.cmdf('/target id %d', e.id)
    mq.delay(1000, function() return mq.TLO.Target.ID() == e.id end)
    mq.delay(1000, function() return util.mqbool(mq.TLO.Target.BuffsPopulated()) end)
  end
  if mq.TLO.Target.ID() ~= e.id then return end
  -- double-mez protection: already mezzed with healthy remaining duration (macro @10451/10560)
  if util.mqbool(mq.TLO.Target.Mezzed.ID()) then
    local rem  = mq.TLO.Target.Mezzed.Duration.TotalSeconds() or 0
    local full = (mq.TLO.Spell(m.spell).Duration.TotalSeconds() or 0) + (m.mod or 0)
    if rem > full * 0.10 then e.timer = os.clock() + rem * 0.75; return end
  end
  if not util.mqbool(mq.TLO.Target.LineOfSight()) then return end
  if cast.cast(m.spell, 'Mez', e.id) == 'CAST_SUCCESS' then
    e.count = (e.count or 0) + 1
    e.timer = os.clock() + (mq.TLO.Spell(m.spell).Duration.TotalSeconds() or 18) * 0.75
  end
end

----------------------------------------------------------------------
-- AE mez (MezMobsAE @10476): bard twist / enchanter cast; resets all single timers.
----------------------------------------------------------------------
function mez.cast_ae(st, id)
  local m = st.mez
  Write.Info('AE mezzing with %s', tostring(m.ae_spell))
  if is_bard() then
    local gem = mq.TLO.Me.Gem(m.ae_spell)()
    if gem then mq.cmdf('/twist once %d', gem) end
    m.ae_until = os.clock() + 300
  else
    cast.cast(m.ae_spell, 'Mez', id)
    m.ae_until = os.clock() + (mq.TLO.Spell(m.ae_spell).Duration.TotalSeconds() or 18)
  end
  for _, e in ipairs(m.array) do e.timer = 0 end   -- AE re-mezzes everything (macro @10519)
end

----------------------------------------------------------------------
-- tick (DoMezStuff @10221 driver).
----------------------------------------------------------------------
function mez.tick(st)
  local m = st.mez
  if (m.on or 0) == 0 then return end
  if not m.spell or m.spell == '' then return end
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if util.mqbool(mq.TLO.Me.Hovering()) then return end
  if st.pull and st.pull.state ~= 'idle' then return end           -- coexist with pulling
  if not util.is_mezzer() then return end
  -- wait for the group to engage: no assist target yet but the MA exists (macro @10233)
  if not st.combat.my_target_id and st.main_assist_id ~= 0 then return end

  local mob_count, ae_closest, ae_in_radius = mez.radar(st)
  local ma_alive = st.main_assist_id ~= 0 and not util.mqbool(mq.TLO.Spawn(st.main_assist_id).Dead())
  if mob_count < 2 and ma_alive then return end                    -- nothing worth mezzing

  -- AE branch (BRD/ENC only; macro @10287)
  if (m.on == 1 or m.on == 3) and m.ae_spell and m.ae_spell ~= '' and can_ae()
     and (m.ae_count or 0) > 0 and ae_in_radius >= m.ae_count
     and os.clock() >= (m.ae_until or 0) and ae_closest ~= 0 then
    mez.cast_ae(st, ae_closest)
    return
  end

  -- single branch (one mez per tick; the loop continues across ticks)
  if not (m.on == 1 or m.on == 2) then return end
  if not is_bard() and not util.mqbool(mq.TLO.Me.SpellReady(m.spell)()) then return end
  for _, e in ipairs(m.array) do
    if eligible(st, e) then mez.cast(st, e); return end
  end
end

return mez
