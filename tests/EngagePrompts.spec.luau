-- The one-time prompts after a match (Shared/EngagePrompts): notifications
-- first, then favorite, each once.
return function(t)
	local EngagePrompts = t.require("EngagePrompts")

	t.test("notifications after the first match, once", function()
		t.eq(EngagePrompts.pick({ matches = 0, wins = 0, tipsSeen = {} }), nil)
		t.eq(EngagePrompts.pick({ matches = 1, wins = 0, tipsSeen = {} }), "notify")
		t.eq(EngagePrompts.pick({ matches = 1, wins = 0, tipsSeen = { "notify" } }), nil)
	end)

	t.test("favorite after a win or the third match, after notifications", function()
		t.eq(EngagePrompts.pick({ matches = 2, wins = 1, tipsSeen = {} }), "notify")
		t.eq(EngagePrompts.pick({ matches = 2, wins = 1, tipsSeen = { "notify" } }), "favorite")
		t.eq(EngagePrompts.pick({ matches = 2, wins = 0, tipsSeen = { "notify" } }), nil)
		t.eq(EngagePrompts.pick({ matches = 3, wins = 0, tipsSeen = { "notify" } }), "favorite")
		t.eq(EngagePrompts.pick({ matches = 9, wins = 2, tipsSeen = { "notify", "favorite" } }), nil)
	end)

	t.test("no view, no prompt", function()
		t.eq(EngagePrompts.pick(nil), nil)
		t.eq(EngagePrompts.pick({}), nil)
	end)
end
