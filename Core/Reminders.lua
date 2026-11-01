-- Ammonia - the reminder engine: vendors, missing ammo, low-ammo steps and
-- the login greeting.
local addonName, ns = ...

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
	if not ns.HasRangedWeaponEquipped() then
		return
	end
	if not ns.MerchantSellsAmmo() then
		return
	end
	remindedThisVendor = true
	lastReminder = GetTime()
	ns.FireReminder()
end

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



local missingAmmoCheckGeneration = 0
local missingAmmoReminded = false
local missingAmmoRepeatElapsed = 0
local merchantAmmoCheckGeneration = 0



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
	local kind = ns.GetEquippedAmmoKind()
	if not kind then
		missingAmmoReminded = false
		return
	end
	if ns.HasCompatibleAmmoEquipped(kind) then
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
	if itemCount <= 0 or ns.MerchantSellsAmmo() then
		return
	end
	local kind, _, equipped = ns.GetFiringAmmo()
	if not kind then
		return
	end
	local count = equipped and equipped.count or 0
	if count > (tonumber(ns.db.warnBelow) or 400) then
		return
	end
	lowAmmoWarnedThisVendor = true
	local colour = ns.GetMessageColour()
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("You're low on Ammo, find a merchant that sells it", colour.r, colour.g, colour.b)
	end
	-- Same chime as the other vendor and missing-ammo reminders, so a low
	-- warning at the wrong vendor is not the one silent message.
	ns.PlayChime()
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

-- Posts one warning line in the saved chat colour. The count in the message
-- is the real count, which is usually a little below the level itself (the
-- first step below 400 might catch you at 397). Hitting zero gets its own
-- louder wording.
function ns.FireLowAmmoWarning(kind, count)
	local text
	if count == 0 then
		text = "You are out of "..ns.AmmoLabel(kind, count).."!"
	else
		text = "Low ammo: "..ns.AmmoAmountText(kind, count)
	end
	local colour = ns.GetMessageColour()
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(text, colour.r, colour.g, colour.b)
	end
end

-- The friendly line shown once per session, the first time a real ammo
-- count is seen: "Ammonia enabled - You have 1,183 bullets left".
function ns.FireAmmoGreeting(kind, count)
	local text = "Ammonia enabled - You have "..ns.AmmoAmountText(kind, count)
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
	local kind, types, equipped = ns.GetFiringAmmo()
	if not kind then
		announcedLevel = nil
		return
	end
	-- The warnings count the firing type: the bullets the gun will use up
	-- next, not the grand total over every type carried.
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
	local kind, _, equipped = ns.GetFiringAmmo()
	kind = kind or "bullet"
	local count = equipped and equipped.count or 0
	ns.FireLowAmmoWarning(kind, count)
end

------------------------------------------------------------------------------
-- Entry points the event file calls.
------------------------------------------------------------------------------
ns.ScheduleMissingAmmoCheck = ScheduleMissingAmmoCheck

function ns.OnMerchantShow()
	remindedThisVendor = false
	lowAmmoWarnedThisVendor = false
	ns.TryReminder()
	ScheduleMerchantAmmoCheck()
end

function ns.OnMerchantUpdate()
	ns.TryReminder()
	ScheduleMerchantAmmoCheck()
end

function ns.OnMerchantClosed()
	merchantAmmoCheckGeneration = merchantAmmoCheckGeneration + 1
end

-- The one-second watch in Events.lua calls this; the five-minute repeat lives
-- here with the rest of the missing-ammo state.
function ns.TickMissingAmmo(delta)
	if not ns.db or not ns.db.enabled or not ns.db.remindMissingAmmo then
		missingAmmoRepeatElapsed = 0
		return
	end
	missingAmmoRepeatElapsed = missingAmmoRepeatElapsed + (tonumber(delta) or 0)
	if missingAmmoRepeatElapsed >= 300 then
		missingAmmoRepeatElapsed = 0
		pcall(ns.CheckEquippedAmmo, true)
	end
end
