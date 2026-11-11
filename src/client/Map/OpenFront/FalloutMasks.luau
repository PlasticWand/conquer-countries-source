--!strict
-- Cosmetic masks for confirmed fallout. A coarse pixel is filled only when
-- every covered tile is fallout: reduced resolution never lights clean land.
local Masks={}
Masks.__index=Masks
function Masks.new(width:number,height:number,size:number,cap:number,lifetime:number):any
	assert(size>0 and size*size<=65536,'mask queue uses u16 indices')
	return setmetatable({width=width,height=height,size=size,cap=cap,lifetime=lifetime,slots={},cursor=0,
		generation=0,visits=0},Masks)
end
local function mark(self:any,m:any,index:number)
	if buffer.readu8(m.dirty,index)~=0 then return end
	buffer.writeu8(m.dirty,index,1)
	buffer.writeu16(m.queue,m.tail*2,index); m.tail=(m.tail+1)%(self.size*self.size); m.remaining+=1
end
function Masks.add(self:any,tile:number,radius:number,now:number):any
	if tile<0 or tile>=self.width*self.height or radius<=0 then return nil end
	local slot=1
	for i=1,self.cap do
		if not self.slots[i] then slot=i; break end
		if self.slots[i].start<self.slots[slot].start then slot=i end
	end
	self.generation+=1
	local n=self.size*self.size
	local step=math.max(1,math.ceil((math.ceil(radius)*2+1)/self.size))
	local extent=math.min(self.size,math.ceil((math.ceil(radius)*2+1)/step))
	local cx,cy=tile%self.width,math.floor(tile/self.width)
	local m={slot=slot,generation=self.generation,start=now,revision=1,uploaded=0,radius=radius,cx=cx,cy=cy,
		x=cx-math.ceil(radius),y=cy-math.ceil(radius),step=step,
		pixels=buffer.create(n*4),dirty=buffer.create(n),queue=buffer.create(n*2),head=0,tail=0,remaining=extent^2,
		initialX=0,initialY=0,initialExtent=extent}
	-- Initial work is implicit and still consumed through the same pixel/time
	-- budget. Filling row flags avoids thousands of queue writes at impact time.
	for y=0,extent-1 do buffer.fill(m.dirty,y*self.size,1,extent) end
	self.slots[slot]=m
	return m
end
function Masks.tilesChanged(self:any,tiles:{number}):{number}
	local affected={}
	if next(self.slots)==nil or #tiles==0 then return affected end
	local bulk=#tiles>=1024
	local sorted=bulk
	if bulk then for i=2,#tiles do if tiles[i]<tiles[i-1] then sorted=false;break end end end
	local function lowerBound(value:number):number
		local lo,hi=1,#tiles
		while lo<=hi do local mid=math.floor((lo+hi)/2)
			if tiles[mid]<value then lo=mid+1 else hi=mid-1 end
		end
		return lo
	end
	for slot,m in self.slots do
		-- A large new blast can invalidate thousands of pixels in several old
		-- masks. One exact hit schedules a full implicit refresh through step's
		-- existing pixel/deadline budget, instead of expanding the whole delta
		-- against every mask synchronously. Output still samples confirmed bits.
		if bulk then
			if m.initialY==0 and m.remaining==m.initialExtent^2 then continue end
			local hit=false
			if sorted then
				-- Wire/run order is usually row-major. Search the small mask's row
				-- intervals; a larger surrounding blast may change NO covered tile.
				-- Validate ordering once above; arbitrary lists retain the exact scan.
				local radius=math.ceil(m.radius)
				for y=math.max(0,m.cy-radius),math.min(self.height-1,m.cy+radius) do
					local first=y*self.width+math.max(0,m.cx-radius)
					local last=y*self.width+math.min(self.width-1,m.cx+radius)
					local i=lowerBound(first)
					while i<=#tiles and tiles[i]<=last do
						if (tiles[i]%self.width-m.cx)^2+(y-m.cy)^2<=m.radius^2 then hit=true;break end
						i+=1
					end
					if hit then break end
				end
			else
				for _,tile in tiles do local tx,ty=tile%self.width,math.floor(tile/self.width)
					if (tx-m.cx)^2+(ty-m.cy)^2<=m.radius^2 then hit=true;break end
				end
			end
			if hit then
				buffer.fill(m.dirty,0,0)
				for y=0,m.initialExtent-1 do buffer.fill(m.dirty,y*self.size,1,m.initialExtent) end
				m.initialX,m.initialY,m.head,m.tail,m.remaining=0,0,0,0,m.initialExtent^2
				m.revision+=1;table.insert(affected,slot)
			end
			continue
		end
		local changed=false
		for _,tile in tiles do
			local tx,ty=tile%self.width,math.floor(tile/self.width)
			local px,py=math.floor((tx-m.x)/m.step),math.floor((ty-m.y)/m.step)
			if px>=0 and py>=0 and px<self.size and py<self.size and (tx-m.cx)^2+(ty-m.cy)^2<=m.radius^2 then
				mark(self,m,py*self.size+px); changed=true
			end
		end
		if changed then m.revision+=1; table.insert(affected,slot) end
	end
	return affected
end
function Masks.expire(self:any,now:number)
	for slot,m in self.slots do if now-m.start>=self.lifetime then self.slots[slot]=nil end end
end
function Masks.step(self:any,states:buffer,budget:number,milliseconds:number?):number
	local visits=0
	local deadline=os.clock()+(milliseconds or math.huge)/1000
	local empty=0
	while visits<budget and empty<self.cap and os.clock()<deadline do
		self.cursor=self.cursor%self.cap+1
		local m=self.slots[self.cursor]
		if not m or m.remaining==0 then empty+=1; continue end
		empty=0
		local index
		if m.initialY<m.initialExtent then
			index=m.initialY*self.size+m.initialX; m.initialX+=1
			if m.initialX==m.initialExtent then m.initialX=0; m.initialY+=1 end
		else index=buffer.readu16(m.queue,m.head*2); m.head=(m.head+1)%(self.size*self.size) end
		m.remaining-=1; buffer.writeu8(m.dirty,index,0)
		local x,y=m.x+(index%self.size)*m.step,m.y+math.floor(index/self.size)*m.step
		local covered=true
		for dy=0,m.step-1 do for dx=0,m.step-1 do
			local tx,ty=x+dx,y+dy
			if tx<0 or ty<0 or tx>=self.width or ty>=self.height or (tx-m.cx)^2+(ty-m.cy)^2>m.radius^2
				or bit32.band(buffer.readu16(states,(ty*self.width+tx)*2),8192)==0 then covered=false; break end
		end; if not covered then break end end
		buffer.writeu32(m.pixels,index*4,if covered then 0xff55dd55 else 0)
		visits+=1
	end
	self.visits+=visits
	return visits
end
function Masks.clear(self:any) table.clear(self.slots); self.cursor=0 end
return Masks
