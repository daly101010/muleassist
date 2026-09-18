-- muleassist/loot.lua
-- Placeholder for the KissAssist loot module. The Lua reference currently has no runtime
-- behavior, so this preserves the config surface without adding unsafe corpse automation.
local loot = {}

function loot.setup(st)
  st.loot.last_check = st.loot.last_check or 0
end

function loot.tick(st)
  if not st.loot or not st.loot.on then return end
  st.loot.last_check = os.clock()
end

return loot
