--!strict
-- Roblox presentation choices approved by Bruno, 2026-10-27. Source defaults
-- remain in RenderDefaults/StructureMath; these never change gameplay ranges.
return {
	-- A/B switches: restart the match after changing these.
	splitMapGuis = false, -- native overlap/appearance review pending; ordered passes preserve existing interleaving
	deferredOwnership = false, -- lower callback bursts trade against sparse total CPU and drain latency; phone A/B pending
	deferredTilesPerFrame = 2048,
	deferredMs = 1.25,
	deferredMaxPendingRecords = 32768, -- sparse/run record cap; overflow uses existing immediate invalidation
	deferredBatchBytes = 512*1024, -- conservative accounting includes both references to a shared bulk buffer
	structureScale = 0.5,
	continuousStructureZoom = true,
	capNameScreenHeight = true, -- Bruno: deliberate difference from OpenFront.
	nameMaxViewportHeight = 0.08, -- name em; flag/troops/status scale with it
	structureAtlasPages = 2, -- bounded 2 * 990^2 * 4 native pixel bytes
	structureComposeMs = 1,
	smoothShips = true, -- original 256px masks; optional allocation has source fallback
	capWarshipHealthBars = true, -- Bruno, 2026-11-13: deliberate difference from OpenFront.
	warshipHealthBarMaxWidth = 48,
	warshipHealthBarMaxHeight = 5,
	warshipHealthBarMaxBorder = 1,
	transportScale = 0.7, -- Bruno, 2026-10-29: boats and trade ships at 70%; warships unchanged
	shipArtMs = 1,
	shipArtPixelsPerFrame = 4096,
	-- Rejected soft-filter prototype, retained for regression comparisons.
	-- Bruno chose static curved coasts; keep territory filtering off.
	softMapEdges = false,
	staticCoasts = true,
	coastTouchResolution = 2,
	coastDesktopResolution = 4,
	coastTouchPixelBytes = 16*1024*1024,
	coastDesktopPixelBytes = 64*1024*1024,
	coastBuildMs = 1,
	coastLoadMs = 8,
	coastComposeMs = .75,
	coastTouchCellsPerFrame = 256,
	coastDesktopCellsPerFrame = 512,
	coastMinScale = .75, -- subpixel-wide coasts use the base raster at wider zoom
	coastTouchViews = 384,
	coastDesktopViews = 1024,
	coastCreatesPerFrame = 16, -- shares the scene's 25-new-view allowance
	coastDeletesPerFrame = 32,
	-- Phone regression mitigation (2026-10-28): source 1..3 exposes thousands
	-- of GUI rail tiles. False retains cba537a's 3..5; Bruno can choose parity.
	sourceRailFade = false,
	railCreatesPerFrame = 32,
	railDeletesPerFrame = 32,
	adornmentUpdatesPerFrame = 32,
	structureLodVisitsPerFrame = 64,
	rasterBaseMs = 2,
	rasterDesktopMaxMs = 4,
	rasterTouchMaxMs = 2.5,
	rasterMaxPixels = 131072,
	coherentFallout = true, -- Bruno, 2026-11-17: hide the dirty-block reveal grid.
	falloutRevealMinTiles = 64,
	falloutRevealMaxPixels = 65536, -- one <=256 KiB native write, no extra images
	falloutRevealRegions = 8, -- overload retains ordinary bounded raster progress
	defenseProbeTilesPerFrame = 2048,
	defenseProbeMs = 1,
	defenseExplosionScale = 2.5,
	defenseSmokeLifetimeMs = 3000,
	falloutLifetimeMs = 15000,
	falloutMaskSize = 128,
	falloutTouchMasks = 4,
	falloutDesktopMasks = 8,
	falloutTouchSprites = 24, -- global fire/smoke, including source nuke debris
	falloutDesktopSprites = 48,
	falloutMaskPixelsPerFrame = 1024,
	falloutMaskMs = 1,
	falloutGlowAlpha = .24,
}
