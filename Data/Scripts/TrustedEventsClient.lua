--[[
    Trusted Events Client
]]
local DEBUG = false

_ENV.require = _G.import or require

local Maid = require("Maid")
local Base64 = require("Base64")
local MessagePack = require("MessagePack")
local AckAbility = require("AckAbility")

local ReliableEndpoint = require("ReliableEndpoint")
local UnreliableEndpoint = require("UnreliableEndpoint")

local TRUSTED_EVENTS_HOST = script:GetCustomProperty("TrustedEventsHost"):WaitForObject()
local LOCAL_PLAYER = Game.GetLocalPlayer()

local select, tunpack, mtype, error = select, table.unpack, math.type, error
local format, print, random = string.format, print, math.random
local assert, ipairs, type, pcall = assert, ipairs, type, pcall
local Task, Events = Task, Events
local BroadcastEventResultCode = BroadcastEventResultCode
local _G, script = _G, script

local gettime = time

local dtrace = function (...)  if DEBUG then print("[TEC]", ...) end end

_ENV = nil

local BROADCAST_CHANNEL = "0xFF"
local S_ENDPOINT_EVENT = ";"

local SMALL_CLIENT_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
     -- (!) we prohibit sending unreliable messages over AckAbility
     -- (!) don't mess with this config: you can break client-to-server messaging
    NAME = "TSE [S] Client",
    MAX_MESSAGE_SIZE = 25,
    MAX_PACKET_SIZE = 26,
    MAX_DATA_BYTES = true,
    UPDATE_INTERVAL = 1.0/30,
    ACK_TIMEOUT_FACTOR = 10,
    PACKET_RESEND_DELAY_FACTOR = 15
}

local BIG_CLIENT_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    NAME = "TSE [B] Client",
    SEQ_BITS = 4,
    UPDATE_INTERVAL = 1.0/15, -- updates will be forced by SMALL Client
    ACK_TIMEOUT_FACTOR = 1,   -- send acks 15 time a second (without physical layer)
}

local UNRELIABLE_CONFIG = UnreliableEndpoint.DEFAULT_CONFIG {
    NAME = "TSE [U] Client"
}

---------------------------------------
--Truste Events Client
---------------------------------------
local TrustedEventsClient = {}

function TrustedEventsClient._OnMessageReceive(queue)
    while not queue:IsEmpty() do
        local message = queue:Pop()
        if type(message) == "table" then
            local event = message[#message]
            message[#message] = nil
            if type(event) == "string" then
                Events.Broadcast(event, tunpack(message))
            else
                -- TODO: message intepretator
                print("unhandled message", event, tunpack(message))
            end
        else
            dtrace(format("WARNING: server sent unknown message: %q", message))
        end
    end
end

-- @ _DecodeFrame :: self, base64 -> header, data | false
function TrustedEventsClient:_DecodeFrame(b64str)
    if not b64str or b64str == "" then
        return false
    end
    local ok, frame = pcall(Base64.decode, b64str)
        if not ok then
            dtrace("base64 error", frame)
            return false
        end
        ok, frame = pcall(MessagePack.decode, frame)
        -- check for proper frame format: {header:int32, data:table|nil}
        if not ok or type(frame) ~= "table" or mtype(frame[1]) ~= "integer" then
            dtrace("not a proper frame: "..  b64str) -- use original string for investigation
            return false
        end
        local header = frame[1]
        local data = frame[2]
        return header, data
end

function TrustedEventsClient:BroadcastToServer(event, ...)
    -- be careful with nils
    for i = 1, select("#", ...) do
        if select(i, ...) == nil then
            error("*nil* event args not allowed: arg#"..i, 3)
        end
    end
    local message = {...}
    message[#message + 1] = event
    local ok, err = self.s_endpoint:SendMessage(message, false)
    if not ok then
        return BroadcastEventResultCode.FAILURE, err
    else
        return BroadcastEventResultCode.SUCCESS
    end
end

function TrustedEventsClient:Start()
    self.maid = Maid.New(script)
    self.s_endpoint = ReliableEndpoint.New(SMALL_CLIENT_CONFIG, "", gettime)
    self.b_endpoint = ReliableEndpoint.New(BIG_CLIENT_CONFIG, "", gettime)
    self.u_endpoint = UnreliableEndpoint.New(UNRELIABLE_CONFIG, "", gettime)
    self.u_endpoint:SetTransmitFrameCallback(function(header, data) error("receive only") end)

    self.maid:GiveTask(self.s_endpoint)
    self.maid:GiveTask(self.b_endpoint)
    self.maid:GiveTask(self.u_endpoint)

    -- find ack_ability among local player abilities
    local ack_ability
    while true do
        for _, ability in ipairs(LOCAL_PLAYER:GetAbilities()) do
            if ability.name == LOCAL_PLAYER.id then
                ack_ability = ability
                break
            end
        end
        if ack_ability ~= nil then
            dtrace("INFO: got ack")
            break
        else
            dtrace("INFO: waiting for channel ...")
            Task.Wait(SMALL_CLIENT_CONFIG.UPDATE_INTERVAL)
        end
    end
    self.ack_ability = ack_ability
    -------------------------
    -- state closures:
    -------------------------
    local state_header_0 = false
    local state_data_0 = false
    local state_header_1 = false

    -- wire up ack-ability
    self.maid.ack_sub = ack_ability.castEvent:Connect(function(ack)
        if state_header_0 then
            local data = MessagePack.encode(state_data_0)
            AckAbility.write(ack, state_header_0, data)
            state_header_0, state_data_0 = false, false
        end
    end)
    -- set-up endpoints
    self.s_endpoint:SetSecondHeaderGetter(function() return state_header_1 end)
    self.s_endpoint:SetSecondHeaderCallback(function(header)
        self.b_endpoint:OnReceiveFrame(header, nil)
    end)
    self.b_endpoint:SetTransmitFrameCallback(function(header, data)
        assert(not data, "sanity check")
        state_header_1 = header
    end)

    self.s_endpoint:SetTransmitFrameCallback(function (header, data)
        local now = gettime()
        self.b_endpoint:Update(now) -- to refresh state_header_1
        state_header_0 = ReliableEndpoint.header_merge(header, state_header_1)
        state_header_1 = false
        state_data_0 = data
        -- pure magic! (see AckAbility.lua)
        self.ack_ability:Activate()
        self.ack_ability:Interrupt()
    end)

    self.s_endpoint:SetReceiveMessageCallback(TrustedEventsClient._OnMessageReceive)
    self.b_endpoint:SetReceiveMessageCallback(TrustedEventsClient._OnMessageReceive)
    self.u_endpoint:SetReceiveMessageCallback(TrustedEventsClient._OnMessageReceive)
    self.maid.s_endpoint_sub = Events.Connect(S_ENDPOINT_EVENT, function(b64str)
        assert(b64str, "sombody hijack our event?")
        local header, data = self:_DecodeFrame(b64str)
        if not header then return end
        self.s_endpoint:OnReceiveFrame(header, data)
    end)

    self.maid.s_endpoint_update = Task.Spawn(function()
        local now = gettime()
        self.s_endpoint:Update(now)
    end)
    self.maid.s_endpoint_update.repeatCount = -1
    self.maid.s_endpoint_update.repeatInterval = SMALL_CLIENT_CONFIG.UPDATE_INTERVAL

    self.maid.b_endpoint_sub = LOCAL_PLAYER.privateNetworkedDataChangedEvent:Connect(function(_, key)
        local b64str = LOCAL_PLAYER:GetPrivateNetworkedData(key)
        local header, data = self:_DecodeFrame(b64str)
        if not header then return end
        self.b_endpoint:OnReceiveFrame(header, data)
    end)

    self.maid.unreliable_sub = TRUSTED_EVENTS_HOST.networkedPropertyChangedEvent:Connect(function(_, prop)
        if prop ~= BROADCAST_CHANNEL  then return end
        local b64str = TRUSTED_EVENTS_HOST:GetCustomProperty(BROADCAST_CHANNEL)
        local header, data = self:_DecodeFrame(b64str)
        if not header then return end
        self.u_endpoint:OnReceiveFrame(header, data)
    end)

    self.s_endpoint:UnlockTransmission()
    self.b_endpoint:UnlockTransmission()
    self.u_endpoint:UnlockTransmission()

    -- initiate handshake with server
    while Events.BroadcastToServer(ReliableEndpoint.READY) ~= BroadcastEventResultCode.SUCCESS do
        Task.Wait(SMALL_CLIENT_CONFIG.UPDATE_INTERVAL)
    end
    -- register client for API
    _G["<TE_CLIENT_INSTANCE>"] = self
    print("INFO: [TrustedEventsClient] -- START")

    self.maid.debug = Task.Spawn(function()
        print("-- CLIENT ---------------------------------------------------------------------------------------")
        print(self.s_endpoint)
        print(self.b_endpoint)
        print(self.u_endpoint)
        print("-------------------------------------------------------------------------------------------------")
    end)
    self.maid.debug.repeatCount = -1
    self.maid.debug.repeatInterval = 5
end

-- Start
TrustedEventsClient:Start()