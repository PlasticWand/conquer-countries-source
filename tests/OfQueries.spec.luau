-- The build preview's alliance warning (2026-11 audit F7): Runner.buildPreview
-- now reads it off one walk of the blast (listNukeBreakAlliance) instead of
-- walking it a second time (wouldNukeBreakAlliance). Both must agree.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local NukeExecution = t.require("OpenFront.Executions.NukeExecution")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	t.test("the preview's alliance warning matches wouldNukeBreakAlliance", function()
		local runner = Runner.new({
			gameID = "queries-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 20,
				nations = "disabled",
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
		runner:intent("1002", { type = "spawn", tile = landNear(560, 150) })
		for _ = 1, 4000 do
			if not game:inSpawnPhase() then
				break
			end
			runner:step()
		end
		local a, b = game:playerByClientID("1001"), game:playerByClientID("1002")
		for _ = 1, 150 do
			runner:step()
		end
		-- Allies: each asks the other.
		runner:intent("1001", { type = "allianceRequest", recipient = b:id() })
		runner:step()
		runner:intent("1002", { type = "allianceRequest", recipient = a:id() })
		for _ = 1, 5 do
			runner:step()
		end
		t.ok(a:isAlliedWith(b), "allied")
		b:buildUnit("City", b:tiles():values()[1], {})
		local config = game:config()
		local warned, clear = 0, 0
		local bx, by = map:x(b:tiles():values()[1]), map:y(b:tiles():values()[1])
		for _, unit in { "Atom Bomb", "Hydrogen Bomb" } do
			local magnitude = config:nukeMagnitudes(unit)
			for i = 0, 119 do
				local x = math.clamp(bx + (i % 12 - 6) * 22, 0, map:width() - 1)
				local y = math.clamp(by + (i // 12 - 5) * 22, 0, map:height() - 1)
				local tile = map:ref(x, y)
				local preview = runner:buildPreview("1001", tile, unit) :: any
				local expected = not map:isImpassable(tile) and NukeExecution.wouldNukeBreakAlliance(game, tile, magnitude, { [b:smallID()] = true }, config:nukeAllianceBreakThreshold())
				t.eq(preview.rangeWarning, expected, `{unit} at {x},{y}`)
				if expected then
					warned += 1
				else
					clear += 1
				end
			end
		end
		t.ok(warned > 5 and clear > 5, `both answers seen ({warned} warned, {clear} clear)`)
		-- A disconnected ally doesn't warn, as before.
		runner:markDisconnected("1002", true)
		runner:step()
		local preview = runner:buildPreview("1001", b:tiles():values()[1], "Hydrogen Bomb") :: any
		t.eq(preview.rangeWarning, false, "no warning for a disconnected ally")
	end)
end
