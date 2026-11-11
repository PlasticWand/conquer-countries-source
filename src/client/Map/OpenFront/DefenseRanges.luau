--!strict
-- Roblox presentation for Bruno's confirmed outgoing-attack/post intersections.
-- Reads confirmed buffers only. Work resumes across frames; no territory scan.
local Defense={}
Defense.__index=Defense
local CELL=128
function Defense.new(width:number,height:number):any
	return setmetatable({width=width,height=height,owner=0,targets={},posts={},cells={},queue={},head=1,
		active={},version=0,visits=0,circles={},circlesVersion=-1},Defense)
end
local function invalidate(self:any,p:any)
	p.generation=(p.generation or 0)+1
	p.witness=nil
	if self.active[p.id] then self.active[p.id]=nil; self.version+=1 end
	if not p.queued then p.queued=true; table.insert(self.queue,p.id) end
	p.x,p.y=-p.radius,-p.radius
end
function Defense.setTargets(self:any,attacks:{any},owner:number)
	local targets={}
	for _,a in attacks do
		if a.outgoing==true and a.attacker==owner and a.target~=owner then targets[a.target]=true end
	end
	local changed=self.owner~=owner
	for id in self.targets do if not targets[id] then changed=true end end
	for id in targets do if not self.targets[id] then changed=true end end
	if not changed then return end
	self.owner,self.targets=owner,targets
	for _,p in self.posts do invalidate(self,p) end
end
function Defense.setUnits(self:any,units:{[number]:any},radius:number)
	local changed=false
	for id,p in self.posts do
		local u=units[id]
		if not u or u.type~='Defense Post' or u.active==false then
			self.posts[id]=nil; if self.active[id] then self.active[id]=nil; self.version+=1 end; changed=true
		end
	end
	for id,u in units do if u.type=='Defense Post' and u.active~=false then
		local p=self.posts[id]
		if not p or p.tile~=u.tile or p.owner~=u.owner or p.radius~=radius then
			if not p then p={id=id}; self.posts[id]=p end
			p.tile,p.owner,p.radius=u.tile,u.owner,radius
			invalidate(self,p); changed=true
		end
	end end
	if not changed then return end
	self.cells={}
	for id,p in self.posts do
		local x,y=p.tile%self.width,math.floor(p.tile/self.width)
		for cy=math.max(0,math.floor((y-p.radius)/CELL)),math.floor(math.min(self.height-1,y+p.radius)/CELL) do
			for cx=math.max(0,math.floor((x-p.radius)/CELL)),math.floor(math.min(self.width-1,x+p.radius)/CELL) do
				local key=cy*math.ceil(self.width/CELL)+cx
				self.cells[key]=self.cells[key] or {}; self.cells[key][id]=true
			end
		end
	end
end
function Defense.tilesChanged(self:any,tiles:{number}?)
	if not tiles then for _,p in self.posts do invalidate(self,p) end; return end
	-- Without outgoing targets no range can be displayed. setTargets invalidates
	-- every post if that changes; do not walk thousands of captures meanwhile.
	if self.owner<=0 or next(self.targets)==nil or #tiles==0 then return end
	-- Build a candidate list once per touched cell. Remove a post once this
	-- batch invalidates it, and test a live witness directly instead of visiting
	-- every post for every tile of a capitulating nation.
	local candidates,marked,witnesses={},{},{}
	for id in self.active do
		local p=self.posts[id]
		if p.witness then
			local list=witnesses[p.witness] or {};witnesses[p.witness]=list;table.insert(list,p)
		end
	end
	for _,tile in tiles do
		local hits=witnesses[tile]
		if hits then
			for _,p in hits do marked[p.id]=true;invalidate(self,p) end
			witnesses[tile]=nil
		end
		local x,y=tile%self.width,math.floor(tile/self.width)
		local key=math.floor(y/CELL)*math.ceil(self.width/CELL)+math.floor(x/CELL)
		local cell=candidates[key]
		if not cell then
			cell={};candidates[key]=cell
			for id in self.cells[key] or {} do
				local p=self.posts[id]
				if p.owner~=self.owner and self.targets[p.owner] and not self.active[id] and not marked[id] then cell[id]=p end
			end
		end
		for id,p in cell do
			if marked[id] then cell[id]=nil;continue end
			local dx,dy=x-p.tile%self.width,y-math.floor(p.tile/self.width)
			if dx*dx+dy*dy<=p.radius*p.radius then
				marked[id]=true;cell[id]=nil;invalidate(self,p)
			end
		end
	end
end
function Defense.step(self:any,states:buffer,budget:number,milliseconds:number?):{any}
	local deadline=os.clock()+(milliseconds or math.huge)/1000
	local visits=0
	while self.head<=#self.queue and visits<budget and os.clock()<deadline do
		local id=self.queue[self.head]; local p=self.posts[id]
		if not p or self.owner<=0 or p.owner==self.owner or not self.targets[p.owner] then
			if p then p.queued=false end
			self.head+=1; continue
		end
		local r=p.radius
		local cx,cy=p.tile%self.width,math.floor(p.tile/self.width)
		local x,y=cx+p.x,cy+p.y
		visits+=1
		local hit=x>=0 and y>=0 and x<self.width and y<self.height and p.x*p.x+p.y*p.y<=r*r
			and bit32.band(buffer.readu16(states,(y*self.width+x)*2),4095)==self.owner
		p.x+=1; if p.x>r then p.x=-r; p.y+=1 end
		if hit or p.y>r then
			p.queued=false; self.head+=1
			if hit then p.witness=y*self.width+x; self.active[id]={id=id,tile=p.tile,radius=r}; self.version+=1 end
		end
	end
	self.visits+=visits
	if self.head>#self.queue then table.clear(self.queue); self.head=1 end
	if self.head>256 and self.head>#self.queue/2 then
		local queue={}; for i=self.head,#self.queue do table.insert(queue,self.queue[i]) end
		self.queue,self.head=queue,1
	end
	if self.circlesVersion~=self.version then
		local circles={}; for _,p in self.active do table.insert(circles,p) end
		table.sort(circles,function(a,b) return a.id<b.id end)
		self.circles,self.circlesVersion=circles,self.version
	end
	return self.circles
end
function Defense.clear(self:any)
	table.clear(self.posts); table.clear(self.cells); table.clear(self.targets); table.clear(self.active)
	table.clear(self.queue); table.clear(self.circles); self.head=1
end
return Defense
