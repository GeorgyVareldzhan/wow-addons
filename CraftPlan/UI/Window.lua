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
