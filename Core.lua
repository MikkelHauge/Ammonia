-------------------------------------------------------------------------------
-- Ammonia - a friendly little ammo reminder for hunters
-------------------------------------------------------------------------------
-- What it does:
--   * When you open a vendor that sells arrows or bullets and you have a bow,
--     crossbow or gun equipped, Ammonia reminds you to restock - in chat,
--     with a chime, or both.
--   * Fifteen seconds after login or equipping a ranged weapon, it checks for
--     compatible ammunition in the ammo slot and reminds you if it is missing.
--   * It can count the ammo you carry and add it to the reminder, for
--     example: "Reminder: Buy Ammo!  (Bullets: 342)".
--   * It can also speak up in chat as your ammo runs low (400, then 350,
--     then 300 ...), including at vendors that do not sell ammo. Both the
--     starting number and the warning step are adjustable in the options.
--   * A small icon sits near the minimap: left-click opens the options,
--     right-click turns the reminders on or off.
--
-- How an addon like this is put together, for anyone who wants to tinker:
--   * The game loads the files named in Ammonia.toc from top to bottom.
--   * The first line of each file is:
--         local addonName, ns = ...
--     The game hands every file the addon's name and one shared table
--     (called a namespace; "ns" here). Files can put functions and settings
--     on that table and see what the other files put there. Core.lua loads
--     first, so the shared machinery lives here; UI.lua adds the icon and
--     the options window on top of it.
--   * Addons hear about the world through events. The game calls our event
--     handler (see the Events section below) with names like MERCHANT_SHOW
--     ("a vendor window just opened") or BAG_UPDATE ("a bag changed"). We
--     register for the events we care about and act when they fire.
--   * AmmoniaDB is a saved-variables table: the game stores it in the WTF
--     folder and hands it back on every login, so settings survive between
--     sessions.
--   * Functions named like ns.Something are shared with UI.lua too; plain
--     local functions stay private to this file.
--
-- Files:
--   * Core.lua (this file): defaults, ammo counting, the reminder and the
--     low-ammo warnings, events, slash commands.
--   * UI.lua: the icon and the options window.
-------------------------------------------------------------------------------
local addonName, ns = ...

-- Item info moved from a global function to C_Item on newer clients; keep a
-- single reference so the rest of the file does not have to care which one
-- this client has.
local GetItemInfoFunction = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function SafeGetItemInfo(item)
	if type(GetItemInfoFunction) ~= "function" then
		return nil
	end
	local ok, name, link, quality, itemLevel, minLevel, itemType, itemSubType,
		stackCount, equipLoc, texture, sellPrice, classID, subclassID = pcall(GetItemInfoFunction, item)
	if ok then
		return name, classID, subclassID
	end
	return nil
end

-- Enum tables (Enum.ItemClass and so on) only exist on newer clients. The
-- plain numbers mean the same thing everywhere, so fall back to those.
local itemClass = Enum and Enum.ItemClass
local itemSubclass = Enum and Enum.ItemWeaponSubclass
local AMMO_CLASS = (itemClass and itemClass.Projectile) or 6
local WEAPON_CLASS = (itemClass and itemClass.Weapon) or 2
local BOW_SUBCLASS = (itemSubclass and (itemSubclass.Bows or itemSubclass.Bow)) or 2
local GUN_SUBCLASS = (itemSubclass and (itemSubclass.Guns or itemSubclass.Gun)) or 3
local CROSSBOW_SUBCLASS = (itemSubclass and (itemSubclass.Crossbow or itemSubclass.Crossbows)) or 18
local RANGED_WEAPON_SUBCLASSES = {
	[BOW_SUBCLASS] = true,
	[GUN_SUBCLASS] = true,
	[CROSSBOW_SUBCLASS] = true,
}

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

-------------------------------------------------------------------------------
-- The reminder itself
-------------------------------------------------------------------------------

-- Reads the ranged slot (and the main hand, so a bow in the hand still
-- counts) and returns the weapon subclass when a bow, gun or crossbow is
-- equipped. This is what decides whether ammo matters at all.
local function GetEquippedRangedSubclass()
	if not GetInventoryItemLink then
		return nil
	end
	local slots = { INVSLOT_MAINHAND or 16, INVSLOT_RANGED or 18 }
	for _, slot in ipairs(slots) do
		local okLink, itemLink = pcall(GetInventoryItemLink, "player", slot)
		if not okLink then
			itemLink = nil
		end
		if itemLink then
			local _, classID, subclassID = SafeGetItemInfo(itemLink)
			if classID == WEAPON_CLASS and RANGED_WEAPON_SUBCLASSES[subclassID] then
				return subclassID
			end
		end
	end
	return nil
end

-- True when some kind of ranged weapon is equipped.
local function HasRangedWeaponEquipped()
	return GetEquippedRangedSubclass() ~= nil
end

-- Looks through the open vendor's stock and reports whether it sells ammo.
-- The item class is the reliable signal when the item is cached; a name
-- match on "arrow" or "bullet" is the backup for items the client has not
-- seen yet.
local function MerchantSellsAmmo()
	if not GetMerchantNumItems then
		return false
	end
	local okCount, numItems = pcall(GetMerchantNumItems)
	if not okCount or type(numItems) ~= "number" then
		return false
	end
	for index = 1, numItems do
		local classID
		if GetMerchantItemID then
			local okID, itemID = pcall(GetMerchantItemID, index)
			if okID and itemID then
				local _, foundClass = SafeGetItemInfo(itemID)
				classID = foundClass
			end
		end
		if not classID and GetMerchantItemLink and GetItemInfoFunction then
			local okLink, itemLink = pcall(GetMerchantItemLink, index)
			if okLink and itemLink then
				local _, foundClass = SafeGetItemInfo(itemLink)
				classID = foundClass
			end
		end
		if classID == AMMO_CLASS then
			return true
		end

		-- Fallback for items the client has not cached yet: match on the name.
		if not classID then
			local name
			if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
				local okInfo, merchantInfo = pcall(C_MerchantFrame.GetItemInfo, index)
				name = okInfo and merchantInfo and merchantInfo.name
			elseif GetMerchantItemInfo then
				local okInfo, itemName = pcall(GetMerchantItemInfo, index)
				name = okInfo and itemName
			end
			if name then
				local lowerName = string.lower(name)
				if string.find(lowerName, "arrow", 1, true) or string.find(lowerName, "bullet", 1, true) then
					return true
				end
			end
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- Ammo counting
-------------------------------------------------------------------------------

-- Formats a number with thousands separators where the client can do that
-- ("1,250"), and as a plain number where it cannot.
local function FormatCount(count)
	if BreakUpLargeNumbers then
		local ok, formatted = pcall(BreakUpLargeNumbers, count)
		if ok and formatted then
			return tostring(formatted)
		end
	end
	return tostring(count)
end

-- Works out whether a carried item is arrows or bullets. The item class is the
-- reliable signal when the client has the item cached; the name is the backup.
local function ClassifyAmmo(itemID, hyperlink)
	local name, classID
	if type(GetItemInfoFunction) == "function" then
		if itemID then
			name, classID = SafeGetItemInfo(itemID)
		end
		if not classID and hyperlink then
			name, classID = SafeGetItemInfo(hyperlink)
		end
	end
	if classID and classID ~= AMMO_CLASS then
		return nil
	end
	if not name and hyperlink then
		name = hyperlink:match("%[(.-)%]")
	end
	if not name then
		return nil
	end
	local lowerName = string.lower(name)
	if string.find(lowerName, "arrow", 1, true) then
		return "arrow"
	end
	if string.find(lowerName, "bullet", 1, true) or string.find(lowerName, "shot", 1, true) then
		return "bullet"
	end
	return nil
end

-- Walks every carried bag and adds the stacks up, returning how many arrows
-- and how many bullets you are carrying.
local function CountCarriedAmmo()
	local arrows, bullets = 0, 0
	if not (C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerNumSlots) then
		return arrows, bullets
	end
	local lastBag = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)
	for bag = 0, lastBag do
		local numSlots = C_Container.GetContainerNumSlots(bag)
		if numSlots and numSlots > 0 then
			for slot = 1, numSlots do
				local info = C_Container.GetContainerItemInfo(bag, slot)
				if info then
					local kind = ClassifyAmmo(info.itemID, info.hyperlink)
					local count = info.stackCount or 1
					if kind == "arrow" then
						arrows = arrows + count
					elseif kind == "bullet" then
						bullets = bullets + count
					end
				end
			end
		end
	end
	return arrows, bullets
end

-- The display name for an ammo stack: the item's own name once the client
-- has the item cached, otherwise whatever name sits inside the item link.
local function GetAmmoTypeName(info)
	local name
	if GetItemInfoFunction then
		if info.itemID then
			name = SafeGetItemInfo(info.itemID)
		end
		if not name and info.hyperlink then
			name = SafeGetItemInfo(info.hyperlink)
		end
	end
	if not name and info.hyperlink then
		name = info.hyperlink:match("%[(.-)%]")
	end
	return name
end

-- How the equipped type is found. The ammo slot answers directly when it
-- can: its item id names the ammo being fired (see GetAmmoSlotItemID below).
-- When it does not answer, two backups stand in: lastTypeCounts and
-- observedEquipped watch for shots - the stack that goes down when firing is
-- the equipped one - and the type behind the smallest stack is the last
-- stand-in, since that is the stack the game will use up first.
local lastTypeCounts = {}
local observedEquipped = {}

-- The count in the ammo slot. This client keeps the stack being fired in the
-- character sheet's ammo slot: the item itself stays hidden (no link, no
-- name), but the count reads true - it is the real equipped count, straight
-- from the client. Returns nil when the slot reads nothing.
local function GetAmmoSlotCount()
	if not GetInventoryItemCount then
		return nil
	end
	local ok, count = pcall(GetInventoryItemCount, "player", INVSLOT_AMMO or 0)
	if ok and count and count > 0 then
		return count
	end
	return nil
end

-- The item id in the ammo slot: the ammo the client is firing right now. The
-- slot hides the item's link but answers with its id, which is enough to
-- name it and to find its matching stack in the bags. Nil when the slot
-- reads nothing.
local function GetAmmoSlotItemID()
	if not GetInventoryItemID then
		return nil
	end
	local ok, itemID = pcall(GetInventoryItemID, "player", INVSLOT_AMMO or 0)
	if ok and itemID and itemID > 0 then
		return itemID
	end
	return nil
end

-- Collects the carried ammo of one kind, rolled up by item type: every stack
-- of "Heavy Shot" adds into one entry, every "Crafted Heavy Shot" stack into
-- another. Returns the entries in the order their first stack appears in the
-- bags, plus the entry that is equipped: the type last seen being fired (see
-- the tables above), or the type behind the smallest stack until a shot has
-- been seen.
local function CollectAmmoTypes(kind)
	local types = {}
	local order = {}
	local fallback
	local fallbackSmallest
	if not kind then
		return order, fallback
	end
	if not (C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerNumSlots) then
		return order, fallback
	end
	local lastBag = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)
	for bag = 0, lastBag do
		local numSlots = C_Container.GetContainerNumSlots(bag)
		if numSlots and numSlots > 0 then
			for slot = 1, numSlots do
				local info = C_Container.GetContainerItemInfo(bag, slot)
				if info and ClassifyAmmo(info.itemID, info.hyperlink) == kind then
					local count = info.stackCount or 1
					if count > 0 then
						local key = info.itemID or info.hyperlink or (bag * 1000 + slot)
						local entry = types[key]
						if not entry then
							entry = {
								key = key,
								name = GetAmmoTypeName(info),
								count = 0,
							}
							types[key] = entry
							order[#order + 1] = entry
						end
						entry.count = entry.count + count
						if not fallbackSmallest or count < fallbackSmallest then
							fallbackSmallest = count
							fallback = entry
						end
					end
				end
			end
		end
	end
	-- The equipped type is the one whose total dropped since the last look: a
	-- shot lowers a stack's count without lifting another stack of the same
	-- type (moving, splitting and merging keep the total level, buying lifts
	-- it), so a drop is a real shot, seen rather than guessed.
	local previous = lastTypeCounts[kind]
	local current = {}
	for _, entry in ipairs(order) do
		current[entry.key] = entry.count
		if previous and previous[entry.key] and entry.count < previous[entry.key] then
			observedEquipped[kind] = entry.key
		end
	end
	lastTypeCounts[kind] = current
	-- Which type is equipped: the ammo slot names it directly when the
	-- client answers (its item id is the key of the matching bag entry);
	-- after that the type last seen being fired; the smallest stack is the
	-- last stand-in.
	local equipped
	local slotItemID = GetAmmoSlotItemID()
	if slotItemID then
		for _, entry in ipairs(order) do
			if entry.key == slotItemID then
				equipped = entry
				break
			end
		end
	end
	if not equipped then
		for _, entry in ipairs(order) do
			if entry.key == observedEquipped[kind] then
				equipped = entry
				break
			end
		end
	end
	if not equipped then
		equipped = fallback
	end
	return order, equipped
end

-- "bullet"/"bullets" or "arrow"/"arrows" for a count, so every message reads
-- naturally in both singular and plural.
local function AmmoLabel(kind, count)
	if count == 1 then
		if kind == "bullet" then
			return "bullet"
		end
		return "arrow"
	end
	if kind == "bullet" then
		return "bullets"
	end
	return "arrows"
end

-- The equipped-first type list for one kind: "21 equipped Heavy Shot, 1,000
-- Crafted Heavy Shot spare". Every other type carries its own count and the
-- word "spare". Returns nil when there is no split to show (none or just one
-- type carried) - the messages then keep their simple old wording.
local function AmmoTypeListText(kind)
	local types, equipped = CollectAmmoTypes(kind)
	if #types < 2 or not equipped then
		return nil
	end
	-- The equipped number is the ammo slot count when the client reads one:
	-- that is the stack being fired, straight from the game. The type's own
	-- total stands in when the slot reads nothing.
	local equippedCount = GetAmmoSlotCount() or equipped.count
	local parts = {}
	parts[1] = FormatCount(equippedCount).." equipped "..(equipped.name or AmmoLabel(kind, equippedCount))
	for _, entry in ipairs(types) do
		if entry ~= equipped then
			parts[#parts + 1] = FormatCount(entry.count).." "..(entry.name or AmmoLabel(kind, entry.count)).." spare"
		end
	end
	return table.concat(parts, ", ")
end

-- One count part for the reminder summary: the type list when the firing
-- kind is carried in several types ("Bullets: 21 equipped Heavy Shot, 1,000
-- Crafted Heavy Shot spare"), otherwise the plain total as before.
local function AmmoCountPart(label, kind, total)
	local list = AmmoTypeListText(kind)
	if list then
		return label..": "..list
	end
	return label..": "..FormatCount(total)
end

-- Shows the count for the type the equipped ranged weapon fires; the other
-- type is included too when you happen to carry some.
function ns.GetAmmoSummary()
	local arrows, bullets = CountCarriedAmmo()
	local subclass = GetEquippedRangedSubclass()
	local parts = {}
	if subclass == GUN_SUBCLASS then
		parts[#parts + 1] = AmmoCountPart("Bullets", "bullet", bullets)
		if arrows > 0 then
			parts[#parts + 1] = "Arrows: "..FormatCount(arrows)
		end
	elseif subclass then
		parts[#parts + 1] = AmmoCountPart("Arrows", "arrow", arrows)
		if bullets > 0 then
			parts[#parts + 1] = "Bullets: "..FormatCount(bullets)
		end
	else
		if arrows > 0 then
			parts[#parts + 1] = "Arrows: "..FormatCount(arrows)
		end
		if bullets > 0 then
			parts[#parts + 1] = "Bullets: "..FormatCount(bullets)
		end
	end
	if #parts == 0 then
		return nil
	end
	return "("..table.concat(parts, ", ")..")"
end

-- The full reminder line: your text plus the ammo count when enabled.
function ns.BuildReminderText()
	local text = ns.db.reminderText or ""
	if ns.db.showAmmoCount then
		local summary = ns.GetAmmoSummary()
		if summary then
			if text ~= "" then
				text = text.."  "..summary
			else
				text = summary
			end
		end
	end
	return text
end

-- Fires the current reminder: chat message and/or chime.
function ns.FireReminder(message)
	if ns.db.chatAlert then
		local text = message or ns.BuildReminderText()
		if text ~= "" then
			local colour = ns.GetMessageColour()
			if DEFAULT_CHAT_FRAME then
				DEFAULT_CHAT_FRAME:AddMessage(text, colour.r, colour.g, colour.b)
			end
		end
	end
	ns.PlayChime()
end

-- Reminds at most once per vendor visit. The flag resets on MERCHANT_SHOW,
-- and the optional cooldown limits how often the reminder can repeat across
-- visits.
local remindedThisVendor = false
local lastReminder
local lowAmmoWarnedThisVendor = false

function ns.TryReminder()
	if not ns.db or not ns.db.enabled or not ns.db.vendorReminder or remindedThisVendor then
		return
	end
	if ns.db.useCooldown and ns.db.cooldown and ns.db.cooldown > 0 and lastReminder
		and (GetTime() - lastReminder) < ns.db.cooldown then
		return
	end
	if not HasRangedWeaponEquipped() then
		return
	end
	if not MerchantSellsAmmo() then
		return
	end
	remindedThisVendor = true
	lastReminder = GetTime()
	ns.FireReminder()
end

-------------------------------------------------------------------------------
-- Low ammo warnings
-------------------------------------------------------------------------------

-- The warning levels work like a staircase: with "Warn at" set to 400 and
-- "Warn every" set to 50, the levels are 400, 350, 300, 250 and so on. A
-- level is announced when your count drops to it or below. The same level is
-- never announced twice on one slide down - stocking back up above the
-- starting number arms the whole staircase again. announcedLevel remembers
-- the last level, and nil means "fully armed".
local announcedLevel

-- Right after a login or a reload the game can still be filling in its bag
-- and item details for a moment, and a scan during that moment looks exactly
-- like an empty quiver. This flag turns true as soon as one real stack of
-- ammo has actually been seen this session; until then a zero is treated as
-- "not known yet" and stays quiet.
local sawRealAmmo = false

-- The greeting happens once per session (once per login or reload); this
-- flag keeps a later zone or bag update from repeating it.
local greetedThisSession = false

-- Which kind of ammo the equipped ranged weapon fires: "bullet" for a gun,
-- "arrow" for a bow or crossbow, nil when no ranged weapon is equipped.
local function GetEquippedAmmoKind()
	local subclass = GetEquippedRangedSubclass()
	if not subclass then
		return nil
	end
	if subclass == GUN_SUBCLASS then
		return "bullet"
	end
	return "arrow"
end

local missingAmmoCheckGeneration = 0
local missingAmmoReminded = false
local missingAmmoRepeatElapsed = 0
local merchantAmmoCheckGeneration = 0

local function HasCompatibleAmmoEquipped(kind)
	local itemID = GetAmmoSlotItemID()
	return itemID ~= nil and GetAmmoSlotCount() ~= nil and ClassifyAmmo(itemID) == kind
end

local function MissingAmmoReminderText(kind)
	local text = "Reminder: Equip or purchase compatible ammo!"
	if ns.db.showAmmoCount then
		local summary = ns.GetAmmoSummary()
		if summary then
			text = text.."  "..summary
		end
	end
	return text
end

function ns.CheckEquippedAmmo(isRepeat)
	if not ns.db or not ns.db.enabled or not ns.db.remindMissingAmmo then
		return
	end
	local kind = GetEquippedAmmoKind()
	if not kind then
		missingAmmoReminded = false
		return
	end
	if HasCompatibleAmmoEquipped(kind) then
		missingAmmoReminded = false
		return
	end
	if missingAmmoReminded and not isRepeat then
		return
	end
	missingAmmoReminded = true
	ns.FireReminder(MissingAmmoReminderText(kind))
end

local function ScheduleMissingAmmoCheck(resetReminder)
	missingAmmoRepeatElapsed = 0
	if resetReminder then
		missingAmmoReminded = false
	end
	missingAmmoCheckGeneration = missingAmmoCheckGeneration + 1
	local generation = missingAmmoCheckGeneration
	ns.After(15, function()
		if generation == missingAmmoCheckGeneration then
			missingAmmoRepeatElapsed = 0
			ns.CheckEquippedAmmo()
		end
	end)
end

function ns.SetMissingAmmoReminderEnabled(enabled)
	if not ns.db then
		return
	end
	ns.db.remindMissingAmmo = enabled and true or false
	missingAmmoReminded = false
	missingAmmoRepeatElapsed = 0
	missingAmmoCheckGeneration = missingAmmoCheckGeneration + 1
	if ns.db.remindMissingAmmo and ns.db.enabled then
		ScheduleMissingAmmoCheck(true)
	end
end

function ns.TryLowAmmoMerchantWarning()
	if not ns.db or not ns.db.enabled or not ns.db.warnLowAmmo or not ns.db.vendorLowAmmo or lowAmmoWarnedThisVendor then
		return
	end
	local itemCount = GetMerchantNumItems and GetMerchantNumItems() or 0
	if itemCount <= 0 or MerchantSellsAmmo() then
		return
	end
	local kind = GetEquippedAmmoKind()
	if not kind then
		return
	end
	local _, equipped = CollectAmmoTypes(kind)
	local count = equipped and equipped.count or 0
	if count > (tonumber(ns.db.warnBelow) or 400) then
		return
	end
	lowAmmoWarnedThisVendor = true
	local colour = ns.GetMessageColour()
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("You're low on Ammo, find a merchant that sells it", colour.r, colour.g, colour.b)
	end
end

local function ScheduleMerchantAmmoCheck()
	merchantAmmoCheckGeneration = merchantAmmoCheckGeneration + 1
	local generation = merchantAmmoCheckGeneration
	ns.After(1, function()
		if generation == merchantAmmoCheckGeneration then
			ns.TryLowAmmoMerchantWarning()
		end
	end)
end

-- The counting part of every message: the equipped-first type list when the
-- firing kind is carried in several types ("21 equipped Heavy Shot, 1,000
-- Crafted Heavy Shot spare"), or the familiar "342 bullets left" when there
-- is just one type.
local function AmmoAmountText(kind, count)
	local list = AmmoTypeListText(kind)
	if list then
		return list
	end
	return FormatCount(count).." "..AmmoLabel(kind, count).." left"
end

-- Posts one warning line in the saved chat colour. The count in the message
-- is the real count, which is usually a little below the level itself (the
-- first step below 400 might catch you at 397). Hitting zero gets its own
-- louder wording.
function ns.FireLowAmmoWarning(kind, count)
	local text
	if count == 0 then
		text = "You are out of "..AmmoLabel(kind, count).."!"
	else
		text = "Low ammo: "..AmmoAmountText(kind, count)
	end
	local colour = ns.GetMessageColour()
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(text, colour.r, colour.g, colour.b)
	end
end

-- The friendly line shown once per session, the first time a real ammo
-- count is seen: "Ammonia enabled - You have 1,183 bullets left".
function ns.FireAmmoGreeting(kind, count)
	local text = "Ammonia enabled - You have "..AmmoAmountText(kind, count)
	local colour = ns.GetMessageColour()
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(text, colour.r, colour.g, colour.b)
	end
end

-- Runs whenever the ammo count may have changed (bags updated, weapon
-- swapped, loading in). It only speaks when the staircase actually descends
-- to a new level, so the warnings follow the ammo and never a clock.
function ns.CheckLowAmmo()
	if not ns.db or not ns.db.enabled then
		-- The master switch silences everything, warnings included.
		announcedLevel = nil
		return
	end
	if not ns.db.warnLowAmmo and greetedThisSession then
		-- Warnings are off and the greeting has already been said: nothing
		-- here would speak up, so the slow bag scan is skipped. The reset
		-- keeps switching the warnings back on re-armed, exactly as before.
		announcedLevel = nil
		return
	end
	local kind = GetEquippedAmmoKind()
	if not kind then
		announcedLevel = nil
		return
	end
	-- The warnings count the firing type: the bullets the gun will use up
	-- next, not the grand total over every type carried.
	local types, equipped = CollectAmmoTypes(kind)
	local count = equipped and equipped.count or 0
	if #types > 0 then
		sawRealAmmo = true
	end
	if count == 0 and not sawRealAmmo then
		-- The bags may still be filling in (see above): a zero here is not
		-- trusted, and the next real change will speak up instead.
		return
	end
	local start = tonumber(ns.db.warnBelow) or 400
	local step = tonumber(ns.db.warnStep) or 50
	if step < 1 then
		step = 1
	end
	-- The next round number at or above the count, for example 350 when the
	-- count is 347; clamped so the starting number is always the first step.
	local level = math.ceil(count / step) * step
	if level > start then
		level = start
	end
	-- The first real look of the session: greet with the count when the
	-- greeting is on. It stands in for the first announcement (the number is
	-- right there in the line), and the staircase starts from this look, so
	-- the next spoken level is a genuine crossing.
	if not greetedThisSession then
		greetedThisSession = true
		if ns.db.greetOnLoad then
			ns.FireAmmoGreeting(kind, count)
			announcedLevel = level
			return
		end
	end
	if not ns.db.warnLowAmmo then
		-- Warnings switched off: the count was looked at for the greeting,
		-- and nothing else is said about it.
		announcedLevel = nil
		return
	end
	if count > start then
		-- Comfortably stocked: re-arm every step for the next slide down.
		announcedLevel = nil
		return
	end
	if announcedLevel == nil or level < announcedLevel then
		announcedLevel = level
		ns.FireLowAmmoWarning(kind, count)
	elseif level > announcedLevel then
		-- A small top-up (bought or looted a few): the staircase climbs
		-- with the ammo without a word, re-arming the steps above.
		announcedLevel = level
	end
end

-- Shows what a warning looks like, for the /ammonia warn command: the same
-- line the next real warning would speak, built from the live counts.
function ns.TestLowAmmoWarning()
	local kind = GetEquippedAmmoKind() or "bullet"
	local _, equipped = CollectAmmoTypes(kind)
	local count = equipped and equipped.count or 0
	ns.FireLowAmmoWarning(kind, count)
end

-- Prints what the client says about the carried ammo types and the equipped
-- pick, for checking the message counts in game with /ammonia ammo. Every
-- call is pcall-guarded, so it is safe to run on any client.
function ns.ReportEquippedAmmo()
	local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	local version = "?"
	if getMetadata then
		local ok, value = pcall(getMetadata, addonName, "Version")
		if ok and value then
			version = value
		end
	end
	ns.Print("Ammonia "..version.." ammo report:")
	local kind = GetEquippedAmmoKind()
	ns.Print("weapon fires: "..tostring(kind))
	local types = {}
	local equipped
	if kind then
		types, equipped = CollectAmmoTypes(kind)
	end
	local slotItemID = GetAmmoSlotItemID()
	local slotName
	if slotItemID then
		slotName = SafeGetItemInfo(slotItemID)
	end
	ns.Print("ammo slot: "..tostring(slotName or slotItemID).." x"..tostring(GetAmmoSlotCount()))
	local how = "guess"
	if equipped then
		if slotItemID and equipped.key == slotItemID then
			how = "slot"
		elseif observedEquipped[kind] == equipped.key then
			how = "seen"
		end
	end
	ns.Print("equipped count: "..tostring(equipped and equipped.count).." ("..how..")")
	if #types > 0 then
		local parts = {}
		for _, entry in ipairs(types) do
			local mark = (entry == equipped) and " (equipped)" or ""
			parts[#parts + 1] = FormatCount(entry.count).." "..tostring(entry.name or "?")..mark
		end
		ns.Print("types: "..table.concat(parts, ", "))
	end
	local arrows, bullets = CountCarriedAmmo()
	ns.Print("carried: "..tostring(arrows).." arrows, "..tostring(bullets).." bullets")
	local lastBag = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)
	if C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo then
		for bag = 0, lastBag do
			local numSlots = C_Container.GetContainerNumSlots(bag)
			if numSlots and numSlots > 0 then
				for slot = 1, numSlots do
					local info = C_Container.GetContainerItemInfo(bag, slot)
					if info then
						local slotKind = ClassifyAmmo(info.itemID, info.hyperlink)
						if slotKind then
							ns.Print("bag "..bag.." slot "..slot..": x"..tostring(info.stackCount or 1).." "..tostring(info.hyperlink or info.itemID).." ("..slotKind..")")
						end
					end
				end
			end
		end
	end
end

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

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

-- One frame listens for everything. ADDON_LOADED arrives first and is where
-- the saved settings are read; the rest are the moments that matter to the
-- reminders (login, equipment and vendors) or the ammo count (bags changing).
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_UPDATE")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
local function HandleAmmoniaEvent(self, event, ...)
	if event == "ADDON_LOADED" then
		local loadedAddon = ...
		if loadedAddon ~= addonName then
			return
		end
		self:UnregisterEvent("ADDON_LOADED")
		AmmoniaDB = AmmoniaDB or {}
		ns.db = AmmoniaDB
		ApplyDefaults(ns.db, DEFAULTS)
		-- The icon used to be draggable anywhere; it now rides the minimap's
		-- edge. Old saves get the new starting angle once (not in DEFAULTS,
		-- so ApplyDefaults above cannot set it first), which also keeps it
		-- off the spots Tongues and Tally start on.
		if (ns.db.icon.ringRevision or 0) < 2 then
			ns.db.icon.ringRevision = 2
			ns.db.icon.angle = 180
		end
		if ns.BuildUI then
			ns.BuildUI()
		end
		return
	end
	if event == "PLAYER_LOGOUT" then
		-- The chime nudges the dialog volume and puts it back a moment
		-- later. Reloading or quitting inside that brief window would
		-- leave the nudge behind (the game saves volume settings right
		-- away), so the original comes back before the session ends.
		if originalDialogVolume ~= nil and pendingRestores > 0 then
			pcall(SetCVar, "Sound_DialogVolume", originalDialogVolume)
		end
		return
	end
	if not ns.db then
		return
	end
	if event == "MERCHANT_SHOW" then
		-- Every vendor opening gets a fresh reminder.
		remindedThisVendor = false
		lowAmmoWarnedThisVendor = false
		ns.TryReminder()
		ScheduleMerchantAmmoCheck()
	elseif event == "MERCHANT_UPDATE" then
		-- The merchant's item list can arrive a moment after the window
		-- opens, so the check runs here too.
		ns.TryReminder()
		ScheduleMerchantAmmoCheck()
	elseif event == "MERCHANT_CLOSED" then
		merchantAmmoCheckGeneration = merchantAmmoCheckGeneration + 1
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Covers logging in or zoning while the ammo is already low.
		ns.CheckLowAmmo()
		ScheduleMissingAmmoCheck(false)
		-- The minimap has its real size by now: put the icon back on its
		-- ring at the saved angle (the first apply can run before layout).
		if ns.ApplyIconPosition then
			ns.ApplyIconPosition()
		end
	elseif event == "BAG_UPDATE" then
		-- Shooting, looting and buying all end up here.
		ns.CheckLowAmmo()
	elseif event == "UNIT_INVENTORY_CHANGED" then
		local unit = ...
		if unit == "player" then
			-- Swapping weapons can change which ammo is being counted.
			ns.CheckLowAmmo()
			ScheduleMissingAmmoCheck(true)
		end
	end
end

local eventFailuresReported = {}
eventFrame:SetScript("OnEvent", function(self, event, ...)
	local ok = pcall(HandleAmmoniaEvent, self, event, ...)
	if not ok and not eventFailuresReported[event] then
		eventFailuresReported[event] = true
		ns.Print("An internal "..tostring(event).." check failed; Ammonia skipped it without interrupting the game.")
	end
end)

-- A quiet safety net for clients that only refresh bag counts in bursts
-- instead of on every shot: look once a second as a backup. The warnings
-- still only speak when a new step is crossed, so nothing here ever turns
-- into a message on a timer.
local watchFrame = CreateFrame("Frame")
local watchElapsed = 0
watchFrame:SetScript("OnUpdate", function(_, delta)
	watchElapsed = watchElapsed + delta
	if ns.db and ns.db.enabled and ns.db.remindMissingAmmo then
		missingAmmoRepeatElapsed = missingAmmoRepeatElapsed + delta
		if missingAmmoRepeatElapsed >= 300 then
			missingAmmoRepeatElapsed = 0
			pcall(ns.CheckEquippedAmmo, true)
		end
	else
		missingAmmoRepeatElapsed = 0
	end
	if watchElapsed < 1 then
		return
	end
	watchElapsed = 0
	if ns.db and ns.db.enabled and (ns.db.warnLowAmmo or ns.db.greetOnLoad) then
		pcall(ns.CheckLowAmmo)
	end
end)

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

-- /ammonia and friends: the window, the on/off switch, a try-out of the
-- reminder and of a low ammo warning, and the icon position reset.
local function HandleSlash(message)
	if not ns.db then
		return
	end
	local command = string.lower(ns.Trim(message))
	if command == "" or command == "options" or command == "config" then
		ns.ToggleOptions()
	elseif command == "on" then
		ns.SetEnabled(true)
	elseif command == "off" then
		ns.SetEnabled(false)
	elseif command == "toggle" then
		ns.SetEnabled(not ns.db.enabled)
	elseif command == "test" then
		ns.FireReminder()
	elseif command == "warn" then
		ns.TestLowAmmoWarning()
	elseif command == "ammo" then
		ns.ReportEquippedAmmo()
	elseif command == "vendors" then
		ns.db.vendorReminder = not ns.db.vendorReminder
		if ns.RefreshOptions then
			ns.RefreshOptions()
		end
		ns.Print(ns.db.vendorReminder and "Ammo-vendor reminders on." or "Ammo-vendor reminders off.")
	elseif command == "missing" then
		ns.SetMissingAmmoReminderEnabled(not ns.db.remindMissingAmmo)
		if ns.RefreshOptions then
			ns.RefreshOptions()
		end
		ns.Print(ns.db.remindMissingAmmo and "Missing-ammo reminders on." or "Missing-ammo reminders off.")
	elseif command == "vendorwarn" then
		ns.db.vendorLowAmmo = not ns.db.vendorLowAmmo
		if ns.RefreshOptions then
			ns.RefreshOptions()
		end
		ns.Print(ns.db.vendorLowAmmo and "Low-ammo warnings at other vendors on." or "Low-ammo warnings at other vendors off.")
	elseif command == "reset" or command == "resetpos" then
		ns.ResetIconPosition()
		ns.Print("Icon position reset.")
	else
		ns.Print("Commands: /ammonia, on, off, toggle, test, warn, ammo, vendors, missing, vendorwarn, reset")
	end
end

SLASH_AMMONIA1 = "/ammonia"
local slashFailureReported = false
SlashCmdList["AMMONIA"] = function(message)
	local ok = pcall(HandleSlash, message)
	if not ok and not slashFailureReported then
		slashFailureReported = true
		ns.Print("An internal slash command failed; Ammonia skipped it without interrupting the game.")
	end
end
