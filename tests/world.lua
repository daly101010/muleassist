-- tests/world.lua: a fake game for the module tests. world(opts) builds the mq.TLO tree the modules read:
-- me, my spells, my buffs, my group, spawns, the target. Everything is a plain table the tests can tweak.
local M = {}

function M.build(mq, o)
    o = o or {}
    local spells = o.spells or {}
    o.spawns = o.spawns or {}
    o.group = o.group or {}
    o.myBuffs = o.myBuffs or {}
    o.target = o.target or { id = 0 }

    local function spellNode(name)
        local s = spells[name]
        if not s then return mq.build({ _ = nil, ID = 0, Name = '' }) end
        return mq.build({
            _ = name, ID = s.id or 100, Name = name, RankName = name,
            MyRange = s.range or 0, AERange = s.aerange or 0, MyCastTime = s.castMs or 3000, Mana = s.mana or 50,
            TargetType = s.tt or 'Single', SpellType = s.st or 'Beneficial', Subcategory = s.sub or '', Category = '',
            Duration = { _ = s.dur or 1200, TotalSeconds = s.dur or 1200 }, RecastTime = { TotalSeconds = s.recast or 0 },
            Level = s.level or 60, EnduranceCost = 0, IsSkill = false, StacksWithDiscs = true, StacksPet = true,
            MaxLevel = s.maxLevel or 150, Beneficial = (s.st or 'Beneficial') ~= 'Detrimental', Range = s.range or 0, MyDuration = { TotalSeconds = s.dur or 0 },
            HasSPA = { _ = function(n) return (s.spa and s.spa[n]) or false end },
            ReagentID = { _ = function() return 0 end }, ReagentCount = { _ = function() return 0 end },
            NoExpendReagentID = { _ = function() return 0 end },
            Stacks = s.stacks ~= false, StacksTarget = s.stacks ~= false,
            StacksSpawn = { _ = function(id) if s.stacksOn then return s.stacksOn[id] ~= false end return s.stacks ~= false end },
            Trigger = { _ = function() return mq.build({ Name = '', ID = 0 }) end },
            WillStack = { _ = function() return 'TRUE' end },
        })
    end

    local function spawnNode(sp)
        if not sp then return mq.build({ _ = nil, ID = 0 }) end
        return mq.build({
            _ = true, ID = sp.id, CleanName = sp.name, Name = sp.name, Type = sp.type or 'PC', Distance = sp.dist or 10, Distance3D = sp.dist or 10,
            Level = sp.level or 60, Class = { ShortName = sp.class or 'WAR' }, PctHPs = sp.hp or 100, LineOfSight = sp.los ~= false,
            X = sp.x or 0, Y = sp.y or 0, Z = sp.z or 0, Heading = { Clock = 12 }, Named = sp.named or false, Animation = sp.anim or 0,
            Speed = sp.speed or 0, MaxRangeTo = sp.reach or 14, AssistName = sp.assistName or '', Dead = sp.type == 'Corpse', PctAggro = sp.aggro or 0,
            Mezzed = { ID = sp.mezzed and 1 or 0 }, Charmed = { ID = sp.charmed and 1 or 0 }, Rooted = { ID = sp.rooted and 1 or 0 },
            Body = { Name = sp.body or 'Humanoid' }, Aggressive = sp.aggressive ~= false, Linkdead = false, FloorZ = sp.z or 0,
            HeadingToLoc = { _ = function() return mq.build({ Degrees = 0 }) end },
            CachedBuffCount = sp.cachedCount or 0, Master = { Type = sp.masterType or '', ID = sp.masterId or 0 }, Owner = { ID = sp.ownerId or 0 }, Guild = sp.guild or '',
            CachedBuff = { _ = function(n)
                local secs = sp.buffs and sp.buffs[n]
                if secs then return mq.build({ ID = 1, Name = n, Duration = { _ = secs, TotalSeconds = secs }, Caster = '', SpellType = 'Beneficial' }) end
                return mq.build({ ID = 0, Name = '', Duration = { _ = 0, TotalSeconds = 0 }, Caster = '', SpellType = '' })
            end },
        })
    end
    local function findSpawn(q)
        if type(q) == 'number' then return spawnNode(o.spawns[q]) end
        q = tostring(q)
        local id = q:match('^id (%d+)')
        if id then
            local sp = o.spawns[tonumber(id)]
            if q:find('alert 5', 1, true) and not (sp and sp.protected) then return spawnNode(nil) end
            return spawnNode(sp)
        end
        local name = q:match('=(.+)$')
        if name then
            for _, sp in pairs(o.spawns) do
                if q:find('^pccorpse') then
                    if sp.type == 'Corpse' and (sp.name == name .. "'s corpse" or sp.owner == name) then return spawnNode(sp) end
                elseif sp.name == name and (not q:find('^pc ') and not q:find('^pc$') or (sp.type or 'PC') == 'PC') and (not q:find('^pet') or sp.type == 'Pet') then return spawnNode(sp) end
            end
            return spawnNode(nil)
        end
        local pcname = q:match('^pccorpse (%S+)$')
        if pcname then
            for _, sp in pairs(o.spawns) do
                if sp.type == 'Corpse' and sp.pc ~= false and (tostring(sp.name):find(pcname, 1, true) or sp.owner == pcname) then return spawnNode(sp) end
            end
            return spawnNode(nil)
        end
        local cname = q:match('^corpse (%S+)')
        if cname then
            for _, sp in pairs(o.spawns) do if sp.type == 'Corpse' and sp.owner == cname then return spawnNode(sp) end end
            return spawnNode(nil)
        end
        if q:find('^group corpse') then
            for _, sp in pairs(o.spawns) do if sp.type == 'Corpse' and sp.group then return spawnNode(sp) end end
            return spawnNode(nil)
        end
        return spawnNode(nil)
    end
    local function memberNode(m)
        if not m then return mq.build({ _ = nil, ID = 0 }) end
        local sp = o.spawns[m.id]
        local function hp() if sp and sp.hp then return sp.hp end return m.hp or 100 end
        local function dist() if sp and sp.dist then return sp.dist end return m.dist or 10 end
        local function ty() if sp and sp.type then return sp.type end return m.type or 'PC' end
        return mq.build({ _ = m.name, ID = m.id, CleanName = m.name, Name = m.name, Distance = { _ = dist }, Distance3D = { _ = dist }, Type = { _ = ty },
            Class = { ShortName = m.class or 'WAR', Name = m.className or 'Warrior' }, PctMana = { _ = function() return m.mana or 100 end }, PctEndurance = m.endurance or 100, PctHPs = { _ = hp },
            Present = { _ = function() return m.present ~= false end }, Mercenary = false, Dead = { _ = function() return m.dead or false end }, Hovering = { _ = function() return m.hovering or false end },
            OtherZone = { _ = function() return m.otherZone or false end }, Sitting = m.sitting or false, Index = m.index or 0, Level = m.level or 60,
            Pet = { ID = m.petId or 0, PctHPs = m.petHp or 100, Distance = m.petDist or 10, CleanName = (m.name or '') .. 's pet' } })
    end
    local me = o.me or {}
    o.xtargets = o.xtargets or {}     -- hater spawn ids, slot order
    o.xtSlots = o.xtSlots or {}       -- other slots: [i] = { type = 'Empty Target' | 'Specific PC', name = '', id = 0 }
    o.marks = o.marks or { group = 0, raid = {} }
    o.raid = o.raid or {}             -- raid members: { name, class, group }
    o.abilities = o.abilities or {}   -- Me.AbilityReady(name)
    local function tid() return rawget(mq.TLO.Target, '__children').ID.__value or 0 end
    local function tspawn() local id = tid() if id == 1 then return { id = 1, name = 'Bob', type = 'PC', dist = 0 } end return o.spawns[id] end
    local function tfield(k, default) return { _ = function() local sp = tspawn() if sp then local v = sp[k] if v == nil then return default end return v end return default end } end
    -- a cast bar: /cast "x" keeps Me.Casting.ID set for the spell's cast time (the stub's delays advance mq.now)
    o.castEndsAt = -1
    local function castingId()
        if (mq.now or 0) < o.castEndsAt and (mq.now or 0) >= (o.castStartsAt or 0) then return 5 end
        if o.pendingHeal then local f = o.pendingHeal o.pendingHeal = nil f() end
        return 0
    end
    local function myBuff(n)
        local b = o.myBuffs[n]
        if b ~= nil then return mq.build({ ID = 1, Name = n, Duration = { TotalSeconds = b } }) end
        return mq.build({ ID = 0, Name = '' })
    end
    local spec = {
        -- as in game: a loaded plugin's TLO is its name, an unloaded one is NULL
        Plugin = { _ = function(n) if n == 'MQ2DanNet' and o.dannet then return 'MQ2DanNet' end if n == 'MQ2Nav' and o.nav then return 'MQ2Nav' end return nil end },
        Me = {
            ID = 1, CleanName = 'Bob', Name = 'Bob', Class = { ShortName = me.class or 'SHM', Name = 'Shaman' }, Level = me.level or 60, PctAggro = me.aggro or 100, Sneaking = false,
            GroupAssistTarget = { ID = { _ = function() return o.maTarget or 0 end } }, Invulnerable = { _ = '', ID = 0 }, Guild = me.guild or '', NumGems = 12, XTargetSlots = 13,
            GroupMarkNPC = { _ = function() return mq.build({ ID = o.marks.group or 0 }) end },
            RaidMarkNPC = { _ = function(n) return mq.build({ ID = o.marks.raid[tonumber(n) or 1] or 0 }) end }, AAPoints = 0,
            Spell = { _ = function(n) return mq.build({ ID = spells[n] and (spells[n].id or 100) or 0 }) end },
            HaveExpansion = { _ = function() return true end },
            Hovering = false, Invis = false, Standing = true, Sitting = false, Moving = false, Feigning = false,
            CombatState = me.combat or 'ACTIVE', CurrentMana = me.curMana or 1000, CurrentEndurance = 1000,
            PctMana = me.mana or 100, PctEndurance = me.endurance or 100, PctHPs = me.hp or 100, MaxMana = 1000, MaxEndurance = 1000,
            Casting = { ID = { _ = castingId } }, CastTimeLeft = 0, SpellInCooldown = false, Mount = { ID = 0 }, CanMount = false, FeetWet = false,
            Pet = { ID = me.petId or 0, CleanName = 'Pet', Height = 1, Combat = false, X = 0, Y = 0, Distance = 5, Stance = 'FOLLOW', Target = { ID = 0, CleanName = '' }, TargetOfTarget = { ID = 0 }, Heading = { Clock = 12 } },
            X = me.x or 0, Y = me.y or 0, FreeInventory = 10, TargetOfTarget = { ID = 0 },
            Fellowship = { Members = 0, Member = { _ = function() return '' end }, CampfireZone = { ID = 0 } },
            FloorZ = 0, Z = 0, Combat = false, Stunned = false, Rooted = { ID = 0 }, Heading = { Clock = 12 },
            Bandolier = { _ = function() return mq.build({ Active = false, Name = '' }) end },
            XTarget = { _ = function(i)
                if not i then return #o.xtargets end
                local sp = o.spawns[o.xtargets[i] or 0]
                if not sp then
                    local slot = o.xtSlots[i]
                    if slot then return mq.build({ TargetType = slot.type, Type = slot.name ~= '' and 'PC' or '', ID = slot.id or 0, Name = slot.name, Named = false, PctAggro = 0, Distance = 0, CleanName = slot.name }) end
                    return mq.build({ TargetType = i <= #o.xtargets + 1 and 'Auto Hater' or 'Empty Target', Type = '', ID = 0, Name = '', Named = false, PctAggro = 0, Distance = 0, CleanName = '' })
                end
                return mq.build({ TargetType = sp.xtType or 'Auto Hater', Type = sp.type or 'NPC', ID = sp.id, Named = sp.named or false, PctAggro = sp.aggro or 0, Distance = sp.dist or 10, Distance3D = sp.dist or 10, CleanName = sp.name, AssistName = sp.assistName or '' })
            end },
            AbilityReady = { _ = function(n) return o.abilities[n] == true end },
            Book = { _ = function(n) return (spells[n] and spells[n].book ~= false) and 5 or 0 end },
            Gem = { _ = function(n)
                if type(n) == 'number' then
                    local nm = o.gems and o.gems[n]
                    if nm and spells[nm] then local node = spellNode(nm) rawget(node, '__children').Name = mq.node(nm) return node end
                    return mq.build({ Name = nm or '', ID = 0 })
                end
                if o.gems then for g, nm in pairs(o.gems) do if nm == n then return g end end end
                return 0
            end },
            SpellReady = { _ = function(n) return spells[n] ~= nil and spells[n].ready ~= false end },
            GemTimer = { _ = function() return 0 end },
            AltAbility = { _ = function(n) return mq.build({ ID = 0, Rank = 0, Spell = { ID = 0, StacksSpawn = { _ = function() return nil end }, Stacks = nil } }) end },
            AltAbilityReady = { _ = function() return false end },
            CombatAbility = { _ = function() return 0 end }, CombatAbilityReady = { _ = function() return false end }, ActiveDisc = { ID = 0 },
            ItemReady = { _ = function() return false end }, SkillCap = { _ = function() return 0 end }, PctAggro = me.aggro or 100,
            Buff = { _ = myBuff }, Song = { _ = function() return mq.build({ ID = 0 }) end }, AutoFire = false, State = 'STAND', TributeActive = false, RangedReady = true,
            BlockedBuff = { _ = function() return mq.build({ Name = '' }) end },
            PetBuff = { _ = function(n) return (me.petBuffs and me.petBuffs[n]) and 1 or 0 end },
            Aura = { _ = function() return mq.build({ Name = '' }) end },
            Inventory = { _ = function() return mq.build({ Name = '', Power = 0 }) end },
        },
        Target = {
            ID = o.target.id or 0, BuffsPopulated = true, Distance = tfield('dist', 0), Distance3D = tfield('dist', 0), Type = tfield('type', 'PC'),
            CleanName = tfield('name', ''), PctHPs = tfield('hp', 100), CanSplashLand = true, LineOfSight = { _ = function() local sp = tspawn() return sp ~= nil and sp.los ~= false end },
            Mezzed = { ID = { _ = function() local sp = tspawn() return (sp and sp.mezzed) and 1 or 0 end } },
            Charmed = { ID = { _ = function() local sp = tspawn() return (sp and sp.charmed) and 1 or 0 end } },
            Rooted = { ID = { _ = function() local sp = tspawn() return (sp and sp.rooted) and 1 or 0 end } },
            Tashed = { ID = { _ = function() local sp = tspawn() return (sp and sp.buffs and sp.buffs['Tashed']) and 1 or 0 end } },
            BuffDuration = { _ = function(n) return mq.build({ TotalSeconds = M.targetBuffs(mq, o)[n] or 0 }) end },
            Buff = { _ = function(n) local s = M.targetBuffs(mq, o)[n]; if s then return mq.build({ ID = 1, Duration = { TotalSeconds = s }, Caster = '' }) end return mq.build({ ID = 0, Caster = '' }) end },
        },
        Spell = { _ = spellNode },
        FindItem = { _ = function() return mq.build({ ID = 0, Clicky = { Spell = { ID = 0, StacksSpawn = { _ = function() return nil end } } }, Spell = { ID = 0, Name = '', Stacks = nil }, Timer = 0 }) end },
        FindItemCount = { _ = function() return 0 end },
        Spawn = { _ = findSpawn },
        SpawnCount = { _ = function(q)
            q = tostring(q or '')
            local radius = tonumber(q:match('radius (%d+)')) or 99999
            local n = 0
            for _, sp in pairs(o.spawns) do
                local ok
                if q:find('pccorpse') then ok = sp.type == 'Corpse' and sp.pc ~= false and (not q:match('^pccorpse (%a%S*)') or sp.owner == q:match('^pccorpse (%S+)'))
                elseif q:find('corpse') then ok = sp.type == 'Corpse' and (not q:find('group') or sp.group)
                elseif q:match('^pc%f[%W]') then ok = (sp.type or 'PC') == 'PC'
                else ok = (sp.type or 'PC') == 'NPC' and sp.los ~= false end
                if ok and (sp.dist or 10) <= radius then n = n + 1 end
            end
            return n
        end },
        Group = { Members = o.groupN or 0, AnyoneMissing = false, MainAssist = { ID = { _ = function() return o.groupMA or 0 end }, Name = { _ = function() return o.groupMAName or '' end }, Sitting = false }, Puller = { Name = '' },
            Leader = { _ = function() return o.leader or '' end },
            AvgHPs = { _ = function()
                local n, sum = 0, 0
                for i = 0, (o.groupN or 0) do local m = o.group[i] if m then local sp = o.spawns[m.id] n = n + 1 sum = sum + ((sp and sp.hp) or m.hp or 100) end end
                if n == 0 then return 100 end return math.floor(sum / n)
            end },
            Injured = { _ = function(pct)
                local n = 0
                for i = 0, (o.groupN or 0) do local m = o.group[i] if m then local sp = o.spawns[m.id] if ((sp and sp.hp) or m.hp or 100) < (tonumber(pct) or 0) then n = n + 1 end end end
                return n
            end },
            Member = { _ = function(i)
                if type(i) == 'number' then return memberNode(o.group[i]) end
                for _, m in pairs(o.group) do if m.name == i then return memberNode(m) end end
                return mq.build({ ID = 0, Index = 0 })
            end } },
        NearestSpawn = { _ = function(j, q)
            local list = {}
            if type(j) == 'string' and q == nil then q, j = j, 1 end
            q = tostring(q or '')
            local radius = tonumber(q:match('radius (%d+)')) or 99999
            local quoted = q:match('"(.-)"') or q:match('=(.+)$')
            if quoted then quoted = quoted:gsub('^=', '') end
            for _, sp in pairs(o.spawns) do
                local okType = not quoted or sp.name == quoted
                if q:find('pccorpse') then okType = okType and (sp.type == 'Corpse' and sp.pc ~= false)
                elseif q:find('corpse') then okType = okType and sp.type == 'Corpse'
                elseif q:match('^pc%f[%W]') then okType = okType and (sp.type or 'PC') == 'PC'
                elseif q:find('npc') then okType = okType and sp.type == 'NPC' end
                if okType and (sp.dist or 10) <= radius then list[#list + 1] = sp end
            end
            table.sort(list, function(a, b) return (a.dist or 10) < (b.dist or 10) end)
            return spawnNode(list[tonumber(j) or 1])
        end },
        Raid = { Members = { _ = function() return #o.raid end }, MainAssist = { _ = function() return '' end },
            Member = { _ = function(i)
                local r = nil
                if type(i) == 'number' then r = o.raid[i] else for _, m in ipairs(o.raid) do if m.name == i then r = m end end end
                if not r then return mq.build({ ID = 0, Name = '', Level = 0, Class = { ShortName = '' }, Group = 0 }) end
                return mq.build({ _ = r.name, ID = r.id or 0, Name = r.name, Level = r.level or 60, Class = { ShortName = r.class or 'WAR' }, Group = r.group or 1 })
            end } },
        Zone = { ID = 100, ShortName = 'commonlands', Indoor = false },
        Cursor = { ID = 0, Name = '' }, Macro = { RunTime = 500, Name = '' },
        Time = { Day = '1', Hour = '1', SecondsSinceMidnight = 1000 },
        Navigation = { Active = false, Velocity = 0, Paused = false, MeshLoaded = o.nav or false, PathExists = { _ = function() return o.nav or false end },
            PathLength = { _ = function(q) local x, y = tostring(q):match('locxyz (%-?%d+) (%-?%d+)') if x then return math.sqrt(tonumber(x) ^ 2 + tonumber(y) ^ 2) end return 0 end } },
        Stick = { Status = 'OFF', Active = false, StickTarget = { _ = 0, Type = '' } }, AdvPath = { State = false, Following = false },
        MoveTo = { Moving = false }, InvSlot = { _ = function() return mq.build({ ID = 0, Item = { Name = '' } }) end },
        Window = { _ = function() return mq.build({ Open = false }) end },
        DanNet = { Peers = { _ = function() return o.peers or '' end }, _ = function(peer) return mq.build({
            Q = { _ = function() return mq.build({ _ = nil, Received = 0 }) end },
            Observe = { _ = function(q) local v = o.observed and o.observed[tostring(peer) .. '|' .. tostring(q)] return mq.build({ _ = v }) end },
        }) end },
        MacroQuest = { GameState = 'INGAME' }, EverQuest = { Server = 'srv' },
        Ini = { _ = function() return nil end },
    }
    mq.TLO = mq.build(spec)
    -- command side effects the modules rely on: /target id N, /target clear, /memspell gem "name"
    local function apply(s)
        local id = s:match('/target id (%d+)')
        if id then rawget(mq.TLO.Target, '__children').ID.__value = tonumber(id) end
        if s:find('/target clear', 1, true) then rawget(mq.TLO.Target, '__children').ID.__value = 0 end
        local cast = s:match('^/cast "(.+)"')
        if cast and spells[cast] and spells[cast].noCast then cast = nil end
        if cast then
            local late = (spells[cast] and spells[cast].lateMs) or 0
            o.castStartsAt = (mq.now or 0) + late
            o.castEndsAt = (mq.now or 0) + late + ((spells[cast] and spells[cast].castMs) or 3000)
            if spells[cast] and spells[cast].stuck then o.castEndsAt = math.huge end
            -- the buff lands on the target at once
            local tid = rawget(mq.TLO.Target, '__children').ID.__value or 0
            local dur = (spells[cast] and spells[cast].dur) or 1200
            -- a heal raises the target's hp (group heals: everyone in the group)
            local heal = spells[cast] and spells[cast].heal
            if heal then
                local function mend(id) local sp = o.spawns[id] if sp then sp.hp = math.min(100, (sp.hp or 100) + heal) end end
                local tt = (spells[cast].tt or 'Single'):lower()
                -- lands when the cast bar completes (the interrupt rules read the live hp during the cast)
                o.pendingHeal = function()
                    if tt:find('group v') then for _, m in pairs(o.group) do mend(m.id) end else mend(tid == 0 and 1 or tid) end
                end
            end
            if dur > 0 then
                local function land(id)
                    if id == 1 then o.myBuffs[cast] = dur end
                    if id > 0 and o.spawns[id] then
                        o.spawns[id].buffs = o.spawns[id].buffs or {}
                        o.spawns[id].buffs[cast] = dur
                    end
                end
                if tid == 0 then land(1) else land(tid) end
                local tt = (spells[cast] and spells[cast].tt) or 'Single'
                if tt:lower():find('group v') then
                    for _, m in pairs(o.group) do land(m.id) end
                end
            end
        end
        if s == '/stopcast' then o.castEndsAt = -1 end
        if cast and spells[cast] and spells[cast].pet then rawget(mq.TLO.Me.Pet, '__children').ID.__value = spells[cast].pet end
        if cast and spells[cast] and spells[cast].pulls then
            local tid = rawget(mq.TLO.Target, '__children').ID.__value or 0
            if tid > 0 then o.xtargets[#o.xtargets + 1] = tid end
        end
        if s:find('/attack on', 1, true) then rawget(mq.TLO.Me, '__children').Combat.__value = true end
        if s:find('/attack off', 1, true) then rawget(mq.TLO.Me, '__children').Combat.__value = false end
        local stickId = s:match('^/stick .-id (%d+)')
        if stickId then
            rawget(mq.TLO.Stick, '__children').Status.__value = 'ON'
            rawget(mq.TLO.Stick, '__children').Active.__value = true
            rawget(mq.TLO.Stick, '__children').StickTarget.__value = tonumber(stickId)
        end
        if s:find('/stick off', 1, true) then
            rawget(mq.TLO.Stick, '__children').Status.__value = 'OFF'
            rawget(mq.TLO.Stick, '__children').Active.__value = false
            rawget(mq.TLO.Stick, '__children').StickTarget.__value = 0
        end
        local xs, xname = s:match('^/xtarget set (%d+) (%S+)')
        if xs then
            if xname == 'autohater' then o.xtSlots[tonumber(xs)] = nil
            else
                local id = 0
                for _, sp in pairs(o.spawns) do if sp.name == xname then id = sp.id end end
                o.xtSlots[tonumber(xs)] = { type = 'Specific PC', name = xname, id = id }
            end
        end
        local xr = s:match('^/xtarget remove (%d+)')
        if xr then o.xtSlots[tonumber(xr)] = { type = 'Empty Target', name = '' } end
        local petAtk = s:match('^/pet attack (%d+)')
        if petAtk then
            rawget(mq.TLO.Me.Pet, '__children').Combat.__value = true
            rawget(mq.TLO.Me.Pet.Target, '__children').ID.__value = tonumber(petAtk)
        end
        if s == '/pet back off' or s == '/pet back' then
            rawget(mq.TLO.Me.Pet, '__children').Combat.__value = false
            rawget(mq.TLO.Me.Pet.Target, '__children').ID.__value = 0
        end
        local gem, name = s:match('^/memspell (%d+) "(.+)"')
        if gem then o.gems = o.gems or {} o.gems[tonumber(gem)] = name end
        if s:find('^/nav id') or s:find('^/nav loc') then
            rawget(mq.TLO.Navigation, '__children').Active.__value = true
            rawget(mq.TLO.Navigation, '__children').Velocity.__value = 10
        end
        if s == '/nav stop' then
            rawget(mq.TLO.Navigation, '__children').Active.__value = false
            rawget(mq.TLO.Navigation, '__children').Velocity.__value = 0
        end
        if s == '/sit' then rawget(mq.TLO.Me, '__children').Sitting.__value = true rawget(mq.TLO.Me, '__children').Standing.__value = false end
        if s == '/stand' then rawget(mq.TLO.Me, '__children').Sitting.__value = false rawget(mq.TLO.Me, '__children').Standing.__value = true end
    end
    mq.cmd = function(s) mq.cmds[#mq.cmds + 1] = s apply(s) end
    mq.cmdf = function(fmt, ...) local s = string.format(fmt, ...) mq.cmds[#mq.cmds + 1] = s apply(s) end
    return o
end

--- Set a leaf of the current TLO tree: World.set(mq, 'Me.Invis', true)
function M.set(mq, path, value)
    local node = mq.TLO
    local parts = {}
    for p in path:gmatch('[^.]+') do parts[#parts + 1] = p end
    for i = 1, #parts - 1 do node = rawget(node, '__children')[parts[i]] end
    local leaf = rawget(node, '__children')[parts[#parts]]
    if leaf then leaf.__value = value else rawget(node, '__children')[parts[#parts]] = mq.node(value) end
end

--- The buff window of whatever is targeted right now (me = my buffs).
function M.targetBuffs(mq, o)
    local tid = rawget(mq.TLO.Target, '__children').ID.__value or 0
    if tid == 1 then return o.myBuffs end
    if tid > 0 and o.spawns[tid] then return o.spawns[tid].buffs or {} end
    return o.target.buffs or {}
end

--- Count the captured commands that match a Lua pattern.
function M.count(mq, pattern)
    local n = 0
    for _, c in ipairs(mq.cmds) do if c:find(pattern) then n = n + 1 end end
    return n
end

return M
