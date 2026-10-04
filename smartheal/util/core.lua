-- smartheal/util/core.lua: stand-in for sidekick-next's utils/core (the engine reads Core.Settings).
local Env = require('smartheal.env')
return setmetatable({ load = function() end }, {
    __index = function(_, k) if k == 'Settings' then return Env.settings() end end,
})
