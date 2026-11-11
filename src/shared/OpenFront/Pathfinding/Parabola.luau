--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/PathFinder.Parabola.ts and utilities/Line.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Missile flight paths: a cubic Bezier arc from launch to target, sampled
-- at fixed spacing in 8-bit fixed point so every engine gets the same tiles.
--   - Points come from in-order De Casteljau subdivision with integer
--     midpoints and floor(sqrt) distances (both exact in IEEE doubles).
--   - JS `>>` on these values is floor division by a power of two.

local PathFinding = require(script.Parent.PathFinding)
local Util = require(script.Parent.Parent.Util)

local PathStatus = PathFinding.PathStatus

local SUB_SCALE = 256
local PARABOLA_MIN_HEIGHT = 50

local function jsRound(x: number): number
	return math.floor(x + 0.5)
end

export type Point = { x: number, y: number }

-- Line.ts DistanceBasedBezierCurve ------------------------------------------------

local Bezier = {}
Bezier.__index = Bezier

export type Bezier = typeof(setmetatable(
	{} :: {
		p0: Point,
		p1: Point,
		p2: Point,
		p3: Point,
		cachedPoints: { Point },
		currentIndex: number, -- 0-based, like the TS index
		pixelSpacingScaled: number,
		accumulatedDistanceScaled: number,
	},
	Bezier
))

type SubState = { lastX: number, lastY: number, accumDist: number, stepThreshold: number?, cachedPoints: { Point }? }

local function sharedSubdivide(ax: number, ay: number, bx: number, by: number, cx: number, cy: number, dx: number, dy: number, depth: number, st: SubState)
	local dist = math.abs(bx - ax) + math.abs(by - ay) + math.abs(cx - bx) + math.abs(cy - by) + math.abs(dx - cx) + math.abs(dy - cy)
	if dist <= 256 or depth >= 10 then
		local edx = ax - st.lastX
		local edy = ay - st.lastY
		st.accumDist += math.floor(math.sqrt(edx * edx + edy * edy))
		st.lastX = ax
		st.lastY = ay
		local threshold, points = st.stepThreshold, st.cachedPoints
		if threshold ~= nil and points ~= nil then
			while st.accumDist >= threshold do
				table.insert(points, { x = (ax + 128) // 256, y = (ay + 128) // 256 })
				st.accumDist -= threshold
			end
		end
		return
	end
	local m01x, m01y = (ax + bx) // 2, (ay + by) // 2
	local m12x, m12y = (bx + cx) // 2, (by + cy) // 2
	local m23x, m23y = (cx + dx) // 2, (cy + dy) // 2
	local m012x, m012y = (m01x + m12x) // 2, (m01y + m12y) // 2
	local m123x, m123y = (m12x + m23x) // 2, (m12y + m23y) // 2
	local mx, my = (m012x + m123x) // 2, (m012y + m123y) // 2
	sharedSubdivide(ax, ay, m01x, m01y, m012x, m012y, mx, my, depth + 1, st)
	sharedSubdivide(mx, my, m123x, m123y, m23x, m23y, dx, dy, depth + 1, st)
end

function Bezier.new(p0: Point, p1: Point, p2: Point, p3: Point, distanceIncrement: number): Bezier
	local self = setmetatable({
		p0 = p0,
		p1 = p1,
		p2 = p2,
		p3 = p3,
		cachedPoints = {},
		currentIndex = 0,
		pixelSpacingScaled = 1,
		accumulatedDistanceScaled = 0,
	}, Bezier)
	self:computeAllPoints(distanceIncrement)
	return self
end

-- Full curve length without allocating points.
function Bezier.getLength(p0: Point, p1: Point, p2: Point, p3: Point): number
	local scale = 256
	local p0x, p0y = jsRound(p0.x) * scale, jsRound(p0.y) * scale
	local p3x, p3y = jsRound(p3.x) * scale, jsRound(p3.y) * scale
	local st: SubState = { lastX = p0x, lastY = p0y, accumDist = 0 }
	sharedSubdivide(p0x, p0y, jsRound(p1.x) * scale, jsRound(p1.y) * scale, jsRound(p2.x) * scale, jsRound(p2.y) * scale, p3x, p3y, 0, st)
	local edx, edy = p3x - st.lastX, p3y - st.lastY
	st.accumDist += math.floor(math.sqrt(edx * edx + edy * edy))
	return st.accumDist / scale
end

function Bezier.getAllPoints(self: Bezier): { Point }
	return self.cachedPoints
end

-- Moves along the curve by `distance`; the next cached point, or nil at the end.
function Bezier.increment(self: Bezier, distance: number?): Point?
	self.accumulatedDistanceScaled += math.max(1, jsRound((distance or 1) * SUB_SCALE))
	local last = #self.cachedPoints - 1
	while self.currentIndex < last and self.accumulatedDistanceScaled >= self.pixelSpacingScaled do
		self.currentIndex += 1
		self.accumulatedDistanceScaled -= self.pixelSpacingScaled
	end
	if self.currentIndex >= last then
		return nil
	end
	return self.cachedPoints[self.currentIndex + 1]
end

function Bezier.getCurrentIndex(self: Bezier): number
	return self.currentIndex
end

function Bezier.computeAllPoints(self: Bezier, pixelSpacing: number)
	self.cachedPoints = {}
	self.currentIndex = 0
	self.accumulatedDistanceScaled = 0
	self.pixelSpacingScaled = math.max(SUB_SCALE, jsRound(pixelSpacing * SUB_SCALE))
	local scale = SUB_SCALE
	local p0x, p0y = jsRound(self.p0.x) * scale, jsRound(self.p0.y) * scale
	local p3x, p3y = jsRound(self.p3.x) * scale, jsRound(self.p3.y) * scale
	local st: SubState = {
		lastX = p0x,
		lastY = p0y,
		accumDist = 0,
		stepThreshold = self.pixelSpacingScaled,
		cachedPoints = self.cachedPoints,
	}
	table.insert(self.cachedPoints, { x = (p0x + 128) // 256, y = (p0y + 128) // 256 })
	sharedSubdivide(
		p0x,
		p0y,
		jsRound(self.p1.x) * scale,
		jsRound(self.p1.y) * scale,
		jsRound(self.p2.x) * scale,
		jsRound(self.p2.y) * scale,
		p3x,
		p3y,
		0,
		st
	)
	local lastPt = { x = (p3x + 128) // 256, y = (p3y + 128) // 256 }
	local endCached = self.cachedPoints[#self.cachedPoints]
	if endCached == nil or endCached.x ~= lastPt.x or endCached.y ~= lastPt.y then
		table.insert(self.cachedPoints, lastPt)
	end
end

-- PathFinder.Parabola.ts -------------------------------------------------------------

export type ParabolaOptions = {
	increment: number?,
	distanceBasedHeight: boolean?,
	directionUp: boolean?,
	ignoreMapBounds: boolean?,
}

local Parabola = {}
Parabola.__index = Parabola
Parabola.Bezier = Bezier

function Parabola.controlPoints(gameMap: any, from: number, to: number, options: ParabolaOptions?): (Point, Point, Point, Point)
	local o: ParabolaOptions = options or {}
	local distanceBasedHeight = if o.distanceBasedHeight == nil then true else o.distanceBasedHeight
	local directionUp = if o.directionUp == nil then true else o.directionUp
	local ignoreMapBounds = o.ignoreMapBounds or false
	local p0 = { x = gameMap:x(from), y = gameMap:y(from) }
	local p3 = { x = gameMap:x(to), y = gameMap:y(to) }
	local dx, dy = p3.x - p0.x, p3.y - p0.y
	local distance = math.sqrt(dx * dx + dy * dy)
	local maxHeight = if distanceBasedHeight then math.max(distance / 3, PARABOLA_MIN_HEIGHT) else 0
	local heightMult = if directionUp then -1 else 1
	local mapHeight = gameMap:height()
	local p1y = p0.y + dy / 4 + heightMult * maxHeight
	local p2y = p0.y + (dy * 3) / 4 + heightMult * maxHeight
	local p1 = { x = p0.x + dx / 4, y = if ignoreMapBounds then p1y else Util.within(p1y, 0, mapHeight - 1) }
	local p2 = { x = p0.x + (dx * 3) / 4, y = if ignoreMapBounds then p2y else Util.within(p2y, 0, mapHeight - 1) }
	return p0, p1, p2, p3
end

export type Parabola = typeof(setmetatable(
	{} :: { gameMap: any, options: ParabolaOptions?, curve: Bezier?, lastTo: number? },
	Parabola
))

function Parabola.new(gameMap: any, options: ParabolaOptions?): Parabola
	return setmetatable({ gameMap = gameMap, options = options, curve = nil, lastTo = nil }, Parabola)
end

function Parabola._createCurve(self: Parabola, from: number, to: number): Bezier
	local increment = (self.options and self.options.increment) or 3
	local p0, p1, p2, p3 = Parabola.controlPoints(self.gameMap, from, to, self.options)
	return Bezier.new(p0, p1, p2, p3, increment)
end

function Parabola.findPath(self: Parabola, from: number, to: number): { number }
	local out = {}
	for _, p in self:_createCurve(from, to):getAllPoints() do
		table.insert(out, self.gameMap:ref(math.floor(p.x), math.floor(p.y)))
	end
	return out
end

-- A PathResult like the Stepper's (status NEXT or COMPLETE, always a node).
function Parabola.next(self: Parabola, from: number, to: number, speed: number?): { status: number, node: number }
	if self.lastTo ~= to then
		self.curve = self:_createCurve(from, to)
		self.lastTo = to
	end
	local nextPoint = (self.curve :: Bezier):increment(speed or 1)
	if nextPoint == nil then
		return { status = PathStatus.COMPLETE, node = to }
	end
	return { status = PathStatus.NEXT, node = self.gameMap:ref(math.floor(nextPoint.x), math.floor(nextPoint.y)) }
end

function Parabola.invalidate(self: Parabola)
	self.curve = nil
	self.lastTo = nil
end

function Parabola.currentIndex(self: Parabola): number
	return if self.curve then self.curve:getCurrentIndex() else 0
end

return Parabola
