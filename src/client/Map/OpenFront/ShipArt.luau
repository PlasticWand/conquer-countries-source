--!strict
-- Original Conquer Countries artwork, 2026-10-29. Analytic top-down hulls;
-- no source/competitor artwork or external image assets are used here.
local Art = {size=256, cell=258, width=516, height=516, columns=2, count=4}
local columns: {[string]: number} = {Transport=0,["Trade Ship"]=1,Warship=2}
function Art.column(kind: string): number?
	return columns[kind]
end

-- Nose is up. RGB is a neutral stencil multiplied by the owner's colour;
-- black rim, shaded deck and the faint wake are baked into the same image.
function Art.sample(column: number, x: number, y: number): (number, number)
	local retreat=column==3
	if retreat then column=2 end
	local length=if column==2 then .68 elseif column==1 then .60 else .55
	local beam=if column==2 then .108 elseif column==1 then .145 else .16
	local bow,stern=-length*.55,length*.45
	local u=(y-bow)/length
	local bowT,sternT=math.clamp(u/.28,0,1),math.clamp((1-u)/.13,0,1)
	local bowWidth=if column==0 then math.sqrt(bowT*(2-bowT)) else math.sin(bowT*math.pi/2)
	local width=beam*math.min(bowWidth,math.sqrt(sternT*(2-sternT)))
	local d=math.min(width-math.abs(x),y-bow,stern-y)
	local alpha=math.clamp(d*Art.size+.5,0,1)
	local ink=.045+.955*math.clamp((d-.014)*Art.size+.5,0,1)
	if alpha>0 then
		local deck=math.abs(x)<beam*.55 and y>bow+length*.25 and y<stern-length*.14
		if deck then
			ink=.64
			if column==2 then
				if math.abs(x)<beam*.35 and y>-.08 and y<.09 then ink=.88 end
				if x*x+(y+.18)^2<.026^2 or x*x+(y-.16)^2<.024^2 then ink=.28 end
				if math.abs(x)<.009 and ((y>-.25 and y<-.18) or (y>.16 and y<.22)) then ink=.28 end
				if retreat then ink*=.08 end
			elseif column==1 then
				if y>.09 then ink=.86 elseif math.floor((y+.12)*32)%2==0 then ink=.48 end
			else
				if y>.035 then ink=.9 elseif math.abs(x)<beam*.4 then ink=.43 end
			end
		end
		if column==2 and math.abs(x)<.007 and ((y>-.27 and y<-.18) or (y>.16 and y<.22)) then ink=.22 end
		return ink,alpha
	end
	local wakeY=y-stern
	if wakeY>0 and y<.49 then
		local fade=(.49-y)/(.49-stern)
		local v=math.abs(math.abs(x)-(.035+wakeY*.42))
		local wake=math.clamp((.012-v)*Art.size+.5,0,1)*fade*.38
		return 1,wake
	end
	return 0,0
end

function Art.heading(tile: number, last: number?, width: number, previous: number?): number
	if last==nil or last==tile then return previous or 0 end
	local dx,dy=tile%width-last%width,math.floor(tile/width)-math.floor(last/width)
	return math.deg(math.atan2(dx,-dy))
end

-- A single atlas for every owner: no per-ship palette entries or GUI pixels.
-- Build slices are bounded separately from the one final displayed upload.
function Art.new(): any
	return {cursor=0,needed=false,pixels=nil,content=nil,image=nil,failed=false}
end
function Art.build(state: any, budgetMs: number, maxPixels: number): boolean
	if not state.needed or state.content or state.failed then return false end
	if not state.pixels then state.pixels=buffer.create(Art.width*Art.height*4) end
	local started,count=os.clock(),0
	while state.cursor<Art.size*Art.size*Art.count do
		local n=state.cursor
		local column=math.floor(n/(Art.size*Art.size))
		local x,y=n%Art.size,math.floor(n/Art.size)%Art.size
		local ink,a=Art.sample(column,(x+.5)/Art.size-.5,(y+.5)/Art.size-.5)
		if a>0 then
			local off=((math.floor(column/Art.columns)*Art.cell+y+1)*Art.width+column%Art.columns*Art.cell+x+1)*4
			local gray=math.floor(ink*255+.5)
			buffer.writeu32(state.pixels,off,gray+gray*256+gray*65536+math.floor(a*255+.5)*16777216)
		end
		state.cursor+=1; count+=1
		if count>=maxPixels or (count%64==0 and (os.clock()-started)*1000>=budgetMs) then break end
	end
	state.buildMs=(state.buildMs or 0)+(os.clock()-started)*1000
	return state.cursor==Art.size*Art.size*Art.count
end
return Art
