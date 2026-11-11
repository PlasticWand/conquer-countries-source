return function(t)
	local Base64 = t.require("Base64")
	local Crc32 = t.require("Crc32")
	local TileMap = t.require("TileMap")
	local Rng = t.require("Rng")

	t.test("base64 round-trips every length 0..40", function()
		local rng = Rng.new(5)
		for len = 0, 40 do
			local b = buffer.create(len)
			for i = 0, len - 1 do
				buffer.writeu8(b, i, Rng.int(rng, 0, 255))
			end
			local back = Base64.decode(Base64.encode(b))
			t.eq(buffer.tostring(back), buffer.tostring(b), `length {len}`)
		end
	end)

	t.test("base64 matches the RFC 4648 vectors", function()
		t.eq(Base64.encode(buffer.fromstring("foobar")), "Zm9vYmFy")
		t.eq(Base64.encode(buffer.fromstring("fo")), "Zm8=")
		t.eq(buffer.tostring(Base64.decode("Zm9vYg==")), "foob")
	end)

	t.test("crc32 check value", function()
		t.eq(Crc32.ofString("123456789"), 0xCBF43926)
	end)

	t.test("a corrupted chunk fails its checksum", function()
		-- (an imported OpenFront map's chunk; MapLoader decodes these)
		local Maps = t.mount("src/maps", "OpenFrontMaps")
		local good = t.load(Maps.World.M00_00)
		t.ok(TileMap.decodeChunk(good) ~= nil, "the real chunk decodes")
		local chunk = table.clone(good)
		chunk.checksum = (chunk.checksum + 1) % 4294967296
		t.errors(function()
			TileMap.decodeChunk(chunk)
		end)
	end)
end
