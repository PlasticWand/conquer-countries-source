--!strict
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/PlayerExecution.ts calculateClusters/removeClusters), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Confirmed-tile fallback for clients that have not received server anchors.
local Clusters = {}

-- Original: PlayerExecution.calculateClusters: border membership and 8-neighbour
-- flood, then largest cluster by border-tile count. Source Set insertion order
-- is not replicated; exact ties must come from authoritative server anchors.
function Clusters.largestBorderBounds(border: {number}, width: number, height: number): any
	if #border == 0 then return nil end
	local member: {[number]: boolean}, visited: {[number]: boolean} = {}, {}
	for _, tile in border do member[tile] = true end
	local best, bestCount = nil, -1
	for _, start in border do
		if visited[start] then continue end
		local queue = {start}
		visited[start] = true
		local head, count = 1, 0
		local minX, minY = width, height
		local maxX, maxY = 0, 0
		while head <= #queue do
			local tile = queue[head]; head += 1; count += 1
			local x, y = tile % width, math.floor(tile / width)
			minX, minY, maxX, maxY = math.min(minX, x), math.min(minY, y), math.max(maxX, x), math.max(maxY, y)
			for dy = -1, 1 do for dx = -1, 1 do
				if dx == 0 and dy == 0 then continue end
				local nx, ny = x + dx, y + dy
				if nx >= 0 and ny >= 0 and nx < width and ny < height then
					local nextTile = ny * width + nx
					if member[nextTile] and not visited[nextTile] then
						visited[nextTile] = true; table.insert(queue, nextTile)
					end
				end
			end end
		end
		if count > bestCount then
			bestCount = count
			best = {min = {x = minX, y = minY}, max = {x = maxX, y = maxY}}
		end
	end
	return best
end
return Clusters
