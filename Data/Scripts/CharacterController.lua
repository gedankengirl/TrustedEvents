---@diagnostic disable: undefined-field
_ENV.require = _G.import or require
local Debug = require("DebugDraw")(true)

local CharacterController = {}
CharacterController.__index = CharacterController

local acos = math.acos

local UNIT_MASS = 100 -- kg
local GRAVITY = 2000 -- ~1.9*980
local SLOPE_LIMIT = 45

local CAPSULE_BOTTOM = Vector3.New(0, 0, -105.25) -- human
local CAPSULE_R = 30.25
local GROUND = CAPSULE_BOTTOM
local GROUND_HIT_PARAMS = {ignorePlayers = true}
local N_PROBES = 8

local RING_START, RING_END = {}, {} do
    local s1 = CAPSULE_R * Vector3.FORWARD
    local e1 = s1 + GROUND
    local a = 360 / N_PROBES
    for i = 1, N_PROBES do
        local phi = a * (i - 1)
        local rot = Rotation.New(0, 0, phi)
        RING_START[i] = rot * s1
        RING_END[i] = rot * e1
    end
end

function CharacterController.New(obj)
    local self = setmetatable({type = "CharacterController"}, CharacterController)
    self.capsule = obj
    local scale = obj:GetScale().z -- assume uniform
    self.mass = UNIT_MASS * scale * scale
    self.slope_limit = 44
    self.ground_friction = 8
    self.gravity_scale = 1.9
    self.max_speed = 640
    self.swim_speed = 420
    self.jump_speed = 900
    self.max_jumps = 2
    self.fly_speed = 600
    self.is_grounded = false
    return self
end

function CharacterController:FixedUpdate(dt)
    -- check grounded
    local is_grounded = false
    local pos = self.capsule:GetWorldPosition()
    local bottom = pos + GROUND
    local hits = Vector3.ZERO
    local norms = Vector3.ZERO
    local nhits = 0
    for i = 1, N_PROBES do
        local from, to = pos + RING_START[i], pos + RING_END[i]
        local h = World.Raycast(from, to, GROUND_HIT_PARAMS)
        Debug.DrawLine(from, to)
        if h then
            -- TODO: if steep then weight = 0.1
            local htr = h:GetTransform()
            Debug.DrawCross(htr)
            nhits = nhits + 1
            hits = hits +  htr:GetPosition()
            norms = norms + htr:GetForwardVector()
        end
    end
    if nhits == 0 then
        print("flight")
    else
        local r = Rotation.New(norms/nhits, Vector3.UP)
        local tr = Transform.New(r, hits/nhits, Vector3.ONE)
        Debug.DrawPlane(tr)
    end
end

function CharacterController:Update() end

function CharacterController:Jump()
    -- TODO:
end

function CharacterController:Turn(val)
    -- TODO:
end
function CharacterController:Forward(val)
    -- TODO:
end

--
return CharacterController
