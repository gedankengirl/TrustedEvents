--[[
    Signals is a lightweight single-thread analog of non-networked Core Events.

    Core Events interface:
    ======================
    Signals.Connect(eventName:any, observer) -> EventListener
    Signals.Broadcast(eventName:any, ...) -> nil

    BehaviorSubject interface:
    ==========================
    Simple analog of ReactiveX BehaviorSubject (http://reactivex.io/documentation/subject.html)
    Well suited for reactive properties.

    Signals.BehaviorSubject(x, y) -> BehaviorSubject
    BehaviorSubject.Connect :: self, (x, y, z ^-> nil) -> EventListener
    BehaviorSubject.Update  :: self, x, y, z ^-> nil
    BehaviorSubject.UpdateDistinct  :: self, x, y, z ^-> nil
    BehaviorSubject.Destroy :: self ^ -> nil

    (!) In this module, we franticly avoiding use more memory than absolutely necessary.
]] local DEBUG = true

_ENV.require = _G.import or require

local Queue = require("Queue").New

local assert = assert
local error = error
local format = string.format
local next = next
local pairs = pairs
local pcall = pcall
local print = print
local rawget = rawget
local select = select
local setmetatable = setmetatable
local tpack, tunpack = table.pack, table.unpack
local type = type
local warn = print or warn

_ENV = nil

---------------------------------------
-- STATE varibles
---------------------------------------
local fresh
do
    local _unique = 0
    fresh = function()
        _unique = _unique + 1
        return _unique
    end
end

-- _subscriptions :: {uid -> event}
local _subscriptions = {}
-- _observers :: {event -> {uid -> observer}}
local _observers = {}

---------------------------------------
-- Forward declarations
---------------------------------------
local Signals = {type = "Signals"}
Signals.__index = Signals

local BehaviorSubject = {type = "BehaviorSubject"}
BehaviorSubject.__index = BehaviorSubject

local EventListener = {type = "EventListener"}
EventListener.__index = EventListener

---------------------------------------
-- EventListener
---------------------------------------
local function createEventListener(event, uid)
    _subscriptions[uid] = event
    return setmetatable({uid}, EventListener)
end

-- get_observer :: self -> function | nil
function EventListener:__call()
    local uid = self[1]
    local event = _subscriptions[uid]
    return event and _observers[event][uid]
end

function EventListener:__newindex()
    return error("EventListener read-only")
end

function EventListener:__index(key)
    if key == "isConnected" then
        return not not self()
    end
    return rawget(EventListener, key)
end

function EventListener:__tostring()
    return format("%s:<%0.4x>:%s", EventListener.type, self[1],
                  self.isConnected and "connected" or "disconnected")
end

function EventListener:Disconnect()
    local uid = self[1]
    local event = _subscriptions[uid]
    if not event then
        return
    end
    _subscriptions[uid] = nil
    local observers = assert(_observers[event])
    observers[uid] = nil
    if not next(observers) then
        _observers[event] = nil
    end
end

---------------------------------------
-- Signals (Core Events substitution)
---------------------------------------
local _signals_in_trampoline = false
local _signals_queue = Queue()

-- Connect :: eventName:any, ovserver:(... -> nil) -> EventListener
function Signals.Connect(eventName, observer)
    assert(eventName ~= nil, "eventName can't be nil")
    assert(type(eventName) ~= "table" or eventName.type ~= Signals.type,
           "remove `:` from Connect call")
    assert(type(observer) == "function", "observer must be a function")
    local observers = _observers[eventName]
    if not observers then
        observers = {}
        _observers[eventName] = observers
    end
    local uid = fresh()
    observers[uid] = observer
    return createEventListener(eventName, uid)
end

function Signals.BehaviorSubject(x, y, z)
    return BehaviorSubject.New(x, y, z)
end

local function do_broadcast(event, ...)
    local observers = _observers[event]
    if not observers then
        return
    end
    for _, observer in pairs(observers) do
        local ok, err = pcall(observer, ...)
        if not ok then
            warn(format("ERROR -- event:<%q> observer:<%q>", event, observer, err))
        end
    end
end

-- NOTE: Signals broadcast yourself in Breadth-first order.
function Signals.Broadcast(event, ...)
    if not _signals_in_trampoline then
        _signals_in_trampoline = true
        do_broadcast(event, ...)
    else
        local ev = tpack(...)
        ev.eventName = event
        _signals_queue:Push(ev)
        return
    end
    while not _signals_queue:IsEmpty() do
        local ev = _signals_queue:Pop()
        local ename = ev.eventName
        do_broadcast(ename, tunpack(ev, 1, ev.n))
    end
    _signals_in_trampoline = false
end

---------------------------------------
-- BehaviorSubject
---------------------------------------
-- NOTE: if three arguments are not enough: use the table!
function BehaviorSubject.New(x, y, z, ...)
    assert(x, "specify at least one state argument")
    assert(select("#", ...) == 0, "3 state arguments max")
    return setmetatable({x, y, z}, BehaviorSubject)
end

function BehaviorSubject:Connect(observer)
    assert(type(observer) == "function")
    local observers = _observers[self]
    if not observers then
        observers = {}
        _observers[self] = observers
    end
    if DEBUG then -- check for observer duplication (very common error)
        for _, obr in pairs(observers) do
            if obr == observer then
                return error("attempt to duplicate observer connection")
            end
        end
    end
    local uid = fresh()
    observers[uid] = observer
    local ok, err = pcall(observer, self[1], self[2], self[3])
    if not ok then
        warn(format("ERROR -- subject:<%q> observer:<%q>", self, observer, err))
    end
    return createEventListener(self, uid)
end

function BehaviorSubject:Update(x, y, z)
    self[1], self[2], self[3] = x, y, z
    Signals.Broadcast(self, x, y, z)
end

function BehaviorSubject:UpdateDistinct(x, y, z)
    assert(type(x) ~= "table", "can't use UpdateDistinct with reference arg#1")
    assert(type(y) ~= "table", "can't use UpdateDistinct with reference arg#2")
    assert(type(z) ~= "table", "can't use UpdateDistinct with reference arg#3")
    if x ~= self[1] or y ~= self[2] or z ~= self[3] then
        self:Update(x, y, z)
    end
end

function BehaviorSubject:Destroy()
    _observers[self] = nil
    self[1], self[2], self[3] = nil, nil, nil
    setmetatable(self, nil)
end

---------------------------------------
-- Test
---------------------------------------
local function test_event_listener()
    local sub = Signals.Connect("x", function(...)
        print(...)
    end)
    assert(sub())
    assert(sub.isConnected)
    sub:Disconnect()
    assert(not sub.isConnected)
    --
    print("  test_event_listener -- ok")
end

local function test_signals()
    local out = {}
    local ev1 = Signals.Connect("_x_Test_A", function()
        Signals.Broadcast("_x_Test_B", "A")
        Signals.Broadcast("_x_Test_C", "A")
        out[#out + 1] = "A"
    end)
    local ev2 = Signals.Connect("_x_Test_B", function()
        Signals.Broadcast("_x_Test_C", "B")
        out[#out + 1] = "B"
    end)
    local ev3 = Signals.Connect("_x_Test_C", function()
        out[#out + 1] = "C"
    end)
    Signals.Broadcast("_x_Test_A")
    assert(out[1] == "A" and out[2] == "B" and out[3] == "C" and out[4] == "C")
    assert(ev1.isConnected)
    assert(ev2.isConnected)
    assert(ev3.isConnected)
    --
    print("  test_signals -- ok")
end

local function test_behaviors()
    local beh = BehaviorSubject.New(1, 2, 3)
    local res1 = {}
    local res2 = {}
    local count = 0
    local function observer(t)
        return function(x, y, z)
            count = count + 1
            t[1] = x
            t[2] = y
            t[3] = z
        end
    end
    local sub1 = beh:Connect(observer(res1))
    assert(#res1 == 3 and res1[1] == 1)
    beh:Update(11, 22, 33)
    assert(#res1 == 3 and res1[2] == 22)
    local sub2 = beh:Connect(observer(res2))
    assert(#res2 == 3 and res2[3] == 33)
    sub2:Disconnect()
    beh:Update(33, 44, 55)
    assert(#res2 == 3 and res2[3] == 33)
    assert(#res1 == 3 and res1[3] == 55)
    sub1:Disconnect()
    beh:Update(0, 0, 0)
    assert(#res1 == 3 and res1[3] == 55)
    beh:Destroy()
    assert(not pcall(beh.Update, 1, 2, 3))
    local c = count
    res1 = {}
    beh = Signals.BehaviorSubject(0, 0, 0)
    beh:Connect(observer(res1))
    assert(count == c + 1)
    beh:UpdateDistinct(0, 0, 0)
    assert(count == c + 1)

    --
    print("  test_behaviors-- ok")
end

-- test
local function self_test()
    print("[Signals]")
    test_event_listener()
    test_signals()
    test_behaviors()
end

self_test()

-- module
return Signals
