--!strict
-- Which one-time Roblox prompt a player sees after a match, if any
-- (2026-11-15 review, Bruno: "Do them all"). At most one per match card, each
-- once per player (saved as a coach tip, Profile.tipSeen):
--   "notify"    after their first finished match: Roblox's opt-in for
--               experience notifications (ExperienceNotificationService), so
--               the game can tell them when new things arrive.
--   "favorite"  after their first win, or their third match: Roblox's prompt
--               to favorite the game (AvatarEditorService.PromptSetFavorite).
-- Pure: the client adapter shows them (OpenFrontClient, menu.starsGained).

local EngagePrompts = {}

EngagePrompts.NOTIFY = "notify"
EngagePrompts.FAVORITE = "favorite"
EngagePrompts.FAVORITE_AFTER_MATCHES = 3
-- Seconds after the Stars arrive on the result card.
EngagePrompts.DELAY_S = 2.5

local function seen(view: any, id: string): boolean
	if type(view.tipsSeen) ~= "table" then
		return false
	end
	for _, t in view.tipsSeen do
		if t == id then
			return true
		end
	end
	return false
end

-- `view`: the profile view after the match was counted (matches, wins,
-- tipsSeen). Returns the prompt to show now, or nil.
function EngagePrompts.pick(view: any): string?
	if type(view) ~= "table" or type(view.matches) ~= "number" then
		return nil
	end
	if view.matches >= 1 and not seen(view, EngagePrompts.NOTIFY) then
		return EngagePrompts.NOTIFY
	end
	local wins = if type(view.wins) == "number" then view.wins else 0
	if (wins >= 1 or view.matches >= EngagePrompts.FAVORITE_AFTER_MATCHES) and not seen(view, EngagePrompts.FAVORITE) then
		return EngagePrompts.FAVORITE
	end
	return nil
end

return EngagePrompts
