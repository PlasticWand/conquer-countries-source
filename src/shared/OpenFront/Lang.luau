--!strict
-- Ported from OpenFront v0.35.2 (src/client/Utils.ts translateText), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- OpenFront's translateText for the English HUD strings (Data/LangEn):
-- "section.key" (or deeper, "chat.help.troops"), with {param} replaced by
-- params[param]. A missing key returns the key itself, as the source does.

local LangEn = require(script.Parent.Data.LangEn) :: any
local LangConquest = require(script.Parent.Data.LangConquest) :: any

local Lang = {}

-- ICU plurals as OpenFront's strings use them, English rules:
-- "{count, plural, one {# nuke ...} other {# nukes ...}}" ("=N" cases too);
-- "#" becomes the number.
local function plurals(text: string, params: { [string]: any }): string
	return (string.gsub(text, "%b{}", function(block: string): string
		local var, rest = string.match(block, "^{(%w+),%s*plural,(.*)}$")
		if var == nil or rest == nil then
			return block
		end
		local n = tonumber(params[var]) or 0
		local exact, one, other = nil, nil, nil
		for key, body in string.gmatch(rest, "%s*(=?%w+)%s*(%b{})") do
			if key == `={n}` then
				exact = body
			elseif key == "one" then
				one = body
			elseif key == "other" then
				other = body
			end
		end
		local chosen = exact or (if n == 1 and one then one else other) or one or ""
		local inner = string.sub(chosen, 2, -2)
		return (string.gsub(inner, "#", function(): string
			return tostring(n)
		end))
	end))
end

local function lookup(root: any, key: string): string?
	local node: any = root
	for part in string.gmatch(key, "[^%.]+") do
		if type(node) ~= "table" then
			return nil
		end
		node = node[part]
	end
	return if type(node) == "string" then node else nil
end

function Lang.t(key: string, params: { [string]: any }?): string
	local node = lookup(LangEn, key) or lookup(LangConquest, key)
	if node == nil then
		return key
	end
	if params == nil then
		return node
	end
	local p = params :: { [string]: any }
	local text = if string.find(node, "plural,", 1, true) then plurals(node, p) else node
	-- Unknown params stay as "{name}", like the source's formatter.
	return (string.gsub(text, "{(%w+)}", function(name: string): string
		local v = p[name]
		if v == nil then
			return `\{{name}\}`
		end
		return tostring(v)
	end))
end

return Lang
