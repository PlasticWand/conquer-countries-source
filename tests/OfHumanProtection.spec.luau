-- RoWorld's human protection on OpenFront's nation AI (HumanProtection.luau),
-- on a real compact World with real nations. Ages are set by moving the game's
-- start tick. That every part is off in OpenFront's own rules is checked by
-- OfNations: its traces run with no flags and match tick by tick.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local HumanProtection = t.require("OpenFront.HumanProtection")
	local AiAttackBehavior = t.require("OpenFront.Executions.AiAttackBehavior")
	local NationMIRVBehavior = t.require("OpenFront.Executions.Nation.NationMIRVBehavior")
	local PseudoRandom = t.require("OpenFront.PseudoRandom")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function start(difficulty: string, flags: { string }?): any
		local gameConfig: { [string]: any } = {
			gameMap = "World",
			gameMapSize = "Compact",
			gameMode = "Free For All",
			gameType = "Singleplayer",
			difficulty = difficulty,
			bots = 0,
			nations = "default",
		}
		for _, flag in flags or {} do
			gameConfig[flag] = true
		end
		local runner = Runner.new({ gameID = `protect{difficulty}`, mapFolder = Maps.World, gameConfig = gameConfig })
		runner:addHuman("1001", "Bruno")
		runner:start()
		local game = runner.game
		for _ = 1, 20 do
			runner:step()
		end
		local map = game:map()
		for tile = 0, map:width() * map:height() - 1, 97 do
			if map:isLand(tile) and not game:hasOwner(tile) then
				runner:intent("1001", { type = "spawn", tile = tile })
				break
			end
		end
		for _ = 1, 30 do
			runner:step()
		end
		return {
			runner = runner,
			game = game,
			human = game:playerByClientID("1001"),
			nation = (function()
				for _, p in game:players() do
					if p:type() == "NATION" and p:isAlive() then
						return p
					end
				end
				error("no nation alive")
			end)(),
		}
	end

	local function setAge(game: any, age: number)
		game.startTick = game:ticks() - age
	end

	local function behavior(m: any): any
		return AiAttackBehavior.new(PseudoRandom.new(1), m.game, m.nation, 0.5, 0.3, 0.1)
	end

	-- Every nation but `first` up to `n`, each with a pending order on the human.
	local function fillWars(m: any, n: number)
		local count = 0
		for _, p in m.game:players() do
			if count >= n then
				break
			end
			if p:type() == "NATION" and p:isAlive() and p ~= m.nation then
				HumanProtection.noteWar(m.game, p, m.human)
				count += 1
			end
		end
		t.eq(count, n, "enough nations for the test")
	end

	t.test("enable turns on all four parts, but not in Humans vs Nations", function()
		local config: { [string]: any } = {}
		HumanProtection.enable(config)
		t.ok(config.humanGrace and config.humanWarLimit and config.humanSkip and config.capitulation, "all on")
		local hvn: { [string]: any } = { playerTeams = "Humans Vs Nations" }
		HumanProtection.enable(hvn)
		t.eq(hvn.humanGrace, nil, "HvN stays OpenFront's")
	end)

	t.test("the values per difficulty are RoWorld's, and Impossible takes Brutal's", function()
		t.eq(HumanProtection.GRACE_TICKS.Easy, 3000, "Relaxed")
		t.eq(HumanProtection.GRACE_TICKS.Medium, 1800, "Standard")
		t.eq(HumanProtection.GRACE_TICKS.Hard, 1200, "Brutal")
		t.eq(HumanProtection.GRACE_TICKS.Impossible, 1200, "Impossible = Brutal")
		t.eq(HumanProtection.MAX_WARS.Easy, 1, "Relaxed")
		t.eq(HumanProtection.MAX_WARS.Impossible, 3, "Impossible = Brutal")
		t.eq(HumanProtection.SKIP_CHANCE.Easy, 0.75, "Relaxed")
		t.eq(HumanProtection.SKIP_CHANCE.Medium, 0.25, "Standard")
		t.eq(HumanProtection.SKIP_CHANCE.Impossible, 0, "Impossible = Brutal")
	end)

	t.test("with every flag off nothing is off limits and no state is kept", function()
		local m = start("Hard")
		setAge(m.game, 0)
		t.ok(not HumanProtection.offLimits(m.game, m.nation, m.human), "no grace")
		t.ok(not HumanProtection.nukeOffLimits(m.game, m.nation, m.human), "no bomb grace")
		HumanProtection.noteWar(m.game, m.nation, m.human)
		t.ok(not HumanProtection.considerCapitulation(m.game, m.nation), "no capitulation")
		t.eq(m.game._humanProtection, nil, "no protection state on the game")
		t.ok(behavior(m):shouldAttack(m.human), "Hard attacks as OpenFront does")
	end)

	t.test("grace: a nation can't start on a human until its own grace ends", function()
		local m = start("Hard", { "humanGrace" })
		local grace = HumanProtection.graceFor(m.game, m.nation, m.human)
		t.ok(grace >= 1200 and grace <= 1200 + 900 + 1200, `grace in range ({grace})`)
		local b = behavior(m)
		setAge(m.game, 0)
		t.ok(not b:shouldAttack(m.human), "at the start of play")
		setAge(m.game, grace - 1)
		t.ok(not b:shouldAttack(m.human), "one tick before")
		setAge(m.game, grace)
		t.ok(b:shouldAttack(m.human), "when it ends")
		setAge(m.game, 0)
		t.ok(b:shouldAttack(m.game:terraNullius()), "free land is never protected")
	end)

	t.test("grace: nothing else is protected, and a forced retaliation still goes", function()
		local m = start("Hard", { "humanGrace" })
		setAge(m.game, 0)
		local other
		for _, p in m.game:players() do
			if p:type() == "NATION" and p ~= m.nation and p:isAlive() then
				other = p
				break
			end
		end
		t.ok(not HumanProtection.offLimits(m.game, m.nation, other), "nations don't protect each other")
		t.ok(behavior(m):shouldAttack(other), "a nation may attack a nation")
		-- sendAttack(target, true) is the retaliation path: it never asks shouldAttack.
		local asked = false
		local b = behavior(m)
		b.shouldAttack = function()
			asked = true
			return true
		end
		pcall(function()
			b:sendAttack(m.human, true)
		end)
		t.ok(not asked, "a forced attack doesn't check protection")
	end)

	t.test("war limit: full at 1 on Easy, 3 on Hard, and a running war may continue", function()
		local easy = start("Easy", { "humanWarLimit" })
		setAge(easy.game, 100000)
		t.ok(not HumanProtection.offLimits(easy.game, easy.nation, easy.human), "room for one")
		fillWars(easy, 1)
		t.eq(HumanProtection.warsOn(easy.game, easy.human), 1, "one order counted")
		t.ok(HumanProtection.offLimits(easy.game, easy.nation, easy.human), "Easy: the second must wait")
		easy.runner:step()
		t.eq(HumanProtection.warsOn(easy.game, easy.human), 0, "an order counts for its own tick only")

		local hard = start("Hard", { "humanWarLimit" })
		setAge(hard.game, 100000)
		fillWars(hard, 2)
		t.ok(not HumanProtection.offLimits(hard.game, hard.nation, hard.human), "Hard: room for a third")
		fillWars(hard, 3)
		t.ok(HumanProtection.offLimits(hard.game, hard.nation, hard.human), "Hard: the fourth must wait")
	end)

	t.test("war limit: a live attack counts until it ends; one answering the human doesn't", function()
		local m = start("Easy", { "humanWarLimit" })
		setAge(m.game, 100000)
		local other
		for _, p in m.game:players() do
			if p:type() == "NATION" and p ~= m.nation and p:isAlive() then
				other = p
				break
			end
		end
		local fakeAttack = {
			attacker = function()
				return other
			end,
		}
		local incoming = m.human.incomingAttacks
		m.human.incomingAttacks = function()
			return { fakeAttack }
		end
		t.eq(HumanProtection.warsOn(m.game, m.human), 1, "a nation attacking the human")
		t.ok(HumanProtection.offLimits(m.game, m.nation, m.human), "so Easy is full")
		-- The same attack as an answer to the human's own attack on that nation.
		local outgoing = m.human.outgoingAttacks
		m.human.outgoingAttacks = function()
			return {
				{
					target = function()
						return other
					end,
				},
			}
		end
		t.eq(HumanProtection.warsOn(m.game, m.human), 0, "a counter-attack isn't counted")
		m.human.incomingAttacks, m.human.outgoingAttacks = incoming, outgoing
	end)

	t.test("war limit: an attack ordered this tick holds its slot for later nations", function()
		local m = start("Easy", { "humanWarLimit" })
		setAge(m.game, 100000)
		local b = behavior(m)
		-- Border checks aside: send through the real land path.
		b.emojiBehavior = { maybeSendAttackEmoji = function() end }
		t.eq(HumanProtection.warsOn(m.game, m.human), 0, "no war yet")
		t.ok(b:_sendLandAttack(m.human, function()
			return 100
		end), "the order goes")
		t.eq(HumanProtection.warsOn(m.game, m.human), 1, "counted at once")
		t.eq(#m.human:incomingAttacks(), 0, "before the attack itself is in play")
	end)

	t.test("skip: Easy passes a human over about 3 in 4, once per cycle, and Hard never", function()
		local easy = start("Easy", { "humanSkip" })
		local b = behavior(easy)
		local first = b:shouldAttack(easy.human)
		for _ = 1, 20 do
			t.eq(b:shouldAttack(easy.human), first, "one roll within a cycle")
		end
		local skipped, n = 0, 2000
		for _ = 1, n do
			easy.game._ticks += 1
			if not b:shouldAttack(easy.human) then
				skipped += 1
			end
		end
		t.ok(skipped > n * 0.70 and skipped < n * 0.80, `Easy skips about 75% ({skipped} of {n})`)

		local hard = start("Hard", { "humanSkip" })
		local bh = behavior(hard)
		for _ = 1, 200 do
			hard.game._ticks += 1
			t.ok(bh:shouldAttack(hard.human), "Hard never skips")
		end
	end)

	t.test("skip: a traitor is never skipped, as in OpenFront; the grace still holds", function()
		local m = start("Easy", { "humanSkip", "humanGrace" })
		m.human.isTraitor = function()
			return true
		end
		local b = behavior(m)
		setAge(m.game, 100000)
		for _ = 1, 50 do
			m.game._ticks += 1
			t.ok(b:shouldAttack(m.human), "traitors are always fair game")
		end
		setAge(m.game, 0)
		t.ok(not b:shouldAttack(m.human), "but not during the grace")
	end)

	t.test("random boats and betrayals respect the grace", function()
		local m = start("Easy", { "humanGrace" })
		setAge(m.game, 0)
		local b = behavior(m)
		-- A boat target on the human's land.
		local tile = m.human:tiles():values()[1]
		b._findRandomBoatTarget = function()
			return { tile = tile, launch = tile }
		end
		b._shoreTiles = function()
			return { tile }
		end
		b._sail = function()
			return { length = 1, blocker = nil }
		end
		local before = #m.game:executions()
		b:_attackWithRandomBoat({})
		t.eq(#m.game:executions(), before, "no boat during the grace")

		local betrayed = false
		b.allianceBehavior = {
			findJuiciestAlly = function()
				return nil
			end,
			maybeBetray = function()
				betrayed = true
				return true
			end,
		}
		t.ok(not b:_maybeBetrayAndAttack({ m.human }, {}), "no betrayal")
		t.ok(not betrayed, "it isn't even considered during the grace")
		setAge(m.game, 100000)
		b:_maybeBetrayAndAttack({ m.human }, {})
		t.ok(betrayed, "and is afterwards")
	end)

	t.test("bombs wait 2 minutes longer than land attacks", function()
		local m = start("Hard", { "humanGrace" })
		local grace = HumanProtection.graceFor(m.game, m.nation, m.human)
		setAge(m.game, grace)
		t.ok(not HumanProtection.offLimits(m.game, m.nation, m.human), "land is free")
		t.ok(HumanProtection.nukeOffLimits(m.game, m.nation, m.human), "bombs aren't")
		setAge(m.game, grace + HumanProtection.NUKE_EXTRA)
		t.ok(not HumanProtection.nukeOffLimits(m.game, m.nation, m.human), "then they are")

		setAge(m.game, 0)
		local emoji = 0
		local mirv = setmetatable({
			game = m.game,
			player = m.nation,
			emojiBehavior = {
				maybeSendAttackEmoji = function()
					emoji += 1
				end,
			},
		}, NationMIRVBehavior)
		mirv:_maybeSendMIRV(m.human)
		t.eq(emoji, 0, "a MIRV stops at the same gate")
	end)

	-- A small nation, an attacker with the troops, a live attack between them.
	local function surrenderSetup(): any
		local m = start("Medium", { "capitulation" })
		local loser, winner
		for _, p in m.game:players() do
			if p:type() == "NATION" and p:isAlive() then
				if loser == nil then
					loser = p
				elseif winner == nil then
					winner = p
				end
			end
		end
		setAge(m.game, HumanProtection.CAPITULATE_AGE)
		loser:setTroops(1000)
		winner:setTroops(100000)
		local attack = {
			attacker = function()
				return winner
			end,
			troops = function()
				return 1000
			end,
		}
		loser.incomingAttacks = function()
			return { attack }
		end
		m.loser, m.winner, m.attack = loser, winner, attack
		return m
	end

	t.test("capitulation: the small nation surrenders everything to the attacker", function()
		local m = surrenderSetup()
		local game, loser, winner = m.game, m.loser, m.winner
		local tilesBefore = winner:numTilesOwned() + loser:numTilesOwned()
		t.ok(loser:numTilesOwned() > 0, "it holds land")
		t.ok(HumanProtection.considerCapitulation(game, loser), "it surrenders")
		t.eq(loser:numTilesOwned(), 0, "all its land is gone")
		t.eq(winner:numTilesOwned(), tilesBefore, "all of it to the attacker")
		t.ok(not loser:isAlive(), "it is eliminated")
		for _ = 1, 5 do
			m.runner:step()
		end
		t.ok(winner:isAlive(), "and the match runs on")
	end)

	t.test("capitulation: its structures go to the attacker on the next tick", function()
		local m = surrenderSetup()
		local game, loser, winner = m.game, m.loser, m.winner
		local city = loser:buildUnit("City", loser:tiles():values()[1], {})
		HumanProtection.considerCapitulation(game, loser)
		m.runner:step()
		t.eq(city:owner(), winner, "the city changes hands")
	end)

	t.test("capitulation: each condition holds it back", function()
		local m = surrenderSetup()
		local game, loser = m.game, m.loser

		setAge(game, HumanProtection.CAPITULATE_AGE - 1)
		t.ok(not HumanProtection.considerCapitulation(game, loser), "not before 20 minutes")
		setAge(game, HumanProtection.CAPITULATE_AGE)

		local land = game.totalLandTiles
		game.totalLandTiles = function()
			return loser:numTilesOwned()
		end
		t.ok(not HumanProtection.considerCapitulation(game, loser), "not with 2% of the land or more")
		game.totalLandTiles = land

		loser:setTroops(13000)
		t.ok(not HumanProtection.considerCapitulation(game, loser), "not against under 8x its troops")
		loser:setTroops(1000)

		local attacks = loser.incomingAttacks
		loser.incomingAttacks = function()
			return {}
		end
		t.ok(not HumanProtection.considerCapitulation(game, loser), "not unless attacked")
		loser.incomingAttacks = attacks

		local attacker = m.attack.attacker
		m.attack.attacker = function()
			return { type = function()
				return "BOT"
			end, troops = function()
				return 1e9
			end }
		end
		t.ok(not HumanProtection.considerCapitulation(game, loser), "not to a tribe")
		m.attack.attacker = attacker
	end)

	t.test("capitulation: at most one per 30 s, and never a human", function()
		local m = surrenderSetup()
		local game, loser = m.game, m.loser
		local second
		for _, p in game:players() do
			if p:type() == "NATION" and p:isAlive() and p ~= loser and p ~= m.winner then
				second = p
				break
			end
		end
		second:setTroops(1000)
		second.incomingAttacks = loser.incomingAttacks
		t.ok(HumanProtection.considerCapitulation(game, loser), "the first")
		t.ok(not HumanProtection.considerCapitulation(game, second), "the second must wait")
		game._ticks += HumanProtection.CAPITULATE_GAP
		setAge(game, HumanProtection.CAPITULATE_AGE)
		t.ok(HumanProtection.considerCapitulation(game, second), "then it may")

		m.human.incomingAttacks = second.incomingAttacks
		game._ticks += HumanProtection.CAPITULATE_GAP
		setAge(game, HumanProtection.CAPITULATE_AGE)
		t.ok(not HumanProtection.considerCapitulation(game, m.human), "a human never surrenders")
	end)

	t.test("the nation AI runs a match with all four parts on", function()
		local m = start("Hard", { "humanGrace", "humanWarLimit", "humanSkip", "capitulation" })
		local before = m.human:numTilesOwned()
		for _ = 1, 300 do
			m.runner:step()
		end
		t.ok(m.human:isAlive(), "the human survives the grace")
		t.ok(m.human:numTilesOwned() >= before, "and loses no land while it idles")
		for _, a in m.human:incomingAttacks() do
			t.ok(a:attacker():type() ~= "NATION", "no nation attacks the human in the grace")
		end
	end)
end
