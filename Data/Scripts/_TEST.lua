_ENV.require = _G.import or require
local clock = time or os.clock
local CORE_ENV = CoreDebug and true
local Signals = require("Signals")

if Environment.IsServer() then

else -- Client

end
