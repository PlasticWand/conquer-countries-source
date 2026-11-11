--!strict
-- Ported from OpenFront v0.35.2 (src/client/TransformHandler.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
export type View = {width: number, height: number, viewportWidth: number, viewportHeight: number,
	left: number, top: number, offsetX: number, offsetY: number, scale: number}
local Camera = {}

-- Original: TransformHandler.screenToWorldCoordinatesFloat.
function Camera.screenToWorldCoordinatesFloat(v: View, screenX: number, screenY: number): (number, number)
	return (screenX - v.left - v.width / 2) / v.scale + v.offsetX + v.width / 2,
		(screenY - v.top - v.height / 2) / v.scale + v.offsetY + v.height / 2
end

-- Original: TransformHandler.screenToWorldCoordinates.
function Camera.screenToWorldCoordinates(v: View, x: number, y: number): (number, number)
	local xx, yy = Camera.screenToWorldCoordinatesFloat(v, x, y)
	return math.floor(xx), math.floor(yy)
end

-- Original: TransformHandler.worldToCanvasCoordinates + canvasToScreenCoordinates.
function Camera.worldToScreenCoordinates(v: View, x: number, y: number): (number, number)
	return (x - v.width / 2 - v.offsetX) * v.scale + v.width / 2 + v.left,
		(y - v.height / 2 - v.offsetY) * v.scale + v.height / 2 + v.top
end

-- Original: TransformHandler.clampOffsets. Mutates only the passed camera.
function Camera.clampOffsets(v: View)
	local dx, dy = (v.width - v.viewportWidth) / (2 * v.scale), (v.height - v.viewportHeight) / (2 * v.scale)
	v.offsetX = math.clamp(v.offsetX, -v.width / 2 + dx, v.width / 2 + dx)
	v.offsetY = math.clamp(v.offsetY, -v.height / 2 + dy, v.height / 2 + dy)
end

-- Original: TransformHandler.onZoom. Scale is CSS-equivalent pixels/tile;
-- Roblox screen/safe-area offsets are explicit, not silently applied twice.
function Camera.onZoom(v: View, screenX: number, screenY: number, delta: number)
	local old = v.scale
	v.scale = math.clamp(v.scale / (1 + delta / 600), 0.2, 20)
	local x, y = screenX - v.left - v.width / 2, screenY - v.top - v.height / 2
	v.offsetX += x / old - x / v.scale
	v.offsetY += y / old - y / v.scale
	Camera.clampOffsets(v)
end

-- Original: TransformHandler.onMove.
function Camera.onMove(v: View, deltaX: number, deltaY: number)
	v.offsetX -= deltaX / v.scale; v.offsetY -= deltaY / v.scale
	Camera.clampOffsets(v)
end

-- Original: TransformHandler.screenBoundingRect + screenCenter. Both ends
-- are floored before calculating the centre, including on narrow phones.
function Camera.screenCenter(v: View): (number, number)
	local x0 = math.floor(-v.width / 2 / v.scale + v.offsetX + v.width / 2)
	local y0 = math.floor(-v.height / 2 / v.scale + v.offsetY + v.height / 2)
	local x1 = math.floor((v.viewportWidth - v.width / 2) / v.scale + v.offsetX + v.width / 2)
	local y1 = math.floor((v.viewportHeight - v.height / 2) / v.scale + v.offsetY + v.height / 2)
	return x0 + math.floor((x1 - x0) / 2), y0 + math.floor((y1 - y0) / 2)
end

-- Original: TransformHandler.goTo. Caller owns the 16ms scheduling/lifetime;
-- dt is milliseconds (first callback uses 16). Returns true when finished.
function Camera.goTo(v: View, targetX: number, targetY: number, targetScale: number?, dt: number): boolean
	local x, y = Camera.screenCenter(v)
	if math.abs(targetX - x) + math.abs(targetY - y) < 2
		and (targetScale == nil or math.abs(v.scale - targetScale) < 0.01) then return true end
	local r = 1 - 0.03 ^ (dt / 1000)
	v.offsetX += math.clamp((targetX - x) * r, -15, 15)
	v.offsetY += math.clamp((targetY - y) * r, -15, 15)
	if targetScale ~= nil then
		local old, diff = v.scale, targetScale - v.scale
		local smooth = diff * (1 - 0.7 ^ (dt / 1000))
		local minimum = math.sign(diff) * math.min(math.abs(diff), 6 * dt / 1000)
		v.scale += if math.abs(smooth) >= math.abs(minimum) then smooth else minimum
		v.offsetX += (v.viewportWidth - v.width) * (1 / (2 * old) - 1 / (2 * v.scale))
		v.offsetY += (v.viewportHeight - v.height) * (1 / (2 * old) - 1 / (2 * v.scale))
	end
	return false
end

-- Original: TransformHandler.centerAll + override. Source deliberately
-- bypasses wheel zoom clamps for initial fit; preserve that exception.
function Camera.centerAll(v: View, fit: number?)
	v.scale = math.min(v.viewportWidth / v.width, v.viewportHeight / v.height) * (fit or 1)
	v.offsetX = (v.width - v.viewportWidth) / 2 / v.scale
	v.offsetY = (v.height - v.viewportHeight) / 2 / v.scale
end

return Camera
