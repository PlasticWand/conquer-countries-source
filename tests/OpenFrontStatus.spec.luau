--!strict
return function(t)
	local fs,luau,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/serde')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Status,Atlas=H.require(root.PlayerStatus),H.require(root.StatusAtlas)
	local Config=H.require(H.shared().OpenFront.EngineConfig)
	local config=Config.new({},false)
	local fixture=serde.decode('json',fs.readFile('tests/fixtures/OpenFrontStatus.json'))
	t.test('confirmed status flags match 8 original TypeScript cases',function()
		for _,c in fixture.cases do
			local model=Status.new(); model:events(c.events,c.tick)
			local units,tiles={},buffer.create(128)
			for _,u in c.units or {} do units[u.id]={type=u.unitType,owner=u.ownerID,active=u.isActive,targetTile=u.targetTile} end
			for _,p in c.owners or {} do buffer.writeu16(tiles,p[1]*2,p[2]) end
			local actual=model:compute(c.roster,units,tiles,c.you,c.diplomacy,c.tick,config)
			for _,p in c.expected do for key,value in p.flags do
				t.eq(actual[p.id][key],value,`{c.name}: {p.id}.{key}`)
			end end
		end
	end)
	t.test('emoji visibility, newest-first stable ties and expiration use confirmed ticks',function()
		local m=Status.new()
		local roster={{smallID=1,alive=true,tiles=10},{smallID=2,alive=true,tiles=20}}
		local dip={alliances={},incoming={},outgoing={}}
		m:events({{type='Emoji',emoji={senderID=2,recipientID='AllPlayers',message='😀',createdAt=2}},
			{type='Emoji',emoji={senderID=1,recipientID=2,message='😊',createdAt=3}},
			{type='Emoji',emoji={senderID=2,recipientID=3,message='😡',createdAt=5}},
			{type='Emoji',emoji={senderID=2,recipientID=1,message='🤝',createdAt=6}},
			{type='Emoji',emoji={senderID=2,recipientID='AllPlayers',message='👋',createdAt=6}}},10)
		local function compute(tick) return m:compute(roster,{},buffer.create(0),1,dip,tick,config) end
		t.eq(compute(10)[2].emoji,'🤝'); t.eq(compute(10)[1].emoji,nil,'sender echo to another recipient stays private')
		t.eq(compute(55)[2].emoji,'🤝'); t.eq(compute(56)[2].emoji,nil); t.eq(next(m.emojis),nil)
		m:events({{type='Emoji',emoji={senderID=2,recipientID='AllPlayers',message='🫴',createdAt=60}}},60)
		roster[2].alive=false; t.eq(compute(60)[2],nil)
		m:clear(); t.eq(next(m.emojis),nil)
	end)
	t.test('targets follow direct friendship changes and expire at the source duration',function()
		local m=Status.new()
		local me,friend={smallID=1,alive=true,tiles=10,allies={2}},{smallID=2,alive=true,tiles=20,allies={1}}
		local roster={me,friend,{smallID=3,alive=true,tiles=30}}
		m:events({{type='TargetPlayer',playerID=2,targetID=3}},10)
		local function targeted(tick) return m:compute(roster,{},buffer.create(0),1,{},tick,config)[3].target end
		t.eq(targeted(10),true)
		me.allies={}; t.eq(targeted(20),false)
		me.team,friend.team='Blue','Blue'; t.eq(targeted(20),true)
		me.team=nil; t.eq(targeted(20),false)
		me.allies={2}; t.eq(targeted(109),true); t.eq(targeted(110),false); t.eq(next(m.targets),nil)
	end)
	t.test('status row order, combined emoji centering and expiry flash match shader rules',function()
		local icons=Status.icons({crown=true,traitor=true,disconnected=true,alliance=true,allianceReq=true,target=true,embargo=true,nukeActive=true,nukeTargetsMe=false})
		for i,value in {0,1,2,3,4,5,6,8} do t.eq(icons[i],value) end
		local layout=Status.layout(1,2,3)
		t.near(layout.size,79.2,1e-10); t.near(layout.y,-100.8,1e-10)
		t.near(layout.x+layout.step+layout.size/2,0,1e-10,'middle item is centered')
		t.eq(Status.flash(0,150,1),1); t.eq(Status.flash(151,150,1),1)
		t.near(Status.flash(150,150,.25),.3,1e-9,'traitor two-Hz trough')
	end)
	t.test('native-codec atlas matches open-art samples, validates size and does not substitute unknown emoji',function()
		local art=serde.decode('json',fs.readFile('tests/fixtures/OpenFrontStatusArt.json'))
		local encoding=luau.load(fs.readFile('tests/OpenFrontEncodingHarness.luau'))()
		local pixels=Atlas.rgba(encoding,'zstd'); t.eq(buffer.len(pixels),art.rgbaBytes)
		t.eq(serde.hash('sha256',buffer.tostring(pixels)),art.rgbaSha256)
		local wrong=table.clone(encoding); wrong.GetDecompressedBufferSize=function() return 1 end
		t.errors(function() Atlas.rgba(wrong,'zstd') end)
		for _,sample in art.samples do t.eq(buffer.readu32(pixels,(sample[2]*640+sample[1])*4),sample[3]) end
		t.eq(Atlas.emojis['🫴'],22); t.eq(Atlas.emojis['🤦‍♂️'],24); t.eq(Atlas.emojis['⏳'],nil)
	end)
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local function setup():any
		local e=native(); local s=e.client(); s.startTick=0
		s.players[1].tiles,s.players[2].tiles=10,20
		s.players[1].allies={2}; s.players[2].embargoes={1}
		s.players[2].traitor,s.players[2].disconnected=true,true
		s.players[2].traitorUntil=100
		s.names={[1]={x=20,y=20,size=30},[2]={x=30,y=30,size=30}}
		s.diplomacy={alliances={{id=1,other=2,createdAt=0,expiresAt=1500}},incoming={{requestor=2,createdAt=0}},outgoing={}}
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
		r:attachState(s)
		s.DiplomacyEvents:Fire({{type='Emoji',emoji={senderID=2,recipientID=1,message='🫴',createdAt=0}},
			{type='TargetPlayer',playerID=1,targetID=2}})
		local camera=table.clone(r.camera); camera.scale,camera.offsetX,camera.offsetY=1.8,0,0
		r:setCamera(camera)
		return e,s,r
	end
	t.test('ClientState signals render packed status/emoji art, alliance drain and target cull boost',function()
		local e,s,r=setup(); r:step(1e9,1e9)
		local uploaded=false
		for _=1,3000 do if r:step(1e9,1e9).atlasUpload then uploaded=true; break end end
		t.eq(uploaded,true); t.ok(r.scene.nameStatus.images<=25)
		local view=r.scene.nameViews[2]
		t.eq(r.scene.playerStatus:compute(r.scene.roster,r.scene.units,r.core.tileState,s.you,s.diplomacy,0,config)[2].traitorRemainingTicks,100)
		t.eq(#view.statusIcons,7); t.eq(view.statusEmoji.Visible,true)
		t.eq(view.statusEmoji.ImageRectOffset.X,128); t.eq(view.statusEmoji.ImageRectOffset.Y,192)
		t.eq(view.statusIcons[4].base.ImageRectOffset.X,576,'alliance faded cell')
		t.eq(view.statusIcons[4].fill.Visible,true)
		t.eq(view.statusIcons[4].fill.ImageRectOffset.X,192,'colored alliance cell')
		local decorations=r.scene.nameStatus
		t.eq(#decorations.animations,1); t.eq(decorations.animations[1].remaining,100,'confirmed traitor expiry drives flash')
		decorations:step(.25)
		t.near(view.statusIcons[2].base.ImageTransparency,1-Status.flash(100,150,.25),1e-9)
		t.near(view.statusIcons[4].base.Size.Y.Offset+view.statusIcons[4].fill.Size.Y.Offset,
			view.statusIcons[4].base.Size.X.Offset,1e-9,'drain crops partition the icon without double blending')
		local dense={}
		for i=1,20 do
			local parent=e.instance('Frame'); parent.Parent=r.root; dense[i]={root=parent}
		end
		local data={crown=true,traitor=true,disconnected=true,traitorRemainingTicks=0,allianceFraction=0,allianceRemainingTicks=0}
		local before=decorations.images
		decorations:beginFrame(0)
		for _,v in dense do decorations:draw(v,data,1,2,96,300,1,config,0) end
		t.eq(decorations.images,before); t.eq(decorations.pending,true,'unit burst keeps its shared creation budget')
		for _=1,4 do
			local previous=decorations.images; decorations:beginFrame(25)
			for _,v in dense do decorations:draw(v,data,1,2,96,300,1,config,0) end
			t.ok(decorations.images-previous<=25)
		end
		t.eq(decorations.images-before,60,'all deferred icons eventually render')
		r.scene:setNameAnchors({[1]={x=20,y=20,size=30},[2]={x=30,y=30,size=1}})
		r.scene.nameTransitions={}; local camera=table.clone(r.camera); camera.scale=.2
		r:setCamera(camera); r:step(1e9,1e9); t.eq(view.root.Visible,true,'targeted name survives cull')
		s.tick=100; s.TickApplied:Fire(100); r.scene:setCamera(); r:step(1e9,1e9)
		t.eq(view.root.Visible,false,'expired target restores source cull')
		s.Snapshot:Fire(); t.eq(next(r.scene.playerStatus.emojis),nil); t.eq(next(r.scene.playerStatus.targets),nil)
		local atlas=r.scene.nameStatus.atlas; r:destroy(); t.eq(atlas.destroyed,true)
		local objects=#e.objects; s.DiplomacyEvents:Fire({}); s.DiplomacyChanged:Fire(); t.eq(#e.objects,objects)
	end)
	t.test('status atlas allocation failure cleans up the renderer and atlas state',function()
		local e,_,r=setup(); local decorations=r.scene.nameStatus; e.failStatus=true; r:step(1e9,1e9)
		local failed=false
		for _=1,3000 do
			if not pcall(function() r:step(1e9,1e9) end) then failed=true; break end
		end
		t.eq(failed,true); t.eq(r.destroyed,true); t.eq(decorations.atlas,nil); t.eq(decorations.content,nil)
		for _,image in e.images do t.eq(image.destroyed,true) end
	end)
end
