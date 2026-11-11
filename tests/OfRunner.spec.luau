-- OpenFront port: the server runner, replication and client state together.
-- A solo match on the imported World map (compact) with tribes, a human
-- spawning and attacking. After every tick the client's rebuilt state must
-- equal the server's: every tile state, every player's stats, the viewer's
-- gold and attacks.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local ClientState = t.require("OpenFront.ClientState")

	local Maps = t.mount("src/maps", "OpenFrontMaps")

	t.test("client state mirrors the server through a solo match", function()
		local runner = Runner.new({
			gameID = "of-runner-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Singleplayer",
				difficulty = "Medium",
				bots = 60,
				nations = "disabled",
			},
		})
		t.ok(runner:addHuman("1001", "Bruno"), "joins the lobby")
		runner:start()
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local client = ClientState.new()
		client:applySnapshot(rep:snapshot("1001"))
		t.eq(client.you, game:playerByClientID("1001"):smallID(), "viewer identity")

		-- Spawn on a land tile near the middle of Europe (compact World).
		local map = game:map()
		local spawn = nil
		for dy = 0, 40 do
			for dx = 0, 40 do
				local tile = map:ref(520 + dx, 130 + dy)
				if map:isLand(tile) and not map:isImpassable(tile) then
					spawn = tile
					break
				end
			end
			if spawn then
				break
			end
		end
		t.ok(spawn ~= nil, "found land")
		t.eq(select(1, runner:intent("1001", { type = "spawn", tile = spawn })), true, "spawn accepted")
		t.eq(select(2, runner:intent("1001", { type = "nuke" })), "unsupported", "unknown intents rejected")

		local me = game:playerByClientID("1001")
		for tick = 1, 400 do
			if tick == 60 then
				-- Expand into free land with 20% of troops, as the panel's default share sends.
				runner:intent("1001", { type = "attack", troops = me:troops() * 0.2 })
			end
			runner:step()
			local delta = rep:forViewer(rep:collect(), "1001", game:drainMessages())
			client:applyDelta(delta)
			-- Every tile state matches.
			local n = map:width() * map:height()
			if tick % 50 == 0 or tick < 5 then
				for i = 0, n - 1 do
					if buffer.readu16(client.tileState, i * 2) ~= map:tileState(i) then
						error(`tick {tick}: tile {i} differs`)
					end
				end
			end
			-- The viewer's own numbers every tick; everyone else's on the ticks
			-- they are sent (Replication.STATS_EVERY apart), and whether they
			-- are alive at once.
			local everyone = (tick - 1) % Replication.STATS_EVERY == 0
			for _, p in game:allPlayers() do
				local view = client:player(p:smallID())
				t.ok(view ~= nil, `tick {tick}: player {p:smallID()} known`)
				t.eq(view.alive, p:isAlive(), `tick {tick} {p:name()} alive`)
				t.eq(view.spawnTile, p:spawnTile(), `tick {tick} {p:name()} capital`)
				if everyone or p == me then
					t.eq(view.tiles, p:numTilesOwned(), `tick {tick} {p:name()} tiles`)
					t.eq(view.troops, p:troops(), `tick {tick} {p:name()} troops`)
					t.eq(view.gold, p:gold(), `tick {tick} {p:name()} gold`)
					t.eq(view.maxTroops, game:config():maxTroops(p), `tick {tick} {p:name()} troop limit`)
				end
			end
			t.eq(client.gold, me:gold(), `tick {tick} gold`)
		end
		t.ok(not client:inSpawnPhase(), "the spawn phase ended when the human spawned (singleplayer)")
		t.ok(me:numTilesOwned() > 30, `the human expanded ({me:numTilesOwned()} tiles)`)
		t.ok(#client.rosterOrder == 61, `all players on the roster ({#client.rosterOrder})`)
	end)

	t.test("units, motion plans and rails mirror the server (with a late joiner)", function()
		local runner = Runner.new({
			gameID = "of-runner-units",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 30,
				nations = "disabled",
			},
		})
		runner:addHuman("1001", "A")
		runner:addHuman("1002", "B")
		runner:start()
		local game = runner.game
		local map = game:map()
		local rep = Replication.newReplicator(runner)
		local client = ClientState.new()
		client:applySnapshot(rep:snapshot("1001"))
		local late = nil

		-- Two coastal spawns in Europe (compact World), first shore tile at or after each seed.
		local spawns = {}
		for i, seed in { { 480, 120 }, { 540, 150 } } do
			local tile = map:ref(seed[1], seed[2])
			while not (map:isLand(tile) and map:isShore(tile)) do
				tile += 1
			end
			spawns[i] = tile
			runner:intent(`100{i}`, { type = "spawn", tile = tile })
		end
		local function waterNear(tile: number): number
			while not map:isWater(tile) do
				tile += 1
			end
			return tile
		end

		local builds = { "Port", "Factory", "City", "Port", "City", "Factory", "City" }
		local maxUnits, sawPlanUnit, finalRecords = 0, false, 0
		for tick = 1, 1400 do
			if not game:inSpawnPhase() then
				for i = 1, 2 do
					local id = `100{i}`
					local p = game:playerByClientID(id)
					if p and p:isAlive() then
						if p:gold() < 1_000_000 then
							p:addGold(5_000_000) -- test-only grant
						end
						if tick % 40 == i then
							runner:intent(id, { type = "attack", troops = p:troops() * 0.3 })
						end
						if tick % 60 == 10 + i then
							local k = (tick // 60) % #builds + 1
							local offset = ((tick // 60) % 5) * 7
							runner:intent(id, { type = "build_unit", unit = builds[k], tile = spawns[i] + offset })
						end
						if tick % 200 == 100 + i then
							runner:intent(id, { type = "build_unit", unit = "Warship", tile = waterNear(spawns[i]) })
						end
					end
				end
			end
			runner:step()
			local public = rep:collect()
			-- A unit that's gone sends its final, inactive record too.
			for _, id in public.removed do
				local final = nil
				for _, rec in public.units do
					if rec.id == id then
						final = rec
					end
				end
				t.ok(final ~= nil and final.active == false, `tick {tick}: removed unit {id} sends its final record`)
				finalRecords += 1
			end
			local messages = game:drainMessages()
			client:applyDelta(rep:forViewer(public, "1001", messages))
			if late then
				late:applyDelta(public)
			elseif tick == 700 then
				late = ClientState.new()
				late:applySnapshot(rep:snapshot(nil))
			end
			local units = game:units()
			maxUnits = math.max(maxUnits, #units)
			for _, view in { client, late } do
				local count = 0
				for _ in view.units do
					count += 1
				end
				t.eq(count, #units, `tick {tick}: unit count`)
				for _, u in units do
					local rec = view.units[u:id()]
					t.ok(rec ~= nil, `tick {tick}: unit {u:id()} ({u:type()}) known`)
					-- OpenFront's MotionPlanResolver ignores the station tile a train plan
					-- prepends when its first rail was split, so its client draws such a
					-- train one step behind; ours matches that client. Everything else
					-- is exact.
					local slack = if u:type() == "Train" then 2 else 0
					if map:manhattanDist(rec.tile, u:tile()) > slack then
						error(`tick {tick}: {u:type()} {u:id()} at {rec.tile}, server {u:tile()}`)
					end
					t.eq(rec.owner, u:owner():smallID(), `tick {tick}: unit {u:id()} owner`)
					t.eq(rec.level, u:level(), `tick {tick}: unit {u:id()} level`)
					if client.plans:hasGridPlan(u:id()) then
						sawPlanUnit = true
					end
				end
			end
			if tick % 100 == 0 then
				local server = {}
				for _, station in game:railNetwork():stationManager():getAll().list do
					for _, r in station:getRailroads().list do
						server[r.id] = #r.tiles
					end
				end
				for _, view in { client, late } do
					for id, n in server do
						t.eq(view.railroads[id] and #view.railroads[id], n, `tick {tick}: railroad {id}`)
					end
					for id in view.railroads do
						t.ok(server[id] ~= nil, `tick {tick}: railroad {id} still exists`)
					end
				end
			end
		end
		local types = {}
		for _, u in game:units() do
			types[u:type()] = true
		end
		t.ok(sawPlanUnit, "plan-driven units were resolved on the client")
		t.ok(maxUnits >= 10, `units built ({maxUnits})`)
		t.ok(finalRecords > 0, `units removed with final records ({finalRecords})`)
	end)

	t.test("relations, name anchors and construction starts mirror the server (nations, late joiner)", function()
		local runner = Runner.new({
			gameID = "conqnatMed",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 40,
				nations = "default",
			},
		})
		runner:start()
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local client = ClientState.new()
		client:applySnapshot(rep:snapshot(nil))
		local late = nil
		local sawAlliance, sawConstruction = false, false
		local function check(view: any, tick: number, label: string)
			for _, p in game:allPlayers() do
				local pv = view:player(p:smallID())
				local allies = {}
				for _, a in p:allies() do
					table.insert(allies, a:smallID())
				end
				t.eq(table.concat(pv.allies, ","), table.concat(allies, ","), `{label} tick {tick}: {p:name()} allies`)
				sawAlliance = sawAlliance or #allies > 0
				local a = runner.names.anchors[p:id()]
				local n = view.names[p:smallID()]
				if a == nil then
					t.ok(n == nil, `{label} tick {tick}: {p:name()} has no anchor`)
				else
					t.ok(n ~= nil and n.x == a.x and n.y == a.y and n.size == a.size, `{label} tick {tick}: {p:name()} anchor`)
				end
			end
			for _, u in game:units() do
				local rec = view.units[u:id()]
				if u:isUnderConstruction() then
					sawConstruction = true
					t.ok(rec.constructionStartTick ~= nil and rec.constructionStartTick <= game:ticks(), `{label} tick {tick}: unit {u:id()} start`)
				end
			end
		end
		for tick = 1, 1100 do
			runner:step()
			local public = rep:collect()
			client:applyDelta(public)
			if late then
				late:applyDelta(public)
			elseif tick == 500 then
				late = ClientState.new()
				late:applySnapshot(rep:snapshot(nil))
			end
			if tick % 10 == 0 then
				check(client, tick, "client")
				if late then
					check(late, tick, "late joiner")
				end
			end
		end
		t.ok(sawAlliance, "nations made alliances")
		t.ok(sawConstruction, "structures were under construction")
	end)

	t.test("the roster carries a human's Roblox user id; bots and nations have none", function()
		local runner = Runner.new({
			gameID = "conqUserIds",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 5,
				nations = "default",
			},
		})
		runner:addHuman("1001", "Ada")
		runner:start()
		local client = ClientState.new()
		client:applySnapshot(Replication.newReplicator(runner):snapshot("1001"))
		local humans, others = 0, 0
		for _, p in runner.game:allPlayers() do
			local pv = client:player(p:smallID())
			if p:type() == "HUMAN" then
				humans += 1
				t.eq(pv.userId, 1001, "Ada's user id")
			else
				others += 1
				t.eq(pv.userId, nil, `{p:name()} ({p:type()}) has no user id`)
			end
		end
		t.eq(humans, 1, "one human")
		t.ok(others > 0, "bots and nations checked")
	end)

	t.test("diplomacy reaches both players: request, accept, emoji, embargo, betrayal", function()
		local runner = Runner.new({
			gameID = "of-diplomacy-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
			},
		})
		runner:addHuman("1001", "Ada")
		runner:addHuman("1002", "Bea")
		runner:start()
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local views = { ["1001"] = ClientState.new(), ["1002"] = ClientState.new() }
		local events = { ["1001"] = {}, ["1002"] = {} }
		local changes = { ["1001"] = 0, ["1002"] = 0 }
		for id, view in views do
			view:applySnapshot(rep:snapshot(id))
			view.DiplomacyEvents:Connect(function(list)
				for _, e in list do
					table.insert(events[id], e)
				end
			end)
			view.DiplomacyChanged:Connect(function()
				changes[id] += 1
			end)
		end
		local function step(n: number)
			for _ = 1, n do
				runner:step()
				local public = rep:collect()
				local messages = game:drainMessages()
				for id, view in views do
					view:applyDelta(rep:forViewer(public, id, messages))
				end
			end
		end
		local function has(id: string, kind: string): boolean
			for _, e in events[id] do
				if e.type == kind then
					return true
				end
			end
			return false
		end
		-- Spawn both on free land, then wait out the spawn phase.
		local map = game:map()
		local n = map:width() * map:height()
		for i, id in { "1001", "1002" } do
			for tile = math.floor(n * i / 3), n - 1, 7 do
				if map:isLand(tile) and not game:hasOwner(tile) then
					t.ok(runner:intent(id, { type = "spawn", tile = tile }), `{id} spawns`)
					break
				end
			end
		end
		while game:inSpawnPhase() do
			step(1)
		end
		step(5)
		local ada, bea = game:playerByClientID("1001"), game:playerByClientID("1002")

		t.ok(runner:intent("1001", { type = "allianceRequest", recipient = bea:id() }), "request accepted by the runner")
		step(2)
		t.ok(has("1002", "AllianceRequest"), "Bea is told about the request")
		local incoming = views["1002"].diplomacy.incoming
		t.eq(#incoming, 1, "Bea has one incoming request")
		t.eq(incoming[1].requestor, ada:smallID(), "from Ada")
		t.eq(views["1001"].diplomacy.outgoing[1].recipient, bea:smallID(), "Ada sees her outgoing request")
		local HudModelP = t.require("OpenFront.HudModel")
		local prompts = HudModelP.newPrompts()
		prompts:onEvents(views["1002"], events["1002"])
		local cards = prompts:tick(views["1002"])
		t.eq(#cards, 1, "Bea has one alliance card")
		t.eq(cards[1].text, "Ada requests an alliance!", "worded as OpenFront")

		-- Bea accepts by requesting back (OpenFront's accept).
		runner:intent("1002", { type = "allianceRequest", recipient = ada:id() })
		step(2)
		t.ok(has("1001", "AllianceRequestReply"), "Ada hears the reply")
		for id, view in views do
			t.eq(#view.diplomacy.alliances, 1, `{id} has the alliance`)
			t.eq(#view.diplomacy.incoming + #view.diplomacy.outgoing, 0, `{id} has no pending requests`)
		end
		t.eq(views["1001"].diplomacy.alliances[1].other, bea:smallID(), "Ada's ally is Bea")
		t.eq(views["1001"]:player(ada:smallID()).allies[1], bea:smallID(), "allies are public")
		local acts = runner:playerActions("1001", nil, bea:smallID()) :: any
		t.eq(acts.other, bea:smallID(), "actions are about Bea")
		t.ok(acts.interaction.canBreakAlliance and not acts.interaction.canSendAllianceRequest, "allied: break, not request")
		t.ok(acts.interaction.canEmbargo and acts.interaction.canSendEmoji, "embargo and emoji allowed")
		t.ok(runner:playerActions("nobody", nil, bea:smallID()) == nil, "unknown viewers get nothing")

		runner:intent("1001", { type = "emoji", recipient = bea:id(), emoji = 20 })
		runner:intent("1001", { type = "quick_chat", recipient = bea:id(), quickChatKey = "help.troops" })
		step(2)
		t.ok(has("1002", "Emoji"), "Bea gets the emoji")
		t.ok(has("1002", "DisplayChatEvent"), "Bea gets the quick chat")
		-- A target request goes to the targeter's friends, not back to them.
		local HudModelT = t.require("OpenFront.HudModel")
		local targetEvent = { type = "TargetPlayer", playerID = ada:smallID(), targetID = bea:smallID() }
		t.ok(HudModelT.feedLine(views["1001"], targetEvent) == nil, "the targeter isn't told their own request")

		-- The HUD model's lines and cards, as OpenFront's HUD words them.
		local HudModel = t.require("OpenFront.HudModel")
		local function lines(id: string): { string }
			local out = {}
			for _, e in events[id] do
				local line = HudModel.feedLine(views[id], e)
				if line then
					table.insert(out, line.text)
				end
			end
			return out
		end
		local adaLines = table.concat(lines("1001"), " | ")
		t.ok(string.find(adaLines, "Bea accepted your alliance request", 1, true) ~= nil, `Ada's feed: {adaLines}`)
		local beaLines = table.concat(lines("1002"), " | ")
		t.ok(string.find(beaLines, "Ada: ", 1, true) ~= nil, `Bea sees the emoji: {beaLines}`)
		t.ok(string.find(beaLines, "Ada", 1, true) ~= nil and string.find(beaLines, "troops", 1, true) ~= nil, `Bea sees the chat: {beaLines}`)
		local items = HudModel.buildItems(views["1001"])
		t.eq(#items, 10, "ten build-bar items")
		t.eq(items[1].type, "City", "City first")
		t.eq(items[1].key, "1", "on key 1")
		t.eq(items[8].enabled, false, "no atom bomb without a silo")

		runner:intent("1001", { type = "breakAlliance", recipient = bea:id() })
		step(2)
		local traitorLine = table.concat(lines("1001"), " | ")
		t.ok(string.find(traitorLine, "TRAITOR", 1, true) ~= nil, `Ada is told she's a traitor: {traitorLine}`)
		t.ok(string.find(table.concat(lines("1002"), " | "), "Ada broke their alliance with you", 1, true) ~= nil, "Bea is told")
		t.ok(has("1002", "BrokeAlliance"), "Bea learns of the betrayal")
		t.eq(#views["1002"].diplomacy.alliances, 0, "the alliance is gone")
		t.ok(views["1002"]:player(ada:smallID()).traitor, "Ada is a traitor to everyone")
		local adaSeen = views["1002"]:player(ada:smallID()) :: any
		t.eq(adaSeen.betrayals, 1, "and her betrayal count is public (PlayerPanel)")
		t.ok(adaSeen.traitorUntil ~= nil and adaSeen.traitorUntil > game:ticks(), "with when her traitor status ends")
		t.eq(runner:playerProfile("1002", ada:smallID()), nil, "profile relations are a nations-only answer")

		runner:intent("1002", { type = "embargo", targetID = ada:id(), action = "start" })
		step(2)
		t.ok(has("1001", "EmbargoEvent"), "the embargo is announced")
		t.eq(views["1001"]:player(bea:smallID()).embargoes[1], ada:smallID(), "Bea's embargo on Ada is public")
		t.ok(changes["1001"] >= 3 and changes["1002"] >= 3, "DiplomacyChanged fired for requests, alliance and break")
		t.ok(views["1001"]:player(bea:smallID()).disconnected == false, "Bea is connected")
		runner:markDisconnected("1002", true)
		step(1)
		t.ok(views["1001"]:player(bea:smallID()).disconnected, "Bea shows as disconnected")
	end)

	t.test("build_action builds, then upgrades the nearest structure; costs reach the client", function()
		local runner = Runner.new({
			gameID = "of-build-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Singleplayer",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				startingGold = 5000000,
			},
		})
		runner:addHuman("1001", "Ada")
		runner:start()
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local client = ClientState.new()
		client:applySnapshot(rep:snapshot("1001"))
		local map = game:map()
		local spawn = nil
		for tile = math.floor(map:width() * map:height() / 3), map:width() * map:height() - 1, 7 do
			if map:isLand(tile) and not game:hasOwner(tile) then
				spawn = tile
				break
			end
		end
		runner:intent("1001", { type = "spawn", tile = spawn })
		local function step(n: number)
			for _ = 1, n do
				runner:step()
				client:applyDelta(rep:forViewer(rep:collect(), "1001", game:drainMessages()))
			end
		end
		step(3)
		local ada = game:playerByClientID("1001")
		t.ok(not game:inSpawnPhase(), "the game started")
		t.eq(client.costs.City, 125000, "a first city costs 125k")
		t.ok(runner:intent("1001", { type = "build_action", unit = "City", tile = spawn }), "build accepted")
		step(2)
		local cities = ada:units("City")
		t.eq(#cities, 1, "a city is under construction")
		-- Wait for it to finish, then click next to it: that upgrades it.
		local guard = 0
		while cities[1]:isUnderConstruction() and guard < 400 do
			step(1)
			guard += 1
		end
		t.ok(not cities[1]:isUnderConstruction(), "the city finished")
		t.eq(client.costs.City, 250000, "the second city costs 250k")
		runner:intent("1001", { type = "build_action", unit = "City", tile = spawn })
		step(2)
		t.eq(#ada:units("City"), 1, "still one city")
		t.eq(cities[1]:level(), 2, "it was upgraded")
		t.ok(runner:intent("1001", { type = "build_action", unit = "Nope", tile = spawn }) == false, "unknown types are refused")

		-- Pause (singleplayer): one more turn carries it, then turns stop.
		t.ok(runner:intent("1001", { type = "toggle_pause", paused = true }), "pause accepted")
		step(1)
		t.ok(runner:isPaused() and game:isPaused() and client.paused, "paused on server and client")
		local at = game:ticks()
		step(5)
		t.eq(game:ticks(), at, "no turns while paused")
		t.ok(runner:intent("1001", { type = "toggle_pause", paused = false }), "unpause accepted")
		step(1)
		t.ok(not runner:isPaused() and not game:isPaused() and not client.paused, "running again")
		t.eq(game:ticks(), at + 1, "turns resume")
	end)

	t.test("buildPreview: upgrade target and bulk totals, nuke aim from the nearest silo, SAM threats by alliance", function()
		local runner = Runner.new({
			gameID = "of-preview-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				startingGold = 50000000,
				instantBuild = true,
			},
		})
		runner:addHuman("1001", "Ada")
		runner:addHuman("1002", "Bea")
		runner:start()
		local game = runner.game
		local map = game:map()
		local n = map:width() * map:height()
		local spawns = {}
		for i, id in { "1001", "1002" } do
			for tile = math.floor(n * i / 3), n - 1, 7 do
				if map:isLand(tile) and not game:hasOwner(tile) then
					runner:intent(id, { type = "spawn", tile = tile })
					spawns[id] = tile
					break
				end
			end
		end
		local function step(k: number)
			for _ = 1, k do
				runner:step()
			end
		end
		while game:inSpawnPhase() do
			step(1)
		end
		step(5)
		local ada, bea = game:playerByClientID("1001"), game:playerByClientID("1002")
		local home, away = spawns["1001"], spawns["1002"]
		local config = game:config()

		t.ok(runner:buildPreview("1001", home, "Nope") == nil, "unknown types get nothing")
		t.ok(runner:buildPreview("nobody", home, "City") == nil, "unknown viewers get nothing")
		local off = runner:buildPreview("1001", nil, "City") :: any
		t.ok(off.buildable.canBuild == false and off.buildable.canUpgrade == false, "off the map: nothing to build")
		local fresh = runner:buildPreview("1001", home, "City") :: any
		t.ok(fresh.buildable.canBuild ~= false and fresh.buildable.canUpgrade == false, "a city can be built at home")
		t.eq(fresh.buildable.upgradeCosts, nil, "no bulk totals for a new build")
		t.ok(fresh.tile == home and fresh.unit == "City" and fresh.tick == game:ticks(), "the reply echoes tile, unit and tick")

		runner:intent("1001", { type = "build_action", unit = "City", tile = home })
		step(3)
		local city = ada:units("City")[1]
		t.ok(city ~= nil and not city:isUnderConstruction(), "the city stands")
		local up = runner:buildPreview("1001", home, "City") :: any
		t.eq(up.buildable.canUpgrade, city:id(), "clicking next to it would upgrade it")
		t.eq(#up.buildable.upgradeCosts, 50, "50 bulk totals")
		t.eq(up.buildable.upgradeCosts[1], up.buildable.cost, "the first total is one upgrade")
		t.eq(up.buildable.upgradeCosts[2], up.buildable.cost + config:unitInfo("City").cost(game, ada, 1), "the second adds the next level's price")
		t.eq(#up.buildable.ghostRailPaths, 0, "no rail ghosts for an upgrade")

		local noSilo = runner:buildPreview("1001", away, "Atom Bomb") :: any
		t.eq(noSilo.nukeAim, nil, "no silo: no aim")
		-- The city fills Ada's start: expand into free land, then put the
		-- silo wherever there is room.
		for _, tile in ada:borderTiles():values() do
			local free = nil
			for _, nb in game:neighbors(tile) do
				if game:isLand(nb) and not game:hasOwner(nb) then
					free = nb
				end
			end
			if free then
				runner:intent("1001", { type = "tile_action", tile = free, ratio = 0.5 })
				break
			end
		end
		step(150)
		local siloAt = nil
		for _, tile in ada:tiles():values() do
			if ada:canBuild("Missile Silo", tile) ~= false then
				siloAt = tile
				break
			end
		end
		t.ok(siloAt ~= nil, "Ada has room for a silo")
		runner:intent("1001", { type = "build_action", unit = "Missile Silo", tile = siloAt })
		runner:intent("1002", { type = "build_action", unit = "SAM Launcher", tile = away })
		step(3)
		local silo, sam = ada:units("Missile Silo")[1], bea:units("SAM Launcher")[1]
		t.ok(silo ~= nil and sam ~= nil, "a silo for Ada, a SAM for Bea")
		local aim = runner:buildPreview("1001", away, "Atom Bomb") :: any
		t.eq(aim.nukeAim.siloTile, silo:tile(), "aimed from Ada's silo")
		t.eq(#aim.nukeAim.sams, 1, "Bea's SAM threatens the strike")
		t.eq(aim.nukeAim.sams[1].r, config:samRange(1), "at its level's range")
		t.eq(aim.rangeWarning, false, "no ally to warn about")
		t.eq((runner:buildPreview("1001", away, "MIRV") :: any).nukeAim, nil, "MIRVs get no aim arc")

		-- Allied: Bea's SAM spares strikes elsewhere, but not one on her.
		runner:intent("1001", { type = "allianceRequest", recipient = bea:id() })
		step(2)
		runner:intent("1002", { type = "allianceRequest", recipient = ada:id() })
		step(2)
		t.ok(ada:isAlliedWith(bea), "allied")
		local elsewhere = runner:buildPreview("1001", home, "Atom Bomb") :: any
		t.eq(#elsewhere.nukeAim.sams, 0, "an ally's SAM ignores a strike that spares her")
		t.eq(elsewhere.rangeWarning, false, "no warning at home")
		local betrayal = runner:buildPreview("1001", away, "Atom Bomb") :: any
		t.eq(#betrayal.nukeAim.sams, 1, "a strike on her breaks the alliance, so her SAM engages")
		t.eq(betrayal.rangeWarning, true, "and the ghost warns")
	end)

	t.test("edge intents: tribe renewal keeps ticking, NaN/empty ids and bad amounts refused, pause race", function()
		local runner = Runner.new({
			gameID = "of-edge-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Singleplayer",
				difficulty = "Easy",
				bots = 20,
				nations = "disabled",
			},
		})
		runner:addHuman("1001", "Ada")
		runner:start()
		local game = runner.game
		for _ = 1, 5 do
			runner:step()
		end
		local map = game:map()
		for tile = math.floor(map:width() * map:height() / 3), map:width() * map:height() - 1, 7 do
			if map:isLand(tile) and not game:hasOwner(tile) then
				runner:intent("1001", { type = "spawn", tile = tile })
				break
			end
		end
		for _ = 1, 30 do
			runner:step()
		end
		local ada = game:playerByClientID("1001")
		local tribe = nil
		for _, p in game:players() do
			if p:type() == "BOT" and p:isAlive() then
				tribe = p
				break
			end
		end
		t.ok(tribe ~= nil, "a tribe to ally with")
		t.ok(runner:intent("1001", { type = "allianceRequest", recipient = tribe:id() }), "request accepted")
		for _ = 1, 60 do
			runner:step()
		end
		t.ok(ada:isAlliedWith(tribe), "the tribe accepted")
		t.ok(runner:intent("1001", { type = "allianceExtension", recipient = tribe:id() }), "renewal accepted")
		local before = game:ticks()
		for _ = 1, 200 do
			runner:step() -- TribeExecution used to throw here on every tick
		end
		t.eq(game:ticks(), before + 200, "the match keeps ticking after a tribe renewal")

		t.eq(runner:intent("1001", { type = "move_warship", unitIds = { 0 / 0 }, tile = 0 }), false, "NaN unit ids refused")
		t.eq(runner:intent("1001", { type = "move_warship", unitIds = {}, tile = 0 }), false, "an empty selection refused")
		t.eq(runner:intent("1001", { type = "move_warship", unitIds = { 1.5 }, tile = 0 }), false, "fractional ids refused")
		t.eq(runner:intent("1001", { type = "delete_unit", unitId = 0 / 0 }), false, "NaN delete refused")
		t.eq(runner:intent("1001", { type = "upgrade_structure", unitId = 1, amount = 0 }), false, "amount 0 refused")
		t.eq(runner:intent("1001", { type = "upgrade_structure", unitId = 1, amount = 51 }), false, "amount above 50 refused")
		t.ok(runner:intent("1001", { type = "upgrade_structure", unitId = 1, amount = 50 }), "amount 50 accepted")

		-- A pause and an unpause in the same turn cancel out.
		runner:intent("1001", { type = "toggle_pause", paused = true })
		runner:intent("1001", { type = "toggle_pause", paused = false })
		runner:step()
		t.ok(not runner:isPaused() and not game:isPaused(), "not stuck paused")
		local at = game:ticks()
		runner:step()
		t.eq(game:ticks(), at + 1, "turns continue")
	end)

	t.test("private diplomacy reaches only the players involved; spectators get none", function()
		local runner = Runner.new({
			gameID = "of-privacy-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				donateGold = true,
			},
		})
		local ids = { "1001", "1002", "1003" }
		for i, id in ids do
			runner:addHuman(id, ({ "Ada", "Bea", "Cy" })[i])
		end
		runner:start()
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local seen: { [string]: { [string]: number } } = { ["1001"] = {}, ["1002"] = {}, ["1003"] = {}, spectator = {} }
		local function step(k: number)
			for _ = 1, k do
				runner:step()
				local public = rep:collect()
				local messages = game:drainMessages()
				for _, id in ids do
					for _, e in rep:forViewer(public, id, messages).events or {} do
						seen[id][e.type] = (seen[id][e.type] or 0) + 1
					end
				end
				for _, e in rep:forViewer(public, nil, nil).events or {} do
					seen.spectator[e.type] = (seen.spectator[e.type] or 0) + 1
				end
			end
		end
		local map = game:map()
		local n = map:width() * map:height()
		for i, id in ids do
			for tile = math.floor(n * i / 4), n - 1, 7 do
				if map:isLand(tile) and not game:hasOwner(tile) then
					runner:intent(id, { type = "spawn", tile = tile })
					break
				end
			end
		end
		while game:inSpawnPhase() do
			step(1)
		end
		step(5)
		local ada, bea = game:playerByClientID("1001"), game:playerByClientID("1002")
		runner:intent("1001", { type = "allianceRequest", recipient = bea:id() })
		runner:intent("1001", { type = "emoji", recipient = bea:id(), emoji = 1 })
		runner:intent("1001", { type = "quick_chat", recipient = bea:id(), quickChatKey = "greet.hello" })
		step(2)
		runner:intent("1002", { type = "allianceRequest", recipient = ada:id() })
		runner:intent("1001", { type = "donate_gold", recipient = bea:id(), gold = 100 })
		runner:intent("1003", { type = "emoji", recipient = "AllPlayers", emoji = 2 })
		step(3)
		for _, kind in { "AllianceRequest", "AllianceRequestReply", "Emoji", "DisplayChatEvent" } do
			t.ok((seen["1001"][kind] or 0) > 0, `Ada sees her {kind}`)
			t.ok((seen["1002"][kind] or 0) > 0, `Bea sees {kind} sent to her`)
		end
		for _, kind in { "AllianceRequest", "AllianceRequestReply", "DisplayChatEvent", "DonateEvent" } do
			t.eq(seen["1003"][kind], nil, `Cy sees no {kind} between Ada and Bea`)
			t.eq(seen.spectator[kind], nil, `a spectator sees no {kind}`)
		end
		t.eq(seen["1003"].Emoji, 1, "Cy sees only his own emoji to everyone")
		t.eq(seen.spectator.Emoji, 1, "a spectator sees only the emoji to everyone")
	end)

	t.test("contextMenu follows the radial menu: own land, a stranger's, an ally's", function()
		local HudModel = t.require("OpenFront.HudModel")
		local runner = Runner.new({
			gameID = "of-menu-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				startingGold = 50000000,
				instantBuild = true,
			},
		})
		runner:addHuman("1001", "Ada")
		runner:addHuman("1002", "Bea")
		runner:start()
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local view = ClientState.new()
		view:applySnapshot(rep:snapshot("1001"))
		local function step(k: number)
			for _ = 1, k do
				runner:step()
				view:applyDelta(rep:forViewer(rep:collect(), "1001", game:drainMessages()))
			end
		end
		local map = game:map()
		local n = map:width() * map:height()
		local spawns = {}
		for i, id in { "1001", "1002" } do
			for tile = math.floor(n * i / 3), n - 1, 7 do
				if map:isLand(tile) and not game:hasOwner(tile) then
					runner:intent(id, { type = "spawn", tile = tile })
					spawns[id] = tile
					break
				end
			end
		end
		while game:inSpawnPhase() do
			step(1)
		end
		step(5)
		local ada, bea = game:playerByClientID("1001"), game:playerByClientID("1002")
		local home, away = spawns["1001"], spawns["1002"]
		local function menu(tile: number): any
			return HudModel.contextMenu(view, tile, runner:playerActions("1001", tile, nil, true) :: any, 0.2, true)
		end
		local function ids(m: any): string
			local out = {}
			for _, item in m.items do
				table.insert(out, item.id)
			end
			return table.concat(out, ",")
		end
		local function find(list: { any }, id: string): any
			for _, item in list do
				if item.id == id then
					return item
				end
			end
			return nil
		end

		local own = menu(home)
		t.eq(ids(own), "info,delete,ally_request,build", "own land: info, delete, alliance, build")
		t.eq(own.selected, ada:smallID(), "selected is you")
		t.ok(not find(own.items, "delete").enabled, "nothing to delete yet")
		local city = find(find(own.items, "build").sub, "build_City")
		t.ok(city.enabled and city.intent.type == "build_unit" and city.intent.tile == home, "build a city here")
		t.eq(find(find(own.items, "build").sub, "build_Atom Bomb"), nil, "the build list has no bombs")

		runner:intent("1001", city.intent)
		step(3)
		local built = ada:units("City")[1]
		t.ok(built ~= nil, "the city stands")
		t.ok((runner:playerActions("1001", home) :: any).deleteUnitCooldown > 0, "deleting waits out the cooldown from the start")
		t.ok(not find(menu(home).items, "delete").enabled, "so delete is off")
		step(100)
		own = menu(home)
		local del = find(own.items, "delete")
		t.ok(del.enabled and del.intent.unitId == built:id(), "delete offers the city")
		local up = find(find(own.items, "build").sub, "build_City")
		t.eq(up.intent.type, "upgrade_structure", "the city item now upgrades")
		t.eq(#up.sub, 4, "four bulk slots")
		t.eq(up.sub[2].label, "x5", "x1, x5, x10, max")
		t.eq(up.sub[2].intent.amount, 5, "x5 upgrades five levels")
		t.eq(up.sub[2].cost, HudModel.bulkCost((runner:playerActions("1001", home, nil, true) :: any).buildableUnits[1], 5), "priced as the bulk total")

		local stranger = menu(away)
		t.eq(stranger.selected, bea:smallID(), "Bea's land selects Bea")
		t.eq(ids(stranger), "info,boat,ally_request,attack", "a stranger: info, boat, alliance, attack")
		t.eq(stranger.center.label, "Attack", "the centre attacks")
		t.eq(stranger.center.intent.targetID, bea:id(), "aimed at Bea")
		t.ok(find(stranger.items, "ally_request").enabled, "we may ask Bea")

		-- The attack card (Bruno, 2026-10-28) on the same tiles.
		local function card(tile: number): any
			return HudModel.attackCard(view, tile, runner:playerActions("1001", tile, nil, true) :: any, 0.2)
		end
		t.eq(card(home), nil, "no card on your own land")
		local sc = card(away)
		t.eq(sc.other, bea:smallID(), "the card is Bea's")
		t.eq(sc.kind, "Player", "Bea is a player")
		t.eq(sc.relation, "NEUTRAL", "not allied yet")
		t.eq(sc.ally.id, "ally_request", "Ally asks")
		t.eq(sc.main.intent.type, if sc.boat then "boat" else "attack", "the main button attacks (by sea when the boat is picked)")
		t.eq(sc.main.intent.troops, 0.2 * view:me().troops, "at the attack ratio")

		runner:intent("1001", { type = "allianceRequest", recipient = bea:id() })
		step(2)
		runner:intent("1002", { type = "allianceRequest", recipient = ada:id() })
		step(2)
		local ally = menu(away)
		t.eq(ids(ally), "info,ally_break,donate_gold", "an ally: info, break, send gold")
		t.eq(ally.center.intent.type, "donate_troops", "the centre sends troops")
		t.eq(ally.center.intent.troops, math.floor(0.2 * view:me().troops), "at the attack ratio")
		local ac = card(away)
		t.eq(ac.relation, "ALLY", "now allies")
		t.eq(ac.main.intent.type, "donate_troops", "the main button sends troops to an ally")
		t.eq(ac.ally.id, "ally_break", "Ally becomes Break alliance")
	end)

	t.test("a ConquestEvent (flag and gold) reaches only the conqueror", function()
		local function viewer(small: number, id: string): any
			return { smallID = function() return small end, id = function() return id end }
		end
		local events = { { type = "ConquestEvent", conquerorId = "A", conqueredId = "B", gold = 5000 } }
		local mine = Replication.eventsFor(nil, events, viewer(1, "A"))
		t.eq(mine and #mine, 1, "the conqueror sees it")
		t.eq(Replication.eventsFor(nil, events, viewer(2, "C")), nil, "a third player doesn't")
		t.eq(Replication.eventsFor(nil, events, viewer(3, "B")), nil, "nor does the conquered")
		t.eq(Replication.eventsFor(nil, events, nil), nil, "nor a spectator")
	end)

	t.test("attackCard: a coast tap picks the boat, else land, else boat", function()
		local HudModel = t.require("OpenFront.HudModel")
		local players = {
			[1] = { smallID = 1, id = "me", displayName = "Me", type = "HUMAN", troops = 1000, tiles = 10, allies = {}, disconnected = false },
			[2] = { smallID = 2, id = "them", displayName = "Them", type = "NATION", troops = 500, tiles = 40, allies = {}, disconnected = false },
		}
		local state = {
			you = 1,
			players = players,
			me = function() return players[1] end,
			ownerAt = function(_, tile: number) return if tile == 0 then 0 else 2 end,
			inSpawnPhase = function() return false end,
		}
		local boatOk = { { type = "Transport", canBuild = 5 } }
		local function main(acts: { [string]: any }): string
			local c = HudModel.attackCard(state, 7, acts, 0.5) :: any
			return c.main.intent.type
		end
		t.eq(HudModel.attackCard(state, 0, {}, 0.5), nil, "unowned land: no card")
		t.eq(main({ isLand = true, canAttack = true, isOceanShore = true, buildableUnits = boatOk }), "boat", "bordering, but their coast: by boat")
		t.eq(main({ isLand = true, canAttack = true, isOceanShore = false, buildableUnits = boatOk }), "attack", "inland while bordering: by land")
		t.eq(main({ isLand = true, canAttack = false, isOceanShore = false, buildableUnits = boatOk }), "boat", "no border: by boat")
		t.eq(main({ isLand = true, canAttack = true, isOceanShore = true, buildableUnits = { { type = "Transport", canBuild = false } } }), "attack", "a coast with no boat route: by land")
		local c = HudModel.attackCard(state, 7, { isLand = true, canAttack = true }, 0.5) :: any
		t.eq(c.kind, "Nation", "a nation")
		t.eq(c.main.intent.troops, 500, "half your troops")
		t.ok(c.main.enabled, "attack enabled")
	end)

	t.test("wheel: the centre action on top, Focus and Emoji added, own land trimmed", function()
		local HudModel = t.require("OpenFront.HudModel")
		local state = {
			you = 1,
			players = { [2] = { displayName = "Them" } },
			inSpawnPhase = function() return false end,
		}
		local function ids(w: any): string
			local out = {}
			for _, it in w.items do
				table.insert(out, it.id)
			end
			return table.concat(out, ",")
		end
		local attack = { id = "center", label = "Attack", enabled = true, intent = { type = "attack" } }
		local other = HudModel.wheel(state, {
			tile = 7,
			selected = 2,
			center = attack,
			items = {
				{ id = "info", label = "Info", enabled = true, panel = "player" },
				{ id = "boat", label = "Boat", enabled = true, intent = { type = "boat" } },
				{ id = "ally_request", label = "Request", enabled = true },
				{ id = "attack", label = "Weapons", enabled = true, sub = {} },
			},
		} :: any)
		t.eq(ids(other), "center,boat,ally_request,attack,focus,emoji,info", "clockwise as mockup B")
		t.eq(other.title, "THEM", "the nation's name")
		t.ok(other.items[1].primary, "the action is the yellow tile")
		t.eq(other.items[1].glyph, "sword", "attack")
		local wild = HudModel.wheel(state, {
			tile = 7,
			selected = nil,
			center = attack,
			items = {
				{ id = "info", label = "Info", enabled = false, panel = "player" },
				{ id = "boat", label = "Boat", enabled = true },
				{ id = "ally_request", label = "Request", enabled = false },
				{ id = "attack", label = "Weapons", enabled = true, sub = {} },
			},
		} :: any)
		t.eq(ids(wild), "center,boat,attack,focus", "no Info, Ally or Emoji without a player")
		local function own(deleteEnabled: boolean): string
			return ids(HudModel.wheel(state, {
				tile = 7,
				selected = 1,
				center = attack,
				items = {
					{ id = "info", label = "Info", enabled = true, panel = "player" },
					{ id = "delete", label = "Delete", enabled = deleteEnabled },
					{ id = "ally_request", label = "Request", enabled = false },
					{ id = "build", label = "Build", enabled = true, sub = {} },
				},
			} :: any))
		end
		t.eq(own(false), "build,info,focus", "your land: Build, Info, Focus (Bruno)")
		t.eq(own(true), "build,info,focus,delete", "and Delete with a structure in reach")
	end)

	t.test("sendToasts: a new or grown attack is news, the first look is a baseline", function()
		local HudModel = t.require("OpenFront.HudModel")
		local state = { you = 1, players = { [2] = { displayName = "Them" } }, attacks = {} :: { any } }
		state.attacks = { { id = 1, attacker = 1, target = 0, troops = 5000, outgoing = true } }
		local news, seen = HudModel.sendToasts(state, nil)
		t.eq(#news, 0, "a snapshot's attacks aren't news")
		state.attacks = {
			{ id = 1, attacker = 1, target = 0, troops = 4000, outgoing = true },
			{ id = 2, attacker = 1, target = 2, troops = 12000, outgoing = true },
			{ id = 3, attacker = 2, target = 1, troops = 9000, outgoing = false },
		}
		news, seen = HudModel.sendToasts(state, seen)
		t.eq(#news, 1, "one new attack of yours")
		t.eq(news[1].text, "Attacking Them with 1.20K", "named, in shown troops")
		state.attacks[1].troops = 9000
		news, seen = HudModel.sendToasts(state, seen)
		t.eq(#news, 1, "a second send merged into the expansion")
		t.eq(news[1].text, "Expanding with 500", "the troops added")
		news = HudModel.sendToasts(state, seen)
		t.eq(#news, 0, "nothing new")
	end)

	t.test("warshipCard: your warship's health, veterancy and status", function()
		local HudModel = t.require("OpenFront.HudModel")
		local function ship(over: { [string]: any }): { [string]: any }
			local u: { [string]: any } = { id = 5, type = "Warship", owner = 1, active = true, health = 800, maxHealth = 1000, warship = { state = "patrolling", patrolTile = 42, veterancy = 1 } }
			for k, v in over do
				u[k] = v
			end
			return u
		end
		local function card(u: { [string]: any }): any
			return HudModel.warshipCard({ you = 1, units = { [5] = u } }, 5)
		end
		local c = card(ship({}))
		t.eq(c.health, 800, "health")
		t.eq(c.maxHealth, 1000, "max health")
		t.eq(c.veterancy, 1, "veterancy")
		t.eq(c.maxVeterancy, 3, "OpenFront's max veterancy")
		t.eq(c.status, "PATROLLING", "patrolling")
		t.eq(c.patrolTile, 42, "the confirmed patrol centre")
		t.eq(card(ship({ warship = { state = "patrolling", inCombat = true } })).status, "IN COMBAT", "fighting on patrol")
		t.eq(card(ship({ warship = { state = "retreating", inCombat = true } })).status, "RETREATING", "retreat wins over combat")
		t.eq(card(ship({ warship = { state = "docked" } })).status, "REPAIRING", "docked at a port")
		t.eq(card(ship({ owner = 2 })), nil, "not yours")
		t.eq(card(ship({ active = false })), nil, "sunk")
		t.eq(card(ship({ type = "Port" })), nil, "not a warship")
		t.eq(HudModel.warshipCard({ you = 1, units = {} }, 5), nil, "gone")
	end)
end
