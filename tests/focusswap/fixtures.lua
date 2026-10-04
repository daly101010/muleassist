-- Shared focus fixtures. The two pants foci are laid out as Magelo lists them (screenshots,
-- 2026-09-23): slot order and meaning are real; the SPA 136 target ids are illustrative until
-- /focusswap dump shows the real ones.
local M = {}

local function pantsFocus(resistId)
  return {
    { attrib = 124, base = 1, base2 = 30 },       -- Increase Spell Damage by 1% to 30%
    { attrib = 134, base = 70, base2 = 5 },       -- Limit Max Level: 70 (lose 5% per level)
    { attrib = 137, base = 0, base2 = 0 },        -- Limit Effect: Hitpoints
    { attrib = 138, base = 0, base2 = 0 },        -- Limit Type: Detrimental
    { attrib = 136, base = -1, base2 = 0 },       -- Limit Target: Exclude Unknown (id illustrative)
    { attrib = 136, base = -4, base2 = 0 },       -- Exclude Area around caster (id illustrative)
    { attrib = 136, base = -8, base2 = 0 },       -- Exclude Area around target (id illustrative)
    { attrib = 136, base = -17, base2 = 0 },      -- Exclude Giant (id illustrative)
    { attrib = 136, base = -18, base2 = 0 },      -- Exclude Dragon (id illustrative)
    { attrib = 311, base = 0, base2 = 0 },        -- Limit Type: Exclude Procs
    { attrib = 135, base = resistId, base2 = 0 }, -- Limit Resist
  }
end
M.MURK_BLOOD = pantsFocus(4)     -- poison
M.PYRILEN_FURY = pantsFocus(2)   -- fire

-- a spell record as scan.spellInfo returns it; overrides replace fields
function M.spell(over)
  local s = { name = 'Chaos Venom', id = 1001, level = 65, resist = 'poison', beneficial = false,
    durTicks = 7, castMs = 3000, targetType = 'Single', spas = { [0] = true } }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end
M.POISON_DOT = M.spell()
M.FIRE_DOT = M.spell({ name = 'Ignite Blood', id = 1002, resist = 'fire' })
M.FIRE_NUKE = M.spell({ name = 'Fire Bolt', id = 1003, resist = 'fire', durTicks = 0 })

-- an item record as scan.lua builds it
function M.item(name, effects, fits, focusName)
  local L = require('focusswap.limits')
  local foci = effects and L.fromEffects(focusName or name, effects) or {}
  return { name = name, foci = foci, fits = fits or {}, spells = {}, unknown = {} }
end

return M
