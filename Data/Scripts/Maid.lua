--[[
    * License: MIT
    * Based on Quenty's Maid:
        https://github.com/Quenty/NevermoreEngine/blob/version2/Modules/Shared/Events/Maid.lua
    * Manages the cleaning of events and other things.
    * Useful for encapsulating state and make deconstructors easy.
    * Adapted for Core by zoon (https://github.com/zoon).
    * Supports (and do all necessary checks for):
        - regular callbacks (call them on Maid:Destroy())
        - CoreObject (:Destroy)
        - Events and Hooks (:Disconnect)
        - Tasks (:Cancel)
        - any type that realize any of this methods
    * Usage (in Core):
    ```
        local Maid = require(`some_muid:Maid.lua`)
        -- will call _maid:OnDestroy() when this `script` is destroyed
        local _maid = Maid.New(script)
        ...
        _maid.cool_event_connection = Events.Connect("MyCoolEvent", OnMyCoolEvent)
        -- diconnect MyCoolEvent after 1 sec
        Task.Wait(1)
        _maid.cool_event_connection = nil
        -- will destroy spawned object when _maid:Destroy() is called
        _maid:GiveTask(World.SpawnAsset(SOME_TEMPLATE))
        _maid.my_cool_pet = World.SpawnAssets(BRONZE_PET_TEMPLATE)
        ...
        -- will destroy instance of BRONZE_PET_TEMPLATE and keep the ref to SILVER_PET_TEMPLATE instance
        _maid.my_cool_pet = World.SpawnAssets(SILVER_PET_TEMPLATE)
    ```
    * Quenty has a good post about Maid:
    https://medium.com/roblox-development/how-to-use-a-maid-class-on-roblox-to-manage-state-651bf74de98b
    * For people with Unity background: Maid is like Rx's CompositeDisposable on steroids.
]]

local CORE_ENV = CoreDebug and true
local stacktrace = (CORE_ENV and CoreDebug.GetStackTrace) or debug.traceback
local warn = warn or print

local Maid = {type = "Maid"}
Maid.__index = Maid

--- Returns a new Maid object that can be connected to `destroyEvent` of any Core object
-- @return Maid
function Maid.New(coreObject)
    local self = setmetatable({_tasks = {}}, Maid)
    if CORE_ENV and coreObject then
        self:GiveTask(coreObject.destroyEvent:Connect(self))
    elseif coreObject then
        warn("Outside Core argument will be ignored")
    end
    return self
end

--- Returns Maid[key] if not part of Maid metatable
-- @return Maid[key] value
function Maid:__index(index)
    if Maid[index] then
        return Maid[index]
    else
        return self._tasks[index]
    end
end

local function _cleanupTask(task)
    if task == nil then
        return
    end

    if type(task) == "function" then
        task()
    elseif type(task) == 'userdata' and CORE_ENV then
        -- Core types:
        if (task:IsA("EventListener") or task:IsA("HookListener")) and task.isConnected then
            task:Disconnect()
        elseif task:IsA("CoreObject") and task:IsValid() then
            task:Destroy()
        elseif task:IsA("Task") then
            task:Cancel()
        end
    else
        -- user types, assume that `table type` or `userdata type` are not Core objects
        if task.Disconnect then
            task:Disconnect()
        elseif task.Cancel then
            task:Cancel()
        elseif task.Destroy then
            task:Destroy()
        end
    end
end

local function _check(task)
    if task and (type(task) == "table" or type(task) == "userdata") and
        not (task.Destroy or task.Cancel or task.Disconnect) then
        warn("[Maid][Warning] - Gave task without Destroy|Cancel|Disconnect\n\n" .. stacktrace())
    end
    return task
end

--- Add a task to clean up. Tasks given to a maid will be cleaned when
--  maid[index] is set to a different value.
-- @usage
-- Maid[key] = (function)         Adds a task to perform
-- Maid[key] = (event connection) Manages an event connection
-- Maid[key] = (Maid)             Maids can act as an event connection, allowing a Maid to have other maids to clean up.
-- Maid[key] = (Object)           Maids can cleanup objects with a `Destroy` method
-- Maid[key] = nil                Removes a named task. If the task is an event, it is disconnected. If it is an object,
--                                it is destroyed.
function Maid:__newindex(index, newTask)
    if Maid[index] ~= nil then
        error(("'%s' is reserved"):format(tostring(index)), 2)
    end

    local tasks = self._tasks
    local oldTask = tasks[index]

    if oldTask == newTask then
        return
    end
    tasks[index] = _check(newTask)
    _cleanupTask(oldTask)
end

function Maid:__call()
    self:Destroy()
end

--- Same as indexing, but uses an incremented number as a key.
-- GiveTask :: self, task ^-> task, task_id
function Maid:GiveTask(task)
    if self.type ~= "Maid" then
        error("Maid -- don't forget `:`", 2)
    end
    if not task then
        error("Maid -- task cannot be false or nil", 2)
    end
    local taskId = #self._tasks + 1
    self[taskId] = task

    return task, taskId
end

--[[ TODO: implement promise module and wire it here
function Maid:GivePromise(promise)
    if not promise:IsPending() then
        return promise
    end
    local newPromise = promise.resolved(promise)
    local id = self:GiveTask(newPromise)
    -- Ensure GC
    newPromise:Finally(function()
        self[id] = nil
    end)
    return newPromise
end
--]]

--- Cleans up all tasks
function Maid:Destroy()
    local tasks = self._tasks

    -- Clear out tasks table completely, even if cleaning up tasks adds more tasks to this maid
    local index, task = next(tasks)
    while task ~= nil do
        tasks[index] = nil
        _cleanupTask(task)
        index, task = next(tasks)
    end
end

---------------------------------------
-- Test
---------------------------------------
local function _test()
    do -- resursive tasks
        local m = Maid.New()
        local inner1, inner2
        m:GiveTask({
            Destroy = function()
                inner1 = true
                m.x = function()
                    inner2 = true
                end
            end
        })
        m:Destroy()
        assert(inner1)
        assert(inner2)
    end
    print("maid -- ok")
end
_test()

-- extra export: clean-up or destroy something with all nessesary checks
Maid.safeDestroy = _cleanupTask

-- alias to `Destroy`
Maid.Reset = Maid.Destroy

return Maid
