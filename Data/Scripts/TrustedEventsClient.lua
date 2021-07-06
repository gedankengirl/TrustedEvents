--[[
    Trusted Events Client
]]
local DEBUG = false

local require = _G.export or require

local Maid = require("Maid")
local Base64 = require("Base64")
local MessagePack = require("MessagePack")
local AckAbility = require("AckAbility")

local ReliableEndpoint = require("ReliableEndpoint")

local TRUSTED_EVENTS_HOST = script:GetCustomProperty("TrustedEventsHost"):WaitForObject()
local LOCAL_PLAYER = Game.GetLocalPlayer()

local select, tunpack, mtype, error = select, table.unpack, math.type, error
local format, print = string.format, print
local assert, ipairs, type, pcall = assert, ipairs, type, pcall
local Task, Events, CoreString = Task, Events, CoreString
local BroadcastEventResultCode, time = BroadcastEventResultCode, time
local _G, script = _G, script

local dtrace = function (...)  if DEBUG then print("[TEC]", ...) end end

_ENV = nil

local CLIENT_TICK = 0.3

local CLIENT_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
     -- (!) we prohibit sending unreliable messages over AckAbility
     -- (!) don't mess with this config: you can break client-to-server messaging
    MAX_UNREALIBLE_PACKET_SIZE = 0,
    MAX_UNREALIBLE_MESSAGE_SIZE = 0,
    MAX_REALIBLE_PACKET_SIZE = 26,
    MAX_REALIBLE_MESSAGE_SIZE = 25,
    MAX_DATA_BYTES = 27,
    MAX_RELIABLE_PACKETS = 1,
    UPDATE_INTERVAL = CLIENT_TICK,
    ACK_TIMEOUT = 2 * CLIENT_TICK,
    PACKET_RESEND_DELAY = 3 * CLIENT_TICK
}
---------------------------------------
--Truste Events Client
---------------------------------------
local TrustedEventsClient = {}

function TrustedEventsClient:BroadcastToServer(eventName, ...)
    -- be very careful with size budget:
    for i = 1, select("#", ...) do
        if select(i, ...) == nil then
            error("`nil` event argument not allowed: arg#"..i, 3)
        end
    end
    local message = {...}
    message[#message + 1] = eventName
    local ok, err = self.endpoint:SendMessage(message, false)
    if not ok then
        return BroadcastEventResultCode.FAILURE, err
    else
        return BroadcastEventResultCode.SUCCESS
    end
end

function TrustedEventsClient:Start()
    self.maid = Maid.New(script)
    self.endpoint = ReliableEndpoint.New(CLIENT_CONFIG, self.channel, time)

    -- find ack_ability among local player abilities
    local channel, ack_ability, broadcast = nil, nil, nil
    while true do
        for _, ability in ipairs(LOCAL_PLAYER:GetAbilities()) do
            local id, ch, br = CoreString.Split(ability.name, ",")
            if id == LOCAL_PLAYER.id then
                channel = assert(ch)
                broadcast = assert(br)
                ack_ability = ability
                break
            end
        end
        if channel ~= nil and ack_ability ~= nil then
            dtrace("INFO: got channel", channel)
            break
        else
            dtrace("INFO: waiting for channel ...")
            Task.Wait(CLIENT_TICK)
        end
    end
    self.channel = channel
    self.broadcast = broadcast
    self.ack_ability = ack_ability
    -- TODO: hide them in closure?
    self.header = false
    self.data = false
    -- write to ability
    self.maid.ack_sub = ack_ability.castEvent:Connect(function()
        if self.header and self.data then
            AckAbility.write(self.ack_ability, self.header, self.data)
            self.header, self.data = false, false
        end
    end)
    --  endpoint setup
    self.endpoint:SetTransmitFrameCallback(function (header, data)
        self.header = header
        self.data = data
        -- pure magic! (see AckAbility.lua)
        self.ack_ability:Activate()
        self.ack_ability:Interrupt()
    end)

    self.maid.channel_sub = TRUSTED_EVENTS_HOST.networkedPropertyChangedEvent:Connect(function(_, prop)
        local chan = (prop == channel and channel) or (prop == broadcast and broadcast)
        if not chan then return end

        local str64 = TRUSTED_EVENTS_HOST:GetCustomProperty(chan)
        -- sometimes we can just clear property with empty value, do nothing
        if not str64 or str64 == "" then
            return
        end
        local ok, frame = pcall(Base64.decode, str64)
        if not ok then
            dtrace("base64 error", frame)
            return
        end
        ok, frame = pcall(MessagePack.decode, frame)
        -- check for proper frame format: {header:int32, data:str}
        if not ok or type(frame) ~= "table" or #frame ~= 2 or mtype(frame[1]) ~= "integer" then
            dtrace("not a proper frame: "..  str64) -- use original string for investigation
            return
        end
        local header = frame[1]
        local data = frame[2]
        self.endpoint:OnReceiveFrame(header, data)
    end)

    self.maid.update_loop = Task.Spawn(function()
        local now = time()
        self.endpoint:Update(now)
    end)
    self.maid.update_loop.repeatCount = -1
    self.maid.update_loop.repeatInterval = CLIENT_CONFIG.UPDATE_INTERVAL

    self.endpoint:UnlockTransmission()

    -- set how we handle received messages
    -- here we dispatch client-local event with the same name
    self.endpoint:SetReceiveMessageCallback(function(queue)
        while not queue:IsEmpty() do
            local message = queue:Pop()
            if type(message) == "table" and message.eventName then
                local eventName = assert(message.eventName)
                local n = assert(message.n)
                message.eventName = nil
                message.n = nil
                Events.Broadcast(eventName, tunpack(message, 1, n))
            else
                dtrace(format("WARNING: server sent unknown message: %q", message))
            end
        end
    end)

    -- initiate handshake with server
    while Events.BroadcastToServer(ReliableEndpoint.READY) ~= BroadcastEventResultCode.SUCCESS do
        Task.Wait(CLIENT_CONFIG.UPDATE_INTERVAL)
    end
    -- register client for API
    _G["<TE_CLIENT_INSTANCE>"] = self
    print("INFO: [TrustedEventsClient] -- START")
end

-- Start
TrustedEventsClient:Start()