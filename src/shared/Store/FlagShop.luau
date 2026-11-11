--!strict
-- The Flag Shop's offers (docs/design/rofront-ui-pass.md, screen 5): a
-- limited event section while an event runs, and four "today's flags" that
-- change at 00:00 UTC. The choice depends only on the UTC date, so every
-- server shows the same flags. Pure.

local FlagList = require(script.Parent.FlagList) :: { { id: string, name: string, rarity: string, set: string } }

local FlagShop = {}

FlagShop.DAILY_COUNT = 4
local DAY = 86400

-- Events: [startsAt, endsAt) in Unix time (UTC). `stamp`: the Flag Shop
-- header's rubber stamp (UiAssets).
FlagShop.EVENTS = {
	{ id = "halloween", name = "Halloween", set = "halloween", stamp = "stamp_halloween", startsAt = 1760659200, endsAt = 1762214400 }, -- 2025-10-17 .. 2025-11-04
	{ id = "halloween26", name = "Halloween", set = "halloween", stamp = "stamp_halloween", startsAt = 1792195200, endsAt = 1793750400 }, -- 2026-10-17 .. 2026-11-04
}

-- Days since 1970-01-01 of a UTC date (Howard Hinnant's days_from_civil).
local function dayNumber(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = y // 400
	local yoe = y - era * 400
	local doy = (153 * (if m > 2 then m - 3 else m + 9) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end
FlagShop._dayNumber = dayNumber

-- Thanksgiving (Bruno, 2026-11-11), every year: from a week before US
-- Thanksgiving (November's 4th Thursday) through the Tuesday after.
function FlagShop.thanksgiving(year: number): { id: string, name: string, set: string, stamp: string, startsAt: number, endsAt: number }
	local nov1 = dayNumber(year, 11, 1)
	local weekday = (nov1 + 4) % 7 -- 0 = Sunday (1970-01-01 was a Thursday)
	local thursday = nov1 + (4 - weekday) % 7 + 21
	return { id = `thanksgiving{year}`, name = "Thanksgiving", set = "thanksgiving", stamp = "stamp_thanksgiving", startsAt = (thursday - 7) * DAY, endsAt = (thursday + 6) * DAY }
end

export type Offers = {
	event: { id: string, name: string, stamp: string, endsAt: number, flags: { string } }?,
	daily: { string },
	nextDailyAt: number,
}

local function pool(set: string): { string }
	local out = {}
	for _, f in FlagList do
		if f.set == set then
			table.insert(out, f.id)
		end
	end
	return out
end

-- A small deterministic shuffle (xorshift on the day number).
local function pick(list: { string }, count: number, seed: number): { string }
	local items = table.clone(list)
	local s = (seed * 2654435761) % 4294967296
	if s == 0 then
		s = 1
	end
	local out = {}
	for _ = 1, math.min(count, #items) do
		s = bit32.bxor(s, bit32.lshift(s, 13))
		s = bit32.bxor(s, bit32.rshift(s, 17))
		s = bit32.bxor(s, bit32.lshift(s, 5))
		local i = s % #items + 1
		table.insert(out, table.remove(items, i) :: string)
	end
	return out
end

-- Today's flags (Bruno, 2026-11-11: a big pool that changes by itself every
-- day): the pool is shuffled once a cycle of #pool / DAILY_COUNT days and dealt
-- out DAILY_COUNT a day, so every flag shows once before any repeats. The first
-- day of a cycle trades away any flag the day before had (no flag two days
-- running across the turn).
-- (The trade takes from the cycle's middle days only, so a cycle's last day is
-- its plain shuffle's and the day before a turn is known without the chain.)
local function cycleOrder(list: { string }, cycle: number): { string }
	local n = FlagShop.DAILY_COUNT
	local days = #list // n
	local order = pick(list, #list, cycle + 1)
	if cycle > 0 then
		local prev = pick(list, #list, cycle)
		local last = {}
		for i = (days - 1) * n + 1, days * n do
			last[prev[i]] = true
		end
		for i = 1, n do
			if last[order[i]] then
				for j = n + 1, (days - 1) * n do
					if not last[order[j]] then
						order[i], order[j] = order[j], order[i]
						break
					end
				end
			end
		end
	end
	return order
end

function FlagShop.daily(day: number): { string }
	local list = pool("daily")
	local days = #list // FlagShop.DAILY_COUNT
	if days < 2 then
		return pick(list, FlagShop.DAILY_COUNT, day)
	end
	local order = cycleOrder(list, day // days)
	local first = (day % days) * FlagShop.DAILY_COUNT
	return table.move(order, first + 1, first + FlagShop.DAILY_COUNT, 1, {})
end

function FlagShop.offers(now: number): Offers
	local day = now // DAY
	local event = nil
	local year = 1970 + day // 365 -- (a lower bound; both candidates are checked)
	local events = table.clone(FlagShop.EVENTS)
	for y = year - 1, year + 1 do
		table.insert(events, FlagShop.thanksgiving(y))
	end
	for _, e in events do
		if now >= e.startsAt and now < e.endsAt then
			event = { id = e.id, name = e.name, stamp = e.stamp, endsAt = e.endsAt, flags = pool(e.set) }
		end
	end
	return {
		event = event,
		daily = FlagShop.daily(day),
		nextDailyAt = (day + 1) * DAY,
	}
end

-- Whether a flag is on sale right now.
function FlagShop.onSale(now: number, flagId: string): boolean
	local offers = FlagShop.offers(now)
	if table.find(offers.daily, flagId) then
		return true
	end
	return offers.event ~= nil and table.find(offers.event.flags, flagId) ~= nil
end

return FlagShop
