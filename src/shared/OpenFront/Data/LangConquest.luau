--!strict
-- Conquest's own strings, for what OpenFront doesn't have (the Arsenal's
-- weapons). Lang.t looks here when a key isn't in LangEn.
return {
	events_display = {
		mega_nuke_inbound = "{name} - mega nuke inbound",
		mega_nuke_detonated = "{name} - mega nuke detonated",
		scattershot_inbound = "{name} - scattershot inbound",
		scattershot_detonated = "{name} - scattershot detonated",
		air_strike_hit = "{name}'s air strike hit your land",
		railgun_shot_hit = "{name}'s railgun hit your land",
		took_over = "You took over {name}",
		reinforcements_arrived = "Reinforcements arrived: +{troops} troops",
		paratroopers_inbound = "{name} - paratroopers inbound ({troops})",
		paratroopers_shot_down = "{name}'s SAM shot down your paratroopers",
		paratroopers_returned = "Your paratroopers returned {troops} troops home",
		sabotage_inbound = "{name} - sabotage on one of your buildings",
		sabotaged = "{name} sabotaged your {unit}: dark for 30 s",
	},
	unit_type = {
		mega_nuke = "Mega Nuke",
		scattershot = "Scattershot",
		artillery = "Artillery",
		artillery_shell = "Artillery Shell",
		airfield = "Airfield",
		air_strike = "Air Strike",
		railgun = "Railgun",
		railgun_shot = "Railgun Shot",
		paratroopers = "Paratroopers",
		coastal_battery = "Coastal Battery",
		sabotage = "Sabotage",
		field_works = "Field Works",
	},
	build_menu = {
		desc = {
			mega_nuke = "Twice an Atom Bomb's blast radius",
			scattershot = "An Atom Bomb that drops 4 to 6 warheads around its target",
			artillery = "Shells enemy land within 45 tiles by itself, every 4 to 7 seconds",
			airfield = "Launches Air Strikes up to 156 tiles away; rearms in 30 seconds",
			air_strike = "Bombs a 15-tile circle from your nearest Airfield; can't be stopped",
			railgun = "Fires anywhere on the map; reloads in 25 seconds",
			railgun_shot = "Hits a 5-tile circle from your nearest Railgun; can't be stopped",
			field_works = "Earthworks near a front: attackers lose 5x and slow 3x within 15 tiles for 60 s",
			sabotage = "Switches off one enemy building for 30 s after a 5-second fuse",
			coastal_battery = "A shore gun that shells enemy boats within 40 tiles; one shot sinks a transport",
			paratroopers = "Flies troops from a City or Airfield up to 120 tiles to attack there; SAMs can shoot it down",
		},
	},
}
