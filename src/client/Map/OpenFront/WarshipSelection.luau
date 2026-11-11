--!strict
-- Ported from OpenFront v0.35.2 (src/client/controllers/WarshipSelectionController.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Selection={}
Selection.__index=Selection
function Selection.new():any return setmetatable({ids={},singleID=nil,onSingleChanged=nil},Selection) end
-- Only a tap opens the single-ship card. Box/select-all never promote their
-- last surviving ship into a tapped selection.
local function single(self:any,id:number?)
	if self.singleID==id then return end
	self.singleID=id
	if self.onSingleChanged then self.onSingleChanged(id) end
end
function Selection.clear(self:any) table.clear(self.ids); single(self,nil) end

-- Original: tick / getAllWarships, also drop captured/dead selections before input.
function Selection.prune(self:any,units:{[number]:any},owner:number)
	local out={}
	for _, id in self.ids do
		local u=units[id]
		if u and u.type=='Warship' and u.active~=false and u.owner==owner then table.insert(out,id) end
	end
	self.ids=out
	if #out~=1 or out[1]~=self.singleID then single(self,nil) end
end
local function all(units:{[number]:any},order:{number},owner:number):{number}
	local out={}
	if owner<=0 then return out end
	for _, id in order do local u=units[id]
		if u and u.type=='Warship' and u.active~=false and u.owner==owner then table.insert(out,id) end
	end
	return out
end

-- Original: onMouseUp / findWarshipsNearCell. L1 radius <=10; ordered ties.
-- Only confirmed water taps are intercepted. Caller sends the existing move
-- command; selection never moves a unit locally or decides acceptance.
function Selection.tap(self:any,tile:number,width:number,water:boolean,units:{[number]:any},order:{number},owner:number):any
	self:prune(units,owner)
	if not water or owner<=0 then return {kind='pass'} end
	if #self.ids>0 then
		local ids=table.clone(self.ids); self:clear()
		return {kind='move',ids=ids,tile=tile}
	end
	local x,y=tile%width,math.floor(tile/width)
	local best,distance=nil,math.huge
	for _, id in all(units,order,owner) do
		local u=units[id]
		local d=math.abs(u.tile%width-x)+math.abs(math.floor(u.tile/width)-y)
		if d<=10 and d<distance then best,distance=id,d end
	end
	if best then self.ids={best}; single(self,best); return {kind='select',ids={best}} end
	return {kind='pass'}
end

-- Original: onSelectionBoxComplete inclusive projected tile bounds.
function Selection.box(self:any,units:{[number]:any},order:{number},owner:number,x1:number,y1:number,x2:number,y2:number,
	project:(number)->(number,number))
	local out={}
	for _, id in all(units,order,owner) do
		local x,y=project(units[id].tile)
		if x>=math.min(x1,x2) and x<=math.max(x1,x2) and y>=math.min(y1,y2) and y<=math.max(y1,y2) then table.insert(out,id) end
	end
	self.ids=out
	single(self,nil)
end

-- Original: onSelectAllWarships / selectedAllWarships.
function Selection.toggleAll(self:any,units:{[number]:any},order:{number},owner:number)
	self:prune(units,owner)
	local ids=all(units,order,owner)
	if #ids==0 then single(self,nil); return end
	self.ids=if #self.ids==#ids then {} else ids
	single(self,nil)
end
return Selection
