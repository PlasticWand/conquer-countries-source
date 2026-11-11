-- The result card's words and numbers (ResultModel): team and free-for-all
-- verdicts, death, the stat trackers and the Stars rows.
return function(t)
	local ResultModel = t.require("OpenFront.ResultModel")

	local function state(winner: any, you: number): any
		return {
			me = function(self: any): any
				return self.players[self.you]
			end,
			you = you,
			winner = winner,
			players = {
				[1] = { smallID = 1, id = "ada00001", displayName = "Ada", type = "HUMAN", team = "Red", tiles = 300, troops = 10, alive = true },
				[2] = { smallID = 2, id = "bea00002", displayName = "Bea", type = "HUMAN", team = "Red", tiles = 500, troops = 10, alive = true },
				[3] = { smallID = 3, id = "cy000003", displayName = "Cy", type = "HUMAN", team = "Blue", tiles = 150, troops = 10, alive = true },
				[4] = { smallID = 4, id = "nat00004", displayName = "France", type = "NATION", team = "Blue", tiles = 50, troops = 10, alive = true },
			},
		}
	end

	t.test("a team win: every member sees VICTORY with the team's share; the others DEFEAT", function()
		local ada = ResultModel.card(state("Red", 1), false, 0, 1000)
		t.eq(ada.kind, "won")
		t.eq(ada.title, "VICTORY")
		t.eq(ada.sub, "Your team won with 80.0% of the land.")
		t.eq(ada.team, "Red")
		-- Bea, the other Red member, wins too (not just the top player).
		t.eq(ResultModel.card(state("Red", 2), false, 0, 1000).kind, "won")
		local cy = ResultModel.card(state("Red", 3), false, 0, 1000)
		t.eq(cy.kind, "lost")
		t.eq(cy.title, "DEFEAT")
		t.eq(cy.sub, "Red team won with 80.0% of the land.")
	end)

	t.test("free for all: the winner, a human or a nation, and you", function()
		local mine = ResultModel.card(state("bea00002", 2), false, 0, 1000)
		t.eq(mine.kind, "won")
		t.eq(mine.sub, "You conquered the world with 50.0% of the land.")
		t.eq(mine.team, nil)
		local other = ResultModel.card(state("bea00002", 1), false, 0, 1000)
		t.eq(other.kind, "lost")
		t.eq(other.sub, "Bea won with 50.0% of the land.")
		t.eq(ResultModel.card(state("nat00004", 1), false, 0, 1000).sub, "Nation France won with 5.0% of the land.")
	end)

	t.test("death: ELIMINATED with the time you fell", function()
		local c = ResultModel.card(state(nil, 1), true, 252, 1000)
		t.eq(c.kind, "died")
		t.eq(c.title, "ELIMINATED")
		t.eq(c.kicker, "YOUR NATION HAS FALLEN")
		t.eq(c.sub, "Your last territory fell at 4:12.")
	end)

	t.test("trackers keep the peaks and count only your conquests", function()
		local tr = ResultModel.newTracker()
		ResultModel.track(tr, { alive = true, tiles = 100, troops = 5000 }, 1000)
		ResultModel.track(tr, { alive = true, tiles = 40, troops = 9000 }, 1000)
		ResultModel.track(tr, { alive = false, tiles = 900, troops = 99999 }, 1000)
		t.near(tr.peakShare, 0.1, 1e-9)
		t.eq(tr.maxTroops, 9000)
		local me = { id = "ada00001" }
		ResultModel.trackEvents(tr, me, {
			{ type = "ConquestEvent", conquerorId = "ada00001", conqueredId = "x" },
			{ type = "ConquestEvent", conquerorId = "bea00002", conqueredId = "y" },
			{ type = "Emoji" },
			{ type = "ConquestEvent", conquerorId = "ada00001", conqueredId = "z" },
		})
		t.eq(tr.eliminated, 2)
	end)

	t.test("Stars rows: the next unowned weapon, and 2x only without the pass", function()
		local arsenal = {
			{ id = "w_reinforce", name = "Reinforcements", stars = 15000 },
			{ id = "w_mega", name = "Mega Nuke", stars = 30000 },
			{ id = "b_double", name = "2x Stars" },
		}
		local g = ResultModel.nextGoal(arsenal, { stars = 6835, owned = { "w_reinforce" } })
		t.eq(g and g.name, "MEGA NUKE")
		t.eq(g and g.have, 6835)
		t.eq(g and g.need, 30000)
		t.eq(g and g.ready, false)
		t.eq(ResultModel.nextGoal(arsenal, { stars = 40000, owned = { "w_reinforce" } }).ready, true)
		t.eq(ResultModel.nextGoal(arsenal, { stars = 1, owned = { "w_reinforce", "w_mega" } }), nil)
		t.eq(ResultModel.nextGoal(arsenal, nil), nil)
		t.eq(ResultModel.doubled(740, { doubleStars = false }), 1480)
		t.eq(ResultModel.doubled(740, { doubleStars = true }), nil)
		t.eq(ResultModel.doubled(0, { doubleStars = false }), nil)
	end)
end
