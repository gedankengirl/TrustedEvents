local DEBUG = true
--[[
    Trusted Events Server
]]
_ENV.require = _G.export or require

local dtrace = function (...)  if DEBUG then print("[TES]", ...) end end
local dwarn  = function (str)  if DEBUG then warn(str) end end
local format = string.format

local Maid = require("Maid")
local Base64 = require("Base64")
local MessagePack = require("MessagePack")
local AckAbility = require("AckAbility")

local BitVector32 = require("BitVector32")
local ReliableEndpoint = require("ReliableEndpoint")

local SERVER_TICK = 0.2

local SERVER_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    -- put overrides here:
    PACKET_RESEND_DELAY = 2 * SERVER_TICK,
}

print("INFO: Trusted Events Server Configuration")
print(SERVER_CONFIG)

---------------------------------------
-- Channels: Networked Properties
---------------------------------------
local NUM_CHANNELS = 16 + 1       -- one custom property per player + 1 for broadcast
local NUM_ACKS = NUM_CHANNELS - 1 -- one ability per player

local TRUSTED_EVENTS_HOST, ACK_ABILITY_POOL, CHANNELS, IN_USE do
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
    table.sort(CHANNELS, function(a, b) return tonumber(a) < tonumber(b) end)
    IN_USE = BitVector32.New()
    for i= 0, 31 do
        IN_USE[i] = not CHANNELS[i] -- write `true` at all indices absent in CHANNELS
    end
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

function PlayerConnection.New(player)
    assert(player)
    local self = setmetatable({}, PlayerConnection)
    self.maid = Maid.New()
    local channel, ack_ability = _borrow_channel()
    local config = SERVER_CONFIG {NAME = channel}
    self.channel = channel

    -- ack ability
    -- check that all preallocated abilities good for us
    AckAbility.check(ack_ability)
    ack_ability.owner = player
    ack_ability.isEnabled = true
    -- notify client about his channel by renaming ability
    ack_ability.name = player.id ..','.. channel
    self.ack_ability = ack_ability

    self.player = player
    self.unique = 0
    self.started = false

    -- endpoint
    self.endpoint = ReliableEndpoint.New(config, channel)

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
        -- networked custom properties are not tolerated for non-text strings
        local b64str = Base64.encode(mpacked)
        TRUSTED_EVENTS_HOST:SetNetworkedCustomProperty(self.channel, b64str)
    end)
    -- connect endpoint and ability
    self.maid.ability_sub = self.ack_ability.readyEvent:Connect(function()
        local header, data = AckAbility.read(self.ack_ability)
        if header then
            local r = math.random()
            if r < 0.5 then
                dtrace("XXX drop frame")
                return
            end
            self.endpoint:OnReceiveFrame(header, data)
        else -- got garbage
            dtrace(data)
        end
    end)

    -- endpoint update loop
    self.maid.update_loop = Task.Spawn(function()
        local now = time()
        self.endpoint:Update(now)
    end)
    self.maid.update_loop.repeatCount = -1
    self.maid.update_loop.repeatInterval = SERVER_TICK

    -- now endpoint is ready to transmit frames to client
    self.endpoint:UnlockTransmission()

    dwarn("Endpoint activated: " .. self.endpoint.id)
end

function PlayerConnection:Destroy()
    TRUSTED_EVENTS_HOST:SetNetworkedCustomProperty(self.channel, "")
    self.maid:Destroy()
end

---------------------------------------
--Trusted Events Server
---------------------------------------
local TrustedEventsServer = {}

-- Global method that mimics `Events.BroadcastToPlayer`
function _G.TEBroadcastToPayer(player, eventName, ...)
    assert(player and player:IsA("Player"))
    assert(eventName and type(eventName) == "string")
    TrustedEventsServer:BroadcastToPlayer(player, eventName, ...)
end

function TrustedEventsServer:BroadcastToPlayer(player, eventName, ...)
    local connection = self.playerConnections[player]
    assert(connection)
    local message = MessagePack.encode({eventName = eventName, ...})
    connection.endpoint:SendMessage(message)
end

function TrustedEventsServer:Start()
    self.maid = Maid.New(script)
    self.playerConnections = {}
    self.maid.player_joined_sub = Game.playerJoinedEvent:Connect(function(player) self:OnPlayerJoined(player) end)
    self.maid.player_left_sub = Game.playerLeftEvent:Connect(function(player) self:OnPlayerLeft(player) end)
    self.maid.handshake_sub = Events.ConnectForPlayer(ReliableEndpoint.READY, function (player)
        local connection = self.playerConnections[player]
        if connection then
            connection:StartEndpoint()
        end
    end)
    warn("INFO: [TrustedEventsServer] -- START")
end

function TrustedEventsServer:OnPlayerJoined(player)
    if self.playerConnections[player] then return end
    self.playerConnections[player] = PlayerConnection.New(player)

    if DEBUG then -- send 100 events to player
        local pretty_big_string = ("0"):rep(128)
        for i = 1, 100 do
            TrustedEventsServer:BroadcastToPlayer(player, "TE_TEST_EVENT", i, Vector4.New(i, i, i, i), pretty_big_string)
        end
    end
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




