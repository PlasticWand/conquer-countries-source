--!strict
-- Original presentation experiment, 2026-10-29. Edge-only antialiasing at the
-- existing one-pixel/tile resolution. This cannot produce sub-tile curves.
local Edge = {}
local read8,read16=buffer.readu8,buffer.readu16
local band,btest=bit32.band,bit32.btest
local function identity(s: any, x: number, y: number): number
	local tile=y*s.width+x
	return band(read16(s.tileState,tile*2),4095)+(if btest(read8(s.terrain,tile),128) then 4096 else 0)
end
function Edge.pixel(s: any, x: number, y: number, owners: {[number]: boolean}, shade: any): number
	local center=identity(s,x,y)
	local boundary=false
	for dy=-1,1 do for dx=-1,1 do
		if identity(s,math.clamp(x+dx,0,s.width-1),math.clamp(y+dy,0,s.height-1))~=center then boundary=true; break end
	end; if boundary then break end end
	local base=shade(s,x,y,owners)
	if not boundary then return base end
	local r,g,b=0,0,0
	for dy=-1,1 do for dx=-1,1 do
		local weight=(if dx==0 then 6 else 1)*(if dy==0 then 6 else 1)
		local c=if dx==0 and dy==0 then base else shade(s,math.clamp(x+dx,0,s.width-1),math.clamp(y+dy,0,s.height-1),owners)
		r+=band(c,255)*weight; g+=band(bit32.rshift(c,8),255)*weight; b+=band(bit32.rshift(c,16),255)*weight
	end end
	return math.floor(r/64+.5)+math.floor(g/64+.5)*256+math.floor(b/64+.5)*65536+4278190080
end
return Edge
