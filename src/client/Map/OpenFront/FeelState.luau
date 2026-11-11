--!strict
-- Bounded presentation history. Confirmed records are copied, never retained:
-- ClientState may mutate a record before publishing its next UnitsChanged.
local Feel = {}
Feel.__index = Feel
local STRUCTURES = {City=true, Port=true, Factory=true, ["Defense Post"]=true,
	["Missile Silo"]=true, ["SAM Launcher"]=true, Artillery=true, Airfield=true, Railgun=true, ['Coastal Battery']=true}
local UNIT_CAP, PULSE_CAP = 4, 4
Feel.unitCap, Feel.pulseCap = UNIT_CAP, PULSE_CAP
local LIFETIME = {impact=.28,tap=.28,loss=.40,landing=.40,home=.30,move=.28,moveConfirmed=.40}

local function record(u:any):any?
	if not STRUCTURES[u.type] and u.type~="Transport" and u.type~="Warship" then return nil end
	return {type=u.type, owner=u.owner, active=u.active~=false,
		building=u.underConstruction==true, level=u.level or 1,patrol=if u.warship then u.warship.patrolTile else nil}
end

function Feel.new(width:number?):any
	return setmetatable({seen={}, units={}, pulses={}, focus=nil,orders={},width=width or 1},Feel)
end

function Feel.clear(self:any)
	table.clear(self.seen); table.clear(self.units); table.clear(self.pulses); table.clear(self.orders); self.focus=nil
end

function Feel.seed(self:any,units:{[number]:any})
	self:clear()
	for id,u in units do self.seen[id]=record(u) end
end

function Feel.updates(self:any,updates:{any},removed:{number},you:number,visible:(number)->boolean,now:number)
	for _,u in updates do
		local before,after=self.seen[u.id],record(u)
		self.seen[u.id]=after
		if before and before.active and before.owner==you and before.type=="Transport" and u.type=="Transport"
			and u.owner==you and u.active==false and u.reachedTarget==true and u.retreating~=true then
			local tile=u.targetTile or u.tile
			if visible(tile) then self:atTile("landing",tile,now) end
		end
		for i=#self.orders,1,-1 do
			local order=self.orders[i]
			if order.ids[u.id] then
				if not after or not after.active or after.owner~=you or after.type~="Warship" then order.ids[u.id]=nil
				elseif before and before.active and before.owner==you and before.type=="Warship"
					and before.patrol~=after.patrol and after.patrol==order.tile then
					self:atTile("moveConfirmed",order.tile,now); table.remove(self.orders,i)
				end
			end
		end
		if before and after and before.type~=after.type then self.units[u.id]=nil end
		if not after or not after.active or after.owner~=you then
			self.units[u.id]=nil
		elseif visible(u.tile) then
			local fresh=before==nil and after.type~="Warship"
			local continuous=before and before.active and before.owner==you and before.type==after.type
			local complete=STRUCTURES[after.type] and continuous and before.building and not after.building
			local upgrade=STRUCTURES[after.type] and continuous and after.level>before.level
			if fresh or complete or upgrade then
				local count=0; for _ in self.units do count+=1 end
				if self.units[u.id] or count<UNIT_CAP then
					self.units[u.id]={id=u.id,tile=u.tile,target=u.targetTile,start=now,
						settle=fresh,boat=after.type=="Transport",complete=complete==true,upgrade=upgrade==true}
				end
			end
		end
	end
	for _,id in removed do
		self.seen[id]=nil; self.units[id]=nil
		for _,order in self.orders do order.ids[id]=nil end
	end
end

function Feel.pulse(self:any,kind:string,x:number,y:number,now:number)
	if not LIFETIME[kind] then return end
	for i=#self.pulses,1,-1 do
		local e=self.pulses[i]
		if (kind=="loss" and e.kind=="loss") or (kind=="home" and e.kind=="landing" and e.x==x and e.y==y) then table.remove(self.pulses,i) end
	end
	if #self.pulses>=PULSE_CAP then table.remove(self.pulses,1) end
	table.insert(self.pulses,{kind=kind,x=x,y=y,start=now,lifetime=LIFETIME[kind]})
end
function Feel.atTile(self:any,kind:string,tile:number,now:number)
	self:pulse(kind,tile%self.width+.5,math.floor(tile/self.width)+.5,now)
end

function Feel.move(self:any,ids:{number},tile:number,units:{[number]:any},you:number,now:number)
	local chosen={}
	for i,id in ids do
		if i>500 then break end
		local u=units[id]
		if u and u.type=="Warship" and u.active~=false and u.owner==you then chosen[id]=true end
	end
	if next(chosen)==nil then return end
	for _,order in self.orders do for id in chosen do order.ids[id]=nil end end
	for i=#self.orders,1,-1 do if next(self.orders[i].ids)==nil then table.remove(self.orders,i) end end
	if #self.orders>=4 then table.remove(self.orders,1) end
	table.insert(self.orders,{ids=chosen,tile=tile,deadline=now+3})
	self:atTile("move",tile,now)
end

function Feel.focusAt(self:any,x:number,y:number,now:number)
	self.focus={kind="focus",x=x,y=y,start=now,pending=true,deadline=now+5}
end

function Feel.expire(self:any,now:number)
	for id,e in self.units do if now-e.start>=.28 then self.units[id]=nil end end
	for i=#self.pulses,1,-1 do local e=self.pulses[i]; if now-e.start>=e.lifetime then table.remove(self.pulses,i) end end
	for i=#self.orders,1,-1 do
		if now>=self.orders[i].deadline or next(self.orders[i].ids)==nil then table.remove(self.orders,i) end
	end
	local f=self.focus
	if f and ((f.pending and now>=f.deadline) or (not f.pending and now-f.start>=.30)) then self.focus=nil end
end

local function out(t:number):number return 1-(1-math.clamp(t,0,1))^2 end
function Feel.settle(age:number):number
	if age<.065 then return .90+.18*out(age/.065) end
	return 1+.08*(1-out((age-.065)/.095))
end
function Feel.numeral(age:number):number return 1+.25*math.sin(math.pi*math.clamp(age/.20,0,1)) end
function Feel.mark(kind:string,age:number,zoom:number):(number,number)
	if kind=="focus" then return 24-12*out(age/.13),math.clamp((age-.13)/.17,0,1) end
	local far=1-math.clamp(zoom/8,0,1)
	if kind=="loss" then return (16+10*far)*(1-.5*out(age/.25)),math.clamp(age/.40,0,1) end
	if kind=="landing" then return 7+14*out(age/.40),math.clamp(age/.40,0,1) end
	if kind=="home" then return 10-4*out(age/.30),.3+.7*math.clamp(age/.30,0,1) end
	if kind=="move" then return 18-7*out(age/.20),math.clamp(age/.28,0,1) end
	if kind=="moveConfirmed" then return 9+9*out(age/.25),math.clamp(age/.40,0,1) end
	local radius=if kind=="tap" then 12 else 14+8*(1-math.clamp(zoom/8,0,1))
	return radius*(1-.28*out(age/.10)),math.clamp(age/.28,0,1)
end

return Feel
