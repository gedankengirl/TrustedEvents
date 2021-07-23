_ENV.require = _G.import or require
-- TODO:
-- Implementation notes:
-- * Number of actions isn't limted but we preallocate some space.
-- * Worldstate and Context are 32-bit bitsets, i.e. MAX_ATOMS (lua, bit32 lib) should to be 32.
-- * There is not precedence - only cost.
-- * Context - preconditions that the planner will never try to satisfy,
--   used for pruning actions (validate context preconditions) from possible transitions.

local DEBUG = false
local VERBOSE = true

local CORE_ENV = CoreDebug and true

-- assume Lua supports uint64
local INTBITS = math.floor(math.log(math.maxinteger, 2) + 0.5) + 1
assert(INTBITS == 64)

local perfn = require("Snippets").perfn

local mtype = math.type
local type = type
local tconcat = table.concat
local assert = assert
local print = print
local setmetatable = setmetatable
local pairs = pairs
local format = string.format
local concat = table.concat
local NOOP = function() end

local dtrace = DEBUG and print or NOOP
local vtrace = VERBOSE and DEBUG and print or NOOP

---------------------------------------
-- Constants
---------------------------------------
local HUGE = math.huge
local K_MAX_ATOMS = 32
local K_DEFAULT_COST = 1

_ENV = nil

-- for debugging, bit order 0 .. 63
local function bitstr(val, width, sep, ngroup)
    assert(mtype(val) == "integer")
    width = width or 64
    assert(width > 0 and width <= 64)
    sep = sep or "\n"
    ngroup = ngroup or 32
    local out = {}
    local group = ""
    for i = 0, width - 1 do
        local b = val & (1 << i) ~= 0 and "1" or "0"
        if #group < ngroup then
            group = group .. b
        else
            out[#out + 1] = group
            group = b
        end
    end
    out[#out + 1] = group
    return tconcat(out, sep)
end

-- _array_swap_remove: remove and swap with last element of array, O(1) and 10x faster then table.remove
local function array_swap_remove(arr, idx)
    local n = #arr
    local val = arr[idx]
    arr[idx] = arr[n]
    arr[n] = nil
    return val
end

local function array_clean(arr, clean)
    for i = 1, #arr do
        arr[i] = clean(arr[i])
    end
    return arr
end

-- in-place array reverce
local function array_reverse(ar)
    if not ar then return end
    local n = #ar
    for i = 1, n//2 do
        ar[i], ar[n - i + 1] = ar[n - i + 1], ar[i]
    end
end

local function popcount32(x)
    x = x - ((x >> 1) & 0x55555555)
    x = (x & 0x33333333) + ((x >> 2) & 0x33333333)
    x = (x + (x >> 4)) & 0x0F0F0F0F
    return ((x * 0x01010101) & 0xFFFFFFFF) >> 24
end

---------------------------------------
-- World State
---------------------------------------
-- World state is a 64-bit integer with lower 32bit - VALUE, and upper 32bit - DONTCARE
local WS_MASK = 0xffffffff
local WS_CLEAR = 0xffffffff00000000

-- unused (inlined)
local function ws_create(value, dontcare)
    return value | dontcare << 32
end

-- unused (inlined)
local function ws_value(ws)
    return ws & WS_MASK
end

-- unused (inlined)
local function ws_care(ws)
    return (ws >> 32) ~ WS_MASK
end

local function ws_set_bit(ws, idx, bool)
    assert(idx > 0 and idx <= 32)
    local bit = idx - 1
    local dc_bit = bit + 32
    ws = bool and ws | (1 << bit) or ws & ~(1 << bit)
    ws = ws & ~(1 << dc_bit)
    return ws
end

local function ws_get_bit(ws, idx)
    assert(idx > 0 and idx <= 32)
    local bit = idx - 1
    local dc_bit = bit + 32
    return ws & (1 << bit) ~= 0, ws & (1 << dc_bit) ~= 0
end

---------------------------------------
-- AStar
---------------------------------------
local WS, PARENT_WS, G, H, F, ACTION = 1, 2, 3, 4, 5, 6
local AS_NODE_POOL = {}
local function as_node_obtain()
    local as_node
    if #AS_NODE_POOL == 0 then
        as_node = {false, false, false, false, false, false}
    else
        as_node = AS_NODE_POOL[#AS_NODE_POOL]
        AS_NODE_POOL[#AS_NODE_POOL] = nil
    end
    return as_node
end

local function as_node_release(as_node)
    assert(as_node)
    as_node[ACTION] = false
    AS_NODE_POOL[#AS_NODE_POOL + 1] = as_node
end

-- AStar sets
local S_OPEN = {}
local S_CLOSED = {}

local function as_storage_cleanup()
    array_clean(S_OPEN, as_node_release)
    array_clean(S_CLOSED, as_node_release)
end

local function as_idx_in(set, ws)
    local values = ws & WS_MASK
    for i = 1, #set do
        if set[i][WS] & WS_MASK == values then
            return i
        end
    end
    return false
end

local function as_reconstruct_plan(goal_node, out_plan, out_debug_ws)
    -- clean-up scratches
    local cursor = goal_node
    local steps = 0
    while cursor and cursor[ACTION] do
        steps = steps + 1
        out_plan[steps] = cursor[ACTION]
        if out_debug_ws then
            out_debug_ws[steps] = cursor[WS]
        end
        local idx_c = as_idx_in(S_CLOSED, cursor[PARENT_WS])
        cursor = idx_c and S_CLOSED[idx_c]
    end
    array_reverse(out_plan)
    array_reverse(out_debug_ws)
    return out_plan, out_debug_ws
end

-- pretty common GOAP heuristic: minimize the number of state differences
local function as_heuristic(from, to)
    local care = (to >> 32) ~ WS_MASK
    local diff = (from & care) ~ (to & care)
    return popcount32(diff)
end

---------------------------------------
-- Planner
---------------------------------------
local GOAPPlanner = {type = "GOAPPlanner"}
GOAPPlanner.__index = GOAPPlanner

function GOAPPlanner.New(id)
    return setmetatable({
        id = id or GOAPPlanner.type,
        context_names = {},
        context_names_idx = {},
        atoms = {},
        atoms_idx = {},
        action_names = {},
        action_names_idx = {},
        action_costs = {},
        action_preconditions = {},
        action_effects = {},
        action_contexts = {}
    }, GOAPPlanner)
end

---------------------------------------
-- Plan
---------------------------------------
-- scratch arrays
local s_out_actions = {} -- index array
local s_out_costs = {}
local s_out_to = {}

function GOAPPlanner:get_possible_state_transitions(context, ws_from)
    local pre = self.action_preconditions
    local actions = self.action_names
    local costs = self.action_costs
    local effects = self.action_effects
    -- clear scratch array
    for i = #s_out_actions, 1, -1 do
        s_out_actions[i] = nil
    end
    for i = 1, #actions do
        -- context pruning
        local act_ctx = self.action_contexts[i]
        local care_ctx = (act_ctx >> 32) ~ WS_MASK
        if care_ctx ~= 0 and (act_ctx & care_ctx) ~= (context & care_ctx) then
            goto continue
        end
        -- preconditions
        local act_pre = pre[i]
        local care_pre = (act_pre >> 32) ~ WS_MASK
        local met = (act_pre & care_pre) == (ws_from & care_pre)
        if met then
            s_out_actions[#s_out_actions + 1] = actions[i]
            local idx = #s_out_actions
            s_out_costs[idx] = costs[i]
            -- apply effect
            local effect = effects[i]
            local unaffected = effect >> 32
            local affected = (effect >> 32) ~ WS_MASK
            local value = (ws_from & unaffected) | (effect & affected)
            local dont = (ws_from >> 32) & unaffected
            s_out_to[idx] = value | dont << 32
        end
        ::continue::
    end
    return #s_out_actions
end

-- @Plan :: self, start, goal, context -> true, plan, cost[, debug_ws_out] | false, reason
function GOAPPlanner:Plan(start, goal, context, out_plan, out_debug_ws)
    assert(mtype(start) == "integer")
    assert(mtype(goal) == "integer")
    assert(mtype(context) == "integer")
    out_plan = out_plan or {}
    assert(type(out_plan) == "table" and #out_plan == 0, "'out_plan' should be empty table")
    as_storage_cleanup()
    local n0 = as_node_obtain()
    n0[WS] = start
    n0[PARENT_WS] = start
    n0[G] = 0
    n0[H] = as_heuristic(start, goal)
    n0[F] = n0[G] + n0[H]
    n0[ACTION] = false
    S_OPEN[#S_OPEN + 1] = n0
    local care = (goal >> 32) ~ WS_MASK
    local goal_bits = goal & care
    while true do
        if #S_OPEN == 0 then
            return false, "didn't find a path"
        end
        local lowest_idx = 0
        local lowest_f = HUGE
        for i = 1, #S_OPEN do
            local f = S_OPEN[i][F]
            if f < lowest_f then
                lowest_f = f
                lowest_idx = i
            end
        end
        local cur_node = array_swap_remove(S_OPEN, lowest_idx)
        if goal_bits == cur_node[WS] & care then
            local plan, debug_ws_out = as_reconstruct_plan(cur_node, out_plan, out_debug_ws)
            local cost = cur_node[G]
            as_node_release(cur_node)
            return true, plan, cost, debug_ws_out
        end
        S_CLOSED[#S_CLOSED + 1] = cur_node
        -- here we fill stratch out arrays
        local n_transitions = self:get_possible_state_transitions(context, cur_node[WS])
        for i = 1, n_transitions do
            local transition_cost = cur_node[G] + s_out_costs[i]
            local to = s_out_to[i]
            local idx_open = as_idx_in(S_OPEN, to)
            local idx_close = as_idx_in(S_CLOSED, to)
            if idx_open and transition_cost < S_OPEN[idx_open][G] then
                as_node_release(array_swap_remove(S_OPEN, idx_open))
                idx_open = false
            end
            if idx_close and transition_cost < S_CLOSED[idx_close][G] then
                as_node_release(array_swap_remove(S_CLOSED, idx_close))
                idx_close = false
            end
            if not idx_open and not idx_close then
                local nb = as_node_obtain()
                nb[WS] = to
                nb[PARENT_WS] = cur_node[WS]
                nb[G] = transition_cost
                nb[H] = as_heuristic(nb[WS], goal)
                nb[F] = nb[G] + nb[H]
                nb[ACTION] = s_out_actions[i]
                S_OPEN[#S_OPEN + 1] = nb
            end
        end
    end
end

function GOAPPlanner:idx_for_atom(atom)
    local idx = self.atoms_idx[atom]
    if not idx then
        local atoms = self.atoms
        atoms[#atoms + 1] = atom
        idx = #atoms
        assert(idx <= K_MAX_ATOMS)
        self.atoms_idx[atom] = idx
    end
    return idx
end

function GOAPPlanner:idx_for_context_name(ctx_name)
    local idx = self.context_names_idx[ctx_name]
    if not idx then
        self.context_names[#self.context_names + 1] = ctx_name
        idx = #self.context_names
        assert(idx <= K_MAX_ATOMS)
        self.context_names_idx[ctx_name] = idx
    end
    return idx
end

function GOAPPlanner:idx_for_action_name(action_name)
    local idx = self.action_names_idx[action_name]
    if not idx then
        self.action_names[#self.action_names + 1] = action_name
        idx = #self.action_names
        self.action_names_idx[action_name] = idx
        self.action_costs[idx] = K_DEFAULT_COST
        self.action_preconditions[idx] = WS_CLEAR
        self.action_effects[idx] = WS_CLEAR
        self.action_contexts[idx] = WS_CLEAR
    end
    return idx
end

function GOAPPlanner:SetActionPrecondition(action_name, atom, bool)
    local actidx = self:idx_for_action_name(action_name)
    local idx = self:idx_for_atom(atom)
    self.action_preconditions[actidx] = ws_set_bit(self.action_preconditions[actidx], idx, bool)
    return self
end

function GOAPPlanner:SetActionEffect(action_name, atom, bool)
    local actidx = self:idx_for_action_name(action_name)
    local idx = self:idx_for_atom(atom)
    self.action_effects[actidx] = ws_set_bit(self.action_effects[actidx], idx, bool)
    return self
end

function GOAPPlanner:SetActionContext(action_name, ctx_name, bool)
    local actidx = self:idx_for_action_name(action_name)
    local idx = self:idx_for_context_name(ctx_name)
    self.action_contexts[actidx] = ws_set_bit(self.action_contexts[actidx], idx, bool)
    return self
end

-- -- NOTE: instead of using precedence field we adjust a small (0.001) fraction of the cost
function GOAPPlanner:SetActionCost(action_name, cost, precedence)
    cost = (cost or K_DEFAULT_COST) + (precedence or 0) * 0.001
    local action_idx = self:idx_for_action_name(action_name)
    self.action_costs[action_idx] = cost
    return self
end

--[[ GOAP SetActions Schema
-- @ SetActions :: self, data ^-> self
data :: {action_name = settings}
settings :: {
  cost? = number,
  precedence? = number,
  precondition? = {atom = bool},
  effect? = {atom = bool},
  context? = {ctx_name = bool}
}
--]]
function GOAPPlanner:SetActions(data)
    assert(type(data) == "table")
    for action_name, settings in pairs(data) do
        self:SetActionCost(action_name, settings.cost, settings.precedence)
        if settings.precondition then
            for atom, bool in pairs(settings.precondition) do
                self:SetActionPrecondition(action_name, atom, bool)
            end
        end
        if settings.effect then
            for atom, bool in pairs(settings.effect) do
                self:SetActionEffect(action_name, atom, bool)
            end
        end
        if settings.context then
            for ctx, bool in pairs(settings.context) do
                self:SetActionContext(action_name, ctx, bool)
            end
        end
    end
    return self
end

function GOAPPlanner:ws_to_string(ws)
    local out = {}
    for i = 1, #self.atoms do
        local atom = self.atoms[i]
        local value, _ = ws_get_bit(ws, i)
        out[#out + 1] = value and atom:upper() or atom
    end
    return concat(out, '|')
end

function GOAPPlanner:ctx_to_string(ws)
    local out = {}
    for i = 1, #self.context_names do
        local atom = self.context_names[i]
        local value, _ = ws_get_bit(ws, i)
        out[#out + 1] = value and atom:upper() or atom
    end
    return concat(out, '|')
end


function GOAPPlanner:__tostring()
    local out = {self.id}
    for idx = 1, #self.action_names do
        local action, cost = self.action_names[idx], self.action_costs[idx]
        out[#out + 1] = format("%.2d: %s (cost: %5.2f)", idx, action, cost)
        local pre = self.action_preconditions[idx]
        local eff = self.action_effects[idx]
        local ctx = self.action_contexts[idx]
        if self.action_contexts[idx] ~= WS_CLEAR then
            out[#out + 1] = "  * context:"
            for i = 1, #self.context_names do
                local val, dont = ws_get_bit(ctx, i)
                if not dont then
                    out[#out + 1] = format("\t%s <> %s", self.context_names[i], val)
                end
            end
        end
        out[#out + 1] = "  * preconditions:"
        for i = 1, #self.atoms do
            local val, dont = ws_get_bit(pre, i)
            if not dont then
                out[#out + 1] = format("\t%s == %s", self.atoms[i], val)
            end
        end
        out[#out + 1] = "  * effects:"
        for i = 1, #self.atoms do
            local val, dont = ws_get_bit(eff, i)
            if not dont then
                out[#out + 1] = format("\t%s <- %s", self.atoms[i], val)
            end
        end
    end
    return concat(out, "\n")
end

---------------------------------------
-- Actor GOAP State
---------------------------------------
local GOAPState = {type = "GOAPState"}
GOAPState.__index = GOAPState
function GOAPState.New(planner, id)
    id = id or ""
    assert(type(planner) == "table" and planner.type == GOAPPlanner.type)
    return setmetatable({
        id = planner.id .. id,
        world_state = WS_CLEAR,
        context = WS_CLEAR,
        goal = WS_CLEAR,
        planner = planner
    }, GOAPState)
end

function GOAPState:__tostring()
    local out = {self.id}
    out[#out + 1] = self.planner:ws_to_string(self.world_state)
    out[#out + 1] = self.planner:ws_to_string(self.goal)
    out[#out + 1] = self.planner:ctx_to_string(self.context)
    return concat(out, '\n')
end

-- @ GetPlan :: self[, out_plan][ ,out_debug_ws] -> true, out_plan, cost, out_debug_ws | false, reason
function GOAPState:GetPlan(out_plan, out_debug_ws)
    return self.planner:Plan(self.world_state, self.goal, self.context, out_plan, out_debug_ws)
end

function GOAPState:SetWorldState(atom, bool)
    local idx = self.planner:idx_for_atom(atom)
    self.world_state = ws_set_bit(self.world_state, idx, bool)
    return self
end

function GOAPState:SetGoal(atom, bool)
    local idx = self.planner:idx_for_atom(atom)
    self.goal = ws_set_bit(self.goal, idx, bool)
    return self
end

function GOAPState:SetWorldContext(ctx_name, bool)
    local idx = self.planner:idx_for_context_name(ctx_name)
    self.context = ws_set_bit(self.context, idx, bool)
    return self
end

---------------------------------------
-- Tests
---------------------------------------
local function test_bits()
    assert(bitstr(WS_CLEAR, 64, "") == "0000000000000000000000000000000011111111111111111111111111111111")
    assert(bitstr(ws_value(WS_CLEAR), 32, "") == "00000000000000000000000000000000")
    assert(bitstr(WS_CLEAR >> 32, 32, "") == "11111111111111111111111111111111")
    assert(popcount32(WS_CLEAR >> 32) == 32)

    local ws = WS_CLEAR
    ws = ws_set_bit(ws, 1, true)
    ws = ws_set_bit(ws, 3, true)
    assert(bitstr(ws, 3) == "101")
    local care = (ws >> 32) ~ WS_MASK
    assert(bitstr(care, 3) == "101")
    local act = ws_set_bit(WS_CLEAR, 1, true)
    act = ws_set_bit(act, 2, false)
    assert(bitstr(act, 3) == "100")
    assert(bitstr(ws & care, 3) == "101")
    assert(bitstr(act & care, 3) == "100")
    assert(bitstr((ws & care) ~ (act & care), 3) == "001")
    assert(ws_create(0, -1) == WS_CLEAR)

    print("  test_bits -- ok")
end

local function test_planner()
    local planner = GOAPPlanner.New("== Grunt")
    planner:SetActions{
        scout = {precondition = {armedwithgun = true}, effect = {enemyvisible = true}},
        aim = {
            precondition = {enemyvisible = true, weaponloaded = true},
            effect = {enemylinedup = true}
        },
        shoot = {precondition = {enemylinedup = true}, effect = {enemyalive = false}},
        load = {precondition = {armedwithgun = true}, effect = {weaponloaded = true}},
        detonatebomb = {
            cost = 1,
            precondition = {armedwithbomb = true, nearenemy = true},
            effect = {alive = false, enemyalive = false, armedwithbomb = false}
        },
        flee = {precondition = {enemyvisible = true}, effect = {nearenemy = false}},
        approach = {
            precedence = 50,
            precondition = {enemyvisible = true},
            effect = {nearenemy = true}},
        darkjump = {
            precedence = 10,
            precondition = {enemyvisible = true},
            effect = {nearenemy = true},
            context = {night = true}
        }
    }
    vtrace(planner)

    local grunt1 = GOAPState.New(planner)
    grunt1
        :SetWorldState("enemyvisible", false)
        :SetWorldState("armedwithgun", true)
        :SetWorldState("weaponloaded", false)
        :SetWorldState("enemylinedup", false)
        :SetWorldState("enemyalive", true)
        :SetWorldState("armedwithbomb", true)
        :SetWorldState("nearenemy", false)
        :SetWorldState("alive", true)
        -- ctx
        :SetWorldContext("night", false)
        -- goal
        :SetGoal("enemyalive", false)

    local function dump_plan(ok, plan, cost, dout)
        if not ok then return plan or "no plan" end
        local out = {}
        for i = 1, #plan do
            out[#out + 1] = format("%d: %s", i, plan[i])
            if dout then
                out[#out + 1] = format(planner:ws_to_string(dout[i]))
            end
        end
        return concat(out, "\n")
    end

    dtrace("context:", planner:ctx_to_string(grunt1.context))
    dtrace(dump_plan(grunt1:GetPlan()))
    assert(grunt1:GetPlan())

    dtrace("--- make it night ---")
    dtrace("context:", planner:ctx_to_string(grunt1.context))
    grunt1:SetWorldContext("night", true)
    dtrace(dump_plan(grunt1:GetPlan()))
    assert(grunt1:GetPlan())

    dtrace("--- discriminate bomb ---")
    dtrace("context:", planner:ctx_to_string(grunt1.context))
    planner:SetActionCost("detonatebomb", 5)
    dtrace(dump_plan(grunt1:GetPlan({}, {})))
    assert(grunt1:GetPlan())

    if not CORE_ENV then
        local out_plan = {}
        perfn("perf", 1000, function()
            local ok, plan, cost, dout = grunt1:GetPlan(out_plan)
            array_clean(out_plan, NOOP)
        end)
    end
    print("  test_planner -- ok")
end


local function self_test()
    print("[GOAP]")
    test_bits()
    test_planner()
end
self_test()

return GOAPPlanner
