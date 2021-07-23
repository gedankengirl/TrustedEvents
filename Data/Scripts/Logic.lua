_ENV .require = _G.import or require
local xoshiro256 = require("Xoshiro256")
local random = xoshiro256.random
local log, floor = math.log, math.floor

local Logic = {}
Logic.__index = Logic

local _tiers = {"K", "M", "B", "T", "Q"}
local function formatNumber(n, max_unformatted)
    max_unformatted = max_unformatted or 100000
    n = math.tointeger(n) or n//1
    if n < max_unformatted then return tostring(n) end
    local tier = log(n, 10)//3
    n = n / 10^(3*tier)
    return string.format("%.4g%s", n, _tiers[tier])
end

-- pythonic uniform
local function uniform(a, b)
    assert(a < b, "empty interval")
    return a + (b-a)*random()
end


-- weightedChoice :: {[key, weight]} -> key
local function weightedChoice(t)
    local sum = 0
    for _, w in pairs(t) do sum = sum + w end
    local rnd = uniform(0, sum)
    for k, w in pairs(t) do
        rnd = rnd - w
        if rnd < 0 then return k end
    end
end

local function roundToSignificantDigits(d, digits, trancate)
    assert(d >= 0)
    digits = digits or 3
    if d == 0 then return 0 end
    local k = floor(log(d, 10))
    local scale = 10^(k - digits + 1)
    return scale * floor(d/scale + (trancate and 0 or 0.5))
end

local function geomNth(a, f, n, digits)
    return roundToSignificantDigits(a*f^n, digits)
end

local function calculateAfforadableAmount(initial, exp, owned, cash)
    return log(1 - cash * (1 - exp) / (initial * exp^owned)) / log(exp)
end

-- exports
Logic.uniform = uniform
Logic.formatNumber = formatNumber
Logic.weightedChoice = weightedChoice
Logic.roundToSignificantDigits = roundToSignificantDigits
Logic.geomNth = geomNth
Logic.calculateAfforadableAmount = calculateAfforadableAmount

return Logic