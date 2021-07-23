-- The MIT Licence (MIT)
-- Copyright (c) 2021 Andrew Zhilin (andrew.zhilin@gmail.com)
-- Crockford's Base32 (https://www.crockford.com/base32.html)
-- Ref https://github.com/nmap/nmap/blob/master/nselib/base32.lua

local crockford32 = {}
local char, byte, gsub, find = string.char, string.byte, string.gsub, string.find
local PAD = string.byte('=')

local enc do
    -- '0123456789ABCDEFGHJKMNPQRSTVWXYZ', 0-indexed
    local ENC = {[0] =
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
        0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
        0x47, 0x48, 0x4A, 0x4B, 0x4D, 0x4E, 0x50, 0x51,
        0x52, 0x53, 0x54, 0x56, 0x57, 0x58, 0x59, 0x5A,
    }
    -- export
    crockford32.ENC = ENC

    -- pass data string to _enc
    local _data = nil
    -- caching lambda, it saves us ~100 bytes
    -- unrolled for 30->48 chars, for big strings (> 1K) it gives 3-4x less garbage
    local function _enc(x, y)
        local data = _data -- pass data string to inner scope
        -- 30 -> 48
        if y - x == 30 then
            local
                a1, b1, c1, d1, e1, a2, b2, c2, d2, e2,
                a3, b3, c3, d3, e3, a4, b4, c4, d4, e4,
                a5, b5, c5, d5, e5, a6, b6, c6, d6, e6 = byte(data, x, x + 29)
        return char(
            ENC[(a1>>3)&0x1F], ENC[((a1<<2)&0x1C|(b1>>6)&0x03)&0x1F], ENC[(b1>>1)&0x1F], ENC[((b1<<4)&0x10|(c1>>4)&0x0F)&0x1F],
            ENC[((c1<<1)&0x1E|(d1>>7)&0x01)&0x1F], ENC[(d1>>2)&0x1F], ENC[((d1<<3)&0x18|(e1>>5)&0x07)&0x1F], ENC[e1&0x1F],

            ENC[(a2>>3)&0x1F], ENC[((a2<<2)&0x1C|(b2>>6)&0x03)&0x1F], ENC[(b2>>1)&0x1F], ENC[((b2<<4)&0x10|(c2>>4)&0x0F)&0x1F],
            ENC[((c2<<1)&0x1E|(d2>>7)&0x01)&0x1F], ENC[(d2>>2)&0x1F], ENC[((d2<<3)&0x18|(e2>>5)&0x07)&0x1F], ENC[e2&0x1F],

            ENC[(a3>>3)&0x1F], ENC[((a3<<2)&0x1C|(b3>>6)&0x03)&0x1F], ENC[(b3>>1)&0x1F], ENC[((b3<<4)&0x10|(c3>>4)&0x0F)&0x1F],
            ENC[((c3<<1)&0x1E|(d3>>7)&0x01)&0x1F], ENC[(d3>>2)&0x1F], ENC[((d3<<3)&0x18|(e3>>5)&0x07)&0x1F], ENC[e3&0x1F],

            ENC[(a4>>3)&0x1F], ENC[((a4<<2)&0x1C|(b4>>6)&0x03)&0x1F], ENC[(b4>>1)&0x1F], ENC[((b4<<4)&0x10|(c4>>4)&0x0F)&0x1F],
            ENC[((c4<<1)&0x1E|(d4>>7)&0x01)&0x1F], ENC[(d4>>2)&0x1F], ENC[((d4<<3)&0x18|(e4>>5)&0x07)&0x1F], ENC[e4&0x1F],

            ENC[(a5>>3)&0x1F], ENC[((a5<<2)&0x1C|(b5>>6)&0x03)&0x1F], ENC[(b5>>1)&0x1F], ENC[((b5<<4)&0x10|(c5>>4)&0x0F)&0x1F],
            ENC[((c5<<1)&0x1E|(d5>>7)&0x01)&0x1F], ENC[(d5>>2)&0x1F], ENC[((d5<<3)&0x18|(e5>>5)&0x07)&0x1F], ENC[e5&0x1F],

            ENC[(a6>>3)&0x1F], ENC[((a6<<2)&0x1C|(b6>>6)&0x03)&0x1F], ENC[(b6>>1)&0x1F], ENC[((b6<<4)&0x10|(c6>>4)&0x0F)&0x1F],
            ENC[((c6<<1)&0x1E|(d6>>7)&0x01)&0x1F], ENC[(d6>>2)&0x1F], ENC[((d6<<3)&0x18|(e6>>5)&0x07)&0x1F], ENC[e6&0x1F]
        )
        end

        local out = {}
        local a1, b1, c1, d1, e1, a2, b2, c2, d2, e2
        -- 10 -> 16
        while x + 9 < y do
            a1, b1, c1, d1, e1, a2, b2, c2, d2, e2 = byte(data, x, x + 9)
            out[#out+1] = char(
                ENC[(a1>>3)&0x1F], ENC[((a1<<2)&0x1C|(b1>>6)&0x03)&0x1F], ENC[(b1>>1)&0x1F], ENC[((b1<<4)&0x10|(c1>>4)&0x0F)&0x1F],
                ENC[((c1<<1)&0x1E|(d1>>7)&0x01)&0x1F], ENC[(d1>>2)&0x1F], ENC[((d1<<3)&0x18|(e1>>5)&0x07)&0x1F], ENC[e1&0x1F],

                ENC[(a2>>3)&0x1F], ENC[((a2<<2)&0x1C|(b2>>6)&0x03)&0x1F], ENC[(b2>>1)&0x1F], ENC[((b2<<4)&0x10|(c2>>4)&0x0F)&0x1F],
                ENC[((c2<<1)&0x1E|(d2>>7)&0x01)&0x1F], ENC[(d2>>2)&0x1F], ENC[((d2<<3)&0x18|(e2>>5)&0x07)&0x1F], ENC[e2&0x1F]
            )
            x = x + 10
        end
        -- 5 -> 8
        while x + 4 < y do
            a1, b1, c1, d1, e1 = byte(data, x, x + 4)
            out[#out+1] = char(
                ENC[(a1>>3)&0x1F], ENC[((a1<<2)&0x1C|(b1>>6)&0x03)&0x1F], ENC[(b1>>1)&0x1F], ENC[((b1<<4)&0x10|(c1>>4)&0x0F)&0x1F],
                ENC[((c1<<1)&0x1E|(d1>>7)&0x01)&0x1F], ENC[(d1>>2)&0x1F], ENC[((d1<<3)&0x18|(e1>>5)&0x07)&0x1F], ENC[e1&0x1F]
            )
            x = x + 5
        end
        -- tail: 1..4 -> 2..7 + padding
        local n = y - x
        if n == 4 then
            a1, b1, c1, d1  = byte(data, x, x + 3)
            e1 = 0
            out[#out+1] = char(
                ENC[(a1>>3)&0x1F], ENC[((a1<<2)&0x1C|(b1>>6)&0x03)&0x1F], ENC[(b1>>1)&0x1F], ENC[((b1<<4)&0x10|(c1>>4)&0x0F)&0x1F],
                ENC[((c1<<1)&0x1E|(d1>>7)&0x01)&0x1F], ENC[(d1>>2)&0x1F], ENC[((d1<<3)&0x18|(e1>>5)&0x07)&0x1F], PAD
            )
        elseif n == 3 then
            a1, b1, c1 = byte(data, x, x + 3)
            d1, e1 = 0, 0
            out[#out+1] = char(
                ENC[(a1>>3)&0x1F], ENC[((a1<<2)&0x1C|(b1>>6)&0x03)&0x1F], ENC[(b1>>1)&0x1F], ENC[((b1<<4)&0x10|(c1>>4)&0x0F)&0x1F],
                ENC[((c1<<1)&0x1E|(d1>>7)&0x01)&0x1F], PAD, PAD, PAD
            )
        elseif n == 2 then
            a1, b1 = byte(data, x, x + 1)
            c1, d1, e1 = 0, 0, 0
            out[#out+1] = char(
                ENC[(a1>>3)&0x1F], ENC[((a1<<2)&0x1C|(b1>>6)&0x03)&0x1F], ENC[(b1>>1)&0x1F], ENC[((b1<<4)&0x10|(c1>>4)&0x0F)&0x1F],
                PAD, PAD, PAD, PAD
            )
        elseif n == 1 then
            a1 = byte(data, x)
            b1, c1, d1, e1 = 0, 0, 0, 0
            out[#out+1] = char(
                ENC[(a1>>3)&0x1F], ENC[((a1<<2)&0x1C|(b1>>6)&0x03)&0x1F], PAD, PAD, PAD, PAD, PAD, PAD
            )
        end
        return table.concat(out)
    end

    -- there is no limiting quantifier support in lua pattens ...
    local OPT30 = "()" .. string.rep('.?', 30) .. "()"
    enc = function(data)
        _data = data -- pass data to outer scope
        return (gsub(_data, OPT30, _enc))
    end
end -- do

local dec do
    local DEC = {
        [0x30] = 00, -- '0'
        [0x4F] = 00, -- 'O'
        [0x6F] = 00, -- 'o'

        [0x31] = 01, -- '1'
        [0x49] = 01, -- 'I'
        [0x69] = 01, -- 'i'
        [0x4C] = 01, -- 'L'
        [0x6C] = 01, -- 'l'

        [0x32] = 02, -- '2'
        [0x33] = 03, -- '3'
        [0x34] = 04, -- '4'
        [0x35] = 05, -- '5'
        [0x36] = 06, -- '6'
        [0x37] = 07, -- '7'
        [0x38] = 08, -- '8'
        [0x39] = 09, -- '9'

        [0x41] = 10, -- 'A'
        [0x61] = 10, -- 'a'

        [0x42] = 11, -- 'B'
        [0x62] = 11, -- 'b'

        [0x43] = 12, -- 'C'
        [0x63] = 12, -- 'c'

        [0x44] = 13, -- 'D'
        [0x64] = 13, -- 'd'

        [0x45] = 14, -- 'E'
        [0x65] = 14, -- 'e'

        [0x46] = 15, -- 'F'
        [0x66] = 15, -- 'f'

        [0x47] = 16, -- 'G'
        [0x67] = 16, -- 'g'

        [0x48] = 17, -- 'H'
        [0x68] = 17, -- 'h'

        [0x4A] = 18, -- 'J'
        [0x6A] = 18, -- 'j'

        [0x4B] = 19, -- 'K'
        [0x6B] = 19, -- 'k'

        [0x4D] = 20, -- 'M'
        [0x6D] = 20, -- 'm'

        [0x4E] = 21, -- 'N'
        [0x6E] = 21, -- 'n'

        [0x50] = 22, -- 'P'
        [0x70] = 22, -- 'p'

        [0x51] = 23, -- 'Q'
        [0x71] = 23, -- 'q'

        [0x52] = 24, -- 'R'
        [0x72] = 24, -- 'r'

        [0x53] = 25, -- 'S'
        [0x73] = 25, -- 's'

        [0x54] = 26, -- 'T'
        [0x74] = 26, -- 't'

        [0x56] = 27, -- 'V'
        [0x76] = 27, -- 'v'

        [0x57] = 28, -- 'W'
        [0x77] = 28, -- 'w'

        [0x58] = 29, -- 'X'
        [0x78] = 29, -- 'x'

        [0x59] = 30, -- 'Y'
        [0x79] = 30, -- 'y'

        [0x5A] = 31, -- 'Z'
        [0x7A] = 31, -- 'z'
    }
    -- export
    crockford32.DEC = DEC

    local _b32str = nil
    -- caching lambda, it saves us ~100 bytes
    -- unrolled for 24->15 chars, it gives much less garbage
    local function _dec(x, y)
        local b32str = _b32str
        -- 24 -> 15
        if y - x == 24 and byte(b32str, x + 23) ~= PAD then
            local
                a1, b1, c1, d1, e1, f1, g1, h1,
                a2, b2, c2, d2, e2, f2, g2, h2,
                a3, b3, c3, d3, e3, f3, g3, h3 = byte(b32str, x, x + 23)
                -- decode all
                a1, b1, c1, d1, e1, f1, g1, h1,
                a2, b2, c2, d2, e2, f2, g2, h2,
                a3, b3, c3, d3, e3, f3, g3, h3 =
                    DEC[a1], DEC[b1], DEC[c1], DEC[d1], DEC[e1], DEC[f1], DEC[g1], DEC[h1],
                    DEC[a2], DEC[b2], DEC[c2], DEC[d2], DEC[e2], DEC[f2], DEC[g2], DEC[h2],
                    DEC[a3], DEC[b3], DEC[c3], DEC[d3], DEC[e3], DEC[f3], DEC[g3], DEC[h3]
            return char(
                (a1<<3)&0xF8|(b1>>2)&0x07, (b1<<6)&0xC0|(c1<<1)&0x3E|(d1>>4)&0x01, (d1<<4)&0xf0|(e1>>1)&0x0f,
                (e1<<7)&0x80|(f1<<2)&0x7c|(g1>>3)&0x03, (g1<<5)&0xe0|(h1)&0x1f,

                (a2<<3)&0xF8|(b2>>2)&0x07, (b2<<6)&0xC0|(c2<<1)&0x3E|(d2>>4)&0x01, (d2<<4)&0xf0|(e2>>1)&0x0f,
                (e2<<7)&0x80|(f2<<2)&0x7c|(g2>>3)&0x03, (g2<<5)&0xe0|(h2)&0x1f,

                (a3<<3)&0xF8|(b3>>2)&0x07, (b3<<6)&0xC0|(c3<<1)&0x3E|(d3>>4)&0x01, (d3<<4)&0xf0|(e3>>1)&0x0f,
                (e3<<7)&0x80|(f3<<2)&0x7c|(g3>>3)&0x03, (g3<<5)&0xe0|(h3)&0x1f
            )
        end

        local out = {}
        local a1, b1, c1, d1, e1, f1, g1, h1
        -- 8 -> 5
        while x + 7 < y - 8 do -- all but last 8
            a1, b1, c1, d1, e1, f1, g1, h1 = byte(b32str, x, x + 7)
            a1, b1, c1, d1, e1, f1, g1, h1 = DEC[a1], DEC[b1], DEC[c1], DEC[d1], DEC[e1], DEC[f1], DEC[g1], DEC[h1]
            out[#out+1] = char(
                (a1<<3)&0xF8|(b1>>2)&0x07, (b1<<6)&0xC0|(c1<<1)&0x3E|(d1>>4)&0x01, (d1<<4)&0xf0|(e1>>1)&0x0f,
                (e1<<7)&0x80|(f1<<2)&0x7c|(g1>>3)&0x03, (g1<<5)&0xe0|(h1)&0x1f
            )
            x = x + 8
        end
        -- last 8 -> 1..5
        -- possible padding 1, 3, 4, 6
        a1, b1, c1, d1, e1, f1, g1, h1 = byte(b32str, x, x + 7)
        a1, b1, c1, d1, e1, f1, g1, h1 = DEC[a1], DEC[b1], DEC[c1], DEC[d1], DEC[e1], DEC[f1], DEC[g1], DEC[h1]
        if not a1 or not b1 then
            error("invalid padding")
        elseif not c1 then
            out[#out+1] = char(
                (a1<<3)&0xF8|(b1>>2)&0x07
            )
        elseif not d1 then
            error("invalid padding")
        elseif not e1 then
            out[#out+1] = char((a1<<3)&0xF8|(b1>>2)&0x07, (b1<<6)&0xC0|(c1<<1)&0x3E|(d1>>4)&0x01)
        elseif not f1 then
            out[#out+1] = char(
                (a1<<3)&0xF8|(b1>>2)&0x07, (b1<<6)&0xC0|(c1<<1)&0x3E|(d1>>4)&0x01, (d1<<4)&0xf0|(e1>>1)&0x0f
            )
        elseif not g1 then
            error("invalid padding")
        elseif not h1 then
            out[#out+1] = char(
                (a1<<3)&0xF8|(b1>>2)&0x07, (b1<<6)&0xC0|(c1<<1)&0x3E|(d1>>4)&0x01, (d1<<4)&0xf0|(e1>>1)&0x0f,
                (e1<<7)&0x80|(f1<<2)&0x7c|(g1>>3)&0x03
            )
        else
            out[#out+1] = char(
                (a1<<3)&0xF8|(b1>>2)&0x07, (b1<<6)&0xC0|(c1<<1)&0x3E|(d1>>4)&0x01, (d1<<4)&0xf0|(e1>>1)&0x0f,
                (e1<<7)&0x80|(f1<<2)&0x7c|(g1>>3)&0x03, (g1<<5)&0xe0|(h1)&0x1f
            )
        end
        return table.concat(out)
    end

    local OPT24 = "()" .. string.rep('.?', 24) .. "()"
    dec = function(b32str)
        if #b32str == 0 then return "" end
        -- remove whitespace if any
        if find(b32str, "[-%s]") then b32str = gsub(b32str, "[-%s]+", "") end
        assert(#b32str%8 == 0, "invalid encoding: input length is not divisible by 8")
        _b32str = b32str -- pass to outer scope
        return (gsub(b32str, OPT24, _dec)) -- coerce to 1 result
    end

    ----------------------------------
    -- partial decode utils:
    ----------------------------------
    local function _test(prefix, ...)
        assert(prefix and #prefix <= 5, "max length of prefix should be 5")
        assert(select("#", ...) == 5)
        for i = 1, #prefix do
            if byte(prefix, i) ~= select(i, ...) then return false end
        end
        return true
    end

    -- dec3 :: crockford32 -> byte1, byte2, byte3, byte4, byte5
    local function dec5(s32)
        assert(s32 and #s32 >=8, "length of encoded string should be >= 8")
        local a1, b1, c1, d1, e1, f1, g1, h1 = byte(s32, 1, 8)
        a1, b1, c1, d1, e1, f1, g1, h1 = DEC[a1], DEC[b1], DEC[c1], DEC[d1], DEC[e1], DEC[f1], DEC[g1], DEC[h1]
        return (a1<<3)&0xF8|(b1>>2)&0x07, (b1<<6)&0xC0|(c1<<1)&0x3E|(d1>>4)&0x01, (d1<<4)&0xf0|(e1>>1)&0x0f,
            (e1<<7)&0x80|(f1<<2)&0x7c|(g1>>3)&0x03, (g1<<5)&0xe0|(h1)&0x1f
    end

    local function test_prefix(s32, prefix)
        return _test(prefix, dec5(s32))
    end

    -- select_prefix :: crockford32, prefix1, prefix2, ...  -> index
    local function select_prefix(s32, ...)
        local n = select("#", ...)
        local b1, b2, b3, b4, b5 = dec5(s32)
        for i = 1, n do
            if _test(select(i, ...), b1, b2, b3, b4, b5) then return i end
        end
    end

    -- exports
    crockford32.dec5 = dec5
    crockford32.test_prefix = test_prefix
    crockford32.select_prefix = select_prefix
end -- do

local function _self_test()
    local data = {
        [""] = "",
        ["A"]="84======",
        ["12345"] = "64S36D1N",
        ["BC"]="891G====",
        ["DEF"]="8H2MC===",
        ["*?!@"]="58ZJ2G0=",
        ["Man "]="9NGPW80=",
        ["7904 (base10)"]="6WWK0D1051H62WV564R2J===",
        ["1337lEEt\0\0\0\0"]="64SK6DVC8N2Q80000000====",
        ["Use our super handy online tool to decode or encode your data."] =
            "ANSPA83FENS20WVNE1JQ4838C5Q68Y90DXQ6RTBECMG78VVFDGG78VS0CHJP6VV4CMG6YWH0CNQ66VV4CMG7JVVNE8G68RBMC4Q0====",
        ["<D\254"] = "7H2FW==="
    }

    for r, e in pairs(data) do
        assert(enc(r) == e, string.format("err encode: %q -> %q", r, enc(r)))
        assert(dec(e) == r, string.format("err decode: %q -> %q", r, dec(e)))
    end

    local s32 = enc("12345")
    assert(crockford32.test_prefix(s32, "1"))
    assert(crockford32.test_prefix(s32, "12"))
    assert(crockford32.test_prefix(s32, "123"))
    assert(crockford32.test_prefix(s32, "1234"))
    assert(crockford32.test_prefix(s32, "12345"))
    assert(crockford32.select_prefix(s32, "AA", "BB", "123", "85") == 3)

    --TODO: test some substitutuions, lower, IL1i etc.

    -- test bugfix (dec returned 2 value)
    local id = "eec0239c0d644f5bb9f59779307edb17"
    local fmt = "c1 z c3"
    local x = string.pack(fmt, "$", id, "C09")
    assert(select(2, string.unpack(fmt, x)) == id)
    assert(select(2, string.unpack(fmt, dec(enc(x)))) == id)
    --
    print('crockford32 -- ok')
end

_self_test()

-- exports
crockford32.encode = enc
crockford32.decode = dec

return crockford32