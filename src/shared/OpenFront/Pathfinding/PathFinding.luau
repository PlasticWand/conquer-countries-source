--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/{PathFinder,PathFinderStepper,types}.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The water pathfinding chain ships use, and the stepper that walks a cached
-- path one tile per call.
--   - Chain: MiniMap(ShoreCoercing(Smoothing(ComponentCheck(hierarchical))));
--     the plain A* is used when the graph has under 100 nodes.
--   - One chain per game, rebuilt when the water graph version changes.
--   - Trade ships use a memo in front of it.
--   - WaterPathFinder staggers its switch to a new graph per ship, as the
--     original does.

local AStarWater = require(script.Parent.AStarWater)
local Transformers = require(script.Parent.Transformers)

local PseudoRandom = require(script.Parent.Parent.PseudoRandom)

local PathFinding = {}

-- types.ts PathStatus
local PathStatus = table.freeze({ NEXT = 0, COMPLETE = 2, NOT_FOUND = 3 })
PathFinding.PathStatus = PathStatus

export type PathResult = { status: number, node: number? }

-- PathFinderStepper -----------------------------------------------------------------

local Stepper = {}
Stepper.__index = Stepper
PathFinding.Stepper = Stepper

export type Stepper = typeof(setmetatable(
	{} :: {
		finder: any,
		game: any,
		path: { number }?,
		pathIndex: number, -- 0-based, as in the original
		lastTo: number?,
		plain: boolean,
	},
	Stepper
))

-- tileStepperConfig: equality on refs, Manhattan distance, invalid refs fail.
-- `plain` is the bare { equals } config (PathFinding.Air): no checks, no
-- distance exit.
function Stepper.new(finder: any, game: any, plain: boolean?): Stepper
	return setmetatable({ finder = finder, game = game, path = nil, pathIndex = 0, lastTo = nil, plain = plain == true }, Stepper)
end

function Stepper._preCheck(self: Stepper, from: number, to: number): PathResult?
	if self.plain then
		return nil
	end
	if not self.game:isValidRef(from) or not self.game:isValidRef(to) then
		return { status = PathStatus.NOT_FOUND }
	end
	return nil
end

function Stepper.next(self: Stepper, from: number, to: number, dist: number?): PathResult
	local pre = self:_preCheck(from, to)
	if pre then
		return pre
	end
	if from == to then
		return { status = PathStatus.COMPLETE, node = to }
	end
	if dist ~= nil and dist > 0 and not self.plain and self.game:manhattanDist(from, to) <= dist then
		return { status = PathStatus.COMPLETE, node = from }
	end
	if self.lastTo == nil or self.lastTo ~= to then
		self.path = nil
		self.pathIndex = 0
		self.lastTo = to
	end
	if self.path == nil then
		local ok, path = pcall(function()
			return self.finder:findPath(from, to)
		end)
		if not ok or path == nil then
			return { status = PathStatus.NOT_FOUND }
		end
		self.path = path
		self.pathIndex = 0
		if #path > 0 and path[1] == from then
			self.pathIndex = 1
		end
	end
	local path = self.path :: { number }
	if self.pathIndex > 0 and from ~= path[self.pathIndex] then
		self:invalidate()
		self.lastTo = to
		return self:next(from, to, dist)
	end
	if self.pathIndex >= #path then
		return { status = PathStatus.COMPLETE, node = to }
	end
	local nextNode = path[self.pathIndex + 1]
	self.pathIndex += 1
	return { status = PathStatus.NEXT, node = nextNode }
end

function Stepper.invalidate(self: Stepper)
	self.path = nil
	self.pathIndex = 0
	self.lastTo = nil
end

-- The active path from the node most recently returned by next().
function Stepper.pathAfterNext(self: Stepper): { number }?
	local path = self.path
	if path == nil or self.pathIndex == 0 then
		return nil
	end
	return table.move(path, self.pathIndex, #path, 1, {})
end

-- A one-shot route that leaves the cached one alone.
function Stepper.findPath(self: Stepper, from: number | { number }, to: number): { number }?
	local list: { number } = if type(from) == "number" then { from } else from :: { number }
	local allFailed = true
	for _, f in list do
		local r = self:_preCheck(f, to)
		if not (r and r.status == PathStatus.NOT_FOUND) then
			allFailed = false
			break
		end
	end
	if allFailed then
		return nil
	end
	return self.finder:findPath(from, to)
end

-- PathFinder.Air.ts AirPathFinder ----------------------------------------------------
-- Straight-ish flight for shells and SAM missiles: each step moves one tile
-- in x or y, choosing x with chance 1/ratio. Re-seeded with the creation
-- tick on every query, so a path is a pure function of (seed, from, to).

local AirPathFinder = {}
AirPathFinder.__index = AirPathFinder

function AirPathFinder.new(game: any): any
	return setmetatable({ game = game, seed = game:ticks() }, AirPathFinder)
end

function AirPathFinder.findPath(self: any, from: number, to: number): { number }
	local random = PseudoRandom.new(self.seed)
	local path = { from }
	local current = from
	while current ~= to do
		local nextTile = self:_computeNext(current, to, random)
		if nextTile == current then
			break
		end
		current = nextTile
		table.insert(path, current)
	end
	return path
end

function AirPathFinder._computeNext(self: any, from: number, to: number, random: any): number
	local game = self.game
	local x, y = game:x(from), game:y(from)
	local dstX, dstY = game:x(to), game:y(to)
	if x == dstX and y == dstY then
		return to
	end
	local nextX, nextY = x, y
	local ratio = math.floor(1 + math.abs(dstY - y) / (math.abs(dstX - x) + 1))
	if x == dstX then
		nextY += if y < dstY then 1 else -1
	elseif y == dstY then
		nextX += if x < dstX then 1 else -1
	elseif random:chance(ratio) then
		nextX += if x < dstX then 1 else -1
	else
		nextY += if y < dstY then 1 else -1
	end
	return game:ref(nextX, nextY)
end

PathFinding.AirPathFinder = AirPathFinder

function PathFinding.Air(game: any): Stepper
	return Stepper.new(AirPathFinder.new(game), game, true)
end

-- The shared chain -----------------------------------------------------------------

local function buildWaterChain(game: any): any
	local hpa = game:miniWaterHPA()
	local graph = game:miniWaterGraph()
	local miniMap = game:miniMap()
	if hpa == nil or graph == nil or graph.nodeCount < 100 then
		local simple: any = AStarWater.new(miniMap)
		return Transformers.MiniMap.new(Transformers.ShoreCoercing.new(simple, miniMap), game:map(), miniMap)
	end
	local chain: any = Transformers.ComponentCheck.new(hpa, function(t: number): number
		return graph:getComponentId(t)
	end)
	chain = Transformers.Smoothing.new(chain, miniMap)
	chain = Transformers.ShoreCoercing.new(chain, miniMap)
	return Transformers.MiniMap.new(chain, game:map(), miniMap)
end

-- WaterPathMemo: (from, to) answers for one water graph. Every query of a
-- graph version gives the same answer, so this only saves time. Bounded by
-- entry count instead of bytes; evicts the oldest entry.
local MEMO_MAX_ENTRIES = 4096

local function newMemo(chain: any, numTiles: number, game: any): any
	local memo = {
		paths = {} :: { [number]: { number } | false },
		order = {} :: { number },
		waterVersion = game:map():waterVersion(),
	}
	function memo.findPath(_self: any, from: number | { number }, to: number): { number }?
		local wv = game:map():waterVersion()
		if wv ~= memo.waterVersion then
			memo.waterVersion = wv
			memo.paths = {}
			memo.order = {}
		end
		if type(from) ~= "number" then
			return chain:findPath(from, to)
		end
		local key = (from :: number) * numTiles + to
		local hit = memo.paths[key]
		if hit ~= nil then
			return if hit == false then nil else table.clone(hit :: { number })
		end
		local path = chain:findPath(from, to)
		memo.paths[key] = if path == nil then false else table.clone(path)
		table.insert(memo.order, key)
		if #memo.order > MEMO_MAX_ENTRIES then
			local oldest = table.remove(memo.order, 1) :: number
			memo.paths[oldest] = nil
		end
		return path
	end
	return memo
end

function PathFinding.sharedWaterChain(game: any, memoized: boolean?): any
	local version = game:waterGraphVersion()
	local cached = game._waterChainCache
	if cached == nil or cached.version ~= version then
		local chain = buildWaterChain(game)
		cached = {
			version = version,
			chain = chain,
			memo = newMemo(chain, game:map():width() * game:map():height(), game),
		}
		game._waterChainCache = cached
	end
	return if memoized then cached.memo else cached.chain
end

-- WaterPathFinder ------------------------------------------------------------------

local WaterPathFinder = {}
WaterPathFinder.__index = WaterPathFinder
PathFinding.WaterPathFinder = WaterPathFinder
WaterPathFinder.STAGGER_SPREAD = 50

export type WaterPathFinder = typeof(setmetatable(
	{} :: {
		game: any,
		stagger: number,
		memoized: boolean,
		stepper: Stepper,
		waterGraphVersion: number,
		rebuiltFlag: boolean,
		staggerCountdown: number,
		pendingVersion: number,
	},
	WaterPathFinder
))

-- `stagger`: ticks to wait before switching to a rebuilt water graph.
function WaterPathFinder.new(game: any, stagger: number?, memoized: boolean?): WaterPathFinder
	return setmetatable({
		game = game,
		stagger = stagger or 0,
		memoized = memoized == true,
		stepper = Stepper.new(PathFinding.sharedWaterChain(game, memoized), game),
		waterGraphVersion = game:waterGraphVersion(),
		rebuiltFlag = false,
		staggerCountdown = 0,
		pendingVersion = -1,
	}, WaterPathFinder)
end

function WaterPathFinder._ensureFresh(self: WaterPathFinder)
	local v = self.game:waterGraphVersion()
	if v == self.waterGraphVersion then
		return
	end
	if self.pendingVersion ~= v then
		self.pendingVersion = v
		self.staggerCountdown = self.stagger
	end
	if self.staggerCountdown > 0 then
		self.staggerCountdown -= 1
		return
	end
	self.waterGraphVersion = v
	self.stepper = Stepper.new(PathFinding.sharedWaterChain(self.game, self.memoized), self.game)
	self.rebuiltFlag = true
end

-- True if rebuilt since the last read (resets on read).
function WaterPathFinder.rebuilt(self: WaterPathFinder): boolean
	self:_ensureFresh()
	local v = self.rebuiltFlag
	self.rebuiltFlag = false
	return v
end

function WaterPathFinder.next(self: WaterPathFinder, from: number, to: number, dist: number?): PathResult
	self:_ensureFresh()
	return self.stepper:next(from, to, dist)
end

function WaterPathFinder.findPath(self: WaterPathFinder, from: number | { number }, to: number): { number }?
	self:_ensureFresh()
	return self.stepper:findPath(from, to)
end

-- The route after a successful next(), starting at `from`.
function WaterPathFinder.pathForTraversal(self: WaterPathFinder, from: number, to: number): { number }
	self:_ensureFresh()
	local path = self.stepper:pathAfterNext() or self.stepper:findPath(from, to)
	if path == nil or #path == 0 then
		return { from }
	end
	if path[1] == from then
		return path
	end
	local out = { from }
	table.move(path, 1, #path, 2, out)
	return out
end

function WaterPathFinder.invalidate(self: WaterPathFinder)
	self.stepper:invalidate()
end

return PathFinding
