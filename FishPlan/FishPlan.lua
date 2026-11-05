-- FishPlan — рыбалка (вынесено из CraftPlan 0.12). Ничего не делает сам — только кнопки, подсказки и журнал:
-- журнал улова (что и где поймано), подсказка «вы ловили» к предмету, навык и срывы по зоне,
-- кнопки «удочка/оружие», «приманка», «забросить», громкий всплеск поплавка.
FishPlan = FishPlan or {}
FishPlan.VERSION = "0.1.0"
BINDING_HEADER_FISHPLAN = "FishPlan (рыбалка)"
_G["BINDING_NAME_CLICK FishPlanCast:LeftButton"] = "Забросить удочку"
_G["BINDING_NAME_CLICK FishPlanLure:LeftButton"] = "Наложить приманку"
BINDING_NAME_FISHPLAN_SWAP = "Надеть удочку / вернуть оружие"

local FISHING_SPELL = 7620 -- Рыбная ловля
-- Удочки (номера сверены с базой Questie)
local POLES = {
	[6256] = true, [6365] = true, [6366] = true, [6367] = true, [12225] = true, [19022] = true,
	[19970] = true, [25978] = true, [44050] = true, [45858] = true, [45991] = true, [45992] = true,
}
-- Приманки, от лучшей к худшей (номера сверены с базой Questie)
local LURES = {
	34861, -- Заострённый рыболовный крючок
	46006, -- Светящийся червяк
	6533,  -- Аквадинамический магнит для рыбы
	7307,  -- Плотоядный червь
	6532,  -- Яркие побрякушки
	6811,  -- Аквадинамическая рыбная линза
	6530,  -- Ночные выползки
	6529,  -- Блестящая побрякушка
}
-- Рыба из косяков (по базе Questie: падает из объектов-косяков); остальную узнаём из журнала
local POOL_FISH = {
	[6358] = true, [6359] = true, [6522] = true, [13422] = true, [21071] = true, [21153] = true,
	[27425] = true, [27429] = true, [27435] = true, [27437] = true, [27438] = true, [27439] = true,
	[27515] = true, [27516] = true, [41800] = true, [41801] = true, [41802] = true, [41806] = true,
	[41807] = true, [41809] = true, [41810] = true, [41813] = true, [41814] = true,
}
local LOUD_SOUND = { Sound_SFXVolume = "1", Sound_MusicVolume = "0", Sound_AmbienceVolume = "0" }
local BUTTON = 36

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffFishPlan:|r " .. msg)
end

-- Журнал улова и настройки — FishPlanDB (по персонажу); при первом входе переносится из CraftPlanDB.fish
local function DB()
	FishPlanDB = FishPlanDB or {}
	local f = FishPlanDB
	f.catch = f.catch or {} -- [itemID] = { [зона] = штук }
	f.zones = f.zones or {} -- [зона] = { catches, escapes, minSkill }
	return f
end

local function CharDB()
	return DB()
end

local function ItemID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

----------------------------------------------------------------------------------------------
-- Навык и снаряжение
local function FishingSkill()
	local fishName = GetSpellInfo(FISHING_SPELL)
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank, _, modifier = GetSkillLineInfo(i)
		if not isHeader and name == fishName then return rank, modifier or 0 end
	end
end

local function PoleEquipped()
	return POLES[ItemID(GetInventoryItemLink("player", 16)) or 0] and true or false
end

-- Первая подходящая вещь из списка в сумках: bag, slot, itemID
local function FindInBags(want)
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			local id = ItemID(GetContainerItemLink(bag, slot))
			if id and want(id) then return bag, slot, id end
		end
	end
end

local function BestLure()
	local have = {}
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			local id = ItemID(GetContainerItemLink(bag, slot))
			if id and not have[id] then have[id] = { bag, slot } end
		end
	end
	for _, id in ipairs(LURES) do
		if have[id] then return have[id][1], have[id][2], id end
	end
end

-- Запомнить оружие в руках, если это не удочка: тогда его можно вернуть, даже если удочку
-- надели вручную, а не кнопкой
local function RememberWeapons()
	if PoleEquipped() then return end
	local main = ItemID(GetInventoryItemLink("player", 16))
	if not main then return end -- руки пустые — прежнее оружие не забываем
	local c = CharDB()
	c.mainHand, c.offHand = main, ItemID(GetInventoryItemLink("player", 17))
end

-- Надеть удочку (запомнив оружие) или вернуть оружие
function FishPlan.Swap()
	if InCombatLockdown() then Print("в бою снаряжение не меняю.") return end
	local c = CharDB()
	if PoleEquipped() then
		if c.mainHand then EquipItemByName(c.mainHand, 16) end
		if c.offHand then EquipItemByName(c.offHand, 17) end
		if not c.mainHand then Print("не помню, какое было оружие — наденьте его сами.") end
	else
		local _, _, pole = FindInBags(function(id) return POLES[id] end)
		if not pole then Print("в сумках нет удочки.") return end
		RememberWeapons()
		EquipItemByName(pole, 16)
	end
end

----------------------------------------------------------------------------------------------
-- Журнал улова: что поймано в какой зоне; срывы рыбы по зонам
local events = CreateFrame("Frame")

local function ZoneStats(zone)
	local z = DB().zones[zone]
	if not z then
		z = { catches = 0, escapes = 0 }
		DB().zones[zone] = z
	end
	return z
end

local function OnFishingLoot()
	local zone = GetRealZoneText()
	if not zone or zone == "" then return end
	local rank, mod = FishingSkill()
	local z = ZoneStats(zone)
	z.catches = z.catches + 1
	if rank then
		local skill = rank + mod
		if not z.minSkill or skill < z.minSkill then z.minSkill = skill end
	end
	for i = 1, GetNumLootItems() do
		local id = ItemID(GetLootSlotLink(i))
		if id then
			local _, _, qty = GetLootSlotInfo(i)
			local t = DB().catch[id] or {}
			t[zone] = (t[zone] or 0) + (qty or 1)
			DB().catch[id] = t
		end
	end
end

-- Где ловится предмет: признак «рыба» и текст зон из журнала (по убыванию улова).
function FishPlan.Where(itemID)
	local t = itemID and DB().catch[itemID]
	if t then
		local list = {}
		for zone, n in pairs(t) do list[#list + 1] = { zone, n } end
		table.sort(list, function(a, b) return a[2] > b[2] end)
		local parts = {}
		for i = 1, math.min(#list, 3) do parts[#parts + 1] = list[i][1] end
		return true, table.concat(parts, ", ")
	end
	if itemID and POOL_FISH[itemID] then return true, "в косяках рыбы" end
	return false
end

----------------------------------------------------------------------------------------------
-- Громкий всплеск: пока удочка в руках — звуки на максимум, музыка и фон выключены
local function SetLoud(on)
	local c = CharDB()
	if on and not c.savedSound then
		c.savedSound = {}
		for cvar, value in pairs(LOUD_SOUND) do
			c.savedSound[cvar] = GetCVar(cvar)
			SetCVar(cvar, value)
		end
	elseif not on and c.savedSound then
		for cvar, value in pairs(c.savedSound) do SetCVar(cvar, value) end
		c.savedSound = nil
	end
end

local function LoudEnabled() -- по умолчанию включено
	return DB().loud ~= false
end

----------------------------------------------------------------------------------------------
-- Панель: видна, пока удочка в руках (или закреплена командой /fish)
local panel = CreateFrame("Frame", "FishPlanFrame", UIParent)
panel:SetWidth(3 * BUTTON + 2 * 6 + 20)
panel:SetHeight(BUTTON + 64)
panel:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
panel:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
panel:SetBackdropColor(0, 0, 0, 0.8)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local _, _, _, x, y = self:GetPoint()
	CharDB().pos = { x, y }
end)
panel:Hide()

local function MakeButton(name, template, index, tipTitle, tipText)
	local b = CreateFrame("Button", name, panel, template)
	b:SetWidth(BUTTON)
	b:SetHeight(BUTTON)
	b:SetPoint("TOPLEFT", panel, "TOPLEFT", 10 + (index - 1) * (BUTTON + 6), -10)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints(b)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b.text = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.text:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(tipTitle)
		GameTooltip:AddLine(type(tipText) == "function" and tipText() or tipText, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local swapButton = MakeButton("FishPlanSwap", nil, 1, "Удочка / оружие", function()
	return PoleEquipped() and "Вернуть оружие, которое было до удочки." or "Надеть удочку из сумки (оружие запомнится)."
end)
swapButton:SetScript("OnClick", FishPlan.Swap)

local lureButton = MakeButton("FishPlanLure", "SecureActionButtonTemplate", 2, "Приманка", function()
	local _, _, id = BestLure()
	if not id then return "В сумках нет приманки." end
	return "Наложить на удочку: " .. (GetItemInfo(id) or ("предмет " .. id)) .. ". Цифра — сколько минут осталось у текущей приманки."
end)
lureButton:SetAttribute("type", "macro")

local castButton = MakeButton("FishPlanCast", "SecureActionButtonTemplate", 3, "Забросить",
	"Забросить удочку. Клавишу можно назначить: «Назначение клавиш», раздел «FishPlan (рыбалка)».")
castButton:SetAttribute("type", "spell")
castButton:SetAttribute("spell", (GetSpellInfo(FISHING_SPELL)))
castButton.icon:SetTexture(select(3, GetSpellInfo(FISHING_SPELL)))

local info = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
info:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -BUTTON - 16)
info:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
info:SetJustifyH("LEFT")

local loudCheck = CreateFrame("CheckButton", "FishPlanLoud", panel, "UICheckButtonTemplate")
loudCheck:SetWidth(20)
loudCheck:SetHeight(20)
loudCheck:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 4)
_G["FishPlanLoudText"]:SetText("Громкий всплеск")
loudCheck:SetScript("OnClick", function(self)
	DB().loud = self:GetChecked() and true or false
	SetLoud(DB().loud and PoleEquipped())
end)
loudCheck:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine("Громкий всплеск")
	GameTooltip:AddLine("Пока удочка в руках: звуки на максимум, музыка и фоновые звуки выключены — всплеск поплавка слышно лучше. Снимете удочку — всё вернётся.", 1, 1, 1, true)
	GameTooltip:Show()
end)
loudCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Обновить кнопки (атрибуты защищённых кнопок и показ панели — только вне боя)
local pendingSecure = false
local function UpdateSecure()
	if InCombatLockdown() then pendingSecure = true return end
	pendingSecure = false
	local bag, slot, id = BestLure()
	if bag then
		lureButton:SetAttribute("macrotext", "/use " .. bag .. " " .. slot .. "\n/use 16")
		lureButton.icon:SetTexture(GetItemIcon(id))
		lureButton.icon:SetDesaturated(false)
	else
		lureButton:SetAttribute("macrotext", nil)
		lureButton.icon:SetTexture(GetItemIcon(LURES[#LURES]))
		lureButton.icon:SetDesaturated(true)
	end
	local pole = PoleEquipped()
	if pole or CharDB().pinned then panel:Show() else panel:Hide() end
end

local function UpdateInfo()
	local pole = PoleEquipped()
	if pole then
		swapButton.icon:SetTexture(GetItemIcon(CharDB().mainHand or 0) or "Interface\\Icons\\INV_Sword_04")
	else
		local _, _, id = FindInBags(function(i) return POLES[i] end)
		swapButton.icon:SetTexture(GetItemIcon(id or 6256))
	end
	-- оставшееся время приманки
	local hasEnchant, expires = GetWeaponEnchantInfo()
	lureButton.text:SetText(pole and hasEnchant and expires and (math.ceil(expires / 60000) .. "м") or "")
	lureButton:SetAlpha(pole and hasEnchant and 0.5 or 1)

	local rank, mod = FishingSkill()
	local zone = GetRealZoneText() or ""
	local z = DB().zones[zone]
	local line1 = rank and ("Навык: " .. rank .. (mod > 0 and (" |cff40ff40+" .. mod .. "|r") or "")) or "Рыбная ловля не изучена"
	local line2
	if z and (z.catches + z.escapes) > 0 then
		local pct = math.floor(100 * z.escapes / (z.catches + z.escapes) + 0.5)
		local col = pct == 0 and "|cff40ff40" or (pct < 20 and "|cffffff00" or "|cffff6060")
		line2 = zone .. ": поймано " .. z.catches .. ", сорвалось " .. col .. z.escapes .. " (" .. pct .. "%)|r"
	else
		line2 = zone .. ": здесь ещё не ловили"
	end
	info:SetText(line1 .. "\n" .. line2)
end

local elapsedTotal = 0
panel:SetScript("OnUpdate", function(_, elapsed)
	elapsedTotal = elapsedTotal + elapsed
	if elapsedTotal < 1 then return end
	elapsedTotal = 0
	UpdateInfo()
end)

local function UpdateAll()
	UpdateSecure()
	if PoleEquipped() then SetLoud(LoudEnabled()) else SetLoud(false) end
	if panel:IsShown() then UpdateInfo() end
end

----------------------------------------------------------------------------------------------
-- Подсказка к предмету: где вы его ловили
local function AddCatchToTooltip(tip)
	local _, link = tip:GetItem()
	local id = ItemID(link)
	local t = id and DB().catch[id]
	if not t then
		if id and POOL_FISH[id] then
			tip:AddLine("Ловится в косяках рыбы.", 0.4, 0.85, 1, true)
			tip:Show()
		end
		return
	end
	local list = {}
	for zone, n in pairs(t) do list[#list + 1] = { zone, n } end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	local parts = {}
	for i = 1, math.min(#list, 4) do parts[#parts + 1] = list[i][1] .. " (" .. list[i][2] .. ")" end
	if #list > 4 then parts[#parts + 1] = "и ещё " .. (#list - 4) end
	tip:AddLine("Вы ловили: " .. table.concat(parts, ", "), 0.4, 0.85, 1, true)
	tip:Show()
end
for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
	tip:HookScript("OnTooltipSetItem", AddCatchToTooltip)
end

----------------------------------------------------------------------------------------------
-- События
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "LOOT_OPENED", "UI_ERROR_MESSAGE", "UNIT_INVENTORY_CHANGED",
	"BAG_UPDATE", "PLAYER_REGEN_ENABLED", "ZONE_CHANGED_NEW_AREA" }) do
	events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "PLAYER_LOGIN" then
		-- перенос журнала из CraftPlan 0.12 (там остаётся как было)
		if not (FishPlanDB and FishPlanDB.migrated) and CraftPlanDB and type(CraftPlanDB.fish) == "table" then
			FishPlanDB = FishPlanDB or {}
			for k, v in pairs(CraftPlanDB.fish) do
				local cur = FishPlanDB[k]
				if cur == nil or (type(cur) == "table" and next(cur) == nil) then FishPlanDB[k] = v end
			end
			Print("журнал улова перенесён из CraftPlan.")
		end
		DB().migrated = true
		local c = CharDB()
		if c.pos then
			panel:ClearAllPoints()
			panel:SetPoint("CENTER", UIParent, "CENTER", c.pos[1], c.pos[2])
		end
		-- звук остался громким после вылета игры — вернуть
		if c.savedSound and not PoleEquipped() then SetLoud(false) end
		loudCheck:SetChecked(LoudEnabled())
		RememberWeapons()
		UpdateAll()
	elseif event == "PLAYER_LOGOUT" then
		SetLoud(false) -- в файл настроек уходят ваши обычные громкости
	elseif event == "LOOT_OPENED" then
		if IsFishingLoot() then OnFishingLoot() end
	elseif event == "UI_ERROR_MESSAGE" then
		if arg1 == ERR_FISH_ESCAPED then
			local zone = GetRealZoneText()
			if zone and zone ~= "" then
				local z = ZoneStats(zone)
				z.escapes = z.escapes + 1
			end
		end
	elseif event == "UNIT_INVENTORY_CHANGED" then
		if arg1 == "player" then
			RememberWeapons()
			UpdateAll()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingSecure then UpdateSecure() end
	else
		UpdateSecure()
	end
end)

----------------------------------------------------------------------------------------------
-- /fish — показать/скрыть панель без удочки; /fish loud — громкий всплеск; /fish reset — очистить журнал
SLASH_FISHPLAN1 = "/fish"
SlashCmdList["FISHPLAN"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "loud" then
		loudCheck:SetChecked(not LoudEnabled())
		loudCheck:GetScript("OnClick")(loudCheck)
		Print("громкий всплеск: " .. (LoudEnabled() and "вкл" or "выкл") .. ".")
	elseif msg == "reset" then
		DB().catch, DB().zones = {}, {}
		Print("журнал улова очищен.")
	elseif msg == "" then
		if InCombatLockdown() then Print("в бою панель не переключаю.") return end
		CharDB().pinned = not CharDB().pinned
		UpdateAll()
		Print("панель " .. (CharDB().pinned and "закреплена (видна и без удочки)" or "видна только с удочкой в руках") .. ".")
	else
		Print("/fish — закрепить/открепить панель; /fish loud — громкий всплеск; /fish reset — очистить журнал улова.")
	end
end
