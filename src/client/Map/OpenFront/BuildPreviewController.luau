--!strict
-- Ported from OpenFront v0.35.2 (src/client/controllers/BuildPreviewController.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- The source queries its engine worker; this adapter queries the caller's
-- server and renders advisory intent separately from confirmed match units.
local Camera = require(script.Parent.CameraTransform)
local Trajectory = require(script.Parent.NukeTrajectory)
local Shared = game:GetService("ReplicatedStorage").Shared.OpenFront
local Arsenal = require(Shared.ArsenalUnits)
local NukeExecution = require(Shared.Executions.NukeExecution)
local StrikeExecution = require(Shared.Executions.StrikeExecution)
local FieldWorksExecution = require(Shared.Executions.FieldWorksExecution)
local SabotageExecution = require(Shared.Executions.SabotageExecution)

export type Buildable = {
	type: string, canBuild: number | false, canUpgrade: number | false, cost: number,
	upgradeCosts: {number}?, ghostRailPaths: {{number}}, overlappingRailroads: {number},
}
export type Reply = {
	tile: number?, unit: string, tick: number, buildable: Buildable, rangeWarning: boolean,
	nukeAim: {siloTile: number, sams: {Trajectory.SAMInfo}}?,
	strikeAim: {launcherTile:number?,radius:number,reach:number}?,
	paraAim: {originTile:number?,reach:number,troops:number,readyAt:number}?,
	sabotageAim: {targetTile:number?,reach:number,readyAt:number,reason:string?}?,
	fieldWorksAim: {radius:number,readyAt:number}?,
}
export type Query = (tile: number?, unit: string) -> Reply?
export type Options = {snapToPlacement: boolean?, showCost: boolean?}
local Controller = {}
Controller.__index = Controller
local QUERY_INTERVAL_SECONDS = 0.05
local T_BLOCKED_DST = 0.9999
local STRUCTURES = {City=true, Factory=true, Port=true, ["Defense Post"]=true, ["Missile Silo"]=true, ["SAM Launcher"]=true}
for _,entry in Arsenal.BUILD do
	if not Arsenal.AIMED[entry.type] and not Arsenal.STRIKES[entry.type]
		and entry.type~='Paratroopers' and entry.type~='Sabotage' and entry.type~='Field Works' then STRUCTURES[entry.type]=true end
end
local BUILDABLE = table.clone(STRUCTURES)
BUILDABLE.Warship, BUILDABLE["Atom Bomb"], BUILDABLE["Hydrogen Bomb"], BUILDABLE.MIRV = true, true, true, true
for _,entry in Arsenal.BUILD do BUILDABLE[entry.type]=true end

local function nuke(unit: string?): boolean
	return unit == "Atom Bomb" or unit == "Hydrogen Bomb" or (unit~=nil and Arsenal.AIMED[unit]==true)
end

local function clear(self: any)
	self.drawKey=nil
	self.draftKey=nil
	self.renderer:setBuildPreview(nil)
	self.renderer:setNukePreview(nil)
end

-- Original: renderGhost and cursorLoop. Validation uses a snapped tile while
-- the visible cursor remains continuous, including during camera movement.
local function pointer(self: any): (boolean, number?, number?, number?, boolean)
	local renderer, state = self.renderer, self.state
	if renderer.destroyed or not state.ready or state:inSpawnPhase() or state:me() == nil then
		return false, nil, nil, nil, false
	end
	local pinned=self.pending
	if pinned~=nil then
		local byte=buffer.readu8(renderer.core.terrain,pinned)
		return true,pinned,pinned%state.width,math.floor(pinned/state.width),bit32.band(byte,128)~=0 and bit32.band(byte,31)==31
	end
	if self.placementPaused or not renderer.input then return false,nil,nil,nil,false end
	local sx, sy = renderer.input:pointerPosition()
	if sx == nil or sy == nil then return false, nil, nil, nil, false end
	local x, y = Camera.screenToWorldCoordinatesFloat(renderer.camera, sx, sy)
	local tile = renderer:screenToTile(sx, sy)
	local impassable = tile ~= nil and bit32.band(buffer.readu8(renderer.core.terrain, tile), 128) ~= 0
		and bit32.band(buffer.readu8(renderer.core.terrain, tile), 31) == 31
	return true, tile, x - 0.5, y - 0.5, impassable
end

function Controller.new(renderer: any, state: any, query: Query, options: Options?): any
	local self: any = setmetatable({renderer=renderer, state=state, query=query, options=options or {},
		chosen=nil, rocketDirectionUp=true, generation=0, inFlight=false, lastQueryAt=-math.huge, reply=nil,
		pointerActive=false, pointerTile=nil, connections={}, destroyed=false, queryThread=nil,
		dataReply=nil, ghostData=nil, pending=nil, placementPaused=false}, Controller)
	table.insert(self.connections, game:GetService("RunService").RenderStepped:Connect(function() self:step() end))
	table.insert(self.connections, renderer.root.Destroying:Connect(function() self:destroy() end))
	return self
end

-- Original: syncGhostState / clearGhostStructure. No remote response from an
-- earlier selection may resurrect its ghost, rail lines, ranges or arc.
function Controller.setChosen(self: any, unitType: string?)
	if self.destroyed or (self.chosen == unitType and unitType~=nil) then return end
	self.chosen = unitType
	self.pending,self.placementPaused=nil,false
	self.generation += 1
	self.reply, self.lastQueryAt, self.dataReply, self.ghostData = nil, -math.huge, nil, nil
	clear(self)
	self.sabotageReach=if unitType=='Sabotage' then SabotageExecution.REACH else nil
	self.renderer:setSabotageReach(self.sabotageReach)
end

-- Pending intent is a world tile, independent of the pointer/card/safe area.
-- Clearing suppresses the floating ghost until another pin/type is selected;
-- it never sends a command or changes the UI's selected build item.
function Controller.setPendingTile(self:any,tile:number?)
	if self.destroyed then return end
	assert(tile==nil or (tile==math.floor(tile) and tile>=0 and tile<self.state.width*self.state.height),'invalid pending tile')
	if self.pending==tile and self.placementPaused==(tile==nil) then return end
	self.pending,self.placementPaused=tile,tile==nil
	self.generation+=1
	self.reply,self.dataReply,self.ghostData,self.lastQueryAt=nil,nil,nil,-math.huge
	clear(self)
end
function Controller.pendingTile(self:any):number? return self.pending end

local function sameSams(a:any,b:any):boolean
	if a==b then return true end
	if not a or not b or #a~=#b then return false end
	for i,s in a do local t=b[i]; if s.x~=t.x or s.y~=t.y or s.r~=t.r then return false end end
	return true
end

-- A network query may take longer than crossing a tile. Render geometry from
-- confirmed config/costs immediately, with no build permission or old upgrade
-- target. The server's reply supplies validity, snapped placement and rails.
local function draft(self:any,tile:number?,x:number?,y:number?,impassable:boolean)
	if tile==nil or x==nil or y==nil or impassable then clear(self); return end
	local unit,state=self.chosen,self.state
	local cost=state.costs[unit]
	local key=self.draftKey
	if key and key.unit==unit and key.x==x and key.y==y and key.gold==state.gold and key.cost==cost then return end
	self.draftKey={unit=unit,x=x,y=y,gold=state.gold,cost=cost}
	local config=state:config()
	local radius,inner=0,0
	if unit=='SAM Launcher' then radius=config:samRange(1)
	elseif unit=='Artillery' then radius=config.ARTILLERY_RANGE or 0
	elseif unit=='Coastal Battery' then radius=config.COASTAL_RANGE or 0
	elseif unit=='Field Works' then radius=FieldWorksExecution.RADIUS
	elseif unit=='Airfield' then radius=StrikeExecution.SPEC['Air Strike'].reach
	elseif StrikeExecution.SPEC[unit] then radius=StrikeExecution.SPEC[unit].radius
	elseif unit=='Factory' then radius=config:trainStationMaxRange()
	elseif unit=='Defense Post' then radius=config:defensePostRange()
	elseif unit=='Warship' then radius=config:warshipPatrolRange()
	elseif nuke(unit) then local m=config:nukeMagnitudes(unit); radius,inner=m.outer,m.inner end
	self.renderer:setBuildPreview({ghostType=unit,tileX=x,tileY=y,radiusTileX=x,radiusTileY=y,
		rangeRadius=radius,innerRangeRadius=inner,ownerID=state.you,canBuild=false,canUpgrade=false,validated=false,
		spreadInnerRadius=if unit=='Scattershot' then NukeExecution.SCATTER_NEAR else nil,
		spreadOuterRadius=if unit=='Scattershot' then NukeExecution.SCATTER_FAR else nil,
		strikeReach=if StrikeExecution.SPEC[unit] then StrikeExecution.SPEC[unit].reach else nil,
		cost=cost or 0,showCost=cost~=nil and self.options.showCost~=false,canAfford=cost~=nil and state.gold>=cost})
	self.renderer:setNukePreview(nil)
end

-- Original: updateNukeTrajectoryPreview reads uiState.rocketDirectionUp;
-- cursorLoop passes it to buildNukeTrajectory. The launch silo and threat
-- set do not depend on arc direction, so keep the
-- current query result (including any request in flight) when it changes.
function Controller.setRocketDirection(self: any, up: boolean)
	if self.destroyed then return end
	self.rocketDirectionUp = up
end

-- Original: buildGhostPreviewData / resolveGhostRangeLevel / cursorLoop.
-- Amount=1 matches this round's OfActions command. Source
-- settings default to unsnapped placement and a visible cursor cost label.
function Controller.draw(self: any, tile: number?, x: number?, y: number?, impassable: boolean)
	local reply: Reply? = self.reply
	local unit: string = self.chosen
	if not reply then draft(self,tile,x,y,impassable); return end
	self.draftKey=nil
	if tile == nil or x == nil or y == nil then clear(self); return end
	local renderer, state = self.renderer, self.state
	local key=self.drawKey
	if key and key.reply==reply and key.x==x and key.y==y and key.impassable==impassable
		and key.up==self.rocketDirectionUp and key.gold==state.gold and (impassable or self.dataReply==reply) then return end
	if key and key.gold~=state.gold then self.dataReply=nil end
	self.drawKey={reply=reply,x=x,y=y,impassable=impassable,up=self.rocketDirectionUp,gold=state.gold}
	local config = state:config()
	if not impassable then
		-- Original builds static data only on a fresh worker result. Keep the
		-- silo count/config/upgrade/rail reads out of the per-frame cursor loop.
		if self.dataReply ~= reply then
			local u = reply.buildable
			local existing = if u.canUpgrade ~= false then state.units[u.canUpgrade] else nil
			local upgradeTile = if existing then existing.tile else nil
			local shore=unit=='Coastal Battery'
			local snap = (self.options.snapToPlacement == true or shore) and STRUCTURES[unit] and u.canUpgrade == false
				and u.canBuild ~= false and (shore or u.canBuild ~= tile)
			local gx, gy = x, y
			if snap then gx, gy = (u.canBuild :: number) % state.width, math.floor((u.canBuild :: number) / state.width) end
			local rx, ry = gx, gy
			local radius,innerRadius = 0,0
			if unit == "SAM Launcher" then radius = config:samRange(if existing then existing.level + 1 else 1)
			elseif unit == "Artillery" then radius = config.ARTILLERY_RANGE or 0
			elseif unit == 'Coastal Battery' then radius = config.COASTAL_RANGE or 0
			elseif unit=='Field Works' then radius=if reply.fieldWorksAim then reply.fieldWorksAim.radius else FieldWorksExecution.RADIUS
			elseif unit=='Airfield' then radius=StrikeExecution.SPEC['Air Strike'].reach
			elseif Arsenal.STRIKES[unit] then radius=if reply.strikeAim then reply.strikeAim.radius else StrikeExecution.SPEC[unit].radius
			elseif nuke(unit) then
				local magnitudes=config:nukeMagnitudes(unit)
				radius,innerRadius=magnitudes.outer,magnitudes.inner
			elseif unit == "Factory" then radius = config:trainStationMaxRange()
			elseif unit == "Defense Post" then radius = config:defensePostRange()
			elseif unit == "Warship" then radius = config:warshipPatrolRange() end
			if radius > 0 and upgradeTile ~= nil then rx, ry = upgradeTile % state.width, math.floor(upgradeTile / state.width) end
			local cost = if u.upgradeCosts then u.upgradeCosts[1] or u.cost else u.cost
			local canAfford = state.gold >= cost
			if unit == "Atom Bomb" or Arsenal.AIMED[unit] then
				local ready = 0
				for _, silo in state.units do
					if silo.type == "Missile Silo" and silo.owner == state.you and silo.active ~= false and not silo.underConstruction then
						ready += math.max(0, silo.level - #(silo.missileTimerQueue or {}))
					end
				end
				canAfford = canAfford and ready >= 1
			end
			self.ghostData = {ghostType=unit, tileX=gx, tileY=gy, radiusTileX=rx, radiusTileY=ry,validated=true,
				spreadInnerRadius=if unit=='Scattershot' then NukeExecution.SCATTER_NEAR else nil,
				spreadOuterRadius=if unit=='Scattershot' then NukeExecution.SCATTER_FAR else nil,
				strikeLauncherTile=if reply.strikeAim then reply.strikeAim.launcherTile else nil,
				strikeReach=if reply.strikeAim then reply.strikeAim.reach else nil,
				paraOriginTile=if reply.paraAim then reply.paraAim.originTile else nil,
				sabotageTargetTile=if reply.sabotageAim then reply.sabotageAim.targetTile else nil,
				snapToPlacement=snap == true, canBuild=u.canBuild ~= false, canUpgrade=u.canUpgrade ~= false,
				cost=cost, multiplier=1, showCost=self.options.showCost ~= false, canAfford=canAfford,
				ghostRailPaths=u.ghostRailPaths, overlappingRailroads=u.overlappingRailroads,
				ownerID=state.you, upgradeTargetTile=upgradeTile, rangeRadius=radius, innerRangeRadius=innerRadius, rangeWarning=reply.rangeWarning}
			self.dataReply = reply
		end
		local ghost = table.clone(self.ghostData)
		if not ghost.snapToPlacement then ghost.tileX, ghost.tileY = x, y end
		if not ghost.snapToPlacement and not (ghost.canUpgrade and ghost.upgradeTargetTile ~= nil) then
			ghost.radiusTileX, ghost.radiusTileY = x, y
		end
		renderer:setBuildPreview(ghost)
	else
		renderer:setBuildPreview(nil)
	end
	local aim = reply.nukeAim
	if nuke(unit) and aim then
		local prior=self.aimKey
		local unchanged=prior and prior.silo==aim.siloTile and prior.x==x and prior.y==y and prior.height==state.height
			and prior.up==self.rocketDirectionUp and prior.impassable==impassable and sameSams(prior.sams,aim.sams)
		local data=self.aimData
		if not unchanged then
			local stamp=renderer.profiler:begin()
			data=Trajectory.buildNukeTrajectory(aim.siloTile % state.width, math.floor(aim.siloTile / state.width),
				x, y, state.height, self.rocketDirectionUp, aim.sams)
			if impassable then data.tSamIntercept = math.min(data.tSamIntercept, T_BLOCKED_DST) end
			renderer.profiler:finish('previewArc',stamp)
			local sams={}; for _,s in aim.sams do table.insert(sams,{x=s.x,y=s.y,r=s.r}) end
			self.aimKey={silo=aim.siloTile,x=x,y=y,height=state.height,up=self.rocketDirectionUp,impassable=impassable,sams=sams}
			self.aimData=data
		end
		renderer:setNukePreview(data)
	else
		renderer:setNukePreview(nil)
	end
end

-- Original: renderGhost's 50ms worker query. Roblox requests are coalesced
-- with at most one InvokeServer in flight. Never reuse a tile's placement at
-- another tile while waiting, and reject replies after any intent change.
function Controller.step(self: any)
	if self.destroyed then return end
	if self.renderer.destroyed then self:destroy(); return end
	local unit: string? = self.chosen
	local aim=self.reply and self.reply.sabotageAim
	if aim then self.sabotageReach=aim.reach end
	self.renderer:setSabotageReach(if unit=='Sabotage' and self.state.ready and not self.state:inSpawnPhase()
		and self.state:me()~=nil then self.sabotageReach else nil)
	local active, tile, x, y, impassable = pointer(self)
	if not unit or not BUILDABLE[unit] then active = false end
	if active ~= self.pointerActive or tile ~= self.pointerTile then
		self.pointerActive, self.pointerTile = active, tile
		self.generation += 1
		self.reply, self.dataReply, self.ghostData = nil, nil, nil
	end
	if not active or not unit then clear(self); return end
	local queryTile = if impassable and not nuke(unit) then nil else tile
	local now = os.clock()
	local fresh=self.pending==nil or not self.reply or self.lastQueryTick~=self.state.tick or self.lastQueryGold~=self.state.gold
	if not self.inFlight and fresh and now - self.lastQueryAt >= QUERY_INTERVAL_SECONDS then
		self.inFlight, self.lastQueryAt = true, now
		self.lastQueryTick,self.lastQueryGold=self.state.tick,self.state.gold
		local generation = self.generation
		self.queryThread = task.spawn(function()
			local stamp=self.renderer.profiler:begin()
			local ok, result = pcall(self.query, queryTile, unit)
			self.renderer.profiler:finish('previewQuery',stamp) -- round-trip wall time, including any yield
			self.inFlight = false
			if self.destroyed or self.generation ~= generation or self.chosen ~= unit then return end
			local stillActive, currentTile, _, _, currentImpassable = pointer(self)
			local currentQueryTile = if currentImpassable and not nuke(unit) then nil else currentTile
			if not stillActive or currentTile ~= tile or currentQueryTile ~= queryTile then return end
			if ok and type(result) == "table" and result.tile == queryTile and result.unit == unit
				and result.buildable and result.buildable.type == unit then
				self.reply = result
			else
				self.reply = nil
			end
		end)
	end
	self:draw(tile, x, y, impassable)
end

function Controller.destroy(self: any)
	if self.destroyed then return end
	self.destroyed = true
	self.renderer:setSabotageReach(nil)
	self.generation += 1
	if self.queryThread then pcall(task.cancel, self.queryThread); self.queryThread = nil end
	for _, connection in self.connections do connection:Disconnect() end
	table.clear(self.connections)
	self.reply, self.chosen, self.dataReply, self.ghostData = nil, nil, nil, nil
	self.pending,self.drawKey,self.aimKey,self.aimData=nil,nil,nil,nil
	clear(self)
end

return Controller
