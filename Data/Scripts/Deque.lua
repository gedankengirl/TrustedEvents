--[[
    Deque
    A double ended queue from PIL.
--]]

local Deque = {}
Deque.__index = Deque

function Deque.New()
    return setmetatable({_front = 0, _back = -1}, Deque)
end

function Deque:Clear()
    for i = self._front, self._back, 1 do
        self[i] = nil
    end
    self._front = 0
    self._back = -1
end

function Deque:Empty()
    return self._front > self._back
end

function Deque:Count()
    if not self:Empty() then
        return self._back - self._front + 1
    else
        return 0
    end
end

function Deque:PushBack(value)
    self._back = self._back + 1
    self[self._back] = value
end

function Deque:PushFront(value)
    self._front = self._front - 1
    self[self._front] = value
end

function Deque:Front()
    if not self:Empty() then
        return self[self._front]
    else
        return nil
    end
end

function Deque:Back()
    if not self:Empty() then
        return self[self._back]
    else
        return nil
    end
end

function Deque:PopBack()
    if not self:Empty() then
        local val = self[self._back]
        self[self._back] = nil
        self._back = self._back - 1
        return val
    else
        return nil
    end
end

function Deque:PopFront()
    if not self:Empty() then
        local val = self[self._front]
        self[self._front] = nil
        self._front = self._front + 1
        return val
    else
        return nil
    end
end

-- extra exports
Deque.PeekFront = Deque.Front
Deque.PeekBack = Deque.Back
Deque.Push = Deque.PushBack
Deque.Pop = Deque.PopFront
Deque.Peek = Deque.Front
Deque.IsEmpty = Deque.Empty

local function _test()
    local q = Deque.New()
    assert(q:Count() == 0 and q:IsEmpty())
    q:Push(1)
    q:Push(2)
    q:Push(3)
    q:Push(4)
    assert(q:Count() == 4 and not q:IsEmpty())
    assert(q:Front() == 1 and q:Back() == 4)
    q:PopFront()
    q:PopBack()
    assert(q:Front() == 2 and q:Back() == 3 and q:Count() == 2)


   print("deque -- ok")
end
_test()

return Deque