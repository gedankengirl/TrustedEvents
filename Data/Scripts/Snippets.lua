-- LuaFormatter off
--[[
    Lua 5.3 bits, little snippets and notes
    * https://www.ilikebigbits.com/2015_03_04_plane_from_points.html
    * What in C is (i % N) in Lua must become ((i-1)%N + 1), i=1 .. inf
    * [de]serialize set of ints: utf8.char <-> utf8.codepoint. Max int = 2^21 (~2E+6).
    * For inspiration:
        + [Util] https://github.com/rxi/lume/blob/master/lume.lua
        + [Math] https://github.com/excessive/cpml + [3D Anim] https://github.com/excessive/anim9
        + [Crypto] https://github.com/philanc/plc
        + [BITHACKS] https://graphics.stanford.edu/~seander/bithacks.html
		+ cool funtions https://iquilezles.org/www/articles/functions/functions.htm
    * math.random :: (nil) -> [0,1) | (a:int, b:int) -> [a,b] | (n:int) -> [1, n]
--]]
local CORE_ENV = CoreString and CoreMath

local PI_2 = 2 * math.pi

local pairs, ipairs = pairs, ipairs
local rand = math.random
math.randomseed(os.time())
local abs, sqrt, cos, sin, log = math.abs, math.sqrt, math.cos, math.sin, math.log
local ceil, floor = math.ceil, math.floor

local snippets = {}


-- convert to signed
local function u32_to_i32(n)
    n = n & 0xFFFFFFFF
    return n <= 0x7FFFFFFF and n or n - 0x100000000
end
snippets.u32_to_i32 = u32_to_i32

local function u16_to_i16(n)
    n = n & 0xFFFF
    return n <= 0x7FFF and n or n - 0x10000
end
snippets.u16_to_i16 = u16_to_i16

local function is_power_of_2(n)
    return n & (n - 1) == 0
end
snippets.is_power_of_2 = is_power_of_2

local function clamp(x, min, max)
    return x < min and min or x < max and x or max
end
snippets.clamp = clamp

-- Euclidean (non negative) `%` for modilar arithmetic.
-- NOTE: for M == 2^n `mod` eqvivalent to: `x & (M - 1)`
local function mod(x, M)
    assert(M > 0)
    assert(not is_power_of_2(M), "M is a power of 2, use `x & (M - 1)`")
    local r = x % M
    return r < 0 and r + M or r
end
snippets.mod = mod

-- Wraps x to be between min and max, inclusive
--[[ dirty version
    local r = hi - lo
    return num - math.floor((num - lo) / r) * r
]]
local function wrapf(x, min, max)
    local size = max - min
    local result = x
    while result < min do
        result = result + size
    end
    while result > max do
        result = result - size
    end
    return result
end
snippets.wrapf = wrapf

-- lerp - stable version
local function lerp(a, b, t)
    return a * (1.0 - t) + t * b
end
snippets.lerp = lerp

-- returns the percentage along a line from `min` to `max` that `val` is
local function inverse_lerp(min, max, val)
    local divisor = max - min
    if divisor > -0.00000001 and divisor < 0.00000001 then return val >= max and 1 or 0 end
    return (val - min)/divisor
end
snippets.inverse_lerp = inverse_lerp

-- scales a value from one range to another.
local function remap(val, min_in, max_in, min_out, max_out)
    return lerp(min_out, max_out, inverse_lerp(min_in, max_in, val))
end
snippets.remap = remap

-- example: remap hp to output colors:
-- remap(20, 50, Color.RED, Color.GREEN, health)
local function clamped_remap(val, min_in, max_in, min_out, max_out)
    return lerp(min_out, max_out, clamp(inverse_lerp(min_in, max_in, val), 0, 1))
end
snippets.clamped_remap = clamped_remap


-- up to 32 bit
local function next_power_of_2(x)
    x = x - 1
    x = x | x >> 1
    x = x | x >> 2
    x = x | x >> 4
    x = x | x >> 8
    x = x | x >> 16
    -- x = x | x >> 32 -- for 64 bit
    return x + 1
end
snippets.next_power_of_2 = next_power_of_2

-- NOTE:  bits are numbered from 0 (least significant) to 63 (most significant)
-- retuns [idx0, idx0 + width - 1] bits
local function extract_bits64(x, idx0, width)
    width = width or 1
    assert(math.tointeger(x))
    assert(width > 0)
    assert(idx0 + width <= 64)
    local mask = ~(-1 << width)
    return (x >> idx0) & mask
end

local function replace_bits64(x, v, idx0, width)
    width = width or 1
    assert(math.tointeger(x))
    assert(math.tointeger(v))
    assert(width > 0)
    assert(idx0 + width <= 64)
    local mask = ~(-1 << width)
    v = v & mask -- erase bits outside given width
    return (x & ~(mask << idx0)) | (v << idx0)
end

local function replace_bits32(x, v, idx0, width)
    return replace_bits64(x, v, idx0, width) & 0xFFFFFFFF
end

snippets.extract_bits64 = extract_bits64
snippets.replace_bits64 = replace_bits64
snippets.replace_bits32 = replace_bits32

local clock do
    if not CORE_ENV then
        local ok, socket = pcall(require, "socket")
        clock = ok and socket.gettime or os.clock
    else
        clock = os.clock
    end
end
snippets.clock = clock

-- formatting
function snippets.formatOrdinal(n)
    assert(n >= 1)
    local num = string.format("%d", n // 1)
    local last2 = string.sub(num, -2)
    if last2 == "11" then return num .. "th" end
    if last2 == "12" then return num .. "th" end
    if last2 == "13" then return num .. "th" end
    local last = string.sub(num, -1)
    if last == "1" then return num .. "st" end
    if last == "2" then return num .. "nd" end
    if last == "3" then return num .. "rd" end
    return num .. 'th'
end

-- function for wrapping very long text-encoded data
function snippets.wrap(text, width)
    assert(type(text) == "string")
    width = width or 72
    if #text <= width then
        return text
    end
    return (text:gsub(string.rep(".", width), "%1\n"))
end

-- timestamps
local os_time, os_date = os.time, os.date
local function utc_timestamp() return os_time(os_date "!*t") end

local function format_timestamp(timestamp)
    local d = os_date("!*t", timestamp)
    return string.format("%04d-%02d-%02d %02d:%02d:%02d", d.year, d.month, d.day, d.hour, d.min, d.sec)
end
snippets.utc_timestamp = utc_timestamp
snippets.format_timestamp = format_timestamp


-- ZigZag encoding for negative integers
-- https://en.wikipedia.org/wiki/Variable-length_quantity#Zigzag_encoding
local function zigzag_encode(i)
    assert(abs(i) < 0x80000000, "abs(i) >= 2^31")
    return (i << 1 & 0xFFFFFFFF) ~ (i >> 31 & 0xFFFFFFFF)
end

local function zigzag_decode(i) return (i >> 1) ~ -(i & 1) end

snippets.zigzag_encode = zigzag_encode
snippets.zigzag_decode = zigzag_decode

-- Table optimizations
-- ar_swap_remove: remove and swap with last element of array, O(1) and 10x faster then table.remove
function snippets.array_swap_remove(ar, idx)
    local n = #ar
    local res = ar[idx]
    ar[idx] = ar[n]
    ar[n] = nil
    return res
end

-- in-place array reverce
function snippets.array_reverse(ar)
    local n = #ar
    for i = 1, n//2 do
        ar[i], ar[n - i + 1] = ar[n - i + 1], ar[i]
    end
end

function snippets.table_clear(t)
    -- NOTE: it's an idiomatic way to `erase & modify` table.
    -- Using `pairs` will cause errors if `t[k] = nil` has side effects to `t`.
    local k, v = next(t)
    while v ~= nil do
        t[k] = nil
        -- use k, v and modify table here ...
        k, v = next(t)
    end
end

function snippets.array_clear(ar, null)
    local n = #ar
    for i = n, 1, -1 do
        ar[i] = null -- or `nil` if we don't care to preserve shape
    end
end

 -- classic Fisher-Yates shaffle (https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle)
function snippets.array_shuffle(ar)
    for i = #ar, 2, -1 do
        local r = rand(i)
        ar[i], ar[r] = ar[r], ar[i]
    end
    return ar
end

-- insertion sort: stable, good for near-sorted arrays
local insertion_sort do
    local function _less(lhs, rhs) return lhs < rhs end

    insertion_sort = function(array, compare)
        compare = compare or _less
        local n = #array
        for i = 2, n do
            local key = array[i]
            local j = i - 1
            while j > 0 and compare(key, array[j]) do
                array[j + 1] = array[j]
                j = j - 1
            end
            array[j + 1] = key
        end
        return array
    end
end
snippets.insertion_sort = insertion_sort

-- pythonic uniform
local function uniform(a, b)
    assert(a < b, "empty interval")
    return a + (b - a) * rand()
end
snippets.uniform = uniform

-- gamma-corrected: rand^gamma, practical range for gamma: [3, 0.3]
function snippets.skewed(a, b, gamma)
    assert(a < b, "empty interval")
    assert(gamma and type(gamma) == "number", "gamma undefined")
    local r = rand()
    return a + (b - a) * r ^ gamma
end

-- https://eli.thegreenplace.net/2010/01/22/weighted-random-generation-in-python
function snippets.weightedchoice(t)
    local sum = 0
    for _, w in pairs(t) do
        sum = sum + w
    end
    local rnd = uniform(0, sum)
    for k, w in pairs(t) do
        rnd = rnd - w
        if rnd < 0 then
            return k
        end
    end
end

local bitstr do
    local NIBBLES = {[0] =
        "0000", "0001", "0010", "0011",
        "0100", "0101", "0110", "0111",
        "1000", "1001", "1010", "1011",
        "1100", "1101", "1110", "1111",
    }

    -- converts integer to binary string
    bitstr = function(v, sep, width, out)
        assert(math.type(v) == "integer")
        width = width or 32
        assert(math.type(width) == "integer" and width % 8 == 0, "`width` should be 8, 16, 24, 32 or 64")
        sep, out = sep or " ", out or {}
        for b = (width // 8 - 1), 0, -1 do
            local byte = v >> 8 * b & 0xFF
            out[#out + 1] = NIBBLES[byte >> 4 & 0xF]
            out[#out + 1] = NIBBLES[byte & 0xF]
        end
        return table.concat(out, sep)
    end
end

snippets.bitstr = bitstr

local popcount32, popcount64 do
    -- https://en.wikipedia.org/wiki/Hamming_weight
    -- NOTE: popcount (without assert) 50% faster then 8-bit table lookup

    popcount64 = function(i64)
        -- assert(math.tointeger(i64))
        i64 = i64 - ((i64 >> 1) & 0x5555555555555555)
        i64 = (i64 & 0x3333333333333333) + ((i64 >> 2) & 0x3333333333333333)
        i64 = (i64 + (i64 >> 4)) & 0x0F0F0F0F0F0F0F0F
        return (i64 * 0x0101010101010101) >> 56
    end

    popcount32 = function(i32)
        i32 = i32 - ((i32 >> 1) & 0x55555555)
        i32 = (i32 & 0x33333333) + ((i32 >> 2) & 0x33333333)
        i32 = (i32 + (i32 >> 4)) & 0x0F0F0F0F
        return ((i32 * 0x01010101) & 0xFFFFFFFF) >> 24
    end
end

snippets.popcount32 = popcount32
snippets.popcount64 = popcount64

-- measure the time and memory consumption of the thunk execution
local function perfn(tag, times, thunk)
    if not CORE_ENV then
        collectgarbage("collect")
        collectgarbage("stop")
    end
    local m1 = collectgarbage("count")
    local t1 = clock()
    local result = nil
    for i = 1, times do
        result = thunk()
    end
    local t2 = clock()
    local m2 = collectgarbage("count")
    if not CORE_ENV then
        collectgarbage("restart")
    end
    local tmstr = string.format("time: %0.4fs mem: %0.2fK", t2 - t1, m2 - m1)
    if times <= 1 then
        print("REPF:", tag, tmstr)
    else
        print(string.format("PERF: %d", times), tag, tmstr)
    end
    return result
end

local function perf(tag, thunk) return perfn(tag, 1, thunk) end

snippets.perfn = perfn
snippets.perf = perf

-- https://community.khronos.org/t/zoom-to-fit-screen/59857/12
function snippets.fitSphereToCamera(r, fov)
    local scr = UI.GetScreenSize()
    local halfMinFov = 0.5 * math.rad(fov)
    local aspect = scr.x / scr.y
    if aspect < 1 then
        halfMinFov = math.atan(aspect * math.tan(halfMinFov))
    end
    return r / math.sin(halfMinFov)
end

-- kudos waffle
-- assumes obj attached to local view (in Core sence)
function snippets.ScreenPosition(obj, w3d, w2d, fov, x, y, tocam)
    local res = UI.GetScreenSize()
    local wx, wy = res.x, res.y
    fov, x, y = fov or 90, x or wx // 2, y or wy // 2
    local xf = math.tan(fov * math.pi / 360)
    local yf = xf * wy / wx
    local depth = 0.5 * w3d / w2d * wx / xf
    local xo = xf * depth * (x / wx * 2 - 1)
    local yo = -yf * depth * (y / wy * 2 - 1)
    local offset = Vector3.New(depth, xo, yo)
    obj:SetPosition(offset)
    if tocam then
        obj:SetRotation(Rotation.New(-offset, Vector3.UP))
    end
end

-- table deepcopy from lua wiki
local function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
    elseif orig_type == "userdata" then
        local new = orig.New or orig.new -- TODO: should we allow shared references to CoreObjects?
        assert(new, "there is no copy constructor for `userdata`")
        copy = new(orig)
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

snippets.deepcopy = deepcopy

local queue = {--[[Simple FIFO queue]]}
queue.__index = queue
function queue.new() return setmetatable({_read = 0, _write = 0}, queue) end
function queue:empty() return self._read == self._write end
function queue:__len() return self._write - self._read end
function queue:peek() return self[self._read] end
function queue:clear() while #self > 0 do self:pop() end end
function queue:push(v)
    self[self._write] = v
    self._write = self._write + 1
    return self
end
function queue:pop()
    local r = self._read
    if r == self._write then return nil end
    local v = self[r]
    self[r], self._read = nil, r + 1
    return v
end

snippets.queue = queue

-----------------------------------------------------------------------------
-- Core specific
-----------------------------------------------------------------------------

-- pass value to observer before subscribe, like Rx's subject
function snippets.Subject(obj, networkedProperty, callback)
    assert(CORE_ENV)
    local observer = function(coreObject, propertyName)
        if networkedProperty == propertyName then
            -- pcall?
             callback(coreObject:GetCustomProperty(networkedProperty))
        end
    end
    observer(obj, networkedProperty)
    return obj.networkedPropertyChangedEvent:Connect(observer)
end

-- call thunk immediately (not at the end of frame) in it's own thread
function snippets.fastSpawn(thunk)
    local FAST_SPAWN_INTERNAL_EVENT = "%<fast-spawn>"
    local connection
    do
        connection = Events.Connect(FAST_SPAWN_INTERNAL_EVENT, function()
            connection:Disconnect()
            thunk()
        end)
    end
    Events.Broadcast(FAST_SPAWN_INTERNAL_EVENT)
end

--
local function _test()
    local u64 = 0x3333333333333333 -- ..00110011
    for i = 0, 31, 4 do
        local x = extract_bits64(u64, i, 2)
        assert(x == 3)
    end
    local x = extract_bits64(u64, 0, 8)
    assert(x == 0x33)

    local u32 = 0x33333333
    x = extract_bits64(u32, 0, 8)
    assert(x == 0x33)
    x = extract_bits64(u32, 4, 1)
    assert(x == 1)
    x = extract_bits64(u32, 28, 4)
    assert(x == 3)

    local u = 0xff94 -- i = 4, w = 3
    -- print(bitstr(u, ' ', 16))
    x = extract_bits64(u, 4, 3)
    -- print(bitstr(x, ' ', 16))
    x = replace_bits32(x, 0xF, 4, 4)
    -- print(bitstr(x, ' ', 16))
    assert(x == 0xF1)
end
_test()

-- LuaFormatter on
return snippets
