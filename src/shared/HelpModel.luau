--!strict
-- How to Play's content (docs/design/rofront-ui-pass.md, screen 6): seven
-- idea cards, the buildings, and the controls we actually bind. Every number
-- is read from an OpenFront EngineConfig, so the text follows the rules.
-- Pure; Ui/Screens/HowToPlay draws it.

local OF = script.Parent.OpenFront
local Format = require(OF.Format)

local HelpModel = {}

export type Card = { n: number, title: string, icon: string, tone: string, text: string }
export type Building = { icon: string, name: string, text: string }
export type Control = { keys: string, action: string }

local function seconds(ticks: number): number
	return math.floor(ticks / 10 + 0.5)
end

function HelpModel.cards(config: any): { Card }
	local publicSpawn = seconds(200) -- Config.numSpawnPhaseTurns for a public game
	local atom = config:nukeMagnitudes("Atom Bomb")
	local hydrogen = config:nukeMagnitudes("Hydrogen Bomb")
	local overtime = config:overtimeConfig()
	return {
		{
			n = 1,
			title = "Pick your start",
			icon = "target",
			tone = "amber",
			text = `Click unclaimed land to place your capital. A solo match begins as soon as you pick; in a public match you have {publicSpawn} seconds to choose and can move until then.`,
		},
		{
			n = 2,
			title = "Expand & attack",
			icon = "sword",
			tone = "red",
			text = "Click land beside yours to expand, or a neighbour to attack it. The attack bar sets the share of your troops you send (Q / E or T / Y). Troops grow back on their own, fastest when you are far below your limit.",
		},
		{
			n = 3,
			title = "Boats",
			icon = "boat",
			tone = "cyan",
			text = "Click a coast you can't reach by land and a transport ship carries your troops from your nearest shore. Warships, built from a Port, patrol where you send them, sink transports and capture trade ships.",
		},
		{
			n = 4,
			title = "Alliances & betrayal",
			icon = "alliance",
			tone = "violet",
			text = `Right-click a player to propose an alliance. It lasts {math.floor(seconds(config:allianceDuration()) / 60)} minutes and can be renewed, and allies can't attack each other. Breaking one makes you a traitor for {seconds(config:traitorDuration())} seconds, with {math.floor(config:traitorDefenseDebuff() * 100 + 0.5)}% less defense, and everyone sees it.`,
		},
		{
			n = 5,
			title = "Build your economy",
			icon = "city",
			tone = "gold",
			text = `Gold comes from your land, trade ships and trains. Build on your own land with the command bar (1 - 0) or the action menu. Structures need {config:structureMinDist()} tiles between them, and each one you own makes the next cost more.`,
		},
		{
			n = 6,
			title = "Nukes & SAMs",
			icon = "atom",
			tone = "red",
			text = `A Missile Silo launches Atom bombs (a {atom.outer}-tile blast), Hydrogen bombs ({hydrogen.outer} tiles) and MIRVs, which split into many warheads. Blasts kill troops, wreck structures and leave fallout. A SAM Launcher shoots down bombs aimed within {math.floor(config:samRange(1))} tiles, further when upgraded.`,
		},
		{
			n = 7,
			title = `Win at {config:percentageTilesOwnedToWin(0)}%`,
			icon = "crown",
			tone = "gold",
			text = `Hold {config:percentageTilesOwnedToWin(0)}% of the land to win (fallout doesn't count). In public free-for-all matches the share you need drops by {overtime.dropPercentPerMinute}% a minute after {overtime.startMinutes} minutes.`,
		},
	}
end

function HelpModel.buildings(config: any): { Building }
	return {
		{ icon = "city", name = "City", text = `Raises your troop limit by {Format.renderTroops(config:cityTroopIncrease())}.` },
		{ icon = "port", name = "Port", text = "On the coast. Sends trade ships for gold and builds Warships." },
		{ icon = "factory", name = "Factory", text = "Lays railroads to your cities and ports; trains pay gold at every stop." },
		{
			icon = "defense",
			name = "Defense Post",
			text = `Attacks on your land within {config:defensePostRange()} tiles cost {config:defensePostDefenseBonus()}x the troops and take {config:defensePostSpeedBonus()}x as long.`,
		},
		{ icon = "sam", name = "SAM Launcher", text = `Shoots down bombs aimed within {math.floor(config:samRange(1))} tiles; each level reaches further.` },
		{ icon = "silo", name = "Missile Silo", text = "Launches Atom bombs, Hydrogen bombs and MIRVs." },
		{ icon = "warship", name = "Warship", text = "Patrols where you send it: sinks transports and warships, captures trade ships." },
	}
end

-- Only what MapInput, OfHud and OfActions bind.
function HelpModel.controls(): { mouse: { Control }, keys: { Control }, touch: { Control } }
	return {
		mouse = {
			{ keys = "Click", action = "Expand, attack or build" },
			{ keys = "Right-click", action = "Action menu" },
			{ keys = "Drag", action = "Move the map" },
			{ keys = "Wheel", action = "Zoom" },
			{ keys = "Shift + drag", action = "Select warships" },
		},
		keys = {
			{ keys = "1 - 0", action = "Choose a building or bomb" },
			{ keys = "Q / E,  T / Y", action = "Attack share down / up" },
			{ keys = "U", action = "Flip the bomb arc" },
		},
		touch = {
			{ keys = "Tap", action = "Expand, attack or build" },
			{ keys = "Long-press", action = "Action menu" },
			{ keys = "Drag", action = "Move the map" },
			{ keys = "Pinch", action = "Zoom" },
			{ keys = "Tap a slot, then the map", action = "Build there" },
		},
	}
end

return HelpModel
