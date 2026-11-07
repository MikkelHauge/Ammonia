-- Ammonia - ammo use counter. One count per shot or ranged ability use,
-- stored per character and per ammo item, and shown at the bottom of the
-- settings window.
local addonName, ns = ...

local frame = CreateFrame("Frame")
local playerGUID

-- Ranged abilities that consume ammo but whose names do not contain "shot".
-- Every hunter ability that does end in "Shot", so the substring check below
-- also catches ranks and spells this list has never heard of.
local SHOT_NAMES = {
	["serpent sting"] = true,
	["volley"] = true,
	["wyvern sting"] = true,
	["black arrow"] = true,
}

local function IsShotSpell(name)
	if not name then
		return false
	end
	local lower = string.lower(name)
	if lower == "auto shot" then
		-- Auto Shot is counted from its RANGE_DAMAGE event. Some clients also
		-- fire a cast-success for it; counting both would double every shot.
		return false
	end
	if SHOT_NAMES[lower] then
		return true
	end
	return string.find(lower, "shot", 1, true) ~= nil
end

-- This client passes the combat-log tuple straight to the handler; others
-- only expose it through an accessor. Try both, the same way Tally does.
local function ReadCombatLog(...)
	if select("#", ...) >= 2 and type(select(2, ...)) == "string" then
		return ...
	end
	local readers = {
		C_CombatLogSecure and C_CombatLogSecure.GetCurrentEventInfo,
		C_CombatLog and C_CombatLog.GetCurrentEventInfo,
		CombatLogGetCurrentEventInfo,
	}
	for index = 1, 3 do
		local reader = readers[index]
		if type(reader) == "function" then
			local ok, timestamp, subevent, hideCaster, sourceGUID, sourceName,
				sourceFlags, sourceRaidFlags, destGUID, destName, destFlags,
				destRaidFlags, spellID, spellName = pcall(reader)
			if ok and type(subevent) == "string" then
				return timestamp, subevent, hideCaster, sourceGUID, sourceName,
					sourceFlags, sourceRaidFlags, destGUID, destName, destFlags,
					destRaidFlags, spellID, spellName
			end
		end
	end
end

local function CurrentGUID()
	if not playerGUID and type(UnitGUID) == "function" then
		playerGUID = UnitGUID("player")
	end
	return playerGUID
end

local function CharacterKey()
	local name = UnitName and UnitName("player")
	if not name then
		return nil
	end
	local realm = GetRealmName and GetRealmName()
	return tostring(name).."-"..tostring(realm or "?")
end

-- The saved counter table for the character currently logged in.
local function ShotsForCharacter()
	if type(ns.db) ~= "table" then
		return nil
	end
	local key = CharacterKey()
	if not key then
		return nil
	end
	if type(ns.db.shots) ~= "table" then
		ns.db.shots = {}
	end
	local mine = ns.db.shots[key]
	if type(mine) ~= "table" then
		mine = {}
		ns.db.shots[key] = mine
	end
	return mine
end

-- Called once for every shot or ranged ability use. The ammo slot names the
-- type being consumed at that moment, so the count lands on the right arrow
-- or bullet even when the player switches types between shots.
local function CountShot()
	-- Auto Shot reports the same range event for a thrown weapon, which uses
	-- no ammo. Only count while a bow, gun or crossbow is equipped.
	if not (ns.HasRangedWeaponEquipped and ns.HasRangedWeaponEquipped()) then
		return
	end
	local itemID, name, kind = ns.GetEquippedAmmoInfo and ns.GetEquippedAmmoInfo()
	if not itemID then
		return
	end
	local mine = ShotsForCharacter()
	if not mine then
		return
	end
	local entry = mine[itemID]
	if type(entry) ~= "table" then
		entry = { count = 0, first = time() }
		mine[itemID] = entry
	end
	entry.count = (tonumber(entry.count) or 0) + 1
	entry.name = name or entry.name
	entry.kind = kind or entry.kind
	entry.last = time()
	-- Keep an open settings window current without waiting for a reopen.
	if ns.RefreshShotCounters then
		pcall(ns.RefreshShotCounters)
	end
end

local function HandleCombatLog(...)
	local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags,
		sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, spellID,
		spellName = ReadCombatLog(...)
	if not subevent then
		return
	end
	if subevent ~= "RANGE_DAMAGE" and subevent ~= "RANGE_MISSED"
		and subevent ~= "SPELL_CAST_SUCCESS" then
		return
	end
	local guid = CurrentGUID()
	if not guid or sourceGUID ~= guid then
		return
	end
	if subevent == "SPELL_CAST_SUCCESS" and not IsShotSpell(spellName) then
		return
	end
	CountShot()
end

frame:SetScript("OnEvent", function(_, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		HandleCombatLog(...)
	else
		-- A fresh login can hand out a new GUID; do not keep the old one.
		playerGUID = nil
	end
end)

pcall(frame.RegisterEvent, frame, "PLAYER_LOGIN")
pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")
local ok = pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
if not ok then
	ns.ShotsUnavailable = true
end

-- Sorted snapshot for the settings panel: one row per ammo item, plus the
-- arrow and bullet totals for the current character.
function ns.GetShotStats()
	local mine = ShotsForCharacter()
	local list = {}
	local arrows, bullets = 0, 0
	if mine then
		for itemID, entry in pairs(mine) do
			local count = tonumber(entry.count) or 0
			if count > 0 then
				list[#list + 1] = {
					itemID = itemID,
					name = entry.name,
					kind = entry.kind,
					count = count,
					last = entry.last,
				}
				if entry.kind == "arrow" then
					arrows = arrows + count
				elseif entry.kind == "bullet" then
					bullets = bullets + count
				end
			end
		end
	end
	table.sort(list, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return tostring(a.name or a.itemID) < tostring(b.name or b.itemID)
	end)
	return { list = list, arrows = arrows, bullets = bullets, total = arrows + bullets }
end

-- /ammonia shots: the current character's totals and the combat-log state,
-- for checking the counter in game.
function ns.ReportShots()
	local stats = ns.GetShotStats()
	local who = CharacterKey() or "this character"
	ns.Print("ammo use for "..who..": "..ns.FormatCount(stats.total).." uses")
	ns.Print("arrows: "..ns.FormatCount(stats.arrows)..", bullets: "..ns.FormatCount(stats.bullets))
	if #stats.list == 0 then
		ns.Print("no ammo use recorded yet")
	else
		for _, entry in ipairs(stats.list) do
			ns.Print(tostring(entry.name or ("Ammo #"..tostring(entry.itemID)))
				..": "..ns.FormatCount(entry.count).." ("..tostring(entry.kind or "?")..")")
		end
	end
	local accessor = "none"
	if C_CombatLogSecure and C_CombatLogSecure.GetCurrentEventInfo then
		accessor = "C_CombatLogSecure"
	elseif C_CombatLog and C_CombatLog.GetCurrentEventInfo then
		accessor = "C_CombatLog"
	elseif CombatLogGetCurrentEventInfo then
		accessor = "CombatLogGetCurrentEventInfo"
	end
	if ns.ShotsUnavailable then
		accessor = accessor.." (event refused)"
	end
	ns.Print("combat log: "..accessor)
end
