--!strict
-- Ported from OpenFront v0.35.2 (resources/atlases/unit-atlas.png; resources/atlases/icon-atlas.png; src/client/render/gl/shaders/unit/unit.frag.glsl), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Sprite source assets in resources/ are CC BY-SA 4.0. Credit: OpenFront.
local Encoded = require(script.Parent.SpriteAtlasData)
local Atlas = {}
Atlas.width, Atlas.height = 512, 192
-- Original Arsenal plate geometry. Small new masks occupy unused 32px
-- cells beside the unit bands; the atlas keeps its existing dimensions.
function Atlas.arsenalDistance(column:number,x:number,y:number):number
	if column==10 then return math.max(math.abs(x),math.abs(y)*1.25) end
	if column==9 then return math.max(math.abs(x),math.abs(y),(.72*(math.abs(x)+math.abs(y)))) end
	if column==6 then return math.max(math.abs(x),math.abs(y)*1.6) end
	local half=math.pi/6
	local angle=(math.atan2(y/.8,x)+half)%(2*half)-half
	return math.sqrt(x*x+(y/.8)^2)*math.cos(angle)/math.cos(half)
end

local decodeTable = {}
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
for i = 1, #alphabet do decodeTable[string.byte(alphabet, i)] = i - 1 end

-- Original: UnitPass.loadAtlas/StructurePass.loadAtlas. The generated data
-- separates four replacement bands, so ImageColor3 can tint each one with
-- the exact owner palette without per-unit EditableImage writes.
function Atlas.rgba(): buffer
	local pixels = buffer.create(Atlas.width * Atlas.height * 4)
	local value, bits, n = 0, 0, 0
	local function putAlpha(alpha: number)
		local x, y
		if n < 8112 then
			x = n % 156
			y = math.floor(n / 156)
		else
			local i = n - 8112
			x, y = i % 384, math.floor(i / 384) + 56
		end
		local off = (y * Atlas.width + x) * 4
		buffer.writeu8(pixels, off, 255)
		buffer.writeu8(pixels, off + 1, 255)
		buffer.writeu8(pixels, off + 2, 255)
		buffer.writeu8(pixels, off + 3, alpha)
		n += 1
	end
	for i = 1, #Encoded do
		local b = string.byte(Encoded, i)
		local digit = decodeTable[b]
		if digit ~= nil then
			value = value * 64 + digit
			bits += 6
			if bits >= 8 then
				bits -= 8
				local div = 2 ^ bits
				putAlpha(math.floor(value / div))
				value %= div
			end
		end
	end
	assert(n == 32688, "OpenFront sprite mask length")
	-- Original: structure.frag.glsl shapeSDF. Six code-drawn masks share the
	-- atlas with the original glyphs and have no third-party image dependency.
	for shape = 0, 5 do
		for yy = 0, 63 do for xx = 0, 63 do
			local px, py = (xx + .5) / 64 - .5, (yy + .5) / 64 - .5
			local inside
			if shape == 0 then inside = px * px + py * py <= .45 ^ 2
			elseif shape == 4 then inside = math.max(math.abs(px), math.abs(py)) <= .45 * math.sqrt(2) / 2
			else
				local sides = if shape == 1 then 5 elseif shape == 2 then 6 elseif shape == 3 then 8 else 3
				local rot = if shape == 1 or shape == 5 then math.pi / 2 elseif shape == 2 then math.pi / 6 else 0
				local half = math.pi / sides
				local angle = (math.atan2(py, px) - rot + half) % (2 * half) - half
				inside = math.sqrt(px * px + py * py) * math.cos(angle) <= .45 * math.cos(half)
			end
			local off = ((120 + yy) * Atlas.width + shape * 64 + xx) * 4
			buffer.writeu8(pixels, off, 255); buffer.writeu8(pixels, off + 1, 255)
			buffer.writeu8(pixels, off + 2, 255); buffer.writeu8(pixels, off + 3, if inside then 255 else 0)
		end end
	end
	-- Original: selection-box.frag, two parity phases of its 13-tile checker.
	for phase=0,1 do for y=0,12 do for x=0,12 do
		local edge=x==0 or x==12 or y==0 or y==12
		local alpha=if edge and (x+y+phase)%2==0 then 255 else 0
		buffer.writeu32(pixels,((120+y)*Atlas.width+384+phase*16+x)*4,0x00ffffff+alpha*16777216)
	end end end
	-- Source railroad.frag 3x3 detail mask and the existing coarse half-tile
	-- segments, packed into unused atlas cells. One image replaces seven GUIs.
	for kind=1,6 do
		for y=0,2 do for x=0,2 do
			local hit=(kind==1 and (x==0 or x==2)) or (kind==2 and (y==0 or y==2))
				or (kind==3 and (y==0 or x==0)) or (kind==4 and (y==0 or x==2))
				or (kind==5 and (y==2 or x==0)) or (kind==6 and (y==2 or x==2)) or (x==1 and y==1)
			if hit then buffer.writeu32(pixels,((56+y)*Atlas.width+384+(kind-1)*16+x)*4,4294967295) end
		end end
		for y=0,1 do for x=0,1 do
			local hit=kind<=2 or (kind==3 and (y==0 or x==0)) or (kind==4 and (y==0 or x==1))
				or (kind==5 and (y==1 or x==0)) or (kind==6 and (y==1 or x==1))
			if hit then buffer.writeu32(pixels,((72+y)*Atlas.width+384+(kind-1)*16+x)*4,4294967295) end
		end end
	end
	-- Original Conquest cannon glyph and diamond, in unused cells. The 32px
	-- glyph avoids the rail masks at y=56/72; existing atlas dimensions stay.
	for y=0,31 do for x=0,31 do
		local px,py=(x+.5)/32-.5,(y+.5)/32-.5
		local ax,ay,bx,by=-.19,.06,.28,-.23
		local dx,dy=bx-ax,by-ay
		local along=math.clamp(((px-ax)*dx+(py-ay)*dy)/(dx*dx+dy*dy),0,1)
		local barrel=math.sqrt((px-ax-along*dx)^2+(py-ay-along*dy)^2)-.065
		local wheels=math.min(math.sqrt((px+.18)^2+(py-.24)^2),math.sqrt((px-.12)^2+(py-.24)^2))-.08
		local axle=math.max(math.abs(px+.03)-.23,math.abs(py-.14)-.045)
		local alpha=math.clamp(.5-math.min(barrel,wheels,axle)*32,0,1)
		buffer.writeu32(pixels,((80+y)*Atlas.width+480+x)*4,0x00ffffff+math.floor(alpha*255+.5)*16777216)
	end end
	for y=0,63 do for x=0,63 do
		local d=math.abs((x+.5)/64-.5)+math.abs((y+.5)/64-.5)
		local alpha=math.clamp((.45-d)*64+.5,0,1)
		buffer.writeu32(pixels,((120+y)*Atlas.width+448+x)*4,0x00ffffff+math.floor(alpha*255+.5)*16777216)
	end end
	for column=6,8,2 do for y=0,31 do for x=0,31 do
		local px,py=(x+.5)/32-.5,(y+.5)/32-.5
		local alpha=math.clamp((.45-Atlas.arsenalDistance(column,px,py))*32+.5,0,1)
		local shapeX=if column==6 then 192 else 224
		buffer.writeu32(pixels,(y*Atlas.width+shapeX+x)*4,0x00ffffff+math.floor(alpha*255+.5)*16777216)
		local glyph=false
		if column==6 then
			glyph=(math.abs(py)<.19 and math.abs(py)>.12 and math.abs(px)<.39)
				or (math.abs(py)<.045 and math.abs(px)<.36 and math.floor((px+.36)*16)%4<2)
		else
			local dx,dy=.51,-.36
			local t=math.clamp(((px+.22)*dx+(py-.10)*dy)/(dx*dx+dy*dy),0,1)
			glyph=(px+.22-t*dx)^2+(py-.10-t*dy)^2<.065^2
				or (math.abs(px)<.23 and py>.21 and py<.31) or (math.abs(px)<.08 and py>.08 and py<.25)
		end
		local glyphX=if column==6 then 256 else 288
		buffer.writeu32(pixels,(y*Atlas.width+glyphX+x)*4,if glyph then 4294967295 else 0x00ffffff)
	end end end
	-- Original top-down bomber silhouette: fuselage, broad wings and tail.
	for y=0,12 do for x=0,12 do
		local dx=math.abs(x-6)
		local hit=(dx<=1 and y>=1 and y<=11) or (y>=4 and y<=6 and dx<=2+(y-4)*2)
			or (y>=9 and y<=10 and dx<=3)
		if hit then buffer.writeu32(pixels,(y*Atlas.width+156+x)*4,4294967295) end
	end end
	-- Original smooth transport and canopy masks in spare cells. Four samples
	-- per pixel soften the outline without another image or a live art upload.
	for shape=0,1 do for y=0,31 do for x=0,31 do
		local hits=0
		for sy=0,1 do for sx=0,1 do
			local px,py=(x+(sx+.5)/2)/32-.5,(y+(sy+.5)/2)/32-.5
			local hit
			if shape==0 then
				local dx=math.abs(px)
				hit=(dx<.065 and py>-.43 and py<.40)
					or (dx<.44 and py>-.14+dx*.22 and py<.045+dx*.10)
					or (dx>.20 and dx<.255 and py>-.23 and py<.13)
					or (dx<.22 and py>.25+dx*.12 and py<.34+dx*.12)
			else
				local dome=px*px+(py+.10)^2<.36^2 and py<-.08
				local lines=py>=-.08 and py<.29 and (math.abs(math.abs(px)-(.30-(py+.08)*.66))<.018 or math.abs(px)<.013)
				hit=dome or lines or (math.abs(px)<.075 and py>=.27 and py<.39)
			end
			if hit then hits+=1 end
		end end
		buffer.writeu32(pixels,(y*Atlas.width+320+shape*32+x)*4,0x00ffffff+math.floor(hits*255/4+.5)*16777216)
	end end end
	-- Original casemate gun: low sloped bunker and seaward barrel, plus an
	-- octagonal plate. Two spare cells, no atlas growth or separate upload.
	for y=0,31 do for x=0,31 do
		local px,py=(x+.5)/32-.5,(y+.5)/32-.5
		local alpha=math.clamp((.45-Atlas.arsenalDistance(9,px,py))*32+.5,0,1)
		buffer.writeu32(pixels,(y*Atlas.width+384+x)*4,0x00ffffff+math.floor(alpha*255+.5)*16777216)
		local bunker=py>=-.08 and py<=.29 and px>=-.39+(py-.29)*-.28 and px<=.19+(py-.29)*.28
		local slit=py>=.04 and py<=.10 and px>=-.28 and px<=.08
		local barrel=math.abs(py+.06)<.045 and px>=.04 and px<=.43
		local base=py>=.28 and py<=.35 and math.abs(px+.1)<.35
		buffer.writeu32(pixels,(y*Atlas.width+416+x)*4,if (bunker and not slit) or barrel or base then 4294967295 else 0x00ffffff)
	end end
	-- Original sandbag courses and angular trench, in the last two spare
	-- top-band cells. These are presentation masks, never gameplay geometry.
	for y=0,31 do for x=0,31 do
		local px,py=(x+.5)/32-.5,(y+.5)/32-.5
		local alpha=math.clamp((.45-Atlas.arsenalDistance(10,px,py))*32+.5,0,1)
		buffer.writeu32(pixels,(y*Atlas.width+448+x)*4,0x00ffffff+math.floor(alpha*255+.5)*16777216)
		local bags=false
		for row=0,1 do for bag=0,2 do
			local cx=-.27+bag*.25+row*.06
			if math.abs(px-cx)<.11 and math.abs(py-(-.19+row*.15))<.06 then bags=true end
		end end
		local trench=(math.abs(py-.13)<.035 and px>-.30 and px<.13)
			or (math.abs(px-.13)<.035 and py>.10 and py<.32)
		buffer.writeu32(pixels,(y*Atlas.width+480+x)*4,if bags or trench then 4294967295 else 0x00ffffff)
	end end
	return pixels
end

-- Original: atlas column order in UnitPass/StructurePass.
function Atlas.unitRect(column: number, band: number): (number, number, number, number)
	return column * 13, band * 13, 13, 13
end
function Atlas.iconRect(column: number): (number, number, number, number)
	if column==10 then return 480,0,32,32 end
	if column==9 then return 416,0,32,32 end
	if column==7 then return 480,80,32,32 end
	if column==6 then return 256,0,32,32 end
	if column==8 then return 288,0,32,32 end
	return column * 64, 56, 64, 64
end
function Atlas.shapeRect(column: number): (number, number, number, number)
	if column==10 then return 448,0,32,32 end
	if column==9 then return 384,0,32,32 end
	if column==6 then return 192,0,32,32 end
	if column==8 then return 224,0,32,32 end
	return column * 64, 120, 64, 64
end
return Atlas
