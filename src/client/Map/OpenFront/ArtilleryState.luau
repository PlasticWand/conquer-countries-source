--!strict
-- Original Conquest presentation history for ARSENAL_V2. Confirmed records
-- are copied: the client may mutate a unit before publishing its next update.
local Visual = require(script.Parent.UnitVisuals)
local State = {}
State.__index = State
State.shellCap, State.markCap, State.visitCap = 32, 12, 128
State.projectiles={['Artillery Shell']=true,['Air Strike']=true,['Railgun Shot']=true,Paratroopers=true,Sabotage=true}

-- Clip long rail beams before assigning native GUI geometry, including a
-- beam crossing the viewport with both endpoints offscreen.
function State.clipLine(x0:number,y0:number,x1:number,y1:number,w:number,h:number):(number?,number?,number?,number?)
	local dx,dy=x1-x0,y1-y0
	local lo,hi=0,1
	for _,v in {{-dx,x0},{dx,w-x0},{-dy,y0},{dy,h-y0}} do
		local p,q=v[1],v[2]
		if p==0 then if q<0 then return nil end
		else local t=q/p
			if p<0 then lo=math.max(lo,t) else hi=math.min(hi,t) end
			if lo>hi then return nil end
		end
	end
	return x0+lo*dx,y0+lo*dy,x0+hi*dx,y0+hi*dy
end

local function record(u:any):any?
	local _,structure=Visual.sprite(u)
	if not structure and not State.projectiles[u.type] and u.type~='SAMMissile' and u.type~='Shell' then return nil end
	return {type=u.type,owner=u.owner,tile=u.tile,active=u.active~=false,dark=u.dark==true,level=u.level or 1,waiting=(u.waitTicks or 0)>0,target=u.targetUnitId}
end

function State.new(width:number,specs:any?):any
	return setmetatable({width=width,seen={},marks={},flights={},samTargets={},coastal={},specs=specs or {}},State)
end
function State.seed(self:any,units:{[number]:any})
	table.clear(self.seen);table.clear(self.marks);table.clear(self.flights);table.clear(self.samTargets);table.clear(self.coastal)
	for id,u in units do
		self.seen[id]=record(u)
		if u.type=='Coastal Battery' and u.active~=false and not u.underConstruction then self.coastal[u.tile]=u.owner end
		if u.type=='Paratroopers' and u.active~=false then
			local x,y=u.tile%self.width,math.floor(u.tile/self.width)
			self.flights[id]={x=x,y=y,tx=x,ty=y,start=0,duration=.1}
		end
		if u.type=='SAMMissile' and u.targetUnitId~=nil and u.active~=false then self.samTargets[u.targetUnitId]=u.owner end
	end
end
-- Interpolate from the last displayed confirmed pose, not Unit.lastTile:
-- move() runs four times/tick and network deltas can span several ticks.
-- Never extrapolate beyond the latest confirmed tile.
function State.flightPosition(self:any,u:any,now:number):(number,number)
	local f=self.flights[u.id]
	if not f then return u.tile%self.width,math.floor(u.tile/self.width) end
	local a=math.clamp((now-f.start)/f.duration,0,1)
	return f.x+(f.tx-f.x)*a,f.y+(f.ty-f.y)*a
end
function State.expire(self:any,now:number)
	for i=#self.marks,1,-1 do
		local e=self.marks[i]
		if now-e.start>=e.life then table.remove(self.marks,i) end
	end
end
local function mark(self:any,kind:string,tile:number,now:number,scale:number,loss:number?,source:number?,radius:number?)
	local x,y=tile%self.width+.5,math.floor(tile/self.width)+.5
	-- Merge only presentation bursts, never damage or confirmed records. Keep
	-- the original start so a hot point cannot hold an accent open forever.
	if kind~="levelLoss" and kind~="railBeam" then
		local mergeRadius=10/math.max(.05,scale)
		for _,e in self.marks do
			if e.kind==kind and now-e.start<.10 and (e.x-x)^2+(e.y-y)^2<=mergeRadius^2 then return end
		end
	end
	if #self.marks>=State.markCap then table.remove(self.marks,1) end
	table.insert(self.marks,{kind=kind,x=x,y=y,start=now,loss=loss,source=source,radius=radius,
		life=if kind=='fieldFade' then .65 elseif kind=='paraLand' then .85 elseif kind=='paraDown' then .65 elseif kind=="muzzle" then .12 elseif kind=="impact" then .24 elseif kind=='airImpact' then .48 elseif kind=='railBeam' then .18 else .36})
end
function State.updates(self:any,updates:{any},removed:{number},visible:(number,number?)->boolean,now:number,scale:number)
	self:expire(now)
	-- Read all missiles first: packet unit ordering must not decide whether a
	-- confirmed plane death has a matching interceptor (including instant finals).
	for _,u in updates do
		if u.type=='SAMMissile' and u.targetUnitId~=nil then self.samTargets[u.targetUnitId]=u.owner end
		local prior=self.seen[u.id]
		if prior and prior.type=='Coastal Battery' then self.coastal[prior.tile]=nil end
		if u.type=='Coastal Battery' and u.active~=false and not u.underConstruction then self.coastal[u.tile]=u.owner end
	end
	for _,u in updates do
		local before,after=self.seen[u.id],record(u)
		self.seen[u.id]=after
		if before and after and before.active and before.type==after.type then
			if after.active and after.dark and not before.dark and u.type~='Field Works' and visible(u.tile) then mark(self,'switchOff',u.tile,now,scale) end
			if u.type=='Field Works' and not after.active and visible(u.tile) then mark(self,'fieldFade',u.tile,now,scale) end
		end
		if u.type=='Shell' then
			-- Ordinary Shells keep their existing mobile/trail/impact renderer.
			-- Only a first record at a confirmed friendly battery identifies its
			-- muzzle; do not guess a source from the nearest gun or any Warship.
			local source=u.sourceTile or u.tile
			if not before and (u.active~=false or u.reachedTarget==true) and self.coastal[source]==u.owner and visible(source) then mark(self,'muzzle',source,now,scale) end
		elseif u.type=='Paratroopers' then
			if u.active~=false then
				local f=self.flights[u.id]
				if not f or f.tx~=u.tile%self.width or f.ty~=math.floor(u.tile/self.width) then
					local x,y=self:flightPosition(u,now)
					if not f and u.lastTile~=nil then x,y=u.lastTile%self.width,math.floor(u.lastTile/self.width) end
					self.flights[u.id]={x=x,y=y,tx=u.tile%self.width,ty=math.floor(u.tile/self.width),start=now,
						duration=if f and f.received then math.clamp(now-f.received,.05,.25) else .1,received=now}
				end
			end
			if u.active==false and (not before or before.active) and visible(u.tile) then
				if u.reachedTarget==true then mark(self,'paraLand',u.tile,now,scale)
				elseif u.destroyer~=nil and self.samTargets[u.id]==u.destroyer then mark(self,'paraDown',u.tile,now,scale) end
			end
			if u.active==false then self.samTargets[u.id]=nil;self.flights[u.id]=nil end
		elseif u.type=='Sabotage' then
			-- Its final reachedTarget also means a fizzle. Only a building's
			-- confirmed dark transition can emit the switch-off accent above.
		elseif State.projectiles[u.type] then
			if (not before or before.waiting) and (u.waitTicks or 0)<=0 and (u.active~=false or u.reachedTarget==true) then
				local source=u.sourceTile
				if source==nil and u.active~=false and (u.lastTile==nil or u.lastTile==u.tile) then source=u.tile end
				if source~=nil and visible(source) then mark(self,"muzzle",source,now,scale) end
			end
			if u.active==false and u.reachedTarget==true and (not before or before.active) then
				local tile=u.targetTile or u.tile
				if u.type=='Railgun Shot' and u.sourceTile~=nil and visible(u.sourceTile,tile) then
					mark(self,'railBeam',tile,now,scale,nil,u.sourceTile)
				end
				if visible(tile) then
					local spec=self.specs[u.type]
					mark(self,if u.type=='Air Strike' then 'airImpact' elseif u.type=='Railgun Shot' then 'railImpact' else 'impact',
						tile,now,scale,nil,u.sourceTile,if spec then spec.radius else 0)
				end
			end
		elseif before and after and before.active and after.active and before.owner==after.owner
			and before.type==after.type and after.level<before.level and visible(u.tile) then
			mark(self,"levelLoss",u.tile,now,scale,before.level-after.level)
		end
	end
	for _,id in removed do
		local prior=self.seen[id]
		if prior and prior.type=='Field Works' and prior.active and visible(prior.tile) then mark(self,'fieldFade',prior.tile,now,scale) end
		if prior and prior.type=='Coastal Battery' then self.coastal[prior.tile]=nil end
		if prior and prior.type=='SAMMissile' and prior.target then self.samTargets[prior.target]=nil end
		self.samTargets[id]=nil;self.seen[id]=nil;self.flights[id]=nil
	end
end
return State
