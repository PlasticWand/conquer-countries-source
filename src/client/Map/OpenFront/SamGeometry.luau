--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/passes/SamRadiusPass.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Trajectory=require(script.Parent.NukeTrajectory)
local Sam={}
local TAU,EPS=math.pi*2,1e-9
export type Circle={x:number,y:number,radius:number,r:number,g:number,b:number,alpha:number,group:number,spin:number,id:number,owner:number,offset:number}

-- Original: normalizeAngle / mergeIntervals, including the wrap and epsilon.
local function normalize(a:number):number return a%TAU end
local function merge(intervals:{{number}}):{{number}}
	local flat={}
	for _, interval in intervals do
		local s,e=normalize(interval[1]),normalize(interval[2])
		if e<s then table.insert(flat,{s,TAU}); table.insert(flat,{0,e}) else table.insert(flat,{s,e}) end
	end
	table.sort(flat,function(a,b) return a[1]<b[1] end)
	if #flat==0 then return {} end
	local out,current={},table.clone(flat[1])
	for i=2,#flat do
		local v=flat[i]
		if v[1]<=current[2]+EPS then current[2]=math.max(current[2],v[2])
		else table.insert(out,current); current=table.clone(v) end
	end
	table.insert(out,current); return out
end

-- Original: computeUncoveredArcs. Coincident centres intentionally skip the
-- enclosure branch, preserving the source's duplicate-circle behavior.
function Sam.uncovered(a:Circle,circles:{Circle}):{{number}}
	local covered={}
	for _, b in circles do
		if a==b then continue end
		local dx,dy=b.x-a.x,b.y-a.y
		local squared=dx*dx+dy*dy
		if squared<=EPS then continue end
		local diff=b.radius-a.radius
		if diff>=0 and squared<=diff*diff+EPS then return {} end
		local maximum=a.radius+b.radius
		if squared>=maximum*maximum-EPS then continue end
		local distance=math.sqrt(squared)
		local cosine=(a.radius*a.radius+squared-b.radius*b.radius)/(2*a.radius*distance)
		local phi=math.acos(math.clamp(cosine,-1,1))
		local theta=math.atan2(dy,dx)
		table.insert(covered,{theta-phi,theta+phi})
	end
	local merged=merge(covered)
	if #merged==0 then return {{0,TAU}} end
	local out,cursor={},0
	for _, v in merged do if v[1]>cursor+EPS then table.insert(out,{cursor,v[1]}) end; cursor=math.max(cursor,v[2]) end
	if cursor<TAU-EPS then table.insert(out,{cursor,TAU}) end
	return out
end

-- Original: collectSAMCircles / pushSAMCircles. Perspective mode merges all
-- friendlies and all enemies separately. Owner mode unions direct alliances.
function Sam.collect(units:{[number]:any},order:{number},width:number,tick:number,localPlayer:number,
	friendly:{[number]:boolean},clusters:{[number]:number},ownerMode:boolean?,palette:any?):{Circle}
	local dirty={}
	local function group(u:any):number
		if ownerMode then return clusters[u.owner] or u.owner end
		return if u.owner==localPlayer or friendly[u.owner] then 0 else 1
	end
	local function upgrading(u:any):boolean
		local s=u.samUpgrade
		return s~=nil and s.startTick~=nil and tick>=s.startTick and tick-s.startTick<(s.duration or 0)
	end
	for _, id in order do
		local u=units[id]
		if u and u.type=='SAM Launcher' and u.active~=false and upgrading(u) then dirty[group(u)]=true end
	end
	local out:{Circle}={}
	for _, id in order do
		local u=units[id]
		if not u or u.type~='SAM Launcher' or u.active==false then continue end
		local ally=u.owner==localPlayer or friendly[u.owner]==true
		local r,g,b=0,0,0
		if u.owner==localPlayer then g=1 elseif friendly[u.owner] then r,g=1,1 else r=1 end
		if ownerMode and palette and palette[u.owner] then local c=palette[u.owner].fill; r,g,b=c.r,c.g,c.b end
		local base=group(u)*2
		local function push(radius:number,alpha:number,offset:number,spin:number)
			table.insert(out,{x=u.tile%width,y=math.floor(u.tile/width),radius=radius,r=r,g=g,b=b,alpha=alpha,group=base+offset,spin=spin,id=id,owner=u.owner,offset=offset})
		end
		if upgrading(u) then
			local s=u.samUpgrade
			local target=Trajectory.samRange(s.targetLevel or 0)
			local radius=(s.startRange or 0)+(target-(s.startRange or 0))*math.clamp((tick-s.startTick)/s.duration,0,1)
			push(radius,if ally then 1 else .35,0,if ally then 1 else 0)
			push(target,if ally then .35 else 1,1,if ally then 0 else 1)
		else
			push(Trajectory.samRange(u.level or 1),1,0,1)
			if dirty[group(u)] then push(Trajectory.samRange(u.level or 1),if ally then .35 else 1,1,if ally then 0 else 1) end
		end
	end
	return out
end

-- Original: uploadInstances groups independently before clipping overlaps.
function Sam.arcs(circles:{Circle}):{any}
	local buckets,groups={},{}
	for _, c in circles do
		if not buckets[c.group] then buckets[c.group]={}; table.insert(groups,c.group) end
		table.insert(buckets[c.group],c)
	end
	table.sort(groups)
	local out={}
	for _, group in groups do
		local bucket=buckets[group]
		for _, c in bucket do for _, arc in Sam.uncovered(c,bucket) do table.insert(out,{circle=c,start=arc[1],finish=arc[2]}) end end
	end
	return out
end
return Sam
