--!strict
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Labels,Policy=H.require(root.LabelMath),H.require(root.RenderPolicy)
	local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
	source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then','node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
	local make=luau.load(source)()
	t.test('default name cap limits the em to 8 percent and uniformly scales flags, troops and status geometry',function()
		t.eq(Policy.capNameScreenHeight,true);t.eq(Policy.nameMaxViewportHeight,.08)
		local raw=Labels.size(300,2*8/844,false,false,false)
		for _,height in {375,390,829} do
			local limited=Labels.limitHeight(raw,8,height,.08)
			local p=Labels.project(limited,8);local original=Labels.project(raw,8)
			t.near(p.namePixels,height*.08,1e-9)
			t.near(p.troopPixels/p.namePixels,original.troopPixels/original.namePixels,1e-12)
			t.near(p.lineOffset/p.namePixels,original.lineOffset/original.namePixels,1e-12)
			t.eq(limited.visible,raw.visible)
		end
		t.eq(Labels.limitHeight(raw,8,390,nil),raw,'flag off retains source sizing')
		local small=Labels.size(12,2*.4/844,false,false,false)
		local larger=Labels.size(20,2*.4/844,false,false,false)
		t.eq(Labels.limitHeight(small,.4,390,.08),small)
		t.eq(Labels.limitHeight(larger,.4,390,.08),larger)
		t.ok(Labels.project(larger,.4).namePixels>Labels.project(small,.4).namePixels,'territory growth below the cap was lost')
	end)
	t.test('cap applies on the first zoom/resize frame, preserves growth below the cap and keeps name centers aligned',function()
		local e=make();local s=e.client();s.startTick=0;s.players[1].flag='us';s.players[1].userId=1642763318;s.players[1].tiles=100
		s.names={[1]={x=20,y=20,size=300},[2]={x=40,y=40,size=20}}
		local parent=e.instance('Frame');local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(parent,terrain,64,64,{autoStep=false});r.flagArt=luau.load(fs.readFile('src/client/Ui/FlagArt.luau'))()
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}});r:attachState(s)
		for _=1,4 do e.now+=.11;r:step(1e9,1e9) end
		for _,height in {375,390,829} do for _,zoom in {.4,1.9,4,8,16} do
			local c=table.clone(r.camera);c.scale,c.viewportHeight=zoom,height;r:setCamera(c)
			e.now+=.001;r:step(1e9,1e9)
			local v=r.scene.nameViews[1];local factor=v.scale.Scale*r.scene.worldScale.Scale
			t.ok(v.name.TextSize*factor<=height*.08+.00001,'zoom frame exceeded cap')
			t.near(v.troops.TextSize*factor,v.name.TextSize*factor*.6,1e-5)
			t.near(v.flag.Size.Y.Offset*factor,v.name.TextSize*factor*.78,2*factor)
			t.near(v.head.Size.Y.Offset*factor,v.name.TextSize*factor*1.05,2*factor)
			local content=H.require(root.StatusAtlas).statusContent
			t.near(v.statusIcons[1].base.Size.Y.Offset*factor,v.name.TextSize*factor*.825*64/content,2*factor)
			local center=(v.root.Position.X.Offset+v.name.Size.X.Offset*v.scale.Scale/2)*r.scene.worldScale.Scale
			t.near(center,20*zoom,2*factor+r.scene.worldScale.Scale,'integer GUI offsets moved the name anchor')
		end end
		local v=r.scene.nameViews[1];t.ok(v.statusIcons and v.statusIcons[1].base.Visible,'crown lost while capping')
		local original=e.policy.capNameScreenHeight;e.policy.capNameScreenHeight=false;r.scene:setCamera();e.now+=.001;r:step(1e9,1e9)
		t.ok(v.name.TextSize*v.scale.Scale*r.scene.worldScale.Scale>829*.08,'flag off did not restore source projection')
		e.policy.capNameScreenHeight=original;r:destroy()
	end)
end
