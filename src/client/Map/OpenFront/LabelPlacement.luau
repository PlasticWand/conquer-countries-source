--!strict
-- Screen-space annotation placement, independent of sim anchors and GUI layout.
export type Rect = {x: number, y: number, w: number, h: number}
local Placement = {}

function Placement.intersects(a: Rect, b: Rect, gap: number?): boolean
	local g = gap or 0
	return a.x < b.x+b.w+g and a.x+a.w > b.x-g and a.y < b.y+b.h+g and a.y+a.h > b.y-g
end

function Placement.clear(rect: Rect, bounds: Rect, obstacles: {Rect}, gap: number?): boolean
	if rect.x<bounds.x or rect.y<bounds.y or rect.x+rect.w>bounds.x+bounds.w or rect.y+rect.h>bounds.y+bounds.h then return false end
	for _,other in obstacles do if Placement.intersects(rect,other,gap) then return false end end
	return true
end

-- Small fixed candidate set: no unbounded search or dragging an annotation
-- across the map to make it fit. Omit it when all nearby positions are covered.
function Placement.cost(x: number, y: number, bounds: Rect, obstacles: {Rect}): Rect?
	for _,offset in {{-90,25},{24,-22},{-204,-22},{-90,-69},{-90,76},{76,30},{-256,30},
		{-90,128},{204,-22},{-384,-22},{-90,-150}} do
		local rect = {x=x+offset[1],y=y+offset[2],w=180,h=44}
		if Placement.clear(rect,bounds,obstacles,6) then return rect end
	end
	return nil
end

function Placement.own(rect: Rect, bounds: Rect, obstacles: {Rect}): (number?,number?)
	for _,distance in {0,32,64,96} do
		for _,direction in {{0,1},{0,-1},{1,0},{-1,0}} do
			local dx,dy=direction[1]*distance,direction[2]*distance
			if Placement.clear({x=rect.x+dx,y=rect.y+dy,w=rect.w,h=rect.h},bounds,obstacles,6) then return dx,dy end
		end
	end
	return nil,nil
end

return Placement
