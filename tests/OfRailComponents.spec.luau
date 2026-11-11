-- GameMap.railComponents (a Conquest addition): the rail search skips
-- stations in different areas. Areas must follow AStar.RailAdapter exactly,
-- or a skipped search could have found a path.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local AStar = t.require("OpenFront.Pathfinding.AStar")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function miniMapOf(folder: any, name: string, size: string): any
		local runner = Runner.new({
			gameID = "rail-areas",
			mapFolder = folder,
			gameConfig = { gameMap = name, gameMapSize = size, gameMode = "Free For All", gameType = "Singleplayer", difficulty = "Medium", bots = 0, nations = "disabled" },
		})
		runner:start()
		return runner.game:miniMap()
	end

	local function check(folder: any, name: string, size: string)
		local mini = miniMapOf(folder, name, size)
		local labels = mini:railComponents()
		local adapter = AStar.RailAdapter.new(mini)
		local n = mini:width() * mini:height()
		local out, back = {}, {}
		local bad, sizes = 0, {}
		for a = 0, n - 1 do
			if not mini:isImpassable(a) then
				local la = buffer.readu32(labels, a * 4)
				sizes[la] = (sizes[la] or 0) + 1
				for i = 1, adapter:neighbors(a, out) do
					local b = out[i]
					if not mini:isImpassable(b) then
						-- Same area, and the move back is allowed too.
						local reverse = false
						for j = 1, adapter:neighbors(b, back) do
							if back[j] == a then
								reverse = true
							end
						end
						if buffer.readu32(labels, b * 4) ~= la or not reverse then
							bad += 1
						end
					end
				end
			else
				t.eq(buffer.readu32(labels, a * 4), 0, "impassable tiles are unlabelled")
			end
		end
		t.eq(bad, 0, `{name}: rail moves that leave their area or can't be reversed`)

		-- The two largest areas: A* (without the shortcut) finds no path between
		-- them, and does find one inside an area.
		local order = {}
		for label, count in sizes do
			table.insert(order, { label = label, count = count })
		end
		table.sort(order, function(x, y) return x.count > y.count end)
		t.ok(#order >= 2, `{name}: at least two rail areas`)
		local function firstOf(label: number, skip: number?): number
			for a = 0, n - 1 do
				if a ~= skip and buffer.readu32(labels, a * 4) == label and not mini:isWater(a) then
					return a
				end
			end
			error("no tile")
		end
		local a1 = firstOf(order[1].label)
		local b1 = firstOf(order[2].label)
		t.eq(AStar.new(AStar.RailAdapter.new(mini)):findPath(a1, b1), nil, `{name}: no rail path between areas`)
		local near: number? = nil
		for i = 1, adapter:neighbors(a1, out) do
			if buffer.readu32(labels, out[i] * 4) == order[1].label then
				near = out[i]
			end
		end
		if near then
			t.ok(AStar.new(AStar.RailAdapter.new(mini)):findPath(a1, near) ~= nil, `{name}: a path inside an area`)
		end
		t.eq(mini:railComponents(), labels, "cached until the water changes")
	end

	t.test("rail areas follow the rail search's moves: compact World", function()
		check(Maps.World, "World", "Compact")
	end)

	t.test("rail areas follow the rail search's moves: Four Islands", function()
		check(Maps.FourIslands, "FourIslands", "Normal")
	end)
end
