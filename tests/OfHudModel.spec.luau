-- OpenFront port: the pure HUD wording (Lang plurals, HudModel.messageLine,
-- chat substitution) against small hand-built client states.
return function(t)
	local Lang = t.require("OpenFront.Lang")
	local HudModel = t.require("OpenFront.HudModel")

	local function state(): any
		return {
			me = function(self: any): any
				return self.players[self.you]
			end,
			you = 1,
			players = {
				[1] = { smallID = 1, id = "ada00001", displayName = "Ada", alive = true },
				[2] = { smallID = 2, id = "bea00002", displayName = "Bea 50%" },
			},
			units = {
				[7] = { id = 7, owner = 2, type = "Atom Bomb", troops = 0 },
				[8] = { id = 8, owner = 2, type = "Transport", troops = 12345 },
			},
		}
	end

	t.test("lockedArsenal: build weapons not unlocked, none without extra weapons", function()
		local st = state()
		t.eq(#HudModel.lockedArsenal(st), 0, "no Arsenal in this match")
		st.arsenal = { weapons = { megaNuke = true, airStrike = true, reinforcements = true } }
		local locked = HudModel.lockedArsenal(st)
		local ids, types = {}, {}
		for _, l in locked do
			ids[l.id] = true
			types[l.id] = l.type
		end
		t.ok(not ids.w_mega and not ids.w_airstrike, "unlocked ones left out")
		t.ok(not ids.w_reinforce and not ids.w_rapidreload, "no build unit: not in the fly-out")
		t.eq(types.w_artillery, "Artillery")
		t.eq(types.w_railgun, "Railgun")
		t.eq(#locked, 7)
	end)

	t.test("ICU plurals choose one or other and fill #", function()
		local one = Lang.t("events_display.alliance_nukes_destroyed_incoming", { count = 1, name = "Bea" })
		t.eq(one, "1 nuke launched by Bea was destroyed due to the alliance")
		local many = Lang.t("events_display.alliance_nukes_destroyed_incoming", { count = 3, name = "Bea" })
		t.eq(many, "3 nukes launched by Bea were destroyed due to the alliance")
	end)

	t.test("messageLine words every message as EventsDisplay does", function()
		local s = state()
		local nuke = HudModel.messageLine(s, { key = "events_display.atom_bomb_inbound", kind = "NUKE_INBOUND", params = { unitId = 7 } }) :: any
		t.eq(nuke.text, "Bea 50% - atom bomb inbound", "the bomb's owner by name")
		t.eq(nuke.tone, "danger")
		local boat = HudModel.messageLine(s, { key = "events_display.naval_invasion_inbound", kind = "NAVAL_INVASION_INBOUND", params = { unitId = 8 } }) :: any
		t.eq(boat.text, "Naval invasion incoming from Bea 50% (1.23K)", "with the boat's troops")
		local lost = HudModel.messageLine(s, { key = "events_display.unit_destroyed", kind = "UNIT_DESTROYED", params = { unit = "unit_type.city" } }) :: any
		t.eq(lost.text, "Your City was destroyed", "unit names translated")
		t.eq(HudModel.messageLine(s, { key = "events_display.received_gold_from_captured_ship", kind = "CAPTURED_ENEMY_UNIT", params = { gold = 5, name = "Bea" } }), nil, "captured-ship gold is a pip, not a line")
		local conquered = HudModel.messageLine(s, { key = "events_display.received_gold_from_conquest", kind = "CONQUERED_PLAYER", params = { name = "Bea", gold = 125000 } }) :: any
		t.eq(conquered.text, "Conquered Bea, received 125K gold")
		t.eq(conquered.tone, "good")
	end)

	t.test("quick chat with a target whose name has a %", function()
		local s = state()
		local line = HudModel.feedLine(s, { type = "DisplayChatEvent", key = "attack", category = "attack", target = "bea00002", playerID = 1, isFrom = true, recipient = "bea00002" })
		t.ok(line ~= nil and string.find(line.text, "Bea 50%", 1, true) ~= nil, "the name goes in as written")
	end)
end
