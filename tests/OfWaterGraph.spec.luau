-- OpenFront port, Phase C: water components and the hierarchical-pathfinding
-- graph, built as WaterManager builds them (half-size map, cluster 32, shared
-- components). tests/fixtures/openfront/water-graph.json holds hashes of
-- every node, edge, cluster list and per-tile component id, dumped from
-- OpenFront v0.35.2's own code (openfront-run/tests/conquest/WaterGraphDump).
-- Maps are read from the reference clone; skipped when it is absent.
return function(t)
	local GameMap = t.require("OpenFront.GameMap")
	local ConnectedComponents = t.require("OpenFront.Pathfinding.ConnectedComponents")
	local AbstractGraph = t.require("OpenFront.Pathfinding.AbstractGraph")

	local ROOT = "../reference/openfront-v0.35.2/resources/maps"

	local function imul(a: number, b: number): number
		local aHi, aLo = bit32.rshift(a, 16), bit32.band(a, 0xffff)
		local bHi, bLo = bit32.rshift(b, 16), bit32.band(b, 0xffff)
		return ((((aHi * bLo + aLo * bHi) % 65536) * 65536) + aLo * bLo) % 4294967296
	end
	local function mix(h: number, v: number): number
		return imul(bit32.bxor(h, v % 4294967296), 0x01000193)
	end

	for _, want in t.json(t.readFile("tests/fixtures/openfront/water-graph.json")) do
		t.test(`{want.map} minimap graph matches OpenFront`, function()
			local dir = `{ROOT}/{want.map}`
			if not t.isFile(dir .. "/map4x.bin") then
				print(`  (skipped {want.map}: reference maps not available)`)
				return
			end
			local manifest = t.json(t.readFile(dir .. "/manifest.json"))
			local mini = GameMap.new(
				manifest.map4x.width,
				manifest.map4x.height,
				buffer.fromstring(t.readFile(dir .. "/map4x.bin")),
				manifest.map4x.num_land_tiles
			)
			local cc = ConnectedComponents.new(mini)
			cc:initialize()
			local ch = 2166136261
			for tile = 0, mini:width() * mini:height() - 1 do
				ch = mix(ch, cc:getComponentId(tile))
			end
			t.eq(ch, want.components, "component labels")
			local g = AbstractGraph.Builder.new(mini, 32, nil, nil, cc, AbstractGraph.BFSGrid.new(mini:width() * mini:height())):build()
			t.eq(g.nodeCount, want.nodeCount, "node count")
			t.eq(g.edgeCount, want.edgeCount, "edge count")
			for i, e in want.firstEdges do
				local got = g:getEdge(i - 1) :: any
				for _, k in { "id", "nodeA", "nodeB", "cost", "clusterX", "clusterY" } do
					t.eq(got[k], e[k], `edge {i - 1} {k}`)
				end
			end
			local nh = 2166136261
			for id = 0, g.nodeCount - 1 do
				local n = g:getNode(id) :: any
				for _, v in { n.id, n.x, n.y, n.tile, n.componentId } do
					nh = mix(nh, v)
				end
			end
			t.eq(nh, want.nodes, "node hash")
			local eh = 2166136261
			for id = 0, g.edgeCount - 1 do
				local e = g:getEdge(id) :: any
				for _, v in { e.id, e.nodeA, e.nodeB, e.cost, e.clusterX, e.clusterY } do
					eh = mix(eh, v)
				end
			end
			t.eq(eh, want.edges, "edge hash")
			local clh = 2166136261
			for cy = 0, g.clustersY - 1 do
				for cx = 0, g.clustersX - 1 do
					for _, id in (g:getCluster(cx, cy) :: any).nodeIds do
						clh = mix(clh, id)
					end
				end
			end
			t.eq(clh, want.clusters, "cluster node lists")
		end)
	end
end
