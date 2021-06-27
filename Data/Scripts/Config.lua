--[[
    A very simple module for handling read-only key-value configuration files.
]]

local Config = {}
Config.__index = Config

function Config.__newindex()
    return error("configs are read-only", 2)
end

function Config.New(defaults)
    defaults = defaults or {}
    return setmetatable(defaults, Config)
end

-- override
function Config:__call(values)
    values = values or {}
    -- shallow copy
    for k, v in pairs(self) do
        if values[k] == nil then
            values[k] = v
        end
    end
    return setmetatable(values, Config)
end

function Config:__tostring()
    local out = {}
    for k, v in pairs(self) do
        out[#out + 1] = string.format("  %s = %s,", k, v)
    end
    table.sort(out)
    out[#out + 1] = "}"
    return "{\n".. table.concat(out, "\n")
end

return Config