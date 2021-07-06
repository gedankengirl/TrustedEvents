--
-- lua-MessagePack : <https://fperrad.frama.io/lua-MessagePack/>
--
--[[
    lua-MessagePack (MP) Core extensions:

    * An alias for MP.pack with *measure* option.
      Returns MessagePack serialized string. With truthy `measure` option
      returns the length of serialized string instead.
    @ MP.encode :: data[, measure=nil]-> str(MP)

    * An alias for MP.unpack with interval and "no throw" options. Returns
      message pack encoded string or throw an error. The `no_throw` option
      allows you to return `nil` instead of throwing an error.
    @ MP.decode :: str(MP)[, from=1][, to=#str(MP)][, no_throw=nil] -> data

    * Support for Core types (through MessagePack `ext`):
        - CoreObjectReference (via CoreObjectReferenceProxy)
        - Color
        - Player
        - Rotation
        - Vector2
        - Vector3
        - Vector4
    (!) By default, all non-integer Lua numbers will be serialized as a double (64-bit).
        This option can be changed: `MP.set_number("float|double")`
        All Core's Vector-ish elements will be serialized as float 32.
    (!) Whenever possible, you should use constants (like Color.WHITE or Vector3.ONE) -
        they are much more efficient to serialize.

    Usage (in Core):
    ```
        local mp = require("XXXXXXXX:MessagePack") -- Core style MUID require

        -- Feed it with any lua (no function, of course) or supported Core values:
        local data = {tag = "TestData", Vector2.New(10, 20), Vector3.ONE, Color.CYAN}
        local encoded = mp.encode(data)    -- => string 33 bytes
        local decoded = mp.decode(encoded) -- => {tag="TestData", Vector2(10, 20), Vector3.ONE, Color.CYAN}
    ```

    Core Extensions:
    Copyright (c) 2021 Andrew Zhilin (https://github.com/zoon)

    lua-MessagePack:
    Copyright (c) 2012-2019 Francois Perrad

]]
-- luaFormatter off

local assert = assert
local error = error
local pairs = pairs
local pcall = pcall
local setmetatable = setmetatable
local tostring = tostring
local type = type
local char = string.char
local format = string.format
local math_type = math.type
local tointeger = math.tointeger
local tconcat = table.concat
local pack = string.pack
local unpack = string.unpack

local ipairs = ipairs
local tonumber, print = tonumber, print
local BIG_TIMEOUT = 120
local select = select
local packsize = string.packsize

---------------------------------------
-- Core types:
---------------------------------------
local CoreString = CoreDebug
local CORE_ENV = CoreString and true
local Color = Color
local Rotation = Rotation
local Vector2 = Vector2
local Vector3 = Vector3
local Vector4 = Vector4
local Task = Task
local Game = Game
local World = World
local time = time

_ENV = nil

local m = {}


--[[ debug only
local function hexadump (s)
    return (s:gsub('.', function (c) return format('%02X ', c:byte()) end))
end
m.hexadump = hexadump
--]]

local function argerror (caller, narg, extramsg)
    error("bad argument #" .. tostring(narg) .. " to "
          .. caller .. " (" .. extramsg .. ")")
end

local function typeerror (caller, narg, arg, tname)
    argerror(caller, narg, tname .. " expected, got " .. type(arg))
end

local function checktype (caller, narg, arg, tname)
    if type(arg) ~= tname then
        typeerror(caller, narg, arg, tname)
    end
end

local packers = setmetatable({}, {
    __index = function (t, k)
        if k == 1 then return end   -- allows ipairs
        error("pack '" .. k .. "' is unimplemented")
    end
})
m.packers = packers

packers['nil'] = function (buffer)
    buffer[#buffer+1] = char(0xC0)                      -- nil
end

packers['boolean'] = function (buffer, bool)
    if bool then
        buffer[#buffer+1] = char(0xC3)                  -- true
    else
        buffer[#buffer+1] = char(0xC2)                  -- false
    end
end

packers['string_compat'] = function (buffer, str)
    local n = #str
    if n <= 0x1F then
        buffer[#buffer+1] = char(0xA0 + n)              -- fixstr
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = pack('>B I2', 0xDA, n)      -- str16
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = pack('>B I4', 0xDB, n)      -- str32
    else
        error"overflow in pack 'string_compat'"
    end
    buffer[#buffer+1] = str
end

packers['_string'] = function (buffer, str)
    local n = #str
    if n <= 0x1F then
        buffer[#buffer+1] = char(0xA0 + n)              -- fixstr
    elseif n <= 0xFF then
        buffer[#buffer+1] = char(0xD9, n)               -- str8
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = pack('>B I2', 0xDA, n)      -- str16
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = pack('>B I4', 0xDB, n)      -- str32
    else
        error"overflow in pack 'string'"
    end
    buffer[#buffer+1] = str
end

packers['binary'] = function (buffer, str)
    local n = #str
    if n <= 0xFF then
        buffer[#buffer+1] = char(0xC4, n)               -- bin8
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = pack('>B I2', 0xC5, n)      -- bin16
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = pack('>B I4', 0xC6, n)      -- bin32
    else
        error"overflow in pack 'binary'"
    end
    buffer[#buffer+1] = str
end

local set_string = function (str)
    if str == 'string_compat' then
        packers['string'] = packers['string_compat']
    elseif str == 'string' then
        packers['string'] = packers['_string']
    elseif str == 'binary' then
        packers['string'] = packers['binary']
    else
        argerror('set_string', 1, "invalid option '" .. str .."'")
    end
end
m.set_string = set_string

packers['map'] = function (buffer, tbl, n)
    if n <= 0x0F then
        buffer[#buffer+1] = char(0x80 + n)              -- fixmap
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = pack('>B I2', 0xDE, n)      -- map16
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = pack('>B I4', 0xDF, n)      -- map32
    else
        error"overflow in pack 'map'"
    end
    for k, v in pairs(tbl) do
        packers[type(k)](buffer, k)
        packers[type(v)](buffer, v)
    end
end

packers['array'] = function (buffer, tbl, n)
    if n <= 0x0F then
        buffer[#buffer+1] = char(0x90 + n)              -- fixarray
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = pack('>B I2', 0xDC, n)      -- array16
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = pack('>B I4', 0xDD, n)      -- array32
    else
        error"overflow in pack 'array'"
    end
    for i = 1, n do
        local v = tbl[i]
        packers[type(v)](buffer, v)
    end
end

local set_array = function (array)
    if array == 'without_hole' then
        packers['_table'] = function (buffer, tbl)
            local is_map, n, max = false, 0, 0
            for k in pairs(tbl) do
                if type(k) == 'number' and k > 0 then
                    if k > max then
                        max = k
                    end
                else
                    is_map = true
                end
                n = n + 1
            end
            if max ~= n then    -- there are holes
                is_map = true
            end
            if is_map then
                packers['map'](buffer, tbl, n)
            else
                packers['array'](buffer, tbl, n)
            end
        end
    elseif array == 'with_hole' then
        packers['_table'] = function (buffer, tbl)
            local is_map, n, max = false, 0, 0
            for k in pairs(tbl) do
                if type(k) == 'number' and k > 0 then
                    if k > max then
                        max = k
                    end
                else
                    is_map = true
                end
                n = n + 1
            end
            if is_map then
                packers['map'](buffer, tbl, n)
            else
                packers['array'](buffer, tbl, max)
            end
        end
    elseif array == 'always_as_map' then
        packers['_table'] = function(buffer, tbl)
            local n = 0
            for k in pairs(tbl) do
                n = n + 1
            end
            packers['map'](buffer, tbl, n)
        end
    else
        argerror('set_array', 1, "invalid option '" .. array .."'")
    end
end
m.set_array = set_array

packers['table'] = function (buffer, tbl)
    packers['_table'](buffer, tbl)
end

packers['unsigned'] = function (buffer, n)
    if n >= 0 then
        if n <= 0x7F then
            buffer[#buffer+1] = char(n)                 -- fixnum_pos
        elseif n <= 0xFF then
            buffer[#buffer+1] = char(0xCC, n)           -- uint8
        elseif n <= 0xFFFF then
            buffer[#buffer+1] = pack('>B I2', 0xCD, n)  -- uint16
        elseif n <= 0xFFFFFFFF then
            buffer[#buffer+1] = pack('>B I4', 0xCE, n)  -- uint32
        else
            buffer[#buffer+1] = pack('>B I8', 0xCF, n)  -- uint64
        end
    else
        if n >= -0x20 then
            buffer[#buffer+1] = char(0x100 + n)         -- fixnum_neg
        elseif n >= -0x80 then
            buffer[#buffer+1] = pack('>B i1', 0xD0, n)  -- int8
        elseif n >= -0x8000 then
            buffer[#buffer+1] = pack('>B i2', 0xD1, n)  -- int16
        elseif n >= -0x80000000 then
            buffer[#buffer+1] = pack('>B i4', 0xD2, n)  -- int32
        else
            buffer[#buffer+1] = pack('>B i8', 0xD3, n)  -- int64
        end
    end
end

packers['signed'] = function (buffer, n)
    if n >= 0 then
        if n <= 0x7F then
            buffer[#buffer+1] = char(n)                 -- fixnum_pos
        elseif n <= 0x7FFF then
            buffer[#buffer+1] = pack('>B i2', 0xD1, n)  -- int16
        elseif n <= 0x7FFFFFFF then
            buffer[#buffer+1] = pack('>B i4', 0xD2, n)  -- int32
        else
            buffer[#buffer+1] = pack('>B i8', 0xD3, n)  -- int64
        end
    else
        if n >= -0x20 then
            buffer[#buffer+1] = char(0xE0 + 0x20 + n)   -- fixnum_neg
        elseif n >= -0x80 then
            buffer[#buffer+1] = pack('>B i1', 0xD0, n)  -- int8
        elseif n >= -0x8000 then
            buffer[#buffer+1] = pack('>B i2', 0xD1, n)  -- int16
        elseif n >= -0x80000000 then
            buffer[#buffer+1] = pack('>B i4', 0xD2, n)  -- int32
        else
            buffer[#buffer+1] = pack('>B i8', 0xD3, n)  -- int64
        end
    end
end

local set_integer = function (integer)
    if integer == 'unsigned' then
        packers['integer'] = packers['unsigned']
    elseif integer == 'signed' then
        packers['integer'] = packers['signed']
    else
        argerror('set_integer', 1, "invalid option '" .. integer .."'")
    end
end
m.set_integer = set_integer

packers['float'] = function (buffer, n)
    buffer[#buffer+1] = pack('>B f', 0xCA, n)
end

packers['double'] = function (buffer, n)
    buffer[#buffer+1] = pack('>B d', 0xCB, n)
end

local set_number = function (number)
    if number == 'float' then
        packers['number'] = function (buffer, n)
            if math_type(n) == 'integer' then
                packers['integer'](buffer, n)
            else
                packers['float'](buffer, n)
            end
        end
    elseif number == 'double' then
        packers['number'] = function (buffer, n)
            if math_type(n) == 'integer' then
                packers['integer'](buffer, n)
            else
                packers['double'](buffer, n)
            end
        end
    else
        argerror('set_number', 1, "invalid option '" .. number .."'")
    end
end
m.set_number = set_number

for k = 0, 4 do
    local n = tointeger(2^k)
    local fixext = 0xD4 + k
    packers['fixext' .. tostring(n)] = function (buffer, tag, data)
        assert(#data == n, "bad length for fixext" .. tostring(n))
        buffer[#buffer+1] = pack('>B i1', fixext, tag)
        buffer[#buffer+1] = data
    end
end

packers['ext'] = function (buffer, tag, data)
    local n = #data
    if n <= 0xFF then
        buffer[#buffer+1] = pack('>B B i1', 0xC7, n, tag)       -- ext8
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = pack('>B I2 i1', 0xC8, n, tag)      -- ext16
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = pack('>B I4 i1', 0xC9, n, tag)      -- ext32
    else
        error"overflow in pack 'ext'"
    end
    buffer[#buffer+1] = data
end

function m.pack (data)
    local buffer = {}
    packers[type(data)](buffer, data)
    return tconcat(buffer)
end

local unpackers         -- forward declaration

local function unpack_cursor (c)
    local s, i, j = c.s, c.i, c.j
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local val = s:byte(i)
    c.i = i+1
    return unpackers[val](c, val)
end
m.unpack_cursor = unpack_cursor

local function unpack_str (c, n)
    local s, i, j = c.s, c.i, c.j
    local e = i+n-1
    if e > j or n < 0 then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
        e = i+n-1
    end
    c.i = i+n
    return s:sub(i, e)
end

local function unpack_array (c, n)
    local t = {}
    for i = 1, n do
        t[i] = unpack_cursor(c)
    end
    return t
end

local function unpack_map (c, n)
    local t = {}
    for i = 1, n do
        local k = unpack_cursor(c)
        local val = unpack_cursor(c)
        if k == nil or k ~= k then
            k = m.sentinel
        end
        if k ~= nil then
            t[k] = val
        end
    end
    return t
end

local function unpack_float (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+4
    return unpack('>f', s, i)
end

local function unpack_double (c)
    local s, i, j = c.s, c.i, c.j
    if i+7 > j then
        c:underflow(i+7)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+8
    return unpack('>d', s, i)
end

local function unpack_uint8 (c)
    local s, i, j = c.s, c.i, c.j
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+1
    return unpack('>I1', s, i)
end

local function unpack_uint16 (c)
    local s, i, j = c.s, c.i, c.j
    if i+1 > j then
        c:underflow(i+1)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+2
    return unpack('>I2', s, i)
end

local function unpack_uint32 (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+4
    return unpack('>I4', s, i)
end

local function unpack_uint64 (c)
    local s, i, j = c.s, c.i, c.j
    if i+7 > j then
        c:underflow(i+7)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+8
    return unpack('>I8', s, i)
end

local function unpack_int8 (c)
    local s, i, j = c.s, c.i, c.j
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+1
    return unpack('>i1', s, i)
end

local function unpack_int16 (c)
    local s, i, j = c.s, c.i, c.j
    if i+1 > j then
        c:underflow(i+1)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+2
    return unpack('>i2', s, i)
end

local function unpack_int32 (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+4
    return unpack('>i4', s, i)
end

local function unpack_int64 (c)
    local s, i, j = c.s, c.i, c.j
    if i+7 > j then
        c:underflow(i+7)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+8
    return unpack('>i8', s, i)
end

-- we will define it lower ...
-- function m.build_ext (tag, data)
--     return nil
-- end

local function unpack_ext (c, n, tag)
    local s, i, j = c.s, c.i, c.j
    local e = i+n-1
    if e > j or n < 0 then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
        e = i+n-1
    end
    c.i = i+n
    return m.build_ext(tag, s:sub(i, e))
end

unpackers = setmetatable({
    [0xC0] = function () return nil end,
    [0xC2] = function () return false end,
    [0xC3] = function () return true end,
    [0xC4] = function (c) return unpack_str(c, unpack_uint8(c)) end,    -- bin8
    [0xC5] = function (c) return unpack_str(c, unpack_uint16(c)) end,   -- bin16
    [0xC6] = function (c) return unpack_str(c, unpack_uint32(c)) end,   -- bin32
    [0xC7] = function (c) return unpack_ext(c, unpack_uint8(c), unpack_int8(c)) end,
    [0xC8] = function (c) return unpack_ext(c, unpack_uint16(c), unpack_int8(c)) end,
    [0xC9] = function (c) return unpack_ext(c, unpack_uint32(c), unpack_int8(c)) end,
    [0xCA] = unpack_float,
    [0xCB] = unpack_double,
    [0xCC] = unpack_uint8,
    [0xCD] = unpack_uint16,
    [0xCE] = unpack_uint32,
    [0xCF] = unpack_uint64,
    [0xD0] = unpack_int8,
    [0xD1] = unpack_int16,
    [0xD2] = unpack_int32,
    [0xD3] = unpack_int64,
    [0xD4] = function (c) return unpack_ext(c, 1, unpack_int8(c)) end,
    [0xD5] = function (c) return unpack_ext(c, 2, unpack_int8(c)) end,
    [0xD6] = function (c) return unpack_ext(c, 4, unpack_int8(c)) end,
    [0xD7] = function (c) return unpack_ext(c, 8, unpack_int8(c)) end,
    [0xD8] = function (c) return unpack_ext(c, 16, unpack_int8(c)) end,
    [0xD9] = function (c) return unpack_str(c, unpack_uint8(c)) end,
    [0xDA] = function (c) return unpack_str(c, unpack_uint16(c)) end,
    [0xDB] = function (c) return unpack_str(c, unpack_uint32(c)) end,
    [0xDC] = function (c) return unpack_array(c, unpack_uint16(c)) end,
    [0xDD] = function (c) return unpack_array(c, unpack_uint32(c)) end,
    [0xDE] = function (c) return unpack_map(c, unpack_uint16(c)) end,
    [0xDF] = function (c) return unpack_map(c, unpack_uint32(c)) end,
}, {
    __index = function (t, k)
        if k < 0xC0 then
            if k < 0x80 then
                return function (c, val) return val end
            elseif k < 0x90 then
                return function (c, val) return unpack_map(c, val & 0xF) end
            elseif k < 0xA0 then
                return function (c, val) return unpack_array(c, val & 0xF) end
            else
                return function (c, val) return unpack_str(c, val & 0x1F) end
            end
        elseif k > 0xDF then
            return function (c, val) return val - 0x100 end
        else
            return function () error("unpack '" .. format('%#x', k) .. "' is unimplemented") end
        end
    end
})

local function cursor_string (str)
    return {
        s = str,
        i = 1,
        j = #str,
        underflow = function ()
                        error "missing bytes"
                    end,
    }
end

local function cursor_loader (ld)
    return {
        s = '',
        i = 1,
        j = 0,
        underflow = function (self, e)
                        self.s = self.s:sub(self.i)
                        e = e - self.i + 1
                        self.i = 1
                        self.j = 0
                        while e > self.j do
                            local chunk = ld()
                            if not chunk then
                                error "missing bytes"
                            end
                            self.s = self.s .. chunk
                            self.j = #self.s
                        end
                    end,
    }
end

function m.unpack (s)
    checktype('unpack', 1, s, 'string')
    local cursor = cursor_string(s)
    local data = unpack_cursor(cursor)
    if cursor.i <= cursor.j then
        error "extra bytes"
    end
    return data
end

function m.unpacker (src)
    if type(src) == 'string' then
        local cursor = cursor_string(src)
        return function ()
            if cursor.i <= cursor.j then
                return cursor.i, unpack_cursor(cursor)
            end
        end
    elseif type(src) == 'function' then
        local cursor = cursor_loader(src)
        return function ()
            if cursor.i > cursor.j then
                pcall(cursor.underflow, cursor, cursor.i)
            end
            if cursor.i <= cursor.j then
                return true, unpack_cursor(cursor)
            end
        end
    else
        argerror('unpacker', 1, "string or function expected, got " .. type(src))
    end
end

set_string'string_compat'
set_integer'unsigned'
if #pack('n', 0.0) == 4 then
    m.small_lua = true
    unpackers[0xCB] = nil       -- double
    unpackers[0xCF] = nil       -- uint64
    unpackers[0xD3] = nil       -- int64
    set_number'float'
else
    m.full64bits = true
    set_number'double'
    if #pack('n', 0.0) > 8 then
        m.long_double = true
    end
end
set_array'without_hole'

m._VERSION = '0.5.2'
m._DESCRIPTION = "lua-MessagePack : a pure Lua 5.3 implementation"
m._COPYRIGHT = "Copyright (c) 2012-2019 Francois Perrad"
-- luaFormatter on

----------------------------------------------------------------------------
-- Core Extensions for lua-MessagePack
-- Copyright (c) 2021 Andrew Zhilin (https://github.com/zoon)
----------------------------------------------------------------------------
do
    -- NOTE: this is "measure" lite - fast but still allocates. For hardcore
    -- version put `local char, pack = buffer.char, buffer.pack` in the first
    -- line of every `packers[xxx]` function. Pass `char` `select("#, ...)`
    -- instead of `char` and packsize instead of `pack` Memory allocation will
    -- be near-zero, but encoding will be 10-20% slower.
    local measure_buffer do
        local measure_buffer_mt = {}
        measure_buffer_mt.__index = measure_buffer_mt

        function measure_buffer_mt:__newindex(_, v)
            self.length = self.length + #v
        end

        function measure_buffer_mt:__call()
            local length = self.length
            self.length = 0
            return length
        end
        -- assign forward declaration
        measure_buffer = setmetatable({length = 0}, measure_buffer_mt)
    end

    -- An alias for MP.pack with *measure* option
    -- @ encode :: data[, measure] -> str
    -- returns MessagePack serialized string
    -- with truthy `measure` option returns length of serialized string instead.
    m.encode = function(data, measure)
        if not measure then
            return m.pack(data)
        end
        packers[type(data)](measure_buffer, data)
        return measure_buffer()
    end

    local ENCODED_NIL = char(0xC0) -- nil
    local function nil_looader() return ENCODED_NIL end
    local function err_loader() return nil end

    -- @ decode :: data:str[, from=1][, to=#s][, no_throw=nil] -> str | nil | error
    -- data: MessagePack encoded string
    -- Returns message pack encoded string or throw an error. The `no_throw`
    -- option allows you to return `nil` instead of throwing an error.
    m.decode = function(s, from, to, no_throw)
        local c = cursor_loader(no_throw and nil_looader or err_loader)
        c.s = s
        c.i = from or 1
        c.j = to or #s
        return m.unpack_cursor(c)
    end

    -- `CoreObjectReference` has no constructor and we have to use
    -- proxy type copying its interface
    local CoreObjectReferenceProxy = {type = "CoreObjectReference"}
    CoreObjectReferenceProxy.__index = CoreObjectReferenceProxy
    function CoreObjectReferenceProxy.New(muid)
        local self = {}
        self.isAssigned = muid ~= nil
        self.id = muid or "0000000000000000"
        return setmetatable(self, CoreObjectReferenceProxy)
    end

    function CoreObjectReferenceProxy:__tostring() return format("%s: %s", self.type, self.id) end

    function CoreObjectReferenceProxy:IsA(typeName) return typeName == self.type end

    -- NOTE: `__eq` metamethod will be called only if both operands have the
    -- same type, i.e. `userdata` and `table` will not work. Since Lua 5.3, we
    -- can create `userdata` exclusively through the C API. In other words,
    -- this `==` operator rather useless and intended only for ease of writing
    -- tests.
    function CoreObjectReferenceProxy:__eq(other)
        if CoreObjectReferenceProxy.type == other.type then
            return self.id == other.id
        end
        return false
    end

    function CoreObjectReferenceProxy:GetObject()
        if self.isAssigned then
            return World.FindObjectById(self.id)
        end
    end

    function CoreObjectReferenceProxy:WaitForObject(wait)
        wait = wait or BIG_TIMEOUT
        assert(type(wait) == "number")
        if not self.isAssigned then
            return nil
        end
        -- happy path:
        local result = self:GetObject()
        if result then
            return result
        end
        -- unhappy path:
        local begin = time()
        while true do
            Task.Wait(0.1)
            if time() - begin >= wait then
                return false, "no object"
            end
            result = self:GetObject()
            if result then
                return result
            end
        end
    end

    -- Core specific type-tags (should be in [0, 127])
    -- Reference: https://github.com/msgpack/msgpack/blob/master/spec.md#extension-types

    -- Core types will be in [0..40]
    local EXT_CORE_VECTOR3 = 0
    local EXT_CORE_ROTATION = 1
    local EXT_CORE_COLOR = 2
    local EXT_CORE_VECTOR2 = 3
    local EXT_CORE_VECTOR4 = 4
    local EXT_CORE_PLAYER_ID_128 = 5
    local EXT_CORE_PLAYER_ID_STR = 6
    local EXT_CORE_OBJECT_REFERENCE_ID_64 = 7
    local EXT_CORE_OBJECT_REFERENCE_ID_STR = 8

    -- All Core constants will have tag=40 and data:DATA_CORE_CONST_XXX
    local EXT_CORE_CONST = 40

    -- Core constants will have Tag = EXT_CORE_CONST (40) and data:DATA_CORE_CONST_XXX
    -- CoreObjectReference
    local DATA_CORE_CONST_REFERENCE_NOT_ASSIGNED = char(0)
    -- 1..9 reserved

    -- Color
    local DATA_CORE_CONST_COLOR_WHITE = char(10)
    local DATA_CORE_CONST_COLOR_GRAY = char(11)
    local DATA_CORE_CONST_COLOR_BLACK = char(12)
    local DATA_CORE_CONST_COLOR_TRANSPARENT = char(13)
    local DATA_CORE_CONST_COLOR_RED = char(14)
    local DATA_CORE_CONST_COLOR_GREEN = char(15)
    local DATA_CORE_CONST_COLOR_BLUE = char(16)
    local DATA_CORE_CONST_COLOR_CYAN = char(17)
    local DATA_CORE_CONST_COLOR_MAGENTA = char(18)
    local DATA_CORE_CONST_COLOR_YELLOW = char(19)
    local DATA_CORE_CONST_COLOR_ORANGE = char(20)
    local DATA_CORE_CONST_COLOR_PURPLE = char(21)
    local DATA_CORE_CONST_COLOR_BROWN = char(22)
    local DATA_CORE_CONST_COLOR_PINK = char(23)
    local DATA_CORE_CONST_COLOR_TAN = char(24)
    local DATA_CORE_CONST_COLOR_RUBY = char(25)
    local DATA_CORE_CONST_COLOR_EMERALD = char(26)
    local DATA_CORE_CONST_COLOR_SAPPHIRE = char(27)
    local DATA_CORE_CONST_COLOR_SILVER = char(28)
    local DATA_CORE_CONST_COLOR_SMOKE = char(29)
    -- 30 .. 39 reserved

    -- Vector2
    local DATA_CORE_CONST_VECTOR2_ONE = char(40)
    local DATA_CORE_CONST_VECTOR2_ZERO = char(41)
    -- 42 .. 49 reserved

    -- Vector3
    local DATA_CORE_CONST_VECTOR3_ONE = char(51)
    local DATA_CORE_CONST_VECTOR3_ZERO = char(52)
    local DATA_CORE_CONST_VECTOR3_FORWARD = char(53)
    local DATA_CORE_CONST_VECTOR3_UP = char(54)
    local DATA_CORE_CONST_VECTOR3_RIGHT =char(55)
    -- 56 .. 59 reserved

    -- Vector4
    local DATA_CORE_CONST_VECTOR4_ONE = char(60)
    local DATA_CORE_CONST_VECTOR4_ZERO = char(61)
    -- 62 .. 69 reserved

    -- Rotation
    local DATA_CORE_CONST_ROTATION_ZERO = char(70)
    -- 71 .. 79 reserved
    -- 80 .. 255 free

    -- Core constants lookup table {data -> Core Constant}
    local CORE_CONST_DECODE = not CORE_ENV and {} or {
        [DATA_CORE_CONST_REFERENCE_NOT_ASSIGNED] = CoreObjectReferenceProxy.New(nil),

        [DATA_CORE_CONST_COLOR_WHITE] = Color.WHITE,
        [DATA_CORE_CONST_COLOR_GRAY] = Color.GRAY,
        [DATA_CORE_CONST_COLOR_BLACK] = Color.BLACK,
        [DATA_CORE_CONST_COLOR_TRANSPARENT] = Color.TRANSPARENT,
        [DATA_CORE_CONST_COLOR_RED] = Color.RED,
        [DATA_CORE_CONST_COLOR_GREEN] = Color.GREEN,
        [DATA_CORE_CONST_COLOR_BLUE] = Color.BLUE,
        [DATA_CORE_CONST_COLOR_CYAN] = Color.CYAN,
        [DATA_CORE_CONST_COLOR_MAGENTA] = Color.MAGENTA,
        [DATA_CORE_CONST_COLOR_YELLOW] = Color.YELLOW,
        [DATA_CORE_CONST_COLOR_ORANGE] = Color.ORANGE,
        [DATA_CORE_CONST_COLOR_PURPLE] = Color.PURPLE,
        [DATA_CORE_CONST_COLOR_BROWN] = Color.BROWN,
        [DATA_CORE_CONST_COLOR_PINK] = Color.PINK,
        [DATA_CORE_CONST_COLOR_TAN] = Color.TAH,
        [DATA_CORE_CONST_COLOR_RUBY] = Color.RUBY,
        [DATA_CORE_CONST_COLOR_EMERALD] = Color.EMERALD,
        [DATA_CORE_CONST_COLOR_SAPPHIRE] = Color.SAPPHIRE,
        [DATA_CORE_CONST_COLOR_SILVER] = Color.SILVER,
        [DATA_CORE_CONST_COLOR_SMOKE] = Color.SMOKE,

        [DATA_CORE_CONST_VECTOR2_ONE] = Vector2.ONE,
        [DATA_CORE_CONST_VECTOR2_ZERO] = Vector2.ZERO,

        [DATA_CORE_CONST_VECTOR3_ONE] = Vector3.ONE,
        [DATA_CORE_CONST_VECTOR3_ZERO] = Vector3.ZERO,
        [DATA_CORE_CONST_VECTOR3_FORWARD] = Vector3.FORWARD,
        [DATA_CORE_CONST_VECTOR3_UP] = Vector3.UP,
        [DATA_CORE_CONST_VECTOR3_RIGHT] = Vector3.RIGHT,

        [DATA_CORE_CONST_VECTOR4_ONE] = Vector4.ONE,
        [DATA_CORE_CONST_VECTOR4_ZERO] = Vector4.ZERO,
        [DATA_CORE_CONST_ROTATION_ZERO] = Rotation.ZERO
    }

    -- Core constant colors lookup table (Color -> EXT_CORE_COLOR_XXX)
    local CORE_CONST_COLOR_ENCODE = {}
    for data, value in pairs(CORE_CONST_DECODE) do
        if value.type == "Color" then
            CORE_CONST_COLOR_ENCODE[value] = data
        end
    end

    -----------------------------------
    -- Core serialization
    -----------------------------------
    m.packers["userdata"] = function(buffer, udata)
        if udata.type == "CoreObjectReference" then
            if not udata.isAssigned then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_REFERENCE_NOT_ASSIGNED)
            else
                local id = CoreString.Split(udata.id, ":")
                local uid64 = tonumber(id, 16)
                -- NOTE: be conservative: there is no guarantee that `id` retuns 64-bit hex-encoded number
                if uid64 then
                    m.packers.fixext8(buffer, EXT_CORE_OBJECT_REFERENCE_ID_64, pack("I8", uid64))
                else -- failsafe scenario: use id string as-is
                    assert(udata.id and type(udata.id) == "string", "CoreObjectReference has no id")
                    print("INFO: object's MUID is not a 64-bit number:", udata.id)
                    m.packers.ext(buffer, EXT_CORE_OBJECT_REFERENCE_ID_STR, udata.id)
                end
            end
        elseif udata.type == "Color" then
            local data = CORE_CONST_COLOR_ENCODE[udata]
            if data then
                m.packers.fixext1(buffer, EXT_CORE_CONST, data)
            else
                m.packers.fixext4(buffer, EXT_CORE_COLOR, pack("BBBB", udata.r, udata.g, udata.b, udata.a))
            end
        elseif udata.type == "Player" then
            assert(udata.id and type(udata.id) == "string")
            local str128 = nil
            -- if id is UUID, try to serialize it as a pair of uint64
            if #udata.id == 32 then
                local first64, second64 = tonumber(udata.id:sub(1, 16), 16), tonumber(udata.id:sub(17, 32), 16)
                if first64 and second64 then
                    str128 = pack("I8I8", first64, second64)
                end
            end
            -- be conservative, do roundtrip check
            if str128 and format("%x%x", unpack("I8I8", str128)) == udata.id then -- we good
                m.packers.fixext16(buffer, EXT_CORE_PLAYER_ID_128, str128)
            else -- save verbatim id as a string
                m.packers.ext(buffer, EXT_CORE_PLAYER_ID_STR, udata.id)
            end
        elseif udata.type == "Rotation" then
            if udata == Rotation.ZERO then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_ROTATION_ZERO)
            else
                m.packers.ext(buffer, EXT_CORE_ROTATION, pack("fff", udata.x, udata.y, udata.z))
            end
        elseif udata.type == "Vector2" then
            if udata == Vector2.ONE then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR2_ONE)
            elseif udata == Vector2.ZERO then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR2_ZERO)
            else
                m.packers.fixext8(buffer, EXT_CORE_VECTOR2, pack("ff", udata.x, udata.y))
            end
        elseif udata.type == "Vector3" then
            if udata == Vector3.ONE then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR3_ONE)
            elseif udata == Vector3.ZERO then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR3_ZERO)
            elseif udata == Vector3.FORWARD then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR3_FORWARD)
            elseif udata == Vector3.UP then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR3_UP)
            elseif udata == Vector3.RIGHT then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR3_RIGHT)
            else
                m.packers.ext(buffer, EXT_CORE_VECTOR3, pack("fff", udata.x, udata.y, udata.z))
            end
        elseif udata.type == "Vector4" then
            if udata == Vector4.ONE then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR4_ONE)
            elseif udata == Vector4.ZERO then
                m.packers.fixext1(buffer, EXT_CORE_CONST, DATA_CORE_CONST_VECTOR4_ZERO)
            else
                m.packers.fixext16(buffer, EXT_CORE_VECTOR4, pack("ffff", udata.x, udata.y, udata.z, udata.w))
            end
        elseif udata.type then
            error("unsupprted Core type: ", udata.type)
        else
            error("unsuported userdata: " .. tostring(udata))
        end
    end

    -----------------------------------
    -- Core deserialization
    -----------------------------------
    m.build_ext = function(tag, data)
        if tag == EXT_CORE_CONST then
            return CORE_CONST_DECODE[data] or error(format("unknown DATA_CORE_CONST: %d", data))
        elseif tag == EXT_CORE_VECTOR3 then
            local x, y, z = unpack("fff", data)
            return Vector3.New(x, y, z)
        elseif tag == EXT_CORE_ROTATION then
            local x, y, z = unpack("fff", data)
            return Rotation.New(x, y, z)
        elseif tag == EXT_CORE_COLOR then
            local r, g, b, a = unpack("BBBB", data)
            return Color.New(r, g, b, a)
        elseif tag == EXT_CORE_VECTOR2 then
            local x, y = unpack("ff", data)
            return Vector2.New(x, y)
        elseif tag == EXT_CORE_VECTOR4 then
            local x, y, z, w = unpack("ffff", data)
            return Vector4.New(x, y, z, w)
        elseif tag == EXT_CORE_PLAYER_ID_128 then
            local first, second = unpack("I8I8", data)
            local id = format("%x%x", first, second)
            return Game.FindPlayer(id)
        elseif tag == EXT_CORE_PLAYER_ID_STR then
            return Game.FindPlayer(data)
        elseif tag == EXT_CORE_OBJECT_REFERENCE_ID_64 then
            local uid64 = unpack("I8", data)
            local muid = format("%X", uid64)
            return CoreObjectReferenceProxy.New(muid)
        elseif tag == EXT_CORE_OBJECT_REFERENCE_ID_STR then
            return CoreObjectReferenceProxy.New(data)
        else
            error(format("unknown type extension tag: %d", tag))
        end
    end

    -----------------------------------
    -- Test
    -----------------------------------
    local function test_measure()

        assert(type(m.encode("hello", "measure")) == "number")

        local data = {
            0xf,
            123,
            1234,
            1234567890,
            "hello",
            {1, "hello"},
            {1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, {1, 2, 3}},
            3.14159265359,
            {3.14159265359},
            {{{{{{0}}}}}}
        }
        for i, v in pairs(data) do
            assert(#m.encode(v) == m.encode(v, "measure"), "#"..i)
        end
        assert(#m.encode(data) == m.encode(data, "measure"))
        print("  test_measure -- ok")
    end

    local function core_types_test()
        if not CORE_ENV then
            print("  core_types_test -- skipped")
            return
        end
        local core_data = {
            Vector2.New(1.1, 2.2),
            Vector3.New(1.1, 2.2, 3.3),
            Vector4.New(1.1, 2.2, 3.3, 4.4),
            Rotation.New(1.1, 2.2, 3.3),
            Color.New(0, 127, 255, 100),
        }
        for _, val in ipairs(core_data) do
            local p = m.encode(val)
            local v = m.decode(p)
            assert(v == val, tostring(val))
        end

        for _, val in pairs(CORE_CONST_DECODE) do
            local p = m.encode(val)
            local v = m.decode(p)
            assert(v == val, tostring(val))
        end

        print("  core_types_test -- ok")
    end

    local function self_test()
        print("[lua-MessagePack]")
        core_types_test()
        test_measure()
    end

    -- run test
    self_test()

    ---------------------------------------------
    -- Default serialization settings for Core
    ---------------------------------------------
    set_array("without_hole")
    set_string("string")
    set_number("double")

end -- end of extensions

return m
--
-- This library is licensed under the terms of the MIT/X11 license,
-- like Lua itself.
--
