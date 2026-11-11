-- 2026-10-24 menus: the map picker's catalog and the solo difficulty text.
return function(t)
	local MapCatalog = t.require("MapCatalog")
	local MenuModel = t.require("MenuModel")
	local Config = t.require("OpenFront.Config")

	t.test("every imported map is in All, with its OpenFront name and size", function()
		local all = MapCatalog.all()
		t.ok(#all >= 3, "World, Black Sea and Europe Classic at least")
		local world = MapCatalog.get("World") :: any
		t.eq(world.name, "World")
		t.eq(world.type, "World")
		t.eq(MapCatalog.sizeText(world), "2000 × 1000")
		t.eq((MapCatalog.get("BlackSea") :: any).type, "Black Sea", "the GameMapType value, not the folder")
		t.eq(MapCatalog.get("Nowhere"), nil)
	end)

	t.test("tabs follow OpenFront's categories; a map can sit in several", function()
		local europe = MapCatalog.inTab("europe")
		local asia = MapCatalog.inTab("asia")
		local function has(list: { any }, folder: string): boolean
			for _, e in list do
				if e.folder == folder then
					return true
				end
			end
			return false
		end
		t.ok(has(europe, "BlackSea") and has(asia, "BlackSea"), "Black Sea is in Europe and Asia")
		t.ok(has(MapCatalog.inTab("world"), "EuropeClassic"), "continental maps sit under World")
		t.eq(MapCatalog.inTab("featured")[1].folder, "World", "World is featured rank 1")
		for _, tab in MapCatalog.tabs() do
			t.ok(#MapCatalog.inTab(tab.id) > 0, tab.id .. " has maps")
		end
	end)

	t.test("difficulty text uses OpenFront's strings and Config's multipliers", function()
		t.eq(MenuModel.difficultyName("Impossible"), "Impossible")
		local easy = MenuModel.difficultyText("Easy")
		t.ok(string.find(easy, "Dumb, 50% of a human's max troops", 1, true) ~= nil, easy)
		t.ok(string.find(MenuModel.difficultyText("Hard"), "the same max troops as a human", 1, true) ~= nil)
		-- The multipliers the text quotes are Config's own.
		local function nation(troops: number): any
			return {
				type = function()
					return "NATION"
				end,
				numTilesOwned = function()
					return 1000
				end,
				troops = function()
					return troops
				end,
				units = function()
					return {}
				end,
			}
		end
		local human = Config.new({ difficulty = "Hard" } :: any, false)
		local base = human:maxTroops(nation(0))
		for _, d in MenuModel.DIFFICULTIES do
			local c = Config.new({ difficulty = d } :: any, false)
			t.near(c:maxTroops(nation(0)), base * MenuModel.NATION_TROOPS[d], 1e-6, d .. " max troops")
		end
	end)

	local MapPlaylist = t.require("OpenFront.MapPlaylist")
	local Lobbies = t.require("Lobbies")
	local AVAILABLE = { World = { landTiles = 651569 }, ["Black Sea"] = { landTiles = 1165868 }, ["Europe Classic"] = { landTiles = 1008469 } }
	local function playlist(rolls: { number }?): any
		local i = 0
		return MapPlaylist.new(AVAILABLE, function()
			i += 1
			return if rolls then rolls[(i - 1) % #rolls + 1] else 0.5
		end, function()
			return 12345
		end)
	end

	t.test("MapPlaylist: lobby sizes from land tiles, as calculateMapPlayerCounts", function()
		local l, m, s = MapPlaylist.calculateMapPlayerCounts(651569)
		t.eq(l, 35)
		t.eq(m, 25)
		t.eq(s, 20)
		t.eq(select(1, MapPlaylist.calculateMapPlayerCounts(10)), 5, "never below 5")
		t.eq(MapPlaylist.adjustForTeams(35, "Quads"), 32)
		t.eq(MapPlaylist.adjustForTeams(35, "Humans Vs Nations"), 17)
		t.eq(MapPlaylist.adjustForTeams(35, 3), 33)
	end)

	t.test("MapPlaylist: weighted playlists with no map within 5 games, every 3rd compact", function()
		local p = playlist()
		local seen = {}
		local compact = 0
		for _ = 1, 12 do
			local cfg = p:gameConfig("ffa")
			t.ok(AVAILABLE[cfg.gameMap] ~= nil, "only imported maps")
			seen[cfg.gameMap] = true
			t.eq(cfg.gameMode, "Free For All")
			t.eq(cfg.difficulty, "Medium")
			t.eq(cfg.nations, "default")
			t.eq(cfg.overtime.enabled, true)
			if cfg.gameMapSize == "Compact" then
				compact += 1
				t.eq(cfg.bots, 100)
			else
				t.eq(cfg.bots, 400)
			end
		end
		t.ok(seen.World and seen["Black Sea"], "World and Black Sea both come up")
		t.ok(compact > 0, "some games are compact")
		-- Conquest's public lobbies turn compact games off (Bruno, 2026-11-03)
		local full = MapPlaylist.new(AVAILABLE, function()
			return 0.5
		end, function()
			return 12345
		end, { compact = false })
		for _ = 1, 12 do
			local cfg = full:gameConfig("ffa")
			t.eq(cfg.gameMapSize, "Normal", "never compact")
			t.eq(cfg.bots, 400)
			t.ok(cfg.maxPlayers >= 5, "full lobby sizes")
		end
		local team = playlist({ 0.95 }):gameConfig("team")
		t.eq(team.gameMode, "Team")
		t.eq(team.playerTeams, "Humans Vs Nations", "roll 0.95 lands on HvN (weight 20 of 100)")
		t.eq(team.difficulty, "Hard")
		t.eq(team.nations, "default")
		local duo = playlist({ 0.62 }):gameConfig("team")
		t.eq(duo.playerTeams, "Duos")
		t.eq(duo.nations, "disabled", "team games other than HvN have no nations")
		t.eq(duo.donateTroops, true)
		local world = playlist():gameConfig("ffa", "World")
		t.eq(world.gameMap, "World")
		t.eq(world.gameMapSize, "Normal")
	end)

	t.test("Lobbies: countdown from the first join, parties move together, one live game per queue", function()
		local clock = 100
		local lobbies = Lobbies.new(playlist(), function()
			return clock
		end, true)
		local rows = lobbies:rows()
		t.eq(#rows, 3)
		t.eq(rows[1].title, "Public match")
		t.eq(rows[2].title, "World")
		t.eq(rows[1].seconds, nil, "no countdown before anyone joins")
		t.ok(lobbies:join("world", { "a", "b" }), "a party of two")
		t.eq(lobbies:rows()[2].players, 2)
		t.eq(lobbies:rows()[2].seconds, Lobbies.COUNTDOWN)
		t.ok(lobbies:join("ffa", { "b" }))
		t.eq(lobbies:rows()[2].players, 1, "joining another queue leaves the first")
		lobbies:leave("a")
		t.eq(lobbies:rows()[2].seconds, nil, "an empty lobby stops its countdown")
		clock += Lobbies.COUNTDOWN
		local due = lobbies:due()
		t.eq(#due, 1)
		t.eq(due[1].queue.id, "ffa")
		t.eq(due[1].members[1], "b")
		t.eq(lobbies:rows()[1].live, true)
		t.eq(lobbies:join("ffa", { "c" }), false, "a live queue offers Watch, not Join")
		lobbies:ended("ffa")
		t.ok(lobbies:join("ffa", { "c" }))
	end)

	t.test("Parties: invites expire, accepting joins, a party of one dissolves", function()
		local Parties = t.require("Parties")
		local clock = 0
		local p = Parties.new(function()
			return clock
		end)
		t.eq(#p:members("a"), 1)
		t.ok(p:invite("a", "b"))
		t.eq(p:invite("a", "a"), false, "not yourself")
		t.eq(p:pending("b")[1], "a")
		t.ok(p:accept("b", "a"))
		t.eq(#p:members("a"), 2)
		t.eq(p:members("b"), p:members("a"), "one shared party")
		t.eq(p:invite("b", "a"), false, "already together")
		p:invite("a", "c")
		clock += Parties.INVITE_SECONDS + 1
		t.eq(p:accept("c", "a"), false, "expired")
		p:leave("b")
		t.eq(#p:members("a"), 1, "a party of one is no party")
		p:invite("c", "a")
		p:remove("c")
		t.eq(#p:pending("a"), 0, "a player who leaves takes their invites")
	end)

	t.test("How to Play quotes the rules' own numbers", function()
		local HelpModel = t.require("HelpModel")
		local EngineConfig = t.require("OpenFront.EngineConfig")
		local config = EngineConfig.new({ difficulty = "Medium", gameType = "Public" } :: any, false)
		local cards = HelpModel.cards(config)
		t.eq(#cards, 7)
		local all = ""
		for _, c in cards do
			all ..= c.title .. " " .. c.text .. "\n"
		end
		t.ok(string.find(all, "Win at 80%", 1, true) ~= nil, "win share")
		t.ok(string.find(all, "lasts 5 minutes", 1, true) ~= nil, "alliance length")
		t.ok(string.find(all, "traitor for 30 seconds, with 50% less defense", 1, true) ~= nil, "traitor")
		t.ok(string.find(all, "a 30-tile blast", 1, true) ~= nil, "atom outer radius")
		t.ok(string.find(all, "within 70 tiles", 1, true) ~= nil, "SAM level 1 range")
		t.ok(string.find(all, "15 tiles between", 1, true) ~= nil, "structure spacing")
		t.ok(string.find(all, "20 seconds to choose", 1, true) ~= nil, "public spawn phase")
		local b = HelpModel.buildings(config)
		t.eq(b[1].text, "Raises your troop limit by 25.0K.")
		t.eq(b[4].text, "Attacks on your land within 30 tiles cost 5x the troops and take 3x as long.")
		t.ok(#HelpModel.controls().mouse + #HelpModel.controls().keys >= 6)
	end)

	t.test("build slot tooltips: OpenFront's description and why a slot is dim", function()
		local HudModel = t.require("OpenFront.HudModel")
		local state = {
			you = 1,
			gold = 100,
			costs = { City = 125000, ["Atom Bomb"] = 750000, Warship = 250000, MIRV = 25000000 },
			units = {},
			players = { [1] = { alive = true } },
			me = function(self: any)
				return self.players[1]
			end,
			config = function()
				return {
					isUnitDisabled = function(_, unit: string)
						return unit == "MIRV"
					end,
				}
			end,
		}
		local byType = {}
		for _, item in HudModel.buildItems(state) do
			byType[item.type] = item
		end
		local city = HudModel.slotInfo(state, byType.City)
		t.eq(city.desc, "Increases max population")
		t.eq(city.reason, "Not enough money")
		t.eq(HudModel.slotInfo(state, byType["Atom Bomb"]).reason, "Needs a Missile Silo")
		t.eq(HudModel.slotInfo(state, byType.Warship).reason, "Needs a Port")
		t.eq(HudModel.slotInfo(state, byType.MIRV).reason, "Disabled in this match")
		state.gold = 1e9
		t.eq(HudModel.slotInfo(state, HudModel.buildItems(state)[1]).reason, nil, "affordable: no red line")
	end)

	t.test("public match rows read like the menu shows them", function()
		local line = MenuModel.lobbyLine({ mapName = "Black Sea", players = 41, capacity = 50, seconds = 44 }, true)
		t.eq(line, "Next: Black Sea  •  41 / 50 players  •  starts in 0:44")
		t.eq(MenuModel.lobbyLine({ players = 6, capacity = 28, seconds = 55, mode = "Quads" }, false), "Quads  •  6 / 28 players  •  starts in 0:55")
	end)
	t.test("Parties.form: arrivals from one teleport become one party again", function()
		local Parties = t.require("Parties")
		local p = Parties.new(function()
			return 0
		end)
		p:form({ "1" })
		t.eq(#p:members("1"), 1, "one alone is no party")
		p:form({ "1", "2", "2" })
		t.eq(table.concat(p:members("2"), ","), "1,2")
		-- a third arrives later: the whole group again
		p:form({ "1", "2", "3" })
		t.eq(table.concat(p:members("3"), ","), "1,2,3")
		t.eq(p:members("1"), p:members("3"), "one shared party")
		-- forming takes a player out of another party
		p:form({ "3", "4" })
		t.eq(table.concat(p:members("1"), ","), "1,2")
		t.eq(table.concat(p:members("4"), ","), "3,4")
		local many = {}
		for i = 1, Parties.MAX_SIZE + 3 do
			table.insert(many, tostring(100 + i))
		end
		p:form(many)
		t.eq(#p:members("101"), Parties.MAX_SIZE)
	end)
end
