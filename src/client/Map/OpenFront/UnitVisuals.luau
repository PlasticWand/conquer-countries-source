--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/passes/UnitPass.ts; StructurePass.ts; BarPass.ts; NukeTelegraphPass.ts; RailroadPass.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Structure = require(script.Parent.StructureMath)
local Defaults = require(script.Parent.RenderDefaults)
local Visual = {}

-- Field Works uses the structure presentation pass only; it is not a sim structure.
local structures = {City = 0, Port = 1, Factory = 2, ["Defense Post"] = 3, ["SAM Launcher"] = 4, ["Missile Silo"] = 5, Artillery = 7, Airfield = 6, Railgun = 8, ['Coastal Battery'] = 9, ['Field Works'] = 10}
local mobiles = {Transport = 0, ["Trade Ship"] = 1, Warship = 2, ["Atom Bomb"] = 3, ["Mega Nuke"] = 3, Scattershot = 3,
	["Hydrogen Bomb"] = 4, MIRV = 5, SAMMissile = 6, Shell = 7,
	["MIRV Warhead"] = 8, Train = 9, ["Artillery Shell"] = 7, ["Air Strike"] = 12, ["Railgun Shot"] = 7, Paratroopers = 13}
local missiles = {["Atom Bomb"] = true, ["Mega Nuke"] = true, ["Hydrogen Bomb"] = true, MIRV = true, SAMMissile = true,
	Shell = true, ["MIRV Warhead"] = true, ["Artillery Shell"] = true, Scattershot = true}
local smooth = {["Atom Bomb"] = true, ["Mega Nuke"] = true, ["Hydrogen Bomb"] = true, MIRV = true, ["MIRV Warhead"] = true, ["Artillery Shell"] = true, Scattershot = true}
local nukes = {["Atom Bomb"]=true,["Mega Nuke"]=true,["Hydrogen Bomb"]=true,MIRV=true,["MIRV Warhead"]=true,Scattershot=true}
local innerOuter = {["Atom Bomb"] = {12, 30}, ["Mega Nuke"] = {24, 60}, ["Hydrogen Bomb"] = {80, 100}, ["MIRV Warhead"] = {12, 18}, Scattershot = {12,30}}
local durations = {City = 20, Factory = 20, Port = 50, ["Missile Silo"] = 100,
	["Defense Post"] = 50, ["SAM Launcher"] = 300, Artillery = 80, Airfield = 100, Railgun = 150, ['Coastal Battery'] = 80}

function Visual.isSmoothed(kind: string): boolean return smooth[kind] == true end
function Visual.isMissile(kind: string): boolean return missiles[kind] == true end
function Visual.isNuke(kind:string):boolean return nukes[kind]==true end
function Visual.hasBlastRing(kind:string):boolean return innerOuter[kind]~=nil end

-- Original: Config.unitInfo default constructionDuration (10 ticks/sec).
function Visual.constructionDuration(kind: string): number
	return durations[kind] or 50
end

-- Original: StructurePass/UnitPass atlas lookup and source layer order.
function Visual.sprite(unit: {[string]: any}): (number?, boolean)
	local kind = unit.type
	if structures[kind] ~= nil then return structures[kind], true end
	local col = mobiles[kind]
	if kind == "Train" then
		col = if unit.trainType == "Engine" or unit.trainType == "TailEngine" then 9
			elseif unit.loaded then 11 else 10
	end
	return col, false
end

-- Original: UnitPass.updateUnits, including the waiting and targetable gates.
function Visual.unit(unit: {[string]: any}, width: number, zoom: number, tickFraction: number, presentation: boolean?): {[string]: any}?
	if unit.active == false or (unit.waitTicks or 0) > 0 then return nil end
	local col, structure = Visual.sprite(unit)
	if col == nil then return nil end
	local tile = unit.tile :: number
	local x, y = tile % width, math.floor(tile / width)
	if not structure and smooth[unit.type] and unit.lastTile ~= nil and unit.lastTile ~= tile then
		local last = unit.lastTile :: number
		local oldX, oldY = last % width, math.floor(last / width)
		local a = math.clamp(tickFraction, 0, 1)
		x, y = oldX + (x - oldX) * a, oldY + (y - oldY) * a
	end
	local size = if structure then (if presentation then Structure.presentationSize(unit.type,zoom) else Structure.size(unit.type, zoom).screenSize) else 13 * zoom
	local kind = unit.type
	return {x = x, y = y, size = size, column = col, structure = structure,
		missile = missiles[kind] == true, underConstruction = unit.underConstruction == true,
		markedForDeletion = unit.markedForDeletion ~= nil and unit.markedForDeletion ~= false,
		flicker = missiles[kind] == true, dim = unit.targetable == false and missiles[kind] == true,
		angry = kind == "Warship" and unit.targetUnitId ~= nil,
		retreating = kind == "Warship" and (unit.retreating == true or (unit.warship ~= nil and unit.warship.state == "retreating")),
		dots = structure and zoom <= 1.2,
		level = if structure and zoom > 1.2 and (unit.level or 1) > 1 then unit.level else nil,
		station = structure and unit.hasTrainStation == true,
		trailTile = if kind == "Shell" and unit.lastTile ~= tile then unit.lastTile else nil}
end

-- Original: BarPass.computeStructureProgress/missileReadiness.
-- Caller supplies the exact match Config values; missing construction start
-- suppresses that bar instead of inventing a fresh progress value.
function Visual.progress(unit: {[string]: any}, tick: number, cooldown: number, deletionDuration: number, constructionDuration: number?): number?
	if type(unit.markedForDeletion) == "number" then
		return math.clamp((unit.markedForDeletion - tick) / deletionDuration, 0, 1)
	end
	if unit.underConstruction then
		if unit.constructionStartTick == nil then return nil end
		return math.clamp((tick - unit.constructionStartTick) / (constructionDuration or 50), 0, 1)
	end
	if unit.type ~= "SAM Launcher" and unit.type ~= "Missile Silo" and unit.type~="Airfield" and unit.type~="Railgun" then return nil end
	local queue = unit.missileTimerQueue or {}
	if #queue == 0 then return nil end
	local maxMissiles = math.max(1, unit.level or 1)
	local readiness = (maxMissiles - #queue) / maxMissiles
	local duration=unit.reloadTicks or cooldown
	if duration<=0 then return nil end
	for _, launch in queue do readiness += (tick - launch) / duration / maxMissiles end
	readiness=math.clamp(readiness,0,1)
	return if readiness<1 then readiness else nil
end

-- Original Field Works presentation. Both durations come from the shared
-- execution; a snapshot can recover construction progress from expiresAt.
function Visual.fieldProgress(unit:any,tick:number,build:number,lifetime:number):number?
	if type(unit.expiresAt)~='number' or build<=0 or lifetime<=0 then return nil end
	if unit.underConstruction then return math.clamp((tick-(unit.expiresAt-lifetime-build))/build,0,1) end
	return math.clamp((unit.expiresAt-tick)/lifetime,0,1)
end

-- Original: NukeTelegraphPass input derive in WebGLFrameBuilder.
function Visual.telegraph(unit: {[string]: any}, width: number, tick: number?, planStartTick: number?, config: any?): {[string]: number}?
	local radii = innerOuter[unit.type]
	if radii == nil or unit.active == false or (unit.waitTicks or 0) > 0 or unit.targetTile == nil
		or (planStartTick ~= nil and tick ~= nil and planStartTick > tick) then return nil end
	local tile = unit.targetTile :: number
	local configured = if (unit.type == "Mega Nuke" or unit.type == "Scattershot") and config then config:nukeMagnitudes(unit.type) else nil
	return {x = tile % width + .5, y = math.floor(tile / width) + .5,
		inner = if configured then configured.inner else radii[1], outer = if configured then configured.outer else radii[2]}
end

-- Original: RailroadPass.railExtremity / railDirection (1..6 encoding).
function Visual.railType(prev: number?, tile: number, next: number?, width: number): number
	-- Original RailroadPass.computePathOrientations: a one-tile path is vertical.
	if prev == nil and next == nil then return 1 end
	if prev == nil or next == nil then
		local other = (prev or next) :: number
		return if other % width == tile % width then 1 else 2
	end
	local x1, x2, x3 = prev % width, tile % width, next % width
	local y1, y2, y3 = math.floor(prev / width), math.floor(tile / width), math.floor(next / width)
	local dx1, dy1, dx2, dy2 = x2 - x1, y2 - y1, x3 - x2, y3 - y2
	if dx1 == dx2 and dy1 == dy2 then return if dx1 ~= 0 then 2 else 1 end
	if dx1 == 0 and dx2 == 1 and dy1 == -1 then return 6 end
	if dx1 == 0 and dx2 == -1 and dy1 == -1 then return 5 end
	if dx1 == 0 and dx2 == 1 and dy1 == 1 then return 4 end
	if dx1 == 0 and dx2 == -1 and dy1 == 1 then return 3 end
	if dx1 == 1 and dx2 == 0 and dy2 == -1 then return 3 end
	if dx1 == -1 and dx2 == 0 and dy2 == -1 then return 4 end
	if dx1 == 1 and dx2 == 0 and dy2 == 1 then return 5 end
	if dx1 == -1 and dx2 == 0 and dy2 == 1 then return 6 end
	return 1
end

-- Original: RailroadPass draw zoom gate/fade.
function Visual.railFade(zoom: number): number
	local settings=Defaults.railroad
	local range=math.max(0,settings.railFadeRange)
	if range==0 then return if zoom>=settings.railMinZoom then 1 else 0 end
	return math.clamp((zoom-(settings.railMinZoom-range))/range,0,1)
end

-- Original: PlayerView.computeColors rail backdrop brightness and
-- railroad.frag.glsl local/unowned rail palette selection.
function Visual.railColor(owner: number, localPlayer: number, fill: {r: number, g: number, b: number}?,
	border: {r: number, g: number, b: number}?, patterned: boolean?): {r: number, g: number, b: number}
	if owner == 0 then return {r = .75, g = .75, b = .75} end
	if border == nil then return {r = .5, g = .5, b = .5} end
	if owner ~= localPlayer then return border end
	local base = fill or border
	local brightness = (base.r * .299 + base.g * .587 + base.b * .114)
	if patterned then
		-- Colord.brightness() rounds each operand to two decimal places.
		brightness = (math.floor(brightness * 100 + .5) / 100
			+ math.floor((border.r * .299 + border.g * .587 + border.b * .114) * 100 + .5) / 100) / 2
	else
		brightness = math.floor(brightness * 100 + .5) / 100
	end
	if brightness > .8 then return {r = 0, g = 0, b = 0} end
	return {r = 230 / 255, g = 230 / 255, b = 230 / 255}
end

return Visual
