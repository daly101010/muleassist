-- muleassist/buff.lua
-- Phase 3a: self/group/MA buff maintenance. Ports Sub CheckBuffs @6593 + Sub GroupBuff
-- @6402. Casts via cast.cast (auto-mems, Phase 2c). OOG/auras/pet/INI-coord/regen are
-- Phase 3b (see plan). Combat branches read st.combat.* defensively (nil => no aggro).
local mq    = require('mq')
local Write = require('muleassist.Write')
local cast  = require('muleassist.cast')
local cond  = require('muleassist.cond')
local serialize = require('muleassist.serialize')
local buff  = {}

local CASTER = { CLR=1,DRU=1,SHM=1,BST=1,ENC=1,MAG=1,NEC=1,PAL=1,SHD=1,RNG=1,WIZ=1 }
local MELEE  = { BRD=1,BER=1,BST=1,MNK=1,PAL=1,ROG=1,RNG=1,SHD=1,WAR=1 }

-- MQ bool TLO members (Stacks/StacksSpawn/StacksTarget) can come back as the STRINGS
-- "TRUE"/"FALSE"/"NULL" rather than Lua booleans -- and "FALSE" is truthy in Lua, so a
-- naive `if not Spell.StacksSpawn(id)()` never skips a non-stacking buff. Coerce robustly.
local function mqbool(v)
  local t = type(v)
  if t == 'boolean' then return v end
  if t == 'number'  then return v ~= 0 end
  if t == 'string'  then local u = v:upper(); return u == 'TRUE' or u == '1' end
  return false  -- nil/unknown -> treat as "no" (don't stack / not ready), the safe default
end

-- Temporary diagnostics for the buff stacking issue. Toggle with /lua ... or buff.debug.
buff.debug = true
local function dbg(fmt, ...)
  if buff.debug then Write.Info('[buffdbg] ' .. fmt, ...) end
end
-- Show a TLO result's value AND lua type, e.g. "FALSE(string)" or "true(boolean)".
local function vt(v) return tostring(v) .. '(' .. type(v) .. ')' end

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
    if raw_name ~= '' and raw_name:lower() ~= 'null' then
      local entry = serialize.parse_buff(e.raw, e.cond)
      entry.index     = e.index
      entry.cast_name = entry.name   -- buff.lua casts by cast_name
      out[#out + 1] = entry
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

-- Class/archetype gate from an entry's derived archetype + class_list.
local function class_ok(en, short)
  if en.archetype == 'caster' then return CASTER[short] ~= nil end
  if en.archetype == 'melee'  then return MELEE[short]  ~= nil end
  if en.archetype == 'class' then
    return (',' .. (en.class_list or '') .. ','):find(',' .. short .. ',', 1, true) ~= nil
  end
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
    local nm = gm.CleanName() or ('m' .. j)
    repeat
      if not id then break end
      if (mq.TLO.Spawn(id).Distance() or 9999) >= spell_range then dbg('p1 %s/%s skip: out of range', sb, nm); break end
      if (not ready(st, en.index, j))
         and (mq.TLO.Spawn(id).CachedBuff(sb).Duration.TotalSeconds() or 0) > 30 then dbg('p1 %s/%s skip: timer+cached>30', sb, nm); break end
      if st.buff.cond_on and en.cond and en.cond ~= '' and not cond.eval(en.cond) then dbg('p1 %s/%s skip: cond false', sb, nm); break end
      if en.tag == 'Me' and id ~= me_id then break end
      local short = gm.Class.ShortName() or ''
      if not class_ok(en, short) then dbg('p1 %s/%s skip: class/archetype', sb, nm); break end
      if (mq.TLO.Me.CurrentMana() or 0) < (mq.TLO.Spell(spell_to_cast).Mana() or 0) then dbg('p1 %s/%s skip: low mana', sb, nm); break end
      if en.tag == '!MA' and id == st.main_assist_id then break end
      if en.tag == '!ME' and id == me_id then break end

      if id == me_id then
        if mq.TLO.Me.Buff(sb).ID() or mq.TLO.Me.Song(sb).ID() then dbg('p1 %s/ME skip: already on me', sb); break end
        local raw = mq.TLO.Spell(sb).Stacks()
        dbg('p1 %s/ME Stacks=%s -> %s', sb, vt(raw), tostring(mqbool(raw)))
        if not mqbool(raw) then break end
      else
        cache_buffs(id)
        local cd = mq.TLO.Spawn(id).CachedBuff(sb).Duration.TotalSeconds() or 0
        if cd > 30 then dbg('p1 %s/%s skip: cached dur %s>30', sb, nm, tostring(cd)); break end
        local raw = mq.TLO.Spell(sb).StacksSpawn(id)()
        dbg('p1 %s/%s StacksSpawn=%s -> %s (cachedCnt=%s)', sb, nm, vt(raw), tostring(mqbool(raw)),
            tostring(mq.TLO.Spawn(id).CachedBuffCount()))
        if not mqbool(raw) then break end
      end
      dbg('p1 %s/%s ADDED to cast list', sb, nm)
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
      -- Authoritative stacking check now that the member is targeted and their buffs are
      -- populated. Pass-1 StacksSpawn is optimistic before the target's buffs are cached
      -- (returns true), so a buff blocked by a DIFFERENT buff (e.g. the cleric's) would
      -- otherwise get memmed+cast here. StacksTarget reads the live target's buffs.
      local tgtOk = mq.TLO.Target.ID() == id
      local hasBuff = mq.TLO.Target.Buff(sb).ID()
      local stRaw = mq.TLO.Spell(spell_to_cast).StacksTarget()
      dbg('p2 %s/%s targetOk=%s hasBuff=%s StacksTarget=%s -> %s',
          spell_to_cast, (gm.CleanName() or ('m'..j)), tostring(tgtOk), tostring(hasBuff),
          vt(stRaw), tostring(mqbool(stRaw)))
      if tgtOk and not hasBuff and mqbool(stRaw) then
        dbg('p2 %s -> CASTING on %s', spell_to_cast, (gm.CleanName() or ('m'..j)))
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
  local maSpawnRaw = mq.TLO.Spell(sb).StacksSpawn(mat_id)()
  dbg('ma %s StacksSpawn=%s -> %s', sb, vt(maSpawnRaw), tostring(mqbool(maSpawnRaw)))
  if not mqbool(maSpawnRaw) then return end
  -- Authoritative stacking check against the now-targeted MA (StacksSpawn can be optimistic).
  local maTgtRaw = mq.TLO.Spell(en.check_name).StacksTarget()
  dbg('ma %s targetOk=%s StacksTarget=%s -> %s', en.check_name, tostring(mq.TLO.Target.ID() == mat_id),
      vt(maTgtRaw), tostring(mqbool(maTgtRaw)))
  if mq.TLO.Target.ID() == mat_id and not mqbool(maTgtRaw) then return end
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
  if mq.TLO.Me.Buff(sb).ID() or mq.TLO.Me.Song(sb).ID() then dbg('self %s skip: already on me', sb); return end
  local raw = mq.TLO.Spell(sb).Stacks()
  dbg('self %s Stacks=%s -> %s', sb, vt(raw), tostring(mqbool(raw)))
  if not mqbool(raw) then return end
  if st.buff.cond_on and en.cond and en.cond ~= '' and not cond.eval(en.cond) then return end
  if not ready(st, en.index, 0) then return end
  dbg('self %s -> CASTING on me', sb)
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
-- Regen (Sub RegenOther @8280) + mana/endurance loop (Sub CastMana @17335).
----------------------------------------------------------------------
local REGEN_END  = { BER=1,BST=1,MNK=1,PAL=1,RNG=1,ROG=1,SHD=1,WAR=1 }
local REGEN_MANA = { BRD=1,BST=1,CLR=1,DRU=1,ENC=1,MAG=1,NEC=1,PAL=1,RNG=1,SHD=1,SHM=1,WIZ=1 }

-- stat: 'Mana' | 'Endurance'. classes: comma list or nil (-> default by stat).
function buff.regen_other(st, name, stat, pct, classes)
  if mq.TLO.Me.Invis() or mq.TLO.Me.Hovering() then return end
  if st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT' then return end
  local set
  if classes and classes ~= '' and classes ~= '0' and classes:lower() ~= 'null' then
    set = {}; for c in (classes .. ','):gmatch('([^,]*),') do if c ~= '' then set[c] = 1 end end
  else
    set = (stat == 'Endurance') and REGEN_END or REGEN_MANA
  end
  for i = 1, 5 do
    local gm = mq.TLO.Group.Member(i)
    local id, short = gm.ID(), gm.Class.ShortName() or ''
    if id and set[short] then
      local skip = (name:find('Rallying Call', 1, true) and id == st.main_assist_id)
        or (name:find('Dichotomic Psalm', 1, true) and (mq.TLO.Me.CurrentEndurance() or 0) < 6700)
        or ((gm.Class.Name() or ''):lower() == 'bard'
            and (name == 'Dichotomic Psalm' or name == 'Quiet Miracle'))
      if not skip then
        local cur = (stat == 'Endurance') and (gm.PctEndurance() or 100) or (gm.PctMana() or 100)
        if cur <= pct and cur >= 1 then
          if cast.cast(name, 'Regenother', id) == 'CAST_SUCCESS' then
            Write.Info('Casting %s on %s for %s', name, gm.CleanName() or ('m' .. i), stat)
            return
          end
        end
      end
    end
  end
end

-- Sub CastMana @17335: self mana-regen (Mana) + group regen (Managroup/Endgroup). Own slot.
function buff.run_mana(st)
  if mq.TLO.Me.Invis() then return end
  for _, en in ipairs(st.buff.entries) do
    local cond_ok = not (st.buff.cond_on and en.cond and en.cond ~= '' and not cond.eval(en.cond))
    if cond_ok then
      if en.tag == 'Mana' then
        if not mq.TLO.Me.Buff('Revival Sickness').ID() then
          local dich_skip = (en.cast_name == 'Dichotomic Psalm')
            and ((mq.TLO.Me.Class.ShortName() == 'BRD') or (mq.TLO.Me.CurrentEndurance() or 0) < 6600)
          if not dich_skip then
            local mana_floor = tonumber(en.part3) or 0
            local hp_floor   = tonumber(en.part4) or 0
            if (mq.TLO.Me.PctMana() or 100) <= mana_floor and (mq.TLO.Me.PctHPs() or 0) > hp_floor then
              if cast.cast(en.cast_name, 'Buffs', mq.TLO.Me.ID()) == 'CAST_SUCCESS' then
                Write.Info('Casting %s for mana', en.cast_name)
              end
            end
          end
        end
      elseif en.tag == 'Managroup' then
        buff.regen_other(st, en.cast_name, 'Mana', tonumber(en.part3) or 0, en.part5)
      elseif en.tag == 'Endgroup' then
        buff.regen_other(st, en.cast_name, 'Endurance', tonumber(en.part3) or 0, en.part5)
      end
    end
  end
end

----------------------------------------------------------------------
-- End / Summon / Once dispatch (CheckEndurance @8078, SummonStuff @8103, BuffOnce @7957).
----------------------------------------------------------------------
function buff.check_endurance(st, en)
  if mq.TLO.Me.Invis() or mq.TLO.Me.Hovering() then return end
  local epct    = tonumber(en.part3) or 0
  local ehealth = tonumber(en.part4) or 0
  if (mq.TLO.Me.PctEndurance() or 100) > epct then return end
  if (mq.TLO.Me.PctHPs() or 0) <= ehealth then return end
  if cast.cast(en.cast_name, 'CheckEndurance', mq.TLO.Me.ID()) == 'CAST_SUCCESS' then
    Write.Info('Casting %s for endurance', en.cast_name)
  end
end

function buff.summon_stuff(st, en)
  if mq.TLO.Me.Invis() or mq.TLO.Me.Hovering() then return end
  local item = en.part3
  local want = tonumber(en.part4) or 0
  if not item or item == '' then return end
  if (mq.TLO.FindItemCount('=' .. item)() or 0) >= want then return end
  if (mq.TLO.Me.FreeInventory() or 0) == 0 then
    Write.Warn('No inventory room to summon %s', item); return
  end
  if cast.cast(en.cast_name, 'SummonStuff-nomem', mq.TLO.Me.ID()) == 'CAST_SUCCESS' then
    mq.delay(15000, function() return mq.TLO.Cursor.ID() ~= nil end)
    if mq.TLO.Cursor.ID() then mq.cmd('/autoinventory') end
    Write.Info('Summoned %s (%d/%d)', item, mq.TLO.FindItemCount('=' .. item)() or 0, want)
  end
end

function buff.buff_once(st, en)
  if mq.TLO.Me.Invis() or mq.TLO.Me.Hovering() then return end
  if not mqbool(mq.TLO.Spell(en.cast_name).Stacks()) then return end
  if not ready(st, en.index, 0) then return end
  if cast.cast(en.cast_name, 'CheckEndurance', mq.TLO.Me.ID()) == 'CAST_SUCCESS' then
    arm(st, en.index, 0, en.cast_name)
  end
end

----------------------------------------------------------------------
-- Auras (Sub CheckAura @7974).
----------------------------------------------------------------------
local function aura_name(spell)
  local n = spell:gsub('%s*Rk%.%s*I+%s*$', '')
  if spell:find("Disciple's Aura", 1, true) then n = 'Disciples Aura' end
  local cls = (mq.TLO.Me.Class.Name() or ''):lower()
  if cls == 'cleric' and spell:find('Reverent', 1, true) then n = 'Reverent Aura' end
  if spell:find('Mana Reverberation', 1, true) then n = 'Mana Rev.'
  elseif spell:find('Mana Repercussion', 1, true) or spell:find('Mana Reiteration', 1, true) then n = 'Mana Recursion Aura'
  elseif spell:find('Mana Reiterate', 1, true) then n = 'Mana Reiterate Aura'
  elseif spell:find('Mana Resurgence', 1, true) then n = 'Mana Resurgence Aura'
  elseif spell:find('Runic Radiance Aura', 1, true) then n = 'Runic Rad. Aura' end
  return n
end

local function aura_present(name)
  local a1 = mq.TLO.Me.Aura(1).Name() or ''
  local a2 = mq.TLO.Me.Aura(2).Name() or ''
  return a1:find(name, 1, true) ~= nil or a2:find(name, 1, true) ~= nil
end

function buff.check_aura(st, spell)
  if mq.TLO.Me.Invis() or mq.TLO.Me.Hovering() then return end
  local short = mq.TLO.Me.Class.ShortName() or ''
  local name  = aura_name(spell)
  if short == 'MAG' and (spell:find('Arcane Distillect', 1, true) or spell:find('Earthen Strength', 1, true)
       or spell:find("Rathe's Strength", 1, true)) then
    if mq.TLO.Me.Pet.ID() and (mq.TLO.Me.Pet.Distance() or 999) < 175 and aura_present(name) then return end
  elseif aura_present(name) then
    return
  end
  if short == 'BRD' and mq.TLO.Me.Book(spell)() then
    mq.cmd('/stopcast'); mq.cmd('/stoptwist')
    mq.delay(5000, function() return not mq.TLO.Me.BardSongPlaying() end)
    if not mq.TLO.Me.Gem(spell)() then
      if mq.TLO.Cursor.ID() then mq.cmd('/autoinventory') end
      cast.mem_spell(spell, cast.misc_gem, 0, 'CheckAura')
      mq.delay(15000, function() return mq.TLO.Me.SpellReady(spell)() end)
    end
    mq.cmdf('/cast "%s"', spell)
    cast.wait_cast('CheckAura', mq.TLO.Spell(spell).MyCastTime() or 0, spell)
    Write.Info('Cast aura %s', spell); return
  end
  if (short == 'BER' or short == 'MNK' or short == 'ROG' or short == 'WAR')
     and (mq.TLO.Me.CurrentEndurance() or 0) > 500 then
    mq.cmdf('/disc %s', spell)
    cast.wait_cast('CheckAura', 0, spell)
    Write.Info('Cast aura disc %s', spell); return
  end
  if cast.cast(spell, 'CheckAura', mq.TLO.Me.ID()) == 'CAST_SUCCESS' then
    Write.Info('Cast aura %s', spell)
  end
end

----------------------------------------------------------------------
-- Out-of-group buffing (Sub OOGBuff @7633 + CheckBuffs :OOG @7442).
-- In-memory dedup (replaces MuleAssistOOGBuffs.ini); session-scoped.
----------------------------------------------------------------------
local function oog_ready(st, id)
  local d = st.buff.oog_timers[id]; return (not d) or os.clock() >= d
end
local function oog_arm(st, id, name)
  local secs = (mq.TLO.Spell(name).Duration.TotalSeconds() or 0)
  st.buff.oog_timers[id] = os.clock() + math.max(secs, 60)
end

-- One OOG target with class/stack/stick/dedup guards. Returns true on cast success.
local function oog_try(st, en, name, id)
  if not id or id == 0 or id == mq.TLO.Me.ID() then return false end
  local sp = mq.TLO.Spawn(id)
  local dist = sp.Distance() or 9999
  if dist >= (mq.TLO.Spell(name).Range() or 0) and dist >= (mq.TLO.Spell(name).AERange() or 0) then
    return false
  end
  if not class_ok(en, sp.Class.ShortName() or '') then return false end
  if not mqbool(mq.TLO.Spell(name).StacksSpawn(id)()) then return false end
  if (sp.CachedBuff(name).Duration() or 0) > 180 then return false end
  if st.buff.cond_on and en.cond and en.cond ~= '' and not cond.eval(en.cond) then return false end
  if not cast.will_it_stick(name, id) then return false end
  if not oog_ready(st, id) then return false end
  dbg('oog %s -> CASTING on %s', name, sp.CleanName() or tostring(id))
  if cast.cast(name, 'OOGBuffs-nomem', id) == 'CAST_SUCCESS' then
    oog_arm(st, id, name)
    Write.Info('OOG buffed %s on %s', name, sp.CleanName() or tostring(id))
    return true
  end
  return false
end

-- Sub OOGBuff @7633: sweep raid / fellowship / range.
function buff.oog_sweep(st, en, name, kind, brange)
  if not (mq.TLO.Me.Book(name)() or mq.TLO.FindItem('=' .. name).ID()
          or (mq.TLO.Me.AltAbility(name).Rank() or 0) > 0) then return end
  if mq.TLO.Me.Invis() or mq.TLO.Me.Hovering() then return end
  local function aggro()
    return st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT'
  end
  local function in_group(cleanname)
    return cleanname and mq.TLO.Group.Member(cleanname).ID() ~= nil
  end
  if kind == 'raid' then
    for b = 0, (tonumber(mq.TLO.Raid.Members()) or 0) do
      if aggro() and not st.flags.buff_mode then return end
      local rm = mq.TLO.Raid.Member(b)
      if rm.ID() and not in_group(rm.CleanName()) then oog_try(st, en, name, rm.ID()) end
    end
  elseif kind == 'fellowship' then
    for b = 1, (tonumber(mq.TLO.Me.Fellowship.Members()) or 0) do
      if aggro() and not st.flags.buff_mode then return end
      local fname = mq.TLO.Me.Fellowship.Member(b)() or ''
      local fid = mq.TLO.Spawn('pc =' .. fname).ID()
      if fid and not in_group(mq.TLO.Spawn(fid).CleanName()) then oog_try(st, en, name, fid) end
    end
  elseif kind == 'range' then
    local cnt = tonumber(mq.TLO.SpawnCount('pc radius ' .. brange)()) or 0
    if not (st.flags.buff_mode or cnt <= 12) then return end
    for b = 2, cnt do
      if aggro() and not st.flags.buff_mode then return end
      local id = mq.TLO.NearestSpawn(b .. ',pc radius ' .. brange).ID()
      if id and not in_group(mq.TLO.Spawn(id).CleanName()) then oog_try(st, en, name, id) end
    end
  end
end

-- CheckBuffs :OOG @7442: dispatch the entry's structured OOG targets.
function buff.check_oog(st, en, srange)
  local oog = en.oog
  if not oog then return end
  if st.combat.chasing and not st.buff.while_chasing then return end
  local name = en.check_name
  local function combat_abort()
    return (st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT')
           and not st.flags.buff_mode
  end
  local function eligible(id)
    return id and id ~= mq.TLO.Me.ID()
       and not mq.TLO.Group.Member(mq.TLO.Spawn(id).CleanName()).ID()
       and (mq.TLO.Spawn(id).Distance() or 9999) <= srange
  end

  if oog.raid and (tonumber(mq.TLO.Raid.Members()) or 0) > 0 then
    buff.oog_sweep(st, en, name, 'raid', 0)
  end
  if combat_abort() then return end
  if oog.fellowship and (tonumber(mq.TLO.Me.Fellowship.Members()) or 0) > 0 then
    buff.oog_sweep(st, en, name, 'fellowship', 0)
  end
  if combat_abort() then return end
  if oog.range and st.flags.buff_mode then
    buff.oog_sweep(st, en, name, 'range', oog.range)
  end
  if combat_abort() then return end
  for _, slot in ipairs(oog.xtargets or {}) do
    local id = mq.TLO.Me.XTarget(slot).ID()
    if eligible(id) then oog_try(st, en, name, id) end
    if combat_abort() then return end
  end
  for _, nm in ipairs(oog.names or {}) do
    local id = mq.TLO.Spawn('pc =' .. nm).ID()
    if eligible(id) then oog_try(st, en, name, id) end
    if combat_abort() then return end
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

  dbg('tick RUN (CheckBuffsTimer=%s; was throttled until %.1f, now %.1f)',
      tostring(st.buff.check_secs), st.buff.read_deadline or 0, os.clock())

  for _, en in ipairs(st.buff.entries) do
    -- per-iteration combat re-check (macro re-runs GetHostilesOnXTarget each pass).
    if (st.combat.aggro_target_id ~= nil or mq.TLO.Me.CombatState() == 'COMBAT')
       and not st.flags.buff_mode then break end
    en.bufftype = en.bufftype or buff._bufftype(en.cast_name)
    local rng = spell_range(en)

    if en.tag == 'Mana' or en.tag == 'Managroup' or en.tag == 'Endgroup'
       or en.tag == 'Mount' or en.tag == 'NoGroup' then
      -- Mana/regen run in buff.run_mana; Mount/NoGroup not handled in 3a/3b.
    elseif en.tag == 'End' then
      buff.check_endurance(st, en)
    elseif en.tag == 'Summon' then
      buff.summon_stuff(st, en)
    elseif en.tag == 'Once' then
      buff.buff_once(st, en)
    elseif en.tag == 'Remove' then
      if mq.TLO.Me.Buff(en.cast_name).ID() then mq.cmdf('/removebuff %s', en.cast_name) end
    elseif en.tag == 'Aura' then
      buff.check_aura(st, en.cast_name)
    elseif en.bufftype ~= 'command' then
      local tt  = buff._target_type(en.check_name)
      local handled = false

      dbg('dispatch %s tag=%q bufftype=%s tt=%q grp=%s', en.cast_name, en.tag, tostring(en.bufftype),
          tt, tostring(group_size() > 0))

      if en.tag == 'MA' or en.tag == 'DualMA' then
        dbg('-> check_ma %s', en.cast_name)
        buff.check_ma(st, en, rng); handled = true
      end

      if not handled then
        local grp = group_size() > 0
        local self_only = (tt:lower() == 'self')
        dbg('-> %s %s', (grp and not self_only) and 'check_group' or 'check_self', en.cast_name)
        if grp and not self_only then
          if buff.check_group(st, en, en.cast_name, en.check_name, rng) == false then
            break  -- hostiles abort
          end
        else
          buff.check_self(st, en)
        end
      end

      -- Out-of-group targets (named/raid/fellowship/range).
      buff.check_oog(st, en, rng)
    end
  end

  -- ReadBuffsTimer: set only when not in combat (macro @7620: !AggroTargetID).
  if st.combat.aggro_target_id == nil and mq.TLO.Me.CombatState() ~= 'COMBAT' then
    st.buff.read_deadline = os.clock() + (st.buff.check_secs or 10)
  end
end

return buff
