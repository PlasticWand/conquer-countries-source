-- lune run tests/run [filter]
-- Runs every tests/*.spec.luau. A spec returns function(t) and registers
-- cases with t.test(name, fn); assertions raise errors.

local fs = require("@lune/fs")
local process = require("@lune/process")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local Harness = require("./harness")
local Shared = Harness.shared()
-- Tests stay strict: a failing signal handler fails the test.
Harness.require(Shared.Signal).onError = function(message: any)
	error(message, 0)
end

local filter = process.args[1]

local passed, failed = 0, 0
local failures: { string } = {}

local function fmt(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local t = {}
t.Shared = Shared
t.readFile = fs.readFile -- golden fixtures (tests/fixtures/...)
t.isFile = fs.isFile
t.mount = function(dir: string, name: string?): any
	return Harness.mount(dir, name)
end
-- A module from a t.mount tree (an imported map's chunk).
t.load = function(node: any): any
	return Harness.require(node)
end
t.json = function(text: string): any
	return serde.decode("json", text)
end
t.require = function(path: string): any
	local node = Shared
	for part in path:gmatch("[^%.]+") do
		node = node[part]
	end
	return Harness.require(node)
end
function t.eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "values differ"}: expected {fmt(expected)}, got {fmt(actual)}`, 2)
	end
end
function t.ok(value: any, label: string?)
	if not value then
		error(label or "expected a truthy value", 2)
	end
end
function t.near(actual: number, expected: number, tolerance: number, label: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{label or "values differ"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end
function t.errors(fn: () -> (), label: string?)
	if pcall(fn) then
		error(label or "expected an error", 2)
	end
end

local currentSpec = ""
function t.test(name: string, fn: () -> ())
	local full = `{currentSpec} > {name}`
	if filter and not full:lower():find(filter:lower(), 1, true) then
		return
	end
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, `FAIL {full}\n     {err}`)
	end
end

local specs = {}
for _, entry in fs.readDir("tests") do
	if entry:match("%.spec%.luau$") then
		table.insert(specs, entry)
	end
end
table.sort(specs)

for _, entry in specs do
	currentSpec = entry:gsub("%.spec%.luau$", "")
	local path = `tests/{entry}`
	local chunk = luau.load(fs.readFile(path), { debugName = path })
	local spec = chunk()
	spec(t)
end

for _, line in failures do
	print(line)
end
print(`{passed} passed, {failed} failed`)
process.exit(if failed > 0 then 1 else 0)
