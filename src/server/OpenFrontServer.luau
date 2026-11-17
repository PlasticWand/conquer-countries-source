--!strict
-- Roblox adapter for the OpenFront port: remotes, matches and the 10 Hz loop.
-- All rules live in Shared.OpenFront; this file connects them to players.
--   - Public lobbies across servers (RoWorld's, docs/openfront-port/LOBBIES_PLAN.md):
--     every hub server (an ordinary public server) reads one shared list of
--     upcoming public matches (Shared/LobbyDirectory over LobbyStore:
--     OpenFront's FFA playlist, World FFA and the team playlist, each with a
--     fixed start). JOIN seats the player (and party) in the soonest lobby of
--     that kind and teleports them to its reserved match server; with every
--     lobby full they wait in line. A match server (Shared/MatchHost) waits
--     for its start, plays the match and sends everyone back to a hub. A
--     running match's row offers Watch (a teleport as spectator). In Studio
--     there are no teleports: the hub plays the lobby itself (localLobbies).
--   - Parties (Shared/Parties) join together and pass each other as
--     friends, so team games put them on one team (TeamAssignment); the
--     teleport data carries the party to the match server.
--   - "Solo" starts a private singleplayer game on any imported map. On a
--     live hub it runs on a reserved server of its own (Bruno, 2026-11-10,
--     audit F3: every match on a server shares one thread and its memory):
--     the hub reserves one and teleports the player with { solo = { map,
--     difficulty } }; that server's role is "solo", and it starts the match
--     when the client says it is ready. Studio, or a failed teleport, plays
--     it here as before.
--   - The map in play is cloned from ServerStorage.OpenFrontMaps into
--     ReplicatedStorage.OpenFrontMaps, so clients only download maps in use
--     (World is published at start for the menu's background).
--   - Players who leave mid-match are marked disconnected (AFK).
-- Remote payloads: Snapshot/Tick are OpenFront/Replication tables;
-- Intent is a Runner intent; Status is { phase = "menu" | ... } for a player
-- leaving a match; Menu is { lobbies = Lobbies rows, queued = id?, party }
-- at 2 Hz to everyone not playing.
-- Start: { mode = "solo", map, difficulty } | { mode = "queue", id } |
-- { mode = "unqueue" } | { mode = "watch", id } | { mode = "leave" }.
-- Party: { op = "invite", userId } | { op = "accept", userId } | { op = "leave" }.
-- Query (RemoteFunction) answers { kind = "actions", tile?, other?, buildables? } with
-- Runner.playerActions and { kind = "build_preview", tile?, unit } with
-- Runner.buildPreview, as OpenFront's worker answers its client.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OF = Shared:WaitForChild("OpenFront")
local ArsenalUnits = require(OF.ArsenalUnits)
local ImportedMaps = require(OF.Data.ImportedMaps) :: { { folder: string, id: string, landTiles: number } }
local Lobbies = require(Shared.Lobbies)
local LobbyDirectory = require(Shared.LobbyDirectory)
local LobbyStore = require(Shared.LobbyStore)
local MapInfo = require(OF.Data.MapInfo) :: { any }
local HumanProtection = require(OF.HumanProtection)
local MapPlaylist = require(OF.MapPlaylist)
local MatchHost = require(Shared.MatchHost)
local Parties = require(Shared.Parties)
local WaitingRoom = require(Shared.WaitingRoom)
local PublicLobbies = require(Shared.PublicLobbies)
local Replication = require(OF.Replication)
local Runner = require(OF.Runner)
local Tutorial = require(Shared.Tutorial)

local Analytics = require(script.Parent.Analytics)
local CrateModels = require(script.Parent.CrateModels)
local SharedClock = require(script.Parent.Lobbies.SharedClock)
local Store = require(script.Parent.Store)
local Teleports = require(script.Parent.Lobbies.Teleports)

local OpenFrontServer = {}

local TICK = 0.1 -- Config.msPerTick
local MAX_STEPS_PER_FRAME = 3
local RESULTS_SECONDS = 15
-- PLAY AGAIN from a public match: how long after arriving at a hub its
-- queue for the next one starts (the party re-forms and the menu loads first).
local QUEUE_ON_ARRIVAL_S = 2
-- A won match with players still in it stops after this long (a server
-- resource guard; OpenFront's own servers keep a finished game until its
-- clients leave).
local KEEP_PLAYING_SECONDS = 30 * 60
local MENU_INTERVAL = 0.5

local REMOTES = { "Intent", "IntentResult", "Snapshot", "Tick", "Start", "Status", "Menu", "Party", "Tutorial" }
local DIFFICULTIES = { Easy = true, Medium = true, Hard = true, Impossible = true }
-- Orders that count as an attack (analytics' first attack): on land, a
-- neighbour or across water.
local ATTACKS = { tile_action = true, attack = true, boat = true }

-- Token buckets per player. Intents follow OpenFront's ClientMsgRateLimiter
-- (10 a second, 150 a minute; excess intents are dropped). Query and Start
-- are ours: the build preview asks up to 20 times a second and the player
-- panel 10; a match start is expensive.
type Bucket = { tokens: number, size: number, per: number, at: number }
local function bucket(size: number, per: number): Bucket
	return { tokens = size, size = size, per = per, at = os.clock() }
end
local function take(b: Bucket): boolean
	local now = os.clock()
	b.tokens = math.min(b.size, b.tokens + (now - b.at) * b.size / b.per)
	b.at = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end
-- Query time: ms of server time a player's queries may use (audit F7).
local QUERY_MS_PER_S, QUERY_MS_BURST = 60, 120
local limits: { [Player]: { second: Bucket, minute: Bucket, query: Bucket, queryMs: Bucket, start: Bucket, party: Bucket, tutorial: Bucket } } = {}
local function limitsOf(player: Player)
	local l = limits[player]
	if l == nil then
		l = { second = bucket(10, 1), minute = bucket(150, 60), query = bucket(40, 1), queryMs = bucket(QUERY_MS_BURST, QUERY_MS_BURST / QUERY_MS_PER_S), start = bucket(4, 4), party = bucket(6, 10), tutorial = bucket(10, 5) }
		limits[player] = l
	end
	return l
end

type Match = {
	id: string,
	runner: any,
	replicator: any,
	public: boolean,
	queue: string?, -- the public lobby it came from (its id)
	kind: string?, -- that lobby's kind (PublicLobbies.KIND_*)
	beatAt: number?, -- Studio: when its local lobby record was last refreshed
	nextAt: number?, -- when its players last heard when the next match starts
	mapName: string,
	members: { [Player]: true },
	spectators: { [Player]: true },
	accum: number,
	-- Studio filming (Server/Filming): the match is frozen while true.
	filmHold: boolean?,
	-- A winner was decided (stars paid). The match keeps running, as in
	-- OpenFront ("Keep playing"), until its players leave.
	wonAt: number?,
	endedAt: number?,
	-- Server tick cost (ms): a running mean and the worst in the last window.
	stepMean: number,
	stepWorst: number,
	stepWindowAt: number,
	stepWorstLast: number,
	paid: { [Player]: boolean }, -- stars already paid for this match
	-- Ticks each member has been alive since the spawn phase ended (Bruno,
	-- 2026-11-10, audit F9: per-minute stars stop when you are eliminated;
	-- a Takeover starts them again).
	aliveTicks: { [Player]: number },
	-- Analytics (new players' funnel): matches each member had played before
	-- this one, and what was already logged for them here.
	matchesBefore: { [Player]: number },
	logged: { [Player]: { [string]: boolean } },
	startedAt: number?,
	-- The tutorial's City gold, given once per member (Runner.tutorialGold).
	tutorialGold: { [Player]: boolean },
}

local remotes: { [string]: RemoteEvent } = {}
local publicMatches: { [string]: Match } = {} -- by lobby id
local soloMatches: { [Player]: Match } = {}
local matchOf: { [Player]: Match } = {}
local nextMatchId = 0
local menuAt = 0

-- Imported maps by OpenFront map type ("Black Sea" -> "BlackSea").
local folderOfType: { [string]: string } = {}
local available: MapPlaylist.Available = {}
do
	local typeOf: { [string]: string } = {}
	for _, m in MapInfo do
		typeOf[m.id] = m.type
	end
	for _, imported in ImportedMaps do
		local t = typeOf[imported.id]
		if t then
			folderOfType[t] = imported.folder
			available[t] = { landTiles = imported.landTiles }
		end
	end
end

local rng = Random.new()
local playlist = MapPlaylist.new(available, function()
	return rng:NextNumber()
end, function()
	return math.floor(os.clock() * 1000) + os.time()
end, {
	-- Conquest (Bruno, 2026-11-03): no compact public games (a config flag;
	-- OpenFront plays every 3rd on the quarter-area map, where ranges looked
	-- twice as big).
	compact = false,
})
local parties = Parties.new(os.clock)

local function keyOf(player: Player): string
	return tostring(player.UserId)
end
local function playerOfKey(key: string): Player?
	local id = tonumber(key)
	return if id then Players:GetPlayerByUserId(id) else nil
end

-- Public lobbies across servers (see the header). A reserved server with no
-- private-server owner is a lobby's match server; every other server is a hub.
local isMatchServer = WaitingRoom.isMatchServer(game.PrivateServerId, game.PrivateServerOwnerId)
-- "hub", "match" (a public lobby's server) or "solo" (one player's solo
-- match). A reserved server learns which from its first arrival's teleport
-- data; until then nil.
local serverRole: string? = if isMatchServer then nil else WaitingRoom.ROLE_HUB
-- Solo server: the setup each arrival came for, until their client is ready.
local soloWanted: { [Player]: { map: string?, difficulty: string?, tutorial: boolean? } } = {}
-- Hub: solo players on their way to their own server.
local soloSent: { [Player]: { map: string?, difficulty: string?, tutorial: boolean? } } = {}
local worldAvailable = available.World ~= nil
local clock: () -> number = SharedClock.now
local store: LobbyStore.Store = nil :: any -- set in start()
local teleports: Teleports.Teleporter = Teleports.studio()
local directory: LobbyDirectory.Directory? = nil -- a hub's
local host: MatchHost.Host? = nil -- a match server's
-- Studio (no teleports): lobbies this hub plays itself, with the players seated.
local localLobbies: { [string]: { lobby: PublicLobbies.Lobby, members: { Player } } } = {}
-- Hub: players seated (`sent` on their way, or in a local lobby) or in line.
local pending: { [Player]: { kind: string, at: number, lobby: string?, sent: boolean? } } = {}
-- Match server: who came in which party (user id -> its members' ids), and
-- who came to watch.
local arrivedParty: { [string]: { string } } = {}
local spectating: { [Player]: boolean } = {}
-- Players on their way back to a hub (not put back into the match meanwhile).
local leaving: { [Player]: boolean } = {}
-- A teleported player still here this long after was not taken: seat lapses.
local SENT_TIMEOUT = 30

-- Takes the player out of any lobby they wait for on this hub: the line, or a
-- local lobby (its seat goes back). A player already on their way keeps it.
local function leaveLobby(player: Player)
	local p = pending[player]
	if p == nil then
		return
	end
	pending[player] = nil
	if directory then
		directory:dequeue(keyOf(player))
	end
	local id = p.lobby
	local entry = if id then localLobbies[id] else nil
	if id and entry then
		local i = table.find(entry.members, player)
		if i then
			table.remove(entry.members, i)
		end
		task.spawn(function()
			pcall(store.release, id, { keyOf(player) })
		end)
	end
end

-- A player's party friends: the party on this server, and on a match server
-- the party they arrived with.
local function friendsOf(key: string): { string }
	local out = {}
	for _, other in parties:members(key) do
		if other ~= key then
			table.insert(out, other)
		end
	end
	local arrived: { string } = arrivedParty[key] or {}
	for _, other in arrived do
		if other ~= key and table.find(out, other) == nil then
			table.insert(out, other)
		end
	end
	return out
end

local function mapsFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("OpenFrontMaps")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "OpenFrontMaps"
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

-- Clones a map module into ReplicatedStorage on first use and returns it.
local function publishMap(name: string): Instance
	local existing = mapsFolder():FindFirstChild(name)
	if existing then
		return existing
	end
	local source = ServerStorage:WaitForChild("OpenFrontMaps"):FindFirstChild(name)
	assert(source, `map {name} is not imported`)
	local copy = source:Clone()
	copy.Parent = mapsFolder()
	return copy
end

local function newMatch(public: boolean, folderName: string, gameConfig: { [string]: any }): Match
	nextMatchId += 1
	local id = `{game.JobId ~= "" and string.sub(game.JobId, 1, 8) or "studio"}-{nextMatchId}-{os.time()}`
	local folder = publishMap(folderName)
	local runner = Runner.new({
		gameID = id,
		mapFolder = folder,
		-- Name placement is client work in OpenFront; spread it so it never
		-- lands as one long server tick.
		nameBudgetMs = 4,
		gameConfig = gameConfig,
	})
	return {
		id = id,
		runner = runner,
		replicator = nil :: any,
		public = public,
		queue = nil,
		kind = nil,
		beatAt = nil,
		nextAt = nil,
		mapName = folderName,
		members = {},
		spectators = {},
		accum = 0,
		wonAt = nil,
		endedAt = nil,
		stepMean = 0,
		stepWorst = 0,
		stepWindowAt = os.clock(),
		stepWorstLast = 0,
		paid = {},
		aliveTicks = {},
		matchesBefore = {},
		logged = {},
		startedAt = nil,
		tutorialGold = {},
	}
end

-- Pays a member's stars once: at the end of the match, or when they leave.
-- Placement ranks humans and nations by land (tribes don't count).
local function payStars(match: Match, player: Player)
	if match.paid[player] or match.replicator == nil then
		return
	end
	match.paid[player] = true
	local g = match.runner.game
	local key = keyOf(player)
	local ranked = {}
	local me = nil
	for _, p in g:allPlayers() do
		if p:type() ~= "BOT" then
			table.insert(ranked, p)
			if p:clientID() == key then
				me = p
			end
		end
	end
	if me == nil then
		return
	end
	table.sort(ranked, function(a, b)
		return a:numTilesOwned() > b:numTilesOwned()
	end)
	-- The winner is a player, or a team's name in team games.
	local winner = g:getWinner()
	local won = if type(winner) == "table" then winner:id() == me:id() elseif type(winner) == "string" then me:team() == winner else false
	local minutes = (match.aliveTicks[player] or 0) / 600
	local placement = table.find(ranked, me) or #ranked
	local sawResult = winner ~= nil or not me:isAlive()
	Analytics.matchFinished(player, match.matchesBefore[player] or 1, minutes, placement, match.id, sawResult)
	Store.matchEnded(player, {
		won = won,
		placement = table.find(ranked, me) or #ranked,
		players = #ranked,
		-- Minutes alive, not the match clock: a player who sits dead earns no
		-- more per-minute stars (audit F9).
		minutes = (match.aliveTicks[player] or 0) / 600,
		difficulty = if match.public then nil else match.runner.gameConfig.difficulty,
	})
end

-- A singleplayer game as OpenFront's SinglePlayerModal sets it up.
-- `tutorial`: a new player's first match (Shared/Tutorial, after RoWorld's):
-- fewer tribes, a 1 s deploy countdown, and the flag the client's tutorial
-- and Runner.tutorialGold read.
local function soloConfig(mapType: string, difficulty: string, tutorial: boolean?): { [string]: any }
	local config: { [string]: any } = {
		-- OpenFront's GameMapType value ("Black Sea"), not our folder name.
		gameMap = mapType,
		gameMapSize = "Normal",
		gameMode = "Free For All",
		gameType = "Singleplayer",
		difficulty = difficulty,
		bots = 400,
		nations = "default", -- the map's nations, as OpenFront picks them
		donateGold = false,
		donateTroops = false,
		infiniteGold = false,
		infiniteTroops = false,
		instantBuild = false,
		randomSpawn = false,
		extraWeapons = true, -- Conquest's Arsenal (each player still needs the unlock)
		-- Conquest (Bruno 2026-10-27): placing your capital starts a 5 s
		-- countdown to move it, rather than starting at once as OpenFront's
		-- singleplayer does (DeployCountdownExecution).
		soloDeployCountdown = 5,
	}
	-- Conquest (Bruno 2026-11-05): RoWorld's protection, so every difficulty can be won.
	HumanProtection.enable(config)
	config.boatFullRefund = true -- Conquest (Bruno 2026-11-05)
	if tutorial then
		config.tutorial = true
		config.bots = Tutorial.BOTS
		config.soloDeployCountdown = Tutorial.COUNTDOWN_S
	end
	return config
end

local function startMatch(match: Match)
	for player in match.members do
		local key = keyOf(player)
		local friends = friendsOf(key)
		local loadout = Store.loadout(player)
		match.runner:addHuman(key, player.DisplayName, friends, { flag = loadout.flag, skin = loadout.skin, weapons = loadout.weapons })
		matchOf[player] = match
	end
	match.runner:start()
	match.replicator = Replication.newReplicator(match.runner)
	match.startedAt = os.clock()
	for player in match.members do
		local before = Store.matchesOf(player) or 0
		match.matchesBefore[player] = before
		match.logged[player] = {}
		Analytics.matchStarted(player, before, match.id)
	end
	for player in match.members do
		remotes.Snapshot:FireClient(player, match.replicator:snapshot(keyOf(player)))
	end
end

local function watch(match: Match, player: Player)
	match.spectators[player] = true
	matchOf[player] = match
	if match.replicator then
		remotes.Snapshot:FireClient(player, match.replicator:snapshot(nil))
	end
end

local function leaveMatch(player: Player)
	local match = matchOf[player]
	if match then
		-- OpenFront's server sends mark_disconnected for a player who leaves
		-- mid-match; their nation stays on the map, now AFK.
		if match.members[player] and match.replicator ~= nil and match.endedAt == nil then
			match.runner:markDisconnected(keyOf(player), true)
		end
		if match.members[player] then
			pcall(payStars, match, player)
		end
		match.members[player] = nil
		match.spectators[player] = nil
		matchOf[player] = nil
	end
	soloMatches[player] = nil
end

-- The player's party members who are on the menu (not playing).
local function partyInMenu(player: Player): { string }
	local out = {}
	for _, key in parties:members(keyOf(player)) do
		local p = playerOfKey(key)
		if p and matchOf[p] == nil then
			table.insert(out, key)
		end
	end
	return out
end

local function startSoloHere(player: Player, request: any)
	leaveMatch(player)
	leaveLobby(player)
	local folder = if type(request.map) == "string" then request.map else "World"
	local mapType = nil
	for t, f in folderOfType do
		if f == folder then
			mapType = t
		end
	end
	if mapType == nil then
		folder, mapType = "World", "World"
	end
	local difficulty = if DIFFICULTIES[request.difficulty] then request.difficulty else "Medium"
	local tutorial = request.tutorial == true
	if tutorial then
		Store.setTutorial(player, "started")
	end
	local match = newMatch(false, folder, soloConfig(mapType :: string, difficulty, tutorial))
	match.members[player] = true
	soloMatches[player] = match
	local ok, err = pcall(startMatch :: any, match)
	if not ok then
		warn(`OpenFront: solo match failed to start: {err}`)
		leaveMatch(player)
		remotes.Status:FireClient(player, { phase = "menu" })
	end
end

-- PLAY SOLO: on a live hub, the player goes to a reserved server of their
-- own with the setup (audit F3); anywhere else (Studio, a solo server's
-- Restart) it starts here. A failed teleport starts it here too.
local function startSolo(player: Player, request: any)
	if serverRole ~= WaitingRoom.ROLE_HUB or RunService:IsStudio() then
		startSoloHere(player, request)
		return
	end
	local setup = {
		map = if type(request.map) == "string" and #request.map <= 64 then request.map else nil,
		difficulty = if type(request.difficulty) == "string" and DIFFICULTIES[request.difficulty] then request.difficulty else nil,
		tutorial = if request.tutorial == true then true else nil,
	}
	leaveMatch(player)
	leaveLobby(player)
	soloSent[player] = setup
	task.spawn(function()
		local ok, code = pcall(function(): string
			return (teleports.reserve())
		end)
		local sent, note = false, nil
		if ok and type(code) == "string" then
			sent, note = teleports.send({ player }, code, { solo = setup })
		end
		if sent and note == Teleports.INFLIGHT then
			-- Already teleporting (a PLAY pressed twice), or throttled: only if
			-- they are still here after a while does the match run here.
			task.wait(Teleports.INFLIGHT_WAIT_S)
			sent = false
		end
		if not sent and soloSent[player] == setup and player.Parent ~= nil and matchOf[player] == nil then
			soloSent[player] = nil
			warn("[Solo] no server of its own; playing on the hub")
			startSoloHere(player, setup)
		end
	end)
end

-- Starts lobby `lobbyId`'s public match with `members` (a match server's
-- arrivals, or in Studio a local lobby's players).
local function startPublic(lobbyId: string, kind: string, members: { Player }, config: { [string]: any }): Match?
	config = table.clone(config)
	config.extraWeapons = true -- Conquest's Arsenal (each player still needs the unlock)
	-- Conquest (Bruno 2026-10-28): a player who doesn't pick a start before
	-- the timer ends gets a random one (AutoSpawnExecution).
	config.autoSpawnUnplaced = true
	-- Conquest (Bruno 2026-11-05): solo and public alike; not Humans vs Nations.
	HumanProtection.enable(config)
	config.boatFullRefund = true -- Conquest (Bruno 2026-11-05)
	local folder = folderOfType[config.gameMap]
	if folder == nil then
		warn(`OpenFront: lobby {lobbyId} asks for a map this place doesn't have: {config.gameMap}`)
		return nil
	end
	local match = newMatch(true, folder, config)
	match.queue = lobbyId
	match.kind = kind
	for _, p in members do
		if p.Parent ~= nil and matchOf[p] == nil then
			match.members[p] = true
		end
	end
	if next(match.members) == nil then
		return nil
	end
	publicMatches[lobbyId] = match
	local ok, err = pcall(startMatch :: any, match)
	if not ok then
		warn(`OpenFront: public match failed to start: {err}`)
		match.endedAt = os.clock()
	end
	return match
end

-- Studio: a local lobby's record shows as started (then live, to watch) or
-- stays fresh while its match runs.
local function touchLocalLobby(id: string, humans: number, starting: boolean)
	task.spawn(function()
		pcall(store.update, id, function(v: any): any?
			local cur = PublicLobbies.decode(v)
			if cur == nil then
				return nil
			end
			if starting then
				cur.status = "started"
			end
			cur.players = humans
			cur.beat = clock()
			return cur
		end)
	end)
end

local function partyView(player: Player): { [string]: any }
	local key = keyOf(player)
	local members = {}
	for _, k in parties:members(key) do
		local p = playerOfKey(k)
		table.insert(members, { userId = tonumber(k), name = if p then p.DisplayName else "?" })
	end
	local invites = {}
	for _, from in parties:pending(key) do
		local p = playerOfKey(from)
		if p then
			table.insert(invites, { userId = p.UserId, name = p.DisplayName })
		end
	end
	return { members = members, invites = invites }
end

-- A menu row for lobby `l` (Shared/Lobbies.Row; its id is the kind, which is
-- what JOIN and WATCH ask for).
local function lobbyRow(l: PublicLobbies.Lobby, now: number, startsIn: number?): { [string]: any }
	local cfg = l.config
	local live = l.status == "started"
	return {
		id = l.kind,
		title = if l.kind == PublicLobbies.KIND_FFA then "Public match" elseif l.kind == PublicLobbies.KIND_BLITZ then "Blitz" else Lobbies.mapName(cfg.gameMap),
		mapName = Lobbies.mapName(cfg.gameMap),
		mapType = cfg.gameMap,
		mode = Lobbies.modeText(cfg),
		minutes = cfg.maxTimerValue,
		players = math.min(l.players, l.max),
		capacity = l.max,
		seconds = if live then nil else math.floor(startsIn or math.max(0, l.starts - now)),
		live = live,
		liveSeconds = if live then math.max(0, math.floor(now - l.starts)) else nil,
	}
end

-- One row per kind: its soonest joinable lobby, else its busiest running
-- match. A match server shows only its own lobby.
local function menuRows(): { any }
	local now = clock()
	local h = host
	if h then
		local l = h.lobby
		return if l then { lobbyRow(l, now, h:startsIn()) } else {}
	end
	local rows = {}
	local list: { PublicLobbies.Lobby } = if directory then directory:lobbies() else {}
	for _, k in PublicLobbies.kinds(worldAvailable) do
		local open: PublicLobbies.Lobby? = nil
		local live: PublicLobbies.Lobby? = nil
		for _, l in list do
			if l.kind == k.kind then
				if PublicLobbies.joinable(l, now) then
					if open == nil or l.starts < (open :: PublicLobbies.Lobby).starts then
						open = l
					end
				elseif PublicLobbies.watchable(l, now) and (live == nil or l.players > (live :: PublicLobbies.Lobby).players) then
					live = l
				end
			end
		end
		local pick = open or live
		if pick then
			table.insert(rows, lobbyRow(pick, now, nil))
		end
	end
	return rows
end

-- Match server: the humans waiting for the start (not watching, not solo,
-- not on their way back to a hub).
local function waitingHere(): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		if matchOf[p] == nil and soloMatches[p] == nil and not spectating[p] and not leaving[p] then
			table.insert(out, p)
		end
	end
	return out
end

-- A match server's waiting room (WaitingRoom.view): the lobby's map, who is
-- here and the start. Empty while the lobby record isn't found yet.
local function roomView(): { [string]: any }
	local h = host :: MatchHost.Host
	local l = h.lobby
	if l == nil then
		return {}
	end
	local names = {}
	for _, p in waitingHere() do
		table.insert(names, p.DisplayName)
	end
	local s = h:startsIn()
	return {
		mapName = Lobbies.mapName(l.config.gameMap),
		mapType = l.config.gameMap,
		mode = Lobbies.modeText(l.config),
		minutes = l.config.maxTimerValue,
		players = math.min(math.max(l.players, #names), l.max),
		capacity = l.max,
		seconds = s,
		names = names,
		starting = h.started or (s ~= nil and s <= WaitingRoom.LEAVE_LOCK_S),
	}
end

local function sendMenu()
	local rows = menuRows()
	local h = host
	local room = if h then roomView() else nil
	for _, player in Players:GetPlayers() do
		if matchOf[player] == nil and not leaving[player] then
			-- queued: the kind they wait for; queueState: "line" (finding a
			-- seat), "joining" (teleporting) or "waiting" (seated, for the start)
			local q, state = nil, nil
			if h then
				if h.lobby and not spectating[player] then
					q, state = h.lobby.kind, "waiting"
				end
			elseif pending[player] then
				local p = pending[player]
				q = p.kind
				state = if p.sent then "joining" elseif p.lobby then "waiting" else "line"
			end
			remotes.Menu:FireClient(player, {
				lobbies = rows,
				queued = q,
				queueState = state,
				party = partyView(player),
				-- on a match server: the waiting room, not the menu
				room = if room and not spectating[player] then room else nil,
			})
		end
	end
end

-- A join that didn't work: the players are free again, with why.
local function failJoin(group: { Player }, reason: string?)
	for _, p in group do
		pending[p] = nil
		if reason and p.Parent then
			remotes.Status:FireClient(p, { phase = "menu", notice = reason })
		end
	end
end

-- Studio: the players wait in lobby `l`, which this hub plays itself.
local function joinLocal(l: PublicLobbies.Lobby, group: { Player })
	local entry = localLobbies[l.id]
	if entry == nil then
		entry = { lobby = l, members = {} }
		localLobbies[l.id] = entry
	end
	for _, p in group do
		if table.find(entry.members, p) == nil then
			table.insert(entry.members, p)
		end
		pending[p] = { kind = l.kind, at = os.clock(), lobby = l.id }
	end
end

-- Seated and teleporting: the seat is theirs until they arrive (or it lapses).
local function seated(group: { Player }, l: PublicLobbies.Lobby)
	for _, p in group do
		pending[p] = { kind = l.kind, at = os.clock(), lobby = l.id, sent = true }
	end
end

-- JOIN on a hub: the player and their party on the menu get seats in the
-- soonest lobby of `kind` (or wait in line for one), then go there.
local function publicJoin(player: Player, kind: string)
	local dir = directory
	if dir == nil or not PublicLobbies.isKind(kind) or matchOf[player] ~= nil or pending[player] ~= nil then
		return
	end
	local leader = keyOf(player)
	pending[player] = { kind = kind, at = os.clock() }
	-- who goes: the leader's party on the menu, not seated elsewhere (asked
	-- again from the line, as people come and go)
	local function group(): ({ any }?, { [string]: any }?)
		local mine = pending[player]
		if player.Parent == nil or mine == nil or mine.lobby ~= nil then
			return nil, nil
		end
		local out, uids = {}, {}
		for _, k in partyInMenu(player) do
			local p = playerOfKey(k)
			if p and (p == player or pending[p] == nil or pending[p].lobby == nil) then
				table.insert(out, p)
				table.insert(uids, k)
			end
		end
		return out, if #out > 1 then { key = leader, uids = uids, leader = leader } else nil
	end
	local players, party = group()
	local who = (players or { player }) :: { Player }
	for _, p in who do
		pending[p] = { kind = kind, at = os.clock() }
	end
	sendMenu()
	task.spawn(function()
		local ok, reason, l = dir:joinPublic(who, kind, {
			party = party,
			wanted = function(): boolean
				return pending[player] ~= nil
			end,
		})
		if ok and l then
			seated(who, l)
		elseif reason == "studio" and l then
			joinLocal(l, who)
		elseif reason == LobbyDirectory.NO_ROOM then
			-- every lobby of the kind is full right now: wait in line
			dir:enqueue({
				key = leader,
				kind = kind,
				since = clock(),
				members = group,
				done = function(okay: boolean, why: string?, lb: PublicLobbies.Lobby?, sent: { any }?)
					local went = (sent or { player }) :: { Player }
					if okay and lb then
						seated(went, lb)
					elseif why == "studio" and lb then
						joinLocal(lb, went)
					elseif why == "timeout" then
						failJoin(went, "Every public match is full right now. Try again in a moment, or play solo.")
					else
						failJoin(went, if why == "gone" then nil else why)
					end
					sendMenu()
				end,
			})
		elseif reason ~= "cancelled" then
			failJoin(who, reason)
		end
		sendMenu()
	end)
end

-- WATCH: a running public match of `kind`. Here (Studio, or this match
-- server's own), else a teleport to its match server as a spectator.
local function publicWatch(player: Player, kind: string)
	for _, m in publicMatches do
		if m.kind == kind and m.endedAt == nil then
			leaveLobby(player)
			watch(m, player)
			return
		end
	end
	local dir = directory
	if dir == nil then
		return
	end
	local now = clock()
	local best: PublicLobbies.Lobby? = nil
	for _, l in dir:lobbies() do
		if l.kind == kind and PublicLobbies.watchable(l, now) and (best == nil or l.players > (best :: PublicLobbies.Lobby).players) then
			best = l
		end
	end
	local target = best
	if target then
		task.spawn(function()
			local ok, reason = dir:spectate(player, target.id)
			if not ok and reason ~= "studio" then
				remotes.Status:FireClient(player, { phase = "menu", notice = reason })
			end
		end)
	end
end

-- Back to a hub (a match server's players after the match, or on LEAVE).
-- `queue`: a public kind the hub joins them to on arrival (PLAY AGAIN).
local function sendToHub(list: { Player }, queue: string?)
	if #list == 0 then
		return
	end
	-- everyone goes together, with who was in which party (re-formed on
	-- arrival: onArrival)
	local groups, seen = {}, {}
	for _, p in list do
		leaving[p] = true
		-- their screen says so while the teleport runs (WaitingRoom.returning)
		remotes.Status:FireClient(p, { phase = "menu", returning = true })
		local key = keyOf(p)
		local members = parties:members(key)
		if #members > 1 and not seen[key] then
			for _, k in members do
				seen[k] = true
			end
			table.insert(groups, table.clone(members))
		end
	end
	local data: { [string]: any }? = if #groups > 0 then { parties = groups } else nil
	if queue ~= nil then
		local d: { [string]: any } = data or {}
		d.queue = queue
		data = d
	end
	task.spawn(function()
		local ok, err = teleports.toHub(list, data)
		if not ok then
			warn(`OpenFront: return teleport failed: {err}`)
		end
	end)
end

local function stepMatch(match: Match)
	local t0 = os.clock()
	match.runner:step()
	local game = match.runner.game
	local public = match.replicator:collect()
	local messages = game:drainMessages()
	if not game:inSpawnPhase() and match.wonAt == nil then
		for player in match.members do
			local p = game:playerByClientID(keyOf(player))
			if p ~= nil and p:isAlive() then
				local ticks = (match.aliveTicks[player] or 0) + 1
				match.aliveTicks[player] = ticks
				-- (analytics: alive 3 and 10 minutes; 10 ticks a second)
				if ticks == 1800 or ticks == 6000 then
					Analytics.played(player, match.matchesBefore[player] or 1, ticks // 600, match.id)
				end
			end
		end
	end
	for player in match.members do
		remotes.Tick:FireClient(player, match.replicator:forViewer(public, keyOf(player), messages))
		local logged = match.logged[player]
		if logged and not logged.spawned then
			local p = game:playerByClientID(keyOf(player))
			if p ~= nil and p:numTilesOwned() > 0 then
				logged.spawned = true
				Analytics.spawned(player, match.matchesBefore[player] or 1, match.id)
			end
		end
	end
	-- Spectators get the public part only (no one's private diplomacy).
	local watched = if next(match.spectators) ~= nil then match.replicator:forViewer(public, nil, nil) else nil
	for player in match.spectators do
		remotes.Tick:FireClient(player, watched)
	end
	if match.wonAt == nil and game:getWinner() ~= nil then
		match.wonAt = os.clock()
		for player in match.members do
			pcall(payStars, match, player)
		end
	end
	local ms = (os.clock() - t0) * 1000
	match.stepMean = match.stepMean * 0.95 + ms * 0.05
	match.stepWorst = math.max(match.stepWorst, ms)
	if os.clock() - match.stepWindowAt >= 10 then
		match.stepWorstLast, match.stepWorst, match.stepWindowAt = match.stepWorst, 0, os.clock()
	end
end

local function everyMatch(): { Match }
	local list = {}
	for _, m in publicMatches do
		table.insert(list, m)
	end
	for _, m in soloMatches do
		table.insert(list, m)
	end
	return list
end

-- A hub's lobbies: the shared list, the line, Studio's local lobbies
-- starting, and seats that lapsed.
local function hubStep(dt: number)
	local dir = directory :: LobbyDirectory.Directory
	if SharedClock.ready() then
		dir:tick(dt, task.spawn)
	end
	dir:tickQueue(dt, task.spawn)
	local now = clock()
	for id, entry in localLobbies do
		if now >= entry.lobby.starts then
			localLobbies[id] = nil
			local present = {}
			for _, p in entry.members do
				if p.Parent ~= nil and pending[p] and pending[p].lobby == id then
					pending[p] = nil
					table.insert(present, p)
				end
			end
			local match = if #present > 0 then startPublic(id, entry.lobby.kind, present, entry.lobby.config) else nil
			if match then
				match.beatAt = os.clock()
				touchLocalLobby(id, #present, true)
			end
		end
	end
	for p, info in pending do
		if info.sent and os.clock() - info.at > SENT_TIMEOUT then
			pending[p] = nil
		end
	end
	-- Studio's local matches keep their records fresh (listed to watch).
	for id, match in publicMatches do
		if match.beatAt and match.endedAt == nil and os.clock() - match.beatAt >= PublicLobbies.LIVE_BEAT_S then
			match.beatAt = os.clock()
			local n = 0
			for _ in match.members do
				n += 1
			end
			touchLocalLobby(id, n, false)
		end
	end
end

-- A match server: its lobby record, who is here, the start, late arrivals.
local rosterAt = 0
local function hostStep(dt: number)
	local h = host :: MatchHost.Host
	h:tick(dt, task.spawn)
	local l = h.lobby
	if os.clock() - rosterAt >= 1 then
		rosterAt = os.clock()
		local uids = {}
		for _, p in Players:GetPlayers() do
			local m = matchOf[p]
			if not spectating[p] and soloMatches[p] == nil and (m == nil or m.members[p]) then
				table.insert(uids, keyOf(p))
			end
		end
		h:setRoster(uids)
	end
	if l == nil then
		return
	end
	local match = publicMatches[l.id]
	if not h.started then
		local here = waitingHere()
		if #here > 0 and h:startsIn() == 0 then
			h.started = true
			task.spawn(function()
				h:start(#here)
			end)
			startPublic(l.id, l.kind, here, l.config)
		end
	elseif match and match.endedAt == nil then
		-- arrivals after the start, and spectators, watch
		for _, p in Players:GetPlayers() do
			if matchOf[p] == nil and soloMatches[p] == nil and not leaving[p] then
				watch(match, p)
			end
		end
	end
end

-- The lobbies this server knows of: a hub's list, or on a match server the
-- store read now and then (for "Next match in").
local knownLobbies: { PublicLobbies.Lobby } = {}
local knownAt = -math.huge
local knownBusy = false
local function lobbyList(): { PublicLobbies.Lobby }
	local dir = directory
	if dir then
		return dir:lobbies()
	end
	if os.clock() - knownAt >= 10 and not knownBusy then
		knownBusy, knownAt = true, os.clock()
		task.spawn(function()
			local ok, list = pcall(store.list)
			if ok then
				local out = {}
				for _, v in list do
					local l = PublicLobbies.decode(v)
					if l then
						table.insert(out, l)
					end
				end
				knownLobbies = out
			end
			knownBusy = false
		end)
	end
	return knownLobbies
end

-- Seconds until the next public match a player of `kind` could join, or nil.
local function nextLobbyIn(kind: string): number?
	local now = clock()
	local best: number? = nil
	local kinds = PublicLobbies.takesFrom(kind)
	for _, l in lobbyList() do
		if table.find(kinds, l.kind) and PublicLobbies.joinable(l, now) then
			local s = l.starts - now
			if best == nil or s < (best :: number) then
				best = s
			end
		end
	end
	return if best then math.max(0, math.floor(best)) else nil
end

-- After a public match is won, its players hear (every few seconds) when the
-- next one of its kind starts: the result card's "Next match in 0:21".
local NEXT_INTERVAL = 5
local function announceNext(match: Match)
	local kind = match.kind
	if not match.public or match.wonAt == nil or match.endedAt ~= nil or kind == nil then
		return
	end
	if os.clock() - (match.nextAt or -math.huge) < NEXT_INTERVAL then
		return
	end
	match.nextAt = os.clock()
	local seconds = nextLobbyIn(kind)
	for player in match.members do
		remotes.Status:FireClient(player, { phase = "next", kind = kind, seconds = seconds })
	end
end

-- Server health telemetry (Analytics.serverHealth): Heartbeat frames are
-- counted for a minute, then each running match with players logs once.
local HEALTH_INTERVAL = 60
local healthFrames, healthSince = 0, os.clock()

local function sampleHealth()
	healthFrames += 1
	local elapsed = os.clock() - healthSince
	if elapsed < HEALTH_INTERVAL then
		return
	end
	local fps = healthFrames / elapsed
	healthFrames, healthSince = 0, os.clock()
	local all = everyMatch()
	for _, match in all do
		local someone = next(match.members)
		if match.endedAt == nil and someone ~= nil then
			local kind = if match.public then "public" elseif serverRole == WaitingRoom.ROLE_HUB then "hub-solo" else "solo"
			Analytics.serverHealth(someone, match.mapName, kind, #all, fps, match.stepMean, math.max(match.stepWorst, match.stepWorstLast))
		end
	end
end

local function onHeartbeat(dt: number)
	sampleHealth()
	if directory then
		hubStep(dt)
	end
	if host then
		hostStep(dt)
	end
	if os.clock() - menuAt >= MENU_INTERVAL then
		menuAt = os.clock()
		sendMenu()
	end
	for _, match in everyMatch() do
		announceNext(match)
		-- After a win the match runs on until everyone has left (then it is
		-- cleaned up at once) or the keep-playing limit passes.
		if match.wonAt ~= nil and match.endedAt == nil then
			if next(match.members) == nil then
				match.endedAt = os.clock() - RESULTS_SECONDS
			elseif os.clock() - match.wonAt >= KEEP_PLAYING_SECONDS then
				match.endedAt = os.clock()
			end
		end
		if match.filmHold then
			match.accum = 0 -- (Studio filming: frozen between shots)
		elseif match.endedAt == nil and match.runner:isPaused() then
			match.accum = 0
			-- Turns stop while paused; the unpause intent restarts them.
		elseif match.endedAt == nil then
			match.accum = math.min(match.accum + dt, TICK * MAX_STEPS_PER_FRAME)
			while match.accum >= TICK do
				match.accum -= TICK
				local ok, err = pcall(stepMatch :: any, match)
				if not ok then
					-- One failing match must not stop the others (or retry every
					-- frame): end it; its players go back to the menu after the
					-- results delay.
					warn(`OpenFront: match {match.id} stopped: {err}`)
					match.endedAt = os.clock()
					break
				end
			end
		elseif os.clock() - (match.endedAt :: number) >= RESULTS_SECONDS then
			-- Back to the menu (a match server: back to a hub); a public
			-- match's lobby record goes.
			local everyone = {}
			for player in match.members do
				matchOf[player] = nil
				table.insert(everyone, player)
				remotes.Status:FireClient(player, { phase = "menu" })
			end
			for player in match.spectators do
				matchOf[player] = nil
				table.insert(everyone, player)
				remotes.Status:FireClient(player, { phase = "menu" })
			end
			local lobbyId = match.queue
			if lobbyId and publicMatches[lobbyId] == match then
				publicMatches[lobbyId] = nil
				local h = host
				if h and h.lobby and h.lobby.id == lobbyId then
					task.spawn(function()
						h:finish()
					end)
					sendToHub(everyone)
				else
					task.spawn(function()
						pcall(store.remove, lobbyId)
					end)
				end
			end
			for player, m in soloMatches do
				if m == match then
					soloMatches[player] = nil
				end
			end
			-- A solo server's match is over: back to a hub.
			if serverRole == WaitingRoom.ROLE_SOLO and match.queue == nil then
				sendToHub(everyone)
			end
		end
	end
end

-- Studio-only: the live matches, for MCP checks.
function OpenFrontServer.debugMatches(): { any }
	return everyMatch()
end

local function onStart(player: Player, request: any)
	if type(request) ~= "table" or not take(limitsOf(player).start) then
		return
	end
	if request.mode == "solo" then
		if request.tutorial == true then
			-- The tutorial's match is always the same (Shared/Tutorial).
			request = { mode = "solo", map = Tutorial.MAP, difficulty = Tutorial.DIFFICULTY, tutorial = true }
		end
		startSolo(player, request)
	elseif request.mode == "ready" then
		-- A solo server's client has loaded: its match starts now.
		local want = soloWanted[player]
		if want ~= nil and matchOf[player] == nil then
			soloWanted[player] = nil
			startSoloHere(player, want)
		end
	elseif request.mode == "queue" and type(request.id) == "string" then
		-- (a match server's players are already in its lobby)
		if matchOf[player] == nil and directory ~= nil then
			publicJoin(player, request.id)
		end
	elseif request.mode == "unqueue" then
		local h = host
		if h then
			-- leaving a match server's waiting room: back to a hub, unless the
			-- match is about to start (LEAVE is closed then)
			local s = h:startsIn()
			if h.lobby and not h.started and s ~= nil and s <= WaitingRoom.LEAVE_LOCK_S then
				return
			end
			sendToHub({ player })
		else
			for _, k in partyInMenu(player) do
				local p = playerOfKey(k)
				if p then
					leaveLobby(p)
				end
			end
		end
		sendMenu()
	elseif request.mode == "watch" and type(request.id) == "string" then
		if matchOf[player] == nil then
			publicWatch(player, request.id)
		end
	elseif request.mode == "leave" then
		-- Exit Game: as if they left (AFK in a public match, a solo match
		-- stops), then back to the menu; on a match server, back to a hub.
		local wasPublic = matchOf[player] ~= nil and (matchOf[player] :: Match).public
		leaveMatch(player)
		remotes.Status:FireClient(player, { phase = "menu" })
		if (host and wasPublic) or serverRole == WaitingRoom.ROLE_SOLO then
			sendToHub({ player })
		end
		sendMenu()
	elseif request.mode == "again" then
		-- PLAY AGAIN on a public match's result card (Bruno, 2026-11-12):
		-- leave it as with EXIT, then join the next public match of its kind,
		-- from here (Studio) or on arriving at a hub. (A solo match's PLAY
		-- AGAIN is a "solo" request: a new match on its own server.)
		local m = matchOf[player]
		local kind = if m ~= nil and m.public then m.kind else nil
		leaveMatch(player)
		remotes.Status:FireClient(player, { phase = "menu" })
		if host or serverRole == WaitingRoom.ROLE_SOLO then
			sendToHub({ player }, kind)
		elseif kind then
			publicJoin(player, kind)
		end
		sendMenu()
	end
end

local function onParty(player: Player, request: any)
	if type(request) ~= "table" or not take(limitsOf(player).party) then
		return
	end
	local key = keyOf(player)
	if request.op == "invite" and type(request.userId) == "number" then
		local other = Players:GetPlayerByUserId(request.userId)
		if other and other ~= player and parties:invite(key, keyOf(other)) then
			remotes.Party:FireClient(other, { op = "invited", userId = player.UserId, name = player.DisplayName })
		end
	elseif request.op == "accept" and type(request.userId) == "number" then
		if parties:accept(key, tostring(request.userId)) then
			-- Joining a party leaves any lobby; the leader joins for everyone.
			leaveLobby(player)
		end
	elseif request.op == "leave" then
		parties:leave(key)
	end
	sendMenu()
end

-- User ids from teleport data (strings, MAX_SIZE at most), or nil.
local function uidList(v: any): { string }?
	if type(v) ~= "table" then
		return nil
	end
	local uids = {}
	for _, u in v do
		if type(u) == "string" and #u <= 24 and #uids < Parties.MAX_SIZE then
			table.insert(uids, u)
		end
	end
	return if #uids > 0 then uids else nil
end

-- Someone arrived by teleport: who came to watch (a match server), and who
-- was in their party. The party is formed again from the members here now
-- (each arrival re-forms it, so it grows as they land). Teleport data:
-- hub -> match server { party = { uids, ... }, spectate? }; match server ->
-- hub { parties = { { uids }, ... } }.
local function onArrival(player: Player)
	local ok, data = pcall(function(): any
		return player:GetJoinData().TeleportData
	end)
	if not ok or type(data) ~= "table" then
		return
	end
	if isMatchServer and data.spectate == true then
		spectating[player] = true
	end
	if serverRole == WaitingRoom.ROLE_SOLO and type(data.solo) == "table" then
		soloWanted[player] = { map = data.solo.map, difficulty = data.solo.difficulty, tutorial = data.solo.tutorial == true }
	end
	-- PLAY AGAIN from a public match: join the next one of its kind, once
	-- their party (below) has re-formed and the menu has loaded.
	if serverRole == WaitingRoom.ROLE_HUB and type(data.queue) == "string" and PublicLobbies.isKind(data.queue) then
		local kind = data.queue
		task.delay(QUEUE_ON_ARRIVAL_S, function()
			if player.Parent ~= nil and matchOf[player] == nil then
				publicJoin(player, kind)
			end
		end)
	end
	local key = keyOf(player)
	local group: { string }? = nil
	if type(data.party) == "table" then
		group = uidList(data.party.uids)
	elseif type(data.parties) == "table" then
		for _, g in data.parties do
			local uids = uidList(g)
			if uids and table.find(uids, key) then
				group = uids
				break
			end
		end
	end
	if group == nil or table.find(group, key) == nil then
		return
	end
	if isMatchServer then
		for _, u in group do
			arrivedParty[u] = group
		end
	end
	local here = {}
	for _, u in group do
		if playerOfKey(u) ~= nil then
			table.insert(here, u)
		end
	end
	if #here > 1 then
		parties:form(here)
	end
end

-- The store, the shared clock, teleports, and this server's role (a hub's
-- directory or a match server's host). Studio: a local store and stand-in
-- teleports, so a hub plays its lobbies itself.
local function startLobbies()
	if RunService:IsStudio() then
		SharedClock._givenUp = true -- (one server: its own clock)
		store = LobbyStore.localstore(clock)
		teleports = Teleports.studio()
	else
		SharedClock.start(print)
		local ok, live = pcall(LobbyStore.memory, game.JobId, clock)
		if ok then
			store = live
		else
			warn(`[Lobbies] MemoryStore unavailable, using a local store: {live}`)
			store = LobbyStore.localstore(clock)
		end
		teleports = Teleports.live(game.PlaceId)
	end
	-- A reserved server is a public lobby's or one player's solo server: its
	-- first arrival's teleport data says which.
	local function decideRole(player: Player)
		if serverRole ~= nil then
			return
		end
		local ok, data = pcall(function(): any
			return player:GetJoinData().TeleportData
		end)
		if ok and type(data) == "table" and type(data.solo) == "table" then
			serverRole = WaitingRoom.ROLE_SOLO
		else
			serverRole = WaitingRoom.ROLE_MATCH
			host = MatchHost.new({ store = store, psid = game.PrivateServerId, now = clock, log = print })
		end
		ReplicatedStorage:SetAttribute(WaitingRoom.ROLE_ATTRIBUTE, serverRole)
	end
	local function arrived(player: Player)
		decideRole(player)
		onArrival(player)
	end
	Players.PlayerAdded:Connect(arrived)
	for _, p in Players:GetPlayers() do
		arrived(p)
	end
	if isMatchServer then
		return
	end
	directory = LobbyDirectory.new({
		store = store,
		teleport = teleports,
		config = function(kind: string): { [string]: any }
			local cfg = playlist:gameConfig(if kind == PublicLobbies.KIND_TEAM then "team" else "ffa", if kind == PublicLobbies.KIND_WORLD then "World" else nil)
			if kind == PublicLobbies.KIND_BLITZ then
				-- OpenFront's max timer (WinCheckExecution): the most land wins then.
				cfg.maxTimerValue = PublicLobbies.BLITZ_MINUTES
			elseif kind == PublicLobbies.KIND_TEAM and PublicLobbies.TEAM_NATIONS then
				-- AI nations on the teams (TeamAssignment shares them out).
				cfg.nations = "default"
			end
			return cfg
		end,
		now = clock,
		rand = function(): number
			return rng:NextNumber()
		end,
		newId = function(): string
			return HttpService:GenerateGUID(false)
		end,
		worldAvailable = worldAvailable,
		-- (never more seats than a server holds; Studio's MaxPlayers isn't the place's)
		serverSize = function(): number?
			return if RunService:IsStudio() then nil else Players.MaxPlayers
		end,
		wait = task.wait,
		log = print,
	})
	if not RunService:IsStudio() then
		-- a teleport that failed after it began: the seat goes back
		game:GetService("TeleportService").TeleportInitFailed:Connect(function(player: Player, result: Enum.TeleportResult)
			if result == Enum.TeleportResult.IsTeleporting then
				return
			end
			-- A solo teleport that failed: the match runs here instead.
			local solo = soloSent[player]
			if solo ~= nil then
				soloSent[player] = nil
				warn("[Solo] teleport failed; playing on the hub")
				startSoloHere(player, solo)
				return
			end
			local p = pending[player]
			if p == nil or not p.sent then
				return
			end
			pending[player] = nil
			local id = p.lobby
			local dir = directory
			if id and dir then
				task.spawn(function()
					dir:release(id, { keyOf(player) })
				end)
			end
			remotes.Status:FireClient(player, { phase = "menu", notice = "Couldn't reach that match. Try again." })
		end)
	end
end

function OpenFrontServer.start()
	Players.CharacterAutoLoads = false
	-- Clients can't read game.PrivateServerId: tell them which kind of server
	-- this is (the waiting room shows on a match server from the first frame).
	-- (a reserved server sets it once its first arrival says what it is for)
	if serverRole ~= nil then
		ReplicatedStorage:SetAttribute(WaitingRoom.ROLE_ATTRIBUTE, serverRole)
	end
	local folder = Instance.new("Folder")
	folder.Name = "OpenFrontRemotes"
	for _, name in REMOTES do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		remotes[name] = remote
	end
	local query = Instance.new("RemoteFunction")
	query.Name = "Query"
	query.OnServerInvoke = function(player: Player, request: any): any
		local match = matchOf[player]
		if type(request) ~= "table" or match == nil or match.replicator == nil or not match.members[player] then
			return nil
		end
		local l = limitsOf(player)
		if not take(l.query) then
			return nil
		end
		-- Each player's queries also share a budget of server time (audit F7:
		-- a Hydrogen Bomb preview costs tens of ms, and 40 a second were
		-- allowed): QUERY_MS_PER_S a second, QUERY_MS_BURST at once.
		local budget = l.queryMs
		local now = os.clock()
		budget.tokens = math.min(budget.size, budget.tokens + (now - budget.at) * budget.size / budget.per)
		budget.at = now
		if budget.tokens <= 0 then
			return nil
		end
		local function answer(): any
			if request.kind == "actions" then
				local tile = if type(request.tile) == "number" then request.tile else nil
				local other = if type(request.other) == "number" then request.other else nil
				return match.runner:playerActions(keyOf(player), tile, other, request.buildables == true)
			elseif request.kind == "profile" and type(request.other) == "number" then
				return match.runner:playerProfile(keyOf(player), request.other)
			elseif request.kind == "takeover" then
				-- The Arsenal's Takeover: spend a saved one (else the client
				-- prompts the 25 R$ product and asks again once it's granted),
				-- then command the nation that eliminated you, from a fresh
				-- snapshot.
				local key = keyOf(player)
				if match.runner:takeoverTarget(key) == nil then
					return { ok = false, reason = "gone" }
				end
				if not Store.spendTakeover(player) then
					return { ok = false, reason = "needPurchase" }
				end
				if not match.runner:takeOver(key) then
					Store.refundTakeover(player)
					return { ok = false, reason = "gone" }
				end
				remotes.Snapshot:FireClient(player, match.replicator:snapshot(key))
				return { ok = true }
			elseif request.kind == "build_preview" and type(request.unit) == "string" then
				local tile = if type(request.tile) == "number" then request.tile else nil
				return match.runner:buildPreview(keyOf(player), tile, request.unit)
			end
			return nil
		end
		local result = answer()
		budget.tokens -= (os.clock() - now) * 1000
		return result
	end
	query.Parent = folder
	-- Published before the store starts (its DataStore probe can take
	-- seconds; clients wait on this folder).
	folder.Parent = ReplicatedStorage
	Store.start(folder)
	-- An Arsenal weapon unlocked (stars or Robux) while in a match is usable
	-- in it at once (Bruno, 2026-11-08: before, only the next match had it).
	Store.onChanged(function(player: Player)
		local match = matchOf[player]
		if match == nil or match.runner.game == nil then
			return
		end
		local p = match.runner.game:playerByClientID(keyOf(player))
		if p == nil then
			return
		end
		local info = table.clone(p.playerInfo)
		info.weapons = Store.loadout(player).weapons
		p.playerInfo = info
	end)
	-- A leaving player's match pays its stars before the store's last save.
	Store.onLeaving(function(player: Player)
		leaveMatch(player)
	end)
	CrateModels.start()
	-- The menu draws World behind it.
	if available.World then
		publishMap("World")
	end

	remotes.Start.OnServerEvent:Connect(onStart)
	remotes.Party.OnServerEvent:Connect(onParty)
	remotes.Intent.OnServerEvent:Connect(function(player: Player, intent: any)
		local match = matchOf[player]
		if match == nil or match.replicator == nil or not match.members[player] then
			return
		end
		local l = limitsOf(player)
		if not take(l.second) or not take(l.minute) then
			remotes.IntentResult:FireClient(player, { ok = false, reason = "rateLimited", type = type(intent) == "table" and intent.type or nil })
			return
		end
		local ok, reason = match.runner:intent(keyOf(player), intent)
		if not ok then
			remotes.IntentResult:FireClient(player, { ok = false, reason = reason, type = type(intent) == "table" and intent.type or nil })
		elseif ATTACKS[intent.type] then
			-- (analytics: the first order on land, a neighbour or a coast)
			local logged = match.logged[player]
			local game = match.runner.game
			if logged and not logged.attack and game and not game:inSpawnPhase() then
				logged.attack = true
				Analytics.attacked(player, match.matchesBefore[player] or 1, os.clock() - (match.startedAt or os.clock()), match.id)
			end
		end
	end)
	-- The tutorial's reports (Ui/OpenFront/TutorialController): funnel steps,
	-- Skip, the City's gold, coach tips seen. Stars and gold only in a
	-- tutorial match.
	remotes.Tutorial.OnServerEvent:Connect(function(player: Player, msg: any)
		if type(msg) ~= "table" or type(msg.op) ~= "string" or not take(limitsOf(player).tutorial) then
			return
		end
		local match = matchOf[player]
		local inTutorial = match ~= nil and match.members[player] == true and match.runner.gameConfig.tutorial == true
		if msg.op == "tip" and type(msg.id) == "string" then
			Store.tipSeen(player, msg.id)
		elseif msg.op == "step" and inTutorial and type(msg.n) == "number" then
			local n = math.floor(msg.n)
			local name = Tutorial.FUNNEL[n]
			if name == nil then
				return
			end
			Analytics.tutorialStep(player, (match :: Match).id, n, name, msg.passed == true)
			if n == #Tutorial.FUNNEL then
				Store.payTutorial(player, Tutorial.STARS)
				Store.setTutorial(player, "done")
			end
		elseif msg.op == "skip" and inTutorial and type(msg.n) == "number" then
			Analytics.tutorialSkipped(player, math.floor(msg.n))
			Store.setTutorial(player, "skipped")
			if match then
				match.runner:releaseAiHold()
			end
		elseif msg.op == "left" and inTutorial then
			Store.setTutorial(player, "left")
		elseif msg.op == "cityGold" and inTutorial and match and not match.tutorialGold[player] then
			match.tutorialGold[player] = true
			match.runner:tutorialGold(keyOf(player))
		end
	end)
	Store.onLoaded(function(player: Player)
		Analytics.joined(player, Store.matchesOf(player), Store.tutorialOf(player))
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		Analytics.left(player)
		leaveMatch(player)
		leaveLobby(player)
		parties:remove(keyOf(player))
		limits[player] = nil
		spectating[player] = nil
		leaving[player] = nil
		soloWanted[player] = nil
		soloSent[player] = nil
	end)
	startLobbies()
	if RunService:IsStudio() then
		-- Studio-only probe for MCP checks: returns a summary of each match.
		-- Invoke("gold", n) first gives every human n gold (build checks);
		-- Invoke("win") makes the first human win.
		local probe = Instance.new("BindableFunction")
		probe.Name = "OpenFrontDebugServer"
		probe.OnInvoke = function(code: string?, amount: number?)
			-- Invoke("profile", seconds): where the first match's server
			-- ticks go (sim step, name placement, replication), in ms.
			if code == "profile" and type(amount) == "number" then
				local match = everyMatch()[1]
				if match == nil or match.replicator == nil then
					return nil
				end
				local times: { [string]: { number } } = {}
				local undo = {}
				local function wrap(obj: any, key: string, bucket: string)
					local own = rawget(obj, key)
					local original = obj[key]
					times[bucket] = times[bucket] or {}
					obj[key] = function(...)
						local t = os.clock()
						local r = table.pack(original(...))
						table.insert(times[bucket], (os.clock() - t) * 1000)
						return table.unpack(r, 1, r.n)
					end
					table.insert(undo, function()
						obj[key] = own
					end)
				end
				local g = match.runner.game
				wrap(match.runner, "step", "runner.step")
				wrap(g, "executeNextTick", "game.executeNextTick")
				wrap(match.replicator, "collect", "replicator.collect")
				wrap(match.replicator, "forViewer", "replicator.forViewer")
				wrap(match.runner.names, "update", "names.update")
				-- Every execution class's tick (nation AI, attacks, tribes...).
				for _, ms in OF.Executions:GetDescendants() do
					if ms:IsA("ModuleScript") then
						local ok, mod = pcall(require, ms)
						if ok and type(mod) == "table" and type(rawget(mod, "tick")) == "function" then
							wrap(mod, "tick", "exec." .. ms.Name)
						end
						-- The nation AI's behaviours, function by function (inclusive).
						if ok and type(mod) == "table" and (ms.Name == "AiAttackBehavior" or string.sub(ms.Name, 1, 6) == "Nation") and ms.Name ~= "NationExecution" then
							for key, value in mod do
								if type(value) == "function" and key ~= "new" then
									wrap(mod, key, ms.Name .. "." .. key)
								end
							end
						end
					end
				end
				task.wait(amount)
				for _, u in undo do
					u()
				end
				local out = { tick = g:ticks() }
				for k, list in times do
					table.sort(list)
					local sum = 0
					for _, v in list do
						sum += v
					end
					out[k] = { n = #list, mean = if #list > 0 then sum / #list else 0, p95 = list[math.max(1, math.ceil(#list * 0.95))], max = list[#list] }
				end
				return out
			end
			if code == "gold" and type(amount) == "number" then
				for _, m in everyMatch() do
					for _, p in m.runner.game:allPlayers() do
						if p:type() == "HUMAN" then
							p:addGold(amount)
						end
					end
				end
			end
			-- Invoke("weapons"): every human gets every Arsenal weapon for this
			-- match only (profiles untouched), to test them without stars.
			if code == "weapons" then
				for _, m in everyMatch() do
					for _, p in m.runner.game:allPlayers() do
						if p:type() == "HUMAN" then
							local all = table.clone(p.playerInfo.weapons or {})
							for _, key in ArsenalUnits.KEYS do
								all[key] = true
							end
							p.playerInfo.weapons = all
						end
					end
				end
			end
			-- Invoke("try", unitType): the first human of the first match sends
			-- `unitType` (any Arsenal item) through the real intent path at the
			-- nearest place it's allowed: an enemy structure for Sabotage, else
			-- the nearest tile (own land first) where canBuild agrees. Returns
			-- the tile and its owner, or nil.
			if code == "try" and type(amount) == "string" then
				local m = everyMatch()[1]
				local g = m and m.runner.game
				local human
				for _, p in if g then g:allPlayers() else {} do
					if p:type() == "HUMAN" and p:isAlive() then
						human = p
						break
					end
				end
				if human == nil or human:spawnTile() == nil then
					return nil
				end
				local home = human:spawnTile()
				local candidates = {}
				if amount == "Sabotage" then
					for _, u in g:units(table.unpack((require(OF:WaitForChild("GameTypes")) :: any).Structures)) do
						if u:owner() ~= human and u:owner():isPlayer() then
							table.insert(candidates, u:tile())
						end
					end
				else
					for _, t in human:tiles():values() do
						-- (Coastal Battery: shore tiles only.)
						if amount ~= "Coastal Battery" or g:isShore(t) then
							table.insert(candidates, t)
						end
					end
				end
				table.sort(candidates, function(a, b)
					return g:euclideanDistSquared(a, home) < g:euclideanDistSquared(b, home)
				end)
				-- (The nearest 150 only: a check per tile adds up on big land.)
				for i, t in candidates do
					if i > 150 then
						break
					end
					if human:canBuild(amount, t) ~= false then
						m.runner:intent(human:clientID() :: string, { type = "build_action", unit = amount, tile = t, troops = human:troops() * 0.2 })
						return { tile = t, owner = g:owner(t):displayName() }
					end
				end
				return nil
			end
			-- Invoke("drop", d): the first human of the first match gets a City
			-- at its capital (if it has none) and sends Paratroopers through the
			-- real intent path at the nearest nation land about d tiles away
			-- (default 70). Returns the target and the preview.
			if code == "drop" then
				local m = everyMatch()[1]
				local g = m and m.runner.game
				local human
				for _, p in if g then g:allPlayers() else {} do
					if p:type() == "HUMAN" and p:isAlive() then
						human = p
						break
					end
				end
				if human == nil or human:spawnTile() == nil then
					return nil
				end
				local home = human:spawnTile()
				if #human:units("City") == 0 then
					human:buildUnit("City", home, {})
				end
				local want = amount or 70
				local best, bestErr = nil, math.huge
				for _, p in g:allPlayers() do
					if p ~= human and p:isAlive() and p:type() == "NATION" then
						for _, t in p:borderTiles():values() do
							local d = math.sqrt(g:euclideanDistSquared(t, home))
							if math.abs(d - want) < bestErr then
								best, bestErr = t, math.abs(d - want)
							end
						end
					end
				end
				if best == nil then
					return nil
				end
				local id = human:clientID() :: string
				local preview = m.runner:buildPreview(id, best, "Paratroopers")
				m.runner:intent(id, { type = "build_action", unit = "Paratroopers", tile = best, troops = human:troops() * 0.2 })
				return { target = best, owner = g:owner(best):displayName(), paraAim = preview and preview.paraAim }
			end
			-- Invoke("troops", n): every human's troops set to n (stored units,
			-- ten times what's shown), to grow big fast for performance checks.
			if code == "troops" and type(amount) == "number" then
				for _, m in everyMatch() do
					for _, p in m.runner.game:allPlayers() do
						if p:type() == "HUMAN" then
							p:setTroops(amount)
						end
					end
				end
			end
			-- Invoke("conquer", n): the first human of the first match takes the n
			-- nations nearest its capital whole, in one tick each call
			-- (HumanProtection.surrender's path): big conquest bursts for
			-- performance checks.
			if code == "conquer" and type(amount) == "number" then
				local m = everyMatch()[1]
				local g = m and m.runner.game
				local human
				for _, p in if g then g:allPlayers() else {} do
					if p:type() == "HUMAN" and p:isAlive() then
						human = p
						break
					end
				end
				if human and human:spawnTile() then
					local home = human:spawnTile()
					local nations = {}
					for _, p in g:allPlayers() do
						if p ~= human and p:isAlive() and p:type() == "NATION" and p:spawnTile() then
							table.insert(nations, p)
						end
					end
					table.sort(nations, function(x, y)
						return g:manhattanDist(x:spawnTile(), home) < g:manhattanDist(y:spawnTile(), home)
					end)
					local taken = 0
					for i = 1, math.min(amount, #nations) do
						taken += nations[i]:numTilesOwned()
						HumanProtection.surrender(g, nations[i], human)
					end
					return { conquered = math.min(amount, #nations), tiles = taken, humanTiles = human:numTilesOwned() }
				end
			end
			-- Invoke("lose"): the first match's first member surrenders to the
			-- biggest living nation and gets one saved Takeover (checks the
			-- TAKE OVER plate and the in-place takeover).
			if code == "lose" then
				local match = everyMatch()[1]
				if match then
					local g = match.runner.game
					for player in match.members do
						local me = g:playerByClientID(keyOf(player))
						local best = nil
						for _, p in g:allPlayers() do
							if p:type() == "NATION" and p:isAlive() and (best == nil or p:numTilesOwned() > best:numTilesOwned()) then
								best = p
							end
						end
						if me and best then
							HumanProtection.surrender(g, me, best)
							Store.refundTakeover(player)
						end
						break
					end
				end
			end
			-- Invoke("win"): the first human of each running match wins now
			-- (checks the result card and "Keep playing").
			if code == "win" then
				for _, m in everyMatch() do
					local g = m.runner.game
					if g:getWinner() == nil then
						for _, p in g:allPlayers() do
							if p:type() == "HUMAN" then
								g:setWinner(p)
								break
							end
						end
					end
				end
			end
			local out = {}
			for _, m in everyMatch() do
				local g = m.runner.game
				local humans = {}
				for _, p in g:allPlayers() do
					if p:type() == "HUMAN" then
						table.insert(humans, { name = p:name(), tiles = p:numTilesOwned(), troops = p:troops(), spawned = p:hasSpawned() })
					end
				end
				table.insert(out, {
					id = m.id,
					public = m.public,
					queue = m.queue,
					tick = g:ticks(),
					startTick = g.startTick,
					players = #g:allPlayers(),
					humans = humans,
					queued = #m.runner.queued,
					winner = m.wonAt ~= nil,
					stepMeanMs = m.stepMean,
					stepWorstMs = math.max(m.stepWorst, m.stepWorstLast),
				})
			end
			return out
		end
		probe.Parent = ServerStorage
		-- Filming the page video (Server/Filming): its first match's first
		-- member is the one on camera.
		require(script.Parent.Filming).start({
			focus = function(): (any?, Player?, any?, string?)
				local match = everyMatch()[1]
				if match == nil or match.replicator == nil then
					return nil, nil, nil, nil
				end
				for player in match.members do
					local id = keyOf(player)
					return match, player, match.runner.game:playerByClientID(id), id
				end
				return nil, nil, nil, nil
			end,
		})
	end
	RunService.Heartbeat:Connect(onHeartbeat)
end

return OpenFrontServer
