-- Ammonia - ammo detection, counting and the /ammonia ammo report.
local addonName, ns = ...

-- FormatCount and the other shared helpers live in Core.lua, which loads
-- before this file.
local FormatCount = ns.FormatCount

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

local function HasCompatibleAmmoEquipped(kind)
	local itemID = GetAmmoSlotItemID()
	return itemID ~= nil and GetAmmoSlotCount() ~= nil and ClassifyAmmo(itemID) == kind
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

------------------------------------------------------------------------------
-- Public surface for the reminder engine.
------------------------------------------------------------------------------
ns.GetEquippedAmmoKind = GetEquippedAmmoKind
ns.HasRangedWeaponEquipped = HasRangedWeaponEquipped
ns.MerchantSellsAmmo = MerchantSellsAmmo
ns.HasCompatibleAmmoEquipped = HasCompatibleAmmoEquipped
ns.AmmoAmountText = AmmoAmountText
ns.AmmoLabel = AmmoLabel

-- The kind of ammo the equipped weapon fires, plus the carried types and
-- the one currently being fired. Nil when no ranged weapon is equipped.
function ns.GetFiringAmmo()
	local kind = GetEquippedAmmoKind()
	if not kind then
		return nil
	end
	local types, equipped = CollectAmmoTypes(kind)
	return kind, types, equipped
end
