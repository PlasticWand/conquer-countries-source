--!strict
-- Ported from OpenFront v0.35.2 (render/gl/passes/name-pass/StatusIconProgram.ts;
-- IconProgram.ts; shaders/name/status-icon.vert.glsl and status-icon.frag.glsl),
-- © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by Conquest.
-- Artwork: open resources/atlases, CC BY-SA 4.0. Credit: OpenFront.
local Atlas = require(script.Parent.StatusAtlas)
local Status = require(script.Parent.PlayerStatus)
local Decorations = {}
Decorations.__index = Decorations

function Decorations.new(): any
	return setmetatable({needed = false, destroyed = false, atlas = nil,
		content = nil, budget = 25, pending = false, animations = {}, images = 0}, Decorations)
end

-- Native decompression/upload is exclusive with the map/FX image upload.
-- Ordinary names remain visible while artwork is loading.
function Decorations.prepare(self: any): boolean
	if self.destroyed or self.content or not self.needed then return false end
	local pixels = Atlas.rgba(game:GetService("EncodingService"), Enum.CompressionAlgorithm.Zstd)
	local atlas = game:GetService("AssetService"):CreateEditableImage({Size = Vector2.new(Atlas.width, Atlas.height)})
	assert(atlas, "OpenFront status atlas allocation failed")
	self.atlas = atlas
	atlas:WritePixelsBuffer(Vector2.zero, Vector2.new(Atlas.width, Atlas.height), pixels)
	self.content = Content.fromObject(atlas)
	return true
end

function Decorations.beginFrame(self: any, budget: number?)
	self.budget, self.pending = budget or 25, false
end

local function image(self: any, parent: Instance, name: string): ImageLabel?
	if self.budget <= 0 then self.pending = true; return nil end
	self.budget -= 1; self.images += 1
	local i = Instance.new("ImageLabel")
	i.Name, i.BackgroundTransparency, i.BorderSizePixel, i.ZIndex = name, 1, 0, 10
	i.ImageContent, i.ImageColor3, i.ResampleMode = self.content, Color3.new(1, 1, 1), Enum.ResamplerMode.Default
	i.Parent = parent
	return i
end

local function rect(i: GuiObject, x: number, y: number, w: number, h: number)
	i.Position, i.Size = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h)
end

local function crop(i: ImageLabel, index: number, y: number?, height: number?)
	i.ImageRectOffset = Vector2.new(index % 10 * 64, math.floor(index / 10) * 64 + (y or 0))
	i.ImageRectSize = Vector2.new(64, height or 64)
end

function Decorations.draw(self: any, view: any, data: any, worldScale: number, zoom: number,
	namePixels: number, width: number, guiScale: number, config: any, now: number)
	-- Only this name's decorations are being replaced. Other names keep their
	-- shader-equivalent opacity animation between incremental layout updates.
	for index=#self.animations,1,-1 do
		if self.animations[index].view==view then table.remove(self.animations,index) end
	end
	-- Most names have no decorations. Avoid allocating an icon list, layout
	-- and empty GUI cache for every tribe on every name refresh. Clear old
	-- views when a status expires.
	if not (data.crown or data.traitor or data.disconnected or data.alliance or data.allianceReq
		or data.target or data.embargo or data.nukeActive or data.emoji) then
		if view.statusIcons then
			for _, entry in view.statusIcons do
				if entry.base.Visible then entry.base.Visible = false end
				if entry.fill and entry.fill.Visible then entry.fill.Visible = false end
			end
		end
		if view.statusEmoji and view.statusEmoji.Visible then view.statusEmoji.Visible = false end
		if view.nativeEmoji and view.nativeEmoji.Visible then view.nativeEmoji.Visible = false end
		return
	end
	local icons = Status.icons(data)
	local emojiIndex = if data.emoji then Atlas.emojis[data.emoji] else nil
	local hasEmoji = data.emoji ~= nil
	local count = #icons + (if hasEmoji then 1 else 0)
	local layout = Status.layout(worldScale, zoom, count)
	local left, top = width / 2 + layout.x, namePixels / 2 + layout.y
	view.statusIcons = view.statusIcons or {}
	if #icons > 0 or emojiIndex ~= nil then self.needed = true end
	for index, atlasIndex in icons do
		local entry = view.statusIcons[index]
		if not entry and self.content then
			local base = image(self, view.root, "PlayerStatus")
			if base then entry = {base = base}; view.statusIcons[index] = entry end
		end
		if entry then
			local base = entry.base
			base.Visible = self.content ~= nil
			if entry.fill then entry.fill.Visible = false end
			local side = layout.size * 64 / Atlas.statusContent / guiScale
			local margin = layout.size * 4 / Atlas.statusContent
			local x, y = (left + (index - 1) * layout.step - margin) / guiScale, (top - margin) / guiScale
			local alpha = 1
			local flashWindow = 0
			if atlasIndex == 1 then
				alpha = Status.flash(data.traitorRemainingTicks, 150, now)
				if data.traitorRemainingTicks > 0 and data.traitorRemainingTicks <= 150 then flashWindow = 150 end
			elseif atlasIndex == 3 then
				local window = if config then config:allianceExtensionPromptOffset() else 0
				alpha = Status.flash(data.allianceRemainingTicks, window, now)
				if data.allianceRemainingTicks > 0 and data.allianceRemainingTicks <= window then flashWindow = window end
			end
			base.ImageTransparency = 1 - alpha
			rect(base, x, y, side, side); crop(base, atlasIndex)
			local fraction = data.allianceFraction
			if atlasIndex == 3 and fraction > 0 and fraction < 1 then
				crop(base, 9)
				if not entry.fill then entry.fill = image(self, view.root, "AllianceDrain") end
				if entry.fill then
					local cut = math.floor(4 + 56 * (.20 + (1 - fraction) * .624))
					local sidePixels = math.floor(side)
					local cutPixels = math.floor(sidePixels * cut / 64)
					crop(base, 9, 0, cut)
					rect(base, x, y, sidePixels, cutPixels)
					local fill = entry.fill
					fill.Visible, fill.ImageTransparency = true, 1 - alpha
					crop(fill, 3, cut, 64 - cut)
					rect(fill, x, y + cutPixels, sidePixels, sidePixels - cutPixels)
				end
			end
			if flashWindow > 0 then
				table.insert(self.animations, {view = view, base = base, fill = entry.fill,
					remaining = if atlasIndex == 1 then data.traitorRemainingTicks else data.allianceRemainingTicks, window = flashWindow})
			end
		end
	end
	for index = #icons + 1, #view.statusIcons do
		local entry = view.statusIcons[index]
		entry.base.Visible = false; if entry.fill then entry.fill.Visible = false end
	end
	if view.statusEmoji then view.statusEmoji.Visible = false end
	if view.nativeEmoji then view.nativeEmoji.Visible = false end
	if hasEmoji then
		local x, y = (left + #icons * layout.step) / guiScale, top / guiScale
		local side = layout.size / guiScale
		if emojiIndex ~= nil and self.content then
			if not view.statusEmoji then view.statusEmoji = image(self, view.root, "PlayerEmoji") end
			if view.statusEmoji then
				view.statusEmoji.Visible = true; crop(view.statusEmoji, emojiIndex + 10)
				rect(view.statusEmoji, x, y, side, side)
			end
		elseif emojiIndex == nil then
			-- Preserve an unknown glyph, rather than substituting an unrelated
			-- picture. Upstream's atlas lacks the table's U+23F3 hourglass.
			if not view.nativeEmoji and self.budget > 0 then
				self.budget -= 1
				local text = Instance.new("TextLabel")
				text.Name, text.BackgroundTransparency, text.BorderSizePixel, text.ZIndex = "UnmappedEmoji", 1, 0, 10
				text.Font, text.TextColor3 = Enum.Font.SourceSans, Color3.new(1, 1, 1)
				text.Parent = view.root; view.nativeEmoji = text
			end
			if view.nativeEmoji then
				view.nativeEmoji.Visible, view.nativeEmoji.Text = true, data.emoji
				view.nativeEmoji.TextSize = math.clamp(side, 1, 100); rect(view.nativeEmoji, x, y, side, side)
			else self.pending = true end
		end
	end
end

-- The shader animates opacity every frame without re-uploading all player
-- state. Do the same with cached visible image references; layout stays tick/
-- camera-driven rather than rebuilding all names for one flashing alliance.
function Decorations.step(self: any, now: number)
	if self.destroyed then return end
	for _, animation in self.animations do
		if not animation.view.root.Visible then continue end
		local transparency = 1 - Status.flash(animation.remaining, animation.window, now)
		animation.base.ImageTransparency = transparency
		if animation.fill then animation.fill.ImageTransparency = transparency end
	end
end

function Decorations.destroy(self: any)
	if self.destroyed then return end
	self.destroyed = true
	if self.atlas then self.atlas:Destroy() end
	self.atlas, self.content = nil, nil
	table.clear(self.animations)
	table.clear(self.animations)
	-- Per-name GUI views are descendants of the scene-owned name roots.
end

return Decorations
