--[[
    API holder for Trusted Events
]]

-- STRICT = true : will throw errors
-- STRICT = false: will return BroadcastEventResultCode.FAILURE + error messgae
local STRICT = true

local CLIENT = Environment.IsClient()
local SERVER = Environment.IsServer()

local INSTANCE = nil
local INSTANCE_KEY = SERVER and "<TE_SERVER_INSTANCE>" or "<TE_CLIENT_INSTANCE>"
local MAX_WAIT = 30.0 -- pretty big timeout

local function getInstance()
        local time = 0
        while not INSTANCE do
            local dt = Task.Wait(0.1)
            time = time + dt
            if time > MAX_WAIT then
                error("something wrong: can't get Trusted Events instance")
            end
            INSTANCE = _G[INSTANCE_KEY]
            if INSTANCE then break end
        end
        return INSTANCE
end

---------------------------------------
-- Trusted Events API module
---------------------------------------
local TrustedEvents = {type="TrustedEvents"}
TrustedEvents.__index = TrustedEvents

TrustedEvents.Broadcast = Events.Broadcast
TrustedEvents.Connect = Events.Connect

if SERVER then

    TrustedEvents.ConnectForPlayer = Events.Connect

    function TrustedEvents.BroadcastToAllPlayers(eventName, ...)
        assert(eventName and type(eventName) == "string", "eventName should be a string")
        local server = getInstance()
        local ok, err = server:ReliableBroadcastToAllPlayers(eventName, ...)
        if ok ~= BroadcastEventResultCode.SUCCESS and STRICT then error(err) end
        return ok, err
    end

    -- method that mimics `Events.BroadcastToPlayer`
    function TrustedEvents.BroadcastToPlayer(player, eventName, ...)
        assert(player and player:IsA("Player"))
        assert(eventName)
        local server = getInstance()
        local ok, err = server:BroadcastToPlayer(player, eventName, ...)
        if ok ~= BroadcastEventResultCode.SUCCESS and STRICT then error(err) end
        return ok, err
    end

    function TrustedEvents.UnreliableBroadcastToAllPlayers(eventName, ...)
        assert(eventName and type(eventName) == "string", "eventName should be a string")
        local server = getInstance()
        local ok, err = server:UnreliableBroadcastToAllPlayers(eventName, ...)
        if ok ~= BroadcastEventResultCode.SUCCESS and STRICT then error(err) end
        return ok, err
    end

end

if CLIENT then

    function TrustedEvents.BroadcastToServer(event, ...)
        -- FIXME: could be a small integer too
        local client = getInstance()
        local ok, err = client:BroadcastToServer(event, ...)
        if ok ~= BroadcastEventResultCode.SUCCESS and STRICT then error(err) end
        return ok, err
    end
end

-- module
return TrustedEvents
