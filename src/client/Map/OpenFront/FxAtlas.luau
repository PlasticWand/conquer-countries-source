--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/passes/fx-pass/FxSpritePass.ts; resources/atlases/fx-atlas-meta.json), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Artwork: resources/atlases/fx-atlas.png, CC BY-SA 4.0. Credit: OpenFront.
local Encoded = require(script.Parent.FxAtlasData)
local Spawn = require(script.Parent.SpawnOverlay)
local Atlas = {}
Atlas.width, Atlas.height = 540, 306
-- Original: FX_CONFIG / fx-atlas-meta.rows; width, height, offset, frames, ms, loop.
local rows: {{any}} = {
	{60,60,0,9,70,false}, {48,38,60,9,70,false}, {17,15,98,10,70,false},
	{19,19,113,4,70,false}, {13,12,132,4,70,false}, {16,14,144,14,90,false},
	{7,13,158,6,100,true}, {11,12,171,4,120,true}, {24,16,183,5,120,true},
	{24,16,199,5,120,true}, {9,7,215,3,100,false}, {21,20,222,10,90,false},
}
Atlas.rows = rows
function Atlas.rgba(): buffer
	local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	local decode = {}; for i = 1, #alphabet do decode[string.byte(alphabet, i)] = i - 1 end
	local bytes,value,bits,n = buffer.create(math.ceil(#Encoded*3/4)),0,0,0
	for i = 1, #Encoded do
		local d = decode[string.byte(Encoded, i)]
		if d ~= nil then
			value = value * 64 + d; bits += 6
			if bits >= 8 then
				bits -= 8; local div = 2 ^ bits
				buffer.writeu8(bytes,n,math.floor(value/div)); n+=1; value %= div
			end
		end
	end
	local pixels, cursor = buffer.create(Atlas.width * Atlas.height * 4), 0
	for i = 0, n-1, 6 do
		local count,color = buffer.readu16(bytes,i),buffer.readu32(bytes,i+2)
		if color==0 then buffer.fill(pixels,cursor*4,0,count*4); cursor+=count
		else for _ = 1, count do buffer.writeu32(pixels,cursor*4,color); cursor+=1 end end
	end
	assert(cursor == 540 * 242, 'OpenFront FX atlas length')
	-- Native substitute for spawn-overlay.frag: static radial masks scaled/tinted
	-- each frame. 64px sampling/GUI filtering approximate the shader's edges.
	for kind = 1, 2 do for y = 0, 63 do for x = 0, 63 do
		local maxRadius = if kind == 1 then 30 else 14
		local distance = math.sqrt(((x + .5) / 32 - 1)^2 + ((y + .5) / 32 - 1)^2) * maxRadius * 1.15
		local c = Spawn.sample(kind, distance, 1, {r = 1,g = 1,b = 1,a = 1}, true, 0)
		local off = ((242 + y) * Atlas.width + (kind - 1) * 64 + x) * 4
		buffer.writeu32(pixels, off, 0x00ffffff + math.floor(c.a * 255 + .5) * 16777216)
	end end end
	return pixels
end
return Atlas
