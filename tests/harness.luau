-- Loads Rojo-style ModuleScripts under Lune by faking the `script` instance
-- tree, so shared code using require(script.Parent.X) runs unmodified.
-- Only for pure modules (no Roblox services except the faked
-- game:GetService("ReplicatedStorage").Shared).

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Harness = {}

type Node = {
	Name: string,
	Parent: Node?,
	path: string?, -- source file, nil for plain folders
	children: { [string]: Node },
}

local function stripExt(name: string): string?
	return name:match("^(.-)%.luau$") or name:match("^(.-)%.lua$")
end

local function makeNode(name: string, parent: Node?): Node
	local node = { Name = name, Parent = parent, path = nil, children = {} }
	return setmetatable(node :: any, {
		__index = function(_, key)
			local child = rawget(node, "children")[key]
			if child == nil then
				error(`{key} is not a valid member of {name}`, 2)
			end
			return child
		end,
	})
end

local function scan(dir: string, node: Node)
	for _, entry in fs.readDir(dir) do
		local full = `{dir}/{entry}`
		if fs.isDir(full) then
			local child = makeNode(entry, node)
			node.children[entry] = child
			scan(full, child)
		else
			local base = stripExt(entry)
			if base == "init" then
				node.path = full
			elseif base and not base:match("%.") then
				local child = makeNode(base, node)
				child.path = full
				node.children[base] = child
			end
		end
	end
end

-- Returns the root node for `dir`; index it like a Roblox instance.
function Harness.mount(dir: string, name: string?): any
	local root = makeNode(name or dir, nil)
	scan(dir, root)
	return root
end

local loaded: { [any]: any } = {}
local services: { [string]: any } = {}

local fakeGame = {
	GetService = function(_, name: string)
		local service = services[name]
		if service == nil then
			error(`service {name} is not available in the test harness`, 2)
		end
		return service
	end,
}

function Harness.provideService(name: string, service: any)
	services[name] = service
end

function Harness.require(node: any): any
	if loaded[node] ~= nil then
		return loaded[node]
	end
	local path = rawget(node, "path")
	assert(path, `{rawget(node, "Name")} is not a module`)
	local fn = luau.load(fs.readFile(path), {
		debugName = path,
		environment = { script = node, require = Harness.require, game = fakeGame },
		injectGlobals = true,
	})
	local result = fn()
	loaded[node] = result
	return result
end

-- Mounts src/shared as ReplicatedStorage.Shared and returns it.
function Harness.shared(): any
	local shared = Harness.mount("src/shared", "Shared")
	Harness.provideService("ReplicatedStorage", { Shared = shared })
	return shared
end

return Harness
