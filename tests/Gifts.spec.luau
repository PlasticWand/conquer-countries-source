-- Gifts (Bruno, 2026-11-23): 3 crates, 5 crates or the Campaign Pass for a
-- friend; the buyer's outbox (Profile.giftsOut) and receiving.
return function(t)
	local Profile = t.require("Store.Profile")
	local Pass = t.require("Store.Pass")
	local Catalog = t.require("Store.Catalog")

	local NOW = Pass.EPOCH + 3600
	local function roll(): number
		return 0.5
	end

	t.test("a picked gift goes to the outbox, saved; the buyer gets nothing", function()
		local p = Profile.new()
		t.ok(Profile.pickGift(p, "giftCrate3", 42, NOW))
		t.eq(Profile.pickGift(p, "crate3", 42, NOW), false, "only gift products")
		local g = Profile.grant(p, "giftCrate3", "rcpt1", roll, NOW) :: any
		t.eq(g.kind, "giftSent")
		t.eq(#g.items, 0)
		t.eq(#p.giftsOut, 1)
		t.eq(p.giftsOut[1].to, 42)
		t.eq(p.pendingGift, nil, "the pick is used up")
		local back = Profile.decode(Profile.encode(p)) :: any
		t.eq(back.giftsOut[1].id, "rcpt1", "the outbox is saved")
		t.eq(Profile.grant(p, "giftCrate3", "rcpt1", roll, NOW), nil, "a receipt once")
	end)

	t.test("no fresh pick: the buyer gets it", function()
		local p = Profile.new()
		local g = Profile.grant(p, "giftCrate5", "r2", roll, NOW) :: any
		t.eq(#g.items, 5, "five crates opened for the buyer")
		local q = Profile.new()
		Profile.pickGift(q, "giftCrate5", 7, NOW)
		local late = Profile.grant(q, "giftCrate5", "r3", roll, NOW + Profile.GIFT_PICK_S + 1) :: any
		t.eq(#late.items, 5, "a stale pick")
		t.eq(#q.giftsOut, 0)
	end)

	t.test("receiving: crates, or the pass premium (5 crates if they have it)", function()
		local p = Profile.new()
		t.eq(#Profile.receiveGift(p, "giftCrate3", roll, NOW).items, 3)
		local pass = Profile.receiveGift(p, "giftPass", roll, NOW)
		t.eq(pass.kind, "giftPass")
		t.ok((Profile.passOf(p, NOW) :: any).premium)
		t.eq(#Profile.receiveGift(p, "giftPass", roll, NOW).items, 5, "already premium")
		for key in Profile.GIFTS do
			t.ok(Catalog.product(key) ~= nil, key .. " is a product")
		end
	end)
end
