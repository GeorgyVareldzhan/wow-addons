-- CraftPlan 2.0 — ядро: база (CraftPlanDB), профессии, подсчёт «есть», чтение окон игры, события.
-- Стеки и расчёт материалов — Calc.lua, окна — UI/*.lua.

CraftPlan = CraftPlan or {}
local CP = CraftPlan

CP.VERSION = "2.0.21"

BINDING_HEADER_CRAFTPLAN = "CraftPlan (профессии)"
BINDING_NAME_CRAFTPLAN_MAP = "Открыть/закрыть окно CraftPlan"
BINDING_NAME_CRAFTPLAN_COLLAPSE = "Свернуть/развернуть полосу"

function CP.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCraftPlan:|r " .. msg)
end

function CP.DB()
	CraftPlanDB = CraftPlanDB or {}
	CraftPlanDB.profs = CraftPlanDB.profs or {}
	return CraftPlanDB
end
local DB = CP.DB

----------------------------------------------------------------------------------------------
-- Профессии: название <-> номер навыка (для таблиц CraftPlanThresholds / CraftPlanRouteData)
CP.SKILL_ID = {
	["Кузнечное дело"] = 164, ["Кожевничество"] = 165, ["Алхимия"] = 171, ["Кулинария"] = 185,
	["Горное дело"] = 186, ["Портняжное дело"] = 197, ["Инженерное дело"] = 202, ["Наложение чар"] = 333,
	["Ювелирное дело"] = 755, ["Начертание"] = 773, ["Первая помощь"] = 129,
}
CP.SKILL_NAME = {}
for name, id in pairs(CP.SKILL_ID) do CP.SKILL_NAME[id] = name end

-- Значки профессий (текстуры игры)
CP.PROF_ICON = {
	["Кузнечное дело"] = "Interface\\Icons\\Trade_BlackSmithing", ["Кожевничество"] = "Interface\\Icons\\Trade_LeatherWorking",
	["Алхимия"] = "Interface\\Icons\\Trade_Alchemy", ["Кулинария"] = "Interface\\Icons\\INV_Misc_Food_15",
	["Горное дело"] = "Interface\\Icons\\Trade_Mining", ["Портняжное дело"] = "Interface\\Icons\\Trade_Tailoring",
	["Инженерное дело"] = "Interface\\Icons\\Trade_Engineering", ["Наложение чар"] = "Interface\\Icons\\Trade_Engraving",
	["Ювелирное дело"] = "Interface\\Icons\\INV_Misc_Gem_01", ["Начертание"] = "Interface\\Icons\\INV_Inscription_Tradeskill01",
	["Первая помощь"] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
}

CP.TOP_SKILL = 450 -- верх навыка в 3.3.5 (полоса навыка рисуется до него)

-- Цвета рецептов, как в игре
CP.KIND_COLOR = {
	optimal = { 1, 0.5, 0.25 }, medium = { 1, 1, 0 }, easy = { 0.25, 0.75, 0.25 }, trivial = { 0.5, 0.5, 0.5 },
}
CP.KIND_HEX = { optimal = "|cffff8040", medium = "|cffffff00", easy = "|cff40c040", trivial = "|cff808080" }

-- Пороги цвета рецепта: жёлтый с навыка, серый с навыка (или nil)
function CP.Thresholds(sk, recName)
	local t = CraftPlanThresholds and CraftPlanThresholds[sk]
	local v = t and t[recName]
	if v then return v[1], v[2] end
end

-- Цвет рецепта при навыке: оранжевый до жёлтого порога, жёлтый до середины, зелёный до серого
function CP.KindAt(y, g, rank)
	if rank < y then return "optimal" end
	if rank < math.floor((y + g) / 2) then return "medium" end
	if rank < g then return "easy" end
	return "trivial"
end

-- Шанс роста навыка: оранжевый — всегда, дальше убывает к серому порогу (общая формула 3.3.5)
function CP.Chance(y, g, r)
	if r < y then return 1 end
	if r >= g or g <= y then return 0 end
	return (g - r) / (g - y)
end

-- Навык и максимум профессии сейчас (из окна навыков, без окна профессии)
-- Навык берём больший из списка навыков и окна профессии: после создания окно профессии обновляется сразу,
-- а список навыков — чуть позже (иначе итог «навык + прирост» на миг или насовсем уменьшался бы)
function CP.SkillLines()
	local t = {}
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank, _, _, max = GetSkillLineInfo(i)
		if name and not isHeader then t[name] = { rank = rank, max = max } end
	end
	if TradeSkillFrame and TradeSkillFrame:IsShown() and not (IsTradeSkillLinked and IsTradeSkillLinked()) then
		local prof, rank, max = GetTradeSkillLine()
		local l = prof and t[prof]
		if l and rank and rank > l.rank then l.rank = rank end
		if l and max and max > l.max then l.max = max end
	end
	return t
end

----------------------------------------------------------------------------------------------
-- Предметы: название и значок (кэш игры, иначе база Questie, иначе «предмет N»)
local function ItemOfLink(link) return link and tonumber(link:match("item:(%d+)")) end
CP.ItemOfLink = ItemOfLink

function CP.ItemName(id)
	if not id then return "?" end
	local name = GetItemInfo(id)
	if name then return name end
	local q = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	if q and q.QueryItemSingle then
		local ok, n = pcall(q.QueryItemSingle, id, "name")
		if ok and n then return n end
	end
	return "предмет " .. id
end

function CP.ItemIcon(id)
	return (id and GetItemIcon(id)) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

----------------------------------------------------------------------------------------------
-- Сколько предмета есть: сумки + хранилище для ингредиентов Sirus (контейнер -4, крафт берёт из него
-- где угодно; содержимое запоминается, если игра его сейчас не отдаёт) + банк (запомненный).
do
	local REAGENT_BAG = -4
	local ids, stamp
	local function Scan()
		ids = {}
		for bag = 0, NUM_BAG_SLOTS do
			for slot = 1, GetContainerNumSlots(bag) or 0 do
				local id = ItemOfLink(GetContainerItemLink(bag, slot))
				if id then
					local _, count = GetContainerItemInfo(bag, slot)
					ids[id] = (ids[id] or 0) + (count or 1)
				end
			end
		end
		local live = {}
		for slot = 1, GetContainerNumSlots(REAGENT_BAG) or 0 do
			local link = GetContainerItemLink(REAGENT_BAG, slot)
			if link then
				local _, count = GetContainerItemInfo(REAGENT_BAG, slot)
				live[#live + 1] = { ItemOfLink(link), link:match("%[(.-)%]"), count or 1 }
			end
		end
		-- пустой ответ вдали от банка не затирает запомненное (хранилище могло ещё не загрузиться)
		if #live > 0 or CP.bankIsOpen then DB().reagentBag = live end
		for _, e in ipairs(DB().reagentBag or {}) do
			if e[1] then ids[e[1]] = (ids[e[1]] or 0) + e[3] end
		end
	end
	-- пересчёт не чаще раза за кадр
	CreateFrame("Frame"):SetScript("OnUpdate", function() stamp = nil end)
	function CP.BagCount(id)
		if not stamp then Scan() stamp = true end
		return (id and ids[id]) or 0
	end
end
function CP.BankCount(id)
	local bank = DB().bank
	return (id and bank and bank[id]) or 0
end
function CP.Have(id) return CP.BagCount(id) + CP.BankCount(id) end

-- Банк: запоминаем содержимое, пока он открыт
local function ScanBank()
	if not CP.bankIsOpen then return end
	local bank = {}
	local bags = { BANK_CONTAINER or -1 }
	for b = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do bags[#bags + 1] = b end
	for _, bag in ipairs(bags) do
		for slot = 1, GetContainerNumSlots(bag) or 0 do
			local id = ItemOfLink(GetContainerItemLink(bag, slot))
			if id then
				local _, count = GetContainerItemInfo(bag, slot)
				bank[id] = (bank[id] or 0) + (count or 1)
			end
		end
	end
	DB().bank = bank
end

----------------------------------------------------------------------------------------------
-- Окно профессии: изученные рецепты (название, изделие, материалы, перезарядка)
local scanning = false
function CP.ScanTradeSkill(expand)
	if scanning then return end
	if IsTradeSkillLinked and IsTradeSkillLinked() then return end -- чужая профессия по ссылке
	local profName, rank, maxRank = GetTradeSkillLine()
	if not profName or profName == "UNKNOWN" then return end
	scanning = true
	-- свёрнутые разделы прячут рецепты — разворачиваем, только при открытии окна
	if expand then
		for i = GetNumTradeSkills(), 1, -1 do
			local _, kind, _, expanded = GetTradeSkillInfo(i)
			if kind == "header" and not expanded then ExpandTradeSkillSubClass(i) end
		end
	end
	local recipes = {}
	for i = 1, GetNumTradeSkills() do
		local name, kind = GetTradeSkillInfo(i)
		if name and kind ~= "header" then
			local rec = {
				name = name, kind = kind, icon = GetTradeSkillIcon(i), link = GetTradeSkillItemLink(i),
				tools = GetTradeSkillTools and GetTradeSkillTools(i) or nil,
				made = GetTradeSkillNumMade and GetTradeSkillNumMade(i) or 1, reagents = {},
			}
			for j = 1, GetTradeSkillNumReagents(i) do
				local rName, rIcon, rCount = GetTradeSkillReagentInfo(i, j)
				local rID = ItemOfLink(GetTradeSkillReagentItemLink(i, j))
				if rName or rID then rec.reagents[#rec.reagents + 1] = { id = rID, name = rName, icon = rIcon, count = rCount or 1 } end
			end
			local cd = GetTradeSkillCooldown and GetTradeSkillCooldown(i)
			if cd and cd > 0 then rec.cdEnd = time() + cd end
			recipes[#recipes + 1] = rec
		end
	end
	DB().profs[profName] = { rank = rank, max = maxRank, recipes = recipes, scanned = time() }
	scanning = false
	CP.Changed()
end

-- Изучен ли рецепт (по последнему открытию окна профессии)
function CP.KnownRecipe(prof, name)
	local p = DB().profs[prof]
	for _, rec in ipairs(p and p.recipes or {}) do
		if rec.name == name then return rec end
	end
end

----------------------------------------------------------------------------------------------
-- Учитель: с какого навыка учится рецепт и сколько стоит. learn[навык][название] = { req, cost }
local function ScanTrainer()
	if not (IsTradeskillTrainer and IsTradeskillTrainer()) then return end
	local db = DB()
	db.learn = db.learn or {}
	local changed = false
	for i = 1, GetNumTrainerServices() do
		local name, _, kind = GetTrainerServiceInfo(i)
		local ok, skill = pcall(GetTrainerServiceSkillLine, i)
		local sk = ok and skill and CP.SKILL_ID[skill]
		if name and sk and kind ~= "header" then
			local _, req = GetTrainerServiceSkillReq(i)
			local t = db.learn[sk] or {}
			db.learn[sk] = t
			local cost = GetTrainerServiceCost(i) or 0
			local old = t[name]
			if not (old and old.req == (req or 0) and old.cost == cost) then changed = true end
			t[name] = { req = req or 0, cost = cost }
		end
	end
	if changed then CP.Changed() end
end

-- С какого навыка учится рецепт: учитель, иначе «Требуется: … (N)» в подсказке рецепта-предмета
-- (db.bookReq[предмет]); нет данных — nil
local reqTip, reqMiss = nil, {}
function CP.BookReq(item, prof)
	local db = DB()
	db.bookReq = db.bookReq or {}
	if db.bookReq[item] or reqMiss[item] then return db.bookReq[item] end
	if not GetItemInfo(item) then return nil end -- нет в кэше игры — спросим, когда придёт
	reqMiss[item] = true -- строки «Требуется» нет — больше не читаем подсказку в эту сессию
	reqTip = reqTip or CreateFrame("GameTooltip", "CraftPlanReqTip", UIParent, "GameTooltipTemplate")
	reqTip:SetOwner(UIParent, "ANCHOR_NONE")
	reqTip:SetHyperlink("item:" .. item)
	for i = 2, reqTip:NumLines() do
		local fs = _G["CraftPlanReqTipTextLeft" .. i]
		local text = fs and fs:GetText()
		local n = text and text:find(prof, 1, true) and tonumber(text:match("%((%d+)%)"))
		if n then db.bookReq[item] = n break end
	end
	reqTip:Hide()
	return db.bookReq[item]
end

----------------------------------------------------------------------------------------------
-- Перерисовка после изменений: не чаще раза в 0.3 с (BAG_UPDATE идёт пачками)
local listeners = {}
function CP.OnChange(fn) listeners[#listeners + 1] = fn end
local due
local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function(self)
	if GetTime() < due then return end
	self:Hide()
	if InCombatLockdown() then
		due = GetTime() + 1
		self:Show()
		return
	end
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn)
		if not ok then CP.Print("|cffff4040ошибка:|r " .. tostring(err)) end
	end
end)
function CP.Changed(delay)
	if CP.DropCache then CP.DropCache() end
	local t = GetTime() + (delay or 0.3)
	if not ticker:IsShown() or t < due then due = t end
	ticker:Show()
end
-- пересчёт через sec после ПОСЛЕДНЕГО вызова (щелчки «+»/«-» подряд — один пересчёт)
function CP.ChangedSettle(sec)
	if CP.DropCache then CP.DropCache() end
	due = GetTime() + (sec or 0.5)
	ticker:Show()
end
-- ещё один пересчёт позже (после создания: игра обновляет навык с задержкой)
local later = CreateFrame("Frame")
later:Hide()
later:SetScript("OnUpdate", function(self)
	if GetTime() < self.at then return end
	self:Hide()
	CP.Changed()
end)
function CP.ChangedLater(sec)
	later.at = GetTime() + (sec or 1.5)
	later:Show()
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "BAG_UPDATE", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "SKILL_LINES_CHANGED",
	"BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "TRAINER_SHOW", "TRAINER_UPDATE", "PLAYER_REGEN_ENABLED" }) do
	events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		local db = DB()
		-- настройки, убранные в 2.0
		db.allowChance, db.hideUseless, db.oreOff, db.nodeApplied, db.noBank = nil, nil, nil, nil, nil
		if CP.OnLogin then CP.OnLogin() end
		CP.Changed()
	elseif event == "BANKFRAME_OPENED" then
		CP.bankIsOpen = true
		ScanBank()
		CP.Changed()
	elseif event == "BANKFRAME_CLOSED" then
		CP.bankIsOpen = false -- не читаем: банк уже недоступен и записался бы пустым
	elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "BAG_UPDATE" then
		ScanBank()
		CP.Changed()
	elseif event == "TRADE_SKILL_SHOW" then
		CP.ScanTradeSkill(true)
	elseif event == "TRADE_SKILL_UPDATE" then
		CP.ScanTradeSkill(false)
	elseif event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
		pcall(ScanTrainer)
	else
		CP.Changed()
	end
end)

-- Выбрать рецепт в открытом окне профессии и подставить количество
function CP.SelectRecipe(prof, recipeName, count)
	if not (TradeSkillFrame and TradeSkillFrame:IsShown()) or GetTradeSkillLine() ~= prof then
		CP.Print("откройте окно профессии «" .. prof .. "» и щёлкните ещё раз.")
		return
	end
	for i = 1, GetNumTradeSkills() do
		local name, kind = GetTradeSkillInfo(i)
		if name == recipeName and kind ~= "header" then
			TradeSkillFrame_SetSelection(i)
			TradeSkillFrame_Update()
			if count and TradeSkillInputBox then TradeSkillInputBox:SetNumber(count) end
			return
		end
	end
	CP.Print("рецепт «" .. recipeName .. "» не найден в окне — снимите фильтры в окне профессии.")
end

SLASH_CRAFTPLAN1 = "/cplan"
SlashCmdList["CRAFTPLAN"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "min" then
		if CP.ToggleCollapsed then CP.ToggleCollapsed() end
	elseif msg == "reset" then
		DB().profs = {}
		CP.Print("рецепты забыты. Откройте окна профессий, чтобы аддон узнал их заново.")
		CP.Changed()
	elseif msg == "" or msg == "map" then
		if CP.ToggleWindow then CP.ToggleWindow() end
	else
		CP.Print(CP.VERSION .. ": /cplan — окно, /cplan min — свернуть полосу, /cplan reset — забыть рецепты.")
	end
end
