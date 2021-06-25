--[[
    _G.export: replacing Core `require` which can take the filename or MUID as an argument.
    This is convenient since you no longer need to do custom properties or hardcode
    MUID strings to export a module.

    If you make `require` an alias of `_G.export` and export modules by name,
    then they will continue to function correctly in the absence of Core - for example,
    you can run tests in vanilla Lua 5.3, and not just in the editor.
    ```lua
    -- begining of the script
    _ENV.require = _G.export or require
    ```
    TODO: FAQ
    - How to make "Module Container" by yourself.
    - How to prohibit an export of server-only modules in client context.
    - Where to place module containers in hierarchy.
    - Can I store templates in Module container and get them by name.
]]

local EXPORT_DEPRECATED = false

-- This script must always be a child of the root container (in default or server context).
-- For client context you should create client context follder as a child of module container,
-- and add this script as a child to that folder.
local CONTAINER = Environment.IsClient() and script.parent.parent or script.parent

local MODULES_G_KEY = "<~ Modules ~>"
_G[MODULES_G_KEY] = _G[MODULES_G_KEY] or {}
local modules = _G[MODULES_G_KEY]

for mod_name, mod_muid in pairs(CONTAINER:GetCustomProperties()) do
    if modules[mod_name] then
        error(string.format("ERROR: name duplication: `%s` in container `%s`", mod_name, CONTAINER.name), 2)
    end
    modules[mod_name] = mod_muid
end

-- get template's MUID by name
local function get_muid(module_name)
    local muid = modules[module_name]
    if muid then
        return muid
    else
        error(string.format("ERROR: unknown muid for: `%s`", module_name), 2)
    end
end

-- Replacement for Core's `require`, works with MUID parameter or module name (like vanilla Lua).
local function export(nameOrMuid)
    local muid = modules[nameOrMuid]
    if not muid then
        -- does it look like a MUID?
        if tonumber(CoreString.Split(nameOrMuid, ':'), 16) then
            -- ... then treat it like a MUID
            return require(nameOrMuid)
        else
            error("ERROR: unknown module: '" .. nameOrMuid .. "'", 2)
        end
    end
    local t1 = os.clock()
    local module = require(muid)
    local dt = os.clock() - t1
    if dt > 0.025 then
        warn(string.format("INFO: initial module loading time exceeds the 25 ms theshold: [%s]: %d ms.", nameOrMuid, dt*1000//1))
    end
    return module
end

-- export to global
_G.get_muid = get_muid
_G.export = export

if EXPORT_DEPRECATED then
    _G.muid = get_muid
    _G.req = export
end
