--!strict
-- Original static-contour compositor. Only colours change during play; the
-- shape/templates are immutable and shared by land, sea and political paint.
local Geometry=require(script.Parent.CoastGeometry)
local C={}
local read8,read32,write32=buffer.readu8,buffer.readu32,buffer.writeu32
local band,rshift=bit32.band,bit32.rshift

function C.new(g: any,resolution: number,maxBytes: number): any
	local cell=Geometry.chunk*resolution+2
	local columns=math.floor(1024/cell)
	local capacity=columns^2
	local pages,slots={},{}
	local bytes=0
	for first=1,#g.chunks,capacity do
		local count=math.min(capacity,#g.chunks-first+1)
		local width=math.min(columns,count)*cell
		local height=math.ceil(count/columns)*cell
		bytes+=width*height*4
		if bytes>maxBytes then return nil end
		table.insert(pages,{width=width,height=height,pixels=nil,dirty=false,image=nil,content=nil,uploaded=false})
		for i=0,count-1 do slots[first+i]={page=#pages,x=i%columns*cell+1,y=math.floor(i/columns)*cell+1} end
	end
	local queues={}; for i=1,#pages do queues[i]={items={},head=1} end
	return {geometry=g,resolution=resolution,pages=pages,slots=slots,nativeBytes=bytes,
		samples=buffer.create(g.count*16),skipped=0,
		flags=buffer.create(g.count),queues=queues,pendingCount=0,nextPage=1,initial=true,initialCursor=0,
		dirtyChunks={},dirtyOrder={},dirtyHead=1,
		composeMs=0,composed=0,uploadedPixels=0,uploads=0,scratch=nil,scratchBytes=0}
end
function C.mark(s: any,x: number,y: number,w: number,h: number)
	if s.initial and s.initialCursor==0 then return end -- initial pass samples after the full base paint
	Geometry.visit(s.geometry,x,y,w,h,function(id)
		if read8(s.flags,id)==0 then
			buffer.writeu8(s.flags,id,1)
			local page=s.slots[read32(s.geometry.chunkIDs,id*4)].page
			table.insert(s.queues[page].items,id); s.pendingCount+=1
		end
	end)
end
local function source(core: any,x: number,y: number): number
	x,y=math.clamp(x,0,core.width-1),math.clamp(y,0,core.height-1)
	local p=core.pages[math.floor(y/1024)*core.pageColumns+math.floor(x/1024)+1]
	return read32(p.pixels,((y-p.y)*p.width+x-p.x)*4)
end
local function blend(a: number,b: number,c: number,alpha: number,coast: number): number
	if alpha==255 then return bit32.bor(a,4278190080) end
	if coast==0 then return bit32.bor(c,4278190080) end
	if alpha==0 and coast==255 then return bit32.bor(b,4278190080) end
	local near,far=coast-alpha,255-coast
	return math.floor((band(a,255)*alpha+band(b,255)*near+band(c,255)*far)/255+.5)
		+math.floor((band(rshift(a,8),255)*alpha+band(rshift(b,8),255)*near+band(rshift(c,8),255)*far)/255+.5)*256
		+math.floor((band(rshift(a,16),255)*alpha+band(rshift(b,16),255)*near+band(rshift(c,16),255)*far)/255+.5)*65536+4278190080
end
function C.cell(s: any,core: any,id: number): (number,number,number,number,number)
	local g,r=s.geometry,s.resolution
	local ref=read32(g.refs,id*4); local ax,ay=ref%(g.width+1)-1,math.floor(ref/(g.width+1))-1
	local chunkID=read32(g.chunkIDs,id*4); local slot=s.slots[chunkID]
	local page=s.pages[slot.page]
	if not page.pixels then page.pixels=buffer.create(page.width*page.height*4) end
	local x0,y0=slot.x+(ax+1)%Geometry.chunk*r,slot.y+(ay+1)%Geometry.chunk*r
	local pixels=g.templates[r][read32(g.patterns,id*4)]
	local colors={source(core,ax,ay),source(core,ax+1,ay),source(core,ax,ay+1),source(core,ax+1,ay+1)}
	local same=not s.initial
	for i=1,4 do
		local offset=id*16+(i-1)*4
		if read32(s.samples,offset)~=colors[i] then same=false; write32(s.samples,offset,colors[i]) end
	end
	if same then s.skipped+=1; return slot.page,x0,y0,0,0 end
	for y=0,r-1 do for x=0,r-1 do
		local off=(y*r+x)*3
		local a,near,codes=read8(pixels,off),read8(pixels,off+1),read8(pixels,off+2)
		local rgb=blend(colors[band(codes,3)+1],colors[band(rshift(codes,2),3)+1],colors[rshift(codes,4)+1],a,near)
		write32(page.pixels,((y0+y)*page.width+x0+x)*4,rgb)
	end end
	-- Extruded gutters prevent transparent atlas seams at chunk boundaries.
	local extent=Geometry.chunk*r
	local left,right=x0==slot.x,x0+r==slot.x+extent
	local top,bottom=y0==slot.y,y0+r==slot.y+extent
	if left or right then for y=0,r-1 do
		if left then write32(page.pixels,((y0+y)*page.width+x0-1)*4,read32(page.pixels,((y0+y)*page.width+x0)*4)) end
		if right then write32(page.pixels,((y0+y)*page.width+x0+r)*4,read32(page.pixels,((y0+y)*page.width+x0+r-1)*4)) end
	end end
	if top or bottom then
		local lo,hi=x0-(if left then 1 else 0),x0+r+(if right then 1 else 0)
		if top then buffer.copy(page.pixels,((y0-1)*page.width+lo)*4,page.pixels,(y0*page.width+lo)*4,(hi-lo)*4) end
		if bottom then buffer.copy(page.pixels,((y0+r)*page.width+lo)*4,page.pixels,((y0+r-1)*page.width+lo)*4,(hi-lo)*4) end
	end
	page.dirty=true; s.composed+=1
	return slot.page,x0-(if left then 1 else 0),y0-(if top then 1 else 0),r+(if left or right then 1 else 0),r+(if top or bottom then 1 else 0)
end
function C.prepare(s: any,core: any,budgetMs: number,maxCells: number,maxUploadPixels: number?,maxWrites: number?): any
	local started=os.clock()
	if s.initial then
		if core.pending>0 then return nil end
		local count=0
		while s.initialCursor<s.geometry.count do
			C.cell(s,core,s.initialCursor); s.initialCursor+=1; count+=1
			if count>=maxCells or (os.clock()-started)*1000>=budgetMs then break end
		end
		s.composeMs+=(os.clock()-started)*1000
		if s.initialCursor<s.geometry.count then return nil end
		for id,page in s.pages do
			if not page.uploaded then
				page.dirty=false; page.uploaded=true
				return {page=id,x=0,y=0,w=page.width,h=page.height,pixels=page.pixels}
			end
		end
		s.initial=false
		return nil
	end
	if not s.dirtyOrder[s.dirtyHead] then
		table.clear(s.dirtyOrder); s.dirtyHead=1
		if s.pendingCount==0 then return nil end
		local pageID=0
		for i=0,#s.pages-1 do
			local index=(s.nextPage+i-1)%#s.pages+1; local q=s.queues[index]
			if q.items[q.head]~=nil then pageID=index; break end
		end
		assert(pageID>0,'coast pending index inconsistent')
		local queue=s.queues[pageID]
		local count=0
		while queue.head<=#queue.items do
			local id=queue.items[queue.head]; local chunk=read32(s.geometry.chunkIDs,id*4)
			buffer.writeu8(s.flags,id,0); queue.head+=1; s.pendingCount-=1
			local _,x,y,w,h=C.cell(s,core,id)
			if w>0 then
				local rect=s.dirtyChunks[chunk]
				if rect then rect.x0=math.min(rect.x0,x); rect.y0=math.min(rect.y0,y); rect.x1=math.max(rect.x1,x+w); rect.y1=math.max(rect.y1,y+h)
				else s.dirtyChunks[chunk]={x0=x,y0=y,x1=x+w,y1=y+h}; table.insert(s.dirtyOrder,chunk) end
			end
			count+=1
			if count>=maxCells or (os.clock()-started)*1000>=budgetMs then break end
		end
		if queue.head>#queue.items then table.clear(queue.items); queue.head=1
		elseif queue.head>256 then
			local compact={}; for i=queue.head,#queue.items do table.insert(compact,queue.items[i]) end
			queue.items,queue.head=compact,1
		end
		s.nextPage=pageID%#s.pages+1
	end
	s.composeMs+=(os.clock()-started)*1000
	if not s.dirtyOrder[s.dirtyHead] then return nil end
	local pageID=s.slots[s.dirtyOrder[s.dirtyHead]].page
	local writes={}; local pixels=0
	while s.dirtyOrder[s.dirtyHead] do
		if #writes>=(maxWrites or math.huge) then break end
		local chunk=s.dirtyOrder[s.dirtyHead]
		if s.slots[chunk].page~=pageID then break end
		local rect=s.dirtyChunks[chunk]; local w,h=rect.x1-rect.x0,rect.y1-rect.y0
		if #writes>0 and pixels+w*h>(maxUploadPixels or math.huge) then break end
		table.insert(writes,{x=rect.x0,y=rect.y0,w=w,h=h}); pixels+=w*h
		s.dirtyChunks[chunk]=nil; s.dirtyHead+=1
	end
	return {page=pageID,writes=writes}
end
function C.pending(s: any): boolean return s.initial or s.pendingCount>0 or s.dirtyOrder[s.dirtyHead]~=nil end
function C.bytes(s: any): number
	local n=buffer.len(s.flags)+buffer.len(s.samples)+s.scratchBytes
	for _,page in s.pages do if page.pixels then n+=buffer.len(page.pixels) end end
	return n
end
return C
