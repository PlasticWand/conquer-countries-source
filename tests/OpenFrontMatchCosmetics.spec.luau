--!strict
-- Real adapters under the property shim: no native font/GPU/phone claim.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local C,Fx,Line=H.require(root.MatchCosmetics),H.require(root.FxState),H.require(root.NameLine)
	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function count(items:any):number local n=0;for _ in items do n+=1 end;return n end
	local function setup(studio:boolean?):any
		local e=native();e.studio=studio==true
		local s=e.client();s.startTick=0
		s.names={[1]={x=20,y=20,size=300},[2]={x=48,y=45,size=30}}
		s.players[1].title='t_warlord';s.players[1].nameStyle='n_gold';s.players[1].conquestFx='x_conquest_gold';s.players[1].blastFx='x_blast_ironroad'
		local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,coasts=false,firstPaint='full'})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
		r:attachState(s)
		for _=1,100 do e.now+=.11;r:step(1e9,1e9) end
		return e,s,r
	end
	local function emit(s:any,event:any)
		s:applyDelta({tick=s.tick+1,tiles=buffer.create(0),events={event}})
	end
	local function public(tick:number):any
		return {type='ConquestCosmeticEvent',conquerorId='other',conqueredId='me',x=20,y=20,tick=tick,tickAge=0,conquestFx='x_conquest_gold'}
	end

	t.test('known human styles only; title screen threshold and em remain bounded',function()
		for id,text in {t_recruit='RECRUIT',t_veteran='VETERAN',t_warlord='WARLORD',t_soldier='SOLDIER'} do
			t.eq(C.title({type='HUMAN',title=id}),text)
			t.eq(C.title({type='BOT',title=id}),nil)
		end
		t.eq(C.title({type='HUMAN',title='arbitrary text'}),nil)
		t.eq(C.goldName({type='HUMAN',nameStyle='n_gold'}),true)
		t.eq(C.goldName({type='NATION',nameStyle='n_gold'}),false)
		t.eq(C.blast('bad'),nil);t.eq(C.conquest(nil),nil)
		t.eq(Line.titleLayout('WARLORD',29.99,1),nil)
		for _,scale in {.25,1,8} do for _,screen in {30,50,160} do
			local title=Line.titleLayout('WARLORD',screen/scale,scale)
			t.ok(title.pixels*scale>=10 and title.pixels*scale<=14)
		end end
	end)
	t.test('gold styles only the name, restores defaults on unequip and follows a takeover roster change',function()
		local _,s,r=setup();local v=r.scene.nameViews[1]
		t.eq(v.name.TextColor3,rb.Color3.new(1,.78,.28));t.eq(v.strokes[1].Color,rb.Color3.new(.10,.075,.045))
		t.ok(v.troops.TextColor3~=v.name.TextColor3);local troops,outline=v.troops.TextColor3,v.strokes[2].Color
		t.eq(v.titleLabel.Text,'WARLORD');t.ok(v.titleShift>0)
		t.ok(r:playerNameScreenRect(1).w<100,'title ink bounds exclude its wide transparent TextLabel box')
		s.players[1].nameStyle=nil;s.players[1].title=nil;s.RosterChanged:Fire({1});r:step(1e9,1e9)
		t.eq(v.name.TextColor3,troops);t.eq(v.strokes[1].Color,outline);t.eq(v.titleShift,0);t.eq(v.titleLabel,nil)
		s.players[1].type='BOT';s.players[1].nameStyle='n_gold';s.players[1].title='t_veteran';s.RosterChanged:Fire({1});r:step(1e9,1e9)
		t.eq(v.goldName,false);t.eq(v.titleLabel,nil)
		s.players[1].type='HUMAN';s.RosterChanged:Fire({1});r:step(1e9,1e9)
		t.eq(v.goldName,true);t.eq(v.titleLabel.Text,'VETERAN');r:destroy()
	end)
	t.test('titles yield to other nation labels, HUD, tiny/source-culled names and recover without moving name anchors',function()
		local _,s,r=setup();local v=r.scene.nameViews[1];local anchor=v.sx
		t.ok(v.titleLabel and v.titleLabel.Visible)
		r.scene.nameViews[2].sourceVisible=true
		r.scene.nameViews[2].sx,r.scene.nameViews[2].sy=v.sx,v.sy
		r.scene.labelLayoutDirty=true;r.scene:layoutLabels()
		t.eq(v.titleLabel,nil);t.eq(v.titleShift,0);t.eq(v.sx,anchor);t.ok(v.root.Visible)
		r.scene.nameViews[2].sourceVisible=false;r.scene.labelLayoutDirty=true;r.scene:layoutLabels();t.ok(v.titleLabel)
		local base=r:playerNameScreenRect(1,true)
		local obstacle={x=base.x,y=base.y+base.h-8,w=base.w,h=30}
		r:setLabelOccluders({obstacle})
		if v.titleLabel and v.root.Visible then
			t.eq(H.require(root.LabelPlacement).intersects(r:playerNameScreenRect(1),obstacle),false,'title yields or follows an already-relocated own label')
		end
		r:setLabelOccluders({});local c=table.clone(r.camera);c.viewportHeight=300;r:setCamera(c);r:step(1e9,1e9)
		t.eq(v.titleLabel,nil,'24px capped name has no title')
		r.scene:setNameAnchors({});r:step(1e9,1e9);t.eq(v.root.Visible,false);t.eq(v.titleLabel,nil)
		r:destroy()
	end)
	t.test('title pool and steady GUI writes stay bounded, and cleanup owns pooled labels',function()
		local e,_,r=setup();local v=r.scene.nameViews[1];local title=v.titleLabel
		local images,objects=#e.images,#e.objects
		e.changedWrites={}
		for _=1,30 do r.scene.labelLayoutDirty=true;r.scene:layoutLabels() end
		t.eq(#e.images,images);t.eq(#e.objects,objects)
		t.eq(e.changedWrites.Parent or 0,0,'stable titles do not reparent every layout')
		t.ok(#r.scene.titles.slots<=8);r:destroy();t.ok(title.destroyed)
	end)
	t.test('every nuke tint preserves exact emission, radii and durations; intercepts and other units stay default',function()
		for _,kind in {'Atom Bomb','Hydrogen Bomb','MIRV Warhead','Mega Nuke','Scattershot'} do
			local base,styled=Fx.new(64),Fx.new(64)
			local u={type=kind,tile=100,reachedTarget=true}
			base:deadUnit(u,100);styled:deadUnit(u,100,nil,'x_blast_ironroad')
			t.eq(#base.sprites,#styled.sprites);t.eq(#base.shockwaves,#styled.shockwaves)
			for i,sprite in base.sprites do
				for key,value in sprite do t.eq(styled.sprites[i][key],value,kind..' '..key) end
				t.eq(styled.sprites[i].tint,C.ironRoad)
			end
			for key,value in base.shockwaves[1] do t.eq(styled.shockwaves[1][key],value) end
			t.eq(styled.shockwaves[1].tint,C.ironRoad)
			local intercepted=Fx.new(64);u.reachedTarget=false;intercepted:deadUnit(u,100,nil,'x_blast_ironroad')
			t.eq(intercepted.sprites[1].tint,nil);t.eq(intercepted.shockwaves[1].tint,nil)
		end
		local fx=Fx.new(64);fx:deadUnit({type='City',tile=0},0,nil,'x_blast_ironroad');t.eq(fx.sprites[1].tint,nil)
	end)
	t.test('many equipped humans share at most eight title labels with bounded crowd checks and no image allocations',function()
		local e,s,r=setup();local images=#e.images
		local template=table.clone(s.players[1]);s.names={};s.rosterOrder={}
		for id=1,16 do
			local p=table.clone(template);p.id='p'..id;p.smallID=id;p.name='X';p.displayName='X';p.title='t_soldier';p.userId=nil
			s.players[id]=p;table.insert(s.rosterOrder,id)
			s.names[id]={x=10+(id-1)%4*14,y=10+math.floor((id-1)/4)*14,size=300}
		end
		e.textWidths={X=.05}
		s.RosterChanged:Fire({});s.NamesChanged:Fire()
		local camera=table.clone(r.camera);camera.viewportWidth,camera.viewportHeight=4000,3000;camera.scale=45;camera.offsetX,camera.offsetY=-32,-32
		r:setCamera(camera)
		for _=1,20 do e.now+=.11;r:step(1e9,1e9) end
		t.eq(#r.scene.titles.slots,8);t.eq(r.scene.titles.visible,8)
		t.ok(r.scene.titles.checks<=8*128);t.eq(#e.images,images)
		r:destroy()
	end)
	t.test('fallout pixels, temporary glow and aftermath receive no blast style; live owner changes resolve once',function()
		local _,s,r=setup();local fx=r.scene.effects.state
		local u={id=99,type='Hydrogen Bomb',owner=1,tile=100,active=false,reachedTarget=true}
		s.UnitsChanged:Fire({u},{99})
		t.eq(fx.sprites[1].tint.g,.32);t.eq(fx.impacts[1].tint,nil)
		for _,e in fx.sprites do if e.fallout then t.eq(e.tint,nil) end end
		-- Ordinary duplicate inactive updates retain the source dead-ID guard.
		fx:clear();u.id=100;s.UnitsChanged:Fire({u},{})
		local n=#fx.sprites;s.UnitsChanged:Fire({u},{});t.eq(#fx.sprites,n)
		fx:clear();u.id=101;u.owner=2;s.UnitsChanged:Fire({u},{});t.eq(fx.sprites[1].tint,nil)
		s.players[2].blastFx='x_blast_ironroad';s.RosterChanged:Fire({2})
		fx:clear();u.id=102;s.UnitsChanged:Fire({u},{});t.eq(fx.sprites[1].tint.g,.32)
		s.players[2].type='BOT';s.RosterChanged:Fire({2})
		fx:clear();u.id=103;s.UnitsChanged:Fire({u},{});t.eq(fx.sprites[1].tint,nil)
		r:destroy()
	end)
	t.test('pooled tinted sprites, rings and popups reset their default colours on reuse',function()
		local _,_,r=setup();local effects=r.scene.effects;local fx=effects.state
		fx:deadUnit({type='Atom Bomb',tile=64*20+20,reachedTarget=true},0,nil,'x_blast_ironroad');effects:step(20)
		t.eq(effects.sprites[1].ImageColor3,rb.Color3.new(1,.32,.12));t.eq(effects.rings[1]:FindFirstChild('Stroke').Color,rb.Color3.new(1,.32,.12))
		fx:clear();fx:deadUnit({type='Atom Bomb',tile=64*20+20,reachedTarget=false},100);effects:step(120)
		t.eq(effects.sprites[1].ImageColor3,rb.Color3.new(1,1,1));t.eq(effects.rings[1]:FindFirstChild('Stroke').Color,rb.Color3.new(1,1,1))
		fx:clear();fx:conquests({{x=20,y=20,gold=5,conquestFx='x_conquest_gold'}},200);effects:step(900)
		t.eq(effects.popups[1].TextColor3,rb.Color3.new(1,.78,.28))
		fx:clear();fx:bonuses({{tile=64*20+20,gold=5}},1000);effects:step(1020)
		t.eq(effects.popups[1].TextColor3,rb.Color3.new(1,1,1));r:destroy()
	end)
	t.test('private gold conquest retains gold value and timing; public observers see only a capped cosmetic mark',function()
		local e,s,r=setup();local fx=r.scene.effects.state
		emit(s,{type='ConquestEvent',conquerorId='me',conqueredId='other',gold=12345,tickAge=0})
		t.eq(fx.conquestMoment.tint.g,.78);t.eq(fx.conquestMoment.gold,12345)
		local popup=fx.conquestMoment.popup;t.eq(popup.start,fx.conquestMoment.start+650)
		local own=public(1);own.conquerorId='me';emit(s,own)
		t.eq(#fx.sprites,1,'winner suppresses its public duplicate')
		local event=public(2);event.gold=999999;emit(s,event);emit(s,event)
		t.eq(#fx.sprites,2);t.eq(#fx.popups,1);t.eq(fx.conquestMoment.gold,12345)
		for i=3,100 do emit(s,public(i)) end
		local marks=0;for _,v in fx.sprites do if v.publicConquest then marks+=1;t.eq(v.tint.g,.78);t.eq(v.gold,nil) end end
		t.eq(marks,4);t.ok(count(fx.publicSeen)<=64)
		local images=#e.images
		r:step(1e9,1e9);t.eq(#e.images,images,'public marks reuse the existing atlas')
		s.Snapshot:Fire();t.eq(#fx.sprites,0);t.eq(next(fx.publicSeen),nil);r:destroy()
	end)
	t.test('public event validation and late age cannot invent default conquests or gold',function()
		local _,s,r=setup();local fx=r.scene.effects.state
		for _,change in {{x=-1},{x=0/0},{conquerorId='unknown'},{conquestFx='unknown'},{tickAge=9},{tick=math.huge}} do
			local e=public(1);for k,v in change do e[k]=v end;emit(s,e)
		end
		t.eq(#fx.sprites,0);t.eq(#fx.popups,0)
		emit(s,public(2));t.eq(#fx.sprites,1);fx:tick(fx.sprites[1].start+900);t.eq(#fx.sprites,0)
		r:destroy();s.DiplomacyEvents:Fire({public(3)});t.eq(#fx.sprites,0)
	end)
	t.test('Studio endpoint is absent live, overrides bots without mutating state, previews allocate no new image, clears on snapshot and teardown',function()
		local _,_,live=setup();t.eq(live.cosmeticsPreview,nil);live:destroy()
		local e,s,r=setup(true);local endpoint=r.cosmeticsPreview;t.ok(endpoint)
		s.players[2].type='BOT';s.RosterChanged:Fire({2})
		endpoint.OnInvoke('set',{player=2,title='t_soldier',nameStyle='n_gold',conquestFx='x_conquest_gold',blastFx='x_blast_ironroad'})
		t.eq(s.players[2].title,nil);t.eq(s.players[2].type,'BOT');t.eq(r.scene.blastStyles[2],'x_blast_ironroad')
		local images=#e.images
		endpoint.OnInvoke('conquest',{player=2});endpoint.OnInvoke('blast',{player=2,tile=0,unit='Scattershot'})
		t.eq(#r.scene.effects.state.impacts,0)
		for _=1,4 do r:step(1e9,1e9) end;t.eq(#e.images,images)
		endpoint.OnInvoke('clear');t.eq(next(r.scene.cosmeticOverrides),nil)
		endpoint.OnInvoke('set',{player=2,title='t_veteran'});s.Snapshot:Fire();t.eq(next(r.scene.cosmeticOverrides),nil)
		endpoint.OnInvoke('set',{player=2,title='t_veteran'});s.Rebound:Fire();t.eq(next(r.scene.cosmeticOverrides),nil)
		r:destroy();t.ok(endpoint.destroyed);t.eq(endpoint.OnInvoke,nil)
	end)
end
