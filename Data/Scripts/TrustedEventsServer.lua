local DEBUG = true
--[[

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
        IN_USE[i] = not CHANNELS[i] -- write true at all indices absent in CHANNELS
    end
end

-- _borrow_channel :: nil ^-> prop:str, ack:AckAbility
-- returns custom property name and designated ack ability
local function _borrow_channel()
    local idx = IN_USE:find_and_swap(false)
    assert(idx <= NUM_ACKS)
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
    local channel, ack_ability = _borrow_channel()
    AckAbility.check(ack_ability)
    local config = SERVER_CONFIG {NAME = channel}
    local self = setmetatable({}, PlayerConnection)
    self.maid = Maid.New()
    self.player = player.id

    -- networked property
    self.channel = channel
    self.unique = 0

    -- endpoint
    self.endpoint = ReliableEndpoint.New(config, channel)
    self.on_rcv_frame = self.endpoint:GetIncomingFrameCallback()
    self.endpoint:SetTransmitCallback(function (header, data)
        -- first 4 bits of header are reserved for the user, so we are putting
        -- a counter in it in order to fire networkedPropertyChangedEvent even
        -- for a non-unique string.
        header = header | (self.unique & ~(-1 << 4))
        self.unique = self.unique + 1
        local packed = MessagePack.pack({header, data})
        local encoded = Base64.encode(packed)
        TRUSTED_EVENTS_HOST:SetNetworkedCustomProperty(self.channel, encoded)
    end)

    -- ack ability
    self.ack_ability = ack_ability -- can be removed
    ack_ability.owner = player
    ack_ability.isEnabled = true

    -- rudimentary connection state machine
    self.maid.ability_sub = ack_ability.readyEvent:Connect(function()
        local header, data = AckAbility.read(self.ack_ability)
        -- wait for client ready ...
        if not header or data ~= ReliableEndpoint.READY then return end
        -- client ready! change event subscription (the old one will be disconnected)
        self.maid.ability_sub = nil -- disconnects subscription, not necessary
        -- connect endpoint and ability
        local on_receive_frame =  self.endpoint:GetIncomingFrameCallback()
        self.maid.ability_sub = ack_ability.readyEvent:Connect(function()
            header, data = AckAbility.read(self.ack_ability)
            if header then
                on_receive_frame(header, data)
            else -- got garbage
                dtrace(data)
            end
        end)
        -- now endpoint is ready to transmit
        self.endpoint:UnlockTransmission()
    end)
    local on_receive_frame =  self.endpoint:GetIncomingFrameCallback()
    self.maid.ability_sub = ack_ability.readyEvent:Connect(function(_ability)
        local header, data = AckAbility.read(self.ack_ability)
        if header then
            on_receive_frame(header, data)
        else -- got garbage
            dtrace(data)
        end
    end)
    -- notify client about his channel
    TRUSTED_EVENTS_HOST:SetNetworkedCustomProperty(self.channel, player.id)

    -- set clean-up
    self.maid:GiveTask(function () _free_channel(self.channel) end) -- will free ability too
end

function PlayerConnection:Destroy()
    TRUSTED_EVENTS_HOST:SetNetworkedCustomProperty(self.channel, "")
    self.maid:Destroy()
end

---------------------------------------
--Truste Events Server
---------------------------------------
local TrustedEventsServer = {type = "TrustedEventsServer"}
TrustedEventsServer.__index = TrustedEventsServer

function TrustedEventsServer:Start()
    self.maid = Maid.New()
    self.playerConnections = {}
    self.maid.player_joined = Game.playerJoinedEvent:Connect(function(player) self:OnPlayerJoined(player) end)
    self.maid.player_left = Game.playerLeftEvent:Connect(function(player) self:OnPlayerLeft(player) end)
    warn("INFO: [TrustedEventsServer] -- START")
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




