-- Replication's wire format (2026-11 audit: packed stats, unit patches, packed
-- plan paths, changed name anchors, private parts only on change). Whatever
-- the format, a client that followed every delta must hold what a client
-- that just took a snapshot holds.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local ClientState = t.require("OpenFront.ClientState")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function same(a: any, b: any, path: string): string?
		if type(a) ~= type(b) then
			return `{path}: {tostring(a)} vs {tostring(b)}`
		end
		if type(a) ~= "table" then
			return if a == b then nil else `{path}: {tostring(a)} vs {tostring(b)}`
		end
		for k, v in a do
			local why = same(v, b[k], `{path}.{tostring(k)}`)
			if why then
				return why
			end
		end
		for k in b do
			if a[k] == nil then
				return `{path}.{tostring(k)}: nil vs {tostring(b[k])}`
			end
		end
		return nil
	end

	t.test("a packed path unpacks to the same tiles", function()
		for _, path in { {}, { 0 }, { 1999999 }, { 5, 6, 7, 2007, 2006, 6, 5, 1999999, 0, 4000 } } do
			local back = Replication.unpackPath(Replication.packPath(path))
			t.eq(#back, #path, "length")
			for i, tile in path do
				t.eq(back[i], tile, `tile {i}`)
			end
		end
		-- neighbour steps take a byte or two each
		local long = {}
		for i = 1, 500 do
			long[i] = 400000 + (if i % 2 == 0 then i else i + 2000)
		end
		t.ok(buffer.len(Replication.packPath(long)) < 500 * 3, "packed size")
	end)

	t.test("a client following deltas matches a fresh snapshot, through a match with units", function()
		local runner = Runner.new({
			gameID = "wire-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Hard",
				bots = 40,
				nations = "default",
				extraWeapons = true,
				donateGold = true,
				donateTroops = true,
			},
		})
		runner:addHuman("1001", "A")
		runner:addHuman("1002", "B")
		runner:start()
		local game = runner.game
		local map = game:map()
		local function landNear(x: number, y: number): number
			for r = 0, 60 do
				for dy = -r, r do
					for dx = -r, r do
						local tile = map:ref(x + dx, y + dy)
						if map:isLand(tile) and not map:isImpassable(tile) and not map:hasOwner(tile) then
							return tile
						end
					end
				end
			end
			error("no land")
		end
		runner:intent("1001", { type = "spawn", tile = landNear(520, 140) })
		runner:intent("1002", { type = "spawn", tile = landNear(300, 200) })
		local rep = Replication.newReplicator(runner)
		local client = ClientState.new()
		client:applySnapshot(rep:snapshot("1001"))
		local a, b = game:playerByClientID("1001"), game:playerByClientID("1002")
		local patches, fulls, checked, privateSends = 0, 0, 0, 0
		for tick = 1, 1800 do
			-- Some private state that changes: an alliance request and a build.
			if tick == 320 then
				runner:intent("1001", { type = "allianceRequest", recipient = b:id() })
			elseif tick == 340 then
				a:addGold(5_000_000)
				runner:intent("1001", { type = "build_action", unit = "City", tile = a:tiles():values()[1] })
			end
			runner:step()
			local public = rep:collect()
			local delta = rep:forViewer(public, "1001", game:drainMessages())
			for _, u in delta.units do
				if u.type ~= nil then
					fulls += 1
				else
					patches += 1
				end
			end
			if delta.costs or delta.diplomacy or delta.arsenal then
				privateSends += 1
			end
			client:applyDelta(delta)
			-- The viewer's own numbers are current every tick.
			local me = client:me() :: any
			t.eq(me.troops, a:troops(), `tick {tick}: own troops`)
			t.eq(me.tiles, a:numTilesOwned(), `tick {tick}: own tiles`)
			-- On a tick when everyone's stats went out, compare with a snapshot.
			if (tick - 1) % Replication.STATS_EVERY == 0 and (tick % 25 == 1 or tick < 40) then
				local fresh = ClientState.new()
				fresh:applySnapshot(Replication.newReplicator(runner):snapshot("1001"))
				checked += 1
				for id, p in fresh.players do
					local why = same(client.players[id], p, `tick {tick} player {id}`)
					t.ok(why == nil, why)
				end
				local count = 0
				for id, u in client.units do
					count += 1
					local other = fresh.units[id]
					t.ok(other ~= nil, `tick {tick}: unit {id} ({u.type}) is gone on the server`)
					local mine = table.clone(u)
					local theirs = table.clone(other)
					-- The fresh replicator has not seen when a construction began.
					mine.constructionStartTick, theirs.constructionStartTick = nil, nil
					local why = same(mine, theirs, `tick {tick} unit {id} ({u.type})`)
					t.ok(why == nil, why)
				end
				local freshCount = 0
				for _ in fresh.units do
					freshCount += 1
				end
				t.eq(count, freshCount, `tick {tick}: unit count`)
				t.ok(same(client.names, fresh.names, `tick {tick} names`) == nil, same(client.names, fresh.names, `tick {tick} names`))
				t.ok(same(client.costs, fresh.costs, `tick {tick} costs`) == nil, same(client.costs, fresh.costs, `tick {tick} costs`))
				t.ok(same(client.diplomacy, fresh.diplomacy, `tick {tick} diplomacy`) == nil, same(client.diplomacy, fresh.diplomacy, `tick {tick} diplomacy`))
				t.ok(same(client.arsenal, fresh.arsenal, `tick {tick} arsenal`) == nil, same(client.arsenal, fresh.arsenal, `tick {tick} arsenal`))
				t.eq(client.gold, a:gold(), `tick {tick}: gold`)
			end
		end
		t.ok(checked > 60, `compared with snapshots ({checked})`)
		t.ok(patches > 50, `units were patched ({patches} patches, {fulls} full records)`)
		t.ok(privateSends > 2 and privateSends < 600, `private parts go only when they change ({privateSends} of 1800 ticks)`)
	end)
end
