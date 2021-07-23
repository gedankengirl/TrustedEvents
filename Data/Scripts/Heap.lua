--[[
    Heap (priority queue) with compare function.
]]

local Heap = {type=="Heap"}
Heap.__index = Heap

local function _lt(a, b) return a < b end
local function _gt(a, b) return b < a end

function Heap.New(comp)
    assert(comp and type(comp) == "function", "no compare function")
    return setmetatable({_n = 0, _pq = {}, _comp = comp}, Heap)
end

function Heap.NewMin() return Heap.New(_lt) end

function Heap.NewMax() return Heap.New(_gt) end

function Heap:Peek()
    return self._pq[1]
end

function Heap:Count()
    return self._n
end

function Heap:IsEmpty()
    return self._n == 0
end

function Heap:Push(el)
    local k, pq, comp = self._n + 1, self._pq, self._comp
    self._n = k
    -- assert(k == #pq+1)
    pq[k] = el
    while true do
        local parent = k//2
        if k > 1 and comp(pq[k], pq[parent]) then
            pq[k], pq[parent] = pq[parent], pq[k]
            k = parent
        else
          break
        end
    end
    return self
end

function Heap:Pop()
    if self._n == 0 then return nil end
    local n, pq, comp = self._n, self._pq, self._comp
    local result = pq[1]
    pq[1] = pq[n]
    pq[n] = nil
    n = n - 1
    local k = 1
    while 2*k <= n do
        local child = 2*k
        if child < n and comp(pq[child + 1], pq[child]) then
            child = child + 1
        end
        if not comp(pq[child], pq[k]) then
            break
        end
        pq[k], pq[child] = pq[child], pq[k]
        k = child
    end
    self._n = n
    return result
end

function Heap:Purge()
    for i = self._n, 1, -1 do
        self._pq[i] = nil
    end
    self._n = 0
end

-- hacky
function Heap:_for_each(fun)
    for i=1, self._n do
        fun(self._pq[i])
    end
end

-- test helper
local function _assert_heap_invariant(self, k)
    local msg =  "ERROR -- order invariant does not hold."
    k = k or 1
    local comp = self._comp
    if k > self._n then
        return true
    end
    local left = 2*k
    if left <= self._n and comp(self._pq[left], self._pq[k]) then
        return assert(false, msg)
    end
    local right = left + 1
    if right <= self._n and comp(self._pq[right], self._pq[k]) then
        return assert(false, msg)
    end
    return assert(_assert_heap_invariant(self, left) and _assert_heap_invariant(self, right), msg)
end

-- --------------------------------------------------------------------------

local function _test()

    do
        local pqmin = Heap.NewMin()
        pqmin:Push(3):Push(1):Push(2):Push(4):Push(5)
        _assert_heap_invariant(pqmin)
        assert(pqmin:Count() == 5 and #pqmin._pq == 5)
        local out = {}
        while pqmin:Count() > 0 do
            out[#out+1] = pqmin:Pop()
            _assert_heap_invariant(pqmin)
        end
        assert(pqmin:IsEmpty() and pqmin:Count() == 0 and pqmin:Peek() == nil and #pqmin._pq == 0)
        assert(out[1] == 1 and out[2] == 2 and out[3] == 3 and out[4] == 4 and out[5] == 5)
    end

    do
        local pqmax = Heap.NewMax()
        pqmax:Push(3):Push(1):Push(2):Push(4):Push(5):Push(2)
        _assert_heap_invariant(pqmax)
        assert(pqmax:Count() == 6 and #pqmax._pq == 6)
        local sum = 0
        pqmax:_for_each(function(x) sum = sum + x end)
        assert(sum == 17)
        local out = {}
        while pqmax:Count() > 0 do
            out[#out+1] = pqmax:Pop()
            _assert_heap_invariant(pqmax)
        end
        assert(pqmax:IsEmpty() and pqmax:Count() == 0 and #pqmax._pq == 0)
        assert(out[1] == 5 and out[2] == 4 and out[3] == 3 and out[4] == 2 and out[5] == 2 and out[6] == 1)
    end

    print("heap -- ok")
end
_test()

return Heap