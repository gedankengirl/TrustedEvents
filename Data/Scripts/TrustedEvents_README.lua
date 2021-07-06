--[[

    == Trusted Events ==

    Implementation of "Selective Repeat Request" network protocol with some
    variations and additions.

    Reference: https://en.wikipedia.org/wiki/Selective_Repeat_ARQ

    This implementation keeps on delivering messages in the correct order and reliably
    even under severe (90%+) network packets loss.

    This module can handle messages, packets and frames and provides callback
    interface for physical network communications.

    You can see the runnable example below.

]]

------------------------------------------------------------
-- Trusted Events Examples
------------------------------------------------------------

_ENV.require = _G.export or require

local TrustedEvents = require("TrustedEvents")

local CLIENT = Environment.IsClient()
local SERVER = Environment.IsServer()

-- The maximum size of client events is only about 20+ bytes, the name of the
-- event is also taken into account, so we will make it shorter.
local CLIENT_TEST_EVENT = "CTE"

if CLIENT then
    local LOCAL_PLAYER = Game.GetLocalPlayer()
    TrustedEvents.Connect("ServerTestEvent", function(...)
        print("[C]", LOCAL_PLAYER.name, "got", "ServerTestEvent", ...)
    end)

    ----------------------------------------
    -- Reliable broadcast to server
    ----------------------------------------
    -- NOTE: ("CTE", 17, "00000000000000000") is an example of the maximum
    -- client-server event size (25 bytes after serialization, 21 before).
    for i = 0, 17 do
        TrustedEvents.BroadcastToServer(CLIENT_TEST_EVENT, i, string.rep("0", i))
    end

end

if SERVER then
    TrustedEvents.ConnectForPlayer(CLIENT_TEST_EVENT, function(player, ...)
        print("[S]", "got event from:", player.name, CLIENT_TEST_EVENT, ...)
    end)

    -- wait for some players
    while #Game.GetPlayers() < 1 do
        Task.Wait(0.5)
    end

    ----------------------------------------
    -- Reliable broadcast to all players
    ----------------------------------------
    -- NOTE: reliable broadcast to all player imnternally uses `TrustedEvents.BroadcastPlayer`
    for i = 0, 4 do
        -- (!) It is not necessary to wait, the wait is added so that all events
        -- arrive in different packets, and not at the same time
        Task.Wait(0.5)
        TrustedEvents.BroadcastToAllPlayers("ServerTestEvent", i, "Reliable", Color.CYAN)
    end

    ----------------------------------------
    -- Unreliable broadcast to all players
    ----------------------------------------
    for i = 0, 4 do
        Task.Wait(0.5)
        TrustedEvents.UnreliableBroadcastToAllPlayers("ServerTestEvent", i, "Unrealiable", Color.WHITE)
    end
end

