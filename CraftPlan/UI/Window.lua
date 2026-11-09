-- CraftPlan 2.0 — window: caption, the "Все рецепты" button, body — "План" (UI/Plan.lua; "Схема" is a tab of its panel, UI/Schema.lua).
local CP = CraftPlan
local W = CP.W
local DB = CP.DB

CP.tabs = {} -- [key] = { frame, Refresh = function() }

local win = CreateFrame("Frame", "CraftPlanWindow", UIParent)
win:SetFrameStrata("HIGH")
win:SetToplevel(true)
win:SetWidth(980)
win:SetHeight(680)
win:SetPoint("CENTER")
W.Backdrop(win)
win:EnableMouse(true)
win:SetMovable(true)
win:SetResizable(true)
win:SetMinResize(760, 460)
win:SetClampedToScreen(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", function(self) self:StartMoving() end)
win:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local p, _, rp, x, y = self:GetPoint()
	DB().winPos = { p, rp, x, y }
end)
win:Hide()
tinsert(UISpecialFrames, "CraftPlanWindow") -- closes on Esc
CP.win = win

local grip = CreateFrame("Button", nil, win)
grip:SetWidth(16)
grip:SetHeight(16)
grip:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -6, 6)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
-- while sizing, the OnSizeChanged redraws of the tabs are skipped (CP.sizing); releasing the grip redraws once
grip:SetScript("OnMouseDown", function()
	CP.sizing = true
	win:StartSizing("BOTTOMRIGHT")
end)
grip:SetScript("OnMouseUp", function()
	CP.sizing = nil
	win:StopMovingOrSizing()
	DB().winSize = { win:GetWidth(), win:GetHeight() }
	CP.RefreshWindow()
end)

local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -6, -6)

-- caption
local caption = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
caption:SetPoint("TOPLEFT", win, "TOPLEFT", 20, -19)
caption:SetText("CraftPlan")

local recipesBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
recipesBtn:SetText("Все рецепты")
recipesBtn:SetWidth(110)
recipesBtn:SetHeight(22)
recipesBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -40, -16)
recipesBtn:SetScript("OnClick", function() if CP.ToggleRecipes then CP.ToggleRecipes() end end)
CP.recipesBtn = recipesBtn

-- window body: tabs put their frames here
local body = CreateFrame("Frame", nil, win)
body:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -44)
body:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -16, 16)
CP.body = body

-- the only tab is "plan" (no top tabs since 2.0.22)
function CP.ShowTab()
	for k, t in pairs(CP.tabs) do
		if k == "plan" then t.frame:Show() else t.frame:Hide() end
	end
	CP.RefreshWindow()
end

function CP.RefreshWindow()
	if not win:IsShown() then return end
	local t = CP.tabs.plan
	if t and t.Refresh then
		local ok, err = pcall(t.Refresh)
		if not ok then CP.Print("|cffff4040ошибка окна:|r " .. tostring(err)) end
	end
	if CP.RefreshRecipes then
		local ok, err = pcall(CP.RefreshRecipes)
		if not ok then CP.Print("|cffff4040ошибка окна рецептов:|r " .. tostring(err)) end
	end
end
CP.OnChange(CP.RefreshWindow)

local restored = false
function CP.ToggleWindow()
	if win:IsShown() then win:Hide() return end
	local db = DB()
	if not restored then
		restored = true
		db.tab = nil -- the saved top tab of before 2.0.22
		if db.winSize then win:SetWidth(db.winSize[1]); win:SetHeight(db.winSize[2]) end
		if db.winPos then win:ClearAllPoints(); win:SetPoint(db.winPos[1], UIParent, db.winPos[2], db.winPos[3], db.winPos[4]) end
	end
	win:Show()
	CP.ShowTab()
end
win:SetScript("OnShow", function() if CP.OnWindowShow then CP.OnWindowShow() end end)
win:SetScript("OnHide", function()
	if CP.sizing then CP.sizing = nil; win:StopMovingOrSizing() end
	if CP.OnWindowHide then CP.OnWindowHide() end
end)

----------------------------------------------------------------------------------------------
-- Craft bar over the bottom of the window: the Blizzard cast bar is hidden under the window while crafting.
-- Shown while the player casts a profession recipe: icon, fill of the current craft, recipe name,
-- "3 из 10" and the time left for all crafts of the run (only when the whole run takes 5 s or more).
local castBar = CreateFrame("Frame", nil, win)
castBar:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 22, 20)
castBar:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -22, 20)
castBar:SetHeight(34)
castBar:SetFrameLevel(win:GetFrameLevel() + 40)
castBar:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
castBar:SetBackdropColor(0.07, 0.06, 0.04, 0.96)
castBar:SetBackdropBorderColor(0.54, 0.43, 0.17, 1)
castBar:EnableMouse(true) -- the content under it does not react while it is shown
castBar:Hide()
local castIcon = castBar:CreateTexture(nil, "ARTWORK")
castIcon:SetWidth(22)
castIcon:SetHeight(22)
castIcon:SetPoint("LEFT", castBar, "LEFT", 7, 0)
castIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
local castCount = castBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
castCount:SetPoint("RIGHT", castBar, "RIGHT", -10, 0)
castCount:SetJustifyH("RIGHT")
local castFill = CreateFrame("StatusBar", nil, castBar)
castFill:SetPoint("LEFT", castIcon, "RIGHT", 8, 0)
castFill:SetPoint("RIGHT", castBar, "RIGHT", -110, 0)
castFill:SetHeight(18)
castFill:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
castFill:SetMinMaxValues(0, 1)
local castBg = castFill:CreateTexture(nil, "BACKGROUND")
castBg:SetAllPoints(castFill)
castBg:SetTexture(0, 0, 0, 0.6)
local castName = castFill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
castName:SetPoint("CENTER", castFill, "CENTER", 0, 0)

-- recipe names of all professions -> product item (a cast with such a name is a craft); 0 when no item
local recipeNames
local function IsRecipe(name)
	if not recipeNames then
		recipeNames = {}
		for _, sk in pairs(CP.SKILL_ID) do
			for _, rec in ipairs(CP.Recipes(sk)) do
				if not recipeNames[rec.name] or recipeNames[rec.name] == 0 then recipeNames[rec.name] = rec.item or 0 end
			end
		end
	end
	return name and recipeNames[name]
end

-- the run: spell, crafts done/total, one craft's duration and the pause between crafts (measured)
local run = { name = nil, i = 0, n = 0, dur = 0, gap = 0.5, lastDone = nil, showTime = false }
local castStart, castEnd, failUntil = 0, 0, nil
local acc = 0
local function TimeText(sec)
	sec = math.max(0, math.ceil(sec - 1e-6))
	return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end
local function Refresh()
	local now = GetTime()
	local cur = castEnd > castStart and math.min(1, math.max(0, (now - castStart) / (castEnd - castStart))) or 1
	castFill:SetValue(cur)
	local txt = run.i .. " из " .. run.n
	if run.showTime then
		local left = math.max(0, castEnd - now) + (run.n - run.i) * (run.dur + run.gap)
		txt = txt .. "   " .. TimeText(left)
	end
	castCount:SetText(txt)
end
castBar:SetScript("OnUpdate", function(self, e)
	if failUntil then
		if GetTime() >= failUntil then failUntil = nil; self:Hide() end
		return
	end
	-- a craft finished and the next one did not start (run stopped, or fewer repeats than counted)
	if run.lastDone and GetTime() - run.lastDone > 2 then run.name, run.lastDone = nil, nil; self:Hide() return end
	castFill:SetValue(castEnd > castStart and math.min(1, math.max(0, (GetTime() - castStart) / (castEnd - castStart))) or 1)
	acc = acc + e
	if acc >= 0.1 then acc = 0; Refresh() end
end)

local ev = CreateFrame("Frame")
for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED" }) do
	ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function(_, event, unit, spell)
	if unit ~= "player" then return end
	if event == "UNIT_SPELLCAST_START" then
		local name, _, _, tex, startMs, endMs = UnitCastingInfo("player")
		if not name or not IsRecipe(name) then return end
		local now = GetTime()
		if run.name == name and run.i < run.n then
			if run.lastDone then run.gap = math.max(0, math.min(3, now - run.lastDone)) end
			run.i = run.i + 1
		else
			local rep = GetTradeskillRepeatCount and GetTradeskillRepeatCount() or 1
			run.name, run.i, run.n, run.gap = name, 1, math.max(1, rep or 1), 0.5
		end
		castStart, castEnd = startMs / 1000, endMs / 1000
		run.dur = castEnd - castStart
		if run.i == 1 then run.showTime = run.n * run.dur + (run.n - 1) * run.gap >= 5 end
		run.lastDone = nil
		failUntil = nil
		-- the cast gives the spell icon (often the profession's); the product's icon is what the recipe list shows
		local item = IsRecipe(name)
		castIcon:SetTexture((item and item > 0 and GetItemIcon(item)) or tex)
		castName:SetText(name)
		castFill:SetStatusBarColor(1, 0.75, 0.1)
		Refresh()
		castBar:Show()
	elseif not run.name or spell ~= run.name then
		return
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		run.lastDone = GetTime()
		castFill:SetValue(1)
		if run.i >= run.n then run.name = nil; castBar:Hide() end
	else -- interrupted or failed: red for a moment, the run is over
		run.name = nil
		castFill:SetValue(1)
		castFill:SetStatusBarColor(0.8, 0.1, 0.1)
		castName:SetText("Прервано")
		castCount:SetText("")
		failUntil = GetTime() + 0.5
	end
end)
