--!strict
-- Plays Bruno's sound picks (SoundPicks, 2026-10-30) for the cue keys
-- AudioCues and the HUD name: effects (each at most once in a short gap,
-- cut where the sound board cut it), the menu theme and the shuffled match
-- playlist under the Music setting, and one ambience loop at a time. The
-- Sound effects setting mutes effects and ambience. Owns its instances,
-- tweens and connections.

local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Catalog = require(script.Parent.SoundBoardCatalog)
local SoundPicks = require(script.Parent.SoundPicks)

local Audio = {}
Audio.__index = Audio

-- Levels by sound board group (0..1 of a Sound's volume); music and
-- ambience are scaled again by the setting and the zoom.
local GROUP_VOLUME: { [string]: number } = {
	HUD = 0.45,
	Actions = 0.55,
	Builds = 0.55,
	Naval = 0.6,
	Weapons = 0.7,
	Diplomacy = 0.55,
	Alerts = 0.65,
	End = 0.7,
	Menus = 0.55,
	Ambience = 0.5,
	Music = 0.4,
}
-- A cue's own level where its group's is wrong for it (Bruno, 2026-11-11: the
-- victory sting was too loud).
local KEY_VOLUME: { [string]: number } = {
	["end.victory"] = 0.45,
}
-- The same effect at most this often (seconds of real time); the HUD's
-- chattier cues wait longer.
local MIN_GAP = 0.06
-- The HUD click gives way to another cue this close to it (seconds).
local CLICK_WINDOW = 0.1
local KEY_GAP: { [string]: number } = {
	["ui.toast"] = 0.3,
	["ui.tick"] = 0.5,
	["ui.wheelClose"] = 0.2,
}
-- A cut sound fades over its last this many seconds (as on the board), or a
-- quarter of the cut for a short one, so the fade doesn't eat the sound.
local CUT_FADE = 0.3
local MUSIC_FADE = 1.5
-- The most a run of growth lifts the pops' playback speed (about 3 semitones).
local POP_RISE = 0.2
local AMBIENCE_FADE = 0.8

type Cue = { id: number, cut: number?, start: number?, volume: number, group: string, kind: string }
-- "Expansion sound" (Settings): which of the Troops sent picks plays.
local EXPAND_CHOICE: { [string]: number } = { pop = 1, suction = 2 }

export type Audio = typeof(setmetatable(
	{} :: {
		folder: Folder,
		cues: { [string]: Cue },
		templates: { [string]: Sound },
		lastPlayed: { [string]: number },
		sfxOn: boolean,
		musicOn: boolean,
		musicVolume: number,
		musicMode: string?,
		music: Sound?,
		musicTween: Tween?,
		-- Music waits for the player's saved settings (a muted player
		-- shouldn't hear the theme start while their profile loads).
		settingsReady: boolean,
		pendingMusic: string?,
		playlist: { number },
		playlistAt: number,
		musicEnded: RBXScriptConnection?,
		ambienceKey: string?,
		ambience: Sound?,
		ambienceGain: number,
		recent: { string },
		loops: { [string]: Sound },
		expandChoices: { { id: number, cut: number? } },
		expandOff: boolean,
		pops: { [string]: {} },
		-- 0..1: how far a run of growth has lifted the pops' pitch (AudioCues.popRise).
		popRise: number,
		lastCueAt: number,
		clickPending: boolean,
		destroyed: boolean,
	},
	Audio
))

function Audio.new(): Audio
	local folder = Instance.new("Folder")
	folder.Name = "ConquestAudio"
	folder.Parent = SoundService
	local cues: { [string]: Cue } = {}
	local expandChoices: { { id: number, cut: number? } } = {}
	local templates: { [string]: Sound } = {}
	local preload: { Instance } = {}
	for _, e in Catalog.ENTRIES do
		local picks = SoundPicks[e.key]
		if picks and #picks > 0 then
			local cand: any = nil
			for _, c in e.candidates do
				if c.id == picks[1] then
					cand = c
				end
			end
			local volume = KEY_VOLUME[e.key] or GROUP_VOLUME[e.group] or 0.5
			if e.key == "act.send" then
				for _, id in picks do
					for _, c in e.candidates do
						if c.id == id then
							table.insert(expandChoices, { id = id, cut = c.cut })
						end
					end
				end
			end
			cues[e.key] = {
				id = picks[1],
				cut = if cand then cand.cut else nil,
				start = if cand then cand.start else nil,
				volume = volume,
				group = e.group,
				kind = e.kind,
			}
			if e.kind == "sfx" or e.kind == "pop" then
				local s = Instance.new("Sound")
				s.Name = e.key
				s.SoundId = "rbxassetid://" .. picks[1]
				s.Volume = volume
				s.Parent = folder
				templates[e.key] = s
				table.insert(preload, s)
			end
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(preload)
		end)
	end)
	return setmetatable({
		folder = folder,
		cues = cues,
		templates = templates,
		lastPlayed = {},
		sfxOn = true,
		musicOn = true,
		musicVolume = 0.5,
		musicMode = nil,
		music = nil,
		musicTween = nil,
		settingsReady = false,
		pendingMusic = nil,
		playlist = {},
		playlistAt = 0,
		musicEnded = nil,
		ambienceKey = nil,
		ambience = nil,
		ambienceGain = 0,
		recent = {},
		loops = {},
		expandChoices = expandChoices,
		expandOff = false,
		pops = {},
		popRise = 0,
		lastCueAt = -math.huge,
		clickPending = false,
		destroyed = false,
	}, Audio)
end

local function fadeOut(s: Sound, seconds: number)
	local tween = TweenService:Create(s, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Volume = 0 })
	tween.Completed:Once(function()
		s:Destroy()
	end)
	tween:Play()
end

-- One effect. Unknown keys and keys without a pick are ignored. The HUD
-- click waits a frame and gives way to any other cue the same press made
-- (a wheel tile's ring, a card's ✓), so a press makes one sound.
function Audio.play(self: Audio, key: string)
	if self.destroyed or not self.sfxOn then
		return
	end
	if key == "ui.click" then
		if self.clickPending then
			return
		end
		self.clickPending = true
		local at = os.clock()
		task.defer(function()
			self.clickPending = false
			-- Before or after it: buttons run their handler and the thud
			-- in either order.
			if math.abs(self.lastCueAt - at) > CLICK_WINDOW then
				self:_play(key)
			end
		end)
		return
	end
	self.lastCueAt = os.clock()
	self:_play(key)
end

function Audio._play(self: Audio, key: string)
	if self.destroyed then
		return
	end
	local template: Sound? = self.templates[key]
	if not template then
		return
	end
	local now = os.clock()
	if now - (self.lastPlayed[key] or -math.huge) < (KEY_GAP[key] or MIN_GAP) then
		return
	end
	self.lastPlayed[key] = now
	-- Studio: the last cues played, for MCP checks (the folder's "Recent").
	if RunService:IsStudio() then
		table.insert(self.recent, key)
		if #self.recent > 40 then
			table.remove(self.recent, 1)
		end
		self.folder:SetAttribute("Recent", table.concat(self.recent, ","))
	end
	local cut, start = self.cues[key].cut, self.cues[key].start
	if cut == nil and start == nil then
		SoundService:PlayLocalSound(template)
		return
	end
	-- A cut or trimmed sound gets its own copy, started past its lead-in and
	-- faded and removed at the cut.
	local s = template:Clone()
	s.Parent = self.folder
	s.TimePosition = start or 0
	s:Play()
	if cut == nil then
		s.Ended:Once(function()
			s:Destroy()
		end)
		return
	end
	local fade = math.min(CUT_FADE, cut / 4)
	task.delay(math.max(0, cut - fade), function()
		if s.Parent then
			TweenService:Create(s, TweenInfo.new(fade, Enum.EasingStyle.Linear), { Volume = 0 }):Play()
		end
	end)
	task.delay(cut, function()
		s:Destroy()
	end)
end

-- A loop (the fallout fire) for `seconds`, fading in and out; a second
-- call while it burns starts it over.
function Audio.playFor(self: Audio, key: string, seconds: number)
	local cue = self.cues[key]
	if self.destroyed or not self.sfxOn or cue == nil then
		return
	end
	local old = self.folder:FindFirstChild("Loop_" .. key)
	if old then
		old:Destroy()
	end
	local s = Instance.new("Sound")
	s.Name = "Loop_" .. key
	s.SoundId = "rbxassetid://" .. cue.id
	s.Looped = true
	s.Volume = 0
	s.Parent = self.folder
	s:Play()
	TweenService:Create(s, TweenInfo.new(0.3, Enum.EasingStyle.Linear), { Volume = cue.volume }):Play()
	task.delay(math.max(0, seconds - 3), function()
		if s.Parent then
			fadeOut(s, 3)
		end
	end)
end

-- Repeats a "pop" cue's clip every POP_INTERVAL at a varied pitch until
-- its token is replaced (setLoop off).
local function startPops(self: Audio, key: string, cue: Cue)
	local token = {}
	self.pops[key] = token
	local template = self.templates[key]
	task.spawn(function()
		while self.pops[key] == token and not self.destroyed and template do
			local s = template:Clone()
			-- Rising with the run (Bruno, 2026-11-08): from the middle of the
			-- board's range up by POP_RISE, with a narrower jitter so the
			-- climb is heard.
			local low, high = Catalog.POP_PITCH[1], Catalog.POP_PITCH[2]
			local mid, jitter = (low + high) / 2, (high - low) / 4
			s.PlaybackSpeed = mid + POP_RISE * self.popRise + (math.random() * 2 - 1) * jitter
			s.Parent = self.folder
			s:Play()
			task.delay(cue.cut or (s.TimeLength > 0 and s.TimeLength or 1), function()
				s:Destroy()
			end)
			task.wait(Catalog.POP_INTERVAL)
		end
	end)
end

-- How far a run of growth lifts the pops (AudioCues.popRise), 0..1.
function Audio.setPopRise(self: Audio, rise: number)
	self.popRise = math.clamp(rise, 0, 1)
end

-- A loop that plays while `on` is true (the "Troops sent" pops while your
-- land grows): it starts at once and stops at once (a pop) or with a short
-- fade (a loop).
function Audio.setLoop(self: Audio, key: string, on: boolean)
	local cue = self.cues[key]
	if cue and cue.kind == "pop" then
		if key == "act.send" and self.expandOff then
			on = false
		end
		if on and self.sfxOn and not self.destroyed and self.pops[key] == nil then
			startPops(self, key, cue)
		elseif not (on and self.sfxOn) then
			self.pops[key] = nil
		end
		return
	end
	local current: Sound? = self.loops[key]
	if on and self.sfxOn and not self.destroyed and not current and cue then
		local s = Instance.new("Sound")
		s.Name = "While_" .. key
		s.SoundId = "rbxassetid://" .. cue.id
		s.Looped = true
		s.Volume = cue.volume
		s.Parent = self.folder
		s:Play()
		self.loops[key] = s
	elseif (not on or not self.sfxOn) and current then
		fadeOut(current, 0.25)
		self.loops[key] = nil
	end
end

-- A second of a pop cue (the Settings row's sample).
function Audio.preview(self: Audio, key: string, seconds: number)
	if self.pops[key] ~= nil then
		return -- already popping
	end
	self:setLoop(key, true)
	local token = self.pops[key]
	task.delay(seconds, function()
		if self.pops[key] == token then
			self:setLoop(key, false)
		end
	end)
end

function Audio.playAll(self: Audio, keys: { string })
	for _, key in keys do
		self:play(key)
	end
end


local function musicLevel(self: Audio): number
	return if self.musicOn then GROUP_VOLUME.Music * self.musicVolume else 0
end

-- Starts `id` as the music, fading out whatever played.
local function startTrack(self: Audio, id: number, looped: boolean)
	if self.musicEnded then
		self.musicEnded:Disconnect()
		self.musicEnded = nil
	end
	if self.music then
		fadeOut(self.music, MUSIC_FADE)
	end
	local s = Instance.new("Sound")
	s.Name = "Music"
	s.SoundId = "rbxassetid://" .. id
	s.Looped = looped
	s.Volume = 0
	s.Parent = self.folder
	s:Play()
	local tween = TweenService:Create(s, TweenInfo.new(MUSIC_FADE, Enum.EasingStyle.Linear), { Volume = musicLevel(self) })
	tween:Play()
	self.musicTween = tween
	self.music = s
	if not looped then
		self.musicEnded = s.Ended:Connect(function()
			if self.music == s and self.musicMode == "match" then
				self.playlistAt += 1
				local nextId = self.playlist[(self.playlistAt - 1) % #self.playlist + 1]
				startTrack(self, nextId, false)
			end
		end)
	end
end

-- "menu" (the theme, looped), "match" (the playlist, shuffled) or nil.
function Audio.setMusic(self: Audio, mode: string?)
	if not self.settingsReady then
		self.pendingMusic = mode
		return
	end
	if self.destroyed or mode == self.musicMode then
		return
	end
	self.musicMode = mode
	if mode == "menu" and self.cues["music.menu"] then
		startTrack(self, self.cues["music.menu"].id, true)
	elseif mode == "match" then
		local list = table.clone(SoundPicks["music.match"] or {})
		if #list == 0 then
			return
		end
		-- Fisher-Yates: a fresh order each match.
		for i = #list, 2, -1 do
			local j = math.random(1, i)
			list[i], list[j] = list[j], list[i]
		end
		self.playlist, self.playlistAt = list, 1
		startTrack(self, list[1], #list == 1)
	else
		if self.musicEnded then
			self.musicEnded:Disconnect()
			self.musicEnded = nil
		end
		if self.music then
			fadeOut(self.music, MUSIC_FADE)
			self.music = nil
		end
	end
end

-- The Settings screen: Sound effects on/off, Music on/off and its volume.
function Audio.setSettings(self: Audio, settings: { [string]: any })
	self.sfxOn = settings.sounds ~= false
	-- Expansion sound: Pop, Suction (the first or second pick) or Off.
	local choice = self.expandChoices[EXPAND_CHOICE[settings.expandSound] or 0]
	self.expandOff = choice == nil
	local cue, template = self.cues["act.send"], self.templates["act.send"]
	if choice and cue and template then
		cue.id, cue.cut = choice.id, choice.cut
		template.SoundId = "rbxassetid://" .. choice.id
	end
	if self.expandOff then
		self:setLoop("act.send", false)
	end
	self.musicOn = settings.music ~= false
	self.musicVolume = if type(settings.musicVolume) == "number" then settings.musicVolume else 0.5
	-- A fade-in under way would carry on to the old level: stop it first.
	if self.musicTween then
		self.musicTween:Cancel()
		self.musicTween = nil
	end
	if self.music then
		self.music.Volume = musicLevel(self)
	end
	if not self.settingsReady then
		self.settingsReady = true
		self:setMusic(self.pendingMusic)
	end
	if not self.sfxOn then
		self:setAmbience(nil, 0)
	end
end

-- One loop at a time at `gain` (0..1); a new key crossfades.
function Audio.setAmbience(self: Audio, key: string?, gain: number)
	if self.destroyed then
		return
	end
	if not self.sfxOn then
		key = nil
	end
	local cue = if key then self.cues[key] else nil
	if cue == nil then
		key = nil
	end
	local changed = key ~= self.ambienceKey
	if changed then
		if self.ambience then
			fadeOut(self.ambience, AMBIENCE_FADE)
			self.ambience = nil
		end
		self.ambienceKey = key
		if cue then
			local s = Instance.new("Sound")
			s.Name = "Ambience"
			s.SoundId = "rbxassetid://" .. cue.id
			s.Looped = true
			s.Volume = 0
			s.Parent = self.folder
			s:Play()
			self.ambience = s
		end
	end
	-- Small zoom steps don't restart the fade (the source's 3% dedup).
	if not changed and math.abs(gain - self.ambienceGain) < 0.03 then
		return
	end
	self.ambienceGain = gain
	local s = self.ambience
	if s and cue then
		TweenService:Create(s, TweenInfo.new(AMBIENCE_FADE, Enum.EasingStyle.Linear), { Volume = cue.volume * gain }):Play()
	end
end

function Audio.destroy(self: Audio)
	self.destroyed = true
	if self.musicEnded then
		self.musicEnded:Disconnect()
	end
	self.folder:Destroy()
end

return Audio
