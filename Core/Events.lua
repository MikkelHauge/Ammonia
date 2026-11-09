-- Ammonia - events, the one-second watch and slash commands.
local addonName, ns = ...

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_UPDATE")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_LOGOUT")

local function HandleAmmoniaEvent(self, event, ...)
	if event == "ADDON_LOADED" then
		local loadedAddon = ...
		if loadedAddon ~= addonName then
			return
		end
		self:UnregisterEvent("ADDON_LOADED")
		if type(AmmoniaDB) ~= "table" then
			AmmoniaDB = {}
		end
		ns.db = AmmoniaDB
		ns.ApplyDefaults(ns.db, ns.DEFAULTS)
		-- The old single low-ammo switch became the warnWhen dropdown: keep
		-- an explicit "off" for saves that had warnings disabled.
		if ns.db.warnWhenRevision ~= 1 then
			ns.db.warnWhenRevision = 1
			if ns.db.warnLowAmmo == false then
				ns.db.warnWhen = "off"
			elseif ns.db.warnWhen ~= "combat" and ns.db.warnWhen ~= "out"
				and ns.db.warnWhen ~= "off" then
				ns.db.warnWhen = "both"
			end
		end
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
		-- A /reload on this client raises only ADDON_LOADED, so the
		-- PLAYER_ENTERING_WORLD schedule never runs. Start the 15-second
		-- missing-ammo check here too; duplicate schedules are generation
		-- guarded.
		if ns.ScheduleMissingAmmoCheck then
			ns.ScheduleMissingAmmoCheck(true)
		end
		return
	end
	if event == "PLAYER_LOGOUT" then
		if ns.RestoreDialogVolume then
			ns.RestoreDialogVolume()
		end
		return
	end
	if not ns.db then
		return
	end
	if event == "MERCHANT_SHOW" then
		if ns.OnMerchantShow then
			ns.OnMerchantShow()
		end
	elseif event == "MERCHANT_UPDATE" then
		if ns.OnMerchantUpdate then
			ns.OnMerchantUpdate()
		end
	elseif event == "MERCHANT_CLOSED" then
		if ns.OnMerchantClosed then
			ns.OnMerchantClosed()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Covers logging in or zoning while the ammo is already low. The zone
		-- grace keeps a loading-screen zero from printing a false warning.
		if ns.NoteZoneChange then
			ns.NoteZoneChange()
		end
		ns.CheckLowAmmo()
		ns.ScheduleMissingAmmoCheck(false)
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
			ns.ScheduleMissingAmmoCheck(true)
		end
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		if ns.NoteZoneChange then
			ns.NoteZoneChange()
		end
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		-- Entering or leaving combat changes whether the low-ammo mode lets
		-- the staircase speak.
		ns.CheckLowAmmo()
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
	if ns.TickMissingAmmo then
		ns.TickMissingAmmo(delta)
	end
	watchElapsed = watchElapsed + delta
	if watchElapsed < 1 then
		return
	end
	watchElapsed = 0
	if ns.db and ns.db.enabled
		and ((ns.LowAmmoActive and ns.LowAmmoActive()) or ns.db.greetOnLoad) then
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
