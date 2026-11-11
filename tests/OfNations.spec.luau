-- OpenFront port, Phase D gate: whole matches with nations and tribes,
-- through the Runner. tests/fixtures/openfront/nation-matches.json was
-- recorded from OpenFront v0.35.2's own createGameRunner
-- (openfront-run/tests/conquest/NationMatchTrace): the game hash every tick,
-- and every 25 ticks each player's tiles, troops, gold and life, every unit,
-- every alliance, every attack and every name anchor (units every 500). The world-humans case
-- adds two scripted humans; their intents are replayed through
-- Runner.intent. Maps come from the reference clone; skipped when it is
-- absent.
return function(t)
	local GameMap = t.require("OpenFront.GameMap")
	local MapLoader = t.require("OpenFront.MapLoader")
	local Runner = t.require("OpenFront.Runner")

	local ROOT = "../reference/openfront-v0.35.2/resources/maps"

	local function fmt(x: number): string
		return string.format("%.17g", x)
	end

	-- The fixture's sample shape, from our game.
	local function sample(game: any): any
		local players, units, alliances, attacks = {}, {}, {}, {}
		for _, p in game:allPlayers() do
			table.insert(players, { p:id(), p:numTilesOwned(), p:troops(), p:gold(), if p:isAlive() then 1 else 0, p:team() })
			for _, a in p:alliances() do
				if a:requestor() == p then
					table.insert(alliances, `{p:id()}>{a:recipient():id()}@{a:expiresAt()}`)
				end
			end
			for _, a in p:outgoingAttacks() do
				local target = a:target()
				table.insert(attacks, `{p:id()}>{if target:isPlayer() then target:id() else "TN"}:{fmt(a:troops())}`)
			end
		end
		for _, u in game:units() do
			units[u:id()] = `{u:type()}/{u:owner():id()}/{u:tile()}/{u:level()}`
		end
		return { players = players, units = units, alliances = alliances, attacks = attacks }
	end

	-- Every difference between our state and the fixture sample, as text.
	local function diff(game: any, names: any, want: any): { string }
		local got = sample(game)
		local out = {}
		local byId = {}
		for _, p in got.players do
			byId[p[1]] = p
		end
		for _, w in want.players do
			local g = byId[w[1]]
			if g == nil then
				table.insert(out, `missing player {w[1]}`)
			elseif g[2] ~= w[2] or g[3] ~= tonumber(w[3]) or g[4] ~= tonumber(w[4]) or g[5] ~= w[5] then
				table.insert(out, `player {w[1]}: tiles {g[2]}/{w[2]} troops {fmt(g[3])}/{w[3]} gold {g[4]}/{w[4]} alive {g[5]}/{w[5]}`)
			elseif w[6] ~= nil and g[6] ~= w[6] then
				-- Team games: assignTeams (Bot for tribes).
				table.insert(out, `player {w[1]}: team {tostring(g[6])}/{w[6]}`)
			end
		end
		-- Doomsday Clock: fallout and each player's skull, timer and decay.
		if want.doomsday ~= nil then
			if game:numTilesWithFallout() ~= want.doomsday.fallout then
				table.insert(out, `fallout {game:numTilesWithFallout()} / {want.doomsday.fallout}`)
			end
			for _, w in want.doomsday.players do
				local ok, p = pcall(function()
					return game:player(w[1])
				end)
				if ok and p then
					local g = { if p:inDoomsdayClock() then 1 else 0, p:doomsdayClockTicks(), if p:isDecaying() then 1 else 0 }
					if g[1] ~= w[2] or g[2] ~= w[3] or g[3] ~= w[4] then
						table.insert(out, `doomsday {w[1]}: {g[1]},{g[2]},{g[3]} / {w[2]},{w[3]},{w[4]}`)
					end
				end
			end
		end
		if want.teams ~= nil then
			local gotTeams = table.concat(game:teams(), ",")
			local wantTeams = table.concat(want.teams, ",")
			if gotTeams ~= wantTeams then
				table.insert(out, `teams {gotTeams} / {wantTeams}`)
			end
		end
		-- Units are sampled less often (the hash covers them every tick).
		if want.units ~= nil then
			local wantUnits = {}
			for _, u in want.units do
				local key = `{u[2]}/{u[3]}/{u[4]}/{u[5]}`
				wantUnits[u[1]] = key
				if got.units[u[1]] ~= key then
					table.insert(out, `unit {u[1]}: got {got.units[u[1]] or "none"}, want {key}`)
				end
			end
			for id, key in got.units do
				if wantUnits[id] == nil then
					table.insert(out, `extra unit {id}: {key}`)
				end
			end
		end
		local function setDiff(label: string, g: { string }, w: { string })
			local ws, gs = {}, {}
			for _, x in w do
				ws[x] = true
			end
			for _, x in g do
				gs[x] = true
				if not ws[x] then
					table.insert(out, `extra {label} {x}`)
				end
			end
			for _, x in w do
				if not gs[x] then
					table.insert(out, `missing {label} {x}`)
				end
			end
		end
		local wantAlliances, wantAttacks = {}, {}
		for _, a in want.alliances do
			table.insert(wantAlliances, `{a[1]}>{a[2]}@{a[3]}`)
		end
		for _, a in want.attacks do
			table.insert(wantAttacks, `{a[1]}>{a[2] or "TN"}:{fmt(tonumber(a[3]) :: number)}`)
		end
		setDiff("alliance", got.alliances, wantAlliances)
		setDiff("attack", got.attacks, wantAttacks)
		-- Name anchors (NameBoxCalculator on GameRunner's schedule).
		local gotNames, wantNames = {}, {}
		for id, a in names.anchors do
			table.insert(gotNames, `{id}@{a.x},{a.y},{fmt(a.size)}`)
		end
		for _, n in want.names or {} do
			table.insert(wantNames, `{n[1]}@{n[2]},{n[3]},{fmt(tonumber(n[4]) :: number)}`)
		end
		if want.names then
			setDiff("name", gotNames, wantNames)
		end
		return out
	end

	local path = "tests/fixtures/openfront/nation-matches.json"
	if not t.isFile(path) then
		return
	end
	for _, case in t.json(t.readFile(path)) do
		t.test(`{case.name}: {#case.nations} nations, {case.bots} tribes, {case.ticks} ticks`, function()
			local dir = `{ROOT}/{case.map}`
			if not t.isFile(dir .. "/map.bin") then
				print(`  (skipped {case.name}: reference maps not available)`)
				return
			end
			local manifest = t.json(t.readFile(dir .. "/manifest.json"))
			local mapData = MapLoader.fromManifest(manifest, case.size, function(key: string): any
				local m = manifest[key]
				return GameMap.new(m.width, m.height, buffer.fromstring(t.readFile(`{dir}/{key}.bin`)), m.num_land_tiles)
			end)
			local gameConfig = {
				gameMap = case.gameMap,
				gameMapSize = case.size,
				gameMode = "Free For All",
				gameType = case.gameType,
				difficulty = case.difficulty,
				bots = case.bots,
				nations = "default",
			}
			for k, v in case.extra or {} do
				gameConfig[k] = v
			end
			local runner = Runner.new({ gameID = case.gameID, mapFolder = nil, mapData = mapData, gameConfig = gameConfig })
			for _, h in case.humans do
				runner:addHuman(h.clientID, h.username)
			end
			runner:start()
			local game = runner.game
			local names = {}
			for _, n in game:nations() do
				table.insert(names, n.playerInfo.name)
			end
			t.eq(table.concat(names, ","), table.concat(case.nations, ","), "nations chosen")

			local samples = {}
			for _, s in case.samples do
				samples[s.tick] = s
			end
			local firstBad: number? = nil
			local wonAt: number? = nil
			for tick = 0, case.ticks - 1 do
				-- The scripted humans' intents, as OpenFront received them.
				for _, intent in (case.intents :: any)[tostring(tick)] or {} do
					if intent.type == "mark_disconnected" then
						runner:markDisconnected(intent.clientID, intent.isDisconnected)
					else
						local q = table.clone(intent)
						q.clientID = nil
						local ok, why = runner:intent(intent.clientID, q)
						t.ok(ok, `tick {tick} {intent.type} intent accepted ({why})`)
					end
				end
				runner:step()
				if firstBad == nil and game:hash() ~= tonumber(case.hashes[tick + 1]) then
					firstBad = tick
				end
				if wonAt == nil and game:getWinner() ~= nil then
					wonAt = tick
				end
				local want = samples[tick]
				if want then
					local d = diff(game, runner.names, want)
					if firstBad ~= nil or #d > 0 then
						local shown = table.move(d, 1, math.min(#d, 25), 1, {})
						error(
							`hash first differs at tick {firstBad or "-"}; sample tick {tick} has {#d} differences:\n    `
								.. table.concat(shown, "\n    ")
						)
					end
				end
			end
			-- WinCheckExecution: the same winner on the same tick (win cases).
			if case.winner then
				local winner = game:getWinner()
				t.eq(wonAt, case.winner[1], "won on the same tick")
				t.eq(if winner and winner.id then winner:id() else tostring(winner), case.winner[2], "the same winner")
			end
		end)
	end
end
