-- Claude: run in the Client data model at World/public tick ~2000.
-- Inclusive nested spans; do not add their totals together. Wrappers add a
-- small allocation per call. This is a diagnostic, not a shipping patch.
local player = game:GetService('Players').LocalPlayer
local modules = player.PlayerScripts.Client.Map.OpenFront
local probe = player:FindFirstChild('OpenFrontDebugClient')
local before = if probe then probe:Invoke() else nil
local definitions = {
 {'EditableRenderer','step'}, {'RasterCore','step'}, {'SceneOverlay','step'},
 {'EffectOverlay','step'}, {'TrailManager','update'},
 {'PlayerStatus','compute'}, {'NameStatusOverlay','step'},
}
local saved, measurements = {}, {}
for _, definition in definitions do
 local module = require(modules[definition[1]])
 local key = definition[2]
 local original = module[key]
 local name = definition[1]..'.'..key
 local times = {}; measurements[name] = times
 table.insert(saved, {module=module,key=key,original=original})
 module[key] = function(...)
  local started = os.clock()
  local result = table.pack(original(...))
  table.insert(times, (os.clock()-started)*1000)
  return table.unpack(result,1,result.n)
 end
end
local frames = {}
local connection = game:GetService('RunService').RenderStepped:Connect(function(dt)
 table.insert(frames,dt*1000)
end)
local ok, err = pcall(function()task.wait(20)end)
connection:Disconnect()
for _, entry in saved do entry.module[entry.key] = entry.original end
if not ok then error(err)end
measurements.clientFrameMs=frames
local result = {scenario='World/public, no camera input during capture',before=before,after=if probe then probe:Invoke() else nil,spans={}}
for name,times in measurements do
 table.sort(times)
 local sum=0;for _,ms in times do sum+=ms end
 result.spans[name]={calls=#times,cpuMs=sum,p50=times[math.max(1,math.ceil(#times*.5))],p95=times[math.max(1,math.ceil(#times*.95))],max=times[#times]}
end
return result
