--!strict
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/GameImpl.ts, updateBorderStatus), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Original Conquest reach-mask/cache math. Border membership matches OpenFront's
-- four-neighbour ownership border; the authoritative reach comes from the aim.
-- No terrain/path flood: Sabotage measures straight-line tile distance.
local Reach = {}
Reach.__index = Reach
local BLOCK_ROWS = 64

local function same(a:any,b:any):boolean
	if not a or #a~=#b then return false end
	for i,v in a do if v~=b[i] then return false end end
	return true
end
local function enqueue(self:any,kind:string,row:number)
	local versions,queue=self[kind..'Versions'],self[kind..'Queue']
	if versions[row]==nil then table.insert(queue,row) end
	versions[row]=(versions[row] or 0)+1
end
local function borderDirty(self:any,row:number,lo:number,hi:number)
	local old=self.dirtyBounds[row]
	self.dirtyBounds[row]={if old then math.min(lo,old[1]) else lo,if old then math.max(hi,old[2]) else hi}
	enqueue(self,'border',row)
end
local function maskRows(self:any,row:number)
	local lo=math.max(0,math.floor((row-self.reach)*self.mh/self.height)-1)
	local hi=math.min(self.mh-1,math.ceil((row+self.reach+1)*self.mh/self.height))
	for y=lo,hi do
		if math.abs(self.ys[y+1]-row)<=self.reach then enqueue(self,'mask',y) end
	end
end

function Reach.new(width:number,height:number,ownerAt:(number)->number,maxSide:number?):any
	local factor=math.min(1,(maxSide or 512)/math.max(width,height))
	local mw,mh=math.max(1,math.ceil(width*factor)),math.max(1,math.ceil(height*factor))
	local xs,ys={},{}
	for x=0,mw-1 do xs[x+1]=math.min(width-1,math.floor((x+.5)*width/mw)) end
	for y=0,mh-1 do ys[y+1]=math.min(height-1,math.floor((y+.5)*height/mh)) end
	return setmetatable({width=width,height=height,ownerAt=ownerAt,mw=mw,mh=mh,xs=xs,ys=ys,
		owner=0,reach=0,rows={},dirtyBounds={},borderQueue={},borderVersions={},maskQueue={},maskVersions={},
		borderHead=1,maskHead=1,blocks={},started=false,active=false,scans=0,maskBuilds=0,
		steps=0,maxStepMs=0,cpuMs=0,work=0,readyRows={},presented={},uploadCursor=0,borderEntries=0},Reach)
end

function Reach.reset(self:any,owner:number,reach:number)
	self.owner,self.reach=owner,reach
	self.rows,self.borderQueue,self.borderVersions,self.maskQueue,self.maskVersions={},{},{},{},{}
	self.dirtyBounds={}
	self.borderHead,self.maskHead,self.job=1,1,nil
	self.blocks={};self.pixels=nil;self.started=false
	self.readyRows,self.presented,self.uploadCursor={},{},0
	self.borderEntries=0
end
function Reach.prewarm(self:any,owner:number,reach:number)
	if self.owner~=owner or self.reach~=reach then self:reset(owner,reach) end
	if owner>0 and not self.started then
		self.started=true;self.pixels=buffer.create(self.mw*self.mh*4)
		for y=0,self.height-1 do borderDirty(self,y,0,self.width-1) end
		for y=0,self.mh-1 do enqueue(self,'mask',y) end
		for b=0,math.ceil(self.mh/BLOCK_ROWS)-1 do self.blocks[b]=true end
	end
end
function Reach.setActive(self:any,owner:number,reach:number?)
	if reach~=nil then self:prewarm(owner,reach)
	elseif self.owner~=owner then self:reset(owner,self.reach) end
	self.active=reach~=nil and reach>0 and owner>0
end

-- RasterCore already collects exactly the transitions to/from our owner.
-- Reuse that list: no second reads of the whole replication batch.
function Reach.tilesChanged(self:any,tiles:{number}?)
	if not tiles then
		local started=self.started;self:reset(self.owner,self.reach)
		if started then self:prewarm(self.owner,self.reach) end
		return
	end
	if not self.started or #tiles==0 then return end
	local touched={}
	local minRow,maxRow=self.height,-1
	for _,tile in tiles do
		local x,y=tile%self.width,math.floor(tile/self.width)
		local span=touched[y]
		if span then span[1]=math.min(x,span[1]);span[2]=math.max(x,span[2]) else touched[y]={x,x} end
		minRow,maxRow=math.min(minRow,y),math.max(maxRow,y)
	end
	for row,span in touched do
		borderDirty(self,row,math.max(0,span[1]-1),math.min(self.width-1,span[2]+1))
		if row>0 then borderDirty(self,row-1,span[1],span[2]) end
		if row<self.height-1 then borderDirty(self,row+1,span[1],span[2]) end
	end
	-- At most 512 row flags, even when a capitulation changes a million tiles.
	for row,cy in self.ys do
		if maxRow>=0 and cy>=minRow-1-self.reach and cy<=maxRow+1+self.reach then enqueue(self,'mask',row-1) end
	end
end

-- Original: GameImpl.updateBorderStatus / map.isBorder. Row runs and partial
-- span replacement are our presentation cache around that membership rule.
local function borderJob(self:any,row:number,charge:()->())
	local runs={};local first:number?=nil
	local w,h,owner=self.width,self.height,self.owner
	local get=self.ownerAt
	local bounds=self.dirtyBounds[row]
	local lo,hi=bounds[1],bounds[2]
	for x=lo,hi do
		local t=row*w+x
		local border=get(t)==owner and ((x>0 and get(t-1)~=owner) or (x<w-1 and get(t+1)~=owner)
			or (row>0 and get(t-w)~=owner) or (row<h-1 and get(t+w)~=owner))
		if border then if first==nil then first=x end
		elseif first~=nil then table.insert(runs,first);table.insert(runs,x-1);first=nil end
		charge()
	end
	if first~=nil then table.insert(runs,first);table.insert(runs,hi) end
	local merged={}
	local function add(a:number,b:number)
		if a>b then return end
		if #merged>0 and a<=merged[#merged]+1 then merged[#merged]=math.max(merged[#merged],b)
		else table.insert(merged,a);table.insert(merged,b) end
	end
	local old=self.rows[row] or {}
	for i=1,#old,2 do if old[i]<lo then add(old[i],math.min(lo-1,old[i+1])) end;charge() end
	for i=1,#runs,2 do add(runs[i],runs[i+1]);charge() end
	for i=1,#old,2 do if old[i+1]>hi then add(math.max(hi+1,old[i]),old[i+1]) end;charge() end
	return merged
end

local function maskJob(self:any,row:number,charge:()->())
	local cy=self.ys[row+1]
	local outer,inner=table.create(self.mw+1,0),table.create(self.mw+1,0)
	local radius=self.reach
	-- An antialias-width band in mask pixels; this never changes hit testing.
	local innerRadius=math.max(0,radius-math.max(2,1.5*self.width/self.mw))
	local function add(diff:{number},lo:number,hi:number)
		local a=math.max(0,math.ceil(lo*self.mw/self.width-.5))
		local b=math.min(self.mw,math.ceil((hi+1)*self.mw/self.width-.5))
		if a<b then diff[a+1]+=1;diff[b+1]-=1 end
	end
	for y=math.max(0,math.ceil(cy-radius)),math.min(self.height-1,math.floor(cy+radius)) do
		local dy=cy-y
		local dx=math.floor(math.sqrt(math.max(0,radius*radius-dy*dy)))
		local ix=if math.abs(dy)<=innerRadius then math.floor(math.sqrt(math.max(0,innerRadius*innerRadius-dy*dy))) else nil
		local runs=self.rows[y] or {}
		for i=1,#runs,2 do
			add(outer,runs[i]-dx,runs[i+1]+dx)
			if ix then add(inner,runs[i]-ix,runs[i+1]+ix) end
			charge()
		end
		charge()
	end
	local alpha=buffer.create(self.mw)
	local a,b=0,0
	for x=0,self.mw-1 do
		a+=outer[x+1];b+=inner[x+1]
		if a>0 and self.ownerAt(cy*self.width+self.xs[x+1])~=self.owner then
			buffer.writeu8(alpha,x,if b>0 then 42 else 148)
		end
		charge()
	end
	return alpha
end

local function nextRow(self:any,kind:string):number?
	local queue,versions=self[kind..'Queue'],self[kind..'Versions']
	local head=self[kind..'Head']
	if head>#queue then self[kind..'Queue']={};self[kind..'Head']=1;return nil end
	if head>256 and head>#queue/2 then
		local compact={};for i=head,#queue do table.insert(compact,queue[i]) end
		queue=compact;self[kind..'Queue']=queue;head=1
	end
	local row=queue[head];self[kind..'Head']=head+1
	assert(versions[row]~=nil)
	return row
end
function Reach.pending(self:any):boolean
	return self.job~=nil or self.borderHead<=#self.borderQueue or self.maskHead<=#self.maskQueue
end
function Reach.step(self:any,budgetMs:number?,maxWork:number?):number
	if not self.started then return 0 end
	local start=os.clock();local work=0
	while work<(maxWork or 8192) and (os.clock()-start)*1000<(budgetMs or .6) do
		if not self.job then
			local kind='border';local row=nextRow(self,kind)
			if row==nil then kind='mask';row=nextRow(self,kind) end
			if row==nil then break end
			local version=self[kind..'Versions'][row]
			local count=0
			local function charge()
				count+=1;if count==128 then count=0;coroutine.yield() end
			end
			self.job={kind=kind,row=row,version=version,thread=coroutine.create(function()
				return if kind=='border' then borderJob(self,row,charge) else maskJob(self,row,charge)
			end)}
		end
		local job=self.job
		local ok,result=coroutine.resume(job.thread);assert(ok,tostring(result));work+=128
		if coroutine.status(job.thread)=='dead' then
			local versions=self[job.kind..'Versions']
			if versions[job.row]~=job.version then
				table.insert(self[job.kind..'Queue'],job.row)
			else
				versions[job.row]=nil
				if job.kind=='border' then
					self.dirtyBounds[job.row]=nil
					self.scans+=1
					if not same(self.rows[job.row],result) then
						self.borderEntries+=#result-#(self.rows[job.row] or {})
						self.rows[job.row]=result;maskRows(self,job.row)
					end
				else
					self.maskBuilds+=1
					self.readyRows[job.row]=true
					local changed=false
					for x=0,self.mw-1 do
						local at=(job.row*self.mw+x)*4
						local alpha=buffer.readu8(result,x)
						if buffer.readu8(self.pixels,at+3)~=alpha then
							buffer.writeu32(self.pixels,at,255+211*256+64*65536+alpha*16777216);changed=true
						end
					end
					if changed then self.blocks[math.floor(job.row/BLOCK_ROWS)]=true end
				end
			end
			self.job=nil
		end
	end
	local ms=(os.clock()-start)*1000
	self.steps+=1;self.work+=work;self.cpuMs+=ms;self.maxStepMs=math.max(self.maxStepMs,ms)
	return work
end
function Reach.nextUpload(self:any):(number?,number?)
	-- Completed rows can progress amid later border traffic. Round-robin blocks
	-- prevent a busy front from starving the rest of the map's first reveal.
	local count=math.ceil(self.mh/BLOCK_ROWS)
	for offset=0,count-1 do
		local b=(self.uploadCursor+offset)%count
		if self.blocks[b] then
			local y,h=b*BLOCK_ROWS,math.min(BLOCK_ROWS,self.mh-b*BLOCK_ROWS)
			local ready=true
			for row=y,y+h-1 do if not self.readyRows[row] then ready=false;break end end
			if ready then return y,h end
		end
	end
	return nil,nil
end
function Reach.uploaded(self:any,y:number)
	local b=math.floor(y/BLOCK_ROWS)
	self.blocks[b]=nil;self.presented[b]=true;self.uploadCursor=(b+1)%math.ceil(self.mh/BLOCK_ROWS)
end
function Reach.presentable(self:any):boolean
	for b=0,math.ceil(self.mh/BLOCK_ROWS)-1 do if not self.presented[b] then return false end end
	return true
end
function Reach.clean(self:any):boolean return not self:pending() and next(self.blocks)==nil end
function Reach.destroy(self:any)
	self.active=false;self:reset(0,0)
end
return Reach
