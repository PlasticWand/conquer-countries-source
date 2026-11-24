-- The Campaign Pass's gold conquest (2026-11-24): when a human wearing it
-- beats a player, every viewer gets a public ConquestCosmeticEvent at the
-- beaten player's name, with no gold; the gold ConquestEvent stays private.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local HumanProtection = t.require("OpenFront.HumanProtection")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function landNear(map: any, x: number, y: number): number
		for r = 0, 40 do
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

	-- Ada (wearing `fx`) and Bob, past the spawn phase; Bob surrenders to Ada.
	local function play(fx: string?): ({ any }, any)
		local runner = Runner.new({
			gameID = "conquest-cosmetic-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Private",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
			},
		})
		runner:addHuman("1001", "Ada", nil, { conquestFx = fx })
		runner:addHuman("1002", "Bob", nil, {})
		runner:start()
		local game = runner.game
		runner:intent("1001", { type = "spawn", tile = landNear(game:map(), 520, 140) })
		runner:intent("1002", { type = "spawn", tile = landNear(game:map(), math.floor(game:map():width() * 0.72), math.floor(game:map():height() * 0.3)) })
		for _ = 1, 4000 do
			if not game:inSpawnPhase() then
				break
			end
			runner:step()
		end
		for _ = 1, 20 do
			runner:step()
		end
		local ada, bob = game:playerByClientID("1001"), game:playerByClientID("1002")
		local seen = {}
		HumanProtection.surrender(game, bob, ada)
		for _, u in game.updates do
			table.insert(seen, u)
		end
		for _ = 1, 3 do
			runner:step()
			for _, u in game.updates do
				table.insert(seen, u)
			end
		end
		t.eq(bob:isAlive(), false, "Bob is out")
		return seen, game
	end

	local function find(list: { any }, kind: string): any
		for _, u in list do
			if u.type == kind then
				return u
			end
		end
		return nil
	end

	t.test("a gold conquest sends every viewer a public mark without gold", function()
		local seen, game = play("x_conquest_gold")
		local private = find(seen, "ConquestEvent")
		t.ok(private ~= nil, "the conquest happened")
		local e = find(seen, "ConquestCosmeticEvent")
		t.ok(e ~= nil, "a public mark")
		t.eq(e.conquestFx, "x_conquest_gold")
		t.eq(e.conquerorId, private.conquerorId)
		t.eq(e.conqueredId, private.conqueredId)
		t.ok(type(e.x) == "number" and type(e.y) == "number", "at Bob's name")
		t.ok(type(e.tick) == "number" and e.tickAge == 0, "stamped")
		t.eq(e.gold, nil, "no gold")
		-- A spectator (no viewer) and another player both get it; the gold event only the winner.
		local shown = Replication.eventsFor(game, { private, e }, nil)
		t.eq(#(shown or {}), 1, "spectator: the mark only")
		t.eq((shown :: any)[1].type, "ConquestCosmeticEvent")
	end)

	t.test("no mark without the gold conquest equipped", function()
		local seen = play(nil)
		t.ok(find(seen, "ConquestEvent") ~= nil, "the conquest happened")
		t.eq(find(seen, "ConquestCosmeticEvent"), nil)
	end)
end
