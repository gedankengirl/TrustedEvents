-- Copyright (C) 1994-2020 Lua.org, PUC-Rio.
-- Copyright (C) 2021 by Andrew Zhilin <andrew.zhilin@gmail.com>
-- Distributed under MIT license.
--[===========================================================================[
    `xoshiro256` is a pure Lua 5.3 implementation of xoshiro256**, all-purpose,
    rock-solid random generator, that is fully compatible with Lua 5.4 API and
    implementation of `math.random` and `math.randomseed`. It has a reasonable
    performance and passes all random-related tests from Lua 5.4 test suite.

    * xoshiro256.random([m[, n]])
    When called without arguments, returns a pseudo-random float with uniform
    distribution in the range [0,1). When called with two integers m and n,
    xoshiro256.random returns a pseudo-random integer with uniform
    distribution in the range [m, n]. The call xoshiro256.random(n),
    for a positive n, is equivalent to xoshiro256.random(1,n). The call
    math.random(0) produces an integer with all bits (pseudo)random.
    This function uses the xoshiro256** algorithm to produce pseudo-random
    64-bit integers, which are the results of calls with argument 0. Other
    results (ranges and floats) are unbiased extracted from these integers.

    * xoshiro256.randomseed([x[, y]])
    When called with at least one argument, the integer parameters x and y
    are joined into a 128-bit seed that is used to reinitialize the
    pseudo-random generator; equal seeds produce equal sequences of numbers.
    The default for y is zero.
    When called with no arguments, generates a seed with a weak attempt for
    randomness.
    This function returns the two seed components that were effectively used,
    so that setting them again repeats the sequence.
    To ensure a required level of randomness to the initial state (or
    contrarily, to have a deterministic sequence, for instance when debugging
    a program), you should call xoshiro256.randomseed with explicit
    arguments.
--]===========================================================================]
assert(_VERSION:find("Lua 5.3"))
local xoshiro256 = {}
do
    local select, ult = select, math.ult
    local DBL_CONV_MULT = 1/2^53 -- reference: http://prng.di.unimi.it/
    local s0, s1, s2, s3 = 0x00, 0x00, 0x00, 0x00
    local function next_rand()
        local x, k = s1*5, 7
        local result = (x << k | x >> (64 - k))*9
        local t = s1 << 17
        s2 = s2 ~ s0
        s3 = s3 ~ s1
        s1 = s1 ~ s2
        s0 = s0 ~ s3
        s2 = s2 ~ t
        x, k = s3, 45
        s3 = x << k | x >> (64 - k)
        return result
    end

    local function randomseed(n1, n2)
        n1 = n1 or os.time()
        n2 = n2 or 0
        s0, s1, s2, s3 = n1, 0xFF --[[to avoid a zero state]], n2, 0x00
        for _=1, 16 do
            next_rand() -- discard initial values to "spread" seed
        end
        return n1, n2
    end

    randomseed() -- initial seeding

    -- Project the random integer 'ran' into the interval [0, n].
    -- Because 'ran' has 2^B possible values, the projection can only be
    -- uniform when the size of the interval is a power of 2 (exact
    -- division). Otherwise, to get a uniform projection into [0, n], we
    -- first compute 'lim', the smallest Mersenne number not smaller than
    -- 'n'. We then project 'ran' into the interval [0, lim].  If the result
    -- is inside [0, n], we are done. Otherwise, we try with another 'ran',
    -- until we have a result inside the interval.
    local function project(ran, n)
        if n & (n + 1) == 0 then -- is 'n + 1' a power of 2?
            return ran & n -- no bias
        else
            -- compute the smallest (2^b - 1) not smaller than 'n'
            local lim = n
            lim = lim | lim >> 1
            lim = lim | lim >> 2
            lim = lim | lim >> 4
            lim = lim | lim >> 8
            lim = lim | lim >> 16
            lim = lim | lim >> 32
            -- commented out for performance:
            -- assert(lim & (lim + 1) == 0)
            -- assert(lim >= n)
            -- assert(ult(lim >> 1, n))
            while true do
                ran = ran & lim -- project 'ran' into [0..lim]
                if ult(n, ran) then -- not inside [0..n]? try again
                    ran = next_rand()
                else
                    break
                end
            end
            return ran
        end
    end

    local function random(low, up, ...)
        assert(select("#", ...) == 0, "too many arguments")
        local rv = next_rand()
        local nargs = (low and up and 2) or (low and not up and 1) or 0
        if nargs == 0 then
            return (rv >> 11) * DBL_CONV_MULT -- converts uint64 to double at [0, 1)
        elseif nargs == 1 then
            up, low = low, 1 -- only upper limit
            if up == 0 then return rv end
        end
        -- project rv into the interval [low, up]
        assert(low <= up, "interval is empty")
        local p = project(rv, up - low)
        return p + low
     end
    -- exports
    xoshiro256.random = random
    xoshiro256.randomseed = randomseed
end

-------------------------------------------------------------------------------
local function _test()
    print("xoshiro256 -- testing ...")
    local random, max, min = xoshiro256.random, math.max, math.min

    -- All below is a snippets from lua-5.4.2-tests/math.lua

    local minint = math.mininteger
    local maxint = math.maxinteger
    local intbits = math.floor(math.log(maxint, 2) + 0.5) + 1
    assert((1 << intbits) == 0)

    assert(minint == 1 << (intbits - 1))
    assert(maxint == minint - 1)

    -- number of bits in the mantissa of a floating-point number
    local floatbits = 24
    do
        local p = 2.0^floatbits
        while p < p + 1.0 do
            p = p * 2.0
            floatbits = floatbits + 1
        end
    end

    -- NOTE: we cut some corners assuming standard lua 5.3 64-bit runtime and IEEE 754 64-bit doubles
    assert(floatbits == 53)
    assert(intbits == 64)

    local function isNaN (x)
        return (x ~= x)
    end

    assert(isNaN(0/0))
    assert(not isNaN(1/0))

    do
        local x = 2.0^floatbits
        assert(x > x - 1.0 and x == x + 1.0)
        print(string.format("* %d-bit integers, %d-bit (mantissa) floats",
                             intbits, floatbits))
    end
    assert(math.type(0) == "integer" and math.type(0.0) == "float"
        and not math.type("10"))


    -- float equality
    local function eq(a,b,limit)
        if not limit then
            if floatbits >= 50 then limit = 1E-11
            else limit = 1E-5
            end
        end
        -- a == b needed for +inf/-inf
        return a == b or math.abs(a-b) <= limit
    end

    local function testnear (val, ref, tol)
        return (math.abs(val - ref) < ref * tol)
    end

    -- low-level!! For the current implementation of random in Lua,
    -- the first call after seed 1007 should return 0x7a7040a5a323c9d6

    -- all computations should work with 32-bit integers
    do
        local h = 0x7a7040a5   -- higher half
        local l = 0xa323c9d6   -- lower half
        xoshiro256.randomseed(1007)
        -- get the low 'intbits' of the 64-bit expected result
        local res = (h << 32 | l) & ~(~0 << intbits)
        assert(random(0) == res)
        xoshiro256.randomseed(1007, 0)
        -- using higher bits to generate random floats; (the '% 2^32' converts
        -- 32-bit integers to floats as unsigned)
        local res
        if floatbits <= 32 then
            -- get all bits from the higher half
            res = (h >> (32 - floatbits)) % 2^32
        else
            -- get 32 bits from the higher half and the rest from the lower half
            res = (h % 2^32) * 2^(floatbits - 32) + ((l >> (64 - floatbits)) % 2^32)
        end
        local rand = random()
        assert(eq(rand, tonumber'0x0.7a7040a5a323c9d6', 2^-floatbits))
        assert(rand * 2^floatbits == res)
    end

    do
        -- testing return of 'randomseed'
        local x, y = xoshiro256.randomseed()
        local res = xoshiro256.random(0)
        x, y = xoshiro256.randomseed(x, y)    -- should repeat the state
        assert(xoshiro256.random(0) == res)
        xoshiro256.randomseed(x, y)    -- again should repeat the state
        assert(xoshiro256.random(0) == res)
        -- keep the random seed for following tests
    end

    do   -- test random for floats
        local randbits = math.min(floatbits, 64)   -- at most 64 random bits
        local mult = 2^randbits      -- to make random float into an integral
        local counts = {}    -- counts for bits
        for i = 1, randbits do counts[i] = 0 end
        local up = -math.huge
        local low = math.huge
        local rounds = 100 * randbits   -- 100 times for each bit
        local totalrounds = 0
        ::doagain::   -- will repeat test until we get good statistics
        for i = 0, rounds do
            local t = random()
            assert(0 <= t and t < 1)
            up = max(up, t)
            low = min(low, t)
            assert(t * mult % 1 == 0)    -- no extra bits
            local bit = i % randbits     -- bit to be tested
            if (t * 2^bit) % 1 >= 0.5 then    -- is bit set?
                counts[bit + 1] = counts[bit + 1] + 1   -- increment its count
            end
        end
        totalrounds = totalrounds + rounds
        if not (eq(up, 1, 0.001) and eq(low, 0, 0.001)) then
            goto doagain
        end
        -- all bit counts should be near 50%
        local expected = (totalrounds / randbits / 2)
        for i = 1, randbits do
            if not testnear(counts[i], expected, 0.10) then
                goto doagain
            end
        end
        print(string.format("float random range in %d calls: [%f, %f]",
                            totalrounds, low, up))
    end

    do   -- test random for full integers
        local up = 0
        local low = 0
        local counts = {}    -- counts for bits
        for i = 1, intbits do counts[i] = 0 end
        local rounds = 100 * intbits   -- 100 times for each bit
        local totalrounds = 0
        ::doagain::   -- will repeat test until we get good statistics
        for i = 0, rounds do
            local t = random(0)
            up = max(up, t)
            low = min(low, t)
            local bit = i % intbits     -- bit to be tested
            -- increment its count if it is set
            counts[bit + 1] = counts[bit + 1] + ((t >> bit) & 1)
        end
        totalrounds = totalrounds + rounds
        local lim = maxint >> 10
        if not (maxint - up < lim and low - minint < lim) then
            goto doagain
        end
        -- all bit counts should be near 50%
        local expected = (totalrounds / intbits / 2)
        for i = 1, intbits do
            if not testnear(counts[i], expected, 0.10) then
                goto doagain
            end
        end
        print(string.format(
           "integer random range in %d calls: [minint + %.0fppm, maxint - %.0fppm]",
            totalrounds, (minint - low) / minint * 1e6,
                         (maxint - up) / maxint * 1e6))
    end

    do
        -- test distribution for a dice
        local count = {0, 0, 0, 0, 0, 0}
        local rep = 200
        local totalrep = 0
        ::doagain::
        for i = 1, rep * 6 do
            local r = random(6)
            count[r] = count[r] + 1
        end
        totalrep = totalrep + rep
        for i = 1, 6 do
            if not testnear(count[i], totalrep, 0.05) then
                goto doagain
            end
        end
    end

    do
        local function aux (x1, x2)     -- test random for small intervals
        local mark = {}; local count = 0   -- to check that all values appeared
        while true do
            local t = random(x1, x2)
            assert(x1 <= t and t <= x2)
            if not mark[t] then  -- new value
                mark[t] = true
                count = count + 1
                if count == x2 - x1 + 1 then   -- all values appeared; OK
                    goto ok
                end
            end
        end
        ::ok::
        end

        aux(-10,0)
        aux(1, 6)
        aux(1, 2)
        aux(1, 13)
        aux(1, 31)
        aux(1, 32)
        aux(1, 33)
        aux(-10, 10)
        aux(-10,-10)   -- unit set
        aux(minint, minint)   -- unit set
        aux(maxint, maxint)   -- unit set
        aux(minint, minint + 9)
        aux(maxint - 3, maxint)
    end

    do
        local function aux(p1, p2)       -- test random for large intervals
            local max = minint
            local min = maxint
            local n = 100
            local mark = {}; local count = 0   -- to count how many different values
            ::doagain::
        for _ = 1, n do
            local t = random(p1, p2)
            if not mark[t] then  -- new value
                assert(p1 <= t and t <= p2)
                max = math.max(max, t)
                min = math.min(min, t)
                mark[t] = true
                count = count + 1
            end
        end
            -- at least 80% of values are different
            if not (count >= n * 0.8) then
            goto doagain
            end
            -- min and max not too far from formal min and max
            local diff = (p2 - p1) >> 4
            if not (min < p1 + diff and max > p2 - diff) then
            goto doagain
            end
        end
        aux(0, maxint)
        aux(1, maxint)
        aux(3, maxint // 3)
        aux(minint, -1)
        aux(minint // 2, maxint // 2)
        aux(minint, maxint)
        aux(minint + 1, maxint)
        -- aux(minint, maxint - 1)
        aux(0, 1 << (intbits - 5))
    end

    assert(not pcall(random, 1, 2, 3))    -- too many arguments
    -- empty interval
    assert(not pcall(random, minint + 1, minint))
    assert(not pcall(random, maxint, maxint - 1))
    assert(not pcall(random, maxint, minint))

    print("xoshiro256 -- ok")
end


local CORE_ENV = CoreString and CoreMath

local function _test_perf()

    -- PERF: 1000000   math.random ints        time: 0.1780s mem: 0.00K
    -- PERF: 1000000   xoshiro256.lua ints     time: 1.3688s mem: 1.02K
    -- PERF: 1000000   math.random double      time: 0.1410s mem: 0.00K
    -- PERF: 1000000   xoshiro256.lua double   time: 0.6312s mem: 0.95K

    --[==[
        local clock do
            if not CORE_ENV then
                local ok, socket = pcall(require, "socket")
                clock = ok and socket.gettime or os.clock
            else
                clock = os.clock
            end
        end
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

        local N = CORE_ENV and 1000 or 1000000
        perfn("math.random ints", N, function()
            math.random(12345, 1234567890)
        end)
        perfn("xoshiro256.lua ints", N, function()
            xoshiro256.random(123451, 1234567890)
        end)
        perfn("math.random double", N, function()
            math.random()
        end)
        perfn("xoshiro256.lua double", N, function()
            xoshiro256.random()
        end)
    --]==]
end

if not CORE_ENV then -- Core has too low instruction limit
    _test()
end
-- _test_perf()

return xoshiro256
