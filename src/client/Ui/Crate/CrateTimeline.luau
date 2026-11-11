--!strict
-- The crate opening's timing and look, pure (tests/CrateTimeline.spec.luau):
-- sampling the Blender track between frames, the beats of the three taps, the
-- Legendary transform's order, the 3-pack's order and places, rarity colours
-- and the camera's field of view. CrateOpening turns these into instances.

local CrateTimeline = {}

CrateTimeline.FPS = 30

-- Track frames (art/crate/crate.blend; segments in CrateTrack). The crate
-- lands at 10. Tap 1 pops the catches (64), tap 2 snaps the straps (109), tap
-- 3 blows the lid (157); the lid is gone from 173. A card (Bruno: back
-- first; peek, raise it clear, then drop it in front; flip sideways like a
-- playing card as it drops, about 0.5 s) starts deep inside under the glow at
-- 186, its top edge rises over the rim by 200 and holds a beat, the whole card
-- rises clear of the crate by 211, moves out over the front edge by 220, then
-- drops in front of the crate turning a real half turn in 3D (CARD_TURN) and
-- settles face up at 239, where the 2D card replaces it at the same place.
-- It never passes through the wood. The camera looks down into the crate for
-- the peek, up for the card held high, and follows it down.
CrateTimeline.LAND = 10
CrateTimeline.TAP_BREAK = { 64, 109, 157 }
CrateTimeline.CARD_RISE = 186
CrateTimeline.CARD_TURN = { 219, 234 }
-- Bruno: the change from the 3D card to the 2D card must be seamless. The 3D
-- card leans back as it lands so it faces the camera square on; from
-- CARD_FADE the 2D card sits exactly over it, follows its little bounce and
-- fades in, done by CARD_SETTLED.
CrateTimeline.CARD_FADE = 233
CrateTimeline.CARD_SETTLED = 239

-- The Legendary transform (Bruno, 2026-11-02: it turns while it rattles,
-- before the first tap): seconds into the first wait before it starts, then
-- when each part flares gold and swaps to the dark crate, and when the seams
-- ignite. A flare peaks (and swaps) after FLARE seconds and fades over
-- FLARE_FADE.
CrateTimeline.TRANSFORM_DELAY = 0.45
local TRANSFORM: { [string]: number } = {
	Body = 0,
	Lid = 0.22,
	Strap0 = 0.3,
	Strap1 = 0.36,
	Catch0 = 0.42,
	Catch1 = 0.47,
}
CrateTimeline.TRANSFORM = TRANSFORM
CrateTimeline.SEAMS_IGNITE = 0.55
CrateTimeline.FLARE = 0.1
CrateTimeline.FLARE_FADE = 0.3

-- Light through the seams while it waits, brighter after each tap
-- (transparency for waits 0, 1 and 2; it pulses around this).
CrateTimeline.LEAK = { 0.5, 0.32, 0.14 }

-- Rarity: the glow's colour (0-1 RGB), whether light leaks through the seams
-- while it waits, the halo's size (crate widths) and how many sparks the
-- burst throws, and which crate it ends as.
export type Look = { glow: { number }, seams: boolean, haze: number, sparks: number, legendary: boolean }
local LOOK: { [string]: Look } = {
	common = { glow = { 1, 0.86, 0.62 }, seams = false, haze = 1.4, sparks = 10, legendary = false },
	rare = { glow = { 0.25, 0.6, 1 }, seams = true, haze = 1.7, sparks = 16, legendary = false },
	epic = { glow = { 0.5, 0.22, 1 }, seams = true, haze = 2, sparks = 24, legendary = false },
	legendary = { glow = { 1, 0.52, 0.06 }, seams = true, haze = 2.5, sparks = 40, legendary = true },
}
CrateTimeline.LOOK = LOOK

local RANK = { common = 1, rare = 2, epic = 3, legendary = 4 }

-- The best rarity among the items (the crate glows for its best card).
function CrateTimeline.best(rarities: { string }): string
	local best = "common"
	for _, r in rarities do
		if (RANK[r] or 0) > RANK[best] then
			best = r
		end
	end
	return best
end

-- The order the cards come out: rarest last (Bruno), ties as rolled.
function CrateTimeline.order(rarities: { string }): { number }
	local order = {}
	for i in rarities do
		order[i] = i
	end
	table.sort(order, function(a, b)
		local ra, rb = RANK[rarities[a]] or 0, RANK[rarities[b]] or 0
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	return order
end

-- Where the k-th card out ends in the row, as a step from the middle: in a
-- 3-pack the first goes right, the second left, the last stays in the middle.
local PACK_SLOTS = { 1, -1, 0 }
function CrateTimeline.slot(k: number, n: number): number
	if n <= 1 then
		return 0
	end
	if n == 3 then
		return PACK_SLOTS[k]
	end
	return k - (n + 1) / 2
end

-- A part's pose at a fractional frame: position and scale lerp, the rotation
-- is a normalised lerp along the shorter arc. Frames are
-- { x, y, z, qx, qy, qz, qw, sx, sy, sz }; outside the track it holds the end.
function CrateTimeline.sample(frames: { { number } }, first: number, frame: number): { number }
	local n = #frames
	local f = math.clamp(frame - first + 1, 1, n)
	local i = math.floor(f)
	local a, b = frames[i], frames[math.min(i + 1, n)]
	local k = f - i
	local out = table.create(10, 0)
	for j = 1, 3 do
		out[j] = a[j] + (b[j] - a[j]) * k
	end
	local s = if a[4] * b[4] + a[5] * b[5] + a[6] * b[6] + a[7] * b[7] < 0 then -1 else 1
	local len = 0
	for j = 4, 7 do
		out[j] = a[j] + (s * b[j] - a[j]) * k
		len += out[j] * out[j]
	end
	len = math.sqrt(len)
	for j = 4, 7 do
		out[j] /= len
	end
	for j = 8, 10 do
		out[j] = a[j] + (b[j] - a[j]) * k
	end
	return out
end

-- Camera frames are { x, y, z, targetX, targetY, targetZ }, lerped.
function CrateTimeline.camera(frames: { { number } }, first: number, frame: number): { number }
	local n = #frames
	local f = math.clamp(frame - first + 1, 1, n)
	local i = math.floor(f)
	local a, b = frames[i], frames[math.min(i + 1, n)]
	local k = f - i
	local out = table.create(6, 0)
	for j = 1, 6 do
		out[j] = a[j] + (b[j] - a[j]) * k
	end
	return out
end

function CrateTimeline.hidden(ranges: { { number } }, frame: number): boolean
	for _, r in ranges do
		if frame >= r[1] and frame <= r[2] + 0.999 then
			return true
		end
	end
	return false
end

-- The frame `t` seconds into a segment { first, last }; a looped one wraps.
function CrateTimeline.at(segment: { number }, t: number, loop: boolean?): number
	local length = (segment[2] - segment[1]) / CrateTimeline.FPS
	local into = if loop then t % length else math.min(t, length)
	return segment[1] + into * CrateTimeline.FPS
end

-- The viewport's vertical field of view: Blender's frame (horizontal field
-- of view at `renderAspect`) always fits, so a wider screen shows more desk at
-- the sides and a narrower one more above and below. Capped so a tall window
-- doesn't fish-eye.
function CrateTimeline.verticalFov(horizontalFov: number, aspect: number, renderAspect: number): number
	local tanH = math.tan(math.rad(horizontalFov) / 2)
	local keepHeight = math.deg(2 * math.atan(tanH / renderAspect))
	local keepWidth = math.deg(2 * math.atan(tanH / math.max(aspect, 0.1)))
	return math.min(math.max(keepHeight, keepWidth), 70)
end

return CrateTimeline
