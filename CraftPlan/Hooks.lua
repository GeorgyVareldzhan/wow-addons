-- CraftPlan 2.0 — связи с окнами игры: «- N +» в строках окна профессии и учителя, «+» у торговца
-- на рецептах-предметах, Shift+щелчок по предмету (в стек на правке), строка в подсказке предмета.
local CP = CraftPlan

local function Tip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("CraftPlan — стек")
	GameTooltip:AddLine(self.tipText, 1, 1, 1, true)
	GameTooltip:Show()
end
local function Add(prof, name, delta)
	local rec = CP.FindByName(prof, name)
	if not rec then
		CP.Print("«" .. name .. "» нет в данных рецептов CraftPlan — в стек не добавить.")
		return
	end
	CP.Bump(rec.sk, rec.name, delta)
end
local function CountOf(prof, name)
	local rec = CP.FindByName(prof, name)
	return rec and CP.CountIn(rec.sk, rec.name) or 0
end
local function MiniBtn(parent, tex, tipText)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(16)
	b:SetHeight(16)
	b:SetNormalTexture("Interface\\Buttons\\UI-" .. tex .. "Button-Up")
	b:SetPushedTexture("Interface\\Buttons\\UI-" .. tex .. "Button-Down")
	b:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
	b.tipText = tipText
	b:SetScript("OnEnter", Tip)
	return b
end

-- «- N +» прямо в строке списка рецептов, видно при наведении на строку и когда есть стек на правке
local function RowPlus(prefix, count, prof, info)
	for i = 1, count do
		local row = _G[prefix .. i]
		if row and not row.cpPlus then
			local box = CreateFrame("Frame", nil, row)
			box:SetWidth(60)
			box:SetHeight(16)
			box:SetPoint("RIGHT", row, "RIGHT", -2, 0)
			box:SetFrameLevel(row:GetFrameLevel() + 3)
			box:Hide()
			local plus = MiniBtn(box, "Plus", "В стек на правке / ещё 1 (Shift — 10).")
			plus:SetPoint("RIGHT", box, "RIGHT", 0, 0)
			local num = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			num:SetPoint("RIGHT", plus, "LEFT", -2, 0)
			local minus = MiniBtn(box, "Minus", "Меньше на 1 (Shift — 10); до нуля — убрать из стека.")
			minus:SetPoint("RIGHT", num, "LEFT", -2, 0)
			local function Name()
				local id = row:GetID()
				return id and id > 0 and info(id), id
			end
			local function Update()
				local name, id = Name()
				local n = name and CountOf(prof(id), name) or 0
				num:SetText(n > 0 and ("|cffffd200" .. n .. "|r") or "")
				if n > 0 then minus:Show() else minus:Hide() end
			end
			local function Leave()
				GameTooltip:Hide()
				if not row:IsMouseOver() then box:Hide() end
			end
			local function Click(delta)
				local ok, err = pcall(function()
					local name, id = Name()
					if name then Add(prof(id), name, delta) end
					Update()
				end)
				if not ok then CP.Print("ошибка: " .. tostring(err)) end
			end
			plus:SetScript("OnLeave", Leave)
			minus:SetScript("OnLeave", Leave)
			plus:SetScript("OnClick", function() Click(CP.W.Step()) end)
			minus:SetScript("OnClick", function() Click(-CP.W.Step()) end)
			row:HookScript("OnEnter", function()
				if CP.Editing() and Name() then
					pcall(Update)
					box:Show()
				end
			end)
			row:HookScript("OnLeave", function() if not row:IsMouseOver() then box:Hide() end end)
			row.cpPlus = box
		end
	end
end
-- зелёная галочка слева в строке: рецепт есть в каком-то стеке (при наведении — в каком)
local function MarkRows(prefix, count, prof, info)
	for i = 1, count do
		local row = _G[prefix .. i]
		if row then
			local m = row.cpMark
			if not m then
				m = CreateFrame("Frame", nil, row)
				m:SetWidth(14)
				m:SetHeight(14)
				m:SetPoint("LEFT", row, "LEFT", 2, 0) -- у рецептов слева пусто (там «+» только у заголовков)
				m:SetFrameLevel(row:GetFrameLevel() + 3)
				m:EnableMouse(true)
				m.tex = m:CreateTexture(nil, "OVERLAY")
				m.tex:SetAllPoints(m)
				m.tex:SetTexture(CP.W.TEX.ok)
				m:SetScript("OnEnter", Tip)
				m:SetScript("OnLeave", function() GameTooltip:Hide() end)
				row.cpMark = m
			end
			local id = row:IsShown() and row:GetID()
			local name = id and id > 0 and info(id)
			local rec = name and CP.FindByName(prof(id), name)
			local where = rec and CP.StacksWith(rec.sk, rec.name)
			m.tipText = where and ("В стеке: " .. where) or nil
			if where then m:Show() else m:Hide() end
		end
	end
end
local function TSProf() return (GetTradeSkillLine()) end
local function TSInfo(id)
	local name, kind = GetTradeSkillInfo(id)
	if name and kind ~= "header" then return name end
end
local function TRProf(id) return GetTrainerServiceSkillLine and GetTrainerServiceSkillLine(id) end
local function TRInfo(id)
	local name, _, kind = GetTrainerServiceInfo(id)
	if name and kind ~= "header" then return name end
end
local function MarkTS() MarkRows("TradeSkillSkill", TRADE_SKILLS_DISPLAYED or 8, TSProf, TSInfo) end
local function MarkTR() MarkRows("ClassTrainerSkill", CLASS_TRAINER_SKILLS_DISPLAYED or 11, TRProf, TRInfo) end
local hookedTS, hookedTR
local function TradeSkill()
	if not TradeSkillFrame then return end
	RowPlus("TradeSkillSkill", TRADE_SKILLS_DISPLAYED or 8, TSProf, TSInfo)
	if not hookedTS and TradeSkillFrame_Update then
		hookedTS = true
		hooksecurefunc("TradeSkillFrame_Update", function() pcall(MarkTS) end)
	end
	pcall(MarkTS)
end
local function Trainer()
	if not ClassTrainerFrame then return end
	RowPlus("ClassTrainerSkill", CLASS_TRAINER_SKILLS_DISPLAYED or 11, TRProf, TRInfo)
	if not hookedTR and ClassTrainerFrame_Update then
		hookedTR = true
		hooksecurefunc("ClassTrainerFrame_Update", function() pcall(MarkTR) end)
	end
	pcall(MarkTR)
end
-- стеки поменялись — обновить галочки в открытых окнах
CP.OnChange(function()
	if TradeSkillFrame and TradeSkillFrame:IsShown() then pcall(MarkTS) end
	if ClassTrainerFrame and ClassTrainerFrame:IsShown() then pcall(MarkTR) end
end)
-- у торговца: «+» в углу значка рецепта-предмета («Чертеж: X» -> рецепт X)
local function RecipeOf(link)
	local name = link and link:match("%[(.-)%]")
	return name and name:match("^[^:]+:%s*(.+)$")
end
local function Merchant()
	for i = 1, MERCHANT_ITEMS_PER_PAGE or 10 do
		local item = _G["MerchantItem" .. i .. "ItemButton"]
		if item then
			local b = _G["CraftPlanStackM" .. i]
			if not b then
				b = CreateFrame("Button", "CraftPlanStackM" .. i, item)
				b:SetWidth(18)
				b:SetHeight(18)
				b:SetPoint("TOPRIGHT", item, "TOPRIGHT", 6, 6)
				b:SetFrameLevel(item:GetFrameLevel() + 3)
				b:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
				b:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
				b:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
				b.tipText = "Добавить рецепт в стек на правке."
				b:SetScript("OnEnter", Tip)
				b:SetScript("OnLeave", function() GameTooltip:Hide() end)
				b:SetScript("OnClick", function()
					local rec = RecipeOf(GetMerchantItemLink(item:GetID()))
					if rec then Add(nil, rec, 1) end
				end)
			end
			local link = CP.Editing() and MerchantFrame.selectedTab == 1 and item:IsShown() and GetMerchantItemLink(item:GetID())
			if RecipeOf(link) then b:Show() else b:Hide() end
		end
	end
end
if MerchantFrame_UpdateMerchantInfo then hooksecurefunc("MerchantFrame_UpdateMerchantInfo", function() pcall(Merchant) end) end
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED") -- окна профессии и учителя грузятся при первом открытии
f:RegisterEvent("TRADE_SKILL_SHOW")
f:RegisterEvent("TRAINER_SHOW")
f:RegisterEvent("MERCHANT_SHOW")
f:SetScript("OnEvent", function(_, ev)
	pcall(TradeSkill)
	pcall(Trainer)
	if ev == "MERCHANT_SHOW" then pcall(Merchant) end
end)

-- Shift+щелчок по предмету (сумки, окно профессии, торговец) при открытом окне CraftPlan и стеке на правке:
-- рецепт-предмет («Чертеж: …») — рецепт, остальное — материал +1. Окно «разделить стопку» после щелчка закрываем
local splitAt
hooksecurefunc("HandleModifiedItemClick", function(link)
	if not (link and IsModifiedClick("CHATLINK")) then return end
	if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return end -- открыт чат — это ссылка в чат
	if not (CP.win and CP.win:IsShown() and CP.Editing()) then return end
	local item = CP.ItemOfLink(link)
	if not item then return end
	splitAt = GetTime()
	local short = (GetItemInfo(item) or ""):match("^[^:]+:%s*(.+)$")
	local rec = short and CP.FindByName(nil, short)
	if rec then
		CP.Bump(rec.sk, rec.name, 1)
		CP.Print("в стек: " .. rec.name .. ".")
	else
		CP.AddMat(item, 1)
		CP.Print("в стек: " .. CP.ItemName(item) .. " +1.")
	end
end)
if OpenStackSplitFrame then
	hooksecurefunc("OpenStackSplitFrame", function()
		if splitAt == GetTime() and StackSplitFrame then StackSplitFrame:Hide() end
	end)
end

-- Подсказка предмета: сколько его нужно стекам и сколько не хватает; у сырья — где искать
local function Ours(f) -- подсказка от окна или полосы CraftPlan
	while f do
		if f == CraftPlanWindow or f == CraftPlanBar then return true end
		f = f:GetParent()
	end
end
local function Sources(tip, id)
	local src = CP.ItemSources and CP.ItemSources(id)
	if not src then return end
	tip:AddLine("Где искать:", 1, 0.82, 0)
	for _, l in ipairs(src) do tip:AddLine("  " .. l, 1, 1, 1, true) end
end
local function AddTip(tip)
	local _, link = tip:GetItem()
	local id = CP.ItemOfLink(link)
	if not id then return end
	local n
	if CraftPlanDB and CraftPlanDB.goal and CraftPlanDB.goal.stacks and CraftPlanDB.goal.stacks[1] then
		local ok, data = pcall(CP.Compute)
		if ok then n = CP.Merge(data.trees, data.order).nodes[id] end
	end
	if n then
		tip:AddLine("CraftPlan: нужно стекам " .. n.gross .. (n.short > 0 and (", не хватает " .. n.short) or ", хватает"), 0.4, 0.8, 1)
		if n.made == 0 then Sources(tip, id) end
		tip:Show()
	elseif Ours(tip:GetOwner()) and not CP.Producer(id) then
		-- материал в окне CraftPlan (например, в «Все рецепты»), которого нет в стеках
		Sources(tip, id)
		tip:Show()
	end
end
for _, t in ipairs({ GameTooltip, ItemRefTooltip }) do t:HookScript("OnTooltipSetItem", AddTip) end
