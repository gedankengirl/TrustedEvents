local SlidingWindow = {}
SlidingWindow.__index = SlidingWindow

function SlidingWindow.New(seq_bits, buf_bits)
    seq_bits = seq_bits or 8
    buf_bits = buf_bits or seq_bits - 1
    assert(seq_bits > buf_bits)
    local self = {
        upper = 0, -- write, next to send or too far
        lower = 0, -- read, expected (ack or frame)
        mask = 2 ^ seq_bits - 1,
        size = 2 ^ buf_bits,
        buffer = {}
    }
    return setmetatable(self, SlidingWindow)
end

function SlidingWindow:Count()
    return self.upper - self.lower
end

function SlidingWindow:Ready()
    return self.upper - self.lower < self.size
end



