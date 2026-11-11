--!strict
-- CreditsText: the notices the licences require stay on the credits screen
-- (docs/LICENSING_PLAN.md).
return function(t)
	local CreditsText = t.require("CreditsText")

	local function all(placeVersion: number): string
		local parts = {}
		for _, s in CreditsText.sections(placeVersion) do
			table.insert(parts, s.title)
			for _, line in s.lines do
				table.insert(parts, line)
			end
			if s.copy then
				table.insert(parts, s.copy)
			end
		end
		return table.concat(parts, "\n")
	end

	t.test("every required notice is there", function()
		local text = all(42)
		for _, needed in {
			"© OpenFront and Contributors", -- OpenFront 7(b)
			"AGPL-3.0", -- the licence named
			"github.com/PlasticWand/conquer-countries-source", -- section 13: where the source is
			"place-v42", -- the exact version's source
			"ROWORLD",
			"© lukechatton and contributors",
			"CC BY-SA 4.0", -- OpenFront's resources
			"Wikimedia Commons, CC BY-SA 3.0 DE", -- the flags
			"OpenStreetMap contributors, ODbL",
			"Not affiliated with or endorsed by OpenFront", -- 7(c)
			"MIT License", -- colord
		} do
			t.ok(string.find(text, needed, 1, true) ~= nil, `missing: {needed}`)
		end
		t.ok(string.find(CreditsText.BAR, "© OpenFront and Contributors", 1, true) ~= nil, "the menu bar keeps 7(b)'s notice")
		t.ok(string.find(CreditsText.BAR, "RoWorld", 1, true) ~= nil, "and names RoWorld")
	end)

	t.test("an unpublished build says so instead of a tag", function()
		local text = all(0)
		t.ok(string.find(text, "unpublished", 1, true) ~= nil)
		t.ok(string.find(text, "place-v", 1, true) == nil)
	end)
end
