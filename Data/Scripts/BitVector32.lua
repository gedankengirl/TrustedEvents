---------------------------------------
-- bitvector32
---------------------------------------
--[[
    * 32-bit bitset that supports conversion from/to uint32 and int32.
    * Supports set/get bits with index `[i]` notation (i in [0, 31]).
    * Supports `extract` and `replace` bitfields (like in Lua 5.2).
    (!) Module retuns only constructor, not whole metatable.
--]]

local getmetatable, setmetatable = getmetatable, setmetatable
local random, mathtype, tonumber = math.random, math.type, tonumber
local rawget, type, pcall = rawget, type, pcall
local assert, print, format, concat = assert, print, string.format, table.concat

-- for testing
local CORE_ENV = CoreDebug and true
local Environment, Game, Storage, Task = Environment, Game, Storage, Task
local warn = warn or print

_ENV = nil

local bitvector32 = {type = "bitvector32"}
bitvector32.__index = bitvector32

-- @ bitvector32.new :: [integer=0] -> bitvector32
function bitvector32.new(integer)
    integer = integer or 0
    assert(mathtype(integer) == "integer", "arg should be `integer`")
    -- convert to uint32
    integer = integer & 0xFFFFFFFF
    return setmetatable({_data = integer}, bitvector32)
end

-- 0-based indices in [0, 31]
function bitvector32:__index(i)
    if mathtype(i) == "integer" then
        assert(i >= 0 and i <= 31, "index should be integer in [0, 31]")
        return self._data & (1 << i) ~= 0
    end
    return rawget(bitvector32, i) -- to get methods etc.
end

-- 0-based indices in [0, 31]
function bitvector32:__newindex(i, v)
    assert(mathtype(i) == "integer" and i >= 0 and i <= 31, "index should be integer in [0, 31]")
    self._data = v and self._data | (1 << i) or self._data & ~(1 << i)
end

-- Lua 5.2 `bit32.extract` (https://www.lua.org/manual/5.2/manual.html#pdf-bit32.extract)
-- bits are numbered from 0 (LSB) to 31 (MSB)
-- returns [i, i + width - 1] bits
function bitvector32:extract(i, width)
    width = width or 1
    assert(width > 0 and i + width <= 32)
    return self._data >> i & ~(-1 << width)
end

-- Lua 5.2 `bit32.replace` (https://www.lua.org/manual/5.2/manual.html#pdf-bit32.replace)
-- replace [i, i + width - 1] bits with value of `v`
function bitvector32:replace(v, i, width)
    assert(mathtype(v) == "integer")
    assert(width > 0)
    assert(i + width <= 32)
    local mask = ~(-1 << width)
    v = v & mask -- erase bits outside given width
    self._data = self._data & ~(mask << i) | (v << i)
end

-- @ bitvector32.find_and_swap :: self[, val=false] ^-> i | nil
-- finds first entry of value, set it to opposite, returns it's index
function bitvector32:find_and_swap(val)
    val = val and true or false
    for i = 0, 31 do
        if val == self[i] then
            self[i] = not val
            return i
        end
    end
end

-- @ bitvector32.swap :: self, i ^-> i
-- sets value at index to opposite
function bitvector32:swap(i)
    local val = self[i]
    self[i] = not val
    return i
end

-- Popcount aka Hamming Weight (https://en.wikipedia.org/wiki/Hamming_weight)
-- @ bitvector32.popcount self -> int in [0, 32]
-- counts number of set bits
function bitvector32:popcount()
    local n = self._data
    n = n - (n >> 1 & 0x55555555)
    n = (n & 0x33333333) + (n >> 2 & 0x33333333)
    n = (n + (n >> 4)) & 0x0F0F0F0F
    return (n * 0x01010101 & 0xFFFFFFFF) >> 24
end

-- @ bitvector32.eq :: self, bitvector32 -> bool
-- value equality
function bitvector32:eq(other)
    return getmetatable(other) == bitvector32 and self._data == other._data
end

-- @ bitvector32.eqv :: self, integer -> bool
-- equality to integer
function bitvector32:eqv(integer)
    return mathtype(integer) == "integer" and self._data == (integer & 0xFFFFFFFF)
end

-- @ bitvector32.int32 :: self -> int32
-- returns underlying uint32 as int32
function bitvector32:int32()
    local n = self._data
    assert(n == (n & 0xFFFFFFFF))
    -- convert to signed
    return n <= 0x7FFFFFFF and n or n - 0x100000000
end

function bitvector32:__tostring()
    return format("<%s:%s>", bitvector32.type, self:bitstring('|'))
end

local NIBBLES = {[0] =
    "0000", "0001", "0010", "0011",
    "0100", "0101", "0110", "0111",
    "1000", "1001", "1010", "1011",
    "1100", "1101", "1110", "1111",
}

-- @ bitvector32:bitstring :: self[, sep=''] -> str
-- returns a string with individual bits representation (for debug purpose)
-- bit order: MSB(i=31) ... LSB(i=0)
-- optional separator for separating `nibbles` (4-bit sequences)
function bitvector32:bitstring(sep)
    local n = self._data
    local out = {}
    for b = 3, 0, -1 do
        local byte = n >> 8 * b & 0xFF
        out[#out + 1] = NIBBLES[byte >> 4 & 0xF]
        out[#out + 1] = NIBBLES[byte & 0xF]
    end
    return concat(out, sep)
end

-- returns data truncated
function bitvector32:uint32() return self._data end

-- alias `eq` to `==` operator
bitvector32.__eq = bitvector32.eq
-- alias `uint32` to call opertor `()`
bitvector32.__call = bitvector32.uint32
-- alias `popcount` to `#` operator
bitvector32.__len = bitvector32.popcount

---------------------------------------
-- Tests
---------------------------------------
local function basic_test()
    local bv = bitvector32.new()
    assert(not bv[1])
    bv[0] = 1
    assert(bv[0])
    assert(not bv[31])
    bv[31] = 1
    assert(bv[31])

    do -- check operator aliases
        local bv1 = bitvector32.new(bv:int32())
        assert(bv == bv1)
        assert(#bv == #bv1)
        assert(bv() == bv1())
    end

    -- index limits
    assert(not pcall(function() local _ = bv[32] end))
    assert(not pcall(function() local _ = bv[-1] end))

    -- bitstring
    assert(bv:bitstring("|") == "1000|0000|0000|0000|0000|0000|0000|0001")
    assert(bitvector32.new(0x55555555):bitstring() == "01010101010101010101010101010101")
    assert(0x12345678 == tonumber(bitvector32.new(0x12345678):bitstring(), 2))

    -- uint32 <-> int32
    do
        local i32 = -2147483648
        local b = bitvector32.new(i32)
        assert(b:uint32() == 2147483648)
        assert(b:int32() == i32)
        assert(b:uint32() ~= i32)
        assert(bitvector32.new(b:uint32()) == b)
        assert(b:eqv(-i32))
        assert(b:eqv(i32))
    end

    -- roundtrip
    do
        local b = bitvector32.new()
        b[1] = true
        b[2] = true
        b[5] = true
        b[11] = true
        b[31] = true
        local c = bitvector32.new(b:int32())
        for i = 0, 31 do assert(b[i] == c[i]) end
    end

    -- extract-replace
    local x = 0
    local u32 = bitvector32.new(0x33333333)
    x = u32:extract(0, 8)
    assert(x == 0x33)
    x = u32:extract(4, 1)
    assert(x == 1)
    x = u32:extract(28, 4)
    assert(x == 3)

    local u = bitvector32.new(0xff94) -- i = 4, w = 3
    x = bitvector32.new(u:extract(4, 3))
    x:replace(0xF, 4, 4)
    assert(x:uint32() == 0xF1)

    -- popcount
    local fives = bitvector32.new(0x55555555) -- binary: 0101...
    assert(fives:popcount() == 16)
    if not CORE_ENV then
        for _ = 1, 1000 do
            local xx = random(-2147483648, 2147483647)
            local b = bitvector32.new(xx)
            local c = bitvector32.new(b:int32())
            assert(c == b)
            local c1 = b:popcount()
            local c2 = 0
            for j = 0, 31 do c2 = c2 + (b[j] and 1 or 0) end
            assert(c1 == c2)
        end
    end
    print("  basic_test -- ok")
end

local function _bitvector32_core_resource_test()
    if not CORE_ENV then return end
    if Environment.IsPreview() and Environment.IsServer() then
        while #Game.GetPlayers() == 0 do Task.Wait() end
        local PLAYER = Game.GetPlayers()[1]
        local TEST_KEY = "<$TestKey$>"
        -- NOTE: all Core APIs will convert uint32 to int32
        for i = 1, 100 do
            local x = random(-2147483648, 2147483647)
            -- Resources
            PLAYER:SetResource(TEST_KEY, x)
            assert(x == PLAYER:GetResource(TEST_KEY))
            local b = bitvector32.new(x)
            PLAYER:SetResource(TEST_KEY, b:int32())
            assert(b:int32() == x)
            assert(b:int32() == PLAYER:GetResource(TEST_KEY))
            local b1 = bitvector32.new(PLAYER:GetResource(TEST_KEY))
            assert(b == b1)
            PLAYER:SetResource(TEST_KEY, b:uint32())
            assert(b:int32() == PLAYER:GetResource(TEST_KEY))
            -- Storage
            local pdata = Storage.GetPlayerData(PLAYER)
            pdata[TEST_KEY] = b:uint32()
            Storage.SetPlayerData(PLAYER, pdata)
            x = Storage.GetPlayerData(PLAYER)[TEST_KEY]
            assert(x == b:int32())
            local b2 = bitvector32.new(x)
            assert(b == b2)
        end
        local pdata = Storage.GetPlayerData(PLAYER)
        pdata[TEST_KEY] = nil
        Storage.SetPlayerData(PLAYER, pdata)
    end
    print("  bitvector32_core_resource_test -- ok")
end

local function self_test()
    print("[bitvector32]")
    basic_test()
    _bitvector32_core_resource_test()
end
self_test()

-- module return
-- (!) returns only constructor, not metatable
return bitvector32.new

