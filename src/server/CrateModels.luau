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

-- Each model's copies, tried in order. InsertService loads only models the
-- game's owner owns, so the game moving to Bruno's group Echo Arcade (planned
-- for 2026-11-21) needs the group's copies; World_Echo's stay as the
-- fallback, so the crates work before and after the move. (Group copies
-- uploaded 2026-11-16 from World_Echo's, byte for byte; Echo Arcade is
-- group 574812649.)
local ASSETS: { [string]: { number } } = {
	Standard = { 79620105378926, 104794643667639 },
	Legendary = { 136320926410578, 138891362258996 },
	-- The supply depot the crate sits in (Bruno: moody, mostly in shadow):
	-- Floor, Racks and Wall, lighting baked in, placed as they are.
	Depot = { 119320120928262, 106300146678827 },
}

function CrateModels.start()
	local folder = Instance.new("Folder")
	folder.Name = "CrateModels"
	folder.Parent = ReplicatedStorage
	for name, ids in ASSETS do
		task.spawn(function()
			for attempt = 1, 3 * #ids do
				local id = ids[(attempt - 1) % #ids + 1]
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
				-- (the next copy at once; a short wait before going round again)
				if attempt % #ids == 0 then
					task.wait(2 * attempt / #ids)
				end
			end
			warn(`[CrateModels] could not load {name} ({table.concat(ids, ", ")})`)
		end)
	end
end

return CrateModels
