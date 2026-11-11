--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/PseudoRandom.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- sfc32 seeded by splitmix32. State words are kept unsigned (0 .. 2^32-1);
-- JS keeps them signed, which holds the same bits. Sequences match OpenFront's
-- exactly. Arrays are 1-based here; indices drawn with nextInt stay 0-based
-- like the original, so callers add 1.

local PseudoRandom = {}
PseudoRandom.__index = PseudoRandom

export type PseudoRandom = typeof(setmetatable(
	{} :: { s0: number, s1: number, s2: number, s3: number },
	PseudoRandom
))

local TWO32 = 4294967296
local TWO31 = 2147483648
local POW36_8 = 2821109907456 -- 36 ** 8

-- JS `x | 0` as an unsigned word: truncate toward zero, wrap mod 2^32.
local function toU32(x: number): number
	local n = if x < 0 then math.ceil(x) else math.floor(x)
	return n % TWO32
end

-- JS Math.imul on unsigned words, as an unsigned word.
local function imul(a: number, b: number): number
	local aHi, aLo = bit32.rshift(a, 16), bit32.band(a, 0xffff)
	local bHi, bLo = bit32.rshift(b, 16), bit32.band(b, 0xffff)
	return ((((aHi * bLo + aLo * bHi) % 65536) * 65536) + aLo * bLo) % TWO32
end

PseudoRandom.imul = imul

local function toSigned(x: number): number
	return if x >= TWO31 then x - TWO32 else x
end

-- PseudoRandom.ts constructor
function PseudoRandom.new(seed: number): PseudoRandom
	local h = toU32(seed)
	local function split(): number
		h = (h + 0x9e3779b9) % TWO32
		local t = bit32.bxor(h, bit32.rshift(h, 16))
		t = imul(t, 0x21f0aaad)
		t = bit32.bxor(t, bit32.rshift(t, 15))
		t = imul(t, 0x735a2d97)
		return bit32.bxor(t, bit32.rshift(t, 15))
	end
	local s0 = split()
	local s1 = split()
	local s2 = split()
	local s3 = split()
	local self = setmetatable({ s0 = s0, s1 = s1, s2 = s2, s3 = s3 }, PseudoRandom)
	-- Warm up to diffuse low-entropy seeds.
	for _ = 1, 12 do
		self:next()
	end
	return self
end

-- PseudoRandom.ts getState: the four words as JS holds them (signed).
function PseudoRandom.getState(self: PseudoRandom): { number }
	return { toSigned(self.s0), toSigned(self.s1), toSigned(self.s2), toSigned(self.s3) }
end

-- PseudoRandom.ts fromState
function PseudoRandom.fromState(state: { number }): PseudoRandom
	return setmetatable(
		{ s0 = toU32(state[1]), s1 = toU32(state[2]), s2 = toU32(state[3]), s3 = toU32(state[4]) },
		PseudoRandom
	)
end

-- PseudoRandom.ts next: a number in [0, 1).
function PseudoRandom.next(self: PseudoRandom): number
	local t = (self.s0 + self.s1 + self.s3) % TWO32
	self.s3 = (self.s3 + 1) % TWO32
	self.s0 = bit32.bxor(self.s1, bit32.rshift(self.s1, 9))
	self.s1 = (self.s2 + bit32.lshift(self.s2, 3)) % TWO32
	self.s2 = (bit32.lrotate(self.s2, 21) + t) % TWO32
	return t / TWO32
end

-- PseudoRandom.ts nextInt: an integer in [min, max).
function PseudoRandom.nextInt(self: PseudoRandom, min: number, max: number): number
	local lo = math.floor(min)
	local hi = math.floor(max)
	return math.floor(self:next() * (hi - lo)) + lo
end

-- PseudoRandom.ts nextFloat: a number in [min, max).
function PseudoRandom.nextFloat(self: PseudoRandom, min: number, max: number): number
	return self:next() * (max - min) + min
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

-- PseudoRandom.ts nextID: 8 base-36 characters.
function PseudoRandom.nextID(self: PseudoRandom): string
	local n = math.floor(self:next() * POW36_8)
	local out = ""
	repeat
		local d = n % 36
		out = string.sub(DIGITS, d + 1, d + 1) .. out
		n = (n - d) / 36
	until n == 0
	return string.rep("0", 8 - #out) .. out
end

-- PseudoRandom.ts randElement
function PseudoRandom.randElement(self: PseudoRandom, arr: { any }): any
	if #arr == 0 then
		error("array must not be empty")
	end
	return arr[self:nextInt(0, #arr) + 1]
end

-- PseudoRandom.ts randFromSet. JS Sets iterate in insertion order; pass that
-- order as an array.
PseudoRandom.randFromOrdered = PseudoRandom.randElement

-- PseudoRandom.ts chance: true with probability 1/odds.
function PseudoRandom.chance(self: PseudoRandom, odds: number): boolean
	return self:nextInt(0, odds) == 0
end

-- PseudoRandom.ts shuffleArray: a shuffled copy (Fisher-Yates).
function PseudoRandom.shuffleArray(self: PseudoRandom, array: { any }): { any }
	local result = table.clone(array)
	for i = #result - 1, 1, -1 do
		local j = self:nextInt(0, i + 1)
		result[i + 1], result[j + 1] = result[j + 1], result[i + 1]
	end
	return result
end

return PseudoRandom
