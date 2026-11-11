-- Conquest's boatFullRefund (Bruno, 2026-11-05): when two boats sail for one
-- landing and the first takes it, the second brings all its troops home. A boat
-- turned back still pays OpenFront's malus, and without the flag OpenFront's
-- rule holds: any boat reaching its own shore loses 25 %.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local BoatRetreatExecution = t.require("OpenFront.Executions.BoatRetreatExecution")
	local TransportShipExecution = t.require("OpenFront.Executions.TransportShipExecution")
	local TransportShipUtils = t.require("OpenFront.TransportShipUtils")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local SECOND = 10000

	-- A human on one coast and a free shore tile its boats can reach.
	local function setup(boatFullRefund: boolean?): any
		local runner = Runner.new({
			gameID = "boats",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Singleplayer",
				difficulty = "Easy",
				bots = 0,
				nations = "disabled",
				boatFullRefund = boatFullRefund,
			},
		})
		runner:addHuman("1001", "Bruno")
		runner:start()
		local game = runner.game
		local map = game:map()
		for _ = 1, 5 do
			runner:step()
		end
		local spawned = false
		for tile = 0, map:width() * map:height() - 1, 41 do
			if map:isLand(tile) and game:isShore(tile) and not game:hasOwner(tile) then
				runner:intent("1001", { type = "spawn", tile = tile })
				spawned = true
				break
			end
		end
		t.ok(spawned, "found a coast to spawn on")
		for _ = 1, 10 do
			runner:step()
		end
		local human = game:playerByClientID("1001")
		local landing
		for tile = map:width() * map:height() - 1, 0, -37 do
			if map:isLand(tile) and game:isShore(tile) and not game:hasOwner(tile) and game:manhattanDist(tile, human:spawnTile()) > 30 then
				if TransportShipUtils.canBuildTransportShip(game, human, tile) ~= false then
					landing = tile
					break
				end
			end
		end
		t.ok(landing ~= nil, "found a shore to land on")
		human:setTroops(100000)
		return { runner = runner, game = game, human = human, landing = landing }
	end

	-- What the second boat brings home, seen by a spy on addTroops that ignores
	-- the small amounts of normal troop growth.
	local function secondBoatHome(m: any, launch: (boat: any) -> ()): (number, { any })
		local game, human = m.game, m.human
		game:addExecution(TransportShipExecution.new(human, m.landing, 5000))
		for _ = 1, 3 do
			m.runner:step()
		end
		game:addExecution(TransportShipExecution.new(human, m.landing, SECOND))
		m.runner:step()
		local boats = human:units("Transport")
		t.eq(#boats, 2, "both boats at sea")
		local second = boats[2]
		t.eq(second:troops(), SECOND, "the second boat carries its troops")
		launch(second)
		local returned = 0
		local addTroops = human.addTroops
		human.addTroops = function(self: any, n: number)
			if n >= 1000 then
				returned += n
			end
			return addTroops(self, n)
		end
		local messages = {}
		for _ = 1, 3000 do
			m.runner:step()
			for _, message in game:drainMessages() do
				table.insert(messages, message)
			end
			if not second:isActive() then
				break
			end
		end
		human.addTroops = addTroops
		t.ok(not second:isActive(), "the second boat arrived")
		return returned, messages
	end

	local function hasKey(messages: { any }, key: string): boolean
		for _, message in messages do
			if message.key == key then
				return true
			end
		end
		return false
	end

	t.test("with the flag, the second boat brings all its troops home", function()
		local m = setup(true)
		local returned, messages = secondBoatHome(m, function() end)
		t.ok(m.game:owner(m.landing) == m.human, "the first boat took the shore")
		t.eq(returned, SECOND, "every troop comes back")
		t.ok(hasKey(messages, "events_display.boat_returned_troops"), "the player is told")
		t.ok(not hasKey(messages, "events_display.attack_cancelled_retreat"), "and no one is reported killed")
		for _, message in messages do
			if message.key == "events_display.boat_returned_troops" then
				t.eq(message.params.tile, m.landing, "the message says where it came home")
			end
		end
	end)

	t.test("a boat that lands is marked as having reached its target", function()
		local m = setup(true)
		local game, human = m.game, m.human
		game:addExecution(TransportShipExecution.new(human, m.landing, 5000))
		m.runner:step()
		local first = human:units("Transport")[1]
		for _ = 1, 3000 do
			m.runner:step()
			if not first:isActive() then
				break
			end
		end
		t.ok(not first:isActive() and first:reachedTarget(), "the landing boat reached its target")
	end)

	t.test("without the flag, OpenFront's rule: 25 % die", function()
		local m = setup(nil)
		local returned, messages = secondBoatHome(m, function() end)
		t.eq(returned, SECOND * 0.75, "75 % come back")
		t.ok(hasKey(messages, "events_display.attack_cancelled_retreat"), "and the player is told of the deaths")
		t.ok(not hasKey(messages, "events_display.boat_returned_troops"), "with no refund message")
	end)

	t.test("with the flag, a boat turned back still pays the malus", function()
		local m = setup(true)
		local returned, messages = secondBoatHome(m, function(boat)
			m.game:addExecution(BoatRetreatExecution.new(m.human, boat:id()))
		end)
		t.eq(returned, SECOND * 0.75, "75 % come back from a retreat")
		t.ok(hasKey(messages, "events_display.attack_cancelled_retreat"), "as a retreat")
		t.ok(not hasKey(messages, "events_display.boat_returned_troops"), "not as a refund")
	end)
end
