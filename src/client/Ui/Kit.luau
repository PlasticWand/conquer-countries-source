--!strict
-- Construction helpers shared by every screen (the Mix style, M6). No game
-- rules here. Panels are rounded ivory cards with a brass hairline; strips
-- are navy rails; the selected or primary thing is teal. Text never lives in
-- images.

local Theme = require(script.Parent.Theme)
local IconAtlas = require(script.Parent.IconAtlas)
local UiAssets = require(script.Parent.UiAssets)

local C = Theme.color

local Kit = {}

type Props = { [string]: any }

-- Creates an instance, applies props, parents children.
function Kit.new(className: string, props: Props?, children: { Instance }?): any
	local inst = Instance.new(className)
	if props then
		for key, value in props do
			if key ~= "Parent" then
				(inst :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if props and props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

-- True while something that takes input (a window's dimmed desk, a sheet's
-- blocker, a button) lies over `gui` at the mouse. Roblox fires MouseEnter on
-- covered objects too, so every hover effect and tooltip asks first (Bruno,
-- 2026-10-27: nothing behind an open panel reacts).
function Kit.covered(gui: GuiObject): boolean
	local ok, result = pcall(function()
		local player = game:GetService("Players").LocalPlayer
		local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
		if playerGui == nil then
			return false
		end
		-- Mouse coordinates include the top bar; GUI hit tests don't.
		local at = game:GetService("UserInputService"):GetMouseLocation() - game:GetService("GuiService"):GetGuiInset()
		-- Top-most first.
		for _, obj in playerGui:GetGuiObjectsAtPosition(at.X, at.Y) do
			if obj == gui or obj:IsDescendantOf(gui) then
				return false
			end
			if obj.Active then
				return true
			end
		end
		return false
	end)
	return ok and result == true
end

-- True while the player is on a touch screen: no hover there, so no
-- tooltips or hover cards (Bruno, 2026-10-27).
function Kit.touch(): boolean
	local ok, result = pcall(function()
		return game:GetService("UserInputService").PreferredInput == Enum.PreferredInput.Touch
	end)
	return ok and result == true
end

-- The screen root (Root.new sets it): its `compact` flag picks phone layouts.
Kit.root = nil :: any

function Kit.corner(radius: number?): UICorner
	return Kit.new("UICorner", { CornerRadius = UDim.new(0, radius or Theme.size.radius) })
end

function Kit.stroke(color: Color3?, thickness: number?, transparency: number?): UIStroke
	return Kit.new("UIStroke", {
		Color = color or C.paperLine,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Kit.padding(all: number, horizontal: number?): UIPadding
	local h = horizontal or all
	return Kit.new("UIPadding", {
		PaddingTop = UDim.new(0, all),
		PaddingBottom = UDim.new(0, all),
		PaddingLeft = UDim.new(0, h),
		PaddingRight = UDim.new(0, h),
	})
end

function Kit.list(direction: Enum.FillDirection, gap: number?, align: Enum.HorizontalAlignment?, valign: Enum.VerticalAlignment?): UIListLayout
	return Kit.new("UIListLayout", {
		FillDirection = direction,
		Padding = UDim.new(0, gap or Theme.size.gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = valign or Enum.VerticalAlignment.Center,
	})
end

-- An ivory card with a brass hairline; `accent` (modals and popovers) makes
-- the hairline solid and a little heavier.
function Kit.panel(props: Props, accent: boolean?): Frame
	local frame = Kit.new("Frame", {
		BackgroundColor3 = C.paper,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
	})
	for key, value in props do
		if key ~= "Parent" then
			(frame :: any)[key] = value
		end
	end
	Kit.corner(12).Parent = frame
	Kit.stroke(C.paperLine, if accent then 1.5 else 1, if accent then 0 else 0.25).Parent = frame
	if props.Parent then
		frame.Parent = props.Parent
	end
	return frame
end

-- A navy rail (top bar, command bar, tabs). `rounded` gives it card corners.
function Kit.strip(props: Props, rounded: boolean?): Frame
	local frame = Kit.new("Frame", {
		BackgroundColor3 = C.olive,
		BorderSizePixel = 0,
	})
	for key, value in props do
		if key ~= "Parent" then
			(frame :: any)[key] = value
		end
	end
	if rounded then
		Kit.corner(14).Parent = frame
	end
	Kit.stroke(C.oliveLine, 1, 0.2).Parent = frame
	if props.Parent then
		frame.Parent = props.Parent
	end
	return frame
end

function Kit.label(props: Props): TextLabel
	local label = Kit.new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = Theme.font.body,
		TextColor3 = C.ink,
		TextSize = Theme.size.body,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
	})
	for key, value in props do
		if key ~= "Parent" then
			(label :: any)[key] = value
		end
	end
	if props.Parent then
		label.Parent = props.Parent
	end
	return label
end

-- Small uppercase condensed caption ("LIVING / CAPACITY").
function Kit.caption(props: Props): TextLabel
	local defaults: Props = { FontFace = Theme.font.labelSemibold, TextSize = 11, TextColor3 = C.inkSoft }
	for key, value in props do
		defaults[key] = value
	end
	if type(defaults.Text) == "string" then
		defaults.Text = string.upper(defaults.Text)
	end
	return Kit.label(defaults)
end

export type ButtonKind = "primary" | "secondary" | "danger" | "chip" | "dark"

-- 2026-10-24: these simple buttons use the RoFront-level palette too (the
-- action sheet, player panel and alliance cards build with them).
local BUTTON_STYLE = {
	primary = { bg = C.amber, text = C.amberInk, stroke = C.amberDark },
	secondary = { bg = C.surface2, text = C.fg, stroke = C.line2 },
	danger = { bg = C.red, text = C.fg, stroke = C.redDark },
	chip = { bg = C.surface2, text = C.fgSoft, stroke = C.line2 },
	dark = { bg = C.surface2, text = C.fg, stroke = C.line2 },
}

-- A text button; its own Text is the source of truth.
function Kit.button(kind: ButtonKind, props: Props): TextButton
	local style = BUTTON_STYLE[kind]
	local button = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = style.bg,
		BorderSizePixel = 0,
		FontFace = Theme.font.uiBold,
		TextColor3 = style.text,
		TextSize = 17,
		Size = UDim2.fromOffset(120, Theme.size.touch),
	})
	for key, value in props do
		if key ~= "Parent" then
			(button :: any)[key] = value
		end
	end
	Kit.corner(8).Parent = button
	Kit.stroke(style.stroke).Parent = button
	button:SetAttribute("BaseColor", button.BackgroundColor3)
	button.MouseEnter:Connect(function()
		if Kit.covered(button) then
			return
		end
		if button.Active then
			local base = button:GetAttribute("BaseColor") :: Color3
			button.BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.12)
		end
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundColor3 = button:GetAttribute("BaseColor") :: Color3
	end)
	button.Activated:Connect(function()
		if Kit.onActivated then
			Kit.onActivated()
		end
	end)
	if props.Parent then
		button.Parent = props.Parent
	end
	return button
end

-- Called whenever any Kit button is pressed (the click sound sets it).
Kit.onActivated = nil :: (() -> ())?

local function setBase(button: GuiButton, color: Color3)
	button:SetAttribute("BaseColor", color)
	button.BackgroundColor3 = color
end

-- Selected chips fill with teal.
function Kit.setChipSelected(button: TextButton, selected: boolean)
	setBase(button, if selected then Color3.fromRGB(58, 42, 16) else C.surface2)
	button.TextColor3 = if selected then C.amber else C.fgSoft
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if selected then C.amber else C.line2
	end
end

function Kit.setEnabled(button: TextButton, enabled: boolean)
	button.Active = enabled
	button.AutoButtonColor = false
	button.TextTransparency = if enabled then 0 else 0.5
	button.BackgroundTransparency = if enabled then 0 else 0.3
end

-- An icon from the uploaded set (white masks; tinted here).
function Kit.icon(name: string, props: Props?): ImageLabel
	local image = Kit.new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = UiAssets.icon[name] or "",
		ImageColor3 = C.ink,
		Size = UDim2.fromOffset(20, 20),
		ScaleType = Enum.ScaleType.Fit,
	})
	if props then
		for key, value in props do
			if key ~= "Parent" then
				(image :: any)[key] = value
			end
		end
		if props.Parent then
			image.Parent = props.Parent
		end
	end
	return image
end

-- A square navy button with an icon (the top-left icon row). Its Name is the
-- tooltip key; `badge` adds a small count bubble the caller fills.
function Kit.iconButton(name: string, props: Props?): TextButton
	local button = Kit.button("dark", { Text = "", Size = UDim2.fromOffset(44, 44) })
	button.Name = name
	Kit.icon(name, { Name = "Icon", ImageColor3 = C.cream, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(24, 24), Parent = button })
	if props then
		for key, value in props do
			if key ~= "Parent" then
				(button :: any)[key] = value
			end
		end
		if props.Parent then
			button.Parent = props.Parent
		end
	end
	return button
end

-- A progress bar: returns the track and its fill (set fill.Size.X.Scale).
function Kit.bar(props: Props, fillColor: Color3?): (Frame, Frame)
	local track = Kit.new("Frame", { BackgroundColor3 = C.navyDeep, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 6) })
	for key, value in props do
		if key ~= "Parent" then
			(track :: any)[key] = value
		end
	end
	Kit.corner(3).Parent = track
	local fill = Kit.new("Frame", { Name = "Fill", BackgroundColor3 = fillColor or C.signal, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = track })
	Kit.corner(3).Parent = fill
	if props.Parent then
		track.Parent = props.Parent
	end
	return track, fill
end

-- A horizontal rule on paper.
function Kit.rule(props: Props): Frame
	local defaults: Props = { BackgroundColor3 = C.paperLine, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1) }
	for key, value in props do
		defaults[key] = value
	end
	return Kit.new("Frame", defaults)
end

-- 2026-10-24 pass (docs/design/rofront-ui-pass.md) ---------------------------------
-- Dark navy glass panels, wide-caps titles, raised amber / green buttons with
-- a darker lip, pill chips and tabs, currency badges, a star price bar, a
-- modal shell and a hover tooltip. Sizes are in 1920x1080 canvas pixels.

local function apply(inst: Instance, props: Props?, skip: { [string]: boolean }?)
	if props then
		for key, value in props do
			if key ~= "Parent" and not (skip and skip[key]) then
				(inst :: any)[key] = value
			end
		end
	end
end

local function parent(inst: Instance, props: Props?)
	if props and props.Parent then
		inst.Parent = props.Parent
	end
end

-- An icon from the atlas (a white mask, tinted with ImageColor3).
function Kit.glyph(name: string, props: Props?): ImageLabel
	local image = Kit.new("ImageLabel", {
		Name = "Glyph",
		BackgroundTransparency = 1,
		Image = UiAssets.atlas,
		ImageColor3 = C.fg,
		Size = UDim2.fromOffset(24, 24),
		ScaleType = Enum.ScaleType.Fit,
	})
	Kit.setGlyph(image, name)
	apply(image, props)
	parent(image, props)
	return image
end

function Kit.setGlyph(image: ImageLabel, name: string)
	local cell = IconAtlas.icons[name]
	if cell then
		image.ImageRectOffset = Vector2.new(cell[1] * IconAtlas.cell, cell[2] * IconAtlas.cell)
		image.ImageRectSize = Vector2.new(IconAtlas.cell, IconAtlas.cell)
		image.ImageTransparency = 0
	else
		image.ImageTransparency = 1
	end
end

-- Body text on dark surfaces.
function Kit.text(props: Props): TextLabel
	local defaults: Props = { FontFace = Theme.font.ui, TextColor3 = C.fg, TextSize = 18 }
	for key, value in props do
		defaults[key] = value
	end
	return Kit.label(defaults)
end

-- A wide-caps title.
function Kit.title(props: Props): TextLabel
	local defaults: Props = { FontFace = Theme.font.head, TextColor3 = C.fg, TextSize = 28 }
	for key, value in props do
		defaults[key] = value
	end
	if type(defaults.Text) == "string" then
		defaults.Text = string.upper(defaults.Text)
	end
	return Kit.label(defaults)
end

-- A dark glass panel.
function Kit.glass(props: Props, radius: number?): Frame
	local frame = Kit.new("Frame", { BackgroundColor3 = C.surface, BackgroundTransparency = 0.06, BorderSizePixel = 0 })
	apply(frame, props)
	Kit.corner(radius or 16).Parent = frame
	Kit.stroke(C.line, 1, 0).Parent = frame
	parent(frame, props)
	return frame
end

-- A card inside a panel (rows, tiles).
function Kit.card(props: Props, radius: number?): Frame
	local frame = Kit.new("Frame", { BackgroundColor3 = C.surface2, BorderSizePixel = 0 })
	apply(frame, props)
	Kit.corner(radius or 12).Parent = frame
	Kit.stroke(C.line, 1, 0).Parent = frame
	parent(frame, props)
	return frame
end

export type BtnKind = "amber" | "buy" | "danger" | "violet" | "ghost" | "outline"

type BtnStyle = { face: Color3, lip: Color3?, stroke: Color3?, text: Color3, font: Font, faceAlpha: number? }
local BTN: { [string]: BtnStyle } = {
	amber = { face = C.amber, lip = C.amberDark, text = C.amberInk, font = Theme.font.head },
	buy = { face = C.buy, lip = C.buyDark, text = C.fg, font = Theme.font.head },
	danger = { face = C.red, lip = C.redDark, text = C.fg, font = Theme.font.head },
	violet = { face = C.violet, lip = C.violetDark, text = C.fg, font = Theme.font.head },
	ghost = { face = C.surface2, stroke = C.line2, text = C.fg, font = Theme.font.headSemi },
	outline = { face = C.cyan, faceAlpha = 0.86, stroke = C.cyan, text = C.cyan, font = Theme.font.head },
}
local LABEL_PROPS = { TextSize = true, FontFace = true, TextColor3 = true, Icon = true, IconColor = true, Radius = true }
local LIP = 4

-- A raised button. Its own Text is the source of truth; the Face/Label
-- children draw it. Optional props: Icon (atlas name), IconColor, Radius.
function Kit.btn(kind: BtnKind, props: Props): TextButton
	local style = BTN[kind]
	local button = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		Size = UDim2.fromOffset(200, 56),
	}) :: TextButton
	apply(button, props, LABEL_PROPS)
	button.TextTransparency = 1
	local radius = props.Radius or 12
	local lip = Kit.new("Frame", {
		Name = "Lip",
		BorderSizePixel = 0,
		BackgroundColor3 = style.lip or style.face,
		BackgroundTransparency = if style.lip then 0 else 1,
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	})
	Kit.corner(radius).Parent = lip
	local face = Kit.new("Frame", {
		Name = "Face",
		BorderSizePixel = 0,
		BackgroundColor3 = style.face,
		BackgroundTransparency = style.faceAlpha or 0,
		Size = UDim2.new(1, 0, 1, if style.lip then -LIP else 0),
		Parent = button,
	})
	Kit.corner(radius).Parent = face
	if style.stroke then
		Kit.stroke(style.stroke, 1.5, 0).Parent = face
	end
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = face
	if props.Icon then
		Kit.glyph(props.Icon, { Name = "Icon", ImageColor3 = props.IconColor or style.text, Size = UDim2.fromOffset(24, 24), LayoutOrder = 1, Parent = face })
	end
	local label = Kit.label({
		Name = "Label",
		Text = button.Text,
		FontFace = props.FontFace or style.font,
		TextColor3 = props.TextColor3 or style.text,
		TextSize = props.TextSize or 20,
		LayoutOrder = 2,
		Parent = face,
	})
	button:GetPropertyChangedSignal("Text"):Connect(function()
		label.Text = button.Text
	end)
	button:SetAttribute("Kind", kind)
	button.MouseEnter:Connect(function()
		if Kit.covered(button) then
			return
		end
		if button.Active then
			face.BackgroundColor3 = BTN[button:GetAttribute("Kind") :: string].face:Lerp(Color3.new(1, 1, 1), 0.1)
		end
	end)
	button.MouseLeave:Connect(function()
		face.BackgroundColor3 = BTN[button:GetAttribute("Kind") :: string].face
	end)
	button.Activated:Connect(function()
		if Kit.onActivated then
			Kit.onActivated()
		end
	end)
	parent(button, props)
	return button
end

-- Restyle a Kit.btn (for example a toggle between ghost and amber).
function Kit.setBtnKind(button: TextButton, kind: BtnKind)
	local style = BTN[kind]
	button:SetAttribute("Kind", kind)
	local face = button:FindFirstChild("Face") :: Frame
	local lip = button:FindFirstChild("Lip") :: Frame
	face.BackgroundColor3 = style.face
	face.BackgroundTransparency = style.faceAlpha or 0
	face.Size = UDim2.new(1, 0, 1, if style.lip then -LIP else 0)
	lip.BackgroundColor3 = style.lip or style.face
	lip.BackgroundTransparency = if style.lip then 0 else 1
	local stroke = face:FindFirstChildOfClass("UIStroke")
	if style.stroke and stroke == nil then
		Kit.stroke(style.stroke, 1.5, 0).Parent = face
	elseif stroke then
		stroke.Enabled = style.stroke ~= nil
		stroke.Color = style.stroke or stroke.Color
	end
	local label = face:FindFirstChild("Label") :: TextLabel
	label.TextColor3 = style.text
	local icon = face:FindFirstChild("Icon") :: ImageLabel?
	if icon then
		icon.ImageColor3 = style.text
	end
end

-- Dimmed and inert, or live again.
function Kit.setBtnEnabled(button: TextButton, enabled: boolean)
	button.Active = enabled
	button.AutoButtonColor = false
	local face = button:FindFirstChild("Face") :: Frame?
	if face then
		face.BackgroundTransparency = if enabled then (BTN[button:GetAttribute("Kind") :: string].faceAlpha or 0) else 0.55
		local label = face:FindFirstChild("Label") :: TextLabel?
		if label then
			label.TextTransparency = if enabled then 0 else 0.45
		end
	end
end

-- A pill chip (difficulty, attack share, filters). setPill marks it chosen.
function Kit.pill(props: Props): TextButton
	local button = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = C.surface2,
		BorderSizePixel = 0,
		FontFace = Theme.font.uiBold,
		TextColor3 = C.fgSoft,
		TextSize = 18,
		Size = UDim2.fromOffset(110, 40),
	}) :: TextButton
	apply(button, props)
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = button })
	Kit.stroke(C.line2, 1, 0).Parent = button
	button.MouseEnter:Connect(function()
		if Kit.covered(button) then
			return
		end
		if button:GetAttribute("Selected") ~= true then
			button.BackgroundColor3 = C.surface3
		end
	end)
	button.MouseLeave:Connect(function()
		if button:GetAttribute("Selected") ~= true then
			button.BackgroundColor3 = C.surface2
		end
	end)
	button.Activated:Connect(function()
		if Kit.onActivated then
			Kit.onActivated()
		end
	end)
	parent(button, props)
	return button
end

local AMBER_TINT = Color3.fromRGB(58, 42, 16)

function Kit.setPill(button: TextButton, selected: boolean)
	button:SetAttribute("Selected", selected)
	button.BackgroundColor3 = if selected then AMBER_TINT else C.surface2
	button.TextColor3 = if selected then C.amber else C.fgSoft
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if selected then C.amber else C.line2
		stroke.Thickness = if selected then 1.5 else 1
	end
end

-- A row of pill tabs. Returns a setter for the selected id.
function Kit.tabs(host: Instance, items: { { id: string, label: string } }, selected: string?, onSelect: (string) -> ()): (string) -> ()
	local buttons: { [string]: TextButton } = {}
	local function set(id: string)
		for key, b in buttons do
			Kit.setPill(b, key == id)
		end
	end
	for i, item in items do
		local b = Kit.pill({ Text = item.label, Size = UDim2.fromOffset(0, 44), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = i, Parent = host })
		Kit.padding(0, 16).Parent = b
		buttons[item.id] = b
		b.Activated:Connect(function()
			set(item.id)
			onSelect(item.id)
		end)
	end
	if selected then
		set(selected)
	end
	return set
end

-- A round translucent icon button (the top-left row).
function Kit.roundIcon(name: string, props: Props?): TextButton
	local button = Kit.new("TextButton", {
		Name = name,
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(44, 44),
	}) :: TextButton
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = button })
	Kit.glyph(name, { Name = "Icon", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(26, 26), Parent = button })
	button.MouseEnter:Connect(function()
		if Kit.covered(button) then
			return
		end
		button.BackgroundTransparency = 0.15
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundTransparency = 0.35
	end)
	button.Activated:Connect(function()
		if Kit.onActivated then
			Kit.onActivated()
		end
	end)
	apply(button, props)
	parent(button, props)
	return button
end

-- The "off" mark across a square icon button (muted sound, Bruno 2026-10-28):
-- a red diagonal bar with a dark edge, hidden until the caller shows it.
function Kit.slash(button: GuiObject): Frame
	local bar = Kit.new("Frame", {
		Name = "Slash",
		BackgroundColor3 = C.stamp,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.85, 0.09),
		Rotation = -45,
		ZIndex = 2,
		Visible = false,
		Parent = button,
	}) :: Frame
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = bar })
	Kit.new("UIStroke", { Color = C.inkBlack, Thickness = 1, Transparency = 0.3, Parent = bar })
	return bar
end

-- A currency badge: stars (gold outline) or Robux (green). Returns the frame
-- and its number label.
function Kit.currency(kind: "stars" | "robux", text: string, props: Props?): (Frame, TextLabel)
	local robux = kind == "robux"
	local frame = Kit.new("Frame", {
		BackgroundColor3 = if robux then C.buy else C.surface,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
	}) :: Frame
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = frame })
	Kit.stroke(if robux then C.buyDark else C.star, 2, 0).Parent = frame
	Kit.padding(0, 14).Parent = frame
	Kit.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = frame
	if robux then
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, Size = UDim2.fromOffset(20, 20), LayoutOrder = 1, Parent = frame })
	else
		Kit.glyph("star", { ImageColor3 = C.star, Size = UDim2.fromOffset(20, 20), LayoutOrder = 1, Parent = frame })
	end
	local label = Kit.text({ Name = "Amount", Text = text, FontFace = Theme.font.uiHeavy, TextSize = 20, LayoutOrder = 2, Parent = frame })
	apply(frame, props)
	parent(frame, props)
	return frame, label
end

-- A small coloured tag ("NEW", "LIMITED", a rarity).
function Kit.tag(text: string, color: Color3, props: Props?): TextLabel
	local label = Kit.text({
		Text = string.upper(text),
		FontFace = Theme.font.head,
		TextSize = 13,
		TextColor3 = C.amberInk,
		BackgroundColor3 = color,
		BackgroundTransparency = 0,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = label })
	Kit.padding(3, 8).Parent = label
	apply(label, props)
	parent(label, props)
	return label
end

-- A star progress bar with the price in the middle ("★ 20,000"). Returns the
-- track, its fill and the price label.
function Kit.priceBar(props: Props): (Frame, Frame, TextLabel)
	local track = Kit.new("Frame", { BackgroundColor3 = C.surface3, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 36) }) :: Frame
	apply(track, props)
	Kit.corner(8).Parent = track
	local fill = Kit.new("Frame", { Name = "Fill", BackgroundColor3 = Color3.fromRGB(110, 92, 58), BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = track })
	Kit.corner(8).Parent = fill
	local row = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = track })
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
	Kit.glyph("star", { ImageColor3 = C.star, Size = UDim2.fromOffset(18, 18), LayoutOrder = 1, ZIndex = 2, Parent = row })
	local label = Kit.text({ Name = "Price", Text = "", FontFace = Theme.font.uiHeavy, TextSize = 19, LayoutOrder = 2, ZIndex = 2, Parent = row })
	parent(track, props)
	return track, fill, label
end

-- A vertical scrolling area that grows with its content.
function Kit.scroll(props: Props): ScrollingFrame
	local frame = Kit.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.line2,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
	}) :: ScrollingFrame
	apply(frame, props)
	parent(frame, props)
	return frame
end

export type Modal = {
	root: Frame,
	window: Frame,
	header: Frame,
	body: GuiObject,
	close: () -> (),
}

local HEADER = 96

-- The modal shell: a scrim, a centred window with an icon, a wide-caps title,
-- an optional subtitle, a close X and a body. With `height` the body fills
-- the window (scrolling if `scroll`); without it the window grows with the
-- body. The scrim and the X close it and call onClose.
function Kit.modal(host: Instance, opts: {
	title: string,
	subtitle: string?,
	icon: string?,
	iconColor: Color3?,
	width: number,
	height: number?,
	scroll: boolean?,
	onClose: (() -> ())?,
}): Modal
	local root = Kit.new("Frame", { Name = "Modal", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = host }) :: Frame
	local scrim = Kit.new("TextButton", {
		Name = "Scrim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.scrim,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = root,
	})
	local window = Kit.glass({
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(opts.width, opts.height or 0),
		AutomaticSize = if opts.height then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.03,
		Parent = root,
	}, 20)
	local header = Kit.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, -80, 0, HEADER), Parent = window }) :: Frame
	Kit.padding(0, 32).Parent = header
	Kit.list(Enum.FillDirection.Horizontal, 16, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = header
	if opts.icon then
		Kit.glyph(opts.icon, { ImageColor3 = opts.iconColor or C.amber, Size = UDim2.fromOffset(32, 32), LayoutOrder = 1, Parent = header })
	end
	local titles = Kit.new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 2, Parent = header })
	Kit.list(Enum.FillDirection.Vertical, 4).Parent = titles
	Kit.title({ Name = "Title", Text = opts.title, TextSize = 30, LayoutOrder = 1, Parent = titles })
	if opts.subtitle then
		Kit.text({ Name = "Subtitle", Text = opts.subtitle, TextColor3 = C.fgSoft, TextSize = 18, LayoutOrder = 2, Parent = titles })
	end
	local x = Kit.new("TextButton", {
		Name = "Close",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.surface2,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -24, 0, HEADER / 2),
		Size = UDim2.fromOffset(48, 48),
		Parent = window,
	})
	Kit.corner(12).Parent = x
	Kit.glyph("close", { ImageColor3 = C.fgSoft, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), Parent = x })
	x.MouseEnter:Connect(function()
		if Kit.covered(x) then
			return
		end
		x.BackgroundTransparency = 0
	end)
	x.MouseLeave:Connect(function()
		x.BackgroundTransparency = 1
	end)
	local body: GuiObject
	if opts.height and opts.scroll then
		body = Kit.scroll({ Name = "Body", Position = UDim2.fromOffset(0, HEADER), Size = UDim2.new(1, -8, 1, -HEADER - 16), Parent = window })
	elseif opts.height then
		body = Kit.new("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, HEADER), Size = UDim2.new(1, 0, 1, -HEADER), Parent = window })
	else
		-- Auto height: the window grows to the body's bottom edge.
		body = Kit.new("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, HEADER), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = window })
	end
	Kit.new("UIPadding", {
		PaddingLeft = UDim.new(0, 32),
		PaddingRight = UDim.new(0, 32),
		PaddingBottom = UDim.new(0, 28),
		Parent = body,
	})
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		Kit.hideTip()
		root:Destroy()
		if opts.onClose then
			opts.onClose()
		end
	end
	scrim.Activated:Connect(close)
	x.Activated:Connect(close)
	return { root = root, window = window, header = header, body = body, close = close }
end

-- Tooltips: one shared card shown above the hovered target. Root sets
-- Kit.tipLayer and Kit.tipScale (the canvas UIScale).
Kit.tipLayer = nil :: Frame?
Kit.tipScale = nil :: UIScale?
local tipCard: ImageLabel? = nil
local tipOwner: GuiObject? = nil

local function tipFrame(): ImageLabel?
	local layer = Kit.tipLayer
	if layer == nil then
		return nil
	end
	if tipCard == nil or tipCard.Parent == nil then
		-- 2026-10-27: a slip of typing paper (the dossier look).
		local card = Kit.new("ImageLabel", {
			Name = "Tooltip",
			AnchorPoint = Vector2.new(0.5, 1),
			Size = UDim2.fromOffset(320, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false,
			ZIndex = 100,
			BackgroundColor3 = C.sheet,
			BorderSizePixel = 0,
			Image = UiAssets.dossier.tex_paper or "",
			ScaleType = Enum.ScaleType.Tile,
			TileSize = UDim2.fromOffset(256, 256),
			Parent = layer,
		})
		Kit.stroke(C.sheetLine, 1.5, 0).Parent = card
		Kit.padding(12, 14).Parent = card
		Kit.list(Enum.FillDirection.Vertical, 6).Parent = card
		tipCard = card
	end
	return tipCard
end

-- Callers fill tooltips with the navy theme's light text colours; on paper
-- they become ink (the accents keep their hue, darkened to read).
local INK: { [string]: Color3 } = {
	[C.fg:ToHex()] = C.inkBlack,
	[C.fgSoft:ToHex()] = C.inkFaded,
	[C.fgMuted:ToHex()] = C.inkFaded,
	[C.star:ToHex()] = Color3.fromHex("#B07A0E"),
	[C.amber:ToHex()] = Color3.fromHex("#B07A0E"),
	[C.red:ToHex()] = C.stamp,
	[C.ok:ToHex()] = Color3.fromHex("#2E8A3E"),
	[C.cyan:ToHex()] = Color3.fromHex("#2C5E8A"),
}
local function inkOnPaper(card: Instance)
	for _, d in card:GetDescendants() do
		if d:IsA("TextLabel") then
			local mapped = INK[d.TextColor3:ToHex()]
			if mapped then
				d.TextColor3 = mapped
			else
				local c = d.TextColor3
				if 0.3 * c.R + 0.59 * c.G + 0.11 * c.B > 0.6 then
					d.TextColor3 = C.inkBlack
				end
			end
		end
	end
end

local function hide()
	if tipCard then
		tipCard.Visible = false
	end
	tipOwner = nil
end

-- Hides whichever tooltip is showing (a panel opening where it stands).
Kit.hideTip = hide

export type TipOptions = {
	-- No tooltip while this is true (e.g. ARSENAL while its weapons are open).
	skip: (() -> boolean)?,
	-- Sit above this frame instead of the target, so the tooltip never covers
	-- the frame the target is in (2026-11-10 review: the Arsenal's weapons).
	above: (() -> GuiObject?)?,
}

-- Shows a tooltip while the mouse is over `target` (never on touch); `fill`
-- builds its content each time it opens, so it is always current.
function Kit.tip(target: GuiObject, fill: (card: Frame) -> (), options: TipOptions?)
	target.MouseEnter:Connect(function()
		if Kit.covered(target) or Kit.touch() then
			return
		end
		if options and options.skip and options.skip() then
			return
		end
		local card = tipFrame()
		local layer = Kit.tipLayer
		if card == nil or layer == nil then
			return
		end
		for _, child in card:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		tipOwner = target
		fill(card :: any)
		inkOnPaper(card)
		local s = if Kit.tipScale then Kit.tipScale.Scale else 1
		local origin = layer.AbsolutePosition
		local x = (target.AbsolutePosition.X - origin.X + target.AbsoluteSize.X / 2) / s
		local over = if options and options.above then options.above() else nil
		local y = ((over or target).AbsolutePosition.Y - origin.Y) / s - 10
		local maxX = layer.AbsoluteSize.X / s
		local half = 160
		card.Position = UDim2.fromOffset(math.clamp(x, half + 8, maxX - half - 8), y)
		card.Visible = true
	end)
	target.MouseLeave:Connect(function()
		if tipOwner == target then
			hide()
		end
	end)
	target.Destroying:Connect(function()
		if tipOwner == target then
			hide()
		end
	end)
end

function Kit.hideTip()
	hide()
end

-- "0:44", "11:00:51", "9d 10h".
function Kit.clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h, m, s = seconds // 3600, (seconds // 60) % 60, seconds % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

function Kit.days(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d, h = seconds // 86400, (seconds // 3600) % 24
	if d > 0 then
		return `{d}d {h}h`
	end
	return Kit.clock(seconds)
end

-- "5,955"
function Kit.commas(n: number): string
	local s = tostring(math.floor(n))
	local sign = ""
	if string.sub(s, 1, 1) == "-" then
		sign, s = "-", string.sub(s, 2)
	end
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return sign .. out
end

return Kit
