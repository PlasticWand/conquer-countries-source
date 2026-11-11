--!strict
--!native
-- Ported from OpenFront v0.35.2 (src/client/view/MotionPlanResolver.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Moves units along motion plans (transport and trade ships, nukes,
-- trains). The server sends a plan once instead of a record per step; each
-- tick the client works out positions from it.
--   - Grid plans: tile = path[clamp(floor((tick - startTick) / ticksPerStep))].
--   - Train plans: the engine advances `speed` tiles a tick; cars follow the
--     engine's recent tiles at `spacing`, as TrainExecution moves them.
-- Pure: the caller supplies tileOf/move/rest over its unit table.

local MotionPlanResolver = {}
MotionPlanResolver.__index = MotionPlanResolver

export type PlannedUnits = {
	tileOf: (id: number) -> number?,
	move: (id: number, tile: number) -> (),
	rest: (id: number) -> (),
}

type GridPlan = { planId: number, startTick: number, ticksPerStep: number, path: { number } }
type TrainPlan = {
	planId: number,
	speed: number,
	spacing: number,
	carUnitIds: { number },
	path: { number },
	cursor: number, -- 0-based
	used: { number }, -- recent engine tiles, oldest first (capacity cap)
	cap: number,
	lastAdvancedTick: number,
}

export type MotionPlanResolver = typeof(setmetatable(
	{} :: {
		grid: { [number]: GridPlan },
		trains: { [number]: TrainPlan },
		trainUnitToEngine: { [number]: number },
	},
	MotionPlanResolver
))

function MotionPlanResolver.new(): MotionPlanResolver
	return setmetatable({ grid = {}, trains = {}, trainUnitToEngine = {} }, MotionPlanResolver)
end

function MotionPlanResolver.hasGridPlan(self: MotionPlanResolver, unitId: number): boolean
	return self.grid[unitId] ~= nil
end

function MotionPlanResolver.gridPlan(self: MotionPlanResolver, unitId: number): GridPlan?
	return self.grid[unitId]
end

function MotionPlanResolver.applyRecords(self: MotionPlanResolver, records: { any })
	for _, record in records do
		if record.kind == "grid" then
			if record.ticksPerStep >= 1 and #record.path >= 1 then
				local existing = self.grid[record.unitId]
				if not (existing and record.planId <= existing.planId) then
					self.grid[record.unitId] = {
						planId = record.planId,
						startTick = record.startTick,
						ticksPerStep = record.ticksPerStep,
						path = record.path,
					}
				end
			end
		elseif record.speed >= 1 and #record.path >= 1 then
			local existing = self.trains[record.engineUnitId]
			if not (existing and record.planId <= existing.planId) then
				if existing then
					self:_clearTrainPlan(record.engineUnitId)
				end
				local cars = record.carUnitIds
				self.trains[record.engineUnitId] = {
					planId = record.planId,
					speed = record.speed,
					spacing = record.spacing,
					carUnitIds = cars,
					path = record.path,
					cursor = 0,
					used = {},
					cap = math.max(0, #cars * record.spacing + 3),
					lastAdvancedTick = record.startTick,
				}
				self.trainUnitToEngine[record.engineUnitId] = record.engineUnitId
				for _, carId in cars do
					if carId ~= 0 then
						self.trainUnitToEngine[carId] = record.engineUnitId
					end
				end
			end
		end
	end
end

-- A unit went inactive: drop any plan it drives or rides on.
function MotionPlanResolver.unitRemoved(self: MotionPlanResolver, unitId: number)
	self.grid[unitId] = nil
	self:_clearTrainPlan(unitId)
end

function MotionPlanResolver._clearTrainPlan(self: MotionPlanResolver, unitId: number)
	local engineId = self.trainUnitToEngine[unitId] or (if self.trains[unitId] then unitId else nil)
	if engineId == nil then
		return
	end
	self.trainUnitToEngine[unitId] = nil
	local plan = self.trains[engineId]
	if plan == nil then
		return
	end
	self.trains[engineId] = nil
	self.trainUnitToEngine[engineId] = nil
	for _, carId in plan.carUnitIds do
		if carId ~= 0 then
			self.trainUnitToEngine[carId] = nil
		end
	end
end

-- Advances every plan to `tick`.
function MotionPlanResolver.advance(self: MotionPlanResolver, tick: number, units: PlannedUnits)
	for unitId, plan in self.grid do
		local tile = units.tileOf(unitId)
		if tile == nil then
			self.grid[unitId] = nil
		else
			local dt = tick - plan.startTick
			local stepIndex = if dt <= 0 then 0 else math.floor(dt / math.max(1, plan.ticksPerStep))
			local lastIndex = #plan.path - 1
			local newTile = plan.path[math.max(0, math.min(lastIndex, stepIndex)) + 1]
			if newTile ~= tile then
				units.move(unitId, newTile)
			else
				units.rest(unitId)
				-- Past the last step the unit stays put: the plan is done.
				if dt > 0 and stepIndex >= lastIndex then
					self.grid[unitId] = nil
				end
			end
		end
	end

	local stale = {}
	for engineId, plan in self.trains do
		if units.tileOf(engineId) == nil then
			table.insert(stale, engineId)
		else
			local steps = tick - plan.lastAdvancedTick
			if steps > 0 then
				local path = plan.path
				local lastIndex = #path - 1
				local didMove = false
				for _ = 1, steps do
					local cursor = plan.cursor
					if cursor >= lastIndex then
						break
					end
					local i = 0
					while i < plan.speed and cursor + i < #path do
						if plan.cap > 0 then
							table.insert(plan.used, path[cursor + i + 1])
							if #plan.used > plan.cap then
								table.remove(plan.used, 1)
							end
						end
						i += 1
					end
					plan.cursor = math.min(lastIndex, cursor + plan.speed)
					for k = #plan.carUnitIds, 1, -1 do
						local carId = plan.carUnitIds[k]
						if carId ~= 0 then
							local carTile = units.tileOf(carId)
							local tile = plan.used[k * plan.spacing + 2 + 1]
							if carTile ~= nil and tile ~= nil and tile ~= carTile then
								units.move(carId, tile)
								didMove = true
							end
						end
					end
					local engineTile = path[plan.cursor + 1]
					if engineTile ~= units.tileOf(engineId) then
						units.move(engineId, engineTile)
						didMove = true
					end
				end
				plan.lastAdvancedTick = tick
				if not didMove and plan.cursor >= lastIndex then
					table.insert(stale, engineId)
				end
			end
		end
	end
	for _, engineId in stale do
		self:_clearTrainPlan(engineId)
	end
end

return MotionPlanResolver
