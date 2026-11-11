--!strict
-- The credits and licence screen's words (Bruno, 2026-11-08: RoWorld on the
-- credits screen; docs/LICENSING_PLAN.md). Pure, so tests check every
-- required notice is present. Screens/Credits draws it.
--
-- What the licences ask of this screen:
--   - AGPL-3.0 section 13: offer every player the source of the version
--     they play, at no charge (SOURCE_URL, with the place version's tag).
--   - OpenFront's section 7(b): "© OpenFront and Contributors" visible.
--   - OpenFront's section 7(c): not titled "OpenFront", no endorsement.
--   - CC BY-SA 4.0 / 3.0 DE: credit OpenFront's resources and Wikimedia's
--     flags, and share what we derived under the same licence.
--   - RoWorld (AGPL-3.0): named beside OpenFront.
--   - colord (MIT): its copyright notice.

local CreditsText = {}

CreditsText.SOURCE_URL = "github.com/PlasticWand/conquer-countries-source"

-- The git tag holding the exact source of a published place version.
function CreditsText.sourceTag(placeVersion: number): string
	return `place-v{placeVersion}`
end

export type Section = { title: string, lines: { string }, copy: string? }

-- `placeVersion` is game.PlaceVersion (0 in an unpublished Studio file).
function CreditsText.sections(placeVersion: number): { Section }
	local version = if placeVersion > 0
		then `You are playing place version {placeVersion}: its source is the git tag {CreditsText.sourceTag(placeVersion)}.`
		else "This is an unpublished Studio build: its source is the working tree."
	return {
		{
			title = "SOURCE CODE",
			lines = {
				"Conquer Countries is free software: you can share and change it under the GNU Affero General Public License, version 3 (AGPL-3.0), with OpenFront's additional terms.",
				"Its full source code is free to download at:",
				version,
			},
			copy = CreditsText.SOURCE_URL,
		},
		{
			title = "OPENFRONT",
			lines = {
				"Conquer Countries is a fork of OpenFront, rebuilt for Roblox. Its rules, nations, AI and maps are ported from OpenFront v0.35.2.",
				"© OpenFront and Contributors. Code under AGPL-3.0: github.com/openfrontio/OpenFrontIO",
				"Maps, flags and icons from OpenFront (CC BY-SA 4.0). Our redrawn flags and map art are shared under CC BY-SA 4.0 too.",
				"Not affiliated with or endorsed by OpenFront.",
			},
		},
		{
			title = "ROWORLD",
			lines = {
				"Parts of the code are ported from RoWorld: map name labels, lobbies, renderer speed-ups, the team victory screen and protection for new players.",
				"© lukechatton and contributors. Code under AGPL-3.0: github.com/lukechatton/roworld",
			},
		},
		{
			title = "MAP DATA",
			lines = {
				"OpenStreetMap: © OpenStreetMap contributors, ODbL.",
				"Natural Earth: public domain.",
				"Bedmap3 (Pritchard et al., Sci Data 12, 109, 2025): CC BY 4.0.",
				"Copernicus Global DEM: © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018, provided under COPERNICUS by the European Union and ESA; distributed by OpenTopography.",
				"NASA Earth Observatory, NASA/JPL-Caltech, NASA's Scientific Visualization Studio, U.S. Geological Survey: public domain.",
				"USA Hawaii relief location map by NordNordWest: CC BY-SA 3.0 DE. Niledelta 33 by John187: CC BY-SA 4.0. Sumatra Topography by Sadalmelik: CC BY-SA 3.0.",
				"Arctic SDI: CC0 1.0. Polar Geospatial Center, PGC Map Catalog (Harvard Dataverse). Geographicus Rare Antique Maps: public domain.",
			},
		},
		{
			title = "FLAGS AND ICONS",
			lines = {
				"Country flags from Wikimedia Commons, CC BY-SA 3.0 DE, via OpenFront.",
				"Icons from The Noun Project via OpenFront: Stats by Meko, Pay Per Click by Fauzan Adiima, Medal by Snow, Guild by Trimanggolo Mulyo.",
			},
		},
		{
			title = "SOUND AND MUSIC",
			lines = {
				"Sound effects and music from Roblox's audio library (Pro Sound Effects, APM Music), licensed through Roblox.",
			},
		},
		{
			title = "OTHER CODE",
			lines = {
				"Colour maths ported from colord, © 2020 Vlad Shilov, MIT License.",
			},
		},
	}
end

-- The menu's credits bar.
CreditsText.BAR = "Fork of OpenFront  ·  © OpenFront and Contributors  ·  Parts from RoWorld  ·  Credits and source code"

return CreditsText
