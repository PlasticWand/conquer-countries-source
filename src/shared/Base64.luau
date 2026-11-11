--!strict
-- Standard Base64 (RFC 4648, with padding) between strings and buffers.
-- Used for generated map payloads; pure Luau so Lune and Roblox agree.

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local encodeTable: { number } = table.create(64, 0)
local decodeTable: { [number]: number } = {}
for i = 1, 64 do
	local byte = string.byte(ALPHABET, i)
	encodeTable[i] = byte
	decodeTable[byte] = i - 1
end
local PAD = string.byte("=")

local Base64 = {}

function Base64.encode(data: buffer): string
	local len = buffer.len(data)
	local outLen = math.ceil(len / 3) * 4
	local out = buffer.create(outLen)
	local o = 0
	local i = 0
	while i + 2 < len do
		local n = buffer.readu8(data, i) * 65536 + buffer.readu8(data, i + 1) * 256 + buffer.readu8(data, i + 2)
		buffer.writeu8(out, o, encodeTable[bit32.rshift(n, 18) + 1])
		buffer.writeu8(out, o + 1, encodeTable[bit32.band(bit32.rshift(n, 12), 63) + 1])
		buffer.writeu8(out, o + 2, encodeTable[bit32.band(bit32.rshift(n, 6), 63) + 1])
		buffer.writeu8(out, o + 3, encodeTable[bit32.band(n, 63) + 1])
		i += 3
		o += 4
	end
	local rest = len - i
	if rest == 1 then
		local n = buffer.readu8(data, i) * 65536
		buffer.writeu8(out, o, encodeTable[bit32.rshift(n, 18) + 1])
		buffer.writeu8(out, o + 1, encodeTable[bit32.band(bit32.rshift(n, 12), 63) + 1])
		buffer.writeu8(out, o + 2, PAD)
		buffer.writeu8(out, o + 3, PAD)
	elseif rest == 2 then
		local n = buffer.readu8(data, i) * 65536 + buffer.readu8(data, i + 1) * 256
		buffer.writeu8(out, o, encodeTable[bit32.rshift(n, 18) + 1])
		buffer.writeu8(out, o + 1, encodeTable[bit32.band(bit32.rshift(n, 12), 63) + 1])
		buffer.writeu8(out, o + 2, encodeTable[bit32.band(bit32.rshift(n, 6), 63) + 1])
		buffer.writeu8(out, o + 3, PAD)
	end
	return buffer.tostring(out)
end

function Base64.decode(text: string): buffer
	local len = #text
	assert(len % 4 == 0, "base64 length must be a multiple of 4")
	local padding = 0
	if len > 0 and string.byte(text, len) == PAD then
		padding += 1
		if string.byte(text, len - 1) == PAD then
			padding += 1
		end
	end
	local outLen = len // 4 * 3 - padding
	local out = buffer.create(outLen)
	local src = buffer.fromstring(text)
	local o = 0
	for i = 0, len - 1, 4 do
		local a = decodeTable[buffer.readu8(src, i)]
		local b = decodeTable[buffer.readu8(src, i + 1)]
		local cByte = buffer.readu8(src, i + 2)
		local dByte = buffer.readu8(src, i + 3)
		local c = if cByte == PAD then 0 else decodeTable[cByte]
		local d = if dByte == PAD then 0 else decodeTable[dByte]
		assert(a and b and c and d, "invalid base64 character")
		local n = a * 262144 + b * 4096 + c * 64 + d
		if o < outLen then
			buffer.writeu8(out, o, bit32.rshift(n, 16))
		end
		if o + 1 < outLen then
			buffer.writeu8(out, o + 1, bit32.band(bit32.rshift(n, 8), 255))
		end
		if o + 2 < outLen then
			buffer.writeu8(out, o + 2, bit32.band(n, 255))
		end
		o += 3
	end
	return out
end

return Base64
