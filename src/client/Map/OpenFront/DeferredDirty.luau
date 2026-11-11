--!strict
-- Ported from RoWorld 2be8efb (src/client/Map/MapSurface.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
-- Cosmetic-only, capped/deduplicated change expansion. Record references remain
-- distinct across A->B->A and requeue, even while an old priority entry survives.
local Dirty = {}
Dirty.__index = Dirty

function Dirty.new(enabled: boolean, cap: number): any
	return setmetatable({enabled=enabled,cap=cap,items={},queue={},ownQueue={},frontQueue={},head=1,tail=0,ownHead=1,ownTail=0,frontHead=1,frontTail=0,
		count=0,ownCount=0,expanded=0,fallbacks=0,batchBytes=0,serial=0},Dirty)
end

function Dirty.clear(self: any)
	table.clear(self.items);table.clear(self.queue);table.clear(self.ownQueue);table.clear(self.frontQueue)
	self.head,self.tail,self.ownHead,self.ownTail,self.count,self.ownCount=1,0,1,0,0,0
	self.batchBytes=0
	self.frontHead,self.frontTail=1,0
end

function Dirty.push(self: any, tile: number, old: number, new: number, own: boolean, since: number, front: boolean?): boolean
	if not self.enabled then return false end
	local a,b=bit32.band(old,4095),bit32.band(new,4095)
	local item=self.items[tile]
	if not item then
		if self.count>=self.cap then self.fallbacks+=1;return false end
		item={tile=tile,old=a,ownerChanged=false,wide=false,own=false,since=since,live=true}
		self.items[tile]=item;self.count+=1
		self.tail+=1;self.queue[self.tail]=item
	end
	if a~=b then item.wide=item.wide or item.ownerChanged;item.ownerChanged=true end
	if front and not item.front then item.front=true;self.frontTail+=1;self.frontQueue[self.frontTail]=item end
	if own and not item.own then
		item.own=true;self.ownCount+=1;self.ownTail+=1;self.ownQueue[self.ownTail]=item
	end
	return true
end

function Dirty.pushRun(self: any, first: number, last: number, own: boolean, since: number, front: boolean?): boolean
	if not self:push(first,0,0,own,since,front) then return false end
	local item=self.items[first]
	item.last=math.max(item.last or first,last)
	return true
end

function Dirty.pushBatch(self: any, data: buffer, offset: number, count: number, own: boolean, since: number)
	if count==0 then return end
	self.serial-=1
	local item={key=self.serial,data=data,cursor=offset,finish=offset+count*4,own=own,since=since,live=true}
	self.items[item.key]=item;self.count+=1;self.batchBytes+=buffer.len(data)
	self.tail+=1;self.queue[self.tail]=item
	if own then self.ownCount+=1;self.ownTail+=1;self.ownQueue[self.ownTail]=item end
end

local function compact(self: any, own: boolean,front:boolean?)
	local q,head,tail=if front then self.frontQueue elseif own then self.ownQueue else self.queue,
		if front then self.frontHead elseif own then self.ownHead else self.head,
		if front then self.frontTail elseif own then self.ownTail else self.tail
	if head>tail then table.clear(q);head,tail=1,0
	elseif head>4096 and head>tail/2 then
		local n=tail-head+1
		local out=table.create(n);table.move(q,head,tail,1,out)
		q,head,tail=out,1,n
	end
	if front then self.frontQueue,self.frontHead,self.frontTail=q,head,tail
	elseif own then self.ownQueue,self.ownHead,self.ownTail=q,head,tail else self.queue,self.head,self.tail=q,head,tail end
end

function Dirty.step(self: any, visit: (any)->(), limit: number, budgetMs: number, ownFirst: boolean): number
	if self.count==0 then return 0 end
	local started,done,visits=os.clock(),0,0
	local function take(own: boolean, allowance: number,front:boolean?)
		local q=if front then self.frontQueue elseif own then self.ownQueue else self.queue
		local head,tail=if front then self.frontHead elseif own then self.ownHead else self.head,
			if front then self.frontTail elseif own then self.ownTail else self.tail
		local n=0
		while head<=tail and n<allowance and done<limit and visits<limit*3 do
			local item=q[head]
			if visits>0 and (visits%32==0 or item.data) and (os.clock()-started)*1000>=budgetMs then break end
			visits+=1
			if item.live then
				if item.data then
					item.tile=buffer.readu32(item.data,item.cursor);item.last=item.tile;item.cursor+=4
					while item.cursor<item.finish and item.last-item.tile<255 do
						local nextTile=buffer.readu32(item.data,item.cursor)
						if nextTile~=item.last+1 or math.floor(nextTile/self.width)~=math.floor(item.tile/self.width) then break end
						item.last=nextTile;item.cursor+=4
					end
				end
				visit(item)
				local weight=(item.last or item.tile)-item.tile+1
				done+=weight;n+=weight
				if not item.data or item.cursor>=item.finish then
					item.live=false;self.items[item.key or item.tile]=nil
					self.count-=1;if item.own then self.ownCount-=1 end
					if item.data then self.batchBytes-=buffer.len(item.data);item.data=nil end
				end
			end
			if not item.live then q[head]=nil;head+=1
			elseif item.data then
				-- A nation-sized buffer must not pin the queue ahead of newly
				-- confirmed fronts. Rotate after each bounded span; both queues keep
				-- one live reference, the original age, and the same buffer reservation.
				q[head]=nil;head+=1;tail+=1;q[tail]=item
			end
		end
		if front then self.frontHead,self.frontTail=head,tail
		elseif own then self.ownHead,self.ownTail=head,tail else self.head,self.tail=head,tail end
	end
	if ownFirst then take(true,math.max(1,math.floor(limit/4)),true);take(true,math.max(1,math.floor(limit/2))) end
	take(false,limit)
	self.expanded+=done
	if self.count==0 then self:clear() else compact(self,true,true);compact(self,true);compact(self,false) end
	return done
end

function Dirty.ages(self: any, frame: number): (number,number,number)
	local age,own,bytes=0,0,0
	local buffers={}
	for _,item in self.items do
		local a=frame-item.since+1;age=math.max(age,a)
		if item.own then own=math.max(own,a) end
		if item.data and not buffers[item.data] then buffers[item.data]=true;bytes+=buffer.len(item.data) end
	end
	return age,own,bytes
end

return Dirty
