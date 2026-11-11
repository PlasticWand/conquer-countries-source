--!strict
-- Binary-equivalent test adapter; this is not a Roblox native cost measurement.
local serde = require('@lune/serde')
return {
	Base64Decode = function(_, input: buffer): buffer
		local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
		local digits = {}; for i=1,#alphabet do digits[string.byte(alphabet,i)]=i-1 end
		local encoded = buffer.tostring(input)
		local output = buffer.create(math.floor(#encoded*3/4))
		local value,bits,cursor = 0,0,0
		for i=1,#encoded do
			local digit=digits[string.byte(encoded,i)]
			if digit then
				value=value*64+digit; bits+=6
				if bits>=8 then
					bits-=8; local divisor=2^bits
					buffer.writeu8(output,cursor,math.floor(value/divisor)); cursor+=1; value%=divisor
				end
			end
		end
		return buffer.fromstring(string.sub(buffer.tostring(output),1,cursor))
	end,
	GetDecompressedBufferSize = function(_, input: buffer, _algorithm: any): number
		return #serde.decompress('zstd', buffer.tostring(input))
	end,
	DecompressBuffer = function(_, input: buffer, _algorithm: any): buffer
		return buffer.fromstring(serde.decompress('zstd', buffer.tostring(input)))
	end,
}
