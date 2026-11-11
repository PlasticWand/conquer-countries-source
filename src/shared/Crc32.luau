--!strict
-- CRC-32 (IEEE 802.3, the zlib/PNG polynomial) over a buffer range.

local TABLE: { number } = table.create(256, 0)
for n = 0, 255 do
	local c = n
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	TABLE[n + 1] = c
end

local Crc32 = {}

function Crc32.ofBuffer(data: buffer, offset: number?, length: number?): number
	local start = offset or 0
	local stop = start + (length or (buffer.len(data) - start)) - 1
	local crc = 0xFFFFFFFF
	for i = start, stop do
		crc = bit32.bxor(TABLE[bit32.band(bit32.bxor(crc, buffer.readu8(data, i)), 0xFF) + 1], bit32.rshift(crc, 8))
	end
	return bit32.bxor(crc, 0xFFFFFFFF)
end

function Crc32.ofString(text: string): number
	return Crc32.ofBuffer(buffer.fromstring(text))
end

return Crc32
