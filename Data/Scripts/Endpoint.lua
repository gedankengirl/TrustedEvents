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
local DEBUG = true

_ENV.require = _G.import or require

local Config = require("Config").New
local Queue = require("Queue").New
local MessagePack = require("MessagePack")
local SCRATCH32 = require("BitVector32").new()

local ipairs, print, error, type, assert = ipairs, print, error, type, assert
local format, tostring, setmetatable = string.format, tostring, setmetatable
local mtype, random, min, max = math.type, math.random, math.min, math.max
local concat, remove = table.concat, table.remove
local randomseed, os_time = math.randomseed, os.time

local HUGE = math.maxinteger
local NOOP = function() end

-- For testing:
local CORE_ENV = CoreDebug and true
local dump_endpoint = NOOP
local dump_frame = NOOP

_ENV = nil

---------------------------------------
-- Constants (16 bit header)
---------------------------------------
local K_MAX_SEQ_BITS = 4
local K_MAX_SACK_BITS = 8
local K_MAX_SACK = K_MAX_SACK_BITS - 1
local K_SACK_SHIFT = 1 -- bit0 if SACK = ack + 1

-- EMA (exponential moving average)
local RTT_WINDOW = 100
local EMA_FACTOR = 2 / (RTT_WINDOW + 1)
local EPSQ = 0.001 ^ 2
local function ema(prev, val)
    local d = val - prev
    if prev == 0 or d * d < EPSQ then
        return val
    end
    return d * EMA_FACTOR + prev
end

---------------------------------------
-- Header
---------------------------------------
-- 0 - 7: SACK     8
-- 8 -11: ACK      4
-- 12-13: FLAGS    2
local H_BIT_DATA = 12
local H_BIT_SECOND_HEADER  = 13
-- 14-17: SEQ      4
-- 18-25: SACK2    8
-- 26-29: ACK2     4
-- 30-31: RESERVED 2



---------------------------------------
-- Frame, Packet and Message
---------------------------------------
-- `Frame` is a pair of header:int32 and data:str(MessagePack) | nil
-- `data` is a packet or nil
--  * packet:: {message[, message ...]}
-- `message` is an array of values:
--  * message :: {val1[, val2, ...]}

---------------------------------------
-- How we acknowledging
---------------------------------------
-- * ACK SACK and NAK are commmon abbrevations for positive, selective and negative
--   acknowledgment (ref: https://en.wikipedia.org/wiki/Retransmission_(data_networks)).
-- * Header can contain the sequence number of the packet
-- * SACK is a bitmap of (ack+2, ack+3....ack+MAX_SACK+2)

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

-- returns seq moved by delta (delta can be negative)
local function _move_seq(seq, delta, max_seq)
    assert(mtype(delta) == "integer")
    -- we use `|0` to force result to be an integer
    return (seq + delta + 1 + max_seq) % (max_seq + 1) | 0
end

---------------------------------------
-- Default Config
---------------------------------------
local DEFAULT_CONFIG = Config {
    NAME = "[endpoint]",
    SEQ_BITS = K_MAX_SEQ_BITS,
    -- NOTE: for message-count < 15 every level adds 1 byte;
    -- MP{header:int32, data:str} adds 7 bytes
    MAX_MESSAGE_SIZE = 120,
    MAX_PACKET_SIZE = 121,
    MAX_DATA_BYTES = 122,

    UPDATE_INTERVAL = 0.1,
    ACK_TIMEOUT_FACTOR = 2,
    PACKET_RESEND_DELAY_FACTOR = 3,
}

---------------------------------------
-- Counters
---------------------------------------
local C_PACKETS_SENT = 1
local C_BYTES_SENT = 2
local C_PACKETS_RESEND = 3
local C_PACKETS_RECEIVED = 4
local C_PACKETS_RE_RECEIVED = 5
local C_MESSAGES_SENT = 6
local C_MESSAGES_RECEIVED = 7
local C_NAK_RESENDS = 8

---------------------------------------
-- Endpoint
---------------------------------------
local Endpoint = {type = "Endpoint"}
Endpoint.__index = Endpoint

function Endpoint:dump_counters()
    return format("snd:%4d resnd:%6d rcv:%4d rercv:%3d nak:%3d",
    self.counters[C_PACKETS_SENT] or 0,
    self.counters[C_PACKETS_RESEND] or 0,
    self.counters[C_PACKETS_RECEIVED] or 0,
    self.counters[C_PACKETS_RE_RECEIVED] or 0,
    self.counters[C_NAK_RESENDS] or 0
    )
end

-- New :: [Config][, id][, gettime: (nil -> time)] -> ReliableEndpoint
function Endpoint.New(config, id, gettime)
    assert(not config or config.type ~= Endpoint.type, "remove `:` from New call")
    local self = setmetatable({}, Endpoint)
    self.config = config or DEFAULT_CONFIG
    self.id = self.config.NAME .. id

    -- set constants
    local SEQ_BITS = self.config.SEQ_BITS
    assert(SEQ_BITS > 0 and SEQ_BITS <= K_MAX_SEQ_BITS, "incorrect number of sequnce bits")
    self.WINDOW = 2^(SEQ_BITS - 1)
    self.MAX_SEQ = 2^SEQ_BITS - 1
    self.ACK_TIMEOUT = self.config.UPDATE_INTERVAL * self.config.ACK_TIMEOUT_FACTOR
    self.RESEND_DELAY = self.config.UPDATE_INTERVAL * self.config.PACKET_RESEND_DELAY_FACTOR

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
    self.in_too_far = self.WINDOW -- upper in_buffer + 1

    -- network layer
    self.message_queue = Queue()
    self.receive_message_queue = Queue()
    self.on_message_receive = NOOP
    self.on_transmit_frame = nil

    -- misc
    self.on_ack = NOOP
    self.get_second_header = NOOP
    self.on_second_header  = NOOP
    self.counters = {}
    return self
end

function Endpoint:__tostring()
    return format("%s:%s", self.type, self.id)
end

---------------------------------------
-- Internal Serial Arithmetic
---------------------------------------
function Endpoint:move_seq(seq, delta)
    return _move_seq(seq, delta, self.MAX_SEQ)
end

function Endpoint:inc(seq)
    return self:move_seq(seq, 1)
end

function Endpoint:dec(seq)
    return self:move_seq(seq, -1)
end

function Endpoint:idx(seq)
    return seq % self.WINDOW
end
---------------------------------------
-- Public Methods
---------------------------------------
-- @ SetReceiveMessageCallback :: self, (Queue -> nil) -> nil
-- Receive callback will receve non-empty Queue with messages.
-- (!) The callback is *responsible* for removing messages from queue.
function Endpoint:SetReceiveMessageCallback(callback)
    self.on_message_receive = callback
end

-- @ SetTransmitFrameCallback :: self, (header, packet -> nil) -> nil
-- sets callback for transfer frames from this endpoint to some physical layer
function Endpoint:SetTransmitFrameCallback(callback)
    self.on_transmit_frame = callback
end

-- @ SetAckCallback :: self, (seq -> nil) -> nil
-- callback that is called when a reliable packet is removed from the out buffer
function Endpoint:SetAckCallback(callback)
    self.on_ack = callback
end

-- @ SetSecondHeaderCallback :: self, (header -> nil) -> nil
function Endpoint:SetSecondHeaderCallback(callback)
    self.on_second_header = callback
end

-- @ SetSecondHeaderGetter :: self, (nil -> header) -> nil
function Endpoint:SetSecondHeaderGetter(getter)
    self.get_second_header = getter
end

-- callback to transfer frames from some physical layer to this endpoint
function Endpoint:OnReceiveFrame(header, packet)
    self:_OnReceiveFrame(header, packet)
end

-- endpoint should be *unlocked* before it will be trasfer frames outside
function Endpoint:UnlockTransmission()
    self.lock_transmission = false
end

function Endpoint:CanTransmit()
    return not self.lock_transmission and self.on_transmit_frame
end

function Endpoint:OutBufferFull()
    return self.out_buffered >= self.WINDOW
end

-- @ SendMessage :: self, table -> true, count | false, err
function Endpoint:SendMessage(message, size)
    assert(type(message) == "table")
    size = size or MessagePack.encode(message, "measure")
    local max_size = self.config.MAX_MESSAGE_SIZE
    if size > max_size then
        return false, format("[%s]: message size: %d bytes > max:%d bytes", self.id, size, max_size)
    end
    return true, #self.message_queue:Push(message)
end

-- @ Update :: self, time ^-> nil
function Endpoint:Update(time_now)
    self.now = time_now
    -- TODO: calc stats and update counters
    if not self:CanTransmit() then
        return -- endpoint not ready
    end
    local header, data = self:_CreateFrame(time_now)
    local header2 = self.get_second_header()

    if not header and not header2 then
        return -- nothing to transmit
    end

    header = SCRATCH32(header)

    if header[H_BIT_DATA] then
        assert(type(data) == "table")
        data = MessagePack.encode(data)
        assert(data, "sanity check")
        if self.config.MAX_DATA_BYTES and #data > self.config.MAX_DATA_BYTES then
            error(format("ERROR: `data` size: %d bytes exceeds MAX_DATA_BYTES: %d bytes",
                #data, self.config.MAX_DATA_BYTES))
        end
    end

    if header2 then
        header[H_BIT_SECOND_HEADER] = true
        header = header:int32()
        header2 = SCRATCH32(header2)
        local sack2, ack2 = header2:extract(0, 8), header2:extract(8, 4)
        header = SCRATCH32(header)
        header:replace(sack2, 18, 8)
        header:replace(ack2, 26, 4)
    end

    self.ack_sent_time = time_now
    self.on_transmit_frame(header:int32(), data)
end

function Endpoint:Destroy()
    -- dump counters
    local out = {'#', self.id}
    for i = 1, #self.counters do
        out[#out + 1] = format("%d:%d", i, self.counters[i] or 0)
    end
    print(concat(out, "|"))
end

-- DEBUG:
function Endpoint:d(...)
    if self.id == "@" then
        print("---------> ", ...)
        return true
    end
end

---------------------------------------
-- Internals
---------------------------------------
function Endpoint:_counter(c, val)
    self.counters[c] = (self.counters[c] or 0) + val
end

-- takes decoded frame: header, data
function Endpoint:_OnReceiveFrame(header, data)
    header = SCRATCH32(header)
    local seq = header[H_BIT_DATA] and header:extract(14, 4) or false
    local ack = header:extract(8, 4)
    local sack = header:extract(0, 8)

    if header[H_BIT_SECOND_HEADER] then
        local sack2, ack2 = header:extract(18, 8), header:extract(26, 4)
        local header2 = SCRATCH32()
        header2:replace(sack2, 0, 8)
        header2:replace(ack2, 8, 4)
        self.on_second_header(header2:int32())
    end

    -------------------------
    -- handle ack
    -------------------------
    while _between_seq(self.ack_expected, ack, self.next_to_send) do
        -- remove acked packet from buffer
        local idx = self:idx(self.ack_expected)
        local sent_time = self.sent_time[idx]
        self.out_buffer[idx] = false
        self.timeout[idx] = false
        self.sent_time[idx] = false

        self.on_ack(self.ack_expected)

        -- shift window
        self.out_buffered = self.out_buffered - 1
        self.ack_expected = self:inc(self.ack_expected)

        -- calculate RTT
        self.rtt = ema(self.rtt, self.gettime() - sent_time)
    end

    -------------------------
    -- handle sack
    -------------------------
    do
        local oldest_nak, nak_idx = HUGE, nil
        local cursor = self:move_seq(ack, K_SACK_SHIFT) -- to skip ack and expected_packet
        for i = 0, K_MAX_SACK do
            local nak = (sack >> i) & 1 == 0
            if _between_seq(self.ack_expected, cursor, self.next_to_send) then
                local idx = self:idx(cursor)
                if not nak then
                    -- Remove received out-of-order packets from buffer (we will never resend it).
                    self.timeout[idx] = false
                    self.out_buffer[idx] = false
                    self.on_ack(cursor)
                elseif (sack >> i) > 0 then -- nak and ack-with-greater-seq exists
                    -- Heuristic: there is a packet with greater sequence so this one is defenitly lost.
                    if self.timeout[idx] < oldest_nak then
                        oldest_nak = self.timeout[idx]
                        nak_idx = idx
                    end
                end
            end
            cursor = self:inc(cursor)
        end
        -- one NAK at a time
        if nak_idx then
            self.timeout[nak_idx] = -1 -- to resend ASAP
        end
    end

    if not seq then
        return -- there is no data to send
    end

    -------------------------
    -- handle data
    -------------------------
    local packet = MessagePack.decode(data)
    assert(type(packet) == "table", "sanity check")

    local buffered = self.in_buffer[self:idx(seq)]

    if buffered then
        self:_counter(C_PACKETS_RE_RECEIVED, 1)
    end

    if not buffered and _between_seq(self.packet_expected, seq, self.in_too_far) then
        self.in_buffer[self:idx(seq)] = packet
        while self.in_buffer[self:idx(self.packet_expected)] do
            local idx = self:idx(self.packet_expected)
            packet = self.in_buffer[idx]
            self.in_buffer[idx] = false
            for i = 1, #packet do
                local message = packet[i]
                self.receive_message_queue:Push(message)
            end
            -- shift window
            self.packet_expected = self:inc(self.packet_expected)
            self.in_too_far = self:inc(self.in_too_far)
            self:_counter(C_MESSAGES_RECEIVED, #packet)
            self:_counter(C_PACKETS_RECEIVED, 1) -- i.e. received in order
        end
    end

    -- NOTE: we use the same queue and callback fo reliable and unreliable messages
    if not self.receive_message_queue:IsEmpty() then
        -- Huzzah! We got some legit messages. Notify client.
        self.on_message_receive(self.receive_message_queue)
    end
end

-- _CreateFrame :: self, time -> header:int32, data:table | nil
function Endpoint:_CreateFrame(time_now)
    assert(self:CanTransmit(), "sanity check")
    -------------------------
    -- ACK + SACK
    -------------------------
    local ack = self:dec(self.packet_expected)
    local sack = 0
    do
        -- NOTE: ack is true. Let's sack will not contain ack i.e. `bit0 = ack + 1`
        local cursor = self:move_seq(ack, K_SACK_SHIFT)
        for i = 0, K_MAX_SACK do
            if _between_seq(self.packet_expected, cursor, self.in_too_far) then
                if self.in_buffer[self:idx(cursor)] then
                    sack = sack | (1 << i)
                end
            end
            cursor = self:inc(cursor)
        end
    end
    -------------------------
    -- Packet
    -------------------------
    local seq = false
    -- resend
    do
        local cursor = self.ack_expected
        local oldest, oldest_seq = HUGE, nil
        -- choose oldest unacked packet to resend
        while _between_seq(self.ack_expected, cursor, self.next_to_send) do
            local idx = self:idx(cursor)
            local packet = self.out_buffer[idx]
            if packet and self.timeout[idx] < oldest then
                oldest = self.timeout[idx]
                oldest_seq = cursor
            end
            cursor = self:inc(cursor)
        end
        if oldest_seq and oldest <= time_now then
            seq = oldest_seq
            if oldest <= 0 then
                self:_counter(C_NAK_RESENDS, 1)
            end
            self:_counter(C_PACKETS_RESEND, 1)
            self.timeout[self:idx(seq)] = self.RESEND_DELAY + time_now
        end
    end

    -- new packet if no resend and window have free space
    if not (seq or self:OutBufferFull() or self.message_queue:IsEmpty()) then
        -- NOTE: We need to reserve 2 bytes for seq and array encoding. Array encoding
        -- takes 1 byte if its length <= 15, but for AckAbilities (where every byte
        -- matters): 15 is a reasonable limit for messages number; for networked properties
        -- it doesn't matter if the frame will be a couple of bytes longer.
        local threshold = self.config.MAX_PACKET_SIZE
        local packet_bytes = 0
        local packet = {}
        while true do
            local message = self.message_queue:Peek()
            if not message then
                break
            end
            local message_bytes = MessagePack.encode(message, "measure")
            if packet_bytes + message_bytes >= threshold then
                break
            end
            packet[#packet + 1] = self.message_queue:Pop()
            packet_bytes = packet_bytes + message_bytes
        end
        assert(packet_bytes ~= 0 or self.message_queue:IsEmpty(), "config error: max package/message sizes")

        if packet_bytes > 0 then
            -- buffer new packet
            seq = self.next_to_send
            local idx = self:idx(seq)
            self.out_buffer[idx] = packet
            self.timeout[idx] = self.RESEND_DELAY + time_now
            self.sent_time[idx] = time_now
            -- expand window
            self.out_buffered = self.out_buffered + 1
            self.next_to_send = self:inc(self.next_to_send)

            self:_counter(C_MESSAGES_SENT, #packet)
            self:_counter(C_PACKETS_SENT, 1)
            self:_counter(C_BYTES_SENT, packet_bytes)
        end
    end

    -------------------------
    -- Write header
    -------------------------
    local header = SCRATCH32()
    header:replace(sack, 0, 8)
    header:replace(ack, 8, 4)
    local data = nil do
        if seq then
            header[H_BIT_DATA] = true
            header:replace(seq, 14, 4)
            data = self.out_buffer[self:idx(seq)]
            assert(data)
        end
    end

    if not header[H_BIT_DATA] then
         -- check ack timeout
        if time_now - self.ack_sent_time < self.ACK_TIMEOUT then
            return false, nil -- no frame this time
        end
    end

    -- write header
    return header:int32(), data
end

----------------------------------
--- Debug Utils
----------------------------------
if DEBUG then
    dump_frame = function(header, data, tag)
        data = data or ""
        tag = tostring(tag or "#")
        header = SCRATCH32(header)
        local seq = header[H_BIT_DATA] and header:extract(0, 4) or -1
        local ack = header:extract(4, 4)
        local sack = header:extract(10, 6)

        return format("[%s %.3f KB] | ack: %0.3d | seq:[%d]", tag, #data / 1000, ack, seq)
    end

    dump_endpoint = function(self)
        local c = self.ack_expected
        local out = {self.id}
        out[#out + 1] = format("out:%d:%d#%d ", self.ack_expected, self.next_to_send, self.out_buffered)
        while _between_seq(self.ack_expected, c, self.next_to_send) do
            local idx = self:idx(c)
            if self.out_buffer[idx] then
                out[#out + 1] = format("%d:%0.1f", c, self.timeout[idx])
            else
                out[#out + 1] = format("+%d", c)
            end
            c = self:inc(c)
        end
        out[#out + 1] = format("| in:%d:", self.packet_expected, self.out_buffered)
        c = self.packet_expected
        while _between_seq(self.packet_expected, c, self.in_too_far) do
            local idx = self:idx(c)
            out[#out + 1] = self.in_buffer[idx] and format("%d", c) or "x"
            c = self:inc(c)
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
    local config = DEFAULT_CONFIG {
        NAME = "",
        -- SEQ_BITS = 3,
        -- ACK_TIMEOUT_FACTOR = 2,
        -- PACKET_RESEND_DELAY_FACTOR = 3,
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
    local ep1 = Endpoint.New(config, "A ")
    local ep2 = Endpoint.New(config, "\t\t\t\t\t\t\t B")
    ep1:SetReceiveMessageCallback(receive_message(ep1, context))
    ep2:SetReceiveMessageCallback(receive_message(ep2, context))

    ep1:SetTransmitFrameCallback(transmit_frame(ep1, receive_frame(ep2), context))
    ep2:SetTransmitFrameCallback(transmit_frame(ep2, receive_frame(ep1), context))
    ep1:UnlockTransmission()
    ep2:UnlockTransmission()

    local min_message_size = config.MAX_MESSAGE_SIZE-3
    local max_message_size = config.MAX_MESSAGE_SIZE-3

    local time = 0.0
    local dt = config.UPDATE_INTERVAL
    local N = message_count
    for _ = 1, N do
        assert(ep1:SendMessage({("1"):rep(random(min_message_size, max_message_size))}))
        assert(ep2:SendMessage({("2"):rep(random(min_message_size, max_message_size))}))
    end
    local ticks = 0
    for i = 1, 1000 * N do
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

    trace(context[ep1.id])
    trace(context[ep2.id])

    assert(context[ep1.id] == N)
    assert(context[ep2.id] == N)

       print(format("ok: [sq:%d] #%5d drop: %2d%% tick: %6d rtt: [%6.2f %6.2f] [%s |%s]",
              config.SEQ_BITS, N, (drop_rate * 100) // 1, ticks,
              ep1.rtt, ep2.rtt, ep1:dump_counters(), ep2:dump_counters()))
    if verbose then
        ep1:Destroy()
        ep2:Destroy()
    end
end

local function self_test()
    print("[Reliable Endpoint]")
    randomseed(os_time())
    -- randomseed(12345)
    -- test_loop(10, 0.5, "echo")
    -- test_loop(50, 0.5)
    -- Core won't be able to handle it
    if not CORE_ENV then
        test_loop(1000, 0.0)
        test_loop(1000, 0.1)
        test_loop(1000, 0.3)
        test_loop(1000, 0.5)
        test_loop(1000, 0.7)
        test_loop(1000, 0.9)
        test_loop(1000, 0.95)
        test_loop(100, 0.99)
        --[[ soak, use with caution
        test_loop(50000, 0.99)
        --]]
    end
end

self_test()

-----------------------------
-- Module Export
-----------------------------

Endpoint.DEFAULT_CONFIG = DEFAULT_CONFIG

-- Reserved, unique, short string, that we use for handshaking
Endpoint.READY = "<~READY!~>"

return Endpoint
