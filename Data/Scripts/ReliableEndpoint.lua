--[[
    Implementation of "Selective Repeat Request" network protocol with some
    variations and additions.

    Reference: https://en.wikipedia.org/wiki/Selective_Repeat_ARQ

    This implementation keeps on delivering messages orderly and reliably
    even under severe (90%+) network packets loss.

    This module can handle messages, packets and frames and provides callback
    interface for physical network communications.

    You can see a usage exmple in `TrustedEventsServer/TrustedEventsClient`.

]]

_ENV.require = _G.export or require

local Config = require("Config").New
local Queue = require("Queue").New
local BitVector32 = require("BitVector32").new
local MessagePack = require("MessagePack")

local ipairs, print, pcall, type = ipairs, print, pcall, type
local assert, format, tostring = assert, string.format, tostring
local mtype, random, min, max = math.type, math.random, math.min, math.max
local setmetatable, concat, remove = setmetatable, table.concat, table.remove

-- For testing:
local CORE_ENV = CoreDebug and true
---[[ uncomment this to add test variability
math.randomseed(os.time())
--]]

_ENV = nil

local NOOP = function() end

local SEQ_BITS = 7 -- MessagePack will encode 7-bit with just one byte
local MAX_SEQ = 2 ^ SEQ_BITS - 1 -- 127
local MAX_WINDOW_SIZE = 2 ^ (SEQ_BITS - 1) -- 64
local WINDOW_SIZE = 32
local MAX_SACK = 15
assert(WINDOW_SIZE <= MAX_WINDOW_SIZE)

---[[ Test
SEQ_BITS = 3
MAX_SEQ = 2 ^ SEQ_BITS - 1 -- 7
MAX_WINDOW_SIZE = 2 ^ (SEQ_BITS - 1)
WINDOW_SIZE = 4
MAX_SACK = 15
assert(WINDOW_SIZE <= MAX_WINDOW_SIZE)
--]]

---------------------------------------
-- Header
---------------------------------------
-- byte0, bits
-- * 0, 1, 2, 3: reserved for user
-- * 4, 5, 6: reserved for header
-- * 7: signas that frame contains unreliable packet at last position
local H_BIT_UNRELIABLE = 7
-- byte1: ack
-- byte2, byte3: 16 bit sack


---------------------------------------
-- Frame, Packet and Message
---------------------------------------
-- `Frame` is a pair of header:int32 and data:string (encoded by MessagePack).
--  * data: {seq+packet, seq+packet ..., optional unreliable packet}

-- `Packet` is an array of messages with sequence number at index 1:
--  * packet: {seq, message, message ...}

-- `Message` is an array of values:
--  * message: {val1, val2, ...}

---------------------------------------
-- How we acknowledging
---------------------------------------
-- ACK SACK and NAK are commmon abbrevations for positive, selective and negative
-- acknowledgment (ref: https://en.wikipedia.org/wiki/Retransmission_(data_networks)).
-- We acking at packet level, frame has no sequence number.
-- SACK is a bitmap of (ack, ack+1....ack+15) i.e. with ACK we send next 15
-- in case we receive some packets out of order.

---------------------------------------
-- Packets priority
---------------------------------------
-- * unreliable new
-- * reliable resend
-- * reliable new

----------------------------------
--- Debug
----------------------------------
local function debug_frame(header, data, tag)
    tag = tostring(tag or "#")
    header = BitVector32(header)
    local ack = header:get_byte(1)
    local sack = header:get_uint16(1)
    local packets = MessagePack.decode(data)
    local out = {}
    for _, packet in ipairs(packets) do
        out[#out + 1] = packet[1]
    end
    local seq = concat(out, ", ")
    return format("[%s %.3f KB] | ack: %0.3d | seq:[%s]", tag, #data/1000, ack, seq)
end


---------------------------------------
-- Serial Arithmetic
---------------------------------------
-- This version of serial arithmetic is more or less borrowed from
-- "Computer Network" by Tanenbaum et al.

-- NOTE: this functions is not obvious, because `a`, `b`, and `c` are circular indices
-- retuns true if: a <= b < c (circularly)
local function _between_seq(a, b, c)
    return (a <= b and b < c) or (c < a and a <= b) or (b < c and c < a)
end

-- TODO: Investigate: sometimes returns of unmasked _move_seq don't pass the
-- test math.type == "integer"! SEQ_MASK is workaround.
local SEQ_MASK = ~(-1 << SEQ_BITS)

-- returns k moved by delta (delta can be negative)
local function _move_seq(seq, delta)
    assert(mtype(delta) == "integer")
    return (seq + delta + 1 + MAX_SEQ) % (MAX_SEQ + 1) & SEQ_MASK
end

-- returns incremented value of k
local function _inc_seq(seq)
    return _move_seq(seq, 1)
end

-- returns decremented value of k
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
    MAX_RELIABLE_PACKETS_PER_FRAME = 3,
    PACKET_RESEND_DELAY = 0.4, -- 2x send rate is the best
    MAX_ACK_RESEND = 4
}

---------------------------------------
-- Reliable Endpoint
---------------------------------------
local ReliableEndpoint = {type="ReliableEndpoint"}
ReliableEndpoint.__index = ReliableEndpoint

function ReliableEndpoint.New(config, id)
    assert(not config or config.type ~= ReliableEndpoint.type, "remove `:` from New call")
    local self = setmetatable({}, ReliableEndpoint)
    config = config or DEFAULT_CONFIG
    self.id = id or config.NAME
    self.config = config
    self.reliable_send_queue = Queue()
    self.unreliable_send_queue = Queue()
    self.receive_queue = Queue()
    -- out window
    self.out_buffer = {}
    self.ack_expected = 0 -- lower out_buffer
    self.next_to_send = 0 -- upper out_buffer
    self.out_buffered = 0
    self.sent_time = {}
    self.lock_transmission = true -- to lock transmission before handshake
    -- in window
    self.in_buffer = {}
    self.packet_expected = 0 -- lower in_buffer
    self.in_too_far = WINDOW_SIZE -- upper in_buffer + 1
    self.acks_sent = 0
    -- TODO: rename to receive_msg_callback and transmit_frame_callback
    self.receive_callback = NOOP
    self.transmit_callback = nil
    return self
end

---[[ debug only
function ReliableEndpoint:__tostring()
    local c = self.ack_expected
    local out = {self.id}
    out[#out+1] = format("out:%d:%d#%d ", self.ack_expected, self.next_to_send, self.out_buffered)
    while _between_seq(self.ack_expected, c, self.next_to_send) do
        local idx = c % WINDOW_SIZE
        if self.out_buffer[idx] then
            out[#out + 1] = format("%d:%0.1f", self.out_buffer[idx][1], self.sent_time[idx])
        else
            out[#out + 1] = format("+%d", c)
        end
        c = _inc_seq(c)
    end
    out[#out+1] = format("| in:%d:", self.packet_expected, self.out_buffered)
    c = self.packet_expected
    while _between_seq(self.packet_expected, c, self.in_too_far) do
        out[#out+1] = self.in_buffer[c % WINDOW_SIZE] and format("%d", self.in_buffer[c % WINDOW_SIZE][1]) or "x"
        c = _inc_seq(c)
    end
    return concat(out, ' ')
end
--]]

---------------------------------------
-- Public Methods
---------------------------------------
-- SetReceiveCallback:: self, (Queue -> nil) -> nil
-- Receive callback will receve non-empty Queue with messages.
-- (!) The callback is responsible for removing messages from queue.
function ReliableEndpoint:SetReceiveCallback(callback)
    self.receive_callback = callback
end

-- SetNetworkCallback :: self, frame:(header, data) -> nil
-- sets callback for transmitting frames out
function ReliableEndpoint:SetTransmitCallback(callback)
    self.transmit_callback = callback
end

function ReliableEndpoint:UnlockTransmission()
    self.lock_transmission = false
end

-- TODO: rename to OnReceiveFrame, drop lambda
function ReliableEndpoint:GetIncomingFrameCallback()
    return function(header, data) self:_Receive(header, data) end
end

function ReliableEndpoint:CanTransmit()
    return not self.lock_transmission and self.transmit_callback and self.out_buffered < WINDOW_SIZE
end

-- TODO: test unreliable messaging
-- SendMessage :: self, message:string[, unrealible=false] -> true | false, message
function ReliableEndpoint:SendMessage(message, unrealible)
    assert(type(message) == "string")
    -- TODO: checks, size limits
    local max
    if unrealible then
        max = self.config.MAX_UNREALIBLE_MESSAGE_SIZE
        if #message > max then
            return false, format("[%s]: message size: %d bytes > max:%d bytes", self.id, #message, max)
        end
        self.unreliable_send_queue:Push(message)
    else
        max = self.config.MAX_REALIBLE_MESSAGE_SIZE
        if #message > max then
            return false, format("[%s]: message size: %d bytes > max:%d sizes", self.id, #message, max)
        end
        self.reliable_send_queue:Push(message)
    end
    return true
end

function ReliableEndpoint:Update(time_now)
    self:_TransmitFrame(time_now)
end

function ReliableEndpoint:Destroy()
    self.maid:Destroy()
end

---------------------------------------
-- Internals
---------------------------------------
-- takes decoded frame: header + data
function ReliableEndpoint:_Receive(header, data)
    local header32 = BitVector32(header)
    local has_unreliable_packet = header32[H_BIT_UNRELIABLE]
    local ack, sack = header32:get_byte(1), header32:get_uint16(1)

    -------------------------
    -- handle ack
    -------------------------
    -- TODO: calculate packet RTT
    while _between_seq(self.ack_expected, ack, self.next_to_send) do
        -- remove acked packet from buffer
        self.sent_time[self.ack_expected % WINDOW_SIZE] = false
        self.out_buffer[self.ack_expected % WINDOW_SIZE] = false
        -- shift window
        self.out_buffered = self.out_buffered - 1
        self.ack_expected = _inc_seq(self.ack_expected)
    end

    -------------------------
    -- handle sack
    -------------------------
    do
        local cursor = ack
        for i = 0, MAX_SACK do
            local nak = (sack >> i) & 1 == 0
            if _between_seq(self.ack_expected, cursor, self.next_to_send) then
                if not nak then
                -- remove out of order acked packets from window (we will never resend it)
                    self.sent_time[cursor % WINDOW_SIZE] = false
                    self.out_buffer[cursor % WINDOW_SIZE] = false
                elseif (sack >> i) > 0 then
                    -- there is ack with greater seq, heuristic: this packet lost
                    assert(self.sent_time[cursor % WINDOW_SIZE])
                    self.sent_time[cursor % WINDOW_SIZE] = 0
                end
            end
            cursor = _inc_seq(cursor)
        end
    end
    -------------------------
    -- handle data
    -------------------------
    local packets = MessagePack.decode(data)
    assert(type(packets) == "table")

    -- unreliable packet
    if has_unreliable_packet then
        local unreliable = remove(packets)
        assert(unreliable)
        for _, message in ipairs(unreliable) do
            self.receive_queue:Push(message)
        end
    end
    -- reliable packet[s]
    -- Got some real reliable packets? We communicating, not just swapping headers!
    if #packets > 0 then
        self.acks_sent = 0
    end

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
                    self.receive_queue:Push(message)
                end
                -- shift window
                self.packet_expected = _inc_seq(self.packet_expected)
                self.in_too_far = _inc_seq(self.in_too_far)
            end
        end
    end
    -- NOTE: we use the same queue and callback fo reliable and unreliable messages
    if not self.receive_queue:IsEmpty() then
        -- Huzzah! We got some legit messages. Notify client.
        self.receive_callback(self.receive_queue)
    end
end

-- _TransmitFrame :: self, time -> header:int32, data:str
function ReliableEndpoint:_TransmitFrame(time_now)
    -------------------------
    -- create ack + sack
    -------------------------
    local frame = {}
    local ack = _dec_seq(self.packet_expected)
    -- TODO: let's sack will not contain ack i.e. bit0 = self.packet_expected + 1
    local sack = 0x1 -- bit 0 === ack i.e. 0x1
    for i = 1, MAX_SACK do
        local cursor = _move_seq(ack, i)
        if self.in_buffer[cursor % WINDOW_SIZE] then
            sack = sack | (1 << i)
            assert(i ~= 1, "if i == 1 then ack should be at i")
        end
    end

    -------------------------
    -- create frame
    -------------------------
    -- unrealiable part
    local unreliable_bytes = 0
    local unreliable_packet = {}
    do
        -- 1 byte reserved (see NOTE below)
        local threshold = self.config.MAX_UNREALIBLE_PACKET_SIZE  - 1
        while true do
            local message = self.unreliable_send_queue:Peek()
            if not message then
                break
            end
            -- TODO: add `measure` method to MessagePack, that will not allocate string
            local nbytes = MessagePack.encode(message, "measure")
            if unreliable_bytes + nbytes <= threshold then
                unreliable_packet[#unreliable_packet + 1] = self.unreliable_send_queue:Pop()
                unreliable_bytes = unreliable_bytes + nbytes
            else
                break
            end
        end
    end
    -- reliable part
    do
        local cursor = self.ack_expected
        -- collect unacked packets to resend
        while _between_seq(self.ack_expected, cursor, self.next_to_send) do
            if #frame >= self.config.MAX_RELIABLE_PACKETS_PER_FRAME then
                break
            end
            local idx = cursor % WINDOW_SIZE
            local packet = self.out_buffer[idx]
            if packet and self.sent_time[idx] + self.config.PACKET_RESEND_DELAY <= time_now then
                assert(packet[1] == cursor)
                assert(#packet > 1, "buffered empty sequenced packet")
                frame[#frame + 1] = packet
                self.sent_time[idx] = time_now
            end
            cursor = _inc_seq(cursor)
        end
    end
    -- collect messages to new packet if window and frame have free space
    if self:CanTransmit() and #frame < self.config.MAX_RELIABLE_PACKETS_PER_FRAME then
        -- NOTE: We need to reserve 2 bytes for seq and array encoding. Array encoding
        -- takes 1 byte if its length <= 15, but for AckAbilities (where every byte
        -- matters): 15 is a reasonable limit for messages number; for networked properties
        -- it doesn't matter if the frame will be a couple of bytes longer.
        local threshold = self.config.MAX_REALIBLE_PACKET_SIZE - 2 -- 2 bytes reserved
        local reliable_bytes = 0
        local seq = self.next_to_send
        local reliable_packet = {seq}
        while true do
            local message = self.reliable_send_queue:Peek()
            if not message then
                break
            end
            local msize = MessagePack.encode(message, "measure")
            if reliable_bytes + msize > threshold then
                break
            end
            reliable_packet[#reliable_packet + 1] = self.reliable_send_queue:Pop()
            reliable_bytes = reliable_bytes + msize
        end
        if reliable_bytes > 0 then
            -- buffer new packet
            frame[#frame + 1] = reliable_packet
            self.out_buffer[seq % WINDOW_SIZE] = reliable_packet
            self.sent_time[seq % WINDOW_SIZE] = time_now
            -- expand window
            self.out_buffered = self.out_buffered + 1
            self.next_to_send = _inc_seq(self.next_to_send)
        end
    end

    -- write header
    local header = BitVector32()
    header:set_byte(1, ack)
    header:set_uint16(1, sack)

    -- write unreliable_packet
    if unreliable_bytes > 0 then
        frame[#frame + 1] = unreliable_packet
        header[H_BIT_UNRELIABLE] = true
    end

    -- if we have no data to send and sent this ack-only header several times then exit
    -- TODO: need to think about it ...
    self.acks_sent = self.acks_sent + (#frame == 0 and 1 or 0)
    if #frame == 0 and self.acks_sent > self.config.MAX_ACK_RESEND then
        if self:CanTransmit() then
            return
        else
            self.acks_sent = 0
        end
    end

    -- encode header, data and transmit
    assert(self.transmit_callback)
    header = header:int32()
    frame = MessagePack.encode(frame)
    self.transmit_callback(header, frame)
end

---------------------------------------
-- Test
---------------------------------------
local function test_loop(message_count, drop_rate, echo, config)
    config = config or DEFAULT_CONFIG {
        NAME = "[endpoint]",
        MAX_UNREALIBLE_PACKET_SIZE = 512,
        MAX_UNREALIBLE_MESSAGE_SIZE = 256,
        MAX_REALIBLE_PACKET_SIZE = 512,
        MAX_REALIBLE_MESSAGE_SIZE = 256,
        MAX_RELIABLE_PACKETS_PER_FRAME = 3,
        PACKET_RESEND_DELAY = 0.2, -- 2x send rate is the best
        MAX_ACK_RESEND = 9
    }
    drop_rate = drop_rate or 0.5
    drop_rate = max(0, min(drop_rate, 0.99))

    local trace = echo and print or NOOP

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
                trace(endpoint.id, "~>> snd", debug_frame(header, data))
                trace(endpoint)
                receive_frame(header, data)
            else
                -- trace(endpoint.id, "-- drop", debug_frame(header, data))
            end
        end
    end

    local function receive_frame(endpoint)
        return function (header, data)
            -- trace(endpoint.id, "<<~ rcv", debug_frame(header, data))
            endpoint:_Receive(header, data)
        end
    end

    local context = {drop = {}}
    local ep1 = ReliableEndpoint.New(config, "A-")
    local ep2 = ReliableEndpoint.New(config, "\t\t\t\t\t\t\t-B")
    ep1:SetReceiveCallback(receive_message(ep1, context))
    ep2:SetReceiveCallback(receive_message(ep2, context))

    ep1:SetTransmitCallback(transmit_frame(ep1, receive_frame(ep2), context))
    ep2:SetTransmitCallback(transmit_frame(ep2, receive_frame(ep1), context))
    ep1:UnlockTransmission()
    ep2:UnlockTransmission()

    local min_message_size = config.MAX_REALIBLE_MESSAGE_SIZE
    local max_message_size = config.MAX_REALIBLE_MESSAGE_SIZE

    local time = 0.0
    local dt = 0.1
    local N = message_count
    for _ = 1, N do
        assert(ep1:SendMessage(("1"):rep(random(min_message_size, max_message_size))))
        assert(ep2:SendMessage(("2"):rep(random(min_message_size, max_message_size))))
    end
    local ticks = 0
    for i = 1, 200*N do
        context.drop[ep1]  = random() < drop_rate
        context.drop[ep2]  = false -- random() < drop_rate
        if echo then print("--time", format("%0.2f", time),
            "-----------------------------------------------------------------------------------------") end
        ep1:Update(time)
        ep2:Update(time)
        time = time + dt
        if context[ep1.id] == N and context[ep2.id] == N then
            ticks = i
            trace(i)
            break
        end
    end

    trace(context[ep1.id])
    trace(context[ep2.id])

    assert(context[ep1.id] == N)
    assert(context[ep2.id] == N)

    print(format(" test loop: Messages: %d\t drop rate: %2d %%\t ticks: %d\t-- ok",
        N, (drop_rate*100)//1, ticks))
end

local function self_test()
    print("[Reliable Endpoint]")
    test_loop(100, 0.0)
    test_loop(20, 0.5, true)
    -- Core will not chew this
    if not CORE_ENV then
    --[[
        test_loop(1000, 0.5)
        test_loop(1000, 0.99)
        test_loop(10000, 0.0)
        test_loop(10000, 0.1)
        test_loop(10000, 0.5)
        test_loop(10000, 0.7)
    --]]
    --[[ soak, use with caution
        test_loop(100000, 0.99, true)
    --]]
    end
end

self_test()

-- module
ReliableEndpoint.DEFAULT_CONFIG = DEFAULT_CONFIG
-- just some reserved, unique, short string
ReliableEndpoint.READY = "<~READY!~>"
return ReliableEndpoint
