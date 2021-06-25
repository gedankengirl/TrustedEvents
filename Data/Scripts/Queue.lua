--[[
    Simpliest FIFO queue.
]]

local Queue = {type="Queue"}
Queue.__index = Queue
function Queue.New() return setmetatable({_read = 0, _write = 0}, Queue) end
function Queue:IsEmpty() return self._read == self._write end
function Queue:__len() return self._write - self._read end
function Queue:Peek() return self[self._read] end
function Queue:Clear() while #self > 0 do self:Pop() end end
function Queue:Push(val)
    self[self._write] = val
    self._write = self._write + 1
    return self
end
function Queue:Pop()
    local read = self._read
    if read == self._write then return nil end
    local val = self[read]
    self[read], self._read = nil, read + 1
    return val
end

---------------------------------------
-- Test
---------------------------------------
local function test()
    local q = Queue.New()
    assert(#q == 0)
    assert(q:IsEmpty())
    q:Push(1)
    assert(#q == 1)
    assert(q:Peek() == 1)
    assert(q:Pop() == 1)

    for i = 1, 100 do
        q:Push(i)
        assert(#q == i)
    end
    for i = 1, 100 do
        local v = q:Pop()
        assert(v == i, "" .. i .. " " .. v)
    end
    assert(#q == 0)
    for i = 0, q._read do assert(q[i] == nil) end

    for i = 1, 100 do
        q:Push(i)
        assert(#q == i)
    end
    assert(#q == 100)
    q:Clear()
    assert(#q == 0)
    for i = 0, q._read do assert(q[i] == nil) end

    print("queue -- ok")
end
test()
