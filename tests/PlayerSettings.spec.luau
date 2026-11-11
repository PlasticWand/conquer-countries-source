-- The player's settings: defaults and what sanitize keeps from a client or
-- an old save (Bruno's settings pass, 2026-10-28).
return function(t)
	local PlayerSettings = t.require("PlayerSettings")

	t.test("defaults: labels and select-before-attacking on, music at half", function()
		local d = PlayerSettings.defaults()
		t.eq(d.territoryLabels, true, "territory labels on")
		t.eq(d.selectBeforeAttack, true, "select before attacking on")
		t.eq(d.musicVolume, 0.5, "music at half")
		t.eq(d.music, true, "music not muted")
	end)

	t.test("sanitize: an old save gets the new fields, odd volumes are clamped and stepped", function()
		local old = PlayerSettings.sanitize({ music = false, sounds = true, uiScale = 1.1, emojis = false })
		t.eq(old.music, false, "kept the mute")
		t.eq(old.territoryLabels, true, "new field defaulted")
		t.eq(old.musicVolume, 0.5, "new field defaulted")
		t.eq(PlayerSettings.sanitize({ musicVolume = 0.33 }).musicVolume, 0.35, "steps of 0.05")
		t.eq(PlayerSettings.sanitize({ musicVolume = 7 }).musicVolume, 1, "clamped high")
		t.eq(PlayerSettings.sanitize({ musicVolume = -1 }).musicVolume, 0, "clamped low")
		t.eq(PlayerSettings.sanitize({ musicVolume = 0 / 0 }).musicVolume, 0.5, "NaN ignored")
		t.eq(PlayerSettings.sanitize({ territoryLabels = false }).territoryLabels, false, "labels off kept")
		t.eq(PlayerSettings.sanitize({ territoryLabels = "no" }).territoryLabels, true, "a bad type ignored")
	end)
end
