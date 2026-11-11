--!strict
-- xorshift32 using only bit32 shifts and xors, so the sequence is identical
-- under Lune and Roblox. The match sim and map generators take an Rng
-- explicitly; nothing reads a global random source.

export type Rng = { state: number }

local Rng = {}

function Rng.new(seed: number): Rng
	local s = bit32.band(math.floor(seed), 0xFFFFFFFF)
	if s == 0 then
		s = 0x9E3779B9
	end
	local rng = { state = s }
	for _ = 1, 8 do
		Rng.nextU32(rng)
	end
	return rng
end

function Rng.nextU32(rng: Rng): number
	local x = rng.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	rng.state = x
	return x
end

-- [0, 1)
function Rng.nextFloat(rng: Rng): number
	return Rng.nextU32(rng) / 4294967296
end

-- Inclusive integer range.
function Rng.int(rng: Rng, lo: number, hi: number): number
	return lo + Rng.nextU32(rng) % (hi - lo + 1)
end

return Rng
