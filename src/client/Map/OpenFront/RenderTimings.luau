--!strict
-- Bounded controller-owned CPU diagnostics; no native/GPU timing claim.
local Timings = {}
Timings.__index = Timings
local NAMES = {"frame", "prepare", "raster", "scene", "units", "names", "anchors", "status", "icons", "fx", "trails",
	"previewGhost", "previewRanges", "previewTrajectory", "previewArc", "previewQuery"}
type Bucket = {values: {number}, cursor: number, calls: number, total: number, last: number}
export type Timings = typeof(setmetatable({} :: {enabled: boolean, started: number, buckets: {[string]: Bucket}}, Timings))
function Timings.new(enabled: boolean?): Timings
	local self = setmetatable({enabled = enabled ~= false, started = os.clock(), buckets = {}}, Timings) :: Timings
	for _, name in NAMES do self.buckets[name] = {values = {}, cursor = 1, calls = 0, total = 0, last = 0} end
	return self
end
function Timings.reset(self: Timings)
	self.started = os.clock()
	for _, b in self.buckets do table.clear(b.values); b.cursor, b.calls, b.total, b.last = 1, 0, 0, 0 end
end
function Timings.begin(self: Timings): number return if self.enabled then os.clock() else 0 end
function Timings.finish(self: Timings, name: string, started: number)
	if not self.enabled then return end
	local ms = (os.clock() - started) * 1000
	local b = self.buckets[name]
	b.calls += 1; b.total += ms; b.last = ms
	b.values[b.cursor] = ms; b.cursor = b.cursor % 1200 + 1
end
function Timings.metrics(self: Timings): {[string]: number}
	local out = {timingEnabled = if self.enabled then 1 else 0, timingElapsedSeconds = os.clock() - self.started}
	for _, name in NAMES do
		local b = self.buckets[name]
		local sorted = table.clone(b.values); table.sort(sorted)
		local prefix = "timing_" .. name .. "_"
		out[prefix .. "calls"], out[prefix .. "totalMs"], out[prefix .. "lastMs"] = b.calls, b.total, b.last
		out[prefix .. "meanMs"] = if b.calls > 0 then b.total / b.calls else 0
		out[prefix .. "p50Ms"] = sorted[math.max(1, math.ceil(#sorted * .5))] or 0
		out[prefix .. "p95Ms"] = sorted[math.max(1, math.ceil(#sorted * .95))] or 0
		out[prefix .. "maxMs"] = sorted[#sorted] or 0
	end
	return out
end
return Timings
