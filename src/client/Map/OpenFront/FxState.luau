--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/passes/fx-pass/{FxSpritePass,FxShockwavePass,FxSettings}.ts; src/client/render/gl/passes/WorldTextPass.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Atlas = require(script.Parent.FxAtlas)
local Defaults = require(script.Parent.RenderDefaults)
local ShipArt = require(script.Parent.ShipArt)
local Fx = {}
Fx.__index = Fx
local radii = {['Atom Bomb'] = 70, ['Mega Nuke'] = 70, ['Hydrogen Bomb'] = 160, ['MIRV Warhead'] = 70, Scattershot = 70}
local structures = {City = true, Port = true, Factory = true, ['Defense Post'] = true, ['SAM Launcher'] = true, ['Missile Silo'] = true, Artillery = true, Airfield = true, Railgun = true, ['Coastal Battery'] = true}

-- Original: seededRandom (mulberry32), including JS Math.imul low 32 bits.
local function imul(a: number, b: number): number
	return bit32.band(bit32.band(a,65535) * bit32.band(b,65535)
		+ bit32.lshift(bit32.rshift(a,16) * bit32.band(b,65535) + bit32.band(a,65535) * bit32.rshift(b,16),16),0xffffffff)
end
function Fx.seededRandom(seed: number): number
	seed = bit32.band(seed + 0x6d2b79f5,0xffffffff)
	local t = imul(bit32.bxor(seed,bit32.rshift(seed,15)),bit32.bor(1,seed))
	t = bit32.bxor(bit32.band(t + imul(bit32.bxor(t,bit32.rshift(t,7)),bit32.bor(61,t)),0xffffffff),t)
	return bit32.bxor(t,bit32.rshift(t,14)) / 4294967296
end
function Fx.new(width: number, options:any?): any
	return setmetatable({width = width, sprites = {}, shockwaves = {}, popups = {}, dead = {}, impacts={},options=options,smokeCount=0}, Fx)
end

-- Original: FxSpritePass.pushFx / pushDebris. Effect times are milliseconds.
local function sprite(self: any, x: number, y: number, kind: number, now: number, debris: boolean?):any?
	if self.options and kind>=6 and kind<=9 then
		if self.smokeCount>=self.options.spriteCap then return nil end
		self.smokeCount+=1
	end
	local cfg = Atlas.rows[kind + 1]
	local e={x = x,y = y,kind = kind,start = now,
		lifetime = if debris then 6000 else cfg[4] * cfg[5], fadeIn = if debris then .1 else 0, fadeOut = if debris then .8 else 1}
	table.insert(self.sprites,e)
	return e
end

local function aftermath(self:any,x:number,y:number,now:number,lifetime:number,spread:number,fallout:boolean)
	for i,kind in {6,8,7,9} do
		local angle=i*math.pi/2
		local e=sprite(self,x+math.floor(math.cos(angle)*spread),y+math.floor(math.sin(angle)*spread),kind,now,true)
		if e then e.lifetime=lifetime; e.fadeIn=.05; e.fadeOut=.65; e.scale=if fallout then 1.2 else 1.8; e.fallout=fallout end
	end
end

-- Original: FxPass.spawnUnit / FxSpritePass.spawnFxForUnit / spawnNukeSprites.
-- Removal alone is deliberately insufficient: reachedTarget from the final
-- confirmed inactive record distinguishes impact from SAM interception.
function Fx.deadUnit(self: any, unit: any, now: number, heading: number?)
	local kind, tile = unit.type, unit.tile
	local x, y = tile % self.width, math.floor(tile / self.width)
	local radius = radii[kind]
	if radius then
		if unit.reachedTarget then
			sprite(self,x,y,0,now)
			local debrisIndex = 0
			for _, plan in {{6,1,1/25},{7,1,1/28},{8,.9,1/70},{9,.9,1/70}} do
				for _ = 1, math.floor(radius * plan[3]) do
					local seed = tile * 997 + debrisIndex; debrisIndex += 1
					local angle = Fx.seededRandom(seed) * math.pi * 2
					local distance = Fx.seededRandom(seed + 0x10000) * radius * plan[2] / 2
					sprite(self,x + math.floor(math.cos(angle)*distance),y + math.floor(math.sin(angle)*distance),plan[1],now,true)
				end
			end
			if self.options then
				if #self.impacts>=self.options.maskCap then table.remove(self.impacts,1) end
				table.insert(self.impacts,{tile=tile,kind=kind,start=now})
				aftermath(self,x,y,now,self.options.falloutLifetimeMs,radius*.1,true)
			end
		else sprite(self,x,y,1,now) end
		-- FxShockwavePass starts the shockwave on receipt, independent of sprite age.
		table.insert(self.shockwaves,{x = x,y = y,start = now,
			lifetime = if unit.reachedTarget then 1500 else 800,
			radius = if unit.reachedTarget then radius * 1.5 else 40,
			sam = not unit.reachedTarget})
	elseif kind == 'Warship' then
		sprite(self,x,y,3,now)
		local e=sprite(self,x,y,5,now)
		if e then e.shipOwner=unit.owner; e.shipHeading=ShipArt.heading(tile,unit.lastTile,self.width,heading) end
		if self.options and self.options.warshipSmoke then
			local smoke=sprite(self,x,y,7,now,true)
			if smoke then smoke.lifetime=1260; smoke.fadeIn=.05; smoke.fadeOut=.5 end
		end
	elseif (kind == 'Shell' and unit.reachedTarget) or (kind == 'Train' and not unit.reachedTarget) then sprite(self,x,y,4,now)
	elseif structures[kind] then
		local e=sprite(self,x,y,2,now)
		if kind=='Defense Post' and self.options then
			if e then e.scale=self.options.defenseExplosionScale end
			aftermath(self,x,y,now,self.options.defenseSmokeLifetimeMs,2,false)
		end
	end
end

-- Source GameView.buildFrameEvents consumes inactive updates, never snapshots.
function Fx.unitUpdates(self: any, updates: {any}, removed: {number}, now: number, headings: {[number]: number}?)
	for _, u in updates do
		if u.active == false then
			if not self.dead[u.id] then self:deadUnit(u,now,if headings then headings[u.id] else nil); self.dead[u.id] = true end
		else self.dead[u.id] = nil end
	end
	for _, id in removed do self.dead[id] = nil end
end

-- Original: WorldTextPass.formatGold / applyBonusEvents. Gold is not troops/10.
-- JS toFixed(1) rounds binary64 ties upward. Split its exact significand
-- before multiplying by 10; string.format alone uses ties-to-even instead.
local function fixed1(value: number): string
	local mantissa,exponent=math.frexp(value)
	local sig=mantissa*2^53
	local hi,lo=math.floor(sig/2^26)*5,(sig%2^26)*5
	local shift=52-exponent
	local divisor=2^shift
	local q,rem
	if shift>=26 then
		local highDivisor=2^(shift-26)
		q=math.floor(hi/highDivisor)
		rem=(hi%highDivisor)*2^26+lo
		q+=math.floor(rem/divisor); rem%=divisor
	else
		q=hi*2^(26-shift)+math.floor(lo/divisor); rem=lo%divisor
	end
	if rem>=divisor/2 then q+=1 end
	return string.format('%.0f.%d',math.floor(q/10),q%10)
end
function Fx.formatGold(gold: number): string
	if gold >= 1000000 then return fixed1(gold / 1000000)..'M' end
	if gold >= 1000 then return fixed1(gold / 1000)..'K' end
	return tostring(gold)
end
function Fx.bonuses(self: any, events: {any}, now: number)
	for _, e in events do
		if e.gold ~= 0 then
			table.insert(self.popups,{x = e.tile % self.width,y = math.floor(e.tile / self.width) - 3,
				text = (if e.gold >= 0 then '+ ' else '- ') .. Fx.formatGold(math.abs(e.gold)),start = now,lifetime = 1500})
		end
	end
end

-- Original: FxSpritePass.applyConquestEvents / WorldTextPass.applyConquestEvents.
-- The adapter resolves the conquered player's confirmed name location and
-- filters to our own conquests, as GameView.buildFrameEvents does.
function Fx.conquests(self: any, events: {any}, now: number)
	-- Bruno's staged presentation, 2026-11-08. The default pure path below
	-- retains the source oracle; the live overlay always requests staging.
	if self.options and self.options.stagedConquests then self:stagedConquests(events,now); return end
	local settings = Defaults.fx
	for _, e in events do
		local age = (e.tickAge or 0) * 100
		if age < settings.conquestLifetimeMs then
			table.insert(self.sprites,{x=e.x,y=e.y,kind=11,start=now-age,
				lifetime=settings.conquestLifetimeMs,fadeIn=settings.conquestFadeIn,fadeOut=settings.conquestFadeOut})
		end
		if age < 2500 then
			table.insert(self.popups,{x=e.x,y=e.y+8,text='+ '..Fx.formatGold(e.gold),
				start=now-age,lifetime=2500,riseSpeed=0,conquest=true})
		end
	end
end

function Fx.clearConquests(self:any)
	for _,pool in {self.sprites,self.popups} do
		for i=#pool,1,-1 do if pool[i].conquest or pool[i].conquestMark then table.remove(pool,i) end end
	end
	self.conquestMoment=nil
end

-- One bounded moment: existing atlas mark, neutral stencil stamp, then gold.
-- Batches within 150ms merge before the stamp; later moments replace the old
-- cosmetic sequence. Confirmed gold/state are never delayed or accumulated here.
function Fx.stagedConquests(self:any,events:{any},now:number)
	local first,age,gold,count=nil,math.huge,0,0
	for _,e in events do
		local elapsed=math.max(0,(e.tickAge or 0)*100)
		if elapsed<2500 then
			if not first then first=e end
			age=math.min(age,elapsed); gold+=e.gold; count+=1
		end
	end
	if not first then return end
	local moment=self.conquestMoment
	if moment and now-moment.received<=150 and now-moment.start<180 then
		moment.gold+=gold; moment.count+=count
		moment.popup.text='+ '..Fx.formatGold(moment.gold)
		return
	end
	self:clearConquests()
	local start=now-age
	local mark={x=first.x,y=first.y,kind=11,start=start,lifetime=900,fadeIn=0,fadeOut=.6,conquestMark=true}
	if age<mark.lifetime then table.insert(self.sprites,mark) end
	local popup={x=first.x,y=first.y+8,text='+ '..Fx.formatGold(gold),start=start+650,lifetime=1850,riseSpeed=0,conquest=true}
	table.insert(self.popups,popup)
	self.conquestMoment={x=first.x,y=first.y,start=start,received=now,gold=gold,count=count,popup=popup}
end

-- Original: FxSpritePass.rebuildInstances alpha/frame rules and WorldTextPass.tick.
function Fx.sampleSprite(effect: any, now: number): (number, number)
	local cfg = Atlas.rows[effect.kind + 1]
	local elapsed = math.max(0,now - effect.start)
	local frame = if cfg[6] then math.floor((elapsed % (cfg[4]*cfg[5])) / cfg[5]) else math.min(math.floor(elapsed/cfg[5]),cfg[4]-1)
	local t, alpha = elapsed / effect.lifetime, 255
	if t < effect.fadeIn then alpha = math.floor(t/effect.fadeIn*255)
	elseif t > effect.fadeOut then alpha = math.floor((1-t)/(1-effect.fadeOut)*255) end
	return frame, math.clamp(alpha,0,255) / 255
end
function Fx.tick(self: any, now: number)
	if self.conquestMoment and now-self.conquestMoment.start>=2500 then self.conquestMoment=nil end
	for _, pool in {self.sprites,self.shockwaves,self.popups} do
		for i = #pool, 1, -1 do
			local e = pool[i]
			if now-e.start >= e.lifetime then
				if pool==self.sprites and self.options and e.kind>=6 and e.kind<=9 then self.smokeCount-=1 end
				pool[i] = pool[#pool]; table.remove(pool)
			end
		end
	end
end
function Fx.clear(self: any)
	table.clear(self.sprites); table.clear(self.shockwaves); table.clear(self.popups); table.clear(self.dead); table.clear(self.impacts)
	self.smokeCount=0
	self.conquestMoment=nil
end
return Fx
