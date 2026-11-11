--!strict
return function(t)
	local fs,luau=require('@lune/fs'),require('@lune/luau')
	local run=luau.load(fs.readFile('tests/OpenFrontWideZoomHarness.luau'))()
	t.test('late empire zoom frame cost and GUI count stay within cba537a',function()
		local baseline,current=run('cba537a',120),run(nil,120)
		for _,mode in {'wide','close'} do
			local a,b=baseline.windows[mode],current.windows[mode]
			t.ok(b.peakGui<=a.peakGui,`{mode} GUI peak {b.peakGui} exceeds cba537a {a.peakGui}`)
			t.ok(b.frame.mean<=a.frame.mean*1.25+1,`{mode} mean frame regressed: {b.frame.mean} vs {a.frame.mean}`)
			t.ok(b.frame.p95<=a.frame.p95*1.3+2,`{mode} p95 frame regressed: {b.frame.p95} vs {a.frame.p95}`)
		end
	end)
end
