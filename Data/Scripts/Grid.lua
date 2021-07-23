---@diagnostic disable: undefined-field
--[[
    Grid coordinates:
    0 --> +y, +col
    |
    v
    -x, +row
]]

local CORE_ENV = CoreString and CoreMath
_ENV.require = _G.import or require

local abs, sqrt = math.abs, math.sqrt

local Maid = require("Maid")
local Deque = require("Deque")
local Bitarray = require("BitArray")

local Grid = {type = "Grid"}
Grid.__index = Grid

local Cell = {type="Cell"}
Cell.__index = Cell

local CELL_NIL, _cell_center_global do
    function Cell.New(row, col, posx, posy, actor)
        assert(not actor or type(actor) == "number")
        return setmetatable({
            row=row, col=col, posx=posx, posy=posy, actor = actor
        }, Cell)
    end

    CELL_NIL = Cell.New()
    _cell_center_global = CELL_NIL
end

function Cell.__tostring(c)
    if c == CELL_NIL then return "CELL_NIL" end
    local actor = c.actor and tostring(c.actor.id) or "()"
    return string.format(
        "Cell:{row: %d, col: %d, posx: %0.2f, posy: %0.2f, actor: %s}",
        c.row, c.col, c.posx, c.posy, actor)
end

function Cell:IsNil()
    return not self or self == CELL_NIL
end

function Cell:Unpack()
    if self ~= CELL_NIL then
        return self.row, self.col, self.actor and self.actor.id
    end
end

function Cell:ManhattanDistance(other)
    if self == CELL_NIL or other == CELL_NIL then return math.huge end
    return abs(self.row - other.row) + abs(self.col - other.col)
end

function Cell:Distance(other)
    if self == CELL_NIL or other == CELL_NIL then return math.huge end
    local dr, dc = self.row - other.row, self.col - other.col
    return sqrt(dr*dr + dc*dc)
end

function Cell:IsFree()
    return self ~= CELL_NIL and not self.actor
end

function Cell:Destroy()
    Maid.safeDestroy(self.tile)
    Maid.safeDestroy(self.actor)
end

local function idx2rc(idx, width)
    return (idx - 1)//width, (idx - 1)%width -- 0-idx
end

-- rc2idx :: r0, c0, w -> idx|-1
local function rc2idx(row0, col0, width)
    return row0 >= 0 and col0 >= 0 and col0 < width and row0*width + col0 + 1 or -1
end

-- TODO: factor out geometry: dims, transform etc.
-- empty :: [(r,c)]
function Grid.New(w, h, dimx, dimy)
    local _maid = Maid.New()
    local cells = {}
    for i = 1, w*h  do
        local row, col = idx2rc(i, w)
        local posx, posy = -row*dimx, col*dimy
        cells[i] = Cell.New(row, col, posx, posy)
        _maid:GiveTask(cells[i])
    end
    local self = setmetatable({_maid=_maid}, Grid)
    self.w, self.h, self.dimx, self.dimy, self.cells = w, h, dimx, dimy, cells
    -- add spatial extent
    -- local dimx, dimy = self.dimx, self.dimy
    -- local row = (-x + dimx/2)//dimx
    -- local col = (y + dimy/2)//dimy
    self.pos_x, self.neg_x = dimx/2, -dimx*h + dimx/2
    self.pos_y, self.neg_y = dimy*w - dimy/2, -dimy/2
    if CORE_ENV then
        self.worldToGrid = Transform.IDENTITY
    end
    return self
end

function Grid:Fold(binop, seed)
    assert(type(binop) == "function")
    local n = self.w*self.h
    for i=1, n do
        local cell = self.cells[i]
        if cell ~= CELL_NIL then
            seed = binop(seed, cell)
        end
    end
    return seed
end

function Grid:Search(predicate)
    local n = self.w*self.h
    for i=1, n do
        local cell = self.cells[i]
        if predicate(cell) then return cell end
    end
end


-- TODO: remove kruft from serialization, just use MP
local FOURCC = "GRID"
function Grid:serialize(exploded)
    local n = self.w*self.h
    -- first position reserved for protocol op-tag
    local out = {"", FOURCC, utf8.char(self.w, self.h, self.dimx, self.dimy), 'bitmap-placeholder'}
    local bitmap = Bitarray.new(n)
    for i = 1, n do
        local cell = self.cells[i]
        local hole = (cell == CELL_NIL)
        bitmap:set(i, not hole)
        if not hole and cell.actor and cell.actor.id  then
            out[#out+1] = utf8.char(cell.row, cell.col, cell.actor.id)
        end
    end
    assert(out[4] == 'bitmap-placeholder')
    out[4] = bitmap:serialize()
    return exploded and out or table.concat(out)
end

function Grid:__tostring()
    local out = {}
    out[#out+1] = string.format("width=%d height=%d dimx=%d dimy=%d\n", self.w, self.h, self.dimx, self.dimy)
    local rmax, cmax = self.h-1, self.w-1
    for row = 0, rmax do
        for col=1, cmax do
            local cell = self:at(row, col)
            if cell == CELL_NIL then
                out[#out+1] = "| |"
            elseif cell.actor then
                out[#out+1]=string.format("%.3d", cell.actor.id)
            else
                out[#out+1] = "[_]"
            end
            if col == cmax then
                out[#out+1] = "\n"
            end
        end
    end
    return table.concat(out)
end

function Grid.deserialize(s, from, to)
    from, to = from or 1, to or #s
    assert(string.sub(s, from, from + #FOURCC - 1) == FOURCC)
    from = from + #FOURCC
    local whi = utf8.offset(s, 4, from)
    local w, h, dimx, dimy = utf8.codepoint(s, from, whi)
    local bi = utf8.offset(s, 5, from)
    local bitmap
    bitmap, from = Bitarray.deserialize(s, bi)
    assert(bitmap:size() == w*h)
    local actors = {utf8.codepoint(s, from, to)}
    assert(#actors == 0 or #actors%3 == 0)
    local grid = Grid.New(w, h, dimx, dimy)
    for i=1, bitmap:size() do
        if not bitmap:get(i) then
            grid:MakeHole(i)
        end
    end
    for i = 1, #actors, 3 do
        local r, c, actor_id = actors[i], actors[i+1], actors[i+2]
        local cell = grid:at(r,c)
        cell.actor = {id=actor_id}
    end
    return grid
end

-- MakeHole :: self, idx | (row, col) ^-> self
function Grid:MakeHole(row, col)
    local idx = not col and row or rc2idx(row, col, self.w)
    assert(idx <= self.w*self.h)
    assert(not self.cells[idx].tile or not self.cells[idx].actor)
    self.cells[idx]:Destroy()
    self.cells[idx] = CELL_NIL
    return self
end

function Grid:Destroy()
    local n, cells = #self.cells, self.cells
    for i = n, 1, -1 do
        cells[i]:Destroy()
        cells[i] = CELL_NIL
    end
end

-- at :: self, idx | (row, col) -> Cell
function Grid:at(row, col)
    local idx = not col and row or rc2idx(row, col, self.w)
    return self.cells[idx] or CELL_NIL
end

function Grid:GetExtent()
    return {pos_x=self.pos_x, neg_x=self.neg_x, pos_y=self.pos_y, neg_y=self.neg_y}
end

function Grid:in_bounds(x, y)
    return x >= self.neg_x and x <= self.pos_x and y >= self.neg_y and y <= self.pos_y
end

-- world coordinates


if CORE_ENV then
    function Grid:GetCellAtPoint(vec3)
        if not vec3 then return CELL_NIL end
        local p = self.worldToGrid == Transform.IDENTITY
            and vec3
            or self.worldToGrid:TransformPosition(vec3)
        return self:GetCellAt(p.x, p.y)
    end
end

function Grid:GetCellAt(x, y)
    if self:in_bounds(x, y) then
        local dimx, dimy = self.dimx, self.dimy
        local row = (-x + dimx/2)//dimx
        local col = (y + dimy/2)//dimy
        if row < self.h and col < self.w then
            return self.cells[rc2idx(row, col, self.w)]
        end
    end
    return CELL_NIL
end
-- row, col, actor_id -> ok, local_cell, local_actor_id
function Grid:_move_precheck(row, col, actor_id)
    local loc = self:at(row, col)
    local loc_actor = loc.actor
    local loc_actor_id = loc_actor and loc_actor.id
    return (loc ~= CELL_NIL and loc_actor_id == actor_id), loc, loc_actor
end

function Grid:Move(dest, src, check)
    local dok, dloc, _ = self:_move_precheck(table.unpack(dest))
    local sok, sloc, sactor = self:_move_precheck(table.unpack(src))
    local ok = sok and dok
    if ok and not check then
        dloc.actor, sloc.actor = sactor, nil
    end
    return ok
end

function Grid:Swap(dest, src, check)
    local dok, dloc, dactor = self:_move_precheck(table.unpack(dest))
    local sok, sloc, sactor = self:_move_precheck(table.unpack(src))
    local ok = dok and sok and dactor and sactor
    if ok and not check then
        dloc.actor, sloc.actor = sactor, dactor
    end
    return ok
end

function Grid:Push(dest, src, empty, check)
    local dok, dloc, dactor = self:_move_precheck(table.unpack(dest))
    local sok, sloc, sactor = self:_move_precheck(table.unpack(src))
    local eok, eloc, eactor = self:_move_precheck(table.unpack(empty))
    local ok = dok and sok and eok and dactor and sactor and not eactor
    if ok and not check then
        dloc.actor, sloc.actor, eloc.actor = sactor, nil, dactor
    end
    return ok
end

function Grid:Merge3(dest, src, other, factory, check)
    local dok, dloc, dactor = self:_move_precheck(table.unpack(dest))
    local sok, sloc, sactor = self:_move_precheck(table.unpack(src))
    local ook, oloc, oactor = self:_move_precheck(table.unpack(other))
    local ok = dok and sok and ook and dactor and sactor and oactor and (dactor.id == sactor.id) and (dactor.id == oactor.id)
    if ok and not check then
        local new_actor = assert(factory())
        dloc.actor, sloc.actor, oloc.actor = new_actor, nil, nil
    end
    return ok
end

function Grid:Delete(src, check)
    assert(src, CoreDebug.GetStackTrace())
    local ok, sloc, _sactor = self:_move_precheck(table.unpack(src))
    if ok and not check then
        sloc.actor = nil
    end
    return ok
end

-- search_closest :: cell, predicate -> [cell], center excluded
do
    local function comparer(c1, c2)
        return _cell_center_global:ManhattanDistance(c1) < _cell_center_global:ManhattanDistance(c2)
    end
    function Grid:SearchClosest(center, predicate)
        local out, cells, n = {}, self.cells, self.w * self.h
        for i = 1, n do
            local c = cells[i]
            if c ~= center and predicate(c) then out[#out + 1] = c end
        end
        _cell_center_global = center
        table.sort(out, comparer)
        _cell_center_global = CELL_NIL
        return out
    end
end
-- BFS NOTE:
-- -- SearchClosest is faster for < 50 cells and uses 3x less memory - don't use BFS if you can
-- -- returns array + set of satisfied cells, excludes origin
do
    local SEARCH_PATTERN = {1, 0, -1, 0, 1} -- without diagonals
    local all = function() return true end
    function Grid:Bfs(origin, predicate, limit)
        predicate = predicate or all
        limit = limit and limit > 0 and limit or math.huge
        local q, visited = Deque.New(), {}
        q:Push(origin)
        while not q:Empty() do
            if #visited >= limit then break end
            local cell = q:Pop()
            local cr, cc = cell.row, cell.col
            for i = 1, 4 do
                local row, col = cr + SEARCH_PATTERN[i], cc + SEARCH_PATTERN[i+1]
                local next = self:at(row, col)
                if next ~= CELL_NIL and next ~= origin and not visited[next] and predicate(next) then
                    q:Push(next)
                    visited[next] = true
                    visited[#visited+1] = next -- add cell to array part (to return a result)
                end
            end
        end
        return visited
    end

    function Grid:Neighbor4(origin, predicate)
        predicate = predicate or all
        local r, c = origin.row, origin.col
        for i = 1, 4 do
            local row, col = r + SEARCH_PATTERN[i], c + SEARCH_PATTERN[i+1]
            local cell = self:at(row, col)
            if cell ~= CELL_NIL and cell ~= origin and predicate(cell) then
                return cell
            end
        end
    end

    function Grid:Neighbor44(origin, predicate)
        predicate = predicate or all
        local r, c = origin.row, origin.col
        for i = 1, 4 do
            local row, col = r + SEARCH_PATTERN[i], c + SEARCH_PATTERN[i+1]
            local cell = self:at(row, col)
            if cell ~= CELL_NIL and cell ~= origin and predicate(cell) then
                return cell
            end
        end
        return self:Neighbor8(origin, predicate)
    end

    function Grid:Neighbor8(origin, predicate)
        predicate = predicate or all
        local r, c = origin.row, origin.col
        for dr = -1, 1 do
            for dc = -1, 1 do
                local cell = self:at(r + dr, c + dc)
                if cell ~= CELL_NIL and cell ~= origin and predicate(cell) then
                    return cell
                end
            end
        end
    end
end

if CORE_ENV then
    function Grid:SetWorldToGridTransform(tr)
        self.worldToGrid = tr
    end
end

local function _test()

    local g0 = Grid.New(7, 5, 100,100)
    local c30 = g0:GetCellAt(-300, -10)
    assert(c30.row == 3 and c30.col == 0)
    assert(rc2idx(2,7,7) == -1)

    -- g1
    local W, H, DimX, DimY = 5, 4, 50, 100
    local g1 = Grid.New(W, H, DimX, DimY)
    assert(#g1.cells == W*H)
    assert(g1:at(1) == g1:at(0,0))
    assert(g1:at(W*H) == g1:at(H-1, W-1))
    local c00 = g1:GetCellAt(0, 0)
    assert(c00.row == 0 and c00.col == 0)
    local c34 = g1:GetCellAt(-(H-1)*g1.dimx, (W-1)*g1.dimy)
    assert(c34.row == 3 and c34.col == 4)
    local c32 = g1:GetCellAt(-149.999, 199.999)
    assert(c32.row == 3 and c32.col == 2)

    if CORE_ENV then
        local tr = Transform.IDENTITY
        tr:SetPosition(Vector3.New(200, 200, 0))
        local wtr =tr:GetInverse()
        g1:SetWorldToGridTransform(wtr)
        local c31 = g1:GetCellAtPoint(Vector3.New(49.999, 299.999, 0))
        assert(c31.row == 3 and c31.col == 1)
    end
    -- search
    local center = g1:at(0,0)
    local ce = g1:SearchClosest(center, function(c) return c.row % 2 == 0 and c.col %2 == 0 end)
    assert(#ce == 5 and ce[1] == g1:at(0,2))
    assert(ce[2] == g1:at(2,0))
    assert(ce[3] == g1:at(2,2))
    assert(ce[4] == g1:at(0,4))
    assert(ce[5] == g1:at(2,4))

    -- bfs
    local g2 = Grid.New(10, 10, 100, 100)
    center = g2:at(0,0)
    g2:at(0,1).actor={id=12}
    g2:at(0,2).actor={id=12}
    g2:at(1,2).actor={id=730}
    g2:at(2,2).actor={id=730}
    g2:at(2,3).actor={id=0}
    g2:MakeHole(1, 1)
        :MakeHole(0, 3)
        :MakeHole(1, 0)

    local cells = g2:Bfs(center, function(c) return c.actor end)
    assert(#cells == 5)
    assert(not cells[center])
    cells = g2:Bfs(center, function(c) return c.actor end, 3)
    assert(#cells == 3)

    local g2s = g2:serialize()
    local g21 = Grid.deserialize(g2s)
    assert(g21:at(0,1).actor.id==12)
    assert(g21:at(0,2).actor.id==12)
    assert(g21:at(1,2).actor.id==730)
    assert(g21:at(2,2).actor.id==730)
    assert(g21:at(2,3).actor.id==0)


    local g3 = Grid.New(10, 10, 100, 100)
    local r, c = 2, 3
    for dr = -1, 1 do
        for dc = -1, 1 do
            local d = g3:at(r, c):Distance(g3:at(r+dr, c+dc))
            assert(d < 2)
            local md = g3:at(r, c):ManhattanDistance(g3:at(r+dr, c+dc))
            assert(md <= 2)
        end
    end

    print("grid -- ok")

end
_test()

return Grid