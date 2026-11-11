--!strict
-- Property-write and CPU proxy. Indexed child lookup avoids heap-size mock
-- amplification; native layout, texture filtering and GPU work are excluded.
local fs,luau,process=require('@lune/fs'),require('@lune/luau'),require('@lune/process')
return function(ref: string?, fullBaseline: boolean?): any
	local originals={}
	local names={'SceneOverlay','EffectOverlay','FxState','CoastOverlay','CoastRaster','FalloutMasks','DefenseRanges','StructureAtlas','DeferredDirty'}
	if fullBaseline then for _,name in {'EditableRenderer','RasterCore','RenderPolicy','MapInput'} do table.insert(names,name) end end
	if ref then for _,name in names do
		local r=process.exec('git',{'show',ref..':src/client/Map/OpenFront/'..name..'.luau'})
		assert(r.ok,r.stderr); originals[name]=r.stdout
	end end
	local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
	source=source:gsub('local o: any = {ClassName=class','local values: any = {ClassName=class')
	source=source:gsub('o.GetPropertyChangedSignal=function',[[local o: any
o=setmetatable({}, {__index=values,__newindex=function(_,key,value)
	if type(value)~='function' then
		env.writes=env.writes or {}; env.writes[key]=(env.writes[key] or 0)+1
		if values[key]~=value then
			env.changedWrites=env.changedWrites or {}; env.changedWrites[key]=(env.changedWrites[key] or 0)+1
			if env.trackGui then
				local parent=o
				while parent and parent.ClassName~='ScreenGui' do parent=parent.Parent end
				if parent then env.dirtyGuis[parent]=true end
			end
		end
	end
	if key=='Parent' then
		env.children=env.children or {}
		if values.Parent and env.children[values.Parent] then env.children[values.Parent][o]=nil end
		if value then env.children[value]=env.children[value] or {}; env.children[value][o]=true end
	end
	values[key]=value
end})
o.GetPropertyChangedSignal=function]])
	source=source:gsub('for _, child in env.objects do if child.Parent==o and child.Name==key and not child.destroyed then return child end end',
		'for child in (env.children or {})[o] or {} do if child.Name==key and not child.destroyed then return child end end')
	source=source:gsub('for _, child in env.objects do if child.Parent==o then child:Destroy%(%) end end',
		'for child in table.clone((env.children or {})[o] or {}) do child:Destroy() end')
	source=source:gsub('o.destroyed=true; o.Destroying:Fire%(%)','o.destroyed=true; o.Destroying:Fire(); o.Parent=nil',1)
	source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then',
		'node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
	source=source:gsub('return Harness.require%(node%) end','if not originals[node.Name] then return Harness.require(node) end end',1)
	source=source:gsub('fs.readFile%(node.path%)','(originals[node.Name] or fs.readFile(node.path))')
	source=source:gsub('env.Renderer,env.Scene,env.Effects=', 'env.Core=load(root.RasterCore)\n\tenv.Renderer,env.Scene,env.Effects=')
	return luau.load(source,{environment={originals=originals},injectGlobals=true})()()
end
