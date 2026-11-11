--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/frame/derive/RelationMatrix.ts; AllianceClusters.ts; src/client/render/gl/Renderer.ts updateNames), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Relations = {}
Relations.SIZE = 1024

-- Original: buildRelationMatrix. Embargo wins over either-side alliance/team.
function Relations.matrix(players: {any}): {size: number, data: buffer}
	local size=Relations.SIZE
	local data=buffer.create(size*size)
	local teams: {[string]: {number}}={}
	local function valid(id: number): boolean return id>0 and id<size end
	local function pair(a: number,b: number,value: number)
		if valid(a) and valid(b) then
			local ab,ba=a*size+b,b*size+a
			buffer.writeu8(data,ab,math.max(value,buffer.readu8(data,ab)))
			buffer.writeu8(data,ba,math.max(value,buffer.readu8(data,ba)))
		end
	end
	for _, p in players do
		if p.team~=nil and valid(p.smallID) then
			local bucket=teams[p.team] or {}; teams[p.team]=bucket; table.insert(bucket,p.smallID)
		end
	end
	for _, members in teams do for i=1,#members do for j=i+1,#members do pair(members[i],members[j],1) end end end
	for _, p in players do
		for _, id in p.allies or {} do pair(p.smallID,id,1) end
		for _, id in p.embargoes or {} do pair(p.smallID,id,2) end
	end
	return {size=size,data=data}
end

-- Original: computeAllianceClusters. Direct alliance edges union regardless of
-- teams; preserve roster/allies order because union root IDs are order-dependent.
function Relations.clusters(players: {any}): {[number]: number}
	local parent: {[number]: number}={}
	local function find(x: number): number
		while parent[x]~=x do local p=parent[x]; parent[x]=parent[p]; x=p end
		return x
	end
	for _, p in players do if p.smallID>0 then parent[p.smallID]=p.smallID end end
	for _, p in players do
		if p.smallID<=0 then continue end
		for _, ally in p.allies or {} do
			if parent[ally] then
				local a,b=find(p.smallID),find(ally)
				if a~=b then parent[b]=a end
			end
		end
	end
	local out={}; for id in parent do out[id]=find(id) end
	return out
end

-- Original: Renderer.updateNames SAM/unit friend set. Unlike border tints,
-- this uses own direct allies and teams, with no embargo override or ID cap.
function Relations.friendly(players: {any}, localPlayer: number): {[number]: boolean}
	local out: {[number]: boolean}={}
	local me=nil
	for _, p in players do if p.smallID==localPlayer then me=p; break end end
	if not me then return out end
	for _, id in me.allies or {} do out[id]=true end
	if me.team~=nil then
		for _, p in players do if p.smallID~=localPlayer and p.team==me.team then out[p.smallID]=true end end
	end
	return out
end

-- Original: NukeTelegraphs.classifyOwner; spectator sees enemy classification.
function Relations.classify(owner: number, localPlayer: number, data: buffer, size: number): number
	if localPlayer<=0 then return 2 end
	if owner==localPlayer then return 0 end
	if owner>0 and owner<size and localPlayer<size and buffer.readu8(data,localPlayer*size+owner)==1 then return 1 end
	return 2
end
return Relations
