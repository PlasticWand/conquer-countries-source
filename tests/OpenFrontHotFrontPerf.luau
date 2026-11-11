--!strict
local fs,luau,serde,process=require('@lune/fs'),require('@lune/luau'),require('@lune/serde'),require('@lune/process')
local make=luau.load(fs.readFile('tests/OpenFrontHotFrontHarness.luau'))()
local before=process.args[1]=='before'
for _,budget in {64,256,1024} do
	local e=make(before);local first=nil;local previous=0;local maxGap=0;local count=0
	local started=os.clock()
	for frame=1,600 do
		e.now+=1/60
		if (frame-1)%6==0 then e.change(if math.floor((frame-1)/6)%2==0 then 1 else 2) end
		e.Core.step(e.core,1e9,budget)
		if #e.sink.writes>count then
			first=first or frame;maxGap=math.max(maxGap,frame-previous);previous=frame;count=#e.sink.writes
		end
	end
	maxGap=math.max(maxGap,600-previous)
	print(serde.encode('json',{before=before,pixelBudget=budget,frames=600,changeEveryFrames=6,firstUploadFrame=first,
		maxGapFrames=maxGap,uploads=count,wallMs=(os.clock()-started)*1000,metrics=e.Core.metrics(e.core)}))
	e.Core.destroy(e.core)
end
-- A full-fit camera can see a large backlog on the same image as your front.
-- Compare image pixels, not an assumption that any partial write completed a block.
do
	local e=make(before,1024,256);e.change(2)
	while e.core.pending>0 do e.Core.step(e.core,1e9,1e9) end
	local refs={}
	for key=0,171 do
		local bx,by=key%32*32,math.floor(key/32)*32
		for y=by,by+31 do for x=bx,bx+31 do local tile=y*1024+x;buffer.writeu16(e.states,tile*2,3);table.insert(refs,tile) end end
	end
	local tile=248*1024+1016;local original=e.sink.pixel(1016,248)
	buffer.writeu16(e.states,tile*2,1);table.insert(refs,tile);e.Core.applyTileStates(e.core,e.states,refs)
	local pending=e.core.pending;local first=nil;local frames=0
	repeat
		frames+=1;e.now+=1/60;e.Core.step(e.core,1e9,4096)
		if not first and e.sink.pixel(1016,248)~=original then first=frames end
	until e.core.pending==0 or frames==600
	print(serde.encode('json',{before=before,case='ownBehindBacklog',initialPending=pending,pixelBudget=4096,
		ownFirstPixelFrame=first,drainFrames=frames,metrics=e.Core.metrics(e.core)}))
	e.Core.destroy(e.core)
end
do
	local e=make(before)
	local core=e.Core.new(buffer.create(2000*1000),2000,1000,{write=function() end,destroy=function() end})
	print(serde.encode('json',{before=before,case='worldBufferAccounting',metrics=e.Core.metrics(core)}))
	e.Core.destroy(core);e.Core.destroy(e.core)
end
