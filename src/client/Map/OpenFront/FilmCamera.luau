--!strict
-- Conquest's Studio filming keyframes. Presentation only; no match state or services.
local Film = {}

export type Keyframe = {t: number, x: number, y: number, zoom: number, easing: string?}
export type Shot = {duration: number, keyframes: {Keyframe}}
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
	local previous = -1
	for i, key in value.keyframes do
		assert(type(i) == "number" and i == #keys + 1 and type(key) == "table", "film keyframes must be a dense array")
		assert(finite(key.t) and key.t >= 0 and key.t <= value.duration and key.t > previous, "film keyframe times must increase within duration")
		assert(i ~= 1 or key.t == 0, "film first keyframe must start at zero")
		assert(finite(key.x) and finite(key.y) and finite(key.zoom) and key.zoom > 0, "film pose must be finite with positive zoom")
		assert(key.easing == nil or key.easing == "linear" or key.easing == "smoothstep", "unsupported film easing")
		local copied: Keyframe = {t = key.t, x = key.x, y = key.y, zoom = key.zoom, easing = key.easing}
		table.insert(keys, copied)
		previous = key.t
	end
	return {duration = value.duration, keyframes = keys}
end

function Film.sample(shot: Shot, elapsed: number): Pose
	assert(finite(elapsed), "film elapsed time must be finite")
	local t = math.clamp(elapsed, 0, shot.duration)
	local keys = shot.keyframes
	local a = keys[1]
	for i = 2, #keys do
		local b = keys[i]
		if t < b.t then
			local u = (t - a.t) / (b.t - a.t)
			if b.easing == "smoothstep" then u = u * u * (3 - 2 * u) end
			return {x = a.x * (1 - u) + b.x * u, y = a.y * (1 - u) + b.y * u,
				zoom = math.exp(math.log(a.zoom) * (1 - u) + math.log(b.zoom) * u)}
		end
		a = b
	end
	return {x = a.x, y = a.y, zoom = a.zoom}
end

return Film
