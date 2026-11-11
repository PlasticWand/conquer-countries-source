--!strict
-- Parties on one server (docs/design/rofront-ui-pass.md, screen 2). A party
-- joins public queues together and shares a team in team games. Invites
-- expire; a party of one is no party. Keys are player ids as strings. Pure.

local Parties = {}
Parties.__index = Parties

Parties.MAX_SIZE = 8
Parties.INVITE_SECONDS = 60

export type Parties = typeof(setmetatable(
	{} :: {
		now: () -> number,
		partyOf: { [string]: { string } },
		invites: { [string]: { [string]: number } }, -- invitee -> inviter -> expiry
	},
	Parties
))

function Parties.new(now: () -> number): Parties
	return setmetatable({ now = now, partyOf = {}, invites = {} }, Parties)
end

-- The player's party, themselves included (a party of one if none).
function Parties.members(self: Parties, key: string): { string }
	return self.partyOf[key] or { key }
end

function Parties.invite(self: Parties, from: string, to: string): boolean
	if from == to or table.find(self:members(from), to) then
		return false
	end
	if #self:members(from) >= Parties.MAX_SIZE then
		return false
	end
	self.invites[to] = self.invites[to] or {}
	self.invites[to][from] = self.now() + Parties.INVITE_SECONDS
	return true
end

-- Pending, unexpired inviters for a player.
function Parties.pending(self: Parties, to: string): { string }
	local out = {}
	local now = self.now()
	local byFrom = self.invites[to]
	if byFrom then
		for from, expires in byFrom do
			if expires > now then
				table.insert(out, from)
			end
		end
	end
	table.sort(out)
	return out
end

function Parties.leave(self: Parties, key: string)
	local party = self.partyOf[key]
	if party == nil then
		return
	end
	local i = table.find(party, key)
	if i then
		table.remove(party, i)
	end
	self.partyOf[key] = nil
	if #party == 1 then
		self.partyOf[party[1]] = nil
	end
end

-- Accepts `from`'s invite: `to` leaves any party and joins `from`'s.
function Parties.accept(self: Parties, to: string, from: string): boolean
	local expires = self.invites[to] and self.invites[to][from]
	if expires == nil or expires <= self.now() then
		return false
	end
	self.invites[to][from] = nil
	if #self:members(from) >= Parties.MAX_SIZE then
		return false
	end
	self:leave(to)
	local party = self.partyOf[from]
	if party == nil then
		party = { from }
		self.partyOf[from] = party
	end
	table.insert(party, to)
	self.partyOf[to] = party
	return true
end

-- Makes `keys` one party (they leave any other), as they arrive on a server
-- together after a teleport (the teleport data says who was a party). Fewer
-- than two keys: no party. At most MAX_SIZE, in the given order.
function Parties.form(self: Parties, keys: { string })
	local members = {}
	for _, k in keys do
		if table.find(members, k) == nil and #members < Parties.MAX_SIZE then
			table.insert(members, k)
		end
	end
	for _, k in members do
		self:leave(k)
	end
	if #members < 2 then
		return
	end
	for _, k in members do
		self.partyOf[k] = members
	end
end

-- A player left the server: out of their party, invites dropped.
function Parties.remove(self: Parties, key: string)
	self:leave(key)
	self.invites[key] = nil
	for _, byFrom in self.invites do
		byFrom[key] = nil
	end
end

return Parties
