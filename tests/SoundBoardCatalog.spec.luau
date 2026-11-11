--!strict
-- The sound board's candidate list stays well formed: unique keys, known
-- groups and kinds, every candidate a licensed numeric asset, cuts within
-- Bruno's 3 s, and every saved pick one of its mechanic's candidates.
return function(t)
	local fs, luau = require("@lune/fs"), require("@lune/luau")
	local Harness = luau.load(fs.readFile("tests/harness.luau"))()
	local root = Harness.mount("src/client/Ui/OpenFront", "OpenFrontUi")
	local Catalog = Harness.require(root.SoundBoardCatalog)
	local SoundPicks = Harness.require(root.SoundPicks)

	t.test("every entry is well formed", function()
		local groups, keys = {}, {}
		for _, g in Catalog.GROUPS do
			groups[g] = true
		end
		for _, e in Catalog.ENTRIES do
			t.ok(keys[e.key] == nil, `duplicate key {e.key}`)
			keys[e.key] = true
			t.ok(groups[e.group] == true, `{e.key}: unknown group {e.group}`)
			t.ok(e.kind == "sfx" or e.kind == "loop" or e.kind == "pop" or e.kind == "music", `{e.key}: kind {e.kind}`)
			t.ok(#e.candidates >= 2, `{e.key}: needs candidates to choose from`)
			t.ok((e.pick or 1) <= #e.candidates, `{e.key}: picks more than it lists`)
			local seen = {}
			for _, c in e.candidates do
				t.ok(c.id > 0 and c.id == math.floor(c.id), `{e.key}: bad id {c.id}`)
				t.ok(not seen[c.id], `{e.key}: {c.id} listed twice`)
				seen[c.id] = true
				t.ok(c.by == "PSE" or c.by == "APM" or c.by == "Roblox", `{e.key}: unlicensed source {c.by}`)
				t.ok(c.cut == nil or (c.cut > 0 and c.cut <= 3 and c.cut < c.seconds), `{e.key}: cut {c.cut}`)
			end
		end
	end)

	t.test("saved picks belong to their mechanic", function()
		local byKey = {}
		for _, e in Catalog.ENTRIES do
			byKey[e.key] = e
		end
		for key, ids in SoundPicks do
			local e = byKey[key]
			t.ok(e ~= nil, `pick for unknown mechanic {key}`)
			t.ok(#ids <= (e.pick or 1), `{key}: too many picks`)
			for _, id in ids do
				local found = false
				for _, c in e.candidates do
					found = found or c.id == id
				end
				t.ok(found, `{key}: {id} isn't a candidate`)
			end
		end
	end)
end
