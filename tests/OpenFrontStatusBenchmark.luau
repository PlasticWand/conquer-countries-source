--!strict
-- Lune codec adapter only; excludes Roblox native codec/image upload and GUI/GPU.
local fs,luau=require('@lune/fs'),require('@lune/luau')
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local started=os.clock()
local Atlas=H.require(root.StatusAtlas)
local loadMs=(os.clock()-started)*1000
local encoding=luau.load(fs.readFile('tests/OpenFrontEncodingHarness.luau'))()
local before=os.clock()
local pixels=Atlas.rgba(encoding,'zstd')
print(string.format('Status atlas Lune codec adapter: require %.3f ms; decode %.3f ms; RGBA %d bytes',
	loadMs,(os.clock()-before)*1000,buffer.len(pixels)))
