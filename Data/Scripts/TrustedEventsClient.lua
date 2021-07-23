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
local Task, Events, UI = Task, Events, UI
local BroadcastEventResultCode = BroadcastEventResultCode
local warn = warn
local _G, script = _G, script
local gettime = time
local HUGE = math.maxinteger

local dtrace = function (...)  if DEBUG then print("[TEC]", ...) end end

_ENV = nil

---------------------------------------
-- Constants (same as Server)
---------------------------------------
local BROADCAST_CHANNEL = "0xFF"
local RESERVED_ENDPOINT_EVENT = ";"

---------------------------------------
-- Extended Modal State
---------------------------------------
local CHANGE_SUIT_TIME = 3 -- min ~2.5
local IN_MODAL = false
local MODAL_OFF_TIME = 0
local IN_EMOTE = false

---------------------------------------
-- Configs
---------------------------------------
-- snd only
local SMALL_CLIENT_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    -- (!) don't mess with this config: you can break client-to-server messaging
    NAME = "TSE Client [S]",
    MAX_MESSAGE_SIZE = 25,
    MAX_PACKET_SIZE = 26,
    MAX_DATA_BYTES = true,
    UPDATE_INTERVAL = 1.0/30,
    ACK_TIMEOUT_FACTOR = HUGE,     -- S Client don't ack anything
    PACKET_RESEND_DELAY_FACTOR = 7 -- S CLient acked by M Server
}

-- snd+rcv
local MID_CLIENT_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    NAME = "TSE Client [M]",
    UPDATE_INTERVAL = 1.0/7,
    MAX_MESSAGE_SIZE = 64,
    MAX_PACKET_SIZE = 84, --> 4*ceil((84+6)/3) = 120
    MAX_DATA_BYTES = true
}

-- rcv only
local BIG_CLIENT_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    NAME = "TSE Client [B]",
    ACK_TIMEOUT_FACTOR = 0,
}

-- rcv only
local UNRELIABLE_CONFIG = UnreliableEndpoint.DEFAULT_CONFIG {
    NAME = "TSE Client [U]"
}

---------------------------------------
-- Trusted Events Client
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
                -- TODO: message sublanguage interpreter
                print("unhandled message", event, tunpack(message))
            end
        else
            dtrace(format("WARNING: server sent unknown message: %q", message))
        end
    end
end

-- @ _DecodeFrame :: base64 -> header, data | false
function TrustedEventsClient._DecodeFrame(b64str)
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

-- NOTE: small endpoint's purpose is to send small messages very fast (i.e. in
-- combat). Small endpoint uses AckAbility to sent data it will interfere with
-- all modal activity (i.e. Mounts, Character, Emotes, etc.). If any modal
-- activity is present, we will only send packets through
-- Events.BroadcastToServer, assuming then client-to-server traffic in this
-- state will be low.
function TrustedEventsClient:_CanUseSmallEndpoint(size)
    local busy = size > SMALL_CLIENT_CONFIG.MAX_MESSAGE_SIZE or
        IN_MODAL or
        MODAL_OFF_TIME > gettime() or
        IN_EMOTE or
        #self.s_endpoint.message_queue > 16 or
        LOCAL_PLAYER.isMounted
    return not busy
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
    local size = MessagePack.encode(message, "measure")
    local ok, err = nil, nil
    if self:_CanUseSmallEndpoint(size) then
        ok, err = self.s_endpoint:SendMessage(message, size)
    else
        ok, err = self.m_endpoint:SendMessage(message, size)
    end
    if not ok then
        return BroadcastEventResultCode.FAILURE, err
    else
        return BroadcastEventResultCode.SUCCESS
    end
end

function TrustedEventsClient:Start()
    self.maid = Maid.New(script)
    self.s_endpoint = ReliableEndpoint.New(SMALL_CLIENT_CONFIG, "", gettime)
    self.m_endpoint = ReliableEndpoint.New(MID_CLIENT_CONFIG, "", gettime)
    self.b_endpoint = ReliableEndpoint.New(BIG_CLIENT_CONFIG, "", gettime)
    self.u_endpoint = UnreliableEndpoint.New(UNRELIABLE_CONFIG, "", gettime)


    self.maid:GiveTask(self.s_endpoint)
    self.maid:GiveTask(self.m_endpoint)
    self.maid:GiveTask(self.b_endpoint)
    self.maid:GiveTask(self.u_endpoint)

    -- find ack_ability among local player abilities
    while true do
        for _, ability in ipairs(LOCAL_PLAYER:GetAbilities()) do
            if ability.name == LOCAL_PLAYER.id then
                self.ack_ability = ability
                break
            end
        end
        if self.ack_ability ~= nil then
            dtrace("INFO: got ack")
            break
        else
            dtrace("INFO: waiting for channel ...")
            Task.Wait(MID_CLIENT_CONFIG.UPDATE_INTERVAL)
        end
    end

    -------------------------
    -- state closures:
    -------------------------
    local state_s_header = false
    local state_s_data = false
    local state_b_header = false

    -------------------------
    -- set-up endpoints
    -------------------------
    -- [S]
    self.s_endpoint:SetTransmitFrameCallback(function(header, data)
        state_s_header = header
        state_s_data = data
        -- pure magic! (see AckAbility.lua)
        self.ack_ability:Activate()
        self.ack_ability:Interrupt()
    end)
    self.maid.s_endpoint_update = Task.Spawn(function()
        local now = gettime()
        self.s_endpoint:Update(now)
    end)
    self.maid.s_endpoint_update.repeatCount = -1
    self.maid.s_endpoint_update.repeatInterval = SMALL_CLIENT_CONFIG.UPDATE_INTERVAL

    self.maid.s_endpoint_sub = self.ack_ability.castEvent:Connect(function(ack)
        if state_s_header then
            local data = MessagePack.encode(state_s_data)
            AckAbility.write(ack, state_s_header, data)
            state_s_header, state_s_data = false, false
        end
    end)

    -- [M]
    self.m_endpoint:SetSecondHeaderGetter(function()
        local now = gettime()
        self.b_endpoint:Update(now) -- to update state_b_header
        local header2 = state_b_header
        state_b_header = false
        return header2
    end)
    self.m_endpoint:SetSecondHeaderCallback(function(ack_s_header)
        self.s_endpoint:OnReceiveFrame(ack_s_header, nil)
    end)
    self.m_endpoint:SetTransmitFrameCallback(function(header, data)
        local mpacked = MessagePack.pack({header, data})
        local b64str = Base64.encode(mpacked)
        local ok, err = Events.BroadcastToServer(RESERVED_ENDPOINT_EVENT, b64str)
        if ok ~= BroadcastEventResultCode.SUCCESS then
            warn(format("[%s]: BroadcastEventResultCode: %d: %s", self.m_endpoint.id, ok, err))
        end
    end)
    self.maid.m_endpoint_sub = Events.Connect(RESERVED_ENDPOINT_EVENT, function(b64str)
        local header, data = TrustedEventsClient._DecodeFrame(b64str)
        if not header then return end
        self.m_endpoint:OnReceiveFrame(header, data)
    end)
    self.maid.m_endpoint_update = Task.Spawn(function()
        local now = gettime()
        self.m_endpoint:Update(now)
    end)
    self.maid.m_endpoint_update.repeatCount = -1
    self.maid.m_endpoint_update.repeatInterval = MID_CLIENT_CONFIG.UPDATE_INTERVAL

    -- [B]
    self.b_endpoint:SetTransmitFrameCallback(function(header, data)
        assert(not data, "sanity check, receive only")
        state_b_header = header
    end)
    self.maid.b_endpoint_sub = LOCAL_PLAYER.privateNetworkedDataChangedEvent:Connect(function(_, key)
        local b64str = LOCAL_PLAYER:GetPrivateNetworkedData(key)
        local header, data = TrustedEventsClient._DecodeFrame(b64str)
        if not header then return end
        self.b_endpoint:OnReceiveFrame(header, data)
    end)

    -- [U]
    self.u_endpoint:SetTransmitFrameCallback(function(_header, _data) error("receive only") end)
    self.maid.u_endpoint_sub = TRUSTED_EVENTS_HOST.networkedPropertyChangedEvent:Connect(function(_, prop)
        if prop ~= BROADCAST_CHANNEL then return end
        local b64str = TRUSTED_EVENTS_HOST:GetCustomProperty(BROADCAST_CHANNEL)
        local header, data = TrustedEventsClient._DecodeFrame(b64str)
        if not header then return end
        self.u_endpoint:OnReceiveFrame(header, data)
    end)


    self.s_endpoint:SetReceiveMessageCallback(TrustedEventsClient._OnMessageReceive)
    self.m_endpoint:SetReceiveMessageCallback(TrustedEventsClient._OnMessageReceive)
    self.b_endpoint:SetReceiveMessageCallback(TrustedEventsClient._OnMessageReceive)
    self.u_endpoint:SetReceiveMessageCallback(TrustedEventsClient._OnMessageReceive)

    self.s_endpoint:UnlockTransmission()
    self.m_endpoint:UnlockTransmission()
    self.b_endpoint:UnlockTransmission()
    self.u_endpoint:UnlockTransmission()

    -----------------------------------
    -- set Extended IN_MODAL flags
    -----------------------------------
    self.maid.modal_sub = UI.coreModalChangedEvent:Connect(function(val)
        IN_MODAL = val and true
        MODAL_OFF_TIME = val and HUGE or (gettime() + CHANGE_SUIT_TIME)
    end)
    self.maid.emote_on_sub = LOCAL_PLAYER.emoteStartedEvent:Connect(function()
        IN_EMOTE = true
    end)
    self.maid.emote_off_sub = LOCAL_PLAYER.emoteStoppedEvent:Connect(function()
        IN_EMOTE = false
    end)

    -----------------------------------
    -- initiate handshake with server
    -----------------------------------
    while Events.BroadcastToServer(ReliableEndpoint.READY) ~= BroadcastEventResultCode.SUCCESS do
        Task.Wait(MID_CLIENT_CONFIG.UPDATE_INTERVAL)
    end

    -----------------------------------
    -- register client for API
    -----------------------------------
    _G["<TE_CLIENT_INSTANCE>"] = self
    print("INFO: [TrustedEventsClient] -- START")

    ---------------------------------------
    -- DEBUG loop (dump counters every 5s)
    ---------------------------------------
    if DEBUG then
        self.maid.debug_loop = Task.Spawn(function()
            print("-- CLIENT ---------------------------------------------------------------------------------------")
            print(self.s_endpoint)
            print(self.m_endpoint)
            print(self.b_endpoint)
            print(self.u_endpoint)
            print("-------------------------------------------------------------------------------------------------")
        end)
        self.maid.debug_loop.repeatCount = -1
        self.maid.debug_loop.repeatInterval = 5
    end
end

---------------------------------------
-- Client Start
---------------------------------------
TrustedEventsClient:Start()