--!strict
-- Presentation IDs agreed with Store/Catalog; unknown or non-human IDs use defaults.
local Cosmetics = {}
Cosmetics.gold = table.freeze({r=1,g=.78,b=.28})
Cosmetics.ironRoad = table.freeze({r=1,g=.32,b=.12})
Cosmetics.outline = table.freeze({r=.10,g=.075,b=.045})
Cosmetics.titleCap, Cosmetics.publicCap = 8, 4
local titles: {[string]: string} = {t_recruit='RECRUIT',t_veteran='VETERAN',t_warlord='WARLORD',t_soldier='SOLDIER'}
function Cosmetics.title(player:any):string?
	return if player.type=='HUMAN' then titles[player.title] else nil
end
function Cosmetics.goldName(player:any):boolean
	return player.type=='HUMAN' and player.nameStyle=='n_gold'
end
function Cosmetics.conquest(id:string?):any?
	return if id=='x_conquest_gold' then Cosmetics.gold else nil
end
function Cosmetics.blast(id:string?):any?
	return if id=='x_blast_ironroad' then Cosmetics.ironRoad else nil
end
return Cosmetics
