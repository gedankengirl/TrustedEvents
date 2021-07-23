--[[
     ______             __         ______              __
    /_  __/_____ _____ / /____ ___/ / __/  _____ ___  / /____(TM)
     / / / __/ // (_-</ __/ -_) _  / _/| |/ / -_) _ \/ __(_-<
    /_/ /_/  \_,_/___/\__/\__/\_,_/___/|___/\__/_//_/\__/___/

    TrustedEvents by zoonior

== TrustedEvents is a drop-in replacement for Core Events.

They are:

  * reliable: have a 100%(*) guarantee to be delivered in the order in which they
    were sent, even if the connection is bad and network packets are lost.

  * flexible: you can send *hundreds* of small events per second, or several
    big ones. You have an option to send events either reliably or unreliably.

  * convenient: all dispatched events are queued; no need to check return
    codes and use Task.Wait.

== To use TrustedEvents:

 1. Drag the @TrustedEvents template and place it on the very top of your
    scene hierarchy.

 2. Load the TrustedEvents module. I recommend the following method:
    ```lua
    local TrustedEvents = _G.import("TrustedEvents")
    ```
    But you can use the Core way:
    ```lua
	local TrustedEvents = require("98A501186132D933:TrustedEvents")
    ```

 3. Replace any "Events.XXX" with "TrustedEvents.XXX", i.e.
    Events.BroadcastToPlayer(...) becomes TrustedEvents.BroadcastToPlayer(...)
    and so on.
    The whole Core Events API and all argument types are supported.
    https://docs.coregames.com/api/events/

(!) The current version of the template supports up to 32 players per server.

== What makes TrustedEvents different from Core Events. Limitations.

1. Core’s networked Events.BroadcastXXX return 5 different
   BroadcastMessageResultCode; TrustedEvents return either
   BroadcastMessageResultCode.SUCCESS, or throw an error if the event size
   limit is exceeded.

2. TrustedEvents have a different set of limitations:

    2.1 TrustedEvents.BroadcastToPlayer, TrustedEvents.BroadcastToAllPlayers
        have a 512-byte size limit per event. Events are sent 10 times a second
        with a maximum of 768 bytes a time.

    2.2 TrustedEvents.BroadcastToServer has a 20..22-bytes(**) size limit per
        event(*). Events are sent 30 times a second with a maximum of 25 bytes
        a time.

    (!) These are per-player limits (as opposed to the all-players limit).

3. TrustedEvents batch all events into packets and can send multiple events at
   a time - the only limitation is their size. However, if you keep sending
   more events than is physically possible (~10KB/s for server-to-client,
   !1.5KB/s for client-to-server), events will start piling up in the queue and
   might be sent later than you expect (or never sent at all). So do not to
   use events at the top of their capacity systematically.

4. TrustedEvents.UnreliableBroadcastToAllPlayers is a special method for
   unreliable broadcast: it may be a good idea to use it for unimportant
   events (like social feed updates, etc.) It has next limits: 1024 bytes per
   event and ~10KB per second.

== Notes:

(*) Is it truly 100%? Yes. TrustedEvents uses a rather sophisticated algorithm
    to provide this guarantee. The sender considers the packet delivered only
    after the receiving acknowledgment of delivery.
    https://en.wikipedia.org/wiki/Selective_Repeat_ARQ

(**) It is difficult to specify the exact number of bytes as events are
    serialized by MessagePack before dispatch (https://msgpack.org/). The
    number of bytes after serialization should not exceed 25.
]]

--[[ == TrustedEvents Runnable Example Block
-- ----------------------------------------------------------------------------
-- To run it:

-- 1. Drag the @TrustedEvents template and place it *on the very top* of your
--    scene hierarchy.

-- 2. Put 2 instances of this script in game hierarchy: place one into the
--    Client context, and another into the Default or Server context

-- 3. Uncomment this block (add the 3-rd dash: `---[[ == TrustedEvents Run...`)
-- ----------------------------------------------------------------------------
local DEBUG = false
local NOOP = function() end

_ENV.require = _G.import or require


local STRESS_TEST = false or true

local TrustedEvents = require("TrustedEvents")

local CLIENT = Environment.IsClient()
local SERVER = Environment.IsServer()

local dtrace = not DEBUG and NOOP or function(...) print(CLIENT and "[C]" or "[S]", ...) end

-- The maximum size of client events is only about 20+ bytes, the name of the
-- event is also taken into account, so we will make it shorter.
local CLIENT_TEST_EVENT = "CTE"
local CLIENT_STRESS_EVENT = "CSE"

---------------------------------------
--- Client
---------------------------------------
if CLIENT then
    local LOCAL_PLAYER = Game.GetLocalPlayer()

    TrustedEvents.Connect("ServerTestEvent", function(msg, i, data)
        dtrace(LOCAL_PLAYER.name, "got", "ServerTestEvent", msg, i, #data)
    end)

    TrustedEvents.Connect("ServerStressEvent", function(i, data)
        dtrace(LOCAL_PLAYER.name, "got", "ServerStressEvent", i, "+bytes:", #data)
    end)

    ----------------------------------------
    -- Reliable broadcast to server
    ----------------------------------------

    -- NOTE: ("CTE", 17, "00000000000000000") is an example of the maximum
    -- sized client-to-server event (25 bytes after serialization, 21 before).

    for i = 0, 17 do
        TrustedEvents.BroadcastToServer(CLIENT_TEST_EVENT, i, string.rep("0", i))
    end
    if STRESS_TEST then
        for i = 0, 999 do
            local ch = i%8
            if ch == 7 then Task.Wait(0.5) end
            local ok, err = TrustedEvents.BroadcastToServer(CLIENT_STRESS_EVENT, i, string.rep(tostring(ch), 14))
            if not ok then
                print("ERROR", err)
            end
        end
    end

end

---------------------------------------
--- Server
---------------------------------------
if SERVER then

    TrustedEvents.ConnectForPlayer(CLIENT_TEST_EVENT, function(player, ...)
        dtrace("got event from:", player.name, CLIENT_TEST_EVENT, ...)
    end)

    TrustedEvents.ConnectForPlayer(CLIENT_STRESS_EVENT, function(player, ...)
        dtrace("got event from:", player.name, CLIENT_STRESS_EVENT, ...)
    end)

    -- wait for some players
    while #Game.GetPlayers() < 1 do
        Task.Wait(0.5)
    end

    ----------------------------------------
    -- Reliable broadcast to all players
    ----------------------------------------

    -- NOTE: reliable broadcast to all players internally uses
    -- `TrustedEvents.BroadcastToPlayer`
    local bytes_32 = string.rep("+", 32-1)       -- ajusted for text and index
    local bytes_512 = string.rep("+", 512-30-12) -- ajusted for text and index

    for i = 0, 4 do
        -- (!) It is not necessary to wait, the wait is added so that all
        -- events arrive in different packets, and not at the same time
        Task.Wait(0.5)
        TrustedEvents.BroadcastToAllPlayers("ServerTestEvent", i, "Reliable", bytes_32)
        TrustedEvents.BroadcastToAllPlayers("ServerTestEvent", i, "Reliable", bytes_512)
    end

    ----------------------------------------
    -- Unreliable broadcast to all players
    ----------------------------------------

    for i = 0, 4 do
        Task.Wait(0.5)
        TrustedEvents.UnreliableBroadcastToAllPlayers("ServerTestEvent", i, "Unrealiable", bytes_32)
    end

    if STRESS_TEST then

        for i = 0, 99 do
            Task.Wait()
            TrustedEvents.UnreliableBroadcastToAllPlayers("ServerTestEvent", i, "Unrealiable", bytes_512)
            for _, player in pairs(Game.GetPlayers()) do
                TrustedEvents.BroadcastToPlayer(player, "ServerStressEvent", i, bytes_512)
                TrustedEvents.BroadcastToPlayer(player, "ServerStressEvent", i, bytes_32)
            end
        end
    end
end
--]]
