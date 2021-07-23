--[[
    Slightly abstracted state-machine from Mergelandia
    Predefined state callbacks (all optional):
        Check :: state -> bool
        Enter :: state, ... -> nil (+event)
        Exit  :: state -> nil      (+event)
        Update :: state, dt -> nil
]]
_ENV.require = _G.import or require
local Signals = require("Signals")
local Maid = require("Maid")

local StateMachine = {type="StateMachine"}
StateMachine.__index = StateMachine

local State = {type="StateMachine.State"}
State.__index = State
local START = setmetatable({name="_START"}, State)

-- @param name: string
function StateMachine.New(name)
    assert(name and type(name) == "string")
    return setmetatable({
        name = name,
        states = {},
        _maid = Maid.New(),
        currentState = START,
    }, StateMachine)
end

-- handlers :: {key = [handle1, handle2, ...]
-- example: {["ability_primary"] = {"HandleLeftMouseDown", "HandleLeftMouseUp"}, ...}
-- usage: PLAYER.bindingPressedEvent:Connect(function(_,binding) MapToStateHandler(binding, 1) end)
function StateMachine:SetBindingHandlers(handlers)
    self.handlers = handlers
end

function StateMachine:MapToStateHandler(binding, handlerIndex, ...)
    assert(handlerIndex and type(handlerIndex) == "number")
    if not self.handlers[binding] then return end
    local handler = self.handlers[binding][handlerIndex]
    if self.currentState and self.currentState[handler] then
        self.currentState[handler](self.currentState, ...)
    end
end

function StateMachine:Connect(connectable, callback, event)
    if connectable == Events or connectable == Signals then
        self._maid:GiveTask(connectable.Connect(event, callback))
    else
        self._maid:GiveTask(connectable:Connect(callback))
    end
end

local function _spawnUpdate(self, update)
    return Task.Spawn(function()
        while true do
            local dt = Task.Wait()
            local ok, m = pcall(update, self, dt)
            if not ok then warn(string.format("result:%q message:%q", ok, m)) end
        end
    end)
end

-- @arg nextState: State|string
function StateMachine:GoToState(nextState, ...)
    assert(nextState)
    nextState = getmetatable(nextState) == State and nextState or self.states[nextState]
    if nextState.Check and not nextState:Check() then return end
    local previousState = self.currentState
    if previousState and previousState.name == nextState then return end
    if previousState and previousState.Exit then
        Signals.Broadcast(previousState.exiting_event)
        previousState:Exit()
        Signals.Broadcast(previousState.exited_event)
    end
    self.currentState = nextState
    if nextState.Enter then
        Signals.Broadcast(nextState.entering_event)
        nextState:Enter(previousState, ...)
        Signals.Broadcast(nextState.entered_event)
    end
    self._maid.update = nextState.Update and _spawnUpdate(nextState, nextState.Update)
end

function StateMachine:AddState(name)
    local state = setmetatable({
        name=name,
        _sm = self,
        entering_event = string.format("%s:%s:Entering", self.name, name),
        exiting_event = string.format("%s:%s:Exiting", self.name, name),
        entered_event = string.format("%s:%s:Entered", self.name, name),
        exited_event = string.format("%s:%s:Exited", self.name, name),
        }, State)
    self.states[name] = state
    return state
end

function StateMachine:Destroy()
    self._maid:Destroy()
end

return StateMachine