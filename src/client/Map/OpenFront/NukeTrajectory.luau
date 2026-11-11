--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/utils/NukeTrajectory.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Js = require(script.Parent.JsMath)
export type ControlPoints = {p0x: number, p0y: number, p1x: number, p1y: number,
	p2x: number, p2y: number, p3x: number, p3y: number}
export type SAMInfo = {x: number, y: number, r: number}
export type Thresholds = {tUntargetableStart: number, tUntargetableEnd: number, tSamIntercept: number}
type Polynomial = {ax: number, bx: number, cx: number, dx: number, ay: number, by: number, cy: number, dy: number}
local Trajectory = {}
local TARGETABLE_RANGE_SQ = 150 * 150
local THRESHOLD_SAMPLES = 32
local SAM_SAFETY_MARGIN = 0.75

-- Original: NukeTrajectory.samRange.
function Trajectory.samRange(level: number): number
	return 150 - 480 / (level + 5)
end

-- Original: NukeTrajectory.computeNukeControlPoints.
function Trajectory.computeNukeControlPoints(srcX: number, srcY: number, dstX: number, dstY: number,
	mapH: number, directionUp: boolean): ControlPoints
	local dx, dy = dstX - srcX, dstY - srcY
	local height = math.max(math.sqrt(dx * dx + dy * dy) / 3, 50)
	local sign = if directionUp then -1 else 1
	return {p0x = srcX, p0y = srcY, p1x = srcX + dx / 4, p1y = math.clamp(srcY + dy / 4 + sign * height, 0, mapH - 1),
		p2x = srcX + dx * 3 / 4, p2y = math.clamp(srcY + dy * 3 / 4 + sign * height, 0, mapH - 1), p3x = dstX, p3y = dstY}
end

-- Original: NukeTrajectory.refineCrossing / computeTrajectoryThresholds
-- polynomial samples: +.5 followed by JS |0, not Math.round or floor.
local function sample(p: Polynomial, t: number): (number, number)
	return Js.int32(((p.ax * t + p.bx) * t + p.cx) * t + p.dx + 0.5),
		Js.int32(((p.ay * t + p.by) * t + p.cy) * t + p.dy + 0.5)
end

-- Original: NukeTrajectory.refineCrossing (ten bisections, chord rejection).
local function refineCrossing(p: Polynomial, cx: number, cy: number, rangeSq: number,
	low: number, high: number, exiting: boolean): number
	local foundInside = false
	for _ = 1, 10 do
		local middle = (low + high) * 0.5
		local x, y = sample(p, middle)
		local dx, dy = x - cx, y - cy
		local inside = dx * dx + dy * dy <= rangeSq
		if inside then foundInside = true end
		if (if exiting then inside else not inside) then low = middle else high = middle end
	end
	if not exiting and not foundInside then
		local x, y = sample(p, high)
		local dx, dy = x - cx, y - cy
		if dx * dx + dy * dy > rangeSq then return 1 end
	end
	return (low + high) * 0.5
end

-- Original: NukeTrajectory.computeTrajectoryThresholds. Preserve ordered SAM
-- iteration: the source breaks on the first valid SAM in a sampled segment.
function Trajectory.computeTrajectoryThresholds(cp: ControlPoints, srcX: number, srcY: number,
	dstX: number, dstY: number, sams: {SAMInfo}): Thresholds
	local start, finish, intercept = -1, -1, 1
	local dt = 1 / THRESHOLD_SAMPLES
	local p: Polynomial = {
		cx = 3 * (cp.p1x - cp.p0x), bx = 3 * (cp.p2x - 2 * cp.p1x + cp.p0x),
		ax = dstX - 3 * cp.p2x + 3 * cp.p1x - cp.p0x, dx = cp.p0x,
		cy = 3 * (cp.p1y - cp.p0y), by = 3 * (cp.p2y - 2 * cp.p1y + cp.p0y),
		ay = dstY - 3 * cp.p2y + 3 * cp.p1y - cp.p0y, dy = cp.p0y,
	}
	local dx, dy = dstX - srcX, dstY - srcY
	local hasUntargetable = dx * dx + dy * dy > 4 * TARGETABLE_RANGE_SQ
	local previousX, previousY = Js.int32(cp.p0x + 0.5), Js.int32(cp.p0y + 0.5)
	for i = 1, THRESHOLD_SAMPLES do
		local t, tPrev = i * dt, i * dt - dt
		local x, y = sample(p, t)
		local untargetable = false
		if hasUntargetable then
			if start < 0 then
				local dxSrc, dySrc = x - srcX, y - srcY
				if dxSrc * dxSrc + dySrc * dySrc > TARGETABLE_RANGE_SQ then
					local dxDst, dyDst = x - dstX, y - dstY
					if dxDst * dxDst + dyDst * dyDst >= TARGETABLE_RANGE_SQ then
						start = refineCrossing(p, srcX, srcY, TARGETABLE_RANGE_SQ, tPrev, t, true)
						untargetable = true
					end
				end
			elseif finish < 0 then
				local dxDst, dyDst = x - dstX, y - dstY
				if dxDst * dxDst + dyDst * dyDst < TARGETABLE_RANGE_SQ then
					finish = refineCrossing(p, dstX, dstY, TARGETABLE_RANGE_SQ, tPrev, t, false)
				else untargetable = true end
			end
		end
		if finish >= 0 and tPrev < finish and t >= finish and #sams > 0 then
			local xe, ye = sample(p, finish)
			for _, sam in sams do
				local sx, sy = xe - sam.x, ye - sam.y
				if sx * sx + sy * sy <= sam.r * sam.r then intercept = finish; break end
			end
			if intercept < 1 then break end
		end
		if not untargetable and #sams > 0 then
			local segX, segY = x - previousX, y - previousY
			local l2 = segX * segX + segY * segY
			local invL2 = if l2 == 0 then 0 else 1 / l2
			local maxDist = math.sqrt(l2) + 150 + SAM_SAFETY_MARGIN
			for _, sam in sams do
				local sx, sy = sam.x - previousX, sam.y - previousY
				local distanceSq = sx * sx + sy * sy
				if distanceSq > maxDist * maxDist then continue end
				local dot = sx * segX + sy * segY
				local dSq = if dot <= 0 then distanceSq elseif dot >= l2 then distanceSq + l2 - 2 * dot
					else distanceSq - dot * dot * invL2
				if dSq <= (sam.r + SAM_SAFETY_MARGIN) * (sam.r + SAM_SAFETY_MARGIN) then
					local low = if finish >= 0 and tPrev < finish then finish else tPrev
					local hit = refineCrossing(p, sam.x, sam.y, sam.r * sam.r, low, t, false)
					if hit < 1 then intercept = hit; break end
				end
			end
			if intercept < 1 then break end
		end
		previousX, previousY = x, y
	end
	return {tUntargetableStart = start, tUntargetableEnd = finish, tSamIntercept = intercept}
end

-- Original: NukeTrajectory.buildNukeTrajectory. Continuous control points,
-- discrete Math.round destination for threshold tests, as in v0.35.2.
function Trajectory.buildNukeTrajectory(srcX: number, srcY: number, dstX: number, dstY: number,
	mapH: number, directionUp: boolean, sams: {SAMInfo}): ControlPoints & Thresholds
	local cp = Trajectory.computeNukeControlPoints(srcX, srcY, dstX, dstY, mapH, directionUp)
	local th = Trajectory.computeTrajectoryThresholds(cp, srcX, srcY, Js.round(dstX), Js.round(dstY), sams)
	return {p0x = cp.p0x, p0y = cp.p0y, p1x = cp.p1x, p1y = cp.p1y, p2x = cp.p2x, p2y = cp.p2y,
		p3x = cp.p3x, p3y = cp.p3y, tUntargetableStart = th.tUntargetableStart,
		tUntargetableEnd = th.tUntargetableEnd, tSamIntercept = th.tSamIntercept}
end

return Trajectory
