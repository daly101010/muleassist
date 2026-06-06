-- muleassist/charm.lua
-- Phase 6: charm. Ports CharmStuff @3616 / SelectCharmSpell @3758 / AutoCharmTarget @3833 /
-- CharmRecover @3805 / ComputeCharmMaxLevel @3736 as a NON-BLOCKING tick. ENC/DRU only.
-- Charm list entry grammar: "spell|minLevel|maxLevel|mana".
-- Note: charm-fail detection (resist/immune -> CharmRecover) needs CastResult events, which
-- arrive in Phase 7; until then cast.cast reports CAST_SUCCESS and fail_count won't climb.
-- No MQ2Melee.
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local mez   = require('muleassist.mez')
local util  = require('muleassist.util')
local charm = {}

local function num(v, d) return tonumber(v) or d end

-- comma/pipe list -> array of lowercased substrings (CharmDoNotList, name substring match)
local function parse_substr(s)
  if not s or s == '' or s:lower() == 'null' then return nil end
  local t = {}
  for n in (s .. ','):gmatch('([^,]*),') do
    n = n:gsub('^%s+', ''):gsub('%s+$', '')
    if n ~= '' then t[#t + 1] = n:lower() end
  end
  return #t > 0 and t or nil
end
-- comma/pipe list -> set of UPPER short-names (CharmDoNotClass, exact match)
local function parse_class_set(s)
  if not s or s == '' or s:lower() == 'null' then return nil end
  local t = {}
  for n in (s:gsub('|', ',') .. ','):gmatch('([^,]*),') do
    n = n:gsub('%s+', '')
    if n ~= '' then t[n:upper()] = true end
  end
  return next(t) and t or nil
end

local function name_blocked(ch, name)
  if not ch.donot then return false end
  local lc = (name or ''):lower()
  for _, sub in ipairs(ch.donot) do if lc:find(sub, 1, true) then return true end end
  return false
end
local function class_blocked(ch, sp)
  if not ch.donot_class then return false end
  return ch.donot_class[(sp.Class.ShortName() or ''):upper()] == true
end

----------------------------------------------------------------------
-- setup: parse the charm list + do-not lists + ComputeCharmMaxLevel @3736.
----------------------------------------------------------------------
function charm.setup(st)
  local ch = st.charm
  ch.list = {}
  for _, e in ipairs(st.lists.charm or {}) do
    local a = e.args or {}
    ch.list[#ch.list + 1] =
      { spell = e.spell, min = num(a[2], 0), max = num(a[3], 0), mana = num(a[4], 0) }
  end
  ch.donot       = parse_substr(ch.donot_raw)
  ch.donot_class = parse_class_set(ch.donot_class_raw)
  ch.max_affect  = 0
  for _, c in ipairs(ch.list) do
    if util.mqbool(mq.TLO.Spell(c.spell).ID()) then
      local smax = mq.TLO.Spell(c.spell).MaxLevel() or 0
      local em   = (c.max > 0 and c.max < smax) and c.max or smax
      if em > ch.max_affect then ch.max_affect = em end
    end
  end
  Write.Info('charm.setup: on=%s auto=%s entries=%d maxaffect=%d',
    tostring(ch.on), tostring(ch.auto_on), #ch.list, ch.max_affect)
end

----------------------------------------------------------------------
-- SelectCharmSpell @3758: first ready, in-range, affordable charm; legacy SPA-22 fallback.
----------------------------------------------------------------------
function charm.select_spell(st)
  local ch  = st.charm
  ch.spell  = nil
  local tlvl = mq.TLO.Spawn(ch.pet_id).Level() or 0
  for _, c in ipairs(ch.list) do
    if util.mqbool(mq.TLO.Spell(c.spell).ID()) and util.mqbool(mq.TLO.Me.SpellReady(c.spell)()) then
      local smax    = mq.TLO.Spell(c.spell).MaxLevel() or 0
      local effmax  = (c.max > 0 and c.max < smax) and c.max or smax
      local reqmana = (c.mana > 0) and c.mana or (mq.TLO.Spell(c.spell).Mana() or 0)
      if tlvl <= effmax and not (c.min > 0 and tlvl < c.min)
         and (mq.TLO.Me.CurrentMana() or 0) >= reqmana then
        ch.spell = c.spell; return
      end
    end
  end
  if #ch.list == 0 then  -- legacy: first ready SPA-22 gem with mana
    for i = 1, (tonumber(mq.TLO.Me.NumGems()) or 8) do
      local g = mq.TLO.Me.Gem(i)
      if util.mqbool(g.HasSPA(22)()) and (mq.TLO.Me.CurrentMana() or 0) > (g.Mana() or 0) then
        ch.spell = g.Name(); return
      end
    end
  end
end

----------------------------------------------------------------------
-- AutoCharmTarget @3833: nearest XTarget auto-hater NPC that passes the filters.
----------------------------------------------------------------------
function charm.auto_target(st)
  local ch = st.charm
  if not ch.on or not ch.auto_on or util.mqbool(mq.TLO.Me.Pet.ID()) or ch.pet_id ~= 0 then return end
  if not util.is_charmer() then return end
  local best, bestDist = 0, 1e9
  for i = 1, (tonumber(mq.TLO.Me.XTargetSlots()) or 0) do
    local xt = mq.TLO.Me.XTarget(i)
    local id = xt.ID()
    if id and id > 0 and xt.TargetType() == 'Auto Hater' then
      local sp = mq.TLO.Spawn(id)
      local d  = sp.Distance() or 1e9
      if sp.Type() == 'NPC' and d < 200 and not name_blocked(ch, sp.CleanName())
         and not class_blocked(ch, sp)
         and not (#ch.list > 0 and (sp.Level() or 0) > ch.max_affect) then
        if d < bestDist then bestDist, best = d, id end
      end
    end
  end
  if best ~= 0 then
    ch.pet_id = best
    Write.Info('Auto-charm target: %s', mq.TLO.Spawn(best).CleanName() or tostring(best))
  end
end

----------------------------------------------------------------------
-- control casts before recharm: PB-AE stun (SPA21) / short mez (SPA31<=3s) and Tash.
----------------------------------------------------------------------
local function cast_control(st, sp)
  local ch   = st.charm
  local tlvl = sp.Level() or 0
  local n    = tonumber(mq.TLO.Me.NumGems()) or 8
  local need_extra = mq.TLO.Spell(ch.spell).Mana() or 0
  for i = 1, n do
    local g = mq.TLO.Me.Gem(i)
    local pbae = (g.TargetType() or ''):find('PB AE') ~= nil
    local stun = util.mqbool(g.HasSPA(21)())
    local smez = util.mqbool(g.HasSPA(31)()) and (g.Duration.TotalSeconds() or 99) <= 3
    if pbae and (stun or smez) and tlvl <= (g.MaxLevel() or 0) and not util.mqbool(mq.TLO.Me.GemTimer(i)()) then
      if (g.Mana() or 0) + need_extra <= (mq.TLO.Me.CurrentMana() or 0) then
        cast.cast(g.Name(), 'CharmStuff', ch.pet_id); return
      end
    end
  end
end

local function cast_retash(st, sp)
  local ch = st.charm
  for i = 1, (tonumber(mq.TLO.Me.NumGems()) or 8) do
    local g  = mq.TLO.Me.Gem(i)
    local gn = g.Name() or ''
    if gn:find('Tash') and (mq.TLO.Me.CurrentMana() or 0) > (g.Mana() or 0)
       and not util.mqbool(mq.TLO.Me.GemTimer(i)()) and not util.mqbool(sp.CachedBuff(gn).ID()) then
      cast.cast(gn, 'CharmStuff', ch.pet_id); return
    end
  end
end

----------------------------------------------------------------------
-- CharmRecover @3805: lock the area down with the mez engine after repeated fails.
----------------------------------------------------------------------
function charm.recover(st)
  local ch = st.charm
  if (st.mez.on or 0) == 0 then
    Write.Error('Charm failed %dx and Mez is OFF - clearing charm target.', ch.fail_count)
    ch.pet_id, ch.fail_count = 0, 0
    return
  end
  Write.Warn('Charm failed %dx - mezzing to regain control before recharm.', ch.fail_count)
  for _ = 1, 10 do
    mez.tick(st)
    if mez.radar(st) < 2 then break end
    mq.delay(50)
  end
  ch.fail_count = 0
end

----------------------------------------------------------------------
-- CharmStuff @3616: (re)charm the configured charm target.
----------------------------------------------------------------------
function charm.stuff(st)
  local ch = st.charm
  if not util.is_charmer() or util.mqbool(mq.TLO.Me.Pet.ID()) then return end
  if util.mqbool(mq.TLO.Me.Hovering()) then return end
  local sp = mq.TLO.Spawn(ch.pet_id)
  if not sp.ID() or sp.Type() == 'Corpse' or util.mqbool(sp.Master.ID()) then ch.pet_id = 0; return end
  if (sp.Distance() or 999) >= 200 then return end

  local nm = sp.CleanName() or ''
  if name_blocked(ch, nm)  then Write.Info('Not charming %s (do-not-charm name).', nm); ch.pet_id = 0; return end
  if class_blocked(ch, sp) then Write.Info('Not charming %s (class on do-not list).', nm); ch.pet_id = 0; return end

  charm.select_spell(st)
  if not ch.spell or not util.mqbool(mq.TLO.Spell(ch.spell).ID()) then
    Write.Warn('No charm spell ready for %s.', nm); return
  end
  if (mq.TLO.Spell(ch.spell).Mana() or 0) > (mq.TLO.Me.CurrentMana() or 0) then return end
  if not util.mqbool(mq.TLO.Me.Standing()) then
    mq.cmd('/stand'); mq.delay(1000, function() return util.mqbool(mq.TLO.Me.Standing()) end)
    if not util.mqbool(mq.TLO.Me.Standing()) then return end
  end

  if ch.stun_on   then cast_control(st, sp) end
  if ch.retash_on then cast_retash(st, sp) end

  if (sp.Level() or 0) <= (mq.TLO.Spell(ch.spell).MaxLevel() or 0) then
    local res = cast.cast(ch.spell, 'CharmStuff', ch.pet_id)
    if res == 'CAST_SUCCESS' then
      ch.fail_count = 0
    else
      ch.fail_count = ch.fail_count + 1
      if ch.fail_count >= (ch.max_fails or 3) then charm.recover(st) end
    end
  else
    Write.Info("Can't charm %s: %s only affects up to level %d.", nm, ch.spell,
      mq.TLO.Spell(ch.spell).MaxLevel() or 0)
    ch.pet_id = 0
  end
end

----------------------------------------------------------------------
-- tick: driver (macro @1604-1606).
----------------------------------------------------------------------
function charm.tick(st)
  local ch = st.charm
  if not ch.on then return end
  if st.flags.buff_mode or st.flags.zombie_mode then return end
  if not util.is_charmer() then return end

  if ch.pet_id ~= 0 then
    local sp = mq.TLO.Spawn(ch.pet_id)
    if not sp.ID() or sp.Type() == 'Corpse' then ch.pet_id = 0 end
  end
  if ch.auto_on and not util.mqbool(mq.TLO.Me.Pet.ID()) and ch.pet_id == 0 then charm.auto_target(st) end
  if ch.pet_id ~= 0 and mq.TLO.Spawn(ch.pet_id).Type() ~= 'Corpse' then charm.stuff(st) end
end

return charm
