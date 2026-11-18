--!strict
-- Studio-only filming (Bruno, 2026-11-12: a game page video like RoWorld's,
-- "Build -> Conquer -> Dominate", from real gameplay). Each beat of the shot
-- list is staged through the real intent path in a real solo match: the
-- action on camera is the game playing, at normal speed. Off camera it may
-- hand the filming player resources (gold, troops, Arsenal unlocks) or grow
-- them (nations surrendering, as the debug probe's `conquer`) so the next
-- beat is ready; those shortcuts are never what the camera shows.
--
-- ServerStorage.ConquestFilming:Invoke(command, args) returns a table with
-- `anchor = { x, y }` (map tiles) for Codex's film camera
-- (Players.LocalPlayer.OpenFrontFilmCamera) and what was done, or
-- `{ error = "..." }`. Commands:
--   status                     tick, phase, the player's land share, troops, gold
--   spawn  { x?, y? }          spawn phase: capital on free land near (x, y)
--   expand { ratio? }          one expansion order into free land
--   invade { ratio?, troops?, target? } attack the neighbour with the longest
--                              border; target = "small" picks the smallest
--                              neighbouring nation (of at least `min` tiles,
--                              default 150) or a display name picks that one,
--                              and the reply's `box` frames their whole land
--   navy   { count?, dist?, health? } off camera: an enemy nation's warships
--                              (default 3) appear on our fleet's sea `dist`
--                              tiles away (default 22), `health` of full
--                              (default 1), and sail at it, so they fight
--   build  { unit, count?, gold? } real build orders (Port, City, Factory,
--                              Missile Silo, Warship...) near the capital
--   boat   { ratio? }          a transport to the nearest enemy coast in reach
--   launch { unit?, gold?, at? } a weapon (default Scattershot) at the
--                              furthest enemy land it may hit, from a silo;
--                              at = "capital": a neighbouring nation's capital
--                              (nearest the silo first), for a close shot
--   ships                      where trade ships, our trains (one entry per
--                              train) and our warships are now
--   grow   { share? }          off camera: nearest nations surrender until
--                              the player holds `share` of the land (0.77)
--   finish { ratio?, troops? } the final attack on the biggest neighbour
--   hold   { on }              freeze the match (the camera can still move)
-- For the shorts (Bruno, 2026-11-17: docs/shorts/PLAN.md):
--   ally   { target?, delay? } we ask a neighbouring nation (as invade picks
--                              it) for an alliance, and `delay` s later
--                              (default 1.2) it answers through the game's
--                              own AllianceRequestExecution
--   betray { target?, troops?, ratio?, delay? } our ally on the border breaks
--                              the alliance (the game marks it the traitor)
--                              and `delay` s later (0.4) attacks us with
--                              `ratio` (0.6) of its troops, topped up to
--                              `troops` off camera first
--   troops { share? }          off camera: our troops set to `share` of our
--                              maximum (1 = a full bar); replies with the
--                              growth per second at that level
--   launch { at = "capital", target = name } picks that nation's capital
-- invade, boat, launch, finish, navy, ally and betray take `dry = true`:
-- report the anchor and target without acting, so the camera can be in
-- place first.

local Filming = {}

export type Context = {
	-- The first running match and its first member (Roblox player, their
	-- game player and client id), or nil.
	focus: () -> (any?, Player?, any?, string?),
}

local function anchorOf(game: any, tiles: { number }): { x: number, y: number }?
	if #tiles == 0 then
		return nil
	end
	local sx, sy = 0, 0
	for _, t in tiles do
		sx += game:x(t)
		sy += game:y(t)
	end
	return { x = sx / #tiles + 0.5, y = sy / #tiles + 0.5 }
end

local function tileAnchor(game: any, t: number): { x: number, y: number }
	return { x = game:x(t) + 0.5, y = game:y(t) + 0.5 }
end

local function share(game: any, me: any): number
	local land = game:numLandTiles()
	return if land > 0 then me:numTilesOwned() / land else 0
end

-- Other players who border `me`, with the border tiles of ours touching them.
local function neighbours(game: any, me: any): { [any]: { number } }
	local out: { [any]: { number } } = {}
	local w, h = game:width(), game:height()
	for _, t in me:borderTiles():values() do
		local x, y = game:x(t), game:y(t)
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local nx, ny = x + d[1], y + d[2]
			if nx >= 0 and ny >= 0 and nx < w and ny < h then
				local o = game:owner(game:ref(nx, ny))
				if o ~= me and o:isPlayer() and o:isAlive() then
					local list = out[o]
					if list == nil then
						list = {}
						out[o] = list
					end
					table.insert(list, t)
					break
				end
			end
		end
	end
	return out
end

local function longestBorder(game: any, me: any): (any?, { number })
	local best, bestTiles = nil, {}
	for p, tiles in neighbours(game, me) do
		if p:type() ~= "BOT" and #tiles > #bestTiles then
			best, bestTiles = p, tiles
		end
	end
	if best == nil then
		for p, tiles in neighbours(game, me) do
			if #tiles > #bestTiles then
				best, bestTiles = p, tiles
			end
		end
	end
	return best, bestTiles
end

-- The centre and size (in tiles) of a set of tiles, for framing a whole country.
local function boxOf(game: any, tiles: { number }): { x: number, y: number, w: number, h: number }?
	if #tiles == 0 then
		return nil
	end
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, t in tiles do
		local x, y = game:x(t), game:y(t)
		x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
	end
	return { x = (x0 + x1 + 1) / 2, y = (y0 + y1 + 1) / 2, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

-- The neighbour `invade` attacks: the longest border by default; "small" is
-- the smallest neighbouring nation with at least `min` tiles; else a name.
local function invadeTarget(game: any, me: any, want: any, min: number): (any?, { number })
	if want == nil then
		return longestBorder(game, me)
	end
	local best, bestTiles = nil, {}
	for p, tiles in neighbours(game, me) do
		if want == "small" then
			if p:type() == "NATION" and p:numTilesOwned() >= min and (best == nil or p:numTilesOwned() < best:numTilesOwned()) then
				best, bestTiles = p, tiles
			end
		elseif string.lower(p:displayName()) == string.lower(tostring(want)) then
			return p, tiles
		end
	end
	return best, bestTiles
end

local function sortedByDistance(game: any, tiles: { number }, from: number): { number }
	table.sort(tiles, function(a, b)
		return game:euclideanDistSquared(a, from) < game:euclideanDistSquared(b, from)
	end)
	return tiles
end

local function costOf(game: any, me: any, unit: string): number
	local ok, cost = pcall(function()
		return game:unitInfo(unit).cost(game, me)
	end)
	return if ok and type(cost) == "number" then cost else 0
end

local function unlockArsenal(me: any)
	local ArsenalUnits = require(game:GetService("ReplicatedStorage").Shared.OpenFront.ArsenalUnits) :: any
	local all = table.clone(me.playerInfo.weapons or {})
	for _, key in ArsenalUnits.KEYS do
		all[key] = true
	end
	me.playerInfo.weapons = all
end

local commands: { [string]: (match: any, me: any, id: string, args: { [string]: any }) -> { [string]: any } } = {}

function commands.status(match, me, _id, _args)
	local g = match.runner.game
	return {
		tick = g:ticks(),
		spawnPhase = g:inSpawnPhase(),
		share = share(g, me),
		tiles = me:numTilesOwned(),
		troops = me:troops(),
		gold = me:gold(),
		alive = me:isAlive(),
		hold = match.filmHold == true,
		anchor = if me:spawnTile() then tileAnchor(g, me:spawnTile()) else nil,
	}
end

function commands.hold(match, _me, _id, args)
	match.filmHold = args.on ~= false
	match.accum = 0
	return { hold = match.filmHold }
end

-- Free land near (x, y) (default: West Africa's coast) within 40 tiles of a
-- shore, so later beats have ports and boats.
function commands.spawn(match, me, id, args)
	local g = match.runner.game
	if not g:inSpawnPhase() then
		return { error = "not in the spawn phase" }
	end
	local cx = math.floor(tonumber(args.x) or 960)
	local cy = math.floor(tonumber(args.y) or 470)
	for r = 0, 120, 3 do
		for dy = -r, r, 3 do
			for dx = -r, r, 3 do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local x, y = cx + dx, cy + dy
					if x >= 0 and y >= 0 and x < g:width() and y < g:height() then
						local t = g:ref(x, y)
						if g:isLand(t) and not g:hasOwner(t) and not g:isShore(t) then
							local ok, reason = match.runner:intent(id, { type = "spawn", tile = t })
							if ok then
								return { anchor = tileAnchor(g, t), tile = t }
							end
							return { error = tostring(reason) }
						end
					end
				end
			end
		end
	end
	return { error = "no free land near there" }
end

function commands.expand(match, me, id, args)
	local g = match.runner.game
	local ratio = tonumber(args.ratio) or 0.4
	for _, t in me:borderTiles():values() do
		local x, y = g:x(t), g:y(t)
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local nx, ny = x + d[1], y + d[2]
			if nx >= 0 and ny >= 0 and nx < g:width() and ny < g:height() then
				local n = g:ref(nx, ny)
				if g:isLand(n) and not g:hasOwner(n) then
					local ok, reason = match.runner:intent(id, { type = "tile_action", tile = n, ratio = ratio })
					local home = me:spawnTile()
					return if ok then { anchor = if home then tileAnchor(g, home) else tileAnchor(g, n), tile = n } else { error = tostring(reason) }
				end
			end
		end
	end
	return { error = "no free land on the border" }
end

function commands.invade(match, me, id, args)
	local g = match.runner.game
	local target, tiles = invadeTarget(g, me, args.target, tonumber(args.min) or 150)
	if target == nil then
		return { error = "no neighbour" }
	end
	local reply = {
		anchor = anchorOf(g, tiles),
		target = target:displayName(),
		border = #tiles,
		box = boxOf(g, target:tiles():values()),
		theirTiles = target:numTilesOwned(),
		theirTroops = target:troops(),
	}
	if args.dry then
		reply.dry = true
		return reply
	end
	if tonumber(args.troops) then
		me:setTroops(tonumber(args.troops) :: number)
	end
	local ratio = tonumber(args.ratio) or 0.5
	local ok, reason = match.runner:intent(id, { type = "attack", troops = me:troops() * ratio, targetID = target:id() })
	if not ok then
		return { error = tostring(reason) }
	end
	return reply
end

-- Where `unit` may go, nearest the capital first: shore tiles for a Port,
-- water near our ports for a Warship, else our own land.
local function placesFor(g: any, me: any, unit: string): { number }
	local home = me:spawnTile()
	local out = {}
	if unit == "Warship" then
		for _, port in me:units("Port") do
			local px, py = g:x(port:tile()), g:y(port:tile())
			for dy = -12, 12, 2 do
				for dx = -12, 12, 2 do
					local x, y = px + dx, py + dy
					if x >= 0 and y >= 0 and x < g:width() and y < g:height() then
						local t = g:ref(x, y)
						if g:isOcean(t) then
							table.insert(out, t)
						end
					end
				end
			end
		end
		return out
	end
	for _, t in me:tiles():values() do
		if unit ~= "Port" or g:isShore(t) then
			table.insert(out, t)
		end
	end
	return if home then sortedByDistance(g, out, home) else out
end

function commands.build(match, me, id, args)
	local g = match.runner.game
	local unit = tostring(args.unit or "Port")
	local count = math.clamp(tonumber(args.count) or 1, 1, 8)
	if args.gold ~= false then
		-- Prices double per structure, and every order runs in the same tick
		-- (orders from an earlier call too), so cover the whole doubling run.
		me:addGold(costOf(g, me, unit) * (2 ^ count) * 2 + 1000000)
	end
	local placed = {}
	local used: { [number]: boolean } = {}
	for i, t in placesFor(g, me, unit) do
		if #placed >= count or i > 600 then
			break
		end
		-- (structures keep their distance from each other; skip near ones)
		local near = false
		for _, p in placed do
			if g:euclideanDistSquared(p, t) < 15 * 15 then
				near = true
				break
			end
		end
		if not near and not used[t] and me:canBuild(unit, t) ~= false then
			local ok = match.runner:intent(id, { type = "build_action", unit = unit, tile = t })
			if ok then
				used[t] = true
				table.insert(placed, t)
			end
		end
	end
	if #placed == 0 then
		return { error = `nowhere to build {unit}` }
	end
	return { anchor = anchorOf(g, placed), placed = #placed }
end

function commands.boat(match, me, id, args)
	local g = match.runner.game
	local home = me:spawnTile()
	if home == nil then
		return { error = "no capital" }
	end
	local candidates = {}
	for _, p in g:allPlayers() do
		if p ~= me and p:isAlive() and p:type() ~= "BOT" then
			for _, t in p:borderTiles():values() do
				if g:isShore(t) then
					table.insert(candidates, t)
				end
			end
		end
	end
	sortedByDistance(g, candidates, home)
	for i, t in candidates do
		if i > 400 then
			break
		end
		local launch = me:canBuild("Transport", t)
		if launch ~= false and not me:sharesBorderWith(g:owner(t)) then
			if args.dry then
				return { anchor = anchorOf(g, { launch, t }), from = tileAnchor(g, launch), to = tileAnchor(g, t), target = g:owner(t):displayName(), dry = true }
			end
			if tonumber(args.troops) then
				me:setTroops(tonumber(args.troops) :: number)
			end
			local ok, reason = match.runner:intent(id, { type = "boat", dst = t, troops = me:troops() * (tonumber(args.ratio) or 0.3) })
			if not ok then
				return { error = tostring(reason) }
			end
			return { anchor = anchorOf(g, { launch, t }), from = tileAnchor(g, launch), to = tileAnchor(g, t), target = g:owner(t):displayName() }
		end
	end
	return { error = "no enemy coast in reach" }
end

function commands.launch(match, me, id, args)
	local g = match.runner.game
	local unit = tostring(args.unit or "Scattershot")
	unlockArsenal(me)
	if args.gold ~= false then
		me:addGold(costOf(g, me, unit) * 2 + 1000000)
	end
	local silos = me:units("Missile Silo")
	if #silos == 0 then
		return { error = "no Missile Silo yet: build one first (build { unit = \"Missile Silo\" })" }
	end
	local from = silos[1]:tile()
	local target, tiles = longestBorder(g, me)
	if args.at == "capital" then
		-- A neighbouring nation's capital, nearest the silo first: a short
		-- flight the camera can hold close on.
		local capitals = {}
		local want = if args.target ~= nil then string.lower(tostring(args.target)) else nil
		for p, _ in neighbours(g, me) do
			if p:type() == "NATION" and p:spawnTile() and (want == nil or string.lower(p:displayName()) == want) then
				table.insert(capitals, p:spawnTile())
			end
		end
		for _, t in sortedByDistance(g, capitals, from) do
			-- Skip capitals an enemy SAM covers (it would shoot the bomb down
			-- off camera; 2026-11-13 shoot). Range per the SAM's level.
			local covered = false
			for _, near in g:nearbyUnits(t, g:config():maxSamRange(), { "SAM Launcher" }) do
				local sam = near.unit
				if sam:owner() ~= me and near.distSquared <= g:config():samRange(sam:level()) ^ 2 then
					covered = true
					break
				end
			end
			if not covered and me:canBuild(unit, t) ~= false then
				local who = g:owner(t)
				local reply = { anchor = tileAnchor(g, t), from = tileAnchor(g, from), target = who:displayName(), box = boxOf(g, who:tiles():values()) }
				if args.dry then
					reply.dry = true
					return reply
				end
				local ok, reason = match.runner:intent(id, { type = "build_action", unit = unit, tile = t })
				if not ok then
					return { error = tostring(reason) }
				end
				return reply
			end
		end
		return { error = `no neighbouring capital in reach for {unit}` }
	end
	local candidates = {}
	for p, _ in neighbours(g, me) do
		if p:type() == "NATION" then
			for _, c in p:units("City") do
				table.insert(candidates, c:tile())
			end
		end
	end
	if target then
		for _, t in target:tiles():values() do
			table.insert(candidates, t)
		end
	end
	-- Deep in their land, not on our border: furthest from us first among
	-- those within reach.
	table.sort(candidates, function(a, b)
		return g:euclideanDistSquared(a, from) > g:euclideanDistSquared(b, from)
	end)
	for i, t in candidates do
		if i > 3000 then
			break
		end
		if me:canBuild(unit, t) ~= false then
			if args.dry then
				return { anchor = tileAnchor(g, t), from = tileAnchor(g, from), target = g:owner(t):displayName(), dry = true }
			end
			local preview = match.runner:buildPreview(id, t, unit)
			local ok, reason = match.runner:intent(id, { type = "build_action", unit = unit, tile = t })
			if not ok then
				return { error = tostring(reason) }
			end
			return { anchor = tileAnchor(g, t), from = tileAnchor(g, from), target = g:owner(t):displayName(), border = #tiles, preview = preview and preview.strikeAim }
		end
	end
	return { error = `no target in reach for {unit}` }
end

function commands.ships(match, me, _id, _args)
	local g = match.runner.game
	local trains: { { anchor: { x: number, y: number }, tile: number, cars: number } } = {}
	local out: { [string]: any } = { trade = {}, trains = trains, warships = {} }
	for _, u in g:units("Trade Ship") do
		table.insert(out.trade, { anchor = tileAnchor(g, u:tile()), mine = u:owner() == me })
	end
	-- Our trains only, about one entry per train: a train is a row of Train
	-- units spanning ~11 tiles, so cars within 13 tiles of a listed one join it.
	for _, u in me:units("Train") do
		local t = u:tile()
		local seen = false
		for _, listed in trains do
			if g:euclideanDistSquared(listed.tile, t) <= 169 then
				listed.cars += 1
				seen = true
				break
			end
		end
		if not seen then
			table.insert(trains, { anchor = tileAnchor(g, t), tile = t, cars = 1 })
		end
	end
	for _, u in me:units("Warship") do
		table.insert(out.warships, { anchor = tileAnchor(g, u:tile()) })
	end
	local ports = {}
	for _, p in me:units("Port") do
		table.insert(ports, p:tile())
	end
	out.anchor = anchorOf(g, ports)
	return out
end

-- Off camera: an enemy nation's warships appear on our fleet's sea, `dist`
-- tiles out, patrolling onto our fleet, so the real warship rules start a
-- fight. They are built by the game's own buildUnit (their gold is topped
-- up first) and run by WarshipExecution like any warship.
function commands.navy(match, me, _id, args)
	local g = match.runner.game
	local ours = me:units("Warship")
	if #ours == 0 then
		return { error = "no warships yet: build { unit = \"Warship\", count = 3 } first" }
	end
	local tiles = {}
	for _, u in ours do
		table.insert(tiles, u:tile())
	end
	local centre = anchorOf(g, tiles) :: { x: number, y: number }
	local home = ours[1]:tile()
	local component = g:getWaterComponent(home)
	-- The nearest nation that isn't on our side.
	local enemy, best = nil, math.huge
	for _, p in g:allPlayers() do
		if p ~= me and p:isAlive() and p:type() == "NATION" and p:spawnTile() and not me:isFriendly(p) then
			local d = g:euclideanDistSquared(p:spawnTile(), home)
			if d < best then
				enemy, best = p, d
			end
		end
	end
	if enemy == nil then
		return { error = "no enemy nation" }
	end
	-- Open water `dist` tiles from our fleet, on the same sea, spread round a
	-- quarter circle so they arrive as a group.
	local dist = tonumber(args.dist) or 22
	local count = math.clamp(tonumber(args.count) or 3, 1, 6)
	local spots = {}
	for step = 0, 71 do
		if #spots >= count then
			break
		end
		local a = step * (math.pi / 36)
		local x = math.floor(centre.x + math.cos(a) * dist)
		local y = math.floor(centre.y + math.sin(a) * dist)
		if x >= 0 and y >= 0 and x < g:width() and y < g:height() then
			local t = g:ref(x, y)
			local clear = true
			for _, s in spots do
				if g:euclideanDistSquared(s, t) < 16 then
					clear = false
				end
			end
			if clear and g:isOcean(t) and component ~= nil and g:hasWaterComponent(t, component) then
				table.insert(spots, t)
			end
		end
	end
	if #spots == 0 then
		return { error = "no open water near our fleet" }
	end
	local reply = { anchor = centre, enemy = enemy:displayName(), spots = #spots }
	if args.dry then
		reply.dry = true
		return reply
	end
	local WarshipExecution = require(game:GetService("ReplicatedStorage").Shared.OpenFront.Executions.WarshipExecution) :: any
	enemy:addGold(costOf(g, enemy, "Warship") * #spots * 2 + 100000)
	for _, t in spots do
		local ship = enemy:buildUnit("Warship", t, { patrolTile = home })
		-- Arriving battle-worn (`health`, a share of full), so ours win.
		local health = math.clamp(tonumber(args.health) or 1, 0.05, 1)
		if health < 1 then
			ship:modifyHealth(-ship:maxHealth() * (1 - health))
		end
		g:addExecution(WarshipExecution.new(ship))
	end
	return reply
end

function commands.grow(match, me, _id, args)
	local g = match.runner.game
	local HumanProtection = require(game:GetService("ReplicatedStorage").Shared.OpenFront.HumanProtection) :: any
	local want = math.clamp(tonumber(args.share) or 0.77, 0.05, 0.79)
	local home = me:spawnTile()
	if home == nil then
		return { error = "no capital" }
	end
	local nations = {}
	for _, p in g:allPlayers() do
		if p ~= me and p:isAlive() and p:type() ~= "HUMAN" and p:spawnTile() then
			table.insert(nations, p)
		end
	end
	table.sort(nations, function(a, b)
		return g:euclideanDistSquared(a:spawnTile(), home) < g:euclideanDistSquared(b:spawnTile(), home)
	end)
	local taken = 0
	for _, p in nations do
		if share(g, me) + p:numTilesOwned() / g:numLandTiles() > want then
			continue
		end
		HumanProtection.surrender(g, p, me)
		taken += 1
	end
	return { share = share(g, me), taken = taken, anchor = if home then tileAnchor(g, home) else nil }
end

function commands.ally(match, me, id, args)
	local g = match.runner.game
	local target, tiles = invadeTarget(g, me, args.target, tonumber(args.min) or 150)
	if target == nil then
		return { error = "no neighbour" }
	end
	local reply = { anchor = anchorOf(g, tiles), target = target:displayName(), box = boxOf(g, target:tiles():values()) }
	if args.dry then
		reply.dry = true
		return reply
	end
	if me:isAlliedWith(target) then
		return { error = `already allied with {target:displayName()}` }
	end
	local ok, reason = match.runner:intent(id, { type = "allianceRequest", recipient = target:id() })
	if not ok then
		return { error = tostring(reason) }
	end
	local AllianceRequestExecution = require(game:GetService("ReplicatedStorage").Shared.OpenFront.Executions.AllianceRequestExecution) :: any
	task.delay(tonumber(args.delay) or 1.2, function()
		if not target:isAlive() or target:isAlliedWith(me) then
			return
		end
		-- Accepts our pending request; if their AI already turned it down,
		-- this asks us instead, and our second request below accepts that.
		g:addExecution(AllianceRequestExecution.new(target, me:id()))
		task.delay(0.5, function()
			if target:isAlive() and not target:isAlliedWith(me) then
				match.runner:intent(id, { type = "allianceRequest", recipient = target:id() })
			end
		end)
	end)
	return reply
end

function commands.betray(match, me, _id, args)
	local g = match.runner.game
	local want = if args.target ~= nil then string.lower(tostring(args.target)) else nil
	local traitor, tiles = nil, {}
	for p, border in neighbours(g, me) do
		if me:isAlliedWith(p) and (want == nil or string.lower(p:displayName()) == want) and #border > #tiles then
			traitor, tiles = p, border
		end
	end
	if traitor == nil then
		return { error = "no ally on our border: ally { target = ... } first" }
	end
	local reply = { anchor = anchorOf(g, tiles), target = traitor:displayName(), border = #tiles, box = boxOf(g, me:tiles():values()) }
	if args.dry then
		reply.dry = true
		return reply
	end
	if tonumber(args.troops) then
		traitor:setTroops(tonumber(args.troops) :: number)
	end
	local Executions = game:GetService("ReplicatedStorage").Shared.OpenFront.Executions
	local BreakAllianceExecution = require(Executions.BreakAllianceExecution) :: any
	local AttackExecution = require(Executions.AttackExecution) :: any
	g:addExecution(BreakAllianceExecution.new(traitor, me:id()))
	local ratio = tonumber(args.ratio) or 0.6
	task.delay(tonumber(args.delay) or 0.4, function()
		if traitor:isAlive() and me:isAlive() and not traitor:isAlliedWith(me) then
			g:addExecution(AttackExecution.new(traitor:troops() * ratio, traitor, me:id()))
		end
	end)
	return reply
end

function commands.troops(match, me, _id, args)
	local g = match.runner.game
	local max = g:config():maxTroops(me)
	local want = math.clamp(tonumber(args.share) or 1, 0, 1)
	me:setTroops(math.floor(max * want))
	local home = me:spawnTile()
	return {
		troops = me:troops(),
		max = max,
		-- troopIncreaseRate is per tick; the match runs 10 ticks a second
		perSecond = g:config():troopIncreaseRate(me) * 10,
		anchor = if home then tileAnchor(g, home) else nil,
	}
end

function commands.finish(match, me, id, args)
	local g = match.runner.game
	local target, tiles = longestBorder(g, me)
	if target == nil then
		return { error = "no neighbour" }
	end
	if args.dry then
		return { anchor = anchorOf(g, tiles), target = target:displayName(), share = share(g, me), targetShare = target:numTilesOwned() / g:numLandTiles(), dry = true }
	end
	me:setTroops(tonumber(args.troops) or math.max(me:troops(), target:troops() * 4))
	local ok, reason = match.runner:intent(id, { type = "attack", troops = me:troops() * (tonumber(args.ratio) or 0.8), targetID = target:id() })
	if not ok then
		return { error = tostring(reason) }
	end
	return { anchor = anchorOf(g, tiles), target = target:displayName(), share = share(g, me), targetShare = target:numTilesOwned() / g:numLandTiles() }
end

-- Publishes ServerStorage.ConquestFilming (Studio only; the caller checks).
function Filming.start(ctx: Context)
	local fn = Instance.new("BindableFunction")
	fn.Name = "ConquestFilming"
	fn.OnInvoke = function(command: any, args: any): any
		local run = commands[tostring(command)]
		if run == nil then
			return { error = `unknown command {command}` }
		end
		local match, _player, me, id = ctx.focus()
		if match == nil or me == nil or id == nil then
			return { error = "no running match with a player" }
		end
		local ok, result = pcall(run, match, me, id, if type(args) == "table" then args else {})
		if not ok then
			return { error = tostring(result) }
		end
		return result
	end
	fn.Parent = game:GetService("ServerStorage")
end

return Filming
