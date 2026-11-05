-- CraftPlan 2.0 — окно: вкладки «Схема | План», кнопка «Все рецепты». Вкладки — UI/Schema.lua, UI/Plan.lua.
local CP = CraftPlan
local W = CP.W
local DB = CP.DB

CP.tabs = {} -- [ключ] = { frame, Refresh = function() }

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
tinsert(UISpecialFrames, "CraftPlanWindow") -- закрывается по Esc
CP.win = win

local grip = CreateFrame("Button", nil, win)
grip:SetWidth(16)
grip:SetHeight(16)
grip:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -6, 6)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function() win:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function()
	win:StopMovingOrSizing()
	DB().winSize = { win:GetWidth(), win:GetHeight() }
	CP.RefreshWindow()
end)

local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -6, -6)

-- вкладки
local tabBtns = {}
local function Tab(key, label, x)
	local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	b:SetText(label)
	b:SetWidth(90)
	b:SetHeight(22)
	b:SetPoint("TOPLEFT", win, "TOPLEFT", x, -16)
	b:SetScript("OnClick", function() CP.ShowTab(key) end)
	tabBtns[key] = b
end
Tab("graph", "Схема", 18)
Tab("plan", "План", 112)

local recipesBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
recipesBtn:SetText("Все рецепты")
recipesBtn:SetWidth(110)
recipesBtn:SetHeight(22)
recipesBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -40, -16)
recipesBtn:SetScript("OnClick", function() if CP.ToggleRecipes then CP.ToggleRecipes() end end)
CP.recipesBtn = recipesBtn

-- тело окна: сюда вкладки ставят свои рамки
local body = CreateFrame("Frame", nil, win)
body:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -44)
body:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -16, 16)
CP.body = body

function CP.ShowTab(key)
	local db = DB()
	if not CP.tabs[key] then key = "plan" end
	db.tab = key
	for k, t in pairs(CP.tabs) do
		if k == key then t.frame:Show() else t.frame:Hide() end
		local b = tabBtns[k]
		if b then
			if k == key then b:LockHighlight(); b:GetFontString():SetTextColor(1, 0.82, 0) else b:UnlockHighlight(); b:GetFontString():SetTextColor(0.7, 0.7, 0.7) end
		end
	end
	CP.RefreshWindow()
end

function CP.RefreshWindow()
	if not win:IsShown() then return end
	local t = CP.tabs[DB().tab or "plan"]
	if t and t.Refresh then
		local ok, err = pcall(t.Refresh)
		if not ok then CP.Print("|cffff4040ошибка окна:|r " .. tostring(err)) end
	end
	if CP.RefreshRecipes then pcall(CP.RefreshRecipes) end
end
CP.OnChange(CP.RefreshWindow)

local restored = false
function CP.ToggleWindow()
	if win:IsShown() then win:Hide() return end
	local db = DB()
	if not restored then
		restored = true
		if db.winSize then win:SetWidth(db.winSize[1]); win:SetHeight(db.winSize[2]) end
		if db.winPos then win:ClearAllPoints(); win:SetPoint(db.winPos[1], UIParent, db.winPos[2], db.winPos[3], db.winPos[4]) end
	end
	win:Show()
	CP.ShowTab(db.tab or "plan")
end
win:SetScript("OnShow", function() if CP.OnWindowShow then CP.OnWindowShow() end end)
win:SetScript("OnHide", function() if CP.OnWindowHide then CP.OnWindowHide() end end)
