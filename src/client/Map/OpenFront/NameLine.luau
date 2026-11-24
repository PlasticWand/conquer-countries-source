--!strict
-- Ported from RoWorld 2be8efb (src/client/Map/NameLayer.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
-- Pure inline layout; the confirmed OpenFront name anchor remains the row centre.
local Line = {}

function Line.userId(player: any): number?
	local id = player.userId
	if player.type == "HUMAN" and type(id) == "number" and id > 0 and id < math.huge and id % 1 == 0 then return id end
	return nil
end

function Line.layout(textWidth: number, pixels: number, flag: boolean, head: boolean): any
	local gap = pixels * .03
	local flagH, headH = pixels * .78, pixels * 1.05
	local flagW = flagH * 1.5
	local prefix = (if flag then flagW + gap else 0) + (if head then headH + gap else 0)
	local left = -(textWidth + prefix) / 2
	return {nameX = prefix / 2, flagX = left, flagW = flagW, flagH = flagH,
		headX = left + (if flag then flagW + gap else 0), headH = headH, width = textWidth + prefix}
end

-- RoWorld's drawing code uses OUTLINE_K=.085 (its header still says 1.4).
-- Keep a readable 1.4px floor, with the troop stroke following its smaller em.
function Line.outline(screenPixels: number): number
	return math.max(1.4, screenPixels * .085)
end

-- A title yields to gameplay ink. Dimensions are in the annotation's world
-- units; its 10..14px em and threshold are actual screen pixels.
function Line.titleLayout(text:string?,namePixels:number,screenScale:number):any?
	if not text or screenScale<=0 or namePixels*screenScale<30 then return nil end
	local pixels=math.clamp(namePixels*screenScale*.32,10,14)/screenScale
	return {text=text,pixels=pixels,top=namePixels*1.04,shift=pixels+namePixels*.12,width=#text*pixels*.75}
end

return Line
