--[[
    Unreliable version of ReliableEndpoint, that share its interface.

    -- Copyright (c) 2021 Andrew Zhilin (https://github.com/zoon)
]]
local DEBUG = false

_ENV.require = _G.import or require

local Config = require("Config").New
local Queue = require("Queue").New
local MessagePack = require("MessagePack")
local BitVector32 = require("BitVector32").new

local pack, unpack = string.pack, string.unpack
local ipairs, print, error, type, assert = ipairs, print, error, type, assert
local format, tostring, setmetatable = string.format, tostring, setmetatable
local mtype, random, min, max = math.type, math.random, math.min, math.max
local concat = table.concat

local NOOP = function() end

_ENV = nil

-- EMA (exponential moving average)
local EMA_FACTOR = 2 / (10 + 1) -- window size = 10
local EPSQ = 0.001^2
local function ema(prev, val)
    local d = val - prev
    if prev == 0 or d*d < EPSQ then return val end
    return d * EMA_FACTOR + prev
end

-- number -> uint16
local function pack_time(t)
    return (t * 1000 // 1) & 0xffff
end

-- uint16 -> number
local function unpack_time(uint16)
    return uint16/1000
end

---------------------------------------
-- Header
---------------------------------------
-- byte0 : seq
-- byte1 : reserved
-- byte2 .. byte3 : time (packed to 16 bit)

---------------------------------------
-- Frame Packet and Message
---------------------------------------
-- `Frame` is a pair of header:int32 and a one unreliable packet (non encoded)

-- `Packet` is an array of messages:
--  * unreliable packet :: {message[, message ...]}

-- `Message` is an array of values (non encoded):
--  * message :: {val1[, val2, ...]}

---------------------------------------
-- Default Config
---------------------------------------
local DEFAULT_CONFIG = Config {
    NAME = "[unreliable]",
    MAX_UNREALIBLE_PACKET_SIZE = 2048,
    MAX_UNREALIBLE_MESSAGE_SIZE = 1024,
    MAX_DATA_BYTES = false,
    UPDATE_INTERVAL = 0.25,
    MAX_SEQ = 255
}

---------------------------------------
-- Counters
---------------------------------------
local C_PACKETS_SENT = 1
local C_PACKETS_RECEIVED = 2
local C_PACKETS_NOT_RECEIVED = 3
local C_BYTES_SENT = 4

---------------------------------------
-- Unreliable Endpoint
---------------------------------------
local UnreliableEndpoint = {type = "UnreliableEndpoint"}
UnreliableEndpoint.__index = UnreliableEndpoint

-- New :: [Config][, id] -> UnreliableEndpoint
function UnreliableEndpoint.New(config, id, gettime)
    assert(not config or config.type ~= UnreliableEndpoint.type, "remove `:` from New call")
    local self = setmetatable({}, UnreliableEndpoint)
    self.config = config or DEFAULT_CONFIG
    self.id = id or self.config.NAME
    self.unreliable_message_queue = Queue()
    self.receive_message_queue = Queue()
    self.lock_transmission = true -- to lock transmission before handshake
    -- rtt
    self.now = 0
    self.gettime = gettime or function() return self.now end
    self.rtt = 0
    self.seq = 0      -- for stats
    self.expected = 0 -- for stats
    -- network layer
    self.message_receive_callback = NOOP
    self.transmit_frame_callback = nil
    self.counters = {}
    return self
end

function UnreliableEndpoint:__tostring()
    return format("%s:%s", self.type, self.id)
end

function UnreliableEndpoint:Inc(seq)
    local maxseq = self.config.MAX_SEQ
    return (seq + 1 + 1 + maxseq) % (maxseq + 1) | 0
end

---------------------------------------
-- Public Methods
---------------------------------------
-- @ SetReceiveMessageCallback :: self, (Queue -> nil) -> nil
-- Receive callback will receve non-empty Queue with messages.
-- (!) The callback is *responsible* for removing messages from queue.
function UnreliableEndpoint:SetReceiveMessageCallback(callback)
    self.message_receive_callback = callback
end

-- @ SetTransmitFrameCallback :: self, (header, data -> nil) -> nil
-- sets callback for transfer frames from this endpoint to some physical layer
function UnreliableEndpoint:SetTransmitFrameCallback(callback)
    self.transmit_frame_callback = callback
end

-- callback to transfer frames from some physical layer to this endpoint
function UnreliableEndpoint:OnReceiveFrame(header, data)
    self:_OnReceiveFrame(header, data)
end

-- endpoint should be *unlocked* before it will be trasfer frames outside
function UnreliableEndpoint:UnlockTransmission()
    self.lock_transmission = false
end

function UnreliableEndpoint:CanTransmit()
    return not self.lock_transmission and self.transmit_frame_callback
end

-- @ SendMessage :: self, message:str|table[, unrealible] -> true, count | false, err
function UnreliableEndpoint:SendMessage(message)
    local msg_t = type(message)
    assert(message and (msg_t == "table" or msg_t == "string"), "message should be a table or string")
    local size = msg_t == "table" and MessagePack.encode(message, "measure") or #message
    local max_size = self.config.MAX_UNREALIBLE_MESSAGE_SIZE
    if size > max_size then
        return false, format("[%s]: message size: %d bytes > max:%d bytes", self.id, size, max_size)
    end
    local queue_size = #self.unreliable_message_queue:Push(message)
    return true, queue_size
end

-- @ Update :: self, time ^-> nil
function UnreliableEndpoint:Update(time_now)
    self.now = time_now
    -- TODO: calc stats and update counters
    if not self:CanTransmit() then
        return -- endpoint not ready
    end
    local header, data = self:_CreateFrame(time_now)
    if not header then
        return -- no frame to transmit
    else
        assert(data)
    end

    if self.config.MAX_DATA_BYTES then
        local data_size = MessagePack.encode(data, "measure")
        if data_size > self.config.MAX_DATA_BYTES then
            error(format("ERROR: `data` size: %d bytes exceeds MAX_DATA_BYTES: %d bytes", #data, self.config.MAX_DATA_BYTES))
        end
    end
    self.transmit_frame_callback(header, data)
end

function UnreliableEndpoint:Destroy()
    local out = {self.id}
    for i = 1, #self.counters do
        out[#out + 1] = format("%d:%d", i, self.counters[i])
    end
    print(concat(out, "|"))
end

-- DEBUG:
function UnreliableEndpoint:d(...)
    if self.id == "@" then print("---------> ", ...) return true end
end

---------------------------------------
-- Internals
---------------------------------------
function UnreliableEndpoint:_counter(c, val)
    self.counters[c] = (self.counters[c] or 0) + val
end

-- takes decoded frame: header, data
function UnreliableEndpoint:_OnReceiveFrame(header, data)
    header = BitVector32(header)
    local sent_time = header:get_uint16(1)
    local now = pack_time(self.gettime())
    self.rtt = ema(self.rtt, unpack_time(now) - unpack_time(sent_time))
    local seq = header:get_byte(0)
    local lost = 0
    while seq ~= self.expected do
        self.expected = self:Inc(self.expected)
        lost = lost + 1
        assert(lost < self.config.MAX_SEQ, "sanity check")
    end
    self.expected = self:Inc(self.expected)
    self:_counter(C_PACKETS_RECEIVED, 1)
    self:_counter(C_PACKETS_NOT_RECEIVED, lost)

-------------------------
    -- handle data
    -------------------------
    local unreliable_packet = data
    assert(type(unreliable_packet) == "table", "sanity check")

    for _, message in ipairs(unreliable_packet) do
        self.receive_message_queue:Push(message)
    end

    if not self.receive_message_queue:IsEmpty() then
        self.message_receive_callback(self.receive_message_queue)
    end
end

-- _CreateFrame :: self, time -> header:int32, data:table | nil
function UnreliableEndpoint:_CreateFrame(time_now)
    assert(self:CanTransmit(), "sanity check")
    -------------------------
    -- Unrealiable packet
    -------------------------
    local unreliable_bytes = 0
    local unreliable_packet = {}
    do
        -- 1 byte reserved (see NOTE below)
        local threshold = self.config.MAX_UNREALIBLE_PACKET_SIZE - 1
        while true do
            local message = self.unreliable_message_queue:Peek()
            if not message then
                break
            end
            local msize = MessagePack.encode(message, "measure")
            if unreliable_bytes + msize > threshold then
                break
            end
            unreliable_packet[#unreliable_packet + 1] = self.unreliable_message_queue:Pop()
            unreliable_bytes = unreliable_bytes + msize
        end
    end
    if unreliable_bytes > 0 then
        self:_counter(C_BYTES_SENT, unreliable_bytes)
        self:_counter(C_PACKETS_SENT, 1)
        -------------------------
        -- Write header
        -------------------------
        local header = BitVector32()
        local time = (time_now * 1000 // 1) & 0xffff
        header:set_uint16(1, time)
        header:set_byte(0, self.seq)
        self.seq = self:Inc(self.seq)
        return header:int32(), unreliable_packet
    end
    return false, "no messages to send"
end

---------------------------------------
-- Test
---------------------------------------
local function test_loop(message_count, verbose, drop_rate)
    verbose = verbose and DEBUG
    drop_rate = drop_rate or 0
    drop_rate = max(0, min(drop_rate, 0.99))

    -- test config:
    local config = DEFAULT_CONFIG {
        -- overrides
    }

    local trace = verbose and print or NOOP
    local dump_frame = function(header, data)
        header = BitVector32(header)
        local seq = header:get_byte(0)
        local sent_time = unpack_time(header:get_uint16(1))
        return format("[#] seq: %0.3d time:%0.3f size: %d", seq, sent_time, #data)
    end
    local function dump_endpoint(ep)
        return ep.id
    end

    local function receive_message(endpoint, context)
        return function(queue)
            while queue:Peek() do
                context[endpoint.id] = (context[endpoint.id] or 0) + 1
                queue:Pop()
            end
        end
    end

    local function transmit_frame(endpoint, receive_frame, context)
        -- int32, table
        return function(header, data)
            if not context.drop[endpoint] then
                trace(endpoint.id, "~>> snd", dump_frame(header, data))
                trace(dump_endpoint(endpoint))
                receive_frame(header, data)
            else
                trace(endpoint.id, "-- drop", dump_frame(header, data))
            end
        end
    end

    local function receive_frame(endpoint)
        return function(header, data)
            trace(endpoint.id, "<<~ rcv", dump_frame(header, data))
            endpoint:OnReceiveFrame(header, data)
        end
    end

    local context = {drop = {}}
    local ep1 = UnreliableEndpoint.New(config, "A ")
    local ep2 = UnreliableEndpoint.New(config, "\t\t\t\t\t\t\t B")
    ep1:SetReceiveMessageCallback(receive_message(ep1, context))
    ep2:SetReceiveMessageCallback(receive_message(ep2, context))

    ep1:SetTransmitFrameCallback(transmit_frame(ep1, receive_frame(ep2), context))
    ep2:SetTransmitFrameCallback(transmit_frame(ep2, receive_frame(ep1), context))
    ep1:UnlockTransmission()
    ep2:UnlockTransmission()

    local min_message_size = config.MAX_UNREALIBLE_MESSAGE_SIZE
    local max_message_size = config.MAX_UNREALIBLE_MESSAGE_SIZE

    local time = 0.0
    local dt = config.UPDATE_INTERVAL
    local N = message_count
    for _ = 1, N do
        assert(ep1:SendMessage(("1"):rep(random(min_message_size, max_message_size))))
        assert(ep2:SendMessage(("2"):rep(random(min_message_size, max_message_size))))
    end
    local ticks = 0
    for i = 1, N do
        context.drop[ep1] = random() < drop_rate
        context.drop[ep2] = random() < drop_rate
        if verbose then
            print("-- time", format("%0.2f", time), "-----------------------")
        end
        ep1:Update(time)
        ep2:Update(time)
        time = time + dt
        ticks = ticks + 1
    end
    if verbose then
        print(ep1.id, "lost:", ep1.counters[C_PACKETS_NOT_RECEIVED])
        print(ep2.id, "lost:", ep2.counters[C_PACKETS_NOT_RECEIVED])
    end
    if drop_rate <= 0 then
        assert(context[ep1.id] == N)
        assert(context[ep2.id] == N)
    end
    ep1:Destroy()
    ep2:Destroy()

    print(format(" test loop: Messages: %d\t ticks: %d\t -- ok", N, ticks))
end

local function self_test()
    print("[Unreliable Endpoint]")
    test_loop(20, "echo", 0.2)
    test_loop(50)
end

self_test()

-----------------------------
-- Module Export
-----------------------------

UnreliableEndpoint.DEFAULT_CONFIG = DEFAULT_CONFIG
UnreliableEndpoint.MAX_SEQ = 255

return UnreliableEndpoint
