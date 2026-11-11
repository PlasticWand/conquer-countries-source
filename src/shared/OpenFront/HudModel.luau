--!strict
-- Ported from OpenFront v0.35.2 (src/client/hud/layers/UnitDisplay.ts, EventsDisplay.ts and ActionableEvents.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- What the in-match HUD shows, from the confirmed ClientState, with no
-- Roblox UI in it (Lune-tested):
--   - buildItems: the build bar (UnitDisplay): hotkey, price, how many
--     levels you own, and whether you can use it now
--   - feedLine: the events feed line for a diplomacy update, or nil when
--     it isn't about you (EventsDisplay's rules and English strings)
--   - Prompts: the alliance cards with buttons (ActionableEvents): incoming
--     requests, and renewal near an alliance's expiry

local ArsenalUnits = require(script.Parent.ArsenalUnits)
local Emoji = require(script.Parent.Data.Emoji)
local EngineConfig = require(script.Parent.EngineConfig)
local Format = require(script.Parent.Format)
local Lang = require(script.Parent.Lang)
local QuickChat = require(script.Parent.Data.QuickChat)
local Replication = require(script.Parent.Replication)

local HudModel = {}

-- UnitDisplay order and default keys.
local KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }
local LANG_KEY = {
	City = "city",
	Factory = "factory",
	Port = "port",
	["Defense Post"] = "defense_post",
	["Missile Silo"] = "missile_silo",
	["SAM Launcher"] = "sam_launcher",
	Warship = "warship",
	["Atom Bomb"] = "atom_bomb",
	["Hydrogen Bomb"] = "hydrogen_bomb",
	MIRV = "mirv",
}
-- Conquest's Arsenal.
for _, e in ArsenalUnits.BUILD do
	LANG_KEY[e.type] = e.lang
end
local NUKES = { ["Atom Bomb"] = true, ["Hydrogen Bomb"] = true, MIRV = true, ["Mega Nuke"] = true, Scattershot = true }

-- `arsenal`: one of Conquest's Arsenal weapons, shown in the ARSENAL slot's
-- fly-out (Bruno, 2026-11-08); its key is its place there ("1".."9").
export type BuildItem = { type: string, key: string, name: string, cost: number, count: number, enabled: boolean, arsenal: boolean? }

-- totalUnitLevels per type for the viewer, from the unit records.
local function levelsByType(state: any): { [string]: number }
	local out = {}
	for _, u in state.units do
		if u.owner == state.you and u.active ~= false then
			out[u.type] = (out[u.type] or 0) + (u.level or 1)
		end
	end
	return out
end

function HudModel.buildItems(state: any): { BuildItem }
	local me = state:me()
	local gold = if me then state.gold else 0
	local levels = levelsByType(state)
	local disabled = state:config()
	local items = {}
	local bar = table.clone(Replication.BUILD_BAR)
	-- Conquest's Arsenal: each unlocked weapon after OpenFront's ten (the HUD
	-- puts them in the ARSENAL slot's fly-out).
	local weapons = state.arsenal and state.arsenal.weapons
	if weapons then
		for _, e in ArsenalUnits.BUILD do
			if weapons[e.key] then
				table.insert(bar, e.type)
			end
		end
	end
	for i, t in bar do
		local cost = state.costs[t] or math.huge
		local enabled = me ~= nil and me.alive and cost <= gold
		if NUKES[t] then
			enabled = enabled and (levels["Missile Silo"] or 0) > 0
		elseif ArsenalUnits.STRIKES[t] then
			enabled = enabled and (levels[ArsenalUnits.STRIKES[t]] or 0) > 0
		elseif t == "Paratroopers" then
			-- Needs a City or Airfield to fly from, and the cooldown over.
			local readyAt = state.arsenal and state.arsenal.paraReadyAt or 0
			enabled = enabled and ((levels.City or 0) + (levels.Airfield or 0)) > 0 and (state.tick or 0) >= readyAt
		elseif t == "Sabotage" then
			local readyAt = state.arsenal and state.arsenal.sabotageReadyAt or 0
			enabled = enabled and (state.tick or 0) >= readyAt
		elseif t == "Field Works" then
			local readyAt = state.arsenal and state.arsenal.fieldWorksReadyAt or 0
			enabled = enabled and (state.tick or 0) >= readyAt and (levels["Field Works"] or 0) < 2
		elseif t == "Warship" then
			enabled = enabled and (levels.Port or 0) > 0
		end
		if disabled:isUnitDisabled(t) then
			enabled = false
		end
		local arsenal = ArsenalUnits.KEY[t] ~= nil
		table.insert(items, {
			type = t,
			key = if arsenal then tostring(i - #Replication.BUILD_BAR) else KEYS[i],
			name = Lang.t(`unit_type.{LANG_KEY[t]}`),
			cost = cost,
			count = levels[t] or 0,
			enabled = enabled,
			arsenal = if arsenal then true else nil,
		})
	end
	return items
end

-- Whether the viewer is allied with a player (smallID).
function HudModel.isAlly(state: any, smallID: number): boolean
	for _, a in state.diplomacy.alliances do
		if a.other == smallID then
			return true
		end
	end
	return false
end

-- A build slot's tooltip: OpenFront's one-line description (build_menu.desc)
-- and, when the slot can't be used now, why (the red line).
function HudModel.slotInfo(state: any, item: BuildItem): { desc: string, reason: string? }
	local desc = Lang.t(`build_menu.desc.{LANG_KEY[item.type]}`)
	local reason: string? = nil
	if state:config():isUnitDisabled(item.type) then
		reason = "Disabled in this match"
	elseif not item.enabled then
		local levels = levelsByType(state)
		if NUKES[item.type] and (levels["Missile Silo"] or 0) == 0 then
			reason = `Needs a {Lang.t("unit_type.missile_silo")}`
		elseif item.type == "Warship" and (levels.Port or 0) == 0 then
			reason = `Needs a {Lang.t("unit_type.port")}`
		elseif item.cost > state.gold then
			reason = Lang.t("build_menu.not_enough_money")
		end
	end
	return { desc = desc, reason = reason }
end

local function nameOf(state: any, smallID: number): string
	local p = state.players[smallID]
	return if p then p.displayName else "?"
end

local function byId(state: any, id: string): any?
	for _, p in state.players do
		if p.id == id then
			return p
		end
	end
	return nil
end

export type FeedLine = { text: string, focus: number?, minor: boolean? }

-- EventsDisplay's line for one diplomacy update, or nil.
function HudModel.feedLine(state: any, e: { [string]: any }): FeedLine?
	local me = state:me()
	if me == nil or not me.alive then
		return nil
	end
	local you = state.you
	local kind = e.type
	if kind == "AllianceRequestReply" then
		if e.request.requestorID ~= you then
			return nil
		end
		return {
			text = Lang.t("events_display.alliance_request_status", {
				name = nameOf(state, e.request.recipientID),
				status = Lang.t(if e.accepted then "events_display.alliance_accepted" else "events_display.alliance_rejected"),
			}),
			focus = e.request.recipientID,
		}
	elseif kind == "BrokeAlliance" then
		local betrayed, traitor = state.players[e.betrayedID], state.players[e.traitorID]
		if betrayed == nil or traitor == nil or betrayed.disconnected then
			return nil
		end
		if not betrayed.traitor and e.traitorID == you then
			local config = state:config()
			local seconds = math.floor(config:traitorDuration() * 0.1)
			local duration = if seconds == 1
				then Lang.t("events_display.duration_second")
				else Lang.t("events_display.duration_seconds_plural", { seconds = seconds })
			return {
				text = Lang.t("events_display.betrayal_description", {
					name = betrayed.displayName,
					malusPercent = math.floor((1 - config:traitorDefenseDebuff()) * 100 + 0.5),
					durationText = duration,
				}),
				focus = e.betrayedID,
			}
		elseif e.betrayedID == you then
			return { text = Lang.t("events_display.betrayed_you", { name = traitor.displayName }), focus = e.traitorID }
		end
		return nil
	elseif kind == "AllianceExpired" then
		local other = if e.player1ID == you then e.player2ID elseif e.player2ID == you then e.player1ID else nil
		if other == nil then
			return nil
		end
		local p = state.players[other]
		if p == nil or not p.alive then
			return nil
		end
		return { text = Lang.t("events_display.alliance_expired", { name = p.displayName }), focus = other }
	elseif kind == "DonateEvent" then
		local isRecipient, isSender = e.recipientId == me.id, e.senderId == me.id
		if not isRecipient and not isSender then
			return nil
		end
		local other = byId(state, if isRecipient then e.senderId else e.recipientId)
		if other == nil then
			return nil
		end
		local gold = e.donationType == "gold"
		local key = if isRecipient
			then (if gold then "received_gold_from_player" else "received_troops_from_player")
			else (if gold then "sent_gold_to_player" else "sent_troops_to_player")
		local params: { [string]: any } = { name = other.displayName }
		if gold then
			params.gold = Format.renderNumber(e.amount)
		else
			params.troops = Format.renderTroops(e.amount)
		end
		return { text = Lang.t(`events_display.{key}`, params), focus = other.smallID }
	elseif kind == "TargetPlayer" then
		local other = state.players[e.playerID]
		if other == nil or not HudModel.isFriendly(state, you, e.playerID) then
			return nil
		end
		return {
			text = Lang.t("events_display.attack_request", { name = other.displayName, target = nameOf(state, e.targetID) }),
			focus = e.targetID,
		}
	elseif kind == "Emoji" then
		local msg = e.emoji
		local text = if type(msg.message) == "number" then Emoji.flat[msg.message] else tostring(msg.message)
		if msg.recipientID == you then
			return { text = `{nameOf(state, msg.senderID)}: {text}`, focus = msg.senderID }
		elseif msg.senderID == you and msg.recipientID ~= "AllPlayers" then
			return {
				text = Lang.t("events_display.sent_emoji", { name = nameOf(state, msg.recipientID), emoji = text }),
				focus = msg.recipientID,
				minor = true,
			}
		elseif msg.senderID == you then
			return { text = Lang.t("events_display.sent_emoji_all", { emoji = text }), minor = true }
		end
		return nil
	elseif kind == "DisplayChatEvent" then
		if e.playerID ~= you then
			return nil
		end
		local phrase = Lang.t(`chat.{e.category}.{e.key}`)
		if e.target then
			local target = byId(state, e.target)
			local name = if target then target.displayName else tostring(e.target)
			phrase = string.gsub(phrase, "%[P1%]", function(): string
				return name
			end)
		end
		local other = byId(state, e.recipient)
		local sent = not e.isFrom
		return {
			text = Lang.t(if sent then "chat.to" else "chat.from", { user = if other then other.displayName else "", msg = phrase }),
			focus = if other then other.smallID else nil,
			minor = sent,
		}
	end
	return nil
end

-- PlayerView.isFriendly (the client's, unlike the engine's, is false for
-- yourself in FFA): allied, or on the same team.
function HudModel.isFriendly(state: any, a: number, b: number): boolean
	local pa, pb = state.players[a], state.players[b]
	if pa == nil or pb == nil then
		return false
	end
	if pa.team ~= nil and pa.team == pb.team then
		return true
	end
	return table.find(pa.allies, b) ~= nil
end

-- ActionableEvents ------------------------------------------------------------------

export type Prompt = {
	kind: "request" | "renew",
	text: string,
	other: number,
	allianceID: number?,
	createdAt: number,
}

local Prompts = {}
Prompts.__index = Prompts
HudModel.Prompts = Prompts

export type Prompts = typeof(setmetatable({} :: { list: { Prompt }, checkedAt: { [number]: number } }, Prompts))

function HudModel.newPrompts(): Prompts
	return setmetatable({ list = {}, checkedAt = {} }, Prompts)
end

-- Feed the tick's diplomacy updates (from ClientState.DiplomacyEvents).
function Prompts.onEvents(self: Prompts, state: any, events: { any })
	local you = state.you
	for _, e in events do
		if e.type == "AllianceRequest" and e.recipientID == you then
			table.insert(self.list, {
				kind = "request",
				text = Lang.t("events_display.request_alliance", { name = nameOf(state, e.requestorID) }),
				other = e.requestorID,
				createdAt = state.tick,
			})
		elseif e.type == "AllianceRequestReply" and e.request.recipientID == you then
			self:_remove(function(p)
				return p.kind == "request" and p.other == e.request.requestorID
			end)
		elseif e.type == "BrokeAlliance" then
			self:_remove(function(p)
				return p.kind == "renew" and p.allianceID == e.allianceID
			end)
			self.checkedAt[e.allianceID] = nil
		elseif e.type == "AllianceExtension" and e.playerID == you then
			self:_remove(function(p)
				return p.kind == "renew" and p.allianceID == e.allianceID
			end)
		end
	end
end

function Prompts._remove(self: Prompts, match: (Prompt) -> boolean)
	local kept = {}
	for _, p in self.list do
		if not match(p) then
			table.insert(kept, p)
		end
	end
	self.list = kept
end

function Prompts.dismiss(self: Prompts, prompt: Prompt)
	self:_remove(function(p)
		return p == prompt
	end)
end

-- Once per tick: renewal prompts for alliances about to expire, and expiry
-- of stale cards. Returns the cards to show, most important first.
function Prompts.tick(self: Prompts, state: any): { Prompt }
	local me = state:me()
	if me == nil or not me.alive then
		return {}
	end
	local config = state:config()
	local offset = config:allianceExtensionPromptOffset()
	local now = state.tick
	for _, a in state.diplomacy.alliances do
		if a.expiresAt > now + offset then
			continue
		end
		if (self.checkedAt[a.id] or 0) >= now - offset then
			continue
		end
		self.checkedAt[a.id] = now
		table.insert(self.list, {
			kind = "renew",
			text = Lang.t("events_display.about_to_expire", { name = nameOf(state, a.other) }),
			other = a.other,
			allianceID = a.id,
			createdAt = now,
		})
	end
	local requestDuration = config:allianceRequestDuration()
	self:_remove(function(p)
		if p.kind == "request" then
			if now - p.createdAt >= requestDuration then
				return true
			end
			local requestor = state.players[p.other]
			if requestor == nil or not requestor.alive then
				return true
			end
			for _, r in state.diplomacy.incoming do
				if r.requestor == p.other then
					return false
				end
			end
			return true
		end
		return false
	end)
	-- ActionableEvents sorts by priority descending: renewals (no priority,
	-- 100000) above requests (0); newest first within each.
	local sorted = table.clone(self.list)
	table.sort(sorted, function(a, b)
		local pa = if a.kind == "request" then 0 else 100000
		local pb = if b.kind == "request" then 0 else 100000
		if pa ~= pb then
			return pa > pb
		end
		return a.createdAt > b.createdAt
	end)
	return sorted
end

-- Event messages (EventsDisplay onDisplayMessageEvent / onUnitIncomingEvent) ------------
-- The feed line for one of the viewer's messages ({ key, kind, gold?,
-- params? }), or nil. `tone` colours it: "danger" (incoming bombs and
-- invasions, losses), "good" (conquests, renewals) or nil.

local INCOMING: { [string]: true } = { NUKE_INBOUND = true, HYDROGEN_BOMB_INBOUND = true, MIRV_INBOUND = true, NAVAL_INVASION_INBOUND = true, PARATROOPERS_INBOUND = true, SABOTAGE_INBOUND = true }
local DANGER: { [string]: true } = { NUKE_INBOUND = true, HYDROGEN_BOMB_INBOUND = true, MIRV_INBOUND = true, NAVAL_INVASION_INBOUND = true, PARATROOPERS_INBOUND = true, SABOTAGE_INBOUND = true, SABOTAGED = true, NUKE_DETONATED = true, UNIT_DESTROYED = true, ATTACK_FAILED = true, ATTACK_CANCELLED = true }
local GOOD: { [string]: true } = { CONQUERED_PLAYER = true, ALLIANCE_ACCEPTED = true, CAPTURED_ENEMY_UNIT = true, SAM_HIT = true }

export type MessageLine = { text: string, tone: string? }

function HudModel.messageLine(state: any, m: { [string]: any }): MessageLine?
	local key = m.key
	if type(key) ~= "string" then
		return nil
	end
	-- The source shows captured-ship gold as a +gold pip, not a feed line.
	if key == "events_display.received_gold_from_captured_ship" then
		return nil
	end
	local params: { [string]: any } = table.clone(m.params or {})
	if INCOMING[m.kind] and params.unitId ~= nil then
		local unit = state.units[params.unitId]
		local owner = if unit then state.players[unit.owner] else nil
		params.name = if owner then owner.displayName else "?"
		if m.kind == "NAVAL_INVASION_INBOUND" or m.kind == "PARATROOPERS_INBOUND" then
			params.troops = Format.renderTroops(if unit then unit.troops or 0 else 0)
		end
	end
	if type(params.unit) == "string" and string.sub(params.unit, 1, 10) == "unit_type." then
		params.unit = Lang.t(params.unit)
	end
	for k, v in params do
		if type(v) == "number" then
			params[k] = if k == "troops" then Format.renderTroops(v) elseif k == "gold" then Format.renderNumber(v) elseif k == "count" then v else tostring(v)
		end
	end
	local text = if string.sub(key, 1, 15) == "events_display." then Lang.t(key, params) else key
	return { text = text, tone = if DANGER[m.kind] then "danger" elseif GOOD[m.kind] then "good" else nil }
end

-- Radial menu (MainRadialMenu + RadialMenuElements) -------------------------------------
-- The right-click / long-press menu for one tile, as a list the action sheet
-- draws. `actions` is the server's playerActions for the tile with
-- buildables. OpenFront draws icons; the labels here are its strings where
-- it has them, short English otherwise. Each item either sends `intent`,
-- opens `sub` (build and attack lists, bulk amounts), or names a `panel`
-- for the UI to open.

export type MenuItem = {
	id: string,
	label: string,
	enabled: boolean,
	intent: { [string]: any }?,
	sub: { MenuItem }?,
	panel: string?, -- "player" (PlayerPanel.show)
	cost: number?,
	count: number?,
	description: string?,
	timerFraction: number?,
}
export type ContextMenu = { tile: number, selected: number?, center: MenuItem, items: { MenuItem } }

-- BuildMenu's flattenedBuildTable order; which of them count levels.
local BUILD_TABLE = { "Atom Bomb", "MIRV", "Hydrogen Bomb", "Warship", "Port", "Missile Silo", "SAM Launcher", "Defense Post", "City", "Factory" }
local BUILDABLE_ATTACKS = { ["Atom Bomb"] = true, ["Hydrogen Bomb"] = true, MIRV = true, Warship = true }
local STRUCTURES = { City = true, ["Defense Post"] = true, ["SAM Launcher"] = true, ["Missile Silo"] = true, Port = true, Factory = true }
local NUKE_BULK_STEPS: { number } = { 2, 5 }
local STRUCTURE_BULK_STEPS: { number } = { 5, 10 }
local MAX_UPGRADE_AMOUNT = 50
local DELETE_SELECTION_RADIUS = 5

-- GameTypes.ts bulkCost / maxBulkAmount.
function HudModel.bulkCost(bu: { [string]: any }, amount: number): number
	local totals = bu.upgradeCosts
	if totals ~= nil and totals[amount] ~= nil then
		return totals[amount]
	end
	return bu.cost * amount
end

function HudModel.maxBulkAmount(bu: { [string]: any }, gold: number): number
	local max = 0
	for n = 1, MAX_UPGRADE_AMOUNT do
		if bu.upgradeCosts ~= nil and n > #bu.upgradeCosts then
			break
		end
		if HudModel.bulkCost(bu, n) > gold then
			break
		end
		max = n
	end
	return max
end

-- PlayerView.readyMissileCount: loaded tubes across finished silos.
function HudModel.readyMissileCount(state: any): number
	local n = 0
	for _, u in state.units do
		if u.owner == state.you and u.type == "Missile Silo" and u.active ~= false and not u.underConstruction then
			n += math.max(0, (u.level or 1) - (if u.missileTimerQueue then #u.missileTimerQueue else 0))
		end
	end
	return n
end

local function manhattan(state: any, a: number, b: number): number
	local w = state.width
	return math.abs(a % w - b % w) + math.abs(a // w - b // w)
end

-- deleteUnitElement: your nearest finished structure within 5 tiles.
local function deletable(state: any, tile: number): number?
	local best, bestDist = nil, math.huge
	for id, u in state.units do
		if u.owner == state.you and u.active ~= false and STRUCTURES[u.type] and not u.underConstruction and not u.markedForDeletion then
			local d = manhattan(state, u.tile, tile)
			if d <= DELETE_SELECTION_RADIUS and (d < bestDist or (d == bestDist and id < (best :: number))) then
				best, bestDist = id, d
			end
		end
	end
	return best
end

-- createMenuElements: the build (own territory) or attack list.
local function unitList(state: any, tile: number, actions: { [string]: any }, filter: "attack" | "build", rocketDirectionUp: boolean): { MenuItem }
	local config = state:config()
	local gold = state.gold
	local levels = levelsByType(state)
	local out = {}
	for _, t in BUILD_TABLE do
		if config:isUnitDisabled(t) or (BUILDABLE_ATTACKS[t] == true) ~= (filter == "attack") then
			continue
		end
		local bu = nil
		for _, b in actions.buildableUnits or {} do
			if b.type == t then
				bu = b
			end
		end
		local can = bu ~= nil and (bu.canBuild ~= false or bu.canUpgrade ~= false)
		local item: MenuItem = {
			id = `{filter}_{t}`,
			label = Lang.t(`unit_type.{LANG_KEY[t]}`),
			description = Lang.t(`build_menu.desc.{LANG_KEY[t]}`),
			enabled = can,
			cost = if bu then bu.cost else 0,
			count = if NUKES[t] then nil else levels[t] or 0,
		}
		if can and bu then
			if bu.canUpgrade ~= false then
				item.intent = { type = "upgrade_structure", unitId = bu.canUpgrade, unit = t }
			else
				local aimed = t == "Atom Bomb" or t == "Hydrogen Bomb" or ArsenalUnits.AIMED[t] == true
				item.intent = { type = "build_unit", unit = t, tile = tile, rocketDirectionUp = if aimed then rocketDirectionUp else nil }
			end
			-- Bulk amounts: four fixed slots (x1, two steps, the most you can
			-- afford now), only when more than one is possible.
			local stackableNuke = t == "Atom Bomb" and bu.canBuild ~= false
			if bu.canUpgrade ~= false or stackableNuke then
				local maxAmount = HudModel.maxBulkAmount(bu, gold)
				if stackableNuke then
					maxAmount = math.min(maxAmount, HudModel.readyMissileCount(state))
				end
				if maxAmount > 1 then
					local steps: { number } = if stackableNuke then NUKE_BULK_STEPS else STRUCTURE_BULK_STEPS
					local slots = { 1 }
					for _, step in steps do
						table.insert(slots, step)
					end
					table.insert(slots, maxAmount)
					local sub = {}
					for i, amount in slots do
						local cost = HudModel.bulkCost(bu, amount)
						local isMax = i == #slots
						table.insert(sub, {
							id = if isMax then `upgrade_{t}_max` else `upgrade_{t}_{amount}`,
							label = Lang.t("build_menu.upgrade_amount", { amount = amount }),
							enabled = amount <= maxAmount and gold >= cost,
							cost = cost,
							intent = if stackableNuke
								then { type = "build_unit", unit = t, tile = tile, rocketDirectionUp = rocketDirectionUp, amount = amount }
								else { type = "upgrade_structure", unitId = bu.canUpgrade, unit = t, amount = amount },
						})
					end
					item.sub = sub
				end
			end
		end
		table.insert(out, item)
	end
	return out
end

-- The menu for `tile`; `ratio` is the attack slider (0..1).
function HudModel.contextMenu(state: any, tile: number, actions: { [string]: any }, ratio: number, rocketDirectionUp: boolean): ContextMenu
	local me = state:me()
	local you = state.you
	local owner = state:ownerAt(tile)
	local selected = if owner ~= 0 and state.players[owner] then owner else nil
	local inSpawn = state:inSpawnPhase()
	local isLand = actions.isLand == true
	local interaction = actions.interaction or {}
	local troops = if me then me.troops else 0
	local selectedView = if selected then state.players[selected] else nil
	local friendly = selected ~= nil and HudModel.isFriendly(state, selected, you)
	local disconnected = selectedView ~= nil and selectedView.disconnected == true

	-- centerButtonElement: spawn, donate troops to a friend, or attack.
	local center: MenuItem
	if inSpawn then
		local can = isLand and not state:config():isRandomSpawn() and selected == nil
		center = { id = "center", label = "Spawn", enabled = can, intent = { type = "spawn", tile = tile } }
	elseif friendly and not disconnected then
		local amount = math.floor(ratio * troops)
		center = {
			id = "center",
			label = Lang.t("player_panel.send_troops"),
			enabled = isLand and interaction.canDonateTroops == true,
			intent = if amount > 0 and selectedView then { type = "donate_troops", recipient = selectedView.id, troops = amount } else nil,
		}
	else
		center = {
			id = "center",
			label = "Attack",
			enabled = isLand and actions.canAttack == true,
			intent = { type = "attack", targetID = if selectedView then selectedView.id else nil, troops = ratio * troops },
		}
	end

	local info: MenuItem = { id = "info", label = "Info", enabled = selected ~= nil and not inSpawn, panel = "player" }
	local function allyRequest(): MenuItem?
		if interaction.canBreakAlliance then
			return nil -- displayed only while not allied
		end
		return {
			id = "ally_request",
			label = Lang.t("player_panel.send_alliance"),
			enabled = interaction.canSendAllianceRequest == true,
			intent = if selectedView then { type = "allianceRequest", recipient = selectedView.id } else nil,
		}
	end
	local items: { MenuItem } = { info }
	local function add(item: MenuItem?)
		if item then
			table.insert(items, item)
		end
	end
	if selected ~= nil and selected == you then
		local cooldown = actions.deleteUnitCooldown or 0
		local target = deletable(state, tile)
		add({
			id = "delete",
			label = Lang.t("radial_menu.delete_unit_title"),
			description = Lang.t("radial_menu.delete_unit_description"),
			enabled = isLand and not inSpawn and cooldown <= 0 and target ~= nil,
			intent = if target then { type = "delete_unit", unitId = target } else nil,
		})
		add(allyRequest())
		add({ id = "build", label = "Build", enabled = not inSpawn, sub = unitList(state, tile, actions, "build", rocketDirectionUp) })
	else
		local allied = selectedView ~= nil and table.find(selectedView.allies, you) ~= nil
		if allied and not disconnected then
			add({
				id = "ally_break",
				label = Lang.t("player_panel.break_alliance"),
				enabled = interaction.canBreakAlliance == true,
				intent = if selectedView then { type = "breakAlliance", recipient = selectedView.id } else nil,
			})
		else
			local canBoat = false
			for _, b in actions.buildableUnits or {} do
				if b.type == "Transport" and b.canBuild ~= false then
					canBoat = true
				end
			end
			add({ id = "boat", label = "Boat", enabled = canBoat, intent = { type = "boat", dst = tile, troops = ratio * troops } })
		end
		local info2 = interaction.allianceInfo
		if info2 and info2.inExtensionWindow then
			local window = math.max(1, state:config():allianceExtensionPromptOffset())
			add({
				id = "ally_extend",
				label = Lang.t("events_display.renew_alliance"),
				enabled = info2.canExtend == true,
				intent = if selectedView then { type = "allianceExtension", recipient = selectedView.id } else nil,
				timerFraction = math.clamp(math.max(0, info2.expiresAt - state.tick) / window, 0, 1),
			})
		else
			add(allyRequest())
		end
		local hasBuildableAttacks = false
		for _, b in actions.buildableUnits or {} do
			if BUILDABLE_ATTACKS[b.type] and b.canBuild ~= false then
				hasBuildableAttacks = true
			end
		end
		if friendly and not disconnected and not hasBuildableAttacks then
			add({
				id = "donate_gold",
				label = Lang.t("player_panel.send_gold"),
				enabled = not inSpawn and interaction.canDonateGold == true,
				intent = if selectedView then { type = "donate_gold", recipient = selectedView.id, gold = nil } else nil,
			})
		else
			add({ id = "attack", label = "Weapons", enabled = not inSpawn, sub = unitList(state, tile, actions, "attack", rocketDirectionUp) })
		end
	end
	return { tile = tile, selected = selected, center = center, items = items }
end

-- The wheel (Bruno, 2026-10-28, feature 1; mockup B): the radial menu's
-- items as tiles round a close button, on every device. From contextMenu:
--   - the centre action (attack, send troops, spawn) is the top tile, in
--     yellow; the red centre closes
--   - OpenFront's other items, plus Emoji (a second ring of 8 emojis and
--     More, as the source's infoEmojiElement) and Focus (centre the camera)
--   - your own land gives Build, Info and Focus (Bruno), and Delete while a
--     structure of yours is in reach
--   - unowned land leaves out Info and Ally, which need a player
-- Build and Weapons keep their sub-lists (`sub`) for the second ring.
export type WheelItem = {
	id: string,
	label: string,
	glyph: string,
	enabled: boolean,
	primary: boolean?,
	intent: { [string]: any }?,
	panel: string?, -- "player": the player panel
	sub: { MenuItem }?,
	ring: string?, -- "emoji": the emoji ring
	focus: boolean?, -- centre the camera on the tile
	cost: number?,
	timerFraction: number?,
}
local WHEEL_GLYPH = {
	info = "info",
	boat = "boat",
	ally_request = "alliance",
	ally_extend = "alliance",
	ally_break = "traitor",
	attack = "atom",
	build = "build",
	delete = "close",
	donate_gold = "gold",
}
local WHEEL_LABEL = { attack = "Weapons", ally_request = "Ally", ally_extend = "Renew", ally_break = "Break", donate_gold = "Gold", delete = "Delete" }
function HudModel.wheel(state: any, menu: ContextMenu): { title: string, items: { WheelItem } }
	local selected = menu.selected
	local own = selected ~= nil and selected == state.you
	local items: { WheelItem } = {}
	local function from(m: MenuItem, primary: boolean?): WheelItem
		return {
			id = m.id,
			label = WHEEL_LABEL[m.id] or m.label,
			glyph = WHEEL_GLYPH[m.id] or "target",
			enabled = m.enabled,
			primary = primary,
			intent = m.intent,
			panel = m.panel,
			sub = m.sub,
			cost = m.cost,
			timerFraction = m.timerFraction,
		}
	end
	local byId: { [string]: MenuItem } = {}
	for _, m in menu.items do
		byId[m.id] = m
	end
	local focus: WheelItem = { id = "focus", label = "Focus", glyph = "focus", enabled = true, focus = true }
	if own then
		local build = byId.build
		if build then
			table.insert(items, from(build, true))
		end
		if byId.info then
			table.insert(items, from(byId.info))
		end
		table.insert(items, focus)
		local delete = byId.delete
		if delete and delete.enabled then
			table.insert(items, from(delete))
		end
		return { title = "YOUR LAND", items = items }
	end
	local c = menu.center
	local center = from(c, true)
	center.id = "center"
	center.enabled = c.enabled and c.intent ~= nil
	center.glyph = if c.intent and c.intent.type == "donate_troops" then "troops" elseif c.intent and c.intent.type == "spawn" then "flag" else "sword"
	table.insert(items, center)
	-- Clockwise from the top, as mockup B: boat or break, ally, weapons or
	-- gold, focus, emoji, info.
	local emoji: WheelItem? = if selected ~= nil then { id = "emoji", label = "Emoji", glyph = "emoji", enabled = not state:inSpawnPhase(), ring = "emoji" } else nil
	local order = { "boat", "ally_break", "ally_request", "ally_extend", "attack", "donate_gold", "focus", "emoji", "info" }
	for _, id in order do
		if id == "focus" then
			table.insert(items, focus)
		elseif id == "emoji" then
			if emoji then
				table.insert(items, emoji)
			end
		elseif byId[id] and not (selected == nil and (id == "info" or id == "ally_request")) then
			table.insert(items, from(byId[id]))
		end
	end
	local view = if selected then state.players[selected] else nil
	return { title = if view then string.upper(view.displayName) else "UNCLAIMED LAND", items = items }
end

-- The card a tap on another player's land opens when "Select before
-- attacking" is on (Bruno, 2026-10-28; OpenFront's leftClickOpensMenu shows
-- the radial menu instead). `actions` is playerActions for the tile with
-- buildables. The main button follows the radial menu's rules:
--   - a friend: send troops (centerButtonElement)
--   - a tap on their ocean coast that a boat can reach: invade by boat
--     (Bruno: the coast picks the boat even when you share a border)
--   - else attack by land when you can, else by boat when you can
-- Ally sends a request, or breaks an alliance you have. Nil for unowned
-- land, your own land and the spawn phase.
export type AttackCard = {
	other: number,
	name: string,
	kind: string, -- "Player", "Nation" or "Tribe"
	relation: string, -- "ALLY", "TEAM" or "NEUTRAL"
	troops: number,
	tiles: number,
	boat: boolean, -- the main button invades by sea
	main: MenuItem,
	ally: MenuItem?,
}
local KIND = { HUMAN = "Player", NATION = "Nation", BOT = "Tribe" }
function HudModel.attackCard(state: any, tile: number, actions: { [string]: any }, ratio: number): AttackCard?
	local you = state.you
	local owner = state:ownerAt(tile)
	local other = if owner ~= 0 then state.players[owner] else nil
	if other == nil or owner == you or state:inSpawnPhase() then
		return nil
	end
	local me = state:me()
	local amount = ratio * (if me then me.troops else 0)
	local interaction = actions.interaction or {}
	local friendly = HudModel.isFriendly(state, owner, you)
	local allied = table.find(other.allies, you) ~= nil
	local canBoat = false
	for _, b in actions.buildableUnits or {} do
		if b.type == "Transport" and b.canBuild ~= false then
			canBoat = true
		end
	end
	local boat = false
	local main: MenuItem
	if friendly and not other.disconnected then
		main = {
			id = "send",
			label = Lang.t("player_panel.send_troops"),
			enabled = interaction.canDonateTroops == true and math.floor(amount) > 0,
			intent = { type = "donate_troops", recipient = other.id, troops = math.floor(amount) },
		}
	else
		boat = canBoat and (actions.isOceanShore == true or actions.canAttack ~= true)
		main = if boat
			then { id = "boat", label = "Invade", enabled = true, intent = { type = "boat", dst = tile, troops = amount } }
			else { id = "attack", label = "Attack", enabled = actions.isLand == true and actions.canAttack == true, intent = { type = "attack", targetID = other.id, troops = amount } }
	end
	local ally: MenuItem? = nil
	if allied and not other.disconnected then
		ally = { id = "ally_break", label = Lang.t("player_panel.break_alliance"), enabled = interaction.canBreakAlliance == true, intent = { type = "breakAlliance", recipient = other.id } }
	elseif not allied then
		ally = { id = "ally_request", label = "Ally", enabled = interaction.canSendAllianceRequest == true, intent = { type = "allianceRequest", recipient = other.id } }
	end
	return {
		other = owner,
		name = other.displayName,
		kind = KIND[other.type] or "Player",
		relation = if allied then "ALLY" elseif friendly then "TEAM" else "NEUTRAL",
		troops = other.troops,
		tiles = other.tiles,
		boat = boat,
		main = main,
		ally = ally,
	}
end

-- "Expanding with N" / "Attacking X with N" (Bruno, 2026-10-28, feature 3,
-- after RoWorld): the troops you just sent, from the confirmed attacks. A
-- new outgoing attack is news, and so is one that grew (OpenFront merges a
-- second send at the same target into the attack already under way). `prev`
-- is the last call's map of attack id to troops; nil makes a baseline with
-- no news (a snapshot, or the first tick).
export type SendToast = { target: number, troops: number, text: string }
function HudModel.sendToasts(state: any, prev: { [number]: number }?): ({ SendToast }, { [number]: number })
	local now: { [number]: number } = {}
	local out: { SendToast } = {}
	for _, a in state.attacks do
		if a.outgoing and a.attacker == state.you and not a.retreating then
			now[a.id] = a.troops
			local before = if prev then prev[a.id] else a.troops
			local sent = if before == nil then a.troops else a.troops - before
			-- Troops are stored at ten times what's shown (renderTroops).
			if sent >= 10 then
				local target = state.players[a.target]
				local troops = Format.renderTroops(sent)
				table.insert(out, {
					target = a.target,
					troops = sent,
					text = if a.target == 0 or target == nil then `Expanding with {troops}` else `Attacking {target.displayName} with {troops}`,
				})
			end
		end
	end
	return out, now
end

-- The card a tap on your own warship opens (Bruno, 2026-10-28, feature 13;
-- OpenFront has no such card). From the confirmed unit record: health, the
-- veterancy level and what it is doing. Nil when the unit is gone, isn't a
-- warship or isn't yours.
export type WarshipCard = {
	id: number,
	health: number,
	maxHealth: number,
	veterancy: number,
	maxVeterancy: number,
	status: string, -- "PATROLLING", "IN COMBAT", "RETREATING" or "REPAIRING"
	patrolTile: number?,
}
local WARSHIP_STATUS = { patrolling = "PATROLLING", retreating = "RETREATING", docked = "REPAIRING" }
function HudModel.warshipCard(state: any, unitId: number): WarshipCard?
	local u = state.units[unitId]
	if u == nil or u.type ~= "Warship" or not u.active or u.owner ~= state.you then
		return nil
	end
	local w = u.warship or {}
	local status = WARSHIP_STATUS[w.state] or "PATROLLING"
	if w.inCombat and status == "PATROLLING" then
		status = "IN COMBAT"
	end
	return {
		id = unitId,
		health = u.health or 0,
		maxHealth = u.maxHealth or 0,
		veterancy = w.veterancy or 0,
		maxVeterancy = EngineConfig.warshipMaxVeterancy(nil :: any),
		status = status,
		patrolTile = w.patrolTile,
	}
end

-- Quick chat: categories with their phrases in English.
function HudModel.quickChat(): { { name: string, label: string, entries: { { key: string, text: string, requiresPlayer: boolean } } } }
	local out = {}
	for _, c in QuickChat.categories do
		local entries = {}
		for _, e in c.entries do
			table.insert(entries, {
				key = `{c.name}.{e.key}`,
				text = Lang.t(`chat.{c.name}.{e.key}`),
				requiresPlayer = e.requiresPlayer,
			})
		end
		table.insert(out, { name = c.name, label = Lang.t(`chat.cat.{c.name}`), entries = entries })
	end
	return out
end

return HudModel
