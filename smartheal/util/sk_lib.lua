-- smartheal/util/sk_lib.lua: stand-in for sidekick-next's sk_lib (the engine only reads getSettings().CombatMode
-- and isActiveWorker in Config.save).
local Env = require('smartheal.env')
return {
    getSettings = function() return Env.settings() end,
    isActiveWorker = function() return false end,
}
