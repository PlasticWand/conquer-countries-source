--!strict
local fs, serde, luau = require("@lune/fs"), require("@lune/serde"), require("@lune/luau")
local Harness = luau.load(fs.readFile("tests/harness.luau"))()
local root = Harness.mount("src/client/Map/OpenFront", "OpenFront")
local Js = Harness.require(root.JsMath)
local NameBox = Harness.require(root.NameBoxCalculator)
local Camera = Harness.require(root.CameraTransform)
local Trajectory = Harness.require(root.NukeTrajectory)
local Label = Harness.require(root.LabelMath)
local Structure = Harness.require(root.StructureMath)
local Spawn = Harness.require(root.SpawnOverlay)
local Political = Harness.require(root.PoliticalColors)
local Colors = Harness.require(root.PlayerColors)
local ColorMath = Harness.require(root.ColorMath)
local golden = serde.decode("json", fs.readFile("tests/fixtures/OpenFrontRenderer.json"))

return function(t: any)
	local function nearFields(actual: any, expected: any, label: string)
		for key, value in expected do
			if type(value) == "number" then t.near(actual[key], value, 1e-9, `{label}.{key}`)
			else t.eq(actual[key], value, `{label}.{key}`) end
		end
	end
	for _, case in golden.hashes do
		t.test(`OpenFront JS UTF16/hash {case.value}`, function()
			t.eq(Js.simpleHash(case.value), case.hash); t.eq(#Js.utf16(case.value), case.length)
		end)
	end
	t.test("OpenFront colour allocator first RNG draw agrees with copied TS across signed seeds", function()
		for _, case in golden.random do t.eq(Js.seededInt(case.seed, 0, case.maximum), case.result) end
	end)
	t.test("OpenFront palette first assignments match original allocator TS in both themes", function()
		for _, case in golden.firstColors do
			local theme = Colors.new(case.palette)
			theme.useClassicBotColors = true
			local color = Colors.territoryColor(theme, case.id, case.type, nil)
			t.eq(ColorMath.toHex(color), case.result, `{case.palette}/{case.type}/{case.id}`)
		end
	end)
	t.test("OpenFront player colours preserve tribe grey cosmetic priority and immutable inputs", function()
		local theme = Colors.new()
		local grey = Colors.territoryColor(theme, "tribe", "BOT", nil)
		t.eq(ColorMath.toHex(grey), "#d1cdc7")
		local red = ColorMath.fromHex("#ff0000")
		local default = Colors.resolvePlayerColors(theme, red, {}, nil, false)
		t.eq(ColorMath.toHex(default.border), "#bf0000")
		t.eq(ColorMath.toHex(Colors.resolvePlayerColors(theme, red, {}, nil, true).border), "#e6e6e6")
		local result = Colors.resolvePlayerColors(theme, red, {color = {color = "#123456"},
			pattern = {colorPalette = {primaryColor = "#987654", secondaryColor = "#abcdef"}}}, "Red", true)
		t.eq(ColorMath.toHex(result.territory), "#ff0000"); t.eq(ColorMath.toHex(result.border), "#abcdef")
		t.eq(ColorMath.toHex(red), "#ff0000"); t.eq(ColorMath.delta(red, red), 0)
		t.eq(#Colors.generateTeamColors(red), 64)
		t.eq(ColorMath.toHex(Colors.teamColor(theme, "Red")), "#eb3333")
	end)
	do
		t.test("OpenFront every ordered palette and colour constant matches pinned theme JSON", function()
			t.eq(golden.colord.verified, true, "locked Colord oracle required; regenerate with colord 2.10.0")
			t.eq(golden.colord.version, "2.10.0", "locked Colord version")
			local themes = Harness.require(root.Themes)
			local function compare(actual: any, expected: any, label: string)
				if type(actual) ~= "table" then t.eq(actual, expected, label); return end
				local count = 0
				for key, value in actual do count += 1; compare(value, expected[key], `{label}/{key}`) end
				local expectedCount = 0; for _ in expected do expectedCount += 1 end
				t.eq(count, expectedCount, `{label}/count`)
			end
			for palette, settings in themes do
				for key, value in settings do compare(value, golden.palettes[palette][key], `{palette}/{key}`) end
			end
		end)
		t.test("OpenFront full perceptual allocations and exhaustion agree with locked Colord", function()
			local themes = {default = Colors.new(), colorblind = Colors.new("colorblind")}
			for _, case in golden.colors do
				local theme = themes[case.palette]; theme.useClassicBotColors = case.classic
				local c = Colors.territoryColor(theme, case.id, case.type, nil)
				nearFields(ColorMath.toRgb(c), case.territory, case.id)
				nearFields(ColorMath.toRgb(Colors.borderColor(theme, c)), case.border, "border")
			end
		end)
		t.test("OpenFront every team variation and ID-only assignment cache agrees with locked Colord", function()
			local themes = {default = Colors.new(), colorblind = Colors.new("colorblind")}
			for _, case in golden.teamPalettes do
				t.eq(#themes[case.palette].teamPalettes[case.team], #case.colors, "team length")
				for i, c in themes[case.palette].teamPalettes[case.team] do nearFields(ColorMath.toRgb(c), case.colors[i], `team {case.team}/{i}`) end
			end
			for _, case in golden.teamAssignments do
				nearFields(ColorMath.toRgb(Colors.teamColorForPlayer(themes[case.palette], case.team, case.id)), case.result, "team ID")
				nearFields(Colors.teamColor(themes[case.palette], case.team), case.base, "team base")
			end
		end)
		t.test("OpenFront RGB LAB LCH hex alpha and CIEDE2000 choices agree with locked Colord", function()
			for _, case in golden.conversions do
				local c = ColorMath.fromHex(case.hex)
				nearFields(ColorMath.toRgb(c), case.rgb, "RGB")
				t.eq(ColorMath.toHex(c), case.hexResult, "HEX alpha")
				nearFields(ColorMath.toLab(c, true), case.lab, "LAB")
				nearFields(ColorMath.toLch(c), case.lch, "LCH")
				nearFields(ColorMath.toRgb(ColorMath.darken(c, .125)), case.dark, "HSL darken")
			end
			for _, case in golden.perceptual do
				local available, assigned = {}, {}
				for _, hex in case.available do table.insert(available, ColorMath.fromHex(hex)) end
				for _, hex in case.assigned do table.insert(assigned, ColorMath.fromHex(hex)) end
				t.eq(Colors.selectDistinctColorIndex(available, assigned) - 1, case.index, "perceptual index")
				t.near(ColorMath.delta(available[1], assigned[1]), case.delta, 1e-12, "delta")
			end
		end)
		t.test("OpenFront cosmetic and focused-player precedence agrees with locked Colord", function()
			local themes = {default = Colors.new(), colorblind = Colors.new("colorblind")}
			for _, case in golden.resolve do
				local result = Colors.resolvePlayerColors(themes[case.palette], ColorMath.fromHex(case.themed), case.cosmetics, case.team, case.focused)
				nearFields(ColorMath.toRgb(result.territory), case.territory, "cosmetic fill")
				nearFields(ColorMath.toRgb(result.border), case.border, "cosmetic border")
			end
		end)
		t.test("OpenFront structure contrast iterations and defended borders agree with locked Colord", function()
			local themes = {default = Colors.new(), colorblind = Colors.new("colorblind")}
			for _, case in golden.structureColors do
				local c = ColorMath.fromHex(case.hex)
				local s = Colors.structureColors(themes[case.palette], c)
				local d = Colors.defendedBorderColors(themes[case.palette], c)
				nearFields(ColorMath.toRgb(s.light), case.light, "structure light")
				nearFields(ColorMath.toRgb(s.dark), case.dark, "structure dark")
				nearFields(ColorMath.toRgb(d.light), case.defendedLight, "defended light")
				nearFields(ColorMath.toRgb(d.dark), case.defendedDark, "defended dark")
			end
		end)
	end
	t.test("OpenFront name rectangle and tie order match original TS on 90 irregular grids", function()
		for i, case in golden.rectangles do nearFields(NameBox.findLargestInscribedRectangle(case.grid), case.result, `grid {i}`) end
	end)
	t.test("OpenFront name placement matches original TS across every sampling threshold", function()
		for _, case in golden.names do
			local input = case.input
			local width, height, seed = input.width, input.height, input.seed
			local function flag(tile: number): number return (tile * 17 + seed) % 23 end
			local map = {width = width, height = height, isShore = function(tile: number) return flag(tile) == 2 end,
				isOcean = function(tile: number) return flag(tile) == 3 or flag(tile) == 4 end,
				magnitude = function(tile: number) return if flag(tile) == 3 then 9 else 10 end,
				owner = function(tile: number) return if flag(tile) < 19 then 1 else 2 end,
				hasFallout = function(tile: number) return flag(tile) == 22 end}
			local player = {id = 1, name = input.name, spawnTile = input.spawn,
				largestClusterBoundingBox = if input.fallback then nil else input.bounds,
				borderTiles = {width + 1, (height - 2) * width + width - 2}}
			nearFields(NameBox.placeName(map, player), case.result, `name {width}/{seed}`)
			nearFields(NameBox.placeSpawnName(map, player), case.spawn, "spawn")
			player.spawnTile = nil
			nearFields(NameBox.placeSpawnName(map, player), {x = 0, y = 0, size = 0}, "absent spawn")
		end
	end)
	t.test("OpenFront camera traces match original TransformHandler on phone desktop and small maps", function()
		for _, case in golden.camera do
			local view = table.clone(case.input)
			for _, step in case.steps do
				local command = step.command
				if command[1] == "centerAll" then Camera.centerAll(view, command[2])
				elseif command[1] == "zoom" then Camera.onZoom(view, command[2], command[3], command[4])
				elseif command[1] == "pan" then Camera.onMove(view, command[2], command[3])
				else Camera.goTo(view, command[2], command[3], command[4], command[5]) end
				nearFields(view, step.state, "camera state")
				local x, y = Camera.screenToWorldCoordinatesFloat(view, view.left + 333.5, view.top + 188.25)
				nearFields({x = x, y = y}, step.world, "camera world")
				local cx, cy = Camera.screenCenter(view)
				nearFields({screenX = cx, screenY = cy}, step.center, "camera centre")
				local sx, sy = Camera.worldToScreenCoordinates(view, x, y)
				t.near(sx, view.left + 333.5, 1e-8); t.near(sy, view.top + 188.25, 1e-8)
			end
		end
	end)
	t.test("OpenFront nuke controls and SAM threshold searches match 168 original TS cases", function()
		for i, case in golden.trajectories do
			local a = case.input
			local result = Trajectory.buildNukeTrajectory(a.srcX, a.srcY, a.dstX, a.dstY, a.mapH, a.directionUp, a.sams)
			nearFields(result, case.result, `trajectory {i}`)
		end
	end)
	t.test("OpenFront displayed numbers and troops match original TS at every suffix boundary", function()
		for _, case in golden.numbers do
			t.eq(Label.renderNumber(case.input, case.digits), case.result, `number {case.input}/{case.digits}`)
			t.eq(Label.renderTroops(case.input), case.troops)
		end
	end)
	t.test("OpenFront shader name equations preserve cull target hover and troop scale", function()
		local hidden = Label.size(1, 0.001, false, false, false)
		t.eq(hidden.visible, false); t.near(hidden.worldScale, 1 / 48, 1e-12)
		t.eq(Label.size(1, 0.001, false, true, false).visible, true)
		local target = Label.size(1, 0.001, true, false, true)
		t.eq(target.visible, true); t.eq(target.screenSize, 0.008)
		t.near(target.worldScale, target.nameWorldScale * .6, 1e-12)
		local large = Label.size(100, 0.01, true, false, false)
		t.eq(large.nameSize, 40); t.eq(large.nameScale, 3); t.eq(large.nameWorldScale, 2.5)
		t.eq(large.worldScale, 1.5); t.near(large.lineOffsetY, 99, 1e-12)
		t.eq(Label.troopBucket(.399, 1), 0); t.eq(Label.troopBucket(.4, 1), 1)
		t.near(Label.lerp(0, 1, .1), 1 - math.exp(-1), 1e-12)
	end)
	t.test("OpenFront structure shader thresholds and effective classic defaults", function()
		local dots = Structure.size("City", 1.2)
		t.eq(dots.dots, true); t.near(dots.screenSize, 18, 1e-12)
		t.eq(Structure.size("City", 1.200001).dots, false)
		t.near(Structure.size("Missile Silo", 7).screenSize, 93, 1e-12)
		t.near(Structure.size("Missile Silo", 14).halfSize, Structure.size("Missile Silo", 7).halfSize, 1e-12)
		t.eq(Structure.style().fillDarken, 1); t.eq(Structure.style(false).fillDarken, .65)
	end)
	t.test("OpenFront shader fill orders contrast defence saturation and relation checker", function()
		local neighbours = {{owner = 2, relation = 1}, {owner = 3, relation = 2}, {owner = 1, relation = 0}, {owner = 0, relation = 0}}
		local border = Political.border(1, neighbours, true, 2, 3)
		t.eq(border.borderType, 1); t.eq(border.relation, 1)
		local tile = {owner = 1, x = 2, y = 3, defended = true, hovered = true}
		local stamp = Political.stamp(tile, {r = .2, g = .4, b = .6}, border)
		nearFields(stamp, {r = (.4 * .65 + .35) * .7, g = .55 * .65 * .7, b = .7 * .65 * .7, a = 1}, "checker")
		local fill = Political.fill(tile, {r = .2, g = .4, b = .6}, {r = 1, g = 0, b = 0}, {borderType = 0, relation = 0})
		local r, g, b = .155 * .85, .385 * .85, .615 * .85
		local luma = r * .299 + g * .587 + b * .114
		nearFields(fill, {r = luma + (r - luma) * .85, g = luma + (g - luma) * .85, b = luma + (b - luma) * .85, a = .588}, "fill")
		tile.altView = true; tile.affiliation = {r = .9, g = .1, b = .2}
		nearFields(Political.stamp(tile, {r = 0, g = 0, b = 0}, border), {r = .9, g = .1, b = .2, a = 1}, "alternate")
		local expansion = Political.border(1, {{owner = 1, relation = 0}}, true, 3, 3,
			function(x: number, _y: number) return if x == 1 then 0 else 1 end, 2)
		t.eq(expansion.borderType, 1)
	end)
	t.test("OpenFront spawn shader has human-only centres and owned-tile masked enemy discs", function()
		local color = {r = .2, g = .4, b = .6, a = 1}
		t.eq(Spawn.center("BOT", true, false, nil, true, false, color), nil)
		nearFields(Spawn.center("HUMAN", true, true, nil, true, false, color), {r = 1, g = .84, b = 0, a = 1}, "gold")
		t.eq(Spawn.sample(0, 3, 0, color, true, 1).a, 0)
		t.eq(Spawn.sample(0, 9, 0, color, true, 0).a, 1)
		t.eq(Spawn.sample(0, 9.01, 0, color, true, 0).a, 0)
		nearFields(Spawn.sample(1, 5, 0, color, false, 1), {r = 1, g = 1, b = 1, a = .65}, "breath start")
		t.near(Spawn.breath(0), .5, 1e-12)
	end)
end
