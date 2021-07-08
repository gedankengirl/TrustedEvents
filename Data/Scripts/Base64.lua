--[[
    Fast, memory conservative, pure Lua 5.3+ Base64 encoder/decoder.
]]

-- The MIT Licence (MIT)
-- Copyright (c) 2021 Andrew Zhilin (https://github.com/zoon)

local base64= {}

-- Base64 alphabet: 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local char, byte, gsub, find = string.char, string.byte, string.gsub, string.find
local pack, unpack, rep = string.pack, string.unpack, string.rep
local concat, format = table.concat, string.format
local type, assert, print, pairs, select = type, assert, print, pairs, select

_ENV = nil

local PAD = byte('=')

---------------------------------------
-- Base64 encode
---------------------------------------
-- @ encode :: str -> str(base64)
local encode do
    local ENC = {[0]=
        0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50,
        0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5A, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
        0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E,
        0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76,
        0x77, 0x78, 0x79, 0x7A, 0x30, 0x31, 0x32, 0x33,
        0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x2B, 0x2F,
    }
    -- pass data string to _enc
    local _data = nil
    -- caching lambda, it saves us ~100 bytes
    -- unrolled for 36->48 chars, a little faster and gives 3-4x less garbage
    local function _enc(x, y)
        local data = _data -- pass data string to inner scope
        -- 36 -> 48
        if y - x == 36 then
            local
                a1, b1, c1, a2, b2, c2, a3, b3, c3,
                a4, b4, c4, a5, b5, c5, a6, b6, c6,
                a7, b7, c7, a8, b8, c8, a9, b9, c9,
                aa, ba, ca, ab, bb, cb, ac, bc, cc = byte(data, x, x + 35)
        return char(
            ENC[a1>>2], ENC[(a1&3)<<4|b1>>4], ENC[(b1&15)<<2|c1>>6], ENC[c1&63],
            ENC[a2>>2], ENC[(a2&3)<<4|b2>>4], ENC[(b2&15)<<2|c2>>6], ENC[c2&63],
            ENC[a3>>2], ENC[(a3&3)<<4|b3>>4], ENC[(b3&15)<<2|c3>>6], ENC[c3&63],
            ENC[a4>>2], ENC[(a4&3)<<4|b4>>4], ENC[(b4&15)<<2|c4>>6], ENC[c4&63],
            ENC[a5>>2], ENC[(a5&3)<<4|b5>>4], ENC[(b5&15)<<2|c5>>6], ENC[c5&63],
            ENC[a6>>2], ENC[(a6&3)<<4|b6>>4], ENC[(b6&15)<<2|c6>>6], ENC[c6&63],
            ENC[a7>>2], ENC[(a7&3)<<4|b7>>4], ENC[(b7&15)<<2|c7>>6], ENC[c7&63],
            ENC[a8>>2], ENC[(a8&3)<<4|b8>>4], ENC[(b8&15)<<2|c8>>6], ENC[c8&63],
            ENC[a9>>2], ENC[(a9&3)<<4|b9>>4], ENC[(b9&15)<<2|c9>>6], ENC[c9&63],
            ENC[aa>>2], ENC[(aa&3)<<4|ba>>4], ENC[(ba&15)<<2|ca>>6], ENC[ca&63],
            ENC[ab>>2], ENC[(ab&3)<<4|bb>>4], ENC[(bb&15)<<2|cb>>6], ENC[cb&63],
            ENC[ac>>2], ENC[(ac&3)<<4|bc>>4], ENC[(bc&15)<<2|cc>>6], ENC[cc&63]
        )
        end

        local out = {}
        local a1, b1, c1, a2, b2, c2, a3, b3, c3
        -- 9 -> 12
        while x + 8 < y do
            a1, b1, c1, a2, b2, c2, a3, b3, c3 = byte(data, x, x + 8)
            out[#out+1] = char(
                ENC[a1>>2], ENC[(a1&3)<<4|b1>>4], ENC[(b1&15)<<2|c1>>6], ENC[c1&63],
                ENC[a2>>2], ENC[(a2&3)<<4|b2>>4], ENC[(b2&15)<<2|c2>>6], ENC[c2&63],
                ENC[a3>>2], ENC[(a3&3)<<4|b3>>4], ENC[(b3&15)<<2|c3>>6], ENC[c3&63]
            )
            x = x + 9
        end
        -- 3 -> 4
        while x + 2 < y do
            a1, b1, c1 = byte(data, x, x + 2)
            out[#out+1] = char(ENC[a1>>2], ENC[(a1&3)<<4|b1>>4], ENC[(b1&15)<<2|c1>>6], ENC[c1&63])
            x = x + 3
        end
        -- tail: 1..2 -> 2..3 + padding
        local n = y - x
        if n == 2 then
            a1, b1 = byte(data, x, x + 1)
            c1 = 0
            out[#out+1] = char(ENC[a1>>2], ENC[(a1&3)<<4|b1>>4], ENC[(b1&15)<<2|c1>>6], PAD)
        elseif n == 1 then
            a1 = byte(data, x)
            b1 = 0
            out[#out+1] = char(ENC[a1>>2], ENC[(a1&3)<<4|b1>>4], PAD, PAD)
        end
        return concat(out)
    end

    -- there is no limiting quantifier support in lua patterns ...
    local OPT36 = "()" .. rep('.?', 36) .. "()"
    encode = function(data)
        _data = data -- pass data to outer scope
        return (gsub(_data, OPT36, _enc)) -- coerce to one result
    end
end

---------------------------------------
-- Base64 decode
---------------------------------------
-- @ decode :: str(base64) -> str
local decode do
    local DEC = {
        [0x41]=0x00, [0x42]=0x01, [0x43]=0x02, [0x44]=0x03, [0x45]=0x04, [0x46]=0x05, [0x47]=0x06, [0x48]=0x07,
        [0x49]=0x08, [0x4A]=0x09, [0x4B]=0x0A, [0x4C]=0x0B, [0x4D]=0x0C, [0x4E]=0x0D, [0x4F]=0x0E, [0x50]=0x0F,
        [0x51]=0x10, [0x52]=0x11, [0x53]=0x12, [0x54]=0x13, [0x55]=0x14, [0x56]=0x15, [0x57]=0x16, [0x58]=0x17,
        [0x59]=0x18, [0x5A]=0x19, [0x61]=0x1A, [0x62]=0x1B, [0x63]=0x1C, [0x64]=0x1D, [0x65]=0x1E, [0x66]=0x1F,
        [0x67]=0x20, [0x68]=0x21, [0x69]=0x22, [0x6A]=0x23, [0x6B]=0x24, [0x6C]=0x25, [0x6D]=0x26, [0x6E]=0x27,
        [0x6F]=0x28, [0x70]=0x29, [0x71]=0x2A, [0x72]=0x2B, [0x73]=0x2C, [0x74]=0x2D, [0x75]=0x2E, [0x76]=0x2F,
        [0x77]=0x30, [0x78]=0x31, [0x79]=0x32, [0x7A]=0x33, [0x30]=0x34, [0x31]=0x35, [0x32]=0x36, [0x33]=0x37,
        [0x34]=0x38, [0x35]=0x39, [0x36]=0x3A, [0x37]=0x3B, [0x38]=0x3C, [0x39]=0x3D, [0x2B]=0x3E, [0x2F]=0x3F,
    }

    local _str64 = nil
    -- caching lambda, it saves us ~100 bytes
    -- unrolled for 48->36 chars, a little faster and gives 3-4x less garbage
    local function _dec(x, y)
        local b64str = _str64
        -- 48 -> 36
        if y - x == 48 and byte(b64str, x + 47) ~= PAD then
            local
                a1, b1, c1, d1, a2, b2, c2, d2, a3, b3, c3, d3,
                a4, b4, c4, d4, a5, b5, c5, d5, a6, b6, c6, d6,
                a7, b7, c7, d7, a8, b8, c8, d8, a9, b9, c9, d9,
                aa, ba, ca, da, ab, bb, cb, db, ac, bc, cc, dc =
                    byte(b64str, x, x + 47)
                -- decode all
                a1, b1, c1, d1, a2, b2, c2, d2, a3, b3, c3, d3,
                a4, b4, c4, d4, a5, b5, c5, d5, a6, b6, c6, d6,
                a7, b7, c7, d7, a8, b8, c8, d8, a9, b9, c9, d9,
                aa, ba, ca, da, ab, bb, cb, db, ac, bc, cc, dc =
                    DEC[a1], DEC[b1], DEC[c1], DEC[d1], DEC[a2], DEC[b2], DEC[c2], DEC[d2],
                    DEC[a3], DEC[b3], DEC[c3], DEC[d3], DEC[a4], DEC[b4], DEC[c4], DEC[d4],
                    DEC[a5], DEC[b5], DEC[c5], DEC[d5], DEC[a6], DEC[b6], DEC[c6], DEC[d6],
                    DEC[a7], DEC[b7], DEC[c7], DEC[d7], DEC[a8], DEC[b8], DEC[c8], DEC[d8],
                    DEC[a9], DEC[b9], DEC[c9], DEC[d9], DEC[aa], DEC[ba], DEC[ca], DEC[da],
                    DEC[ab], DEC[bb], DEC[cb], DEC[db], DEC[ac], DEC[bc], DEC[cc], DEC[dc]
            return char(
                a1<<2&0xFC|b1>>4&0x03, b1<<4&0xF0|c1>>2&0x0F, c1<<6&0xC0|d1>>0&0x3F,
                a2<<2&0xFC|b2>>4&0x03, b2<<4&0xF0|c2>>2&0x0F, c2<<6&0xC0|d2>>0&0x3F,
                a3<<2&0xFC|b3>>4&0x03, b3<<4&0xF0|c3>>2&0x0F, c3<<6&0xC0|d3>>0&0x3F,
                a4<<2&0xFC|b4>>4&0x03, b4<<4&0xF0|c4>>2&0x0F, c4<<6&0xC0|d4>>0&0x3F,
                a5<<2&0xFC|b5>>4&0x03, b5<<4&0xF0|c5>>2&0x0F, c5<<6&0xC0|d5>>0&0x3F,
                a6<<2&0xFC|b6>>4&0x03, b6<<4&0xF0|c6>>2&0x0F, c6<<6&0xC0|d6>>0&0x3F,
                a7<<2&0xFC|b7>>4&0x03, b7<<4&0xF0|c7>>2&0x0F, c7<<6&0xC0|d7>>0&0x3F,
                a8<<2&0xFC|b8>>4&0x03, b8<<4&0xF0|c8>>2&0x0F, c8<<6&0xC0|d8>>0&0x3F,
                a9<<2&0xFC|b9>>4&0x03, b9<<4&0xF0|c9>>2&0x0F, c9<<6&0xC0|d9>>0&0x3F,
                aa<<2&0xFC|ba>>4&0x03, ba<<4&0xF0|ca>>2&0x0F, ca<<6&0xC0|da>>0&0x3F,
                ab<<2&0xFC|bb>>4&0x03, bb<<4&0xF0|cb>>2&0x0F, cb<<6&0xC0|db>>0&0x3F,
                ac<<2&0xFC|bc>>4&0x03, bc<<4&0xF0|cc>>2&0x0F, cc<<6&0xC0|dc>>0&0x3F
            )
        end

        local out = {}
        local a1, b1, c1, d1, a2, b2, c2, d2, a3, b3, c3, d3
        -- 12 -> 9
        while x + 11 < y - 4 do -- all but last 4
            a1, b1, c1, d1, a2, b2, c2, d2, a3, b3, c3, d3 = byte(b64str, x, x + 11)
            a1, b1, c1, d1, a2, b2, c2, d2, a3, b3, c3, d3 =
                DEC[a1], DEC[b1], DEC[c1], DEC[d1], DEC[a2], DEC[b2],
                DEC[c2], DEC[d2], DEC[a3], DEC[b3], DEC[c3], DEC[d3]
            out[#out+1] = char(
                a1<<2&0xFC|b1>>4&0x03, b1<<4&0xF0|c1>>2&0x0F, c1<<6&0xC0|d1>>0&0x3F,
                a2<<2&0xFC|b2>>4&0x03, b2<<4&0xF0|c2>>2&0x0F, c2<<6&0xC0|d2>>0&0x3F,
                a3<<2&0xFC|b3>>4&0x03, b3<<4&0xF0|c3>>2&0x0F, c3<<6&0xC0|d3>>0&0x3F
            )
            x = x + 12
        end
        -- 4 -> 3
        while x + 3 < y - 4 do -- all but last 4
            a1, b1, c1, d1 = byte(b64str, x, x + 3)
            a1, b1, c1, d1 = DEC[a1], DEC[b1], DEC[c1], DEC[d1]
            out[#out+1] = char(a1<<2&0xFC|b1>>4&0x03, b1<<4&0xF0|c1>>2&0x0F, c1<<6&0xC0|d1>>0&0x3F)
            x = x + 4
        end
        -- last 4 -> 1..3
        a1, b1, c1, d1 = byte(b64str, x, x + 3)
        a1, b1, c1, d1 = DEC[a1], DEC[b1], DEC[c1], DEC[d1]
        local n = c1 and d1 and 3 or c1 and 2 or 1
        if n == 3 then
            out[#out+1] = char(a1<<2&0xFC|b1>>4&0x03, b1<<4&0xF0|c1>>2&0x0F, c1<<6&0xC0|d1>>0&0x3F)
        elseif n == 2 then
            out[#out+1] = char(a1<<2&0xFC|b1>>4&0x03, b1<<4&0xF0|c1>>2&0x0F)
        elseif n == 1 then
            out[#out+1] = char(a1<<2&0xFC|b1>>4&0x03)
        end
        return concat(out)
    end

    local OPT48 = "()" .. rep('.?', 48) .. "()"
    decode = function (str64)
        assert(type(str64) == "string", "string expected")
        if #str64 == 0 then return "" end
        -- remove whitespace if any (`find` then `gsub` much faster, if there is no whitespace)
        if find(str64, "%s+") then str64 = gsub(str64, "%s+", "") end
        assert(#str64%4 == 0, "invalid encoding: input length is not divisible by 4")
        _str64 = str64 -- pass encoded string to outer scope
        return (gsub(str64, OPT48, _dec)) -- coerce to one result
    end

    ----------------------------------
    -- partial decode utils:
    ----------------------------------
    local function _test(prefix, ...)
        assert(prefix and #prefix <= 3, "length of prefix should be 1..3")
        assert(select("#", ...) == 3)
        for i = 1, #prefix do
            if byte(prefix, i) ~= select(i, ...) then return false end
        end
        return true
    end

    -- @ dec3 :: str(base64) -> byte1, byte2, byte3
    local function dec3(str64)
        assert(str64 and #str64 >= 4, "length of encoded string should be >= 4")
        local a1, b1, c1, d1 = byte(str64, 1, 4)
        a1, b1, c1, d1 = DEC[a1], DEC[b1], DEC[c1], DEC[d1]
        return a1<<2&0xFC|b1>>4&0x03, b1<<4&0xF0|c1>>2&0x0F, c1<<6&0xC0|d1>>0&0x3F
    end

    -- @ test_prefix :: str(base64), str -> bool
    -- prefix :: str with length [1..3]
    local function test_prefix(str64, prefix)
        return _test(prefix, dec3(str64))
    end

    -- @ select_prefix :: str(base64), prefix1:str, prefix2:str, ...  -> index
    -- prefix :: str with length [1..3]
    local function select_prefix(str64, ...)
        local n = select("#", ...)
        local b1, b2, b3 = dec3(str64)
        for i = 1, n do
            if _test(select(i, ...), b1, b2, b3) then return i end
        end
    end

    -- exports
    base64.dec3 = dec3
    base64.test_prefix = test_prefix
    base64.select_prefix = select_prefix
end

local function _self_test()
    local data = {
        [""] = "",
        ["A"]="QQ==",
        ["BC"]="QkM=",
        ["DEF"]="REVG",
        ["*?!@"]="Kj8hQA==",
        ["Man "]="TWFuIA==",
        ["7904 (base10)"]="NzkwNCAoYmFzZTEwKQ==",
        ["1337lEEt\0\0\0\0"]="MTMzN2xFRXQAAAAA",
        ["Use our super handy online tool to decode or encode your data."] =
            "VXNlIG91ciBzdXBlciBoYW5keSBvbmxpbmUgdG9vbCB0byBkZWNvZGUgb3IgZW5jb2RlIHlvdXIgZGF0YS4=",
        ["<D\254"] = "PET+"
    }
    for r, e in pairs(data) do
        assert(encode(r) == e, format("err encode: %q -> %q", r, encode(r)))
        assert(decode(e) == r, format("err decode: %q -> %q", r, decode(e)))
    end

    local str64 = encode("7904 (base10)")
    assert(base64.test_prefix(str64, "7"))
    assert(base64.test_prefix(str64, "79"))
    assert(base64.test_prefix(str64, "790"))
    assert(base64.select_prefix(str64, "A", "BB", "790", "CCC") == 3)

    assert(base64.test_prefix("REVG", "DEF"))

    -- bugfix (dec returns 2 values)
    local id = "eec0239c0d644f5bb9f59779307edb17"
    local fmt = "c1 z c3"
    local x = pack(fmt, "$", id, "C09")
    assert(select(2, unpack(fmt, x)) == id)
    assert(select(2, unpack(fmt, decode(encode(x)))) == id)

    --
    print('base64 -- ok')
end

_self_test()

-- module exports
base64.encode = encode
base64.decode = decode

return base64