--!strict
-- Generated from OpenFront v0.35.2 (packages/engine-api/src/Schemas.ts emojiTable and engine/src/execution/nation/NationEmojiBehavior.ts), © OpenFront and Contributors, AGPL-3.0.
--
-- The emoji table (ids are 0-based indices into the flattened table, as on
-- the wire) and the nation emoji groups.

local Emoji = {}

Emoji.table = {
	{ "😀", "😊", "🥰", "😇", "😎" },
	{ "😞", "🥺", "😭", "😱", "😡" },
	{ "😈", "🤡", "🥱", "🫡", "🖕" },
	{ "👋", "👏", "✋", "🙏", "💪" },
	{ "👍", "👎", "🫴", "🤌", "🤦‍♂️" },
	{ "🤝", "🆘", "🕊️", "🏳️", "⏳" },
	{ "🔥", "💥", "💀", "☢️", "⚠️" },
	{ "↖️", "⬆️", "↗️", "👑", "🥇" },
	{ "⬅️", "🎯", "➡️", "🥈", "🥉" },
	{ "↙️", "⬇️", "↘️", "❤️", "💔" },
	{ "💰", "⚓", "⛵", "🏡", "🛡️" },
	{ "🏭", "🚂", "❓", "🐔", "🐀" },
}

-- flattenedEmojiTable: id -> emoji, ids from 0.
Emoji.flat = {} :: { [number]: string }
local id = 0
for _, row in Emoji.table do
	for _, e in row do
		Emoji.flat[id] = e
		id += 1
	end
end
Emoji.count = id

Emoji.ASSIST_ACCEPT = { 20, 25, 41 }
Emoji.ASSIST_RELATION_TOO_LOW = { 12, 24 }
Emoji.ASSIST_TARGET_ME = { 6, 32 }
Emoji.ASSIST_TARGET_ALLY = { 27, 21 }
Emoji.AGGRESSIVE_ATTACK = { 10 }
Emoji.ATTACK = { 9 }
Emoji.WARSHIP_RETALIATION = { 52 }
Emoji.NUKE = { 33, 31 }
Emoji.GOT_INSULTED = { 14, 9, 11, 5, 7 }
Emoji.LOVE = { 48, 1, 2 }
Emoji.CONFUSED = { 57, 11 }
Emoji.BRAG = { 38, 39, 19 }
Emoji.CHARM_ALLIES = { 25, 3, 19 }
Emoji.CLOWN = { 11, 24 }
Emoji.RAT = { 59 }
Emoji.OVERWHELMED = { 32, 26, 8, 6, 7, 5, 13, 15 }
Emoji.CONGRATULATE = { 16 }
Emoji.VICTORY = { 38, 39, 4, 19, 0 }
Emoji.SCARED_OF_THREAT = { 18, 6 }
Emoji.BORED = { 12 }
Emoji.HANDSHAKE = { 25 }
Emoji.DONATION_OK = { 20 }
Emoji.DONATION_TOO_SMALL = { 57, 12 }
Emoji.GREET = { 15 }

return Emoji
