--!strict
-- Loads the supply crates (art/crate/, uploaded as World_Echo 2026-11-02;
-- docs/design/store-items.md) into ReplicatedStorage.CrateModels for the
-- client's crate opening: Standard and Legendary, each with MeshParts named
-- Body, Lid, Strap0, Strap1, Catch0, Catch1 and Glow, and the Depot around
-- them. A failed crate load leaves the folder without it; the client then
-- shows the "You got" card on its own (without the Depot, a plain desk).

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrateModels = {}

local ASSETS: { [string]: number } = {
	Standard = 104794643667639,
	Legendary = 138891362258996,
	-- The supply depot the crate sits in (Bruno: moody, mostly in shadow):
	-- Floor, Racks and Wall, lighting baked in, placed as they are.
	Depot = 106300146678827,
}

function CrateModels.start()
	local folder = Instance.new("Folder")
	folder.Name = "CrateModels"
	folder.Parent = ReplicatedStorage
	for name, id in ASSETS do
		task.spawn(function()
			for attempt = 1, 3 do
				local ok, container = pcall(function()
					return InsertService:LoadAsset(id)
				end)
				if ok and container then
					local model = container:FindFirstChildWhichIsA("Model") or container
					local crate = Instance.new("Model")
					crate.Name = name
					-- Parts arrive as X_Body or X_L_Body; keep the bare names.
					for _, part in model:GetDescendants() do
						if part:IsA("MeshPart") then
							local bare = (string.gsub(part.Name, "^X_", ""))
							part.Name = (string.gsub(bare, "^L_", ""))
							part.Anchored = true
							part.CanCollide = false
							part.CastShadow = false
							part.Parent = crate
						end
					end
					container:Destroy()
					crate.Parent = folder
					return
				end
				task.wait(2 * attempt)
			end
			warn(`[CrateModels] could not load {name} ({id})`)
		end)
	end
end

return CrateModels
