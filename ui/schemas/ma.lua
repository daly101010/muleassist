local schema = {
    INI_PATTERNS = {
            ['level'] = 'MuleAssist_%s_%s_%d.ini',
            ['nolevel'] = 'MuleAssist_%s_%s.ini',
            ['default'] = 'nolevel',
    },
    StartCommands = {
        '/lua run muleassist/init assist',
        '/lua run muleassist/init assist ${Group.MainAssist}',
        '/lua run muleassist/init tank',
        '/lua run muleassist/init puller ${Group.MainAssist}',
        '/lua run muleassist/init pullertank',
        '/lua run muleassist/init hunter',
    },
    -- Array For tab and INI ordering purposes
    Sections = {
        'General',
        'DPS',
        'Heals',
        'Buffs',
        'Melee',
        'Burn',
        'Mez',
        'AE',
        'OhShit',
        'Pet',
        'Charm',
        'Pull',
        'Aggro',
        'Bandolier',
        'Cures',
        'GoM',
        'Rogue',
        'Merc',
        'AFKTools',
        'GMail',
        'AutoClass',
        'AutoClassCache',
        'MySpells',
        'SpellSet',
    },
    General={
        Properties={
            CampRadius={-- int (30)
                Type='NUMBER',
                Min=0,
                Tooltip='Determines how far your characters interact based on your initial camp spot.',
            },
            CampRadiusExceed={-- int (400)
                Type='NUMBER',
                Min=0,
                Tooltip='Disables the ReturnToCamp setting upon moving large distances from your camp. (Summoned, warp, teleport etc)',
            },
            ReturnToCamp={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Determines if your characters return to the camp after each fight. (Note: Set ChaseAssist to 0 if using this).',
            },
            ReturnToCampAccuracy={-- int (10)
                Type='NUMBER',
                Min=5,
                Tooltip='How close you need to be to your camp point to be considered back.',
            },
            ChaseAssist={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - If set to 1 macro will follow main assist around instead of returning to camp (Note: Set ReturnToCamp to 0)',
            },
            ChaseDistance={-- int (25)
                Type='NUMBER',
                Min=0,
                Tooltip='How close you want your character to follow main assist.',
            },
            MedOn={-- int (1)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles the medding feature for mana or endurance based on the MedStart settings.',
            },
            MedStart={-- string (20)
                Type='NUMBER',
                Min=0,
                Max=100,
                Tooltip='What mana/endurance percentage to start medding at.',
            },
            SitToMed={-- not from LoadIni call??
                Type='NUMBER',
                Min=0,
                Tooltip='How long to wait to sit after casting a spell in combat. 0 is off (it wont sit during combat), otherwise it will wait # seconds to sit after a successful cast. If you want it to be immediate, do a very low number .01 (probably)',
            },
            LootOn={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Turns looting on or off based on your Loot.ini file in your macros folder.',
            },
            RezAcceptOn={--switch + extra option, string, (0|96)
                Type='STRING',
                Tooltip='0=Off/1=On, |%%=minimum rez%% to accept the rez. - Enables MQ2Rez autoaccept. (Example: RezAcceptOn=1|96)',
            },
	    --[[
            RezAcceptOn={--switch + extra option 0/1|96
                Type='MULTIPART',
                Parts={
                    [1]={
                        Name='On|Off',
                        Type='SWITCH'
                    },
                    [2]={
                        Name='Min. Pct',
                        Type='NUMBER',
                        Min=0,
                        Max=100,
                    },
                },
            },
	    --]]
            AcceptInvitesOn={-- int (1)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles automatic party invite offers while muleassist is running.',
            },
            GroupWatchOn={--switch + extra options 0/1/2/3|MedAt%|Classes
                Type='STRING',
                Tooltip='0=Off/1=EntireGroup/2=HealersOnly,|%%=What %% to start waiting for party mana/end to get to 90%%. Default %% is 20.\n3=Watch for select classes.',
            },
            CastingInterruptOn={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Will try and interrupt casting to help save mana. Is used for healing or DPS spells.',
            },
            EQBCOn={--switch + extra option
                Type='STRING',
                Tooltip='0=Off/1=On,|ChannelName - Messages for Mez, Heals, Pulls and Tanking in MQ2EQBC.',
            },
            DanNetOn={--switch + extra option
                Type='STRING',
                Tooltip='0=Off/1=On,|ChannelName - Messages for Mez, Heals, Pulls and Tanking in DanNet. If both EQBCOn and DanNetOn are on DanNetOn is Turned off.',
            },
            DanNetDelay={-- int (20)
                Type='NUMBER',
                Tooltip='',
            },
            MiscGem={-- int (8)
                Type='NUMBER',
                Min=1,
                Max=13,
                Tooltip='Spell Gem # muleassist uses to mem spells that need to be memmed (buffs, pet summons, etc)',
            },
            MiscGemLW={-- int (0)
                Type='NUMBER',
                Min=0,
                Max=13,
                Tooltip='Similar to (MiscGemRemem), however this is used for LONG MEMORIZATION / LONG RECAST time spells.',
            },
            MiscGemRemem={-- int (1)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles rememming the original spell in MiscGem slot that was there when the macro was started.',
            },
            TwistOn={
                Type='SWITCH',
                Tooltip='1= Bard will twist out of combat. TwistOn=0 Bard will NOT twist out of combat (preventing song aggro).',
            },
            TwistMed={
                Type='STRING',
                Tooltip='Example: TwistMed=3 2 5',
            },
            TwistWhat={
                Type='STRING',
                Tooltip='Ex: TwistWhat=1 2 4 6 - Song order (Gem#s) when out of combat. (Or always when using MeleeTwist=Continuous',
            },
            GroupEscapeOn={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - If this character is a Druid or Wizard then if the MA dies (or is not present) when in combat, trigger group evacuation (Exodus or Succor/Evacuate).',
            },
            CampfireOn={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Will try and drop a campfire if 3 or more fellowship members are in range.',
            },
            DPSMeter={-- int (1)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles the dps meter that is displayed after each fight.',
            },
            Scatter={-- int (0)
                Type='SWITCH',
                Tooltip='Will randomize the return to camp location.',
            },
            CheerPeople={-- int (0)
                Type='SWITCH',
                Tooltip='CheerPeople will send a /tell to the person who got a kill shot in the serverwide message. Be very careful using this. Its not our fault if you get banned for sending 32 tells in an instant to some rando.',
            },
            BuffWhileChasing={--bool (1)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Will enable buffing while chase is on.',
            },
            SwitchWithMA={-- bool (FALSE)
                Type='SWITCH',
                Tooltip='',
            },
            CastRetries={ -- new beta int (3)
                Type='NUMBER',
                Tooltip='',
            },
            TravelOnHorse={
                Type='SWITCH',
                Tooltip=''
            }
            --Role string (Assist)
            --GemStuckAbility string (NULL)
            --HoTTOn int (0)
            --MoveCloserIfNoLOS int (0)
            --IRCOn int (0)
            --TravelOnHorse bool (FALSE)
        }
    },
    SpellSet={
        Properties={
            LoadSpellSet={
                Type='NUMBER',
                Min=0,
                Max=2,
            },
            SpellSetName={
                Type='STRING'
            },
        },
    },
    AutoClass={
        Properties={
            AutoClassOn={
                Type='SWITCH',
                Tooltip='Enable MuleAssist auto-class baseline suggestions and fill-empty MySpells generation.',
            },
            Family={
                Type='STRING',
                Tooltip='Baseline data family. Live is the only v1 family.',
            },
            Mode={
                Type='STRING',
                Tooltip='Class loadout mode. Default uses the default or first available loadout for the class.',
            },
            SuggestOnly={
                Type='SWITCH',
                Tooltip='Keep learned upgrades as suggestions instead of overwriting configured MySpells.',
            },
            FillEmptyMySpells={
                Type='SWITCH',
                Tooltip='Only fill empty MySpells Gem# slots when applying the baseline.',
            },
            FillEmptyLists={
                Type='SWITCH',
                Tooltip='Only fill empty MuleAssist action-list slots when applying the baseline.',
            },
        },
    },
    AutoClassCache={
        Properties={
            Family={ Type='STRING' },
            Class={ Type='STRING' },
            Level={ Type='NUMBER' },
            Mode={ Type='STRING' },
            LastScan={ Type='STRING' },
            GemCount={ Type='NUMBER' },
        },
    },
    MySpells={
        Properties={
            Gem1={ Type='SPELL', Tooltip='Spell memorized into gem 1 when LoadSpellSet=2.' },
            Gem2={ Type='SPELL', Tooltip='Spell memorized into gem 2 when LoadSpellSet=2.' },
            Gem3={ Type='SPELL', Tooltip='Spell memorized into gem 3 when LoadSpellSet=2.' },
            Gem4={ Type='SPELL', Tooltip='Spell memorized into gem 4 when LoadSpellSet=2.' },
            Gem5={ Type='SPELL', Tooltip='Spell memorized into gem 5 when LoadSpellSet=2.' },
            Gem6={ Type='SPELL', Tooltip='Spell memorized into gem 6 when LoadSpellSet=2.' },
            Gem7={ Type='SPELL', Tooltip='Spell memorized into gem 7 when LoadSpellSet=2.' },
            Gem8={ Type='SPELL', Tooltip='Spell memorized into gem 8 when LoadSpellSet=2.' },
            Gem9={ Type='SPELL', Tooltip='Spell memorized into gem 9 when LoadSpellSet=2.' },
            Gem10={ Type='SPELL', Tooltip='Spell memorized into gem 10 when LoadSpellSet=2.' },
            Gem11={ Type='SPELL', Tooltip='Spell memorized into gem 11 when LoadSpellSet=2.' },
            Gem12={ Type='SPELL', Tooltip='Spell memorized into gem 12 when LoadSpellSet=2.' },
            Gem13={ Type='SPELL', Tooltip='Spell memorized into gem 13 when LoadSpellSet=2.' },
        },
    },
    Melee={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            AssistAt={
                Type='NUMBER',
                Min=1,
                Max=100,
                Tooltip='Mob health to assist/attack. This affects when you engage and is NOT specific to melee characters. IE pet classes will send pets at this %%.',
            },
            FaceMobOn={
                Type='SWITCH',
                Tooltip='0=Off/1=Will Face mobs (includes casting spells)/2=More realistic facing - Toggles facing mob right before combat starts. (Casters should generally disable this)',
            },
            MeleeDistance={
                Type='NUMBER',
                Min=0,
                Tooltip='Mobs outside this radius will not be engaged. Tank modes will use this distance to decide if mobs should be engaged. This distance applies to casters engaging with spells as well and will be checked even when MeleeOn=0.',
            },
            StickHow={
                Type='STRING',
                Tooltip='Tells character how to stick to mob when fighting. !front, behindonce, snaproll rear, front. See mq2moveutils for more valid commands and descriptions.',
            },
            MeleeTwistOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles melee specific twisting.',
            },
            MeleeTwistWhat={
                Type='STRING',
                Tooltip='Song order to twist during combat if MeleeTwistOn is on. If set to MeleeTwistWhat=Continuous the bard will continue to twist the normal song order as defined in TwistWhat from the General Section',
            },
            AutoFireOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles Auto fire on/off. Ranged item and ammo must be equipped.',
            },
            Autohide={ -- rogue only
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles auto Sneak Hide for Rogues. Rogue will hide sneak after every fight',
            },
            BeforeCombat={
                Type='SPELL',
                Tooltip='Thing to use right before combat. Berserkers and rogues often use this section.',
            },
            RogueTimerEight={-- new beta? rogue only
                Type='SPELL',
                Tooltip='',
            },
            TargetSwitchingOn={
                Type='SWITCH',
                Tooltip='',
            },
            DismountDuringFights={
                Type='SWITCH',
                Tooltip='',
            },
            TankAllMobs={ -- new beta?
                Type='SWITCH',
                Tooltip='0=Off/1=On - Tank add rescue. When tanking, briefly turns attack off, tells MuleAssist assist clients to hold DPS on the original target, targets camp adds on group/raid members, skips mezzed/rooted mobs, taunts only if you are not the aggro holder, navs to the add for Taunt if it is out of range but within 125, and uses ready Aggro entries when another group/raid member is the aggro holder. Returns to the original target and restores attack afterward.',
            }
        },
    },
    DPS={
        Controls={
            On={
                Type='NUMBER',
                Min=0,
                Max=2,
            },
            COn=true,
        },
        Properties={
            DPS={
                Type='LIST',
                Max=40,
                Conditions=true,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Used to control the number of DPS entries.',
                OptionsTooltip='MobHealth%%',
                CondTooltip='If DPSCOn=1, it will only cast the DPS spell if the conditions equate to true.',
            },
            DPSSkip={
                Type='NUMBER',
                Min=1,
                Max=100,
                Tooltip='Stops casting DPS spells when the mob reaches health percentage. Default 20%%',
            },
            DPSInterval={
                Type='NUMBER',
                Min=0,
                Tooltip='This is the amount of time between casts of the same spell. If set to 10, then your box will only cast your DPS1 spell every ten seconds. Attaches a timer in seconds to DPS spells with 0 duration after they are cast. If you are nuking too fast you can slow down by increasing the interval.',
            },
            DebuffAllOn={
                Type='NUMBER',
                Min=0,
                Max=2,
                Tooltip='0=Off/1=On/2=More Persistent debuffing - Enables debuffs to be cast on all targets in camp while DPSing the main target.',
            },
            StayAwayToCast={-- new beta?
                Type='SWITCH',
                Tooltip='',
            },
        },
    },
    Buffs={
        Controls={
            On={
                Type='SWITCH',
            },
            COn=true,
        },
        Properties={
            Buffs={
                Type='LIST',
                Max=20,
                Conditions=true,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Sets the number of Buff# to parse. Similar function to DPSSize. (Speculation: if BuffsSize=10, then Buff11, Buff12, etc. will be ignored.)',
                OptionsTooltip='Buff format: Spell|Tag|Param3|Param4|Param5. Tags include Me, MA, !MA, !ME, caster, Melee, class, Dual, Aura, Mana, Managroup, Endgroup, End, Summon, Once, Remove. Append |combat to allow this entry during combat. Add |OOG:actors,raid,fellowship,range150,xtarget2,Name for out-of-group targets. Examples: Symbol|class|WAR,PAL,SHD; Gather Mana|Mana|20|80; Paragon|Endgroup|40; Unity|Dual|Single Buff|MA|combat; Haste|Melee|OOG:actors,range150.',
                CondTooltip='It will only cast the buff spell if the conditions equate to true.',
            },
            RebuffOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles rebuffing from spell worn off message. Need Clarification.',
            },
            CheckBuffsTimer={
                Type='NUMBER',
                Min=0,
                Tooltip='Number in seconds to skip checking buffs/rebuffing',
            },
            PowerSource={
                Type='STRING',
                Tooltip='Specify the name of the PowerSource you want to maintain being equipped and active in your PowerSource inventory slot, as well as destroy/remove used powersources. You can maintain the PowerSource by treating it as a summoned item.',
            },
            BegOn={
                Type='NUMBER',
                Min=0,
                Max=2,
                Tooltip='0=Off/1=On - Toggles the beg buff feature.',
            },
            BegPermission={
                Type='STRING',
                Tooltip='The Mule will only give buffs to people who meet the permission requirement set here.',
            },
            Beg={
                Type='LIST',
                Max=20,
                Conditions=false,
                Tooltip='This is the name of the buff people can beg.',
                SizeTooltip='Sets the number of Beg# to parse. Similar function to DPSSize.',
                OptionsTooltip='Aliases people can use to beg for the buff. Example: Brells,BBB,BSW',
                CondTooltip='',
            },
            -- BuffCacheingDelay int 300
        }
    },
    Heals={
        Controls={
            On={
                Type='SWITCH',
            },
            COn=true,
        },
        Properties={
            Heals={
                Type='LIST',
                Max=40,
                Conditions=true,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Number of Heals# entries to parse. Similar to DPSSize.',
                OptionsTooltip='%%Health|Flag. The health threshold to cast the heal and optional flag to filter who it will be cast on. Flags: MA, !MA, Me, pet, tap, Mob, !Pet',
                CondTooltip='Like normal conditions. ${TheHealID} is the current target that is checked for each heal.',
            },
            XTarHeal={
                Type='STRING',
                Tooltip='0 is off. Otherwise, it will heal that slot. You should not use slot 1.',
            },
            AutoRezOn={
                Type='NUMBER',
                Min=0,
                Max=2,
                Tooltip='Turns on auto Rez feature. Will rez any character with in a radius of 100 of the Rezzer. HealsOn=1 must be on for this feature to work.',
            },
            AutoRezWith={
                Type='SPELL',
                Tooltip='Rez character with AA/Item/Spell. This is a BATTLE REZ feature. The character will try and rez anyone in the group that is dead during their heal rotation. Due to MQ2Rez issues characters will not accept rezs from Call of the Wild. Fix inc soon.',
            },
            HealGroupPetsOn={
                Type='SWITCH',
                Tooltip='Turn on healing of group pets or not',
            },
            InterruptHeals={
                Type='NUMBER',
                Min=0,
                Tooltip='If the character is currently casting a Heal spell, it will interrupt that spell if the target reaches this number HP%%. If set to 100, it will interrupt the heal within the last second of the casting if the target is at 100%%.',
            },
        },
    },
    Cures={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            Cures={-- loaded once without conds and once with? no COn switch tho
                Type='LIST',
                Max=5,
                Conditions=true,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Number of Cures# entries to parse. Similar to DPSSize.',
                OptionsTooltip='DebuffType',
                CondTooltip='',
            },
        },
    },
    Mez={
        Controls={
            On={
                Type='NUMBER',
                Min=0,
                Max=3,
            },
        },
        --Classes={brd=1,enc=1},
        Properties={
            MezRadius={
                Type='NUMBER',
                Min=0,
                Tooltip='Radius to detect mobs surrounding enchanter/bard',
            },
            MezMinLevel={
                Type='NUMBER',
                Min=1,
                Tooltip='Minimum level of mobs to mez within MezRadius',
            },
            MezMaxLevel={
                Type='NUMBER',
                Min=1,
                Tooltip='Maximum level of mobs to mez within MezRadius',
            },
            MezStopHPs={
                Type='NUMBER',
                Min=1,
                Max=100,
                Tooltip='Mob HPs to stop mezzing at.',
            },
            MezSpell={
                Type='SPELL',
                Tooltip='Your single target mez spell or song',
            },
            MezAESpell={
                Type='SPELL',
                Tooltip='AE Mez spell/song|Number of mobs to start mezzing. 3 is generally a good minimum value.',
            }
        }
    },
    Pet={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            PetToys={
                Type='LIST',
                Max=6,
                Conditions=false,
                Tooltip='Spell',
                SizeTooltip='Number of PetToys# entries to parse. Similar to DPSSize.',
                OptionsTooltip='Weapon 1|Weapon 2',
                CondTooltip='',
            },
            PetSpell={
                Type='SPELL',
                Tooltip='Name of pet spell/item/AA.',
            },
            PetFocus={
                Type='STRING',
                Tooltip='If you have a pet focus item, list it here to equip it. PetFocus=Bonespike Earring|rightear',
            },
            PetShrinkOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles pet shrinking.',
            },
            PetShrinkSpell={
                Type='SPELL',
                Tooltip='Pet shrink AA/Spell/Item.',
            },
            PetHoldOn={
                Type='SWITCH',
                Tooltip='This configurable option is not used any longer in the code for muleassist, as of version 8.0. PetHold ON commands are controlled and initiated by detection of the existence and level of Pet Discipline AA you have.',
            },
            PetBuffsOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles curing of debuffs.',
            },
            PetBuffs={
                Type='LIST',
                Max=8,
                Conditions=false,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Number of PetBuffs entries to parse. Similar to DPSSize.',
                OptionsTooltip='Dual|Pet Illusion: Night Harvest Scarecrow',
                CondTooltip='',
            },
            PetCombatOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Use to initiate pet combat for your pet class.',
            },
            PetAssistAt={
                Type='NUMBER',
                Min=1,
                Max=100,
                Tooltip='Adjusts what %% of the mobs health your pet should start attacking.',
            },
            PetBreakMezSpell={
                Type='SPELL',
                Tooltip='Spell to use to break mez when in PetTank or PullerPetTank roles.',
            },
            PetRampPullWait={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Wait until rampage/swarm pets drop before starting next pull. (Used for pet classes in PullerPetTank role).',
            },
            PetSuspend={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles the function to determine if we have suspended pets / and unsuspend a pet if available when our current pet dies.',
            },
            MoveWhenHit={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Use to enable/disable movement away from mob when code for GotHit (mob beating on pet owner) is called for pet class roles of (pettank,pullerpettank,hunterpettank).',
            },
            PetToysOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles pet toy summoning and gives them to your pets.',
            },
            --PetToysGave=internal?
            --PetForceHealOnMed int
            --PetBehind bool
        }
    },
    Charm={
        Classes={ enc=1, dru=1 },
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            Charm={
                Type='LIST',
                Max=5,
                Conditions=false,
                Tooltip='Charm spell (must be memorized).',
                SizeTooltip='Number of charm spells, in priority order. Index 1 = highest priority; the macro falls back to the next entry when a higher one is on cooldown, unmemmed, or ineligible.',
                OptionsTooltip='MinLevel|MaxLevel|MinMana. Leave a field blank for: no minimum / the spell\'s own max level / the spell\'s own mana cost. Example: 0|60|800',
            },
            CharmStunOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Stun (and short-mez if available) the mob before recharming after a break.',
            },
            CharmRetashOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Reapply Tash before recharming if it has expired on the pet.',
            },
            CharmAutoOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Auto-acquire a charm target: charm the nearest mob already on your XTarget (auto-aggro) that passes the do-not lists and level limits. Never pulls non-aggro mobs.',
            },
            CharmMaxFails={
                Type='NUMBER',
                Min=1,
                Tooltip='Consecutive failed charm attempts (resist/interrupt/fizzle/immune) before the emergency mez-lockdown recovery runs. Requires [Mez] On. Default 3.',
            },
            CharmDoNotList={
                Type='STRING',
                Tooltip='Pipe-separated mob names to never charm (substring match). Ex. a_named_mob|Guardian Kozzalym',
            },
            CharmDoNotClass={
                Type='STRING',
                Tooltip='Pipe-separated class SHORT names to never charm (exact match). Ex. CLR|SHM|NEC',
            },
        },
    },
    Pull={
        Properties={
            PullWith={
                Type='STRING',
                Tooltip='Melee/AA/Pet/Spell/Disc/Ranged|Ammo',
            },
            MaxRadius={
                Type='NUMBER',
                Min=1,
                Tooltip='Radius you want pull mobs with in.',
            },
            MaxZRange={
                Type='NUMBER',
                Min=1,
                Tooltip='Z Axis Radius you want pull mobs with in. Default =50 for hilly zones try 100-200',
            },
            PullWait={
                Type='NUMBER',
                Min=0,
                Tooltip='Time in seconds to wait looking for mobs if no spawns are up (you killed everything). Used mostly for camping named so you are arent looking for mobs every second.',
            },
            PullRoleToggle={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles puller tag in group window before pulls and turns it off once back in camp after a pull. You must be group leader to do this. Used to keep healer merc in came during pulls. (Currently only active in PullerPetTank role)',
            },
            PullTwistOn={
                Type='SWITCH',
                Tooltip='Bard Only - will turn off twisting during pulling if set to 0 Need Clarification?',
            },
            ChainPull={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles chain pulling.',
            },
            ChainPullHP={
                Type='NUMBER',
                Min=1,
                Max=100,
                Tooltip='Mob HP level to start looking for another mob to pull',
            },
            ChainPullPause={
                Type='STRING',
                Tooltip='Time in Minutes to pull mobs before Holding Pulls|How long in minutes after holding to resume pulls.',
            },
            PullLevel={
                Type='STRING',
                Tooltip='MinLevel|MaxLevel - 10|20 would set lowest level of mobs to pull to 10 and highest level to 20.',
            },
            PullMeleeStick={
                Type='SWITCH',
                Tooltip='Use this flag to stick to target when pulling with melee. Helps with mobs that are moving.',
            },
            UseWayPointZ={
                Type='SWITCH',
                Tooltip='Only used with Advanced Path. This feature will use the paths waypoint, not the Pullers, when checking mobs MaxZRange.',
            },
            PullArcWidth={
                Type='STRING',
                Tooltip='The width in degrees on the compass and optionally the heading. Ex. "180 n".',
            },
            PullCond={
                Type='STRING',
                Tooltip='Condition to validate whether a given mob should be pulled.'
            },
            PrePullCond={
                Type='STRING',
                Tooltip='Condition checked before leaving camp to pull.'
            }
            -- CheckForMemblurredMobsInCamp int (0)
            -- PullNamedsFirst int (0)
            -- ActNatural int (1)
            -- UseCalm int (0)
            -- CalmWith string
            -- CalmRadius int
            -- GrabDeadGroupMembers int (1)
        },
    },
    Merc={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            MercAssistAt={
                Type='NUMBER',
                Min=1,
                Max=100,
                Tooltip='Target health percentage for mercenary to assist at.',
            },
            AutoRevive={
                Type='SWITCH',
                Tooltip='Now auto detects if your merc is in group when the macro is started and will auto revive if merc dies.',
            },
        },
    },
    Burn={
        Controls={
            COn=true,
        },
        Properties={
            Burn={
                Type='LIST',
                Max=15,
                Conditions=true,
                Tooltip='',
                SizeTooltip='',
                OptionsTooltip='',
                CondTooltip='',
            },
            BurnAllNamed={
                Type='NUMBER',
                Min=0,
                Max=2,
                Tooltip='0=Off/1=On - When enabled, this will burn ALL named mobs, Ignoring muleassist_info.ini MobsToBurn entry. 2=On - Will burn ONLY mobs listed in your muleassist_info.ini MobsToBurn entry.',
            },
            UseTribute={
                Type='SWITCH',
                Tooltip='',
            },
            BurnText={
                Type='STRING',
                Tooltip='',
            },
        },
    },
    AFKTools={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            AFKGMAction={-- int (1)
                Type='NUMBER',
                Min=0,
                Max=4,
                Tooltip='0=Off, 1=Pause Macro, 2=End Macro, 3=Unload MQ2, 4=/Quit Game',
            },
            AFKPCRadius={-- int (500)
                Type='NUMBER',
                Min=0,
                Tooltip='Radius to detect PCs. Will alert you and pause all macro activity',
            },
            CampOnDeath={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Will camp to desktop on death.',
            },
            ClickBackToCamp={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Will attempt to click back to campfire using fellowship insignia',
            },
            BeepOnNamed={-- int (0)
                Type='SWITCH',
                Tooltip='The macro will beep twice if the mob you are fighting is a named. Note: This will not trigger for "rare" mobs.',
            },
        },
    },
    GoM={
        Controls={
            On={
                Type='SWITCH',
            },
            COn=true,
        },
        Properties={
            GoM={
                Type='LIST',
                Max=5,
                Conditions=true,
                Tooltip='NameofSpell',
                SizeTooltip='Number of GoMSpell# entries to parse. Similar to DPSSize.',
                OptionsTooltip='tag. Ex. Mob, MA or me',
                CondTooltip='',
            },
        },
    },
    AE={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            AERadius={
                Type='NUMBER',
                Min=0,
                Tooltip='Radius around character to detect mobs.',
            },
            AE={
                Type='LIST',
                Max=10,
                Conditions=false,
                Tooltip='Spell/AA/Disc/Item',
                SizeTooltip='Number of AE ini entries. Similar to DPSSize.',
                OptionsTooltip='Min#Mobs|Target',
                CondTooltip='',
            },
        },
    },
    Aggro={
        Controls={
            On={
                Type='SWITCH',
            },
            COn=true,
        },
        Properties={
            Aggro={
                Type='LIST',
                Max=5,
                Conditions=true,
                Tooltip='AA/Disc/Item/Spell',
                SizeTooltip='Number of Aggro# entries to parse. Similar to DPSSize.',
                OptionsTooltip='%% aggro|>or<',
                CondTooltip='',
            },
        },
    },
    OhShit={
        Controls={
            On={
                Type='SWITCH',
            },
            COn=true,
        },
        Properties={
            OhShit={
                Type='LIST',
                Max=10,
                Conditions=true,
                Tooltip='',
                SizeTooltip='',
                OptionsTooltip='',
                CondTooltip='',
            },
        },
    },
    Bandolier={
        Controls={
            On={
                Type='SWITCH',
            },
            COn=true,
        },
        Properties={
            Bandolier={
                Type='LIST',
                Max=5,
                Conditions=true,
                Tooltip='',
                SizeTooltip='',
                OptionsTooltip='',
                CondTooltip='',
            },
            BandolierPull={
                Type='STRING',
                Tooltip='',
            }
        },
    },
    Rogue={
        Classes={
            rog=1,
        },
        Properties={
            RogCorpseRetrieval={
                Type='SWITCH',
                Tooltip='',
            },
            RogCorpseRadius={
                Type='NUMBER',
                Tooltip='',
            },
        },
    },
    -- Gmail
      -- GmailOn, GMailSize, GMail
}

return schema
