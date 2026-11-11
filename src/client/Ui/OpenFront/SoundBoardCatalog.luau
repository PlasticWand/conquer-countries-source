--!strict
-- Candidate sounds for every mechanic that needs audio (Bruno, 2026-10-30:
-- all from Roblox's library; desk sounds for the UI, real war for the
-- battlefield; steady feedback; a rotating orchestral playlist; structure and
-- ocean ambience on zoom). Bruno picked from them on a Studio sound board
-- (removed 2026-11-10); the picks are SoundPicks, the game's cue table.
--
-- Only Roblox's licensed partners are listed (Pro Sound Effects, APM Music)
-- plus Roblox's own uploads: those play in every experience. Titles are
-- shortened from the Creator Store; seconds are as the store lists them.
-- `kind`: "sfx" plays once, "loop" loops until stopped, "pop" repeats a
-- short clip every POP_INTERVAL at a slightly varied pitch (Bruno: Troops
-- sent pops while your land grows, after RoWorld), "music" is a long track. `pick` is how many Bruno chooses (default 1). A candidate's `cut`
-- stops it at that many seconds with a short fade (Bruno, 2026-10-30: the
-- reworked effects are 0-3 s; a longer clip may be cut). A `start` skips that
-- many seconds of lead-in silence (the cut then counts from there).

export type Candidate = { id: number, title: string, by: string, seconds: number, cut: number?, start: number? }
export type Entry = {
	key: string,
	group: string,
	label: string,
	when: string,
	kind: "sfx" | "loop" | "pop" | "music",
	pick: number?,
	candidates: { Candidate },
}

local PSE, APM, RBX = "PSE", "APM", "Roblox"

local function c(id: number, title: string, by: string, seconds: number, cut: number?, start: number?): Candidate
	return { id = id, title = title, by = by, seconds = seconds, cut = cut, start = start }
end

local GROUPS = { "HUD", "Actions", "Builds", "Naval", "Weapons", "Diplomacy", "Alerts", "End", "Menus", "Ambience", "Music" }

local ENTRIES: { Entry } = {
	-- HUD: the dossier desk.
	{ key = "ui.click", group = "HUD", label = "Button press", when = "Any HUD button", kind = "sfx", candidates = {
		c(9120300134, "Typewriter Key 2", PSE, 1), c(9120300066, "Typewriter Key 1", PSE, 1), c(9119717523, "Switch Click Toggle Button 2", PSE, 0),
	} },
	{ key = "ui.wheelOpen", group = "HUD", label = "Wheel opens", when = "Right-click or long-press on the map", kind = "sfx", candidates = {
		c(9125557068, "File Folder Picking Up, Flapping", PSE, 1), c(9116463890, "Manila Folder 11", PSE, 2), c(9118835414, "Scrapbook Open And Turn Pages 2", PSE, 1),
	} },
	{ key = "ui.wheelClose", group = "HUD", label = "Wheel closes", when = "The wheel's red close, or a tap away", kind = "sfx", candidates = {
		c(9125557113, "File Folder Setting Down", PSE, 0), c(9116463231, "Manila Folder 5", PSE, 2), c(9118835802, "Scrapbook Turn Pages 7", PSE, 0),
	} },
	{ key = "ui.ring", group = "HUD", label = "Second ring opens", when = "Build, Weapons, Emoji or amounts on the wheel", kind = "sfx", candidates = {
		c(9118835637, "Scrapbook Turn Pages 5", PSE, 1), c(9125722074, "Paper Handling, Grabs and Flips", PSE, 1), c(9114035348, "Deck Of Cards 2", PSE, 2),
	} },
	{ key = "ui.confirm", group = "HUD", label = "Confirm card: tick", when = "✓ on the build, bomb or warship card", kind = "sfx", candidates = {
		c(9114026047, "Date Stamp Big Office Impact 2", PSE, 1), c(9125482971, "Date Stamp Impact, Reverberant", PSE, 1), c(9114026242, "Date Stamp Impact 5 (the menus' thud now)", PSE, 1),
	} },
	{ key = "ui.cancel", group = "HUD", label = "Confirm card: cross", when = "✕ on any card", kind = "sfx", candidates = {
		c(9125723588, "Paper Packet, Crumpled Sheets", PSE, 0), c(9117088526, "Newspaper Wadding Into A Ball 16", PSE, 1), c(9125724621, "Paper Tear, Fast Harsh Rip", PSE, 1),
	} },
	{ key = "ui.card", group = "HUD", label = "Card appears", when = "The attack card or warship card pins up", kind = "sfx", candidates = {
		c(9117450790, "Plastic Clipboard 2", PSE, 2), c(9114409427, "File Folder Movement 2", PSE, 1), c(9114511936, "Folder Toss 3", PSE, 2),
	} },
	{ key = "ui.slider", group = "HUD", label = "Slider step", when = "Troop share chips, the settings sliders", kind = "sfx", candidates = {
		c(9114071134, "Dial Switch Sharp Ticking 79", PSE, 0), c(9114069409, "Dial Switch Sharp Ticking 48", PSE, 0), c(9116785204, "Metal Ratchet Small Clicks 13", PSE, 1),
	} },
	{ key = "ui.toast", group = "HUD", label = "Toast", when = "\"Expanding with N\", \"Attacking X with N\"", kind = "sfx", candidates = {
		c(9126094819, "Telegraph Key, B-17 Radio Room", PSE, 2), c(9118142087, "Relay Clicks 14", PSE, 0), c(9120300060, "Typewriter 13", PSE, 0),
	} },
	{ key = "ui.error", group = "HUD", label = "Not allowed", when = "Can't afford, can't build there, rejected order", kind = "sfx", candidates = {
		c(9113085764, "Alarm Buzzer 5", PSE, 1), c(9113085623, "Alarm Buzzer 2", PSE, 1), c(1840084163, "Gameshow Buzzer (a)", APM, 2),
		-- Softer desk options (Bruno, 2026-11-08; Nintendo avoids harsh
		-- failure buzzers). Hits measured with an AudioAnalyzer: the knock
		-- clip knocks every ~0.22 s, so the cut keeps two.
		c(9120918417, "Wood Knock, Two Knocks on a Door", PSE, 2, 0.42),
		c(9126267413, "Wood Hit, Dull Thud 10", PSE, 1),
		c(9114773735, "Hand Placed on Wood Table", PSE, 1, 0.35),
		c(9117279995, "Pen Click 1", PSE, 0),
	} },
	{ key = "ui.tick", group = "HUD", label = "Countdown tick", when = "Each second of DEPLOYING IN 5", kind = "sfx", candidates = {
		c(9116467494, "Mantle Clock 20", PSE, 1), c(9113816351, "Clock Mechanism 1", PSE, 1), c(9114068074, "Dial Switch Sharp Ticking 26", PSE, 0),
	} },
	{ key = "ui.sheet", group = "HUD", label = "Panel opens", when = "Leaderboard, player panel, pause window", kind = "sfx", candidates = {
		c(9116463502, "Manila Folder 8", PSE, 2), c(9118837475, "Scrapbook Placed On Table, Pages", PSE, 2), c(9114409428, "File Folder Movement 3", PSE, 1),
	} },
	{ key = "ui.pause", group = "HUD", label = "Pause and resume", when = "The solo pause button", kind = "sfx", candidates = {
		c(9120094547, "Toggle Switch, Industrial 14", PSE, 0), c(9117028601, "Moviola Toggle Switch 6", PSE, 1), c(9120103801, "Toggle Switch, Industrial 32", PSE, 1),
	} },

	-- Your actions.
	{ key = "act.spawn", group = "Actions", label = "Capital placed", when = "You place or move your capital", kind = "sfx", candidates = {
		c(9114461101, "Flag Flap 1", PSE, 3), c(9114462292, "Flagpole Hit 1", PSE, 1), c(9114461561, "Flag Flapping 2", PSE, 2),
	} },
	{ key = "act.start", group = "Actions", label = "Match starts", when = "The spawn phase ends", kind = "sfx", candidates = {
		c(1838998408, "Bugle Charge", APM, 7), c(1845415163, "Heraldic Bugle", APM, 5), c(1837949656, "Military X Sting", APM, 14),
	} },
	{ key = "act.send", group = "Actions", label = "Troops sent", when = "Pops 10 times a second while your land grows; Settings picks 1st or 2nd", kind = "pop", pick = 2, candidates = {
		c(15675055424, "UI Cute Pop", RBX, 3, 0.3),
		c(9113263649, "Balloon Pop 3", PSE, 0),
		c(9112751731, "Bubble Bloop, High Pitched Cute 6", PSE, 0),
		c(12221967, "button", RBX, 0),
		c(16480579910, "Pinball 8-Bit Blip 03", RBX, 0),
		c(9119669065, "Suction Pop 4", PSE, 0),
	} },
	-- Game feel (Bruno, 2026-11-08: docs/design/NINTENDO_FEEL_RESEARCH.md).
	{ key = "act.tap", group = "Actions", label = "Order given", when = "The moment you tap land to expand or attack (before the server answers)", kind = "sfx", candidates = {
		c(9114071134, "Dial Switch Sharp Ticking 79", PSE, 0), c(9114069409, "Dial Switch Sharp Ticking 48", PSE, 0), c(9120300066, "Typewriter Key 1", PSE, 1, 0.25),
	} },
	{ key = "act.impact", group = "Actions", label = "Attack hits their land", when = "Once per attack: your troops first take the nation's land", kind = "sfx", candidates = {
		c(9119072660, "Shield Clang, Hit With Sword 1", PSE, 1), c(9116728376, "Metal Latches, Thunking Impacts 2", PSE, 2, 0.8), c(9119747120, "Sword Impact 102", PSE, 1),
	} },
	{ key = "act.conquerHuman", group = "Actions", label = "Human eliminated", when = "You take a human player's last land", kind = "sfx", candidates = {
		c(9047102381, "Game Day Warrior Sting 1", APM, 3),
		c(1844539433, "Orchestral Hits", APM, 3),
		c(1846284859, "Timpani Signal 1", APM, 3),
		c(1844220041, "Victory Is Ours (a) Sting", APM, 7, 3),
	} },
	{ key = "act.conquerBot", group = "Actions", label = "Nation or tribe eliminated", when = "You take a nation's or tribe's last land (their gold is yours)", kind = "sfx", candidates = {
		c(9113728042, "Cash Register 1", PSE, 2), c(9113728756, "Cash Register 5", PSE, 1), c(9113849651, "Coin Throws 3", PSE, 1),
	} },
	{ key = "act.gold", group = "Actions", label = "Gold arrives", when = "A trade ship or train pays you", kind = "sfx", candidates = {
		c(9113849492, "Coins Or Keys Jingle 6", PSE, 1), c(9113850111, "Coin Throws 8", PSE, 1), c(9125444505, "Medallions Dropped, Metal Hits", PSE, 1),
	} },
	{ key = "act.retreat", group = "Actions", label = "Retreat", when = "You call back an attack or a boat", kind = "sfx", candidates = {
		c(1840120074, "Bugle Call (A)", APM, 4), c(9120675895, "Whistle Calling 4", PSE, 1), c(9125967307, "Soccer Whistle, Acme Thunderer", PSE, 1),
	} },

	-- Your builds.
	{ key = "build.city", group = "Builds", label = "City built", when = "You place your city", kind = "sfx", candidates = {
		c(9120904439, "Wood Impact 2", PSE, 3), c(9116639360, "Metal Hammering 3", PSE, 8), c(9120809403, "Wood Chopping, Single Hits 24", PSE, 1),
	} },
	{ key = "build.port", group = "Builds", label = "Port built", when = "You place your port", kind = "sfx", candidates = {
		c(9119077202, "Ship Horn Interior 1", PSE, 3), c(9119293555, "Small Splash, Shallow Water 1", PSE, 3), c(9114556826, "Gas Pump Bell, Metallic Ding", PSE, 2),
	} },
	{ key = "build.defensePost", group = "Builds", label = "Defense post built", when = "You place your defense post", kind = "sfx", candidates = {
		c(9114083537, "Dirt Throws From Shovel 6", PSE, 3), c(9119120449, "Shovel Dirt 1", PSE, 3), c(9113259397, "Bag Slide And Drop 5", PSE, 2),
	} },
	{ key = "build.factory", group = "Builds", label = "Factory built", when = "You place your factory", kind = "sfx", candidates = {
		c(9119623306, "Steam Piston Pump 10", PSE, 1), c(1846557358, "Machine Start", APM, 6), c(9114369509, "Factory Whistle, Long Steam Blow", PSE, 9),
	} },
	{ key = "build.sam", group = "Builds", label = "SAM launcher built", when = "You place your SAM", kind = "sfx", candidates = {
		c(9118010046, "Radar Static Sweeping Signal 11", PSE, 2), c(9118941667, "Servo Motor 1", PSE, 1), c(9114583503, "Giant Servo Motor Powering Up 2", PSE, 5),
	} },
	{ key = "build.silo", group = "Builds", label = "Missile silo built", when = "You place your silo", kind = "sfx", candidates = {
		c(9125610247, "Hydraulic Hatch Opens", PSE, 4), c(9114854551, "Hydraulic Pallet Lift 10", PSE, 2), c(9126144495, "Heavy Rear Door Slam", PSE, 1),
	} },
	{ key = "build.warship", group = "Builds", label = "Warship launched", when = "Your warship leaves port", kind = "sfx", candidates = {
		c(9113467357, "Boat Horn, Short Blasts 1", PSE, 3),
		c(9119077417, "Ship Horn, USS Constellation 1", PSE, 5, 2.5),
		c(9113121206, "Anchor Foley 2", PSE, 2),
		c(9114792550, "Heavy Chain 7", PSE, 2),
	} },
	{ key = "build.done", group = "Builds", label = "Construction finished", when = "Your structure finishes building", kind = "sfx", candidates = {
		c(9114058995, "Desk Bell Rings 8", PSE, 3, 1), c(9119802009, "Synth Chime, Single Tone 3", PSE, 1), c(9114557092, "Gas Pump Bell, Metallic Ding 3", PSE, 2, 1),
	} },
	{ key = "build.airfield", group = "Builds", label = "Airfield built", when = "Your Airfield is placed", kind = "sfx", candidates = {
		c(9126144495, "Heavy Rear Door Slam", PSE, 3), c(9116728376, "Metal Latches, Thunking Impacts 2", PSE, 3),
	} },
	{ key = "build.railgun", group = "Builds", label = "Railgun built", when = "Your Railgun is placed", kind = "sfx", candidates = {
		c(9118941667, "Servo Motor 1", PSE, 3), c(9126144495, "Heavy Rear Door Slam", PSE, 3),
	} },
	-- Coastal Battery (ARSENAL_V2, 2026-11-09): Claude's candidates, Bruno picks.
	{ key = "build.coastal", group = "Builds", label = "Coastal Battery built", when = "Your Coastal Battery is placed", kind = "sfx", candidates = {
		c(9116728376, "Metal Latches, Thunking Impacts 2", PSE, 2), c(9126144495, "Heavy Rear Door Slam", PSE, 2), c(9119077417, "Ship Horn, USS Constellation 1", PSE, 3),
	} },
	-- Field Works (ARSENAL_V2, 2026-11-09): Claude's candidates, Bruno picks.
	{ key = "build.fieldWorks", group = "Builds", label = "Field Works dug", when = "Your Field Works are placed", kind = "sfx", candidates = {
		c(9114090268, "Dirt Impacts, Wood Stake into Soil 13", PSE, 3.5, 1.5), c(9114083537, "Dirt Throws From Shovel 6", PSE, 2), c(9113764330, "Chains And Metal Impacts 4", PSE, 2),
	} },
	{ key = "build.artillery", group = "Builds", label = "Artillery built", when = "Your Artillery battery is placed", kind = "sfx", candidates = {
		c(9116728376, "Metal Latches, Thunking Impacts 2", PSE, 2, 1), c(9126144495, "Heavy Rear Door Slam", PSE, 1), c(9113764330, "Chains And Metal Impacts 4", PSE, 2, 1),
	} },
	{ key = "build.upgrade", group = "Builds", label = "Structure upgraded", when = "You upgrade a structure", kind = "sfx", candidates = {
		c(9118046636, "Ratchet Wrench Gear Winding 5", PSE, 1), c(9118047507, "Ratchet Wrench Gear Winding 1", PSE, 3), c(9125822176, "Robot Ratchet, Metal Movement", PSE, 1),
	} },
	{ key = "build.delete", group = "Builds", label = "Structure deleted", when = "You delete a structure", kind = "sfx", candidates = {
		c(9125869141, "Rock Cracks, Impact Debris", PSE, 2),
		c(9118586709, "Rock Debris 3", PSE, 3),
		c(9120837884, "Wood Debris Drop To Concrete 2", PSE, 1),
		c(9120479801, "Wall Crash 1", PSE, 5, 2),
	} },

	-- Naval.
	{ key = "naval.boat", group = "Naval", label = "Boat launches", when = "Your transport boat sets off", kind = "sfx", candidates = {
		c(9039691444, "Motorboat Throbber (Short)", APM, 7, 3),
		c(9113467572, "Boat Slide, Large Ship 1", PSE, 6, 3),
		c(9117823374, "Pool Jumps, Splash 4", PSE, 2),
		c(9118710042, "Rope And Water, Heavy Plops 4", PSE, 3),
	} },
	{ key = "naval.landed", group = "Naval", label = "Troops land", when = "Your boat reaches the beach", kind = "sfx", candidates = {
		c(9120609652, "Water Wading, Shallow 2", PSE, 2), c(9120585252, "Big Water Splash 1", PSE, 4), c(9125703162, "Mud Puddle Splash (the old 'landed')", PSE, 1),
	} },
	{ key = "naval.select", group = "Naval", label = "Warship selected", when = "You tap your warship", kind = "sfx", candidates = {
		c(9120456241, "Walkie Talkie 1", PSE, 1), c(9118021986, "Radio Squelches 32", PSE, 1), c(9118027586, "Radio Static 9", PSE, 1),
	} },
	{ key = "naval.move", group = "Naval", label = "Warship ordered", when = "You tap the sea to move it", kind = "sfx", candidates = {
		c(9117795848, "Radio Button Pushes, Walkie Talkie 2", PSE, 2), c(9125937249, "Shortwave Bleep, Radio Telemetry", PSE, 2), c(9120456703, "Walkie Talkie 8", PSE, 2),
	} },
	{ key = "naval.shell", group = "Naval", label = "Warship fires", when = "A warship shoots near your view (rate-limited)", kind = "sfx", candidates = {
		c(9114842503, "Howitzer Tank 12", PSE, 1), c(9114842256, "Howitzer Tank 9", PSE, 2), c(9116973611, "Mortar Explosion 3", PSE, 1),
	} },
	{ key = "naval.sunk", group = "Naval", label = "Your warship sinks", when = "Your warship is destroyed", kind = "sfx", candidates = {
		c(9120314397, "Underwater Explosion 1", PSE, 6, 3),
		c(9120314649, "Underwater Explosion 2", PSE, 5, 3),
		c(9120310416, "Underwater Bubbles, Deep Short Bursts 6", PSE, 1),
		c(9116892160, "Metal Tank Impact, Deep Metallic Boom 1", PSE, 7, 3),
	} },

	-- Weapons.
	{ key = "wpn.atomLaunch", group = "Weapons", label = "Atom bomb launch", when = "Any atom bomb launches", kind = "sfx", candidates = {
		c(9118592471, "Rocket Flare Out 9", PSE, 2),
		c(9118592481, "Rocket Flare Out 11", PSE, 2),
		c(9114659666, "Grenade Launcher 2", PSE, 1),
		c(12222084, "Rocket shot", RBX, 5, 3),
	} },
	{ key = "wpn.hydrogenLaunch", group = "Weapons", label = "Hydrogen bomb launch", when = "Any hydrogen bomb launches", kind = "sfx", candidates = {
		c(9118592231, "Rocket Flare Out 7", PSE, 3),
		c(9118592241, "Rocket Flare Out 6", PSE, 3),
		c(9113044263, "Aerobraking Rocket 3", PSE, 10, 3),
		c(12222095, "Rocket whoosh 01", RBX, 6, 3),
	} },
	{ key = "wpn.mirvLaunch", group = "Weapons", label = "MIRV launch", when = "Any MIRV launches", kind = "sfx", candidates = {
		c(9117089870, "New Super Missile Pass By 3", PSE, 5), c(9118592231, "Rocket Flare Out 7", PSE, 3), c(9125698572, "Mortar Launches, Big Metallic", PSE, 4),
	} },
	{ key = "wpn.megaLaunch", group = "Weapons", label = "Mega Nuke launch", when = "A Mega Nuke launches", kind = "sfx", candidates = {
		c(9120057087, "Searing Build Up, Boomy Explosion 5", PSE, 2),
		c(9125577419, "Giant Air Blast, Launching Catapult", PSE, 2),
		c(9113044149, "Aerobraking Rocket 1", PSE, 12, 3),
		c(9117090333, "New Super Missile Pass By 1", PSE, 8, 3),
	} },
	{ key = "wpn.scatterLaunch", group = "Weapons", label = "Scattershot launch", when = "A Scattershot launches (the Arsenal)", kind = "sfx", candidates = {
		c(9118592231, "Rocket Flare Out 7", PSE, 3),
		c(9113044149, "Aerobraking Rocket 1", PSE, 12, 3),
		c(9117090333, "New Super Missile Pass By 1", PSE, 8, 3),
	} },
	{ key = "wpn.atomHit", group = "Weapons", label = "Atom bomb detonates", when = "An atom bomb lands", kind = "sfx", candidates = {
		c(9117876319, "Power Explosions, Big Heavy Boom 1", PSE, 5), c(9114224354, "Earthquake Explosion 1", PSE, 7), c(9125484367, "Deep Hits, Big Reverberant Booms", PSE, 4),
	} },
	{ key = "wpn.hydrogenHit", group = "Weapons", label = "Hydrogen bomb detonates", when = "A hydrogen bomb or Mega Nuke lands", kind = "sfx", candidates = {
		c(9117876720, "Power Explosions, Big Heavy Boom 1 (long)", PSE, 8), c(9114224675, "Earthquake Explosion 5", PSE, 13), c(9126102254, "Big Explosion Blast Boom", PSE, 6),
	} },
	{ key = "wpn.mirvHit", group = "Weapons", label = "MIRV warhead lands", when = "MIRV warheads land (at most one a half second)", kind = "sfx", candidates = {
		c(9114361853, "Explosions 2", PSE, 2), c(9116973350, "Mortar Explosion 1", PSE, 1), c(1837830050, "BOOM-Sub Boom 01", APM, 4),
	} },
	{ key = "wpn.airStrike", group = "Weapons", label = "Air Strike inbound", when = "An Air Strike leaves your Airfield, or heads for your land", kind = "sfx", candidates = {
		c(9117089870, "New Super Missile Pass By 3", PSE, 5), c(9117090333, "New Super Missile Pass By 1", PSE, 8, 3), c(9113044149, "Aerobraking Rocket 1", PSE, 12, 3),
	} },
	{ key = "wpn.railgunFire", group = "Weapons", label = "Railgun fires", when = "Your Railgun fires, or one fires at your land", kind = "sfx", candidates = {
		c(9125577419, "Giant Air Blast, Launching Catapult", PSE, 2), c(9114159857, "Doppler Whoosh, Crackly Burst 1", PSE, 3),
	} },
	{ key = "wpn.strikeHit", group = "Weapons", label = "Strike lands", when = "An Air Strike or Railgun shot lands (yours, or on your land)", kind = "sfx", candidates = {
		c(9114362396, "Explosions 8, Distant", PSE, 3), c(9117876319, "Power Explosions, Big Heavy Boom 1", PSE, 5), c(9116973611, "Mortar Explosion 3", PSE, 3),
	} },
	-- Paratroopers (ARSENAL_V2, 2026-11-09): Claude's candidates, Bruno picks.
	{ key = "wpn.paraLaunch", group = "Weapons", label = "Paratroopers take off", when = "Your plane takes off, or one heads for your land", kind = "sfx", candidates = {
		c(9125727985, "Peacemaker Whine Bys, Helicopter Buzz 3", PSE, 6.5, 2.5), c(9125693640, "Missile Pass Bys, Buzzy Synth Fly By 2", PSE, 2.3), c(9117090333, "New Super Missile Pass By 1", PSE, 8, 3),
	} },
	{ key = "wpn.paraLand", group = "Weapons", label = "Paratroopers land", when = "Your paratroopers land, or land on you", kind = "sfx", candidates = {
		-- Lead-ins trimmed to just before each onset (AudioAnalyzer, 2026-11-09:
		-- Bruno heard it late; audible from 0.58 / 0.21 / 0.56 s).
		c(9117235033, "Parachute Blossom 9 (lead-in trimmed)", PSE, 2, nil, 0.5), c(9117234408, "Parachute Blossom 1 (lead-in trimmed)", PSE, 3.1, nil, 0.15), c(9117235915, "Parachute Blossom 17 (lead-in trimmed)", PSE, 2.4, nil, 0.5),
	} },
	-- Sabotage (ARSENAL_V2, 2026-11-09): Claude's candidates, Bruno picks.
	{ key = "wpn.sabotageFuse", group = "Weapons", label = "Sabotage fuse lit", when = "You light a sabotage fuse", kind = "sfx", candidates = {
		c(9113158741, "Arrow By and Hit 15 (hissing, sizzling)", PSE, 3.9, 2), c(9112780193, "Fireplace, Constant Burning Flame 1", PSE, 3, 2), c(9118027586, "Radio Static 9", PSE, 2),
	} },
	{ key = "wpn.sabotageDark", group = "Weapons", label = "Building goes dark", when = "A sabotaged building switches off (yours, or one you hit)", kind = "sfx", candidates = {
		c(9117028601, "Moviola Toggle Switch 6", PSE, 1), c(9118142087, "Relay Clicks 14", PSE, 1), c(9118941667, "Servo Motor 1", PSE, 2),
	} },
	{ key = "wpn.artilleryFire", group = "Weapons", label = "Your Artillery fires", when = "Each shell your batteries fire (at most every half second)", kind = "sfx", candidates = {
		c(9125698572, "Mortar Launches, Big Metallic", PSE, 4, 1.2), c(9116973350, "Mortar Explosion 1", PSE, 1), c(9114361853, "Explosions 2", PSE, 2, 1),
	} },
	{ key = "wpn.shellImpact", group = "Weapons", label = "Shell lands on you", when = "An enemy Artillery shell lands on your land", kind = "sfx", candidates = {
		c(9116973607, "Mortar Explosion 5", PSE, 1), c(9116973611, "Mortar Explosion 3", PSE, 1), c(9114361856, "Explosions 4", PSE, 2, 1),
	} },
	{ key = "wpn.samShot", group = "Weapons", label = "SAM fires", when = "A SAM fires near your view", kind = "sfx", candidates = {
		c(9118592471, "Rocket Flare Out 9", PSE, 2), c(12222132, "Shoulder fired rocket", RBX, 1), c(9114159857, "Doppler Whoosh, Crackly Burst 1", PSE, 2),
	} },
	{ key = "wpn.intercept", group = "Weapons", label = "SAM intercepts", when = "A bomb is shot down", kind = "sfx", candidates = {
		c(9116973607, "Mortar Explosion 5", PSE, 1), c(9114361856, "Explosions 4", PSE, 2), c(9120705982, "Whoosh Explosion 1", PSE, 2),
	} },
	{ key = "wpn.fallout", group = "Weapons", label = "Fallout fire", when = "Crackling for 12 s after an atom or hydrogen bomb lands (fades out)", kind = "loop", candidates = {
		c(9112780193, "Fireplace, Constant Burning Flame 1", PSE, 36), c(9118029844, "Rain Of Fire 2", PSE, 56), c(9112780462, "Fireplace, Constant Burning Flame 4", PSE, 43),
	} },
	{ key = "wpn.postDestroyed", group = "Weapons", label = "Defense post destroyed", when = "A defense post blows up in view", kind = "sfx", candidates = {
		c(9116973852, "Mortar Explosion 6", PSE, 1),
		c(9114361853, "Explosions 2", PSE, 2),
		c(9120705982, "Whoosh Explosion 1", PSE, 2),
		c(9114361763, "Explosion, Oxyacetylene Gas 1", PSE, 5, 3),
	} },
	{ key = "wpn.reinforce", group = "Weapons", label = "Reinforcements arrive", when = "You call Reinforcements", kind = "sfx", candidates = {
		c(9114887148, "Jeep Horn, Doubles 6", PSE, 2),
		c(9112983172, "Jeep Wrangler Hard Start 1", PSE, 2),
		c(1840120155, "Bugle Call (C)", APM, 3),
		c(9113417747, "Huey Helicopter, Short Fly By 1", PSE, 6, 3),
	} },

	-- Diplomacy.
	{ key = "dip.request", group = "Diplomacy", label = "Alliance request", when = "Someone asks you for an alliance", kind = "sfx", candidates = {
		c(9125492547, "Door Chime, Two-Three Notes 1", PSE, 6), c(9114557092, "Gas Pump Bell, Metallic Ding 3", PSE, 2), c(9126094832, "Telegraph Key, constant", PSE, 2),
	} },
	{ key = "dip.accepted", group = "Diplomacy", label = "Alliance accepted", when = "An alliance forms", kind = "sfx", candidates = {
		c(9114816356, "Homey Handshake 20", PSE, 1), c(9114771586, "Handshakes 2", PSE, 1), c(1842059783, "Heroic Arrival (sting a)", APM, 8),
	} },
	{ key = "dip.declined", group = "Diplomacy", label = "Alliance declined", when = "Your request is refused", kind = "sfx", candidates = {
		c(9125724895, "Paper Tear, Fast Harsh Rip 2", PSE, 2), c(9117233449, "Paper Tear, Heavy Paper Bag 4", PSE, 2), c(9117624703, "Plastic Sheet Rips, Paper Tears 3", PSE, 1),
	} },
	{ key = "dip.broken", group = "Diplomacy", label = "Alliance broken", when = "An alliance of yours is broken (betrayal)", kind = "sfx", candidates = {
		c(9119742466, "Sword Draw, Unsheathing Two Sabers 1", PSE, 1), c(9114592245, "Glass Breaks 3", PSE, 3), c(1840576383, "Betrayal", APM, 14),
	} },
	{ key = "dip.expiring", group = "Diplomacy", label = "Alliance expiring", when = "An alliance is about to run out (renew)", kind = "sfx", candidates = {
		c(9113421646, "Bell Rings 1", PSE, 3), c(9119761512, "Synth Beeps High Pitch 7", PSE, 2), c(9113584318, "Brass Hand Bell 5", PSE, 11),
	} },
	{ key = "dip.emoji", group = "Diplomacy", label = "Emoji received", when = "Someone sends you an emoji", kind = "sfx", candidates = {
		c(15675055424, "UI Cute Pop", RBX, 3), c(9113263649, "Balloon Pop 3", PSE, 0), c(9119669618, "Suction Pop 6", PSE, 0),
	} },
	{ key = "dip.donation", group = "Diplomacy", label = "Donation received", when = "An ally sends you troops or gold", kind = "sfx", candidates = {
		c(9125445531, "Medallions Dropped, Metal Hits", PSE, 2), c(9113720469, "Cardboard Box 1", PSE, 2), c(9113849445, "Coins Or Keys Jingle 5", PSE, 2),
	} },

	-- Danger alerts.
	{ key = "alert.attacked", group = "Alerts", label = "You are under attack", when = "A new attack on you starts (rate-limited)", kind = "sfx", candidates = {
		-- Not bells (Bruno, 2026-11-02: "don't sound like a bell"); his old
		-- pick stays last until he picks one of these.
		c(9125775207, "Police Whistle, Long and Short (trench whistle)", PSE, 2),
		c(9119661877, "Submarine Alarm, Collision Siren", PSE, 6, 2.5),
		c(9118805558, "Buzzy Whining Klaxon", PSE, 7, 2.5),
		c(9119561244, "Stadium Buzzer, Air-Horn Honks", PSE, 6, 2.5),
		c(9119160597, "Siren Blats, Short", PSE, 2),
		c(9119164100, "Siren Variety, Wail and Horn", PSE, 3),
		c(9118847820, "Scream Siren, Rapid High-Low", PSE, 11, 2.5),
		c(1838612196, "Horn Call 1 (military)", APM, 14, 3),
		c(1844590958, "Signal (bugle)", APM, 11, 3),
		c(9113584318, "Brass Hand Bell 5", PSE, 11, 3),
	} },
	{ key = "alert.losing", group = "Alerts", label = "You are losing land", when = "You lose land fast (at most every few seconds)", kind = "sfx", candidates = {
		c(9125484743, "Deep Hits, Big Reverberant Booms", PSE, 5), c(9113169429, "Artillery Distant 1", PSE, 8), c(9114362396, "Explosions 8, Distant", PSE, 3),
	} },
	{ key = "alert.boat", group = "Alerts", label = "Enemy boat landing", when = "An enemy boat lands on your coast", kind = "sfx", candidates = {
		c(9040286658, "Frigid Foghorn", APM, 10), c(9119077202, "Ship Horn Interior 1", PSE, 3), c(9119663313, "Submarine Alarm Klaxon 2", PSE, 2),
	} },
	{ key = "alert.para", group = "Alerts", label = "Paratroopers inbound", when = "An enemy plane with paratroopers heads for your land", kind = "sfx", candidates = {
		c(9125775207, "Police Whistle, Long and Short (trench whistle)", PSE, 2), c(9119663313, "Submarine Alarm Klaxon 2", PSE, 2), c(9117235900, "Parachute Blossom 16 (lead-in trimmed)", PSE, 2.8, nil, 0.5),
	} },
	{ key = "alert.sabotage", group = "Alerts", label = "Sabotage on you", when = "A fuse is lit on one of your buildings", kind = "sfx", candidates = {
		c(9118027586, "Radio Static 9", PSE, 2), c(9125775207, "Police Whistle, Long and Short (trench whistle)", PSE, 2), c(9126094832, "Telegraph Key, constant", PSE, 2),
	} },
	{ key = "alert.nuke", group = "Alerts", label = "Nuke inbound", when = "A bomb is launched at you", kind = "sfx", candidates = {
		c(9125544285, "Elevator Alarm Bell, Several Rings", PSE, 12, 3),
		c(1841710250, "Alarm Bells sting b", APM, 9, 3),
		c(9114239127, "Electric Bell, Small Buzzy 4", PSE, 15, 3),
	} },

	-- The end.
	{ key = "end.victory", group = "End", label = "Victory", when = "You win", kind = "sfx", candidates = {
		c(1836473422, "Victory Fanfare Sting", APM, 10), c(85130118995016, "Arc Of Triumph (Sting)", APM, 11), c(9043656146, "Olympic Victory - Sting", APM, 10),
		-- Shorter ones for Bruno to choose from (2026-11-11: Arc Of Triumph is
		-- "too loud and too long"; lengths measured in Studio).
		c(9043512647, "Move to the Finish Line (sting b)", APM, 4.6), c(9045751375, "1812 Overture (sting b)", APM, 4.7),
		c(9043511963, "Run Forth (sting b)", APM, 2.7), c(1846884344, "Coast Road (b)", APM, 4.3),
	} },
	{ key = "end.defeat", group = "End", label = "Defeat", when = "You die or someone else wins", kind = "sfx", candidates = {
		c(9040273460, "Tragic Disbelief - Sting 1", APM, 11), c(9045918379, "Seconds Til Defeat (sting)", APM, 4), c(9046010557, "Dark Tide - Sting 1", APM, 11),
	} },
	{ key = "end.flag", group = "End", label = "Conquest flag", when = "Crossed swords over a captured nation", kind = "sfx", candidates = {
		c(9119747120, "Sword Impact 102", PSE, 1),
		c(9119747138, "Sword Impact 202 (first clang)", PSE, 1, 0.6),
		c(9119072660, "Shield Clang, Hit With Sword 1", PSE, 1),
		c(9119746108, "Sword Duel 402", PSE, 1),
	} },

	-- Menus and store.
	{ key = "menu.reveal", group = "Menus", label = "Item revealed", when = "\"You got\" card shows the item", kind = "sfx", candidates = {
		c(9119447936, "Sparkle Bell Tree, Wind Chimes 1", PSE, 5), c(9125635426, "Magical Sparkling Pass By", PSE, 4), c(9126073011, "Synth Sparkle, Bell Tone Ding", PSE, 3),
	} },
	-- The crate opening (Bruno, 2026-11-02; Ui/Crate/CrateOpening.luau).
	{ key = "menu.crateLand", group = "Menus", label = "Crate lands", when = "The supply crate drops onto the depot floor", kind = "sfx", candidates = {
		c(9126260819, "Wood Drop, Pieces Falling To Concrete 31", PSE, 2), c(9113466920, "Board Drops, Wood Impacts, Wobble 3", PSE, 2), c(9120796401, "Wood Barrel Impact, Dropping On Ground 2", PSE, 3),
	} },
	{ key = "menu.crateRattle", group = "Menus", label = "Crate rattles", when = "The crate rattles while it waits for a tap", kind = "sfx", candidates = {
		c(9120877159, "Wood Fall, Pallets On Dirt 6", PSE, 1), c(9113466745, "Board Drops, Wood Impacts 3", PSE, 1), c(9126254743, "Wood Drops On Garage Door, Clattering 22", PSE, 2, 1.2),
	} },
	{ key = "menu.crateTap", group = "Menus", label = "Crate jumps (each tap)", when = "A tap makes the crate crouch and jump", kind = "sfx", candidates = {
		c(9113481039, "Body Fall Wood 1", PSE, 1), c(9125870755, "Rock Hitting Wood, Crash, Bangs 1", PSE, 1), c(9126258653, "Wood Drop, Pieces Falling To Concrete 3", PSE, 2),
	} },
	{ key = "menu.crateCatch", group = "Menus", label = "Catches pop (tap 1)", when = "The first tap pops the crate's catches", kind = "sfx", candidates = {
		c(9116722779, "Metal Latches, Snapping Impacts 3", PSE, 2), c(9116722865, "Metal Latches, Snapping Impacts 4", PSE, 2), c(9116728376, "Metal Latches, Thunking Impacts 2", PSE, 2),
	} },
	{ key = "menu.crateStrap", group = "Menus", label = "Straps snap (tap 2)", when = "The second tap snaps the iron straps off", kind = "sfx", candidates = {
		c(9113764330, "Chains And Metal Impacts 4", PSE, 2), c(9116725218, "Metal Latches, Whipping, Clanking 17", PSE, 2), c(9116761443, "Metal Pole Bangs 1", PSE, 2),
	} },
	{ key = "menu.crateOpen", group = "Menus", label = "Lid blows off (tap 3)", when = "The third tap blows the lid off", kind = "sfx", candidates = {
		c(9120873989, "Wooden Gate Crash, Rattle, Splintering 1 (lead-in trimmed)", PSE, 2, nil, 0.36), c(9120801590, "Wood Break, Snap, Crack, Splinter 1", PSE, 2), c(9120957636, "Wood Roof Crash 5", PSE, 2),
	} },
	{ key = "menu.crateTransform", group = "Menus", label = "Legendary transform", when = "The crate turns into the dark Legendary crate", kind = "sfx", candidates = {
		c(9116385087, "Magic Burst, Big Beefy Impact 5", PSE, 2), c(9116384757, "Magic Burst, Big Beefy Impact 1", PSE, 2), c(9125635650, "Magical Exit, Sparkling Pass By 10", PSE, 4, 3),
	} },
	{ key = "menu.cardRise", group = "Menus", label = "Card rises out", when = "A card peeks out of the crate and rises clear", kind = "sfx", candidates = {
		c(9116415609, "Magic Swoosh, Fast Zooming Pass By 28", PSE, 2), c(9125635426, "Magical Sparkling Pass By", PSE, 4, 2.5), c(9119447936, "Sparkle Bell Tree, Wind Chimes 1", PSE, 5, 3),
	} },
	{ key = "menu.cardFlip", group = "Menus", label = "Card flips", when = "The card flips sideways as it drops", kind = "sfx", candidates = {
		c(9125557068, "File Folder Picking Up, Flapping", PSE, 1), c(9116463243, "Manila Folder 4", PSE, 2), c(9118159730, "Reverse Suck, Short Swish 2", PSE, 1),
	} },
	{ key = "menu.cardSlide", group = "Menus", label = "Card slides aside (3-pack)", when = "A tapped pack card slides to its place", kind = "sfx", candidates = {
		c(9116463890, "Manila Folder 11", PSE, 2), c(9116472221, "Map Movement 1", PSE, 4, 1.5), c(9118768952, "Sand Paper Rubbing On Wood 6 (first swish)", PSE, 1.1, 0.46),
	} },
	{ key = "menu.purchase", group = "Menus", label = "Purchase complete", when = "A Robux or stars purchase goes through", kind = "sfx", candidates = {
		c(9113728049, "Cash Register 2", PSE, 2), c(9113728183, "Cash Register 4", PSE, 3), c(9113849445, "Coins Or Keys Jingle 5", PSE, 2),
	} },
	{ key = "menu.levelUp", group = "Menus", label = "Level up", when = "Your level rises", kind = "sfx", candidates = {
		c(1845349688, "Trumpet Call", APM, 6), c(1845720698, "Medal Of Honor F", APM, 4), c(1845298676, "1812 Fanfare", APM, 5),
	} },
	{ key = "menu.stars", group = "Menus", label = "Stars earned", when = "The results card counts your stars", kind = "sfx", candidates = {
		c(9126073001, "Synth Sparkle, Bell Tone Ding (the old 'built')", PSE, 1), c(9126076030, "Synth Sparkle, Tone Burst", PSE, 1), c(9119448154, "Sparkle Bell Tree, Wind Chimes 2", PSE, 5),
	} },
	{ key = "menu.mapPick", group = "Menus", label = "Map picked", when = "You choose a map in the picker", kind = "sfx", candidates = {
		c(9116472221, "Map Movement 1", PSE, 4), c(9117278125, "Pencil Set Down 1", PSE, 1), c(9116463243, "Manila Folder 4", PSE, 2),
	} },
	{ key = "menu.invite", group = "Menus", label = "Party invite", when = "A friend invites you", kind = "sfx", candidates = {
		c(9114058995, "Desk Bell Rings 8", PSE, 3),
		c(9114301515, "Elevator Bell Synth Chimes 2", PSE, 2),
		c(9119802009, "Synth Chime, Single Tone 3", PSE, 1),
		c(9125492547, "Door Chime, Two-Three Notes 1", PSE, 6, 3),
	} },
	{ key = "menu.lobby", group = "Menus", label = "Match found", when = "A public lobby's countdown ends", kind = "sfx", candidates = {
		c(1840120111, "Bugle Call (B)", APM, 4), c(9042819052, "Drumline (sting a)", APM, 5), c(1845466694, "Drum Roll And Cymbal Ending", APM, 11),
	} },

	-- Ambience, on zoom.
	{ key = "amb.city", group = "Ambience", label = "City", when = "Zoomed in on a city", kind = "loop", candidates = {
		c(9112758856, "City Day Ambience 1", PSE, 36), c(9112770701, "Distant City Traffic 1", PSE, 46), c(9112874053, "Small Town Ambience 1", PSE, 36),
	} },
	{ key = "amb.factory", group = "Ambience", label = "Factory", when = "Zoomed in on a factory", kind = "loop", candidates = {
		c(9112796599, "Industrial Ambience 1", PSE, 36), c(9112838943, "Oil Refinery Ambience 1", PSE, 41), c(9112890497, "UPS Sorting Facility 1", PSE, 36),
	} },
	{ key = "amb.silo", group = "Ambience", label = "Missile silo", when = "Zoomed in on a silo", kind = "loop", candidates = {
		c(9125446564, "Command Room Tone, Deep Hum", PSE, 35), c(1843732610, "Heavy Drone 45", APM, 127), c(9117728939, "Pod Idle Or Cruising 1", PSE, 36),
	} },
	{ key = "amb.sam", group = "Ambience", label = "SAM launcher", when = "Zoomed in on a SAM", kind = "loop", candidates = {
		c(9118008947, "Radar Buzz 5", PSE, 6), c(9119997818, "Electrical Hum Buzz 2", PSE, 33), c(9114776167, "Harbor Machine Idle 1", PSE, 42),
	} },
	{ key = "amb.ocean", group = "Ambience", label = "Ocean and coast", when = "Zoomed in over sea or shore", kind = "loop", candidates = {
		c(9126201834, "Waves Rolling In, Heavy Surf", PSE, 54), c(9117143192, "Ocean Surf 1", PSE, 32), c(9119677305, "Surf, Wave Impact On Zuma Beach 4", PSE, 40),
	} },

	-- Music (APM): tense military orchestral.
	{ key = "music.menu", group = "Music", label = "Menu theme", when = "Main menu and screens", kind = "music", candidates = {
		c(1841366314, "The War Room", APM, 102), c(1837876035, "Cold War Rising - Underscore", APM, 190), c(9046505640, "Imminent Closure (Underscore A)", APM, 110),
	} },
	{ key = "music.match", group = "Music", label = "Match playlist", when = "Shuffled during matches", kind = "music", pick = 5, candidates = {
		c(1837225428, "Requiem of War", APM, 112), c(1837240654, "On the Warpath", APM, 115), c(1842337366, "Might of Arms (b)", APM, 114),
		c(1837225473, "Trench Warfare #2", APM, 96), c(1843083411, "March To War (Underscore)", APM, 102), c(1838617399, "Drums Of War", APM, 109),
		c(120569045226864, "Epic War - Underscore", APM, 122), c(9046457633, "Armies On the March", APM, 149), c(1847635191, "Another Cold War A", APM, 172),
		c(1848108442, "Tactics", APM, 101),
	} },
}

-- The pop's rate and pitch range, for the board and the game alike.
-- task.wait rounds up to whole frames: 0.09 s is about 10 pops a second at
-- 60 FPS.
local POP_INTERVAL = 0.09
local POP_PITCH = { 0.92, 1.12 }

return { GROUPS = GROUPS, ENTRIES = ENTRIES, POP_INTERVAL = POP_INTERVAL, POP_PITCH = POP_PITCH }
