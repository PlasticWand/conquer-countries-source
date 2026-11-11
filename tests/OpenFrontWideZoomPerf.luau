--!strict
-- Run serially: cba537a, 84a82ed, then no argument. No other Lune measurement.
local fs,luau,serde,process=require('@lune/fs'),require('@lune/luau'),require('@lune/serde'),require('@lune/process')
local run=luau.load(fs.readFile('tests/OpenFrontWideZoomHarness.luau'))()
local revision=process.args[1]
assert(revision==nil or revision=='cba537a' or revision=='84a82ed','unsupported baseline')
local result=run(revision,180)
local output=serde.encode('json',result)..'\n'
fs.writeFile('tests/fixtures/OpenFrontWideZoomPerf.'..(revision or 'after')..'.jsonl',output)
print(output)
