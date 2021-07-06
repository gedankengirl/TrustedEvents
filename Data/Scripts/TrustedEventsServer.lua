--[[
    Trusted Events Server
]]
local DEBUG = false

_ENV.require = _G.export or require

local Maid = require("Maid")
local Base64 = require("Base64")
local MessagePack = require("MessagePack")
local AckAbility = require("AckAbility")

local BitVector32 = require("BitVector32")
local ReliableEndpoint = require("ReliableEndpoint")

local format, tpack, tunpack, tsort = string.format, table.pack, table.unpack, table.sort
local setmetatable, print, warn = setmetatable, print, warn or print
local tostring, tonumber, concat = tostring, tonumber, table.concat
local assert, pairs, next, type, pcall = assert, pairs, next, type, pcall
local Task, Game, Events, BroadcastEventResultCode = Task, Game, Events, BroadcastEventResultCode
local time = time
local _G, script = _G, script

local dtrace = function (...)  if DEBUG then print("[TES]", ...) end end

_ENV = nil

local ALL_PLAYERS = {id = "*all*players", name = "*all*"}
local HUGE = 1

local SERVER_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    -- overrides
}

local UNRELIABLE_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    MAX_DATA_BYTES = false,
    MAX_REALIBLE_MESSAGE_SIZE = 0,
    MAX_REALIBLE_PACKET_SIZE = 0,
    MAX_RELIABLE_PACKETS = 0,
    MAX_UNREALIBLE_MESSAGE_SIZE = 512,
    MAX_UNREALIBLE_PACKET_SIZE = 1024,
    UPDATE_INTERVAL = 0.2,
    PACKET_RESEND_DELAY = HUGE,
    ACK_TIMEOUT = HUGE,
}

dtrace("INFO: Trusted Events Server Configuration")
dtrace(SERVER_CONFIG)

---------------------------------------
-- Channels: Networked Properties
---------------------------------------
local NUM_CHANNELS = 16 + 1       -- one custom property per player + 1 for broadcast
local NUM_ACKS = NUM_CHANNELS - 1 -- one ability per player

local TRUSTED_EVENTS_HOST, ACK_ABILITY_POOL, CHANNELS, BROADCAST_CHANNEL, IN_USE do
    TRUSTED_EVENTS_HOST = script:GetCustomProperty("TrustedEventsHost"):WaitForObject()
    ACK_ABILITY_POOL = TRUSTED_EVENTS_HOST:FindDescendantsByType("Ability")
    assert(#ACK_ABILITY_POOL >= NUM_ACKS , "can't find enough AckAbilities, need: " .. tostring(NUM_ACKS))
    CHANNELS = {}
    for prop, _ in pairs(TRUSTED_EVENTS_HOST:GetCustomProperties()) do
        if type(prop) == "string" then
            CHANNELS[#CHANNELS+1] = prop
        end
    end

    if #CHANNELS ~= NUM_CHANNELS then
        warn(format("wrong number of networked custom properties: %d, should be: %d", #CHANNELS, NUM_CHANNELS))
    end
    -- for easy sorting, our properties names are in fact hex numbers: 1..16 and 255
    tsort(CHANNELS, function(a, b) return tonumber(a) < tonumber(b) end)
    IN_USE = BitVector32.New()
    for i= 0, 31 do
        IN_USE[i] = not CHANNELS[i] -- write `true` at all indices absent in CHANNELS
    end
    -- broadcast channel is a last one (0xFF)
    BROADCAST_CHANNEL = CHANNELS[#CHANNELS]
    IN_USE:swap(#CHANNELS) -- mark broadcast as used
end

-- _borrow_channel :: nil ^-> prop:str, ack:AckAbility
-- returns custom property name and designated ack ability
local function _borrow_channel()
    local idx = IN_USE:find_and_swap(false)
    assert(idx > 0 and idx <= NUM_ACKS)
    return CHANNELS[idx], ACK_ABILITY_POOL[idx]
end

-- _free_channel :: prop:str ^-> nil
local function _free_channel(prop)
    local idx = -1
    for i=1, #CHANNELS do
        if CHANNELS[i] == prop then idx = i break end
    end
    assert(idx > 0)
    IN_USE:swap(idx)
    local ability = ACK_ABILITY_POOL[idx]
    assert(ability)
    ability.owner = nil
    ability.name = "AckAbility"
    ability.isEnabled = false
    ability.parent = TRUSTED_EVENTS_HOST
end

---------------------------------------
-- Player Connection module
---------------------------------------
local PlayerConnection = {type="PlayerConnection"}
PlayerConnection.__index = PlayerConnection

function PlayerConnection.NewUnreliableBroadcastConnection()
    local self = setmetatable({}, PlayerConnection)
    self.maid = Maid.New()
    self.player = ALL_PLAYERS
    self.unique = 0
    self.started = false
    self.channel = BROADCAST_CHANNEL
    self.endpoint = ReliableEndpoint.New(UNRELIABLE_CONFIG, "[broadcast]")
    self:StartEndpoint()
    return self
end

function PlayerConnection.New(player)
    assert(player)
    local self = setmetatable({}, PlayerConnection)
    self.maid = Maid.New()
    local channel, ack_ability = _borrow_channel()
    self.channel = channel
    -- ack ability
    -- check that all preallocated abilities good for us
    AckAbility.check(ack_ability)
    ack_ability.owner = player
    ack_ability.isEnabled = true
    -- notify client about his channel by renaming ability
    ack_ability.name = format("%s,%s,%s", player.id, channel, BROADCAST_CHANNEL)
    self.ack_ability = ack_ability

    self.player = player
    self.unique = 0
    self.started = false

    -- endpoint
    self.endpoint = ReliableEndpoint.New(SERVER_CONFIG, channel, time)

    -- set clean-up on destroy
    self.maid:GiveTask(function () _free_channel(self.channel) end) -- will free ability too
    return self
end

function PlayerConnection:StartEndpoint()
    if self.started then return end
    self.endpoint:SetTransmitFrameCallback(function (header, data)
        -- first 4 bits of header are reserved for the user, so we are putting
        -- a counter in it in order to fire networkedPropertyChangedEvent even
        -- for a non-unique string.
        header = header | (self.unique & ~(-1 << 4))
        self.unique = self.unique + 1
        local mpacked = MessagePack.pack({header, data})
        -- networked custom properties are not tolerated for non-ASCII strings
        local b64str = Base64.encode(mpacked)
        TRUSTED_EVENTS_HOST:SetNetworkedCustomProperty(self.channel, b64str)
    end)
    -- connect endpoint and ability
    if self.ack_ability then -- unreliable broadcast don't ack
        self.maid.ability_sub = self.ack_ability.readyEvent:Connect(function()
            local header, data = AckAbility.read(self.ack_ability)
            if header then
                self.endpoint:OnReceiveFrame(header, data)
            else
                dtrace("AckAbility receive garbage: ", data)
            end
        end)
    end
    -- endpoint update loop
    self.maid.update_loop = Task.Spawn(function()
        local now = time()
        self.endpoint:Update(now)
    end)
    self.maid.update_loop.repeatCount = -1
    self.maid.update_loop.repeatInterval = SERVER_CONFIG.UPDATE_INTERVAL
    -- receive message
    self.endpoint:SetReceiveMessageCallback(function(queue)
        while not queue:IsEmpty() do
            local message = queue:Pop()
            if type(message) == "table" and #message > 0 then
                local eventName = message[#message]
                message[#message] = nil
                Events.Broadcast(eventName, self.player, tunpack(message))
            else
                dtrace(format("WARNING: server sent unknown message: %q", message))
            end
        end
    end)

    -- now endpoint is ready to transmit frames to client
    self.endpoint:UnlockTransmission()
    self.started = true
    dtrace("INFO: Endpoint ready:", self.endpoint.id)
end

function PlayerConnection:Destroy()
    TRUSTED_EVENTS_HOST:SetNetworkedCustomProperty(self.channel, "")
    self.maid:Destroy()
end

---------------------------------------
--Trusted Events Server
---------------------------------------
local TrustedEventsServer = {type = "TrustedEventsServer"}

function TrustedEventsServer:BroadcastToPlayer(unrealible, player, eventName, ...)
    local connection = self.playerConnections[player]
    if not connection then
        return BroadcastEventResultCode.FAILURE, "player not connected"
    end
    local message = tpack(...)
    message.eventName = eventName
    local ok, err = connection.endpoint:SendMessage(message, unrealible)
    if not ok then
        return BroadcastEventResultCode.FAILURE, err
    else
        return BroadcastEventResultCode.SUCCESS
    end
end

function TrustedEventsServer:ReliableBroadcastToAllPlayers(eventName, ...)
    local errors = {}
    for player in pairs(self.playerConnections) do
        if player ~= ALL_PLAYERS then
            local code, err = self:BroadcastToPlayer(false, player, eventName, ...)
            if code ~= BroadcastEventResultCode.SUCCESS then
                errors[player.id:sub(1, 5)] = err
            end
        end
    end
    if not next(errors) then
        return BroadcastEventResultCode.SUCCESS
    else
        local out = {"ERRORS: "}
        for pid, err in pairs(errors) do
            out[#out+1] = format("player.id:%q: %s", pid, err)
        end
        return BroadcastEventResultCode.FAILURE, concat(out, " ")
    end
end

function TrustedEventsServer:UnreliableBroadcastToAllPlayers(eventName, ...)
    return self:BroadcastToPlayer("unreliable", ALL_PLAYERS, eventName, ...)
end

function TrustedEventsServer:Start()
    self.maid = Maid.New(script)
    self.playerConnections = {
        [ALL_PLAYERS] = PlayerConnection.NewUnreliableBroadcastConnection()
    }
    self.maid.player_joined_sub = Game.playerJoinedEvent:Connect(function(player) self:OnPlayerJoined(player) end)
    self.maid.player_left_sub = Game.playerLeftEvent:Connect(function(player) self:OnPlayerLeft(player) end)
    self.maid.handshake_sub = Events.ConnectForPlayer(ReliableEndpoint.READY, function (player)
        local connection = self.playerConnections[player]
        if connection then
            connection:StartEndpoint()
        end
    end)

    -- register server for API
    _G["<TE_SERVER_INSTANCE>"] = self
    print("INFO: [TrustedEventsServer] -- START")
end

function TrustedEventsServer:OnPlayerJoined(player)
    if self.playerConnections[player] then return end
    self.playerConnections[player] = PlayerConnection.New(player)
end

function TrustedEventsServer:OnPlayerLeft(player)
    local connection = self.playerConnections[player]
    self.playerConnections[player] = nil
    Maid.safeDestroy(connection)
end

---------------------------------------
-- Start Server
---------------------------------------
TrustedEventsServer:Start()




