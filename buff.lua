-- muleassist/buff.lua
-- Phase 3a: self/group/MA buff maintenance. Ports Sub CheckBuffs @6593 + Sub GroupBuff
-- @6402. Casts via cast.cast (auto-mems, Phase 2c). OOG/auras/pet/INI-coord/regen are
-- Phase 3b (see plan). Combat branches read st.combat.* defensively (nil => no aggro).
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local cond  = require('muleassist.cond')
local buff  = {}

-- Tags handled by other subsystems (skip in the normal buff path) -- Phase 3b.
local SKIP_TAGS = { Aura=true, End=true, Mount=true, Mana=true, Managroup=true,
                    Endgroup=true, Summon=true, Once=true, Remove=true, NoGroup=true }
local CASTER = { CLR=1,DRU=1,SHM=1,BST=1,ENC=1,MAG=1,NEC=1,PAL=1,SHD=1,RNG=1,WIZ=1 }
local MELEE  = { BRD=1,BER=1,BST=1,MNK=1,PAL=1,ROG=1,RNG=1,SHD=1,WAR=1 }

-- Indirection so categorization is testable offline (overridden in tests).
function buff._target_type(name) return (mq.TLO.Spell(name).TargetType() or '') end

-- Sub CheckBuffs @6869-6890: resolve how an entry is cast.
function buff._bufftype(name)
  if name:find('^command:') then return 'command' end
  if (mq.TLO.Me.AltAbility(name).Rank() or 0) > 0 then return 'aa' end
  if mq.TLO.FindItem('=' .. name).ID() then return 'item' end
  if mq.TLO.Spell(name).IsSkill() then return 'ca' end
  return 'spell'
end

-- silverBuff: strip "Rk. N" suffix when rank cap is low (GroupBuff @6415).
local function silver(name)
  if name:find('Rk%. ') and (mq.TLO.Me.SpellRankCap() or 3) < 2 then
    return (name:gsub('%s*Rk%. .*$', ''))
  end
  return name
end

----------------------------------------------------------------------
-- Per-target duration timers (replace Buff{i}GM{j}).
----------------------------------------------------------------------
local function ready(st, i, who)
  local row = st.buff.timers[i]
  return (not row) or (not row[who]) or os.clock() >= row[who]
end
local function arm(st, i, who, name)
  st.buff.timers[i] = st.buff.timers[i] or {}
  local secs = (mq.TLO.Spell(name).Duration.TotalSeconds() or 0) * (st.buff.duration_mod or 1)
  st.buff.timers[i][who] = os.clock() + secs
end

----------------------------------------------------------------------
-- setup: parse + categorize st.lists.buffs into st.buff.entries
----------------------------------------------------------------------
function buff.setup(st)
  local out = {}
  for _, e in ipairs(st.lists.buffs) do
    local raw_name = e.args[1] or e.spell or ''
    local tag      = e.args[2] or ''
    local part3    = e.args[3] or ''
    local part4    = e.args[4] or ''
    local part5    = e.args[5] or ''
    if raw_name ~= '' and raw_name:lower() ~= 'null' then
      local cast_name  = raw_name:gsub('^item:', ''):gsub('^summoned:', '')
      local is_dual    = tag:find('Dual') ~= nil
      local check_name = (is_dual and part3 ~= '') and part3 or cast_name
      out[#out + 1] = {
        index      = e.index,
        cast_name  = cast_name,
        check_name = check_name,
        tag        = tag,
        part3 = part3, part4 = part4, part5 = part5,
        cond       = e.cond,
        is_dual    = is_dual,
        mgb        = tag:lower():find('mgb') ~= nil,
      }
    end
  end
  st.buff.entries = out
  Write.Info('buff.setup: %d buff entries', #out)
end

-- Stub: KissAssist cross-character INI coordination is Phase 3b.
function buff.write_buffs(st) end

----------------------------------------------------------------------
-- CacheBuffs: target a spawn and wait for its buff window to populate so CachedBuff reads
-- are valid (macro Sub CacheBuffs).
----------------------------------------------------------------------
local function cache_buffs(id)
  if mq.TLO.Target.ID() ~= id then
    mq.cmdf('/target id %d', id)
    mq.delay(1000, function() return mq.TLO.Target.ID() == id end)
  end
  mq.delay(3000, function() return mq.TLO.Target.BuffsPopulated() end)
  mq.delay(3000, function() return (mq.TLO.Target.CachedBuffCount() or -1) ~= -1 end)
end

-- ${Group} numeric count. The Lua binding returns the string "FALSE" when solo, so
-- coerce; tonumber("FALSE") -> nil -> 0.
local function group_size() return tonumber(mq.TLO.Group()) or 0 end

local function archetype_ok(tag, short)
  if tag == 'caster' then return CASTER[short] ~= nil end
  if tag == 'Melee'  then return MELEE[short]  ~= nil end
  return true
end

----------------------------------------------------------------------
-- Sub GroupBuff @6402: two passes -- build the needs-buff list, then cast on each.
-- Returns true normally, false to signal "hostiles, abort CheckBuffs" (macro return 100).
----------------------------------------------------------------------
function buff.check_group(st, en, spell_to_cast, buff_sub, spell_range)
  local sb = silver(buff_sub)
  local me_id = mq.TLO.Me.ID()
  local list = {}

  local gn = group_size()
  for j = 0, gn do
    -- combat abort (macro re-runs GetHostilesOnXTarget per member); CombatState fallback
    -- until Phase 4 supplies aggro_target_id. BuffMode overrides.
    if (st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT')
       and not st.flags.buff_mode then return false end
    local gm = mq.TLO.Group.Member(j)
    local id = gm.ID()
    repeat
      if not id then break end
      if (mq.TLO.Spawn(id).Distance() or 9999) >= spell_range then break end
      if (not ready(st, en.index, j))
         and (mq.TLO.Spawn(id).CachedBuff(sb).Duration.TotalSeconds() or 0) > 30 then break end
      if st.buff.cond_on and en.cond and en.cond ~= '' and not cond.eval(en.cond) then break end
      if en.tag == 'Me' and id ~= me_id then break end
      local short = gm.Class.ShortName() or ''
      if (en.tag == 'class' or en.tag == 'dualclass')
         and not (',' .. (en.part5 or '') .. ','):find(',' .. short .. ',', 1, true) then break end
      if not archetype_ok(en.tag, short) then break end
      if (mq.TLO.Me.CurrentMana() or 0) < (mq.TLO.Spell(spell_to_cast).Mana() or 0) then break end
      if en.tag == '!MA' and id == st.main_assist_id then break end
      if en.tag == '!ME' and id == me_id then break end

      if id == me_id then
        if mq.TLO.Me.Buff(sb).ID() or mq.TLO.Me.Song(sb).ID() then break end
        if not mq.TLO.Spell(sb).Stacks() then break end
      else
        cache_buffs(id)
        if (mq.TLO.Spawn(id).CachedBuff(sb).Duration.TotalSeconds() or 0) > 30 then break end
        if not mq.TLO.Spell(sb).StacksSpawn(id)() then break end
      end
      list[#list + 1] = j
    until true
  end

  -- Pass 2: cast on each member who needs it.
  for _, j in ipairs(list) do
    local gm = mq.TLO.Group.Member(j)
    local id = gm.ID()
    local myr  = mq.TLO.Spell(spell_to_cast).MyRange() or 0
    local aer  = mq.TLO.Spell(spell_to_cast).AERange() or 0
    local dist = mq.TLO.Spawn(id).Distance() or 9999
    if id and not ((myr > 0 and dist > myr) or (aer > 0 and dist > aer)) then
      if mq.TLO.Target.ID() ~= id then
        mq.cmdf('/target id %d', id)
        mq.delay(1000, function() return mq.TLO.Target.ID() == id end)
        mq.delay(3000, function() return mq.TLO.Target.BuffsPopulated() end)
        mq.delay(3000, function() return (mq.TLO.Target.CachedBuffCount() or -1) ~= -1 end)
      end
      if not mq.TLO.Target.Buff(sb).ID() then
        mq.delay(3000, function() return not mq.TLO.Me.SpellInCooldown() end)
        if en.mgb and mq.TLO.Me.AltAbilityReady('Mass Group Buff')() then
          mq.cmd('/alt act 35'); mq.delay(100)
        end
        if cast.cast(spell_to_cast, 'Buffs-nomem', id) == 'CAST_SUCCESS' then
          Write.Info('Buffed %s on %s', spell_to_cast, gm.CleanName() or ('member ' .. j))
          arm(st, en.index, j, en.check_name)
          buff.write_buffs(st)
          if (mq.TLO.Spell(spell_to_cast).TargetType() or ''):find('Group v') then return true end
          if group_size() == j then return true end
        end
      end
    end
  end
  return true
end

----------------------------------------------------------------------
-- Sub CheckBuffs MA path @7079-7136. Returns nil (continue) -- never aborts the loop.
----------------------------------------------------------------------
function buff.check_ma(st, en, spell_range)
  local ma = st.main_assist
  local mat_id = st.main_assist_id
  if not ma or not mat_id or mat_id == 0 then return end
  if (mq.TLO.Spawn('=' .. ma).Distance() or 9999) > spell_range then return end
  local sb = silver(en.check_name)
  if st.buff.cond_on and en.cond and en.cond ~= '' and not cond.eval(en.cond) then return end
  cache_buffs(mat_id)
  if not mq.TLO.Spell(sb).StacksSpawn(mat_id)() then return end
  if (mq.TLO.Spawn(mat_id).CachedBuff(sb).Duration() or 0) > 1000 then return end
  if not ready(st, en.index, 7) then return end
  if cast.cast(en.check_name, 'Buffs-nomem', mat_id) == 'CAST_SUCCESS' then
    Write.Info('Buffed %s on >> MA %s <<', en.check_name, ma)
    arm(st, en.index, 7, en.check_name)
    buff.write_buffs(st)
  end
end

----------------------------------------------------------------------
-- Sub CheckBuffs self path @7186-7258 (no-group / Me-tag fallback).
----------------------------------------------------------------------
function buff.check_self(st, en)
  local sb = silver(en.check_name)
  if mq.TLO.Me.Buff(sb).ID() or mq.TLO.Me.Song(sb).ID() then return end
  if not mq.TLO.Spell(sb).Stacks() then return end
  if st.buff.cond_on and en.cond and en.cond ~= '' and not cond.eval(en.cond) then return end
  if not ready(st, en.index, 0) then return end
  if en.mgb and mq.TLO.Me.AltAbilityReady('Tranquil Blessing')() then
    mq.cmd('/alt act 992'); mq.delay(100)
  end
  if cast.cast(en.check_name, 'Buffs-nomem', mq.TLO.Me.ID()) == 'CAST_SUCCESS' then
    Write.Info('Buffed %s on Me', en.check_name)
    arm(st, en.index, 0, en.check_name)
    buff.write_buffs(st)
  end
end

----------------------------------------------------------------------
-- Resolve effective spell range for the cast-name (CheckBuffs @6945-6960).
----------------------------------------------------------------------
local function spell_range(en)
  local n = en.cast_name
  local r
  if en.bufftype == 'item' then
    r = mq.TLO.Spell(mq.TLO.FindItem('=' .. n).Spell()).MyRange()
  else
    r = mq.TLO.Spell(n).MyRange()
    if (mq.TLO.Spell(n).TargetType() or ''):find('Group v') then
      r = mq.TLO.Spell(n).AERange()
    end
  end
  if not r or r == 0 then r = 100 end
  return r
end

----------------------------------------------------------------------
-- Sub CheckBuffs @6593 (3a core). Throttled by st.buff.read_deadline (ReadBuffsTimer).
----------------------------------------------------------------------
function buff.tick(st)
  if not st.flags.buffs_on then return end
  if st.flags.zombie_mode then return end
  if mq.TLO.Me.Hovering() then return end
  if mq.TLO.Me.Invis() and not st.combat.aggro_target_id then return end
  -- ChaseAssist + !BuffWhileChasing (Phase 5 sets st.combat.chasing; nil => not chasing).
  if st.combat.chasing and not st.buff.while_chasing then return end
  -- combat / BuffMode gate (entry + per-iteration below). aggro_target_id is nil until
  -- Phase 4, so fall back to CombatState for real combat protection now.
  local in_combat = st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT'
  if in_combat and not st.flags.buff_mode then return end
  if os.clock() < (st.buff.read_deadline or 0) then return end

  for _, en in ipairs(st.buff.entries) do
    -- per-iteration combat re-check (macro re-runs GetHostilesOnXTarget each pass).
    if (st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT')
       and not st.flags.buff_mode then break end
    en.bufftype = en.bufftype or buff._bufftype(en.cast_name)
    if not SKIP_TAGS[en.tag] and en.bufftype ~= 'command' then
      local rng = spell_range(en)
      local tt  = buff._target_type(en.check_name)
      local handled = false

      if en.tag == 'MA' or en.tag == 'DualMA' then
        buff.check_ma(st, en, rng); handled = true
      end

      if not handled then
        local grp = group_size() > 0
        local self_only = (tt:lower() == 'self')
        if grp and not self_only then
          if buff.check_group(st, en, en.cast_name, en.check_name, rng) == false then
            break  -- hostiles abort
          end
        else
          buff.check_self(st, en)
        end
      end
    end
  end

  -- ReadBuffsTimer: set only when not in combat (macro @7620: !AggroTargetID).
  if st.combat.aggro_target_id == nil and mq.TLO.Me.CombatState() ~= 'COMBAT' then
    st.buff.read_deadline = os.clock() + (st.buff.check_secs or 10)
  end
end

return buff
