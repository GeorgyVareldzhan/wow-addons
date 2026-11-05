-- CraftPlan 2.0 — просеивание (ювелирное дело), перенесено из 0.12. Каждое нажатие — одно просеивание, само ничего не делается.
-- Кнопка на полосе справа от значка окна: значок заклинания, число — сколько раз можно просеять, не трогая руду стеков;
-- при наведении — столбик руды из сумок, щелчок по руде — одно просеивание. Журнал «руда -> что выпало» и подсказки к руде и камням.
local CP = CraftPlan
local W = CP.W

local PROSPECT_SPELL = 31252 -- Просеивание
local ORES = { 2770, 2771, 2772, 3858, 10620, 23424, 23425, 36909, 36912, 36910 } -- руда, которую можно просеять
local IS_ORE = {}
for _, id in ipairs(ORES) do IS_ORE[id] = true end
local SIZE = 32
local LOOT_WAIT = 5 -- сколько секунд после просеивания ждём окно добычи

-- Что обычно выпадает (данные 3.3.5; на Sirus может отличаться — журнал важнее) и с какого навыка просеивается
local TBC = { 23077, 21929, 23112, 23079, 23117, 23107, 23436, 23439, 23440, 23437, 23438, 23441 }
local WOTLK = { 36917, 36920, 36923, 36926, 36929, 36932, 36918, 36921, 36924, 36927, 36930, 36933 }
local function With(list, ...)
	local t = {}
	for _, v in ipairs(list) do t[#t + 1] = v end
	for _, v in ipairs({ ... }) do t[#t + 1] = v end
	return t
end
local PROSPECT = {
	[2770] = { 774, 818, 1210 },                                  -- медная
	[2771] = { 1210, 1206, 1705, 1529, 3864, 7909 },              -- оловянная
	[2772] = { 1529, 3864, 1705, 7909, 7910 },                    -- железная
	[3858] = { 3864, 7909, 7910, 12361, 12799, 12800, 12364 },    -- мифриловая
	[10620] = { 7910, 12361, 12799, 12800, 12364 },               -- ториевая
	[23424] = TBC,                                                -- оскверненного железа
	[23425] = With(TBC, 24243),                                   -- адамантитовая
	[36909] = WOTLK,                                              -- кобальтовая
	[36912] = WOTLK,                                              -- саронитовая
	[36910] = With(WOTLK, 36919, 36922, 36925, 36928, 36931, 36934, 46849), -- титановая
}
local PROSPECT_REQ = { [2770] = 20, [2771] = 50, [2772] = 125, [3858] = 175, [10620] = 250,
	[23424] = 275, [23425] = 325, [36909] = 350, [36912] = 400, [36910] = 450 }

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCraftPlan (просеивание):|r " .. msg) end

-- Журнал — CraftPlanDB.prospect: ore[руда] = { n = просеиваний, gems = { [камень] = { c = штук, t = раз выпадал } } };
-- fail[руда] = навык, при котором игра отказала (навыка мало)
local function PDB()
	local db = CP.DB()
	local p = db.prospect or {}
	db.prospect = p
	p.ore = p.ore or {}
	p.fail = p.fail or {}
	return p
end

local function JewelRank()
	local l = CP.SkillLines()["Ювелирное дело"]
	return l and l.rank or 0
end

-- Сколько руды нужно стекам
local function StackNeed(id)
	local data = CP.Compute()
	local n = CP.Merge(data.trees, data.order).nodes[id]
	return n and n.gross or 0
end

-- Свободно для просеивания: всё (сумки + банк) минус нужное стекам, не больше, чем в сумках
local function FreeOre(id)
	local bags = GetItemCount(id)
	local need = StackNeed(id)
	local total = CP.Have(id)
	return math.max(0, math.min(bags, total - need)), need, bags, total - bags
end

-- руда, на которой игра отказала при нынешнем навыке, пропускается
local function Usable(id)
	local failAt = PDB().fail[id]
	return GetItemCount(id) >= 5 and not (failAt and JewelRank() <= failAt)
end

-- Ячейка со стопкой руды от 5 штук
local function OreSlot(id)
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			if CP.ItemOfLink(GetContainerItemLink(bag, slot)) == id then
				local _, count = GetContainerItemInfo(bag, slot)
				if (count or 0) >= 5 then return bag, slot end
			end
		end
	end
end

local function OreTooltipLines(tip, id)
	local o = PDB().ore[id]
	if not o or o.n == 0 then
		tip:AddLine("Просеивание: вы ещё не просеивали эту руду.", 0.6, 0.6, 0.6, true)
		return
	end
	local list = {}
	for gem, g in pairs(o.gems) do list[#list + 1] = { gem, g.c / o.n } end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	tip:AddLine("Просеивание (ваш журнал, " .. o.n .. " раз), в среднем за раз:", 0.4, 0.8, 1)
	for i = 1, math.min(#list, 6) do
		tip:AddDoubleLine("  " .. CP.ItemName(list[i][1]), string.format("%.2f", list[i][2]), 1, 1, 1, 1, 1, 1)
	end
end

----------------------------------------------------------------------------------------------
-- Кнопка (защищённая): стоит на полосе справа от значка окна, полоса оставляет ей место
local mapBtn = CP.mapButton
local frame = CreateFrame("Frame", "CraftPlanProspectFrame", UIParent)
frame:SetWidth(SIZE)
frame:SetHeight(SIZE)
frame:SetPoint("LEFT", mapBtn, "RIGHT", 6, 0)
frame:SetFrameStrata("MEDIUM")
frame:Hide()
CP.prospectFrame = frame

local function Border(b)
	b.border = b:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	b.border:SetBlendMode("ADD")
	b.border:SetWidth(SIZE * 1.8)
	b.border:SetHeight(SIZE * 1.8)
	b.border:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.border:SetVertexColor(0.4, 0.8, 1)
end

local function SecureButton(name, parent)
	local b = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
	b:SetWidth(SIZE)
	b:SetHeight(SIZE)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetAttribute("type1", "macro")
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints(b)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
	-- Ctrl+перетаскивание — передвинуть полосу, как и с её значков
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", CP.BarDragStart)
	b:SetScript("OnDragStop", CP.BarDragStop)
	return b
end

local button = SecureButton("CraftPlanProspect", frame)
button:SetAllPoints(frame)
Border(button)
button.warn = button:CreateTexture(nil, "OVERLAY") -- руда нужна стекам
button.warn:SetWidth(14)
button.warn:SetHeight(14)
button.warn:SetPoint("TOPRIGHT", button, "TOPRIGHT", 2, 2)
button.warn:SetTexture(W.TEX.alert)

local updateSecure
local clickAt, clickOre = 0, nil -- какую руду просеивали щелчком (для отказа «навыка мало»)
local flyOres = {}
button:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT") -- снизу — столбик руды
	GameTooltip:AddLine("Просеивание")
	GameTooltip:AddLine("Число — сколько раз всего можно просеять, не трогая руду стеков.", 1, 1, 1, true)
	for _, id in ipairs(flyOres) do
		local free, need = FreeOre(id)
		GameTooltip:AddDoubleLine("  " .. CP.ItemName(id), math.floor(free / 5) .. " раз" .. (need > 0 and ("  (стекам нужно " .. need .. ")") or ""),
			1, 1, 1, need > 0 and 1 or 0.25, need > 0 and 0.82 or 1, need > 0 and 0 or 0.25)
	end
	GameTooltip:AddLine("Значок в углу — какая-то руда нужна стекам. Просеять — щелчок по руде в столбике снизу.", 0.6, 0.8, 1, true)
	GameTooltip:AddLine("Ctrl+перетаскивание — передвинуть полосу.", 0.6, 0.8, 1, true)
	GameTooltip:Show()
end)
button:SetScript("OnLeave", W.TipLeave)

-- Столбик под кнопкой: значок руды, число — сколько раз можно просеять без руды стеков; щелчок — одно просеивание
local fly = CreateFrame("Frame", "CraftPlanProspectFly", frame)
fly:SetPoint("TOP", frame, "BOTTOM", 0, -16) -- ниже процента под значком окна
fly:SetWidth(SIZE)
fly:Hide()
local flyButtons = {}
local function FlyButton(i)
	local b = flyButtons[i]
	if b then return b end
	b = SecureButton("CraftPlanProspectFly" .. i, fly)
	b:SetPoint("TOP", fly, "TOP", 0, -(i - 1) * (SIZE + 4))
	b:HookScript("OnClick", function(self, mouse)
		if mouse ~= "RightButton" then clickAt, clickOre = GetTime(), self.ore end
	end)
	b:SetScript("OnEnter", function(self)
		local id = self.ore
		if not id then return end
		local free, need, bags, bank = FreeOre(id)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(CP.ItemName(id) .. ": в сумках " .. bags .. (bank > 0 and (", в банке " .. bank) or "") .. " шт.")
		if need > 0 then
			GameTooltip:AddLine("Стекам нужно " .. need .. ", есть " .. (bags + bank) .. " — свободно " .. free .. ", можно просеять " .. math.floor(free / 5) .. " раз.",
				free >= 5 and 0.25 or 1, free >= 5 and 1 or 0.4, free >= 5 and 0.25 or 0.4, true)
		else
			GameTooltip:AddLine("Стекам не нужна — можно просеять " .. math.floor(bags / 5) .. " раз.", 0.25, 1, 0.25, true)
		end
		OreTooltipLines(GameTooltip, id)
		GameTooltip:AddLine("Щелчок — одно просеивание этой руды.", 0.6, 0.8, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", W.TipLeave)
	flyButtons[i] = b
	return b
end

-- настроить столбик (только вне боя)
local function FlySetup(spell)
	wipe(flyOres)
	for _, id in ipairs(ORES) do
		if Usable(id) and OreSlot(id) then flyOres[#flyOres + 1] = id end
	end
	for i, id in ipairs(flyOres) do
		local b = FlyButton(i)
		local bag, slot = OreSlot(id)
		b.ore = id
		b:SetAttribute("macrotext1", "/cast " .. spell .. "\n/use " .. bag .. " " .. slot)
		b.icon:SetTexture(GetItemIcon(id))
		local times = math.floor(FreeOre(id) / 5)
		b.count:SetText((times > 0 and "" or "|cffff6060") .. times .. (times > 0 and "" or "|r"))
		b:Show()
	end
	for i = #flyOres + 1, #flyButtons do
		flyButtons[i].ore = nil
		flyButtons[i]:SetAttribute("macrotext1", nil)
		flyButtons[i]:Hide()
	end
	fly:SetHeight(math.max(1, #flyOres * (SIZE + 4)))
	if #flyOres < 1 then fly:Hide() end
end

-- показать при наведении на кнопку; спрятать, когда курсор ушёл и с кнопки, и со столбика
button:HookScript("OnEnter", function()
	if #flyOres >= 1 and not InCombatLockdown() then fly:Show() end
end)
fly:SetScript("OnUpdate", function(self, elapsed)
	if InCombatLockdown() then return end
	if MouseIsOver(frame) or MouseIsOver(self) then
		self.away = 0
	else
		self.away = (self.away or 0) + elapsed
		if self.away > 0.3 then
			self.away = 0
			self:Hide()
		end
	end
end)

local pending = false
updateSecure = function()
	if InCombatLockdown() then pending = true return end
	pending = false
	local was = frame:IsShown()
	local spell = GetSpellInfo(PROSPECT_SPELL)
	local known = spell and GetSpellInfo(spell) -- есть в книге заклинаний
	if known then FlySetup(spell) else fly:Hide() end
	if known and #flyOres > 0 and not CP.DB().collapsed then
		local times, needed = 0, false
		for _, id in ipairs(flyOres) do
			local free, need = FreeOre(id)
			times = times + math.floor(free / 5)
			if need > 0 then needed = true end
		end
		button.icon:SetTexture(select(3, GetSpellInfo(PROSPECT_SPELL)))
		button.count:SetText((times > 0 and "" or "|cffff6060") .. times .. (times > 0 and "" or "|r"))
		if needed then button.warn:Show() else button.warn:Hide() end
		frame:Show()
	else
		frame:Hide()
	end
	if was ~= frame:IsShown() and CP.RefreshBar then CP.RefreshBar() end -- полоса сдвигает значки
end
CP.ProspectUpdate = function() updateSecure() end
CP.OnChange(updateSecure)

----------------------------------------------------------------------------------------------
-- Журнал: перед просеиванием запоминаем количество руды, после — какая убыла и что выпало
local before, castAt = nil, 0
local function OreCounts()
	local t = {}
	for _, id in ipairs(ORES) do t[id] = GetItemCount(id) end
	return t
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "LEARNED_SPELL_IN_TAB",
	"UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "LOOT_OPENED", "UI_ERROR_MESSAGE" }) do
	events:RegisterEvent(e)
end
local prospectName
events:SetScript("OnEvent", function(_, event, arg1, arg2)
	prospectName = prospectName or GetSpellInfo(PROSPECT_SPELL)
	if event == "UNIT_SPELLCAST_SENT" then
		if arg1 == "player" and arg2 == prospectName then before = OreCounts() end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if arg1 == "player" and arg2 == prospectName then castAt = GetTime() end
	elseif event == "UI_ERROR_MESSAGE" then
		-- отказ сразу после щелчка со словом «навык»: руда «навыка мало», пока пропускаем
		if GetTime() - clickAt < 2 and clickOre and arg1 and arg1:find("навык") then
			PDB().fail[clickOre] = JewelRank()
			Print(CP.ItemName(clickOre) .. ": игра пишет, что навыка мало, — пока пропускаю её.")
			updateSecure()
		end
	elseif event == "LOOT_OPENED" then
		if not before or GetTime() - castAt > LOOT_WAIT then return end
		local now, ore = OreCounts(), nil
		for id, n in pairs(before) do
			if (now[id] or 0) <= n - 5 then ore = id break end
		end
		before = nil
		if not ore then return end
		local o = PDB().ore[ore] or { n = 0, gems = {} }
		PDB().ore[ore] = o
		o.n = o.n + 1
		for i = 1, GetNumLootItems() do
			local id = CP.ItemOfLink(GetLootSlotLink(i))
			if id then
				local _, _, qty = GetLootSlotInfo(i)
				local g = o.gems[id] or { c = 0, t = 0 }
				o.gems[id] = g
				g.c = g.c + (qty or 1)
				g.t = g.t + 1
			end
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pending then updateSecure() end
	else
		updateSecure()
	end
end)

----------------------------------------------------------------------------------------------
-- Подсказки: к руде — что из неё выпадает; к камню — из какой руды получается
local function AddTip(tip)
	local _, link = tip:GetItem()
	local id = CP.ItemOfLink(link)
	if not id then return end
	local owner = tip:GetOwner()
	if owner == button or (owner and owner.ore) then return end -- у кнопок своя подсказка
	if IS_ORE[id] then
		if PDB().ore[id] then OreTooltipLines(tip, id) tip:Show() end
		return
	end
	local parts = {}
	for ore, o in pairs(PDB().ore) do
		local g = o.gems[id]
		if g then parts[#parts + 1] = CP.ItemName(ore) .. " (" .. g.t .. " из " .. o.n .. ")" end
	end
	if #parts > 0 then
		tip:AddLine("Просеиванием (ваш журнал): " .. table.concat(parts, ", "), 0.4, 0.8, 1, true)
		tip:Show()
		return
	end
	for _, ore in ipairs(ORES) do
		for _, g in ipairs(PROSPECT[ore]) do
			if g == id then parts[#parts + 1] = CP.ItemName(ore) .. " (навык " .. PROSPECT_REQ[ore] .. ")" break end
		end
	end
	if #parts > 0 then
		tip:AddLine("Просеиванием (обычно): " .. table.concat(parts, ", "), 0.4, 0.8, 1, true)
		tip:Show()
	end
end
for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do tip:HookScript("OnTooltipSetItem", AddTip) end
