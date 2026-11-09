-- Ammonia - the icon and the options window
-- (Core.lua at the top explains how the file header and the shared "ns"
-- table work; this file adds the visible bits on top of it.)
local addonName, ns = ...

-- Amber accent for the section headings in the window.
local ACCENT = { 1.0, 0.72, 0.25 }

-- The ammo icon: an arrow rather than the old bullet. The texture path is
-- used on its own - the file ID the first build passed was the bullet's, so
-- keeping it would have overridden this.
local ICON_PATH = "Interface\\Icons\\INV_Ammo_Arrow_01"

-- File-wide handles, so the helper functions and the slash commands can
-- reach the pieces that are created further down.
local optionsFrame
local iconButton
local iconTexture
local iconRing
local scrollHost      -- the window's viewport; clips whatever scrolls
local scrollContent   -- the tall frame inside it that actually moves
local scrollBar       -- the little bar on the right
local reminderEditBox -- the "Reminder text" box, re-synced on every open
local refreshers = {}

-- Reads the version straight from Ammonia.toc for the window title.
local function GetAddonVersion()
	local getMetadata = GetAddOnMetadata
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		getMetadata = C_AddOns.GetAddOnMetadata
	end
	if getMetadata then
		local ok, version = pcall(getMetadata, addonName, "Version")
		if ok and version then
			return version
		end
	end
	return "?"
end

-- Every setting control registers a small "read the saved value and show
-- it" function here; this is what re-syncs the whole window in one go.
local function RefreshAll()
	for index = 1, #refreshers do
		refreshers[index]()
	end
end
ns.RefreshOptions = RefreshAll

-------------------------------------------------------------------------------
-- Icon (rides the minimap edge, toggled with a right click)
-------------------------------------------------------------------------------

-- The icon rides the minimap's outer edge, the same way Tongues and Tally
-- do it: only the angle around the circle is saved, so it comes back to the
-- same spot after a reload. Read as a clock face, the three addons sit at
-- 11 (Tongues), 9 (Ammonia) and 7 (Tally) o'clock down the left side.
local ICON_DEFAULT_ANGLE = 180
local ICON_LEEWAY = 10

-- How far from the middle of the minimap the icon's middle belongs. Worked
-- out whenever it is used, so a resized minimap still gets a ring that hugs
-- its edge; 140 is only the fallback before the minimap is laid out.
local function IconRingRadius()
	local width = Minimap:GetWidth()
	if not width or width <= 0 then
		width = 140
	end
	return width / 2 + ICON_LEEWAY
end

-- Puts the icon where the saved angle says it belongs.
local function ApplyIconPosition()
	if not iconButton then
		return
	end
	local angle = math.rad(ns.db.icon.angle or ICON_DEFAULT_ANGLE)
	local radius = IconRingRadius()
	iconButton:ClearAllPoints()
	iconButton:SetParent(Minimap)
	iconButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end
-- Shared, so Core.lua can put it back once the minimap has its real size.
ns.ApplyIconPosition = ApplyIconPosition

-- Back to the default spot around the minimap (the window's reset button
-- and /ammonia reset both call this).
function ns.ResetIconPosition()
	ns.db.icon.angle = ICON_DEFAULT_ANGLE
	ApplyIconPosition()
end

-- Shows or hides the icon. While reminders are off the ring drains from
-- gold to silver, so the state shows at a glance - the grey icon alone
-- cannot show it.
function ns.UpdateIconState()
	if not iconButton then
		return
	end
	iconButton:SetShown(ns.db.icon.shown and true or false)
	if iconTexture then
		iconTexture:SetDesaturated(not ns.db.enabled)
	end
	if iconRing then
		iconRing:SetDesaturated(not ns.db.enabled)
	end
end

-- Opens the options window, or closes it when it is already open.
function ns.ToggleOptions()
	if not optionsFrame then
		return
	end
	if optionsFrame:IsShown() then
		optionsFrame:Hide()
	else
		ns.PlayUISound("IG_MAINMENU_OPEN")
		RefreshAll()
		optionsFrame:Show()
	end
end

-- Puts the ammo texture on the icon. A plain texture path works on every
-- client this addon runs on, so there is no file-ID attempt any more.
local function ApplyAmmoIcon(texture)
	texture:SetTexture(ICON_PATH)
end

-- Builds the little button that rides the minimap.
local function CreateIconButton()
	local button = CreateFrame("Button", "AmmoniaIcon", Minimap)
	iconButton = button
	button:SetSize(32, 32)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:SetMovable(true)
	button:EnableMouse(true)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	-- The minimap-button look: decorative border, dark disc, icon on top.
	-- The border ring is kept as a handle: gold while reminders are on,
	-- silver while they are off.
	-- The classic minimap-button geometry, the same numbers LibDBIcon uses:
	-- the tracking border's ring sits in the upper-left of its 53 pixel
	-- texture, so the disc and the icon are offset down-right to line up with
	-- it. Centring them on the button instead left the icon off-centre in
	-- the ring and its square corners showing outside the circle.
	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetSize(53, 53)
	overlay:SetPoint("TOPLEFT", 0, 0)
	iconRing = overlay

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)

	iconTexture = button:CreateTexture(nil, "ARTWORK")
	ApplyAmmoIcon(iconTexture)
	iconTexture:SetSize(17, 17)
	iconTexture:SetPoint("TOPLEFT", 7, -6)
	iconTexture:SetTexCoord(0.05, 0.95, 0.05, 0.95)

	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	-- Dragging: the icon slides around the minimap's edge (unless locked).
	-- The cursor's direction from the middle of the minimap is the angle; the
	-- distance is always the ring, so one saved number brings it back after a
	-- reload and it cannot wander off screen.
	--
	-- Every press notes where it began and clears the "actually moved"
	-- flag: clients also deliver OnClick when a drag is released, and
	-- without the flag every move would end by opening the window.
	button:SetScript("OnMouseDown", function(self)
		local x, y = GetCursorPosition()
		self.pressX, self.pressY = x, y
		self.dragMoved = nil
	end)
	button:SetScript("OnDragStart", function(self)
		if ns.db.icon.locked then
			return
		end
		self:SetScript("OnUpdate", function()
			local x, y = GetCursorPosition()
			if not x then
				return
			end
			if self.pressX and math.abs(x - self.pressX) + math.abs(y - self.pressY) > 8 then
				self.dragMoved = true
			end
			-- Both the cursor and the minimap's middle are read in the
			-- minimap's own units, which is what its anchors use too.
			local scale = Minimap:GetEffectiveScale() or 1
			x, y = x / scale, y / scale
			local centerX, centerY = Minimap:GetCenter()
			if not centerX then
				return
			end
			local angle = math.deg(math.atan2(y - centerY, x - centerX))
			ns.db.icon.angle = angle
			local radius = IconRingRadius()
			self:ClearAllPoints()
			self:SetPoint("CENTER", Minimap, "CENTER",
				math.cos(math.rad(angle)) * radius, math.sin(math.rad(angle)) * radius)
		end)
	end)
	-- Dropping it: stop following the cursor; the saved angle stays put.
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	-- Right-click flips the reminders on or off; left-click opens the window.
	-- A release that ended a real drag is swallowed (see above).
	button:SetScript("OnClick", function(self, mouseButton)
		if self.dragMoved then
			return
		end
		if mouseButton == "RightButton" then
			ns.SetEnabled(not ns.db.enabled)
		else
			ns.ToggleOptions()
		end
	end)
	-- Tooltip: quick state readout plus the two click hints.
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Ammonia")
		if ns.db.enabled then
			GameTooltip:AddLine("Reminders are on.", 1, 1, 1)
		else
			GameTooltip:AddLine("Reminders are off.", 1, 1, 1)
		end
		GameTooltip:AddLine("Left-click: open the options.", 1, 1, 1)
		GameTooltip:AddLine("Right-click: "..(ns.db.enabled and "turn reminders off." or "turn reminders on."), 1, 1, 1)
		if ns.db.icon.locked then
			GameTooltip:AddLine("Position locked.", 1, 1, 1)
		else
			GameTooltip:AddLine("Drag it around the minimap to move it.", 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	ApplyIconPosition()
end

-------------------------------------------------------------------------------
-- Options window
-------------------------------------------------------------------------------

-- The settings list is taller than the window, so every row is drawn into
-- one tall frame (scrollContent) that lives inside a scroll frame
-- (scrollHost). The scroll frame clips the content to the window bounds, and
-- the content is then moved up and down by hand - the same way AceGUI moves
-- things for Prat's options. Bigger values move the content further up,
-- which is what reveals the rows below.

-- Moves the content so `value` (0 = top of the list, 1000 = bottom) points
-- into the list.
local function ApplyScroll(value)
	if not scrollHost or not scrollContent then
		return
	end
	if not value or value < 0 then
		value = 0
	elseif value > 1000 then
		value = 1000
	end
	local viewHeight = scrollHost:GetHeight() or 0
	local contentHeight = scrollContent:GetHeight() or 0
	local maxOffset = contentHeight - viewHeight
	local offset = 0
	if maxOffset > 0 then
		offset = math.floor(maxOffset / 1000 * value + 0.5)
	end
	scrollContent:ClearAllPoints()
	scrollContent:SetPoint("TOPLEFT", 0, offset)
	scrollContent:SetPoint("TOPRIGHT", 0, offset)
end

-- One mouse wheel notch moves about 100 pixels; the 0-1000 bar value is
-- worked out from how much content actually overflows.
local function ScrollWheel(delta)
	if not scrollHost or not scrollContent or not scrollBar or not scrollBar:IsShown() then
		return
	end
	local maxOffset = (scrollContent:GetHeight() or 0) - (scrollHost:GetHeight() or 0)
	if maxOffset <= 0 then
		return
	end
	local value = scrollBar:GetValue() - delta * (100 / maxOffset) * 1000
	if value < 0 then
		value = 0
	elseif value > 1000 then
		value = 1000
	end
	scrollBar:SetValue(value)
end

-- Shows the scroll bar only when the rows are taller than the window can
-- show, and parks the list at the top when everything fits.
local function UpdateScrollBar()
	if not scrollHost or not scrollContent or not scrollBar then
		return
	end
	local overflow = (scrollContent:GetHeight() or 0) > (scrollHost:GetHeight() or 0) + 2
	scrollBar:SetShown(overflow)
	if not overflow then
		scrollBar:SetValue(0)
	end
end

-- Builds the whole window, once, on the first login.
local function CreateOptionsFrame()
	local frame = CreateFrame("Frame", "AmmoniaFrame", UIParent, "BasicFrameTemplateWithInset")
	optionsFrame = frame
	frame:SetSize(480, 700)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()
	if frame.TitleText then
		frame.TitleText:SetText("Ammonia "..GetAddonVersion())
	end
	-- The stock title band is 18 pixels tall, shorter than the 22 pixel
	-- icon, so the icon used to hang over the inset and look like it was
	-- falling out of the bar. Give the band the icon's height, and put the
	-- icon on the overlay layer so the frame's own border art cannot cover
	-- it.
	if frame.TitleBg then
		frame.TitleBg:SetHeight(24)
	end
	local titleIcon = frame:CreateTexture(nil, "OVERLAY", nil, 1)
	titleIcon:SetSize(22, 22)
	titleIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -2)
	ApplyAmmoIcon(titleIcon)
	table.insert(UISpecialFrames, "AmmoniaFrame")

	-- Opening the window: fresh values everywhere, always start back at the
	-- top of the list, and make sure the text box really shows its text.
	frame:SetScript("OnShow", function()
		RefreshAll()
		if scrollBar then
			scrollBar:SetValue(0)
		end
		-- Setting the position right here - not only when the bar value
		-- changes - is what keeps the very first open correct: the bar
		-- starts at 0, so a plain SetValue(0) would never fire.
		ApplyScroll(0)
		-- The reminder text box gets a direct re-fill, straight away and
		-- once more a frame later (after the open layout has settled), so
		-- its text is there however a client treats text boxes while
		-- their window is hidden.
		local function SyncTextBox()
			if reminderEditBox and not reminderEditBox:HasFocus() then
				reminderEditBox:SetText(ns.db.reminderText or ns.DEFAULT_REMINDER_TEXT)
			end
		end
		SyncTextBox()
		if C_Timer and C_Timer.After then
			C_Timer.After(0, SyncTextBox)
		end
	end)

	-- The viewport. Everything drawn below is clipped to this rectangle.
	local host = CreateFrame("ScrollFrame", "AmmoniaScrollHost", frame)
	host:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -36)
	host:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 14)
	host:EnableMouse(true)
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, delta)
		ScrollWheel(delta)
	end)
	scrollHost = host

	-- The tall frame inside the viewport; every row is a child of this. It
	-- is handed to the scroll frame as its scroll child further down, once
	-- its real height is known - the order matters (see there).
	local content = CreateFrame("Frame", "AmmoniaScrollContent", host)
	content:SetPoint("TOPLEFT", 0, 0)
	content:SetPoint("TOPRIGHT", 0, 0)
	content:SetHeight(1)
	scrollContent = content

	-- Blizzard's scroll bar template wants a scroll frame as its parent (its
	-- built-in handler leans on methods only scroll frames have). The look
	-- is free with it; the value handler is pointed at our own content
	-- movement instead. The handler is set last, so nothing fires through
	-- the template default while the starting values are put in place.
	local bar = CreateFrame("Slider", "AmmoniaScrollBar", host, "UIPanelScrollBarTemplate")
	bar:SetPoint("TOPLEFT", host, "TOPRIGHT", 6, -16)
	bar:SetPoint("BOTTOMLEFT", host, "BOTTOMRIGHT", 6, 16)
	bar:SetWidth(16)
	bar:SetMinMaxValues(0, 1000)
	bar:SetValueStep(1)
	bar:SetValue(0)
	bar:SetScript("OnValueChanged", function(_, value)
		ApplyScroll(value)
	end)
	scrollBar = bar

	-- The writing position, walked down the page as rows are added. It is
	-- always a negative number of pixels from the top of the content.
	local y = -10

	-- One line of small grey text, used when the client cannot measure a
	-- font string for us.
	local SMALL_LINE = 12

	-- How tall a wrapped piece of text turned out to be. GetStringHeight is
	-- the real answer; the width-based estimate covers clients without it.
	-- This is what keeps rows from overlapping when a note wraps to a
	-- second line.
	local function TextHeight(fontString, fallback)
		local height = fontString.GetStringHeight and fontString:GetStringHeight()
		if height and height > 0 then
			return height
		end
		local width = fontString.GetStringWidth and fontString:GetStringWidth()
		if width and width > 0 then
			return math.ceil(width / 400) * SMALL_LINE
		end
		return fallback or SMALL_LINE
	end

	-- Short grey explanation under a setting. Returns the font string so the
	-- caller can measure it before placing the next row.
	local function AddNote(parent, point, text)
		local note = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		note:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, point)
		note:SetWidth(400)
		note:SetJustifyH("LEFT")
		note:SetTextColor(0.58, 0.58, 0.58)
		note:SetText(text)
		return note
	end

	-- One checkbox setting: a title line, the box itself on the right and an
	-- optional explanation under the title. The next row is placed below
	-- whatever the explanation really took up, so a wrapped note pushes the
	-- following row down instead of being overlapped by it.
	local function AddCheckboxRow(parent, title, descText, getter, setter)
		local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
		label:SetText(title)

		local checkbox = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
		checkbox:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y + 2)

		local note
		if descText then
			note = AddNote(parent, y - 15, descText)
		end

		-- Clicking the box flips the matching saved setting and plays the
		-- little tick sound the game uses everywhere.
		checkbox:SetScript("OnClick", function(self)
			local checked = self:GetChecked() and true or false
			if checked then
				ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
			else
				ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_OFF")
			end
			setter(checked)
		end)
		-- Re-read the saved value whenever the window refreshes.
		table.insert(refreshers, function()
			checkbox:SetChecked(getter() and true or false)
		end)

		if note then
			y = y - 15 - TextHeight(note) - 15
		else
			y = y - 26
		end
		return checkbox
	end

	-- One dropdown setting, drawn with Blizzard's own menu frames. The
	-- dropdown itself is 32 pixels tall, so the block is measured from its
	-- top edge: title line, menu, then an optional explanation under it.
	local function AddDropdownRow(parent, labelText, descText, getEntries, getSelectedKey, setSelectedKey)
		local blockTop = y

		local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, blockTop)
		label:SetText(labelText)

		local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
		dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, blockTop - 10)
		UIDropDownMenu_SetWidth(dropdown, 220)

		-- Finds the chosen entry so the closed menu can show its label.
		local function FindEntry(key)
			for _, entry in ipairs(getEntries()) do
				if entry.key == key then
					return entry
				end
			end
			return nil
		end

		-- Puts the chosen entry's label on the closed menu button.
		local function UpdateText()
			local entry = FindEntry(getSelectedKey())
			UIDropDownMenu_SetText(dropdown, entry and (entry.text or entry.label) or "?")
		end

		-- The menu is rebuilt from the live entry list every time it opens,
		-- so entries that depend on the client (like the chime sounds) are
		-- always accurate.
		UIDropDownMenu_Initialize(dropdown, function()
			for _, entry in ipairs(getEntries()) do
				local info = UIDropDownMenu_CreateInfo()
				info.text = entry.text or entry.label
				info.checked = (entry.key == getSelectedKey())
				info.func = function()
					setSelectedKey(entry.key)
					UpdateText()
					ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
				end
				UIDropDownMenu_AddButton(info)
			end
		end)

		UpdateText()
		table.insert(refreshers, UpdateText)

		if descText then
			local note = AddNote(parent, blockTop - 45, descText)
			y = blockTop - 45 - TextHeight(note) - 15
		else
			y = blockTop - 56
		end
		return dropdown
	end

	-- One slider setting: title with the current value in brackets, a track,
	-- and the two ends left blank (the numbers are in the title).
	local function AddSliderRow(parent, title, minValue, maxValue, step, getter, setter, formatValue, allowEdit, editHint)
		local slider = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
		slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, y - 16)
		slider:SetWidth(320)
		slider:SetMinMaxValues(minValue, maxValue)
		slider:SetValueStep(step)
		if slider.SetObeyStepOnDrag then
			slider:SetObeyStepOnDrag(true)
		end
		if slider.Low then
			slider.Low:SetText("")
		end
		if slider.High then
			slider.High:SetText("")
		end

		-- How the value reads in the title; a plain number unless the caller
		-- brings its own wording ("80%", "30 seconds").
		local function Format(value)
			if formatValue then
				return formatValue(value)
			end
			return tostring(math.floor(value + 0.5))
		end

		local function Raw(value)
			return tostring(math.floor((tonumber(value) or minValue) + 0.5))
		end

		-- The optional box on the right takes an exact number, including ones
		-- the slider's step cannot land on. It always clamps to min..max.
		local editBox
		local function UpdateTitle(value)
			if slider.Text then
				slider.Text:SetText(title.."  ("..Format(value)..")")
			end
			if editBox and not editBox:HasFocus() then
				editBox:SetText(Raw(value))
			end
		end

		-- Dragging the slider writes the setting straight away. The
		-- "updating" flag keeps refreshers from bouncing straight back into
		-- the setter while they move the thumb themselves.
		local updating = false
		local function ApplyValue(value)
			local number = tonumber(value)
			if not number then
				-- An empty box (or a lost focus mid-edit) keeps the setting
				-- rather than silently dropping it to the minimum.
				UpdateTitle(tonumber(getter()) or minValue)
				return
			end
			value = math.floor(number + 0.5)
			if value < minValue then
				value = minValue
			elseif value > maxValue then
				value = maxValue
			end
			setter(value)
			updating = true
			slider:SetValue(value)
			updating = false
			UpdateTitle(value)
			return value
		end

		slider:SetScript("OnValueChanged", function(_, value)
			if updating then
				return
			end
			value = tonumber(value)
			if not value then
				return
			end
			setter(value)
			UpdateTitle(value)
		end)

		if allowEdit then
			editBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
			editBox:SetSize(78, 20)
			editBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 352, y - 12)
			editBox:SetAutoFocus(false)
			if editBox.SetNumeric then
				editBox:SetNumeric(true)
			end
			editBox:SetMaxLetters(6)
			editBox:SetJustifyH("CENTER")
			editBox:SetText(Raw(getter()))
			editBox:SetScript("OnEnterPressed", function(self)
				ApplyValue(self:GetText())
				self:ClearFocus()
			end)
			editBox:SetScript("OnEditFocusLost", function(self)
				ApplyValue(self:GetText())
			end)
			editBox:SetScript("OnEscapePressed", function(self)
				UpdateTitle(tonumber(getter()) or minValue)
				self:ClearFocus()
			end)
			editBox:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(title, ACCENT[1], ACCENT[2], ACCENT[3])
				GameTooltip:AddLine("Type any number from "..minValue.." to "..maxValue..".", 1, 1, 1, true)
				if editHint then
					GameTooltip:AddLine(editHint, 0.7, 0.7, 0.7, true)
				end
				GameTooltip:Show()
			end)
			editBox:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
		end

		table.insert(refreshers, function()
			updating = true
			local value = tonumber(getter())
			if not value or value < minValue then
				value = minValue
			elseif value > maxValue then
				value = maxValue
			end
			slider:SetValue(value)
			UpdateTitle(value)
			updating = false
		end)

		y = y - 50
		return slider
	end

	-- About
	local header = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	header:SetText("Ammo reminder")
	header:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	y = y - 20

	local info = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", content, "TOPLEFT", 18, y)
	info:SetWidth(410)
	info:SetJustifyH("LEFT")
	info:SetText("Ammonia watches the vendors you visit. When one sells ammo and you have a bow, crossbow or gun equipped, it reminds you to restock - in chat, with a chime, or both. It can count your ammo and warn you as it runs low. Right-click the icon to switch it on or off.")
	y = y - TextHeight(info, 51) - 12

	AddCheckboxRow(content, "Enable Ammonia",
		"The master switch. Right-clicking the icon does the same.",
		function() return ns.db.enabled end,
		function(value) ns.SetEnabled(value) end)

	AddCheckboxRow(content, "Text reminders",
		"Show reminder text in your chat frame. This is the master text switch.",
		function() return ns.db.chatAlert end,
		function(value) ns.db.chatAlert = value end)

	AddCheckboxRow(content, "Audio reminders",
		"Play the selected chime for reminders. This is the master sound switch.",
		function() return ns.db.chimeAlerts ~= false end,
		function(value) ns.db.chimeAlerts = value end)

	AddCheckboxRow(content, "Show ammo count",
		"Adds the ammo you are carrying to the reminder and the missing-ammo line (Bullets: 342).",
		function() return ns.db.showAmmoCount end,
		function(value) ns.db.showAmmoCount = value end)

	AddCheckboxRow(content, "Greet on login",
		"Greets you in chat with your ammo count on login or reload.",
		function() return ns.db.greetOnLoad end,
		function(value) ns.db.greetOnLoad = value end)

	AddCheckboxRow(content, "Remind me when ammo is missing",
		"When a bow, gun or crossbow is equipped with no compatible ammo in the ammo slot. Repeats every five minutes while it stays empty.",
		function() return ns.db.remindMissingAmmo end,
		function(value) ns.SetMissingAmmoReminderEnabled(value) end)

	AddDropdownRow(content, "Low ammo warnings",
		"Controls the Warn at / Warn every steps below. 'Disable warnings' keeps their values but stops the messages. 'In Combat' and 'Out of Combat' refer to your character.",
		function()
			return {
				{ key = "both", text = "Both" },
				{ key = "combat", text = "In Combat" },
				{ key = "out", text = "Out of Combat" },
				{ key = "off", text = "|cffff5555Disable warnings|r" },
			}
		end,
		function() return ns.db.warnWhen or "both" end,
		function(value) ns.db.warnWhen = value end)

	-- The warning staircase: where it starts and how far apart the steps
	-- are. For example 400 with a step of 50 warns at 400, 350, 300 ...
	-- 20,000 is 100 stacks of 200, more than a character can carry in ammo
	-- next to the rest of their bags. The box on the right takes any exact
	-- number, so the slider step does not limit the setting.
	AddSliderRow(content, "Warn at", 0, 20000, 50,
		function() return ns.db.warnBelow end,
		function(value) ns.db.warnBelow = math.floor(value + 0.5) end,
		nil, true, "0 warns only when the quiver is empty.")

	AddSliderRow(content, "Warn every", 0, 2000, 10,
		function() return ns.db.warnStep end,
		function(value) ns.db.warnStep = math.floor(value + 0.5) end,
		nil, true, "0 gives the first warning only, with no repeats on the way down.")

	AddCheckboxRow(content, "Warn at other vendors",
		"When a vendor that does not sell ammo opens, remind you that this one cannot help. It only reads the stock of the vendor you have open; it does not know where another one is. Part of the low-ammo warnings above.",
		function() return ns.db.vendorLowAmmo end,
		function(value) ns.db.vendorLowAmmo = value end)

	-- The vendor reminder's own switch. It sits next to the text it uses, so
	-- the pair reads as one setting: whether it speaks, and what it says.
	AddCheckboxRow(content, "Remind me at ammo vendors",
		"The 'buy ammo' line when a vendor that sells ammo opens. Off leaves the low-ammo warnings and the missing-ammo line alone.",
		function() return ns.db.vendorReminder end,
		function(value) ns.db.vendorReminder = value end)

	-- Reminder text
	local textLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	textLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	textLabel:SetText("Reminder text")
	y = y - 18

	local editBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
	editBox:SetSize(210, 24)
	editBox:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	editBox:SetAutoFocus(false)
	editBox:SetMaxLetters(100)
	editBox:SetText(ns.db.reminderText or ns.DEFAULT_REMINDER_TEXT)
	reminderEditBox = editBox

	-- What actually gets saved: the box text with the loose spaces trimmed.
	local function SaveReminderText()
		ns.db.reminderText = ns.Trim(editBox:GetText())
	end

	-- Escape puts the saved text back; Enter and clicking away save.
	editBox:SetScript("OnEscapePressed", function(self)
		self:SetText(ns.db.reminderText or ns.DEFAULT_REMINDER_TEXT)
		self:ClearFocus()
	end)
	editBox:SetScript("OnEnterPressed", function(self)
		SaveReminderText()
		self:ClearFocus()
	end)
	editBox:SetScript("OnEditFocusLost", function()
		SaveReminderText()
	end)
	table.insert(refreshers, function()
		if not editBox:HasFocus() then
			editBox:SetText(ns.db.reminderText or ns.DEFAULT_REMINDER_TEXT)
		end
	end)

	-- "Default" restores the original wording...
	local defaultButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	defaultButton:SetSize(58, 22)
	defaultButton:SetPoint("LEFT", editBox, "RIGHT", 6, 0)
	defaultButton:SetText("Default")
	defaultButton:SetScript("OnClick", function()
		editBox:SetText(ns.DEFAULT_REMINDER_TEXT)
		ns.db.reminderText = ns.DEFAULT_REMINDER_TEXT
		ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
	end)

	-- ...and "Preview" prints exactly what a reminder would look like now,
	-- in the saved colour.
	local previewButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	previewButton:SetSize(64, 22)
	previewButton:SetPoint("LEFT", defaultButton, "RIGHT", 6, 0)
	previewButton:SetText("Preview")
	previewButton:SetScript("OnClick", function()
		SaveReminderText()
		local text = ns.BuildReminderText()
		if text == "" then
			text = ns.DEFAULT_REMINDER_TEXT
		end
		local colour = ns.GetMessageColour()
		if DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage(text, colour.r, colour.g, colour.b)
		end
	end)

	y = y - 24
	local reminderNote = AddNote(content, y, "The exact message Ammonia posts. 'Preview' shows it in your colour.")
	y = y - TextHeight(reminderNote) - 15

	-- Message colour
	AddDropdownRow(content, "Message colour",
		"Colour for the chat reminder - clear of your chat channel colours.",
		function()
			-- The labels are painted in their own colour with a |cff code.
			local entries = {}
			for index = 1, #ns.MESSAGE_COLOURS do
				local colour = ns.MESSAGE_COLOURS[index]
				entries[index] = { key = colour.key, text = ns.ColourCode(colour)..colour.label.."|r" }
			end
			return entries
		end,
		function() return ns.db.colourKey end,
		function(key) ns.db.colourKey = key end)

	-- Chime
	local chimeDropdown = AddDropdownRow(content, "Chime",
		"Sound that plays with the reminder. 'No sound' keeps it quiet.",
		function() return ns.GetChimeEntries() end,
		function() return ns.db.chime end,
		function(key) ns.db.chime = key end)

	-- "Play" tries the chosen sound right away, at the chosen volume.
	local playButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	playButton:SetSize(56, 22)
	playButton:SetPoint("LEFT", chimeDropdown, "RIGHT", 2, -2)
	playButton:SetText("Play")
	playButton:SetScript("OnClick", function()
		ns.PlayChime()
	end)
	table.insert(refreshers, function()
		if ns.db.chime == "none" then
			playButton:Disable()
		else
			playButton:Enable()
		end
	end)

	AddSliderRow(content, "Chime volume", 0, 1, 0.05,
		function() return ns.db.volume end,
		function(value) ns.db.volume = value end,
		function(value) return math.floor(value * 100 + 0.5).."%" end)

	AddCheckboxRow(content, "Limit repeat reminders",
		"Usually once per vendor visit. This also waits out the cooldown below.",
		function() return ns.db.useCooldown end,
		function(value) ns.db.useCooldown = value end)

	AddSliderRow(content, "Cooldown", 5, 300, 5,
		function() return ns.db.cooldown end,
		function(value) ns.db.cooldown = value end,
		function(value) return math.floor(value + 0.5).." seconds" end)

	-- Icon section
	local divider = content:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 1, 1, 0.1)
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", content, "TOPLEFT", 10, y)
	divider:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, y)
	y = y - 12

	local iconHeader = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	iconHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	iconHeader:SetText("Icon")
	iconHeader:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])

	local resetButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	resetButton:SetSize(140, 22)
	resetButton:SetPoint("TOPRIGHT", content, "TOPRIGHT", -14, y + 2)
	resetButton:SetText("Reset icon position")
	resetButton:SetScript("OnClick", function()
		ns.ResetIconPosition()
		ns.Print("Icon position reset.")
	end)
	y = y - 24

	AddCheckboxRow(content, "Show icon",
		"Hide the icon completely. /ammonia still opens this window.",
		function() return ns.db.icon.shown end,
		function(value)
			ns.db.icon.shown = value
			ns.UpdateIconState()
		end)

	AddCheckboxRow(content, "Lock icon", nil,
		function() return ns.db.icon.locked end,
		function(value) ns.db.icon.locked = value end)

	-- The list is finished. y is the bottom edge (negative), so the content
	-- is one small padding taller than -y, and the scroll bar appears only
	-- when the rows do not all fit the window.
	content:SetHeight(-y + 12)
	-- The content is handed over as the scroll frame's scroll child only
	-- now, with its real height in place: doing it while the frame was
	-- still 1 pixel tall left the whole list off-screen on the first open,
	-- until something scrolled it into view. A manual position is applied
	-- last, so the list is guaranteed to start at the top.
	if host.SetScrollChild then
		host:SetScrollChild(content)
	end
	if host.UpdateScrollChildRect then
		host:UpdateScrollChildRect()
	end
	UpdateScrollBar()
	ApplyScroll(0)

	RefreshAll()
end

-- Entry point: called once from Core.lua after the saved settings are in.
function ns.BuildUI()
	CreateIconButton()
	CreateOptionsFrame()
	ns.UpdateIconState()
end
