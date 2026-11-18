--!strict
-- Conquest's Studio filming keyframes. Presentation only; no match state or services.
local Film = {}

export type Box = {x: number, y: number, w: number, h: number}
export type Keyframe = {t: number, x: number, y: number, zoom: number?, box: Box?, fit: number?, easing: string?}
export type Shot = {duration: number, keyframes: {Keyframe}, frame: Box?, labelPixels: number?}
export type Pose = {x: number, y: number, zoom: number}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- Copy first: callers may reuse/edit their command table while a shot plays.
-- Easing belongs to the destination keyframe; omitted means linear.
function Film.prepare(value: any): Shot
	assert(type(value) == "table" and finite(value.duration) and value.duration > 0, "film duration must be finite and positive")
	assert(type(value.keyframes) == "table" and #value.keyframes > 0, "film needs keyframes")
	local keys: {Keyframe} = {}
	local frame: Box? = nil
	if value.frame ~= nil then
		local f = value.frame
		assert(type(f) == "table" and finite(f.x) and finite(f.y) and finite(f.w) and finite(f.h)
			and f.x >= 0 and f.y >= 0 and f.w > 0 and f.h > 0 and f.x + f.w <= 1 and f.y + f.h <= 1,
			"film frame must be a normalized rectangle inside the viewport")
		frame = {x = f.x, y = f.y, w = f.w, h = f.h}
	end
	assert(value.labelPixels == nil or (finite(value.labelPixels) and value.labelPixels > 0 and value.labelPixels <= 200),
		"film labelPixels must be positive and at most 200 (at 1920px height)")
	local previous = -1
	for i, key in value.keyframes do
		assert(type(i) == "number" and i == #keys + 1 and type(key) == "table", "film keyframes must be a dense array")
		assert(finite(key.t) and key.t >= 0 and key.t <= value.duration and key.t > previous, "film keyframe times must increase within duration")
		assert(i ~= 1 or key.t == 0, "film first keyframe must start at zero")
		assert(key.easing == nil or key.easing == "linear" or key.easing == "smoothstep", "unsupported film easing")
		local copied: Keyframe
		if key.box ~= nil then
			local b = key.box
			assert(type(b) == "table" and finite(b.x) and finite(b.y) and finite(b.w) and finite(b.h) and b.w > 0 and b.h > 0,
				"film box needs finite centre x/y and positive w/h")
			assert(key.zoom == nil and key.x == nil and key.y == nil, "film box replaces x/y/zoom")
			assert(key.fit == nil or (finite(key.fit) and key.fit > 0 and key.fit <= 1), "film fit must be in (0, 1]")
			copied = {t = key.t, x = b.x, y = b.y, box = {x = b.x, y = b.y, w = b.w, h = b.h}, fit = key.fit or 1, easing = key.easing}
		else
			assert(finite(key.x) and finite(key.y) and finite(key.zoom) and key.zoom > 0, "film pose must be finite with positive zoom")
			assert(key.fit == nil, "film fit requires a box")
			copied = {t = key.t, x = key.x, y = key.y, zoom = key.zoom, easing = key.easing}
		end
		table.insert(keys, copied)
		previous = key.t
	end
	return {duration = value.duration, keyframes = keys, frame = frame, labelPixels = value.labelPixels}
end

-- Fit both dimensions, using the shorter available span; tall boxes are
-- height-limited even in portrait. Recompute on resize, without changing time.
local function zoomFor(key: Keyframe, shot: Shot, width: number?, height: number?): number
	if key.zoom then return key.zoom end
	assert(width and height and finite(width) and finite(height) and width > 0 and height > 0, "film box requires a positive viewport")
	local b = key.box :: Box
	local f = shot.frame
	local zoom = math.min(width * (if f then f.w else 1) / b.w, height * (if f then f.h else 1) / b.h) * (key.fit or 1)
	assert(finite(zoom) and zoom > 0, "film box exceeds camera precision")
	return zoom
end

function Film.sample(shot: Shot, elapsed: number, width: number?, height: number?): Pose
	assert(finite(elapsed), "film elapsed time must be finite")
	local t = math.clamp(elapsed, 0, shot.duration)
	local keys = shot.keyframes
	local a = keys[1]
	local az = zoomFor(a, shot, width, height)
	for i = 2, #keys do
		local b = keys[i]
		if t < b.t then
			local u = (t - a.t) / (b.t - a.t)
			if b.easing == "smoothstep" then u = u * u * (3 - 2 * u) end
			return {x = a.x * (1 - u) + b.x * u, y = a.y * (1 - u) + b.y * u,
				zoom = math.exp(math.log(az) * (1 - u) + math.log(zoomFor(b, shot, width, height)) * u)}
		end
		a = b
		az = zoomFor(a, shot, width, height)
	end
	return {x = a.x, y = a.y, zoom = az}
end

return Film
