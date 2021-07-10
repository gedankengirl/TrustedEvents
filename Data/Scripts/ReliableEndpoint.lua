--[[
    Implementation of "Selective Repeat Request" network protocol with some
    variations and additions.

    Reference: https://en.wikipedia.org/wiki/Selective_Repeat_ARQ

    This implementation keeps on delivering messages orderly and reliably
    even under severe (90%+) network packets loss.

    This module can handle messages, packets and frames and provides callback
    interface for physical network communications.

    You can see a usage exmple in `TrustedEventsServer/TrustedEventsClient`.

    -- Copyright (c) 2021 Andrew Zhilin (https://github.com/zoon)
]]
local DEBUG = false

_ENV.require = _G.import or require

local Config = require("Config").New
local Queue = require("Queue").New
local BitVector32 = require("BitVector32").new
local MessagePack = require("MessagePack")

local ipairs, print, error, type, assert = ipairs, print, error, type, assert
local format, tostring, setmetatable = string.format, tostring, setmetatable
local mtype, random, min, max = math.type, math.random, math.min, math.max
local concat, remove = table.concat, table.remove
local randomseed, os_time = math.randomseed, os.time
local pcall = pcall


local NOOP = function() end

-- For testing:
local CORE_ENV = CoreDebug and true
local dump_endpoint = NOOP
local dump_frame = NOOP

_ENV = nil

-- Constants
local MAX_SACK_BITS = 16
local MAX_SEQ_BITS = 8

local SEQ_BITS = 7 -- MessagePack will encode 7-bit with just one byte
local MAX_SEQ = 2 ^ SEQ_BITS - 1
local MAX_WINDOW_SIZE = 2 ^ (SEQ_BITS - 1)
local WINDOW_SIZE = 32
local MAX_SACK = min(MAX_SACK_BITS - 1, WINDOW_SIZE - 1)
-- Contracts
assert(SEQ_BITS <= MAX_SEQ_BITS)
assert(WINDOW_SIZE <= MAX_WINDOW_SIZE)
assert(WINDOW_SIZE & (WINDOW_SIZE - 1) == 0, "WINDOW_SIZE should be a power of 2")

-- EMA (exponential moving average)
local EMA_FACTOR = 2 / (100 + 1) -- window size = 100
local EPSQ = 0.001^2
local function ema(prev, val)
    local d = val - prev
    if prev == 0 or d*d < EPSQ then return val end
    return d * EMA_FACTOR + prev
end

---------------------------------------
-- Header
---------------------------------------
-- byte0, bits:
-- * 0, 1, 2, 3: reserved for user
-- * 4, 5: reserved for header
-- * 6: indicates that frame contains only ack and no sequence
local H_BIT_ACK = 6
-- * 7: indicates that frame contains unreliable packet at last position
local H_BIT_UNRELIABLE = 7
-- byte1: ack
-- byte2, byte3: 16 bit sack

---------------------------------------
-- Frame, Packet and Message
---------------------------------------
-- `Frame` is a pair of header:int32 and data:string (data encoded by MessagePack).
--  * data :: {[reliable packet, reliable packet ...][, unreliable packet]}

-- `Packet` is an array of messages with sequence number at index 1:
--  * reliable packet: {seq, message[, message ...]}
--  * unreliable packet :: {message[, message ...]}

-- `Message` is an array of values (non encoded):
--  * message :: {val1[, val2, ...]}

---------------------------------------
-- How we acknowledging
---------------------------------------
-- * ACK SACK and NAK are commmon abbrevations for positive, selective and negative
--   acknowledgment (ref: https://en.wikipedia.org/wiki/Retransmission_(data_networks)).
-- * We acking at packet level, frame has no sequence number.
-- * SACK is a bitmap of (ack+2, ack+3....ack+MAX_SACK+2) i.e. with ACK we send
--   information about out-of-order packets.

---------------------------------------
-- Packets priority
---------------------------------------
-- * unreliable
-- * reliable resend
-- * reliable new

---------------------------------------
-- Serial Arithmetic
---------------------------------------
-- This version of serial arithmetic is more or less borrowed from
-- "Computer Network" by Tanenbaum et al.

-- NOTE: this functions is not obvious, because `a`, `b`, and `c` are circular indices.
-- Retuns true if: a <= b < c (circularly)
local function _between_seq(a, b, c)
    return (a <= b and b < c) or (c < a and a <= b) or (b < c and c < a)
end

-- NOTE: Sometimes returns of _move_seq don't pass the test
-- `math.type == "integer"`. We use idiomatic `| 0` to force.

-- returns seq moved by delta (delta can be negative)
local function _move_seq(seq, delta)
    assert(mtype(delta) == "integer")
    return (seq + delta + 1 + MAX_SEQ) % (MAX_SEQ + 1) | 0
end

-- returns incremented value of seq
local function _inc_seq(seq)
    return _move_seq(seq, 1)
end

-- returns decremented value of seq
local function _dec_seq(seq)
    return _move_seq(seq, -1)
end

---------------------------------------
-- Default Config
---------------------------------------
local DEFAULT_CONFIG = Config {
    NAME = "[endpoint]",
    MAX_UNREALIBLE_PACKET_SIZE = 512,
    MAX_UNREALIBLE_MESSAGE_SIZE = 256,
    MAX_REALIBLE_PACKET_SIZE = 512,
    MAX_REALIBLE_MESSAGE_SIZE = 256,
    MAX_DATA_BYTES = false,
    MAX_RELIABLE_PACKETS = 3,
    UPDATE_INTERVAL = 0.2,
    ACK_TIMEOUT = 0.4,         -- 1..2x UPDATE_INTERVAL, should be less then PACKET_RESEND_DELAY
    PACKET_RESEND_DELAY = 0.6, -- 2..3x UPDATE_INTERVAL
}

---------------------------------------
-- Reliable Endpoint
---------------------------------------
local ReliableEndpoint = {type = "ReliableEndpoint"}
ReliableEndpoint.__index = ReliableEndpoint

-- New :: [Config][, id][, gettime: (nil -> time)] -> ReliableEndpoint
function ReliableEndpoint.New(config, id, gettime)
    assert(not config or config.type ~= ReliableEndpoint.type, "remove `:` from New call")
    local self = setmetatable({}, ReliableEndpoint)
    self.config = config or DEFAULT_CONFIG
    self.id = id or self.config.NAME
    self.reliable_message_queue = Queue()
    self.unreliable_message_queue = Queue()
    self.receive_message_queue = Queue()
    -- out window
    self.out_buffer = {}
    self.ack_expected = 0 -- lower out_buffer
    self.next_to_send = 0 -- upper out_buffer
    self.out_buffered = 0
    self.timeout = {}
    self.sent_time = {}
    self.ack_sent_time = 0
    self.rtt = 0
    self.gettime = gettime or function() return self.now end
    self.now = 0
    self.lock_transmission = true -- to lock transmission before handshake
    -- in window
    self.in_buffer = {}
    self.packet_expected = 0      -- lower in_buffer
    self.in_too_far = WINDOW_SIZE -- upper in_buffer + 1
    -- network layer
    self.message_receive_callback = NOOP
    self.transmit_frame_callback = nil

    return self
end

function ReliableEndpoint:__tostring()
    return format("%s:%s", self.type, self.id)
end

---------------------------------------
-- Public Methods
---------------------------------------
-- @ SetReceiveMessageCallback :: self, (Queue -> nil) -> nil
-- Receive callback will receve non-empty Queue with messages.
-- (!) The callback is *responsible* for removing messages from queue.
function ReliableEndpoint:SetReceiveMessageCallback(callback)
    self.message_receive_callback = callback
end

-- @ SetTransmitFrameCallback :: self, (header, data -> nil) -> nil
-- sets callback for transfer frames from this endpoint to some physical layer
function ReliableEndpoint:SetTransmitFrameCallback(callback)
    self.transmit_frame_callback = callback
end

-- callback to transfer frames from some physical layer to this endpoint
function ReliableEndpoint:OnReceiveFrame(header, data)
    self:_OnReceiveFrame(header, data)
end

-- endpoint should be *unlocked* before it will be trasfer frames outside
function ReliableEndpoint:UnlockTransmission()
    self.lock_transmission = false
end

function ReliableEndpoint:CanTransmit()
    return not self.lock_transmission and self.transmit_frame_callback
end

function ReliableEndpoint:OutBufferFull()
    return self.out_buffered >= WINDOW_SIZE
end

-- @ SendMessage :: self, message:str|table[, unrealible] -> true, count | false, err
function ReliableEndpoint:SendMessage(message, unrealible)
    local msg_t = type(message)
    local queue_size = nil
    assert(message and (msg_t == "table" or msg_t == "string"), "message should be a table or string")
    local size = msg_t == "table" and MessagePack.encode(message, "measure") or #message
    local max_size
    if unrealible then
        max_size = self.config.MAX_UNREALIBLE_MESSAGE_SIZE
        if size > max_size then
            return false, format("[%s]: message size: %d bytes > max:%d bytes", self.id, size, max_size)
        end
        queue_size = #self.unreliable_message_queue:Push(message)
    else
        max_size = self.config.MAX_REALIBLE_MESSAGE_SIZE
        if size > max_size then
            return false, format("[%s]: message size: %d bytes > max:%d bytes", self.id, size, max_size)
        end
        queue_size = #self.reliable_message_queue:Push(message)
    end
    return true, queue_size
end

-- @ Update :: self, time ^-> nil
function ReliableEndpoint:Update(time_now)
    self.now = time_now
    -- TODO: calc stats and update counters
    if not self:CanTransmit() then
        return -- endpoint not ready
    end
    local header, data = self:_CreateFrame(time_now)
    if not header then
        return -- no frame to transmit
    end
    assert(type(data) == "table")
    data = MessagePack.encode(data)
    assert(data, "sanity check")

    if self.config.MAX_DATA_BYTES and #data > self.config.MAX_DATA_BYTES then
        error(format("ERROR: `data` size: %d bytes exceeds MAX_DATA_BYTES: %d bytes", #data, self.config.MAX_DATA_BYTES))
    end
    self.ack_sent_time = time_now
    self.transmit_frame_callback(header, data)
end

function ReliableEndpoint:Destroy()
    -- do nothing
end

-- DEBUG:
function ReliableEndpoint:d(...)
    if self.id == "@" then print("---------> ", ...) return true end
end

---------------------------------------
-- Internals
---------------------------------------
-- takes decoded frame: header, data
function ReliableEndpoint:_OnReceiveFrame(header, data)
    local header32 = BitVector32(header)
    local has_unreliable_packet = header32[H_BIT_UNRELIABLE]
    local ack_only = header32[H_BIT_ACK]
    local ack, sack = header32:get_byte(1), header32:get_uint16(1)

    -------------------------
    -- handle ack
    -------------------------
    while _between_seq(self.ack_expected, ack, self.next_to_send) do
        -- remove acked packet from buffer
        local idx = self.ack_expected % WINDOW_SIZE
        local sent_time = self.sent_time[idx]
        self.out_buffer[idx] = false
        self.timeout[idx] = false
        self.sent_time[idx] = false

        -- shift window
        self.out_buffered = self.out_buffered - 1
        self.ack_expected = _inc_seq(self.ack_expected)

        -- calculate RTT
        self.rtt = ema(self.rtt, self.gettime() - sent_time)
    end

    -------------------------
    -- handle sack
    -------------------------
    do
        local cursor = _move_seq(ack, 2) -- to skip ack and expected_packet
        for i = 0, MAX_SACK do
            local nak = (sack >> i) & 1 == 0
            if _between_seq(self.ack_expected, cursor, self.next_to_send) then
                if not nak then
                    -- Remove received out-of-order packets from window (we will never resend it).
                    self.timeout[cursor % WINDOW_SIZE] = false
                    self.out_buffer[cursor % WINDOW_SIZE] = false
                elseif (sack >> i) > 0 then -- nak and ack-with-greater-seq exists
                    -- Heuristic: there is a packet with greater sequence so this one is lost.
                    assert(self.timeout[cursor % WINDOW_SIZE])
                    -- TODO: we ned separate timer for RTT, or flag for ASAP
                    self.timeout[cursor % WINDOW_SIZE] = 0 -- resend ASAP
                end
            end
            cursor = _inc_seq(cursor)
        end
    end
    -- can we return early?
    if ack_only and not has_unreliable_packet then
        return -- there is no packets
    end

    -------------------------
    -- handle data
    -------------------------
    local packets = MessagePack.decode(data)
    assert(type(packets) == "table", "sanity check")

    -- unreliable packet
    if has_unreliable_packet then
        local unreliable = remove(packets)
        assert(unreliable)
        for _, message in ipairs(unreliable) do
            self.receive_message_queue:Push(message)
        end
    end
    -- reliable packet[s]
    for _, packet in ipairs(packets) do
        -- TODO: review
        local seq = packet[1]
        local not_buffered = not self.in_buffer[seq % WINDOW_SIZE]
        if not_buffered and _between_seq(self.packet_expected, seq, self.in_too_far) then
            self.in_buffer[seq % WINDOW_SIZE] = packet
            while self.in_buffer[self.packet_expected % WINDOW_SIZE] do
                local idx = self.packet_expected % WINDOW_SIZE
                packet = self.in_buffer[idx]
                self.in_buffer[idx] = false
                for i = 2, #packet do -- first is a seq
                    local message = packet[i]
                    self.receive_message_queue:Push(message)
                end
                -- shift window
                self.packet_expected = _inc_seq(self.packet_expected)
                self.in_too_far = _inc_seq(self.in_too_far)
            end
        end
    end
    -- NOTE: we use the same queue and callback fo reliable and unreliable messages
    if not self.receive_message_queue:IsEmpty() then
        -- Huzzah! We got some legit messages. Notify client.
        self.message_receive_callback(self.receive_message_queue)
    end
end

-- _CreateFrame :: self, time -> header:int32, data:table | nil
function ReliableEndpoint:_CreateFrame(time_now)
    assert(self:CanTransmit(), "sanity check")
    -------------------------
    -- ACK + SACK
    -------------------------
    local frame = {}
    local ack = _dec_seq(self.packet_expected)
    local sack = 0
    do
        -- NOTE: ack is true, self.packet_expected is false, we know it.  Let's
        -- sack will not contain ack i.e. `bit0 = self.packet_expected + 1`
        local cursor = _move_seq(ack, 2)
        for i = 0, MAX_SACK do
            if self.in_buffer[cursor % WINDOW_SIZE] then
                sack = sack | (1 << i)
            end
            cursor = _inc_seq(cursor)
        end
    end
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

    -------------------------
    -- Reliable packets
    -------------------------
    do
        local cursor = self.ack_expected
        -- collect unacked packets to resend
        while _between_seq(self.ack_expected, cursor, self.next_to_send) do
            if #frame >= self.config.MAX_RELIABLE_PACKETS then
                break
            end
            local idx = cursor % WINDOW_SIZE
            local packet = self.out_buffer[idx]
            if packet and self.timeout[idx] + self.config.PACKET_RESEND_DELAY <= time_now then
                assert(packet[1] == cursor, "sanity check")
                frame[#frame + 1] = packet
                self.timeout[idx] = time_now
            end
            cursor = _inc_seq(cursor)
        end
    end
    -- collect messages to new packet if window and frame have free space
    if not self:OutBufferFull() and #frame < self.config.MAX_RELIABLE_PACKETS then
        -- NOTE: We need to reserve 2 bytes for seq and array encoding. Array encoding
        -- takes 1 byte if its length <= 15, but for AckAbilities (where every byte
        -- matters): 15 is a reasonable limit for messages number; for networked properties
        -- it doesn't matter if the frame will be a couple of bytes longer.
        local threshold = self.config.MAX_REALIBLE_PACKET_SIZE - 2 -- 2 bytes reserved
        local reliable_bytes = 0
        local seq = self.next_to_send
        local reliable_packet = {seq}
        while true do
            local message = self.reliable_message_queue:Peek()
            if not message then
                break
            end
            local msize = MessagePack.encode(message, "measure")
            if reliable_bytes + msize > threshold then
                break
            end
            reliable_packet[#reliable_packet + 1] = self.reliable_message_queue:Pop()
            reliable_bytes = reliable_bytes + msize
        end
        if reliable_bytes > 0 then
            -- buffer new packet
            frame[#frame + 1] = reliable_packet
            local idx = seq % WINDOW_SIZE
            self.out_buffer[idx] = reliable_packet
            self.timeout[idx] = time_now
            self.sent_time[idx] = time_now
            -- expand window
            self.out_buffered = self.out_buffered + 1
            self.next_to_send = _inc_seq(self.next_to_send)
        end
    end

    -------------------------
    -- Write header
    -------------------------
    local header = BitVector32()
    header:set_byte(1, ack)
    header:set_uint16(1, sack)

    if #frame == 0 then
        header[H_BIT_ACK] = true
    end

    -- add unreliable_packet to frame
    if unreliable_bytes > 0 then
        frame[#frame + 1] = unreliable_packet
        header[H_BIT_UNRELIABLE] = true
    end

    if header[H_BIT_ACK] and not header[H_BIT_UNRELIABLE] then
        -- check ack timeout
        if time_now - self.ack_sent_time < self.config.ACK_TIMEOUT then
            return false -- no frame this time
        end
    end

    return header:int32(), frame
end

----------------------------------
--- Debug Utils
----------------------------------
if DEBUG then
    dump_frame = function(header, data, tag)
        tag = tostring(tag or "#")
        header = BitVector32(header)
        local ack = header:get_byte(1)
        local packets = type(data) == "table" and data or MessagePack.decode(data)
        local out = {}
        for _, packet in ipairs(packets) do
            out[#out + 1] = type(packet[1]) ~= "number" and "#nr" or packet[1]
        end
        local seq = concat(out, ", ")
        return format("[%s %.3f KB] | ack: %0.3d | seq:[%s]", tag, #data / 1000, ack, seq)
    end

    dump_endpoint = function(self)
        local c = self.ack_expected
        local out = {self.id}
        out[#out + 1] = format("out:%d:%d#%d ", self.ack_expected, self.next_to_send, self.out_buffered)
        while _between_seq(self.ack_expected, c, self.next_to_send) do
            local idx = c % WINDOW_SIZE
            if self.out_buffer[idx] then
                out[#out + 1] = format("%d:%0.1f", self.out_buffer[idx][1], self.timeout[idx])
            else
                out[#out + 1] = format("+%d", c)
            end
            c = _inc_seq(c)
        end
        out[#out + 1] = format("| in:%d:", self.packet_expected, self.out_buffered)
        c = self.packet_expected
        while _between_seq(self.packet_expected, c, self.in_too_far) do
            out[#out + 1] = self.in_buffer[c % WINDOW_SIZE] and format("%d", self.in_buffer[c % WINDOW_SIZE][1]) or "x"
            c = _inc_seq(c)
        end
        return concat(out, ' ')
    end
end

---------------------------------------
-- Test
---------------------------------------
local function test_loop(message_count, drop_rate, verbose)
    verbose = verbose and DEBUG
    drop_rate = drop_rate or 0.5
    drop_rate = max(0, min(drop_rate, 0.99))

    -- test config:
    local TICK = 0.3
    local config = DEFAULT_CONFIG {
        NAME = "[endpoint]",
        MAX_RELIABLE_PACKETS = 3,
        UPDATE_INTERVAL = TICK,
        PACKET_RESEND_DELAY = 3*TICK,
        ACK_TIMEOUT = 2*TICK,
    }

    local trace = verbose and print or NOOP

    local function receive_message(endpoint, context)
        return function(queue)
            while queue:Peek() do
                context[endpoint.id] = (context[endpoint.id] or 0) + 1
                queue:Pop()
            end
        end
    end

    local function transmit_frame(endpoint, receive_frame, context)
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
            -- trace(endpoint.id, "<<~ rcv", debug_frame(header, data))
            endpoint:OnReceiveFrame(header, data)
        end
    end

    local context = {drop = {}}
    local ep1 = ReliableEndpoint.New(config, "A ")
    local ep2 = ReliableEndpoint.New(config, "\t\t\t\t\t\t\t B")
    ep1:SetReceiveMessageCallback(receive_message(ep1, context))
    ep2:SetReceiveMessageCallback(receive_message(ep2, context))

    ep1:SetTransmitFrameCallback(transmit_frame(ep1, receive_frame(ep2), context))
    ep2:SetTransmitFrameCallback(transmit_frame(ep2, receive_frame(ep1), context))
    ep1:UnlockTransmission()
    ep2:UnlockTransmission()

    local min_message_size = config.MAX_REALIBLE_MESSAGE_SIZE
    local max_message_size = config.MAX_REALIBLE_MESSAGE_SIZE

    local time = 0.0
    local dt = config.UPDATE_INTERVAL
    local N = message_count
    for _ = 1, N do
        assert(ep1:SendMessage(("1"):rep(random(min_message_size, max_message_size))))
        assert(ep2:SendMessage(("2"):rep(random(min_message_size, max_message_size))))
    end
    local ticks = 0
    -- 200x should be enough even for 99% drop rate
    for i = 1, 200 * N do
        context.drop[ep1] = random() < drop_rate
        context.drop[ep2] = random() < drop_rate
        if verbose then
            -- print("-- time", format("%0.2f", time), "-----------------------")
        end
        ep1:Update(time)
        ep2:Update(time)
        time = time + dt
        if context[ep1.id] == N and context[ep2.id] == N then
            if verbose then
                print("-- end ---------------------------------------")
                time = time + dt
                context.drop[ep1] = false
                context.drop[ep2] = false
                ep1:Update(time)
                ep2:Update(time)
            end
            ticks = i
            break
        end
    end

    -- trace(context[ep1.id])
    -- trace(context[ep2.id])

    assert(context[ep1.id] == N)
    assert(context[ep2.id] == N)

    print(format(" test loop: Messages: %d\t drop rate: %2d %%\t ticks: %d\t rtt: [%0.3f\t %0.3f] -- ok", N,
                 (drop_rate * 100) // 1, ticks, ep1.rtt, ep2.rtt))
end

local function self_test()
    print("[Reliable Endpoint]")
    randomseed(os_time())
    test_loop(50, 0.5)
    -- Core won't be able to handle it
    if not CORE_ENV then
        test_loop(20, 0.5, "echo")
        test_loop(10000, 0.0)
        test_loop(1000, 0.1)
        test_loop(10000, 0.1)
        test_loop(100000, 0.1)
        test_loop(10000, 0.5)
        test_loop(10000, 0.95)
        --[[ soak, use with caution
        test_loop(50000, 0.99)
        --]]
    end
end

self_test()

-----------------------------
-- Module Export
-----------------------------

ReliableEndpoint.DEFAULT_CONFIG = DEFAULT_CONFIG

-- Reserved, unique, short string, that we use for handshaking
ReliableEndpoint.READY = "<~READY!~>"

return ReliableEndpoint
