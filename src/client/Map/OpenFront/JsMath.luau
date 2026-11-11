--!strict
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/Util.ts; packages/engine-lib/src/PseudoRandom.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Js = {}

-- Original: JavaScript Math.round (ties toward positive infinity).
function Js.round(value: number, digits: number?): number
	local base = 10 ^ (digits or 0)
	return math.floor(value * base + 0.5) / base
end

-- Original: JavaScript ToInt32, used by |0 and bitwise hashes.
function Js.int32(value: number): number
	if value ~= value or math.abs(value) == math.huge then return 0 end
	local unsigned = (if value < 0 then math.ceil(value) else math.floor(value)) % 4294967296
	return if unsigned >= 2147483648 then unsigned - 4294967296 else unsigned
end

-- Original: JavaScript Math.imul in PseudoRandom's splitmix32.
local function imul(a: number, b: number): number
	local al, bl = bit32.band(a, 65535), bit32.band(b, 65535)
	return bit32.band(al * bl + bit32.lshift(bit32.rshift(a, 16) * bl + al * bit32.rshift(b, 16), 16), 0xffffffff)
end

-- Original: String.length / charCodeAt (UTF-16, including surrogate pairs).
function Js.utf16(value: string): {number}
	local units: {number} = {}
	for _, code in utf8.codes(value) do
		if code <= 65535 then table.insert(units, code)
		else
			local point = code - 65536
			table.insert(units, 55296 + math.floor(point / 1024))
			table.insert(units, 56320 + point % 1024)
		end
	end
	return units
end

-- Original: Util.simpleHash. Hash UTF-16 units, not UTF-8 bytes.
function Js.simpleHash(value: string): number
	local hash = 0
	for _, unit in Js.utf16(value) do hash = Js.int32(bit32.lshift(hash, 5) - hash + unit) end
	return math.abs(hash)
end

-- Original: PseudoRandom.constructor, next, nextInt. Only the first draw is
-- needed by ColorAllocator; this is independent of the changing engine port.
function Js.seededInt(seed: number, minimum: number, maximum: number): number
	local h = Js.int32(seed)
	-- Original: PseudoRandom.constructor's split closure.
	local function split(): number
		h = Js.int32(h + 0x9e3779b9)
		local v = imul(bit32.bxor(h, bit32.rshift(h, 16)), 0x21f0aaad)
		v = imul(bit32.bxor(v, bit32.rshift(v, 15)), 0x735a2d97)
		return bit32.bxor(v, bit32.rshift(v, 15))
	end
	local s0, s1, s2, s3 = split(), split(), split(), split()
	local value = 0
	for _ = 1, 13 do
		local sum = bit32.band(s0 + s1 + s3, 0xffffffff)
		s3 = bit32.band(s3 + 1, 0xffffffff)
		s0 = bit32.bxor(s1, bit32.rshift(s1, 9))
		s1 = bit32.band(s2 + bit32.lshift(s2, 3), 0xffffffff)
		s2 = bit32.band(bit32.bor(bit32.lshift(s2, 21), bit32.rshift(s2, 11)) + sum, 0xffffffff)
		value = sum / 4294967296
	end
	local low, high = math.floor(minimum), math.floor(maximum)
	return math.floor(value * (high - low)) + low
end

return Js
