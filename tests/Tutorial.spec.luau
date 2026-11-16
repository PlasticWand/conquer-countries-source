-- The tutorial (Shared/Tutorial, ported from RoWorld): its numbers, the
-- rookie protections and the step machine, fed hand-built observations.
return function(t)
	local Tutorial = t.require("Tutorial")

	local function obs(over: { [string]: any }?): any
		local o = {
			touch = true,
			spawned = true,
			alive = true,
			playing = true,
			over = false,
			ordered = false,
			orderedOwner = false,
			orderedLand = false,
			troops = 1000,
			maxTroops = 2000,
			ratio = 0.2,
			aliveSeconds = 20,
			hasSpot = true,
			spotFree = true,
			neighbour = nil,
			neighbourName = nil,
			cityBuilt = false,
			placingCity = false,
			confirmOpen = false,
		}
		for k, v in over or {} do
			o[k] = v
		end
		return o
	end

	local function kinds(events: { any }, kind: string): { any }
		local out = {}
		for _, e in events do
			if e.kind == kind then
				table.insert(out, e)
			end
		end
		return out
	end

	-- Steps through the "Nice!" flash.
	local function settle(run: any, o: any): any
		local f = run.update(o, Tutorial.DONE_S + 0.01)
		return f
	end

	t.test("a new player has no state, no match and no tip", function()
		t.ok(Tutorial.isNew({ matches = 0, tipsSeen = {} }))
		t.ok(not Tutorial.isNew({ matches = 1, tipsSeen = {} }))
		t.ok(not Tutorial.isNew({ matches = 0, tutorial = "skipped", tipsSeen = {} }))
		t.ok(not Tutorial.isNew({ matches = 0, tipsSeen = { "expand" } }))
		t.ok(not Tutorial.isNew(nil))
	end)

	t.test("the floor keeps a share of the limit home and arms on troops or time", function()
		t.eq(Tutorial.floorShare(1000, 2000, nil), 1)
		-- 25% of 2000 = 500 stays: 500 of 1000 may go
		t.near(Tutorial.floorShare(1000, 2000, 0.25), 0.5, 1e-9)
		t.eq(Tutorial.floorShare(505, 2000, 0.25), 0) -- under 2% is nothing
		t.ok(not Tutorial.floorArmed(500, 2000, 3))
		t.ok(Tutorial.floorArmed(700, 2000, 3))
		t.ok(Tutorial.floorArmed(10, 2000, Tutorial.FLOOR_ARM_S))
		t.ok(Tutorial.rookie(4))
		t.ok(not Tutorial.rookie(5))
	end)

	t.test("the Attack bar's stops under the cap", function()
		t.eq(Tutorial.ratioStop(0.75, Tutorial.RATIO_CAP), 0.5)
		t.eq(Tutorial.ratioStop(0.35, Tutorial.RATIO_CAP), 0.35)
		t.eq(Tutorial.ratioStop(0.75, nil), 0.75)
	end)

	t.test("the steps run in order and pay out once at the end", function()
		local run = Tutorial.newRun()
		run.begin()
		local steps = {}
		local function note(f: any)
			for _, e in kinds(f.events, "step") do
				table.insert(steps, e.n)
			end
		end
		-- spawn: the spot is marked; the match counts as started after 1 s
		local f = run.update(obs({ spawned = false, playing = false }), 1.1)
		note(f)
		t.eq(f.mark.target, "spot")
		t.eq(f.ratioCap, Tutorial.RATIO_CAP)
		note(run.update(obs(), 0.1)) -- placed
		-- expand
		f = run.update(obs(), 0.1)
		note(f)
		t.eq(f.card.text, "Tap the land next to you to take it")
		t.eq(f.card.count, "2 / 6")
		t.eq(f.mark.target, "frontier")
		note(run.update(obs({ ordered = true, orderedLand = true }), 0.1))
		note(settle(run, obs({ troops = 300 })))
		-- grow: the troops refill first (30% of 2000 = 600)
		f = run.update(obs({ troops = 300 }), 0.1)
		note(f)
		t.eq(f.mark.target, "troops")
		t.eq(f.card.text, "Now let your troops refill")
		f = run.update(obs({ troops = 700 }), 0.1)
		t.eq(f.mark.target, "frontier")
		note(run.update(obs({ ordered = true, orderedLand = true }), 0.1))
		note(settle(run, obs()))
		-- attack: no neighbour yet, then one
		f = run.update(obs(), 0.1)
		t.eq(f.card.text, Tutorial.CONTACT_WAIT_LINE)
		f = run.update(obs({ neighbour = 7, neighbourName = "Zambia" }), 0.1)
		t.eq(f.card.text, "Tap Zambia, then press ATTACK")
		t.eq(f.mark.target, "neighbour")
		-- their card opens: the mark moves to ATTACK; closing it goes back
		f = run.update(obs({ neighbour = 7, neighbourName = "Zambia", attackCardOpen = true }), 0.1)
		t.eq(f.mark.target, "attack")
		t.eq(f.card.text, Tutorial.ATTACK_PRESS_LINE)
		f = run.update(obs({ neighbour = 7, neighbourName = "Zambia" }), 0.1)
		t.eq(f.mark.target, "neighbour")
		t.eq(f.card.text, "Tap Zambia, then press ATTACK")
		note(run.update(obs({ neighbour = 7, ordered = true, orderedOwner = true }), 0.1))
		note(settle(run, obs()))
		-- ratio: 50% is too much, 35% held is right
		f = run.update(obs({ ratio = 0.5 }), 0.1)
		t.eq(f.card.text, Tutorial.RATIO_TOO_MUCH)
		t.eq(f.card.tint, "red")
		run.update(obs({ ratio = 0.35 }), 0.1)
		note(run.update(obs({ ratio = 0.35 }), 0.15))
		-- city: gold is asked for once, as the step comes up; the mark
		-- follows the build flow
		f = settle(run, obs())
		note(f)
		t.eq(#kinds(f.events, "cityGold"), 1)
		f = run.update(obs(), 0.1)
		t.eq(#kinds(f.events, "cityGold"), 0)
		t.eq(f.mark.target, "city")
		f = run.update(obs({ placingCity = true }), 0.1)
		t.eq(f.mark.target, "ownLand")
		t.ok(not f.card.visible)
		f = run.update(obs({ placingCity = true, confirmOpen = true }), 0.1)
		t.eq(f.mark.target, "confirm")
		f = run.update(obs({ cityBuilt = true }), 0.1)
		note(f)
		t.eq(#kinds(f.events, "cityGold"), 0)
		local done = kinds(f.events, "finished")
		t.eq(#done, 1)
		t.eq(done[1].how, "done")
		t.ok(f.card.visible)
		t.eq(f.ratioCap, 1)
		t.eq(f.troopFloor, nil)
		t.eq(table.concat(steps, ","), "1,2,3,4,5,6,7,8")
	end)

	t.test("nobody picks a start: the marked spot is taken after 12 s", function()
		local run = Tutorial.newRun()
		run.begin()
		local f = run.update(obs({ spawned = false, playing = false }), Tutorial.AUTO_SPAWN_S - 1)
		t.eq(#kinds(f.events, "spawn"), 0)
		f = run.update(obs({ spawned = false, playing = false }), 2)
		t.eq(#kinds(f.events, "spawn"), 1)
		f = run.update(obs({ spawned = false, playing = false }), 1)
		t.eq(#kinds(f.events, "spawn"), 0)
	end)

	t.test("a stuck step is passed over, logged as passed", function()
		local run = Tutorial.newRun()
		run.begin()
		run.update(obs(), 0.1) -- spawned
		run.update(obs(), 0.1) -- expand shown
		local f = run.update(obs(), Tutorial.STEP_MAX_S + 1)
		local steps = kinds(f.events, "step")
		t.eq(#steps, 2) -- "Started", then the passed-over step
		t.eq(steps[1].passed, nil)
		t.eq(steps[2].name, "First Tap")
		t.eq(steps[2].passed, true)
		t.eq(#kinds(f.events, "sound"), 0) -- no "done" chime for it
		f = run.update(obs({ troops = 2000 }), 0.1)
		t.eq(f.card.count, "3 / 6")
	end)

	t.test("an early expansion counts, and says to wait next time", function()
		local run = Tutorial.newRun()
		run.begin()
		run.update(obs(), 0.1)
		run.update(obs(), 0.1)
		run.update(obs({ ordered = true }), 0.1)
		settle(run, obs({ troops = 100 }))
		run.update(obs({ troops = 100 }), 0.1) -- grow, not ready
		local f = run.update(obs({ troops = 100, ordered = true }), 0.1)
		t.eq(f.card.text, "Done! Next time, let the bar fill")
		t.eq(#kinds(f.events, "step"), 1)
	end)

	t.test("the floor arms from the attack step", function()
		local run = Tutorial.newRun()
		run.begin()
		local f = run.update(obs({ troops = 1500 }), 0.1)
		t.eq(f.troopFloor, nil)
		run.update(obs(), 0.1)
		run.update(obs({ ordered = true }), 0.1)
		settle(run, obs())
		run.update(obs({ troops = 2000 }), 0.1)
		run.update(obs({ ordered = true }), 0.1)
		f = settle(run, obs())
		f = run.update(obs({ troops = 1500 }), 0.1)
		t.eq(f.troopFloor, Tutorial.TROOP_FLOOR)
	end)

	t.test("Skip, and losing, stop it without the reward", function()
		local run = Tutorial.newRun()
		run.begin()
		run.update(obs(), 0.1)
		run.press()
		local f = run.update(obs(), 0.1)
		t.eq(kinds(f.events, "finished")[1].how, "skipped")
		t.eq(f.ratioCap, 1)
		t.ok(not f.card.visible)
		local lost = Tutorial.newRun()
		lost.begin()
		lost.update(obs(), 0.1)
		f = lost.update(obs({ alive = false }), 0.1)
		t.eq(kinds(f.events, "finished")[1].how, "left")
	end)
end
