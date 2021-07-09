--[[
    Signals is a single-thread analog of non-networked Core Events.
]]
_ENV.require = _G.import or require
local Queue = require("Queue").New

local warn = print or warn
local format = string.format
local rawget = rawget
local tpack, tunpack = table.pack, table.unpack

local _observers = {}
local _subscriptions = {}
---------------------------------------
-- EventListener
---------------------------------------
local EventListener = {type = "EventListener"}
EventListener.__index = EventListener
local function createEventListener(eventName, unique)
    _subscriptions[unique] = eventName
    return setmetatable({unique}, EventListener)
end

-- get observer :: self -> function | nil
function EventListener:__call()
    local unique = self[1]
    local eventName = _subscriptions[unique]
    return eventName and _observers[eventName][unique]
end

function EventListener:__newindex()
    return error("EventListener read-only")
end

function EventListener:__index(key)
    if key == "isConnected" then
        return not not self()
    elseif key == "Disconnect" then
        return rawget(EventListener, key)
    end
end

function EventListener:__tostring()
    return format("%s:<%0.4x>:%s", EventListener.type, self[1], self.isConnected  and "connected" or "disconnected")
end

function EventListener:Disconnect()
    local unique = self[1]
    local eventName = _subscriptions[unique]
    if not eventName then return end
    _subscriptions[unique] = nil
    _observers[eventName][unique] = nil
end

---------------------------------------
-- Signals (Core Events substitution)
---------------------------------------
local _unique = 0
local _in_trampoline = false
local _queue = Queue()
local Signals = {type = "Signals"}

function Signals.Connect(eventName, observer)
    assert(eventName ~= nil, "eventName can't be nil")
    assert(type(eventName) ~= "table" or eventName.type ~= Signals.type, "remove `:` from connect call")
    assert(type(observer) == "function", "observer must be a function")
    if not _observers[eventName] then _observers[eventName] = {} end
    local unique = _unique
    _unique = _unique + 1
    _observers[eventName][unique] = observer
    return createEventListener(eventName, unique)
end

local function do_broadcast(eventName, ...)
    local observers = _observers[eventName]
    if not observers then return eventName end
    for _, observer in pairs(observers) do
        local ok, err = pcall(observer, ...)
        if not ok then warn(err) end
    end
end

-- NOTE: Signals broadcast yourself in Breadth-first order.
function Signals.Broadcast(eventName, ...)
    if not _in_trampoline then
        _in_trampoline = true
        do_broadcast(eventName, ...)
    else
        local ev = tpack(...)
        ev.eventName = eventName
        _queue:Push(ev)
        return
    end
    while not _queue:IsEmpty() do
        local ev = _queue:Pop()
        local ename = ev.eventName
        ev.eventName = nil
        do_broadcast(ename, tunpack(ev, 1, ev.n))
    end
    _in_trampoline = false
end

Signals.__index = Signals

---------------------------------------
-- Test
---------------------------------------
local function test_event_listener()
    local el = Signals.Connect("x", function (...) print(...) end)
    assert(el())
    assert(el.isConnected)
    el:Disconnect()
    assert(not el.isConnected)
    --
    print("  test_event_listener -- ok")
end

local function test_signals()
    local out = {}
    local ev1 = Signals.Connect("_x_Test_A", function()
        Signals.Broadcast("_x_Test_B", "A")
        Signals.Broadcast("_x_Test_C", "A")
        out[#out+1] = "A"
    end)
    local ev2 = Signals.Connect("_x_Test_B", function()
        Signals.Broadcast("_x_Test_C", "B")
        out[#out+1] = "B"
    end)
    local ev3 = Signals.Connect("_x_Test_C", function()
        out[#out+1] = "C"
    end)
    Signals.Broadcast("_x_Test_A")
    assert(out[1] == "A" and out[2] == "B" and out[3] == "C" and out[4] == "C")
    assert(ev1.isConnected)
    assert(ev2.isConnected)
    assert(ev3.isConnected)
    --
    print("  test_signals -- ok")
end

local function self_test()
    print("[TrustedEvents Supplemental]")
    test_event_listener()
    test_signals()
end

self_test()

-- module
return Signals