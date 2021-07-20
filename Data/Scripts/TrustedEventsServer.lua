---@diagnostic disable: undefined-field
--[[
    Trusted Events Server
]]
local DEBUG = false

_ENV.require = _G.import or require

local Maid = require("Maid")
local Base64 = require("Base64")
local MessagePack = require("MessagePack")
local AckAbility = require("AckAbility")

local ReliableEndpoint = require("ReliableEndpoint")
local UnreliableEndpoint = require("UnreliableEndpoint")

local format, tpack, tunpack = string.format, table.pack, table.unpack
local setmetatable, print, warn = setmetatable, print, warn or print
local tostring, tonumber, concat = tostring, tonumber, table.concat
local mtype = math.type
local select, pairs, next, type = select, pairs, next, type
local assert, error, pcall = assert, error, pcall
local Task, Game, Events = Task, Game, Events
local BroadcastEventResultCode = BroadcastEventResultCode
local PrivateNetworkedDataResultCode = PrivateNetworkedDataResultCode
local CoreDebug = CoreDebug
local gettime = time
local _G, script = _G, script
local HUGE = math.maxinteger

local dtrace = function (...)  if DEBUG then print("[TES]", ...) end end

---------------------------------------
-- Constants (same as Client)
---------------------------------------
local NUM_ACKS = 32 -- max players count
local BIG_KEY_FMT = "<~%d~>" -- seq key
local BROADCAST_CHANNEL = "0xFF"
local RESERVED_ENDPOINT_EVENT = ";"

_ENV = nil

---------------------------------------
-- Configs
---------------------------------------
-- rcv only
local SMALL_SERVER_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
   NAME = "TSE Server [S]: ",
   ACK_TIMEOUT_FACTOR = 0,
}

-- snd+rcv
local MID_SERVER_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    NAME = "TSE Server [M]: ",
    UPDATE_INTERVAL = 1.0/7,
    MAX_MESSAGE_SIZE = 64,
    MAX_PACKET_SIZE = 84, --> 4*ceil((84+6)/3) -> 120
    MAX_DATA_BYTES = true
}

-- snd only
local BIG_SERVER_CONFIG = ReliableEndpoint.DEFAULT_CONFIG {
    NAME = "TSE Server [B]: ",
    UPDATE_INTERVAL = 1.0/10,
    MAX_MESSAGE_SIZE = 512,
    MAX_PACKET_SIZE = 768 - 6, --> 1024
    MAX_DATA_BYTES = true,
    ACK_TIMEOUT_FACTOR = HUGE,     -- B Server don't ack anything
    PACKET_RESEND_DELAY_FACTOR = 3 -- B Server acked by M Client
}

local UNRELIABLE_CONFIG = UnreliableEndpoint.DEFAULT_CONFIG {
    NAME = "TSE Server [U]: ",
    UPDATE_INTERVAL = 1.0/7,
    MAX_MESSAGE_SIZE = 1024,
    MAX_PACKET_SIZE = 1536 - 6, --> 2048
}

dtrace("INFO: Trusted Events Server Configuration")
dtrace(SMALL_SERVER_CONFIG)
dtrace(MID_SERVER_CONFIG)
dtrace(BIG_SERVER_CONFIG)
dtrace(UNRELIABLE_CONFIG)

---------------------------------------
-- Ack Ability Pool
---------------------------------------
local TRUSTED_EVENTS_HOST, ACK_ABILITY_POOL do
    TRUSTED_EVENTS_HOST = script:GetCustomProperty("TrustedEventsHost"):WaitForObject()
    ACK_ABILITY_POOL = TRUSTED_EVENTS_HOST:FindDescendantsByType("Ability")
    assert(#ACK_ABILITY_POOL >= NUM_ACKS , "can't find enough AckAbilities, need: " .. tostring(NUM_ACKS))
    for i=1, #ACK_ABILITY_POOL do
        AckAbility.check(ACK_ABILITY_POOL[i])
    end
end

-- _borrow_ack :: player ^-> ack:AckAbility
-- returns designated ack ability
local function _borrow_ack(player)
    assert(player)
    for i=1, #ACK_ABILITY_POOL do
        local ack = ACK_ABILITY_POOL[i]
        if ack.owner == nil then
            ack.owner = player
            ack.isEnabled = true
            ack.name = player.id
            return ack
        end
    end
end

-- _free_ack :: player, ack:AckAbility ^-> nil
local function _free_ack(player, ability)
    assert(player)
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
    self.ack_ability = _borrow_ack(player)
    self.player = player
    self.started = false

    -- endpoints
    self.s_endpoint = ReliableEndpoint.New(SMALL_SERVER_CONFIG, player.name, gettime)
    self.m_endpoint = ReliableEndpoint.New(MID_SERVER_CONFIG, player.name, gettime)
    self.b_endpoint = ReliableEndpoint.New(BIG_SERVER_CONFIG, player.name, gettime)

    -- set clean-up on destroy
    self.maid:GiveTask(function () _free_ack(player, self.ack_ability) end)
    self.maid:GiveTask(self.s_endpoint)
    self.maid:GiveTask(self.m_endpoint)
    self.maid:GiveTask(self.b_endpoint)
    return self
end

function PlayerConnection._DecodeFrame(b64str)
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

function PlayerConnection:_OnMessageReceive(queue)
    while not queue:IsEmpty() do
        local message = queue:Pop()
        if type(message) == "table" then
            local event = message[#message]
            message[#message] = nil
            if type(event) == "string" then
                Events.Broadcast(event, self.player, tunpack(message))
            else
                -- TODO: message sublanguage interpreter
                print("unhandled message", event, tunpack(message))
            end
        else
            dtrace(format("WARNING: client sent unknown message: %q", message))
        end
    end
end

function PlayerConnection:StartEndpoint()
    if self.started then return end
    -------------------------
    -- set-up endpoints
    -------------------------
    -- [S]
    -- state closure
    local state_s_header = false
    self.s_endpoint:SetTransmitFrameCallback(function(header, data)
        assert(not data, "sanity check, receive only")
        state_s_header = header
    end)
    self.maid.s_endpoint_sub = self.ack_ability.readyEvent:Connect(function(ability)
        local header, data = AckAbility.read(ability)
        if header then
            local ok, packet = pcall(MessagePack.decode, data)
            if not ok then error(packet) end
            self.s_endpoint:OnReceiveFrame(header, packet)
        else
            dtrace("AckAbility receive garbage: ", data)
        end
    end)

    -- [M]
    self.m_endpoint:SetSecondHeaderGetter(function()
        local now = gettime()
        self.s_endpoint:Update(now) -- to update state_s_header
        local header2 = state_s_header
        state_s_header = false
        return header2
    end)
    self.m_endpoint:SetSecondHeaderCallback(function(ack_b_header)
        self.b_endpoint:OnReceiveFrame(ack_b_header, nil)
    end)
    self.m_endpoint:SetTransmitFrameCallback(function(header, data)
        local mpacked = MessagePack.pack({header, data})
        local b64str = Base64.encode(mpacked)
        local ok = Events.BroadcastToPlayer(self.player, RESERVED_ENDPOINT_EVENT, b64str)
        if ok ~= BroadcastEventResultCode.SUCCESS then
            warn(format("[%s]:ERROR: BroadcastEventResultCode: %d", self.m_endpoint.id, ok))
        end
    end)
    self.maid.m_endpoint_sub = Events.ConnectForPlayer(RESERVED_ENDPOINT_EVENT, function(player, b64str)
        if player ~= self.player then return end
        local header, data = PlayerConnection._DecodeFrame(b64str)
        if not header then return end
        self.m_endpoint:OnReceiveFrame(header, data)
    end)

    self.maid.m_endpoint_update = Task.Spawn(function()
        local now = gettime()
        self.m_endpoint:Update(now)
    end)
    self.maid.m_endpoint_update.repeatCount = -1
    self.maid.m_endpoint_update.repeatInterval = MID_SERVER_CONFIG.UPDATE_INTERVAL

    -- [B]
    self.b_endpoint:SetTransmitFrameCallback(function(header, data)
        if not data then
            return -- nothing to send
        end
        local _, _, seq = ReliableEndpoint.header_explode(header)
        assert(seq, "sanity check")
        local key = format(BIG_KEY_FMT, seq)
        local mpacked = MessagePack.pack({header, data})
        local b64 = Base64.encode(mpacked)
        local ok, err = self.player:SetPrivateNetworkedData(key, b64)
        if ok ~= PrivateNetworkedDataResultCode.SUCCESS then
            warn(format("[%s] PrivateNetworkedDataResultCode: %d: %s", self.b_endpoint.id, ok, err))
        end
    end)
    self.b_endpoint:SetAckCallback(function(seq)
        local key = format(BIG_KEY_FMT, seq)
        local ok = self.player:SetPrivateNetworkedData(key, nil)
        if ok ~= PrivateNetworkedDataResultCode.SUCCESS then
            warn(format("[%s] remove: ERROR: PrivateNetworkedDataResultCode: %d", self.b_endpoint.id, ok))
        end
    end)
    self.maid.b_endpoint_update = Task.Spawn(function()
        local now = gettime()
        self.b_endpoint:Update(now)
    end, 0.01) -- small delay
    self.maid.b_endpoint_update.repeatCount = -1
    self.maid.b_endpoint_update.repeatInterval = BIG_SERVER_CONFIG.UPDATE_INTERVAL

    self.s_endpoint:SetReceiveMessageCallback(function(q) self:_OnMessageReceive(q) end)
    self.m_endpoint:SetReceiveMessageCallback(function(q) self:_OnMessageReceive(q) end)

    self.s_endpoint:UnlockTransmission()
    self.m_endpoint:UnlockTransmission()
    self.b_endpoint:UnlockTransmission()
    self.started = true

    dtrace("INFO: Endpoints ready:", self.m_endpoint.id, self.b_endpoint.id)
end

function PlayerConnection:Destroy()
    self.maid:Destroy()
end

---------------------------------------
-- Trusted Events Server
---------------------------------------
local TrustedEventsServer = {type = "TrustedEventsServer"}

function TrustedEventsServer:BroadcastToPlayer(player, event, ...)
    assert(player)
    -- be careful with nils
    for i = 1, select("#", ...) do
        if select(i, ...) == nil then
            error("*nil* event args not allowed: arg#"..i, 3)
        end
    end
    local connection = self.playerConnections[player]
    if not connection then
        return BroadcastEventResultCode.FAILURE, "player not connected"
    end
    local max_mid = connection.m_endpoint.config.MAX_MESSAGE_SIZE
    local message = {...}
    message[#message + 1] = event
    local size = MessagePack.encode(message, "measure")
    local ok, err = nil, nil
    if size <= max_mid then
        ok, err = connection.m_endpoint:SendMessage(message, size)
    else
        ok, err = connection.b_endpoint:SendMessage(message, size)
    end
    if not ok then
        return BroadcastEventResultCode.FAILURE, err
    else
        return BroadcastEventResultCode.SUCCESS
    end
end

function TrustedEventsServer:ReliableBroadcastToAllPlayers(event, ...)
    local errors = {}
    for player in pairs(self.playerConnections) do
        local code, err = self:BroadcastToPlayer(player, event, ...)
        if code ~= BroadcastEventResultCode.SUCCESS then
            errors[player.id:sub(1, 5)] = err
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

function TrustedEventsServer:UnreliableBroadcastToAllPlayers(event, ...)
    local message = tpack(...)
    message[#message + 1] = event
    local ok, err = self.u_endpoint:SendMessage(message)
    if not ok then
        return BroadcastEventResultCode.FAILURE, err
    else
        return BroadcastEventResultCode.SUCCESS
    end
end

function TrustedEventsServer:Start()
    self.maid = Maid.New(script)
    self.playerConnections = {}
    -----------------------------------
    -- Set-up unreliable endpoint
    -----------------------------------

    self.u_endpoint = UnreliableEndpoint.New(UNRELIABLE_CONFIG,"*", gettime)
    self.u_endpoint:SetTransmitFrameCallback(function (header, data)
        local mpacked = MessagePack.pack({header, data})
        -- networked custom properties are not tolerated for non-ASCII strings
        local b64 = Base64.encode(mpacked)
        TRUSTED_EVENTS_HOST:SetNetworkedCustomProperty(BROADCAST_CHANNEL, b64)
    end)
    -- endpoint update loop
    self.maid.update_loop = Task.Spawn(function()
        local now = gettime()
        self.u_endpoint:Update(now)
    end)
    self.maid.update_loop.repeatCount = -1
    self.maid.update_loop.repeatInterval = UNRELIABLE_CONFIG.UPDATE_INTERVAL

    self.maid:GiveTask(self.u_endpoint)
    self.u_endpoint:UnlockTransmission()

    -----------------------------------
    -- Player Events
    -----------------------------------
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
    dtrace(self.u_endpoint)
end

---------------------------------------
-- Start Server
---------------------------------------
TrustedEventsServer:Start()




