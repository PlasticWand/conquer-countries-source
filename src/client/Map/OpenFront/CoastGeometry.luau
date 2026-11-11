--!strict
-- Original presentation geometry, 2026-10-29. The confirmed land mask is
-- sampled, never edited (including the source near-shore water band).
-- Catmull-Rom isocontours interpolate tile centres;
-- a tile's centre always retains its original land/sea classification.
local G = {chunk=32}
local read8,read32=buffer.readu8,buffer.readu32
local cached: any=nil -- one immutable map; no native images survive a match

local function terrainAt(mask: buffer,w: number,h: number,x: number,y: number): number
	return read8(mask,math.clamp(y,0,h-1)*w+math.clamp(x,0,w-1))
end
local function weights(t: number): ({number},{number})
	local t2,t3=t*t,t*t*t
	return {-.5*t+t2-.5*t3,1-2.5*t2+1.5*t3,.5*t+2*t2-1.5*t3,-.5*t2+.5*t3},
		{-.5+2*t-1.5*t2,-5*t+4.5*t2,.5+4*t-4.5*t2,-t+1.5*t2}
end
function G.template(pattern: number,resolution: number): buffer
	local pixels=buffer.create(resolution*resolution*3)
	local nodes,near={},{}
	local lp,cp=bit32.band(pattern,65535),bit32.rshift(pattern,16)
	for i=0,15 do nodes[i+1]=bit32.band(bit32.rshift(lp,i),1); near[i+1]=bit32.band(bit32.rshift(cp,i),1) end
	local central={6,7,10,11}
	for y=0,resolution-1 do for x=0,resolution-1 do
		local u,v=(x+.5)/resolution,(y+.5)/resolution
		local wx,dx=weights(u); local wy,dy=weights(v)
		local f,gx,gy,coast,cx,cy=0,0,0,0,0,0
		for j=1,4 do
			local row,derivative,cr,cd=0,0,0,0
			for i=1,4 do
				local n=(j-1)*4+i
				row+=nodes[n]*wx[i]; derivative+=nodes[n]*dx[i]
				cr+=near[n]*wx[i]; cd+=near[n]*dx[i]
			end
			f+=row*wy[j]; gx+=derivative*wy[j]; gy+=row*dy[j]
			coast+=cr*wy[j]; cx+=cd*wy[j]; cy+=cr*dy[j]
		end
		local alpha=math.clamp(.5+(f-.5)*resolution/math.max(.001,math.sqrt(gx*gx+gy*gy)),0,1)
		local nearAlpha=math.max(alpha,math.clamp(.5+(coast-.5)*resolution/math.max(.001,math.sqrt(cx*cx+cy*cy)),0,1))
		local nearestLand,nearestShore,nearestSea,ld,nd,sd=0,0,0,math.huge,math.huge,math.huge
		for i=0,3 do
			local d=(u-i%2)^2+(v-math.floor(i/2))^2
			local n=central[i+1]
			if nodes[n]==1 then if d<ld then ld,nearestLand=d,i end
			elseif near[n]==1 then if d<nd then nd,nearestShore=d,i end
			elseif d<sd then sd,nearestSea=d,i end
		end
		if nd==math.huge then nearestShore=nearestSea end
		local off=(y*resolution+x)*3
		buffer.writeu8(pixels,off,math.floor(alpha*255+.5))
		buffer.writeu8(pixels,off+1,math.floor(nearAlpha*255+.5))
		buffer.writeu8(pixels,off+2,nearestLand+nearestShore*4+nearestSea*16)
	end end
	return pixels
end

function G.new(terrain: buffer,width: number,height: number,resolution: number): any
	assert(resolution==2 or resolution==4,'coast resolution must be 2 or 4')
	return {terrain=terrain,width=width,height=height,resolution=resolution,stage='mask',cursor=0,
		mask=buffer.create(width*height),same=cached~=nil and cached.width==width and cached.height==height,
		previous=cached,refs={},patterns={},keys={},keySet={},rows={},templates={},buildMs=0,cacheHit=false,done=false}
end
local function seal(s: any)
	local g=s.geometry
	s.done=true; s.stage='done'; s.terrain=nil
	s.refs,s.patterns,s.keys,s.keySet,s.rows,s.previous={},{},{},{},{},nil
	if G.bytes(g)<=16*1024*1024 then cached=g end
end
local function finish(s: any)
	local keys=s.keys; table.sort(keys)
	local chunks,ids={},{}
	local cols=math.ceil((s.width+1)/G.chunk)
	for _,key in keys do
		ids[key]=#chunks+1
		table.insert(chunks,{x=key%cols*G.chunk-.5,y=math.floor(key/cols)*G.chunk-.5})
	end
	local count=#s.refs
	local refs,patterns,chunkIDs=buffer.create(count*4),buffer.create(count*4),buffer.create(count*4)
	local rows=buffer.create((s.height+2)*4)
	for i=0,s.height+1 do buffer.writeu32(rows,i*4,s.rows[i] or count) end
	local g={width=s.width,height=s.height,mask=s.mask,refs=refs,patterns=patterns,chunkIDs=chunkIDs,
		rows=rows,chunks=chunks,count=count,templates={[s.resolution]=s.templates}}
	s.geometry=g; s.packIDs=ids; s.cursor=0; s.stage='pack'
	if count==0 then seal(s) end
end
function G.step(s: any,budgetMs: number,maxVisits: number): boolean
	if s.done then return true end
	local start,visits=os.clock(),0
	while visits<maxVisits do
		local cost,check=1,false
		if s.stage=='mask' then
			local n=s.cursor; local size=math.min(4096,maxVisits-visits,s.width*s.height-n)
			buffer.copy(s.mask,n,s.terrain,n,size)
			if s.same and buffer.readstring(s.terrain,n,size)~=buffer.readstring(s.previous.mask,n,size) then s.same=false end
			s.cursor+=size; cost=size; check=true
			if s.cursor==s.width*s.height then
				if s.same then
					s.geometry=s.previous; s.mask=nil; s.previous=nil; s.cacheHit=true
					if s.geometry.templates[s.resolution] or s.geometry.count==0 then
						s.geometry.templates[s.resolution]=s.geometry.templates[s.resolution] or {}; s.done=true; s.stage='done'; s.terrain=nil
					else s.stage='templates'; s.cursor=0 end
				else s.stage='scan'; s.cursor=0 end
			end
		elseif s.stage=='scan' then
			local n=s.cursor; local x,y=n%(s.width+1)-1,math.floor(n/(s.width+1))-1
			if x==-1 then
				s.rows[y+1]=#s.refs; s.rowTop=math.max(0,y)*s.width; s.rowBottom=math.min(s.height-1,y+1)*s.width
			end
			local left,right=if x<0 then 0 else x,if x+1==s.width then x else x+1
			local a,b=bit32.band(read8(s.mask,s.rowTop+left),192),bit32.band(read8(s.mask,s.rowTop+right),192)
			local c,d=bit32.band(read8(s.mask,s.rowBottom+left),192),bit32.band(read8(s.mask,s.rowBottom+right),192)
			a,b=if a>=128 then 128 else a,if b>=128 then 128 else b
			c,d=if c>=128 then 128 else c,if d>=128 then 128 else d
			if a~=b or a~=c or a~=d then
				local lp,cp=0,0
				for dy=-1,2 do for dx=-1,2 do
					local raw=terrainAt(s.mask,s.width,s.height,x+dx,y+dy); local bit=2^((dy+1)*4+dx+1)
					if bit32.btest(raw,128) then lp+=bit end
					if bit32.btest(raw,192) then cp+=bit end
				end end
				local pattern=lp+cp*65536
				table.insert(s.refs,n); table.insert(s.patterns,pattern)
				if not s.templates[pattern] then s.templates[pattern]=G.template(pattern,s.resolution) end
				local cols=math.ceil((s.width+1)/G.chunk)
				local key=math.floor((y+1)/G.chunk)*cols+math.floor((x+1)/G.chunk)
				if not s.keySet[key] then s.keySet[key]=true; table.insert(s.keys,key) end
			end
			s.cursor+=1
			if s.cursor==(s.width+1)*(s.height+1) then finish(s) end
		elseif s.stage=='pack' then
			local i=s.cursor; local g=s.geometry; local ref=s.refs[i+1]
			local x,y=ref%(s.width+1),math.floor(ref/(s.width+1))
			local cols=math.ceil((s.width+1)/G.chunk)
			buffer.writeu32(g.refs,i*4,ref); buffer.writeu32(g.patterns,i*4,s.patterns[i+1])
			buffer.writeu32(g.chunkIDs,i*4,s.packIDs[math.floor(y/G.chunk)*cols+math.floor(x/G.chunk)])
			s.cursor+=1
			if s.cursor==g.count then s.packIDs=nil; seal(s) end
		elseif s.stage=='templates' then
			local g=s.geometry
			if not g.templates[s.resolution] then g.templates[s.resolution]={} end
			local pattern=read32(g.patterns,s.cursor*4)
			if not g.templates[s.resolution][pattern] then g.templates[s.resolution][pattern]=G.template(pattern,s.resolution) end
			s.cursor+=1
			if s.cursor==g.count then
				s.done=true; s.stage='done'; s.terrain=nil
				-- A second device resolution adds templates to this same geometry.
				if cached==g and G.bytes(g)>16*1024*1024 then cached=nil end
			end
		end
		visits+=cost
		if s.done or ((check or visits%64==0) and (os.clock()-start)*1000>=budgetMs) then break end
	end
	s.buildMs+=(os.clock()-start)*1000
	return s.done
end
function G.bytes(g: any): number
	local n=buffer.len(g.mask)+buffer.len(g.refs)+buffer.len(g.patterns)+buffer.len(g.chunkIDs)+buffer.len(g.rows)
	for _,templates in g.templates do for _,pixels in templates do n+=buffer.len(pixels) end end
	return n
end
function G.clearCache() cached=nil end
function G.cacheBytes(): number return if cached then G.bytes(cached) else 0 end

-- Row-indexed invalidation: only quads sampling the changed source rectangle.
-- There is no territory scan or contour regeneration during normal play.
function G.visit(g: any,x0: number,y0: number,w: number,h: number,callback: (number)->())
	local stride=g.width+1
	for y=math.max(0,y0),math.min(g.height,y0+h) do
		local lo,hi=read32(g.rows,y*4),read32(g.rows,(y+1)*4)
		local last=hi
		local left=math.max(0,x0)
		while lo<hi do
			local mid=math.floor((lo+hi)/2)
			if read32(g.refs,mid*4)%stride<left then lo=mid+1 else hi=mid end
		end
		while lo<last and read32(g.refs,lo*4)%stride<=x0+w do callback(lo); lo+=1 end
	end
end
return G
