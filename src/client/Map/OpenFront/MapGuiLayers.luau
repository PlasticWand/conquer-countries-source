--!strict
-- Ported from RoWorld 2be8efb (src/client/Map/MapView.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
-- Three logical groups, interleaved at existing Sibling pass boundaries.
-- Effects were inserted after Names at equal Z=8; world text is above both.
-- Native factories are injected so lifecycle and coordinate contracts run under Lune.
local Layers = {}
Layers.__index = Layers

function Layers.new(root: Frame, host: ScreenGui?, enabled: boolean, native: any): any
	local self = setmetatable({root=root, guis={}, roots={}, enabled=enabled and host~=nil},Layers)
	if not self.enabled or not host then return self end
	for index,name in {"Ground","Structures","Moving","Labels","Effects","Text"} do
		local gui = native.new("ScreenGui")
		gui.Name = "OpenFrontMap"..name
		gui.IgnoreGuiInset,gui.ScreenInsets = true,native.Enum.ScreenInsets.None
		gui.ClipToDeviceSafeArea,gui.SafeAreaCompatibility = false,native.Enum.SafeAreaCompatibility.None
		gui.ResetOnSpawn,gui.ZIndexBehavior = false,native.Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = host.DisplayOrder+index
		local hold = native.new("Frame")
		hold.Name,hold.BackgroundTransparency,hold.BorderSizePixel = "Viewport",1,0
		hold.ClipsDescendants,hold.Visible = true,root.Visible
		hold.Parent = gui
		self.guis[index],self.roots[name] = gui,hold
		gui.Parent = host.Parent
	end
	self.native=native
	return self
end

function Layers.parent(self: any, pass: string): Frame
	if not self.enabled then return self.root end
	local group = if pass=="Ground" then "Ground" elseif pass=="Structures" then "Structures"
		elseif pass=="WorldText" then "Text" elseif pass=="Effects" then "Effects"
		elseif pass=="Names" or pass=="PreviewText" then "Labels"
		elseif pass=="Missiles" or pass=="Telegraphs" or pass=="Progress"
			or pass=="Ranges" or pass=="PreviewAim" then "Moving" else nil
	return (if group then self.roots[group] else nil) or self.root
end

function Layers.layout(self: any, camera: any)
	if not self.enabled then return end
	local position=self.native.UDim2.fromOffset(camera.left,camera.top)
	local size=self.native.UDim2.fromOffset(camera.viewportWidth,camera.viewportHeight)
	for _,root in self.roots do
		if root.Position~=position then root.Position=position end
		if root.Size~=size then root.Size=size end
	end
end

function Layers.show(self: any, visible: boolean)
	for _,root in self.roots do if root.Visible~=visible then root.Visible=visible end end
end

function Layers.contains(self: any, object: GuiObject): boolean
	for _,gui in self.guis do if object:IsDescendantOf(gui) then return true end end
	return false
end

function Layers.destroy(self: any)
	for _,gui in self.guis do gui:Destroy() end
	table.clear(self.guis);table.clear(self.roots)
end

return Layers
