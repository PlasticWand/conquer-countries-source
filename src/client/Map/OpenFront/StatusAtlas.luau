--!strict
-- Artwork: OpenFront v0.35.2 resources/atlases/status-atlas.png and emoji-atlas.png,
-- CC BY-SA 4.0. Credit: OpenFront and Contributors. Resized; alliance outline baked.
-- Native adapter for name-pass/StatusIconProgram.ts and IconProgram.ts (AGPL-3.0).
-- © OpenFront and Contributors; modified for Roblox/Luau by Conquest.
local Encoded = require(script.Parent.StatusAtlasData)
local Atlas = {width = 640, height = 448, cell = 64, statusContent = 56}
Atlas.emojis = require(script.Parent.StatusEmojiLookup)

-- Dependency injected so the packed bytes can be checked headlessly. Native
-- codec work replaces a multi-second Lua byte loop; validate before allocation.
function Atlas.rgba(encoding: any, algorithm: any): buffer
	local compressed = encoding:Base64Decode(buffer.fromstring(Encoded))
	local expected = Atlas.width * Atlas.height * 4
	assert(encoding:GetDecompressedBufferSize(compressed, algorithm) == expected, "OpenFront status atlas header size")
	local pixels = encoding:DecompressBuffer(compressed, algorithm)
	assert(buffer.len(pixels) == expected, "OpenFront status atlas length")
	return pixels
end

return Atlas
