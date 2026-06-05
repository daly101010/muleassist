-- Stop, don't look at this! Just some WIP stuff, nothing to see here.
local schema = {
    StartCommands = {
        '/mac kissassist',
        '/mac kissassist assist ${Group.MainAssist}',
        '/mac kissassist tank',
        '/mac kissassist puller ${Group.MainAssist}',
        '/mac kissassist pullertank',
    },
    INI_PATTERNS = {
        ['nolevel'] = 'KissAssist_%s.ini',
        ['default'] = 'nolevel',
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
        'KConditions',
        'Pet',
        'Pull',
        'PullAdvanced',
        'Aggro',
        'Cures',
        'Merc',
        'AFKTools',
        'GMail',
        'Spells',
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
            MedCombat={-- int (1)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles the medding feature for mana or endurance based on the MedStart settings.',
            },
            LootOn={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Turns looting on or off based on your Loot.ini file in your macros folder.',
            },
            RezAcceptOn={--switch + extra option, string, (0|96)
                Type='STRING',
                Tooltip='0=Off/1=On, |%%=minimum rez%% to accept the rez. - Enables MQ2Rez autoaccept. (Example: RezAcceptOn=1|96)',
            },
            AcceptInvitesOn={-- int (1)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles automatic party invite offers while muleassist is running.',
            },
            GroupWatchOn={--switch + extra options 0/1/2/3|MedAt%|Classes
                Type='STRING',
                Tooltip='0=Off/1=EntireGroup/2=HealersOnly,|%%=What %% to start waiting for party mana/end to get to 90%%. Default %% is 20.\n3=Watch for select classes.',
            },
            GroupWatchCheck={--switch + extra options 0/1/2/3|MedAt%|Classes
                Type='STRING',
                Tooltip='0=Off/1=EntireGroup/2=HealersOnly,|%%=What %% to start waiting for party mana/end to get to 90%%. Default %% is 20.\n3=Watch for select classes.',
            },
            CorpseRecoveryOn={-- int (0)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Will try and interrupt casting to help save mana. Is used for healing or DPS spells. Also see InterruptHeals under [Heals]',
            },
            EQBCOn={--switch + extra option
                Type='STRING',
                Tooltip='0=Off/1=On,|ChannelName - Messages for Mez, Heals, Pulls and Tanking in MQ2EQBC. See EQBC for more info.',
            },
            DanNetOn={--switch + extra option
                Type='STRING',
                Tooltip='0=Off/1=On,|ChannelName - Messages for Mez, Heals, Pulls and Tanking in DanNet. See DanNet for more info. If both EQBCOn and DanNetOn are on DanNetOn is Turned off.',
            },
            IRCOn={-- int (20)
                Type='SWITCH',
                Tooltip='',
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
            ScatterOn={-- int (0)
                Type='SWITCH',
                Tooltip='Will randomize the return to camp location.',
            },
        }
    },
    Spells={
        Properties={
            LoadSpellSet={
                Type='NUMBER',
                Min=0,
                Max=2,
            },
            SpellSetName={
                Type='STRING'
            },
            MiscGem={-- int (8)
                Type='NUMBER',
                Min=1,
                Max=13,
                Tooltip='Spell Gem # muleassist uses to mem spells that need to be memmed (buffs, pet summons, etc)',
            },
            MiscGemLW={-- int (0)
                Type='NUMBER',
                Min=1,
                Max=13,
                Tooltip='Similar to (MiscGemRemem), however this is used for LONG MEMORIZATION / LONG RECAST time spells.',
            },
            MiscGemRemem={-- int (1)
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles rememming the original spell in MiscGem slot that was there when the macro was started.',
            },
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
                Tooltip='0=Off/1=On - Toggles melee specific twisting. See General Section for more information.',
            },
            MeleeTwistWhat={
                Type='STRING',
                Tooltip='Song order to twist during combat if MeleeTwistOn is on. If set to MeleeTwistWhat=Continuous the bard will continue to twist the normal song order as defined in TwistWhat from the General Section',
            },
            AutoFireOn={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles Auto fire on/off. Ranged item and ammo must be equipped.',
            },
            UseMQ2Melee={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles all MQ2Melee functions, including holy/downshits, and when off, lets muleassist completely control your Melee character.',
            },
            Autohide={ -- rogue only
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles auto Sneak Hide for Rogues. Rogue will hide sneak after every fight',
            },
            TargetSwitchingOn={
                Type='SWITCH',
                Tooltip='',
            },
        },
    },
    DPS={
        Controls={
            On={
                Type='NUMBER',
                Min=0,
                Max=2,
            },
        },
        Properties={
            DPS={
                Type='LIST',
                Max=40,
                Conditions=false,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Used to control the number of DPS entries.',
                OptionsTooltip='MobHealth%%',
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
        },
    },
    Buffs={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            Buffs={
                Type='LIST',
                Max=20,
                Conditions=false,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Sets the number of Buff# to parse. Similar function to DPSSize. (Speculation: if BuffsSize=10, then Buff11, Buff12, etc. will be ignored.)',
                OptionsTooltip='What to buff. MA, Me, Melee, Caster, Class. Ex. melee|OOG:raid, dual|illusion: ondine wavefront.',
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
                Tooltip='Specify the name of the PowerSource you want to maintain being equipped and active in your PowerSource inventory slot, as well as destroy/remove used powersources. You can maintain the PowerSource by treating it as a summoned item. (See Summon Items modifier below).',
            },
        }
    },
    Heals={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            Heals={
                Type='LIST',
                Max=15,
                Conditions=false,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Number of Heals# entries to parse. Similar to DPSSize.',
                OptionsTooltip='%%Health|Flag. The health threshold to cast the heal and optional flag to filter who it will be cast on. Flags: MA, !MA, Me, pet, tap, Mob, !Pet',
            },
            XTarHeal={
                Type='STRING',
                Tooltip='0 is off. Otherwise, it will heal that slot. You should not use slot 1.',
            },
            XTarHealList={
                Type='STRING',
                Tooltip='0 is off. Otherwise, it will heal that slot. You should not use slot 1.',
            },
            AutoRezOn={
                Type='SWITCH',
                Tooltip='Turns on auto Rez feature. Will rez any character with in a radius of 100 of the Rezzer. HealsOn=1 must be on for this feature to work.',
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
                Conditions=false,
                Tooltip='Spell/Disc/Item/AA',
                SizeTooltip='Number of Cures# entries to parse. Similar to DPSSize.',
                OptionsTooltip='DebuffType',
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
            },
            MezDebuffOnResist={
                Type='SWITCH',
                Tooltip='AE Mez spell/song|Number of mobs to start mezzing. 3 is generally a good minimum value.',
            },
            MezDebuffSpell={
                Type='SPELL',
                Tooltip='Your single target mez spell or song',
            },
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
            PetForceHealOnMed={
                Type='SWITCH',
                Tooltip='0=Off/1=On - Toggles pet toy summoning and gives them to your pets.',
            },
        }
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
                Tooltip='Radius you want pull mobs with in. (See Image below for a visual)',
            },
            MaxZRange={
                Type='NUMBER',
                Min=1,
                Tooltip='Z Axis Radius you want pull mobs with in. Default =50 for hilly zones try 100-200 (See Image below)',
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
            PullPause={
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
                Type='NUMBER',
                Min=0,
                Max=360,
                Tooltip='The width in degrees on the compass. See /setpullarc in the command section.',
            },
            PullOnReturn={
                Type='SWITCH',
                Tooltip=''
            },
        },
    },
    PullAdvanced={
        Controls={},
        Properties={
            PullLocsOn={
                Type='SWITCH',
                Tooltip=''
            },
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
        },
    },
    Burn={
        Controls={},
        Properties={
            Burn={
                Type='LIST',
                Max=15,
                Conditions=false,
                Tooltip='',
                SizeTooltip='',
                OptionsTooltip='',
            },
            BurnAllNamed={
                Type='NUMBER',
                Min=0,
                Max=2,
                Tooltip='0=Off/1=On - When enabled, this will burn ALL named mobs, Ignoring muleassist_info.ini MobsToBurn entry. 2=On - Will burn ONLY mobs listed in your muleassist_info.ini MobsToBurn entry.',
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
        },
    },
    GoM={
        Controls={},
        Properties={
            GoM={
                Type='LIST',
                Max=5,
                Conditions=false,
                Tooltip='NameofSpell',
                SizeTooltip='Number of GoMSpell# entries to parse. Similar to DPSSize.',
                OptionsTooltip='tag. Ex. Mob, MA or me',
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
            },
        },
    },
    Aggro={
        Controls={
            On={
                Type='SWITCH',
            },
        },
        Properties={
            Aggro={
                Type='LIST',
                Max=5,
                Conditions=false,
                Tooltip='AA/Disc/Item/Spell',
                SizeTooltip='Number of Aggro# entries to parse. Similar to DPSSize.',
                OptionsTooltip='%% aggro|>or<',
            },
        },
    },
    -- Gmail
      -- GmailOn, GMailSize, GMail
}

return schema
