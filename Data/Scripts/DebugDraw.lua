---@diagnostic disable: undefined-field
-- TODO: rename to DebugDraw

local NOOP = function(...) end
assert(CoreDebug)
local Debug = {}
Debug.__index = {}
Debug = setmetatable(Debug, Debug)

local _cross_params = {duration = 0.1, thickness = 1, color = Color.MAGENTA}
local _plane_params = {duration = 0.1, thickness = 2, color = Color.MAGENTA}
local _line_params = {duration = 0.1, thickness = 1, color = Color.YELLOW}


local _methods = {}
-- disable forever, ignore
function Debug.__call(self, enable)
    if not next(_methods) then
        for key, value in pairs(self) do
            if type(value) == "function" then
                _methods[key] = value
            end
        end
    end
    for key, value in pairs(self) do
        if type(value) == "function" and key ~= "__call" then
            self[key] = enable and _methods[key] or NOOP
        end
    end
    return self
end

function Debug.DrawLine(from, to) CoreDebug.DrawLine(from, to, _line_params) end

function Debug.DrawCross(p, r)
    r = r or 10
    local tr = p.type == "Transform" and p or Transform.New(Vector3.FORWARD, Vector3.RIGHT, Vector3.UP, p)
    local c, up, right, forward = tr:GetPosition(), tr:GetUpVector(), tr:GetRightVector(), tr:GetForwardVector()
    _cross_params.color = Color.MAGENTA
    CoreDebug.DrawSphere(c, 2, _cross_params)
    _cross_params.color = Color.BLUE
    CoreDebug.DrawLine(c, c + r * up, _cross_params)
    CoreDebug.DrawLine(c, c - r * up, _cross_params)
    _cross_params.color = Color.GREEN
    CoreDebug.DrawLine(c, c + r * right, _cross_params)
    CoreDebug.DrawLine(c, c - r * right, _cross_params)
    _cross_params.color = Color.RED
    CoreDebug.DrawLine(c, c + r * forward, _cross_params)
    CoreDebug.DrawLine(c, c - r * forward, _cross_params)
end

function Debug.DrawPlane(tr, r)
    assert(tr.type == "Transform", tr.type)
    r = r or 35
    local c = tr:GetPosition()
    -- forward is a normal
    local up, right = tr:GetUpVector(), tr:GetRightVector()
    Debug.DrawCross(tr, r)
    local v0 = r * (up + right)
    local v1 = r * (right - up)
    local v2 = c - v0
    local v3 = c - v1
    v0 = c + v0
    v1 = c + v1
    CoreDebug.DrawLine(v0, v1, _plane_params)
    CoreDebug.DrawLine(v1, v2, _plane_params)
    CoreDebug.DrawLine(v2, v3, _plane_params)
    CoreDebug.DrawLine(v3, v0, _plane_params)
end

return Debug
