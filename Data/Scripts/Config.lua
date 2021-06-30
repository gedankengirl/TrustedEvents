--[[
    A very simple module for handling read-only key-value configuration files.

    * To create config:
    ```
    local config = Config { KEY=value, ... }
    ```
    * To override some values:
    ```
    local overrided = config { KEY=override, ... }
    ```
]]

local Config = {type = "Config"}
Config.__index = Config

function Config.__newindex()
    return error("configs are read-only", 2)
end

function Config.New(defaults)
    defaults = defaults or {}
    return setmetatable(defaults, Config)
end

-- override
function Config:__call(overrides)
    overrides = overrides or {}
    -- NOTE: we don't mess with metatables, shallow copy FTW
    for k, v in pairs(self) do
        if overrides[k] == nil then
            overrides[k] = v
        end
    end
    return setmetatable(overrides, Config)
end

-- dump
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