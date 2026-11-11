--!strict
-- Ported from OpenFront v0.35.2 (packages/engine/src/GameRunner.ts and execution/ExecutionManager.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Runs one OpenFront match on the server.
--   - Humans join while the lobby is open. start() builds the game exactly as
--     createGameRunner does: human ids from PseudoRandom(simpleHash(gameID)),
--     then GameRunner.init's executions.
--   - Each step turns the intents queued since the last tick into executions
--     (Executor.createExec), then runs one tick. Diplomacy intents are all
--     here; toggle_pause and the lobby-only intents are not.
--   - Pure: no Roblox services, so Lune tests drive it.
-- Not ported (web-only): turn hashes/desync checks, snapshots, ranked.

local ArsenalUnits = require(script.Parent.ArsenalUnits)
local Emoji = require(script.Parent.Data.Emoji)
local EngineConfig = require(script.Parent.EngineConfig)
local Game = require(script.Parent.Game)
local GameTypes = require(script.Parent.GameTypes)
local MapLoader = require(script.Parent.MapLoader)
local NameBoxCalculator = require(script.Parent.NameBoxCalculator)
local NationCreation = require(script.Parent.NationCreation)
local PseudoRandom = require(script.Parent.PseudoRandom)
local QuickChat = require(script.Parent.Data.QuickChat)
local Util = require(script.Parent.Util)
local Executions = script.Parent.Executions
local AllianceExtensionExecution = require(Executions.AllianceExtensionExecution)
local AllianceRejectExecution = require(Executions.AllianceRejectExecution)
local AllianceRequestExecution = require(Executions.AllianceRequestExecution)
local AttackExecution = require(Executions.AttackExecution)
local BoatRetreatExecution = require(Executions.BoatRetreatExecution)
local BreakAllianceExecution = require(Executions.BreakAllianceExecution)
local ConstructionExecution = require(Executions.ConstructionExecution)
local DeleteUnitExecution = require(Executions.DeleteUnitExecution)
local DonateExecution = require(Executions.DonateExecution)
local DoomsdayClockExecution = require(Executions.DoomsdayClockExecution)
local EmbargoExecution = require(Executions.EmbargoExecution)
local EmojiExecution = require(Executions.EmojiExecution)
local RecomputeRailClusterExecution = require(Executions.RecomputeRailClusterExecution)
local MoveWarshipExecution = require(Executions.MoveWarshipExecution)
local NukeExecution = require(Executions.NukeExecution)
local StrikeExecution = require(Executions.StrikeExecution)
local PauseExecution = require(Executions.PauseExecution)
local NationExecution = require(Executions.NationExecution)
local RetreatExecution = require(Executions.RetreatExecution)
local SocialExecutions = require(Executions.SocialExecutions)
local SpawnExecution = require(Executions.SpawnExecution)
local SpawnTimerExecution = require(Executions.SpawnTimerExecution)
local DeployCountdownExecution = require(Executions.DeployCountdownExecution)
local AutoSpawnExecution = require(Executions.AutoSpawnExecution)
local TransportShipExecution = require(Executions.TransportShipExecution)
local ParatroopersExecution = require(Executions.ParatroopersExecution)
local SabotageExecution = require(Executions.SabotageExecution)
local FieldWorksExecution = require(Executions.FieldWorksExecution)
local TribeSpawner = require(Executions.TribeSpawner)
local UpgradeStructureExecution = require(Executions.UpgradeStructureExecution)
local WinCheckExecution = require(Executions.WinCheckExecution)

local AllPlayers = GameTypes.AllPlayers
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

-- build_unit types whose executions are ported so far.
local PORTED_BUILDS: { [string]: true } = {
	[UnitType.City] = true,
	[UnitType.DefensePost] = true,
	[UnitType.Port] = true,
	[UnitType.MissileSilo] = true,
	[UnitType.SAMLauncher] = true,
	[UnitType.AtomBomb] = true,
	[UnitType.HydrogenBomb] = true,
	[UnitType.MIRV] = true,
	[UnitType.Warship] = true,
	[UnitType.Factory] = true,
}
-- Conquest's Arsenal (Player checks the unlock).
for _, e in ArsenalUnits.BUILD do
	PORTED_BUILDS[e.type] = true
end

export type Intent = { [string]: any }

export type Options = {
	gameID: string,
	mapFolder: any, -- the imported map module (src/maps/<Name>)
	gameConfig: { [string]: any }, -- OpenFront GameConfig fields
	mapData: MapLoader.TerrainMapData?, -- already loaded maps instead (tests)
	-- Spread name placements over ticks within this many ms per tick (the
	-- server); nil computes them exactly on GameRunner's ticks (tests).
	nameBudgetMs: number?,
}

local Runner = {}
Runner.__index = Runner

export type Runner = typeof(setmetatable(
	{} :: {
		gameID: string,
		mapFolder: any,
		gameConfig: { [string]: any },
		mapData: MapLoader.TerrainMapData?,
		lobby: { { clientID: string, username: string, friends: { string }?, cosmetics: { flag: string?, skin: string?, weapons: { [string]: boolean }? }? } },
		game: any,
		queued: { { clientID: string, intent: Intent } },
		started: boolean,
		names: NameBoxCalculator.Tracker,
		namesChanged: boolean,
		paused: boolean,
		pauseAfterStep: boolean,
	},
	Runner
))

function Runner.new(options: Options): Runner
	return setmetatable({
		gameID = options.gameID,
		mapFolder = options.mapFolder,
		gameConfig = options.gameConfig,
		mapData = options.mapData,
		lobby = {},
		game = nil,
		queued = {},
		started = false,
		names = NameBoxCalculator.newTracker(options.nameBudgetMs),
		namesChanged = false,
		paused = false,
		pauseAfterStep = false,
	}, Runner)
end

-- `friends` (clientIDs) is PlayerInfo.friends: TeamAssignment prefers to
-- put friends on one team (Conquest passes the player's party).
-- `cosmetics` is what the player wears and has unlocked (Conquest's store:
-- flag and skin ids, Arsenal weapons).
function Runner.addHuman(self: Runner, clientID: string, username: string, friends: { string }?, cosmetics: { flag: string?, skin: string?, weapons: { [string]: boolean }? }?): boolean
	if self.started then
		return false
	end
	for _, p in self.lobby do
		if p.clientID == clientID then
			return true
		end
	end
	table.insert(self.lobby, { clientID = clientID, username = username, friends = friends, cosmetics = cosmetics })
	return true
end

-- GameRunner.ts createGameRunner + init.
function Runner.start(self: Runner)
	assert(not self.started, "already started")
	self.started = true
	local gameConfig = self.gameConfig
	local config = EngineConfig.new(gameConfig :: any, false)
	local data = self.mapData or MapLoader.loadTerrainMap(self.mapFolder, gameConfig.gameMapSize or "Normal")
	local random = PseudoRandom.new(Util.simpleHash(self.gameID))
	local humans = {}
	for _, p in self.lobby do
		table.insert(humans, {
			name = p.username,
			playerType = PlayerType.Human,
			clientID = p.clientID,
			id = random:nextID(),
			isLobbyCreator = false,
			friends = p.friends,
			flag = if p.cosmetics then p.cosmetics.flag else nil,
			skin = if p.cosmetics then p.cosmetics.skin else nil,
			weapons = if p.cosmetics then p.cosmetics.weapons else nil,
		})
	end
	local nations = NationCreation.createNationsForGame(gameConfig, data.nations, data.additionalNations, #humans, random)
	local game = Game.new(humans, nations, data.gameMap, data.miniGameMap, config, data.teamGameSpawnAreas)
	;(game :: any).mapName = data.name
	-- The map's folder (OpenFrontMaps child), which clients load by name.
	;(game :: any).mapFolder = if self.mapFolder then (self.mapFolder :: any).Name else nil
	self.game = game
	-- Conquest: the rail areas are built while the match loads, not in the
	-- tick of the first station (GameMap.railComponents).
	if data.miniGameMap then
		data.miniGameMap:railComponents()
	end
	-- GameRunner.init
	if gameConfig.gameType ~= "Singleplayer" then
		game:addExecution(SpawnTimerExecution.new())
		if gameConfig.autoSpawnUnplaced and not config:isRandomSpawn() then
			-- Conquest: place humans who didn't pick a start (AutoSpawnExecution).
			game:addExecution(AutoSpawnExecution.new(self.gameID))
		end
	elseif gameConfig.soloDeployCountdown then
		-- Conquest: the solo deploy countdown (DeployCountdownExecution).
		game:addExecution(DeployCountdownExecution.new())
	end
	if config:spawnNations() then
		for _, nation in game:nations() do
			game:addExecution(NationExecution.new(self.gameID, nation))
		end
	end
	-- PlayerSpawner: with random spawn, every human gets a SpawnExecution
	-- with no tile, which picks one at random.
	if config:isRandomSpawn() then
		for _, player in game:allPlayers() do
			if player:type() == PlayerType.Human then
				game:addExecution(SpawnExecution.new(self.gameID, player:info()))
			end
		end
	end
	if config:bots() > 0 then
		-- ExecutionManager.spawnTribes: tribes keep clear of the nations' spawn cells
		local nationCells = {}
		for _, n in game:nations() do
			if n.spawnCell ~= nil then
				table.insert(nationCells, n.spawnCell)
			end
		end
		game:addExecution(table.unpack(TribeSpawner.new(game, self.gameID, nationCells):spawnTribes(config:bots())))
	end
	game:addExecution(WinCheckExecution.new())
	if config:doomsdayClockConfig().enabled then
		game:addExecution(DoomsdayClockExecution.new())
	end
	if not config:isUnitDisabled(UnitType.Factory) then
		game:addExecution(RecomputeRailClusterExecution.new(game:railNetwork()))
	end
end

local function isTile(game: any, v: any): boolean
	return type(v) == "number" and v == math.floor(v) and game:isValidRef(v)
end

local function isAmount(v: any): boolean
	return type(v) == "number" and v == v and v >= 0 and v < math.huge
end

-- Unit ids: whole numbers (OpenFront's zb.int()); NaN can't be a table key.
local function isUnitId(v: any): boolean
	return type(v) == "number" and v == v and v >= 0 and v < 2 ^ 31 and v == math.floor(v)
end

-- Bulk amounts: 1..MAX_UPGRADE_AMOUNT whole units, as OpenFront's schema.
local function isBulkAmount(v: any): boolean
	return type(v) == "number" and v == math.floor(v) and v >= 1 and v <= GameTypes.MAX_UPGRADE_AMOUNT
end

-- Schemas.ts ID (GAME_ID_REGEX): 8 to 10 letters and digits.
local function isID(v: any): boolean
	return type(v) == "string" and #v >= 8 and #v <= 10 and string.match(v, "^%w+$") ~= nil
end

local function isAction(v: any): boolean
	return v == "start" or v == "stop"
end

-- Checks an intent's shape and queues it for the next tick. Returns false and
-- a reason if it can't be accepted (unknown sender, malformed, unsupported).
function Runner.intent(self: Runner, clientID: string, intent: Intent): (boolean, string?)
	local game = self.game
	if game == nil then
		return false, "notStarted"
	end
	if type(intent) ~= "table" or type(intent.type) ~= "string" then
		return false, "badRequest"
	end
	if game:playerByClientID(clientID) == nil then
		return false, "notPlaying"
	end
	local kind = intent.type
	if kind == "toggle_pause" then
		-- IntentAuthorization + LocalServer/GameServer: only singleplayer here
		-- (no private lobbies yet), once the game has started. Pausing runs
		-- one more turn carrying the intent, then turns stop; unpausing
		-- restarts them with it.
		if type(intent.paused) ~= "boolean" then
			return false, "badRequest"
		end
		if self.gameConfig.gameType ~= "Singleplayer" then
			return false, "notAllowed"
		end
		-- A pause and an unpause in one turn cancel out.
		if intent.paused then
			self.pauseAfterStep = true
		else
			self.pauseAfterStep = false
			self.paused = false
		end
		table.insert(self.queued, { clientID = clientID, intent = intent })
		return true, nil
	end
	-- While paused, gameplay intents are accepted but dropped (GameServer).
	if self.paused then
		return true, nil
	end
	if kind == "spawn" then
		if not isTile(game, intent.tile) then
			return false, "badTile"
		end
	elseif kind == "attack" then
		if not isAmount(intent.troops) then
			return false, "badRequest"
		end
		if intent.targetID ~= nil and type(intent.targetID) ~= "string" then
			return false, "badRequest"
		end
	elseif kind == "boat" then
		if not isTile(game, intent.dst) or not isAmount(intent.troops) then
			return false, "badRequest"
		end
	elseif kind == "tile_action" then
		if not isTile(game, intent.tile) or not isAmount(intent.ratio) or intent.ratio > 1 then
			return false, "badRequest"
		end
	elseif kind == "cancel_attack" then
		if type(intent.attackID) ~= "string" then
			return false, "badRequest"
		end
	elseif kind == "cancel_boat" then
		if not isUnitId(intent.unitID) then
			return false, "badRequest"
		end
	elseif kind == "build_unit" then
		if type(intent.unit) ~= "string" or not isTile(game, intent.tile) then
			return false, "badRequest"
		end
		if not PORTED_BUILDS[intent.unit] then
			return false, "unsupported"
		end
		if intent.rocketDirectionUp ~= nil and type(intent.rocketDirectionUp) ~= "boolean" then
			return false, "badRequest"
		end
		if intent.amount ~= nil and not isBulkAmount(intent.amount) then
			return false, "badRequest"
		end
	elseif kind == "build_action" then
		if type(intent.unit) ~= "string" or not PORTED_BUILDS[intent.unit] or not isTile(game, intent.tile) then
			return false, "badRequest"
		end
		-- Conquest's Paratroopers carry troops, like a boat.
		if intent.troops ~= nil and not isAmount(intent.troops) then
			return false, "badRequest"
		end
		if intent.rocketDirectionUp ~= nil and type(intent.rocketDirectionUp) ~= "boolean" then
			return false, "badRequest"
		end
		if intent.amount ~= nil and not isBulkAmount(intent.amount) then
			return false, "badRequest"
		end
	elseif kind == "upgrade_structure" then
		if not isUnitId(intent.unitId) then
			return false, "badRequest"
		end
		if intent.amount ~= nil and not isBulkAmount(intent.amount) then
			return false, "badRequest"
		end
	elseif kind == "delete_unit" then
		if not isUnitId(intent.unitId) then
			return false, "badRequest"
		end
	elseif kind == "move_warship" then
		if type(intent.unitIds) ~= "table" or #intent.unitIds == 0 or #intent.unitIds > 500 or not isTile(game, intent.tile) then
			return false, "badRequest"
		end
		for _, id in intent.unitIds do
			if not isUnitId(id) then
				return false, "badRequest"
			end
		end
	elseif kind == "allianceRequest" or kind == "breakAlliance" or kind == "allianceExtension" then
		if not isID(intent.recipient) then
			return false, "badRequest"
		end
	elseif kind == "allianceReject" then
		if not isID(intent.requestor) then
			return false, "badRequest"
		end
	elseif kind == "targetPlayer" then
		if not isID(intent.target) then
			return false, "badRequest"
		end
	elseif kind == "emoji" then
		if not (isID(intent.recipient) or intent.recipient == AllPlayers) then
			return false, "badRequest"
		end
		local e = intent.emoji
		if type(e) ~= "number" or e ~= math.floor(e) or e < 0 or e >= Emoji.count then
			return false, "badRequest"
		end
	elseif kind == "donate_troops" or kind == "donate_gold" then
		local amount = if kind == "donate_troops" then intent.troops else intent.gold
		if not isID(intent.recipient) or (amount ~= nil and not isAmount(amount)) then
			return false, "badRequest"
		end
	elseif kind == "embargo" then
		if not isID(intent.targetID) or not isAction(intent.action) then
			return false, "badRequest"
		end
	elseif kind == "embargo_all" then
		if not isAction(intent.action) then
			return false, "badRequest"
		end
	elseif kind == "reinforce" then
		-- Conquest's Arsenal; ReinforceExecution checks the unlock and cooldown.
		if not game:config():extraWeapons() then
			return false, "unsupported"
		end
	elseif kind == "quick_chat" then
		if not isID(intent.recipient) or type(intent.quickChatKey) ~= "string" or QuickChat.keys[intent.quickChatKey] == nil then
			return false, "badRequest"
		end
		if intent.target ~= nil and not isID(intent.target) then
			return false, "badRequest"
		end
	else
		return false, "unsupported"
	end
	table.insert(self.queued, { clientID = clientID, intent = intent })
	return true, nil
end

-- ExecutionManager.ts createExec, for the intents ported so far.
function Runner._createExec(self: Runner, clientID: string, intent: Intent): any?
	local game = self.game
	local player = game:playerByClientID(clientID)
	if player == nil then
		return nil
	end
	local kind = intent.type
	if kind == "attack" then
		return AttackExecution.new(intent.troops, player, intent.targetID, nil)
	elseif kind == "cancel_attack" then
		return RetreatExecution.new(player, intent.attackID)
	elseif kind == "cancel_boat" then
		return BoatRetreatExecution.new(player, intent.unitID)
	elseif kind == "spawn" then
		return SpawnExecution.new(self.gameID, player:info(), intent.tile, true)
	elseif kind == "boat" then
		return TransportShipExecution.new(player, intent.dst, intent.troops)
	elseif kind == "build_unit" then
		return ConstructionExecution.new(player, intent.unit, intent.tile, intent.rocketDirectionUp, intent.amount)
	elseif kind == "upgrade_structure" then
		return UpgradeStructureExecution.new(player, intent.unitId, intent.amount)
	elseif kind == "delete_unit" then
		return DeleteUnitExecution.new(player, intent.unitId)
	elseif kind == "move_warship" then
		return MoveWarshipExecution.new(player, intent.unitIds, intent.tile)
	elseif kind == "toggle_pause" then
		return PauseExecution.new(player, intent.paused)
	elseif kind == "mark_disconnected" then
		return SocialExecutions.MarkDisconnected.new(player, intent.isDisconnected)
	elseif kind == "allianceRequest" then
		return AllianceRequestExecution.new(player, intent.recipient)
	elseif kind == "allianceReject" then
		return AllianceRejectExecution.new(intent.requestor, player)
	elseif kind == "breakAlliance" then
		return BreakAllianceExecution.new(player, intent.recipient)
	elseif kind == "allianceExtension" then
		return AllianceExtensionExecution.new(player, intent.recipient)
	elseif kind == "targetPlayer" then
		return SocialExecutions.TargetPlayer.new(player, intent.target)
	elseif kind == "emoji" then
		return EmojiExecution.new(player, intent.recipient, intent.emoji)
	elseif kind == "donate_troops" then
		return DonateExecution.Troops.new(player, intent.recipient, intent.troops)
	elseif kind == "donate_gold" then
		return DonateExecution.Gold.new(player, intent.recipient, intent.gold)
	elseif kind == "embargo" then
		return EmbargoExecution.new(player, intent.targetID, intent.action)
	elseif kind == "embargo_all" then
		return EmbargoExecution.All.new(player, intent.action)
	elseif kind == "quick_chat" then
		return SocialExecutions.QuickChat.new(player, intent.recipient, intent.quickChatKey, intent.target)
	elseif kind == "tile_action" then
		return self:_tileAction(player, intent.tile, intent.ratio)
	elseif kind == "build_action" then
		return self:_buildAction(player, intent.unit, intent.tile, intent.rocketDirectionUp, intent.amount, intent.troops)
	elseif kind == "reinforce" then
		return (require(script.Parent.Executions.ReinforceExecution) :: any).new(player)
	end
	return nil
end

-- BuildPreviewController.createStructure, decided on the server (the client
-- has no engine to ask for buildableUnits): with a structure type chosen, a
-- click upgrades the nearest own one in reach, else builds a new one there.
-- Bulk amounts apply to upgrades and atom bombs, as in the source.
function Runner._buildAction(self: Runner, player: any, unitType: string, tile: number, rocketDirectionUp: boolean?, amount: number?, troops: number?): any?
	if self.game:inSpawnPhase() then
		return nil
	end
	local bu = player:buildableUnits(tile, { unitType })[1]
	if bu.canUpgrade ~= false then
		return UpgradeStructureExecution.new(player, bu.canUpgrade, amount or 1)
	elseif bu.canBuild ~= false then
		local isNuke = unitType == UnitType.AtomBomb
		local direction = if unitType == UnitType.AtomBomb or unitType == UnitType.HydrogenBomb or ArsenalUnits.AIMED[unitType] then rocketDirectionUp else nil
		local carried = if unitType == UnitType.Paratroopers then troops else nil
		return ConstructionExecution.new(player, unitType, tile, direction, if isNuke then amount or 1 else nil, carried)
	end
	return nil
end

-- ClientGameRunner.ts inputEvent, decided on the server (the engine lives
-- here, not in the client's worker):
--   - spawn phase: spawn on free land
--   - otherwise attack the tile's owner if we can (canAttack), sending
--     troops * ratio
--   - else auto-boat if our launch shore is within 100 tiles
function Runner._tileAction(self: Runner, player: any, tile: number, ratio: number): any?
	local game = self.game
	if game:isLand(tile) and not game:hasOwner(tile) and game:inSpawnPhase() and not game:config():isRandomSpawn() then
		return SpawnExecution.new(self.gameID, player:info(), tile, true)
	end
	if game:inSpawnPhase() then
		return nil
	end
	if player:canAttack(tile) then
		return AttackExecution.new(player:troops() * ratio, player, game:owner(tile):id(), nil)
	end
	if game:isLand(tile) then
		local launch = player:canBuild("Transport", tile)
		if launch ~= false and game:euclideanDistSquared(tile, launch) < 100 * 100 then
			return TransportShipExecution.new(player, tile, player:troops() * ratio)
		end
	end
	return nil
end

-- GameRunner.playerActions, for the client's panels (OpenFront's client asks
-- its engine worker; ours asks the server). `tile` (or, for a panel opened
-- from a list, `otherSmallID`) picks the other player. `withBuildables`
-- adds buildableUnits for every type at the tile (the radial menu's call;
-- the player panel passes null). Also carries isLand for the tile and the
-- viewer's deleteUnitCooldown in seconds, which OpenFront's client reads
-- from its GameView. Returns nil for an unknown viewer.
function Runner.playerActions(self: Runner, clientID: string, tile: number?, otherSmallID: number?, withBuildables: boolean?): { [string]: any }?
	local game = self.game
	if game == nil then
		return nil
	end
	local player = game:playerByClientID(clientID)
	if player == nil then
		return nil
	end
	if tile ~= nil and not isTile(game, tile) then
		tile = nil
	end
	local actions: { [string]: any } = {
		canAttack = tile ~= nil and player:canAttack(tile),
		isLand = tile ~= nil and game:isLand(tile),
		-- For the attack card: a tap on an ocean coast picks the boat (Bruno, 2026-10-28).
		isOceanShore = tile ~= nil and game:isLand(tile) and game:isOceanShore(tile),
		canSendEmojiAllPlayers = player:canSendEmoji(AllPlayers),
		canEmbargoAll = player:canEmbargoAll(),
		buildableUnits = if withBuildables then player:buildableUnits(tile, GameTypes.PlayerBuildable) else {},
		deleteUnitCooldown = math.max(0, game:config():deleteUnitCooldown() - (game:ticks() + 1 - player.lastDeleteUnitTick)) / 10,
	}
	local other = nil
	if type(otherSmallID) == "number" then
		other = game:playerBySmallID(otherSmallID)
	elseif tile ~= nil and game:hasOwner(tile) then
		other = game:owner(tile)
	end
	if other ~= nil and other.isPlayer ~= nil and other:isPlayer() and other ~= player then
		actions.other = other:smallID()
		actions.interaction = {
			sharedBorder = player:sharesBorderWith(other),
			canSendEmoji = player:canSendEmoji(other),
			canTarget = player:canTarget(other),
			canSendAllianceRequest = player:canSendAllianceRequest(other),
			canBreakAlliance = player:isAlliedWith(other),
			canDonateGold = player:canDonateGold(other),
			canDonateTroops = player:canDonateTroops(other),
			canEmbargo = not player:hasEmbargoAgainst(other),
			canSendQuickChat = player:canSendQuickChat(other),
			allianceInfo = player:allianceInfo(other),
		}
	end
	return actions
end

-- BuildPreviewController.renderGhost and updateNukeTrajectoryPreview: what
-- the build ghost under the pointer shows. OpenFront's client reads these
-- from its engine worker and GameView; ours asks the server.
--   - `tile` is the pointer tile (nil off the map). Impassable terrain voids
--     the ghost but keeps the nuke's aim.
--   - buildable: buildableUnits for the ghost tile.
--   - rangeWarning: the blast would break an alliance with a connected ally.
--   - nukeAim (atom and hydrogen bombs, and the Arsenal's Mega Nuke): the
--     nearest ready silo and the SAMs that would engage, whether or not the
--     bomb can be built now.
-- Returns nil for an unknown viewer or unit type.
function Runner.buildPreview(self: Runner, clientID: string, tile: number?, unitType: string): { [string]: any }?
	local game = self.game
	if game == nil then
		return nil
	end
	-- The Mega Nuke isn't in OpenFront's PlayerBuildable, so allow it here
	-- when the match has extra weapons, as the build path does.
	local extra = ArsenalUnits.KEY[unitType] ~= nil and game:config():extraWeapons()
	if not extra and not table.find(GameTypes.PlayerBuildable, unitType) then
		return nil
	end
	local player = game:playerByClientID(clientID)
	if player == nil then
		return nil
	end
	local aimTile = if tile ~= nil and isTile(game, tile) then tile else nil
	local ghostTile = if aimTile ~= nil and not game:isImpassable(aimTile) then aimTile else nil
	local config = game:config()
	local isAimed = unitType == UnitType.AtomBomb or unitType == UnitType.HydrogenBomb or ArsenalUnits.AIMED[unitType] == true

	-- Whom this strike would betray (NukeAlliance.ts listNukeBreakAlliance):
	-- one walk over the blast, shared by the warning and the SAM list below.
	-- (wouldNukeBreakAlliance for the connected allies says the same as "one
	-- of them is on that list"; asking both walked the blast twice.)
	local breaks: { [number]: boolean }? = nil
	local function wouldBreak(): { [number]: boolean }
		if breaks == nil then
			local set: { [number]: boolean } = {}
			for _, id in NukeExecution.listNukeBreakAlliance(game, aimTile :: number, config:nukeMagnitudes(unitType), config:nukeAllianceBreakThreshold()) do
				set[id] = true
			end
			breaks = set
		end
		return breaks :: { [number]: boolean }
	end

	local rangeWarning = false
	if ghostTile ~= nil and isAimed then
		for _, ally in player:allies() do
			if not ally:isDisconnected() and wouldBreak()[ally:smallID()] then
				rangeWarning = true
				break
			end
		end
	end

	local nukeAim = nil
	if aimTile ~= nil and isAimed then
		local dx, dy = game:x(aimTile), game:y(aimTile)
		local best, bestDist = nil, math.huge
		for _, silo in player:units(UnitType.MissileSilo) do
			if silo:isActive() and not silo:isInCooldown() and not silo:isUnderConstruction() and not silo:isDark() then
				local d = math.abs(game:x(silo:tile()) - dx) + math.abs(game:y(silo:tile()) - dy)
				if d < bestDist then -- first of equals, as the source's stable sort
					best, bestDist = silo, d
				end
			end
		end
		if best ~= nil then
			local allies: { [number]: boolean } = {}
			for _, ally in player:allies() do
				allies[ally:smallID()] = true
			end
			local betrayed: { [number]: boolean } = if next(allies) ~= nil then wouldBreak() else {}
			-- samThreatensNukePreview: never own or teammates' SAMs; allies'
			-- only when this strike would betray them.
			local sams = {}
			for _, sam in game:units(UnitType.SAMLauncher) do
				local owner = sam:owner()
				if not sam:isActive() or owner == player or player:isOnSameTeam(owner) then
					continue
				end
				local id = owner:smallID()
				if allies[id] and not betrayed[id] then
					continue
				end
				table.insert(sams, { x = game:x(sam:tile()), y = game:y(sam:tile()), r = config:samRange(sam:level()) })
			end
			nukeAim = { siloTile = best:tile(), sams = sams }
		end
	end

	-- Conquest's Arsenal: an Air Strike or Railgun shot's launcher and blast.
	local strikeAim = nil
	if aimTile ~= nil and ArsenalUnits.STRIKES[unitType] then
		local from = player:strikeSpawn(aimTile, unitType)
		local spec = StrikeExecution.SPEC[unitType]
		strikeAim = { launcherTile = if from == false then nil else from, radius = spec.radius, reach = spec.reach }
	end

	-- Conquest's Paratroopers: where the plane would take off (nil when no
	-- City or Airfield is in reach, or it can't go now), and what it carries.
	local paraAim = nil
	if aimTile ~= nil and unitType == UnitType.Paratroopers then
		local from = player:paraSpawn(aimTile)
		paraAim = {
			originTile = if from == false then nil else from,
			reach = ParatroopersExecution.REACH,
			troops = ParatroopersExecution.troopsFor(game, player, math.huge),
			readyAt = player.paraReadyAt or 0,
		}
	end

	-- Conquest's Field Works: its circle and when the next may go.
	local fieldWorksAim = nil
	if aimTile ~= nil and unitType == UnitType.FieldWorks then
		fieldWorksAim = { radius = FieldWorksExecution.RADIUS, readyAt = player.fieldWorksReadyAt or 0 }
	end

	-- Conquest's Sabotage: the building it would hit (nil: none).
	local sabotageAim = nil
	if aimTile ~= nil and unitType == UnitType.Sabotage then
		local target = player:sabotageTarget(aimTile)
		sabotageAim = {
			targetTile = if target ~= nil then target:tile() else nil,
			reach = SabotageExecution.REACH,
			readyAt = player.sabotageReadyAt or 0,
		}
	end

	return {
		tile = tile,
		unit = unitType,
		tick = game:ticks(),
		buildable = player:buildableUnits(ghostTile, { unitType })[1],
		rangeWarning = rangeWarning,
		nukeAim = nukeAim,
		strikeAim = strikeAim,
		paraAim = paraAim,
		sabotageAim = sabotageAim,
		fieldWorksAim = fieldWorksAim,
	}
end

-- Conquest's Arsenal (not OpenFront; docs/design/ARSENAL_V2.md, RoWorld's
-- Sim.take_over): the AI nation an eliminated human may take over, or nil.
-- Only the nation that eliminated them, still alive with land; never a tribe
-- or a bot (in a public match that would give a bot away as not a person).
function Runner.takeoverTarget(self: Runner, clientID: string): any?
	local game = self.game
	if game == nil or game:inSpawnPhase() or game:getWinner() ~= nil then
		return nil
	end
	local old = game:playerByClientID(clientID)
	if old == nil or old:type() ~= PlayerType.Human or old:isAlive() then
		return nil
	end
	local target = (old :: any)._conqueredBy
	if target == nil or not target:isPlayer() or target:type() ~= PlayerType.Nation or not target:isAlive() or target:numTilesOwned() <= 0 then
		return nil
	end
	return target
end

-- The takeover itself (its Robux credit already spent): the human commands
-- the nation from now on, with its land, troops, gold, buildings and
-- alliances, under the human's name, Arsenal and cosmetics; the nation keeps
-- its colour and its AI stops. True when done.
function Runner.takeOver(self: Runner, clientID: string): boolean
	local target = self:takeoverTarget(clientID)
	if target == nil then
		return false
	end
	local game = self.game :: any
	local old = game:playerByClientID(clientID)
	local was = target:displayName()
	local info = table.clone(target.playerInfo)
	local mine = old.playerInfo
	info.playerType = PlayerType.Human
	info.clientID = mine.clientID
	info.name = mine.name
	info.displayName = mine.displayName
	info.friends = mine.friends
	info.flag = mine.flag
	info.skin = mine.skin
	info.weapons = mine.weapons
	target.playerInfo = info
	local gone = table.clone(mine)
	gone.clientID = nil
	old.playerInfo = gone
	game:displayMessage("events_display.took_over", "CONQUERED_PLAYER", target:id(), nil, { name = was })
	return true
end

-- Conquest's tutorial (Shared/Tutorial, after RoWorld's): its City step tops
-- the player's gold up to a City's price. Only in a match whose config says
-- `tutorial`; the caller allows it once per match. True when gold was given.
function Runner.tutorialGold(self: Runner, clientID: string): boolean
	local game = self.game
	if game == nil or self.gameConfig.tutorial ~= true or game:inSpawnPhase() then
		return false
	end
	local player = game:playerByClientID(clientID)
	if player == nil or not player:isAlive() then
		return false
	end
	local cost = game:unitInfo("City").cost(game, player)
	local short = cost - player:gold()
	if short <= 0 then
		return false
	end
	player:addGold(short)
	return true
end

-- GameRunner.playerProfile, as the player panel reads it: a nation's
-- relation toward the viewer (Hostile 0 .. Friendly 3); nil for others.
function Runner.playerProfile(self: Runner, clientID: string, otherSmallID: number): { [string]: any }?
	local game = self.game
	if game == nil or type(otherSmallID) ~= "number" then
		return nil
	end
	local viewer = game:playerByClientID(clientID)
	local ok, other = pcall(function()
		return game:playerBySmallID(otherSmallID)
	end)
	if viewer == nil or not ok or other == nil or other.isPlayer == nil or not other:isPlayer() or other:type() ~= "NATION" then
		return nil
	end
	return { relation = other:relation(viewer) }
end

-- The server's mark_disconnected intent, queued like a client's: a player
-- who leaves (or comes back) mid-match.
function Runner.markDisconnected(self: Runner, clientID: string, isDisconnected: boolean)
	if self.game ~= nil and self.game:playerByClientID(clientID) ~= nil then
		table.insert(self.queued, { clientID = clientID, intent = { type = "mark_disconnected", isDisconnected = isDisconnected } })
	end
end

-- One turn: queued intents become executions, then the game ticks.
-- Whether turns are stopped (the server skips step while true).
function Runner.isPaused(self: Runner): boolean
	return self.paused
end

function Runner.step(self: Runner)
	local game = self.game
	if self.paused then
		return
	end
	local queued = self.queued
	self.queued = {}
	for _, q in queued do
		local exec = self:_createExec(q.clientID, q.intent)
		if exec ~= nil then
			game:addExecution(exec)
		end
	end
	local wasInSpawnPhase = game:inSpawnPhase()
	game:executeNextTick()
	-- GameRunner: name anchors, recomputed on its schedule.
	self.namesChanged = self.names:update(game, wasInSpawnPhase)
	if self.pauseAfterStep then
		self.pauseAfterStep = false
		self.paused = true
	end
end

return Runner
