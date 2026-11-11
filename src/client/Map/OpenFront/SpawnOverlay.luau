--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/shaders/spawn-overlay/spawn-overlay.frag.glsl; src/client/render/gl/passes/SpawnOverlayPass.ts; src/client/WebGLFrameBuilder.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Defaults = require(script.Parent.RenderDefaults)
export type Color = {r: number, g: number, b: number, a: number}
local Spawn = {}

-- Original: SpawnOverlayPass.draw (accumulated animation time in ms).
function Spawn.breath(elapsedMs: number, settings: typeof(Defaults.spawnOverlay)?): number
	return 0.5 + 0.5 * math.sin(elapsedMs * (settings or Defaults.spawnOverlay).animSpeed)
end

-- Original: WebGLFrameBuilder.syncSpawnOverlay human-only filter and colour.
function Spawn.center(playerType: string, hasSpawn: boolean, isSelf: boolean, team: string?, inSpawn: boolean,
	ownSpawnRing: boolean, color: Color): Color?
	if playerType ~= "HUMAN" or not hasSpawn or (not inSpawn and (not ownSpawnRing or not isSelf)) then return nil end
	if isSelf and team == nil then return {r = 1, g = 0.84, b = 0, a = 1} end
	return {r = color.r, g = color.g, b = color.b, a = 1}
end

-- Original: spawn-overlay.frag main. RGB and alpha use normalized floats;
-- kind 0 = enemy highlight, 1 = self glow, 2 = teammate glow. Tile mask is
-- supplied by confirmed ownership; rings themselves are not clipped to land.
function Spawn.sample(kind: number, distance: number, breath: number, color: Color, onMap: boolean, owner: number,
	settings: typeof(Defaults.spawnOverlay)?): Color
	local s = settings or Defaults.spawnOverlay
	if kind < 0.5 then
		if not onMap or distance * distance > s.highlightRadius * s.highlightRadius or owner ~= 0 then
			return {r = 0, g = 0, b = 0, a = 0}
		end
		return {r = color.r, g = color.g, b = color.b, a = s.highlightAlpha}
	end
	local teammate = kind > 1.5
	local scale = 0.5 + 0.65 * breath
	local minimum = (if teammate then s.mateMinRad else s.selfMinRad) * scale
	local maximum = (if teammate then s.mateMaxRad else s.selfMaxRad) * scale
	local t = (distance - minimum) / (maximum - minimum)
	local alpha = 0
	if distance < minimum then alpha = distance / math.max(minimum, 0.001)
	elseif t < s.gradientSolidEnd then alpha = 1
	elseif t < 1 then alpha = 1 - (t - s.gradientSolidEnd) / (1 - s.gradientSolidEnd) end
	alpha *= 0.65 + 0.35 * breath
	if alpha <= 0 then return {r = 0, g = 0, b = 0, a = 0} end
	return {r = if teammate then color.r else 1 + (color.r - 1) * breath,
		g = if teammate then color.g else 1 + (color.g - 1) * breath,
		b = if teammate then color.b else 1 + (color.b - 1) * breath, a = alpha}
end

return Spawn
