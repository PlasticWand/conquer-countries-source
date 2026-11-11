--!strict
-- Screen geometry/native-property regressions; no native layout or device claim.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Placement=H.require(root.LabelPlacement)
	local make=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local function setup(split)
		local e=make(); e.policy.splitMapGuis=split
		local parent=e.instance('Frame');parent.AbsoluteSize=rb.Vector2.new(1920,1080);parent.AbsolutePosition=rb.Vector2.new(27,39)
		local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(parent,terrain,64,64,{autoStep=false})
		local s=e.client();s.startTick=0;s.names={[1]={x=20,y=20,size=300},[2]={x=40,y=30,size=100}}
		s.players[1].userId=1642763318;s.players[1].flag='us';s.players[1].troops=125000
		r.flagArt=luau.load(fs.readFile('src/client/Ui/FlagArt.luau'))()
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}});r:attachState(s)
		local c=table.clone(r.camera);c.scale=12;c.offsetX=-49;c.offsetY=-25;r:setCamera(c)
		for _=1,6 do e.now+=.11;r:step(1e9,1e9) end
		return e,r,s,parent
	end
	t.test('HUD rectangles hide complete nation ink, copy caller data and restore after rebuild without losing anchors',function()
		for _,split in {false,true} do
			local e,r,s=setup(split)
			local rect=r:playerNameScreenRect(2);t.ok(rect);t.ok(rect.w>0 and rect.h>0)
			local view=r.scene.nameViews[2];local sx,sy=view.sx,view.sy
			local supplied=table.clone(rect);r:setLabelOccluders({supplied});supplied.x+=10000
			t.eq(r.labelOccluders[1].x,rect.x);t.eq(view.sourceVisible,true);t.eq(view.root.Visible,false)
			t.eq(r:playerNameScreenRect(2),nil);t.eq(r:playerNameScreenPosition(2),nil)
			t.eq(view.sx,sx);t.eq(view.sy,sy)
			s.players[2].name='Changed behind HUD';s.StatsChanged:Fire();r:step(1e9,1e9)
			t.eq(view.name.Text,'Changed behind HUD');t.eq(view.root.Visible,false)
			r:setLabelOccluders({});t.eq(view.root.Visible,true);t.ok(r:playerNameScreenRect(2))
			t.errors(function() r:setLabelOccluders({{x=0/0,y=0,w=1,h=1}}) end)
			r:destroy()
		end
	end)
	t.test('own label moves at most 96 screen pixels, bounds and toast anchor follow, fully covered labels hide',function()
		local e,r=setup(false);local rect=r:playerNameScreenRect(1)
		local x,y=r:playerNameScreenPosition(1)
		local strip={x=rect.x,y=rect.y+rect.h-8,w=rect.w,h=8}
		r:setLabelOccluders({strip})
		local moved=r:playerNameScreenRect(1);t.ok(moved);t.ok(not Placement.intersects(moved,strip,6))
		local mx,my=r:playerNameScreenPosition(1);t.ok(math.abs(mx-x)+math.abs(my-y)<=96);t.ok(mx~=x or my~=y)
		t.near(moved.x-rect.x,mx-x,1e-5);t.near(moved.y-rect.y,my-y,1e-5)
		r:setLabelOccluders({{x=27,y=39,w=1920,h=1080}});t.eq(r:playerNameScreenRect(1),nil)
		r:setLabelOccluders({});local rx,ry=r:playerNameScreenPosition(1);t.near(rx,x,1e-6);t.near(ry,y,1e-6)
		r:destroy()
	end)
	t.test('build price avoids full flag head name troop bounds on creation and camera callbacks in both GUI modes',function()
		for _,split in {false,true} do
			local e,r=setup(split)
			r.scene:setBuildPreview({type='City',ghostType='City',tileX=19.5,tileY=19.5,cost=125000,showCost=true,
				canAfford=true,canBuild=true,canUpgrade=false,ghostRailPaths={},overlappingRailroads={}})
			r:step(1e9,1e9)
			local function check()
				local cost=r.scene.ghostCost;t.ok(cost.Visible,'room exists beside the nation label')
				local box={x=cost.Position.X.Offset+r.camera.left,y=cost.Position.Y.Offset+r.camera.top,w=cost.Size.X.Offset,h=cost.Size.Y.Offset}
				for id in r.scene.nameViews do local name=r:playerNameScreenRect(id);if name then t.ok(not Placement.intersects(box,name,6),'price overlaps ink') end end
			end
			check()
			local c=table.clone(r.camera);c.offsetX-=3;c.scale=14;r:setCamera(c);check()
			r:setLabelOccluders({{x=c.left,y=c.top,w=c.viewportWidth,h=c.viewportHeight}});r:step(1e9,1e9)
			t.eq(r.scene.ghostCost.Visible,false,'no clear position must hide the price')
			r:destroy()
		end
	end)
end
