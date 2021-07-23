--[[
    *Spring Animator* - 'fire and forget' animation system with Core(TM) flavor.
    Based on closed form ODE solver for damped harmonic oscillator (spring).
    Copyright (C) 2021 Andrew Zhilin <andrew.zhilin@gmail.com>
    https://github.com/zoon

    Inspired by https://github.com/Fraktality/spr
    Copyright (c) 2020 Parker Stebbins. All rights reserved.

    Distributed under the MIT license.

    NOTE: I'm not happy with API, in the future we should use spr's wrap-unwrap technique and lua arrays.
]]

-- mostly for testing in console
local CORE_ENV = CoreMath and CoreString
local _DUMMY = CORE_ENV and World.GetRootObject()

local EPS = 0.001 -- 0.0001 will stay awake a little longer
local MIN_OFFSET_SQ = EPS*EPS
local MIN_VELOCITY_SQ = EPS

local PI_2 = 2*math.pi
local exp, sqrt, sin, cos = math.exp, math.sqrt, math.sin, math.cos
local ceil, floor = math.ceil, math.floor
local _noop = function() return end
local _weak_key_mt = {__mode="k"}
local _weak_val_mt = {__mode="v"}

-- @ spring_solver :: dt, damping, omega, pos, vel, goal -> pos', vel'
-- Closed form ODE solver for damped harmonic oscillator.
-- Taken from https://github.com/Fraktality/Spring
--   dt: Delta time.
--   dumping: Dumping factor.
--     damping < 1 Underdamping: overshoots and converges on the goal.
--     damping = 1 Critical damping: converges on the goal without overshooting.
--     damping > 1 Overdamping: converges on the goal without overshooting, but slower.
--   omega: angular frequency (2PI*frequency)
-- pos, vel, goal: state veriables of 'number' or 'vectorish' type.
local function spring_solver(dt, dumping, omega, pos, vel, goal)
    local offset = pos - goal
    local decay = exp(-dumping*omega*dt)

    local pos_1, vel_1

    if dumping == 1 then -- Critically damped
        pos_1 = (offset*(1 + omega*dt) + vel*dt)*decay + goal
        vel_1 = (vel*(1 - omega*dt) - offset*(omega*omega*dt))*decay

    elseif dumping < 1 then -- Underdamped
        local c = sqrt(1 - dumping*dumping)

        local i = cos(omega*c*dt)
        local j = sin(omega*c*dt)

        -- Damping ratios approaching 1 can cause division by small numbers.
        -- To fix that, group terms around z=j/c and find an approximation for z.
        -- Start with the definition of z:
        --    z = sin(dt*f*c)/c
        -- Substitute a=dt*f:
        --    z = sin(a*c)/c
        -- Take the Maclaurin expansion of z with respect to c:
        --    z = a - (a^3*c^2)/6 + (a^5*c^4)/120 + O(c^6)
        --    z ≈ a - (a^3*c^2)/6 + (a^5*c^4)/120
        -- Rewrite in Horner form:
        --    z ≈ a + ((a*a)*(c*c)*(c*c)/20 - c*c)*(a*a*a)/6

        local z
        if c > EPS then
            z = j/c
        else -- uncommon case
            local a = dt*omega
            z = a + ((a*a)*(c*c)*(c*c)/20 - c*c)*(a*a*a)/6
        end

        -- Frequencies approaching 0 present a similar problem.
        -- We want an approximation for y as f approaches 0, where:
        --    y = sin(dt*f*c)/(f*c)
        -- Substitute b=dt*c:
        --    y = sin(b*c)/b
        -- Now reapply the process from z.

        local y
        if omega*c > EPS then
            y = j/(omega*c)
        else -- uncommon case
            local b = omega*c
            y = dt + ((dt*dt)*(b*b)*(b*b)/20 - b*b)*(dt*dt*dt)/6
        end

        pos_1 = (offset*(i + dumping*z) + vel*y)*decay + goal
        vel_1 = (vel*(i - z*dumping) - offset*(z*omega))*decay

    else -- Overdamped
        local c = sqrt(dumping*dumping - 1)

        local r1 = -omega*(dumping - c)
        local r2 = -omega*(dumping + c)

        local co2 = (vel - offset*r1)/(2*omega*c)
        local co1 = offset - co2

        local e1 = co1*exp(r1*dt)
        local e2 = co2*exp(r2*dt)

        pos_1 = e1 + e2 + goal
        vel_1 = e1*r1 + e2*r2
    end

    return pos_1, vel_1
end

-----------------------------------------------------------------------------
-- Utility
-----------------------------------------------------------------------------
-- forward declaration
local MinHeap = {}
MinHeap.__index = MinHeap
function MinHeap.New() return setmetatable({_n = 0, _pq= {}}, MinHeap) end

local function _typeof(v)
    local lua_type = type(v)
    return (lua_type == "userdata" or lua_type == "table") and v.type and v.type or lua_type
end

local function _type(val, type, msg)
    local tval = _typeof(val)
    if tval == type then return true end
    return false, string.format("%s(argument '%s' should be '%s')", (msg..": ") or "", tval, type)
end

local function _round_vec2(vec2)
    local x, y = vec2.x, vec2.y
    x = x >= 0 and floor(x + .5) or ceil(x - .5)
    y = y >= 0 and floor(y + .5) or ceil(y - .5)
    return x, y
end

-- Lerps color, maps t:[0,2] -> [0,1]
local function _lerp_color_02(a, b, t)
    t = t < 1 and t or 2 - t
    return Color.Lerp(a, b, t)
end

-- Lerps numbers, maps t:[0,2] -> [0,1]
local function _lerp_02(a, b, t)
    t = t < 1 and t or 2 - t
    return CoreMath.Lerp(a, b, t)
end

-- _SETTING_METHODS :: {[propkey] = {[get]=, [set]=, [wrap]=, [unwrap]=, [add]=, [lerp]=}}
-- all deductable methods optional
local _SETTING_METHODS = not CORE_ENV and {} or {
    -- offset, size rotationAngle fo UIControl
    offset = {
        get=function(obj) return Vector2.New(obj.x, obj.y) end,
        set=function(obj, vec2) obj.x, obj.y = _round_vec2(vec2) end,
    },
    size = {
        get=function(obj) return Vector2.New(obj.width, obj.height) end,
        set=function(obj, vec2) obj.width, obj.height = _round_vec2(vec2) end,
    },
    rotationAngle = {
        get=function(obj) return obj.rotationAngle end,
        set=function(obj, val) obj.rotationAngle = val end,
    },
    WorldRotation = {
        wrap = function(rot) return Quaternion.New(rot) end,
        unwrap = function(quat) return Rotation.New(quat) end,
        add = function(q1, q2) return q1*q2 end,
    },
    Rotation = {
        wrap = function(rot) return Quaternion.New(rot) end,
        unwrap = function(quat) return Rotation.New(quat) end,
        add = function(q1, q2) return q1*q2 end,
    },
    alpha = {
        get=function(obj) local c = obj:GetColor() return c.a end,
        set=function(obj, a) local c = obj:GetColor() c.a = a obj:SetColor(c) end,
        lerp = _lerp_02
    },
    Color = {
        -- CoreObject does not have Get/SetColor, CoreMesh does
        get=function(obj)
            return obj:GetColor()
        end,
        set=function(obj, c) obj:SetColor(c) end,
        lerp = _lerp_color_02
    },
    -- `U` Prefix for "User defined objects"
    UPosition = {
        get=function(obj) return obj:GetPosition() end,
        set=function(obj, v) obj:SetPosition(v) end,
    },
    UScale = {
        get=function(obj) return obj:GetScale() end,
        set=function(obj, v) obj:SetScale(v) end,
    }
}

local function _get_setting_methods(propkey, instance)
    instance = instance or _DUMMY -- NOTE: there is no dummy for UIControl
    if not _SETTING_METHODS[propkey] then _SETTING_METHODS[propkey] = {} end
    local methods = _SETTING_METHODS[propkey]
    methods.get = methods.get or assert(instance["Get" .. propkey], "not found Get" .. propkey)
    methods.set = methods.set or assert(instance["Set" .. propkey], "not found Set" .. propkey)
    if not methods.lerp then
        local val = methods.wrap and methods.wrap(methods.get(instance)) or methods.get(instance)
        methods.lerp = assert(type(val) == "number" and CoreMath.Lerp or val.Lerp or val.Slerp, "not found Lerp")
    end
    return methods
end

-----------------------------------------------------------------------------
-- SpringParams
-----------------------------------------------------------------------------
local SpringParams = {type="SpringParams"}
SpringParams.__index = SpringParams

-- @SpringParams.New :: dampingRatio, frequency -> new SpringParams
-- Encapsulates spring solver parameters.
--  dampingRatio < 1 Underdamping: overshoots and converges on the goal.
--  dampingRatio = 1 Critical damping: converges on the goal without overshooting.
--  dampingRatio > 1 Overdamping: converges on the goal without overshooting, but slower.
--  frequency: frequency in Hz.
function SpringParams.New(dampingRatio, frequency, ...)
    assert(select("#", ...) == 0, "too many arguments")
    assert(frequency >= EPS, frequency)
    assert(_type(dampingRatio, "number", "dampingRatio"))
    dampingRatio = dampingRatio >= 0 and dampingRatio or 0
    return setmetatable({frequency=frequency, angularFrequency=PI_2*frequency, dampingRatio=dampingRatio}, SpringParams)
end

-- @ SpringParams.RandomizeFrequency: self[, factor=0.05] -> new SpringParams
-- factor: randomizing factor, default: +-5%
function SpringParams:RandomizeFrequency(factor)
    factor = factor or 0.05
    factor = math.max(0, math.min(factor, 1 - EPS))
    if factor == 0 then return self:Copy() end
    local r = 2*math.random() - 1 -- [-1, 1)
    factor = r*factor
    local d, f = self.dampingRatio, self.frequency
    f = f + f*factor
    return SpringParams.New(d, f)
end

function SpringParams:Copy()
    return SpringParams.New(self.dampingRatio, self.frequency)
end

-----------------------------------------------------------------------------
-- Spring: low-level explicit-state spring with update method
-----------------------------------------------------------------------------
local Spring = {type="Spring"}
Spring.__index = Spring

local D_IDX, O_IDX, P_IDX,V_IDX, G_IDX = 1, 2, 3, 4, 5

-- @Spring.New :: spring_params, position -> new Spring
-- Creates new Spring in equlibrium state.
function Spring.New(spring_params, position, ...)
    assert(select("#", ...) == 0, "too many arguments")
    local tpos = _typeof(position)
    if tpos ~= "number" and not (position.__mul and position.__sub) then
        error(string.format("'%s' not supported multiplication and substraction", tpos))
    end
    assert(_type(spring_params, SpringParams.type, "spring_params"))
    local d, omega = spring_params.dampingRatio, spring_params.angularFrequency
    local self = {nil, nil, nil, nil, nil}
    self[D_IDX] = d
    self[O_IDX] = omega
    self[P_IDX] = position
    self[V_IDX] = position*0
    self[G_IDX] = position
    return setmetatable(self, Spring)
end

-- internal Spring._unpack :: self -> dumping, omega, pos, vel, goal
function Spring:_unpack()
    -- 2x faster then table.unpack
    return self[D_IDX], self[O_IDX], self[P_IDX], self[V_IDX], self[G_IDX]
end

-- internal Spring._set_pos_vel :: self, pos, vel ^-> nil
function Spring:_set_pos_vel(pos,vel)
    self[P_IDX], self[V_IDX] = pos, vel
end

-- @ Spring.Update :: self, dt ^-> pos', vel', goal
function Spring:Update(dt)
    local p, v = spring_solver(dt, self[D_IDX], self[O_IDX], self[P_IDX], self[V_IDX], self[G_IDX])
    -- update state
    self:_set_pos_vel(p, v)
    return p, v
end

-- @ Spring.SetGoal :: self, goal ^-> self
function Spring:SetGoal(goal)
    self[G_IDX] = goal
    return self
end

function Spring:SetPosition(position)
    self[P_IDX] = position
    return self
end

function Spring:SetVelocity(velocity)
    self[V_IDX] = velocity
    return self
end

-- @ Spring.SetGoalByOffset :: self, offset ^-> self
function Spring:SetGoalByOffset(offset)
    self[G_IDX] = self[P_IDX] + offset
end

-- @ Spring.SetParams :: self[, dumping, frequency] ^-> self
function Spring:SetParams(dumping, frequency)
    if dumping then self[D_IDX] = dumping end
    if frequency then self[O_IDX] = PI_2*frequency end
    return self
end

-- @ Spring.SetParams :: self, spring_params ^-> self
function Spring:SetSpringParams(spring_params)
    assert(_type(spring_params, SpringParams.type, "spring_params"))
    self[D_IDX], self[O_IDX] = spring_params.dampingRatio, spring_params.angularFrequency
    return self
end

-- @ Spring.GetPosition :: self -> position, velocity
function Spring:GetPosition()
    return self[P_IDX]
end

function Spring:GetVelocity()
    return self[V_IDX]
end

-- @ Spring.GetAngularFrequency :: self -> omega
function Spring:GetAngularFrequency()
    return self[O_IDX]
end

-- @ Spring.AddImpulse :: self, velocity ^-> self
function Spring:AddImpulse(velocity)
    self[V_IDX] = self[V_IDX] + velocity
    return self
end

-- @ Spring.Nudge :: self, radius ^-> self
-- Adds impulse to radius direction, with undumped amplitude = 2*radius
function Spring:Nudge(radius)
    self[V_IDX] = self[V_IDX] + self[O_IDX]*radius
    return self
end

-----------------------------------------------------------------------------
-- Spring Animator - fire-and-forget property animator with chaining support
-----------------------------------------------------------------------------
local SpringAnimator = {type="SpringAnimator"}
SpringAnimator.__index = SpringAnimator
-- `less` operator for scheduler
function SpringAnimator.__lt(spr_anim1, spr_anim2) return spr_anim1._run_at < spr_anim2._run_at end

---------------------------------------
-- Spring Animator Internals
---------------------------------------

-- _springStates ::  {[instance(weak)] = {[property] = state}
local _sa_states = setmetatable({}, _weak_key_mt)
local _sa_scheduler = MinHeap.New()
local _sa_states_active = false
local _sa_scheduler_active = false

-- forward declaration
local _sa_worker, _sa_scheduler_worker

local function _activate_sa_thread()
    if not _sa_states_active then
        _sa_states_active = true
        Task.Spawn(_sa_worker)
    end
end

local function _activate_sa_scheduler()
    if not _sa_scheduler_active then
        _sa_scheduler_active = true
        Task.Spawn(_sa_scheduler_worker)
    end
end

local function _sa_scheduler_add(spr_anim)
    _sa_scheduler:Push(spr_anim)
    _activate_sa_scheduler()
end

local function _sa_scheduler_remove(instance, propkey)
    _sa_scheduler:_for_each(function(spr_anim)
        if spr_anim:_get_instance() == instance and (not propkey or spr_anim._propkey == propkey) then
            spr_anim._instance[1] = nil -- nil instance for (lazy) remove it later
            local ok, msg = pcall(spr_anim._onCancel)
            if not ok then warn(msg) end
        end
    end)
end

local function _sa_states_add(spr_anim)
    if not spr_anim then return end
    assert(_type(spr_anim, SpringAnimator.type, "spr_anim"))
    local instance = spr_anim:_get_instance()
    if not instance then return end
    local propkey = spr_anim._propkey
    if not _sa_states[instance] then
        _sa_states[instance] = {}
    end
    local states = _sa_states[instance]
    -- call `onCancel` on previous animation of this property
    if states[propkey] then
        local ok, msg = pcall(states[propkey]._onCancel)
        if not ok then warn(msg) end
        states[propkey] = nil
    end
    -- try to remove from scheduler too
    _sa_scheduler_remove(instance, propkey)
    -- actualize origin and goal
    local methods = spr_anim._methods
    local get, wrap, add = methods.get, methods.wrap, methods.add
    local value = get(instance)
    value = wrap and wrap(value) or value
    spr_anim._origin = value
    if spr_anim._goal then
        spr_anim._goal = wrap and wrap(spr_anim._goal) or spr_anim._goal
    elseif spr_anim._offset then
        local offset = spr_anim._offset
        offset = wrap and wrap(offset) or offset
        spr_anim._goal = add and add(spr_anim._origin, offset) or spr_anim._origin + offset
    elseif not spr_anim._goal then -- equilibrium, no goal was set
        spr_anim._goal = spr_anim._origin
    end
    states[propkey] = spr_anim
    _activate_sa_thread()
end

_sa_worker = function()
    local _unpack = Spring._unpack
    local _set_pos_vel = Spring._set_pos_vel
    local _animations_to_run = {}
    local _on_finish_to_run = {}

    while _sa_states_active do
        local dt = Task.Wait()
        -- clean up invalid instances
        for instance, _ in pairs(_sa_states) do
            if instance and instance.IsValid and not instance:IsValid() then
                -- it seems reasonble do not try to call 'onCancel' here
                _sa_states[instance] = nil
            end
        end
        for instance, animations in pairs(_sa_states) do
            for propkey, anim in pairs(animations) do
                -- for our normalized offsets, p should be *precisely* at [0, 2], and goal at `1`
                local spring = anim._spring
                local d, o, p0, v0, _ = _unpack(spring)
                local p, v = spring_solver(dt, d, o, p0, v0, 1)
                -- clamp p to [0, 2] sharp - miniscule overshoots possible with zero dumping
                p = p < 0 and 0 or p
                p = p > 2 and 2 or p
                local finish = v*v < MIN_VELOCITY_SQ and (p - 1)*(p - 1) < MIN_OFFSET_SQ
                local t = not finish and p or 1
                local lerp, set, unwrap = anim._methods.lerp, anim._methods.set, anim._methods.unwrap
                local origin, goal = anim._origin, anim._goal
                local value = anim._swap and lerp(goal, origin, t) or lerp(origin, goal, t)
                value = unwrap and unwrap(value) or value
                set(instance, value)

                if not finish then
                    _set_pos_vel(spring, p, v)
                else -- finished
                    animations[propkey] = nil
                    -- move to next in chain/cycle
                    if anim._next then
                        anim._next:Reset()
                        -- we can't mess with tables from within cycle
                        _animations_to_run[#_animations_to_run+1] = anim._next
                    end
                    -- we can't mess with tables from within cycle
                    _on_finish_to_run[#_on_finish_to_run+1] = anim._onFinish
                end
            end
        end
        -- call pending onFinish callbacks
        for i = 1, #_on_finish_to_run do
            local onFinish = _on_finish_to_run[i]
            _on_finish_to_run[i] = nil
            local ok, msg = pcall(onFinish)
            if not ok then warn("ERROR: onFinish: " .. msg) end
        end
        -- add pending animations
        for i=1, #_animations_to_run do
            local spr_anim = _animations_to_run[i]
            _animations_to_run[i] = nil
            spr_anim:Run()
        end
        -- clean-up finished instances
        for instance, animations in pairs(_sa_states) do
            if not next(animations) then _sa_states[instance] = nil end
        end
        if not next(_sa_states) then
            _sa_states_active = false
            break
        end
    end
end

_sa_scheduler_worker = function()
    while not _sa_scheduler:IsEmpty() do
        local spr_anim = _sa_scheduler:Peek()
        if not spr_anim:_get_instance() then -- i.e marked to remove by scheduler or instance destroyed
            _sa_scheduler:Pop()
        elseif spr_anim._run_at <= time() then
            _sa_scheduler:Pop()
            spr_anim._run_at = 0
            _sa_states_add(spr_anim)
        else
            Task.Wait(0.1) -- will check ~10 times per second
        end
    end
    _sa_scheduler_active = false
end

---------------------------------------
-- Spring Animator Public methods
---------------------------------------
-- TODO: add periodic params randomization: delay, freq
-- TODO: cycle breaker
-- TODO: smart properties support

-- @ SpringAnimator.New :: SpringParams, instance, proprkey, random_cactor -> new SpringAnimator
-- instance :: `CoreObject`, `UIControl` or user-object with according API.
-- Constructs animation object and sets animation `origin` to current value of instance property.
-- Supported propkeys for `CoreObject`: '[World]Position', '[World]Rotation', 'Scale', 'Color', 'alpha'
-- Supprted propkeys for `UIControl`: 'size', 'offset', 'rotationAndle', 'Color', 'alpha'
function SpringAnimator.New(spring_params, instance, propkey, random_factor)
    assert(_type(spring_params, SpringParams.type, "spring_params"))
    assert(instance and (type(instance) == "userdata" or type(instance) == "table"), "no instance")
    if instance.IsValid and not instance:IsValid() then
        error("invalid object instance")
    end
    assert(_type(propkey, "string", "propkey"))
    local self = spring_params:ToAnim(random_factor, random_factor)
    self(instance)
    -- target -----------------------------------
    self._propkey = propkey
    self._methods = _get_setting_methods(self._propkey, instance)
    self._origin = nil
    self._goal = nil
    self._offset = nil
    self._swap = false
    return self
end

-- To make `SpringAnimator` from `SpringParams`
function SpringParams:ToAnim(randomize, factor)
    local anim = setmetatable({}, SpringAnimator)
    anim._instance = setmetatable({}, _weak_val_mt)
    local params = randomize and self:RandomizeFrequency(factor) or self:Copy()
    anim._spring = Spring.New(params, 0)
    -- save state for reset
    anim._p0 = anim._spring:GetPosition()
    anim._v0 = anim._spring:GetVelocity()
    -- etc. -------------------------------------
    anim._next = nil
    anim._onFinish = _noop
    anim._onCancel = _noop
    anim._periodic_delay = 0
    anim._run_at = 0
    return anim
end

-- Next 4 methods are the new API
function SpringAnimator:Target(propkey, goal)
    self._propkey = propkey
    self._methods = _get_setting_methods(self._propkey, self:_get_instance())
    self:SetGoal(goal)
    return self
end

function SpringAnimator:Offset(propkey, offset)
    self._propkey = propkey
    self._methods = _get_setting_methods(self._propkey, self:_get_instance())
    self:SetGoalByOffset(offset)
    return self
end

function SpringAnimator:Impulse(propkey, radius)
    self._propkey = propkey
    self._methods = _get_setting_methods(self._propkey, self:_get_instance())
    self:Nudge(radius)
    return self
end

-- To bind instance with premade SpringAnimator
-- local premade = SpringParams.New(1,1):ToAnim():Impulse(50*Vector3.UP)
-- ... premade(self._geo):Run()
function SpringAnimator:__call(instance)
    assert(instance)
    self._instance[1] = instance
    return self
end

-- @ SpringAnimator.SetPeriodicDelay :: self, delay:sec ^-> self
-- Every time when animation run, it will wait `delay` second in scheduler.
function SpringAnimator:SetPeriodicDelay(delay)
    self._periodic_delay = delay
    return self
end

function SpringAnimator:GetPeriodicDelay()
    return self._periodic_delay, self._run_at
end

-- `onFinish` callback alled every time when animator reach equlibrium state (finished).
function SpringAnimator:SetOnFinish(onFinish)
    self._onFinish = onFinish
    return self
end

-- `onCancel` callback called by SpringAnimator:Stop and for shcheduled animations by SpringAnimator:Finalize.
function SpringAnimator:SetOnCancel(onCancel)
    self._onCancel = onCancel
end

-- @ SpringAnimator.Chain :: self, SpringAnimator, ... ^-> self
-- Runs next animation in chain when previous animation finished.
function SpringAnimator:Chain(...)
    local n = select("#", ...)
    assert(n > 0, "no arguments to chain")
    assert(not self._next, "already chained or cycled")
    local prev = self
    for i = 1, n do
        local spr_anim = select(i, ...)
        assert(_type(spr_anim, SpringAnimator.type, "spr_anim"))
        prev._next = spr_anim
        prev = spr_anim
    end
    return self
end

-- @ SpringAnimator.Cycle :: self, SpringAnimator, ... ^-> self
-- Chain with cycle, will be switched to next animation forever.
function SpringAnimator:Cycle(...)
    self:Chain(...)
    local n = select("#", ...)
    local last = select(n, ...)
    last._next = self
    return self
end

-- @ SpringAnimator.Run :: self[, delay] ^-> nil
-- Starts animation next frame or after `delay`, will add `delay` to `periodic delay` for this run.
function SpringAnimator:Run(delay)
    assert(self._periodic_delay)
    delay = delay or 0
    delay = self._periodic_delay + delay
    if delay <= 0 then
        _sa_states_add(self)
    else
        self._run_at = time() + delay
        _sa_scheduler_add(self)
    end
    return self
end

-- @ SpringAnimator.Stop :: instance[, propkey]
-- Stops animation (or all animations) of instance and lives instance as is.
-- Removes animation from scheduler if it wasn't started.
-- Calls `OnCancel` for each stopped or removed animation.
function SpringAnimator.Stop(instance, propkey)
    assert(instance.type ~= SpringAnimator.type, "SpringAnimator.Stop is a static method: use `.` istead of `:`")
    local anims = _sa_states[instance]
    if anims then
        for pk, spr_anim in pairs(anims) do
            if not propkey or propkey == pk then
                local ok, msg = pcall(spr_anim._onCancel)
                if not ok then warn(msg) end
                anims[pk] = nil
            end
        end
    end
    -- remove from scheduler too (it's seems reasonable)
    _sa_scheduler_remove(instance, propkey)
end

-- @ SpringAnimator.Finalize :: instance[, propkey] ^-> nil
-- Forces animation (or all animations of instance) to reach the goal next frame.
-- Removes animations from scheduler if it wasn't started, calls `OnCancel` for each removed animation.
function SpringAnimator.Finalize(instance, propkey)
    assert(instance.type ~= SpringAnimator.type, "SpringAnimator.Stop is a static method: use `.` istead of `:`")
    local anims = _sa_states[instance]
    if anims then
        for pk, spr_anim in pairs(anims) do
            if not propkey or propkey == pk then
                spr_anim._spring:_set_pos_vel(1, 0)
            end
        end
    end
    -- remove from scheduler before it starts (it's seems reasonable)
    _sa_scheduler_remove(instance, propkey)
end

-- Resets animation state (position and velocity).
function SpringAnimator:Reset()
    self._spring:_set_pos_vel(self._p0, self._v0)
    return self
end

function SpringAnimator:_get_instance()
    local instance  = self._instance and self._instance[1]
    if instance and instance._IsValid and not instance:IsValid() then return nil end
    return instance
end

-- Sets animation `goal` to goal value
function SpringAnimator:SetGoal(goal)
    self._goal = goal
    return self
end

-- Sets animation goal by adding `offset` to itanstance's `origin` property value.
function SpringAnimator:SetGoalByOffset(offset)
    self._offset = offset
    return self
end

-- Adds impulse to radius direction, with undumped amplitude = 2*radius
function SpringAnimator:Nudge(radius)
    self._offset = radius
    -- swap origin and goal, set state to (p = 1, v = -omega)
    self._swap = true
    local omega = self._spring:GetAngularFrequency()
    self._spring:_set_pos_vel(1, -omega)
    -- save state for reset
    self._p0 = self._spring:GetPosition()
    self._v0 = self._spring:GetVelocity()
    return self
end

-----------------------------------------------------------------------------
-- Rest of definitions
-----------------------------------------------------------------------------
do
    local insert = table.insert
    -- internal hacky method
    function MinHeap:_for_each(callback)
        local array, n = self._pq, self._n
        for i = 1, n do
            local el = array[i]
            callback(el)
        end
    end
    function MinHeap:Peek()
        return self._pq[1]
    end
    function MinHeap:Count()
        return self._n
    end
    function MinHeap:IsEmpty()
        return self._n == 0
    end
    local function swim(k, pq)
        while true do
            local parent = math.floor(k/2)
            if k > 1 and pq[k] < pq[parent] then
                local temp = pq[k]
                pq[k] = pq[parent]
                pq[parent] = temp
                k = parent
            else
              break
            end
        end
    end
    function MinHeap:Push(el)
        local n = self._n + 1
        self._n = n
        local pq = self._pq
        insert(pq, n, el)
        swim(n, pq)
        return self
    end
    local function sink(n, pq)
        local k = 1
        while 2*k <= n do
            local child = 2*k
            if child < n and pq[child + 1] < pq[child] then
                child = child + 1
            end
            if not (pq[child] < pq[k]) then
                break
            end
            local temp = pq[k]
            pq[k] = pq[child]
            pq[child] = temp
            k = child
        end
    end
    function MinHeap:Pop()
        local n = self._n
        if n == 0 then
            return nil
        end
        local pq = self._pq
        local result = pq[1]
        pq[1] = pq[n]
        pq[n] = nil
        n = n - 1
        sink(n, pq)
        self._n = n
        return result
    end
    function MinHeap:Clear()
        local n = self._n
        if n == 0 then return end
        for i = n, 1, -1 do
            self._pq[i] = nil
        end
        assert(#self._pq == 0)
        self._n = 0
    end
end

-- self test
local function _self_test()
    -- @ spring_solver :: dt, damping, omega, pos, vel, goal -> pos', vel', in_equilibrium
    local d, f = 1, 1*PI_2
    local p1, v1 = spring_solver(0.5, d, f, 0, 0, 1)
    assert(math.abs(p1 - 0.82102555358593) < EPS)
    assert(math.abs(v1 - 0.85300855576888) < EPS)
    local p2, v2= spring_solver(0.5, d, f, p1, v1, 1)
    assert(math.abs(p2 - 0.98639906853443) < EPS)
    assert(math.abs(v2 - 0.07372368401459) < EPS)
    d = 0.5
    p1, v1 = spring_solver(0.5, d, f, 0, 0, 1)
    assert(math.abs(p1 - 1.1406996741435) < EPS)
    assert(math.abs(v1 - 0.61621768737322) < EPS)
    p2, v2 = spring_solver(0.5, d, f, p1, v1, 1)
    assert(math.abs(p2 - 0.98982212901474) < EPS)
    assert(math.abs(v2 - -0.23383824515613) < EPS)

    d = 1.5
    p1, v1 = spring_solver(0.5, d, f, 0, 0, 1)
    assert(math.abs(p1 - 0.75020554281012) < EPS)
    assert(math.abs(v1 - 0.60014052697326) < EPS)
    p2, v2= spring_solver(0.5, d, f, p1, v1, 1)
    assert(math.abs(p2 - 0.92474819921701) < EPS)
    assert(math.abs(v2 - 0.1806013825691) < EPS)

    d, f = 1, 2*PI_2
    p1, v1= spring_solver(0.5, d, f, 0, 0, 1)
    assert(math.abs(p1 - 0.98639906853443) < EPS)
    assert(math.abs(v1 - 0.14744736802918) < EPS)
    p2, v2 = spring_solver(0.5, d, f, p1, v1, 1)
    assert(math.abs(p2 - 0.99995268942114) < EPS) -- sleeps
    assert(math.abs(v2 - 0.00055069903147113) < EPS)

    -- Heap
    local pq = MinHeap.New()
    pq:Push(3):Push(1):Push(2):Push(4):Push(5)
    assert(pq:Count() == 5 and #pq._pq == 5)
    local out = {}
    while not pq:IsEmpty() do
        out[#out+1] = pq:Pop()
    end
    assert(pq:IsEmpty() and #pq._pq == 0)
    assert(out[1] == 1 and out[2] == 2 and out[3] == 3 and out[4] == 4 and out[5] == 5)

    --
    print("spring animator -- ok")
end
_self_test()

-- exports
SpringAnimator.SpringParams = SpringParams
SpringAnimator.Spring = Spring
-- export solver as-is
SpringAnimator.spring_solver = spring_solver
return SpringAnimator
