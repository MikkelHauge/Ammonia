-- Ammonia - shared helpers, colours, chimes, defaults and the master switch.
--
-- The addon is split by job:
--   Core.lua            helpers, colours/chimes, defaults, SetEnabled
--   Core/Ammo.lua       detection, counting, types, ammo report
--   Core/Reminders.lua  vendor/missing/low/greeting reminders
--   Core/Events.lua     events, watch, slash commands
--   UI.lua              minimap icon and options window
local addonName, ns = ...

-- What the "Reminder text" box falls back to.
ns.DEFAULT_REMINDER_TEXT = "Reminder: Buy Ammo!"

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

-- Prints a line in chat with the addon's name in front, used by the slash
-- commands and the icon tooltip actions.
function ns.Print(message)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffb347[Ammonia]|r "..tostring(message))
	end
end

-- Removes leading and trailing spaces from a piece of text.
function ns.Trim(text)
	return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

-- Runs a function after a delay of seconds. C_Timer is the modern way; the
-- frame timer preserves the delay on clients that do not have it.
function ns.After(seconds, callback)
	if C_Timer and C_Timer.After then
		C_Timer.After(seconds, function()
			pcall(callback)
		end)
	else
		local remaining = math.max(0, tonumber(seconds) or 0)
		local timer = CreateFrame("Frame")
		timer:SetScript("OnUpdate", function(self, elapsed)
			remaining = remaining - elapsed
			if remaining <= 0 then
				self:SetScript("OnUpdate", nil)
				pcall(callback)
			end
		end)
	end
end

-- Plays one of the game's interface sounds by its SOUNDKIT name, quietly
-- doing nothing when the client does not know that name.
function ns.PlayUISound(name)
	local kit = SOUNDKIT and SOUNDKIT[name]
	if kit then
		pcall(PlaySound, kit)
	end
end

-------------------------------------------------------------------------------
-- Message colours
-------------------------------------------------------------------------------

-- These stay clear of the colours chat channels already use (white, red,
-- green, pink, pale blue ...) so a reminder never reads like a whisper or a
-- guild message.
local MESSAGE_COLOURS = {
	{ key = "yellow",    label = "Yellow (default)", r = 1.00, g = 0.92, b = 0.20 },
	{ key = "gold",      label = "Gold",             r = 1.00, g = 0.76, b = 0.25 },
	{ key = "amber",     label = "Amber",            r = 1.00, g = 0.62, b = 0.30 },
	{ key = "lavender",  label = "Lavender",         r = 0.80, g = 0.73, b = 1.00 },
	{ key = "violet",    label = "Violet",           r = 0.63, g = 0.45, b = 1.00 },
	{ key = "indigo",    label = "Indigo",           r = 0.45, g = 0.52, b = 1.00 },
	{ key = "purple",    label = "Purple",           r = 0.76, g = 0.32, b = 1.00 },
	{ key = "magenta",   label = "Magenta",          r = 0.95, g = 0.38, b = 0.95 },
	{ key = "sky",       label = "Sky",              r = 0.45, g = 0.78, b = 1.00 },
	{ key = "cyan",      label = "Cyan",             r = 0.30, g = 0.88, b = 1.00 },
	{ key = "turquoise", label = "Turquoise",        r = 0.30, g = 1.00, b = 0.78 },
}
ns.MESSAGE_COLOURS = MESSAGE_COLOURS

-- Turns the saved colour key into the colour entry itself, defaulting to the
-- first one (Yellow) when the key is unknown.
function ns.GetMessageColour()
	for _, entry in ipairs(MESSAGE_COLOURS) do
		if entry.key == ns.db.colourKey then
			return entry
		end
	end
	return MESSAGE_COLOURS[1]
end

-- |cffrrggbb escape, used for the coloured labels in the dropdowns.
function ns.ColourCode(entry)
	return string.format("|cff%02x%02x%02x",
		math.floor(entry.r * 255 + 0.5),
		math.floor(entry.g * 255 + 0.5),
		math.floor(entry.b * 255 + 0.5))
end

-------------------------------------------------------------------------------
-- Chimes
-------------------------------------------------------------------------------

-- "No sound" always sits at the top of the dropdown. "Ping" is the classic
-- reminder sound; the rest are picked from this client's sound kit table and
-- only offered when the client actually has them.
local CHIME_POOL = {
	{ key = "PING", label = "Ping" },
	{ key = "RAID_WARNING", label = "Raid Warning" },
	{ key = "ALARM_CLOCK_WARNING_1", label = "Alarm One" },
	{ key = "ALARM_CLOCK_WARNING_2", label = "Alarm Two" },
	{ key = "ALARM_CLOCK_WARNING_3", label = "Alarm Three" },
	{ key = "IG_MAINMENU_OPEN", label = "Menu Click" },
	{ key = "IG_MAINMENU_CLOSE", label = "Menu Close" },
	{ key = "IG_CHARACTER_INFO_OPEN", label = "Character Sheet" },
	{ key = "IG_SPELLBOOK_OPEN", label = "Spellbook" },
	{ key = "IG_QUEST_LIST_OPEN", label = "Quest Log" },
	{ key = "IG_BACKPACK_OPEN", label = "Bag Open" },
	{ key = "MONEY_FRAME_OPEN", label = "Coin Purse" },
	{ key = "LEVEL_UP", label = "Level Up" },
}

-- Builds the list the chime dropdown shows: "No sound" first, then every
-- candidate this client really has (Ping is always offered; the fallback
-- number below covers clients without it in the table).
function ns.GetChimeEntries()
	local entries = { { key = "none", label = "No sound" } }
	for _, candidate in ipairs(CHIME_POOL) do
		if candidate.key == "PING" or (SOUNDKIT and SOUNDKIT[candidate.key] ~= nil) then
			table.insert(entries, candidate)
		end
	end
	return entries
end

-- Turns the saved chime key into a sound kit number. Ping has a couple of
-- possible names depending on the client, with a raw fallback ID.
function ns.ResolveChime(key)
	if not key or key == "none" then
		return nil
	end
	if key == "PING" then
		return (SOUNDKIT and (SOUNDKIT.MAP_PING or SOUNDKIT.RAID_WARNING)) or 3175
	end
	return SOUNDKIT and SOUNDKIT[key] or nil
end

-------------------------------------------------------------------------------
-- Sound playback with volume
-------------------------------------------------------------------------------

-- There is no per-sound volume in the API, so the chime plays on the dialog
-- channel and the game's dialog volume is nudged to the chosen level for the
-- moment the chime plays, then put straight back.
local originalDialogVolume
local pendingRestores = 0

-- Some clients keep the dialog volume as 0-1 and some as 0-100; this works
-- out which scale the current one uses so the same setting fits both.
local function DialogVolumeScale()
	local current = GetCVar and GetCVar("Sound_DialogVolume")
	local number = tonumber(current or "")
	if number and number > 1.5 then
		return 100
	end
	return 1
end

-- Plays the chosen chime at the chosen volume. The pending-restore counter
-- makes sure two chimes in quick succession still put the original volume
-- back exactly once, after the last one is done.
function ns.PlayChime()
	local kitID = ns.ResolveChime(ns.db.chime)
	if not kitID then
		return
	end
	local volume = tonumber(ns.db.volume) or 0.8
	if volume < 0 then
		volume = 0
	elseif volume > 1 then
		volume = 1
	end
	if GetCVar and SetCVar then
		local ok = pcall(function()
			if originalDialogVolume == nil then
				originalDialogVolume = GetCVar("Sound_DialogVolume")
			end
			SetCVar("Sound_DialogVolume", tostring(volume * DialogVolumeScale()))
		end)
		if ok and originalDialogVolume ~= nil then
			pendingRestores = pendingRestores + 1
			ns.After(1.3, function()
				pendingRestores = pendingRestores - 1
				if pendingRestores <= 0 then
					pcall(SetCVar, "Sound_DialogVolume", originalDialogVolume)
				end
			end)
		end
	end
	local played = pcall(PlaySound, kitID, "Dialog")
	if not played then
		pcall(PlaySound, kitID)
	end
end

local function FormatCount(count)
	if BreakUpLargeNumbers then
		local ok, formatted = pcall(BreakUpLargeNumbers, count)
		if ok and formatted then
			return tostring(formatted)
		end
	end
	return tostring(count)
end
ns.FormatCount = FormatCount

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------

-- Every setting, with the value a fresh install starts from. ApplyDefaults
-- below copies missing keys from here into the saved table, so new settings
-- can simply be added to this list.
local DEFAULTS = {
	enabled = true,
	-- One switch for every line Ammonia posts in chat; each kind of message
	-- also has its own switch below.
	chatAlert = true,
	showAmmoCount = true,
	greetOnLoad = true,
	-- The "buy ammo" reminder at a vendor that sells ammo.
	vendorReminder = true,
	-- The "equip or purchase compatible ammo" reminder.
	remindMissingAmmo = true,
	warnLowAmmo = true,
	-- The "find a merchant that sells it" line at a vendor that does not.
	vendorLowAmmo = true,
	warnBelow = 400,
	warnStep = 50,
	reminderText = ns.DEFAULT_REMINDER_TEXT,
	colourKey = "yellow",
	chime = "PING",
	volume = 0.8,
	useCooldown = true,
	cooldown = 30,
	icon = {
		shown = true,
		locked = false,
		-- Degrees around the minimap's outer edge; 180 is 9 o'clock.
		-- Tongues sits at 120 (11 o'clock) and Tally at 240 (7 o'clock), so
		-- the three line up down the left side of the minimap.
		angle = 180,
	},
}

-- Walks the defaults and fills in anything the saved table does not have
-- yet (tables go one level deeper). Existing values are never touched.
local function ApplyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			ApplyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
end

-- The master switch, used by the checkbox, the icon's right-click and the
-- slash command. Refreshes the icon and the window so everything agrees.
function ns.SetEnabled(enabled)
	ns.db.enabled = enabled and true or false
	if ns.UpdateIconState then
		ns.UpdateIconState()
	end
	if ns.RefreshOptions then
		ns.RefreshOptions()
	end
	if ns.db.enabled then
		ns.Print("Reminders enabled.")
		if ns.db.remindMissingAmmo then
			ns.SetMissingAmmoReminderEnabled(true)
		end
	else
		ns.Print("Reminders disabled.")
	end
end

ns.DEFAULTS = DEFAULTS
ns.ApplyDefaults = ApplyDefaults

-- The chime nudges the dialog volume and restores it a moment later. A
-- logout or reload inside that window must put the original back first.
function ns.RestoreDialogVolume()
	if originalDialogVolume ~= nil and pendingRestores > 0 then
		pcall(SetCVar, "Sound_DialogVolume", originalDialogVolume)
	end
end
