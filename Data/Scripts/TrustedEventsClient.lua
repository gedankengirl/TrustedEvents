local DEBUG = true
--[[
    Trusted Events Client
]]
_ENV.require = _G.export or require

local dtrace = function (...)  if DEBUG then print("[TEC]", ...) end end
local dwarn  = function (str)  if DEBUG then warn(str) end end
local format = string.format

local Maid = require("Maid")
local Base64 = require("Base64")
local MessagePack = require("MessagePack")
local AckAbility = require("AckAbility")

local BitVector32 = require("BitVector32")
local ReliableEndpoint = require("ReliableEndpoint")

local TRUSTED_EVENTS_HOST = script:GetCustomProperty("TrustedEventsHost"):WaitForObject()
local LOCAL_PLAYER = Game.GetLocalPlayer()

local CLIENT_TICK = 0.3

local CLIENT_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    -- put overrides here:
    PACKET_RESEND_DELAY = 2 * CLIENT_TICK,
    MAX_UNREALIBLE_PACKET_SIZE = 24,
    MAX_UNREALIBLE_MESSAGE_SIZE = 22,
    MAX_REALIBLE_PACKET_SIZE = 24,
    MAX_REALIBLE_MESSAGE_SIZE = 22,
    MAX_RELIABLE_PACKETS_PER_FRAME = 1,
}

---------------------------------------
--Truste Events Client
---------------------------------------

local TrustedEventsClient = {}

function TrustedEventsClient:Start()
    self.maid = Maid.New(script)
    self.endpoint = ReliableEndpoint.New(CLIENT_CONFIG)

    -- find ack_ability among local player abilities
    local channel, ack_ability = nil, nil
    while true do
        for _, ability in ipairs(LOCAL_PLAYER:GetAbilities()) do
            dtrace(ability.name)
            local id, ch = CoreString.Split(ability.name, ",")
            if id == LOCAL_PLAYER.id then
                channel = ch
                ack_ability = ability
                break
            end
        end
        if channel ~= nil and ack_ability ~= nil then
            dtrace("got channel", channel)
            break
        else
            dtrace("waiting for channel ...")
            Task.Wait(CLIENT_TICK)
        end
    end
    dtrace("activating endpoint")
    self.channel = channel
    self.ack_ability = ack_ability
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
        if prop ~= self.channel then return end
        local str64 = TRUSTED_EVENTS_HOST:GetCustomProperty(self.channel)
        -- sometimes we can just clear property with empty value, do nothing
        if not str64 or str64 == "" then
            return
        end
        local ok, frame = pcall(Base64.decode, str64)
        if not ok then
            dwarn("base64 error", frame)
            return
        end
        ok, frame = pcall(MessagePack.decode, frame)
        -- check for proper frame format: {heder:int32, data:str}
        if not ok or type(frame) ~= "table" or #frame ~= 2 or math.type(frame[1]) ~= "integer" then
            dwarn("not a proper frame ", str64) -- use original string for investigation
            return
        end
        local header = frame[1]
        local data = frame[2]
        -- TODO: pcall
        self.endpoint:OnReceiveFrame(header, data)
    end)

    self.maid.update_loop = Task.Spawn(function()
        local now = time()
        self.endpoint:Update(now)
    end)
    self.maid.update_loop.repeatCount = -1
    self.maid.update_loop.repeatInterval = CLIENT_TICK
    self.endpoint:UnlockTransmission()

    -- set how we handle received messages
    -- in this case we dispatch client local event with the same name
    self.endpoint:SetReceiveMessageCallback(function(queue)
        while not queue:IsEmpty() do
            local message = queue:Pop()
            local ok, val = pcall(MessagePack.decode, message)
            if not ok then
                dwarn(val)
            elseif type(val) == "table" and val.eventName then
                local event = val.eventName
                val.eventName = nil
                -- TODO: proper unpack(t, 1, t.n)
                Events.Broadcast(event, table.unpack(val))
            else
                dtrace(string.format("WARNING: server sent unknown message: %q", message))
            end
        end
    end)

    -- send READY to server
    while Events.BroadcastToServer(ReliableEndpoint.READY) ~= BroadcastEventResultCode.SUCCESS do
        Task.Wait(CLIENT_TICK)
    end
    dtrace("READY")
end

-- Start
TrustedEventsClient:Start()