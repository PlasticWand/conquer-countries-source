-- Invite rewards (Catalog.REFERRAL): Store/Profile's referrer, credit and
-- payout, and that they survive a save.
return function(t)
	local Profile = t.require("Store.Profile")
	local Catalog = t.require("Store.Catalog")

	t.test("the inviter is recorded once, only on a brand-new profile, never yourself", function()
		local p = Profile.new()
		t.ok(not Profile.setReferrer(p, 42, 42), "not yourself")
		t.ok(not Profile.setReferrer(p, 0, 1), "not nobody")
		t.ok(Profile.setReferrer(p, 42, 1))
		t.eq(p.referredBy, 42)
		t.ok(not Profile.setReferrer(p, 43, 1), "once")
		local old = Profile.new()
		old.matches = 2
		t.ok(not Profile.setReferrer(old, 42, 1), "not a returning player")
	end)

	t.test("the first counted match credits the inviter once", function()
		local p = Profile.new()
		t.eq(Profile.referralDue(p), nil, "not invited")
		Profile.setReferrer(p, 42, 1)
		t.eq(Profile.referralDue(p), nil, "no match yet")
		p.matches = 1
		t.eq(Profile.referralDue(p), 42)
		t.eq(Profile.referralDue(p), nil, "once")
	end)

	t.test("the inviter is paid up to the day's limit; the rest waits", function()
		local p = Profile.new()
		local per, limit = Catalog.REFERRAL.stars, Catalog.REFERRAL.perDay
		local stars, left = Profile.payReferrals(p, 2, 100)
		t.eq(stars, 2 * per)
		t.eq(left, 0)
		stars, left = Profile.payReferrals(p, limit, 100)
		t.eq(stars, (limit - 2) * per)
		t.eq(left, 2)
		stars, left = Profile.payReferrals(p, 2, 100)
		t.eq(stars, 0, "the day is full")
		t.eq(left, 2)
		stars, left = Profile.payReferrals(p, 2, 101)
		t.eq(stars, 2 * per, "a new day")
		t.eq(left, 0)
		t.eq(p.stars, (limit + 2) * per)
		t.eq(select(1, Profile.payReferrals(p, 0, 101)), 0)
	end)

	t.test("the fields survive a save", function()
		local p = Profile.new()
		Profile.setReferrer(p, 42, 1)
		p.matches = 1
		Profile.referralDue(p)
		Profile.payReferrals(p, 1, 7)
		local back = Profile.decode(Profile.encode(p)) :: any
		t.eq(back.referredBy, 42)
		t.eq(back.referralCredited, true)
		t.eq(back.referralDay, 7)
		t.eq(back.referralsToday, 1)
	end)
end
