-- Minimal RGB PNG writer for Lune previews (zlib via @lune/serde).
local serde = require("@lune/serde")
local Crc32 = require("../../src/shared/Crc32")

local Png = {}

-- rgb: buffer of width*height*3 bytes, row-major.
function Png.encode(width: number, height: number, rgb: buffer): string
	local stride = width * 3
	local raw = buffer.create((stride + 1) * height)
	for y = 0, height - 1 do
		buffer.writeu8(raw, y * (stride + 1), 0)
		buffer.copy(raw, y * (stride + 1) + 1, rgb, y * stride, stride)
	end
	local function chunk(kind: string, data: string): string
		return string.pack(">I4", #data) .. kind .. data .. string.pack(">I4", Crc32.ofString(kind .. data))
	end
	local header = string.pack(">I4I4BBBBB", width, height, 8, 2, 0, 0, 0)
	return "\137PNG\r\n\26\n"
		.. chunk("IHDR", header)
		.. chunk("IDAT", serde.compress("zlib", buffer.tostring(raw)))
		.. chunk("IEND", "")
end

return Png
