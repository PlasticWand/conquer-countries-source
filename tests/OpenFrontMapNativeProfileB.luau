-- Run in the Client model: World/public, 400 tribes+nations, tick ~2100,
-- no camera input, same viewport. Built-in live-controller timing, no wrappers.
local player=game:GetService('Players').LocalPlayer
local probe=assert(player:FindFirstChild('OpenFrontDebugClient'))
local beforeState,before=probe:Invoke(),probe:Invoke('render')
assert(before.timingEnabled==1,'renderer profiling disabled or stale Play session')
local frames={}
local connection=game:GetService('RunService').RenderStepped:Connect(function(dt) frames[#frames+1]=dt*1000 end)
local ok,err=pcall(function()task.wait(20)end)
connection:Disconnect()
if not ok then error(err)end
local afterState,after=probe:Invoke(),probe:Invoke('render')
local function quantiles(values)
 table.sort(values);local sum=0;for _,v in values do sum+=v end
 return {calls=#values,meanMs=sum/math.max(1,#values),p50Ms=values[math.max(1,math.ceil(#values*.5))],p95Ms=values[math.max(1,math.ceil(#values*.95))],maxMs=values[#values]}
end
local result={beforeState=beforeState,afterState=afterState,clientFrame=quantiles(frames),spans={},metrics=after}
for _,name in {'frame','prepare','raster','scene','units','names','anchors','status','icons','fx','trails'} do
 local p='timing_'..name..'_'
 local calls=after[p..'calls']-before[p..'calls']
 local cpu=after[p..'totalMs']-before[p..'totalMs']
 result.spans[name]={calls=calls,totalMs=cpu,meanMs=cpu/math.max(1,calls),
  rollingP50Ms=after[p..'p50Ms'],rollingP95Ms=after[p..'p95Ms'],rollingMaxMs=after[p..'maxMs']}
end
local all,map=0,0
local gui=player.PlayerGui
local mapRoot=gui:FindFirstChild('OpenFrontMap')
for _,child in gui:GetDescendants()do if child:IsA('GuiObject')then all+=1;if mapRoot and child:IsDescendantOf(mapRoot)then map+=1 end end end
result.playerGuiObjects,result.mapScreenGuiObjects=all,map
-- Span totals are exact deltas for this window. Rolling quantiles cover the
-- last <=1200 INVOCATIONS per span, possibly including older calls. Inclusive
-- nested spans must not be summed. Render CPU excludes native layout/GPU.
return result
