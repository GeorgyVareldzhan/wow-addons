-- CraftPlan: полоса вверху экрана — что можно скрафтить из сумок прямо сейчас, чтобы поднять
-- профессии как можно выше. Общие ингредиенты (например, слитки для кузнечного дела и ювелирного
-- дела) делятся между профессиями так, чтобы в сумме получить больше очков навыка.
--
-- Игра отдаёт рецепты только при открытом окне профессии, поэтому каждую профессию нужно
-- один раз открыть: аддон запомнит рецепты и их цвет. Цвет меняется с ростом навыка —
-- время от времени открывайте окно профессии, чтобы список обновился.

-- Ожидаемый прирост навыка за одно создание по цвету рецепта
local GAIN = {
	optimal = 1,    -- оранжевый: навык растёт всегда
	medium = 0.5,   -- жёлтый: чаще всего
	easy = 0.15,    -- зелёный: изредка
}                   -- серый (trivial): не растёт, в план не попадает
local COLOR = {
	optimal = { 1, 0.5, 0.25 },
	medium = { 1, 1, 0 },
	easy = { 0.25, 0.75, 0.25 },
	trivial = { 0.5, 0.5, 0.5 },
}
local COLOR_NAME = { optimal = "оранжевый", medium = "жёлтый", easy = "зелёный", trivial = "серый" }

local ICON_SIZE = 32
local COLLAPSE_SIZE = 24 -- стрелка «свернуть/развернуть» справа от значков полосы
local ICON_GAP = 6
local MAX_ICONS = 14
local BATCH = 5           -- сколько создать за один шаг распределения (меньше — честнее делятся общие ингредиенты)
local REFRESH_DELAY = 1   -- пересчёт после изменения сумок, сек (реже — меньше нагрузки)

-- Названия для окна «Назначение клавиш»
BINDING_HEADER_CRAFTPLAN = "CraftPlan (профессии)"
BINDING_NAME_CRAFTPLAN_MAP = "Открыть/закрыть карту крафта"
BINDING_NAME_CRAFTPLAN_COLLAPSE = "Свернуть/развернуть полосу"

-- Общая таблица аддона: создаётся сразу, поля добавляются по ходу файла
CraftPlan = {}

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCraftPlan:|r " .. msg)
end

local function DB()
	CraftPlanDB = CraftPlanDB or {}
	CraftPlanDB.profs = CraftPlanDB.profs or {}
	return CraftPlanDB
end

----------------------------------------------------------------------------------------------
-- Чтение рецептов из открытого окна профессии
local scanning = false
local lastScan = 0
local function ScanTradeSkill(expand)
	if scanning then return end
	if IsTradeSkillLinked and IsTradeSkillLinked() then return end -- чужая профессия по ссылке
	local profName, rank, maxRank = GetTradeSkillLine()
	if not profName or profName == "UNKNOWN" then return end
	scanning = true

	lastScan = GetTime()
	-- свёрнутые разделы прячут рецепты — разворачиваем все, но только при открытии окна
	-- (каждое разворачивание вызывает новое обновление окна — иначе они гоняли бы друг друга)
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
				name = name,
				kind = kind,
				icon = GetTradeSkillIcon(i),
				link = GetTradeSkillItemLink(i),
				tools = GetTradeSkillTools and GetTradeSkillTools(i) or nil,
				made = GetTradeSkillNumMade and GetTradeSkillNumMade(i) or 1, -- сколько штук за раз (меньшее из разброса)
				reagents = {},
			}
			for j = 1, GetTradeSkillNumReagents(i) do
				local rName, rIcon, rCount = GetTradeSkillReagentInfo(i, j)
				local rLink = GetTradeSkillReagentItemLink(i, j)
				local rID = rLink and tonumber(rLink:match("item:(%d+)"))
				if rName or rID then
					rec.reagents[#rec.reagents + 1] = { id = rID, name = rName, icon = rIcon, count = rCount or 1 }
				end
			end
			-- рецепт с перезарядкой (трансмутации и т.п.): запоминаем, когда снова можно
			local cd = GetTradeSkillCooldown and GetTradeSkillCooldown(i)
			if cd and cd > 0 then
				rec.cooldown = true
				rec.cdEnd = time() + cd
			end
			recipes[#recipes + 1] = rec
		end
	end
	-- рецепты с перезарядкой помним и после того, как она прошла
	local old = DB().profs[profName]
	if old then
		local wasCd = {}
		for _, r in ipairs(old.recipes) do
			if r.cooldown then wasCd[r.name] = true end
		end
		for _, r in ipairs(recipes) do
			if wasCd[r.name] then r.cooldown = true end
		end
	end

	local db = DB()
	db.profs[profName] = { rank = rank, max = maxRank, recipes = recipes, scanned = time() }
	scanning = false
end

-- Обновить уровень навыка профессий без открытия окна
local function UpdateRanks()
	local db = DB()
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
		local p = name and not isHeader and db.profs[name]
		if p then
			if p.rank ~= rank then p.stale = true end -- цвета рецептов могли смениться
			p.rank, p.max = rank, maxRank
		end
	end
end

----------------------------------------------------------------------------------------------
-- План: жадно выбираем самый выгодный рецепт, на который хватает ингредиентов, «создаём»
-- его небольшой пачкой и повторяем. Выгода — ожидаемый прирост навыка, делённый на то,
-- какую долю запаса ингредиентов он съедает: так общие ингредиенты достаются тому рецепту,
-- который даёт за них больше очков.
local function ReagentKey(r) return r.id or r.name end

-- Номер навыка профессии (для таблицы порогов CraftPlanThresholds в конце файла)
local SKILL_ID = {
	["Кузнечное дело"] = 164, ["Кожевничество"] = 165, ["Алхимия"] = 171, ["Кулинария"] = 185,
	["Горное дело"] = 186, ["Портняжное дело"] = 197, ["Инженерное дело"] = 202, ["Наложение чар"] = 333,
	["Ювелирное дело"] = 755, ["Начертание"] = 773, ["Первая помощь"] = 129,
}

-- Пороги цвета рецепта: жёлтый с навыка, серый с навыка (или nil, если неизвестны)
local function Thresholds(prof, recName)
	local t = CraftPlanThresholds and SKILL_ID[prof] and CraftPlanThresholds[SKILL_ID[prof]]
	local v = t and t[recName]
	if v then return v[1], v[2] end
end

-- Цвет рецепта при данном навыке: оранжевый до жёлтого порога, жёлтый до середины между
-- жёлтым и серым, зелёный до серого, дальше серый (так считает сервер; сверено с игрой)
local function KindAt(yellow, grey, rank)
	if rank < yellow then return "optimal" end
	if rank < math.floor((yellow + grey) / 2) then return "medium" end
	if rank < grey then return "easy" end
	return "trivial"
end

-- Подсказка о порогах: «Оранжевый ещё 4 раза (до 95). Жёлтый до 102, зелёный до 110, дальше серый.»
local function ColorInfo(prof, recName)
	local y, g = Thresholds(prof, recName)
	local p = DB().profs[prof]
	if not (y and p and p.rank) then return nil end
	local mid = math.floor((y + g) / 2)
	local r = p.rank
	local now
	if r < y then
		now = "|cffff8040Оранжевый ещё " .. (y - r) .. " раз|r (навык сейчас " .. r .. ", жёлтым станет с " .. y .. ")."
	elseif r < mid then
		now = "|cffffff00Жёлтый|r до навыка " .. mid .. ": навык растёт с шансом."
	elseif r < g then
		now = "|cff40c040Зелёный|r до навыка " .. g .. ": навык растёт редко."
	else
		now = "|cff999999Серый|r: навык не растёт."
	end
	return now .. " Пороги: жёлтый с " .. y .. ", зелёный с " .. mid .. ", серый с " .. g .. "."
end

-- Пересчитать цвета всех запомненных рецептов по текущему навыку — не нужно открывать окно
local function RecolorAll()
	for profName, p in pairs(DB().profs) do
		local allKnown = true
		for _, rec in ipairs(p.recipes) do
			local y, g = Thresholds(profName, rec.name)
			if y and p.rank then rec.kind = KindAt(y, g, p.rank) else allKnown = false end
		end
		if allKnown then p.stale = nil end
	end
end
-- Подсказка к предмету: в каких рецептах ваших профессий он пригодится. Изученные — цветом
-- рецепта (оранжевый/жёлтый/зелёный/серый), ещё не изученные — красным (только пока они дают навык).
local SKILL_NAME = {}
for profName, id in pairs(SKILL_ID) do SKILL_NAME[id] = profName end
local KIND_ORDER = { optimal = 1, medium = 2, easy = 3, trivial = 4 }
local TIP_PER_PROF = 6 -- больше строк на профессию не выводим

local function AddUsesToTooltip(tip)
	if not CraftPlanReagents then return end
	local _, link = tip:GetItem()
	local itemID = link and tonumber(link:match("item:(%d+)"))
	local uses = itemID and CraftPlanReagents[itemID]
	if not uses then return end
	-- профессии персонажа и навык — прямо из окна навыков
	local ranks = {}
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank = GetSkillLineInfo(i)
		if name and not isHeader and SKILL_ID[name] then ranks[name] = rank end
	end
	local byProf = {}
	for i = 1, #uses, 2 do
		local profName = SKILL_NAME[uses[i]]
		local recName = uses[i + 1]
		local rank = profName and ranks[profName]
		if rank then
			local p = DB().profs[profName]
			local known
			if p and p.recipes and p.scanned then
				for _, rec in ipairs(p.recipes) do
					if rec.name == recName then known = rec break end
				end
			end
			local y, g = Thresholds(profName, recName)
			local e
			if known then
				local kind = (y and KindAt(y, g, rank)) or known.kind
				e = { name = recName, kind = kind, order = KIND_ORDER[kind] or 5, y = y or 0 }
			elseif not (p and p.scanned) then
				-- окно профессии ещё не открывали: изученность неизвестна, показываем цвет по навыку
				if y then
					local kind = KindAt(y, g, rank)
					e = { name = recName, kind = kind, order = (KIND_ORDER[kind] or 5) + 10, y = y, unsure = true }
				end
			elseif not g or rank < g then
				e = { name = recName, red = true, order = 20, y = y or 0 }
			end
			if e then
				byProf[profName] = byProf[profName] or {}
				table.insert(byProf[profName], e)
			end
		end
	end
	local first = true
	for profName, list in pairs(byProf) do
		table.sort(list, function(a, b)
			if a.order ~= b.order then return a.order < b.order end
			if a.y ~= b.y then return a.y < b.y end
			return a.name < b.name
		end)
		if first then tip:AddLine("CraftPlan — пригодится:", 0.4, 0.8, 1) first = false end
		local p = DB().profs[profName]
		tip:AddLine(profName .. " (" .. ranks[profName] .. ")" ..
			((p and p.scanned) and "" or " — откройте окно профессии, чтобы отметить изученные"), 1, 0.82, 0, true)
		for k = 1, math.min(#list, TIP_PER_PROF) do
			local e = list[k]
			if e.red then
				tip:AddDoubleLine("  " .. e.name, "не изучен" .. (e.y > 0 and (", оранж. до " .. e.y) or ""),
					1, 0.2, 0.2, 0.8, 0.4, 0.4)
			else
				local c = COLOR[e.kind] or COLOR.trivial
				tip:AddDoubleLine("  " .. e.name, COLOR_NAME[e.kind] or "", c[1], c[2], c[3], c[1], c[2], c[3])
			end
		end
		if #list > TIP_PER_PROF then
			tip:AddLine("  и ещё " .. (#list - TIP_PER_PROF), 0.6, 0.6, 0.6)
		end
	end
	if not first then tip:Show() end
end
for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
	tip:HookScript("OnTooltipSetItem", AddUsesToTooltip)
end

-- Значок для требования рецепта «нужно рядом / в сумке» (текст игры, например
-- «находиться рядом с горном»). Первое подходящее по порядку.
local TOOL_ICONS = {
	{ "очаг", "Interface\\Icons\\Spell_Fire_Fire" },              -- огонь для кулинарии
	{ "огн", "Interface\\Icons\\Spell_Fire_Fire" },
	{ "костр", "Interface\\Icons\\Spell_Fire_Fire" },
	{ "горн", "Interface\\Icons\\Achievement_Cooking_MasteroftheOven" }, -- кузнечный горн (печь с огнём)
	{ "наковальн", "Interface\\Icons\\Trade_BlackSmithing" },    -- наковальня
	{ "ювелир", "Interface\\Icons\\INV_Misc_Gem_02" },           -- набор ювелира
}
-- Инструменты-предметы: если лежат в сумке, требование выполнено и значок не нужен
local TOOL_ITEMS = {
	{ "ювелир", 20815 }, -- Набор ювелира
}
-- Чего из требования рецепта не хватает: nil — ничего (или требования нет)
local function MissingTool(tools)
	if not tools or tools == "" then return nil end
	for _, t in ipairs(TOOL_ITEMS) do
		if tools:find(t[1], 1, true) then
			if GetItemCount(t[2]) > 0 then return nil end
			return tools, true
		end
	end
	return tools
end
-- Подпись требования: «Необходимо: Набор ювелира (нет в сумках)» / «Необходимо рядом: наковальня»
local function ToolText(tools)
	local miss, isItem = MissingTool(tools)
	if not miss then return nil end
	if isItem then return "Необходимо: " .. miss .. " (нет в сумках)" end
	return "Необходимо рядом: " .. miss
end
local function ToolIcon(tools)
	if not MissingTool(tools) then return nil end
	for _, t in ipairs(TOOL_ICONS) do
		if tools:find(t[1], 1, true) then return t[2] end
	end
	return "Interface\\Icons\\Trade_Engineering" -- прочие инструменты
end

local function ItemOfLink(link) return link and tonumber(link:match("item:(%d+)")) end

-- Сколько предмета есть: в сумках (игра знает всегда) и в банке (аддон запоминает, когда банк открыт)
local function BagCount(r) return GetItemCount(r.id or r.name) or 0 end
local function BankCount(r)
	if DB().noBank then return 0 end -- «Учитывать банк» выключено
	local bank = DB().bank
	return (r.id and bank and bank[r.id]) or 0
end
local function TotalCount(r) return BagCount(r) + BankCount(r) end

-- «12» или «12 (+30 в банке)»
local function CountText(r)
	local bags, bank = BagCount(r), BankCount(r)
	return bank > 0 and (bags .. " |cff88bbff(+" .. bank .. " в банке)|r") or tostring(bags)
end

-- Предмет продаётся у торговца без ограничения (аддон запомнил при посещении торговца)
local function VendorInfo(r)
	local v = DB().vendor
	return r.id and v and v[r.id]
end

-- Цена в медных монетах → «1з 2с 30м»
local function Money(copper)
	copper = math.floor(copper + 0.5)
	local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local t = {}
	-- значки монет, как в окне торговца
	if g > 0 then t[#t + 1] = g .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t" end
	if sv > 0 then t[#t + 1] = sv .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t" end
	if c > 0 or #t == 0 then t[#t + 1] = c .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" end
	return table.concat(t, " ")
end

----------------------------------------------------------------------------------------------
-- Банк: запоминаем содержимое, пока он открыт
local bankOpen = false
local function ScanBank()
	if not bankOpen then return end
	local bank = {}
	local bags = { BANK_CONTAINER or -1 }
	for b = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do bags[#bags + 1] = b end
	for _, bag in ipairs(bags) do
		for slot = 1, GetContainerNumSlots(bag) or 0 do
			local link = GetContainerItemLink(bag, slot)
			local id = link and tonumber(link:match("item:(%d+)"))
			if id then
				local _, count = GetContainerItemInfo(bag, slot)
				bank[id] = (bank[id] or 0) + (count or 1)
			end
		end
	end
	DB().bank = bank
	DB().bankTime = time()
end

-- Торговцы: запоминаем материалы для известных рецептов, которые продаются без ограничения
local function ScanMerchant()
	local wanted = {}
	for _, p in pairs(DB().profs) do
		for _, rec in ipairs(p.recipes) do
			for _, r in ipairs(rec.reagents) do
				if r.id then wanted[r.id] = true end
			end
		end
	end
	local db = DB()
	db.vendor = db.vendor or {}
	local npc, zone = UnitName("npc"), GetRealZoneText()
	-- что на самом деле продаёт этот торговец (по номеру NPC) — точнее базы Questie
	local guid = UnitGUID("npc")
	local npcId = guid and tonumber(guid:sub(-12, -7), 16)
	local stock = {}
	db.vendorStock = db.vendorStock or {}
	for i = 1, GetMerchantNumItems() do
		local link = GetMerchantItemLink(i)
		local id = link and tonumber(link:match("item:(%d+)"))
		if id then stock[id] = true end
	end
	if npcId and next(stock) then db.vendorStock[npcId] = stock end
	if CraftPlan.UpdateQuestieVendors then pcall(CraftPlan.UpdateQuestieVendors) end
	for i = 1, GetMerchantNumItems() do
		local link = GetMerchantItemLink(i)
		local id = link and tonumber(link:match("item:(%d+)"))
		local _, _, price, quantity, numAvailable = GetMerchantItemInfo(i)
		if id and wanted[id] and price and numAvailable == -1 then
			db.vendor[id] = { price = price / math.max(1, quantity or 1), npc = npc, zone = zone }
		end
	end
end

local NEED_CRAFTS = 10 -- для рецептов без известных порогов: на сколько созданий вперёд считать

-- Расчёт идёт по кусочкам: каждые ~8 мс отдаёт кадр игре (coroutine), чтобы клиент не замирал
local SLICE_MS = 8
local sliceStart = 0
local function Now() return debugprofilestop and debugprofilestop() or GetTime() * 1000 end
local function Breathe()
	if coroutine.running() and Now() - sliceStart > SLICE_MS then
		coroutine.yield()
	end
end

-- Расчёт плана. Один расчёт для полосы, карты и списка «Как качать дальше»:
--  * plan — что создать из того, что есть (сумки и банк), с промежуточными шагами;
--  * cont — что делать дальше по каждой профессии, когда имеющееся кончится: чего не хватает.
-- Навык растёт по ходу плана: оранжевое создание даёт ровно +1, на пороге рецепт желтеет.
-- Жёлтые и зелёные рецепты дают навык только с шансом — по умолчанию план их не берёт.
local function BuildPlan()
	local db = DB()
	local allowChance = db.allowChance

	-- кто что производит: номер предмета → рецепт (например, медный слиток ← выплавка меди)
	local producers = {}
	for profName, p in pairs(db.profs) do
		for _, rec in ipairs(p.recipes) do
			local id = ItemOfLink(rec.link)
			if id and #rec.reagents > 0 and not producers[id] then producers[id] = { rec = rec, prof = profName } end
		end
	end

	-- Можно ли вообще получить материал: есть в запасе или делается из того, что можно получить.
	-- Отсекает заведомо невозможные рецепты до перебора — это главное ускорение.
	local reachable = {}
	local function Reachable(r, depth)
		local key = ReagentKey(r)
		if reachable[key] ~= nil then return reachable[key] end
		if TotalCount(r) > 0 then reachable[key] = true return true end
		local pr = r.id and producers[r.id]
		if not pr or depth > 4 then reachable[key] = false return false end
		reachable[key] = false -- защита от круговых рецептов
		for _, rr in ipairs(pr.rec.reagents) do
			if not Reachable(rr, depth + 1) then return false end
		end
		reachable[key] = true
		return true
	end

	local now = time()
	local base = {}
	for profName, p in pairs(db.profs) do
		for _, rec in ipairs(p.recipes) do
			Breathe()
			local ok = #rec.reagents > 0 and not (rec.cdEnd and rec.cdEnd > now)
			if ok then
				for _, r in ipairs(rec.reagents) do
					if not Reachable(r, 0) then ok = false break end
				end
			end
			if ok then base[#base + 1] = { prof = profName, rec = rec } end
		end
	end

	-- Один проход плана. alpha — насколько важна экономия материала, favored — профессия,
	-- которой отдаётся приоритет. Проходов несколько, берётся лучший по точному приросту.
	local function Run(alpha, favored)
		local have = {}
		local function Have(key, r)
			if have[key] == nil then have[key] = TotalCount(r) end
			return have[key]
		end

		-- Можно ли создать rec n раз из запаса, по пути создавая промежуточное (руда → слиток)
		local function Simulate(rec, n)
			local use, steps, extra, ok = {}, {}, {}, true
			local function Require(r, amount, depth)
				if not ok then return end
				local key = ReagentKey(r)
				local e = extra[key] or 0 -- остаток от промежуточного создания
				local fromExtra = math.min(e, amount)
				extra[key] = e - fromExtra
				amount = amount - fromExtra
				if amount <= 0 then return end
				local take = math.min(Have(key, r) - (use[key] or 0), amount)
				if take > 0 then
					use[key] = (use[key] or 0) + take
					amount = amount - take
				end
				if amount <= 0 then return end
				local pr = r.id and producers[r.id]
				if not pr or depth >= 4 or pr.rec == rec or (pr.rec.cdEnd and pr.rec.cdEnd > now) then ok = false return end
				local made = math.max(1, pr.rec.made or 1)
				local times = math.ceil(amount / made)
				steps[#steps + 1] = { rec = pr.rec, prof = pr.prof, times = times }
				for _, rr in ipairs(pr.rec.reagents) do Require(rr, rr.count * times, depth + 1) end
				extra[key] = (extra[key] or 0) + times * made - amount
			end
			for _, r in ipairs(rec.reagents) do Require(r, r.count * n, 0) end
			return ok, use, steps, extra
		end

		local rank, left = {}, {}
		for profName, p in pairs(db.profs) do
			rank[profName] = p.rank or 0
			left[profName] = math.max(0, (p.max or 0) - (p.rank or 0))
		end

		-- цвет рецепта при навыке в плане и сколько раз он ещё останется оранжевым
		local function KindNow(prof, rec)
			local y, g = Thresholds(prof, rec.name)
			if y then return KindAt(y, g, rank[prof]), math.max(0, y - rank[prof]) end
			return rec.kind, nil
		end

		local plan, byRec, total, chance, order = {}, {}, {}, {}, 0
		local function AddEntry(prof, rec, n, isStep, forName)
			local entry = byRec[rec]
			if not entry then
				order = order + 1
				entry = { prof = prof, rec = rec, count = 0, gain = 0, chance = 0, order = order, forNames = {}, rankFrom = rank[prof] }
				byRec[rec] = entry
				plan[#plan + 1] = entry
			end
			-- сколько из n созданий точно дадут навык (оранжевые), а сколько — с шансом
			local kind, orangeLeft = KindNow(prof, rec)
			local sure, maybe = 0, 0
			if kind == "optimal" and left[prof] > 0 then
				sure = math.min(n, orangeLeft or n, left[prof])
			end
			if sure < n and left[prof] - sure > 0 then
				local k2 = kind -- цвет после оранжевых созданий
				local y, g = Thresholds(prof, rec.name)
				if y and sure > 0 then k2 = KindAt(y, g, rank[prof] + sure) end
				if k2 ~= "trivial" then maybe = n - sure end
			end
			rank[prof] = rank[prof] + sure
			left[prof] = left[prof] - sure
			total[prof] = (total[prof] or 0) + sure
			if maybe > 0 then chance[prof] = (chance[prof] or 0) + maybe end
			entry.count = entry.count + n
			entry.gain = entry.gain + sure
			entry.chance = entry.chance + maybe
			entry.rankTo = rank[prof]
			if isStep then
				entry.step = true
				if forName then entry.forNames[forName] = true end
			end
			return entry
		end

		for _ = 1, 300 do
			local best, bestScore, bestMax
			for _, c in ipairs(base) do
				Breathe()
				local kind, orangeLeft = KindNow(c.prof, c.rec)
				local w = GAIN[kind]
				if kind ~= "optimal" and not allowChance then w = nil end
				if c.rec.cooldown and byRec[c.rec] then w = nil end -- рецепт с перезарядкой — один раз
				if w and left[c.prof] > 0 then
					local ok, use = Simulate(c.rec, 1)
					if ok then
						local cost = 0
						for key, amount in pairs(use) do cost = cost + amount / math.max(1, have[key]) end
						local score = w * w / math.max(cost, 0.0001) ^ alpha
						if favored == c.prof then score = score * 1000 end
						if not bestScore or score > bestScore then
							local cap = BATCH
							if kind == "optimal" then cap = math.min(cap, orangeLeft or cap, left[c.prof]) end
							if c.rec.cooldown then cap = 1 end
							cap = math.max(1, cap)
							local maxN = 1
							while maxN < cap and (Simulate(c.rec, maxN + 1)) do maxN = maxN + 1 end
							best, bestScore, bestMax = c, score, maxN
						end
					end
				end
			end
			if not best then break end

			local n = bestMax
			local _, use, steps, extra = Simulate(best.rec, n)
			for key, amount in pairs(use) do have[key] = have[key] - amount end
			for key, amount in pairs(extra) do
				if amount > 0 then have[key] = (have[key] or 0) + amount end
			end
			for _, st in ipairs(steps) do AddEntry(st.prof, st.rec, st.times, true, best.rec.name) end
			local final = AddEntry(best.prof, best.rec, n, false)
			final.prereq = final.prereq or {}
			for _, st in ipairs(steps) do
				local pr = final.prereq[st.rec]
				if not pr then
					pr = { rec = st.rec, prof = st.prof, times = 0 }
					final.prereq[st.rec] = pr
				end
				pr.times = pr.times + st.times
			end
		end

		local sum = 0
		for _, v in pairs(total) do sum = sum + v end
		return { plan = plan, total = total, chance = chance, have = have, rank = rank, left = left, sum = sum,
			Simulate = Simulate, KindNow = KindNow }
	end

	-- несколько стратегий: разная цена материала и приоритет каждой профессии; лучший — по
	-- точному приросту (при равенстве — тот, что тратит меньше созданий «на шанс»)
	local best
	local runsTotal, runsDone = 1, 0
	local function Consider(r)
		runsDone = runsDone + 1
		CraftPlan.progress = 0.1 + 0.85 * runsDone / runsTotal
		local function chanceSum(x) local c = 0 for _, v in pairs(x.chance) do c = c + v end return c end
		if not best or r.sum > best.sum or (r.sum == best.sum and chanceSum(r) < chanceSum(best)) then best = r end
	end
	-- кандидаты только профессий, которым есть куда расти (на максимуме — не перебираем)
	local growing, nGrowing = {}, 0
	for profName, p in pairs(db.profs) do
		if (p.max or 0) > (p.rank or 0) then growing[profName] = true; nGrowing = nGrowing + 1 end
	end
	local kept = {}
	for _, c in ipairs(base) do
		if growing[c.prof] then kept[#kept + 1] = c end
	end
	base = kept
	if #base > 0 then runsTotal = 3 + (nGrowing > 1 and nGrowing or 0) end
	CraftPlan.progress = 0.1 -- подготовка позади

	Consider(Run(1))
	if #base > 0 then
		Consider(Run(0.5))
		Consider(Run(2))
		if nGrowing > 1 then -- приоритет профессии имеет смысл, только если их несколько
			for profName in pairs(growing) do Consider(Run(1, profName)) end
		end
	end

	-- сначала промежуточное (выплавка), потом остальное — в порядке выбора
	table.sort(best.plan, function(a, b)
		if (a.step and true or false) ~= (b.step and true or false) then return a.step and true or false end
		return a.order < b.order
	end)

	-- Дальше: для каждой профессии — самый доступный оранжевый рецепт при навыке после плана
	-- (жёлтый — только если разрешены «с шансом») и чего на него не хватит
	local cont = {}
	local have = best.have
	local function Requirements(rec, times)
		local stock = {}
		local missing, steps = {}, {}
		local function Avail(key, r)
			if stock[key] == nil then
				stock[key] = have[key]
				if stock[key] == nil then stock[key] = TotalCount(r) end
			end
			return stock[key]
		end
		local function Require(r, amount, depth)
			local key = ReagentKey(r)
			local take = math.min(Avail(key, r), amount)
			stock[key] = stock[key] - take
			local short = amount - take
			if short <= 0 then return end
			local pr = r.id and producers[r.id]
			if pr and depth < 4 and not VendorInfo(r) and pr.rec ~= rec then
				local made = math.max(1, pr.rec.made or 1)
				local t = math.ceil(short / made)
				steps[#steps + 1] = { rec = pr.rec, prof = pr.prof, times = t }
				for _, rr in ipairs(pr.rec.reagents) do Require(rr, rr.count * t, depth + 1) end
			else
				local m = missing[key]
				if not m then
					m = { r = r, amount = 0 }
					missing[key] = m
				end
				m.amount = m.amount + short
			end
		end
		for _, r in ipairs(rec.reagents) do Require(r, r.count * times, 0) end
		local cost = 0
		for _, m in pairs(missing) do cost = cost + m.amount * (VendorInfo(m.r) and 0.1 or 1) end
		return missing, steps, cost
	end
	for profName, p in pairs(db.profs) do
		Breathe()
		local r, left = best.rank[profName], best.left[profName]
		local entry = { prof = profName, rank = r, max = p.max or 0 }
		if left <= 0 then
			entry.trainer = true
		else
			local pick, pickCost, pickTimes, pickKind
			for _, want in ipairs(allowChance and { "optimal", "medium" } or { "optimal" }) do
				for _, rec in ipairs(p.recipes) do
					Breathe()
					if #rec.reagents > 0 then
						local kind, orangeLeft = best.KindNow(profName, rec)
						if kind == want then
							local times = (kind == "optimal" and orangeLeft) and math.max(1, math.min(orangeLeft, left))
								or math.min(NEED_CRAFTS, left)
							local _, _, cost = Requirements(rec, times)
							if not pickCost or cost < pickCost then pick, pickCost, pickTimes, pickKind = rec, cost, times, kind end
						end
					end
				end
				if pick then break end
			end
			if pick then
				entry.rec, entry.times, entry.kind = pick, pickTimes, pickKind
				entry.missing, entry.steps = Requirements(pick, pickTimes)
			else
				entry.noRecipes = true
			end
		end
		cont[#cont + 1] = entry
	end
	table.sort(cont, function(a, b) return a.prof < b.prof end)

	return best.plan, best.total, best.chance, cont
end

-- Ингредиенты, которые нужны рецептам сразу нескольких профессий (не серым)
local function SharedReagents()
	local users, info = {}, {}
	for profName, p in pairs(DB().profs) do
		for _, rec in ipairs(p.recipes) do
			if GAIN[rec.kind] then
				for _, r in ipairs(rec.reagents) do
					local key = ReagentKey(r)
					users[key] = users[key] or {}
					users[key][profName] = true
					info[key] = r
				end
			end
		end
	end
	local list = {}
	for key, profs in pairs(users) do
		local names = {}
		for name in pairs(profs) do names[#names + 1] = name end
		if #names > 1 then
			local r = info[key]
			local count = TotalCount(r)
			if count > 0 then
				table.sort(names)
				list[#list + 1] = { name = r.name or ("предмет " .. key), count = count, profs = table.concat(names, ", ") }
			end
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

----------------------------------------------------------------------------------------------
-- Полоса вверху экрана
local bar = CreateFrame("Frame", "CraftPlanBar", UIParent)
-- К полосе привязана защищённая кнопка «Просеять», поэтому в бою игра не даёт её прятать:
-- в бою — прозрачность 0, вне боя — обычное скрытие
CraftPlan.HideBar = function()
	if InCombatLockdown() then bar:SetAlpha(0) else bar:Hide() end
end
bar:SetPoint("TOP", UIParent, "TOP", 0, -6)
bar:SetWidth(400)
bar:SetHeight(ICON_SIZE + 22)
bar:SetFrameStrata("MEDIUM")
bar:SetMovable(true)
bar:SetClampedToScreen(true)

-- Shift + перетаскивание любой иконки — передвинуть полосу; место запоминается
local function BarDragStart() if IsShiftKeyDown() then bar:StartMoving() end end
local function BarDragStop()
	bar:StopMovingOrSizing()
	local point, _, relPoint, x, y = bar:GetPoint()
	DB().barPos = { point, relPoint, x, y }
end
-- индикатор расчёта под полосой: «CraftPlan: считаю план… 45%»
local loader = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
loader:SetPoint("TOP", bar, "BOTTOM", 0, -2)
loader:Hide()

local function RestoreBar()
	local pos = DB().barPos
	if pos then
		bar:ClearAllPoints()
		bar:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	end
end

bar.bg = bar:CreateTexture(nil, "BACKGROUND")
bar.bg:SetAllPoints(bar)
bar.bg:SetTexture(0, 0, 0, 0.45)

-- Строка-сводка по профессиям; при наведении — общие ингредиенты
local summary = CreateFrame("Frame", nil, bar)
summary:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
summary:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
summary:SetHeight(18)
summary:EnableMouse(true)
summary.text = summary:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
summary.text:SetPoint("CENTER", summary, "CENTER", 0, -1)
-- значок свернуть/развернуть слева от сводки; щелчок по строке переключает
summary.toggle = summary:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
summary.toggle:SetPoint("LEFT", summary, "LEFT", 6, -1)

-- Кнопка-значок карты крафта — прямо на полосе, слева от иконок того, что создать
local mapButton = CreateFrame("Button", nil, bar)
mapButton:SetWidth(ICON_SIZE)
mapButton:SetHeight(ICON_SIZE)
mapButton:SetFrameLevel(bar:GetFrameLevel() + 2)
mapButton.border = mapButton:CreateTexture(nil, "BACKGROUND")
mapButton.border:SetPoint("TOPLEFT", mapButton, "TOPLEFT", -2, 2)
mapButton.border:SetPoint("BOTTOMRIGHT", mapButton, "BOTTOMRIGHT", 2, -2)
mapButton.border:SetTexture(0.4, 0.8, 1, 0.9)
mapButton.icon = mapButton:CreateTexture(nil, "ARTWORK")
mapButton.icon:SetAllPoints(mapButton)
mapButton.icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
mapButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
mapButton:SetScript("OnClick", function() if CraftPlan.ToggleMap then CraftPlan.ToggleMap() end end)
mapButton:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:AddLine("Карта крафта", 0.4, 0.8, 1)
	GameTooltip:AddLine("Что из чего делается во всех профессиях: материалы, стрелки, изделия.", 1, 1, 1, true)
	GameTooltip:Show()
end)
mapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
mapButton:RegisterForDrag("LeftButton")
mapButton:SetScript("OnDragStart", BarDragStart)
mapButton:SetScript("OnDragStop", BarDragStop)

-- Стрелка справа от иконок: свернуть полосу (остаётся значок карты) или развернуть.
-- Свёрнутая полоса план не пересчитывает (см. Refresh)
do
	local b = CreateFrame("Button", "CraftPlanCollapse", bar)
	b:SetWidth(COLLAPSE_SIZE)
	b:SetHeight(COLLAPSE_SIZE)
	b:SetFrameLevel(bar:GetFrameLevel() + 2)
	b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	b:SetScript("OnClick", function() if CraftPlan.ToggleCollapsed then CraftPlan.ToggleCollapsed() end end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		if DB().collapsed then
			GameTooltip:AddLine("Развернуть полосу CraftPlan", 0.4, 0.8, 1)
		else
			GameTooltip:AddLine("Свернуть полосу CraftPlan", 0.4, 0.8, 1)
			GameTooltip:AddLine("Останется только значок карты. Пока свёрнуто, план не пересчитывается — посчитается, когда откроете карту крафта, торговца или развернёте.", 1, 1, 1, true)
		end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", BarDragStart)
	b:SetScript("OnDragStop", BarDragStop)
	-- поставить справа от последнего значка; x — правый край значков от центра полосы
	b.Place = function(self, x, collapsed)
		local tex = collapsed and "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up" or "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up"
		self:SetNormalTexture(tex)
		self:SetPushedTexture(collapsed and "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down" or "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
		self:ClearAllPoints()
		self:SetPoint("TOPLEFT", bar, "TOP", x + 2, -2 - (ICON_SIZE - COLLAPSE_SIZE) / 2)
		self:Show()
	end
	CraftPlan.collapseButton = b
end


local icons = {}
local more = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")

local function ShowRecipeTooltip(self)
	local e = self.entry
	if not e then return end
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	if e.rec.link then
		GameTooltip:SetHyperlink(e.rec.link)
		GameTooltip:AddLine(" ")
	else
		GameTooltip:AddLine(e.rec.name, 1, 1, 1)
	end
	local c = COLOR[e.rec.kind] or COLOR.trivial
	GameTooltip:AddLine(e.prof .. ": " .. e.rec.name, c[1], c[2], c[3])
	if e.step then
		local names = {}
		for name in pairs(e.forNames) do names[#names + 1] = name end
		table.sort(names)
		GameTooltip:AddLine("Сначала создайте это: нужно для " .. table.concat(names, ", ") .. ".", 0.53, 0.73, 1, true)
	end
	if e.maxCraft then
		GameTooltip:AddLine("Можно создать из имеющегося: " .. e.maxCraft .. " раз (серое число)", 0.7, 0.7, 0.7)
	end
	GameTooltip:AddLine("По плану создать: " .. e.count .. " раз", 1, 1, 1)
	if e.gain > 0 then
		GameTooltip:AddLine("Навык: +" .. e.gain .. " точно (оранжевые создания)", 0.25, 1, 0.25)
	end
	if e.chance > 0 then
		GameTooltip:AddLine("Ещё " .. e.chance .. " раз — навык с шансом (жёлтый или зелёный рецепт)", 1, 1, 0, true)
	end
	local info = ColorInfo(e.prof, e.rec.name)
	if info then GameTooltip:AddLine(info, 0.8, 0.8, 0.8, true) end
	GameTooltip:AddLine("Ингредиенты (есть / нужно на весь план):", 0.8, 0.8, 0.8)
	local fromBank = false
	for _, r in ipairs(e.rec.reagents) do
		if BagCount(r) < r.count * e.count and BankCount(r) > 0 then fromBank = true end
		GameTooltip:AddDoubleLine("  " .. (r.name or "?"), CountText(r) .. " / " .. (r.count * e.count), 1, 1, 1, 1, 1, 1)
	end
	if fromBank then
		GameTooltip:AddLine("Часть материалов в банке — заберите перед созданием.", 0.53, 0.73, 1, true)
	end
	if e.prereq and next(e.prereq) then
		GameTooltip:AddLine("Сначала создайте из того, что есть:", 0.53, 0.73, 1)
		for _, pr in pairs(e.prereq) do
			GameTooltip:AddDoubleLine("  " .. pr.rec.name .. " x" .. pr.times, pr.prof, 1, 1, 1, 0.7, 0.7, 0.7)
		end
	end
	local toolText = ToolText(e.rec.tools)
	if toolText then GameTooltip:AddLine(toolText, 1, 0.5, 0.25, true) end
	GameTooltip:AddLine("Щелчок — открыть карту крафта с цепочкой этого предмета.", 0.5, 0.8, 1, true)
	GameTooltip:AddLine("Правый щелчок при открытом окне профессии — выбрать рецепт.", 0.5, 0.8, 1, true)
	GameTooltip:Show()
end

-- Выбрать рецепт в открытом окне профессии и подставить количество
local function SelectRecipeByName(prof, recipeName, count)
	local profName = GetTradeSkillLine()
	if not (TradeSkillFrame and TradeSkillFrame:IsShown() and profName == prof) then
		Print("откройте окно профессии «" .. prof .. "» и щёлкните ещё раз.")
		return
	end
	for i = 1, GetNumTradeSkills() do
		if GetTradeSkillInfo(i) == recipeName then
			if TradeSkillFrame_SetSelection then TradeSkillFrame_SetSelection(i) end
			if TradeSkillFrame_Update then TradeSkillFrame_Update() end
			if TradeSkillInputBox and count then TradeSkillInputBox:SetNumber(count) end
			return
		end
	end
	Print("рецепт «" .. recipeName .. "» не найден в окне — снимите фильтры в окне профессии.")
end

local function SelectRecipe(self)
	local e = self.entry
	if e then SelectRecipeByName(e.prof, e.rec.name, e.count) end
end

local function GetIcon(i)
	local f = icons[i]
	if not f then
		f = CreateFrame("Button", nil, bar)
		f:SetWidth(ICON_SIZE)
		f:SetHeight(ICON_SIZE)
		f.border = f:CreateTexture(nil, "BACKGROUND")
		f.border:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
		f.border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
		f.icon = f:CreateTexture(nil, "ARTWORK")
		f.icon:SetAllPoints(f)
		f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		f.count:SetPoint("BOTTOM", f, "BOTTOM", 0, 1)
		-- под иконкой (сейчас не используется — всё в «19/1»)
		f.gainText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		f.gainText:SetPoint("TOP", f, "BOTTOM", 0, -2)
		-- в углу: нужна наковальня / горн / другое рядом
		f.tool = f:CreateTexture(nil, "OVERLAY")
		f.tool:SetTexture("Interface\\Icons\\Trade_BlackSmithing")
		f.tool:SetWidth(12)
		f.tool:SetHeight(12)
		f.tool:SetPoint("TOPRIGHT", f, "TOPRIGHT", 1, 1)
		-- в левом верхнем углу: часть материалов в банке — заберите
		f.bankMark = f:CreateTexture(nil, "OVERLAY")
		f.bankMark:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Blue")
		f.bankMark:SetWidth(12)
		f.bankMark:SetHeight(12)
		f.bankMark:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", BarDragStart)
		f:SetScript("OnDragStop", BarDragStop)
		f:SetScript("OnEnter", ShowRecipeTooltip)
		f:SetScript("OnLeave", function() GameTooltip:Hide() end)
		f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		f:SetScript("OnClick", function(self, button)
			local e = self.entry
			if not e then return end
			if button == "RightButton" then
				SelectRecipe(self)
			elseif CraftPlan.FocusItem then
				CraftPlan.FocusItem(ItemOfLink(e.rec.link) or ("recipe:" .. e.prof .. ":" .. e.rec.name), e.rec.name)
			end
		end)
		icons[i] = f
	end
	return f
end

local function FormatGain(g)
	return (g == math.floor(g)) and tostring(g) or string.format("%.1f", g)
end

-- Сколько раз можно создать рецепт из того, что есть (сумки и банк), включая промежуточное
-- (слитки из руды) до 4 шагов. Каждый рецепт считается отдельно, без дележа общего материала.
local maxMemo = {} -- запоминаем результат на один пересчёт (иначе цепочки считаются много раз)
local function MaxCraftable(rec, producers, depth, visiting)
	if maxMemo[rec] then return maxMemo[rec] end
	if depth > 4 or visiting[rec] then return 0 end
	visiting[rec] = true
	local times = math.huge
	for _, r in ipairs(rec.reagents) do
		local avail = TotalCount(r)
		local pr = r.id and producers[r.id]
		if pr then avail = avail + MaxCraftable(pr, producers, depth + 1, visiting) * math.max(1, pr.made or 1) end
		times = math.min(times, math.floor(avail / math.max(1, r.count)))
	end
	visiting[rec] = nil
	local result = (times == math.huge) and 0 or times
	maxMemo[rec] = result
	return result
end

local lastPlan
-- Применить готовый результат расчёта: полоса, сводка; затем обновить карту и план
local AfterPlan -- задаётся ниже (обновление карты и вкладки «План»)
local function ApplyPlan(fullPlan, total, chance, cont)
	local db = DB()
	CraftPlan.fullPlan, CraftPlan.cont = fullPlan, cont
	-- на полосе только то, что поднимает навык; промежуточное без прироста (серая выплавка)
	-- показывается в подсказке изделия как «сначала создайте»
	local plan = {}
	for _, e in ipairs(fullPlan) do
		-- промежуточный шаг, который даёт навык только с шансом (например, зелёная выплавка),
		-- на полосе не показываем, если «с шансом» не разрешено: он есть в подсказке изделия
		if e.gain > 0 or (e.chance > 0 and db.allowChance) then plan[#plan + 1] = e end
	end
	lastPlan = plan
	local planCount = {}
	for _, e in ipairs(fullPlan) do planCount[e.rec] = (planCount[e.rec] or 0) + e.count end
	CraftPlan.planCount = planCount -- рецепт → сколько создать (для карты «Только план»)
	local planEntry = {}
	for _, e in ipairs(fullPlan) do planEntry[e.rec] = e end
	CraftPlan.planEntry = planEntry

	-- сводка по профессиям (показывается на кнопках профессий в карте крафта):
	-- «88/150 ≈+6», «150/150 (нужен учитель)», «нечего»
	local profSummary = {}
	for profName, p in pairs(db.profs) do
		local s = (p.rank or 0) .. "/" .. (p.max or 0)
		if (p.rank or 0) >= (p.max or 0) then
			s = s .. " |cffff8000(учитель)|r"
		elseif (total[profName] or 0) > 0 or (chance[profName] or 0) > 0 then
			if (total[profName] or 0) > 0 then s = s .. " |cff00ff00+" .. total[profName] .. "|r" end
			if (chance[profName] or 0) > 0 then s = s .. " |cffffff00+шанс|r" end
		else
			s = s .. " |cff999999нечего|r"
		end
		if p.stale then s = s .. "|cffffff00*|r" end
		profSummary[profName] = s
	end
	CraftPlan.profSummary = profSummary
	if db.hidden then
		CraftPlan.HideBar()
		if AfterPlan then AfterPlan() end
		return
	end

	local producers = {}
	for _, p in pairs(db.profs) do
		for _, rec in ipairs(p.recipes) do
			local id = ItemOfLink(rec.link)
			if id and #rec.reagents > 0 and not producers[id] then producers[id] = rec end
		end
	end

	maxMemo = {}

	-- полоса без фона и без строки сводки: только значки
	local n = db.collapsed and 0 or math.min(#plan, MAX_ICONS)
	local width = (n + 1) * ICON_SIZE + n * ICON_GAP -- +1 — значок карты
	mapButton:ClearAllPoints()
	mapButton:SetPoint("TOPLEFT", bar, "TOP", -width / 2, -2)
	for i = 1, n do
		local e = plan[i]
		local f = GetIcon(i)
		f.entry = e
		f.icon:SetTexture(e.rec.icon)
		local c = COLOR[e.rec.kind] or COLOR.trivial
		f.border:SetTexture(c[1], c[2], c[3], 0.9)
		-- «19/1»: серым — сколько всего можно создать из имеющегося, после черты — что даст
		-- навык по плану: зелёным — точно, жёлтым — сколько раз создать «с шансом»
		e.maxCraft = MaxCraftable(e.rec, producers, 0, {})
		local right = (e.gain > 0) and ("|cff40ff40" .. e.gain .. "|r") or ("|cffffff00" .. e.count .. "|r")
		f.count:SetText("|cffaaaaaa" .. e.maxCraft .. "/|r" .. right)
		f.gainText:SetText("")
		f.tool:Hide() -- «нужно рядом» показывается на карте и во вкладке «План»
		-- нужны вещи из банка: в сумках меньше, чем требуется на весь план, а в банке есть
		local needBank = false
		for _, r in ipairs(e.rec.reagents) do
			if BagCount(r) < r.count * e.count and BankCount(r) > 0 then needBank = true break end
		end
		f.bankMark:Hide() -- на полосе значок банка не показываем (он есть на карте и во вкладке «План»)
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", bar, "TOP", -width / 2 + i * (ICON_SIZE + ICON_GAP), -2)
		f:Show()
	end
	for i = n + 1, #icons do icons[i]:Hide(); icons[i].entry = nil end
	CraftPlan.collapseButton:Place(width / 2, db.collapsed)
	if n > 0 and #plan > n then
		more:SetText("+" .. (#plan - n))
		more:ClearAllPoints()
		more:SetPoint("LEFT", bar, "TOP", width / 2 + COLLAPSE_SIZE + 8, -2 - ICON_SIZE / 2)
		more:Show()
	else
		more:Hide()
	end

	bar:SetWidth(width + COLLAPSE_SIZE + ((n > 0 and #plan > n) and 40 or 0) + 8)
	bar:SetHeight(ICON_SIZE + 4)
	bar:SetAlpha(1)
	bar:Show()
	if AfterPlan then AfterPlan() end
end

-- Запуск пересчёта: план считается в coroutine по кусочкам на нескольких кадрах
local planCo
local planDirty = false -- данные изменились, пока шёл расчёт — посчитать ещё раз после
local Refresh
local runner = CreateFrame("Frame")
runner:Hide()
-- текст индикатора: точки бегут, проценты — по ходу расчёта
local function LoaderText()
	local dots = string.rep(".", math.floor(GetTime() * 3) % 4)
	return "считаю план" .. dots .. " " .. math.floor((CraftPlan.progress or 0) * 100) .. "%"
end
CraftPlan.IsComputing = function() return planCo ~= nil end
CraftPlan.LoaderText = LoaderText

runner:SetScript("OnUpdate", function(self)
	if not planCo then self:Hide() return end
	if InCombatLockdown() then return end -- в бою ждём
	if not DB().hidden then
		loader:SetText("|cff66ccffCraftPlan:|r " .. LoaderText())
		loader:Show()
	end
	if CraftPlan.UpdateMapTitle then CraftPlan.UpdateMapTitle() end
	sliceStart = Now()
	local ok, a, b, c, d = coroutine.resume(planCo)
	if coroutine.status(planCo) == "dead" then
		planCo = nil
		self:Hide()
		loader:Hide()
		CraftPlan.progress = 1
		if CraftPlan.UpdateMapTitle then CraftPlan.UpdateMapTitle() end
		if ok then
			ApplyPlan(a, b, c, d)
		else
			Print("ошибка расчёта: " .. tostring(a))
		end
		if planDirty then
			planDirty = false
			Refresh()
		end
	end
end)

Refresh = function()
	if InCombatLockdown() then CraftPlan.HideBar() return end
	-- полоса свёрнута, а карта крафта и торговец закрыты — план не нужен: не считаем,
	-- рисуем только значок карты и стрелку; посчитаем, когда понадобится
	local db = DB()
	if db.collapsed and not (CraftPlanMap and CraftPlanMap:IsShown()) and not (MerchantFrame and MerchantFrame:IsShown()) then
		CraftPlan.planStale = true
		if db.hidden or planCo then return end
		for i = 1, #icons do icons[i]:Hide(); icons[i].entry = nil end
		more:Hide()
		mapButton:ClearAllPoints()
		mapButton:SetPoint("TOPLEFT", bar, "TOP", -ICON_SIZE / 2, -2)
		CraftPlan.collapseButton:Place(ICON_SIZE / 2, true)
		bar:SetWidth(ICON_SIZE + COLLAPSE_SIZE + 8)
		bar:SetHeight(ICON_SIZE + 4)
		bar:SetAlpha(1)
		bar:Show()
		return
	end
	CraftPlan.planStale = nil
	if planCo then planDirty = true return end -- не обрывать идущий расчёт, а повторить после
	UpdateRanks()
	RecolorAll()
	planCo = coroutine.create(BuildPlan)
	CraftPlan.progress = 0
	runner:Show()
end

local function SummaryTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:AddLine("CraftPlan", 0.4, 0.8, 1)
	GameTooltip:AddLine("Что создать из того, что есть в сумках и банке, чтобы поднять навык как можно выше. +N у профессии — точный прирост навыка от оранжевых рецептов (каждое создание +1, до порога пожелтения из файлов игры). «+шанс» — ещё будут жёлтые или зелёные создания: навык от них растёт не каждый раз.", 1, 1, 1, true)
	local shared = SharedReagents()
	if #shared > 0 then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Общие ингредиенты (есть в сумках и банке):", 0.8, 0.8, 0.8)
		for _, s in ipairs(shared) do
			GameTooltip:AddDoubleLine("  " .. s.name .. " — " .. s.count, s.profs, 1, 1, 1, 0.7, 0.7, 0.7)
		end
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("* — навык вырос, цвета рецептов могли смениться: откройте окно профессии, чтобы обновить.", 1, 1, 0, true)
	GameTooltip:AddLine("Щелчок по кнопке профессии — скрыть или показать её на карте.", 0.5, 0.8, 1, true)
	GameTooltip:AddLine("Банк учитывается после того, как вы его откроете. /cplan min — свернуть полосу, /cplan — скрыть.", 0.6, 0.6, 0.6, true)
	GameTooltip:Show()
end
summary:Hide() -- строка сводки перенесена в карту крафта
bar.bg:Hide() -- полоса без фона

local function ToggleCollapsed()
	local db = DB()
	db.collapsed = not db.collapsed
	Refresh()
	if CraftPlan.ProspectUpdate then CraftPlan.ProspectUpdate() end -- кнопка «Просеять» сворачивается вместе с полосой
end



----------------------------------------------------------------------------------------------
-- «Как качать дальше» — вкладка «План» в окне карты. Показывает тот же расчёт, что и полоса:
-- сначала что создать из имеющегося, потом по каждой профессии — чего не хватает дальше.
local NEED_WIDTH = 460
local NEED_LINE = 18

-- Руда → жилы GatherMate (номера узлов из GatherMate/Constants.lua)
local ORE_NODES = {
	[2770] = { 201 },                -- медная руда
	[2771] = { 202 },                -- оловянная руда
	[2772] = { 203 },                -- железная руда
	[2775] = { 204, 209 },           -- серебряная руда
	[2776] = { 205, 210 },           -- золотая руда
	[3858] = { 206, 207 },           -- мифриловая руда
	[7911] = { 208, 211 },           -- истинное серебро
	[10620] = { 212, 213, 214, 215 }, -- ториевая руда
	[11370] = { 217 },               -- руда черного железа
	[3340] = { 219 },                -- зажигательная руда
	[4278] = { 218 },                -- малая кровавокаменная руда
	[5833] = { 220 },                -- индарилиевая руда
	[23424] = { 221 },               -- оскверненное железо
	[23425] = { 222, 223 },          -- адамантит
	[23426] = { 224 },               -- кориум
	[36909] = { 228, 229 },          -- кобальт
	[36912] = { 231, 232 },          -- саронит
	[36910] = { 230 },               -- титан
}

-- Название профессии → как она называется в подписи учителя («Учитель кузнечного дела»)
local TRAINER_STEM = {
	["Кузнечное дело"] = "кузнечного дела",
	["Ювелирное дело"] = "ювелирного дела",
	["Горное дело"] = "горного дела",
	["Первая помощь"] = "первой помощи",
	["Кулинария"] = "кулинарии",
	["Портняжное дело"] = "портняжного дела",
	["Кожевничество"] = "кожевничества",
	["Инженерное дело"] = "инженерного дела",
	["Алхимия"] = "алхимии",
	["Наложение чар"] = "наложения чар",
	["Начертание"] = "начертания",
	["Рыбная ловля"] = "рыбной ловли",
	["Травничество"] = "травничества",
	["Снятие шкур"] = "снятия шкур",
}

local function ItemOf(link) return link and tonumber(link:match("item:(%d+)")) end

-- Зоны, где GatherMate знает жилы этой руды: { {zone, count}, ... } по убыванию
local function OreZones(itemID)
	local nodes = ORE_NODES[itemID]
	if not (nodes and GatherMate and GatherMate.zoneData and GatherMateMineDB) then return nil end
	local set = {}
	for _, id in ipairs(nodes) do set[id] = true end
	local list, seen = {}, {}
	for zoneName, zd in pairs(GatherMate.zoneData) do
		local db = zd[3] and GatherMateMineDB[zd[3]]
		if db and not seen[zd[3]] then
			seen[zd[3]] = true
			local c = 0
			for _, nodeID in pairs(db) do
				if set[nodeID] then c = c + 1 end
			end
			if c > 0 then list[#list + 1] = { zoneName, c } end
		end
	end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	return list
end

-- Жилы руды на карте GatherMate — через его фильтр «Горное дело» (как галочки в настройках GatherMate).
-- db.oreOff[руда]: true — скрыта щелчком, false — показана щелчком, nil — решает галочка
-- «Скрыть жилы без пользы». db.nodeApplied[жила] — что мы поставили в прошлый раз: фильтр меняем,
-- только когда наше решение изменилось, чтобы не перебивать ручные настройки GatherMate.
local function MineFilter()
	local p = GatherMate and GatherMate.db and GatherMate.db.profile
	return p and p.filter and p.filter["Mining"]
end

local function OreShown(oreID)
	local f = MineFilter()
	for _, node in ipairs(f and ORE_NODES[oreID] or {}) do
		if f[node] then return true end
	end
	return false
end

-- Предметы, которые дают навык: материалы не серых рецептов, а также материалы для их
-- материалов (руда → слиток → изделие), до трёх шагов; плюс руда, чьи камни (по журналу
-- просеиваний) нужны таким рецептам
local function UsefulItems()
	local useful, producers = {}, {}
	for _, p in pairs(DB().profs) do
		for _, rec in ipairs(p.recipes or {}) do
			local prod = ItemOf(rec.link)
			if prod then
				producers[prod] = producers[prod] or {}
				table.insert(producers[prod], rec)
			end
			if rec.kind ~= "trivial" then
				for _, r in ipairs(rec.reagents) do
					if r.id then useful[r.id] = true end
				end
			end
		end
	end
	for _ = 1, 3 do
		for prod, recs in pairs(producers) do
			if useful[prod] then
				for _, rec in ipairs(recs) do
					for _, r in ipairs(rec.reagents) do
						if r.id then useful[r.id] = true end
					end
				end
			end
		end
	end
	local journal = CraftPlanDB and CraftPlanDB.prospect and CraftPlanDB.prospect.ore
	for ore, o in pairs(journal or {}) do
		for gem in pairs(o.gems or {}) do
			if useful[gem] then useful[ore] = true end
		end
	end
	return useful
end

do -- свой блок: у основного кода предел в 200 локальных переменных
	-- Даёт ли жила навык горного дела сейчас: можно добыть (навык не ниже минимального)
	-- и она ещё не серая (по правилу сбора серой становится при навыке на 100 выше минимального)
	local GREY_AFTER = 100
	local function MiningRank()
		for i = 1, GetNumSkillLines() do
			local name, isHeader, _, rank = GetSkillLineInfo(i)
			if not isHeader and name == "Горное дело" then return rank end
		end
	end
	local function NodeGivesSkill(node, rank)
		local minTable = GatherMate.nodeMinHarvest and GatherMate.nodeMinHarvest["Mining"]
		local req = minTable and minTable[node]
		return rank and req and rank >= req and rank < req + GREY_AFTER or false
	end

	-- Галочка «Скрыть жилы без пользы»: прячем жилу, если она не даёт навык горного дела
	-- и её руда не нужна рецептам (UsefulItems). Ручной щелчок по руде (db.oreOff) важнее.
	local function ApplyOreFilter()
		local f = MineFilter()
		if not f then return end
		local db = DB()
		db.oreOff = db.oreOff or {}
		db.nodeApplied = db.nodeApplied or {}
		if db.oreApplied then -- версия 0.9.2 запоминала по руде — переносим на жилы
			for ore, hidden in pairs(db.oreApplied) do
				for _, node in ipairs(ORE_NODES[ore] or {}) do db.nodeApplied[node] = hidden or nil end
			end
			db.oreApplied = nil
		end
		local useful = db.hideUseless and UsefulItems()
		local rank = MiningRank()
		local changed = false
		for ore, nodes in pairs(ORE_NODES) do
			for _, node in ipairs(nodes) do
				local hide
				if db.oreOff[ore] ~= nil then
					hide = db.oreOff[ore]
				else
					hide = useful and not useful[ore] and not NodeGivesSkill(node, rank) or false
				end
				if hide ~= (db.nodeApplied[node] or false) then
					f[node] = not hide
					db.nodeApplied[node] = hide or nil
					changed = true
				end
			end
		end
		if changed and GatherMate.SendMessage then GatherMate:SendMessage("GatherMateConfigChanged") end
	end
	CraftPlan.ApplyOreFilter = ApplyOreFilter
end

-- (в блоке do … end: у основного кода предел в 200 локальных переменных)
do
	-- Пункт в меню Questie («Торговец» → «Торговцы для CraftPlan»): торговцы, у которых продаётся то,
	-- чего не хватает текущему плану (рецепты, дающие навык сейчас). Кто продаёт — по базе Questie,
	-- но если вы открывали окно торговца, верим тому, что он продаёт на самом деле (db.vendorStock).
	-- Список кладём в Questie.db.char.vendorList — оттуда Questie строит меню и ставит значки
	local QUESTIE_VENDOR_KEY = "Торговцы для CraftPlan"
	local QUESTIE_VENDOR_ICON = "Interface\\Icons\\INV_Misc_Coin_02"
	local questieVendorSig -- подпись прошлого списка, чтобы не пересчитывать без изменений
	local function UpdateQuestieVendors()
		if not (Questie and Questie.db and Questie.db.char and Questie.db.char.vendorList and QuestieLoader) then return end
		local Townsfolk = QuestieLoader:ImportModule("Townsfolk")
		local QuestieMenu = QuestieLoader:ImportModule("QuestieMenu")
		local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
		if not (Townsfolk and Townsfolk.PopulateVendors) then return end
		if not CraftPlan.PlanDeficit then return end
		local deficit = CraftPlan.PlanDeficit()
		local items = {}
		for id in pairs(deficit) do items[#items + 1] = id end
		table.sort(items)
		local stockAll = DB().vendorStock or {}
		local stockN = 0
		for _ in pairs(stockAll) do stockN = stockN + 1 end
		local sig = table.concat(items, ",") .. "|" .. stockN
		if sig == questieVendorSig and Questie.db.char.vendorList[QUESTIE_VENDOR_KEY] then return end
		local ok, set = pcall(Townsfolk.PopulateVendors, Townsfolk, items, {})
		if not ok or not set then return end -- база Questie ещё не загружена — попробуем после следующего расчёта
		questieVendorSig = sig
		local old = Questie.db.char.vendorList[QUESTIE_VENDOR_KEY] or {}
		local list = {}
		for id in pairs(set) do
			local stock = stockAll[id]
			local keep = true
			if stock then -- были у него: оставляем, только если правда продаёт нужное
				keep = false
				for item in pairs(deficit) do
					if stock[item] then keep = true break end
				end
			end
			if keep then list[#list + 1] = id end
		end
		Questie.db.char.vendorList[QUESTIE_VENDOR_KEY] = list
		if QuestieMenu and QuestieMenu.private and QuestieMenu.private.townsfolk_texturemap then
			QuestieMenu.private.townsfolk_texturemap[QUESTIE_VENDOR_KEY] = QUESTIE_VENDOR_ICON
		end
		-- пункт включён — перерисовать значки по новому списку
		local cfg = Questie.db.profile and Questie.db.profile.townsfolkConfig
		if cfg and cfg[QUESTIE_VENDOR_KEY] and QuestieMap and QuestieMap.ShowNPC then
			local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
			for _, id in ipairs(old) do QuestieMap:UnloadManualFrames(id, QUESTIE_VENDOR_KEY) end
			for _, id in ipairs(list) do
				local name = QuestieDB and QuestieDB.QueryNPCSingle(id, "name") or "?"
				local sub = QuestieDB and QuestieDB.QueryNPCSingle(id, "subName") or ""
				QuestieMap:ShowNPC(id, QUESTIE_VENDOR_ICON, 1.2, "|cffffffff" .. name .. "|r (" .. sub .. ")", {}, true, QUESTIE_VENDOR_KEY, true)
			end
		end
	end
	CraftPlan.UpdateQuestieVendors = UpdateQuestieVendors
end

-- Щелчок по руде: скрыть её жилы на карте или снова показать; возвращает true, если теперь показаны
local function ToggleOre(oreID, name)
	local f = MineFilter()
	if not f then return true end
	local db = DB()
	db.oreOff = db.oreOff or {}
	db.nodeApplied = db.nodeApplied or {}
	local show = not OreShown(oreID)
	db.oreOff[oreID] = not show
	for _, node in ipairs(ORE_NODES[oreID]) do
		f[node] = show
		db.nodeApplied[node] = (not show) or nil
	end
	if GatherMate.SendMessage then GatherMate:SendMessage("GatherMateConfigChanged") end
	if not show then Print(name .. ": жилы скрыты на карте. Щёлкните ещё раз — показать.") end
	return show
end

-- Где взять материал: руда — зоны с жилами (GatherMate), торговец — кто и где,
-- остальное — источники на карте через WhereToGet (Questie)
local function WhereToGetReagent(r)
	local name = r.name or ("предмет " .. tostring(r.id))
	local zones = r.id and OreZones(r.id)
	local v = VendorInfo(r)
	if v then
		Print(name .. ": продаётся у торговца " .. (v.npc or "?") .. " (" .. (v.zone or "?") .. ") за " .. Money(v.price) .. " за штуку.")
	end
	if zones then
		-- щелчок по руде переключает её жилы на карте; при скрытии зоны не перечисляем
		if not ToggleOre(r.id, name) then return end
		if #zones == 0 then
			Print(name .. ": GatherMate пока не знает жил этой руды.")
		else
			local here, parts = GetRealZoneText(), {}
			for i = 1, math.min(6, #zones) do
				local z = zones[i]
				parts[#parts + 1] = (z[1] == here and ("|cff00ff00" .. z[1] .. "|r") or z[1]) .. " (" .. z[2] .. ")"
			end
			Print(name .. ": жилы — " .. table.concat(parts, ", ") .. ". Жилы видны на карте и миникарте (GatherMate).")
		end
		return
	end
	if not v then
		if WhereToGet_ShowItem and r.id then
			WhereToGet_ShowItem(r.id)
		else
			Print(name .. ": нужен Questie, чтобы показать источники на карте.")
		end
	end
end

-- Учителя профессии из базы Questie: отмечаем на карте тех, кто в текущей зоне,
-- а если здесь никого — всех своей фракции
local trainerCache, trainerShown = {}, {}
local trainerPins = {} -- метки TomTom для учителей, которых нет в Questie

-- Учителя, у которых вы были: [профессия][номер NPC или имя] = { name, zone, c, z, x, y }.
-- Нужны для учителей, которых нет в базе Questie (например, свои NPC Sirus)
local scanTip -- скрытая подсказка: подпись NPC под именем («Учитель ювелирного дела»)
local function NpcSubtitle()
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "CraftPlanScanTip", UIParent, "GameTooltipTemplate")
	end
	scanTip:SetOwner(UIParent, "ANCHOR_NONE")
	scanTip:SetUnit("npc")
	local line = _G["CraftPlanScanTipTextLeft2"]
	local text = line and line:GetText()
	scanTip:Hide()
	return text
end

local function RememberTrainer()
	if IsTradeskillTrainer and not IsTradeskillTrainer() then return end
	local prof
	-- профессия: по подписи NPC, иначе по рецептам в списке учителя
	local sub = NpcSubtitle()
	if sub then
		local low = sub:lower()
		for profName, stem in pairs(TRAINER_STEM) do
			if low:find(stem, 1, true) then prof = profName break end
		end
	end
	if not prof and GetTrainerServiceSkillLine then
		for i = 1, GetNumTrainerServices() do
			local ok, skill = pcall(GetTrainerServiceSkillLine, i)
			if ok and skill and TRAINER_STEM[skill] then prof = skill break end
		end
	end
	local name = UnitName("npc")
	if not name then return end
	if not prof then
		Print("не понял, какой профессии учитель " .. name .. (sub and (" («" .. sub .. "»)") or "") .. " — не запомнил.")
		return
	end
	local guid = UnitGUID("npc")
	local npcId = guid and tonumber(guid:sub(-12, -7), 16)
	if WorldMapFrame and WorldMapFrame:IsShown() then
		Print("закройте карту мира и откройте окно учителя ещё раз — с открытой картой не узнать, где вы стоите.")
		return
	end
	SetMapToCurrentZone()
	local x, y = GetPlayerMapPosition("player")
	local c, z = GetCurrentMapContinent(), GetCurrentMapZone()
	if not x or (x == 0 and y == 0) or not c or c < 1 then
		Print("не удалось узнать место на карте (здесь игра не даёт координат) — учителя " .. name .. " не запомнил.")
		return
	end
	local db = DB()
	db.trainers = db.trainers or {}
	db.trainers[prof] = db.trainers[prof] or {}
	local key = npcId or name
	local known = db.trainers[prof][key]
	-- номер зоны, как в базе Questie (нужен, чтобы добавить учителя в его базу)
	local area
	if QuestieCompat and QuestieCompat.C_Map and QuestieLoader then
		local ok, uiMapId = pcall(QuestieCompat.C_Map.GetBestMapForUnit, "player")
		local ZoneDB = QuestieLoader:ImportModule("ZoneDB")
		if ok and uiMapId and ZoneDB and ZoneDB.GetAreaIdByUiMapId then
			local ok2, a = pcall(ZoneDB.GetAreaIdByUiMapId, ZoneDB, uiMapId)
			area = ok2 and a or nil
		end
	end
	db.trainers[prof][key] = { name = name, id = npcId, zone = GetRealZoneText(), c = c, z = z, x = x, y = y, area = area,
		pinned = known and known.pinned }
	if not known then Print("запомнил учителя «" .. prof .. "»: " .. name .. " (" .. (GetRealZoneText() or "?") .. ").") end
	if CraftPlan.EnsureQuestieTrainers then pcall(CraftPlan.EnsureQuestieTrainers, true) end
end
CraftPlan.RememberTrainer = RememberTrainer

-- Запомненные учителя на карте всегда: если NPC есть в базе Questie — добавляем его в список
-- учителей профессии Questie (меню «Учитель профессии»; Questie собирает этот список заново при
-- загрузке, поэтому добавляем каждый раз); если нет — постоянная метка TomTom
do
	local PROF_KEY = { -- номер навыка, как у Questie
		["Первая помощь"] = 129, ["Кузнечное дело"] = 164, ["Кожевничество"] = 165, ["Алхимия"] = 171,
		["Травничество"] = 182, ["Кулинария"] = 185, ["Горное дело"] = 186, ["Портняжное дело"] = 197,
		["Инженерное дело"] = 202, ["Наложение чар"] = 333, ["Рыбная ловля"] = 356, ["Снятие шкур"] = 393,
		["Ювелирное дело"] = 755, ["Начертание"] = 773,
	}
	local shownNow = {} -- кому уже поставили значок в этом сеансе
	function CraftPlan.EnsureQuestieTrainers(verbose)
		local trainers = DB().trainers
		if not trainers then return end
		local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
		local qList = Questie and Questie.db and Questie.db.global and Questie.db.global.professionTrainers
		for prof, list in pairs(trainers) do
			for _, t in pairs(list) do
				local spawns
				if t.id and QuestieDB and QuestieDB.QueryNPCSingle then
					local ok, sp = pcall(QuestieDB.QueryNPCSingle, t.id, "spawns")
					spawns = ok and sp
				end
				local key = PROF_KEY[prof]
				-- нет в базе Questie, но знаем зону — добавляем в базу Questie через его поправки
				-- (npcDataOverrides: Questie читает их раньше своей базы; живут до выхода из игры,
				-- поэтому добавляем при каждом входе)
				if not (spawns and next(spawns)) and t.id and t.area and QuestieDB and QuestieDB.npcDataOverrides then
					local keys = QuestieDB.npcKeys
					local flags = QuestieDB.npcFlags and QuestieDB.npcFlags.TRAINER or 16
					local faction = (UnitFactionGroup("player") == "Horde") and "H" or "A"
					QuestieDB.npcDataOverrides[t.id] = {
						[keys.name] = t.name,
						[keys.spawns] = { [t.area] = { { t.x * 100, t.y * 100 } } },
						[keys.zoneID] = t.area,
						[keys.friendlyToFaction] = faction,
						[keys.subName] = "Учитель " .. (TRAINER_STEM[prof] or prof),
						[keys.npcFlags] = flags,
					}
					spawns = QuestieDB.npcDataOverrides[t.id][keys.spawns]
					if verbose then Print(t.name .. ": добавлен в базу Questie (до выхода из игры; при входе добавится снова).") end
				end
				if spawns and next(spawns) and qList and key and qList[key] then
					local has = false
					for _, id in ipairs(qList[key]) do if id == t.id then has = true break end end
					if not has then
						table.insert(qList[key], t.id)
						if verbose then Print(t.name .. " добавлен в учителей Questie: меню Questie → «Учитель профессии» → «" .. prof .. "».") end
					end
					-- пункт этой профессии в меню Questie уже включён — значок сразу, без переключения
					local cfg = Questie.db.profile and Questie.db.profile.townsfolkConfig
					local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
					if not shownNow[t.id] and cfg and cfg[key] and QuestieMap and QuestieMap.ShowNPC then
						QuestieMap:ShowNPC(t.id, "Interface\\Minimap\\tracking\\profession", 1.2,
							"|cffffffff" .. t.name .. "|r (учитель: " .. prof .. ")", {}, true, key, true)
						shownNow[t.id] = true
					end
				elseif TomTom and TomTom.AddZWaypoint and not t.pinned then
					-- в базе Questie его нет: постоянная метка TomTom (переживает перезаход)
					TomTom:AddZWaypoint(t.c, t.z, t.x * 100, t.y * 100, t.name .. " (учитель: " .. prof .. ")", true, true, true, nil, true)
					t.pinned = true
					if verbose then Print(t.name .. ": в базе Questie его нет — поставил постоянную метку TomTom на карте.") end
				end
			end
		end
	end
end
local function ShowTrainers(prof)
	local stem = TRAINER_STEM[prof]
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local QuestieMap = QuestieLoader and QuestieLoader:ImportModule("QuestieMap")
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	if not stem then Print("не знаю, как называются учителя профессии «" .. prof .. "».") return end
	if not (QuestieDB and QuestieDB.NPCPointers and QuestieMap and QuestieMap.ShowNPC) then
		Print("Questie ещё не загрузил базу — попробуйте через минуту.")
		return
	end
	local list = trainerCache[prof]
	if not list then
		list = {}
		local faction = (UnitFactionGroup("player") == "Horde") and "H" or "A"
		for id in pairs(QuestieDB.NPCPointers) do
			local sub = QuestieDB.QueryNPCSingle(id, "subName")
			if sub and sub:find("^Учител") and sub:find(stem, 1, true) then
				local friendly = QuestieDB.QueryNPCSingle(id, "friendlyToFaction")
				local spawns = QuestieDB.QueryNPCSingle(id, "spawns")
				if friendly and friendly:find(faction, 1, true) and spawns and next(spawns) then
					local zones = {}
					for areaId in pairs(spawns) do
						zones[#zones + 1] = TrackerUtils and TrackerUtils.GetZoneNameByID and TrackerUtils:GetZoneNameByID(areaId) or tostring(areaId)
					end
					list[#list + 1] = { id = id, name = QuestieDB.QueryNPCSingle(id, "name") or "?", sub = sub, zones = zones }
				end
			end
		end
		trainerCache[prof] = list
	end
	for id in pairs(trainerShown) do QuestieMap:UnloadManualFrames(id) end
	trainerShown = {}
	for _, uid in ipairs(trainerPins) do if TomTom and TomTom.RemoveWaypoint then TomTom:RemoveWaypoint(uid) end end
	trainerPins = {}
	-- запомненные учителя, которых нет в Questie: метками TomTom (или координатами в чат)
	local inQuestie, remembered = {}, {}
	for _, t in ipairs(list) do inQuestie[t.id] = true end
	for _, t in pairs(DB().trainers and DB().trainers[prof] or {}) do
		if not (t.id and inQuestie[t.id]) then remembered[#remembered + 1] = t end
	end
	if CraftPlan.EnsureQuestieTrainers then pcall(CraftPlan.EnsureQuestieTrainers) end -- добавить в базу Questie
	for _, t in ipairs(remembered) do
		local where = string.format("%s %.0f, %.0f", t.zone or "?", t.x * 100, t.y * 100)
		local mark
		if t.id and QuestieDB.npcDataOverrides and QuestieDB.npcDataOverrides[t.id] then
			QuestieMap:ShowNPC(t.id) -- уже в базе Questie (добавлен нами) — обычный значок Questie
			trainerShown[t.id] = true
			mark = " — отмечен на карте (Questie)."
		elseif TomTom and TomTom.AddZWaypoint then
			local uid = TomTom:AddZWaypoint(t.c, t.z, t.x * 100, t.y * 100, t.name .. " (учитель: " .. prof .. ")", false, true, true, nil, true)
			if uid then trainerPins[#trainerPins + 1] = uid mark = " — метка TomTom на карте." end
		end
		Print("учитель «" .. prof .. "» (запомнен вами): " .. t.name .. " — " .. where .. (mark or "."))
	end
	if #list == 0 then
		if #remembered == 0 then
			Print("в базе Questie нет учителей профессии «" .. prof .. "» вашей фракции. Поговорите с учителем — аддон запомнит его.")
		end
		return
	end

	local here, near = GetRealZoneText(), {}
	for _, t in ipairs(list) do
		for _, z in ipairs(t.zones) do
			if z == here then near[#near + 1] = t break end
		end
	end
	local show = (#near > 0) and near or list
	local parts = {}
	for i, t in ipairs(show) do
		if i > 25 then break end
		QuestieMap:ShowNPC(t.id)
		trainerShown[t.id] = true
		if i <= 8 then parts[#parts + 1] = t.name .. " — " .. table.concat(t.zones, ", ") end
	end
	Print("учителя «" .. prof .. "»" .. ((#near > 0) and " в этой зоне" or "") .. " отмечены на карте (M): " .. table.concat(parts, "; ") .. ".")
	Print("Учитель повышает потолок навыка, только если уровень персонажа позволяет; не каждый учитель учит высшим ступеням. /cplan clear — убрать метки.")
end

local function ClearTrainers()
	local QuestieMap = QuestieLoader and QuestieLoader:ImportModule("QuestieMap")
	if QuestieMap then
		for id in pairs(trainerShown) do QuestieMap:UnloadManualFrames(id) end
	end
	trainerShown = {}
	for _, uid in ipairs(trainerPins) do if TomTom and TomTom.RemoveWaypoint then TomTom:RemoveWaypoint(uid) end end
	trainerPins = {}
end

-- Панель под полосой
local need = CreateFrame("Frame", "CraftPlanNeed", UIParent)
need:SetPoint("TOP", bar, "BOTTOM", 0, -4)
need:SetWidth(NEED_WIDTH)
need:SetHeight(40)
need:SetFrameStrata("MEDIUM")
need:SetBackdrop({
	bgFile = "Interface\\ChatFrame\\ChatFrameBackground", -- сплошной фон
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
need:SetBackdrop(nil) -- внутри окна карты отдельный фон не нужен
need:Hide()

local needLines = {}
local function NeedLine(i)
	local l = needLines[i]
	if not l then
		l = CreateFrame("Button", nil, need)
		l:SetHeight(NEED_LINE)
		l.icon = l:CreateTexture(nil, "ARTWORK")
		l.icon:SetWidth(NEED_LINE - 2)
		l.icon:SetHeight(NEED_LINE - 2)
		l.icon:SetPoint("LEFT", l, "LEFT", 0, 0)
		l.text = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		l.text:SetPoint("RIGHT", l, "RIGHT", 0, 0)
		l.text:SetJustifyH("LEFT")
		l:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		l:SetScript("OnEnter", function(self)
			if not self.tip then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if self.link then GameTooltip:SetHyperlink(self.link) GameTooltip:AddLine(" ") end
			GameTooltip:AddLine(self.tip, 0.5, 0.8, 1, true)
			GameTooltip:Show()
		end)
		l:SetScript("OnLeave", function() GameTooltip:Hide() end)
		l:SetScript("OnClick", function(self) if self.action then self.action() end end)
		needLines[i] = l
	end
	return l
end

local function Hex(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end

-- Рыба (журнал улова и косяки из базы Questie, раздел «Рыбалка» ниже): true и где ловится
local function FishInfo(r)
	if r.id and CraftPlan.FishWhere then return CraftPlan.FishWhere(r.id) end
	return false
end

-- Короткая подсказка «где взять» для строки списка
local function WhereShort(r)
	local v = VendorInfo(r)
	if v then return "|cff88ff88купить у торговца " .. (v.npc or "?") .. "|r" end
	local isFish, fishWhere = FishInfo(r)
	if isFish then return "|cff66ddffловится: " .. fishWhere .. "|r" end
	local zones = r.id and OreZones(r.id)
	if zones and zones[1] then return "|cffccccccжилы: " .. zones[1][1] .. (zones[2] and (", " .. zones[2][1]) or "") .. "|r" end
	if zones then return "|cffccccccжилы|r" end
	return "|cffccccccгде взять — щёлкните|r"
end

local function DrawNeed()
	local plan, cont = CraftPlan.fullPlan or {}, CraftPlan.cont or {}
	local i, y = 0, -10
	local function Add(text, opts)
		opts = opts or {}
		i = i + 1
		local l = NeedLine(i)
		l:ClearAllPoints()
		l:SetPoint("TOPLEFT", need, "TOPLEFT", 10 + (opts.indent or 0), y)
		l:SetPoint("RIGHT", need, "RIGHT", -10, 0)
		if opts.icon then
			l.icon:SetTexture(opts.icon)
			l.icon:Show()
			l.text:SetPoint("LEFT", l.icon, "RIGHT", 4, 0)
		else
			l.icon:Hide()
			l.text:SetPoint("LEFT", l, "LEFT", 0, 0)
		end
		l.text:SetFontObject(opts.font or "GameFontHighlightSmall")
		l.text:SetText(text)
		l.action, l.tip, l.link = opts.action, opts.tip, opts.link
		l:EnableMouse(opts.action ~= nil or opts.tip ~= nil)
		l:Show()
		y = y - NEED_LINE - (opts.gapAfter or 0)
	end
	local function GainText(sure, maybe)
		local t = {}
		if sure > 0 then t[#t + 1] = "|cff40ff40навык +" .. sure .. " точно|r" end
		if maybe > 0 then t[#t + 1] = "|cffffff00" .. maybe .. " раз с шансом|r" end
		return table.concat(t, ", ")
	end

	if not next(DB().profs) then
		Add("Откройте окно каждой профессии один раз, чтобы аддон узнал рецепты.")
	end
	if planCo then
		Add("|cff66ccff" .. LoaderText() .. "|r — список обновится, когда расчёт закончится.", { gapAfter = 6 })
	end

	-- 1) прямо сейчас — из того, что есть
	Add("|cff66ccffСейчас — из того, что есть|r", { font = "GameFontNormal" })
	if #plan == 0 then
		Add("|cff999999Из имеющихся материалов сейчас нечего создать для навыка.|r", { indent = 12 })
	end
	for k, e in ipairs(plan) do
		local c = COLOR[e.rec.kind] or COLOR.trivial
		local rankText = (e.gain > 0) and ("  |cff999999" .. e.prof .. ": навык с " .. e.rankFrom .. " до " .. e.rankTo .. "|r")
			or ("  |cff999999" .. e.prof .. "|r")
		local g = GainText(e.gain, e.chance)
		local fromBank = false
		for _, r in ipairs(e.rec.reagents) do
			if BagCount(r) < r.count * e.count and BankCount(r) > 0 then fromBank = true break end
		end
		local bankText = fromBank and "  |cff88bbff[забрать из банка]|r" or ""
		local toolText = ToolText(e.rec.tools)
		if toolText then bankText = bankText .. "  |cffff8040[" .. toolText .. "]|r" end
		Add(k .. ". " .. Hex(c) .. e.rec.name .. "|r — " .. e.count .. " раз" .. (g ~= "" and ("   " .. g) or "") .. rankText .. bankText,
			{ indent = 12, icon = e.rec.icon, link = e.rec.link, action = function() SelectRecipeByName(e.prof, e.rec.name, e.count) end,
				tip = (e.step and "Промежуточный шаг. " or "") .. (ColorInfo(e.prof, e.rec.name) or "") ..
					" Щелчок при открытом окне профессии — выбрать рецепт и количество." })
	end
	y = y - 8

	-- итог: что даст весь план «Сейчас» по каждой профессии
	if #plan > 0 then
		local byProf, order = {}, {}
		for _, e in ipairs(plan) do
			local t = byProf[e.prof]
			if not t then
				local p = DB().profs[e.prof]
				t = { from = p and p.rank or e.rankFrom or 0, gain = 0, chance = 0, medium = 0, easy = 0 }
				byProf[e.prof] = t
				order[#order + 1] = e.prof
			end
			t.gain = t.gain + (e.gain or 0)
			t.chance = t.chance + (e.chance or 0)
			-- с шансом — по цвету рецепта: зелёный отдельно, остальное (жёлтый, оранжевый, ставший жёлтым) — жёлтым
			if (e.chance or 0) > 0 then
				local k = (e.rec.kind == "easy") and "easy" or "medium"
				t[k] = t[k] + e.chance
			end
		end
		-- только профессии, где навык вырастет (точно или, если разрешено, с шансом)
		local shown = {}
		for _, prof in ipairs(order) do
			local t = byProf[prof]
			if t.gain > 0 or (t.chance > 0 and DB().allowChance) then shown[#shown + 1] = prof end
		end
		table.sort(shown)
		if #shown > 0 then
			Add("|cff66ccffИтог, если сделать всё из того, что есть|r", { font = "GameFontNormal" })
			for _, prof in ipairs(shown) do
				local t = byProf[prof]
				-- «213 до 218» — только когда навык вырастет точно; иначе просто текущий навык
				local text = prof .. ": " .. t.from
					.. (t.gain > 0 and (" |cffaaaaaaдо|r |cff40ff40" .. (t.from + t.gain) .. "|r") or "")
				if t.gain > 0 then text = text .. "  " .. Hex(COLOR.optimal) .. "+" .. t.gain .. " точно|r" end
				if DB().allowChance then
					if t.medium > 0 then text = text .. "  " .. Hex(COLOR.medium) .. "+" .. t.medium .. " с шансом|r" end
					if t.easy > 0 then text = text .. "  " .. Hex(COLOR.easy) .. "+" .. t.easy .. " с шансом|r" end
				end
				Add(text, { indent = 12, tip = "Сумма по всем шагам раздела «Сейчас». «Точно» — оранжевые рецепты. «С шансом» — сколько созданий могут дать навык: жёлтым — по жёлтым рецептам (шанс выше), зелёным — по зелёным (шанс ниже)." })
			end
			y = y - 6
		end
	end

	-- 2) дальше — по профессиям
	Add("|cff66ccffДальше — когда это кончится|r", { font = "GameFontNormal" })
	local total, totalOrder = {}, {}
	for _, e in ipairs(cont) do
		Add(e.prof .. "   |cffffffff" .. e.rank .. " / " .. e.max .. "|r", { indent = 6 })
		if e.trainer then
			Add("|cffff8000Навык на максимуме.|r Идите к учителю — щёлкните, чтобы отметить учителей на карте.",
				{ indent = 18, action = function() ShowTrainers(e.prof) end, tip = "Отметить учителей этой профессии на карте мира (Questie)." })
		elseif e.noRecipes then
			Add("|cffff8000Нет оранжевых рецептов.|r Выучите новые у учителя — щёлкните."
				.. (DB().allowChance and "" or " Или разрешите жёлтые и зелёные (с шансом)."),
				{ indent = 18, action = function() ShowTrainers(e.prof) end, tip = "Отметить учителей этой профессии на карте мира (Questie)." })
		else
			local step = 0
			for key, m in pairs(e.missing) do
				step = step + 1
				local verb = VendorInfo(m.r) and "Купить" or (FishInfo(m.r) and "Поймать" or "Добыть")
				Add(step .. ". " .. verb .. ": " .. (m.r.name or "?") .. " — |cffff6060" .. m.amount .. "|r   " .. WhereShort(m.r),
					{ indent = 18, icon = m.r.icon, link = m.r.id and ("item:" .. m.r.id), action = function() WhereToGetReagent(m.r) end,
						tip = "Не хватает " .. m.amount .. " шт. Щелчок — где взять: жилы, торговец или источники на карте." })
				local pHint, pOre = CraftPlan.ProspectHint and CraftPlan.ProspectHint(m.r.id, m.amount)
				if pHint then
					Add("|cff66ccff" .. pHint .. "|r", { indent = 30, icon = pOre and GetItemIcon(pOre),
						tip = "По вашему журналу просеиваний. Кнопка «Просеять» — одно просеивание за щелчок." })
				end
				if not total[key] then
					total[key] = { r = m.r, amount = 0, profs = {} }
					totalOrder[#totalOrder + 1] = key
				end
				total[key].amount = total[key].amount + m.amount
				total[key].profs[e.prof] = true
			end
			for k = #e.steps, 1, -1 do
				local st = e.steps[k]
				step = step + 1
				Add(step .. ". Создать: " .. st.rec.name .. " — " .. st.times .. " раз   |cff999999(" .. st.prof .. ")|r",
					{ indent = 18, icon = st.rec.icon, link = st.rec.link, action = function() SelectRecipeByName(st.prof, st.rec.name, st.times) end,
						tip = "Промежуточный предмет. Щелчок при открытом окне профессии — выбрать рецепт." })
			end
			step = step + 1
			local c = COLOR[e.rec.kind] or COLOR.trivial
			local g = (e.kind == "optimal") and ("|cff40ff40навык +" .. e.times .. " точно|r") or "|cffffff00навык с шансом|r"
			Add(step .. ". Создать: " .. Hex(c) .. e.rec.name .. "|r — " .. e.times .. " раз   " .. g,
				{ indent = 18, icon = e.rec.icon, link = e.rec.link, action = function() SelectRecipeByName(e.prof, e.rec.name, e.times) end,
					tip = (ColorInfo(e.prof, e.rec.name) or "") .. " Щелчок при открытом окне профессии — выбрать рецепт." })
			if not next(e.missing) then Add("|cff00ff00Всё есть — можно создавать.|r", { indent = 18 }) end
		end
		y = y - 4
	end

	-- общий список, если материал нужен нескольким профессиям
	local shared = {}
	for _, key in ipairs(totalOrder) do
		local t = total[key]
		local n = 0
		for _ in pairs(t.profs) do n = n + 1 end
		if n > 1 then shared[#shared + 1] = t end
	end
	if #shared > 0 then
		y = y - 4
		Add("|cffffd200Нужно сразу нескольким профессиям — всего:|r", { font = "GameFontNormal" })
		for _, t in ipairs(shared) do
			Add((t.r.name or "?") .. " — " .. t.amount .. "   " .. WhereShort(t.r),
				{ indent = 12, icon = t.r.icon, link = t.r.id and ("item:" .. t.r.id), action = function() WhereToGetReagent(t.r) end,
					tip = "Щелчок — где взять." })
		end
	end

	-- когда в последний раз видели банк
	local bt = DB().bankTime
	y = y - 6
	Add("|cff777777" .. (DB().noBank and "Банк не учитывается (галочка вверху)." or
		(bt and ("Банк учтён по состоянию на " .. date("%d.%m %H:%M", bt) .. ".") or "Банк ещё не открывали — он не учтён.")) .. "|r")

	for k = i + 1, #needLines do needLines[k]:Hide() end
	need:SetHeight(-y + 8)
end

local function NeedRefresh()
	local sc = need:GetParent() -- область прокрутки вкладки «План» в окне карты
	if sc ~= UIParent and sc:IsShown() then
		need:SetWidth(math.max(300, sc:GetWidth() - 4))
		need:Show()
		DrawNeed()
		sc:UpdateScrollChildRect()
	end
end

-- после каждого расчёта: обновить вкладку «План» и карту
AfterPlan = function()
	if DB().hideUseless then CraftPlan.ApplyOreFilter() end -- цвета рецептов могли смениться
	if CraftPlan.UpdateQuestieVendors then pcall(CraftPlan.UpdateQuestieVendors) end
	if CraftPlan.UpdateRecipeVendors then pcall(CraftPlan.UpdateRecipeVendors) end
	if CraftPlan.EnsureQuestieTrainers then pcall(CraftPlan.EnsureQuestieTrainers) end
	NeedRefresh()
	if CraftPlan.MapRefresh then CraftPlan.MapRefresh() end
end

-- Открыть карту на вкладке «План» (или вернуться на «Схему», если «План» уже открыт)
local function ToggleNeed()
	local db = DB()
	db.mapTab = (db.mapTab == "plan") and "graph" or "plan"
	if CraftPlan.OpenMap then CraftPlan.OpenMap() end
	if CraftPlan.MapRefresh then CraftPlan.MapRefresh() end
end

----------------------------------------------------------------------------------------------
-- События: пересчёт с небольшой задержкой, чтобы не считать на каждое из десятков BAG_UPDATE
local pending = nil
local scanDue = false
local timer = CreateFrame("Frame")
timer:Hide()
timer:SetScript("OnUpdate", function(self)
	if GetTime() < pending then return end
	self:Hide()
	-- окно профессии открыто и давно не читали — перечитать (не чаще раза в 2 сек)
	if scanDue and TradeSkillFrame and TradeSkillFrame:IsShown() then
		scanDue = false
		ScanTradeSkill(false)
	end
	Refresh() -- карта и план обновятся, когда расчёт закончится (AfterPlan)
end)
local function RefreshSoon()
	pending = GetTime() + REFRESH_DELAY
	timer:Show()
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "BAG_UPDATE", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE",
	"SKILL_LINES_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
	"BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "MERCHANT_SHOW" }) do
	events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then RestoreBar() end
	if event == "BANKFRAME_OPENED" then
		bankOpen = true
		ScanBank()
		RefreshSoon()
	elseif event == "BANKFRAME_CLOSED" then
		bankOpen = false -- не сканируем: при закрытии банк уже может быть недоступен и запишется пустым
	elseif event == "PLAYERBANKSLOTS_CHANGED" then
		ScanBank()
		RefreshSoon()
	elseif event == "MERCHANT_SHOW" then
		ScanMerchant()
		if CraftPlan.planStale then Refresh() end
	elseif event == "BAG_UPDATE" then
		ScanBank() -- если банк открыт, сумки банка тоже могли измениться
		RefreshSoon()
	elseif event == "TRADE_SKILL_SHOW" then
		ScanTradeSkill(true) -- при открытии: развернуть разделы и прочитать всё
		RefreshSoon()
	elseif event == "TRADE_SKILL_UPDATE" then
		-- окно обновляется часто (каждое создание, разворачивание) — читаем отложенно
		scanDue = true
		RefreshSoon()
	elseif event == "PLAYER_REGEN_DISABLED" then
		CraftPlan.HideBar() -- в бою полоса не нужна
	else
		RefreshSoon()
	end
end)

-- /cplan — скрыть/показать; /cplan reset — забыть рецепты (например, после смены профессии)
SLASH_CRAFTPLAN1 = "/cplan"
SlashCmdList["CRAFTPLAN"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local db = DB()
	if msg == "min" then
		ToggleCollapsed()
	elseif msg == "need" then
		ToggleNeed()
	elseif msg == "clear" then
		ClearTrainers()
		Print("метки учителей убраны.")
	elseif msg == "map" then
		if CraftPlan.ToggleMap then CraftPlan.ToggleMap() else Print("карта не загрузилась — перезапустите игру.") end
	elseif msg == "reset" then
		db.profs = {}
		Print("рецепты забыты. Откройте окна профессий, чтобы аддон узнал их заново.")
		Refresh()
	else
		db.hidden = not db.hidden
		NeedRefresh()
		Print("полоса " .. (db.hidden and "скрыта" or "показана") .. ". /cplan min — свернуть/развернуть, /cplan map — карта крафта, /cplan need — чего не хватает, /cplan clear — убрать метки учителей, /cplan reset — забыть рецепты.")
		Refresh()
	end
end

-- Общие части для окна-карты (CraftMap.lua)
CraftPlan.DB = DB
CraftPlan.GAIN = GAIN
CraftPlan.COLOR = COLOR
CraftPlan.COLOR_NAME = COLOR_NAME
CraftPlan.ReagentKey = ReagentKey
CraftPlan.Print = Print
CraftPlan.ToggleCollapsed = ToggleCollapsed
CraftPlan.ToggleNeed = ToggleNeed
CraftPlan.NeedRefresh = NeedRefresh
CraftPlan.FullRefresh = function() Refresh() end -- карта и план обновятся по окончании расчёта
CraftPlan.SummaryTooltip = SummaryTooltip
CraftPlan.TotalCount = TotalCount
CraftPlan.CountText = CountText
CraftPlan.SelectRecipeByName = SelectRecipeByName
CraftPlan.WhereToGetReagent = WhereToGetReagent

----------------------------------------------------------------------------------------------
-- CraftMap: окно-схема «что из чего делается» для всех запомненных профессий.
-- Слева — исходные материалы, правее — то, что из них создаётся, ещё правее — то, что
-- создаётся из созданного (например, руда → слиток → изделие). Линии окрашены по профессии,
-- поэтому видно, где профессии пересекаются: от одного материала идут линии разных цветов.
-- Наведите мышь на значок — подсветятся только его связи.

local CP = CraftPlan

local NODE = 30           -- размер значка
local LABEL_W = 100       -- ширина подписи справа от значка
local BOX = NODE + 4 + LABEL_W
local COL_W = BOX + 40    -- шаг колонок; в промежутке идут линии
local ROW_H = 40
local PAD = 16
local LINE = 2            -- толщина линии
local LINE_ALPHA = 0.55
local DIM_ALPHA = 0.08

-- Цвета профессий для линий (по алфавиту названий)
local PROF_COLORS = {
	{ 0.30, 0.70, 1.00 }, { 1.00, 0.40, 0.40 }, { 0.40, 1.00, 0.40 }, { 1.00, 0.80, 0.20 },
	{ 0.80, 0.45, 1.00 }, { 1.00, 0.60, 0.20 }, { 0.30, 1.00, 0.90 }, { 1.00, 0.50, 0.80 },
	{ 0.75, 0.75, 0.75 }, { 0.60, 0.85, 0.20 }, { 0.95, 0.95, 0.55 },
}
-- Цвета веток: у каждого изделия свой цвет, им окрашены все линии, входящие в изделие
local BRANCH_COLORS = {
	{ 0.30, 0.70, 1.00 }, { 1.00, 0.35, 0.35 }, { 0.35, 1.00, 0.35 }, { 1.00, 0.85, 0.20 },
	{ 0.80, 0.45, 1.00 }, { 1.00, 0.55, 0.15 }, { 0.20, 1.00, 0.90 }, { 1.00, 0.45, 0.80 },
	{ 0.60, 0.85, 0.20 }, { 0.55, 0.55, 1.00 }, { 0.95, 0.95, 0.60 }, { 0.20, 0.60, 0.60 },
}
local GLOW_UP = { 1, 0.85, 0.2 }    -- подсветка нужных ингредиентов
local GLOW_DOWN = { 0.4, 0.8, 1 }   -- подсветка того, что из предмета делается
local NODE_DIM_ALPHA = 0.3
local SHARED_BORDER = { 1, 0.82, 0 } -- материал нужен нескольким профессиям
local BASE_BORDER = { 0.35, 0.35, 0.35 }

-- Выбор в списке «какие рецепты показывать» по ценности для навыка
local KIND_MODES = {
	{ key = "skill", text = "Всё, что даёт навык", kinds = { optimal = true, medium = true, easy = true } },
	{ key = "orange", text = "|cffff8040Только оранжевые|r", kinds = { optimal = true } },
	{ key = "orangeyellow", text = "|cffff8040Оранжевые|r и |cffffff00жёлтые|r", kinds = { optimal = true, medium = true } },
	{ key = "yellow", text = "|cffffff00Только жёлтые|r", kinds = { medium = true } },
	{ key = "green", text = "|cff40c040Только зелёные|r", kinds = { easy = true } },
	{ key = "all", text = "Все рецепты (и |cff999999серые|r)", kinds = { optimal = true, medium = true, easy = true, trivial = true } },
}

local function MapSettings()
	local db = CP.DB()
	db.map = db.map or { bags = false, off = {} }
	db.map.off = db.map.off or {}
	db.map.kindMode = db.map.kindMode or "skill" -- по умолчанию всё, что даёт навык
	local mode = KIND_MODES[1]
	for _, m in ipairs(KIND_MODES) do
		if m.key == db.map.kindMode then mode = m end
	end
	db.map.kinds = mode.kinds
	db.map.kindText = mode.text
	return db.map
end

----------------------------------------------------------------------------------------------
-- Окно
local map = CreateFrame("Frame", "CraftPlanMap", UIParent)
-- полоса свёрнута и план не считался — посчитать, раз карта открыта
map:SetScript("OnShow", function() if CraftPlan.planStale then Refresh() end end)
map:SetWidth(980)
map:SetHeight(620)
map:SetPoint("CENTER")
map:SetFrameStrata("DIALOG")
map:SetBackdrop({
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
map:EnableMouse(true)
map:SetMovable(true)
map:SetResizable(true)
map:SetMinResize(760, 420)
map:SetClampedToScreen(true)
map:RegisterForDrag("LeftButton")
local function SaveMapGeometry()
	local point, _, relPoint, x, y = map:GetPoint()
	local db = CP.DB()
	db.mapPos = { point, relPoint, x, y }
	db.mapSize = { map:GetWidth(), map:GetHeight() }
end
map:SetScript("OnDragStart", map.StartMoving)
map:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	SaveMapGeometry()
end)
map:Hide()

-- уголок справа внизу — потянуть, чтобы изменить размер окна
local grip = CreateFrame("Button", nil, map)
grip:SetWidth(16)
grip:SetHeight(16)
grip:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", -8, 8)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function() map:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function()
	map:StopMovingOrSizing()
	SaveMapGeometry()
	CP.MapRefresh()
end)

local function RestoreMapGeometry()
	local db = CP.DB()
	if db.mapSize then
		map:SetWidth(db.mapSize[1])
		map:SetHeight(db.mapSize[2])
	end
	if db.mapPos then
		map:ClearAllPoints()
		map:SetPoint(db.mapPos[1], UIParent, db.mapPos[2], db.mapPos[3], db.mapPos[4])
	end
end
tinsert(UISpecialFrames, "CraftPlanMap") -- закрывается по Esc

local title = map:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", map, "TOP", 0, -16)
title:SetText("Карта крафта")
-- во время расчёта в заголовке — «(считаю план… 45%)»
function CP.UpdateMapTitle()
	if CP.IsComputing and CP.IsComputing() then
		title:SetText("Карта крафта  |cff999999(" .. CP.LoaderText() .. ")|r")
	else
		title:SetText("Карта крафта")
	end
end

local close = CreateFrame("Button", nil, map, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", map, "TOPRIGHT", -6, -6)

-- Вкладки: «Схема» — граф «что из чего», «План» — что делать по шагам
local tabs = {}
local function MakeTab(key, label, x)
	local b = CreateFrame("Button", nil, map, "UIPanelButtonTemplate")
	b:SetText(label)
	b:SetWidth(90)
	b:SetHeight(22)
	b:SetPoint("TOPLEFT", map, "TOPLEFT", x, -16)
	b:SetScript("OnClick", function()
		CP.DB().mapTab = key
		CP.MapRefresh()
	end)
	tabs[key] = b
	return b
end
MakeTab("graph", "Схема", 18)
MakeTab("plan", "План", 112)

local hint = map:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOMLEFT", map, "BOTTOMLEFT", 20, 12)
hint:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", -30, 12)
hint:SetJustifyH("LEFT")
hint:SetText("Рамка — цвет рецепта, |cffffd200золотая|r — материал нужен нескольким профессиям, монета — продаётся у торговца, синяя сумка — есть в банке, значок справа вверху — нужно рядом: огонь, горн, наковальня, набор ювелира. " ..
	"Цифра: белая — есть, |cff40ff40+N|r — можно создать, «|cffaaaaaa19/|r|cff40ff401|r» — можно создать / навык по плану. " ..
	"Щелчок — подсветка, правый — где взять. Колесо, Shift+колесо, Ctrl+колесо — прокрутка и масштаб.")

local scroll = CreateFrame("ScrollFrame", "CraftPlanMapScroll", map, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", map, "TOPLEFT", 18, -94)
scroll:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", -36, 42)
-- колесо мыши — вверх/вниз, с Shift — влево/вправо (если схема шире окна)
local defaultWheel = scroll:GetScript("OnMouseWheel")
local mapScale = 1
scroll:SetScript("OnMouseWheel", function(self, delta)
	if IsControlKeyDown() then
		mapScale = math.min(1.5, math.max(0.4, mapScale + delta * 0.1))
		self:GetScrollChild():SetScale(mapScale)
		self:UpdateScrollChildRect()
	elseif IsShiftKeyDown() then
		local maxX = math.max(0, self:GetScrollChild():GetWidth() - self:GetWidth())
		self:SetHorizontalScroll(math.min(maxX, math.max(0, self:GetHorizontalScroll() - delta * 80)))
	elseif defaultWheel then
		defaultWheel(self, delta)
	end
end)
local content = CreateFrame("Frame", nil, scroll)
content:SetWidth(900)
content:SetHeight(400)
scroll:SetScrollChild(content)

-- Поиск по названию: подсвечивает цепочки всех найденных предметов
local searchBox = CreateFrame("EditBox", "CraftPlanMapSearch", map, "InputBoxTemplate")
searchBox:SetWidth(170)
searchBox:SetHeight(20)
searchBox:SetPoint("TOPRIGHT", map, "TOPRIGHT", -40, -18)
searchBox:SetAutoFocus(false)
searchBox:SetTextInsets(0, 18, 0, 0) -- место под крестик справа
local searchLabel = map:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
searchLabel:SetPoint("RIGHT", searchBox, "LEFT", -8, 0)
searchLabel:SetText("Поиск:")

local empty = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
empty:SetPoint("TOP", content, "TOP", 0, -40)
empty:SetWidth(800)

-- Всё, что относится к вкладке «Схема» (кнопки профессий, список, переключатели, поиск),
-- лежит в одном контейнере — на вкладке «План» он прячется целиком
local graphTools = CreateFrame("Frame", nil, map)
graphTools:SetAllPoints(map)
searchBox:SetParent(graphTools)

-- Вкладка «План»: список «Как качать дальше» в своей области прокрутки
local needScroll = CreateFrame("ScrollFrame", "CraftPlanNeedScroll", map, "UIPanelScrollFrameTemplate")
needScroll:SetPoint("TOPLEFT", map, "TOPLEFT", 18, -110)
needScroll:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", -36, 42)
need:SetParent(needScroll)
need:ClearAllPoints()
need:SetPoint("TOPLEFT", needScroll, "TOPLEFT", 0, 0)
need:EnableMouse(false)
needScroll:SetScrollChild(need)
needScroll:Hide()

-- Выпадающий список «какие рецепты показывать»
local KIND_DROP_WIDTH = 190
local kindDrop = CreateFrame("Frame", "CraftPlanMapKind", graphTools, "UIDropDownMenuTemplate")
kindDrop:SetPoint("TOPLEFT", map, "TOPLEFT", 2, -60)
UIDropDownMenu_SetWidth(kindDrop, KIND_DROP_WIDTH)
UIDropDownMenu_Initialize(kindDrop, function(self, level)
	local settings = MapSettings()
	for _, m in ipairs(KIND_MODES) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = m.text
		info.checked = (settings.kindMode == m.key)
		info.func = function()
			settings.kindMode = m.key
			CloseDropDownMenus()
			CP.MapRefresh()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end)

-- Переключатели в окне карты — свои, без стандартных шаблонов (их может не быть в клиенте).
-- kind = "radio" (выбор из нескольких) или "check" (вкл/выкл)
local function MapToggle(kind, label, onClick, parent)
	local b = CreateFrame("Button", nil, parent or graphTools)
	b:SetHeight(20)
	b.box = b:CreateTexture(nil, "ARTWORK")
	b.box:SetPoint("LEFT", b, "LEFT", 0, 0)
	if kind == "radio" then
		b.box:SetTexture("Interface\\Buttons\\UI-RadioButton")
		b.box:SetWidth(16)
		b.box:SetHeight(16)
	else
		b.box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
		b.box:SetWidth(22)
		b.box:SetHeight(22)
		b.check = b:CreateTexture(nil, "OVERLAY")
		b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
		b.check:SetAllPoints(b.box)
	end
	b.kind = kind
	b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.text:SetPoint("LEFT", b.box, "RIGHT", 3, 0)
	b.text:SetText(label)
	b.width = b.box:GetWidth() + 3
	b:SetWidth(b.width + b.text:GetStringWidth() + 4)
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 0.82, 0) end)
	b:SetScript("OnLeave", function(self) self.text:SetTextColor(1, 1, 1) end)
	function b:SetOn(on)
		if self.kind == "radio" then
			if on then self.box:SetTexCoord(0.25, 0.5, 0, 1) else self.box:SetTexCoord(0, 0.25, 0, 1) end
		elseif on then
			self.check:Show()
		else
			self.check:Hide()
		end
	end
	b:Hide()
	return b
end
local function SetSource(bags, planOnly)
	local st = MapSettings()
	st.bags, st.planOnly = bags, planOnly
	CP.MapRefresh()
end
local radioAny = MapToggle("radio", "Из любых материалов", function() SetSource(false, false) end)
local radioCan = MapToggle("radio", "Только то, что можно создать", function() SetSource(true, false) end)
local radioPlan = MapToggle("radio", "Только план", function() SetSource(false, true) end)
-- вкладка «План»: брать ли жёлтые и зелёные рецепты (навык растёт только с шансом)
local bankCheck = MapToggle("check", "Учитывать банк (то, что лежит в банке, считается доступным)", function()
	local db = CP.DB()
	db.noBank = not db.noBank
	CP.FullRefresh()
end, map)
local oreCheck = MapToggle("check", "Скрыть жилы без пользы для навыка", function(self)
	local db = CP.DB()
	db.hideUseless = not db.hideUseless
	self:SetOn(db.hideUseless)
	CP.ApplyOreFilter()
	CP.NeedRefresh()
end, map)
local allowCheck = MapToggle("check", "Брать жёлтые и зелёные рецепты (навык с шансом, тратит материалы)", function()
	local db = CP.DB()
	db.allowChance = not db.allowChance
	CP.FullRefresh()
end, map)

----------------------------------------------------------------------------------------------
-- Кнопки-переключатели: профессии и фильтры
local toggles = {}
local function ToggleButton(i)
	local b = toggles[i]
	if not b then
		b = CreateFrame("Button", nil, graphTools, "UIPanelButtonTemplate")
		b:SetHeight(20)
		-- цветная полоска под включённой кнопкой-переключателем
		b.mark = b:CreateTexture(nil, "OVERLAY")
		b.mark:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 4, -3)
		b.mark:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, -3)
		b.mark:SetHeight(3)
		b.mark:Hide()
		toggles[i] = b
	end
	return b
end

----------------------------------------------------------------------------------------------
-- Граф: узлы — предметы, рёбра — «материал → изделие» для каждой профессии
local function ItemID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

local function BuildGraph(settings)
	local nodes, edges = {}, {}
	local profNames = {}
	for profName in pairs(CP.DB().profs) do profNames[#profNames + 1] = profName end
	table.sort(profNames)
	local profIndex = {}
	for i, name in ipairs(profNames) do profIndex[name] = i end

	local function Node(key)
		local n = nodes[key]
		if not n then
			n = { key = key, ins = {}, outs = {}, uses = {} }
			nodes[key] = n
		end
		return n
	end

	-- Показываем рецепты включённых профессий нужного цвета. Плюс вся цепочка к ним: рецепты,
	-- чей результат нужен показанным, — даже серые и даже из выключенной профессии (например,
	-- для ювелирного дела — выплавка слитков из горного дела), иначе не видно «руда → слиток → изделие».
	local kinds = settings.kinds
	-- кто что производит: номер предмета → рецепт (слиток ← выплавка)
	local producers = {}
	for _, profName in ipairs(profNames) do
		for _, rec in ipairs(CP.DB().profs[profName].recipes) do
			local id = ItemID(rec.link)
			if id and #rec.reagents > 0 and not producers[id] then producers[id] = rec end
		end
	end
	-- Хватает ли ВСЕХ ингредиентов хотя бы на одно создание — из того, что есть, или из того,
	-- что можно создать из имеющегося (слитки из руды), до 4 шагов в глубину
	local function CanCraft(rec, times, depth, visiting)
		if depth > 4 or visiting[rec] then return false end
		visiting[rec] = true
		local ok = true
		for _, r in ipairs(rec.reagents) do
			local need = r.count * times - TotalCount(r)
			if need > 0 then
				local pr = r.id and producers[r.id]
				if not (pr and CanCraft(pr, math.ceil(need / math.max(1, pr.made or 1)), depth + 1, visiting)) then
					ok = false
					break
				end
			end
		end
		visiting[rec] = nil
		return ok
	end
	local function HasSome(rec) return CanCraft(rec, 1, 0, {}) end
	local shown = {}    -- рецепты, которые показываем сами по себе
	local feeds = {}    -- рецепты из цепочки к показанным
	local needed = {}   -- ключи материалов, нужных показанным рецептам
	local function Mark(rec)
		for _, r in ipairs(rec.reagents) do needed[CP.ReagentKey(r)] = true end
	end
	if settings.planOnly then
		-- «Только план»: ровно то, что на полосе сверху, вместе с промежуточными шагами
		for rec in pairs(CP.planCount or {}) do
			shown[rec] = true
			Mark(rec)
		end
	else
		for _, profName in ipairs(profNames) do
			if not settings.off[profName] then
				for _, rec in ipairs(CP.DB().profs[profName].recipes) do
					if kinds[rec.kind] and #rec.reagents > 0 and (not settings.bags or HasSome(rec)) then
						shown[rec] = true
						Mark(rec)
					end
				end
			end
		end
	end
	local changed = true
	while changed do
		changed = false
		for _, profName in ipairs(profNames) do -- все профессии, включая выключенные
			for _, rec in ipairs(CP.DB().profs[profName].recipes) do
				local pid = ItemID(rec.link)
				if not shown[rec] and not feeds[rec] and #rec.reagents > 0 and pid and needed[pid] then
					feeds[rec] = true
					Mark(rec)
					changed = true
				end
			end
		end
	end

	for _, profName in ipairs(profNames) do
		do
			for _, rec in ipairs(CP.DB().profs[profName].recipes) do
				if shown[rec] or feeds[rec] then
					local pid = ItemID(rec.link)
					local p = Node(pid or ("recipe:" .. profName .. ":" .. rec.name))
					p.id = p.id or pid
					p.name = p.name or rec.name
					p.icon = p.icon or rec.icon
					p.link = p.link or rec.link
					p.prof, p.rec = profName, rec
					for _, r in ipairs(rec.reagents) do
						local m = Node(CP.ReagentKey(r))
						m.id = m.id or r.id
						m.name = m.name or r.name
						m.icon = m.icon or r.icon
						m.uses[profName] = (m.uses[profName] or 0) + 1
						local e = { from = m, to = p, prof = profName, color = PROF_COLORS[(profIndex[profName] - 1) % #PROF_COLORS + 1], count = r.count }
						edges[#edges + 1] = e
						m.outs[#m.outs + 1] = e
						p.ins[#p.ins + 1] = e
					end
				end
			end
		end
	end

	-- колонка = глубина: материал без рецепта — 0, изделие — 1 + самая глубокая из его частей
	local function Depth(n, visiting)
		if n.depth then return n.depth end
		if visiting[n] or #n.ins == 0 then return 0 end -- круговые рецепты (например, превращения) обрываем
		visiting[n] = true
		local d = 0
		for _, e in ipairs(n.ins) do d = math.max(d, Depth(e.from, visiting) + 1) end
		visiting[n] = nil
		n.depth = d
		return d
	end
	local maxDepth = 0
	for _, n in pairs(nodes) do
		n.depth = Depth(n, {})
		maxDepth = math.max(maxDepth, n.depth)
	end
	-- конечные изделия (их больше ни во что не превращают) — всегда в последней колонке,
	-- чтобы «кувалда» не стояла посередине, а все готовые вещи были справа
	for _, n in pairs(nodes) do
		if n.rec and #n.outs == 0 then n.depth = maxDepth end
	end
	local columns = {}
	for i = 1, maxDepth + 1 do columns[i] = {} end
	for _, n in pairs(nodes) do
		table.insert(columns[n.depth + 1], n)
	end

	-- порядок: в первой колонке общие материалы выше, дальше — по профессии и названию;
	-- в остальных — по средней высоте материалов, чтобы линии меньше пересекались
	local function ProfCount(n) local c = 0 for _ in pairs(n.uses) do c = c + 1 end return c end
	local function FirstProf(n)
		local best
		for name in pairs(n.uses) do if not best or profIndex[name] < best then best = profIndex[name] end end
		return best or 0
	end
	if columns[1] then
		table.sort(columns[1], function(a, b)
			local ca, cb = ProfCount(a), ProfCount(b)
			if ca ~= cb then return ca > cb end
			local fa, fb = FirstProf(a), FirstProf(b)
			if fa ~= fb then return fa < fb end
			return (a.name or "") < (b.name or "")
		end)
	end
	-- колонки, где предметов меньше, чем в самой высокой, растягиваем на всю высоту:
	-- предметы стоят дальше друг от друга, стрелки не накладываются, одиночный — посередине
	local maxRows = 0
	for _, col in ipairs(columns) do maxRows = math.max(maxRows, #col) end
	for ci, col in ipairs(columns) do
		if ci > 1 then
			for _, n in ipairs(col) do
				local sum, cnt = 0, 0
				for _, e in ipairs(n.ins) do
					if e.from.row then sum = sum + e.from.row; cnt = cnt + 1 end
				end
				n.bary = cnt > 0 and sum / cnt or 0
			end
			table.sort(col, function(a, b)
				if a.bary ~= b.bary then return a.bary < b.bary end
				return (a.name or "") < (b.name or "")
			end)
		end
		local count = #col
		for idx, n in ipairs(col) do
			n.slot = idx - 1 -- порядковый номер в колонке
			n.row = (count < maxRows) and ((idx - 0.5) * maxRows / count - 0.5) or (idx - 1)
		end
	end
	return nodes, edges, columns, profNames, profIndex
end

----------------------------------------------------------------------------------------------
-- Рисование: значки и линии из пулов
local nodeFrames, nodeUsed = {}, 0
local lineTex, lineUsed = {}, 0
local arrowTex, arrowUsed = {}, 0
local currentEdges = {}

local function Line()
	lineUsed = lineUsed + 1
	local t = lineTex[lineUsed]
	if not t then
		t = content:CreateTexture(nil, "BORDER")
		lineTex[lineUsed] = t
	end
	t:ClearAllPoints()
	t:Show()
	return t
end

-- Горизонтальный или вертикальный отрезок; координаты от левого верхнего угла, y вниз отрицательный
local function Segment(x1, y1, x2, y2, c)
	local t = Line()
	t:SetTexture(c[1], c[2], c[3], 1)
	if y1 == y2 then
		t:SetPoint("TOPLEFT", content, "TOPLEFT", math.min(x1, x2), y1 + LINE / 2)
		t:SetWidth(math.max(1, math.abs(x2 - x1)))
		t:SetHeight(LINE)
	else
		t:SetPoint("TOPLEFT", content, "TOPLEFT", x1 - LINE / 2, math.max(y1, y2) + LINE / 2)
		t:SetWidth(LINE)
		t:SetHeight(math.abs(y2 - y1) + LINE)
	end
	return t
end

local function Arrow(x, y, c)
	arrowUsed = arrowUsed + 1
	local t = arrowTex[arrowUsed]
	if not t then
		t = content:CreateTexture(nil, "ARTWORK")
		t:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
		t:SetWidth(12)
		t:SetHeight(12)
		arrowTex[arrowUsed] = t
	end
	t:ClearAllPoints()
	t:SetPoint("RIGHT", content, "TOPLEFT", x + 2, y)
	t:SetVertexColor(c[1], c[2], c[3])
	t:Show()
	return t
end

local function SetEdgeAlpha(e, a)
	for _, t in ipairs(e.tex) do t:SetAlpha(a) end
end

-- Подсветка при наведении: вся цепочка ингредиентов вниз до сырья (золотом) и всё, что из
-- предмета делается дальше (голубым); остальное тускнеет. nil — убрать подсветку.
local function Collect(node, field, endField, set)
	for _, e in ipairs(node[field]) do
		local other = e[endField]
		if not set[other] then
			set[other] = true
			Collect(other, field, endField, set)
		end
	end
	return set
end

-- list — узлы, чьи цепочки подсвечивать; nil или пусто — без подсветки
local function Highlight(list)
	local node = list and list[1] -- есть ли что подсвечивать
	local up, down, self = {}, {}, {}
	if node then
		for _, n in ipairs(list) do
			self[n] = true
			Collect(n, "ins", "from", up)
			Collect(n, "outs", "to", down)
		end
	end
	for _, e in ipairs(currentEdges) do
		local lit = node and (((self[e.to] or up[e.to]) and up[e.from]) or ((self[e.from] or down[e.from]) and down[e.to]))
		SetEdgeAlpha(e, node and (lit and 1 or DIM_ALPHA) or LINE_ALPHA)
	end
	for k = 1, nodeUsed do
		local f = nodeFrames[k]
		local n = f.node
		local glow = node and ((self[n] and GLOW_UP) or (up[n] and GLOW_UP) or (down[n] and GLOW_DOWN))
		if glow then
			f.glow:SetVertexColor(glow[1], glow[2], glow[3])
			f.glow:Show()
		else
			f.glow:Hide()
		end
		f:SetAlpha((not node or glow) and 1 or NODE_DIM_ALPHA)
	end
end

-- Закреплённая подсветка: от щелчка по предмету (на карте или на полосе) или от поиска
local focusKeys = nil  -- { [ключ узла] = true }
local currentNodes = {}

local CYR_UP = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
local CYR_LOW = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
local lowerMap = {}
do
	local ups, lows = {}, {}
	for ch in CYR_UP:gmatch("[\192-\255][\128-\191]*") do ups[#ups + 1] = ch end
	for ch in CYR_LOW:gmatch("[\192-\255][\128-\191]*") do lows[#lows + 1] = ch end
	for i = 1, #ups do lowerMap[ups[i]] = lows[i] end
end
local function Lower(text)
	return (text:gsub("[\192-\255][\128-\191]*", lowerMap):lower())
end

local function FocusList()
	local list = {}
	local query = searchBox:GetText() or ""
	if focusKeys then
		for key in pairs(focusKeys) do
			if currentNodes[key] then list[#list + 1] = currentNodes[key] end
		end
	elseif query ~= "" then
		local q = Lower(query)
		for _, n in pairs(currentNodes) do
			if n.name and Lower(n.name):find(q, 1, true) then list[#list + 1] = n end
		end
	end
	return list
end

-- Перед последней колонкой (конечные предметы) — дополнительный отступ, чтобы стрелкам было
-- где развести вертикали и они не накладывались
local LAST_GAP = 50
local lastDepth = -1
local function NodePosOf(n)
	local extra = (n.depth > 0 and n.depth == lastDepth) and LAST_GAP or 0
	return PAD + n.depth * COL_W + extra, -(PAD + n.row * ROW_H)
end

-- Прокрутить так, чтобы узел оказался посередине окна
-- Прокрутить к узлу, только если его сейчас не видно (чтобы схема не прыгала)
local function ScrollTo(n)
	if not n then return end
	local x, y = NodePosOf(n)
	local px, py = x * mapScale, -y * mapScale
	local w, h = scroll:GetWidth(), scroll:GetHeight()
	local sx, sy = scroll:GetHorizontalScroll(), scroll:GetVerticalScroll()
	if py < sy or py + NODE * mapScale > sy + h then
		scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScrollRange(), py - h / 2)))
	end
	if px < sx or px + BOX * mapScale > sx + w then
		local maxX = math.max(0, content:GetWidth() * mapScale - w)
		scroll:SetHorizontalScroll(math.max(0, math.min(maxX, px - w / 3)))
	end
end

local function ApplyFocus(scrollToIt)
	local list = FocusList()
	Highlight(list)
	if scrollToIt then ScrollTo(list[1]) end
	return list
end

-- крестик справа в поле поиска: снять выбор предмета / очистить поиск
local searchClear = CreateFrame("Button", nil, searchBox)
searchClear:SetWidth(14)
searchClear:SetHeight(14)
searchClear:SetPoint("RIGHT", searchBox, "RIGHT", -3, 0)
searchClear:SetNormalTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
searchClear:SetHighlightTexture("Interface\\FriendsFrame\\ClearBroadcastIcon", "ADD")
searchClear:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:AddLine("Очистить: снять выбор предмета и поиск")
	GameTooltip:Show()
end)
searchClear:SetScript("OnLeave", function() GameTooltip:Hide() end)
searchClear:Hide()

searchBox:SetScript("OnTextChanged", function(self)
	if self:GetText() ~= "" then searchClear:Show() else searchClear:Hide() end
	-- текст, вписанный самим аддоном (щелчок по предмету), — не поиск
	if self.settingText or self:GetText() == self.programText then return end
	focusKeys = nil -- поиск заменяет закреплённый предмет
	ApplyFocus(true)
end)
searchBox:SetScript("OnEscapePressed", function(self)
	self:SetText("")
	self:ClearFocus()
end)
searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

local function SetFocus(node)
	focusKeys = node and { [node.key] = true } or nil
	searchBox.settingText = true
	searchBox.programText = node and (node.name or "") or ""
	searchBox:SetText(searchBox.programText)
	searchBox.settingText = nil
	if searchBox.programText ~= "" then searchClear:Show() else searchClear:Hide() end
	ApplyFocus(false)
end
searchClear:SetScript("OnClick", function()
	SetFocus(nil)
	searchBox:ClearFocus()
end)

-- Сколько штук предмета можно создать из того, что есть (сумки и банк), с учётом цепочек:
-- слиток из руды, изделие из слитков, которые ещё надо выплавить. Запас на ветки не делится —
-- это оценка «из имеющегося хватит на N», а не план.
local canMakeMemo = {} -- сбрасывается при каждой перерисовке схемы
local function CanMake(n, depth, visiting)
	if canMakeMemo[n] then return canMakeMemo[n] end
	if not n.rec or depth > 4 or visiting[n] then return 0 end
	visiting[n] = true
	local times = math.huge
	for _, e in ipairs(n.ins) do
		local avail = TotalCount(e.from) + CanMake(e.from, depth + 1, visiting)
		times = math.min(times, math.floor(avail / math.max(1, e.count)))
	end
	visiting[n] = nil
	local result = (times == math.huge) and 0 or times * math.max(1, n.rec.made or 1)
	canMakeMemo[n] = result
	return result
end

-- Продаётся ли предмет у торговца: сначала то, что аддон видел сам (с ценой), иначе база Questie.
-- Возвращает: краткую подпись для значка и строку для подсказки, или nil
local questieVendorCache = {}
local function VendorHint(n)
	local v = VendorInfo(n)
	if v then
		return "купить: " .. Money(v.price),
			"Продаётся: " .. (v.npc or "?") .. " (" .. (v.zone or "?") .. "), " .. Money(v.price) .. " за шт."
	end
	if not n.id or ORE_NODES[n.id] then return nil end -- руда — из жил, даже если где-то и продаётся
	local cached = questieVendorCache[n.id]
	if cached == nil then
		cached = false
		local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
		if QuestieDB and QuestieDB.QueryItemSingle then
			local ok, vendors = pcall(QuestieDB.QueryItemSingle, n.id, "vendors")
			if ok and type(vendors) == "table" and #vendors > 0 then
				local names = {}
				for i = 1, math.min(3, #vendors) do
					names[#names + 1] = QuestieDB.QueryNPCSingle(vendors[i], "name") or "?"
				end
				cached = { count = #vendors, names = names }
			end
		end
		questieVendorCache[n.id] = cached
	end
	if cached then
		return "у торговца",
			"Продаётся у торговцев (" .. cached.count .. "): " .. table.concat(cached.names, ", ") ..
			(cached.count > 3 and " и др." or "") .. ". Правый щелчок — показать на карте."
	end
end

local function NodeTooltip(self)
	local n = self.node
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if n.link then
		GameTooltip:SetHyperlink(n.link)
	elseif n.id then
		GameTooltip:SetHyperlink("item:" .. n.id)
	else
		GameTooltip:AddLine(n.name or "?", 1, 1, 1)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Есть: " .. CountText(n), 1, 1, 1)
	if n.rec then
		local missing = {}
		for _, e in ipairs(n.ins) do
			local avail = TotalCount(e.from) + CanMake(e.from, 1, {})
			if avail < e.count then
				missing[#missing + 1] = (e.from.name or "?") .. " (есть " .. avail .. " из " .. e.count .. ")"
			end
		end
		if #missing > 0 then
			GameTooltip:AddLine("Не хватает: " .. table.concat(missing, ", "), 1, 0.35, 0.35, true)
		end
	end
	local _, vendorLine = VendorHint(n)
	if vendorLine then GameTooltip:AddLine(vendorLine, 0.53, 1, 0.53, true) end
	local canMake = CanMake(n, 0, {})
	if canMake > 0 then
		GameTooltip:AddLine((TotalCount(n) == 0 and "Нет, но можно создать: " or "Можно создать ещё: ") .. canMake .. " шт.", 0.3, 1, 0.3)
	end
	-- на сколько созданий хватает каждого ингредиента (с тем, что можно сделать из имеющегося);
	-- самый дефицитный — «ограничивает»
	if n.rec and #n.ins > 0 then
		local rows, minTimes = {}, math.huge
		for _, e in ipairs(n.ins) do
			local have, mk = TotalCount(e.from), CanMake(e.from, 1, {})
			local times = math.floor((have + mk) / math.max(1, e.count))
			rows[#rows + 1] = { e = e, have = have, mk = mk, times = times }
			minTimes = math.min(minTimes, times)
		end
		GameTooltip:AddLine("На сколько созданий хватает (по 1 изделию):", 0.8, 0.8, 0.8)
		for _, r in ipairs(rows) do
			local left = "  " .. (r.e.from.name or "?") .. " x" .. r.e.count .. ": есть " .. r.have
				.. (r.mk > 0 and (" +" .. r.mk .. " можно сделать") or "")
			local lim = (r.times == minTimes and #rows > 1) and " |cffff6060ограничивает|r" or ""
			GameTooltip:AddDoubleLine(left, "на " .. r.times .. lim, 1, 1, 1, 1, 1, 1)
		end
	end
	if n.rec then
		local c = CP.COLOR[n.rec.kind] or { 0.6, 0.6, 0.6 }
		GameTooltip:AddLine("Создаёт: " .. n.prof .. " (" .. (CP.COLOR_NAME[n.rec.kind] or "серый") .. ")", c[1], c[2], c[3])
		local cinfo = ColorInfo(n.prof, n.rec.name)
		if cinfo then GameTooltip:AddLine(cinfo, 0.8, 0.8, 0.8, true) end
		local toolText = ToolText(n.rec.tools)
		if toolText then
			GameTooltip:AddLine(toolText .. " (значок в правом верхнем углу)", 1, 0.5, 0.25, true)
		end
		for _, e in ipairs(n.ins) do
			GameTooltip:AddDoubleLine("  " .. (e.from.name or "?"), CountText(e.from) .. " / " .. e.count, 1, 1, 1, 1, 1, 1)
		end
	end
	if #n.outs > 0 then
		GameTooltip:AddLine("Нужен для:", 0.8, 0.8, 0.8)
		for i, e in ipairs(n.outs) do
			if i > 12 then
				GameTooltip:AddLine("  и ещё " .. (#n.outs - 12), 0.6, 0.6, 0.6)
				break
			end
			GameTooltip:AddDoubleLine("  " .. (e.to.name or "?"), e.prof, 1, 1, 1, e.color[1], e.color[2], e.color[3])
		end
	end
	GameTooltip:AddLine(" ")
	if n.rec then GameTooltip:AddLine("Щелчок — выбрать рецепт в открытом окне профессии и закрепить подсветку.", 0.5, 0.8, 1, true) end
	GameTooltip:AddLine("Правый щелчок — где взять.", 0.5, 0.8, 1, true)
	GameTooltip:Show()
	Highlight({ n })
end

local function NodeFrame()
	nodeUsed = nodeUsed + 1
	local f = nodeFrames[nodeUsed]
	if not f then
		f = CreateFrame("Button", nil, content)
		f:SetWidth(NODE)
		f:SetHeight(NODE)
		f:SetFrameLevel(content:GetFrameLevel() + 2)
		f.border = f:CreateTexture(nil, "BACKGROUND")
		f.border:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
		f.border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
		f.icon = f:CreateTexture(nil, "ARTWORK")
		f.icon:SetAllPoints(f)
		f.glow = f:CreateTexture(nil, "OVERLAY")
		f.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
		f.glow:SetBlendMode("ADD")
		f.glow:SetWidth(NODE * 1.9)
		f.glow:SetHeight(NODE * 1.9)
		f.glow:SetPoint("CENTER", f, "CENTER", 0, 0)
		f.glow:Hide()
		f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		f.count:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
		f.coin = f:CreateTexture(nil, "OVERLAY") -- продаётся у торговца
		f.coin:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
		f.coin:SetWidth(13)
		f.coin:SetHeight(13)
		f.coin:SetPoint("TOPLEFT", f, "TOPLEFT", -3, 3)
		f.bankMark = f:CreateTexture(nil, "OVERLAY") -- есть в банке
		f.bankMark:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Blue")
		f.bankMark:SetWidth(13)
		f.bankMark:SetHeight(13)
		f.bankMark:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -3, -3)
		f.tool = f:CreateTexture(nil, "OVERLAY") -- рецепту нужно что-то рядом (наковальня, набор ювелира…)
		f.tool:SetTexture("Interface\\Icons\\Trade_BlackSmithing")
		f.tool:SetWidth(13)
		f.tool:SetHeight(13)
		f.tool:SetPoint("TOPRIGHT", f, "TOPRIGHT", 3, 3)
		f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		f.label:SetPoint("LEFT", f, "RIGHT", 4, 0)
		f.label:SetWidth(LABEL_W)
		f.label:SetHeight(28)
		f.label:SetJustifyH("LEFT")
		f:SetScript("OnEnter", NodeTooltip)
		f:SetScript("OnLeave", function() GameTooltip:Hide(); ApplyFocus(false) end)
		f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		f:SetScript("OnClick", function(self, button)
			local n = self.node
			if IsModifiedClick("CHATLINK") and n.link then
				ChatEdit_InsertLink(n.link)
			elseif button == "RightButton" then
				WhereToGetReagent(n)
			else
				SetFocus(n)
				if n.rec and TradeSkillFrame and TradeSkillFrame:IsShown() then SelectRecipeByName(n.prof, n.rec.name) end
			end
		end)
		nodeFrames[nodeUsed] = f
	end
	f:Show()
	return f
end

local NodePos = NodePosOf

-- Вкладка «План»: только список по шагам и переключатель «с шансом»
local function DrawPlanTab()
	graphTools:Hide() -- кнопки профессий, список, переключатели и поиск «Схемы»
	scroll:Hide()
	hint:Hide()
	searchLabel:Hide()
	allowCheck:ClearAllPoints()
	allowCheck:SetPoint("TOPLEFT", map, "TOPLEFT", 20, -44)
	allowCheck:SetOn(CP.DB().allowChance)
	allowCheck:Show()
	bankCheck:ClearAllPoints()
	bankCheck:SetPoint("TOPLEFT", map, "TOPLEFT", 20, -64) -- второй строкой
	bankCheck:SetOn(not CP.DB().noBank)
	bankCheck:Show()
	oreCheck:ClearAllPoints()
	oreCheck:SetPoint("TOPLEFT", map, "TOPLEFT", 20, -84) -- третьей строкой
	oreCheck:SetOn(CP.DB().hideUseless)
	oreCheck:Show()
	needScroll:Show()
	CP.NeedRefresh()
end

local function Draw()
	local db = CP.DB()
	local tab = db.mapTab or "graph"
	for key, b in pairs(tabs) do
		if key == tab then b:LockHighlight() else b:UnlockHighlight() end
	end
	if tab == "plan" then
		DrawPlanTab()
		return
	end
	allowCheck:Hide()
	bankCheck:Hide()
	oreCheck:Hide()
	needScroll:Hide()
	graphTools:Show()
	for _, w in ipairs({ scroll, kindDrop, searchBox, searchLabel, hint }) do w:Show() end

	local settings = MapSettings()
	canMakeMemo = {}
	local nodes, edges, columns, profNames, profIndex = BuildGraph(settings)
	lastDepth = #columns - 1

	-- кнопки сверху: профессии (вкл/выкл) и два фильтра
	local i, x = 0, 18
	local rowY = -44
	-- isToggle — кнопка-переключатель (профессия): включена — золотой текст и подсветка;
	-- выключена — серая и бледная
	local function Place(text, onClick, on, color, tooltip, isToggle)
		i = i + 1
		local b = ToggleButton(i)
		if isToggle and not on then text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end -- выключенная: весь текст серый
		b:SetText(text)
		b:SetWidth(b:GetFontString():GetStringWidth() + 20)
		-- не влезает в окно — переносим на следующую строку
		if x > 18 and x + b:GetWidth() > map:GetWidth() - 24 then
			x = 18
			rowY = rowY - 26
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", map, "TOPLEFT", x, rowY)
		local fs = b:GetFontString()
		if isToggle then
			b:SetAlpha(on and 1 or 0.6)
			if on then
				b:LockHighlight()
				b.mark:Hide() -- без полоски снизу
				fs:SetTextColor(1, 0.82, 0)
			else
				b:UnlockHighlight()
				b.mark:Hide()
				fs:SetTextColor(0.5, 0.5, 0.5)
			end
		else
			b:SetAlpha(1)
			b:UnlockHighlight()
			b.mark:Hide()
			if color then fs:SetTextColor(color[1], color[2], color[3]) else fs:SetTextColor(1, 0.82, 0) end
		end
		b:SetScript("OnClick", onClick)
		b:SetScript("OnEnter", tooltip)
		b:SetScript("OnLeave", tooltip and function() GameTooltip:Hide() end or nil)
		b:Show()
		x = x + b:GetWidth() + 4
	end
	-- в режиме «Только план» профессии и цвет рецептов ни на что не влияют — их не показываем
	if not settings.planOnly then
		for _, name in ipairs(profNames) do
			local info = CP.profSummary and CP.profSummary[name]
			Place(name .. (info and ("  " .. info) or ""), function()
				settings.off[name] = not settings.off[name] or nil
				CP.MapRefresh()
			end, not settings.off[name], PROF_COLORS[(profIndex[name] - 1) % #PROF_COLORS + 1], CP.SummaryTooltip, true)
		end
		-- второй ряд: список «какие рецепты» (ценность для навыка) и наличие материалов
		_G[kindDrop:GetName() .. "Text"]:SetText(settings.kindText)
		rowY, x = rowY - 40, 18 + KIND_DROP_WIDTH + 40 -- отступ между кнопками профессий и рядом со списком
		kindDrop:ClearAllPoints()
		kindDrop:SetPoint("TOPLEFT", map, "TOPLEFT", 2, rowY + 6)
		kindDrop:Show()
	else
		kindDrop:Hide()
		x = 18 -- переключатели сразу в первом ряду
	end
	-- галочки: видно, включено или нет
	for _, c in ipairs({ { radioAny, not settings.bags and not settings.planOnly }, { radioCan, settings.bags and not settings.planOnly },
		{ radioPlan, settings.planOnly } }) do
		local box, checked = c[1], c[2]
		local w = box.width + box.text:GetStringWidth() + 16
		if x + w > map:GetWidth() - 24 then
			x = 18
			rowY = rowY - 26
		end
		box:ClearAllPoints()
		box:SetPoint("TOPLEFT", map, "TOPLEFT", x, rowY)
		box:SetOn(checked and true or false)
		box:Show()
		x = x + w
	end
	-- включено «Горное дело» — та же галочка, что во вкладке «План»: скрыть жилы без пользы
	local miningOn = false
	if not settings.planOnly and not settings.off["Горное дело"] then
		for _, name in ipairs(profNames) do
			if name == "Горное дело" then miningOn = true end
		end
	end
	if miningOn then
		local w = oreCheck.width + oreCheck.text:GetStringWidth() + 16
		if x + w > map:GetWidth() - 24 then
			x = 18
			rowY = rowY - 26
		end
		oreCheck:ClearAllPoints()
		oreCheck:SetPoint("TOPLEFT", map, "TOPLEFT", x, rowY)
		oreCheck:SetOn(db.hideUseless)
		oreCheck:Show()
		x = x + w
	end
	for j = i + 1, #toggles do toggles[j]:Hide() end
	-- схема и панель «Чего не хватает» начинаются под последней строкой кнопок
	scroll:SetPoint("TOPLEFT", map, "TOPLEFT", 18, rowY - 28)

	-- слишком большая схема рисуется долго и бесполезна — просим сузить
	local MAX_NODES = 500
	local nodeCount = 0
	for _ in pairs(nodes) do nodeCount = nodeCount + 1 end
	if nodeCount > MAX_NODES then
		for k = 1, nodeUsed do nodeFrames[k]:Hide() end
		for k = 1, lineUsed do lineTex[k]:Hide() end
		for k = 1, arrowUsed do arrowTex[k]:Hide() end
		nodeUsed, lineUsed, arrowUsed = 0, 0, 0
		currentEdges, currentNodes = {}, {}
		empty:SetText("На схеме получилось " .. nodeCount .. " предметов — это слишком много для одного окна.\n" ..
			"Сузьте: выключите лишние профессии, выберите «Только оранжевые» или «Только план».")
		empty:Show()
		content:SetWidth(900)
		content:SetHeight(400)
		scroll:UpdateScrollChildRect()
		return
	end

	-- значки
	for k = 1, nodeUsed do nodeFrames[k]:Hide() end
	nodeUsed = 0
	local maxRows = 0
	for _, col in ipairs(columns) do maxRows = math.max(maxRows, #col) end
	for _, n in pairs(nodes) do
		local f = NodeFrame()
		f.node = n
		local nx, ny = NodePos(n)
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", content, "TOPLEFT", nx, ny)
		f.icon:SetTexture(n.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		local profCount = 0
		for _ in pairs(n.uses) do profCount = profCount + 1 end
		local b = (n.rec and CP.COLOR[n.rec.kind]) or (profCount > 1 and SHARED_BORDER) or BASE_BORDER
		f.border:SetTexture(b[1], b[2], b[3], 0.95)
		local have = TotalCount(n)
		local canMake = (have == 0) and CanMake(n, 0, {}) or 0
		local planN = n.rec and CP.planCount and CP.planCount[n.rec]
		if settings.planOnly and planN then
			-- «Только план»: как на полосе — «можно создать / что даст навык по плану»
			local pe = CP.planEntry and CP.planEntry[n.rec]
			local right = (pe and pe.gain > 0) and ("|cff40ff40" .. pe.gain .. "|r") or ("|cffffff00" .. planN .. "|r")
			f.count:SetText("|cffaaaaaa" .. (have + CanMake(n, 0, {})) .. "/|r" .. right)
		elseif have > 0 then
			f.count:SetText(have)
		elseif canMake > 0 then
			f.count:SetText("|cff40ff40+" .. canMake .. "|r") -- нет, но можно создать из имеющегося
		else
			f.count:SetText("")
		end
		local vendorShort = VendorHint(n)
		f.label:SetText(n.name or "?")
		if vendorShort then f.coin:Show() else f.coin:Hide() end
		if BankCount(n) > 0 then f.bankMark:Show() else f.bankMark:Hide() end
		local toolIcon = n.rec and ToolIcon(n.rec.tools)
		if toolIcon then
			f.tool:SetTexture(toolIcon)
			f.tool:Show()
		else
			f.tool:Hide()
		end
		-- серым: материала нет; изделие, на которое сейчас не хватает материалов (даже с учётом
		-- того, что можно создать по пути), — серое и бледное
		local cannot = n.rec and have == 0 and canMake == 0
		f.icon:SetDesaturated((have == 0 and not n.rec) or cannot)
		f.icon:SetAlpha(cannot and 0.5 or 1)
		if cannot then f.label:SetTextColor(0.55, 0.55, 0.55) else f.label:SetTextColor(1, 1, 1) end
	end

	-- линии: от правого края подписи материала до изделия, с изломом перед колонкой изделия
	for k = 1, lineUsed do lineTex[k]:Hide() end
	for k = 1, arrowUsed do arrowTex[k]:Hide() end
	lineUsed, arrowUsed = 0, 0
	currentEdges = edges
	-- цвет ветки — по изделию; соседние изделия в колонке получают разные цвета
	local k = 0
	for ci, col in ipairs(columns) do
		if ci > 1 then
			for _, n in ipairs(col) do
				k = k + 1
				n.color = BRANCH_COLORS[(k - 1) % #BRANCH_COLORS + 1]
			end
		end
	end
	for _, e in ipairs(edges) do
		e.color = e.to.color or e.color
		local fx, fy = NodePos(e.from)
		local tx, ty = NodePos(e.to)
		local x1, y1 = fx + BOX, fy - NODE / 2
		local x2, y2 = tx - 4, ty - NODE / 2
		-- разные изделия — разные вертикали; перед последней колонкой места больше
		local xm = (e.to.depth == lastDepth and e.to.depth > 0)
			and (x2 - 10 - (e.to.slot % 12) * 6)
			or (x2 - 8 - (e.to.slot % 5) * 5)
		e.tex = {
			Segment(x1, y1, xm, y1, e.color),
			Segment(xm, y1, xm, y2, e.color),
			Segment(xm, y2, x2, y2, e.color),
			Arrow(x2, y2, e.color),
		}
		SetEdgeAlpha(e, LINE_ALPHA)
	end

	content:SetWidth(math.max(900, PAD * 2 + #columns * COL_W + LAST_GAP))
	content:SetHeight(math.max(400, PAD * 2 + maxRows * ROW_H))
	scroll:UpdateScrollChildRect()

	currentNodes = nodes
	ApplyFocus(false)

	if next(nodes) == nil then
		empty:SetText(next(CP.DB().profs) == nil
			and "Рецептов пока нет. Откройте окно каждой профессии один раз — аддон их запомнит."
			or "Под эти фильтры ничего не подходит. Включите профессии или переключите фильтры кнопками сверху.")
		empty:Show()
	else
		empty:Hide()
	end
end

function CP.MapRefresh()
	if map:IsShown() then Draw() end
end

local geometryRestored = false
local function ShowMap()
	if not geometryRestored then
		RestoreMapGeometry()
		geometryRestored = true
	end
	map:Show()
	Draw()
end

function CP.ToggleMap()
	if map:IsShown() then map:Hide() else ShowMap() end
end

function CP.OpenMap()
	if not map:IsShown() then ShowMap() end
end

-- Открыть карту и подсветить только цепочку этого предмета (щелчок по иконке на полосе)
function CP.FocusItem(key, name)
	CP.DB().mapTab = "graph" -- цепочку показывает «Схема»
	if not map:IsShown() then ShowMap() end
	Draw()
	local node = currentNodes[key]
	if not node then
		SetFocus(nil)
		Print("«" .. (name or "?") .. "» не попал на карту из-за фильтров — включите его профессию или «Из любых материалов».")
		return
	end
	SetFocus(node)
	ScrollTo(node)
end

----------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------
-- Рыбалка. Ничего не делает сам — только кнопки, подсказки и журнал:
-- журнал улова (что и где поймано), подсказка «ловится» к предмету, навык и срывы по зоне,
-- кнопки «удочка/оружие», «приманка», «забросить», громкий всплеск поплавка.
-- Отдельная функция — свои локальные переменные, не мешают основному коду (лимит 200 на функцию).
;(function()
_G["BINDING_NAME_CLICK CraftPlanFishCast:LeftButton"] = "Забросить удочку"
_G["BINDING_NAME_CLICK CraftPlanFishLure:LeftButton"] = "Наложить приманку"
BINDING_NAME_CRAFTPLAN_FISH_SWAP = "Надеть удочку / вернуть оружие"

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
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCraftPlan (рыбалка):|r " .. msg)
end

-- Журнал улова и настройки рыбалки — внутри CraftPlanDB (по персонажу)
local function DB()
	CraftPlanDB = CraftPlanDB or {}
	local f = CraftPlanDB.fish or {}
	CraftPlanDB.fish = f
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
function CraftPlan.FishSwap()
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
-- Используется в плане (строка «Поймать»).
function CraftPlan.FishWhere(itemID)
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
local panel = CreateFrame("Frame", "CraftPlanFishFrame", UIParent)
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

local swapButton = MakeButton("CraftPlanFishSwap", nil, 1, "Удочка / оружие", function()
	return PoleEquipped() and "Вернуть оружие, которое было до удочки." or "Надеть удочку из сумки (оружие запомнится)."
end)
swapButton:SetScript("OnClick", CraftPlan.FishSwap)

local lureButton = MakeButton("CraftPlanFishLure", "SecureActionButtonTemplate", 2, "Приманка", function()
	local _, _, id = BestLure()
	if not id then return "В сумках нет приманки." end
	return "Наложить на удочку: " .. (GetItemInfo(id) or ("предмет " .. id)) .. ". Цифра — сколько минут осталось у текущей приманки."
end)
lureButton:SetAttribute("type", "macro")

local castButton = MakeButton("CraftPlanFishCast", "SecureActionButtonTemplate", 3, "Забросить",
	"Забросить удочку. Клавишу можно назначить: «Назначение клавиш», раздел «CraftPlan (профессии)».")
castButton:SetAttribute("type", "spell")
castButton:SetAttribute("spell", (GetSpellInfo(FISHING_SPELL)))
castButton.icon:SetTexture(select(3, GetSpellInfo(FISHING_SPELL)))

local info = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
info:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -BUTTON - 16)
info:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
info:SetJustifyH("LEFT")

local loudCheck = CreateFrame("CheckButton", "CraftPlanFishLoud", panel, "UICheckButtonTemplate")
loudCheck:SetWidth(20)
loudCheck:SetHeight(20)
loudCheck:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 4)
_G["CraftPlanFishLoudText"]:SetText("Громкий всплеск")
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
			tip:AddLine("Ловится в косяках рыбы (щелчок по рыбе в плане покажет их на карте)", 0.4, 0.85, 1, true)
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
end)()

----------------------------------------------------------------------------------------------
-- Просеивание (ювелирное дело). Каждое нажатие — одно просеивание, ничего не делается само.
-- Журнал: какая руда что дала; подсказки к руде и камням; строка «Просеять» в плане;
-- кнопка «Просеять» с числом возможных просеиваний и предупреждением, если руда нужна плану.
;(function()
local PROSPECT_SPELL = 31252 -- Просеивание
local ORES = { 2770, 2771, 2772, 3858, 10620, 23424, 23425, 36909, 36912, 36910 } -- руда, которую можно просеять
local IS_ORE = {}
for _, id in ipairs(ORES) do IS_ORE[id] = true end
local LOOT_WAIT = 5 -- сколько секунд после просеивания ждём окно добычи

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCraftPlan (просеивание):|r " .. msg)
end

-- Журнал — в CraftPlanDB.prospect: [руда] = { n = просеиваний, gems = { [камень] = { c = штук, t = раз выпадал } } };
-- fail[руда] = навык, при котором игра отказала (навыка мало)
local function DB()
	CraftPlanDB = CraftPlanDB or {}
	local p = CraftPlanDB.prospect or {}
	CraftPlanDB.prospect = p
	p.ore = p.ore or {}
	p.fail = p.fail or {}
	return p
end

local function ItemID(link)
	return link and tonumber(link:match("item:(%d+)"))
end

local function JewelRank()
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank = GetSkillLineInfo(i)
		if not isHeader and name == "Ювелирное дело" then return rank end
	end
end

-- Сколько этой руды нужно текущему плану CraftPlan («Сейчас» и «Дальше»)
local function PlanNeed(itemID)
	local need = 0
	local function addRec(rec, times)
		for _, r in ipairs(rec and rec.reagents or {}) do
			if r.id == itemID then need = need + r.count * times end
		end
	end
	for _, e in ipairs(CraftPlan.fullPlan or {}) do addRec(e.rec, e.count) end
	for _, e in ipairs(CraftPlan.cont or {}) do
		if e.rec then addRec(e.rec, e.times or 0) end
		for _, st in ipairs(e.steps or {}) do addRec(st.rec, st.times or 0) end
	end
	return need
end

-- Руда для кнопки: выбранная (правый щелчок) или первая в сумках, которую можно просеять;
-- пропускаем ту, на которой игра отказала при нынешнем навыке
local selectedOre
local function Usable(id)
	local failAt = DB().fail[id]
	return GetItemCount(id) >= 5 and not (failAt and (JewelRank() or 0) <= failAt)
end
local function CurrentOre()
	if selectedOre and Usable(selectedOre) then return selectedOre end
	for _, id in ipairs(ORES) do
		if Usable(id) then return id end
	end
end

-- Ячейка со стопкой руды от 5 штук
local function OreSlot(id)
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			if ItemID(GetContainerItemLink(bag, slot)) == id then
				local _, count = GetContainerItemInfo(bag, slot)
				if (count or 0) >= 5 then return bag, slot end
			end
		end
	end
end

----------------------------------------------------------------------------------------------
-- Кнопка (защищённая: «/cast Просеивание» + «/use сумка ячейка»)
-- стоит на полосе CraftPlan, слева от значка карты крафта (и ездит вместе с полосой)
local frame = CreateFrame("Frame", "CraftPlanProspectFrame", UIParent)
frame:SetWidth(ICON_SIZE)
frame:SetHeight(ICON_SIZE)
frame:SetPoint("RIGHT", mapButton, "LEFT", -ICON_GAP, 0)
frame:SetFrameStrata("MEDIUM")
frame:SetFrameLevel(mapButton:GetFrameLevel())
frame:Hide()

local button = CreateFrame("Button", "CraftPlanProspect", frame, "SecureActionButtonTemplate")
button:SetAllPoints(frame)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:SetAttribute("type1", "macro")
button.icon = button:CreateTexture(nil, "ARTWORK")
button.icon:SetAllPoints(button)
button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
button.warn = button:CreateTexture(nil, "OVERLAY") -- руда нужна плану
button.warn:SetWidth(14)
button.warn:SetHeight(14)
button.warn:SetPoint("TOPRIGHT", button, "TOPRIGHT", 2, 2)
button.warn:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")

local function OreTooltipLines(tip, id)
	local o = DB().ore[id]
	if not o or o.n == 0 then
		tip:AddLine("Просеивание: вы ещё не просеивали эту руду.", 0.6, 0.6, 0.6, true)
		return
	end
	local list = {}
	for gem, g in pairs(o.gems) do list[#list + 1] = { gem, g.c / o.n } end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	tip:AddLine("Просеивание (ваш журнал, " .. o.n .. " раз), в среднем за раз:", 0.4, 0.8, 1)
	for i = 1, math.min(#list, 6) do
		local name = GetItemInfo(list[i][1]) or ("предмет " .. list[i][1])
		tip:AddDoubleLine("  " .. name, string.format("%.2f", list[i][2]), 1, 1, 1, 1, 1, 1)
	end
end

local updateSecure -- задаётся ниже
local clickAt = 0
button:HookScript("OnClick", function(self, mouse) -- левый щелчок делает шаблон (макрос)
	if mouse ~= "RightButton" then clickAt = GetTime() return end
	-- правый щелчок — следующая руда из тех, что есть в сумках
	local cur, list = CurrentOre(), {}
	for _, id in ipairs(ORES) do if Usable(id) then list[#list + 1] = id end end
	if #list == 0 then return end
	local nextIdx = 1
	for i, id in ipairs(list) do if id == cur then nextIdx = i % #list + 1 end end
	selectedOre = list[nextIdx]
	updateSecure()
	self:GetScript("OnEnter")(self)
end)
button:SetScript("OnEnter", function(self)
	local id = CurrentOre()
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:AddLine("Просеять")
	if not id then
		GameTooltip:AddLine("В сумках нет руды для просеивания (нужно от 5 штук).", 1, 1, 1, true)
	else
		local count = GetItemCount(id)
		GameTooltip:AddLine((GetItemInfo(id) or "руда") .. ": " .. count .. " шт. — просеять можно " .. math.floor(count / 5) .. " раз.", 1, 1, 1, true)
		local need = PlanNeed(id)
		if need > 0 then
			GameTooltip:AddLine("Эта руда нужна плану CraftPlan: " .. need .. " шт. Если просеять, плану может не хватить.", 1, 0.4, 0.4, true)
		end
		OreTooltipLines(GameTooltip, id)
	end
	GameTooltip:AddLine("Щелчок — одно просеивание. Правый щелчок — другая руда.", 0.6, 0.8, 1, true)
	GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

local pending = false
updateSecure = function()
	if InCombatLockdown() then pending = true return end
	pending = false
	local spell = GetSpellInfo(PROSPECT_SPELL)
	local known = spell and GetSpellInfo(spell) -- есть в книге заклинаний
	local id = known and CurrentOre()
	local bag, slot
	if id then bag, slot = OreSlot(id) end
	if bag and CraftPlanDB and CraftPlanDB.collapsed then bag = nil end -- полоса свёрнута — кнопка тоже
	if bag then
		button:SetAttribute("macrotext1", "/cast " .. spell .. "\n/use " .. bag .. " " .. slot)
		button.icon:SetTexture(GetItemIcon(id))
		button.count:SetText(math.floor(GetItemCount(id) / 5))
		if PlanNeed(id) > 0 then button.warn:Show() else button.warn:Hide() end
		frame:Show()
	else
		button:SetAttribute("macrotext1", nil)
		frame:Hide()
	end
end
CraftPlan.ProspectUpdate = function() updateSecure() end

----------------------------------------------------------------------------------------------
-- Журнал: перед просеиванием запоминаем количество руды, после — какая убыла и что выпало
local before, castAt = nil, 0
-- clickAt (время щелчка по кнопке) объявлен выше
local function OreCounts()
	local t = {}
	for _, id in ipairs(ORES) do t[id] = GetItemCount(id) end
	return t
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "BAG_UPDATE", "PLAYER_REGEN_ENABLED", "SKILL_LINES_CHANGED", "LEARNED_SPELL_IN_TAB",
	"UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "LOOT_OPENED", "UI_ERROR_MESSAGE" }) do
	events:RegisterEvent(e)
end
local prospectName
events:SetScript("OnEvent", function(_, event, arg1, arg2)
	prospectName = prospectName or GetSpellInfo(PROSPECT_SPELL)
	if event == "PLAYER_LOGIN" then
		updateSecure()
	elseif event == "UNIT_SPELLCAST_SENT" then
		if arg1 == "player" and arg2 == prospectName then before = OreCounts() end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if arg1 == "player" and arg2 == prospectName then castAt = GetTime() end
	elseif event == "UI_ERROR_MESSAGE" then
		-- отказ сразу после щелчка по кнопке со словом «навык»: запоминаем руду как «навыка мало»
		if GetTime() - clickAt < 2 and arg1 and arg1:find("навык") then
			local id = CurrentOre()
			if id then
				DB().fail[id] = JewelRank() or 0
				Print((GetItemInfo(id) or "руда") .. ": игра пишет, что навыка мало, — пока пропускаю её.")
				updateSecure()
			end
		end
	elseif event == "LOOT_OPENED" then
		if not before or GetTime() - castAt > LOOT_WAIT then return end
		local now, ore = OreCounts(), nil
		for id, n in pairs(before) do
			if (now[id] or 0) <= n - 5 then ore = id break end
		end
		before = nil
		if not ore then return end
		local o = DB().ore[ore] or { n = 0, gems = {} }
		DB().ore[ore] = o
		o.n = o.n + 1
		for i = 1, GetNumLootItems() do
			local id = ItemID(GetLootSlotLink(i))
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
local function AddProspectTooltip(tip)
	local _, link = tip:GetItem()
	local id = ItemID(link)
	if not id or tip == GameTooltip and tip:GetOwner() == button then return end
	if IS_ORE[id] then
		if DB().ore[id] then OreTooltipLines(tip, id) tip:Show() end
		return
	end
	local parts = {}
	for ore, o in pairs(DB().ore) do
		local g = o.gems[id]
		if g then parts[#parts + 1] = (GetItemInfo(ore) or ("руда " .. ore)) .. " (" .. g.t .. " из " .. o.n .. ")" end
	end
	if #parts > 0 then
		tip:AddLine("Просеиванием (ваш журнал): " .. table.concat(parts, ", "), 0.4, 0.8, 1, true)
		tip:Show()
	end
end
for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
	tip:HookScript("OnTooltipSetItem", AddProspectTooltip)
end

-- Строка для плана: чем добыть недостающий камень просеиванием (по журналу) или nil
function CraftPlan.ProspectHint(itemID, amount)
	local best, bestAvg
	for ore, o in pairs(DB().ore) do
		local g = o.gems[itemID]
		if g and o.n > 0 then
			local avg = g.c / o.n
			local have = GetItemCount(ore) >= 5
			-- руда в сумках важнее, затем — где камень чаще
			if not best or (have and not best.have) or (have == best.have and avg > bestAvg) then
				best, bestAvg = { ore = ore, have = have }, avg
			end
		end
	end
	if not best then return nil end
	local oreName = GetItemInfo(best.ore) or ("руда " .. best.ore)
	if not best.have then
		return "можно просеять из: " .. oreName .. " (её нет в сумках)", best.ore
	end
	local times = math.min(math.ceil(amount / bestAvg), math.floor(GetItemCount(best.ore) / 5))
	return string.format("Просеять: %s — %d раз (ожидается ~%.1f, по журналу)", oreName, times, times * bestAvg), best.ore
end
end)()

----------------------------------------------------------------------------------------------
-- Торговец, учитель, свитки рецептов: купить материалы для плана, продать изделия прокачки,
-- отметить полезные рецепты у учителя, подсказка к рецепту-предмету. Всё — по вашему нажатию.
;(function()
local NO_SELL_EQUIP = { INVTYPE_BAG = true, INVTYPE_AMMO = true, INVTYPE_QUIVER = true, INVTYPE_RELIC = true, [""] = true }
local MAX_SELL_QUALITY = 2 -- продаём только до зелёных включительно
local MAX_PURCHASES = 50   -- больше покупок за одно нажатие не делаем

local function RankOf(prof)
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank = GetSkillLineInfo(i)
		if not isHeader and name == prof then return rank end
	end
end

-- Сколько чего нужно на весь план («Сейчас» и «Дальше») минус то, что план создаст по пути
local function PlanDeficit()
	local need, made = {}, {}
	local function addRec(rec, times, prof, section)
		if not rec or times <= 0 then return end
		for _, r in ipairs(rec.reagents) do
			if r.id then
				local t = need[r.id] or { r = r, n = 0, uses = {}, order = {} }
				t.n = t.n + r.count * times
				-- для чего: рецепт → сколько штук на него, сколько раз создать, профессия, раздел плана
				local u = t.uses[rec.name]
				if not u then
					u = { rec = rec, prof = prof, section = section, amount = 0, times = 0, per = r.count }
					t.uses[rec.name] = u
					t.order[#t.order + 1] = rec.name
				end
				u.amount = u.amount + r.count * times
				u.times = u.times + times
				need[r.id] = t
			end
		end
		local prod = ItemOf(rec.link)
		if prod then made[prod] = (made[prod] or 0) + (rec.made or 1) * times end
	end
	for _, e in ipairs(CraftPlan.fullPlan or {}) do addRec(e.rec, e.count, e.prof, "сейчас") end
	for _, e in ipairs(CraftPlan.cont or {}) do
		addRec(e.rec, e.times or 0, e.prof, "дальше")
		for _, st in ipairs(e.steps or {}) do addRec(st.rec, st.times or 0, st.prof, "дальше") end
	end
	local deficit, info = {}, {}
	for id, t in pairs(need) do
		local have = TotalCount(t.r)
		local left = t.n - (made[id] or 0) - have
		if left > 0 then
			deficit[id] = left
			info[id] = { need = t.n - (made[id] or 0), have = have, uses = t.uses, order = t.order }
		end
	end
	return deficit, info
end

CraftPlan.PlanDeficit = PlanDeficit

----------------------------------------------------------------------------------------------
-- 1) Торговец: «Купить для плана»
local function BuyList()
	local deficit, info = PlanDeficit()
	local list, total = {}, 0
	for i = 1, GetMerchantNumItems() do
		local id = ItemOf(GetMerchantItemLink(i))
		local left = id and deficit[id]
		if left then
			local name, texture, price, per, available, _, extendedCost = GetMerchantItemInfo(i)
			if price and price > 0 and not extendedCost then
				per = math.max(1, per or 1)
				local buys = math.min(math.ceil(left / per), MAX_PURCHASES)
				if available and available >= 0 then buys = math.min(buys, available) end
				if buys > 0 then
					list[#list + 1] = { index = i, name = name, texture = texture, per = per, buys = buys, count = buys * per, cost = buys * price, info = info[id] }
					total = total + buys * price
				end
			end
		end
	end
	return list, total
end

local buyButton = CreateFrame("Button", "CraftPlanBuyButton", MerchantFrame, "UIPanelButtonTemplate")
buyButton:SetWidth(150)
buyButton:SetHeight(22)
buyButton:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 2, -50) -- справа от окна, не заходя на рамку
buyButton:SetText("Купить для плана")
buyButton:SetScript("OnEnter", function(self)
	local list, total = BuyList()
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Купить для плана CraftPlan")
	if #list == 0 then
		GameTooltip:AddLine("У этого торговца нет ничего, чего не хватает плану.", 1, 1, 1, true)
	else
		for _, b in ipairs(list) do
			GameTooltip:AddDoubleLine("|T" .. (b.texture or "") .. ":16|t " .. b.name .. " x" .. b.count, Money(b.cost), 1, 1, 1, 1, 1, 1)
			local inf = b.info
			if inf then
				GameTooltip:AddLine("    нужно " .. inf.need .. ", есть " .. inf.have .. (b.per > 1 and (", продаётся по " .. b.per) or ""), 0.7, 0.7, 0.7)
				-- по рецепту в строке: значок и цвет рецепта, сколько раз создать и сколько штук уйдёт
				for k, recName in ipairs(inf.order) do
					if k > 6 then
						GameTooltip:AddLine("      и ещё рецептов: " .. (#inf.order - 6), 0.6, 0.6, 0.6)
						break
					end
					local u = inf.uses[recName]
					local c = COLOR[u.rec.kind] or COLOR.trivial
					GameTooltip:AddDoubleLine("      |T" .. (u.rec.icon or "") .. ":14|t " .. recName .. " x" .. u.times,
						u.amount .. " шт. · " .. (u.prof or "?") .. ", " .. u.section, c[1], c[2], c[3], 0.7, 0.7, 0.7)
				end
			end
		end
		GameTooltip:AddDoubleLine("Всего", Money(total), 1, 0.82, 0, 1, 0.82, 0)
		if total > GetMoney() then GameTooltip:AddLine("Не хватает денег — купится, сколько хватит.", 1, 0.3, 0.3, true) end
	end
	GameTooltip:Show()
end)
buyButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
buyButton:SetScript("OnClick", function(self)
	local list = BuyList()
	local spent, bought = 0, 0
	for _, b in ipairs(list) do
		local price = b.cost / b.buys
		for _ = 1, b.buys do
			if GetMoney() - spent < price then break end
			if b.per > 1 then
				BuyMerchantItem(b.index) -- товар продаётся пачками: одна покупка — одна пачка
			else
				BuyMerchantItem(b.index, 1)
			end
			spent, bought = spent + price, bought + b.per
		end
	end
	if bought > 0 then
		Print("куплено для плана: " .. bought .. " шт. за " .. Money(spent) .. ".")
	else
		Print("покупать нечего (или не хватает денег).")
	end
	self:GetScript("OnEnter")(self)
end)

----------------------------------------------------------------------------------------------
-- 2) Торговец: «Продать изделия прокачки» — созданные вами по рецептам вещи для надевания
-- (до зелёных), которые не надеты, не входят в комплекты экипировки и не нужны рецептам
local function SellList()
	local products, reagents = {}, {}
	for profName, p in pairs(DB().profs) do
		for _, rec in ipairs(p.recipes or {}) do
			local prod = ItemOf(rec.link)
			if prod then products[prod] = { prof = profName, kind = rec.kind } end
			for _, r in ipairs(rec.reagents) do if r.id then reagents[r.id] = true end end
		end
	end
	local inSet = {}
	for i = 1, (GetNumEquipmentSets and GetNumEquipmentSets() or 0) do
		local setName = GetEquipmentSetInfo(i)
		for _, id in pairs(setName and GetEquipmentSetItemIDs(setName) or {}) do inSet[id] = true end
	end
	local list, total = {}, 0
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			local id = ItemOf(GetContainerItemLink(bag, slot))
			if id and products[id] and not reagents[id] and not inSet[id] then
				local name, _, quality, _, _, _, _, _, equipLoc, _, sellPrice = GetItemInfo(id)
				local _, count = GetContainerItemInfo(bag, slot)
				if name and quality and quality <= MAX_SELL_QUALITY and sellPrice and sellPrice > 0
					and not NO_SELL_EQUIP[equipLoc or ""] then
					list[#list + 1] = { bag = bag, slot = slot, name = name, quality = quality, count = count or 1, price = sellPrice * (count or 1),
						texture = GetContainerItemInfo(bag, slot), from = products[id] }
					total = total + sellPrice * (count or 1)
				end
			end
		end
	end
	return list, total
end

StaticPopupDialogs["CRAFTPLAN_SELL"] = {
	text = "Продать изделия прокачки: %s шт. за %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		if not MerchantFrame:IsShown() then return end
		local list, total = SellList()
		for _, it in ipairs(list) do UseContainerItem(it.bag, it.slot) end -- у торговца это продажа
		Print("продано изделий: " .. #list .. " за " .. Money(total) .. ".")
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

local sellButton = CreateFrame("Button", "CraftPlanSellButton", MerchantFrame, "UIPanelButtonTemplate")
sellButton:SetWidth(150)
sellButton:SetHeight(22)
sellButton:SetPoint("TOPLEFT", buyButton, "BOTTOMLEFT", 0, -4)
sellButton:SetText("Продать изделия")
sellButton:SetScript("OnEnter", function(self)
	local list, total = SellList()
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Продать изделия прокачки")
	GameTooltip:AddLine("Созданные по вашим рецептам вещи для надевания (до зелёных), которые не надеты, не в комплектах экипировки и не нужны другим рецептам.", 1, 1, 1, true)
	if #list == 0 then
		GameTooltip:AddLine("Продавать нечего.", 0.6, 0.6, 0.6)
	else
		for _, it in ipairs(list) do
			local c = ITEM_QUALITY_COLORS[it.quality] or ITEM_QUALITY_COLORS[1]
			GameTooltip:AddDoubleLine("|T" .. (it.texture or "") .. ":16|t " .. it.name .. (it.count > 1 and (" x" .. it.count) or ""), Money(it.price), c.r, c.g, c.b, 1, 1, 1)
			if it.from then
				GameTooltip:AddLine("    " .. it.from.prof .. ", рецепт сейчас " .. (COLOR_NAME[it.from.kind] or "?"), 0.7, 0.7, 0.7)
			end
		end
		GameTooltip:AddDoubleLine("Всего", Money(total), 1, 0.82, 0, 1, 0.82, 0)
		GameTooltip:AddLine("Щелчок — спросит подтверждение.", 0.6, 0.8, 1)
	end
	GameTooltip:Show()
end)
sellButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
sellButton:SetScript("OnClick", function()
	local list, total = SellList()
	if #list == 0 then Print("продавать нечего.") return end
	StaticPopup_Show("CRAFTPLAN_SELL", #list, Money(total))
end)

----------------------------------------------------------------------------------------------
-- 3) Учитель профессии: у доступных рецептов подпись «+N оранж.» / цвет; рядом — список
-- самых полезных (больше оранжевых созданий), щелчок выбирает рецепт
local TRAINER_TOP = 8
local trainerPanel, trainerLines

local function TrainerProf(i)
	local ok, skill = pcall(GetTrainerServiceSkillLine, i)
	if ok and skill and SKILL_ID[skill] then return skill end
end

-- Польза рецепта у учителя: прирост оранжевых созданий, вид цвета и текст, или nil
local function ServiceValue(i)
	local name, _, serviceType = GetTrainerServiceInfo(i)
	if serviceType ~= "available" then return nil end
	local prof = TrainerProf(i)
	if not prof then return nil end
	local rank = RankOf(prof)
	local y, g = Thresholds(prof, name)
	if not (rank and y) then return nil end
	local kind = KindAt(y, g, rank)
	local gain = (kind == "optimal") and (y - rank) or 0
	return gain, kind, name
end

local function SelectService(i)
	SelectTrainerService(i)
	ClassTrainerFrame.selectedService = i
	ClassTrainer_SetSelection(i)
	ClassTrainerFrame_Update()
end

local function UpdateTrainer()
	if not (ClassTrainerFrame and ClassTrainerFrame:IsShown()) then return end
	if not IsTradeskillTrainer() then
		if trainerPanel then trainerPanel:Hide() end
		return
	end
	-- подписи у видимых строк
	local offset = FauxScrollFrame_GetOffset(ClassTrainerListScrollFrame)
	for i = 1, CLASS_TRAINER_SKILLS_DISPLAYED do
		local sub = _G["ClassTrainerSkill" .. i .. "SubText"]
		local gain, kind = ServiceValue(i + offset)
		if sub and kind then
			local c = COLOR[kind]
			sub:SetText(gain > 0 and ("+" .. gain .. " оранж.") or (COLOR_NAME[kind] or ""))
			sub:SetTextColor(c[1], c[2], c[3])
			sub:ClearAllPoints()
			sub:SetPoint("RIGHT", _G["ClassTrainerSkill" .. i], "RIGHT", -2, 0)
			sub:Show()
		end
	end
	-- список самых полезных
	local all = {}
	for i = 1, GetNumTrainerServices() do
		local gain, kind, name = ServiceValue(i)
		if gain and gain > 0 then all[#all + 1] = { i = i, gain = gain, name = name, cost = GetTrainerServiceCost(i) or 0 } end
	end
	table.sort(all, function(a, b) return a.gain > b.gain end)
	if not trainerPanel then
		trainerPanel = CreateFrame("Frame", "CraftPlanTrainerPanel", ClassTrainerFrame)
		trainerPanel:SetWidth(240)
		trainerPanel:SetPoint("TOPLEFT", ClassTrainerFrame, "TOPRIGHT", -32, -14)
		trainerPanel:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		trainerPanel:SetBackdropColor(0, 0, 0, 0.9)
		trainerPanel.title = trainerPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		trainerPanel.title:SetPoint("TOPLEFT", trainerPanel, "TOPLEFT", 10, -8)
		trainerPanel.title:SetText("CraftPlan: полезнее всего")
		trainerLines = {}
		for k = 1, TRAINER_TOP do
			local b = CreateFrame("Button", nil, trainerPanel)
			b:SetHeight(16)
			b:SetPoint("TOPLEFT", trainerPanel, "TOPLEFT", 10, -10 - k * 17)
			b:SetPoint("RIGHT", trainerPanel, "RIGHT", -10, 0)
			b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			b.text:SetAllPoints(b)
			b.text:SetJustifyH("LEFT")
			b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			b:SetScript("OnClick", function(self) if self.index then SelectService(self.index) end end)
			trainerLines[k] = b
		end
	end
	local shown = math.min(#all, TRAINER_TOP)
	for k = 1, TRAINER_TOP do
		local b, a = trainerLines[k], all[k]
		if a then
			b.index = a.i
			b.text:SetText("|cffff8040+" .. a.gain .. "|r  " .. a.name .. "  |cffaaaaaa" .. Money(a.cost) .. "|r")
			b:Show()
		else
			b.index = nil
			b:Hide()
		end
	end
	if shown == 0 then
		trainerLines[1].text:SetText("|cff999999Новых оранжевых рецептов нет.|r")
		trainerLines[1].index = nil
		trainerLines[1]:Show()
		shown = 1
	end
	trainerPanel:SetHeight(18 + (shown + 1) * 17)
	trainerPanel:Show()
end

local function HookTrainer()
	if ClassTrainerFrame_Update and not CraftPlan.trainerHooked then
		hooksecurefunc("ClassTrainerFrame_Update", UpdateTrainer)
		CraftPlan.trainerHooked = true
	end
end

----------------------------------------------------------------------------------------------
-- 4) Подсказка к рецепту-предмету («Чертеж: …», «Рецепт: …»): изучен ли и каким будет цвет
local function RecipeTooltip(tip)
	local name = tip:GetItem()
	local recName = name and name:match("^[^:]+:%s*(.+)$")
	if not recName or not CraftPlanThresholds then return end
	local prof, y, g
	for profName, id in pairs(SKILL_ID) do
		local t = CraftPlanThresholds[id]
		if t and t[recName] then
			if not prof or RankOf(profName) then prof, y, g = profName, t[recName][1], t[recName][2] end
		end
	end
	if not prof then return end
	local rank = RankOf(prof)
	if not rank then
		tip:AddLine("CraftPlan: у вас нет профессии «" .. prof .. "».", 0.6, 0.6, 0.6, true)
		tip:Show()
		return
	end
	local p = DB().profs[prof]
	local known
	if p and p.scanned then
		known = false
		for _, rec in ipairs(p.recipes) do
			if rec.name == recName then known = true break end
		end
	end
	local kind = KindAt(y, g, rank)
	local c = COLOR[kind]
	local state = (known == true and "|cff40ff40изучен|r") or (known == false and "|cffff4040не изучен|r")
		or "|cffaaaaaaизучен ли — откройте окно профессии|r"
	local colorText = (kind == "optimal") and ("оранжевый ещё " .. (y - rank) .. " раз") or (COLOR_NAME[kind] or "")
	tip:AddLine("CraftPlan: " .. state .. ". При навыке " .. rank .. " — " .. colorText .. " (жёлтый с " .. y .. ", серый с " .. g .. ").", c[1], c[2], c[3], true)
	tip:Show()
end
for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
	tip:HookScript("OnTooltipSetItem", RecipeTooltip)
end

----------------------------------------------------------------------------------------------
local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "ADDON_LOADED", "TRAINER_SHOW", "TRAINER_UPDATE", "MERCHANT_SHOW" }) do
	events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == "Blizzard_TrainerUI" then HookTrainer() end
	elseif event == "PLAYER_LOGIN" then
		HookTrainer()
	elseif event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
		if event == "TRAINER_SHOW" and CraftPlan.RememberTrainer then CraftPlan.RememberTrainer() end
		HookTrainer()
		UpdateTrainer()
	elseif event == "MERCHANT_SHOW" then
		local list = BuyList()
		if #list > 0 then buyButton:Enable() else buyButton:Disable() end
		if #SellList() > 0 then sellButton:Enable() else sellButton:Disable() end
	end
end)
end)()

----------------------------------------------------------------------------------------------
-- Пункт в меню Questie «Торговцы рецептами для CraftPlan»: торговцы, у которых продаются
-- рецепты ваших профессий, которых у вас ещё нет. Какие предметы — рецепты: русское название
-- из базы Questie («Рецепт: копченый шалфокунь») сверяется с таблицей CraftPlanThresholds.
-- База Questie большая — перебираем её один раз за сессию, понемногу за кадр, чтобы не было рывка
;(function()
local KEY = "Торговцы рецептами для CraftPlan"
local ICON = "Interface\\Icons\\INV_Scroll_03"
local PER_FRAME = 1500 -- предметов базы за кадр
local MAX_LINES = 12   -- рецептов в подсказке к торговцу

local function DB()
	CraftPlanDB = CraftPlanDB or {}
	CraftPlanDB.profs = CraftPlanDB.profs or {}
	return CraftPlanDB
end

local SKILL_ID = {
	["Кузнечное дело"] = 164, ["Кожевничество"] = 165, ["Алхимия"] = 171, ["Кулинария"] = 185,
	["Горное дело"] = 186, ["Портняжное дело"] = 197, ["Инженерное дело"] = 202, ["Наложение чар"] = 333,
	["Ювелирное дело"] = 755, ["Начертание"] = 773, ["Первая помощь"] = 129,
}

local function RankOf(prof)
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank = GetSkillLineInfo(i)
		if not isHeader and name == prof then return rank end
	end
end

-- Строчные буквы и «е» вместо «ё»: в базе Questie «Рецепт: копченый шалфокунь»,
-- а в игре «Копченый шалфокунь». string.lower русские буквы не трогает
local function Norm(str)
	str = str:gsub("\208\129", "\208\149"):gsub("\209\145", "\208\181")
	str = str:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end)
	str = str:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end)
	return str:lower()
end

local recipes      -- после перебора: список { item, prof, name }
local scanning
local lastSig

local function Update()
	if not recipes then return end
	if not (Questie and Questie.db and Questie.db.char and Questie.db.char.vendorList and QuestieLoader) then return end
	local Townsfolk = QuestieLoader:ImportModule("Townsfolk")
	local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
	local QuestieMenu = QuestieLoader:ImportModule("QuestieMenu")
	local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
	if not (Townsfolk and Townsfolk.PopulateVendors and QuestieDB) then return end

	-- какие рецепты нужны: профессия есть, рецепт не изучен (если окно профессии открывали)
	local db, want, sigParts = DB(), {}, {}
	local ranks = {}
	for _, r in ipairs(recipes) do
		if ranks[r.prof] == nil then ranks[r.prof] = RankOf(r.prof) or false end
		if ranks[r.prof] then
			local p = db.profs[r.prof]
			local known = false
			if p and p.scanned then
				for _, rec in ipairs(p.recipes) do
					if rec.name == r.name then known = true break end
				end
			end
			if not known then
				want[#want + 1] = r
				sigParts[#sigParts + 1] = r.item
			end
		end
	end
	local sig = table.concat(sigParts, ",")
	if sig == lastSig and Questie.db.char.vendorList[KEY] then return end

	-- торговец -> какие из этих рецептов у него продаются (фракцию проверяет Questie)
	local byNpc, list = {}, {}
	for _, r in ipairs(want) do
		local ok, set = pcall(Townsfolk.PopulateVendors, Townsfolk, { r.item }, {})
		for npc in pairs(ok and set or {}) do -- ошибка в данных одного торговца не ломает весь список
			if not byNpc[npc] then
				byNpc[npc] = {}
				list[#list + 1] = npc
			end
			table.insert(byNpc[npc], r)
		end
	end
	lastSig = sig
	local old = Questie.db.char.vendorList[KEY] or {}
	Questie.db.char.vendorList[KEY] = list
	if QuestieMenu and QuestieMenu.private and QuestieMenu.private.townsfolk_texturemap then
		QuestieMenu.private.townsfolk_texturemap[KEY] = ICON
	end
	-- пункт включён — перерисовать значки; в подсказке — какие рецепты у него есть
	local cfg = Questie.db.profile and Questie.db.profile.townsfolkConfig
	if cfg and cfg[KEY] and QuestieMap and QuestieMap.ShowNPC then
		for _, id in ipairs(old) do QuestieMap:UnloadManualFrames(id, KEY) end
		for _, id in ipairs(list) do
			local name = QuestieDB.QueryNPCSingle(id, "name") or "?"
			local body = {}
			for i, r in ipairs(byNpc[id]) do
				if i > MAX_LINES then
					body[#body + 1] = { "и ещё " .. (#byNpc[id] - MAX_LINES), "" }
					break
				end
				body[#body + 1] = { r.name, r.prof }
			end
			QuestieMap:ShowNPC(id, ICON, 1.2, "|cffffffff" .. name .. "|r", body, true, KEY, true)
		end
	end
end
CraftPlan.UpdateRecipeVendors = Update

-- Перебор базы Questie: имена «Префикс: рецепт», которые есть в таблице порогов
local function StartScan()
	if recipes or scanning or not CraftPlanThresholds then return end
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local ptrs = QuestieDB and QuestieDB.ItemPointers
	if not (ptrs and QuestieDB.QueryItemSingle) then return end
	scanning = true
	local byName = {} -- нормализованное название -> { профессия, название как в игре }
	for prof, id in pairs(SKILL_ID) do
		for name in pairs(CraftPlanThresholds[id] or {}) do byName[Norm(name)] = { prof, name } end
	end
	local found, key = {}, nil
	local f = CreateFrame("Frame")
	f:SetScript("OnUpdate", function(self)
		for _ = 1, PER_FRAME do
			key = next(ptrs, key)
			if not key then
				self:SetScript("OnUpdate", nil)
				recipes, scanning = found, false
				Update()
				return
			end
			local name = QuestieDB.QueryItemSingle(key, "name")
			local pre, rec
			if name then pre, rec = name:match("^([^:]+):%s*(.+)$") end
			local hit = rec and byName[Norm(rec)]
			-- «Формула чар для нагрудника: мана I» — это «Чары для нагрудника - мана I»
			local part = not hit and pre and pre:match("^Формула чар для (.+)$")
			if part then hit = byName[Norm("Чары для " .. part .. " - " .. rec)] end
			if hit then found[#found + 1] = { item = key, prof = hit[1], name = hit[2] } end
		end
	end)
end

-- Questie собирает базу после входа — начинаем чуть позже и повторяем, пока не получится
local waitFrame, waited = CreateFrame("Frame"), 0
waitFrame:SetScript("OnUpdate", function(self, elapsed)
	waited = waited + elapsed
	if waited < 5 then return end
	waited = 0
	StartScan()
	if recipes or scanning then self:SetScript("OnUpdate", nil) end
end)
end)()

-- Пороги цвета рецептов из файлов клиента Sirus (SkillLineAbility.dbc, названия из Spell.dbc).
-- [номер навыка] = { ["название рецепта"] = { жёлтый с навыка, серый с навыка } }.
-- Оранжевый — ниже жёлтого порога, зелёный — с середины между жёлтым и серым, серый — с серого.
-- Рецепты с одинаковым названием и разными порогами не включены (цвет берётся из окна профессии).
CraftPlanThresholds = {
	[164] = {
		["Адамантитовая кираса"] = { 350, 370 },
		["Адамантитовая кувалда"] = { 335, 355 },
		["Адамантитовая оружейная цепь"] = { 345, 355 },
		["Адамантитовая шпага"] = { 345, 365 },
		["Адамантитовое грузило"] = { 350, 360 },
		["Адамантитовое точило"] = { 350, 360 },
		["Адамантитовые латные наручи"] = { 345, 365 },
		["Адамантитовые латные перчатки"] = { 345, 365 },
		["Адамантитовый жезл"] = { 350, 360 },
		["Адамантитовый кинжал"] = { 340, 360 },
		["Адамантитовый колун"] = { 340, 360 },
		["Аннигилятор"] = { 320, 340 },
		["Арканитовая отмычка"] = { 275, 285 },
		["Арканитовый жезл"] = { 275, 285 },
		["Арканитовый жнец"] = { 320, 340 },
		["Арканитовый защитник"] = { 320, 340 },
		["Безмятежность"] = { 310, 335 },
		["Благословенные наручи"] = { 375, 395 },
		["Блистающий стальной кинжал"] = { 205, 230 },
		["Боевой доспех из закаленного кория"] = { 375, 410 },
		["Боевой топор с кромкой Скверны"] = { 375, 395 },
		["Большая черная палица"] = { 255, 280 },
		["Большой бронзовый нож"] = { 135, 165 },
		["Большой меч из оскверненного железа"] = { 330, 350 },
		["Большой меч кровавой расправы"] = { 510, 520 },
		["Большой молот земной кузни"] = { 340, 360 },
		["Большой топор небесной кузни"] = { 340, 360 },
		["Ботфорты кузни погибели"] = { 475, 500 },
		["Бригантина завоевания"] = { 420, 430 },
		["Бритва обезглавливателя"] = { 490, 500 },
		["Бронзовая палица"] = { 140, 170 },
		["Бронзовый боевой молот"] = { 155, 185 },
		["Бронзовый боевой топор"] = { 165, 195 },
		["Бронзовый длинный меч"] = { 160, 190 },
		["Бронзовый короткий меч"] = { 150, 180 },
		["Бронзовый топор"] = { 145, 175 },
		["Булава стража из титановой стали"] = { 450, 470 },
		["Варварская железная кираса"] = { 185, 210 },
		["Варварские железные наплечники"] = { 185, 210 },
		["Варварские железные перчатки"] = { 210, 235 },
		["Варварские железные сапоги"] = { 205, 230 },
		["Варварский железный шлем"] = { 200, 225 },
		["Варварский меч"] = { 500, 510 },
		["Вулканический молот"] = { 315, 340 },
		["Выверенный сюрикен"] = { 390, 400 },
		["Выкованная демоном кираса"] = { 305, 325 },
		["Гибельный край миров"] = { 385, 405 },
		["Гибельный мифриловый клинок"] = { 250, 275 },
		["Глубокий гром"] = { 385, 405 },
		["Гнездо в наручах"] = { 400, 400 },
		["Гнездо в перчатках"] = { 400, 400 },
		["Гниль"] = { 275, 300 },
		["Гнутый обсидиан"] = { 460, 470 },
		["Гром"] = { 360, 380 },
		["Грубое грузило"] = { 15, 55 },
		["Грубое точило"] = { 15, 55 },
		["Грубые бронзовые наплечники"] = { 140, 170 },
		["Грубые бронзовые наручи"] = { 145, 175 },
		["Грубые бронзовые поножи"] = { 145, 175 },
		["Грубые бронзовые сапоги"] = { 125, 155 },
		["Грубый бронзовый панцирь"] = { 145, 175 },
		["Грубый медный жилет"] = { 15, 55 },
		["Грубый шлифовальный камень"] = { 45, 85 },
		["Грузило Скверны"] = { 300, 310 },
		["Деревянная рапира саронитовой справедливости"] = { 415, 425 },
		["Длинный меч из оскверненной стали"] = { 375, 395 },
		["Доспех дикого терна"] = { 290, 310 },
		["Драконий удар"] = { 385, 405 },
		["Драконья Пасть"] = { 385, 405 },
		["Жезл из истинного серебра"] = { 205, 210 },
		["Жезл из оскверненного железа"] = { 300, 310 },
		["Железная скоба"] = { 150, 155 },
		["Железный противовес"] = { 190, 215 },
		["Железный шип для щита"] = { 180, 210 },
		["Жнец из оскверненной стали"] = { 375, 395 },
		["Закаленная Скверной кувалда"] = { 375, 395 },
		["Закаленная ветрами рапира"] = { 340, 360 },
		["Закаленная саронитовая кираса"] = { 405, 415 },
		["Закаленные ветрами поножи"] = { 280, 300 },
		["Закаленные сапоги из титановой стали"] = { 450, 470 },
		["Закаленные саронитовые наплечники"] = { 410, 420 },
		["Закаленные саронитовые наручи"] = { 415, 425 },
		["Закаленные саронитовые ножные латы"] = { 400, 410 },
		["Закаленные саронитовые рукавицы"] = { 420, 430 },
		["Закаленные саронитовые сапоги"] = { 405, 415 },
		["Закаленный бурей топор"] = { 340, 360 },
		["Закаленный бурей хауберк"] = { 340, 360 },
		["Закаленный в лаве боевой молот"] = { 340, 360 },
		["Закаленный железный короткий меч"] = { 185, 210 },
		["Закаленный саронитовый пояс"] = { 400, 410 },
		["Закаленный саронитовый шлем"] = { 410, 420 },
		["Закаленный шлем из титановой стали"] = { 450, 470 },
		["Заточенный кобальтовый колун"] = { 395, 405 },
		["Заточка иссушения разума"] = { 495, 505 },
		["Заточка холодной закалки"] = { 470, 480 },
		["Зачарованная адамантитовая кираса"] = { 370, 390 },
		["Зачарованная ториевая кираса"] = { 320, 340 },
		["Зачарованные адамантитовые поножи"] = { 375, 395 },
		["Зачарованные адамантитовые сапоги"] = { 365, 385 },
		["Зачарованные ториевые клинки"] = { 320, 340 },
		["Зачарованные ториевые поножи"] = { 320, 340 },
		["Зачарованный адамантитовый пояс"] = { 365, 385 },
		["Зачарованный боевой молот"] = { 305, 330 },
		["Зачарованный ториевый шлем"] = { 320, 340 },
		["Защитник Львиного сердца"] = { 385, 405 },
		["Защитник из истинного серебра"] = { 285, 310 },
		["Защитники жизни"] = { 475, 500 },
		["Звездчатый обсидиановый щит"] = { 320, 340 },
		["Зеленые железные наплечники"] = { 185, 210 },
		["Зеленые железные наручи"] = { 190, 215 },
		["Зеленые железные поножи"] = { 180, 205 },
		["Зеленые железные рукавицы"] = { 180, 210 },
		["Зеленые железные сапоги"] = { 175, 205 },
		["Зеленый железный хауберк"] = { 205, 230 },
		["Зеленый железный шлем"] = { 195, 220 },
		["Зернистое грузило"] = { 65, 80 },
		["Зернистое точило"] = { 65, 80 },
		["Зернистый шлифовальный камень"] = { 75, 100 },
		["Золотая отмычка"] = { 150, 170 },
		["Золотой жезл"] = { 155, 160 },
		["Золотой чешуйчатый капюшон"] = { 215, 240 },
		["Золотой чешуйчатый панцирь"] = { 220, 245 },
		["Золотые чешуйчатые наплечники"] = { 200, 225 },
		["Золотые чешуйчатые наручи"] = { 210, 235 },
		["Золотые чешуйчатые поножи"] = { 195, 220 },
		["Золотые чешуйчатые рукавицы"] = { 225, 245 },
		["Золотые чешуйчатые сапоги"] = { 225, 250 },
		["Зубчатая кобальтовая секира"] = { 395, 405 },
		["Зубчатые смертеносы"] = { 455, 475 },
		["Извечная поясная пряжка"] = { 420, 430 },
		["Изысканная кираса из закаленного колчедана"] = { 505, 515 },
		["Изысканная кираса из закаленного обсидиана"] = { 480, 490 },
		["Изысканная мифриловая кираса"] = { 260, 280 },
		["Изысканное саронитовое наплечье"] = { 430, 450 },
		["Изысканное саронитовое наплечье претендента"] = { 470, 490 },
		["Изысканные ботинки из закаленного колчедана"] = { 495, 505 },
		["Изысканные ботинки из закаленного обсидиана"] = { 470, 480 },
		["Изысканные мифриловые перчатки"] = { 240, 260 },
		["Изысканные мифриловые сапоги"] = { 265, 285 },
		["Изысканные мифриловые штаны"] = { 240, 260 },
		["Изысканные набедренники из закаленного колчедана"] = { 510, 520 },
		["Изысканные набедренники из закаленного обсидиана"] = { 485, 495 },
		["Изысканные наплечники из закаленного колчедана"] = { 515, 525 },
		["Изысканные наплечники из закаленного обсидиана"] = { 490, 500 },
		["Изысканные наручи из закаленного колчедана"] = { 505, 515 },
		["Изысканные наручи из закаленного обсидиана"] = { 480, 490 },
		["Изысканные рукавицы из закаленного колчедана"] = { 495, 505 },
		["Изысканные рукавицы из закаленного обсидиана"] = { 470, 480 },
		["Изысканные саронитовые наручи"] = { 425, 435 },
		["Изысканные саронитовые наручи претендента"] = { 470, 490 },
		["Изысканные саронитовые ножные латы"] = { 435, 455 },
		["Изысканные саронитовые ножные латы претендента"] = { 470, 490 },
		["Изысканные саронитовые рукавицы"] = { 430, 450 },
		["Изысканные саронитовые рукавицы претендента"] = { 470, 490 },
		["Изысканные саронитовые сапоги"] = { 430, 450 },
		["Изысканные саронитовые сапоги претендента"] = { 470, 490 },
		["Изысканный мифриловый наплечник"] = { 245, 265 },
		["Изысканный мифриловый шлем"] = { 265, 285 },
		["Изысканный пояс из закаленного колчедана"] = { 510, 520 },
		["Изысканный пояс из закаленного обсидиана"] = { 485, 495 },
		["Изысканный саронитовый воинский пояс"] = { 430, 450 },
		["Изысканный саронитовый воинский пояс претендента"] = { 470, 490 },
		["Изысканный саронитовый хауберк"] = { 435, 455 },
		["Изысканный саронитовый хауберк претендента"] = { 470, 490 },
		["Изысканный саронитовый шлем"] = { 435, 455 },
		["Изысканный саронитовый шлем претендента"] = { 470, 490 },
		["Изысканный ториевый одноручный топор"] = { 300, 325 },
		["Изысканный шлем из закаленного колчедана"] = { 500, 510 },
		["Изысканный шлем из закаленного обсидиана"] = { 475, 485 },
		["Императорские латные наплечники"] = { 285, 305 },
		["Императорские латные наручи"] = { 290, 310 },
		["Императорские латные поножи"] = { 320, 340 },
		["Императорские латные сапоги"] = { 315, 335 },
		["Императорский латный пояс"] = { 285, 305 },
		["Императорский латный шлем"] = { 315, 335 },
		["Имперское зерцало"] = { 320, 340 },
		["Инкрустированный мифриловый цилиндр"] = { 225, 250 },
		["Инкрустированный ториевый молот"] = { 295, 320 },
		["Испытующий топор"] = { 515, 525 },
		["Кинжал с жемчужной рукояткой"] = { 140, 170 },
		["Кираса Белого Рыцаря"] = { 460, 475 },
		["Кираса Королей"] = { 360, 380 },
		["Кираса Кузни Солнца"] = { 460, 475 },
		["Кираса Мира"] = { 380, 400 },
		["Кираса Солнечного благословения"] = { 375, 410 },
		["Кираса дикого стража"] = { 385, 405 },
		["Кираса железной лозы"] = { 320, 340 },
		["Кираса из истинного серебра"] = { 265, 285 },
		["Кираса из оскверненного железа"] = { 335, 355 },
		["Кираса из яростной стали"] = { 380, 400 },
		["Кираса кровавого духа"] = { 320, 340 },
		["Кираса ледяного стража"] = { 385, 405 },
		["Кираса ледяной погибели"] = { 320, 340 },
		["Кираса огненной гибели"] = { 375, 395 },
		["Кираса темного духа"] = { 320, 340 },
		["Клинок Львиного сердца"] = { 360, 380 },
		["Клинок ледяного тигра"] = { 225, 250 },
		["Клинок мудреца"] = { 320, 340 },
		["Кобальтовая отмычка"] = { 360, 370 },
		["Кобальтовые наплечники"] = { 370, 380 },
		["Кобальтовые наручи"] = { 370, 380 },
		["Кобальтовые ножные латы"] = { 375, 385 },
		["Кобальтовые рукавицы"] = { 380, 390 },
		["Кобальтовые сапоги"] = { 360, 380 },
		["Кобальтовый нагрудник"] = { 380, 390 },
		["Кобальтовый пояс"] = { 360, 380 },
		["Кобальтовый тесак свирепости"] = { 400, 410 },
		["Кобальтовый треугольный щит"] = { 370, 380 },
		["Кобальтовый шлем"] = { 375, 385 },
		["Кобальтодробитель"] = { 385, 395 },
		["Кованый кобальтовый клеймор"] = { 390, 400 },
		["Колчедановая цепь для оружия"] = { 460, 480 },
		["Колчедановые пластины"] = { 515, 525 },
		["Колчедановый шип для щита"] = { 460, 480 },
		["Колчедановый щит рассвета"] = { 510, 515 },
		["Колчедановый щит сумерек"] = { 505, 515 },
		["Кольчуга из черного железа"] = { 290, 310 },
		["Копье удлинившихся теней"] = { 495, 505 },
		["Кориевые сапоги"] = { 375, 395 },
		["Кориевые штаны"] = { 370, 390 },
		["Кориевый защитник"] = { 375, 395 },
		["Кориевый пояс"] = { 370, 390 },
		["Костекрушитель из титановой стали"] = { 450, 470 },
		["Костомолы леденящего ада"] = { 475, 500 },
		["Красный пояс битвы"] = { 385, 405 },
		["Кровавая луна"] = { 385, 405 },
		["Кровавый коготь"] = { 325, 350 },
		["Кромка Зимы"] = { 215, 240 },
		["Крутящиеся стальные топоры"] = { 220, 240 },
		["Кулачные перчатки из закаленного кория"] = { 375, 410 },
		["Латные набедренники из оскверненного железа"] = { 325, 345 },
		["Латные перчатки из оскверненного железа"] = { 310, 330 },
		["Латные сапоги военачальника"] = { 455, 475 },
		["Латные сапоги из оскверненного железа"] = { 325, 345 },
		["Латные сапоги кузнеца света"] = { 475, 500 },
		["Латный пояс из оскверненного железа"] = { 315, 335 },
		["Латный ремень правоты"] = { 455, 475 },
		["Латы из черного железа"] = { 305, 325 },
		["Легкий клинок земной кузни"] = { 280, 300 },
		["Легкий обсидиановый пояс"] = { 320, 340 },
		["Легкий топор небесной кузни"] = { 280, 300 },
		["Легкий углекованный молот"] = { 280, 300 },
		["Ледяной страж"] = { 320, 340 },
		["Лезвие Рассвета"] = { 300, 325 },
		["Ломатель"] = { 260, 285 },
		["Лунный Серп"] = { 360, 380 },
		["Лунный колун"] = { 385, 405 },
		["Массивное грузило"] = { 255, 260 },
		["Массивное точило"] = { 255, 260 },
		["Массивный железный топор"] = { 210, 235 },
		["Массивный шлифовальный камень"] = { 255, 260 },
		["Медная палица"] = { 55, 95 },
		["Медные наручи"] = { 20, 60 },
		["Медные плетеные сапоги"] = { 60, 100 },
		["Медные плетеные штаны"] = { 50, 90 },
		["Медный боевой топор"] = { 75, 115 },
		["Медный кинжал"] = { 70, 110 },
		["Медный клеймор"] = { 70, 110 },
		["Медный короткий меч"] = { 65, 105 },
		["Медный плетеный нагрудник"] = { 75, 115 },
		["Медный плетеный пояс"] = { 75, 115 },
		["Медный топор"] = { 60, 100 },
		["Мифриловые чешуйчатые наплечники"] = { 255, 275 },
		["Мифриловые чешуйчатые наручи"] = { 235, 255 },
		["Мифриловые чешуйчатые перчатки"] = { 240, 260 },
		["Мифриловые чешуйчатые штаны"] = { 230, 250 },
		["Мифриловые шпоры"] = { 255, 275 },
		["Мифриловый капюшон"] = { 250, 270 },
		["Мифриловый шип для щита"] = { 235, 255 },
		["Молот Драконьей длани"] = { 360, 380 },
		["Молот бури искусной работы"] = { 320, 340 },
		["Молот из оскверненного железа"] = { 325, 345 },
		["Молот праведной мощи"] = { 375, 395 },
		["Молот титанов"] = { 320, 340 },
		["Мрачнолесская секира"] = { 295, 320 },
		["Наголенники праведности"] = { 435, 455 },
		["Нагрудный доспех ледяной погибели"] = { 435, 455 },
		["Наплечники Вестника Рассвета"] = { 310, 330 },
		["Наплечники из быстростали"] = { 385, 405 },
		["Наплечники из черного железа"] = { 300, 320 },
		["Наплечники из яростной стали"] = { 375, 395 },
		["Наплечники кровавого духа"] = { 320, 340 },
		["Наплечники рассветной стали"] = { 385, 405 },
		["Наплечники темного духа"] = { 320, 340 },
		["Наручи Кузни Солнца"] = { 460, 475 },
		["Наручи зеленой крепости"] = { 375, 395 },
		["Наручи из быстростали"] = { 385, 405 },
		["Наручи из черного железа"] = { 315, 335 },
		["Наручи ледяной погибели"] = { 320, 340 },
		["Наручи огненной гибели"] = { 360, 380 },
		["Наручи рассветной стали"] = { 385, 405 },
		["Наручники отмщения"] = { 425, 435 },
		["Несокрушимый латный ремень"] = { 455, 475 },
		["Неуязвимый доспех"] = { 320, 340 },
		["Нефритовый змеиный клинок"] = { 200, 225 },
		["Нити судьбы"] = { 455, 475 },
		["Ножные латы завоевания"] = { 420, 430 },
		["Ножные латы из чистой стали"] = { 475, 500 },
		["Ножные латы мучительной смерти"] = { 475, 500 },
		["Облачение Круговерти Пустоты"] = { 385, 405 },
		["Обсидиановая отмычка"] = { 475, 485 },
		["Обсидиановая цепь для оружия"] = { 505, 515 },
		["Обсидиановое грузило"] = { 520, 530 },
		["Обсидиановое точило"] = { 520, 530 },
		["Обсидиановый бердыш"] = { 470, 480 },
		["Обсидиановый кольчужный мундир"] = { 320, 340 },
		["Обсидиановый палач"] = { 485, 495 },
		["Обсидиановый шип для щита"] = { 505, 515 },
		["Огненные латные рукавицы"] = { 310, 330 },
		["Огненный страж"] = { 360, 380 },
		["Огромный ториевый боевой топор"] = { 305, 330 },
		["Окованный камнем клеймор"] = { 340, 360 },
		["Оплот древних королей"] = { 385, 405 },
		["Оплот королей"] = { 385, 405 },
		["Орочьи боевые поножи"] = { 250, 270 },
		["Осадный щит из титановой стали"] = { 450, 470 },
		["Ослепительная мифриловая рапира"] = { 265, 290 },
		["Отмычка из истинного серебра"] = { 200, 220 },
		["Палач Львиного сердца"] = { 385, 405 },
		["Палаш лунной стали"] = { 205, 230 },
		["Перчатки железной лозы"] = { 320, 340 },
		["Перчатки из быстростали"] = { 380, 400 },
		["Перчатки из оскверненной стали"] = { 370, 390 },
		["Перчатки из яростной стали"] = { 375, 395 },
		["Перчатки огненной гибели"] = { 370, 390 },
		["Перчатки рассвета"] = { 320, 340 },
		["Пламенные плетеные наплечники"] = { 320, 340 },
		["Пламенный плетеный ремень"] = { 315, 335 },
		["Плетеная рубашка Круговерти Пустоты"] = { 385, 405 },
		["Плетеная рубашка Пустоты"] = { 360, 380 },
		["Плетеные наручи из оскверненного железа"] = { 325, 345 },
		["Плетеные перчатки из оскверненного железа"] = { 320, 340 },
		["Плетеный капюшон из оскверненного железа"] = { 310, 330 },
		["Плетеный мундир из оскверненного железа"] = { 330, 350 },
		["Плоскостная кромка"] = { 360, 380 },
		["Поводья разрушителя-железнонога"] = { 535, 545 },
		["Погребальный Плач"] = { 375, 395 },
		["Позолоченный железный разрушитель"] = { 195, 220 },
		["Полированные стальные сапоги"] = { 210, 235 },
		["Поножи дикого стража"] = { 385, 405 },
		["Поножи земной кузни"] = { 280, 300 },
		["Поножи из оскверненной стали"] = { 370, 390 },
		["Поножи из черного железа"] = { 320, 340 },
		["Поножи ледяного стража"] = { 385, 405 },
		["Поножи темного духа"] = { 320, 340 },
		["Поножи титанов"] = { 320, 340 },
		["Порча"] = { 315, 340 },
		["Посеребренная бронзовая кираса"] = { 160, 190 },
		["Посеребренные бронзовые наплечники"] = { 155, 185 },
		["Посеребренные бронзовые поножи"] = { 180, 205 },
		["Посеребренные бронзовые рукавицы"] = { 165, 195 },
		["Посеребренные бронзовые сапоги"] = { 160, 190 },
		["Пояс железной лозы"] = { 320, 340 },
		["Пояс титанов"] = { 455, 475 },
		["Пояс хранителя"] = { 385, 405 },
		["Призрачный осколок"] = { 485, 495 },
		["Призрачный осколок искусной работы"] = { 510, 520 },
		["Пронзатель из титановой стали"] = { 450, 470 },
		["Пронзатель сердец"] = { 320, 340 },
		["Проржавевшее саронитовое лезвие"] = { 420, 430 },
		["Проржавевший саронитовый изранитель"] = { 420, 430 },
		["Простая охранная руна"] = { 325, 335 },
		["Простой оберег"] = { 340, 350 },
		["Прочная железная кувалда"] = { 180, 205 },
		["Прочный кобальтовый быстрый клинок"] = { 385, 395 },
		["Прочный меч"] = { 475, 485 },
		["Пылающая рапира"] = { 305, 330 },
		["Пылающий золотой клинок"] = { 215, 240 },
		["Пылкий страж"] = { 385, 405 },
		["Пылкое неистовство"] = { 385, 405 },
		["Радужный молот"] = { 170, 200 },
		["Разоритель из черного железа"] = { 320, 340 },
		["Разрушитель из титановой стали"] = { 450, 470 },
		["Разрушитель из черного железа"] = { 320, 340 },
		["Распылитель из черного железа"] = { 285, 305 },
		["Рассекатель из черного железа"] = { 295, 315 },
		["Ремень ледяной погибели"] = { 430, 450 },
		["Ремень рассвета"] = { 310, 330 },
		["Рогатый кобальтовый шлем"] = { 405, 415 },
		["Рука Вечности"] = { 375, 395 },
		["Рукавицы Бури"] = { 315, 335 },
		["Рукавицы Железной башни"] = { 375, 395 },
		["Рукавицы Солнечного благословения"] = { 375, 410 },
		["Рукавицы из истинного серебра"] = { 245, 265 },
		["Рукавицы из черного железа"] = { 320, 340 },
		["Рукавицы кровавого духа"] = { 320, 340 },
		["Рукавицы ледяной погибели"] = { 320, 340 },
		["Рукавицы праведности"] = { 430, 450 },
		["Рукавицы стальной хватки"] = { 375, 395 },
		["Рукавицы цитадели"] = { 320, 340 },
		["Рукавицы ярости Скверны"] = { 375, 395 },
		["Руническая кираса"] = { 320, 340 },
		["Руническая медная кираса"] = { 120, 160 },
		["Рунические латные наплечники"] = { 320, 340 },
		["Рунические латные поножи"] = { 320, 340 },
		["Рунические латные сапоги"] = { 320, 340 },
		["Рунические медные наручи"] = { 115, 140 },
		["Рунические медные рукавицы"] = { 80, 120 },
		["Рунические медные штаны"] = { 85, 125 },
		["Рунический латный шлем"] = { 320, 340 },
		["Рунический медный пояс"] = { 110, 150 },
		["Рунический мифриловый молот"] = { 270, 295 },
		["Рунический молот"] = { 375, 395 },
		["Руническое лезвие"] = { 310, 335 },
		["Сапоги защитника"] = { 385, 405 },
		["Сапоги из черного железа"] = { 320, 340 },
		["Сапоги королевского бунта"] = { 475, 500 },
		["Сапоги красного хаоса"] = { 385, 405 },
		["Сапоги ледяной погибели"] = { 430, 450 },
		["Саронитовая ударная палица ярости"] = { 415, 425 },
		["Саронитовое наплечье свирепости"] = { 430, 450 },
		["Саронитовое наплечье свирепости претендента"] = { 470, 490 },
		["Саронитовые мечеломы"] = { 460, 475 },
		["Саронитовые наручи свирепости"] = { 425, 435 },
		["Саронитовые наручи свирепости претендента"] = { 470, 490 },
		["Саронитовые ножные латы свирепости"] = { 435, 455 },
		["Саронитовые ножные латы свирепости претендента"] = { 470, 490 },
		["Саронитовые рукавицы свирепости"] = { 430, 450 },
		["Саронитовые рукавицы свирепости претендента"] = { 470, 490 },
		["Саронитовые сапоги свирепости"] = { 430, 450 },
		["Саронитовые сапоги свирепости претендента"] = { 470, 490 },
		["Саронитовый воинский пояс свирепости"] = { 430, 450 },
		["Саронитовый воинский пояс свирепости претендента"] = { 470, 490 },
		["Саронитовый защитник"] = { 395, 405 },
		["Саронитовый мозголом"] = { 420, 430 },
		["Саронитовый нож"] = { 410, 420 },
		["Саронитовый оплот"] = { 415, 425 },
		["Саронитовый разбойничий кинжал"] = { 405, 415 },
		["Саронитовый страж"] = { 395, 405 },
		["Саронитовый хауберк свирепости"] = { 435, 455 },
		["Саронитовый хауберк свирепости претендента"] = { 470, 490 },
		["Саронитовый чародейский клинок"] = { 415, 425 },
		["Саронитовый шлем свирепости"] = { 435, 455 },
		["Саронитовый шлем свирепости претендента"] = { 470, 490 },
		["Сверкающая саронитовая кираса"] = { 420, 430 },
		["Сверкающее саронитовое наплечье"] = { 410, 420 },
		["Сверкающие сапоги из титановой стали"] = { 450, 470 },
		["Сверкающие саронитовые наручи"] = { 405, 415 },
		["Сверкающие саронитовые ножные латы"] = { 400, 410 },
		["Сверкающие саронитовые рукавицы"] = { 405, 415 },
		["Сверкающие саронитовые сапоги"] = { 410, 420 },
		["Сверкающий саронитовый пояс"] = { 400, 410 },
		["Сверкающий саронитовый шлем"] = { 420, 430 },
		["Сверкающий шлем из титановой стали"] = { 450, 470 },
		["Светозарная кираса"] = { 290, 310 },
		["Светозарные перчатки"] = { 305, 325 },
		["Светозарные поножи"] = { 320, 340 },
		["Светозарные сапоги"] = { 310, 330 },
		["Светозарный венец"] = { 315, 335 },
		["Светозарный пояс"] = { 280, 300 },
		["Секира из оскверненного железа"] = { 320, 340 },
		["Серебряная отмычка"] = { 100, 120 },
		["Серебряный жезл"] = { 105, 110 },
		["Серповидная секира тени"] = { 225, 250 },
		["Сильная охранная руна"] = { 350, 360 },
		["Сильный оберег"] = { 375, 375 },
		["Синий блистающий топор"] = { 245, 270 },
		["Сияющая серебряная кираса"] = { 175, 205 },
		["Смертоносный бронзовый короткий кинжал"] = { 155, 185 },
		["Смертоносный саронитовый кортик"] = { 415, 425 },
		["Стальгорнская кираса"] = { 140, 180 },
		["Стальгорнская кольчуга"] = { 110, 150 },
		["Стальгорнские рукавицы"] = { 170, 200 },
		["Стальная кираса"] = { 225, 250 },
		["Стальная цепь для оружия"] = { 215, 240 },
		["Стальной латный шлем"] = { 235, 255 },
		["Столпы мощи"] = { 475, 500 },
		["Сульфуронский молот"] = { 325, 350 },
		["Сумерки"] = { 320, 340 },
		["Твердое грузило"] = { 200, 210 },
		["Твердое точило"] = { 200, 210 },
		["Твердый шлифовальный камень"] = { 200, 210 },
		["Темноруническая кираса"] = { 320, 340 },
		["Темнорунические рукавицы"] = { 320, 340 },
		["Темнорунический шлем"] = { 320, 340 },
		["Тенестальной ремень"] = { 385, 405 },
		["Тенестальные наголенники"] = { 385, 405 },
		["Тенестальные наручи"] = { 385, 405 },
		["Тенестальные сабо"] = { 385, 405 },
		["Титановая обшивка"] = { 455, 465 },
		["Титановая отмычка"] = { 435, 445 },
		["Титановая цепь для оружия"] = { 425, 435 },
		["Титановые нагрудные пластины"] = { 460, 475 },
		["Титановые шипованные наручи"] = { 460, 475 },
		["Титановый жезл"] = { 425, 435 },
		["Титановый шип для щита"] = { 425, 435 },
		["Толстая обсидиановая кираса"] = { 320, 340 },
		["Ториевая броня"] = { 270, 290 },
		["Ториевые наручи"] = { 275, 295 },
		["Ториевые поножи"] = { 320, 340 },
		["Ториевые сапоги"] = { 300, 320 },
		["Ториевый большой меч"] = { 285, 310 },
		["Ториевый пояс"] = { 270, 290 },
		["Ториевый шип для щита"] = { 295, 315 },
		["Ториевый шлем"] = { 300, 320 },
		["Точило Скверны"] = { 300, 310 },
		["Точило стихий"] = { 300, 320 },
		["Тяжелая бронзовая палица"] = { 160, 190 },
		["Тяжелая броня земной кузни"] = { 340, 360 },
		["Тяжелая медная кувалда"] = { 105, 145 },
		["Тяжелая мифриловая кираса"] = { 250, 270 },
		["Тяжелое грузило"] = { 125, 140 },
		["Тяжелое точило"] = { 125, 140 },
		["Тяжелые мифриловые латные рукавицы"] = { 225, 245 },
		["Тяжелые мифриловые сапоги"] = { 255, 275 },
		["Тяжелые мифриловые штаны"] = { 230, 250 },
		["Тяжелые сапоги Древобрюхов"] = { 320, 340 },
		["Тяжелый железный молот"] = { 175, 205 },
		["Тяжелый медный длинный меч"] = { 75, 115 },
		["Тяжелый медный палаш"] = { 135, 175 },
		["Тяжелый мифриловый наплечник"] = { 225, 245 },
		["Тяжелый мифриловый топор"] = { 235, 260 },
		["Тяжелый мифриловый шлем"] = { 255, 275 },
		["Тяжелый обсидиановый пояс"] = { 320, 340 },
		["Тяжелый пояс Древобрюхов"] = { 310, 330 },
		["Тяжелый шлифовальный камень"] = { 125, 150 },
		["Увещеватель"] = { 320, 340 },
		["Украшенные медные рукавицы"] = { 100, 140 },
		["Украшенные узором бронзовые наручи"] = { 150, 180 },
		["Укрепленная кираса из закаленного колчедана"] = { 505, 515 },
		["Укрепленная кираса из закаленного обсидиана"] = { 480, 490 },
		["Укрепленные ботинки из закаленного колчедана"] = { 495, 505 },
		["Укрепленные ботинки из закаленного обсидиана"] = { 470, 480 },
		["Укрепленные набедренники из закаленного колчедана"] = { 510, 520 },
		["Укрепленные набедренники из закаленного обсидиана"] = { 485, 495 },
		["Укрепленные наплечники из закаленного колчедана"] = { 515, 525 },
		["Укрепленные наплечники из закаленного обсидиана"] = { 490, 500 },
		["Укрепленные наручи из закаленного колчедана"] = { 505, 515 },
		["Укрепленные наручи из закаленного обсидиана"] = { 480, 490 },
		["Укрепленные рукавицы из закаленного колчедана"] = { 495, 505 },
		["Укрепленные рукавицы из закаленного обсидиана"] = { 470, 480 },
		["Укрепленный пояс из закаленного колчедана"] = { 510, 520 },
		["Укрепленный пояс из закаленного обсидиана"] = { 485, 495 },
		["Укрепленный шлем из закаленного колчедана"] = { 500, 510 },
		["Укрепленный шлем из закаленного обсидиана"] = { 475, 485 },
		["Усиленные кобальтовые наплечники"] = { 395, 405 },
		["Усиленные кобальтовые ножные латы"] = { 410, 420 },
		["Усиленный кобальтовый нагрудник"] = { 415, 425 },
		["Усиленный кобальтовый шлем"] = { 405, 415 },
		["Устрашающие боевые рукавицы"] = { 430, 450 },
		["Устрашающие ножные латы"] = { 435, 455 },
		["Утолщенная секира"] = { 110, 150 },
		["Утолщенные бронзовые дротики"] = { 130, 160 },
		["Утраченные сапоги ремесленника"] = { 475, 500 },
		["Факел очищения"] = { 480, 490 },
		["Фантомный клинок"] = { 270, 295 },
		["Чародейский клинок из титановой стали"] = { 450, 470 },
		["Черная плоскостная кромка"] = { 385, 405 },
		["Черное копье"] = { 325, 350 },
		["Черное неистовство"] = { 320, 340 },
		["Черное прощение"] = { 320, 340 },
		["Черные наручи из оскверненной стали"] = { 375, 395 },
		["Черный Страж"] = { 320, 340 },
		["Черный напоясник разрушителя"] = { 320, 340 },
		["Шепчущие ножи из оскверненной стали"] = { 360, 380 },
		["Шип для щита из оскверненной стали"] = { 370, 390 },
		["Шипастая кираса из закаленного колчедана"] = { 505, 515 },
		["Шипастая кираса из закаленного обсидиана"] = { 480, 490 },
		["Шипастые ботинки из закаленного колчедана"] = { 495, 505 },
		["Шипастые ботинки из закаленного обсидиана"] = { 470, 480 },
		["Шипастые кобальтовые наплечники"] = { 390, 400 },
		["Шипастые кобальтовые наручи"] = { 405, 415 },
		["Шипастые кобальтовые ножные латы"] = { 400, 410 },
		["Шипастые кобальтовые рукавицы"] = { 395, 405 },
		["Шипастые кобальтовые сапоги"] = { 385, 395 },
		["Шипастые набедренники из закаленного колчедана"] = { 510, 520 },
		["Шипастые набедренники из закаленного обсидиана"] = { 485, 495 },
		["Шипастые наплечники из закаленного колчедана"] = { 515, 525 },
		["Шипастые наплечники из закаленного обсидиана"] = { 490, 500 },
		["Шипастые наручи из закаленного колчедана"] = { 505, 515 },
		["Шипастые наручи из закаленного обсидиана"] = { 480, 490 },
		["Шипастые рукавицы из закаленного колчедана"] = { 495, 505 },
		["Шипастые рукавицы из закаленного обсидиана"] = { 470, 480 },
		["Шипастые сапоги из титановой стали"] = { 450, 470 },
		["Шипастый кобальтовый нагрудник"] = { 390, 400 },
		["Шипастый кобальтовый пояс"] = { 400, 410 },
		["Шипастый кобальтовый шлем"] = { 380, 390 },
		["Шипастый пояс из закаленного колчедана"] = { 510, 520 },
		["Шипастый пояс из закаленного обсидиана"] = { 485, 495 },
		["Шипастый шлем из закаленного колчедана"] = { 500, 510 },
		["Шипастый шлем из закаленного обсидиана"] = { 475, 485 },
		["Шипастый шлем из титановой стали"] = { 450, 470 },
		["Шлем Львиного Сердца"] = { 320, 340 },
		["Шлем бури"] = { 375, 395 },
		["Шлем великого вождя"] = { 320, 340 },
		["Шлем властности"] = { 435, 455 },
		["Шлем дикого стража"] = { 385, 405 },
		["Шлем из оскверненной стали"] = { 375, 395 },
		["Шлем из черного железа"] = { 320, 340 },
		["Шлем из яростной стали"] = { 375, 395 },
		["Шлем ледяного стража"] = { 385, 405 },
		["Шлем огненной гибели"] = { 365, 385 },
		["Шлем стойкого защитника"] = { 375, 395 },
		["Шлем хранителя клятвы"] = { 375, 395 },
		["Шлем чистой души"] = { 320, 340 },
		["Штормовестник"] = { 385, 405 },
		["Эбеновая рука"] = { 320, 340 },
		["Эбеновый нож"] = { 280, 305 },
		["Элементиевая цепь для оружия"] = { 515, 525 },
		["Элементиевое грузило"] = { 520, 530 },
		["Элементиевое точило"] = { 520, 530 },
		["Элементиевые пластины"] = { 505, 515 },
		["Элементиевый шип для щита"] = { 515, 525 },
		["Элементиевый щит рассвета"] = { 475, 485 },
		["Элементиевый щит сумерек"] = { 485, 495 },
		["Этерниевый жезл"] = { 365, 375 },
		["Этерниевый рунический клинок"] = { 375, 395 },
		["Яунгольский факел"] = { 505, 515 },
	},
	[165] = {
		["Арктические накулачники"] = { 400, 420 },
		["Арктические наплечные пластины"] = { 395, 415 },
		["Арктические перчатки"] = { 390, 410 },
		["Арктические поножи"] = { 390, 410 },
		["Арктические сапоги"] = { 385, 405 },
		["Арктический нагрудник"] = { 385, 405 },
		["Арктический пояс"] = { 395, 415 },
		["Арктический шлем"] = { 400, 420 },
		["Барабаны битвы"] = { 365, 380 },
		["Барабаны войны"] = { 340, 355 },
		["Барабаны восстановления"] = { 350, 365 },
		["Барабаны дикой природы"] = { 440, 470 },
		["Барабаны забытых королей"] = { 440, 470 },
		["Барабаны неистовства"] = { 515, 525 },
		["Барабаны паники"] = { 370, 385 },
		["Барабаны скорости"] = { 345, 360 },
		["Белый кожаный жакет"] = { 90, 120 },
		["Благословенные кенарийские сапоги"] = { 475, 500 },
		["Боевые наручи лунной тени"] = { 460, 475 },
		["Большая вудуистская маска"] = { 240, 260 },
		["Большие вудуистские штаны"] = { 260, 280 },
		["Большое вудуистское одеяние"] = { 235, 255 },
		["Большой вудуистский плащ"] = { 260, 280 },
		["Борейская кожа"] = { 350, 375 },
		["Ботфорты загробника"] = { 450, 460 },
		["Ботфорты потрошителя"] = { 430, 440 },
		["Ботфорты претендента"] = { 470, 490 },
		["Бриджи одичавшей природы"] = { 475, 500 },
		["Броня из зеленого дракончика"] = { 195, 215 },
		["Броня из толстой чешуи мурлока"] = { 190, 210 },
		["Броня огров Гордока"] = { 285, 295 },
		["Варварская портупея"] = { 210, 230 },
		["Варварские наплечники"] = { 195, 215 },
		["Варварские наручи"] = { 175, 195 },
		["Варварские перчатки"] = { 170, 190 },
		["Варварские поножи"] = { 190, 210 },
		["Варварский пояс"] = { 220, 240 },
		["Ветрочешуйчатый капюшон"] = { 375, 395 },
		["Взрывостойкие сапоги"] = { 360, 380 },
		["Взрывостойкие штаны"] = { 360, 380 },
		["Взрывостойкий пояс"] = { 360, 380 },
		["Воинский пояс потрошителя"] = { 430, 440 },
		["Воинский пояс претендента"] = { 470, 490 },
		["Воинский пояс скованных душ"] = { 385, 405 },
		["Волкоголовый шлем"] = { 245, 265 },
		["Вулканическая кираса"] = { 305, 325 },
		["Вулканические наплечники"] = { 320, 340 },
		["Вулканические поножи"] = { 290, 310 },
		["Высокие ботинки штормового укрытия"] = { 430, 440 },
		["Высокие ботинки штормового укрытия претендента"] = { 470, 490 },
		["Высокие драконьи ботинки"] = { 415, 435 },
		["Вычурная багровая шляпа"] = { 360, 380 },
		["Вычурная лиловая шляпа"] = { 360, 380 },
		["Вычурная походная шляпа"] = { 360, 380 },
		["Вычурная тропическая шляпа"] = { 360, 380 },
		["Гибельная кожаная головная повязка"] = { 300, 320 },
		["Гибельные кожаные наручи"] = { 285, 305 },
		["Гибельные кожаные рукавицы"] = { 280, 300 },
		["Гибельные кожаные штаны"] = { 310, 330 },
		["Гибельный кожаный доспех"] = { 320, 340 },
		["Гибельный кожаный пояс"] = { 320, 340 },
		["Глубоководные накладки для поножей"] = { 490, 500 },
		["Гнилостный пояс из шкур вурдалаков"] = { 475, 500 },
		["Грубая кожа"] = { 250, 250 },
		["Дикарские кожаные наплечники"] = { 240, 260 },
		["Дикарские кожаные поножи"] = { 270, 290 },
		["Дикарские кожаные сапоги"] = { 265, 285 },
		["Дикарский кожаный жилет"] = { 245, 265 },
		["Дикарский кожаный плащ"] = { 270, 290 },
		["Дикарский кожаный шлем"] = { 245, 265 },
		["Доспех Грозового Покрова"] = { 305, 325 },
		["Ежевичные сапоги"] = { 320, 340 },
		["Ежевичный пояс"] = { 320, 340 },
		["Ежевичный шлем"] = { 320, 340 },
		["Ездовой хлыст"] = { 360, 380 },
		["Жакет из кожи древней летучей мыши"] = { 320, 340 },
		["Железноперая кираса"] = { 310, 330 },
		["Железноперые наплечники"] = { 290, 310 },
		["Жесткая кираса из чешуи скорпида"] = { 240, 260 },
		["Жесткая кожа"] = { 100, 110 },
		["Жесткие наплечники из чешуи скорпида"] = { 260, 280 },
		["Жесткие наручи из чешуи скорпида"] = { 240, 260 },
		["Жесткие перчатки из чешуи скорпида"] = { 245, 265 },
		["Жесткие поножи из чешуи скорпида"] = { 265, 285 },
		["Жесткие сапоги из чешуи скорпида"] = { 255, 275 },
		["Жесткий шлем из чешуи скорпида"] = { 270, 290 },
		["Жестокие накладки для поножей"] = { 485, 495 },
		["Животворный шлем из чешуи дракона"] = { 375, 395 },
		["Жилет дренейского дикаря"] = { 340, 360 },
		["Жилет из толстой чешуи скорпида"] = { 285, 305 },
		["Жилет лунного сияния"] = { 115, 145 },
		["Жилет упреждающего удара"] = { 385, 405 },
		["Жукохрусты"] = { 415, 435 },
		["Заколдованная нерубская кираса"] = { 460, 475 },
		["Заряженные молнией поножи"] = { 475, 500 },
		["Захваты штормового укрытия"] = { 430, 440 },
		["Захваты штормового укрытия претендента"] = { 470, 490 },
		["Зачарованные перчатки из шкуры копытня"] = { 360, 380 },
		["Зачарованные поножи из шкуры копытня"] = { 360, 380 },
		["Зачарованные сапоги из шкуры копытня"] = { 360, 380 },
		["Зачарованные скверночешуйчатые перчатки"] = { 360, 380 },
		["Зачарованные скверночешуйчатые поножи"] = { 360, 380 },
		["Зачарованные скверночешуйчатые сапоги"] = { 360, 380 },
		["Защитная броня стража"] = { 195, 215 },
		["Зеленые кожаные наручи"] = { 200, 220 },
		["Зеленый кожаный доспех"] = { 175, 195 },
		["Зеленый кожаный пояс"] = { 180, 200 },
		["Земляные накладки для поножей"] = { 435, 445 },
		["Земляные сапоги из чешуи дракона Пустоты"] = { 375, 395 },
		["Зимние сапоги"] = { 285, 285 },
		["Золотая кираса Драконоборца"] = { 350, 370 },
		["Золотое оплечье рассвета"] = { 320, 340 },
		["Изменчивый плащ"] = { 320, 340 },
		["Изысканные наплечники мрачных глубин"] = { 495, 505 },
		["Изысканные наплечники приручителя протодраконов"] = { 510, 520 },
		["Изысканные наплечники с клеймом тьмы"] = { 470, 480 },
		["Изысканные наплечники цунами"] = { 485, 495 },
		["Изысканные наручи мрачных глубин"] = { 500, 510 },
		["Изысканные наручи приручителя протодраконов"] = { 495, 505 },
		["Изысканные наручи с клеймом тьмы"] = { 475, 485 },
		["Изысканные наручи цунами"] = { 470, 480 },
		["Изысканные перчатки мрачных глубин"] = { 505, 515 },
		["Изысканные перчатки приручителя протодраконов"] = { 495, 505 },
		["Изысканные перчатки с клеймом тьмы"] = { 480, 490 },
		["Изысканные перчатки цунами"] = { 470, 480 },
		["Изысканные поножи мрачных глубин"] = { 505, 515 },
		["Изысканные поножи приручителя протодраконов"] = { 500, 510 },
		["Изысканные поножи с клеймом тьмы"] = { 480, 490 },
		["Изысканные поножи цунами"] = { 475, 485 },
		["Изысканные сапоги мрачных глубин"] = { 510, 520 },
		["Изысканные сапоги приручителя протодраконов"] = { 515, 525 },
		["Изысканные сапоги с клеймом тьмы"] = { 485, 495 },
		["Изысканные сапоги цунами"] = { 490, 500 },
		["Изысканный нагрудный доспех мрачных глубин"] = { 510, 520 },
		["Изысканный нагрудный доспех приручителя протодраконов"] = { 505, 515 },
		["Изысканный нагрудный доспех с клеймом тьмы"] = { 485, 495 },
		["Изысканный нагрудный доспех цунами"] = { 480, 490 },
		["Изысканный пояс мрачных глубин"] = { 495, 505 },
		["Изысканный пояс приручителя протодраконов"] = { 510, 520 },
		["Изысканный пояс с клеймом тьмы"] = { 470, 480 },
		["Изысканный пояс цунами"] = { 485, 495 },
		["Изысканный шлем мрачных глубин"] = { 515, 525 },
		["Изысканный шлем приручителя протодраконов"] = { 505, 515 },
		["Изысканный шлем с клеймом тьмы"] = { 490, 500 },
		["Изысканный шлем цунами"] = { 480, 490 },
		["Искусно изготовленная накидка борца со смертью"] = { 510, 520 },
		["Искусно изготовленный плащ защитника пределов"] = { 510, 520 },
		["Йормунгарские накладки для поножей"] = { 410, 420 },
		["Йормунгарское усиление поножей"] = { 400, 410 },
		["Капюшон из чешуи кобры"] = { 375, 395 },
		["Капюшон изначальной жизни"] = { 375, 395 },
		["Капюшон ночного штурма"] = { 430, 440 },
		["Кираса Жизни"] = { 320, 340 },
		["Кираса духовного огня"] = { 320, 340 },
		["Кираса живых кристаллов"] = { 350, 370 },
		["Кираса загробника"] = { 450, 460 },
		["Кираса из борейской кожи"] = { 430, 440 },
		["Кираса из ледяной чешуи"] = { 320, 340 },
		["Кираса из черепашьего панциря"] = { 230, 250 },
		["Кираса из чешуи Ониксии"] = { 320, 340 },
		["Кираса из чешуи дракона"] = { 275, 295 },
		["Кираса из чешуи зеленого дракона"] = { 280, 300 },
		["Кираса из чешуи красного дракона"] = { 320, 340 },
		["Кираса из чешуи мурлока"] = { 125, 155 },
		["Кираса из чешуи синего дракона"] = { 305, 325 },
		["Кираса из чешуи черного дракона"] = { 310, 330 },
		["Кираса извечного шторма"] = { 350, 370 },
		["Кираса кровавого тигра"] = { 320, 340 },
		["Кираса ловца Скверны"] = { 370, 390 },
		["Кираса песчаного ловца"] = { 320, 340 },
		["Кираса рассекающего удара"] = { 430, 440 },
		["Кираса рыцаря из чешуи дракона"] = { 460, 475 },
		["Кираса удара Пустоты"] = { 385, 405 },
		["Кираса чешуи сна"] = { 320, 340 },
		["Кожаные наплечники земли"] = { 160, 185 },
		["Кожаные наручи стража"] = { 215, 235 },
		["Кожаные перчатки жителя холмов"] = { 170, 195 },
		["Кожаные рукавицы Солнца"] = { 375, 410 },
		["Кожаный жилет жителя холмов"] = { 125, 150 },
		["Кожаный нагрудный доспех солнца"] = { 375, 410 },
		["Колчан быстрой тетивы"] = { 245, 265 },
		["Колчан из тонкой кожи"] = { 60, 90 },
		["Колчан из узловатой кожи"] = { 325, 345 },
		["Колчан тысячи оперений"] = { 360, 380 },
		["Корона штормового укрытия"] = { 425, 435 },
		["Корона штормового укрытия претендента"] = { 470, 490 },
		["Короткие штаны боевого медведя"] = { 305, 325 },
		["Кулачные перчатки Древобрюхов"] = { 320, 340 },
		["Кушак искупленной души"] = { 385, 405 },
		["Лавовый пояс"] = { 320, 340 },
		["Ледяной кожаный плащ"] = { 200, 220 },
		["Мангустовые сапоги"] = { 320, 340 },
		["Маска потрошителя"] = { 425, 435 },
		["Маска потрошителя претендента"] = { 470, 490 },
		["Мглистые кожаные поножи"] = { 185, 205 },
		["Мглистые наручи"] = { 205, 225 },
		["Мглистые сапоги"] = { 220, 240 },
		["Мглистый кожаный доспех"] = { 195, 215 },
		["Мглистый пояс"] = { 215, 235 },
		["Меховая подкладка - выносливость"] = { 425, 435 },
		["Меховая подкладка - сила атаки"] = { 425, 435 },
		["Меховая подкладка - сила заклинаний"] = { 425, 435 },
		["Меховая подкладка - сопротивление магии льда"] = { 425, 435 },
		["Меховая подкладка - сопротивление огню"] = { 425, 435 },
		["Меховая подкладка - сопротивление силам природы"] = { 425, 435 },
		["Меховая подкладка - сопротивление тайной магии"] = { 425, 435 },
		["Меховая подкладка - сопротивление темной магии"] = { 425, 435 },
		["Мокасины искупленной души"] = { 385, 405 },
		["Мощь Древобрюхов"] = { 310, 330 },
		["Мундир из кожи ледопарда"] = { 320, 340 },
		["Мундир из чешуи черного дракончика"] = { 125, 150 },
		["Мяч из толстой кожи"] = { 150, 160 },
		["Набедренники земледарения"] = { 450, 460 },
		["Набедренники из осколков драконьих костей"] = { 475, 500 },
		["Набедренники искупленной души"] = { 385, 405 },
		["Набедренники потрошителя"] = { 430, 440 },
		["Набедренники претендента"] = { 470, 490 },
		["Набедренники тяжелых увечий"] = { 450, 460 },
		["Набедренники штормового укрытия"] = { 430, 440 },
		["Набедренники штормового укрытия претендента"] = { 470, 490 },
		["Наголенники скованных душ"] = { 385, 405 },
		["Наголовник угрюмости"] = { 425, 435 },
		["Наголовник угрюмости претендента"] = { 470, 490 },
		["Нагрудный доспех жителя льдов"] = { 390, 410 },
		["Нагрудный доспех из ледяной чешуи"] = { 435, 455 },
		["Нагрудный доспех из обмерзшей чешуи"] = { 390, 410 },
		["Нагрудный доспех потрошителя"] = { 425, 435 },
		["Нагрудный доспех претендента"] = { 470, 490 },
		["Нагрудный доспех сумеречного татя"] = { 375, 395 },
		["Нагрудный доспех угрюмости"] = { 425, 435 },
		["Нагрудный доспех угрюмости претендента"] = { 470, 490 },
		["Надежная накидка из нерубской шкуры"] = { 450, 460 },
		["Накидка борца со смертью"] = { 470, 480 },
		["Накладки для брони воздаятеля"] = { 335, 345 },
		["Накладки для брони магистра"] = { 335, 345 },
		["Накладки для поножей из кожи кобры"] = { 335, 355 },
		["Накладки для поножей из кожи копытня"] = { 365, 385 },
		["Накладки для поножей из ледяной чешуи"] = { 435, 445 },
		["Накладки для поножей из снежной шкуры"] = { 435, 445 },
		["Накладки для поножей из чешуи кобры"] = { 365, 385 },
		["Накладки для поножей из шкуры копытня"] = { 335, 355 },
		["Накладки из борейской кожи"] = { 375, 385 },
		["Накладки из грубой кожи"] = { 255, 275 },
		["Накладки из жесткой кожи"] = { 115, 130 },
		["Накладки из кожи Недр"] = { 320, 340 },
		["Накладки из плотной кожи"] = { 220, 240 },
		["Накладки из толстой борейской кожи"] = { 400, 405 },
		["Накладки из толстой кожи"] = { 170, 190 },
		["Накладки из толстой узловатой кожи"] = { 355, 365 },
		["Накладки из тонкой кожи"] = { 30, 60 },
		["Накладки из узловатой кожи"] = { 310, 340 },
		["Накладки сопротивления магии льда"] = { 350, 360 },
		["Накладки сопротивления огню"] = { 350, 360 },
		["Накладки сопротивления силам природы"] = { 350, 360 },
		["Накладки сопротивления тайной магии"] = { 350, 360 },
		["Накладки сопротивления темной магии"] = { 350, 360 },
		["Накулачники жителя льдов"] = { 400, 420 },
		["Накулачники искупленной души"] = { 385, 405 },
		["Накулачники штормового укрытия"] = { 425, 435 },
		["Накулачники штормового укрытия претендента"] = { 470, 490 },
		["Наплеч безукоризненных рогов"] = { 425, 435 },
		["Наплеч ожесточения"] = { 425, 435 },
		["Наплеч угрюмости"] = { 425, 435 },
		["Наплеч угрюмости претендента"] = { 470, 490 },
		["Наплечники Грозового Покрова"] = { 315, 335 },
		["Наплечники живой земли"] = { 385, 405 },
		["Наплечники жизни"] = { 290, 310 },
		["Наплечники жителя холмов"] = { 155, 180 },
		["Наплечники из обмерзшей чешуи"] = { 390, 410 },
		["Наплечники из толстой чешуи скорпида"] = { 320, 340 },
		["Наплечники из чешуи синего дракона"] = { 315, 335 },
		["Наплечники из чешуи черного дракона"] = { 320, 340 },
		["Наплечники кровавого тигра"] = { 320, 340 },
		["Наплечники молниеносного удара"] = { 385, 405 },
		["Наплечники молниеносной реакции"] = { 385, 405 },
		["Наплечники штормового укрытия"] = { 425, 435 },
		["Наплечники штормового укрытия претендента"] = { 470, 490 },
		["Наплечные пластины жителя льдов"] = { 395, 415 },
		["Наплечные пластины обновленной жизни"] = { 385, 405 },
		["Наплечные пластины потрошителя"] = { 425, 435 },
		["Наплечные пластины претендента"] = { 470, 490 },
		["Наплечные щитки быстрой стрелы"] = { 425, 435 },
		["Наплечные щитки быстрой стрелы претендента"] = { 470, 490 },
		["Напульсники ветроубийцы"] = { 375, 395 },
		["Наручи быстрой смерти"] = { 460, 475 },
		["Наручи быстрой стрелы"] = { 425, 435 },
		["Наручи быстрой стрелы претендента"] = { 470, 490 },
		["Наручи духовного огня"] = { 320, 340 },
		["Наручи из кожи древней летучей мыши"] = { 320, 340 },
		["Наручи из ледяной чешуи"] = { 320, 340 },
		["Наручи из обмерзшей чешуи"] = { 400, 420 },
		["Наручи из толстой чешуи скорпида"] = { 275, 295 },
		["Наручи из тонкой кожи"] = { 100, 130 },
		["Наручи из черепашьего панциря"] = { 230, 250 },
		["Наручи из чешуи зеленого дракончика"] = { 210, 230 },
		["Наручи из чешуи мурлока"] = { 210, 230 },
		["Наручи легкокрылого ястреба"] = { 385, 405 },
		["Наручи ловца Скверны"] = { 370, 390 },
		["Наручи молниеносного удара"] = { 385, 405 },
		["Наручи обновленной жизни"] = { 385, 405 },
		["Наручи орлиной погибели"] = { 425, 435 },
		["Наручи отражения"] = { 410, 420 },
		["Наручи песчаного ловца"] = { 320, 340 },
		["Наручи рыцаря из чешуи дракона"] = { 460, 475 },
		["Наручи скованных душ"] = { 385, 405 },
		["Наручи стремительного полета"] = { 320, 340 },
		["Наручи тяжелых увечий"] = { 450, 460 },
		["Наручи угрюмости"] = { 425, 435 },
		["Наручи угрюмости претендента"] = { 470, 490 },
		["Наручи удара Пустоты"] = { 385, 405 },
		["Наручи упреждающего удара"] = { 385, 405 },
		["Наручники живой земли"] = { 385, 405 },
		["Наручники молниеносной реакции"] = { 385, 405 },
		["Наручники потрошителя"] = { 425, 435 },
		["Наручники претендента"] = { 470, 490 },
		["Небольшой кожаный подсумок"] = { 60, 90 },
		["Нерубские накладки для поножей"] = { 405, 415 },
		["Нерубские наплечники"] = { 395, 415 },
		["Нерубские наручи"] = { 400, 420 },
		["Нерубские перчатки"] = { 385, 405 },
		["Нерубские поножи"] = { 385, 405 },
		["Нерубские сапоги"] = { 395, 415 },
		["Нерубский нагрудный доспех"] = { 390, 410 },
		["Нерубский пояс"] = { 390, 410 },
		["Нерубский шлем"] = { 400, 420 },
		["Нерубское усиление поножей"] = { 395, 405 },
		["Несносимые ботфорты"] = { 475, 500 },
		["Нетронутая шкура"] = { 500, 510 },
		["Нетронутые глубоководные накладки для поножей"] = { 505, 515 },
		["Нетронутые жестокие накладки для поножей"] = { 500, 510 },
		["Нетронутые укрепленные накладки для поножей"] = { 510, 520 },
		["Ночная головная повязка"] = { 225, 245 },
		["Ночной мундир"] = { 225, 245 },
		["Ночной плащ"] = { 250, 270 },
		["Ночные наплечники"] = { 230, 250 },
		["Ночные сапоги"] = { 255, 275 },
		["Ночные штаны"] = { 250, 270 },
		["Облачение Феникса"] = { 375, 410 },
		["Обработанная грубая шкура"] = { 250, 260 },
		["Обработанная легкая шкура"] = { 55, 75 },
		["Обработанная плотная шкура"] = { 200, 200 },
		["Обработанная средняя шкура"] = { 115, 130 },
		["Обработанная тяжелая шкура"] = { 160, 170 },
		["Огненночешуйчатые поножи"] = { 360, 380 },
		["Огненночешуйчатые сапоги"] = { 360, 380 },
		["Огненночешуйчатый пояс"] = { 360, 380 },
		["Одеяния лунного затмения"] = { 460, 475 },
		["Опаленный смертью пояс"] = { 455, 475 },
		["Оперенная перьями кираса"] = { 270, 290 },
		["Оплавленный пояс"] = { 320, 340 },
		["Оплавленный шлем"] = { 320, 340 },
		["Опоясок с ножами для снятия шкур"] = { 475, 500 },
		["Панцирь Солнца и Тени"] = { 375, 410 },
		["Панцирь рыцарского проклятья"] = { 460, 475 },
		["Перчатки Великого Отца"] = { 210, 230 },
		["Перчатки Грозового Покрова"] = { 320, 340 },
		["Перчатки Живого прикосновения"] = { 375, 395 },
		["Перчатки Флетчера"] = { 150, 175 },
		["Перчатки вечного сумрака"] = { 375, 410 },
		["Перчатки дракона Пустоты"] = { 375, 395 },
		["Перчатки дренейского дикаря"] = { 320, 340 },
		["Перчатки жителя льдов"] = { 385, 405 },
		["Перчатки жулика"] = { 165, 190 },
		["Перчатки из гибкой кожи"] = { 145, 170 },
		["Перчатки из искаженной чешуи"] = { 130, 155 },
		["Перчатки из кожи древней летучей мыши"] = { 320, 340 },
		["Перчатки из кожи ледопарда"] = { 315, 335 },
		["Перчатки из обмерзшей чешуи"] = { 395, 415 },
		["Перчатки из сквернокожи"] = { 350, 370 },
		["Перчатки из черепашьего панциря"] = { 225, 245 },
		["Перчатки из чешуи кобры"] = { 375, 395 },
		["Перчатки из чешуи красного дракончика"] = { 145, 170 },
		["Перчатки налетевшего ветра"] = { 375, 395 },
		["Перчатки стража"] = { 210, 230 },
		["Перчатки травника"] = { 160, 185 },
		["Плащ Тьмы"] = { 370, 390 },
		["Плащ жителя холмов"] = { 170, 190 },
		["Плащ защитника пределов"] = { 470, 480 },
		["Плащ из искаженной чешуи"] = { 120, 150 },
		["Плащ из чешуи Ониксии"] = { 320, 340 },
		["Плащ из чешуи черного дракончика"] = { 125, 150 },
		["Плащ ледяного убийцы"] = { 450, 460 },
		["Плащ суровых ветров"] = { 390, 410 },
		["Плащ томимых небес"] = { 405, 425 },
		["Плащ хранителя"] = { 205, 225 },
		["Плотная кираса из чешуи дракона Пустоты"] = { 375, 395 },
		["Плотная кожа"] = { 200, 205 },
		["Поводья выносливой винторогой гарны"] = { 535, 545 },
		["Повязки угрюмости"] = { 430, 440 },
		["Повязки угрюмости претендента"] = { 470, 490 },
		["Подсумок из драконьей чешуи"] = { 420, 425 },
		["Подсумок из плотной кожи"] = { 245, 265 },
		["Подсумок из толстой кожи"] = { 170, 190 },
		["Подсумок из узловатой кожи"] = { 325, 345 },
		["Подсумок из чешуи дракона Пустоты"] = { 360, 380 },
		["Поножи Буйного Пера"] = { 280, 300 },
		["Поножи Драконоборца"] = { 280, 300 },
		["Поножи Черной бури"] = { 280, 300 },
		["Поножи быстрой стрелы"] = { 430, 440 },
		["Поножи быстрой стрелы претендента"] = { 470, 490 },
		["Поножи ветроруба"] = { 450, 460 },
		["Поножи дренейского дикаря"] = { 330, 350 },
		["Поножи дьявозавра"] = { 320, 340 },
		["Поножи жизни"] = { 305, 325 },
		["Поножи жителя льдов"] = { 385, 405 },
		["Поножи из кожи ледопарда"] = { 305, 325 },
		["Поножи из обмерзшей чешуи"] = { 385, 405 },
		["Поножи из сквернокожи"] = { 360, 380 },
		["Поножи из толстой чешуи скорпида"] = { 305, 325 },
		["Поножи из черепашьего панциря"] = { 255, 275 },
		["Поножи из чешуи зеленого дракона"] = { 290, 310 },
		["Поножи из чешуи синего дракона"] = { 320, 340 },
		["Поножи из чешуи черного дракона"] = { 320, 340 },
		["Поножи интуитивного боя"] = { 430, 440 },
		["Поножи клинка"] = { 475, 500 },
		["Поножи неистовства пустоты"] = { 350, 370 },
		["Поножи угрюмости"] = { 430, 440 },
		["Поножи угрюмости претендента"] = { 470, 490 },
		["Портупея боевого медведя"] = { 295, 315 },
		["Портупея из шкуры ящера"] = { 185, 205 },
		["Походная сума зверолова"] = { 420, 425 },
		["Пояс быстрой стрелы"] = { 430, 440 },
		["Пояс быстрой стрелы претендента"] = { 470, 490 },
		["Пояс глубокой тени"] = { 385, 405 },
		["Пояс гончей Недр"] = { 320, 340 },
		["Пояс драконов"] = { 455, 475 },
		["Пояс жителя льдов"] = { 380, 395 },
		["Пояс жителя холмов"] = { 145, 170 },
		["Пояс из искаженной чешуи"] = { 140, 165 },
		["Пояс из ледяной чешуи"] = { 430, 450 },
		["Пояс из обмерзшей чешуи"] = { 385, 405 },
		["Пояс из толстой чешуи скорпида"] = { 300, 320 },
		["Пояс из чешуи мурлока"] = { 120, 150 },
		["Пояс из шкуры ящера"] = { 185, 205 },
		["Пояс легкокрылого ястреба"] = { 385, 405 },
		["Пояс ловца Скверны"] = { 360, 380 },
		["Пояс неистовства пустоты"] = { 350, 370 },
		["Пояс полярной жизни"] = { 455, 475 },
		["Пояс природной силы"] = { 385, 405 },
		["Пояс сезона дождей"] = { 385, 405 },
		["Пояс стража"] = { 190, 210 },
		["Пояс угрюмости"] = { 430, 440 },
		["Пояс угрюмости претендента"] = { 470, 490 },
		["Пояс удара Пустоты"] = { 385, 405 },
		["Пояс упреждающего удара"] = { 385, 405 },
		["Пояс черного орла"] = { 385, 405 },
		["Пояс штормового укрытия"] = { 430, 440 },
		["Пояс штормового укрытия претендента"] = { 470, 490 },
		["Поясное хранилище тяжелых игл"] = { 475, 500 },
		["Пронизанные солнцем чешуйчатые перчатки"] = { 375, 410 },
		["Пронизанный солнцем нагрудный доспех"] = { 375, 410 },
		["Прочные земляные накладки для поножей"] = { 500, 510 },
		["Прочные накладки для поножей из ледяной чешуи"] = { 500, 510 },
		["Прочные накладки для поножей из снежной шкуры"] = { 500, 510 },
		["Разноцветные рукавицы"] = { 320, 340 },
		["Разноцветный плащ"] = { 320, 340 },
		["Рассветные ботфорты"] = { 310, 330 },
		["Ремень Прозрения"] = { 320, 340 },
		["Ремень ночного штурма"] = { 425, 435 },
		["Роскошная шелковая сумка для самоцветов"] = { 520, 530 },
		["Рукавицы Моря"] = { 250, 270 },
		["Рукавицы быстрой стрелы"] = { 430, 440 },
		["Рукавицы быстрой стрелы претендента"] = { 470, 490 },
		["Рукавицы духовного огня"] = { 320, 340 },
		["Рукавицы дьявозавра"] = { 310, 330 },
		["Рукавицы из ледяной чешуи"] = { 320, 340 },
		["Рукавицы из толстой чешуи скорпида"] = { 295, 315 },
		["Рукавицы из чешуи дракона"] = { 245, 265 },
		["Рукавицы из чешуи зеленого дракона"] = { 300, 320 },
		["Рукавицы морского прибоя"] = { 425, 435 },
		["Рукавицы песчаного ловца"] = { 320, 340 },
		["Рукавицы потрошителя"] = { 430, 440 },
		["Рукавицы претендента"] = { 470, 490 },
		["Рукодельные кожаные наручи"] = { 40, 70 },
		["Рукодельные кожаные сапоги"] = { 40, 70 },
		["Рукодельные кожаные штаны"] = { 45, 75 },
		["Рукодельный кожаный жилет"] = { 40, 70 },
		["Рукодельный кожаный плащ"] = { 40, 70 },
		["Рукодельный кожаный пояс"] = { 55, 85 },
		["Руническая кожаная головная повязка"] = { 310, 330 },
		["Рунические кожаные наплечники"] = { 320, 340 },
		["Рунические кожаные наручи"] = { 295, 315 },
		["Рунические кожаные рукавицы"] = { 290, 310 },
		["Рунические кожаные штаны"] = { 320, 340 },
		["Рунический кожаный доспех"] = { 320, 340 },
		["Рунический кожаный пояс"] = { 300, 320 },
		["Рюкзак с бесчисленными карманами"] = { 420, 425 },
		["Сапоги багрового ястреба"] = { 385, 405 },
		["Сапоги быстрой стрелы"] = { 430, 440 },
		["Сапоги быстрой стрелы претендента"] = { 470, 490 },
		["Сапоги быстроты"] = { 220, 240 },
		["Сапоги ветроруба"] = { 450, 460 },
		["Сапоги гончей Недр"] = { 315, 335 },
		["Сапоги дренейского дикаря"] = { 310, 330 },
		["Сапоги духа земли"] = { 475, 500 },
		["Сапоги жителя льдов"] = { 390, 410 },
		["Сапоги земледарения"] = { 450, 460 },
		["Сапоги зимней закалки"] = { 455, 475 },
		["Сапоги из живой чешуи"] = { 455, 475 },
		["Сапоги из жормунгальской чешуи"] = { 425, 435 },
		["Сапоги из кожи ледопарда"] = { 295, 315 },
		["Сапоги из ледяной чешуи"] = { 430, 450 },
		["Сапоги из обмерзшей чешуи"] = { 395, 415 },
		["Сапоги из сквернокожи"] = { 360, 380 },
		["Сапоги из чешуи черного дракона"] = { 320, 340 },
		["Сапоги надвигающейся смерти"] = { 475, 500 },
		["Сапоги неистовства пустоты"] = { 360, 380 },
		["Сапоги непроглядной тьмы"] = { 385, 405 },
		["Сапоги природной милости"] = { 385, 405 },
		["Сапоги скованных душ"] = { 385, 405 },
		["Сапоги тишины"] = { 455, 475 },
		["Сапоги угрюмости"] = { 430, 440 },
		["Сапоги угрюмости претендента"] = { 470, 490 },
		["Сапоги ударившей молнии"] = { 455, 475 },
		["Сапоги урагана"] = { 385, 405 },
		["Сень Природы"] = { 320, 340 },
		["Сильно огрубелая кожа"] = { 460, 470 },
		["Синий пояс Хаоса"] = { 455, 475 },
		["Скверночешуйчатая кираса"] = { 345, 365 },
		["Скверночешуйчатые перчатки"] = { 310, 330 },
		["Скверночешуйчатые сапоги"] = { 320, 340 },
		["Скверночешуйчатые штаны"] = { 330, 350 },
		["Снежные наручи"] = { 320, 340 },
		["Снежные перчатки"] = { 320, 340 },
		["Снежные сапоги"] = { 430, 450 },
		["Снежный жилет"] = { 435, 455 },
		["Снежный мундир"] = { 320, 340 },
		["Снежный шнурованный ремень"] = { 430, 450 },
		["Стрелецкие перчатки Феникса"] = { 375, 410 },
		["Сумка из великолепной шкуры"] = { 520, 530 },
		["Сумка из шкуры кодо"] = { 70, 100 },
		["Сумка кожевника"] = { 310, 330 },
		["Сумка королевского начертателя"] = { 520, 530 },
		["Сумка мастера травника"] = { 520, 530 },
		["Сумка множества шкур"] = { 370, 390 },
		["Таинственные наплечники мрачных глубин"] = { 495, 505 },
		["Таинственные наплечники приручителя протодраконов"] = { 510, 520 },
		["Таинственные наплечники с клеймом тьмы"] = { 470, 480 },
		["Таинственные наплечники цунами"] = { 485, 495 },
		["Таинственные наручи мрачных глубин"] = { 500, 510 },
		["Таинственные наручи приручителя протодраконов"] = { 495, 505 },
		["Таинственные наручи с клеймом тьмы"] = { 475, 485 },
		["Таинственные наручи цунами"] = { 470, 480 },
		["Таинственные перчатки мрачных глубин"] = { 505, 515 },
		["Таинственные перчатки приручителя протодраконов"] = { 495, 505 },
		["Таинственные перчатки с клеймом тьмы"] = { 480, 490 },
		["Таинственные перчатки цунами"] = { 470, 480 },
		["Таинственные поножи мрачных глубин"] = { 505, 515 },
		["Таинственные поножи приручителя протодраконов"] = { 500, 510 },
		["Таинственные поножи с клеймом тьмы"] = { 480, 490 },
		["Таинственные поножи цунами"] = { 475, 485 },
		["Таинственные сапоги мрачных глубин"] = { 510, 520 },
		["Таинственные сапоги приручителя протодраконов"] = { 515, 525 },
		["Таинственные сапоги с клеймом тьмы"] = { 485, 495 },
		["Таинственные сапоги цунами"] = { 490, 500 },
		["Таинственный нагрудный доспех мрачных глубин"] = { 510, 520 },
		["Таинственный нагрудный доспех приручителя протодраконов"] = { 505, 515 },
		["Таинственный нагрудный доспех с клеймом тьмы"] = { 485, 495 },
		["Таинственный нагрудный доспех цунами"] = { 480, 490 },
		["Таинственный пояс мрачных глубин"] = { 495, 505 },
		["Таинственный пояс приручителя протодраконов"] = { 510, 520 },
		["Таинственный пояс с клеймом тьмы"] = { 470, 480 },
		["Таинственный пояс цунами"] = { 485, 495 },
		["Таинственный шлем мрачных глубин"] = { 515, 525 },
		["Таинственный шлем приручителя протодраконов"] = { 505, 515 },
		["Таинственный шлем с клеймом тьмы"] = { 490, 500 },
		["Таинственный шлем цунами"] = { 480, 490 },
		["Темная кираса из обмерзшей чешуи"] = { 410, 430 },
		["Темные кожаные наплечники"] = { 165, 190 },
		["Темные кожаные перчатки"] = { 155, 180 },
		["Темные кожаные сапоги"] = { 125, 150 },
		["Темные кожаные штаны"] = { 140, 165 },
		["Темные нерубские поножи"] = { 410, 430 },
		["Темные поножи жителя льдов"] = { 410, 430 },
		["Темные поножи из обмерзшей чешуи"] = { 410, 430 },
		["Темный кожаный мундир"] = { 125, 150 },
		["Темный кожаный плащ"] = { 135, 160 },
		["Темный кожаный пояс"] = { 150, 175 },
		["Темный нагрудный доспех жителя льдов"] = { 410, 430 },
		["Темный нерубский нагрудник"] = { 410, 430 },
		["Тенекожаные перчатки"] = { 210, 230 },
		["Тисненые кожаные перчатки"] = { 85, 115 },
		["Тисненые кожаные сапоги"] = { 85, 115 },
		["Тисненые кожаные штаны"] = { 105, 135 },
		["Тисненый кожаный жилет"] = { 70, 100 },
		["Тисненый кожаный плащ"] = { 90, 120 },
		["Толстая борейская кожа"] = { 385, 405 },
		["Толстая кожа"] = { 150, 160 },
		["Толстая узловатая кожа"] = { 325, 335 },
		["Тонкая кожа"] = { 20, 40 },
		["Тонкие кожаные перчатки"] = { 105, 135 },
		["Тонкие кожаные сапоги"] = { 120, 150 },
		["Тонкие кожаные штаны"] = { 130, 155 },
		["Тонкий кожаный мундир"] = { 115, 145 },
		["Тонкий кожаный плащ"] = { 105, 135 },
		["Тонкий кожаный пояс"] = { 110, 140 },
		["Трансцендентная сумка"] = { 520, 530 },
		["Троекратно укрепленная шахтерская сумка"] = { 520, 530 },
		["Тролльский тканый наплеч"] = { 450, 460 },
		["Тролльский тканый ремень"] = { 450, 460 },
		["Тяжелые перчатки Земли"] = { 170, 195 },
		["Тяжелые поножи из шкуры копытня"] = { 365, 385 },
		["Тяжелые сапоги из шкуры копытня"] = { 365, 385 },
		["Тяжелый колчан"] = { 170, 190 },
		["Тяжелый панцирь из шкуры копытня"] = { 370, 390 },
		["Удобная кожаная шляпа"] = { 220, 240 },
		["Удобные стельки"] = { 300, 310 },
		["Узловатая кожа"] = { 300, 310 },
		["Укомплектованный ящик с инструментами"] = { 520, 530 },
		["Украшенный самоцветами кожаный пояс"] = { 205, 225 },
		["Укрепленная шахтерская сумка"] = { 335, 345 },
		["Укрепленные кожаные перчатки"] = { 160, 185 },
		["Укрепленные накладки для поножей"] = { 495, 505 },
		["Укрепленный кожаный доспех"] = { 145, 170 },
		["Уплотненный пояс из электрохимеры"] = { 475, 500 },
		["Упрочнения для перчаток"] = { 355, 365 },
		["Усиленный нерубский колчан"] = { 420, 425 },
		["Утолщенная дренейская безрукавка"] = { 340, 360 },
		["Утолщенные дренейские перчатки"] = { 310, 330 },
		["Утолщенные дренейские сапоги"] = { 330, 350 },
		["Утолщенные дренейские штаны"] = { 325, 345 },
		["Хауберк быстрой стрелы"] = { 425, 435 },
		["Хауберк быстрой стрелы претендента"] = { 470, 490 },
		["Хауберк легкокрылого ястреба"] = { 385, 405 },
		["Хауберк штормового укрытия"] = { 425, 435 },
		["Хауберк штормового укрытия претендента"] = { 470, 490 },
		["Химерические перчатки"] = { 285, 305 },
		["Химерические поножи"] = { 300, 320 },
		["Химерические сапоги"] = { 295, 315 },
		["Химерический жилет"] = { 310, 330 },
		["Черная кираса из чешуи дракона Пустоты"] = { 385, 405 },
		["Черные наручи из чешуи дракона Пустоты"] = { 385, 405 },
		["Черные полярные поножи"] = { 410, 430 },
		["Черные полярные сапоги"] = { 415, 435 },
		["Черные хитиновые наручи"] = { 460, 475 },
		["Черный полярный нагрудник"] = { 410, 430 },
		["Черный пояс из чешуи дракона Пустоты"] = { 385, 405 },
		["Чешуйчатая дренейская безрукавка"] = { 335, 355 },
		["Чешуйчатые дренейские перчатки"] = { 320, 340 },
		["Чешуйчатые дренейские сапоги"] = { 345, 365 },
		["Чешуйчатые дренейские штаны"] = { 310, 330 },
		["Чешуйчатые ледоступы"] = { 415, 435 },
		["Шахтерская сумка из шкуры мамонта"] = { 420, 425 },
		["Шлем быстрой стрелы"] = { 425, 435 },
		["Шлем быстрой стрелы претендента"] = { 470, 490 },
		["Шлем дракона Пустоты"] = { 375, 395 },
		["Шлем жителя льдов"] = { 400, 420 },
		["Шлем из обмерзшей чешуи"] = { 400, 420 },
		["Шлем из толстой чешуи скорпида"] = { 315, 335 },
		["Шлем из черепашьего панциря"] = { 250, 270 },
		["Шлем огня"] = { 270, 290 },
		["Штаны Грозового Покрова"] = { 295, 315 },
		["Штаны из грубой кожи"] = { 65, 95 },
		["Штаны из тонкой кожи"] = { 125, 155 },
		["Штаны стража"] = { 180, 200 },
		["Яростные наплечники мрачных глубин"] = { 495, 505 },
		["Яростные наплечники приручителя протодраконов"] = { 510, 520 },
		["Яростные наплечники с клеймом тьмы"] = { 470, 480 },
		["Яростные наплечники цунами"] = { 485, 495 },
		["Яростные наручи мрачных глубин"] = { 500, 510 },
		["Яростные наручи приручителя протодраконов"] = { 495, 505 },
		["Яростные наручи с клеймом тьмы"] = { 475, 485 },
		["Яростные наручи цунами"] = { 470, 480 },
		["Яростные перчатки мрачных глубин"] = { 505, 515 },
		["Яростные перчатки приручителя протодраконов"] = { 495, 505 },
		["Яростные перчатки с клеймом тьмы"] = { 480, 490 },
		["Яростные перчатки цунами"] = { 470, 480 },
		["Яростные поножи мрачных глубин"] = { 505, 515 },
		["Яростные поножи приручителя протодраконов"] = { 500, 510 },
		["Яростные поножи с клеймом тьмы"] = { 480, 490 },
		["Яростные поножи цунами"] = { 475, 485 },
		["Яростные сапоги мрачных глубин"] = { 510, 520 },
		["Яростные сапоги приручителя протодраконов"] = { 515, 525 },
		["Яростные сапоги с клеймом тьмы"] = { 485, 495 },
		["Яростные сапоги цунами"] = { 490, 500 },
		["Яростный нагрудный доспех мрачных глубин"] = { 510, 520 },
		["Яростный нагрудный доспех приручителя протодраконов"] = { 505, 515 },
		["Яростный нагрудный доспех с клеймом тьмы"] = { 485, 495 },
		["Яростный нагрудный доспех цунами"] = { 480, 490 },
		["Яростный пояс мрачных глубин"] = { 495, 505 },
		["Яростный пояс приручителя протодраконов"] = { 510, 520 },
		["Яростный пояс с клеймом тьмы"] = { 470, 480 },
		["Яростный пояс цунами"] = { 485, 495 },
		["Яростный шлем мрачных глубин"] = { 515, 525 },
		["Яростный шлем приручителя протодраконов"] = { 505, 515 },
		["Яростный шлем с клеймом тьмы"] = { 490, 500 },
		["Яростный шлем цунами"] = { 480, 490 },
	},
	[171] = {
		["'Дар Артаса'"] = { 255, 295 },
		["Алхимический дзен-камень"] = { 500, 510 },
		["Алхимический камень"] = { 365, 380 },
		["Алхимический камень жизни"] = { 525, 535 },
		["Алхимический камень искупителя"] = { 380, 390 },
		["Алхимический камень стража"] = { 380, 390 },
		["Алхимический камень убийцы"] = { 380, 390 },
		["Алхимический камень чародея"] = { 380, 390 },
		["Алхимическое зелье омоложения"] = { 500, 510 },
		["Амулет безумия Гурубаши"] = { 315, 330 },
		["Бездонный флакон с зельем маны"] = { 415, 420 },
		["Бездонный флакон с лечебным зельем"] = { 410, 415 },
		["Большое зелье защиты от магии льда"] = { 375, 380 },
		["Большое зелье защиты от огня"] = { 375, 380 },
		["Большое зелье защиты от светлой магии"] = { 375, 380 },
		["Большое зелье защиты от сил природы"] = { 375, 380 },
		["Большое зелье защиты от тайной магии"] = { 375, 380 },
		["Большое зелье защиты от темной магии"] = { 375, 380 },
		["Большое зелье омоложения"] = { 310, 330 },
		["Большое зелье спокойного сна"] = { 365, 380 },
		["Большой флакон с зельем маны"] = { 275, 315 },
		["Большой флакон с лечебным зельем"] = { 230, 270 },
		["Большой эликсир защиты"] = { 360, 375 },
		["Большой эликсир крови волшебника"] = { 370, 380 },
		["Большой эликсир ловкости"] = { 345, 360 },
		["Большой эликсир огневой мощи"] = { 360, 375 },
		["Большой эликсир силы"] = { 320, 335 },
		["Большой эликсир силы льда"] = { 335, 350 },
		["Большой эликсир стойкости"] = { 325, 340 },
		["Большой эликсир тролльей крови"] = { 200, 240 },
		["Большой эликсир энергии Тьмы"] = { 365, 380 },
		["Великий котел войны"] = { 525, 535 },
		["Воспламеняющая смесь"] = { 220, 260 },
		["Гигантский флакон с зельем маны"] = { 355, 370 },
		["Гигантский флакон с зельем омоложения"] = { 375, 380 },
		["Гигантский флакон с лечебным зельем"] = { 340, 355 },
		["Гоблинское ракетное топливо"] = { 225, 265 },
		["Зажигательное масло"] = { 150, 170 },
		["Зелье адреналина"] = { 415, 430 },
		["Зелье безумного алхимика"] = { 335, 350 },
		["Зелье безумной силы"] = { 335, 350 },
		["Зелье быстрого плавания"] = { 130, 170 },
		["Зелье быстроты"] = { 415, 430 },
		["Зелье героизма"] = { 365, 380 },
		["Зелье дикой магии"] = { 415, 430 },
		["Зелье железного щита"] = { 375, 380 },
		["Зелье защиты от магии"] = { 225, 265 },
		["Зелье защиты от магии льда"] = { 205, 245 },
		["Зелье защиты от огня"] = { 210, 250 },
		["Зелье защиты от светлой магии"] = { 130, 170 },
		["Зелье защиты от сил природы"] = { 210, 250 },
		["Зелье защиты от темной магии"] = { 160, 200 },
		["Зелье из дикой лозы"] = { 240, 280 },
		["Зелье лазутчика"] = { 330, 345 },
		["Зелье маны"] = { 180, 220 },
		["Зелье маны мастера"] = { 495, 505 },
		["Зелье невидимости"] = { 250, 290 },
		["Зелье непреклонности"] = { 495, 505 },
		["Зелье несокрушимости"] = { 415, 430 },
		["Зелье неудержимости"] = { 300, 340 },
		["Зелье ночных кошмаров"] = { 385, 395 },
		["Зелье оцепенения"] = { 315, 330 },
		["Зелье очищения"] = { 300, 340 },
		["Зелье поиска сокровищ Фельярда"] = { 525, 535 },
		["Зелье покровов"] = { 350, 365 },
		["Зелье простой невидимости"] = { 185, 225 },
		["Зелье разрушения"] = { 365, 380 },
		["Зелье свободы действий"] = { 175, 215 },
		["Зелье скорости"] = { 90, 130 },
		["Зелье спокойного сна"] = { 245, 285 },
		["Зелье сумасшедшего алхимика"] = { 415, 430 },
		["Зелье ускорения"] = { 365, 380 },
		["Зелье чистой магии"] = { 505, 515 },
		["Зелье чистой ярости"] = { 500, 510 },
		["Зелье ярости"] = { 90, 130 },
		["Исследование трав Нордскола"] = { 415, 430 },
		["Карломасло"] = { 380, 390 },
		["Котел великой защиты от магии льда"] = { 360, 380 },
		["Котел великой защиты от огня"] = { 360, 380 },
		["Котел великой защиты от сил природы"] = { 360, 380 },
		["Котел великой защиты от тайной магии"] = { 360, 380 },
		["Котел великой защиты от темной магии"] = { 360, 380 },
		["Котел войны"] = { 500, 510 },
		["Крепкое зелье тролльей крови"] = { 150, 190 },
		["Крохотный флакон с зельем маны"] = { 65, 105 },
		["Крохотный флакон с лечебным зельем"] = { 55, 95 },
		["Лечебное зелье"] = { 135, 175 },
		["Лечебное зелье мастера"] = { 490, 500 },
		["Маленький флакон с зельем маны"] = { 145, 185 },
		["Маленький флакон с лечебным зельем"] = { 85, 125 },
		["Малый настой весенних цветов"] = { 465, 475 },
		["Малый настой земли"] = { 460, 470 },
		["Малый настой кусачих морозов"] = { 475, 485 },
		["Малый настой ласкового солнца"] = { 470, 480 },
		["Малый настой опадающих листьев"] = { 480, 490 },
		["Малый настой сопротивления"] = { 390, 400 },
		["Малый эликсир азарта"] = { 480, 490 },
		["Малый эликсир безупречности"] = { 465, 475 },
		["Малый эликсир ведьмы"] = { 485, 495 },
		["Малый эликсир вооружения"] = { 475, 485 },
		["Малый эликсир ловкости"] = { 165, 205 },
		["Малый эликсир монаха"] = { 480, 490 },
		["Малый эликсир наставника"] = { 475, 485 },
		["Малый эликсир отражений"] = { 460, 470 },
		["Малый эликсир подземелий"] = { 465, 475 },
		["Малый эликсир спокойствия"] = { 460, 470 },
		["Малый эликсир стремительности"] = { 470, 480 },
		["Малый эликсир упорства"] = { 470, 480 },
		["Масло Тьмы"] = { 190, 230 },
		["Масло каменного угря"] = { 250, 260 },
		["Масло льда"] = { 220, 260 },
		["Масло черноротика"] = { 80, 100 },
		["Могущественный алхимический камень"] = { 420, 430 },
		["Могущественный алхимический камень претендента"] = { 470, 490 },
		["Мощное зелье защиты от магии льда"] = { 410, 420 },
		["Мощное зелье защиты от огня"] = { 410, 420 },
		["Мощное зелье защиты от сил природы"] = { 410, 420 },
		["Мощное зелье защиты от тайной магии"] = { 410, 420 },
		["Мощное зелье защиты от темной магии"] = { 410, 420 },
		["Мощное зелье омоложения"] = { 415, 430 },
		["Мощное зелье ярости"] = { 270, 310 },
		["Мощный эликсир защиты"] = { 415, 430 },
		["Мощный эликсир крови волшебника"] = { 415, 430 },
		["Мощный эликсир ловкости"] = { 400, 415 },
		["Мощный эликсир разума"] = { 400, 415 },
		["Мощный эликсир силы"] = { 390, 400 },
		["Мощный эликсир стойкости"] = { 395, 405 },
		["Мощный эликсир тролльей крови"] = { 305, 345 },
		["Наилучший эликсир защиты"] = { 280, 320 },
		["Настой Слепящего света"] = { 375, 380 },
		["Настой безжалостного убийцы"] = { 375, 380 },
		["Настой бесконечной ярости"] = { 450, 465 },
		["Настой великой силы"] = { 315, 330 },
		["Настой весенних цветов"] = { 505, 515 },
		["Настой всецветного сопротивления"] = { 315, 330 },
		["Настой всецветного чуда"] = { 390, 405 },
		["Настой драконьего разума"] = { 500, 510 },
		["Настой земли"] = { 520, 530 },
		["Настой каменной крови"] = { 450, 465 },
		["Настой крепости"] = { 500, 510 },
		["Настой кусачих морозов"] = { 515, 525 },
		["Настой ласкового солнца"] = { 510, 520 },
		["Настой ледяного змея"] = { 450, 465 },
		["Настой могучего восстановления"] = { 375, 380 },
		["Настой опадающих листьев"] = { 500, 510 },
		["Настой севера"] = { 440, 450 },
		["Настой силы титана"] = { 500, 510 },
		["Настой сопротивления"] = { 500, 510 },
		["Настой стальной кожи"] = { 500, 510 },
		["Настой текущей воды"] = { 500, 510 },
		["Настой титанов"] = { 315, 330 },
		["Настой укрепления"] = { 375, 380 },
		["Настой чистого колдунства"] = { 450, 465 },
		["Настой чистой мудрости"] = { 315, 330 },
		["Настой чистой смерти"] = { 375, 380 },
		["Несокрушимый алхимический камень"] = { 420, 430 },
		["Несокрушимый алхимический камень претендента"] = { 470, 490 },
		["Неустойчивый алхимический камень"] = { 525, 535 },
		["Огромный флакон с зельем маны"] = { 310, 350 },
		["Огромный флакон с лечебным зельем"] = { 290, 330 },
		["Оскверненное зелье маны"] = { 375, 380 },
		["Оскверненное зелье регенерации"] = { 360, 375 },
		["Оскверненное масло"] = { 495, 505 },
		["Оскверненный эликсир силы"] = { 350, 365 },
		["Охранный эликсир"] = { 415, 430 },
		["Переменчивый алхимический камень претендента"] = { 470, 490 },
		["Переменчивый камень"] = { 340, 355 },
		["Поводья мутагенного исчадия"] = { 535, 545 },
		["Приводящее в сознание зелье"] = { 225, 265 },
		["Призрачная краска"] = { 260, 300 },
		["Простое зелье каменного щита"] = { 230, 270 },
		["Резонирующий алхимический камень"] = { 525, 535 },
		["Рунический флакон с зельем маны"] = { 415, 430 },
		["Рунический флакон с лечебным зельем"] = { 410, 425 },
		["Сильнодействующее зелье ярости"] = { 195, 235 },
		["Сильное зелье защиты от магии льда"] = { 305, 345 },
		["Сильное зелье защиты от огня"] = { 305, 345 },
		["Сильное зелье защиты от светлой магии"] = { 305, 345 },
		["Сильное зелье защиты от сил природы"] = { 305, 345 },
		["Сильное зелье защиты от тайной магии"] = { 305, 345 },
		["Сильное зелье защиты от темной магии"] = { 305, 345 },
		["Сильное зелье каменного щита"] = { 295, 335 },
		["Сильное зелье спокойного сна"] = { 290, 330 },
		["Сильный чародейский эликсир"] = { 300, 340 },
		["Сильный эликсир защиты"] = { 215, 255 },
		["Сильный эликсир интеллекта"] = { 250, 290 },
		["Сильный эликсир ловкости"] = { 255, 295 },
		["Сильный эликсир огневой мощи"] = { 265, 305 },
		["Сильный эликсир подводного дыхания"] = { 230, 270 },
		["Слабое зелье защиты от магии"] = { 135, 175 },
		["Слабое зелье неуязвимости"] = { 275, 315 },
		["Слабое зелье омоложения"] = { 70, 110 },
		["Слабое зелье тролльей крови"] = { 60, 100 },
		["Слабый настой крепости"] = { 380, 390 },
		["Слабый эликсир защиты"] = { 55, 95 },
		["Слабый эликсир ловкости"] = { 80, 120 },
		["Слабый эликсир меткости"] = { 160, 200 },
		["Слабый эликсир стойкости"] = { 80, 120 },
		["Средний флакон с зельем маны"] = { 220, 260 },
		["Средний флакон с лечебным зельем"] = { 175, 215 },
		["Трансмутация алмаза небесного сияния"] = { 440, 450 },
		["Трансмутация железа в золото"] = { 240, 280 },
		["Трансмутация мглистого алмаза"] = { 500, 510 },
		["Трансмутация мифрила в истинное серебро"] = { 240, 280 },
		["Трансмутация: Око Зула"] = { 440, 465 },
		["Трансмутация: александрит"] = { 465, 475 },
		["Трансмутация: алмаз землеправителя"] = { 435, 445 },
		["Трансмутация: алмаз земной бури"] = { 365, 380 },
		["Трансмутация: алмаз небесного огня"] = { 365, 380 },
		["Трансмутация: аметрин"] = { 440, 465 },
		["Трансмутация: арканит"] = { 275, 290 },
		["Трансмутация: багровый рубин"] = { 440, 465 },
		["Трансмутация: величественный циркон"] = { 440, 465 },
		["Трансмутация: вода в воздух"] = { 275, 290 },
		["Трансмутация: вода в нежить"] = { 275, 290 },
		["Трансмутация: воздух в огонь"] = { 275, 290 },
		["Трансмутация: врайкульский гранат"] = { 465, 475 },
		["Трансмутация: живые стихии"] = { 475, 485 },
		["Трансмутация: жизнь в землю"] = { 275, 290 },
		["Трансмутация: земля в воду"] = { 275, 290 },
		["Трансмутация: земля в жизнь"] = { 275, 290 },
		["Трансмутация: извечная вода в воздух"] = { 405, 425 },
		["Трансмутация: извечная вода в огонь"] = { 405, 425 },
		["Трансмутация: извечная жизнь в огонь"] = { 405, 425 },
		["Трансмутация: извечная жизнь в тьму"] = { 405, 425 },
		["Трансмутация: извечная земля в воздух"] = { 405, 425 },
		["Трансмутация: извечная земля в тьму"] = { 405, 425 },
		["Трансмутация: извечная сила"] = { 445, 460 },
		["Трансмутация: извечная тьма в жизнь"] = { 405, 425 },
		["Трансмутация: извечная тьма в землю"] = { 405, 425 },
		["Трансмутация: извечный воздух в воду"] = { 405, 425 },
		["Трансмутация: извечный воздух в землю"] = { 405, 425 },
		["Трансмутация: извечный огонь в воду"] = { 405, 425 },
		["Трансмутация: извечный огонь в жизнь"] = { 405, 425 },
		["Трансмутация: изначальная Тень в воду"] = { 375, 380 },
		["Трансмутация: изначальная мощь"] = { 365, 380 },
		["Трансмутация: изначальный алмаз"] = { 485, 495 },
		["Трансмутация: изначальный огонь в землю"] = { 365, 380 },
		["Трансмутация: изначальный огонь в ману"] = { 375, 380 },
		["Трансмутация: изумруд грез"] = { 475, 485 },
		["Трансмутация: инфернальный рубин"] = { 475, 485 },
		["Трансмутация: истинное золото"] = { 525, 535 },
		["Трансмутация: лазурит"] = { 465, 475 },
		["Трансмутация: морской сапфир"] = { 475, 485 },
		["Трансмутация: нежити в воду"] = { 275, 290 },
		["Трансмутация: огонь в землю"] = { 275, 290 },
		["Трансмутация: око демона"] = { 475, 485 },
		["Трансмутация: первичная вода в воздух"] = { 365, 380 },
		["Трансмутация: первичная вода в тьму"] = { 375, 380 },
		["Трансмутация: первичная жизнь в землю"] = { 375, 380 },
		["Трансмутация: первичная земля в воду"] = { 365, 380 },
		["Трансмутация: первичная земля в жизнь"] = { 375, 380 },
		["Трансмутация: первичная мана в огонь"] = { 375, 380 },
		["Трансмутация: первичный воздух в огонь"] = { 365, 380 },
		["Трансмутация: первородный огонь"] = { 301, 310 },
		["Трансмутация: плутовской камень"] = { 465, 475 },
		["Трансмутация: слиток колчедана"] = { 485, 495 },
		["Трансмутация: солнечный камень"] = { 465, 475 },
		["Трансмутация: страхолит"] = { 440, 465 },
		["Трансмутация: тигровый опал"] = { 465, 475 },
		["Трансмутация: титан"] = { 420, 440 },
		["Трансмутация: угасающий топаз"] = { 475, 485 },
		["Трансмутация: царский янтарь"] = { 440, 465 },
		["Трансмутация: янтарный самоцвет"] = { 475, 485 },
		["Философский камень"] = { 240, 280 },
		["Флакон с бесцветным лечебным зельем"] = { 80, 120 },
		["Флакон с бодрящим лечебным зельем"] = { 360, 380 },
		["Флакон с ледяным зельем маны"] = { 365, 385 },
		["Флакон с летучим лечебным зельем"] = { 315, 330 },
		["Флакон с нестойким зельем маны"] = { 325, 340 },
		["Чародейский эликсир"] = { 250, 290 },
		["Эликсир 'Зоркий глаз'"] = { 340, 355 },
		["Эликсир 'Кошачий глаз'"] = { 220, 260 },
		["Эликсир Защиты"] = { 155, 195 },
		["Эликсир адепта"] = { 315, 330 },
		["Эликсир азарта"] = { 500, 510 },
		["Эликсир безупречности"] = { 505, 515 },
		["Эликсир ведьмы"] = { 505, 515 },
		["Эликсир великанов"] = { 260, 300 },
		["Эликсир власти"] = { 330, 345 },
		["Эликсир вооружения"] = { 515, 525 },
		["Эликсир гнева"] = { 365, 385 },
		["Эликсир грубой силы"] = { 290, 330 },
		["Эликсир гуру"] = { 380, 390 },
		["Эликсир дренейской мудрости"] = { 335, 350 },
		["Эликсир духа"] = { 390, 400 },
		["Эликсир железной шкуры"] = { 345, 360 },
		["Эликсир земли"] = { 335, 350 },
		["Эликсир излечения"] = { 145, 185 },
		["Эликсир истребления демонов"] = { 265, 305 },
		["Эликсир крови волшебника"] = { 290, 330 },
		["Эликсир ловкости"] = { 205, 245 },
		["Эликсир львиной силы"] = { 55, 95 },
		["Эликсир мангуста"] = { 295, 335 },
		["Эликсир маскировки"] = { 320, 335 },
		["Эликсир мастерства"] = { 415, 430 },
		["Эликсир меткости"] = { 415, 430 },
		["Эликсир молниеносности"] = { 415, 430 },
		["Эликсир монаха"] = { 500, 510 },
		["Эликсир мудрецов"] = { 285, 325 },
		["Эликсир мудрости"] = { 120, 160 },
		["Эликсир наречий"] = { 100, 140 },
		["Эликсир наставника"] = { 515, 525 },
		["Эликсир натиска"] = { 315, 330 },
		["Эликсир обнаружения демонов"] = { 265, 305 },
		["Эликсир обнаружения нежити"] = { 245, 285 },
		["Эликсир обнаружения простой невидимости"] = { 215, 255 },
		["Эликсир огневой мощи"] = { 165, 205 },
		["Эликсир отражений"] = { 520, 530 },
		["Эликсир подавления"] = { 375, 380 },
		["Эликсир подводного дыхания"] = { 120, 160 },
		["Эликсир подземелий"] = { 505, 515 },
		["Эликсир пробивания брони"] = { 415, 430 },
		["Эликсир силы заклинаний"] = { 375, 390 },
		["Эликсир силы льда"] = { 210, 250 },
		["Эликсир силы огра"] = { 175, 215 },
		["Эликсир смертельных ударов"] = { 415, 430 },
		["Эликсир снозрения"] = { 255, 295 },
		["Эликсир спокойствия"] = { 520, 530 },
		["Эликсир стойкости"] = { 195, 235 },
		["Эликсир стремительности"] = { 510, 520 },
		["Эликсир увеличения"] = { 120, 160 },
		["Эликсир упорства"] = { 510, 520 },
		["Эликсир хождения по воде"] = { 415, 430 },
		["Эликсир целительной силы"] = { 325, 340 },
		["Эликсир энергии Тьмы"] = { 265, 305 },
		["Эфириальное масло"] = { 380, 390 },
	},
	[185] = {
		["'Кит и кот'"] = { 345, 365 },
		["'Пир на весь мир'"] = { 375, 425 },
		["Аппетитный кекс"] = { 350, 365 },
		["Артишоковый чай"] = { 100, 140 },
		["Батончик из мяса моллюска"] = { 320, 340 },
		["Блестящая рыбка"] = { 45, 85 },
		["Блюдо из двух рыб"] = { 465, 475 },
		["Большое освежающее угощение"] = { 535, 525 },
		["Большое угощение в горшочке"] = { 535, 525 },
		["Большое угощение вок"] = { 535, 525 },
		["Большое угощение из печи"] = { 535, 525 },
		["Большое угощение на гриле"] = { 535, 525 },
		["Большое угощение на пару"] = { 535, 525 },
		["Большой медвежий стейк"] = { 150, 190 },
		["Буреветчина"] = { 320, 340 },
		["Вареная клешня краба"] = { 125, 165 },
		["Вареная медуза"] = { 350, 415 },
		["Вареный луфарь"] = { 340, 360 },
		["Вареный северный подкаменщик"] = { 425, 475 },
		["Вареный солнечный лосось"] = { 275, 295 },
		["Вкусный шоколадный торт"] = { 50, 75 },
		["Волчатина на углях"] = { 45, 85 },
		["Волчатина с пряностями"] = { 50, 90 },
		["Гигантский жареный моллюск"] = { 215, 255 },
		["Гоголь-моголь"] = { 75, 115 },
		["Горячий яблочный сидр"] = { 325, 325 },
		["Гуляш по-красногорски"] = { 135, 175 },
		["Даларанская похлебка из моллюсков"] = { 350, 415 },
		["Даларанская похлебка из моллюсков со специями"] = { 500, 510 },
		["Дамайча"] = { 505, 515 },
		["Деликатес из бешенки"] = { 90, 130 },
		["Деликатес из змея"] = { 350, 415 },
		["Деликатес из шалфокуня"] = { 215, 255 },
		["Десерт из корня Рун-Тум"] = { 300, 325 },
		["Десерт из мертвечины"] = { 215, 255 },
		["Десерт из скорпида"] = { 60, 100 },
		["Домашний сыр из молока черпорога"] = { 520, 510 },
		["Жареная вырезка лунного оленя"] = { 45, 85 },
		["Жареная дичь"] = { 465, 475 },
		["Жареная ильница"] = { 340, 360 },
		["Жареная кабанина"] = { 45, 85 },
		["Жареная форель"] = { 375, 385 },
		["Жаренный на углях стейк из оленины"] = { 475, 485 },
		["Жареное крыло канюка"] = { 215, 255 },
		["Жареное мясо кодо"] = { 75, 115 },
		["Жареное мясо копытня"] = { 345, 365 },
		["Жареный ворг"] = { 350, 415 },
		["Жареный ящер"] = { 215, 255 },
		["Женьшеневый чай"] = { 485, 495 },
		["Завтрак безумца"] = { 470, 480 },
		["Завтрак следопыта"] = { 425, 475 },
		["Загадочная похлебка"] = { 215, 255 },
		["Загадочное острое лакомство"] = { 125, 165 },
		["Зажаренный на открытом огне афиохаракс"] = { 320, 340 },
		["Зажигательные химеровые отбивные Могиля"] = { 325, 350 },
		["Закуска из канюка"] = { 320, 340 },
		["Закуска из летучей мыши"] = { 90, 130 },
		["Закуска спорлингов"] = { 330, 350 },
		["Запеченная индейка"] = { 330, 355 },
		["Засахаренный батат"] = { 270, 295 },
		["Зеленый карри с рыбой"] = { 520, 510 },
		["Идеальная лапша быстрого приготовления"] = { 480, 490 },
		["Имбирное печенье"] = { 45, 85 },
		["Испорченные моллюски"] = { 350, 365 },
		["Кабаньи ребрышки в пиве"] = { 60, 100 },
		["Калдорайский шашлык из паука"] = { 50, 90 },
		["Кальмар-гриль"] = { 265, 290 },
		["Каменношкурая треска"] = { 190, 230 },
		["Карпаччо из ворга"] = { 350, 460 },
		["Кебаб из медвежатины на углях"] = { 275, 295 },
		["Клецки с раками-богомолами"] = { 500, 510 },
		["Клюквенный соус"] = { 210, 235 },
		["Консоме из золотистого карпа"] = { 470, 480 },
		["Копченая медвежатина"] = { 80, 120 },
		["Копченая форель"] = { 320, 340 },
		["Копченые пустынные клецки"] = { 310, 335 },
		["Копченый василиск"] = { 335, 355 },
		["Копченый камнеперый окунь"] = { 350, 380 },
		["Копченый лосось"] = { 350, 415 },
		["Копченый спороус"] = { 330, 350 },
		["Копченый шалфокунь"] = { 120, 160 },
		["Корм для зверька"] = { 425, 475 },
		["Костечешуйный луциан - гриль"] = { 350, 380 },
		["Котлета из змея с пряностями"] = { 425, 475 },
		["Котлета из прыгуаны"] = { 345, 365 },
		["Крабовый сюрприз на пару"] = { 520, 510 },
		["Кровяная колбаса"] = { 100, 140 },
		["Кунгалуш"] = { 375, 400 },
		["Курица с арахисом на вертеле"] = { 475, 485 },
		["Кушанье из мамонта"] = { 350, 415 },
		["Лакомство из сквернохвоста"] = { 320, 340 },
		["Лосось духов огня"] = { 530, 520 },
		["Лосось с дымком"] = { 425, 475 },
		["Луциан особого приготовления"] = { 425, 475 },
		["Луциан особого приготовления с приправами"] = { 500, 510 },
		["Люторожий змеестейк"] = { 425, 475 },
		["Люторожий змеестейк с приправами"] = { 500, 510 },
		["Мамонтятина не первой свежести"] = { 350, 365 },
		["Маринованная клыкозубая сельдь"] = { 350, 415 },
		["Медуза с приправами"] = { 500, 510 },
		["Мидии по-гоблински"] = { 165, 205 },
		["Мифрилоголовая форель"] = { 215, 255 },
		["Мощь-рыба в кляре"] = { 250, 275 },
		["Мясо в соусе 'Дыхание дракона'"] = { 225, 250 },
		["Невероятно вкусный омлет"] = { 170, 210 },
		["Невероятные мидии"] = { 250, 300 },
		["Нежный стейк из волчатины"] = { 250, 275 },
		["Нежный стейк из черпорога"] = { 425, 475 },
		["Нежный черепаховый суп"] = { 215, 255 },
		["Окунь горячего копчения"] = { 265, 290 },
		["Освежающее угощение"] = { 520, 510 },
		["Острая волчья грудинка"] = { 215, 255 },
		["Острая жареная сельдь"] = { 425, 475 },
		["Острая отбивная из мяса льва"] = { 175, 215 },
		["Острое крабовое чили"] = { 250, 275 },
		["Острозубый илистый луциан"] = { 90, 130 },
		["Острые овощные чипсы"] = { 520, 510 },
		["Острый стейк из талбука"] = { 335, 355 },
		["Отвар нефритовой ведьмы"] = { 520, 510 },
		["Отварная куколка шелкопряда"] = { 520, 510 },
		["Отварные мидии"] = { 90, 130 },
		["Ощетиненная зубатка"] = { 140, 180 },
		["Палочки из золотой рыбки"] = { 345, 365 },
		["Пассерованная морковь"] = { 495, 505 },
		["Паучья колбаска"] = { 225, 250 },
		["Пережаренное мясо ворга"] = { 425, 475 },
		["Печеный лосось"] = { 300, 325 },
		["Печеный морской дьявол"] = { 350, 415 },
		["Пиво индивидуальных ощущений"] = { 530, 520 },
		["Пикантный йогурт"] = { 520, 510 },
		["Пир для великанов"] = { 435, 475 },
		["Пир для карликов"] = { 435, 475 },
		["Пирожок из паучатины"] = { 150, 190 },
		["Пирожок из печени кровоклыка"] = { 90, 130 },
		["Пирожок с красной фасолью"] = { 485, 475 },
		["Пирожок с мясом краба"] = { 115, 155 },
		["Поджаристый змей"] = { 355, 375 },
		["Подкаменщик-гриль"] = { 350, 415 },
		["Подкопченная дракоперая рыба-ангел"] = { 425, 475 },
		["Подкопченная дракоперая рыба-ангел с приправами"] = { 500, 510 },
		["Подкопченный лосось со специями"] = { 500, 510 },
		["Подкопченный стейк из ворга"] = { 425, 475 },
		["Подрумяненная соленая рыба"] = { 495, 505 },
		["Поминальный хлеб"] = { 30, 40 },
		["Постная оленина"] = { 150, 190 },
		["Постный стейк из волчатины"] = { 165, 205 },
		["Похлебка 'Джунгли'"] = { 215, 255 },
		["Похлебка Западного Края"] = { 115, 155 },
		["Похлебка из долгонога"] = { 90, 130 },
		["Похлебка из моллюсков"] = { 130, 170 },
		["Похлебка из омаров"] = { 300, 325 },
		["Похлебка из пещерной крысы"] = { 130, 170 },
		["Приправленная котлета из волчатины"] = { 140, 180 },
		["Пряная хлебная запеканка"] = { 90, 115 },
		["Пряное лакомство из мамонта"] = { 425, 475 },
		["Пряное лакомство из мамонта c приправами"] = { 500, 510 },
		["Пятнистый желтохвост"] = { 250, 275 },
		["Радужный тунец"] = { 90, 130 },
		["Разрезанные персики"] = { 460, 470 },
		["Рак с пряностями"] = { 370, 380 },
		["Ребрышки Мок'Натала"] = { 355, 375 },
		["Ребрышки с черным перцем и раками"] = { 530, 520 },
		["Рисовая лапша морских туманов"] = { 520, 510 },
		["Рисовый пудинг"] = { 520, 510 },
		["Рыба по-дольски"] = { 525, 515 },
		["Рыбацкая услада"] = { 375, 385 },
		["Рыбный пир"] = { 455, 465 },
		["Рыбный пир со специями"] = { 500, 510 },
		["Рыбный пирог"] = { 460, 470 },
		["Светлое пиво капитана Ромси"] = { 100, 110 },
		["Северная похлебка"] = { 350, 380 },
		["Синяя медуза с пряностями"] = { 425, 475 },
		["Скользкокожая скумбрия"] = { 45, 85 },
		["Сосиска из мяса опустошителя"] = { 320, 340 },
		["Сосиски из люторога"] = { 350, 415 },
		["Соте из бычков"] = { 350, 380 },
		["Сочная котлета из медвежатины"] = { 275, 295 },
		["Сочное мясо люторога"] = { 425, 475 },
		["Сочное мясо люторога со специями"] = { 500, 510 },
		["Сочные свиные ребрышки"] = { 130, 170 },
		["Сочные сосиски из люторога"] = { 425, 475 },
		["Сочные сосиски из люторога с приправами"] = { 500, 510 },
		["Сочный стейк из мяса льва"] = { 190, 230 },
		["Стейк из каракатицы"] = { 425, 475 },
		["Стейк из каракатицы с приправами"] = { 500, 510 },
		["Стейк из койота"] = { 90, 130 },
		["Стейк из королевского ската"] = { 425, 475 },
		["Стейк из королевского ската со специями"] = { 500, 510 },
		["Стейк из кроколиска"] = { 120, 160 },
		["Стейк из мощь-рыбы"] = { 300, 325 },
		["Стейк из рысятины"] = { 45, 85 },
		["Стейк из талбука"] = { 345, 365 },
		["Стейк из черпорога"] = { 350, 415 },
		["Стир-фрай долины"] = { 520, 510 },
		["Суп из дичи с женьшенем"] = { 520, 510 },
		["Суп из клубящегося тумана"] = { 505, 515 },
		["Суп из кроколиска"] = { 160, 200 },
		["Суп из ночного луциана"] = { 275, 295 },
		["Суп из плавников мурлока"] = { 130, 170 },
		["Суп из рыбы-черепа"] = { 335, 355 },
		["Суп из шустрого краба"] = { 505, 515 },
		["Сушеные опята"] = { 490, 500 },
		["Сушеные персики"] = { 520, 510 },
		["Сушеные свиные ребрышки"] = { 120, 160 },
		["Сытная похлебка из кодо"] = { 225, 250 },
		["Сытная похлебка из кроколиска"] = { 160, 200 },
		["Сытное кушанье из мамонта"] = { 425, 475 },
		["Сытное кушанье из мамонта с приправами"] = { 500, 510 },
		["Торт из молотого риса"] = { 500, 510 },
		["Тушеная форель"] = { 335, 355 },
		["Тушеное волчье мясо"] = { 520, 510 },
		["Тыквенный пирог"] = { 150, 175 },
		["Угощение в горшочке"] = { 520, 510 },
		["Угощение вок"] = { 520, 510 },
		["Угощение из печи"] = { 520, 510 },
		["Угощение на гриле"] = { 520, 510 },
		["Угощение на пару"] = { 520, 510 },
		["Филе бешенки"] = { 90, 130 },
		["Филе дракоперой рыбы-ангела"] = { 425, 475 },
		["Филе дракоперой рыбы-ангела с приправами"] = { 500, 510 },
		["Филе краснобородки"] = { 250, 275 },
		["Хаустлундские фриттеры"] = { 485, 495 },
		["Хлеб с пряностями"] = { 30, 40 },
		["Хрустящее крылышко летучей мыши"] = { 45, 85 },
		["Хрустящий паучий десерт"] = { 100, 140 },
		["Хрустящий хвост ящерицы"] = { 140, 180 },
		["Чай из златошипа"] = { 175, 205 },
		["Чай с перламутровым молоком"] = { 520, 510 },
		["Черный студень"] = { 400, 425 },
		["Черный студень с приправами"] = { 500, 510 },
		["Чудовищный омлет"] = { 250, 275 },
		["Шахтерская похлебка из моллюсков"] = { 250, 275 },
		["Эфемерная селедка"] = { 350, 365 },
		["Яйцо с травами"] = { 45, 85 },
	},
	[186] = {
		["Выплавка адамантита"] = { 325, 340 },
		["Выплавка бронзы"] = { 65, 115 },
		["Выплавка железа"] = { 130, 160 },
		["Выплавка закаленного адамантита"] = { 375, 375 },
		["Выплавка закаленного кория"] = { 375, 375 },
		["Выплавка закаленного элементия"] = { 515, 540 },
		["Выплавка золота"] = { 170, 185 },
		["Выплавка истинного серебра"] = { 250, 290 },
		["Выплавка кобальта"] = { 350, 375 },
		["Выплавка колчедана"] = { 515, 540 },
		["Выплавка кория"] = { 375, 375 },
		["Выплавка меди"] = { 25, 70 },
		["Выплавка мифрила"] = { 175, 230 },
		["Выплавка обсидиана"] = { 470, 495 },
		["Выплавка олова"] = { 65, 75 },
		["Выплавка оскверненного железа"] = { 275, 325 },
		["Выплавка оскверненной стали"] = { 340, 375 },
		["Выплавка саронита"] = { 400, 400 },
		["Выплавка серебра"] = { 115, 130 },
		["Выплавка стали"] = { 165, 165 },
		["Выплавка титана"] = { 450, 450 },
		["Выплавка титановой стали"] = { 450, 450 },
		["Выплавка тория"] = { 250, 290 },
		["Выплавка черного железа"] = { 300, 310 },
		["Выплавка этерния"] = { 350, 365 },
		["Зачарованный торий"] = { 250, 260 },
		["Разложение огня"] = { 300, 300 },
		["Расщепление земли"] = { 300, 300 },
	},
	[197] = {
		["Адмиральская шляпа"] = { 255, 285 },
		["Багровое шелковое одеяние"] = { 220, 250 },
		["Багровые шелковые кюлоты"] = { 215, 235 },
		["Багровые шелковые наплечники"] = { 210, 240 },
		["Багровые шелковые перчатки"] = { 225, 255 },
		["Багровый шелковый жилет"] = { 205, 225 },
		["Багровый шелковый плащ"] = { 200, 230 },
		["Багровый шелковый пояс"] = { 195, 225 },
		["Бездонная сумка"] = { 315, 345 },
		["Белая бандитская маска"] = { 220, 230 },
		["Белая лечебная накидка"] = { 360, 370 },
		["Белая льняная рубашка"] = { 35, 60 },
		["Белая рубашка сорвиголовы"] = { 170, 180 },
		["Белое льняное одеяние"] = { 55, 90 },
		["Белое свадебное платье"] = { 255, 265 },
		["Белое шерстяное платье"] = { 135, 170 },
		["Благословенные полуперчатки Света"] = { 430, 450 },
		["Большая зачарованная сумка"] = { 315, 345 },
		["Большее одеяние адепта"] = { 140, 175 },
		["Ботаническая сумка Микаа"] = { 385, 395 },
		["Броня огров Гордока"] = { 285, 295 },
		["Брюки под смокинг"] = { 250, 260 },
		["Варварский льняной жилет"] = { 95, 130 },
		["Великая лазурная чародейская нить"] = { 515, 525 },
		["Великая перламутровая чародейская нить"] = { 515, 525 },
		["Великолепный ковер-самолет"] = { 435, 455 },
		["Венец из луноткани"] = { 315, 345 },
		["Венец из ткани Грез"] = { 265, 295 },
		["Вышивка в виде рукояти меча"] = { 400, 405 },
		["Вышивка темного сияния"] = { 400, 405 },
		["Головная повязка из рунической ткани"] = { 310, 340 },
		["Головная повязка из штормовой ткани"] = { 255, 285 },
		["Грубая рубашка рабочего"] = { 400, 410 },
		["Длинный шелковый плащ"] = { 205, 235 },
		["Желтая рубашка дровосека"] = { 400, 410 },
		["Жилет Земли"] = { 190, 220 },
		["Жилет из луноткани"] = { 315, 345 },
		["Жилет из пепельной ткани"] = { 275, 305 },
		["Жилет из призрачной ткани"] = { 290, 320 },
		["Жилет из ткани Грез"] = { 240, 270 },
		["Жилет из ткани Душ"] = { 380, 385 },
		["Жилет из штормовой ткани"] = { 240, 270 },
		["Жилет кровавой лозы"] = { 315, 345 },
		["Жилет пламенного сердца"] = { 380, 390 },
		["Заиндевевший ковер-самолет"] = { 435, 455 },
		["Застывшее тенетканое одеяние"] = { 385, 395 },
		["Застывшие тенетканые наплечники"] = { 365, 375 },
		["Застывшие тенетканые сапоги"] = { 375, 385 },
		["Зачарованная сумка из рунической ткани"] = { 290, 320 },
		["Зачарованный мешочек из магической ткани"] = { 240, 270 },
		["Звездный пояс"] = { 220, 250 },
		["Зеленая выходная рубашка"] = { 200, 210 },
		["Зеленая льняная рубашка"] = { 95, 130 },
		["Зеленая рубашка дровосека"] = { 400, 410 },
		["Зеленая рубашка рабочего"] = { 400, 410 },
		["Зеленая шелковая броня"] = { 185, 215 },
		["Зеленая шелковая сума"] = { 195, 225 },
		["Зеленая шерстяная сумка"] = { 120, 155 },
		["Зеленое шерстяное одеяние"] = { 115, 150 },
		["Зеленые зимние одежды"] = { 250, 250 },
		["Зеленые льняные наручи"] = { 85, 120 },
		["Зеленые шелковые наплечники"] = { 200, 230 },
		["Зеленый шерстяной жилет"] = { 110, 145 },
		["Золотая чародейская нить"] = { 385, 395 },
		["Изначальная луноткань"] = { 350, 360 },
		["Изумрудный вьюк"] = { 440, 450 },
		["Императорский шелк"] = { 470, 485 },
		["Инфернальные перчатки"] = { 315, 345 },
		["Искусно изготовленная накидка борца со смертью"] = { 510, 520 },
		["Искусно изготовленная накидка ткача таинств"] = { 510, 520 },
		["Искусно изготовленная пелерина сотворителя жизни"] = { 510, 520 },
		["Искусно изготовленное лунношелковое одеяние"] = { 510, 520 },
		["Искусно изготовленное смертошелковое одеяние"] = { 510, 520 },
		["Искусно изготовленные лунношелковые наплечники"] = { 515, 525 },
		["Искусно изготовленные лунношелковые наручи"] = { 495, 505 },
		["Искусно изготовленные лунношелковые перчатки"] = { 505, 515 },
		["Искусно изготовленные лунношелковые поножи"] = { 510, 520 },
		["Искусно изготовленные лунношелковые туфли"] = { 505, 515 },
		["Искусно изготовленные смертошелковые наплечники"] = { 515, 525 },
		["Искусно изготовленные смертошелковые наручи"] = { 495, 505 },
		["Искусно изготовленные смертошелковые перчатки"] = { 505, 515 },
		["Искусно изготовленные смертошелковые поножи"] = { 510, 520 },
		["Искусно изготовленные смертошелковые туфли"] = { 505, 515 },
		["Искусно изготовленный лунношелковый клобук"] = { 500, 510 },
		["Искусно изготовленный лунношелковый пояс"] = { 495, 505 },
		["Искусно изготовленный плащ защитника пределов"] = { 510, 520 },
		["Искусно изготовленный смертошелковый клобук"] = { 500, 510 },
		["Искусно изготовленный смертошелковый пояс"] = { 495, 505 },
		["Иссиня-черная ткань"] = { 425, 435 },
		["Иссиня-черное одеяние"] = { 450, 460 },
		["Иссиня-черные перчатки"] = { 445, 455 },
		["Капюшон белого целителя"] = { 385, 395 },
		["Капюшон боевого заклятья"] = { 385, 395 },
		["Капюшон из ткани Скверны"] = { 305, 335 },
		["Капюшон сокрушительной магии"] = { 385, 395 },
		["Кенарийская сумка для трав"] = { 290, 320 },
		["Клобук волшебника"] = { 185, 215 },
		["Клобук из сумеречной ткани"] = { 405, 415 },
		["Клобук ледяной ярости"] = { 430, 450 },
		["Клобук ледяной ярости претендента"] = { 470, 490 },
		["Ковер-самолет"] = { 340, 350 },
		["Ковер-самолет древней знати"] = { 535, 545 },
		["Колдовская ткань"] = { 425, 435 },
		["Коричневая льняная рубашка"] = { 35, 60 },
		["Коричневое льняное одеяние"] = { 55, 90 },
		["Коричневые льняные штаны"] = { 55, 90 },
		["Коричневый льняной жилет"] = { 45, 70 },
		["Королевские наручи из лунного тюля"] = { 460, 475 },
		["Королевское одеяние из лунного тюля"] = { 460, 475 },
		["Краги Тьмы"] = { 165, 195 },
		["Красная головная повязка из магической ткани"] = { 255, 285 },
		["Красная льняная рубашка"] = { 65, 100 },
		["Красная льняная сумка"] = { 95, 130 },
		["Красная рубашка дровосека"] = { 400, 410 },
		["Красная рубашка рабочего"] = { 400, 410 },
		["Красная рубашка сорвиголовы"] = { 185, 195 },
		["Красная сумка из магической ткани"] = { 250, 280 },
		["Красная шерстяная сумка"] = { 140, 175 },
		["Красное льняное одеяние"] = { 65, 100 },
		["Красные зимние одежды"] = { 250, 250 },
		["Красные наплечники из магической ткани"] = { 250, 280 },
		["Красные перчатки из магической ткани"] = { 240, 270 },
		["Красные шерстяные сапоги"] = { 120, 155 },
		["Красные штаны из магической ткани"] = { 230, 260 },
		["Красный жилет из магической ткани"] = { 230, 260 },
		["Красный льняной жилет"] = { 80, 115 },
		["Куртка Халискана"] = { 265, 295 },
		["Куртка-смокинг"] = { 265, 295 },
		["Кушак древней силы"] = { 455, 465 },
		["Кюлоты Халискана"] = { 250, 260 },
		["Лазурные наплечники"] = { 210, 240 },
		["Лазурные шелковые перчатки"] = { 165, 195 },
		["Лазурные шелковые штаны"] = { 160, 190 },
		["Лазурный шелковый жилет"] = { 170, 200 },
		["Лазурный шелковый капюшон"] = { 155, 165 },
		["Лазурный шелковый плащ"] = { 195, 225 },
		["Лазурный шелковый пояс"] = { 195, 225 },
		["Ледовая сумка"] = { 450, 460 },
		["Ледовое одеяние"] = { 435, 455 },
		["Ледовые накулачники"] = { 315, 345 },
		["Ледовые перчатки"] = { 315, 345 },
		["Ледовые туфли"] = { 430, 450 },
		["Ледовый боевой пояс"] = { 430, 450 },
		["Ледовый жилет"] = { 315, 345 },
		["Ледовый плащ"] = { 315, 345 },
		["Ледовый шнурованный ремень"] = { 430, 450 },
		["Ледотканое одеяние"] = { 370, 390 },
		["Ледотканые наплечники"] = { 360, 380 },
		["Ледотканые напульсники"] = { 360, 380 },
		["Ледотканые перчатки"] = { 370, 390 },
		["Ледотканые поножи"] = { 390, 410 },
		["Ледотканые сапоги"] = { 385, 405 },
		["Ледотканый пояс"] = { 380, 400 },
		["Ледотканый шлем"] = { 390, 410 },
		["Ледяной плащ"] = { 220, 250 },
		["Лесная корона"] = { 315, 345 },
		["Лесной жилет"] = { 315, 345 },
		["Лесные наплечники"] = { 315, 345 },
		["Летний пояс мага-новичка"] = { 475, 500 },
		["Лиловая рубашка из магической ткани"] = { 235, 245 },
		["Лунношелковое одеяние"] = { 485, 495 },
		["Лунношелковые наплечники"] = { 490, 500 },
		["Лунношелковые наручи"] = { 470, 480 },
		["Лунношелковые перчатки"] = { 480, 490 },
		["Лунношелковые поножи"] = { 485, 495 },
		["Лунношелковые туфли"] = { 480, 490 },
		["Лунношелковый вышитый талисман"] = { 520, 530 },
		["Лунношелковый клобук"] = { 475, 485 },
		["Лунношелковый пояс"] = { 470, 480 },
		["Лунный тюль"] = { 425, 435 },
		["Луноткань"] = { 290, 320 },
		["Льняная сумка"] = { 70, 105 },
		["Льняной плащ"] = { 35, 60 },
		["Льняной пояс"] = { 50, 85 },
		["Льняные сапоги"] = { 90, 125 },
		["Льняные сапоги с мягкой подошвой"] = { 105, 140 },
		["Маленькая шелковая сумка"] = { 170, 200 },
		["Мантия быстрого исцеления"] = { 385, 395 },
		["Мантия сообразительности"] = { 385, 395 },
		["Мешочек для драгоценностей"] = { 350, 360 },
		["Мистические ледотканые наплечники"] = { 395, 415 },
		["Мистические ледотканые напульсники"] = { 395, 415 },
		["Мистическое ледотканое одеяние"] = { 400, 420 },
		["Многоцветный килт"] = { 145, 180 },
		["Мудрость Древобрюхов"] = { 305, 335 },
		["Мундир из ледяной ткани"] = { 270, 300 },
		["Мундир из прочной ткани Пустоты"] = { 370, 380 },
		["Мундир из рунической ткани"] = { 275, 305 },
		["Мундир из ткани Пустоты"] = { 355, 365 },
		["Накидка борца со смертью"] = { 470, 480 },
		["Накидка твердости"] = { 375, 385 },
		["Накидка ткача таинств"] = { 470, 480 },
		["Наплечники из изначальной луноткани"] = { 375, 385 },
		["Наплечники из луноткани"] = { 315, 345 },
		["Наплечники из рунической ткани"] = { 315, 345 },
		["Наплечники из сумеречной ткани"] = { 420, 430 },
		["Наплечники из ткани Душ"] = { 375, 385 },
		["Наплечники из ткани Скверны"] = { 315, 345 },
		["Наплечники из штормовой ткани"] = { 260, 290 },
		["Наплечники ледяной ярости"] = { 430, 450 },
		["Наплечники ледяной ярости претендента"] = { 470, 490 },
		["Напульсники из сумеречной ткани"] = { 410, 420 },
		["Напульсники пламенных недр"] = { 320, 350 },
		["Наручи Разора"] = { 360, 370 },
		["Наручи Черного удара"] = { 360, 370 },
		["Наручи волшебника с самоцветами"] = { 460, 475 },
		["Наручи жизненной силы"] = { 365, 375 },
		["Наручи из тайной ткани"] = { 360, 370 },
		["Наручи из ткани Пустоты"] = { 320, 330 },
		["Наручи ледяной ярости"] = { 425, 445 },
		["Наручи ледяной ярости претендента"] = { 470, 490 },
		["Наручи непреклонности"] = { 360, 370 },
		["Наручи пламенного сердца"] = { 360, 370 },
		["Наручи сообразительности"] = { 385, 395 },
		["Наручи стража духа"] = { 385, 395 },
		["Облачение Геи"] = { 315, 345 },
		["Одежды истинной веры"] = { 315, 345 },
		["Одеяние Бездны"] = { 315, 345 },
		["Одеяние Мерлина"] = { 460, 475 },
		["Одеяние Солнечного огня"] = { 375, 410 },
		["Одеяние верховного мага"] = { 315, 345 },
		["Одеяние вечного света"] = { 375, 410 },
		["Одеяние зимней ночи"] = { 300, 330 },
		["Одеяние из изначальной луноткани"] = { 385, 395 },
		["Одеяние из колдовской ткани"] = { 450, 460 },
		["Одеяние из ледяной ткани"] = { 270, 300 },
		["Одеяние из лунного тюля"] = { 450, 460 },
		["Одеяние из луноткани"] = { 315, 345 },
		["Одеяние из огненной чароткани"] = { 385, 395 },
		["Одеяние из пепельной ткани"] = { 240, 270 },
		["Одеяние из прочной ткани Пустоты"] = { 370, 380 },
		["Одеяние из рунической ткани"] = { 275, 305 },
		["Одеяние из сумеречной ткани"] = { 415, 425 },
		["Одеяние из тайной ткани"] = { 380, 390 },
		["Одеяние из ткани Пустоты"] = { 350, 360 },
		["Одеяние из ткани Скверны"] = { 315, 345 },
		["Одеяние из чародейской ткани"] = { 315, 345 },
		["Одеяние из яркой ткани"] = { 285, 315 },
		["Одеяние ледяной ярости"] = { 430, 450 },
		["Одеяние ледяной ярости претендента"] = { 470, 490 },
		["Одеяние могущества"] = { 210, 240 },
		["Одеяние пламени Пустоты"] = { 365, 375 },
		["Одеяние пламенных недр"] = { 315, 345 },
		["Одеяния Тайны"] = { 170, 200 },
		["Оплечье Древобрюхов"] = { 315, 345 },
		["Оплечье пламенных недр"] = { 315, 345 },
		["Оранжевая воинская рубашка"] = { 225, 235 },
		["Оранжевая рубашка из магической ткани"] = { 220, 230 },
		["Освященная чародейская нить"] = { 405, 405 },
		["Парадные ботинки"] = { 255, 285 },
		["Паучий пояс"] = { 200, 230 },
		["Пелерина из паучьего шелка"] = { 150, 185 },
		["Пелерина ледяного стража"] = { 405, 415 },
		["Пелерина сотворителя жизни"] = { 470, 480 },
		["Перламутровая чародейская нить"] = { 510, 520 },
		["Перчатки Медитации"] = { 150, 180 },
		["Перчатки Феникса"] = { 150, 185 },
		["Перчатки вечного света"] = { 375, 410 },
		["Перчатки волшебства"] = { 315, 345 },
		["Перчатки из колдовской ткани"] = { 445, 455 },
		["Перчатки из ледяной ткани"] = { 280, 310 },
		["Перчатки из лунного тюля"] = { 445, 455 },
		["Перчатки из луноткани"] = { 315, 345 },
		["Перчатки из огненной чароткани"] = { 375, 385 },
		["Перчатки из пепельной ткани"] = { 285, 315 },
		["Перчатки из призрачной ткани"] = { 285, 315 },
		["Перчатки из рунической ткани"] = { 290, 320 },
		["Перчатки из сумеречной ткани"] = { 415, 425 },
		["Перчатки из ткани Грез"] = { 240, 270 },
		["Перчатки из ткани Душ"] = { 365, 375 },
		["Перчатки из ткани Пустоты"] = { 330, 340 },
		["Перчатки из ткани Скверны"] = { 315, 345 },
		["Перчатки из штормовой ткани"] = { 235, 265 },
		["Перчатки из яркой ткани"] = { 285, 315 },
		["Перчатки истинной веры"] = { 170, 200 },
		["Перчатки ледяной ярости"] = { 430, 450 },
		["Перчатки ледяной ярости претендента"] = { 470, 490 },
		["Перчатки пламенного сердца"] = { 370, 380 },
		["Перчатки пламенных недр"] = { 315, 345 },
		["Песня жизни"] = { 510, 520 },
		["Плащ багрового снега"] = { 410, 420 },
		["Плащ вечности"] = { 360, 370 },
		["Плащ заледеневших душ"] = { 400, 410 },
		["Плащ защитника пределов"] = { 470, 480 },
		["Плащ защиты от чар"] = { 360, 370 },
		["Плащ из пепельной ткани"] = { 290, 320 },
		["Плащ из рунической ткани"] = { 280, 310 },
		["Плащ из ткани маны"] = { 375, 385 },
		["Плащ из яркой ткани"] = { 290, 320 },
		["Плащ луны"] = { 395, 405 },
		["Плащ огня"] = { 290, 320 },
		["Плащ отмщения"] = { 375, 385 },
		["Плащ с перламутровыми застежками"] = { 115, 150 },
		["Плащ смертельной стужи"] = { 435, 455 },
		["Плащ стражи"] = { 315, 345 },
		["Плащ черной бездны"] = { 360, 370 },
		["Повязки быстрого исцеления"] = { 385, 395 },
		["Повязки солнечного огня"] = { 375, 410 },
		["Покров силы магии из ветроткани"] = { 475, 500 },
		["Поножи жизненной силы"] = { 365, 375 },
		["Поножи из луноткани"] = { 305, 335 },
		["Поножи из сумеречной ткани"] = { 405, 415 },
		["Поножи из чародейской ткани"] = { 290, 320 },
		["Поножи кровавой лозы"] = { 315, 345 },
		["Поножи ледяной ярости"] = { 430, 450 },
		["Поножи ледяной ярости претендента"] = { 470, 490 },
		["Поножи паутины смерти"] = { 475, 500 },
		["Поножи пламенных недр"] = { 315, 345 },
		["Поножи стража духа"] = { 385, 395 },
		["Пояс верховного мага"] = { 315, 345 },
		["Пояс взрыва"] = { 385, 395 },
		["Пояс дальней дороги"] = { 385, 395 },
		["Пояс жизненной силы"] = { 365, 375 },
		["Пояс из изначальной луноткани"] = { 365, 375 },
		["Пояс из огненной чароткани"] = { 365, 375 },
		["Пояс из призрачной ткани"] = { 280, 310 },
		["Пояс из рунической ткани"] = { 270, 300 },
		["Пояс из сумеречной ткани"] = { 400, 410 },
		["Пояс из ткани Пустоты"] = { 320, 330 },
		["Пояс ледяной ярости"] = { 425, 445 },
		["Пояс ледяной ярости претендента"] = { 470, 490 },
		["Пояс пламени Пустоты"] = { 365, 375 },
		["Праздничное платье"] = { 265, 295 },
		["Праздничный красный костюм"] = { 265, 295 },
		["Предел ночи"] = { 385, 395 },
		["Простое одеяние волшебника"] = { 155, 185 },
		["Простое платье"] = { 65, 100 },
		["Простое черное платье"] = { 240, 250 },
		["Простой килт"] = { 100, 135 },
		["Простые льняные сапоги"] = { 50, 85 },
		["Простые льняные штаны"] = { 35, 60 },
		["Прочная сапфировая чародейская нить"] = { 500, 510 },
		["Прочная сверкающая чародейская нить"] = { 500, 510 },
		["Реликвия прошлого: Портняжное дело"] = { 525, 535 },
		["Ремень Непреклонности"] = { 375, 385 },
		["Ремень опустошения"] = { 375, 385 },
		["Ремень стража духа"] = { 385, 395 },
		["Розовая рубашка из магической ткани"] = { 240, 250 },
		["Роскошная лиловая шелковая рубашка"] = { 195, 205 },
		["Рубашка под смокинг"] = { 245, 255 },
		["Рукодельные льняные брюки"] = { 95, 130 },
		["Рулон ветрошерстной ткани"] = { 460, 475 },
		["Рулон ледяной ткани"] = { 370, 375 },
		["Рулон льняной ткани"] = { 25, 50 },
		["Рулон магической ткани"] = { 180, 185 },
		["Рулон прочной ледяной ткани"] = { 400, 405 },
		["Рулон прочной ткани Пустоты"] = { 330, 340 },
		["Рулон рунической ткани"] = { 255, 260 },
		["Рулон ткани Душ"] = { 345, 355 },
		["Рулон ткани Пустоты"] = { 305, 325 },
		["Рулон шелка"] = { 135, 145 },
		["Рулон шерсти"] = { 90, 105 },
		["Руническая чародейская нить"] = { 385, 395 },
		["Рунические стигийские поножи"] = { 315, 345 },
		["Рунические стигийские сапоги"] = { 315, 345 },
		["Рунический стигийский пояс"] = { 315, 345 },
		["Сандалии освящения"] = { 475, 500 },
		["Сапоги Тьмы"] = { 160, 190 },
		["Сапоги взрыва"] = { 385, 395 },
		["Сапоги дальней дороги"] = { 385, 395 },
		["Сапоги заклинателя"] = { 195, 225 },
		["Сапоги из луноткани"] = { 295, 325 },
		["Сапоги из паучьего шелка"] = { 150, 185 },
		["Сапоги из пепельной ткани"] = { 260, 290 },
		["Сапоги из прочной ткани Пустоты"] = { 360, 370 },
		["Сапоги из рунической ткани"] = { 295, 325 },
		["Сапоги из тайной ткани"] = { 370, 380 },
		["Сапоги из ткани Пустоты"] = { 345, 355 },
		["Сапоги из ткани Скверны"] = { 300, 330 },
		["Сапоги из штормовой ткани"] = { 265, 295 },
		["Сапоги кровавой лозы"] = { 315, 345 },
		["Сапоги ледяной ярости"] = { 430, 450 },
		["Сапоги ледяной ярости претендента"] = { 470, 490 },
		["Сапоги пламени Пустоты"] = { 365, 375 },
		["Сапоги смертной стужи"] = { 475, 500 },
		["Сапфировая чародейская нить"] = { 435, 445 },
		["Сверкающая чародейская нить"] = { 435, 445 },
		["Светлотканая вышивка"] = { 400, 405 },
		["Светлотканые поножи"] = { 475, 500 },
		["Серая шерстяная рубашка"] = { 110, 130 },
		["Серебристые наплечники"] = { 315, 345 },
		["Серебристые сапоги"] = { 305, 335 },
		["Серебряная чародейская нить"] = { 345, 355 },
		["Серое шерстяное одеяние"] = { 130, 165 },
		["Сеть из ледяной ткани"] = { 370, 380 },
		["Сеть из ткани Пустоты"] = { 300, 320 },
		["Синее льняное одеяние"] = { 95, 130 },
		["Синий комбинезон"] = { 125, 160 },
		["Синий льняной жилет"] = { 80, 115 },
		["Синяя льняная рубашка"] = { 65, 100 },
		["Синяя рубашка дровосека"] = { 400, 410 },
		["Синяя рубашка рабочего"] = { 400, 410 },
		["Сияющая чародейская нить"] = { 400, 410 },
		["Смертошелковое одеяние"] = { 485, 495 },
		["Смертошелковые вышитый талисман"] = { 520, 530 },
		["Смертошелковые наплечники"] = { 490, 500 },
		["Смертошелковые наручи"] = { 470, 480 },
		["Смертошелковые перчатки"] = { 480, 490 },
		["Смертошелковые поножи"] = { 485, 495 },
		["Смертошелковые туфли"] = { 480, 490 },
		["Смертошелковый клобук"] = { 475, 485 },
		["Смертошелковый пояс"] = { 470, 480 },
		["Старообрядческий пояс из шелка"] = { 475, 500 },
		["Стильная зеленая рубашка"] = { 145, 180 },
		["Стильная красная рубашка"] = { 135, 170 },
		["Стильная синяя рубашка"] = { 145, 180 },
		["Стихийношелковый вышитый талисман"] = { 520, 530 },
		["Сума душ"] = { 275, 305 },
		["Сумка Бездны"] = { 440, 450 },
		["Сумка Кенария"] = { 315, 345 },
		["Сумка из изначальной луноткани"] = { 385, 395 },
		["Сумка из ледяной ткани"] = { 430, 450 },
		["Сумка из луноткани"] = { 315, 345 },
		["Сумка из магической ткани"] = { 240, 270 },
		["Сумка из огненной чароткани"] = { 385, 395 },
		["Сумка из прочной ткани Пустоты"] = { 340, 350 },
		["Сумка из рунической ткани"] = { 275, 305 },
		["Сумка из сердцевинной ткани Скверны"] = { 315, 345 },
		["Сумка из ткани Пустоты"] = { 320, 340 },
		["Сумка из ткани Скверны"] = { 300, 330 },
		["Таинственная котомка"] = { 445, 455 },
		["Таинственная чародейская нить"] = { 345, 355 },
		["Темная шелковая рубашка"] = { 165, 175 },
		["Теневой капюшон"] = { 190, 220 },
		["Тенетканая маска"] = { 260, 290 },
		["Тенетканое одеяние"] = { 230, 260 },
		["Тенетканые наплечники"] = { 250, 280 },
		["Тенетканые перчатки"] = { 240, 270 },
		["Тенетканые сапоги"] = { 255, 285 },
		["Тенетканые штаны"] = { 225, 255 },
		["Ткань Теней"] = { 350, 360 },
		["Тончайший плащ"] = { 435, 455 },
		["Троекратно укрепленная сумка"] = { 505, 515 },
		["Туфли из паутины"] = { 160, 190 },
		["Туфли спасителя"] = { 455, 465 },
		["Туфли стража духа"] = { 385, 395 },
		["Туфли тонких чар"] = { 455, 465 },
		["Туфли утренней зари"] = { 430, 450 },
		["Тюрбан из чародейской ткани"] = { 315, 345 },
		["Тяжелая сеть из ткани Пустоты"] = { 325, 335 },
		["Тяжелые льняные перчатки"] = { 60, 95 },
		["Тяжелые шерстяные перчатки"] = { 110, 145 },
		["Тяжелые шерстяные штаны"] = { 135, 170 },
		["Тяжелый шерстяной плащ"] = { 125, 160 },
		["Усиленная льняная накидка"] = { 85, 120 },
		["Усиленные шерстяные наплечники"] = { 145, 180 },
		["Церемониальная белая рубашка"] = { 180, 190 },
		["Чародейская нить наставника"] = { 405, 405 },
		["Чароткань"] = { 350, 360 },
		["Черная повязка из магической ткани"] = { 245, 275 },
		["Черная рубашка сорвиголовы"] = { 210, 220 },
		["Черная сумка теней"] = { 385, 395 },
		["Черная шелковая сума"] = { 205, 235 },
		["Черное одеяние из магической ткани"] = { 225, 255 },
		["Черное одеяние из сумеречной ткани"] = { 430, 440 },
		["Черные наплечники из магической ткани"] = { 245, 275 },
		["Черные напульсники из сумеречной ткани"] = { 425, 435 },
		["Черные перчатки из магической ткани"] = { 230, 260 },
		["Черные поножи из магической ткани"] = { 220, 250 },
		["Черные поножи из сумеречной ткани"] = { 425, 435 },
		["Черные сапоги из магической ткани"] = { 245, 275 },
		["Черный жилет из магической ткани"] = { 220, 250 },
		["Черный пояс знания"] = { 375, 385 },
		["Шаль силы духа из редкого шелка"] = { 475, 500 },
		["Шелковая головная повязка"] = { 170, 180 },
		["Шелковые сапоги ледяных осколков"] = { 430, 450 },
		["Шелковый пояс земли"] = { 215, 245 },
		["Шерстяная накидка"] = { 100, 135 },
		["Шерстяная сумка"] = { 105, 140 },
		["Шерстяные наплечники с двойным швом"] = { 135, 170 },
		["Шерстяные сапоги"] = { 120, 155 },
		["Шляпа безрадостной судьбы"] = { 435, 445 },
		["Шнурованный ремень светлого утра"] = { 455, 465 },
		["Штаны Белого целителя"] = { 385, 395 },
		["Штаны Феникса"] = { 150, 185 },
		["Штаны боевого заклятья"] = { 385, 395 },
		["Штаны из ледяной ткани"] = { 295, 325 },
		["Штаны из пепельной ткани"] = { 295, 325 },
		["Штаны из призрачной ткани"] = { 305, 335 },
		["Штаны из прочной ткани Пустоты"] = { 350, 360 },
		["Штаны из рунической ткани"] = { 300, 330 },
		["Штаны из ткани Пустоты"] = { 335, 345 },
		["Штаны из ткани Скверны"] = { 290, 320 },
		["Штаны из штормовой ткани"] = { 235, 265 },
		["Штаны из яркой ткани"] = { 305, 335 },
		["Штаны сокрушительной магии"] = { 385, 395 },
		["Штаны холодной луны"] = { 435, 445 },
		["Ярко-желтая рубашка"] = { 145, 155 },
	},
	[202] = {
		["Автоматический молот"] = { 525, 535 },
		["Автоматический ремонтный набор"] = { 200, 240 },
		["Адамантитовая винтовка"] = { 360, 380 },
		["Адамантитовая граната"] = { 335, 355 },
		["Адамантитовая рамка"] = { 325, 335 },
		["Адамантитовый прицел"] = { 345, 365 },
		["Аквадинамический магнит для рыбы"] = { 150, 170 },
		["Активная наручная защита ХМ-52 \"Титан\""] = { 475, 500 },
		["Амуниция из оскверненного железа"] = { 310, 330 },
		["Амуниция с колчедановым наконечником"] = { 515, 525 },
		["Амуниция с ледяным наконечником"] = { 440, 460 },
		["Амуниция с ториевым наконечником"] = { 295, 305 },
		["Анжинерский чоппер"] = { 480, 490 },
		["Анти-перенаправляющий луч"] = { 180, 200 },
		["Арканитовый дракончик"] = { 320, 340 },
		["Армированные биооптические очки бойца"] = { 450, 500 },
		["Армированные биооптические очки защитника"] = { 450, 500 },
		["Армированные биооптические очки целителя"] = { 450, 500 },
		["Белая дымовая сигнальная ракета"] = { 335, 355 },
		["Боевой цыпленок гномов"] = { 250, 270 },
		["Большая бронзовая бомба"] = { 140, 190 },
		["Большая железная бомба"] = { 190, 230 },
		["Большая зеленая ракета"] = { 175, 200 },
		["Большая красная ракета"] = { 175, 200 },
		["Большая медная бомба"] = { 105, 155 },
		["Большая связка зеленых фейерверков"] = { 275, 285 },
		["Большая связка красных фейерверков"] = { 275, 285 },
		["Большая связка синих фейерверков"] = { 275, 285 },
		["Большая синяя ракета"] = { 175, 200 },
		["Большой атомарный перенаправлятор"] = { 285, 295 },
		["Большой папочка"] = { 505, 515 },
		["Большой сефориевый заряд"] = { 200, 240 },
		["Бомба из оскверненного железа"] = { 320, 340 },
		["Бомба из черного железа"] = { 305, 325 },
		["Бронебойная мифриловая амуниция"] = { 210, 250 },
		["Бронзовая трубка"] = { 105, 155 },
		["Бронзовый каркас"] = { 145, 195 },
		["Бронированные титановые очки"] = { 450, 460 },
		["Бронированный боевой дробовик"] = { 455, 465 },
		["Великан"] = { 235, 275 },
		["Величайший"] = { 325, 345 },
		["Ветролет"] = { 330, 350 },
		["Взрывоопасная овца"] = { 175, 200 },
		["Взрывчатая приманка"] = { 385, 395 },
		["Взрывчатое вещество стихий"] = { 300, 320 },
		["Винтовка из черного железа"] = { 295, 315 },
		["Высокомощный крепежный пистолет"] = { 490, 500 },
		["Генератор червоточины: Нордскол"] = { 450, 460 },
		["Генератор червоточины: Фельярд"] = { 525, 535 },
		["Генератор шума"] = { 435, 445 },
		["Гипер-излучающий отражатель пламени"] = { 310, 330 },
		["Гипер-увеличивающие лунные очки"] = { 390, 430 },
		["Гиперскоростные ускорители"] = { 400, 405 },
		["Гиро-балансированный кориевый Разрушитель"] = { 375, 410 },
		["Гирозамораживающий ледяной отражатель"] = { 280, 300 },
		["Гирохронатом"] = { 170, 210 },
		["Гномская шапка контроля над разумом"] = { 255, 275 },
		["Гномские боевые очки"] = { 375, 395 },
		["Гномские очки"] = { 230, 250 },
		["Гномские реактивные сапоги"] = { 245, 265 },
		["Гномские рентгеновские очки"] = { 430, 440 },
		["Гномские силовые очки"] = { 375, 395 },
		["Гномский армейский нож"] = { 440, 450 },
		["Гномский генератор молний"] = { 430, 440 },
		["Гномский пульт управления танком"] = { 325, 335 },
		["Гномский сетестрел"] = { 230, 250 },
		["Гномский тревого-бот"] = { 275, 285 },
		["Гоблинская 'коробка с сюрпризом'"] = { 235, 255 },
		["Гоблинская мина"] = { 205, 245 },
		["Гоблинская мортира"] = { 225, 245 },
		["Гоблинская наземная мина"] = { 215, 235 },
		["Гоблинские реактивные сапоги"] = { 245, 265 },
		["Гоблинский бомбомет"] = { 230, 270 },
		["Гоблинский кабельный дефибриллятор"] = { 160, 200 },
		["Гоблинский кабельный макси-дефибриллятор"] = { 285, 305 },
		["Гоблинский лучевой трансформатор"] = { 415, 425 },
		["Гоблинский планер"] = { 460, 480 },
		["Гоблинский пульт управления танком"] = { 325, 335 },
		["Гоблинский ракетомет"] = { 360, 380 },
		["Гоблинский реактивный шлем"] = { 265, 285 },
		["Гоблинское барбекю"] = { 495, 505 },
		["Гоблинское бургербекю"] = { 510, 520 },
		["Гоблинское драконье ружье"] = { 260, 280 },
		["Гоблинское радио"] = { 240, 260 },
		["Гоблинское ракетное топливо - рецепт"] = { 205, 205 },
		["Голографические очки аннигиляции"] = { 390, 430 },
		["Голографические очки уничтожения"] = { 370, 390 },
		["Голубая ракета"] = { 150, 175 },
		["Горсть винтов из оскверненного железа"] = { 300, 310 },
		["Горсть медных винтов"] = { 45, 60 },
		["Горсть обсидиановых болтов"] = { 450, 470 },
		["Грубая медная бомба"] = { 60, 90 },
		["Грубое взрывчатое вещество"] = { 20, 40 },
		["Грубый динамит"] = { 30, 60 },
		["Грубый огнестрел"] = { 80, 110 },
		["Детали для набора инъекций маны"] = { 420, 430 },
		["Детали для набора лечебных инъекций"] = { 415, 425 },
		["Дживс"] = { 480, 490 },
		["Динамит 'Pro-100-брос II'"] = { 200, 220 },
		["Динамит 'Pro-100-брос'"] = { 115, 130 },
		["Железная балка"] = { 160, 180 },
		["Железная граната"] = { 175, 215 },
		["Живые реплицирующие очки"] = { 370, 390 },
		["Замораживающие гранаты"] = { 345, 365 },
		["Заостренная кирка"] = { 380, 390 },
		["Заряженные синтетические очки типа \"B-ANK-J1R:\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"B-ANK-M3D\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"B-ANK-UK162\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"CHM-BK1N1-M3D\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"CHM-BK1N1-UK162\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"CHM-BK1N1-W1Z\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"GA-CH1-M3D\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"GA-CH1-UK162\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"GA-CH1-W1Z\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"L0-SKUT-M3D\""] = { 520, 530 },
		["Заряженные синтетические очки типа \"L0-SKUT-W1Z\""] = { 520, 530 },
		["Заряженные титановые очки"] = { 450, 460 },
		["Затемненный зеркальный прицел"] = { 525, 535 },
		["Затуманивающие взор очки"] = { 450, 460 },
		["Зачарованный шлем штейгера"] = { 375, 395 },
		["Зеленая дымовая сигнальная ракета"] = { 335, 355 },
		["Зеленая линза"] = { 265, 285 },
		["Зеленая ракета"] = { 150, 175 },
		["Зеленые тонированные очки"] = { 175, 200 },
		["Зеркальный прицел"] = { 485, 495 },
		["Золотое силовое ядро"] = { 150, 190 },
		["Инкрустированный мифриловый цилиндр - чертеж"] = { 205, 205 },
		["Искрящийся эфир"] = { 475, 495 },
		["Искусно изготовленная амуниция"] = { 30, 60 },
		["Иссеченные молниями очки"] = { 390, 430 },
		["Исцеляющий рассеиватель теней XT40"] = { 370, 390 },
		["Исцеляющий рассеиватель теней XT68"] = { 390, 430 },
		["Кабельная система с плавкими предохранителями"] = { 275, 285 },
		["Кирка-молот"] = { 380, 390 },
		["Кобальтовая осколочная бомба"] = { 375, 390 },
		["Колчедановый детонатор"] = { 510, 520 },
		["Комплект для сборки Хламобота"] = { 415, 420 },
		["Концентрированное взрывчатое вещество"] = { 250, 260 },
		["Концентрированный динамит"] = { 250, 270 },
		["Кориевое силовое ядро"] = { 350, 370 },
		["Кориевый прицел"] = { 370, 390 },
		["Коробка с механической белкой"] = { 105, 135 },
		["Красная дымовая сигнальная ракета"] = { 335, 355 },
		["Красная ракета"] = { 150, 175 },
		["Крошечная ходячая бомба"] = { 205, 205 },
		["Крошка Дымок"] = { 205, 205 },
		["Куробойка повышенной мощности"] = { 515, 525 },
		["Курогилятор"] = { 520, 530 },
		["Кустарный прицел"] = { 90, 120 },
		["Ледяной отражатель"] = { 175, 195 },
		["Ледяные взрывчатые запалы"] = { 335, 345 },
		["Летучий громоотвод"] = { 515, 525 },
		["Летучий сефориевый взрывпакет"] = { 480, 485 },
		["Лечебная граната истинного золота"] = { 510, 520 },
		["Лиловая дымовая сигнальная ракета"] = { 335, 355 },
		["Линза кровавой лозы"] = { 320, 340 },
		["Линза могущественного целителя-4000"] = { 370, 390 },
		["Линза могущественного целителя-9000"] = { 390, 430 },
		["Лунная винтовка"] = { 170, 195 },
		["Любительское радио гномов"] = { 240, 260 },
		["Любовно выделанный огнестрел"] = { 145, 170 },
		["МЯЛЛ-И"] = { 430, 435 },
		["Маленькая зеленая ракета"] = { 125, 150 },
		["Маленькая красная ракета"] = { 125, 150 },
		["Маленькая синяя ракета"] = { 125, 150 },
		["Малый атомарный перенаправлятор"] = { 165, 190 },
		["Малый сефориевый заряд"] = { 130, 160 },
		["Мамонтобои"] = { 405, 420 },
		["Манекен-мишень"] = { 115, 145 },
		["Манекен-мишень искусной работы"] = { 295, 315 },
		["Маскировочный механизм гномов"] = { 220, 240 },
		["Медная труба"] = { 80, 110 },
		["Медный регулятор"] = { 95, 125 },
		["Межпространственный тоннель: К-3"] = { 435, 445 },
		["Механизированные снегозащитные очки"] = { 425, 440 },
		["Механическая жаба"] = { 285, 305 },
		["Механическая пелерина претендента"] = { 470, 490 },
		["Механический дракончик"] = { 220, 240 },
		["Механический плащ претендента"] = { 470, 490 },
		["Механокот модели Х-995"] = { 535, 545 },
		["Механоцикл"] = { 480, 490 },
		["Мифриловая гиро-амуниция"] = { 245, 285 },
		["Мифриловая крупнокалиберная винтовка"] = { 240, 260 },
		["Мифриловая обшивка"] = { 215, 255 },
		["Мифриловая осколочная бомба"] = { 215, 255 },
		["Мифриловая труба"] = { 195, 235 },
		["Мифриловый механический дракончик"] = { 270, 290 },
		["Мифриловый мушкетон"] = { 225, 245 },
		["Модулирующий усилитель голоса"] = { 310, 330 },
		["Монокль ремесленника"] = { 205, 225 },
		["Мощный сефориевый заряд"] = { 275, 295 },
		["Мощный фонарь"] = { 270, 290 },
		["Мушкет из оскверненного железа"] = { 330, 350 },
		["Набор для инъекций маны"] = { 345, 365 },
		["Набор для лечебных инъекций"] = { 330, 350 },
		["Набор для снятия ограничителя"] = { 460, 480 },
		["Наременные осколочные бомбы"] = { 380, 385 },
		["Нарукавная зажигательная ракетница"] = { 400, 405 },
		["Наручная маскировка ХТ-92 \"Леший\""] = { 475, 500 },
		["Наручная электрозащита ХЕ-89 \"Буря\""] = { 475, 500 },
		["Наручные подавители боли ХМ-51 \"Узурпатор\""] = { 475, 500 },
		["Наручный инъектор ХЕ-39 \"Водяной\""] = { 475, 500 },
		["Наручный источник сил ХМ-75 \"Очищение\""] = { 475, 500 },
		["Наручный сканер слабостей ХТ-27 \"Трепет\""] = { 475, 500 },
		["Наручный целеуказатель ХЕ-41 \"Раптор\""] = { 475, 500 },
		["Небольшая бронзовая бомба"] = { 120, 170 },
		["Нерушимые усилители исцеления"] = { 450, 460 },
		["Нестабильное пусковое устройство"] = { 200, 240 },
		["Неустойчивый детонатор"] = { 366, 385 },
		["Низкосортное взрывчатое вещество"] = { 85, 95 },
		["Низкосортный динамит"] = { 90, 105 },
		["Нитроускорители"] = { 400, 410 },
		["Облегченные биооптические очки заклинателя"] = { 450, 500 },
		["Облегченные биооптические очки целителя"] = { 450, 500 },
		["Облегченные экстремальные реактивые сапоги"] = { 365, 385 },
		["Образцовый гномский армейский нож"] = { 525, 535 },
		["Обсидиановый дракончик"] = { 510, 520 },
		["Обшивка из оскверненного железа"] = { 300, 320 },
		["Обычный прицел"] = { 135, 160 },
		["Огненная турель гномов"] = { 335, 355 },
		["Огненные очки"] = { 225, 245 },
		["Огнестрел из оскверненной стали"] = { 370, 390 },
		["Огнестрел модели 'С'"] = { 405, 415 },
		["Орудие: перезаряжено"] = { 1, 1 },
		["Осколочные патроны"] = { 440, 460 },
		["Острейшая саронитовая амуниция"] = { 410, 425 },
		["Отличная арканитовая винтовка"] = { 320, 340 },
		["Отражатель пламени"] = { 125, 175 },
		["Очки 'Воздаятель 2000'"] = { 370, 390 },
		["Очки 'Воздаятель-3000'"] = { 390, 430 },
		["Очки верного удара модель 2.0"] = { 370, 390 },
		["Очки верного удара модель 3.0"] = { 390, 430 },
		["Очки волшебного могущества Экстрим-Плюс"] = { 290, 310 },
		["Очки волшебного могущества-Экстрим"] = { 245, 265 },
		["Очки гиперзрения"] = { 370, 390 },
		["Очки из закаленного кория"] = { 390, 430 },
		["Очки изначальной гармонии"] = { 390, 430 },
		["Очки квадри-смертельного удара X44"] = { 390, 430 },
		["Очки кровавой лозы"] = { 320, 340 },
		["Очки летающего тигра"] = { 130, 160 },
		["Очки механического шторма"] = { 370, 390 },
		["Очки прядильщика"] = { 350, 370 },
		["Очки с зелеными стеклами"] = { 450, 460 },
		["Очки смертельного удара X11"] = { 370, 390 },
		["Очки старшего инженера"] = { 310, 330 },
		["Перегруженный конденсатор"] = { 380, 390 },
		["Передвижная сирена"] = { 205, 245 },
		["Переносной бронзовый миномет"] = { 185, 205 },
		["Персональный генератор электромагнитных импульсов"] = { 390, 395 },
		["Петарда 'Змеиное жало'"] = { 250, 270 },
		["Плащ-парашют"] = { 245, 265 },
		["Повышающие проворство биооптические очки бойца"] = { 450, 500 },
		["Повышающие проворство биооптические очки заклинателя"] = { 450, 500 },
		["Повышающие проворство биооптические очки целителя"] = { 450, 500 },
		["Подлинные очки мл. инженера"] = { 470, 480 },
		["Полевой ремонтный робот 110G"] = { 370, 390 },
		["Полевой ремонтный робот 74A"] = { 320, 340 },
		["Полюсный птицефикатор гномов"] = { 360, 380 },
		["Посеребренный дробовик"] = { 155, 180 },
		["Пояс гномов, хранящий от вреда"] = { 235, 255 },
		["Пояс почти-неуязвимости"] = { 360, 380 },
		["Превосходная мина"] = { 340, 360 },
		["Преобразователь истинного серебра"] = { 270, 280 },
		["Пригоршня кобальтовых болтов"] = { 360, 380 },
		["Прицел 'Бизникс' 247x128"] = { 320, 340 },
		["Прицел 'Пронзатель сердец'"] = { 435, 455 },
		["Прицел быстрорукого Джека"] = { 525, 535 },
		["Прицел судьбы лорда Бумтингона"] = { 510, 520 },
		["Проекционные очки резни"] = { 390, 430 },
		["Пространственный проходчик - Зона 52"] = { 350, 370 },
		["Пространственный проходчик - Круговзор"] = { 285, 305 },
		["Пружинистая паутинка"] = { 380, 385 },
		["Пульт управления паровым танком"] = { 275, 285 },
		["Пусковая установка для связок фейерверков"] = { 295, 315 },
		["Пусковая установка для фейерверков"] = { 245, 265 },
		["Реактивный диск"] = { 320, 340 },
		["Рефракторный прицел с бриллиантовой огранкой"] = { 400, 415 },
		["Робот 'Бей-Молоти'"] = { 335, 355 },
		["Розовые очки"] = { 250, 270 },
		["Сборный компактный уборочный голем"] = { 175, 215 },
		["Сверхбезопасный транспортер: Прибамбасск"] = { 285, 305 },
		["Сверхбезопасный транспортер: станция Тошли"] = { 350, 370 },
		["Сверхмощный заряд термической саперной взрывчатки"] = { 425, 435 },
		["Сверхточный арканитовый преобразователь"] = { 305, 325 },
		["Световая бомба"] = { 185, 225 },
		["Связка зеленых фейерверков"] = { 225, 250 },
		["Связка красных фейерверков"] = { 225, 250 },
		["Связка синих фейерверков"] = { 225, 250 },
		["Серебряный контакт"] = { 110, 140 },
		["Сефориевый заряд стихий"] = { 350, 360 },
		["Синтетические очки типа \"B-ANK-J1R:\""] = { 480, 500 },
		["Синтетические очки типа \"B-ANK-M3D\""] = { 480, 500 },
		["Синтетические очки типа \"B-ANK-UK162\""] = { 480, 500 },
		["Синтетические очки типа \"CHM-BK1N1-M3D\""] = { 480, 500 },
		["Синтетические очки типа \"CHM-BK1N1-UK162\""] = { 480, 500 },
		["Синтетические очки типа \"CHM-BK1N1-W1Z\""] = { 480, 500 },
		["Синтетические очки типа \"GA-CH1-M3D\""] = { 480, 500 },
		["Синтетические очки типа \"GA-CH1-UK162\""] = { 480, 500 },
		["Синтетические очки типа \"GA-CH1-W1Z\""] = { 480, 500 },
		["Синтетические очки типа \"L0-SKUT-M3D\""] = { 480, 500 },
		["Синтетические очки типа \"L0-SKUT-W1Z\""] = { 480, 500 },
		["Синяя дымовая сигнальная ракета"] = { 335, 355 },
		["Смертоносные биооптические очки бойца"] = { 450, 500 },
		["Смертоносные биооптические очки заклинателя"] = { 450, 500 },
		["Смертоносные биооптические очки целителя"] = { 450, 500 },
		["Смертоносный луч гномов"] = { 260, 280 },
		["Смертоносный мушкетон"] = { 130, 155 },
		["Смертоносный прицел"] = { 230, 250 },
		["Снайперская винтовка Недр"] = { 320, 340 },
		["Снайперский прицел"] = { 260, 280 },
		["Снегозащитные очки острого зрения"] = { 450, 460 },
		["Создатель снега 9000"] = { 190, 230 },
		["Солнечный прицел"] = { 430, 435 },
		["Солонка"] = { 270, 290 },
		["Спектральный выявитель слабости"] = { 450, 460 },
		["Спокойный механический йети"] = { 320, 340 },
		["Стабилизатор из оскверненной стали"] = { 350, 370 },
		["Стабилизированный этерниевый прицел"] = { 385, 405 },
		["Станок адамантитовой амуниции"] = { 335, 355 },
		["Станок для адамантитовых патронов"] = { 335, 355 },
		["Статические гиперускорители"] = { 400, 405 },
		["Тангенциальный вращатель"] = { 70, 90 },
		["Танкатронные очки"] = { 370, 390 },
		["Твареувеличитель"] = { 325, 345 },
		["Твердая искусно изготовленная амуниция"] = { 125, 145 },
		["Твердое взрывчатое вещество"] = { 175, 195 },
		["Твердый динамит"] = { 175, 195 },
		["Теневые очки"] = { 145, 170 },
		["Термическая наковальня"] = { 525, 535 },
		["Термостойкая вращающаяся наживка"] = { 500, 510 },
		["Титановый ящик с инструментами"] = { 425, 440 },
		["Тонко отлаженный шприцевик"] = { 515, 525 },
		["Ториевая винтовка"] = { 280, 300 },
		["Ториевая граната"] = { 280, 300 },
		["Ториевая труба"] = { 295, 315 },
		["Ториевое устройство"] = { 280, 300 },
		["Точный прицел"] = { 200, 220 },
		["Транслятор нервных импульсов"] = { 410, 420 },
		["Трещащий бронзовый механизм"] = { 125, 175 },
		["Трицикл"] = { 460, 480 },
		["Труба из закаленного адамантита"] = { 350, 370 },
		["Труба из ледяной стали"] = { 395, 405 },
		["Турбоветролет"] = { 385, 395 },
		["Турботрицикл"] = { 460, 480 },
		["Тяжелая искусно изготовленная амуниция"] = { 85, 95 },
		["Тяжелое взрывчатое вещество"] = { 125, 145 },
		["Тяжелый динамит"] = { 125, 145 },
		["Увеличивающие лунные очки"] = { 370, 390 },
		["Увеличитель мира"] = { 260, 270 },
		["Угрозодетектор R19"] = { 460, 480 },
		["Удаленный конденсатор выхлопов"] = { 305, 325 },
		["Ударный шорох"] = { 520, 530 },
		["Узорчатая кориевая винтовка"] = { 385, 405 },
		["Украшенная подзорная труба"] = { 160, 185 },
		["Укрепленный решетчатый каркас"] = { 400, 405 },
		["Укрепленный шлем старшины"] = { 375, 395 },
		["Ультра-вспышечный отражатель тьмы"] = { 320, 340 },
		["Ультра-очки 'Кошачий глаз'"] = { 240, 260 },
		["Ультраскопические очки обнаружения"] = { 360, 380 },
		["Уменьшающий луч гномов"] = { 225, 245 },
		["Умножающие силу очки"] = { 350, 370 },
		["Универсальный гномский дистанционный пульт"] = { 150, 175 },
		["Усилитель звука"] = { 435, 445 },
		["Усовершенствованный манекен-мишень"] = { 185, 225 },
		["Учебный замок"] = { 115, 130 },
		["Фугасная бомба"] = { 235, 275 },
		["Чародейская бомба"] = { 320, 340 },
		["Чоппер изгоя"] = { 480, 490 },
		["Шахтерская гоблинская каска"] = { 225, 245 },
		["Шлем гоблинской конструкции"] = { 225, 245 },
		["Шлем ныряльщика"] = { 250, 270 },
		["Шлицевой гироинструмент"] = { 175, 215 },
		["Шпашко-метатель"] = { 520, 530 },
		["Экстремальные реактивные сапоги"] = { 365, 385 },
		["Эластичная подкладка"] = { 380, 385 },
		["Электропотоковое улучшение зрения"] = { 450, 460 },
		["Электростатический конденсатор"] = { 475, 495 },
		["Элементиевые снаряды"] = { 515, 525 },
		["Элементиевый дракончик"] = { 515, 525 },
		["Эрнестуэй 4000"] = { 455, 465 },
		["Яркоглазые очки"] = { 195, 215 },
		["Яростные механические очки"] = { 370, 390 },
		["Ящик бомб"] = { 410, 420 },
		["Ящик для инструментов из оскверненного железа"] = { 325, 345 },
	},
	[333] = {
		["Большой магический жезл"] = { 110, 150 },
		["Большой радужный осколок"] = { 5, 10 },
		["Большой таинственный жезл"] = { 195, 235 },
		["Волшебное масло"] = { 285, 305 },
		["Дробление космического осколока"] = { 450, 460 },
		["Дробление кристалла Бездны"] = { 360, 365 },
		["Дробление небесного осколока"] = { 450, 460 },
		["Дымящееся сердце горы"] = { 285, 325 },
		["Зачарованная кожа"] = { 250, 260 },
		["Зачарованный торий"] = { 250, 260 },
		["Иллюзорное волшебное масло"] = { 470, 490 },
		["Иллюзорное масло маны"] = { 470, 490 },
		["Космический осколок"] = { 450, 460 },
		["Малый магический жезл"] = { 75, 115 },
		["Малый мистический жезл"] = { 175, 215 },
		["Малый небесный осколок"] = { 450, 460 },
		["Малый радужный осколок"] = { 315, 335 },
		["Обледенение Бездны"] = { 445, 450 },
		["Поводья манапарда чародея"] = { 535, 545 },
		["Превосходное волшебное масло"] = { 340, 360 },
		["Превосходное масло маны"] = { 310, 330 },
		["Преображение кристалла-источника"] = { 295, 305 },
		["Простая божественная субстанция"] = { 450, 460 },
		["Простое волшебное масло"] = { 210, 230 },
		["Простое масло маны"] = { 260, 280 },
		["Пустая сфера"] = { 370, 380 },
		["Радужная сфера"] = { 325, 335 },
		["Распыление"] = { 20, 60 },
		["Распыление простой божественная субстанция"] = { 450, 460 },
		["Распыление простой божественной субстанции"] = { 450, 460 },
		["Рунический адамантитовый жезл"] = { 370, 380 },
		["Рунический арканитовый жезл"] = { 305, 340 },
		["Рунический жезл из оскверненного железа"] = { 310, 340 },
		["Рунический жезл истинного серебра"] = { 220, 260 },
		["Рунический золотой жезл"] = { 175, 215 },
		["Рунический медный жезл"] = { 5, 10 },
		["Рунический серебряный жезл"] = { 130, 170 },
		["Рунический титановый жезл"] = { 435, 455 },
		["Рунический этерниевый жезл"] = { 370, 385 },
		["Сверкающее волшебное масло"] = { 310, 330 },
		["Сверкающее масло маны"] = { 310, 330 },
		["Слабое волшебное масло"] = { 55, 75 },
		["Слабое масло маны"] = { 160, 180 },
		["Фельярдские чары для нагрудника - броня"] = { 475, 490 },
		["Фельярдские чары для нагрудника - восполнение маны"] = { 475, 490 },
		["Фельярдские чары для нагрудника - выносливость"] = { 475, 490 },
		["Фельярдские чары для нагрудника - дух"] = { 475, 490 },
		["Фельярдские чары для нагрудника - защита"] = { 475, 490 },
		["Фельярдские чары для нагрудника - интеллект"] = { 475, 490 },
		["Фельярдские чары для нагрудника - критический удар"] = { 475, 490 },
		["Фельярдские чары для нагрудника - ловкость"] = { 475, 490 },
		["Фельярдские чары для нагрудника - мастерство"] = { 475, 490 },
		["Фельярдские чары для нагрудника - меткость"] = { 475, 490 },
		["Фельярдские чары для нагрудника - парирование"] = { 475, 490 },
		["Фельярдские чары для нагрудника - показатель блокирования"] = { 475, 490 },
		["Фельярдские чары для нагрудника - пробивание брони"] = { 475, 490 },
		["Фельярдские чары для нагрудника - проникающая способность заклинаний"] = { 475, 490 },
		["Фельярдские чары для нагрудника - рейтинг блокирования"] = { 475, 490 },
		["Фельярдские чары для нагрудника - сила"] = { 475, 490 },
		["Фельярдские чары для нагрудника - сила атаки"] = { 475, 490 },
		["Фельярдские чары для нагрудника - сила заклинаний"] = { 475, 490 },
		["Фельярдские чары для нагрудника - скорость"] = { 475, 490 },
		["Фельярдские чары для нагрудника - сопротивление стихиям"] = { 475, 490 },
		["Фельярдские чары для нагрудника - уклонение"] = { 475, 490 },
		["Фельярдские чары для нагрудника - устойчивость"] = { 475, 490 },
		["Фельярдские чары для наручей - броня"] = { 495, 510 },
		["Фельярдские чары для наручей - восполнение маны"] = { 495, 510 },
		["Фельярдские чары для наручей - выносливость"] = { 495, 510 },
		["Фельярдские чары для наручей - дух"] = { 495, 510 },
		["Фельярдские чары для наручей - защита"] = { 495, 510 },
		["Фельярдские чары для наручей - интеллект"] = { 495, 510 },
		["Фельярдские чары для наручей - критический удар"] = { 495, 510 },
		["Фельярдские чары для наручей - ловкость"] = { 495, 510 },
		["Фельярдские чары для наручей - мастерство"] = { 495, 510 },
		["Фельярдские чары для наручей - меткость"] = { 495, 510 },
		["Фельярдские чары для наручей - парирование"] = { 495, 510 },
		["Фельярдские чары для наручей - показатель блокирования"] = { 495, 510 },
		["Фельярдские чары для наручей - пробивание брони"] = { 495, 510 },
		["Фельярдские чары для наручей - проникающая способность заклинаний"] = { 495, 510 },
		["Фельярдские чары для наручей - рейтинг блокирования"] = { 495, 510 },
		["Фельярдские чары для наручей - сила"] = { 495, 510 },
		["Фельярдские чары для наручей - сила атаки"] = { 495, 510 },
		["Фельярдские чары для наручей - сила заклинаний"] = { 495, 510 },
		["Фельярдские чары для наручей - скорость"] = { 495, 510 },
		["Фельярдские чары для наручей - сопротивление стихиям"] = { 495, 510 },
		["Фельярдские чары для наручей - уклонение"] = { 495, 510 },
		["Фельярдские чары для наручей - устойчивость"] = { 495, 510 },
		["Фельярдские чары для обуви - броня"] = { 455, 470 },
		["Фельярдские чары для обуви - восполнение маны"] = { 455, 470 },
		["Фельярдские чары для обуви - выносливость"] = { 455, 470 },
		["Фельярдские чары для обуви - дух"] = { 455, 470 },
		["Фельярдские чары для обуви - защита"] = { 455, 470 },
		["Фельярдские чары для обуви - интеллект"] = { 455, 470 },
		["Фельярдские чары для обуви - критический удар"] = { 455, 470 },
		["Фельярдские чары для обуви - ловкость"] = { 455, 470 },
		["Фельярдские чары для обуви - мастерство"] = { 455, 470 },
		["Фельярдские чары для обуви - меткость"] = { 455, 470 },
		["Фельярдские чары для обуви - парирование"] = { 455, 470 },
		["Фельярдские чары для обуви - показатель блокирования"] = { 455, 470 },
		["Фельярдские чары для обуви - пробивание брони"] = { 455, 470 },
		["Фельярдские чары для обуви - проникающая способность заклинаний"] = { 455, 470 },
		["Фельярдские чары для обуви - рейтинг блокирования"] = { 455, 470 },
		["Фельярдские чары для обуви - сила"] = { 455, 470 },
		["Фельярдские чары для обуви - сила атаки"] = { 455, 470 },
		["Фельярдские чары для обуви - сила заклинаний"] = { 455, 470 },
		["Фельярдские чары для обуви - скорость"] = { 455, 470 },
		["Фельярдские чары для обуви - сопротивление стихиям"] = { 455, 470 },
		["Фельярдские чары для обуви - уклонение"] = { 455, 470 },
		["Фельярдские чары для обуви - устойчивость"] = { 455, 470 },
		["Фельярдские чары для перчаток - броня"] = { 465, 480 },
		["Фельярдские чары для перчаток - восполнение маны"] = { 465, 480 },
		["Фельярдские чары для перчаток - выносливость"] = { 465, 480 },
		["Фельярдские чары для перчаток - дух"] = { 465, 480 },
		["Фельярдские чары для перчаток - защита"] = { 465, 480 },
		["Фельярдские чары для перчаток - интеллект"] = { 465, 480 },
		["Фельярдские чары для перчаток - критический удар"] = { 465, 480 },
		["Фельярдские чары для перчаток - ловкость"] = { 465, 480 },
		["Фельярдские чары для перчаток - мастерство"] = { 465, 480 },
		["Фельярдские чары для перчаток - меткость"] = { 465, 480 },
		["Фельярдские чары для перчаток - парирование"] = { 465, 480 },
		["Фельярдские чары для перчаток - показатель блокирования"] = { 465, 480 },
		["Фельярдские чары для перчаток - пробивание брони"] = { 465, 480 },
		["Фельярдские чары для перчаток - проникающая способность заклинаний"] = { 465, 480 },
		["Фельярдские чары для перчаток - рейтинг блокирования"] = { 465, 480 },
		["Фельярдские чары для перчаток - сила"] = { 465, 480 },
		["Фельярдские чары для перчаток - сила атаки"] = { 465, 480 },
		["Фельярдские чары для перчаток - сила заклинаний"] = { 465, 480 },
		["Фельярдские чары для перчаток - скорость"] = { 465, 480 },
		["Фельярдские чары для перчаток - сопротивление стихиям"] = { 465, 480 },
		["Фельярдские чары для перчаток - уклонение"] = { 465, 480 },
		["Фельярдские чары для перчаток - устойчивость"] = { 465, 480 },
		["Фельярдские чары для плаща - броня"] = { 485, 500 },
		["Фельярдские чары для плаща - восполнение маны"] = { 485, 500 },
		["Фельярдские чары для плаща - выносливость"] = { 485, 500 },
		["Фельярдские чары для плаща - дух"] = { 485, 500 },
		["Фельярдские чары для плаща - защита"] = { 485, 500 },
		["Фельярдские чары для плаща - интеллект"] = { 485, 500 },
		["Фельярдские чары для плаща - критический удар"] = { 485, 500 },
		["Фельярдские чары для плаща - ловкость"] = { 485, 500 },
		["Фельярдские чары для плаща - мастерство"] = { 485, 500 },
		["Фельярдские чары для плаща - меткость"] = { 485, 500 },
		["Фельярдские чары для плаща - парирование"] = { 485, 500 },
		["Фельярдские чары для плаща - показатель блокирования"] = { 485, 500 },
		["Фельярдские чары для плаща - пробивание брони"] = { 485, 500 },
		["Фельярдские чары для плаща - проникающая способность заклинаний"] = { 485, 500 },
		["Фельярдские чары для плаща - рейтинг блокирования"] = { 485, 500 },
		["Фельярдские чары для плаща - сила"] = { 485, 500 },
		["Фельярдские чары для плаща - сила атаки"] = { 485, 500 },
		["Фельярдские чары для плаща - сила заклинаний"] = { 485, 500 },
		["Фельярдские чары для плаща - скорость"] = { 485, 500 },
		["Фельярдские чары для плаща - сопротивление стихиям"] = { 485, 500 },
		["Фельярдские чары для плаща - уклонение"] = { 485, 500 },
		["Фельярдские чары для плаща - устойчивость"] = { 485, 500 },
		["Фельярдские чары для щита - броня"] = { 505, 515 },
		["Фельярдские чары для щита - восполнение маны"] = { 505, 515 },
		["Фельярдские чары для щита - выносливость"] = { 505, 515 },
		["Фельярдские чары для щита - дух"] = { 505, 515 },
		["Фельярдские чары для щита - защита"] = { 505, 515 },
		["Фельярдские чары для щита - интеллект"] = { 505, 515 },
		["Фельярдские чары для щита - критический удар"] = { 505, 515 },
		["Фельярдские чары для щита - мастерство"] = { 505, 515 },
		["Фельярдские чары для щита - меткость"] = { 505, 515 },
		["Фельярдские чары для щита - парирование"] = { 505, 515 },
		["Фельярдские чары для щита - показатель блокирования"] = { 505, 515 },
		["Фельярдские чары для щита - пробивание брони"] = { 505, 515 },
		["Фельярдские чары для щита - проникающая способность заклинаний"] = { 505, 515 },
		["Фельярдские чары для щита - рейтинг блокирования"] = { 505, 515 },
		["Фельярдские чары для щита - сила"] = { 505, 515 },
		["Фельярдские чары для щита - сила заклинаний"] = { 505, 515 },
		["Фельярдские чары для щита - скорость"] = { 505, 515 },
		["Фельярдские чары для щита - сопротивление стихиям"] = { 505, 515 },
		["Фельярдские чары для щита - уклонение"] = { 505, 515 },
		["Фельярдские чары для щита - устойчивость"] = { 505, 515 },
		["Фельярские чары для двуручного оружия - благодать Ранульфа"] = { 515, 525 },
		["Фельярские чары для двуручного оружия - дыхание Сиф"] = { 515, 525 },
		["Фельярские чары для двуручного оружия - мощь Бьорна"] = { 515, 525 },
		["Фельярские чары для двуручного оружия - оберег Исулдофа"] = { 515, 525 },
		["Фельярские чары для двуручного оружия - пламя Фенгира"] = { 515, 525 },
		["Фельярские чары для двуручного оружия - проклятие Имирона"] = { 515, 525 },
		["Фельярские чары для двуручного оружия - увядание Галдора"] = { 515, 525 },
		["Фельярские чары для двуручного оружия - чародейство Квалда"] = { 515, 525 },
		["Фельярские чары для одноручного оружия - благодать Ранульфа"] = { 505, 515 },
		["Фельярские чары для одноручного оружия - дыхание Сиф"] = { 505, 515 },
		["Фельярские чары для одноручного оружия - мощь Бьорна"] = { 505, 515 },
		["Фельярские чары для одноручного оружия - оберег Исулдофа"] = { 505, 515 },
		["Фельярские чары для одноручного оружия - пламя Фенгира"] = { 505, 515 },
		["Фельярские чары для одноручного оружия - проклятие Имирона"] = { 505, 515 },
		["Фельярские чары для одноручного оружия - увядание Галдора"] = { 505, 515 },
		["Фельярские чары для одноручного оружия - чародейство Квалда"] = { 505, 515 },
		["Чародейная пыль"] = { 335, 355 },
		["Чары для двуручного оружия - благодать Ранульфа"] = { 510, 530 },
		["Чары для двуручного оружия - дух I"] = { 135, 175 },
		["Чары для двуручного оружия - дух II"] = { 310, 340 },
		["Чары для двуручного оружия - дыхание Сиф"] = { 510, 530 },
		["Чары для двуручного оружия - импульс I"] = { 130, 170 },
		["Чары для двуручного оружия - импульс II"] = { 170, 210 },
		["Чары для двуручного оружия - импульс III"] = { 220, 260 },
		["Чары для двуручного оружия - импульс IV"] = { 260, 300 },
		["Чары для двуручного оружия - импульс V"] = { 310, 340 },
		["Чары для двуручного оружия - интеллект I"] = { 130, 170 },
		["Чары для двуручного оружия - интеллект II"] = { 310, 340 },
		["Чары для двуручного оружия - ловкость I"] = { 305, 340 },
		["Чары для двуручного оружия - ловкость II"] = { 370, 385 },
		["Чары для двуручного оружия - мощь Бьорна"] = { 510, 530 },
		["Чары для двуручного оружия - оберег Исулдофа"] = { 510, 530 },
		["Чары для двуручного оружия - пламя Фенгира"] = { 510, 530 },
		["Чары для двуручного оружия - проклятие Имирона"] = { 510, 530 },
		["Чары для двуручного оружия - проклятие Плети"] = { 440, 460 },
		["Чары для двуручного оружия - резня"] = { 440, 460 },
		["Чары для двуручного оружия - резня II"] = { 500, 510 },
		["Чары для двуручного оружия - руническая вязь Нарфи"] = { 500, 520 },
		["Чары для двуручного оружия - свирепость"] = { 370, 380 },
		["Чары для двуручного оружия - свирепость II"] = { 400, 420 },
		["Чары для двуручного оружия - увядание Галдора"] = { 510, 530 },
		["Чары для двуручного оружия - чародейство Квалда"] = { 510, 530 },
		["Чары для кольца - все характеристики"] = { 380, 390 },
		["Чары для кольца - выносливость III"] = { 400, 415 },
		["Чары для кольца - сила заклинаний I"] = { 370, 385 },
		["Чары для кольца - сила заклинаний II"] = { 400, 415 },
		["Чары для кольца - удар"] = { 370, 385 },
		["Чары для кольца - целительная сила"] = { 380, 390 },
		["Чары для кольца - штурм I"] = { 400, 415 },
		["Чары для нагрудника - броня"] = { 490, 510 },
		["Чары для нагрудника - броня II"] = { 510, 530 },
		["Чары для нагрудника - быстрое восполнение маны"] = { 310, 340 },
		["Чары для нагрудника - восполнение маны III"] = { 490, 510 },
		["Чары для нагрудника - восполнение маны IV"] = { 510, 530 },
		["Чары для нагрудника - восстановление маны"] = { 430, 450 },
		["Чары для нагрудника - восстановление маны II"] = { 500, 510 },
		["Чары для нагрудника - все характеристики I"] = { 175, 215 },
		["Чары для нагрудника - все характеристики II"] = { 220, 260 },
		["Чары для нагрудника - все характеристики III"] = { 265, 305 },
		["Чары для нагрудника - все характеристики IV"] = { 310, 340 },
		["Чары для нагрудника - все характеристики IX"] = { 460, 490 },
		["Чары для нагрудника - все характеристики V"] = { 355, 380 },
		["Чары для нагрудника - все характеристики VI"] = { 380, 400 },
		["Чары для нагрудника - все характеристики VII"] = { 450, 470 },
		["Чары для нагрудника - все характеристики VIII"] = { 500, 510 },
		["Чары для нагрудника - все характеристики X"] = { 510, 530 },
		["Чары для нагрудника - дух"] = { 330, 360 },
		["Чары для нагрудника - защита I"] = { 370, 400 },
		["Чары для нагрудника - защита II"] = { 410, 430 },
		["Чары для нагрудника - защита III"] = { 500, 510 },
		["Чары для нагрудника - защита IV"] = { 490, 510 },
		["Чары для нагрудника - защита V"] = { 510, 530 },
		["Чары для нагрудника - здоровье I"] = { 70, 110 },
		["Чары для нагрудника - здоровье II"] = { 105, 145 },
		["Чары для нагрудника - здоровье III"] = { 145, 185 },
		["Чары для нагрудника - здоровье IV"] = { 180, 220 },
		["Чары для нагрудника - здоровье IX"] = { 435, 455 },
		["Чары для нагрудника - здоровье V"] = { 240, 280 },
		["Чары для нагрудника - здоровье VI"] = { 295, 335 },
		["Чары для нагрудника - здоровье VII"] = { 325, 355 },
		["Чары для нагрудника - здоровье VIII"] = { 405, 425 },
		["Чары для нагрудника - мана I"] = { 80, 120 },
		["Чары для нагрудника - мана II"] = { 115, 155 },
		["Чары для нагрудника - мана III"] = { 170, 210 },
		["Чары для нагрудника - мана IV"] = { 205, 245 },
		["Чары для нагрудника - мана V"] = { 250, 290 },
		["Чары для нагрудника - мана VI"] = { 305, 340 },
		["Чары для нагрудника - мана VII"] = { 360, 380 },
		["Чары для нагрудника - мастерство"] = { 490, 510 },
		["Чары для нагрудника - мастерство II"] = { 510, 530 },
		["Чары для нагрудника - меткость"] = { 490, 510 },
		["Чары для нагрудника - меткость II"] = { 510, 530 },
		["Чары для нагрудника - поглощение I"] = { 90, 130 },
		["Чары для нагрудника - поглощение II"] = { 165, 205 },
		["Чары для нагрудника - устойчивость I"] = { 355, 380 },
		["Чары для нагрудника - устойчивость II"] = { 435, 455 },
		["Чары для нагрудника - устойчивость III"] = { 500, 510 },
		["Чары для нагрудника - устойчивость IV"] = { 500, 520 },
		["Чары для нагрудника - устойчивость V"] = { 510, 530 },
		["Чары для наручей - броня"] = { 490, 510 },
		["Чары для наручей - броня II"] = { 510, 530 },
		["Чары для наручей - быстрое восполнение маны"] = { 345, 375 },
		["Чары для наручей - восполнение маны"] = { 305, 340 },
		["Чары для наручей - восполнение маны II"] = { 490, 510 },
		["Чары для наручей - восполнение маны III"] = { 510, 530 },
		["Чары для наручей - все характеристики"] = { 325, 355 },
		["Чары для наручей - все характеристики II"] = { 410, 430 },
		["Чары для наручей - все характеристики III"] = { 500, 510 },
		["Чары для наручей - выносливость I"] = { 100, 140 },
		["Чары для наручей - выносливость II"] = { 155, 195 },
		["Чары для наручей - выносливость III"] = { 190, 230 },
		["Чары для наручей - выносливость IV"] = { 265, 305 },
		["Чары для наручей - выносливость IX"] = { 510, 530 },
		["Чары для наручей - выносливость V"] = { 310, 340 },
		["Чары для наручей - выносливость VI"] = { 460, 480 },
		["Чары для наручей - выносливость VII"] = { 500, 510 },
		["Чары для наручей - выносливость VIII"] = { 460, 490 },
		["Чары для наручей - грубая сила"] = { 315, 345 },
		["Чары для наручей - дух I"] = { 105, 145 },
		["Чары для наручей - дух II"] = { 145, 185 },
		["Чары для наручей - дух III"] = { 185, 225 },
		["Чары для наручей - дух IV"] = { 240, 280 },
		["Чары для наручей - дух IX"] = { 510, 530 },
		["Чары для наручей - дух V"] = { 290, 330 },
		["Чары для наручей - дух VI"] = { 430, 450 },
		["Чары для наручей - дух VII"] = { 500, 510 },
		["Чары для наручей - дух VIII"] = { 460, 490 },
		["Чары для наручей - защита"] = { 330, 360 },
		["Чары для наручей - здоровье I"] = { 70, 110 },
		["Чары для наручей - интеллект I"] = { 175, 215 },
		["Чары для наручей - интеллект III"] = { 275, 315 },
		["Чары для наручей - интеллект IV"] = { 315, 345 },
		["Чары для наручей - интеллект V"] = { 460, 490 },
		["Чары для наручей - интеллект VI"] = { 510, 530 },
		["Чары для наручей - лечение II"] = { 335, 365 },
		["Чары для наручей - ловкость I"] = { 115, 155 },
		["Чары для наручей - ловкость II"] = { 460, 490 },
		["Чары для наручей - ловкость III"] = { 510, 530 },
		["Чары для наручей - мастерство"] = { 425, 445 },
		["Чары для наручей - мастерство II"] = { 500, 510 },
		["Чары для наручей - мастерство III"] = { 490, 510 },
		["Чары для наручей - мастерство IV"] = { 510, 530 },
		["Чары для наручей - отражение I"] = { 80, 120 },
		["Чары для наручей - отражение II"] = { 190, 230 },
		["Чары для наручей - отражение III"] = { 255, 295 },
		["Чары для наручей - сила I"] = { 115, 155 },
		["Чары для наручей - сила II"] = { 165, 205 },
		["Чары для наручей - сила III"] = { 200, 240 },
		["Чары для наручей - сила IV"] = { 260, 300 },
		["Чары для наручей - сила V"] = { 310, 340 },
		["Чары для наручей - сила VI"] = { 460, 490 },
		["Чары для наручей - сила VII"] = { 510, 530 },
		["Чары для наручей - сила атаки"] = { 500, 520 },
		["Чары для наручей - сила атаки II"] = { 510, 530 },
		["Чары для наручей - сила заклинаний I"] = { 370, 400 },
		["Чары для наручей - сила заклинаний II"] = { 405, 425 },
		["Чары для наручей - сила заклинаний III"] = { 450, 470 },
		["Чары для наручей - сила заклинаний IV"] = { 500, 510 },
		["Чары для наручей - сила заклинаний V"] = { 500, 520 },
		["Чары для наручей - стойкость"] = { 370, 380 },
		["Чары для наручей - удар III"] = { 370, 390 },
		["Чары для наручей - целительная сила"] = { 310, 340 },
		["Чары для наручей - штурм I"] = { 310, 340 },
		["Чары для наручей - штурм II"] = { 440, 460 },
		["Чары для наручей - штурм III"] = { 500, 510 },
		["Чары для обуви - броня"] = { 490, 510 },
		["Чары для обуви - броня II"] = { 510, 530 },
		["Чары для обуви - быстрота вепря"] = { 370, 385 },
		["Чары для обуви - верный шаг"] = { 380, 390 },
		["Чары для обуви - восполнение маны"] = { 490, 510 },
		["Чары для обуви - восполнение маны II"] = { 510, 530 },
		["Чары для обуви - выносливость"] = { 460, 490 },
		["Чары для обуви - выносливость I"] = { 150, 190 },
		["Чары для обуви - выносливость III"] = { 235, 275 },
		["Чары для обуви - выносливость IV"] = { 280, 320 },
		["Чары для обуви - дух I"] = { 210, 250 },
		["Чары для обуви - дух II"] = { 295, 335 },
		["Чары для обуви - дух III"] = { 420, 440 },
		["Чары для обуви - дух IV"] = { 500, 510 },
		["Чары для обуви - живучесть I"] = { 315, 345 },
		["Чары для обуви - живучесть II"] = { 415, 435 },
		["Чары для обуви - живучесть клыкарра"] = { 450, 470 },
		["Чары для обуви - живучесть клыкарра II"] = { 500, 510 },
		["Чары для обуви - ледопроходец"] = { 395, 415 },
		["Чары для обуви - ледопроходец II"] = { 500, 510 },
		["Чары для обуви - ловкость I"] = { 150, 190 },
		["Чары для обуви - ловкость II"] = { 180, 220 },
		["Чары для обуви - ловкость III"] = { 255, 295 },
		["Чары для обуви - ловкость IV"] = { 310, 340 },
		["Чары для обуви - ловкость V"] = { 425, 445 },
		["Чары для обуви - ловкость VI"] = { 500, 510 },
		["Чары для обуви - меткость I"] = { 245, 285 },
		["Чары для обуви - меткость II"] = { 490, 510 },
		["Чары для обуви - меткость III"] = { 510, 530 },
		["Чары для обуви - проворство кошки"] = { 370, 385 },
		["Чары для обуви - сила атаки"] = { 500, 520 },
		["Чары для обуви - сила атаки II"] = { 510, 530 },
		["Чары для обуви - сила заклинаний"] = { 500, 520 },
		["Чары для обуви - сила заклинаний II"] = { 510, 530 },
		["Чары для обуви - скорость"] = { 245, 285 },
		["Чары для обуви - стойкость I"] = { 330, 360 },
		["Чары для обуви - стойкость II"] = { 380, 400 },
		["Чары для обуви - стойкость III"] = { 500, 510 },
		["Чары для обуви - стремительность"] = { 350, 380 },
		["Чары для обуви - штурм I"] = { 385, 405 },
		["Чары для обуви - штурм II"] = { 450, 470 },
		["Чары для обуви - штурм III"] = { 500, 510 },
		["Чары для одноручного оружия - благодать Ранульфа"] = { 510, 530 },
		["Чары для одноручного оружия - дыхание Сиф"] = { 510, 530 },
		["Чары для одноручного оружия - мощь Бьорна"] = { 510, 530 },
		["Чары для одноручного оружия - оберег Исулдофа"] = { 510, 530 },
		["Чары для одноручного оружия - пламя Фенгира"] = { 510, 530 },
		["Чары для одноручного оружия - проклятие Имирона"] = { 510, 530 },
		["Чары для одноручного оружия - руническая вязь Нарфи"] = { 500, 520 },
		["Чары для одноручного оружия - увядание Галдора"] = { 510, 530 },
		["Чары для одноручного оружия - чародейство Квалда"] = { 510, 530 },
		["Чары для оружия - Отведение удара"] = { 455, 465 },
		["Чары для оружия - берсерк"] = { 450, 470 },
		["Чары для оружия - берсерк II"] = { 500, 510 },
		["Чары для оружия - военачальник"] = { 370, 385 },
		["Чары для оружия - всплеск чар"] = { 370, 385 },
		["Чары для оружия - вытягивание крови"] = { 455, 465 },
		["Чары для оружия - дух II"] = { 420, 440 },
		["Чары для оружия - дух III"] = { 500, 510 },
		["Чары для оружия - зверобой I"] = { 120, 160 },
		["Чары для оружия - зверобой II"] = { 195, 235 },
		["Чары для оружия - интеллект I"] = { 350, 380 },
		["Чары для оружия - истребитель великанов"] = { 440, 460 },
		["Чары для оружия - истребитель демонов"] = { 250, 290 },
		["Чары для оружия - леденящая стужа"] = { 300, 335 },
		["Чары для оружия - ледорез"] = { 435, 455 },
		["Чары для оружия - ледяная душа"] = { 380, 390 },
		["Чары для оружия - лечение I"] = { 370, 380 },
		["Чары для оружия - ловкость I"] = { 305, 340 },
		["Чары для оружия - ловкость II"] = { 360, 375 },
		["Чары для оружия - ловкость III"] = { 420, 440 },
		["Чары для оружия - ловкость IV"] = { 500, 510 },
		["Чары для оружия - малое убийство элементалей"] = { 195, 235 },
		["Чары для оружия - мангуст"] = { 380, 390 },
		["Чары для оружия - мангуст II"] = { 500, 510 },
		["Чары для оружия - меткость"] = { 450, 470 },
		["Чары для оружия - меткость II"] = { 500, 510 },
		["Чары для оружия - могучий дух"] = { 310, 340 },
		["Чары для оружия - могучий интеллект"] = { 310, 340 },
		["Чары для оружия - могущество I"] = { 370, 380 },
		["Чары для оружия - могущество II"] = { 390, 410 },
		["Чары для оружия - могущество III"] = { 445, 465 },
		["Чары для оружия - могущество IV"] = { 500, 510 },
		["Чары для оружия - могущество зимы"] = { 210, 250 },
		["Чары для оружия - нечестивое оружие"] = { 310, 340 },
		["Чары для оружия - оберег"] = { 435, 455 },
		["Чары для оружия - огненное оружие"] = { 285, 325 },
		["Чары для оружия - палач"] = { 380, 390 },
		["Чары для оружия - похищение жизни"] = { 310, 340 },
		["Чары для оружия - рыцарь"] = { 310, 340 },
		["Чары для оружия - сила"] = { 305, 340 },
		["Чары для оружия - сила заклинаний"] = { 310, 340 },
		["Чары для оружия - сила заклинаний I"] = { 370, 380 },
		["Чары для оружия - сила заклинаний II"] = { 405, 425 },
		["Чары для оружия - сила заклинаний III"] = { 445, 465 },
		["Чары для оружия - сила заклинаний IV"] = { 500, 510 },
		["Чары для оружия - смертельный мороз"] = { 350, 365 },
		["Чары для оружия - солнечный огонь"] = { 390, 390 },
		["Чары для оружия - титановый страж"] = { 460, 480 },
		["Чары для оружия - удар I"] = { 120, 160 },
		["Чары для оружия - удар II"] = { 165, 205 },
		["Чары для оружия - удар III"] = { 215, 255 },
		["Чары для оружия - удар IV"] = { 265, 305 },
		["Чары для оружия - удар V"] = { 310, 340 },
		["Чары для оружия - удар VI"] = { 350, 380 },
		["Чары для оружия - целительная сила"] = { 310, 340 },
		["Чары для оружия - черная магия"] = { 450, 470 },
		["Чары для оружия - черная магия II"] = { 500, 510 },
		["Чары для перчаток - взрыв I"] = { 315, 345 },
		["Чары для перчаток - взрыв II"] = { 405, 420 },
		["Чары для перчаток - восполнение маны"] = { 490, 510 },
		["Чары для перчаток - восполнение маны II"] = { 510, 530 },
		["Чары для перчаток - выносливость"] = { 460, 490 },
		["Чары для перчаток - выносливость II"] = { 510, 530 },
		["Чары для перчаток - горное дело I"] = { 170, 210 },
		["Чары для перчаток - горное дело II"] = { 235, 275 },
		["Чары для перчаток - крушитель"] = { 435, 455 },
		["Чары для перчаток - крушитель II"] = { 500, 510 },
		["Чары для перчаток - лечение I"] = { 370, 380 },
		["Чары для перчаток - ловкость I"] = { 230, 270 },
		["Чары для перчаток - ловкость II"] = { 290, 330 },
		["Чары для перчаток - ловкость III"] = { 310, 340 },
		["Чары для перчаток - ловкость IV"] = { 425, 445 },
		["Чары для перчаток - ловкость V"] = { 500, 510 },
		["Чары для перчаток - мастерство"] = { 415, 435 },
		["Чары для перчаток - мастерство II"] = { 500, 510 },
		["Чары для перчаток - мастерство III"] = { 490, 510 },
		["Чары для перчаток - мастерство IV"] = { 510, 530 },
		["Чары для перчаток - навык верховой езды"] = { 270, 310 },
		["Чары для перчаток - оружейник"] = { 445, 465 },
		["Чары для перчаток - оружейник II"] = { 500, 510 },
		["Чары для перчаток - рыбная ловля"] = { 170, 210 },
		["Чары для перчаток - рыболов"] = { 385, 400 },
		["Чары для перчаток - сила I"] = { 245, 285 },
		["Чары для перчаток - сила II"] = { 310, 340 },
		["Чары для перчаток - сила III"] = { 350, 380 },
		["Чары для перчаток - сила атаки"] = { 490, 510 },
		["Чары для перчаток - сила атаки II"] = { 510, 530 },
		["Чары для перчаток - сила заклинаний I"] = { 370, 385 },
		["Чары для перчаток - сила заклинаний II"] = { 370, 390 },
		["Чары для перчаток - сила заклинаний III"] = { 500, 510 },
		["Чары для перчаток - сила заклинаний IV"] = { 510, 530 },
		["Чары для перчаток - сила льда"] = { 310, 340 },
		["Чары для перчаток - сила огня"] = { 310, 340 },
		["Чары для перчаток - слабое ускорение"] = { 270, 310 },
		["Чары для перчаток - снятие шкур"] = { 220, 260 },
		["Чары для перчаток - собиратель"] = { 370, 390 },
		["Чары для перчаток - точность"] = { 420, 440 },
		["Чары для перчаток - точные удары"] = { 370, 385 },
		["Чары для перчаток - травничество I"] = { 170, 210 },
		["Чары для перчаток - травничество II"] = { 245, 285 },
		["Чары для перчаток - угроза"] = { 310, 340 },
		["Чары для перчаток - целительная сила"] = { 310, 340 },
		["Чары для перчаток - штурм I"] = { 320, 350 },
		["Чары для перчаток - штурм II"] = { 405, 425 },
		["Чары для перчаток - энергия Тьмы"] = { 310, 340 },
		["Чары для плаща - броня"] = { 490, 510 },
		["Чары для плаща - броня I"] = { 110, 150 },
		["Чары для плаща - броня III"] = { 320, 350 },
		["Чары для плаща - восполнение маны"] = { 490, 510 },
		["Чары для плаща - восполнение маны II"] = { 510, 530 },
		["Чары для плаща - выносливость"] = { 460, 490 },
		["Чары для плаща - выносливость II"] = { 510, 530 },
		["Чары для плаща - защита"] = { 490, 510 },
		["Чары для плаща - защита I"] = { 175, 215 },
		["Чары для плаща - защита III"] = { 300, 335 },
		["Чары для плаща - колосс"] = { 500, 510 },
		["Чары для плаща - ловкость I"] = { 135, 175 },
		["Чары для плаща - ловкость II"] = { 245, 285 },
		["Чары для плаща - ловкость III"] = { 320, 350 },
		["Чары для плаща - ловкость IV"] = { 405, 425 },
		["Чары для плаща - ловкость V"] = { 430, 450 },
		["Чары для плаща - ловкость VI"] = { 500, 510 },
		["Чары для плаща - ловкость VII"] = { 460, 490 },
		["Чары для плаща - ловкость VIII"] = { 510, 530 },
		["Чары для плаща - мастерство"] = { 490, 510 },
		["Чары для плаща - мастерство II"] = { 510, 530 },
		["Чары для плаща - меткость"] = { 490, 510 },
		["Чары для плаща - меткость II"] = { 510, 530 },
		["Чары для плаща - могучая броня"] = { 440, 460 },
		["Чары для плаща - могучая броня II"] = { 500, 510 },
		["Чары для плаща - мудрость"] = { 450, 470 },
		["Чары для плаща - мудрость II"] = { 500, 510 },
		["Чары для плаща - незаметность"] = { 310, 340 },
		["Чары для плаща - пронзающие заклинания I"] = { 395, 410 },
		["Чары для плаща - пронзающие заклинания II"] = { 500, 510 },
		["Чары для плаща - пронзающие заклинания III"] = { 510, 530 },
		["Чары для плаща - проникающая способность заклинаний"] = { 335, 365 },
		["Чары для плаща - сила атаки"] = { 500, 520 },
		["Чары для плаща - сила атаки II"] = { 510, 530 },
		["Чары для плаща - сила заклинаний"] = { 500, 520 },
		["Чары для плаща - сила заклинаний II"] = { 510, 530 },
		["Чары для плаща - скорость I"] = { 360, 380 },
		["Чары для плаща - скорость II"] = { 440, 460 },
		["Чары для плаща - скорость IV"] = { 510, 530 },
		["Чары для плаща - скрытность"] = { 310, 340 },
		["Чары для плаща - сопротивление I"] = { 95, 135 },
		["Чары для плаща - сопротивление II"] = { 225, 265 },
		["Чары для плаща - сопротивление III"] = { 285, 325 },
		["Чары для плаща - сопротивление IV"] = { 340, 370 },
		["Чары для плаща - сопротивление V"] = { 500, 510 },
		["Чары для плаща - сопротивление VI"] = { 500, 520 },
		["Чары для плаща - сопротивление VII"] = { 510, 530 },
		["Чары для плаща - сопротивление магии льда"] = { 415, 435 },
		["Чары для плаща - сопротивление огню"] = { 195, 235 },
		["Чары для плаща - сопротивление огню II"] = { 150, 190 },
		["Чары для плаща - сопротивление огню III"] = { 310, 340 },
		["Чары для плаща - сопротивление огню IV"] = { 415, 435 },
		["Чары для плаща - сопротивление силам природы I"] = { 310, 340 },
		["Чары для плаща - сопротивление силам природы II"] = { 415, 435 },
		["Чары для плаща - сопротивление тайной магии I"] = { 370, 380 },
		["Чары для плаща - сопротивление тайной магии II"] = { 415, 435 },
		["Чары для плаща - сопротивление темной магии I"] = { 160, 200 },
		["Чары для плаща - сопротивление темной магии II"] = { 370, 380 },
		["Чары для плаща - сопротивление темной магии III"] = { 415, 435 },
		["Чары для плаща - стальная ткань"] = { 380, 390 },
		["Чары для плаща - теневая броня"] = { 450, 470 },
		["Чары для плаща - ткань титанов"] = { 445, 465 },
		["Чары для плаща - ткань титанов II"] = { 500, 510 },
		["Чары для плаща - уклонение"] = { 310, 340 },
		["Чары для посоха - сила заклинаний I"] = { 395, 415 },
		["Чары для посоха - сила заклинаний II"] = { 455, 465 },
		["Чары для посоха - сила заклинаний III"] = { 500, 510 },
		["Чары для щита - Живучесть"] = { 300, 340 },
		["Чары для щита - блок I"] = { 215, 255 },
		["Чары для щита - блок II"] = { 350, 380 },
		["Чары для щита - блок III"] = { 500, 510 },
		["Чары для щита - блокирование"] = { 490, 510 },
		["Чары для щита - блокирование II"] = { 510, 530 },
		["Чары для щита - броня I"] = { 140, 180 },
		["Чары для щита - восполнение маны"] = { 490, 510 },
		["Чары для щита - восполнение маны II"] = { 510, 530 },
		["Чары для щита - выносливость"] = { 460, 490 },
		["Чары для щита - выносливость I"] = { 130, 170 },
		["Чары для щита - выносливость III"] = { 230, 270 },
		["Чары для щита - выносливость IV"] = { 285, 325 },
		["Чары для щита - выносливость V"] = { 335, 365 },
		["Чары для щита - выносливость VI"] = { 500, 510 },
		["Чары для щита - дух I"] = { 155, 195 },
		["Чары для щита - дух II"] = { 200, 240 },
		["Чары для щита - дух III"] = { 250, 290 },
		["Чары для щита - интеллект"] = { 460, 490 },
		["Чары для щита - интеллект I"] = { 335, 365 },
		["Чары для щита - интеллект III"] = { 500, 510 },
		["Чары для щита - показатель блокирования"] = { 490, 510 },
		["Чары для щита - показатель блокирования II"] = { 510, 530 },
		["Чары для щита - прочный щит"] = { 320, 350 },
		["Чары для щита - сила заклинаний"] = { 500, 520 },
		["Чары для щита - сила заклинаний II"] = { 510, 530 },
		["Чары для щита - сопротивление"] = { 370, 385 },
		["Чары для щита - сопротивление II"] = { 500, 510 },
		["Чары для щита - сопротивление VI"] = { 500, 520 },
		["Чары для щита - сопротивление VII"] = { 510, 530 },
		["Чары для щита - сопротивление льду"] = { 255, 295 },
	},
	[755] = {
		["Аквамариновая подвеска воина"] = { 245, 275 },
		["Аквамариновый оберег"] = { 270, 300 },
		["Аквамариновый перстень"] = { 235, 265 },
		["Александрит сенсея"] = { 475, 485 },
		["Алмаз жестокого землеправителя"] = { 440, 460 },
		["Алмаз жестокой земной бури"] = { 375, 380 },
		["Алмаз строгого землеправителя"] = { 440, 460 },
		["Алый перстень"] = { 440, 460 },
		["Алый перстень претендента"] = { 470, 490 },
		["Аметрин авангарда"] = { 440, 465 },
		["Аметрин варвара"] = { 440, 465 },
		["Аметрин защитника"] = { 440, 465 },
		["Аметрин проворства"] = { 440, 465 },
		["Аметрин фехтовальщика"] = { 440, 465 },
		["Амулет Луны"] = { 140, 170 },
		["Амулет бьющего ключа"] = { 375, 385 },
		["Амулет из небесного сапфира"] = { 440, 460 },
		["Амулет из небесного сапфира претендента"] = { 470, 490 },
		["Амулет проницательности"] = { 210, 230 },
		["Амулет с кристаллом кальцедония"] = { 380, 420 },
		["Бездушный алмаз небесного сияния"] = { 440, 460 },
		["Бездушный изначальный алмаз"] = { 520, 530 },
		["Бездушный мглистый алмаз"] = { 500, 510 },
		["Блестящая Звезда Элуны"] = { 350, 380 },
		["Блестящее око дракона"] = { 390, 440 },
		["Блестящее сердце реки"] = { 520, 530 },
		["Блестящий Глаз химеры"] = { 470, 490 },
		["Блестящий величественный циркон"] = { 440, 465 },
		["Блестящий зефирит"] = { 500, 510 },
		["Блестящий кальцедоний"] = { 375, 415 },
		["Блестящий лазурит"] = { 505, 515 },
		["Блестящий лазурный лунный камень"] = { 325, 355 },
		["Блестящий небесный сапфир"] = { 410, 440 },
		["Блестящий неземной сапфир"] = { 375, 385 },
		["Блистательная пунцовая шпинель"] = { 375, 385 },
		["Блистательное око дракона"] = { 390, 440 },
		["Блистательный Глаз химеры"] = { 470, 490 },
		["Блистательный алый рубин"] = { 410, 440 },
		["Блистательный багровый рубин"] = { 440, 465 },
		["Блистательный врайкульский гранат"] = { 500, 510 },
		["Блистательный животворный рубин"] = { 350, 380 },
		["Блистательный кровавый камень"] = { 375, 415 },
		["Блистательный первозданный рубин"] = { 520, 530 },
		["Блистательный сердолик"] = { 500, 510 },
		["Блистающий аметрин"] = { 440, 465 },
		["Блистающий благородный топаз"] = { 350, 380 },
		["Блистающий гессонит"] = { 500, 510 },
		["Блистающий императорский аметист"] = { 520, 530 },
		["Блистающий императорский топаз"] = { 410, 440 },
		["Блистающий огнекамень"] = { 375, 385 },
		["Блистающий огромный цитрин"] = { 375, 415 },
		["Блистающий пламенный спессарит"] = { 315, 355 },
		["Блистающий плутовской камень"] = { 510, 520 },
		["Бриллиантовое кольцо концентрации"] = { 285, 305 },
		["Бронзовая оправа"] = { 70, 90 },
		["Бронзовое кольцо силы"] = { 95, 125 },
		["Бронзовое ожерелье"] = { 110, 140 },
		["Броский аметрин"] = { 440, 465 },
		["Броский гессонит"] = { 500, 510 },
		["Броский закатный оникс"] = { 520, 530 },
		["Броский императорский топаз"] = { 410, 440 },
		["Броский огромный цитрин"] = { 375, 415 },
		["Броский тигровый опал"] = { 510, 520 },
		["Варварский железный ошейник"] = { 140, 170 },
		["Варварский закатный оникс"] = { 520, 530 },
		["Варварский тигровый опал"] = { 460, 470 },
		["Великий золотой дренит"] = { 325, 355 },
		["Великий зоревик"] = { 350, 380 },
		["Великий львиный глаз"] = { 375, 385 },
		["Великолепный закатный оникс"] = { 520, 530 },
		["Великолепный тигровый опал"] = { 495, 505 },
		["Венец Чародейской мощи"] = { 375, 385 },
		["Венок Зеленого Пламени"] = { 375, 385 },
		["Вечный алмаз землеправителя"] = { 440, 460 },
		["Вечный алмаз земной бури"] = { 375, 380 },
		["Вечный изначальный алмаз"] = { 520, 530 },
		["Вечный мглистый алмаз"] = { 500, 510 },
		["Вневременная яшма"] = { 500, 510 },
		["Вневременное Око Зула"] = { 440, 465 },
		["Вневременной императорский аметист"] = { 520, 530 },
		["Вневременной лесной изумруд"] = { 410, 440 },
		["Вневременной плутовской камень"] = { 500, 510 },
		["Вневременной темный нефрит"] = { 375, 415 },
		["Всевластный александрит"] = { 475, 485 },
		["Всевластный камень ночи"] = { 500, 510 },
		["Всевластный самородный нефрит"] = { 520, 530 },
		["Всевластный страхолит"] = { 440, 465 },
		["Всевластный сумеречный опал"] = { 410, 440 },
		["Всевластный сумрачный кристалл"] = { 375, 415 },
		["Гессонит авангарда"] = { 500, 510 },
		["Гессонит варвара"] = { 500, 510 },
		["Гессонит защитника"] = { 500, 510 },
		["Гессонит проворства"] = { 500, 510 },
		["Гессонит фехтовальщика"] = { 500, 510 },
		["Гибельное кольцо лунного камня"] = { 155, 185 },
		["Гибельный аметрин"] = { 440, 465 },
		["Гибельный благородный топаз"] = { 350, 380 },
		["Гибельный гессонит"] = { 500, 510 },
		["Гибельный закатный оникс"] = { 520, 530 },
		["Гибельный императорский топаз"] = { 410, 440 },
		["Гибельный огнекамень"] = { 375, 385 },
		["Гибельный огромный цитрин"] = { 375, 415 },
		["Гибельный пламенный спессарит"] = { 325, 355 },
		["Гибельный тигровый опал"] = { 505, 515 },
		["Гладкий Глаз химеры"] = { 470, 490 },
		["Гладкий алицит"] = { 500, 510 },
		["Гладкий золотой дренит"] = { 325, 355 },
		["Гладкий зоревик"] = { 350, 380 },
		["Гладкий львиный глаз"] = { 375, 385 },
		["Гладкий солнечный камень"] = { 460, 470 },
		["Гладкий солнечный хрусталь"] = { 375, 415 },
		["Гладкий солнцесвет"] = { 520, 530 },
		["Гладкий царский янтарь"] = { 440, 465 },
		["Гладкое око дракона"] = { 390, 440 },
		["Гладкое сияние осени"] = { 410, 440 },
		["Глянцевый аметрин"] = { 440, 465 },
		["Глянцевый гессонит"] = { 500, 510 },
		["Глянцевый закатный оникс"] = { 520, 530 },
		["Глянцевый императорский топаз"] = { 410, 440 },
		["Глянцевый огромный цитрин"] = { 375, 415 },
		["Глянцевый тигровый опал"] = { 500, 510 },
		["Горящий изначальный алмаз"] = { 520, 530 },
		["Гравированный аметрин"] = { 440, 465 },
		["Гравированный гессонит"] = { 500, 510 },
		["Гравированный императорский аметист"] = { 520, 530 },
		["Гравированный императорский топаз"] = { 410, 440 },
		["Гравированный огромный цитрин"] = { 375, 415 },
		["Гравированный плутовской камень"] = { 475, 485 },
		["Грань вечности"] = { 365, 375 },
		["Грозовая Звезда Элуны"] = { 350, 380 },
		["Грозовое око дракона"] = { 390, 440 },
		["Грозовое сердце реки"] = { 520, 530 },
		["Грозовой Глаз химеры"] = { 470, 490 },
		["Грозовой величественный циркон"] = { 440, 465 },
		["Грозовой зефирит"] = { 500, 510 },
		["Грозовой кальцедоний"] = { 375, 415 },
		["Грозовой лазурит"] = { 460, 470 },
		["Грозовой лазурный лунный камень"] = { 315, 355 },
		["Грозовой небесный сапфир"] = { 410, 440 },
		["Грозовой неземной сапфир"] = { 375, 385 },
		["Громовой алмаз небесного огня"] = { 375, 380 },
		["Громовой алмаз небесного сияния"] = { 440, 460 },
		["Громовой мглистый алмаз"] = { 500, 510 },
		["Грубый алмаз земной бури"] = { 375, 380 },
		["Грубый аметрин"] = { 440, 465 },
		["Грубый гессонит"] = { 500, 510 },
		["Грубый закатный оникс"] = { 520, 530 },
		["Грубый тигровый опал"] = { 465, 475 },
		["Жалкий алмаз небесного сияния"] = { 440, 460 },
		["Жалкий изначальный алмаз"] = { 520, 530 },
		["Жалкий мглистый алмаз"] = { 500, 510 },
		["Жестокий мглистый алмаз"] = { 500, 510 },
		["Живительный алмаз землеправителя"] = { 440, 460 },
		["Живительный мглистый алмаз"] = { 500, 510 },
		["Живой александрит"] = { 485, 495 },
		["Живой самородный нефрит"] = { 520, 530 },
		["Загадочный алмаз небесного огня"] = { 375, 380 },
		["Загадочный алмаз небесного сияния"] = { 440, 460 },
		["Загадочный изначальный алмаз"] = { 520, 530 },
		["Загадочный мглистый алмаз"] = { 500, 510 },
		["Зазубренная яшма"] = { 500, 510 },
		["Зазубренное Око Зула"] = { 440, 465 },
		["Зазубренный александрит"] = { 510, 520 },
		["Зазубренный лесной изумруд"] = { 410, 440 },
		["Зазубренный морской изумруд"] = { 375, 385 },
		["Зазубренный самородный нефрит"] = { 520, 530 },
		["Зазубренный талассит"] = { 350, 380 },
		["Зазубренный темный нефрит"] = { 375, 415 },
		["Зазубренный хризолит"] = { 305, 345 },
		["Закатный оникс авангарда"] = { 520, 530 },
		["Закатный оникс адепта"] = { 520, 530 },
		["Закатный оникс воителя"] = { 520, 530 },
		["Закатный оникс проворства"] = { 520, 530 },
		["Закатный оникс фехтовальщика"] = { 520, 530 },
		["Замысловатая яшма"] = { 500, 510 },
		["Замысловатое Око Зула"] = { 440, 465 },
		["Замысловатый лесной изумруд"] = { 410, 440 },
		["Замысловатый темный нефрит"] = { 375, 415 },
		["Заостренный алмаз землеправителя"] = { 440, 460 },
		["Заостренный мглистый алмаз"] = { 500, 510 },
		["Заряженное око ночи"] = { 350, 380 },
		["Заряженный аметист Песни Теней"] = { 375, 385 },
		["Заряженный камень ночи"] = { 500, 510 },
		["Заряженный страхолит"] = { 440, 465 },
		["Заряженный сумеречный опал"] = { 410, 440 },
		["Заряженный сумрачный дренит"] = { 325, 355 },
		["Заряженный сумрачный кристалл"] = { 375, 415 },
		["Застывшее око"] = { 375, 385 },
		["Застывший аметрин"] = { 440, 465 },
		["Застывший гессонит"] = { 500, 510 },
		["Застывший императорский топаз"] = { 410, 440 },
		["Застывший огромный цитрин"] = { 375, 415 },
		["Затвердевший аметрин"] = { 440, 465 },
		["Затвердевший гессонит"] = { 500, 510 },
		["Затвердевший закатный оникс"] = { 520, 530 },
		["Затвердевший императорский топаз"] = { 410, 440 },
		["Затвердевший огромный цитрин"] = { 375, 415 },
		["Затвердевший тигровый опал"] = { 485, 495 },
		["Зачарованная жемчужина"] = { 380, 420 },
		["Зачарованная слеза"] = { 410, 440 },
		["Звонкий изначальный алмаз"] = { 520, 530 },
		["Золотое кольцо власти"] = { 190, 210 },
		["Золотое кольцо с дренитом"] = { 320, 350 },
		["Идеально ограненный аметрин"] = { 440, 465 },
		["Идеально ограненный гессонит"] = { 500, 510 },
		["Идеально ограненный императорский аметист"] = { 520, 530 },
		["Идеально ограненный императорский топаз"] = { 410, 440 },
		["Идеально ограненный огромный цитрин"] = { 375, 415 },
		["Идеально ограненный плутовской камень"] = { 460, 470 },
		["Изменчивое око ночи"] = { 350, 380 },
		["Изменчивый аметист Песни Теней"] = { 375, 385 },
		["Изменчивый императорский аметист"] = { 520, 530 },
		["Изменчивый камень ночи"] = { 500, 510 },
		["Изменчивый плутовской камень"] = { 490, 500 },
		["Изменчивый страхолит"] = { 440, 465 },
		["Изменчивый сумеречный опал"] = { 410, 440 },
		["Изменчивый сумрачный дренит"] = { 315, 355 },
		["Изменчивый сумрачный кристалл"] = { 375, 415 },
		["Изначальная каменная статуя"] = { 300, 320 },
		["Изначальный алмаз"] = { 510, 520 },
		["Изумрудная корона разрушения"] = { 285, 305 },
		["Изумрудное колье"] = { 440, 460 },
		["Изумрудное колье претендента"] = { 470, 490 },
		["Изумрудное кольцо льва"] = { 300, 320 },
		["Изумрудный кабан"] = { 430, 450 },
		["Изысканная пунцовая шпинель"] = { 375, 385 },
		["Изысканное ожерелье тигрового глаза"] = { 60, 90 },
		["Изысканное око дракона"] = { 390, 440 },
		["Изысканное этерниевое кольцо"] = { 365, 385 },
		["Изысканный Глаз химеры"] = { 470, 490 },
		["Изысканный алый рубин"] = { 410, 440 },
		["Изысканный багровый рубин"] = { 440, 465 },
		["Изысканный животворный рубин"] = { 350, 380 },
		["Изысканный кровавый гранат"] = { 325, 355 },
		["Изысканный кровавый камень"] = { 375, 415 },
		["Изысканный сердолик"] = { 500, 510 },
		["Изящная пунцовая шпинель"] = { 375, 385 },
		["Изящное око дракона"] = { 390, 440 },
		["Изящный Глаз химеры"] = { 470, 490 },
		["Изящный алый рубин"] = { 410, 440 },
		["Изящный багровый рубин"] = { 440, 465 },
		["Изящный врайкульский гранат"] = { 465, 475 },
		["Изящный животворный рубин"] = { 350, 380 },
		["Изящный кровавый камень"] = { 375, 415 },
		["Изящный первозданный рубин"] = { 520, 530 },
		["Изящный сердолик"] = { 500, 510 },
		["Императорский аметист защитника"] = { 520, 530 },
		["Императорский аметист стража"] = { 520, 530 },
		["Императорский аметист убийцы"] = { 520, 530 },
		["Императорский топаз воителя"] = { 410, 440 },
		["Императорский топаз проворства"] = { 410, 440 },
		["Инкрустированное малахитом кольцо"] = { 60, 90 },
		["Инфернальное кориевое кольцо"] = { 365, 380 },
		["Искаженный александрит"] = { 470, 480 },
		["Искаженный самородный нефрит"] = { 520, 530 },
		["Искристый золотой дренит"] = { 305, 345 },
		["Искристый зоревик"] = { 350, 380 },
		["Искристый львиный глаз"] = { 375, 385 },
		["Искрящаяся Звезда Элуны"] = { 350, 380 },
		["Искрящееся око дракона"] = { 390, 440 },
		["Искрящееся сердце реки"] = { 520, 530 },
		["Искрящийся Глаз химеры"] = { 470, 490 },
		["Искрящийся величественный циркон"] = { 440, 465 },
		["Искрящийся зефирит"] = { 500, 510 },
		["Искрящийся кальцедоний"] = { 375, 415 },
		["Искрящийся лазурит"] = { 490, 500 },
		["Искрящийся лазурный лунный камень"] = { 305, 345 },
		["Искрящийся небесный сапфир"] = { 410, 440 },
		["Искрящийся неземной сапфир"] = { 375, 385 },
		["Искусный закатный оникс"] = { 520, 530 },
		["Искусный тигровый опал"] = { 465, 475 },
		["Камень клинков"] = { 365, 375 },
		["Камень ночи защитника"] = { 500, 510 },
		["Камень ночи стража"] = { 500, 510 },
		["Каплевидная пунцовая шпинель"] = { 375, 385 },
		["Каплевидный животворный рубин"] = { 350, 380 },
		["Каплевидный кровавый гранат"] = { 300, 340 },
		["Коварный закатный оникс"] = { 520, 530 },
		["Коварный тигровый опал"] = { 465, 475 },
		["Колье из закаленного кория"] = { 375, 385 },
		["Кольцо Солнечного Камня"] = { 380, 420 },
		["Кольцо алых теней"] = { 440, 460 },
		["Кольцо бьющего ключа"] = { 375, 385 },
		["Кольцо жестоких теней"] = { 295, 315 },
		["Кольцо золотого дракона"] = { 165, 195 },
		["Кольцо из закаленного кория"] = { 375, 385 },
		["Кольцо камнестража"] = { 410, 430 },
		["Кольцо командора из истинного серебра"] = { 210, 230 },
		["Кольцо кровавого камня"] = { 380, 420 },
		["Кольцо нападения"] = { 290, 310 },
		["Кольцо огненного ветра"] = { 440, 460 },
		["Кольцо оступившегося льва"] = { 525, 535 },
		["Кольцо полуночного неба"] = { 475, 500 },
		["Кольцо природного огня"] = { 320, 340 },
		["Кольцо с тигровым глазом"] = { 50, 80 },
		["Кольцо силы земли"] = { 440, 460 },
		["Кольцо скованной мощи"] = { 375, 385 },
		["Кольцо сумеречных призраков"] = { 130, 160 },
		["Кольцо темного могущества"] = { 410, 430 },
		["Кольцо тени земли"] = { 390, 420 },
		["Кольцо хладных слез"] = { 440, 460 },
		["Кольцо чародейской защиты"] = { 370, 380 },
		["Кориевое кольцо листвы"] = { 370, 380 },
		["Кориевое кольцо льда"] = { 365, 380 },
		["Кориевое кольцо тайной магии"] = { 370, 380 },
		["Кориевое кольцо теней"] = { 360, 380 },
		["Королевский аметист Песни Теней"] = { 375, 385 },
		["Королевский камень ночи"] = { 500, 510 },
		["Королевский краб"] = { 430, 450 },
		["Королевский страхолит"] = { 440, 465 },
		["Королевский сумеречный опал"] = { 410, 440 },
		["Королевский сумрачный дренит"] = { 305, 345 },
		["Королевский сумрачный кристалл"] = { 375, 415 },
		["Королевское око ночи"] = { 350, 380 },
		["Корона Крови"] = { 335, 355 },
		["Корона лунной души"] = { 150, 180 },
		["Корона морской ведьмы"] = { 375, 385 },
		["Краеугольный аметрин"] = { 440, 465 },
		["Краеугольный гессонит"] = { 500, 510 },
		["Краеугольный закатный оникс"] = { 520, 530 },
		["Краеугольный тигровый опал"] = { 485, 495 },
		["Красное кольцо разрушения"] = { 255, 285 },
		["Крепкая Яшма"] = { 500, 510 },
		["Крепкий алмаз земной бури"] = { 375, 380 },
		["Крепкий императорский аметист"] = { 520, 530 },
		["Крепкий плутовской камень"] = { 510, 520 },
		["Крепкое Око Зула"] = { 440, 465 },
		["Кровавое кольцо из оскверненного железа"] = { 320, 340 },
		["Лазурное кольцо из лунного камня"] = { 330, 350 },
		["Ледяная призма"] = { 445, 470 },
		["Лесной изумруд провидца"] = { 410, 440 },
		["Лучащийся алмаз землеправителя"] = { 440, 460 },
		["Лучащийся мглистый алмаз"] = { 500, 510 },
		["Лучезарный александрит"] = { 480, 490 },
		["Лучезарный алмаз небесного сияния"] = { 440, 460 },
		["Лучезарный изначальный алмаз"] = { 520, 530 },
		["Лучезарный мглистый алмаз"] = { 500, 510 },
		["Лучезарный самородный нефрит"] = { 520, 530 },
		["Лучистая яшма"] = { 500, 510 },
		["Лучистое Око Зула"] = { 440, 465 },
		["Лучистый лесной изумруд"] = { 410, 440 },
		["Лучистый темный нефрит"] = { 375, 415 },
		["Малахитовая подвеска"] = { 50, 80 },
		["Массивная каменная статуя"] = { 120, 140 },
		["Мастерский закатный оникс"] = { 520, 530 },
		["Мастерский тигровый опал"] = { 475, 485 },
		["Матовое око дракона"] = { 390, 440 },
		["Матовое сияние осени"] = { 410, 440 },
		["Матовый Глаз химеры"] = { 470, 490 },
		["Матовый алицит"] = { 500, 510 },
		["Матовый золотой дренит"] = { 315, 355 },
		["Матовый зоревик"] = { 350, 380 },
		["Матовый львиный глаз"] = { 375, 385 },
		["Матовый солнечный камень"] = { 505, 515 },
		["Матовый солнечный хрусталь"] = { 375, 415 },
		["Матовый солнцесвет"] = { 520, 530 },
		["Матовый царский янтарь"] = { 440, 465 },
		["Мерцающий аметрин"] = { 440, 465 },
		["Мерцающий гессонит"] = { 500, 510 },
		["Мерцающий императорский топаз"] = { 410, 440 },
		["Мерцающий огромный цитрин"] = { 375, 415 },
		["Мечта о Море"] = { 525, 535 },
		["Мистический Глаз химеры"] = { 470, 490 },
		["Мистический алицит"] = { 500, 510 },
		["Мистический алмаз небесного огня"] = { 375, 380 },
		["Мистический зоревик"] = { 350, 380 },
		["Мистический львиный глаз"] = { 375, 385 },
		["Мистический солнечный камень"] = { 500, 510 },
		["Мистический солнечный хрусталь"] = { 375, 415 },
		["Мистический солнцесвет"] = { 520, 530 },
		["Мистический царский янтарь"] = { 440, 465 },
		["Мистическое око дракона"] = { 390, 440 },
		["Мистическое сияние осени"] = { 410, 440 },
		["Мифриловая филигрань"] = { 170, 190 },
		["Могучий изначальный алмаз"] = { 520, 530 },
		["Могущественный алмаз землеправителя"] = { 440, 460 },
		["Могущественный алмаз земной бури"] = { 375, 380 },
		["Могущественный аметрин"] = { 440, 465 },
		["Могущественный благородный топаз"] = { 350, 380 },
		["Могущественный гессонит"] = { 500, 510 },
		["Могущественный закатный оникс"] = { 520, 530 },
		["Могущественный императорский топаз"] = { 410, 440 },
		["Могущественный мглистый алмаз"] = { 500, 510 },
		["Могущественный огнекамень"] = { 375, 385 },
		["Могущественный огромный цитрин"] = { 375, 415 },
		["Могущественный пламенный спессарит"] = { 325, 355 },
		["Могущественный тигровый опал"] = { 470, 480 },
		["Молниевый александрит"] = { 470, 480 },
		["Молниевый самородный нефрит"] = { 520, 530 },
		["Монаршее око ночи"] = { 350, 380 },
		["Монарший александрит"] = { 460, 470 },
		["Монарший камень ночи"] = { 500, 510 },
		["Монарший самородный нефрит"] = { 520, 530 },
		["Монарший страхолит"] = { 440, 465 },
		["Монарший сумеречный опал"] = { 410, 440 },
		["Монарший сумрачный кристалл"] = { 375, 415 },
		["Монументальный камень ночи"] = { 500, 510 },
		["Монументальный страхолит"] = { 440, 465 },
		["Мощная яшма"] = { 500, 510 },
		["Мощное Око Зула"] = { 440, 465 },
		["Мощный александрит"] = { 465, 475 },
		["Мощный лесной изумруд"] = { 410, 440 },
		["Мощный морской изумруд"] = { 375, 385 },
		["Мощный самородный нефрит"] = { 520, 530 },
		["Мощный талассит"] = { 350, 380 },
		["Мощный темный нефрит"] = { 375, 415 },
		["Мрачное кольцо"] = { 100, 130 },
		["Мстительный императорский аметист"] = { 520, 530 },
		["Мстительный плутовской камень"] = { 470, 480 },
		["Мягкий Глаз химеры"] = { 470, 490 },
		["Мягкий алицит"] = { 500, 510 },
		["Мягкий зоревик"] = { 350, 380 },
		["Мягкий львиный глаз"] = { 375, 385 },
		["Мягкий солнечный камень"] = { 470, 480 },
		["Мягкий солнечный хрусталь"] = { 375, 415 },
		["Мягкий солнцесвет"] = { 520, 530 },
		["Мягкий царский янтарь"] = { 440, 465 },
		["Мягкое око дракона"] = { 390, 440 },
		["Мягкое сияние осени"] = { 410, 440 },
		["Надежный аметрин"] = { 440, 465 },
		["Надежный гессонит"] = { 500, 510 },
		["Надежный императорский топаз"] = { 410, 440 },
		["Надежный огромный цитрин"] = { 375, 415 },
		["Наделенный силой аметрин"] = { 440, 465 },
		["Наделенный силой гессонит"] = { 500, 510 },
		["Наделенный силой императорский топаз"] = { 410, 440 },
		["Наделенный силой огромный цитрин"] = { 375, 415 },
		["Наследный камень императора"] = { 475, 500 },
		["Насыщенная яшма"] = { 500, 510 },
		["Насыщенное Око Зула"] = { 440, 465 },
		["Насыщенный александрит"] = { 495, 505 },
		["Насыщенный лесной изумруд"] = { 410, 440 },
		["Насыщенный самородный нефрит"] = { 520, 530 },
		["Насыщенный темный нефрит"] = { 375, 415 },
		["Незыблемый алмаз землеправителя"] = { 440, 460 },
		["Незыблемый мглистый алмаз"] = { 500, 510 },
		["Неизменная яшма"] = { 500, 510 },
		["Неизменное Око Зула"] = { 440, 465 },
		["Неизменный александрит"] = { 480, 490 },
		["Неизменный лесной изумруд"] = { 410, 440 },
		["Неизменный морской изумруд"] = { 375, 385 },
		["Неизменный самородный нефрит"] = { 520, 530 },
		["Неизменный талассит"] = { 350, 380 },
		["Неизменный темный нефрит"] = { 375, 415 },
		["Неограненный изначальный алмаз"] = { 520, 530 },
		["Неподатливый закатный оникс"] = { 520, 530 },
		["Неподатливый тигровый опал"] = { 490, 500 },
		["Непоколебимое око дракона"] = { 500, 510 },
		["Непоколебимый Глаз химеры"] = { 470, 490 },
		["Непоколебимый багровый рубин"] = { 500, 510 },
		["Непоколебимый врайкульский гранат"] = { 510, 520 },
		["Непоколебимый первозданный рубин"] = { 520, 530 },
		["Непоколебимый сердолик"] = { 500, 510 },
		["Непрозрачная яшма"] = { 500, 510 },
		["Непрозрачное Око Зула"] = { 440, 465 },
		["Непрозрачный лесной изумруд"] = { 410, 440 },
		["Непрозрачный темный нефрит"] = { 375, 415 },
		["Непрочный камень ночи"] = { 500, 510 },
		["Непрочный страхолит"] = { 440, 465 },
		["Непрочный сумеречный опал"] = { 410, 440 },
		["Непрочный сумрачный кристалл"] = { 375, 415 },
		["Нерушимый алмаз землеправителя"] = { 440, 460 },
		["Нерушимый алмаз земной бури"] = { 375, 380 },
		["Нерушимый мглистый алмаз"] = { 500, 510 },
		["Нетронутый аметрин"] = { 440, 465 },
		["Нетронутый гессонит"] = { 500, 510 },
		["Нетронутый императорский топаз"] = { 410, 440 },
		["Нетронутый огромный цитрин"] = { 375, 415 },
		["Неустанный алмаз небесного сияния"] = { 440, 460 },
		["Неустанный мглистый алмаз "] = { 500, 510 },
		["Нефритовая подвеска взрыва"] = { 190, 220 },
		["Нефритовое кольцо истребления"] = { 390, 420 },
		["Нефритовое око"] = { 200, 230 },
		["Нефритовый кинжал-подвеска"] = { 400, 420 },
		["Объятия рассвета"] = { 375, 385 },
		["Ограненный камень хиджальских гор"] = { 475, 500 },
		["Огромный цитрин воителя"] = { 375, 415 },
		["Огромный цитрин проворства"] = { 375, 415 },
		["Ожерелье Адамантовой башни"] = { 315, 335 },
		["Ожерелье Кровавого солнца"] = { 400, 420 },
		["Ожерелье глубин"] = { 340, 370 },
		["Ожерелье небесного мага"] = { 525, 535 },
		["Ожерелье с кристаллом цитрина"] = { 380, 420 },
		["Оживляющий алмаз небесного сияния"] = { 440, 460 },
		["Оживляющий изначальный алмаз"] = { 520, 530 },
		["Оживляющий мглистый алмаз"] = { 500, 510 },
		["Око Зула провидца"] = { 440, 465 },
		["Око ночи"] = { 370, 380 },
		["Округленный аметрин"] = { 440, 465 },
		["Округленный гессонит"] = { 500, 510 },
		["Округленный закатный оникс"] = { 520, 530 },
		["Округленный тигровый опал"] = { 470, 480 },
		["Опаловое ожерелье столкновения"] = { 275, 305 },
		["Оплетенная этерниевая кольчуга"] = { 370, 385 },
		["Оплетенное медное кольцо"] = { 30, 60 },
		["Ослепительная яшма"] = { 500, 510 },
		["Ослепительное Око Зула"] = { 440, 465 },
		["Ослепительный лесной изумруд"] = { 410, 440 },
		["Ослепительный морской изумруд"] = { 375, 385 },
		["Ослепительный талассит"] = { 350, 380 },
		["Ослепительный темный нефрит"] = { 375, 415 },
		["Ослепительный хризолит"] = { 325, 355 },
		["Острый закатный оникс"] = { 520, 530 },
		["Острый тигровый опал"] = { 460, 470 },
		["Отверделая яшма"] = { 500, 510 },
		["Отверделое Око Зула"] = { 440, 465 },
		["Отверделый лесной изумруд"] = { 410, 440 },
		["Отверделый морской изумруд"] = { 375, 385 },
		["Отверделый талассит"] = { 350, 380 },
		["Отверделый темный нефрит"] = { 375, 415 },
		["Отверделый хризолит"] = { 315, 355 },
		["Очищенная жемчужина джаггала"] = { 325, 340 },
		["Очищенная сумрачная жемчужина"] = { 350, 380 },
		["Очищенный аметист Песни Теней"] = { 375, 385 },
		["Очищенный императорский аметист"] = { 520, 530 },
		["Очищенный камень ночи"] = { 500, 510 },
		["Очищенный плутовской камень"] = { 485, 495 },
		["Очищенный страхолит"] = { 440, 465 },
		["Очищенный сумеречный опал"] = { 410, 440 },
		["Очищенный сумрачный кристалл"] = { 375, 415 },
		["Падающая звезда"] = { 365, 375 },
		["Переменчивый адамантит"] = { 325, 345 },
		["Перстень грез"] = { 440, 460 },
		["Перстень повелителя"] = { 525, 535 },
		["Плетеное медное кольцо"] = { 30, 60 },
		["Плотная яшма"] = { 500, 510 },
		["Плотное Око Зула"] = { 440, 465 },
		["Плотный александрит"] = { 485, 495 },
		["Плотный лесной изумруд"] = { 410, 440 },
		["Плотный самородный нефрит"] = { 520, 530 },
		["Плотный темный нефрит"] = { 375, 415 },
		["Плутовской камень защитника"] = { 505, 515 },
		["Плутовской камень стража"] = { 495, 505 },
		["Плутовской камень убийцы"] = { 510, 520 },
		["Поводья кристаллического охотника"] = { 535, 545 },
		["Подвеска Агатового Щита"] = { 150, 180 },
		["Подвеска Оттепели"] = { 370, 380 },
		["Подвеска замерзшего пламени"] = { 370, 380 },
		["Подвеска из арканитового меча"] = { 325, 345 },
		["Подвеска из животворного изумруда"] = { 300, 320 },
		["Подвеска из животворного рубина"] = { 365, 385 },
		["Подвеска края теней"] = { 370, 380 },
		["Подвеска пустой руны"] = { 370, 380 },
		["Подвеска с тигровым опалом"] = { 525, 535 },
		["Подвеска серебряной розы"] = { 175, 205 },
		["Подвеска солнечного огня"] = { 375, 385 },
		["Подвеска увядания"] = { 370, 380 },
		["Покрытый письменами аметрин"] = { 440, 465 },
		["Покрытый письменами благородный топаз"] = { 350, 380 },
		["Покрытый письменами гессонит"] = { 500, 510 },
		["Покрытый письменами закатный оникс"] = { 520, 530 },
		["Покрытый письменами императорский топаз"] = { 410, 440 },
		["Покрытый письменами огнекамень"] = { 375, 385 },
		["Покрытый письменами огромный цитрин"] = { 375, 415 },
		["Покрытый письменами пламенный спессарит"] = { 300, 340 },
		["Покрытый письменами тигровый опал"] = { 475, 485 },
		["Полированный закатный оникс"] = { 520, 530 },
		["Полированный тигровый опал"] = { 480, 490 },
		["Померкшая яшма"] = { 500, 510 },
		["Померкшее Око Зула"] = { 440, 465 },
		["Померкший александрит"] = { 500, 510 },
		["Померкший лесной изумруд"] = { 410, 440 },
		["Померкший самородный нефрит"] = { 520, 530 },
		["Померкший темный нефрит"] = { 375, 415 },
		["Природный оберег"] = { 375, 385 },
		["Провидческий алмаз землеправителя"] = { 440, 460 },
		["Провидческий алмаз земной бури"] = { 375, 380 },
		["Провидческий мглистый алмаз"] = { 500, 510 },
		["Прожигающий александрит"] = { 465, 475 },
		["Прожигающий самородный нефрит"] = { 520, 530 },
		["Прозрачный аметрин"] = { 440, 465 },
		["Прозрачный гессонит"] = { 500, 510 },
		["Прозрачный закатный оникс"] = { 520, 530 },
		["Прозрачный императорский топаз"] = { 410, 440 },
		["Прозрачный огромный цитрин"] = { 375, 415 },
		["Прозрачный тигровый опал"] = { 480, 490 },
		["Промерзший александрит"] = { 485, 495 },
		["Промерзший самородный нефрит"] = { 520, 530 },
		["Простое жемчужное кольцо"] = { 90, 120 },
		["Простое опаловое кольцо"] = { 280, 300 },
		["Прочное око дракона"] = { 390, 440 },
		["Прочное сияние осени"] = { 410, 440 },
		["Прочный Глаз химеры"] = { 470, 490 },
		["Прочный алицит"] = { 500, 510 },
		["Прочный золотой дренит"] = { 325, 355 },
		["Прочный зоревик"] = { 350, 380 },
		["Прочный львиный глаз"] = { 375, 385 },
		["Прочный солнечный камень"] = { 470, 480 },
		["Прочный солнечный хрусталь"] = { 375, 415 },
		["Прочный солнцесвет"] = { 520, 530 },
		["Прочный царский янтарь"] = { 440, 465 },
		["Пунцовое солнце"] = { 365, 375 },
		["Пылающее цитриновое кольцо"] = { 180, 210 },
		["Пылающее этерниевое кольцо"] = { 375, 380 },
		["Радужный черный бриллиант"] = { 310, 320 },
		["Раздробленная яшма"] = { 500, 510 },
		["Раздробленное Око Зула"] = { 440, 465 },
		["Раздробленный александрит"] = { 510, 520 },
		["Раздробленный лесной изумруд"] = { 410, 440 },
		["Раздробленный самородный нефрит"] = { 520, 530 },
		["Раздробленный темный нефрит"] = { 375, 415 },
		["Разрушительный алмаз небесного огня"] = { 375, 380 },
		["Разрушительный алмаз небесного сияния"] = { 440, 460 },
		["Разрушительный изначальный алмаз"] = { 520, 530 },
		["Разрушительный мглистый алмаз"] = { 500, 510 },
		["Расколотая яшма"] = { 500, 510 },
		["Расколотое Око Зула"] = { 440, 465 },
		["Расколотый лесной изумруд"] = { 410, 440 },
		["Расколотый темный нефрит"] = { 375, 415 },
		["Растрескавшееся око дракона"] = { 390, 440 },
		["Растрескавшийся Глаз химеры"] = { 470, 490 },
		["Растрескавшийся алый рубин"] = { 410, 440 },
		["Растрескавшийся багровый рубин"] = { 440, 465 },
		["Растрескавшийся врайкульский гранат"] = { 490, 500 },
		["Растрескавшийся кровавый камень"] = { 375, 415 },
		["Растрескавшийся первозданный рубин"] = { 520, 530 },
		["Растрескавшийся сердолик"] = { 500, 510 },
		["Резонирующее кольцо гнева"] = { 475, 500 },
		["Рельефная пунцовая шпинель"] = { 375, 385 },
		["Рельефное око дракона"] = { 390, 440 },
		["Рельефный Глаз химеры"] = { 470, 490 },
		["Рельефный алый рубин"] = { 410, 440 },
		["Рельефный багровый рубин"] = { 440, 465 },
		["Рельефный врайкульский гранат"] = { 505, 515 },
		["Рельефный животворный рубин"] = { 350, 380 },
		["Рельефный кровавый гранат"] = { 305, 345 },
		["Рельефный кровавый камень"] = { 375, 415 },
		["Рельефный первозданный рубин"] = { 520, 530 },
		["Рельефный сердолик"] = { 500, 510 },
		["Роза Кайли"] = { 365, 375 },
		["Рокочущий изначальный алмаз"] = { 520, 530 },
		["Рубиновая корона восстановления"] = { 250, 280 },
		["Рубиновая подвеска огня"] = { 260, 290 },
		["Рубиновый заяц"] = { 430, 450 },
		["Руническая пунцовая шпинель"] = { 375, 385 },
		["Рунический Глаз химеры"] = { 470, 490 },
		["Рунический алый рубин"] = { 410, 440 },
		["Рунический багровый рубин"] = { 440, 465 },
		["Рунический врайкульский гранат"] = { 510, 520 },
		["Рунический животворный рубин"] = { 350, 380 },
		["Рунический кровавый гранат"] = { 315, 355 },
		["Рунический кровавый камень"] = { 375, 415 },
		["Рунический первозданный рубин"] = { 520, 530 },
		["Рунический перстень маны"] = { 440, 460 },
		["Рунический перстень маны претендента"] = { 470, 490 },
		["Рунический сердолик"] = { 500, 510 },
		["Руническое око дракона"] = { 390, 440 },
		["Самородный нефрит сенсея"] = { 520, 530 },
		["Сапфировая подвеска зимней ночи"] = { 290, 310 },
		["Сапфировая сова"] = { 430, 450 },
		["Сапфировый перстень"] = { 285, 305 },
		["Сбалансированное око ночи"] = { 350, 380 },
		["Сбалансированный александрит"] = { 490, 500 },
		["Сбалансированный аметист Песни Теней"] = { 375, 385 },
		["Сбалансированный камень ночи"] = { 500, 510 },
		["Сбалансированный самородный нефрит"] = { 520, 530 },
		["Сбалансированный страхолит"] = { 440, 465 },
		["Сбалансированный сумеречный опал"] = { 410, 440 },
		["Сбалансированный сумрачный дренит"] = { 325, 355 },
		["Сбалансированный сумрачный кристалл"] = { 375, 415 },
		["Сверкающая драгоценность"] = { 350, 380 },
		["Сверкающее жемчужное кольцо"] = { 335, 355 },
		["Сверкающее ожерелье"] = { 105, 135 },
		["Сверкающее око дракона"] = { 390, 440 },
		["Сверкающее сияние осени"] = { 410, 440 },
		["Сверкающий Глаз химеры"] = { 470, 490 },
		["Сверкающий алицит"] = { 500, 510 },
		["Сверкающий золотой дренит"] = { 300, 340 },
		["Сверкающий зоревик"] = { 350, 380 },
		["Сверкающий львиный глаз"] = { 375, 385 },
		["Сверкающий солнечный камень"] = { 490, 500 },
		["Сверкающий солнечный хрусталь"] = { 375, 415 },
		["Сверкающий солнцесвет"] = { 520, 530 },
		["Сверкающий царский янтарь"] = { 440, 465 },
		["Светозарная яшма"] = { 500, 510 },
		["Светозарное Око Зула"] = { 440, 465 },
		["Светозарный александрит"] = { 505, 515 },
		["Светозарный лесной изумруд"] = { 410, 440 },
		["Светозарный морской изумруд"] = { 375, 385 },
		["Светозарный самородный нефрит"] = { 520, 530 },
		["Светозарный талассит"] = { 350, 380 },
		["Светозарный темный нефрит"] = { 375, 415 },
		["Светозарный хризолит"] = { 300, 340 },
		["Светоносный аметрин"] = { 440, 465 },
		["Светоносный благородный топаз"] = { 350, 380 },
		["Светоносный гессонит"] = { 500, 510 },
		["Светоносный императорский топаз"] = { 410, 440 },
		["Светоносный огнекамень"] = { 375, 385 },
		["Светоносный огромный цитрин"] = { 375, 415 },
		["Светоносный пламенный спессарит"] = { 305, 345 },
		["Светящееся око ночи"] = { 350, 380 },
		["Светящееся ториевое кольцо"] = { 290, 310 },
		["Светящийся аметист Песни Теней"] = { 375, 385 },
		["Светящийся камень ночи"] = { 500, 510 },
		["Светящийся страхолит"] = { 440, 465 },
		["Светящийся сумеречный опал"] = { 410, 440 },
		["Светящийся сумрачный дренит"] = { 300, 340 },
		["Светящийся сумрачный кристалл"] = { 375, 415 },
		["Сердце дона Хулио"] = { 365, 375 },
		["Сердце земли"] = { 525, 535 },
		["Серебряное кольцо могущества"] = { 110, 140 },
		["Сияющая яшма"] = { 500, 510 },
		["Сияющее Око Зула"] = { 440, 465 },
		["Сияющий лесной изумруд"] = { 410, 440 },
		["Сияющий темный нефрит"] = { 375, 415 },
		["Слеза забвения"] = { 440, 465 },
		["Слеза кошмаров"] = { 440, 465 },
		["Слеза миража"] = { 440, 465 },
		["Слеза утопии"] = { 440, 465 },
		["Смертоносный аметрин"] = { 440, 465 },
		["Смертоносный гессонит"] = { 500, 510 },
		["Смертоносный закатный оникс"] = { 520, 530 },
		["Смертоносный императорский топаз"] = { 410, 440 },
		["Смертоносный огромный цитрин"] = { 375, 415 },
		["Смертоносный тигровый опал"] = { 460, 470 },
		["Смутная яшма"] = { 500, 510 },
		["Смутное Око Зула"] = { 440, 465 },
		["Смутный александрит"] = { 460, 470 },
		["Смутный лесной изумруд"] = { 410, 440 },
		["Смутный самородный нефрит"] = { 520, 530 },
		["Смутный темный нефрит"] = { 375, 415 },
		["Сокрытый аметрин"] = { 440, 465 },
		["Сокрытый благородный топаз"] = { 350, 380 },
		["Сокрытый гессонит"] = { 500, 510 },
		["Сокрытый императорский аметист"] = { 520, 530 },
		["Сокрытый императорский топаз"] = { 410, 440 },
		["Сокрытый огнекамень"] = { 375, 385 },
		["Сокрытый огромный цитрин"] = { 375, 415 },
		["Сокрытый пламенный спессарит"] = { 325, 355 },
		["Сокрытый плутовской камень"] = { 465, 475 },
		["Статуэтка багровой змейки"] = { 375, 385 },
		["Статуэтка вепря из истинного серебра"] = { 260, 290 },
		["Статуэтка вепря из оскверненной стали"] = { 375, 385 },
		["Статуэтка змеи из животворного рубина"] = { 375, 385 },
		["Статуэтка золотого зайца"] = { 225, 255 },
		["Статуэтка изумрудной совы"] = { 295, 315 },
		["Статуэтка кориевого вепря"] = { 375, 385 },
		["Статуэтка краба из зоревика"] = { 375, 385 },
		["Статуэтка краба из истинного серебра"] = { 250, 280 },
		["Статуэтка морского альбатроса"] = { 375, 385 },
		["Статуэтка неземной черепахи"] = { 375, 385 },
		["Статуэтка нефритовой совы"] = { 225, 255 },
		["Статуэтка пантеры Песни Теней"] = { 375, 385 },
		["Статуэтка пантеры из ока ночи"] = { 375, 385 },
		["Статуэтка пантеры из черного жемчуга"] = { 240, 270 },
		["Статуэтка рубиновой змеи"] = { 280, 300 },
		["Статуэтка скорпида из черного железа"] = { 310, 330 },
		["Статуэтка таласситовой совы"] = { 375, 385 },
		["Статуэтка черного алмазного краба"] = { 310, 330 },
		["Статуя из грубого камня"] = { 30, 50 },
		["Статуя из массивного камня"] = { 225, 245 },
		["Статуя из необработанного камня"] = { 70, 90 },
		["Стойкий Глаз химеры"] = { 470, 490 },
		["Стойкий алицит"] = { 500, 510 },
		["Стойкий аметрин"] = { 440, 465 },
		["Стойкий гессонит"] = { 500, 510 },
		["Стойкий закатный оникс"] = { 520, 530 },
		["Стойкий императорский топаз"] = { 410, 440 },
		["Стойкий огромный цитрин"] = { 375, 415 },
		["Стойкий тигровый опал"] = { 490, 500 },
		["Стойкий царский янтарь"] = { 500, 510 },
		["Стойкое око дракона"] = { 500, 510 },
		["Страхолит защитника"] = { 440, 465 },
		["Страхолит стража"] = { 440, 465 },
		["Стремительный алмаз небесного огня"] = { 375, 380 },
		["Стремительный алмаз небесного сияния"] = { 440, 460 },
		["Стремительный изначальный алмаз"] = { 520, 530 },
		["Стремительный мглистый алмаз"] = { 500, 510 },
		["Строгий мглистый алмаз"] = { 500, 510 },
		["Сумеречная змея"] = { 430, 450 },
		["Сумеречный опал защитника"] = { 410, 440 },
		["Сумеречный опал стража"] = { 410, 440 },
		["Сумрачный кристалл защитника"] = { 375, 415 },
		["Сумрачный кристалл стража"] = { 375, 415 },
		["Сфера отрицания"] = { 500, 510 },
		["Таинственный императорский аметист"] = { 520, 530 },
		["Таинственный камень ночи"] = { 500, 510 },
		["Таинственный плутовской камень"] = { 480, 490 },
		["Таинственный страхолит"] = { 440, 465 },
		["Таинственный сумеречный опал"] = { 410, 440 },
		["Таинственный сумрачный кристалл"] = { 375, 415 },
		["Твердая каменная статуя"] = { 175, 195 },
		["Темный нефрит провидца"] = { 375, 415 },
		["Тигровый опал авангарда"] = { 480, 490 },
		["Тигровый опал адепта"] = { 510, 520 },
		["Тигровый опал воителя"] = { 495, 505 },
		["Тигровый опал проворства"] = { 500, 510 },
		["Тигровый опал фехтовальщика"] = { 475, 485 },
		["Титановая печатка свирепости"] = { 440, 460 },
		["Титановая цепь стража земли"] = { 450, 460 },
		["Титановое колье сотрясения"] = { 450, 460 },
		["Титановое кольцо ледяного стража"] = { 440, 460 },
		["Титановое кольцо свирепости"] = { 440, 460 },
		["Титановое кольцо сотрясения"] = { 450, 460 },
		["Титановое кольцо стража земли"] = { 450, 460 },
		["Титановое кольцо чародейского удара"] = { 450, 460 },
		["Титановое ожерелье чародейского удара"] = { 450, 460 },
		["Толстое адамантитовое ожерелье"] = { 345, 365 },
		["Толстое бронзовое ожерелье"] = { 80, 110 },
		["Толстое ожерелье из оскверненной стали"] = { 365, 385 },
		["Тонкая медная проволока"] = { 20, 50 },
		["Тонкий закатный оникс"] = { 520, 530 },
		["Тонкий тигровый опал"] = { 485, 495 },
		["Тончайший закатный оникс"] = { 520, 530 },
		["Тончайший тигровый опал"] = { 470, 480 },
		["Ториевая оправа"] = { 235, 255 },
		["Тревожный аметрин"] = { 440, 465 },
		["Тревожный благородный топаз"] = { 350, 380 },
		["Тревожный гессонит"] = { 500, 510 },
		["Тревожный закатный оникс"] = { 520, 530 },
		["Тревожный императорский топаз"] = { 410, 440 },
		["Тревожный огнекамень"] = { 375, 385 },
		["Тревожный огромный цитрин"] = { 375, 415 },
		["Тревожный тигровый опал"] = { 510, 520 },
		["Треснутая вневременная яшма"] = { 470, 490 },
		["Треснутая зазубренная яшма"] = { 470, 490 },
		["Треснутая замысловатая яшма"] = { 470, 490 },
		["Треснутая крепкая яшма"] = { 470, 490 },
		["Треснутая лучистая яшма"] = { 470, 490 },
		["Треснутая мощная яшма"] = { 470, 490 },
		["Треснутая насыщенная яшма"] = { 470, 490 },
		["Треснутая неизменная яшма"] = { 470, 490 },
		["Треснутая непрозрачная яшма"] = { 470, 490 },
		["Треснутая ослепительная яшма"] = { 470, 490 },
		["Треснутая отверделая яшма"] = { 470, 490 },
		["Треснутая плотная яшма"] = { 470, 490 },
		["Треснутая померкшая яшма"] = { 470, 490 },
		["Треснутая раздробленная яшма"] = { 470, 490 },
		["Треснутая расколотая яшма"] = { 470, 490 },
		["Треснутая светозарная яшма"] = { 470, 490 },
		["Треснутая сияющая яшма"] = { 470, 490 },
		["Треснутая смутная яшма"] = { 470, 490 },
		["Треснутая усиленная яшма"] = { 470, 490 },
		["Треснутая яшма провидца"] = { 470, 490 },
		["Треснутый блестящий зефирит"] = { 470, 490 },
		["Треснутый блистательный сердолик"] = { 470, 490 },
		["Треснутый блистающий гессонит"] = { 470, 490 },
		["Треснутый броский гессонит"] = { 470, 490 },
		["Треснутый всевластный камень ночи"] = { 470, 490 },
		["Треснутый гессонит авангарда"] = { 470, 490 },
		["Треснутый гессонит варвара"] = { 470, 490 },
		["Треснутый гессонит защитника"] = { 470, 490 },
		["Треснутый гессонит проворства"] = { 470, 490 },
		["Треснутый гессонит фехтовальщика"] = { 470, 490 },
		["Треснутый гибельный гессонит"] = { 470, 490 },
		["Треснутый гладкий алицит"] = { 470, 490 },
		["Треснутый глянцевый гессонит"] = { 470, 490 },
		["Треснутый гравированный гессонит"] = { 470, 490 },
		["Треснутый грозовой зефирит"] = { 470, 490 },
		["Треснутый грубый гессонит"] = { 470, 490 },
		["Треснутый заряженный камень ночи"] = { 470, 490 },
		["Треснутый застывший гессонит"] = { 470, 490 },
		["Треснутый затвердевший гессонит"] = { 470, 490 },
		["Треснутый идеально ограненный гессонит"] = { 470, 490 },
		["Треснутый изменчивый камень ночи"] = { 470, 490 },
		["Треснутый изысканный сердолик"] = { 470, 490 },
		["Треснутый изящный сердолик"] = { 470, 490 },
		["Треснутый искрящийся зефирит"] = { 470, 490 },
		["Треснутый камень ночи защитника"] = { 470, 490 },
		["Треснутый камень ночи стража"] = { 470, 490 },
		["Треснутый королевский камень ночи"] = { 470, 490 },
		["Треснутый краеугольный гессонит"] = { 470, 490 },
		["Треснутый матовый алицит"] = { 470, 490 },
		["Треснутый мерцающий гессонит"] = { 470, 490 },
		["Треснутый мистический алицит"] = { 470, 490 },
		["Треснутый могущественный гессонит"] = { 470, 490 },
		["Треснутый монарший камень ночи"] = { 470, 490 },
		["Треснутый монументальный камень ночи"] = { 470, 490 },
		["Треснутый мягкий алицит"] = { 470, 490 },
		["Треснутый надежный гессонит"] = { 470, 490 },
		["Треснутый наделенный силой гессонит"] = { 470, 490 },
		["Треснутый непоколебимый сердолик"] = { 470, 490 },
		["Треснутый непрочный камень ночи"] = { 470, 490 },
		["Треснутый нетронутый гессонит"] = { 470, 490 },
		["Треснутый округленный гессонит"] = { 470, 490 },
		["Треснутый очищенный камень ночи"] = { 470, 490 },
		["Треснутый покрытый письменами гессонит"] = { 470, 490 },
		["Треснутый прозрачный гессонит"] = { 470, 490 },
		["Треснутый прочный алицит"] = { 470, 490 },
		["Треснутый растрескавшийся сердолик"] = { 470, 490 },
		["Треснутый рельефный сердолик"] = { 470, 490 },
		["Треснутый рунический сердолик"] = { 470, 490 },
		["Треснутый сбалансированный камень ночи"] = { 470, 490 },
		["Треснутый сверкающий алицит"] = { 470, 490 },
		["Треснутый светоносный гессонит"] = { 470, 490 },
		["Треснутый светящийся камень ночи"] = { 470, 490 },
		["Треснутый смертоносный гессонит"] = { 470, 490 },
		["Треснутый сокрытый гессонит"] = { 470, 490 },
		["Треснутый стойкий алицит"] = { 470, 490 },
		["Треснутый стойкий гессонит"] = { 470, 490 },
		["Треснутый таинственный камень ночи"] = { 470, 490 },
		["Треснутый тревожный гессонит"] = { 470, 490 },
		["Треснутый царственный камень ночи"] = { 470, 490 },
		["Треснутый цельный зефирит"] = { 470, 490 },
		["Треснутый яркий сердолик"] = { 470, 490 },
		["Треснутый ясный сердолик"] = { 470, 490 },
		["Тяжелое адамантитовое кольцо"] = { 345, 365 },
		["Тяжелое золотое ожерелье битвы"] = { 180, 210 },
		["Тяжелое кольцо из оскверненной стали"] = { 355, 375 },
		["Тяжелое медное кольцо"] = { 35, 65 },
		["Тяжелое нефритовое кольцо"] = { 135, 165 },
		["Тяжелое серебряное кольцо"] = { 120, 150 },
		["Тяжелый железный кастет"] = { 155, 185 },
		["Угасающий алмаз небесного огня"] = { 375, 380 },
		["Угасающий алмаз небесного сияния"] = { 440, 460 },
		["Угасающий изначальный алмаз"] = { 520, 530 },
		["Угасающий мглистый алмаз"] = { 500, 510 },
		["Украшенное самоцветами кольцо"] = { 275, 305 },
		["Усиленная яшма"] = { 500, 510 },
		["Усиленное Око Зула"] = { 440, 465 },
		["Усиленный александрит"] = { 510, 520 },
		["Усиленный лесной изумруд"] = { 410, 440 },
		["Усиленный самородный нефрит"] = { 520, 530 },
		["Усиленный темный нефрит"] = { 375, 415 },
		["Усиливающее слух кольцо преступника"] = { 475, 500 },
		["Фокусирующая линза из сумрачного кристалла"] = { 370, 390 },
		["Фокусирующая линза из сумрачного нефрита"] = { 380, 400 },
		["Фокусирующая линза из темного нефрита"] = { 360, 380 },
		["Хаотический алмаз небесного огня"] = { 375, 380 },
		["Хаотический алмаз небесного сияния"] = { 440, 460 },
		["Хаотический мглистый алмаз"] = { 500, 510 },
		["Хрупкий врайкульский гранат"] = { 460, 470 },
		["Хрупкий первозданный рубин"] = { 520, 530 },
		["Царственное око ночи"] = { 350, 380 },
		["Царственный аметист Песни Теней"] = { 375, 385 },
		["Царственный императорский аметист"] = { 520, 530 },
		["Царственный камень ночи"] = { 500, 510 },
		["Царственный плутовской камень"] = { 510, 520 },
		["Царственный страхолит"] = { 440, 465 },
		["Царственный сумеречный опал"] = { 410, 440 },
		["Царственный сумрачный дренит"] = { 325, 355 },
		["Царственный сумрачный кристалл"] = { 375, 415 },
		["Целительное кольцо из истинного серебра"] = { 265, 295 },
		["Цельная звезда Элуны"] = { 350, 380 },
		["Цельное бронзовое кольцо"] = { 80, 110 },
		["Цельное око дракона"] = { 390, 440 },
		["Цельное сердце реки"] = { 520, 530 },
		["Цельный Глаз химеры"] = { 470, 490 },
		["Цельный величественный циркон"] = { 440, 465 },
		["Цельный зефирит"] = { 500, 510 },
		["Цельный кальцедоний"] = { 375, 415 },
		["Цельный лазурит"] = { 500, 510 },
		["Цельный лазурный лунный камень"] = { 300, 340 },
		["Цельный небесный сапфир"] = { 410, 440 },
		["Цельный неземной сапфир"] = { 375, 385 },
		["Цепь Сумеречной Совы"] = { 375, 385 },
		["Цитриновая подвеска исцеления"] = { 220, 250 },
		["Цитриновое кольцо быстрого исцеления"] = { 210, 240 },
		["Чеканное кольцо из истинного серебра"] = { 200, 230 },
		["Черная жемчужина"] = { 340, 360 },
		["Шершавый императорский аметист"] = { 520, 530 },
		["Шершавый плутовской камень"] = { 500, 510 },
		["Широкий солнечный камень"] = { 500, 510 },
		["Широкий солнцесвет"] = { 520, 530 },
		["Элегантное серебряное кольцо"] = { 80, 110 },
		["Янтарная кровь"] = { 365, 375 },
		["Яркая пунцовая шпинель"] = { 375, 385 },
		["Яркий Глаз химеры"] = { 470, 490 },
		["Яркий алый рубин"] = { 410, 440 },
		["Яркий багровый рубин"] = { 440, 465 },
		["Яркий врайкульский гранат"] = { 510, 520 },
		["Яркий животворный рубин"] = { 350, 380 },
		["Яркий кровавый гранат"] = { 305, 345 },
		["Яркий кровавый камень"] = { 375, 415 },
		["Яркий первозданный рубин"] = { 520, 530 },
		["Яркий сердолик"] = { 500, 510 },
		["Яркое око дракона"] = { 390, 440 },
		["Ясное око дракона"] = { 390, 440 },
		["Ясный Глаз химеры"] = { 470, 490 },
		["Ясный алый рубин"] = { 410, 440 },
		["Ясный багровый рубин"] = { 440, 465 },
		["Ясный врайкульский гранат"] = { 470, 480 },
		["Ясный кровавый камень"] = { 375, 415 },
		["Ясный первозданный рубин"] = { 520, 530 },
		["Ясный сердолик"] = { 500, 510 },
		["Яшма провидца"] = { 500, 510 },
	},
	[773] = {
		["Астральные чернила"] = { 295, 305 },
		["Астрономические чернила"] = { 195, 205 },
		["Бежевые чернила"] = { 15, 30 },
		["Божественный спутник"] = { 525, 535 },
		["Великое начертание журавлиного крыла"] = { 430, 460 },
		["Великое начертание клыка тигра"] = { 430, 460 },
		["Великое начертание когтя тигра"] = { 430, 460 },
		["Великое начертание рога быка"] = { 430, 460 },
		["Воодушевление Аскеладда"] = { 505, 515 },
		["Воодушевление Торкелля"] = { 505, 515 },
		["Воодушевление Торфина"] = { 505, 515 },
		["Инкрустированный серебром посох"] = { 525, 535 },
		["Исследование малого начертания"] = { 125, 150 },
		["Исследование нордскольского начертания"] = { 425, 450 },
		["Карта Новолуния"] = { 290, 300 },
		["Карта Новолуния: Север"] = { 450, 475 },
		["Карта таинства"] = { 125, 150 },
		["Карта тайной магии"] = { 200, 210 },
		["Карта тени"] = { 240, 250 },
		["Ключ к иным мирам"] = { 525, 535 },
		["Книга звезд"] = { 240, 250 },
		["Книга крови"] = { 510, 520 },
		["Книга молитв"] = { 510, 520 },
		["Книга полета"] = { 290, 300 },
		["Книга ритуалов новолуния"] = { 375, 400 },
		["Книга хитрых советов"] = { 340, 350 },
		["Контракт с Абимайскими искателями"] = { 510, 520 },
		["Контракт с Артелем Барханного Ветра"] = { 510, 520 },
		["Контракт с Гилнеасом"] = { 510, 520 },
		["Контракт с Изгнанниками Вайш'ира"] = { 510, 520 },
		["Контракт с Картеля Трюмных Вод"] = { 510, 520 },
		["Контракт с Орденом Белого Тигра"] = { 510, 520 },
		["Контракт с Орденом Красного Журавля"] = { 510, 520 },
		["Контракт с Эльдранилом\n"] = { 510, 520 },
		["Королевские чернила"] = { 170, 180 },
		["Лики Судьбы"] = { 425, 450 },
		["Мастерское начертание бури"] = { 395, 405 },
		["Мастерское начертание вершины"] = { 395, 405 },
		["Мастерское начертание секиры"] = { 395, 405 },
		["Мастерское начертание скалы"] = { 395, 405 },
		["Материал для свитка брони"] = { 75, 100 },
		["Материал для свитка брони II"] = { 210, 220 },
		["Материал для свитка брони III"] = { 355, 385 },
		["Материал для свитка оружия"] = { 100, 125 },
		["Материал для свитка оружия II"] = { 250, 260 },
		["Материал для свитка оружия III"] = { 405, 415 },
		["Мерцающие чернила"] = { 245, 255 },
		["Мистический том"] = { 125, 150 },
		["Мрачно-коричневые чернила"] = { 460, 470 },
		["Небесные чернила"] = { 290, 300 },
		["Огненные чернила"] = { 220, 230 },
		["Поводья акварельного лиса"] = { 535, 545 },
		["Покрытый шипами посох"] = { 510, 520 },
		["Полная схема маршрутов эвакуации"] = { 200, 210 },
		["Полуночные чернила"] = { 75, 80 },
		["Руководство по глотанию огня"] = { 240, 250 },
		["Руководство по исследованию подземелий"] = { 525, 535 },
		["Рунический посох"] = { 510, 520 },
		["Рунический свиток стойкости"] = { 425, 460 },
		["Свиток абиссала"] = { 505, 515 },
		["Свиток беса скверны"] = { 515, 525 },
		["Свиток возврата"] = { 60, 75 },
		["Свиток возврата II"] = { 215, 225 },
		["Свиток возврата III"] = { 345, 355 },
		["Свиток всех характеристик"] = { 510, 520 },
		["Свиток выносливости"] = { 35, 45 },
		["Свиток выносливости II"] = { 75, 85 },
		["Свиток выносливости III"] = { 160, 170 },
		["Свиток выносливости IV"] = { 210, 220 },
		["Свиток выносливости IX"] = { 470, 490 },
		["Свиток выносливости V"] = { 255, 265 },
		["Свиток выносливости VI"] = { 300, 310 },
		["Свиток выносливости VII"] = { 355, 365 },
		["Свиток выносливости VIII"] = { 405, 415 },
		["Свиток высвобожденного элементаля"] = { 515, 525 },
		["Свиток грызунов"] = { 515, 525 },
		["Свиток духа"] = { 35, 45 },
		["Свиток духа II"] = { 75, 85 },
		["Свиток духа III"] = { 165, 175 },
		["Свиток духа IV"] = { 215, 225 },
		["Свиток духа IX"] = { 470, 490 },
		["Свиток духа V"] = { 260, 270 },
		["Свиток духа VI"] = { 305, 315 },
		["Свиток духа VII"] = { 360, 370 },
		["Свиток духа VIII"] = { 410, 420 },
		["Свиток интеллекта"] = { 35, 45 },
		["Свиток интеллекта II"] = { 75, 85 },
		["Свиток интеллекта III"] = { 170, 180 },
		["Свиток интеллекта IV"] = { 220, 230 },
		["Свиток интеллекта IX"] = { 470, 490 },
		["Свиток интеллекта V"] = { 265, 275 },
		["Свиток интеллекта VI"] = { 310, 320 },
		["Свиток интеллекта VII"] = { 365, 375 },
		["Свиток интеллекта VIII"] = { 415, 425 },
		["Свиток критического удара"] = { 510, 520 },
		["Свиток критического удара заклинаний"] = { 510, 520 },
		["Свиток ловкости"] = { 35, 45 },
		["Свиток ловкости II"] = { 85, 95 },
		["Свиток ловкости III"] = { 180, 190 },
		["Свиток ловкости IV"] = { 230, 240 },
		["Свиток ловкости IX"] = { 470, 490 },
		["Свиток ловкости V"] = { 275, 285 },
		["Свиток ловкости VI"] = { 320, 330 },
		["Свиток ловкости VII"] = { 375, 385 },
		["Свиток ловкости VIII"] = { 425, 435 },
		["Свиток наблюдателя"] = { 515, 525 },
		["Свиток повелителя Бездны"] = { 515, 525 },
		["Свиток поганища"] = { 490, 500 },
		["Свиток силы"] = { 35, 45 },
		["Свиток силы II"] = { 80, 90 },
		["Свиток силы III"] = { 175, 185 },
		["Свиток силы IV"] = { 225, 235 },
		["Свиток силы IX"] = { 470, 490 },
		["Свиток силы V"] = { 270, 280 },
		["Свиток силы VI"] = { 315, 325 },
		["Свиток силы VII"] = { 370, 380 },
		["Свиток силы VIII"] = { 420, 430 },
		["Свиток силы атаки"] = { 510, 520 },
		["Свиток скорости"] = { 510, 520 },
		["Свиток снижения урона"] = { 510, 520 },
		["Свиток стража гнева"] = { 515, 525 },
		["Свиток упыря"] = { 515, 525 },
		["Свиток урона"] = { 510, 520 },
		["Свиток шиварры"] = { 515, 525 },
		["Свиток эффективности лечения"] = { 510, 520 },
		["Сертификат собственности"] = { 205, 215 },
		["Символ Килрогга"] = { 130, 140 },
		["Символ Света небес"] = { 110, 120 },
		["Символ Слова Тьмы: Боль"] = { 355, 365 },
		["Символ Тьмы"] = { 390, 405 },
		["Символ ангелов"] = { 515, 525 },
		["Символ антимагического панциря"] = { 390, 405 },
		["Символ астрального возвращения"] = { 155, 165 },
		["Символ ауры меткого выстрела"] = { 390, 405 },
		["Символ бдительности"] = { 430, 440 },
		["Символ безграничного возрождения"] = { 105, 115 },
		["Символ безопасного падения"] = { 205, 215 },
		["Символ безудержного восстановления"] = { 430, 440 },
		["Символ берсерка"] = { 430, 440 },
		["Символ беса"] = { 145, 155 },
		["Символ бесконечного дыхания"] = { 105, 115 },
		["Символ благословения королей"] = { 105, 115 },
		["Символ благословения могущества"] = { 80, 90 },
		["Символ благословения мудрости"] = { 80, 90 },
		["Символ блокирования"] = { 390, 405 },
		["Символ блуждающего духа"] = { 430, 440 },
		["Символ боевого крика"] = { 80, 90 },
		["Символ божественного вмешательства"] = { 510, 520 },
		["Символ божественной бури"] = { 430, 440 },
		["Символ божественности"] = { 140, 150 },
		["Символ болезни"] = { 285, 295 },
		["Символ буйного роста"] = { 430, 440 },
		["Символ быстрины"] = { 430, 440 },
		["Символ быстрого восстановления"] = { 390, 405 },
		["Символ быстрого исцеления"] = { 125, 135 },
		["Символ быстрого разложения"] = { 380, 385 },
		["Символ быстрой стрельбы"] = { 320, 330 },
		["Символ веера клинков"] = { 430, 440 },
		["Символ великого благословения"] = { 510, 520 },
		["Символ верного выстрела"] = { 390, 405 },
		["Символ взлома"] = { 105, 115 },
		["Символ взрыва трупа"] = { 305, 315 },
		["Символ взрывной волны"] = { 355, 365 },
		["Символ взрывной ловушки"] = { 430, 440 },
		["Символ вихря"] = { 350, 360 },
		["Символ вихря клинков"] = { 430, 440 },
		["Символ властности"] = { 355, 365 },
		["Символ вмешательства"] = { 390, 405 },
		["Символ внезапного удара"] = { 345, 355 },
		["Символ внутреннего огня"] = { 140, 150 },
		["Символ водного облика"] = { 105, 115 },
		["Символ водного щита"] = { 105, 115 },
		["Символ возложения рук"] = { 80, 90 },
		["Символ возрождения"] = { 175, 185 },
		["Символ волны исцеления"] = { 390, 405 },
		["Символ воскрешения питомца"] = { 80, 90 },
		["Символ восстановления"] = { 390, 405 },
		["Символ воющего ветра"] = { 430, 440 },
		["Символ воя ужаса"] = { 390, 405 },
		["Символ всеполгощающей тьмы"] = { 515, 525 },
		["Символ вскипания лавы"] = { 170, 180 },
		["Символ вспышки Света"] = { 305, 315 },
		["Символ вульгарных оскорблений"] = { 225, 235 },
		["Символ вурдалака"] = { 355, 365 },
		["Символ выброса адреналина"] = { 390, 405 },
		["Символ выгорания"] = { 500, 510 },
		["Символ вызывающего рева"] = { 155, 165 },
		["Символ выстрела химеры"] = { 430, 440 },
		["Символ вытягивания жизни"] = { 390, 405 },
		["Символ гальки"] = { 465, 475 },
		["Символ гарроты"] = { 140, 150 },
		["Символ гимна надежды"] = { 430, 440 },
		["Символ глубокой заморозки"] = { 430, 440 },
		["Символ глубокой раны"] = { 315, 325 },
		["Символ глухой обороны"] = { 430, 440 },
		["Символ гнева"] = { 95, 115 },
		["Символ гнева деревьев"] = { 105, 115 },
		["Символ гнева карателя"] = { 390, 405 },
		["Символ града стрел"] = { 390, 405 },
		["Символ грозы"] = { 390, 405 },
		["Символ грома"] = { 430, 440 },
		["Символ грома и молнии"] = { 355, 365 },
		["Символ громового удара"] = { 515, 525 },
		["Символ грохочущей мощи"] = { 390, 405 },
		["Символ дара дикой природы"] = { 510, 520 },
		["Символ дезориентирующего выстрела"] = { 430, 440 },
		["Символ демона Бездны"] = { 195, 205 },
		["Символ демонического круга"] = { 430, 440 },
		["Символ десертного угощения"] = { 490, 500 },
		["Символ дикого гриба"] = { 515, 525 },
		["Символ дикого рева"] = { 430, 440 },
		["Символ дикой природы"] = { 80, 90 },
		["Символ дразнящего удара"] = { 105, 115 },
		["Символ дубовой кожи"] = { 430, 440 },
		["Символ духа воздаяния"] = { 390, 405 },
		["Символ духа гадюки"] = { 390, 405 },
		["Символ духа дикого волка"] = { 430, 440 },
		["Символ духа зверя"] = { 390, 405 },
		["Символ духовного созвучия"] = { 90, 110 },
		["Символ душ"] = { 355, 365 },
		["Символ жажды убийства"] = { 430, 440 },
		["Символ жгучей боли"] = { 220, 230 },
		["Символ жертвенного огня"] = { 390, 405 },
		["Символ живой бомбы"] = { 430, 440 },
		["Символ жизнеотвода"] = { 430, 440 },
		["Символ жизнецвета"] = { 390, 405 },
		["Символ залпа"] = { 155, 165 },
		["Символ замедленного падения"] = { 80, 90 },
		["Символ замораживающей ловушки"] = { 265, 275 },
		["Символ захвата рун"] = { 315, 325 },
		["Символ защиты от магии льда"] = { 130, 140 },
		["Символ защиты от огня"] = { 105, 115 },
		["Символ защиты от страха"] = { 275, 285 },
		["Символ защиты от темной магии"] = { 155, 165 },
		["Символ звездного огня"] = { 225, 235 },
		["Символ звездной пыли"] = { 515, 525 },
		["Символ звездопада"] = { 390, 405 },
		["Символ звериного гнева"] = { 390, 405 },
		["Символ зеркального изображения"] = { 430, 440 },
		["Символ зимнего горна"] = { 330, 340 },
		["Символ змеиной ловушки"] = { 390, 405 },
		["Символ извечной воды"] = { 255, 265 },
		["Символ изгнания зла"] = { 380, 390 },
		["Символ инстинкта выживания"] = { 430, 440 },
		["Символ испепеления"] = { 355, 365 },
		["Символ исповеди"] = { 430, 440 },
		["Символ иссушения разума"] = { 430, 440 },
		["Символ исчадия Тьмы"] = { 355, 365 },
		["Символ исчезновения"] = { 130, 140 },
		["Символ казни"] = { 290, 300 },
		["Символ калечащего яда"] = { 390, 405 },
		["Символ камня души"] = { 245, 255 },
		["Символ камня здоровья"] = { 105, 125 },
		["Символ канала здоровья"] = { 115, 125 },
		["Символ карманной коробки"] = { 510, 520 },
		["Символ кары"] = { 215, 225 },
		["Символ коварного удара"] = { 215, 225 },
		["Символ когтя"] = { 105, 115 },
		["Символ колодца Света"] = { 390, 405 },
		["Символ кольца льда"] = { 90, 110 },
		["Символ кольца огня"] = { 115, 125 },
		["Символ кольца света"] = { 320, 330 },
		["Символ контроля над разумом"] = { 390, 405 },
		["Символ костяного щита"] = { 270, 280 },
		["Символ кровавого панциря"] = { 505, 515 },
		["Символ кровавого удара"] = { 325, 335 },
		["Символ кровавой ярости"] = { 80, 90 },
		["Символ крови вампира"] = { 350, 360 },
		["Символ кровожадности"] = { 390, 405 },
		["Символ кровоизлияния"] = { 390, 405 },
		["Символ кровоотвода"] = { 330, 340 },
		["Символ кровопускания"] = { 115, 125 },
		["Символ круга исцеления"] = { 390, 405 },
		["Символ крылатого отмщения"] = { 515, 525 },
		["Символ лавы"] = { 390, 400 },
		["Символ левитации"] = { 180, 190 },
		["Символ ледяного доспеха"] = { 100, 120 },
		["Символ ледяного копья"] = { 380, 390 },
		["Символ ледяного огня"] = { 390, 405 },
		["Символ ледяного прикосновения"] = { 285, 295 },
		["Символ ледяного удара"] = { 275, 285 },
		["Символ ледяного шока"] = { 190, 200 },
		["Символ ледяной глыбы"] = { 230, 240 },
		["Символ ледяной ловушки"] = { 355, 365 },
		["Символ ледяной преграды"] = { 430, 440 },
		["Символ ледяной стрелы"] = { 390, 405 },
		["Символ ледяных оков"] = { 390, 405 },
		["Символ лечения"] = { 120, 130 },
		["Символ лечения питомца"] = { 80, 90 },
		["Символ лика смерти"] = { 390, 405 },
		["Символ ложного выпада"] = { 310, 320 },
		["Символ ложной смерти"] = { 155, 165 },
		["Символ лунного огня"] = { 135, 145 },
		["Символ магического доспеха"] = { 330, 340 },
		["Символ маленьких хитростей"] = { 430, 440 },
		["Символ малой волны исцеления"] = { 240, 250 },
		["Символ маскировки"] = { 515, 525 },
		["Символ массового рассеивания"] = { 390, 405 },
		["Символ ментального крика"] = { 105, 125 },
		["Символ мерцающего пламени"] = { 475, 485 },
		["Символ метаморфозы"] = { 430, 440 },
		["Символ метки охотника"] = { 90, 110 },
		["Символ молитвы духа"] = { 510, 520 },
		["Символ молитвы защиты от темной магии"] = { 510, 520 },
		["Символ молитвы исцеления"] = { 390, 405 },
		["Символ молитвы стойкости"] = { 510, 520 },
		["Символ молнии"] = { 145, 155 },
		["Символ молота гнева"] = { 390, 405 },
		["Символ молота праведника"] = { 430, 440 },
		["Символ молота правосудия"] = { 100, 120 },
		["Символ мора"] = { 305, 315 },
		["Символ морозного доспеха"] = { 80, 90 },
		["Символ мощи тайной магии"] = { 340, 350 },
		["Символ мудрых"] = { 155, 165 },
		["Символ мясника"] = { 515, 525 },
		["Символ мясорубки"] = { 240, 250 },
		["Символ невидимости"] = { 390, 405 },
		["Символ незыблемости льда"] = { 390, 405 },
		["Символ неистового восстановления"] = { 355, 365 },
		["Символ неистового восстановления кошмара"] = { 515, 525 },
		["Символ ненасытной стужи"] = { 430, 440 },
		["Символ неоспоримой победы"] = { 330, 340 },
		["Символ несокрушимой брони"] = { 310, 320 },
		["Символ нестабильного колдовства"] = { 390, 405 },
		["Символ неутомимости"] = { 390, 405 },
		["Символ нечестивой порчи"] = { 430, 440 },
		["Символ нокаута"] = { 500, 510 },
		["Символ оберегающего духа"] = { 430, 440 },
		["Символ обжигающей ловушки"] = { 135, 145 },
		["Символ обновления"] = { 165, 175 },
		["Символ обновленной жизни"] = { 155, 165 },
		["Символ обшаривания карманов"] = { 80, 90 },
		["Символ объятий смерти"] = { 305, 315 },
		["Символ овладения силой"] = { 80, 90 },
		["Символ огненного взрыва"] = { 390, 405 },
		["Символ огненного рывка"] = { 485, 495 },
		["Символ огненного шара"] = { 390, 405 },
		["Символ огненного шока"] = { 95, 115 },
		["Символ огромной скорости"] = { 80, 90 },
		["Символ ожога"] = { 210, 220 },
		["Символ ожога Тьмы"] = { 280, 290 },
		["Символ озарения"] = { 390, 405 },
		["Символ окоченевшего панциря"] = { 470, 480 },
		["Символ омоложения"] = { 90, 110 },
		["Символ оружия жизни земли"] = { 305, 315 },
		["Символ оружия неистовства ветра"] = { 335, 345 },
		["Символ оружия языка пламени"] = { 130, 140 },
		["Символ освящения"] = { 210, 220 },
		["Символ ослабления доспеха"] = { 125, 135 },
		["Символ отвлечения"] = { 130, 140 },
		["Символ отпугивания зверя"] = { 80, 90 },
		["Символ отражения заклинания"] = { 430, 440 },
		["Символ отрыва"] = { 230, 240 },
		["Символ отчаянной защиты"] = { 390, 405 },
		["Символ охотника Скверны"] = { 390, 405 },
		["Символ очищения"] = { 185, 195 },
		["Символ ошеломления"] = { 190, 200 },
		["Символ парализующего удара"] = { 165, 175 },
		["Символ переполняющей мощи"] = { 515, 525 },
		["Символ перерождения"] = { 510, 520 },
		["Символ печати Света"] = { 390, 405 },
		["Символ печати мудрости"] = { 390, 405 },
		["Символ печати отмщения"] = { 390, 405 },
		["Символ печати повиновения"] = { 340, 350 },
		["Символ печати праведности"] = { 390, 405 },
		["Символ пингвина"] = { 80, 90 },
		["Символ пира для воронов"] = { 515, 525 },
		["Символ пламени Тьмы"] = { 430, 440 },
		["Символ плаща Теней"] = { 430, 440 },
		["Символ победного ража"] = { 390, 405 },
		["Символ подавления боли"] = { 255, 270 },
		["Символ подготовки"] = { 390, 405 },
		["Символ поджигания"] = { 390, 405 },
		["Символ подрезанного сухожилия"] = { 130, 140 },
		["Символ покорения стихий"] = { 390, 405 },
		["Символ покровительства природы"] = { 430, 440 },
		["Символ полосования"] = { 265, 275 },
		["Символ порабощения демона"] = { 155, 165 },
		["Символ порчи"] = { 95, 115 },
		["Символ порыва"] = { 155, 165 },
		["Символ потрошения"] = { 110, 120 },
		["Символ похищения души"] = { 80, 90 },
		["Символ праведной защиты"] = { 160, 170 },
		["Символ правосудия"] = { 125, 135 },
		["Символ превосходства"] = { 175, 185 },
		["Символ превращения"] = { 390, 405 },
		["Символ призрачного волка"] = { 105, 115 },
		["Символ призрачного растворения"] = { 475, 485 },
		["Символ призрачного удара"] = { 390, 405 },
		["Символ прилива сил"] = { 160, 170 },
		["Символ прицельного выстрела"] = { 180, 190 },
		["Символ провокации"] = { 390, 405 },
		["Символ проклятия агонии"] = { 390, 405 },
		["Символ проклятия изнеможения"] = { 155, 165 },
		["Символ пути леса"] = { 515, 525 },
		["Символ пылающей ярости"] = { 485, 495 },
		["Символ пытки разума"] = { 185, 195 },
		["Символ размашистого удара"] = { 325, 335 },
		["Символ разрывания"] = { 205, 215 },
		["Символ разрывного выстрела"] = { 430, 440 },
		["Символ раскаленного доспеха"] = { 390, 405 },
		["Символ раскола брони"] = { 145, 155 },
		["Символ расправы"] = { 255, 270 },
		["Символ рассеивания заклинаний"] = { 235, 245 },
		["Символ рассечения"] = { 245, 255 },
		["Символ растворения в тени"] = { 80, 90 },
		["Символ рваной раны"] = { 390, 405 },
		["Символ реванша"] = { 195, 205 },
		["Символ ритуала Рока"] = { 510, 520 },
		["Символ роя насекомых"] = { 155, 165 },
		["Символ рунического удара"] = { 390, 405 },
		["Символ рывка"] = { 80, 90 },
		["Символ рыка"] = { 390, 405 },
		["Символ самоцвета маны"] = { 285, 295 },
		["Символ связки души"] = { 430, 440 },
		["Символ святой клятвы"] = { 430, 440 },
		["Символ священного гнева"] = { 390, 405 },
		["Символ сглаза"] = { 430, 440 },
		["Символ сдерживания"] = { 205, 215 },
		["Символ сдерживания Плети"] = { 380, 390 },
		["Символ сезона дождей"] = { 255, 270 },
		["Символ скачка"] = { 135, 145 },
		["Символ сковывания нежити"] = { 105, 115 },
		["Символ слияния с Тьмой"] = { 430, 440 },
		["Символ слова Тьмы: Смерть"] = { 390, 405 },
		["Символ слова силы: Щит"] = { 90, 110 },
		["Символ смертельного броска"] = { 390, 405 },
		["Символ смертельного удара"] = { 390, 405 },
		["Символ смертельной стужи"] = { 515, 525 },
		["Символ смерти и разложения"] = { 390, 405 },
		["Символ снятия проклятия"] = { 390, 405 },
		["Символ сокрушения"] = { 390, 405 },
		["Символ спасения"] = { 430, 440 },
		["Символ спринта"] = { 290, 300 },
		["Символ стаи"] = { 205, 215 },
		["Символ стойкости"] = { 80, 90 },
		["Символ столпа света"] = { 470, 480 },
		["Символ стража Скверны"] = { 390, 405 },
		["Символ страха"] = { 130, 140 },
		["Символ стрелы Тьмы"] = { 170, 180 },
		["Символ стрелы Хаоса"] = { 430, 440 },
		["Символ стремительного омоложения"] = { 380, 385 },
		["Символ стремительного рывка"] = { 95, 115 },
		["Символ стылой крови"] = { 180, 190 },
		["Символ суккуба"] = { 330, 340 },
		["Символ тайфуна"] = { 355, 365 },
		["Символ танца теней"] = { 430, 440 },
		["Символ танцующего рунического оружия"] = { 430, 440 },
		["Символ темной власти"] = { 390, 405 },
		["Символ тления"] = { 515, 525 },
		["Символ тотема гнева"] = { 255, 270 },
		["Символ тотема исцеляющего потока"] = { 220, 230 },
		["Символ тотема каменного когтя"] = { 430, 440 },
		["Символ тотема прилива маны"] = { 390, 405 },
		["Символ тотема элементаля огня"] = { 390, 405 },
		["Символ трепки"] = { 100, 120 },
		["Символ убийственного выстрела"] = { 430, 440 },
		["Символ увеличения питомца"] = { 515, 525 },
		["Символ увечья"] = { 390, 405 },
		["Символ удара Плети"] = { 335, 345 },
		["Символ удара бури"] = { 380, 390 },
		["Символ удара в сердце"] = { 390, 405 },
		["Символ удара в спину"] = { 90, 110 },
		["Символ удара воина Света"] = { 235, 245 },
		["Символ удара героя"] = { 105, 125 },
		["Символ удара грома"] = { 80, 90 },
		["Символ удара смерти"] = { 345, 355 },
		["Символ удара чумы"] = { 305, 315 },
		["Символ удара ящера"] = { 430, 440 },
		["Символ ударной волны"] = { 430, 440 },
		["Символ удушения"] = { 380, 390 },
		["Символ укуса виверны"] = { 390, 405 },
		["Символ укуса змеи"] = { 100, 120 },
		["Символ уменьшения питомца"] = { 465, 475 },
		["Символ уничтожения"] = { 390, 405 },
		["Символ ускользания"] = { 105, 125 },
		["Символ ухода в тень"] = { 110, 120 },
		["Символ фокусирования"] = { 380, 390 },
		["Символ хватки смерти"] = { 290, 300 },
		["Символ хождения по воде"] = { 155, 165 },
		["Символ хозяина вод"] = { 280, 290 },
		["Символ целительного прикосновения"] = { 120, 130 },
		["Символ цепного исцеления"] = { 390, 405 },
		["Символ цепной молнии"] = { 390, 405 },
		["Символ чародейских стрел"] = { 120, 130 },
		["Символ чародейского взрыва"] = { 105, 115 },
		["Символ чародейского выстрела"] = { 105, 115 },
		["Символ чародейского интеллекта"] = { 80, 90 },
		["Символ чародейского обстрела"] = { 430, 440 },
		["Символ чародейской вспышки"] = { 320, 330 },
		["Символ чародейской гениальности"] = { 510, 520 },
		["Символ частицы Света"] = { 430, 440 },
		["Символ череды убийств"] = { 430, 440 },
		["Символ черепов"] = { 515, 525 },
		["Символ черной смерти"] = { 280, 295 },
		["Символ чутья на нежить"] = { 105, 115 },
		["Символ шипов"] = { 80, 90 },
		["Символ шквала клинков"] = { 390, 405 },
		["Символ шока"] = { 390, 405 },
		["Символ шока небес"] = { 430, 440 },
		["Символ щедрого угощения"] = { 480, 490 },
		["Символ щита земли"] = { 255, 270 },
		["Символ щита молний"] = { 105, 125 },
		["Символ щита мстителя"] = { 390, 405 },
		["Символ щита праведности"] = { 430, 440 },
		["Символ экзорцизма"] = { 270, 280 },
		["Символ элементаля воды"] = { 390, 405 },
		["Символ ястреба"] = { 380, 390 },
		["Старшая карта Новолуния"] = { 350, 380 },
		["Странная карта"] = { 150, 175 },
		["Сумеречный фолиант"] = { 375, 400 },
		["Таинственная карта удачи"] = { 520, 530 },
		["Фельярдский свиток возвращения"] = { 500, 510 },
		["Фельярдский свиток защиты"] = { 500, 510 },
		["Фельярдский свиток исцеления"] = { 500, 510 },
		["Фельярдский свиток скорости"] = { 500, 510 },
		["Фолиант адского огня"] = { 340, 350 },
		["Фолиант в железном переплете"] = { 425, 450 },
		["Фолиант выживания"] = { 150, 175 },
		["Фолиант грозовых оков"] = { 290, 300 },
		["Фолиант королей"] = { 200, 210 },
		["Фолиант рассвета"] = { 150, 175 },
		["Чернила Преисподней"] = { 495, 505 },
		["Чернила лунного сияния"] = { 45, 75 },
		["Чернила моря"] = { 345, 355 },
		["Чернила нефритового пламени"] = { 145, 155 },
		["Чернила охотника"] = { 85, 95 },
		["Чернила снегопада"] = { 370, 380 },
		["Чернила утренней звезды"] = { 125, 135 },
		["Чернила царя зверей"] = { 95, 105 },
		["Чернила черного огня"] = { 320, 330 },
	},
	[129] = {
		["Бальзам с глазом огра"] = { 515, 525 },
		["Бинты из ветрошерсти"] = { 460, 495 },
		["Бинты из ледяной ткани"] = { 375, 410 },
		["Бинты из ледяной ткани Пустоты"] = { 400, 480 },
		["Бинты из магической ткани"] = { 210, 270 },
		["Бинты из рунической ткани"] = { 260, 320 },
		["Бинты из ткани Пустоты"] = { 330, 365 },
		["Концентрат энергии Кришадалиса"] = { 515, 525 },
		["Льняные бинты"] = { 30, 60 },
		["Масло из улетной рыбы"] = { 515, 525 },
		["Мощное противоядие"] = { 300, 360 },
		["Плотные бинты из ветрошерсти"] = { 495, 515 },
		["Плотные бинты из ледяной ткани"] = { 390, 470 },
		["Плотные бинты из магической ткани"] = { 240, 300 },
		["Плотные бинты из рунической ткани"] = { 290, 350 },
		["Плотные бинты из ткани Пустоты"] = { 360, 375 },
		["Плотные льняные бинты"] = { 50, 100 },
		["Плотные шелковые бинты"] = { 180, 240 },
		["Плотные шерстяные бинты"] = { 115, 185 },
		["Противоядие"] = { 80, 150 },
		["Противоядие Седой Лапы"] = { 515, 525 },
		["Сильное противоядие"] = { 130, 200 },
		["Шелковые бинты"] = { 150, 210 },
		["Шерстяные бинты"] = { 80, 150 },
	},
}

-- Где пригождается материал: [номер предмета] = { навык, "рецепт", навык, "рецепт", ... }
-- (из Spell.dbc: реагенты рецептов, в том числе ещё не изученных; навык рецепта — из SkillLineAbility.dbc).
CraftPlanReagents = {
	[118] = { 171, "Маленький флакон с лечебным зельем" },
	[159] = { 185, "Артишоковый чай", 185, "Отварные мидии", 185, "Похлебка 'Джунгли'", 185, "Похлебка из омаров", 185, "Суп из ночного луциана", 185, "Чай из златошипа", 202, "Большой сефориевый заряд", 202, "Малый сефориевый заряд", 202, "Мощный сефориевый заряд" },
	[723] = { 185, "Пирожок из печени кровоклыка" },
	[729] = { 185, "Похлебка Западного Края" },
	[730] = { 185, "Похлебка Западного Края" },
	[731] = { 185, "Похлебка Западного Края" },
	[765] = { 171, "Крохотный флакон с зельем маны", 171, "Крохотный флакон с лечебным зельем", 171, "Слабый эликсир защиты", 171, "Слабый эликсир ловкости", 171, "Эликсир львиной силы" },
	[769] = { 185, "Жареная кабанина" },
	[774] = { 164, "Медный боевой топор", 164, "Стальгорнская кольчуга", 164, "Украшенные медные рукавицы", 202, "Коробка с механической белкой", 202, "Кустарный прицел", 202, "Универсальный гномский дистанционный пульт", 202, "Шлем ныряльщика", 755, "Бронзовое кольцо силы", 755, "Инкрустированное малахитом кольцо", 755, "Малахитовая подвеска" },
	[783] = { 165, "Обработанная легкая шкура" },
	[785] = { 171, "Крохотный флакон с зельем маны", 171, "Маленький флакон с зельем маны", 171, "Слабое зелье защиты от магии", 171, "Слабое зелье омоложения", 171, "Эликсир мудрости", 171, "Эликсир наречий", 185, "Вкусный шоколадный торт" },
	[814] = { 202, "Гоблинский кабельный дефибриллятор", 202, "Универсальный гномский дистанционный пульт" },
	[818] = { 164, "Большой бронзовый нож", 164, "Стальгорнская кираса", 164, "Тяжелый медный длинный меч", 164, "Тяжелый медный палаш", 164, "Украшенные медные рукавицы", 202, "Очки летающего тигра", 202, "Универсальный гномский дистанционный пульт", 202, "Шлем ныряльщика", 755, "Бронзовое кольцо силы", 755, "Изысканное ожерелье тигрового глаза", 755, "Кольцо с тигровым глазом" },
	[929] = { 197, "Перчатки истинной веры" },
	[1015] = { 185, "Постный стейк из волчатины", 185, "Приправленная котлета из волчатины" },
	[1080] = { 185, "Гуляш по-красногорски" },
	[1081] = { 185, "Гуляш по-красногорски" },
	[1179] = { 185, "Вкусный шоколадный торт", 185, "Гоголь-моголь", 185, "Поминальный хлеб", 185, "Похлебка из моллюсков" },
	[1206] = { 164, "Блистающий стальной кинжал", 164, "Зеленый железный хауберк", 164, "Ослепительная мифриловая рапира", 164, "Сияющая серебряная кираса", 164, "Тяжелая бронзовая палица", 165, "Варварские поножи", 202, "Зеленые тонированные очки", 202, "Любовно выделанный огнестрел", 202, "Малый атомарный перенаправлятор", 202, "Обычный прицел", 202, "Украшенная подзорная труба", 755, "Подвеска Агатового Щита", 755, "Подвеска серебряной розы", 755, "Сверкающее ожерелье", 755, "Тяжелое золотое ожерелье битвы", 755, "Тяжелое серебряное кольцо" },
	[1210] = { 164, "Большая черная палица", 164, "Руническая медная кираса", 164, "Смертоносный бронзовый короткий кинжал", 164, "Стальгорнские рукавицы", 164, "Тяжелая бронзовая палица", 202, "Гоблинский кабельный дефибриллятор", 202, "Теневые очки", 755, "Бронзовое кольцо силы", 755, "Кольцо сумеречных призраков", 755, "Мрачное кольцо", 755, "Толстое бронзовое ожерелье" },
	[1288] = { 129, "Сильное противоядие", 171, "Эликсир излечения" },
	[1468] = { 185, "Суп из плавников мурлока" },
	[1475] = { 129, "Противоядие" },
	[1529] = { 164, "Зеленый железный хауберк", 164, "Клинок ледяного тигра", 164, "Ломатель", 164, "Нефритовый змеиный клинок", 165, "Железноперая кираса", 165, "Железноперые наплечники", 165, "Украшенный самоцветами кожаный пояс", 197, "Венец из ткани Грез", 202, "Анти-перенаправляющий луч", 202, "Боевой цыпленок гномов", 202, "Зеленая линза", 202, "Маскировочный механизм гномов", 202, "Точный прицел", 202, "Уменьшающий луч гномов", 755, "Золотое кольцо власти", 755, "Кольцо золотого дракона", 755, "Нефритовая подвеска взрыва", 755, "Нефритовое око", 755, "Подвеска серебряной розы", 755, "Статуэтка нефритовой совы", 755, "Тяжелое нефритовое кольцо" },
	[1705] = { 164, "Железный противовес", 164, "Закаленный железный короткий меч", 164, "Ослепительная мифриловая рапира", 164, "Палаш лунной стали", 164, "Позолоченный железный разрушитель", 164, "Полированные стальные сапоги", 164, "Сияющая серебряная кираса", 164, "Тяжелый железный молот", 202, "Лунная винтовка", 202, "Маскировочный механизм гномов", 755, "Амулет Луны", 755, "Бронзовое ожерелье", 755, "Гибельное кольцо лунного камня", 755, "Золотое кольцо власти", 755, "Корона лунной души", 755, "Тяжелое серебряное кольцо" },
	[2251] = { 185, "Пирожок из паучатины" },
	[2318] = { 164, "Медный боевой топор", 164, "Медный кинжал", 164, "Медный клеймор", 164, "Тяжелая медная кувалда", 164, "Утолщенная секира", 165, "Белый кожаный жакет", 165, "Жесткая кожа", 165, "Жилет лунного сияния", 165, "Кираса из чешуи мурлока", 165, "Колчан из тонкой кожи", 165, "Накладки из тонкой кожи", 165, "Наручи из тонкой кожи", 165, "Небольшой кожаный подсумок", 165, "Пояс из чешуи мурлока", 165, "Рукодельные кожаные наручи", 165, "Рукодельные кожаные сапоги", 165, "Рукодельные кожаные штаны", 165, "Рукодельный кожаный жилет", 165, "Рукодельный кожаный плащ", 165, "Рукодельный кожаный пояс", 165, "Сумка из шкуры кодо", 165, "Тисненые кожаные перчатки", 165, "Тисненые кожаные сапоги", 165, "Тисненые кожаные штаны", 165, "Тисненый кожаный жилет", 165, "Тисненый кожаный плащ", 165, "Тонкие кожаные перчатки", 165, "Тонкие кожаные сапоги", 165, "Тонкий кожаный мундир", 165, "Тонкий кожаный плащ", 165, "Тонкий кожаный пояс", 165, "Штаны из грубой кожи", 165, "Штаны из тонкой кожи", 197, "Варварский льняной жилет", 197, "Красные шерстяные сапоги", 197, "Льняные сапоги", 197, "Льняные сапоги с мягкой подошвой", 197, "Простые льняные сапоги", 197, "Шерстяные сапоги", 202, "Малый сефориевый заряд", 202, "Очки летающего тигра" },
	[2319] = { 164, "Большой бронзовый нож", 164, "Бронзовая палица", 164, "Бронзовый боевой молот", 164, "Бронзовый боевой топор", 164, "Бронзовый длинный меч", 164, "Бронзовый короткий меч", 164, "Бронзовый топор", 164, "Радужный молот", 164, "Смертоносный бронзовый короткий кинжал", 164, "Тяжелая бронзовая палица", 164, "Тяжелый железный молот", 164, "Тяжелый медный палаш", 164, "Утолщенные бронзовые дротики", 165, "Кожаные наплечники земли", 165, "Кожаные перчатки жителя холмов", 165, "Мундир из чешуи черного дракончика", 165, "Накладки из жесткой кожи", 165, "Наплечники жителя холмов", 165, "Перчатки Флетчера", 165, "Перчатки жулика", 165, "Перчатки из гибкой кожи", 165, "Перчатки из чешуи красного дракончика", 165, "Перчатки травника", 165, "Плащ из чешуи черного дракончика", 165, "Пояс жителя холмов", 165, "Темные кожаные наплечники", 165, "Темные кожаные перчатки", 165, "Темные кожаные сапоги", 165, "Темные кожаные штаны", 165, "Темный кожаный мундир", 165, "Темный кожаный плащ", 165, "Толстая кожа", 165, "Тонкие кожаные штаны", 165, "Тяжелые перчатки Земли", 165, "Укрепленные кожаные перчатки", 165, "Укрепленный кожаный доспех", 197, "Сапоги Тьмы", 197, "Сапоги из паучьего шелка", 197, "Усиленные шерстяные наплечники", 202, "Бронзовый каркас", 202, "Зеленые тонированные очки", 202, "Маленькая зеленая ракета", 202, "Маленькая красная ракета", 202, "Маленькая синяя ракета", 202, "Малый атомарный перенаправлятор", 202, "Переносной бронзовый миномет", 202, "Смертоносный мушкетон", 202, "Теневые очки" },
	[2320] = { 165, "Белый кожаный жакет", 165, "Жилет лунного сияния", 165, "Кожаный жилет жителя холмов", 165, "Колчан из тонкой кожи", 165, "Накладки из жесткой кожи", 165, "Наручи из тонкой кожи", 165, "Небольшой кожаный подсумок", 165, "Рукодельные кожаные наручи", 165, "Рукодельные кожаные сапоги", 165, "Рукодельные кожаные штаны", 165, "Рукодельный кожаный жилет", 165, "Рукодельный кожаный плащ", 165, "Рукодельный кожаный пояс", 165, "Сумка из шкуры кодо", 165, "Тисненые кожаные перчатки", 165, "Тисненые кожаные сапоги", 165, "Тисненые кожаные штаны", 165, "Тисненый кожаный жилет", 165, "Тисненый кожаный плащ", 165, "Тонкие кожаные перчатки", 165, "Тонкие кожаные сапоги", 165, "Тонкий кожаный мундир", 165, "Тонкий кожаный пояс", 165, "Штаны из грубой кожи", 197, "Белая льняная рубашка", 197, "Белое льняное одеяние", 197, "Зеленые льняные наручи", 197, "Коричневая льняная рубашка", 197, "Коричневое льняное одеяние", 197, "Коричневые льняные штаны", 197, "Коричневый льняной жилет", 197, "Красная льняная рубашка", 197, "Красное льняное одеяние", 197, "Красный льняной жилет", 197, "Льняная сумка", 197, "Льняной плащ", 197, "Льняной пояс", 197, "Льняные сапоги", 197, "Простое платье", 197, "Простые льняные сапоги", 197, "Простые льняные штаны", 197, "Синее льняное одеяние", 197, "Синий льняной жилет", 197, "Синяя льняная рубашка", 197, "Тяжелые льняные перчатки", 197, "Усиленная льняная накидка" },
	[2321] = { 164, "Рунические медные штаны", 165, "Броня из зеленого дракончика", 165, "Броня из толстой чешуи мурлока", 165, "Варварская портупея", 165, "Варварские наплечники", 165, "Варварские перчатки", 165, "Варварские поножи", 165, "Защитная броня стража", 165, "Зеленые кожаные наручи", 165, "Зеленый кожаный доспех", 165, "Зеленый кожаный пояс", 165, "Кираса из чешуи мурлока", 165, "Кожаные наплечники земли", 165, "Кожаные перчатки жителя холмов", 165, "Ледяной кожаный плащ", 165, "Мглистые кожаные поножи", 165, "Мглистый кожаный доспех", 165, "Мундир из чешуи черного дракончика", 165, "Мяч из толстой кожи", 165, "Накладки из толстой кожи", 165, "Наплечники жителя холмов", 165, "Перчатки Флетчера", 165, "Перчатки жулика", 165, "Перчатки из гибкой кожи", 165, "Перчатки из искаженной чешуи", 165, "Перчатки из чешуи красного дракончика", 165, "Перчатки травника", 165, "Плащ жителя холмов", 165, "Плащ из искаженной чешуи", 165, "Плащ из чешуи черного дракончика", 165, "Подсумок из толстой кожи", 165, "Портупея из шкуры ящера", 165, "Пояс жителя холмов", 165, "Пояс из искаженной чешуи", 165, "Пояс из чешуи мурлока", 165, "Пояс из шкуры ящера", 165, "Пояс стража", 165, "Темные кожаные наплечники", 165, "Темные кожаные перчатки", 165, "Темные кожаные сапоги", 165, "Темные кожаные штаны", 165, "Темный кожаный мундир", 165, "Темный кожаный плащ", 165, "Темный кожаный пояс", 165, "Тонкие кожаные штаны", 165, "Тонкий кожаный плащ", 165, "Тяжелые перчатки Земли", 165, "Тяжелый колчан", 165, "Украшенный самоцветами кожаный пояс", 165, "Укрепленные кожаные перчатки", 165, "Укрепленный кожаный доспех", 165, "Штаны из тонкой кожи", 165, "Штаны стража", 197, "Багровый шелковый жилет", 197, "Белое шерстяное платье", 197, "Большее одеяние адепта", 197, "Варварский льняной жилет", 197, "Жилет Земли", 197, "Зеленая льняная рубашка", 197, "Зеленая шелковая сума", 197, "Зеленая шерстяная сумка", 197, "Зеленое шерстяное одеяние", 197, "Зеленый шерстяной жилет", 197, "Клобук волшебника", 197, "Краги Тьмы", 197, "Красная льняная сумка", 197, "Красная шерстяная сумка", 197, "Красные шерстяные сапоги", 197, "Лазурные шелковые перчатки", 197, "Лазурные шелковые штаны", 197, "Лазурный шелковый капюшон", 197, "Лазурный шелковый плащ", 197, "Лазурный шелковый пояс", 197, "Льняные сапоги с мягкой подошвой", 197, "Маленькая шелковая сумка", 197, "Многоцветный килт", 197, "Одеяния Тайны", 197, "Пелерина из паучьего шелка", 197, "Перчатки Медитации", 197, "Перчатки Феникса", 197, "Перчатки истинной веры", 197, "Плащ с перламутровыми застежками", 197, "Простое одеяние волшебника", 197, "Простой килт", 197, "Рукодельные льняные брюки", 197, "Сапоги Тьмы", 197, "Серая шерстяная рубашка", 197, "Серое шерстяное одеяние", 197, "Синий комбинезон", 197, "Стильная зеленая рубашка", 197, "Стильная красная рубашка", 197, "Стильная синяя рубашка", 197, "Темная шелковая рубашка", 197, "Туфли из паутины", 197, "Тяжелые шерстяные перчатки", 197, "Тяжелые шерстяные штаны", 197, "Тяжелый шерстяной плащ", 197, "Усиленные шерстяные наплечники", 197, "Церемониальная белая рубашка", 197, "Черная шелковая сума", 197, "Шелковая головная повязка", 197, "Шерстяная накидка", 197, "Шерстяная сумка", 197, "Шерстяные наплечники с двойным швом", 197, "Шерстяные сапоги", 197, "Штаны Феникса", 197, "Ярко-желтая рубашка" },
	[2324] = { 165, "Белый кожаный жакет", 197, "Белая бандитская маска", 197, "Белая льняная рубашка", 197, "Белая рубашка сорвиголовы", 197, "Белое льняное одеяние", 197, "Белое свадебное платье", 197, "Белое шерстяное платье", 197, "Перчатки Феникса", 197, "Простое платье", 197, "Простое черное платье", 197, "Церемониальная белая рубашка" },
	[2325] = { 165, "Вычурная походная шляпа", 165, "Гибельная кожаная головная повязка", 165, "Гибельные кожаные наручи", 165, "Гибельные кожаные рукавицы", 165, "Гибельные кожаные штаны", 165, "Гибельный кожаный доспех", 165, "Гибельный кожаный пояс", 165, "Мглистые кожаные поножи", 165, "Мглистые наручи", 165, "Мглистый пояс", 197, "Куртка Халискана", 197, "Кюлоты Халискана", 197, "Простое черное платье", 197, "Черная рубашка сорвиголовы", 197, "Черная шелковая сума" },
	[2447] = { 171, "Крохотный флакон с лечебным зельем", 171, "Слабое зелье омоложения", 171, "Слабое зелье тролльей крови", 171, "Слабый эликсир стойкости", 171, "Флакон с бесцветным лечебным зельем" },
	[2449] = { 171, "Слабое зелье тролльей крови", 171, "Слабый эликсир стойкости", 171, "Эликсир львиной силы", 171, "Эликсир наречий", 171, "Эликсир силы огра", 171, "Эликсир увеличения" },
	[2450] = { 171, "Зелье скорости", 171, "Крепкое зелье тролльей крови", 171, "Лечебное зелье", 171, "Маленький флакон с лечебным зельем", 171, "Эликсир мудрости" },
	[2452] = { 171, "Зелье быстрого плавания", 171, "Зелье защиты от светлой магии", 171, "Зелье скорости", 171, "Малый эликсир ловкости", 171, "Слабый эликсир ловкости", 185, "Артишоковый чай" },
	[2453] = { 171, "Большой эликсир тролльей крови", 171, "Зелье защиты от светлой магии", 171, "Крепкое зелье тролльей крови", 171, "Лечебное зелье", 171, "Слабый эликсир меткости", 171, "Эликсир излечения" },
	[2457] = { 165, "Перчатки из гибкой кожи" },
	[2459] = { 164, "Смертоносный бронзовый короткий кинжал", 165, "Сапоги быстроты" },
	[2589] = { 129, "Льняные бинты", 129, "Плотные льняные бинты", 164, "Грубое грузило", 164, "Медная палица", 164, "Медный короткий меч", 164, "Медный топор", 197, "Рулон льняной ткани", 202, "Грубая медная бомба", 202, "Грубый динамит", 202, "Медный регулятор", 202, "Низкосортный динамит" },
	[2592] = { 129, "Плотные шерстяные бинты", 129, "Шерстяные бинты", 164, "Зернистое грузило", 164, "Тяжелое грузило", 197, "Рулон шерсти", 202, "Бронзовый каркас", 202, "Взрывоопасная овца", 202, "Динамит 'Pro-100-брос'", 202, "Манекен-мишень", 202, "Небольшая бронзовая бомба", 202, "Трещащий бронзовый механизм", 202, "Тяжелый динамит" },
	[2593] = { 185, "Вкусный шоколадный торт" },
	[2594] = { 185, "Светлое пиво капитана Ромси" },
	[2596] = { 185, "Загадочная похлебка", 185, "Светлое пиво капитана Ромси" },
	[2604] = { 165, "Вычурная багровая шляпа", 197, "Багровое шелковое одеяние", 197, "Багровые шелковые кюлоты", 197, "Багровые шелковые наплечники", 197, "Багровые шелковые перчатки", 197, "Багровый шелковый жилет", 197, "Багровый шелковый плащ", 197, "Багровый шелковый пояс", 197, "Большее одеяние адепта", 197, "Великолепный ковер-самолет", 197, "Красная головная повязка из магической ткани", 197, "Красная льняная рубашка", 197, "Красная льняная сумка", 197, "Красная рубашка дровосека", 197, "Красная рубашка рабочего", 197, "Красная рубашка сорвиголовы", 197, "Красная сумка из магической ткани", 197, "Красная шерстяная сумка", 197, "Красное льняное одеяние", 197, "Красные зимние одежды", 197, "Красные наплечники из магической ткани", 197, "Красные перчатки из магической ткани", 197, "Красные шерстяные сапоги", 197, "Красные штаны из магической ткани", 197, "Красный жилет из магической ткани", 197, "Красный льняной жилет", 197, "Куртка Халискана", 197, "Многоцветный килт", 197, "Праздничное платье", 197, "Праздничный красный костюм", 197, "Стильная красная рубашка", 202, "Красная дымовая сигнальная ракета" },
	[2605] = { 164, "Зеленые железные наплечники", 164, "Зеленые железные наручи", 164, "Зеленые железные поножи", 164, "Зеленые железные рукавицы", 164, "Зеленые железные сапоги", 164, "Зеленый железный шлем", 165, "Зеленые кожаные наручи", 165, "Зеленый кожаный доспех", 165, "Зеленый кожаный пояс", 197, "Зеленая выходная рубашка", 197, "Зеленая льняная рубашка", 197, "Зеленая рубашка дровосека", 197, "Зеленая рубашка рабочего", 197, "Зеленая шелковая броня", 197, "Зеленая шелковая сума", 197, "Зеленая шерстяная сумка", 197, "Зеленое шерстяное одеяние", 197, "Зеленые зимние одежды", 197, "Зеленые льняные наручи", 197, "Зеленый шерстяной жилет", 197, "Стильная зеленая рубашка", 202, "Зеленая дымовая сигнальная ракета" },
	[2672] = { 185, "Волчатина на углях", 185, "Волчатина с пряностями" },
	[2673] = { 185, "Стейк из койота" },
	[2674] = { 185, "Пирожок с мясом краба" },
	[2675] = { 185, "Вареная клешня краба" },
	[2677] = { 185, "Сочные свиные ребрышки", 185, "Сушеные свиные ребрышки" },
	[2678] = { 185, "Вкусный шоколадный торт", 185, "Хлеб с пряностями" },
	[2770] = { 186, "Выплавка меди" },
	[2771] = { 186, "Выплавка олова" },
	[2772] = { 186, "Выплавка железа", 333, "Чары для перчаток - горное дело I" },
	[2775] = { 186, "Выплавка серебра" },
	[2776] = { 186, "Выплавка золота" },
	[2835] = { 164, "Грубое грузило", 164, "Грубое точило", 164, "Грубый шлифовальный камень", 202, "Грубое взрывчатое вещество", 755, "Статуя из грубого камня" },
	[2836] = { 164, "Зернистое грузило", 164, "Зернистое точило", 164, "Зернистый шлифовальный камень", 202, "Низкосортное взрывчатое вещество", 755, "Статуя из необработанного камня" },
	[2838] = { 164, "Тяжелое грузило", 164, "Тяжелое точило", 164, "Тяжелый шлифовальный камень", 202, "Тяжелое взрывчатое вещество", 755, "Массивная каменная статуя" },
	[2840] = { 164, "Грубый медный жилет", 164, "Медная палица", 164, "Медные наручи", 164, "Медные плетеные сапоги", 164, "Медные плетеные штаны", 164, "Медный боевой топор", 164, "Медный кинжал", 164, "Медный клеймор", 164, "Медный короткий меч", 164, "Медный плетеный нагрудник", 164, "Медный плетеный пояс", 164, "Медный топор", 164, "Руническая медная кираса", 164, "Рунические медные наручи", 164, "Рунические медные рукавицы", 164, "Рунические медные штаны", 164, "Рунический медный пояс", 164, "Стальгорнская кираса", 164, "Стальгорнская кольчуга", 164, "Тяжелая медная кувалда", 164, "Тяжелый медный длинный меч", 164, "Тяжелый медный палаш", 164, "Украшенные медные рукавицы", 164, "Утолщенная секира", 165, "Зимние сапоги", 186, "Выплавка бронзы", 202, "Большая медная бомба", 202, "Горсть медных винтов", 202, "Грубая медная бомба", 202, "Искусно изготовленная амуниция", 202, "Коробка с механической белкой", 202, "Медная труба", 202, "Медный регулятор", 202, "Тангенциальный вращатель", 202, "Тяжелая искусно изготовленная амуниция", 755, "Изысканное ожерелье тигрового глаза", 755, "Инкрустированное малахитом кольцо", 755, "Плетеное медное кольцо", 755, "Простое жемчужное кольцо", 755, "Тонкая медная проволока", 755, "Тяжелое медное кольцо" },
	[2841] = { 164, "Большой бронзовый нож", 164, "Бронзовая палица", 164, "Бронзовый боевой молот", 164, "Бронзовый боевой топор", 164, "Бронзовый длинный меч", 164, "Бронзовый короткий меч", 164, "Бронзовый топор", 164, "Грубые бронзовые наплечники", 164, "Грубые бронзовые наручи", 164, "Грубые бронзовые поножи", 164, "Грубые бронзовые сапоги", 164, "Грубый бронзовый панцирь", 164, "Кинжал с жемчужной рукояткой", 164, "Посеребренная бронзовая кираса", 164, "Посеребренные бронзовые наплечники", 164, "Посеребренные бронзовые поножи", 164, "Посеребренные бронзовые рукавицы", 164, "Посеребренные бронзовые сапоги", 164, "Радужный молот", 164, "Сияющая серебряная кираса", 164, "Смертоносный бронзовый короткий кинжал", 164, "Стальгорнские рукавицы", 164, "Тяжелая бронзовая палица", 164, "Украшенные узором бронзовые наручи", 164, "Утолщенные бронзовые дротики", 202, "Аквадинамический магнит для рыбы", 202, "Большая бронзовая бомба", 202, "Бронзовая трубка", 202, "Бронзовый каркас", 202, "Манекен-мишень", 202, "Небольшая бронзовая бомба", 202, "Твердая искусно изготовленная амуниция", 202, "Трещащий бронзовый механизм", 202, "Универсальный гномский дистанционный пульт", 202, "Учебный замок", 755, "Бронзовая оправа", 755, "Бронзовое кольцо силы", 755, "Бронзовое ожерелье", 755, "Кольцо сумеречных призраков", 755, "Сверкающее ожерелье", 755, "Толстое бронзовое ожерелье", 755, "Цельное бронзовое кольцо" },
	[2842] = { 164, "Посеребренная бронзовая кираса", 164, "Посеребренные бронзовые наплечники", 164, "Посеребренные бронзовые поножи", 164, "Посеребренные бронзовые рукавицы", 164, "Посеребренные бронзовые сапоги", 164, "Прочная железная кувалда", 164, "Рунические латные сапоги", 164, "Серебряная отмычка", 164, "Серебряный жезл", 164, "Сияющая серебряная кираса", 164, "Утолщенная секира", 202, "Посеребренный дробовик", 202, "Серебряный контакт", 755, "Корона лунной души", 755, "Подвеска серебряной розы", 755, "Серебряное кольцо могущества", 755, "Тяжелое серебряное кольцо", 755, "Элегантное серебряное кольцо" },
	[2880] = { 164, "Большой бронзовый нож", 164, "Бронзовая палица", 164, "Бронзовый короткий меч", 164, "Бронзовый топор", 164, "Медная палица", 164, "Медный боевой топор", 164, "Медный кинжал", 164, "Медный клеймор", 164, "Медный короткий меч", 164, "Медный топор", 164, "Тяжелая медная кувалда", 164, "Тяжелый медный палаш", 164, "Утолщенная секира", 202, "Бронзовая трубка", 202, "Медная труба", 202, "Учебный замок" },
	[2886] = { 185, "Кабаньи ребрышки в пиве" },
	[2901] = { 202, "Гномский армейский нож" },
	[2924] = { 185, "Стейк из кроколиска" },
	[2934] = { 165, "Тонкая кожа" },
	[2996] = { 197, "Белая льняная рубашка", 197, "Белое льняное одеяние", 197, "Варварский льняной жилет", 197, "Зеленая льняная рубашка", 197, "Зеленые льняные наручи", 197, "Коричневая льняная рубашка", 197, "Коричневое льняное одеяние", 197, "Коричневые льняные штаны", 197, "Коричневый льняной жилет", 197, "Красная льняная рубашка", 197, "Красная льняная сумка", 197, "Красное льняное одеяние", 197, "Красный льняной жилет", 197, "Льняная сумка", 197, "Льняной плащ", 197, "Льняной пояс", 197, "Льняные сапоги", 197, "Льняные сапоги с мягкой подошвой", 197, "Простое платье", 197, "Простой килт", 197, "Простые льняные сапоги", 197, "Простые льняные штаны", 197, "Рукодельные льняные брюки", 197, "Синее льняное одеяние", 197, "Синий льняной жилет", 197, "Синяя льняная рубашка", 197, "Тяжелые льняные перчатки", 197, "Усиленная льняная накидка" },
	[2997] = { 165, "Зимние сапоги", 165, "Тонкие кожаные штаны", 165, "Тяжелые перчатки Земли", 197, "Белое шерстяное платье", 197, "Большее одеяние адепта", 197, "Зеленая шерстяная сумка", 197, "Зеленое шерстяное одеяние", 197, "Зеленые зимние одежды", 197, "Зеленый шерстяной жилет", 197, "Красная шерстяная сумка", 197, "Красные зимние одежды", 197, "Красные шерстяные сапоги", 197, "Многоцветный килт", 197, "Перчатки Медитации", 197, "Перчатки Феникса", 197, "Плащ с перламутровыми застежками", 197, "Серая шерстяная рубашка", 197, "Серое шерстяное одеяние", 197, "Синий комбинезон", 197, "Стильная зеленая рубашка", 197, "Стильная красная рубашка", 197, "Стильная синяя рубашка", 197, "Тяжелые шерстяные перчатки", 197, "Тяжелые шерстяные штаны", 197, "Тяжелый шерстяной плащ", 197, "Усиленные шерстяные наплечники", 197, "Шерстяная накидка", 197, "Шерстяная сумка", 197, "Шерстяные наплечники с двойным швом", 197, "Шерстяные сапоги", 197, "Штаны Феникса" },
	[3164] = { 171, "Флакон с бесцветным лечебным зельем" },
	[3172] = { 185, "Кровяная колбаса" },
	[3173] = { 185, "Копченая медвежатина", 185, "Кровяная колбаса" },
	[3174] = { 185, "Кровяная колбаса" },
	[3182] = { 165, "Укрепленные кожаные перчатки", 197, "Одеяния Тайны", 197, "Пелерина из паучьего шелка", 197, "Простое одеяние волшебника", 197, "Сапоги из паучьего шелка", 197, "Туфли из паутины" },
	[3355] = { 171, "Зелье простой невидимости", 171, "Малый эликсир ловкости", 171, "Сильный эликсир защиты", 171, "Слабое зелье защиты от магии", 171, "Эликсир Защиты", 171, "Эликсир стойкости" },
	[3356] = { 165, "Перчатки травника", 171, "Зелье защиты от темной магии", 171, "Зелье маны", 171, "Сильнодействующее зелье ярости", 171, "Средний флакон с лечебным зельем", 171, "Эликсир огневой мощи", 171, "Эликсир силы огра", 333, "Чары для перчаток - травничество I" },
	[3357] = { 171, "Большой эликсир тролльей крови", 171, "Зелье защиты от сил природы", 171, "Средний флакон с лечебным зельем" },
	[3358] = { 171, "Большой флакон с лечебным зельем", 171, "Зелье защиты от магии", 171, "Масло льда", 171, "Сильный эликсир интеллекта", 171, "Средний флакон с зельем маны", 171, "Эликсир обнаружения простой невидимости", 171, "Эликсир силы льда" },
	[3369] = { 171, "Зелье защиты от темной магии", 171, "Масло Тьмы" },
	[3371] = { 171, "Зелье быстрого плавания", 171, "Зелье защиты от светлой магии", 171, "Зелье скорости", 171, "Зелье ярости", 171, "Крохотный флакон с зельем маны", 171, "Крохотный флакон с лечебным зельем", 171, "Маленький флакон с зельем маны", 171, "Слабое зелье защиты от магии", 171, "Слабое зелье омоложения", 171, "Слабое зелье тролльей крови", 171, "Слабый эликсир защиты", 171, "Слабый эликсир ловкости", 171, "Слабый эликсир меткости", 171, "Слабый эликсир стойкости", 171, "Флакон с бесцветным лечебным зельем", 171, "Эликсир львиной силы", 171, "Эликсир мудрости", 171, "Эликсир наречий", 171, "Эликсир подводного дыхания", 171, "Эликсир увеличения", 333, "Слабое волшебное масло" },
	[3372] = { 171, "Большой эликсир тролльей крови", 171, "Гоблинское ракетное топливо", 171, "Зелье защиты от магии льда", 171, "Зелье защиты от огня", 171, "Зелье защиты от сил природы", 171, "Зелье защиты от темной магии", 171, "Зелье маны", 171, "Зелье простой невидимости", 171, "Зелье свободы действий", 171, "Крепкое зелье тролльей крови", 171, "Лечебное зелье", 171, "Малый эликсир ловкости", 171, "Масло Тьмы", 171, "Масло льда", 171, "Простое зелье каменного щита", 171, "Сильнодействующее зелье ярости", 171, "Сильный эликсир защиты", 171, "Средний флакон с зельем маны", 171, "Средний флакон с лечебным зельем", 171, "Эликсир 'Кошачий глаз'", 171, "Эликсир Защиты", 171, "Эликсир излечения", 171, "Эликсир ловкости", 171, "Эликсир обнаружения простой невидимости", 171, "Эликсир огневой мощи", 171, "Эликсир силы льда", 171, "Эликсир силы огра", 171, "Эликсир стойкости", 333, "Простое волшебное масло", 333, "Слабое масло маны" },
	[3383] = { 165, "Пояс жителя холмов", 197, "Перчатки Медитации" },
	[3389] = { 165, "Укрепленные кожаные перчатки" },
	[3390] = { 165, "Темные кожаные наплечники" },
	[3391] = { 164, "Тяжелый железный молот", 755, "Тяжелое золотое ожерелье битвы", 755, "Тяжелый железный кастет" },
	[3404] = { 185, "Жареное крыло канюка" },
	[3466] = { 164, "Блистающий стальной кинжал", 164, "Бронзовый боевой молот", 164, "Бронзовый боевой топор", 164, "Бронзовый длинный меч", 164, "Закаленный железный короткий меч", 164, "Кинжал с жемчужной рукояткой", 164, "Массивный железный топор", 164, "Нефритовый змеиный клинок", 164, "Палаш лунной стали", 164, "Позолоченный железный разрушитель", 164, "Прочная железная кувалда", 164, "Радужный молот", 164, "Смертоносный бронзовый короткий кинжал", 164, "Тяжелая бронзовая палица", 164, "Тяжелый железный молот" },
	[3470] = { 164, "Большой бронзовый нож", 164, "Грубые бронзовые сапоги", 164, "Медный боевой топор", 164, "Медный кинжал", 164, "Медный клеймор", 164, "Медный плетеный нагрудник", 164, "Руническая медная кираса", 164, "Рунические медные наручи", 164, "Рунические медные рукавицы", 164, "Рунические медные штаны", 164, "Серебряная отмычка", 164, "Серебряный жезл", 164, "Стальгорнская кираса", 164, "Стальгорнская кольчуга", 164, "Тяжелый медный длинный меч", 164, "Утолщенная секира", 164, "Утолщенные бронзовые дротики" },
	[3478] = { 164, "Грубые бронзовые наплечники", 164, "Железный противовес", 164, "Железный шип для щита", 164, "Зеленые железные рукавицы", 164, "Зеленые железные сапоги", 164, "Золотой жезл", 164, "Кинжал с жемчужной рукояткой", 164, "Посеребренная бронзовая кираса", 164, "Посеребренные бронзовые наплечники", 164, "Посеребренные бронзовые поножи", 164, "Посеребренные бронзовые рукавицы", 164, "Посеребренные бронзовые сапоги", 164, "Радужный молот", 164, "Смертоносный бронзовый короткий кинжал", 164, "Стальгорнские рукавицы", 164, "Тяжелая бронзовая палица", 164, "Тяжелый железный молот", 164, "Украшенные узором бронзовые наручи" },
	[3486] = { 164, "Варварская железная кираса", 164, "Варварские железные наплечники", 164, "Варварские железные перчатки", 164, "Варварские железные сапоги", 164, "Жезл из истинного серебра", 164, "Закаленный железный короткий меч", 164, "Зеленые железные наплечники", 164, "Зеленые железные поножи", 164, "Зеленый железный хауберк", 164, "Золотая отмычка", 164, "Золотой чешуйчатый капюшон", 164, "Золотой чешуйчатый панцирь", 164, "Золотые чешуйчатые наплечники", 164, "Золотые чешуйчатые наручи", 164, "Золотые чешуйчатые поножи", 164, "Золотые чешуйчатые рукавицы", 164, "Золотые чешуйчатые сапоги", 164, "Крутящиеся стальные топоры", 164, "Массивный железный топор", 164, "Нефритовый змеиный клинок", 164, "Палаш лунной стали", 164, "Позолоченный железный разрушитель", 164, "Полированные стальные сапоги", 164, "Прочная железная кувалда", 164, "Стальная кираса", 164, "Стальная цепь для оружия" },
	[3575] = { 164, "Варварская железная кираса", 164, "Варварские железные наплечники", 164, "Варварские железные перчатки", 164, "Варварские железные сапоги", 164, "Варварский железный шлем", 164, "Железная скоба", 164, "Железный противовес", 164, "Железный шип для щита", 164, "Закаленный железный короткий меч", 164, "Зеленые железные наплечники", 164, "Зеленые железные наручи", 164, "Зеленые железные поножи", 164, "Зеленые железные рукавицы", 164, "Зеленые железные сапоги", 164, "Зеленый железный хауберк", 164, "Зеленый железный шлем", 164, "Золотые чешуйчатые поножи", 164, "Массивный железный топор", 164, "Нефритовый змеиный клинок", 164, "Позолоченный железный разрушитель", 164, "Прочная железная кувалда", 164, "Тяжелый железный молот", 171, "Трансмутация железа в золото", 171, "Философский камень", 186, "Выплавка стали", 202, "Большая железная бомба", 202, "Гирохронатом", 202, "Гоблинская наземная мина", 202, "Гоблинский кабельный дефибриллятор", 202, "Железная балка", 202, "Железная граната", 755, "Варварский железный ошейник", 755, "Гибельное кольцо лунного камня", 755, "Тяжелое нефритовое кольцо", 755, "Тяжелый железный кастет" },
	[3576] = { 186, "Выплавка бронзы" },
	[3577] = { 164, "Золотая отмычка", 164, "Золотой жезл", 164, "Золотой чешуйчатый капюшон", 164, "Золотой чешуйчатый панцирь", 164, "Золотые чешуйчатые наплечники", 164, "Золотые чешуйчатые поножи", 164, "Золотые чешуйчатые рукавицы", 164, "Золотые чешуйчатые сапоги", 164, "Инкрустированный мифриловый цилиндр", 164, "Инкрустированный ториевый молот", 164, "Массивный железный топор", 164, "Позолоченный железный разрушитель", 164, "Пылающий золотой клинок", 164, "Рунические латные наплечники", 164, "Шлем чистой души", 197, "Одеяние из яркой ткани", 197, "Перчатки из яркой ткани", 197, "Плащ из яркой ткани", 197, "Штаны из яркой ткани", 202, "Золотое силовое ядро", 755, "Золотое кольцо власти", 755, "Кольцо золотого дракона", 755, "Статуэтка золотого зайца", 755, "Тяжелое золотое ожерелье битвы", 755, "Цитриновая подвеска исцеления" },
	[3667] = { 185, "Суп из кроколиска", 185, "Сытная похлебка из кроколиска" },
	[3685] = { 185, "Невероятно вкусный омлет" },
	[3712] = { 185, "Нежный черепаховый суп" },
	[3730] = { 185, "Большой медвежий стейк" },
	[3731] = { 185, "Острая отбивная из мяса льва", 185, "Сочный стейк из мяса льва" },
	[3818] = { 171, "Зелье простой невидимости", 171, "Масло Тьмы", 171, "Эликсир 'Кошачий глаз'", 171, "Эликсир обнаружения простой невидимости" },
	[3819] = { 171, "Зелье защиты от магии льда", 171, "Масло льда", 171, "Эликсир силы льда", 333, "Чары для оружия - могущество зимы" },
	[3820] = { 171, "Зелье защиты от сил природы", 171, "Зелье маны", 171, "Зелье свободы действий", 171, "Маленький флакон с зельем маны", 171, "Эликсир Защиты", 171, "Эликсир ловкости", 171, "Эликсир подводного дыхания" },
	[3821] = { 171, "Воспламеняющая смесь", 171, "Зелье защиты от магии льда", 171, "Приводящее в сознание зелье", 171, "Простое зелье каменного щита", 171, "Сильный эликсир защиты", 171, "Сильный эликсир ловкости", 171, "Средний флакон с зельем маны", 171, "Чародейский эликсир", 171, "Эликсир 'Кошачий глаз'", 171, "Эликсир ловкости", 171, "Эликсир стойкости", 185, "Чай из златошипа" },
	[3823] = { 164, "Фантомный клинок" },
	[3824] = { 164, "Серповидная секира тени", 165, "Защитная броня стража", 165, "Мглистый кожаный доспех", 171, "Сильное зелье защиты от темной магии", 197, "Теневой капюшон", 755, "Гибельное кольцо лунного камня" },
	[3827] = { 197, "Багровое шелковое одеяние", 197, "Длинный шелковый плащ", 755, "Корона лунной души" },
	[3829] = { 164, "Клинок ледяного тигра", 164, "Кромка Зимы", 197, "Ледяной плащ", 202, "Гирозамораживающий ледяной отражатель", 202, "Ледяной отражатель", 202, "Создатель снега 9000", 333, "Чары для щита - сопротивление льду" },
	[3857] = { 186, "Выплавка стали" },
	[3858] = { 171, "Простое зелье каменного щита", 186, "Выплавка мифрила" },
	[3859] = { 164, "Блистающий стальной кинжал", 164, "Золотой чешуйчатый капюшон", 164, "Золотой чешуйчатый панцирь", 164, "Золотые чешуйчатые наплечники", 164, "Золотые чешуйчатые наручи", 164, "Золотые чешуйчатые рукавицы", 164, "Золотые чешуйчатые сапоги", 164, "Клинок ледяного тигра", 164, "Кромка Зимы", 164, "Крутящиеся стальные топоры", 164, "Палаш лунной стали", 164, "Полированные стальные сапоги", 164, "Пылающий золотой клинок", 164, "Серповидная секира тени", 164, "Стальная кираса", 164, "Стальная цепь для оружия", 164, "Стальной латный шлем", 202, "Шлицевой гироинструмент" },
	[3860] = { 164, "Большая черная палица", 164, "Гибельный мифриловый клинок", 164, "Гниль", 164, "Закаленные ветрами поножи", 164, "Защитник из истинного серебра", 164, "Изысканная мифриловая кираса", 164, "Изысканные мифриловые перчатки", 164, "Изысканные мифриловые сапоги", 164, "Изысканные мифриловые штаны", 164, "Изысканный мифриловый наплечник", 164, "Изысканный мифриловый шлем", 164, "Инкрустированный мифриловый цилиндр", 164, "Кираса из истинного серебра", 164, "Легкий клинок земной кузни", 164, "Легкий топор небесной кузни", 164, "Легкий углекованный молот", 164, "Ломатель", 164, "Мифриловые чешуйчатые наплечники", 164, "Мифриловые чешуйчатые наручи", 164, "Мифриловые чешуйчатые перчатки", 164, "Мифриловые чешуйчатые штаны", 164, "Мифриловые шпоры", 164, "Мифриловый капюшон", 164, "Мифриловый шип для щита", 164, "Орочьи боевые поножи", 164, "Ослепительная мифриловая рапира", 164, "Поножи земной кузни", 164, "Рукавицы из истинного серебра", 164, "Рунический мифриловый молот", 164, "Синий блистающий топор", 164, "Тяжелая мифриловая кираса", 164, "Тяжелые мифриловые латные рукавицы", 164, "Тяжелые мифриловые сапоги", 164, "Тяжелые мифриловые штаны", 164, "Тяжелый мифриловый наплечник", 164, "Тяжелый мифриловый топор", 164, "Тяжелый мифриловый шлем", 164, "Фантомный клинок", 164, "Эбеновый нож", 171, "Трансмутация мифрила в истинное серебро", 202, "Автоматический ремонтный набор", 202, "Боевой цыпленок гномов", 202, "Бронебойная мифриловая амуниция", 202, "Гномская шапка контроля над разумом", 202, "Гномский сетестрел", 202, "Гоблинская 'коробка с сюрпризом'", 202, "Гоблинская мортира", 202, "Гоблинский реактивный шлем", 202, "Гоблинское драконье ружье", 202, "Гоблинское радио", 202, "Крошечная ходячая бомба", 202, "Крошка Дымок", 202, "Любительское радио гномов", 202, "Мифриловая гиро-амуниция", 202, "Мифриловая крупнокалиберная винтовка", 202, "Мифриловая обшивка", 202, "Мифриловая труба", 202, "Мифриловый механический дракончик", 202, "Мифриловый мушкетон", 202, "Нестабильное пусковое устройство", 202, "Орудие: перезаряжено", 202, "Передвижная сирена", 202, "Пояс гномов, хранящий от вреда", 202, "Пространственный проходчик - Круговзор", 202, "Пульт управления паровым танком", 202, "Сверхбезопасный транспортер: Прибамбасск", 202, "Создатель снега 9000", 202, "Уменьшающий луч гномов", 202, "Шахтерская гоблинская каска", 202, "Шлем гоблинской конструкции", 202, "Шлем ныряльщика", 755, "Мифриловая филигрань", 755, "Цитриновое кольцо быстрого исцеления" },
	[3864] = { 164, "Зеленый железный шлем", 164, "Ломатель", 164, "Полированные стальные сапоги", 164, "Рукавицы из истинного серебра", 164, "Серповидная секира тени", 164, "Стальной латный шлем", 164, "Тяжелый мифриловый топор", 165, "Украшенный самоцветами кожаный пояс", 197, "Звездный пояс", 202, "Маскировочный механизм гномов", 202, "Механический дракончик", 202, "Мифриловая крупнокалиберная винтовка", 202, "Монокль ремесленника", 202, "Огненные очки", 202, "Точный прицел", 202, "Увеличитель мира", 202, "Шахтерская гоблинская каска", 202, "Шлем гоблинской конструкции", 202, "Яркоглазые очки", 755, "Золотое кольцо власти", 755, "Кольцо командора из истинного серебра", 755, "Пылающее цитриновое кольцо", 755, "Статуэтка золотого зайца", 755, "Украшенное самоцветами кольцо", 755, "Цитриновая подвеска исцеления", 755, "Цитриновое кольцо быстрого исцеления" },
	[4096] = { 165, "Варварский пояс" },
	[4231] = { 165, "Жилет лунного сияния", 165, "Кираса из чешуи мурлока", 165, "Кожаный жилет жителя холмов", 165, "Мундир из чешуи черного дракончика", 165, "Плащ из искаженной чешуи", 165, "Тисненые кожаные штаны", 165, "Тонкие кожаные перчатки", 165, "Тонкий кожаный мундир", 165, "Укрепленный кожаный доспех", 165, "Штаны из тонкой кожи" },
	[4232] = { 165, "Обработанная средняя шкура" },
	[4233] = { 165, "Наплечники жителя холмов", 165, "Перчатки Флетчера", 165, "Темный кожаный пояс", 165, "Укрепленные кожаные перчатки" },
	[4234] = { 164, "Блистающий стальной кинжал", 164, "Закаленный железный короткий меч", 164, "Кромка Зимы", 164, "Крутящиеся стальные топоры", 164, "Массивный железный топор", 164, "Мифриловые чешуйчатые перчатки", 164, "Нефритовый змеиный клинок", 164, "Палаш лунной стали", 164, "Позолоченный железный разрушитель", 164, "Прочная железная кувалда", 164, "Пылающий золотой клинок", 164, "Стальная цепь для оружия", 164, "Тяжелый мифриловый наплечник", 164, "Тяжелый мифриловый топор", 165, "Броня из зеленого дракончика", 165, "Броня из толстой чешуи мурлока", 165, "Варварская портупея", 165, "Варварские наплечники", 165, "Варварские наручи", 165, "Варварские перчатки", 165, "Варварские поножи", 165, "Варварский пояс", 165, "Защитная броня стража", 165, "Зеленые кожаные наручи", 165, "Зеленый кожаный доспех", 165, "Зеленый кожаный пояс", 165, "Кожаные наручи стража", 165, "Ледяной кожаный плащ", 165, "Мглистые кожаные поножи", 165, "Мглистые наручи", 165, "Мглистые сапоги", 165, "Мглистый кожаный доспех", 165, "Мглистый пояс", 165, "Мяч из толстой кожи", 165, "Накладки из толстой кожи", 165, "Наручи из чешуи зеленого дракончика", 165, "Наручи из чешуи мурлока", 165, "Перчатки Великого Отца", 165, "Перчатки стража", 165, "Плащ жителя холмов", 165, "Плащ хранителя", 165, "Плотная кожа", 165, "Подсумок из толстой кожи", 165, "Портупея из шкуры ящера", 165, "Пояс из шкуры ящера", 165, "Пояс стража", 165, "Сапоги быстроты", 165, "Тяжелый колчан", 165, "Удобная кожаная шляпа", 165, "Штаны стража", 197, "Звездный пояс", 197, "Зеленая шелковая сума", 197, "Краги Тьмы", 197, "Лазурные шелковые перчатки", 197, "Маленькая шелковая сумка", 197, "Перчатки истинной веры", 197, "Шелковый пояс земли", 202, "Большая зеленая ракета", 202, "Большая красная ракета", 202, "Большая синяя ракета", 202, "Большой сефориевый заряд", 202, "Гномские очки", 202, "Гномские реактивные сапоги", 202, "Гоблинские реактивные сапоги", 202, "Голубая ракета", 202, "Зеленая ракета", 202, "Красная ракета", 202, "Монокль ремесленника", 202, "Огненные очки", 202, "Сборный компактный уборочный голем", 202, "Усовершенствованный манекен-мишень", 202, "Яркоглазые очки" },
	[4235] = { 165, "Обработанная тяжелая шкура" },
	[4236] = { 165, "Броня из толстой чешуи мурлока", 165, "Варварские наплечники", 165, "Варварские наручи", 165, "Варварский пояс", 165, "Защитная броня стража", 165, "Зеленые кожаные наручи", 165, "Зеленый кожаный пояс", 165, "Кожаные наручи стража", 165, "Наручи из чешуи мурлока", 165, "Перчатки стража", 165, "Пояс стража", 165, "Тенекожаные перчатки", 165, "Удобная кожаная шляпа", 165, "Украшенный самоцветами кожаный пояс" },
	[4243] = { 165, "Кожаный жилет жителя холмов" },
	[4246] = { 165, "Темный кожаный пояс" },
	[4255] = { 164, "Зеленый железный хауберк" },
	[4289] = { 165, "Обработанная легкая шкура", 165, "Обработанная средняя шкура", 165, "Обработанная тяжелая шкура" },
	[4291] = { 165, "Варварский пояс", 165, "Жесткая кираса из чешуи скорпида", 165, "Жесткие наручи из чешуи скорпида", 165, "Жесткие перчатки из чешуи скорпида", 165, "Жесткие сапоги из чешуи скорпида", 165, "Кожаные наручи стража", 165, "Колчан быстрой тетивы", 165, "Мглистые наручи", 165, "Мглистые сапоги", 165, "Накладки из плотной кожи", 165, "Наручи из чешуи зеленого дракончика", 165, "Наручи из чешуи мурлока", 165, "Ночная головная повязка", 165, "Ночной мундир", 165, "Ночной плащ", 165, "Ночные наплечники", 165, "Ночные штаны", 165, "Перчатки Великого Отца", 165, "Перчатки стража", 165, "Плащ хранителя", 165, "Подсумок из плотной кожи", 165, "Сапоги быстроты", 165, "Удобная кожаная шляпа", 197, "Багровое шелковое одеяние", 197, "Багровые шелковые кюлоты", 197, "Багровые шелковые наплечники", 197, "Багровые шелковые перчатки", 197, "Багровый шелковый плащ", 197, "Багровый шелковый пояс", 197, "Белая рубашка сорвиголовы", 197, "Длинный шелковый плащ", 197, "Звездный пояс", 197, "Зеленая выходная рубашка", 197, "Зеленая шелковая броня", 197, "Зеленые шелковые наплечники", 197, "Красная рубашка сорвиголовы", 197, "Лазурные наплечники", 197, "Ледяной плащ", 197, "Одеяние могущества", 197, "Роскошная лиловая шелковая рубашка", 197, "Сапоги заклинателя", 197, "Сумка из магической ткани", 197, "Теневой капюшон", 197, "Черная рубашка сорвиголовы", 197, "Черные поножи из магической ткани", 197, "Черный жилет из магической ткани", 197, "Шелковый пояс земли" },
	[4304] = { 164, "Большая черная палица", 164, "Гибельный мифриловый клинок", 164, "Гниль", 164, "Защитник из истинного серебра", 164, "Изысканные мифриловые сапоги", 164, "Изысканный мифриловый наплечник", 164, "Ломатель", 164, "Мифриловые чешуйчатые наплечники", 164, "Рунический мифриловый молот", 164, "Синий блистающий топор", 164, "Тяжелые мифриловые сапоги", 164, "Фантомный клинок", 164, "Эбеновый нож", 165, "Большая вудуистская маска", 165, "Большие вудуистские штаны", 165, "Большое вудуистское одеяние", 165, "Большой вудуистский плащ", 165, "Волкоголовый шлем", 165, "Грубая кожа", 165, "Дикарские кожаные наплечники", 165, "Дикарские кожаные поножи", 165, "Дикарские кожаные сапоги", 165, "Дикарский кожаный жилет", 165, "Дикарский кожаный плащ", 165, "Дикарский кожаный шлем", 165, "Жесткая кираса из чешуи скорпида", 165, "Жесткие наплечники из чешуи скорпида", 165, "Жесткие наручи из чешуи скорпида", 165, "Жесткие перчатки из чешуи скорпида", 165, "Жесткие поножи из чешуи скорпида", 165, "Жесткие сапоги из чешуи скорпида", 165, "Жесткий шлем из чешуи скорпида", 165, "Кираса из черепашьего панциря", 165, "Кираса из чешуи дракона", 165, "Колчан быстрой тетивы", 165, "Накладки из плотной кожи", 165, "Наручи из черепашьего панциря", 165, "Ночная головная повязка", 165, "Ночной мундир", 165, "Ночной плащ", 165, "Ночные наплечники", 165, "Ночные сапоги", 165, "Ночные штаны", 165, "Оперенная перьями кираса", 165, "Перчатки из черепашьего панциря", 165, "Подсумок из плотной кожи", 165, "Поножи из черепашьего панциря", 165, "Рукавицы Моря", 165, "Рукавицы из чешуи дракона", 165, "Тенекожаные перчатки", 165, "Шлем из черепашьего панциря", 165, "Шлем огня", 197, "Багровые шелковые перчатки", 197, "Парадные ботинки", 197, "Сапоги из штормовой ткани", 197, "Тенетканые сапоги", 197, "Черные сапоги из магической ткани", 202, "Зеленая линза", 202, "Очки волшебного могущества-Экстрим", 202, "Розовые очки", 202, "Связка зеленых фейерверков", 202, "Связка красных фейерверков", 202, "Связка синих фейерверков", 202, "Смертоносный прицел", 202, "Ультра-очки 'Кошачий глаз'" },
	[4305] = { 165, "Мглистый пояс", 165, "Плащ хранителя", 165, "Штаны стража", 197, "Багровое шелковое одеяние", 197, "Багровые шелковые кюлоты", 197, "Багровые шелковые наплечники", 197, "Багровые шелковые перчатки", 197, "Багровый шелковый жилет", 197, "Багровый шелковый плащ", 197, "Багровый шелковый пояс", 197, "Белая рубашка сорвиголовы", 197, "Длинный шелковый плащ", 197, "Жилет Земли", 197, "Зеленая выходная рубашка", 197, "Зеленая шелковая броня", 197, "Зеленая шелковая сума", 197, "Зеленые шелковые наплечники", 197, "Клобук волшебника", 197, "Краги Тьмы", 197, "Красная рубашка сорвиголовы", 197, "Лазурные наплечники", 197, "Лазурные шелковые перчатки", 197, "Лазурные шелковые штаны", 197, "Лазурный шелковый жилет", 197, "Лазурный шелковый капюшон", 197, "Лазурный шелковый плащ", 197, "Лазурный шелковый пояс", 197, "Маленькая шелковая сумка", 197, "Одеяния Тайны", 197, "Паучий пояс", 197, "Пелерина из паучьего шелка", 197, "Перчатки истинной веры", 197, "Простое одеяние волшебника", 197, "Роскошная лиловая шелковая рубашка", 197, "Сапоги Тьмы", 197, "Сапоги заклинателя", 197, "Сапоги из паучьего шелка", 197, "Темная шелковая рубашка", 197, "Теневой капюшон", 197, "Туфли из паутины", 197, "Церемониальная белая рубашка", 197, "Черная рубашка сорвиголовы", 197, "Черная шелковая сума", 197, "Шелковая головная повязка", 197, "Шелковый пояс земли", 197, "Ярко-желтая рубашка" },
	[4306] = { 129, "Плотные шелковые бинты", 129, "Шелковые бинты", 164, "Твердое грузило", 197, "Рулон шелка", 202, "Анти-перенаправляющий луч", 202, "Гоблинский кабельный дефибриллятор", 202, "Железная граната", 202, "Световая бомба", 202, "Твердый динамит" },
	[4337] = { 165, "Сапоги быстроты", 197, "Клобук волшебника", 197, "Ледяной плащ", 197, "Паучий пояс", 197, "Сапоги заклинателя", 202, "Гномский сетестрел" },
	[4338] = { 129, "Бинты из магической ткани", 129, "Плотные бинты из магической ткани", 164, "Изысканные мифриловые перчатки", 164, "Мифриловые чешуйчатые перчатки", 164, "Мифриловый капюшон", 164, "Ослепительная мифриловая рапира", 164, "Тяжелые мифриловые латные рукавицы", 165, "Ночные наплечники", 197, "Рулон магической ткани", 202, "Автоматический ремонтный набор", 202, "Гномская шапка контроля над разумом", 202, "Гоблинская мина", 202, "Динамит 'Pro-100-брос II'", 202, "Нестабильное пусковое устройство" },
	[4339] = { 197, "Адмиральская шляпа", 197, "Белая бандитская маска", 197, "Белое свадебное платье", 197, "Брюки под смокинг", 197, "Венец из ткани Грез", 197, "Головная повязка из штормовой ткани", 197, "Жилет из ткани Грез", 197, "Жилет из штормовой ткани", 197, "Зачарованный мешочек из магической ткани", 197, "Звездный пояс", 197, "Красная головная повязка из магической ткани", 197, "Красная сумка из магической ткани", 197, "Красные наплечники из магической ткани", 197, "Красные перчатки из магической ткани", 197, "Красные штаны из магической ткани", 197, "Красный жилет из магической ткани", 197, "Куртка Халискана", 197, "Куртка-смокинг", 197, "Кюлоты Халискана", 197, "Ледяной плащ", 197, "Лиловая рубашка из магической ткани", 197, "Наплечники из штормовой ткани", 197, "Одеяние из пепельной ткани", 197, "Одеяние могущества", 197, "Оранжевая воинская рубашка", 197, "Оранжевая рубашка из магической ткани", 197, "Парадные ботинки", 197, "Перчатки из ткани Грез", 197, "Перчатки из штормовой ткани", 197, "Простое черное платье", 197, "Розовая рубашка из магической ткани", 197, "Рубашка под смокинг", 197, "Сапоги из пепельной ткани", 197, "Сапоги из штормовой ткани", 197, "Сумка из магической ткани", 197, "Тенетканая маска", 197, "Тенетканое одеяние", 197, "Тенетканые наплечники", 197, "Тенетканые перчатки", 197, "Тенетканые сапоги", 197, "Тенетканые штаны", 197, "Черная повязка из магической ткани", 197, "Черное одеяние из магической ткани", 197, "Черные наплечники из магической ткани", 197, "Черные перчатки из магической ткани", 197, "Черные поножи из магической ткани", 197, "Черные сапоги из магической ткани", 197, "Черный жилет из магической ткани", 197, "Штаны из штормовой ткани", 202, "Плащ-парашют" },
	[4340] = { 165, "Темные кожаные наплечники", 165, "Темные кожаные перчатки", 165, "Темные кожаные сапоги", 165, "Темные кожаные штаны", 165, "Темный кожаный мундир", 165, "Темный кожаный плащ", 165, "Темный кожаный пояс", 197, "Серая шерстяная рубашка", 197, "Серое шерстяное одеяние", 197, "Стильная зеленая рубашка", 197, "Стильная синяя рубашка", 197, "Темная шелковая рубашка" },
	[4341] = { 197, "Великолепный ковер-самолет", 197, "Грубая рубашка рабочего", 197, "Желтая рубашка дровосека", 197, "Ярко-желтая рубашка" },
	[4342] = { 165, "Вычурная лиловая шляпа", 171, "Призрачная краска", 197, "Лиловая рубашка из магической ткани", 197, "Роскошная лиловая шелковая рубашка", 202, "Лиловая дымовая сигнальная ракета" },
	[4357] = { 202, "Грубая медная бомба", 202, "Грубый динамит", 202, "Искусно изготовленная амуниция" },
	[4359] = { 202, "Грубая медная бомба", 202, "Грубый огнестрел", 202, "Коробка с механической белкой", 202, "Кустарный прицел", 202, "Любовно выделанный огнестрел", 202, "Манекен-мишень", 202, "Медный регулятор", 202, "Смертоносный мушкетон", 202, "Учебный замок" },
	[4361] = { 202, "Грубый огнестрел", 202, "Кустарный прицел", 202, "Смертоносный мушкетон" },
	[4363] = { 202, "Коробка с механической белкой", 202, "Малый сефориевый заряд", 202, "Манекен-мишень", 202, "Украшенная подзорная труба" },
	[4364] = { 202, "Аквадинамический магнит для рыбы", 202, "Большая медная бомба", 202, "Динамит 'Pro-100-брос'", 202, "Маленькая зеленая ракета", 202, "Маленькая красная ракета", 202, "Маленькая синяя ракета", 202, "Малый сефориевый заряд", 202, "Небольшая бронзовая бомба", 202, "Низкосортный динамит", 202, "Тяжелая искусно изготовленная амуниция" },
	[4368] = { 202, "Зеленые тонированные очки" },
	[4371] = { 202, "Анти-перенаправляющий луч", 202, "Лунная винтовка", 202, "Любовно выделанный огнестрел", 202, "Малый атомарный перенаправлятор", 202, "Обычный прицел", 202, "Переносной бронзовый миномет", 202, "Посеребренный дробовик", 202, "Точный прицел", 202, "Украшенная подзорная труба" },
	[4375] = { 202, "Анти-перенаправляющий луч", 202, "Взрывоопасная овца", 202, "Гоблинский кабельный дефибриллятор", 202, "Ледяной отражатель", 202, "Лунная винтовка", 202, "Малый атомарный перенаправлятор", 202, "Отражатель пламени", 202, "Посеребренный дробовик", 202, "Украшенная подзорная труба", 202, "Универсальный гномский дистанционный пульт" },
	[4377] = { 202, "Большая бронзовая бомба", 202, "Большая железная бомба", 202, "Большая зеленая ракета", 202, "Большая красная ракета", 202, "Большая синяя ракета", 202, "Взрывоопасная овца", 202, "Гоблинская наземная мина", 202, "Голубая ракета", 202, "Железная граната", 202, "Зеленая ракета", 202, "Красная ракета", 202, "Переносной бронзовый миномет", 202, "Световая бомба", 202, "Твердая искусно изготовленная амуниция", 202, "Тяжелый динамит" },
	[4382] = { 202, "Взрывоопасная овца", 202, "Механический дракончик", 202, "Сборный компактный уборочный голем", 202, "Усовершенствованный манекен-мишень" },
	[4385] = { 202, "Огненные очки" },
	[4387] = { 202, "Механический дракончик", 202, "Переносной бронзовый миномет", 202, "Сборный компактный уборочный голем", 202, "Усовершенствованный манекен-мишень" },
	[4389] = { 202, "Гномские реактивные сапоги", 202, "Гоблинская наземная мина", 202, "Гоблинское радио", 202, "Крошка Дымок", 202, "Любительское радио гномов", 202, "Маскировочный механизм гномов", 202, "Механический дракончик", 202, "Сборный компактный уборочный голем", 202, "Создатель снега 9000", 202, "Усовершенствованный манекен-мишень" },
	[4394] = { 202, "Крошечная ходячая бомба" },
	[4399] = { 202, "Грубый огнестрел", 202, "Смертоносный мушкетон" },
	[4400] = { 202, "Лунная винтовка", 202, "Любовно выделанный огнестрел", 202, "Мифриловая крупнокалиберная винтовка", 202, "Мифриловый мушкетон", 202, "Мушкет из оскверненного железа", 202, "Посеребренный дробовик" },
	[4402] = { 171, "Зелье защиты от огня", 185, "Мясо в соусе 'Дыхание дракона'", 202, "Отражатель пламени" },
	[4404] = { 202, "Большая бронзовая бомба", 202, "Большая железная бомба", 202, "Большая медная бомба", 202, "Небольшая бронзовая бомба" },
	[4407] = { 202, "Гоблинский бомбомет" },
	[4461] = { 165, "Варварские наручи", 165, "Портупея из шкуры ящера", 165, "Пояс из шкуры ящера" },
	[4470] = { 202, "Станок адамантитовой амуниции", 202, "Станок для адамантитовых патронов", 333, "Большой магический жезл", 333, "Малый магический жезл" },
	[4589] = { 197, "Адмиральская шляпа" },
	[4603] = { 185, "Пятнистый желтохвост" },
	[4611] = { 202, "Световая бомба" },
	[4625] = { 171, "Воспламеняющая смесь", 171, "Гоблинское ракетное топливо", 171, "Сильный эликсир огневой мощи", 171, "Философский камень", 197, "Праздничное платье", 197, "Праздничный красный костюм", 333, "Волшебное масло", 333, "Сверкающее волшебное масло" },
	[4655] = { 185, "Гигантский жареный моллюск" },
	[5051] = { 185, "Похлебка из пещерной крысы" },
	[5082] = { 165, "Сумка из шкуры кодо" },
	[5373] = { 165, "Перчатки жулика", 165, "Темные кожаные перчатки" },
	[5465] = { 185, "Калдорайский шашлык из паука" },
	[5466] = { 185, "Десерт из скорпида" },
	[5467] = { 185, "Жареное мясо кодо" },
	[5468] = { 185, "Филе бешенки" },
	[5469] = { 185, "Похлебка из долгонога" },
	[5470] = { 185, "Хрустящий хвост ящерицы" },
	[5471] = { 185, "Постная оленина" },
	[5498] = { 164, "Зеленые железные рукавицы", 164, "Кинжал с жемчужной рукояткой", 165, "Варварские наручи", 165, "Жилет лунного сияния", 197, "Плащ с перламутровыми застежками", 197, "Тяжелый шерстяной плащ", 755, "Корона лунной души", 755, "Простое жемчужное кольцо" },
	[5500] = { 164, "Радужный молот", 164, "Сияющая серебряная кираса", 165, "Украшенный самоцветами кожаный пояс", 197, "Перчатки Феникса", 197, "Сапоги из паучьего шелка", 197, "Штаны Феникса", 333, "Рунический золотой жезл" },
	[5503] = { 185, "Отварные мидии", 185, "Похлебка из моллюсков" },
	[5504] = { 185, "Мидии по-гоблински" },
	[5633] = { 165, "Варварский пояс" },
	[5635] = { 164, "Варварские железные наплечники", 164, "Варварский железный шлем", 171, "Зелье ярости" },
	[5637] = { 164, "Варварские железные перчатки", 164, "Варварские железные сапоги", 164, "Варварский железный шлем", 165, "Варварские наручи", 165, "Варварские перчатки", 171, "Сильнодействующее зелье ярости", 333, "Чары для оружия - зверобой II", 755, "Варварский железный ошейник" },
	[5784] = { 165, "Кираса из чешуи мурлока", 165, "Пояс из чешуи мурлока" },
	[5785] = { 165, "Броня из толстой чешуи мурлока", 165, "Наручи из чешуи мурлока" },
	[5956] = { 202, "Гномский армейский нож" },
	[5966] = { 164, "Рукавицы из истинного серебра" },
	[6037] = { 164, "Гибельный мифриловый клинок", 164, "Гниль", 164, "Жезл из истинного серебра", 164, "Защитник из истинного серебра", 164, "Изысканная мифриловая кираса", 164, "Изысканные мифриловые перчатки", 164, "Изысканные мифриловые сапоги", 164, "Изысканные мифриловые штаны", 164, "Изысканный мифриловый наплечник", 164, "Изысканный мифриловый шлем", 164, "Инкрустированный мифриловый цилиндр", 164, "Инкрустированный ториевый молот", 164, "Кираса из истинного серебра", 164, "Ломатель", 164, "Мифриловый шип для щита", 164, "Отмычка из истинного серебра", 164, "Перчатки рассвета", 164, "Ремень рассвета", 164, "Рукавицы из истинного серебра", 164, "Рунический латный шлем", 164, "Темноруническая кираса", 164, "Темнорунические рукавицы", 164, "Темнорунический шлем", 164, "Фантомный клинок", 164, "Шлем чистой души", 164, "Эбеновый нож", 197, "Венец из ткани Грез", 202, "Боевой цыпленок гномов", 202, "Гномская шапка контроля над разумом", 202, "Гоблинский бомбомет", 202, "Гоблинское драконье ружье", 202, "Крошка Дымок", 202, "Манекен-мишень искусной работы", 202, "Мифриловый механический дракончик", 202, "Мощный фонарь", 202, "Пояс гномов, хранящий от вреда", 202, "Преобразователь истинного серебра", 202, "Снайперский прицел", 202, "Шлем ныряльщика", 333, "Чары для перчаток - горное дело II", 755, "Амулет проницательности", 755, "Кольцо командора из истинного серебра", 755, "Опаловое ожерелье столкновения", 755, "Рубиновая корона восстановления", 755, "Сапфировый перстень", 755, "Статуэтка вепря из истинного серебра", 755, "Статуэтка краба из истинного серебра", 755, "Статуэтка нефритовой совы", 755, "Статуэтка рубиновой змеи", 755, "Украшенное самоцветами кольцо", 755, "Целительное кольцо из истинного серебра", 755, "Чеканное кольцо из истинного серебра" },
	[6048] = { 197, "Краги Тьмы", 197, "Сапоги Тьмы", 333, "Чары для плаща - сопротивление темной магии I" },
	[6149] = { 755, "Рубиновая корона восстановления" },
	[6217] = { 333, "Рунический медный жезл" },
	[6218] = { 333, "Рунический серебряный жезл" },
	[6260] = { 197, "Лазурные наплечники", 197, "Лазурные шелковые перчатки", 197, "Лазурные шелковые штаны", 197, "Лазурный шелковый жилет", 197, "Лазурный шелковый капюшон", 197, "Лазурный шелковый плащ", 197, "Лазурный шелковый пояс", 197, "Мундир из ледяной ткани", 197, "Перчатки из ледяной ткани", 197, "Простое платье", 197, "Синее льняное одеяние", 197, "Синий комбинезон", 197, "Синий льняной жилет", 197, "Синяя льняная рубашка", 197, "Синяя рубашка дровосека", 197, "Синяя рубашка рабочего", 197, "Стильная синяя рубашка", 197, "Штаны из ледяной ткани", 202, "Синяя дымовая сигнальная ракета" },
	[6261] = { 197, "Оранжевая воинская рубашка", 197, "Оранжевая рубашка из магической ткани" },
	[6289] = { 185, "Острозубый илистый луциан" },
	[6291] = { 185, "Блестящая рыбка" },
	[6303] = { 185, "Скользкокожая скумбрия" },
	[6308] = { 185, "Ощетиненная зубатка" },
	[6317] = { 185, "Деликатес из бешенки" },
	[6338] = { 333, "Рунический серебряный жезл" },
	[6339] = { 333, "Рунический золотой жезл" },
	[6358] = { 171, "Масло черноротика" },
	[6359] = { 171, "Зажигательное масло" },
	[6361] = { 185, "Радужный тунец" },
	[6362] = { 185, "Каменношкурая треска" },
	[6370] = { 171, "Зелье быстрого плавания", 171, "Зелье свободы действий", 171, "Эликсир подводного дыхания", 333, "Чары для перчаток - рыбная ловля" },
	[6371] = { 171, "Зелье защиты от огня", 171, "Сильный эликсир огневой мощи", 171, "Слабый эликсир меткости", 171, "Эликсир огневой мощи", 197, "Багровые шелковые наплечники", 197, "Багровые шелковые перчатки", 197, "Багровый шелковый плащ", 333, "Чары для плаща - сопротивление огню II" },
	[6470] = { 165, "Перчатки из искаженной чешуи", 165, "Плащ из искаженной чешуи", 165, "Пояс из искаженной чешуи" },
	[6471] = { 165, "Пояс из искаженной чешуи" },
	[6522] = { 171, "Эликсир увеличения", 185, "Загадочное острое лакомство" },
	[6530] = { 202, "Аквадинамический магнит для рыбы" },
	[6889] = { 185, "Вкусный шоколадный торт", 185, "Гоголь-моголь", 185, "Имбирное печенье", 185, "Яйцо с травами" },
	[7005] = { 202, "Гномский армейский нож" },
	[7067] = { 164, "Блистающий стальной кинжал", 164, "Орочьи боевые поножи", 164, "Точило стихий", 165, "Кожаные наплечники земли", 165, "Ледяной кожаный плащ", 165, "Перчатки Великого Отца", 165, "Тяжелые перчатки Земли", 171, "Приводящее в сознание зелье", 171, "Сильное зелье защиты от сил природы", 197, "Жилет Земли", 197, "Одеяние могущества", 197, "Шелковый пояс земли", 202, "Преобразователь истинного серебра", 202, "Шахтерская гоблинская каска", 333, "Чары для оружия - малое убийство элементалей", 755, "Нефритовое око" },
	[7068] = { 164, "Пылающий золотой клинок", 171, "Сильное зелье защиты от огня", 197, "Багровое шелковое одеяние", 197, "Багровые шелковые перчатки", 197, "Одеяние могущества", 197, "Плащ огня", 202, "Гоблинская мортира", 202, "Мифриловый мушкетон", 202, "Огненные очки", 202, "Шлем гоблинской конструкции", 333, "Чары для плаща - сопротивление огню" },
	[7069] = { 164, "Кромка Зимы", 164, "Крутящиеся стальные топоры", 171, "Сильное зелье защиты от светлой магии", 197, "Одеяние могущества", 202, "Преобразователь истинного серебра" },
	[7070] = { 164, "Кромка Зимы", 165, "Ледяной кожаный плащ", 171, "Сильное зелье защиты от магии льда", 197, "Лазурный шелковый пояс", 197, "Одеяние могущества", 755, "Цитриновая подвеска исцеления" },
	[7071] = { 165, "Варварская портупея", 165, "Варварский пояс", 165, "Зеленый кожаный пояс", 165, "Мглистый пояс", 165, "Пояс стража", 197, "Багровый шелковый пояс", 197, "Звездный пояс", 197, "Лазурный шелковый пояс", 197, "Паучий пояс", 197, "Шелковый пояс земли" },
	[7072] = { 197, "Лазурные наплечники" },
	[7075] = { 164, "Легкий клинок земной кузни", 164, "Ломатель", 164, "Поножи земной кузни", 164, "Рунический мифриловый молот", 165, "Вулканические поножи", 202, "Крошка Дымок", 202, "Сверхбезопасный транспортер: Прибамбасск", 333, "Чары для плаща - сопротивление III", 755, "Статуэтка краба из истинного серебра" },
	[7076] = { 164, "Зачарованная ториевая кираса", 164, "Зачарованный ториевый шлем", 164, "Звездчатый обсидиановый щит", 164, "Молот бури искусной работы", 164, "Молот титанов", 164, "Поножи титанов", 164, "Рукавицы цитадели", 164, "Толстая обсидиановая кираса", 164, "Ториевый шип для щита", 164, "Тяжелые сапоги Древобрюхов", 164, "Тяжелый обсидиановый пояс", 164, "Тяжелый пояс Древобрюхов", 165, "Вулканическая кираса", 165, "Вулканические наплечники", 171, "Трансмутация: земля в воду", 171, "Трансмутация: земля в жизнь", 197, "Мудрость Древобрюхов", 197, "Одеяние верховного мага", 197, "Оплечье Древобрюхов", 202, "Отличная арканитовая винтовка", 202, "Прицел 'Бизникс' 247x128", 202, "Реактивный диск", 333, "Чары для оружия - сила", 755, "Кольцо нападения", 755, "Подвеска из арканитового меча" },
	[7077] = { 164, "Вулканический молот", 164, "Изысканная мифриловая кираса", 164, "Кольчуга из черного железа", 164, "Латы из черного железа", 164, "Легкий углекованный молот", 164, "Наплечники из черного железа", 164, "Пылающая рапира", 164, "Распылитель из черного железа", 164, "Рассекатель из черного железа", 164, "Светозарная кираса", 164, "Светозарные перчатки", 164, "Светозарные поножи", 164, "Светозарные сапоги", 164, "Светозарный венец", 164, "Светозарный пояс", 165, "Шлем огня", 171, "Трансмутация: первородный огонь", 197, "Жилет из пепельной ткани", 197, "Одеяние из пепельной ткани", 197, "Перчатки из пепельной ткани", 197, "Плащ огня", 202, "Крошечная ходячая бомба", 202, "Мифриловый механический дракончик", 202, "Пространственный проходчик - Круговзор", 333, "Чары для плаща - сопротивление III", 755, "Статуэтка вепря из истинного серебра" },
	[7078] = { 164, "Огненные латные рукавицы", 164, "Пылающая рапира", 164, "Сульфуронский молот", 165, "Вулканическая кираса", 165, "Вулканические наплечники", 165, "Вулканические поножи", 165, "Кираса духовного огня", 165, "Наручи духовного огня", 165, "Рукавицы духовного огня", 171, "Трансмутация: огонь в землю", 197, "Инфернальные перчатки", 197, "Напульсники пламенных недр", 197, "Одеяние Бездны", 197, "Одеяние верховного мага", 197, "Одеяние пламенных недр", 197, "Перчатки пламенных недр", 197, "Плащ из пепельной ткани", 197, "Плащ огня", 197, "Поножи пламенных недр", 197, "Пояс верховного мага", 197, "Сумка из сердцевинной ткани Скверны", 197, "Штаны из пепельной ткани", 202, "Гирозамораживающий ледяной отражатель", 202, "Кабельная система с плавкими предохранителями", 202, "Мощный фонарь", 202, "Отличная арканитовая винтовка", 333, "Дымящееся сердце горы", 333, "Чары для оружия - огненное оружие", 333, "Чары для перчаток - сила огня", 333, "Чары для плаща - сопротивление огню III", 755, "Кольцо природного огня", 755, "Статуэтка рубиновой змеи" },
	[7079] = { 165, "Рукавицы Моря", 197, "Головная повязка из штормовой ткани", 197, "Жилет из штормовой ткани", 197, "Наплечники из штормовой ткани", 197, "Одеяние из ледяной ткани", 197, "Перчатки из штормовой ткани", 197, "Сапоги из штормовой ткани", 197, "Штаны из штормовой ткани", 202, "Сверхбезопасный транспортер: Прибамбасск", 202, "Спокойный механический йети", 333, "Чары для плаща - сопротивление III", 755, "Статуэтка краба из истинного серебра" },
	[7080] = { 164, "Зачарованная ториевая кираса", 164, "Зачарованные ториевые поножи", 164, "Кираса ледяной погибели", 164, "Ледяной страж", 164, "Наплечники Вестника Рассвета", 164, "Наручи ледяной погибели", 164, "Рукавицы Бури", 164, "Рукавицы ледяной погибели", 165, "Кираса из ледяной чешуи", 165, "Мундир из кожи ледопарда", 165, "Наручи из ледяной чешуи", 165, "Перчатки из кожи ледопарда", 165, "Поножи из кожи ледопарда", 165, "Рассветные ботфорты", 165, "Рукавицы из ледяной чешуи", 165, "Сапоги из кожи ледопарда", 165, "Снежные наручи", 165, "Снежные перчатки", 165, "Снежный мундир", 171, "Трансмутация: вода в воздух", 171, "Трансмутация: вода в нежить", 197, "Ледовые накулачники", 197, "Ледовые перчатки", 197, "Ледовый жилет", 197, "Ледовый плащ", 197, "Одеяние верховного мага", 197, "Одеяние зимней ночи", 197, "Пояс верховного мага", 202, "Гипер-излучающий отражатель пламени", 333, "Чары для наручей - восполнение маны", 333, "Чары для оружия - леденящая стужа", 333, "Чары для оружия - целительная сила", 333, "Чары для перчаток - сила льда" },
	[7081] = { 164, "Закаленные ветрами поножи", 164, "Защитник из истинного серебра", 164, "Легкий топор небесной кузни", 164, "Фантомный клинок", 165, "Поножи Черной бури", 333, "Чары для плаща - сопротивление III", 755, "Статуэтка вепря из истинного серебра" },
	[7082] = { 165, "Доспех Грозового Покрова", 165, "Мангустовые сапоги", 165, "Наплечники Грозового Покрова", 165, "Перчатки Грозового Покрова", 165, "Штаны Грозового Покрова", 171, "Трансмутация: воздух в огонь", 197, "Одеяние верховного мага", 202, "Реактивный диск", 333, "Чары для двуручного оружия - ловкость I", 333, "Чары для оружия - леденящая стужа", 333, "Чары для оружия - ловкость I", 755, "Подвеска из арканитового меча" },
	[7191] = { 202, "Гномский тревого-бот", 202, "Гоблинский кабельный дефибриллятор", 202, "Гоблинский кабельный макси-дефибриллятор", 202, "Крошечная ходячая бомба", 202, "Крошка Дымок", 202, "Маскировочный механизм гномов", 202, "Полевой ремонтный робот 74A" },
	[7286] = { 165, "Мундир из чешуи черного дракончика", 165, "Плащ из чешуи черного дракончика" },
	[7287] = { 165, "Перчатки из чешуи красного дракончика" },
	[7387] = { 202, "Пояс гномов, хранящий от вреда" },
	[7392] = { 165, "Броня из зеленого дракончика", 165, "Наручи из чешуи зеленого дракончика", 333, "Чары для перчаток - снятие шкур" },
	[7909] = { 164, "Изысканные мифриловые сапоги", 164, "Ослепительная мифриловая рапира", 164, "Рукавицы из истинного серебра", 164, "Синий блистающий топор", 164, "Тяжелый мифриловый шлем", 164, "Фантомный клинок", 202, "Зеленая линза", 202, "Пояс гномов, хранящий от вреда", 202, "Сверхбезопасный транспортер: Прибамбасск", 202, "Смертоносный прицел", 202, "Ультра-очки 'Кошачий глаз'", 333, "Чары для обуви - скорость", 755, "Аквамариновая подвеска воина", 755, "Аквамариновый оберег", 755, "Аквамариновый перстень", 755, "Статуэтка краба из истинного серебра", 755, "Украшенное самоцветами кольцо" },
	[7910] = { 164, "Вулканический молот", 164, "Выкованная демоном кираса", 164, "Защитник из истинного серебра", 164, "Императорский латный шлем", 164, "Кираса из истинного серебра", 164, "Кираса кровавого духа", 164, "Кровавый коготь", 164, "Лезвие Рассвета", 164, "Наплечники кровавого духа", 164, "Огненные латные рукавицы", 164, "Пронзатель сердец", 164, "Руническая кираса", 164, "Рунические латные поножи", 164, "Светозарная кираса", 164, "Ториевый шлем", 164, "Эбеновый нож", 197, "Инфернальные перчатки", 197, "Тюрбан из чародейской ткани", 202, "Гипер-излучающий отражатель пламени", 202, "Гномская шапка контроля над разумом", 202, "Гоблинский кабельный макси-дефибриллятор", 202, "Мифриловый механический дракончик", 202, "Очки волшебного могущества Экстрим-Плюс", 202, "Очки волшебного могущества-Экстрим", 202, "Очки кровавой лозы", 202, "Пространственный проходчик - Круговзор", 202, "Розовые очки", 202, "Снайперский прицел", 755, "Кольцо командора из истинного серебра", 755, "Корона Крови", 755, "Красное кольцо разрушения", 755, "Рубиновая корона восстановления", 755, "Рубиновая подвеска огня", 755, "Статуэтка вепря из истинного серебра", 755, "Статуэтка рубиновой змеи", 755, "Статуэтка скорпида из черного железа" },
	[7911] = { 186, "Выплавка истинного серебра" },
	[7912] = { 164, "Твердое грузило", 164, "Твердое точило", 164, "Твердый шлифовальный камень", 202, "Твердое взрывчатое вещество", 755, "Твердая каменная статуя" },
	[7966] = { 164, "Большая черная палица", 164, "Гибельный мифриловый клинок", 164, "Гниль", 164, "Защитник из истинного серебра", 164, "Изысканная мифриловая кираса", 164, "Изысканные мифриловые перчатки", 164, "Изысканные мифриловые сапоги", 164, "Изысканные мифриловые штаны", 164, "Изысканный мифриловый шлем", 164, "Кираса из истинного серебра", 164, "Ломатель", 164, "Мифриловые шпоры", 164, "Мифриловый шип для щита", 164, "Ослепительная мифриловая рапира", 164, "Отмычка из истинного серебра", 164, "Рукавицы из истинного серебра", 164, "Рунический мифриловый молот", 164, "Синий блистающий топор", 164, "Стальной латный шлем", 164, "Тяжелый мифриловый топор", 164, "Фантомный клинок", 164, "Эбеновый нож" },
	[7971] = { 164, "Большая черная палица", 164, "Кираса из истинного серебра", 165, "Оперенная перьями кираса", 165, "Рунические кожаные наручи", 197, "Сапоги из луноткани", 333, "Рунический жезл истинного серебра", 755, "Рубиновая корона восстановления", 755, "Статуэтка пантеры из черного жемчуга" },
	[7972] = { 164, "Гниль", 171, "Сильный эликсир подводного дыхания", 197, "Сума душ", 202, "Смертоносный луч гномов", 333, "Чары для плаща - сопротивление III" },
	[7974] = { 185, "Невероятные мидии", 185, "Шахтерская похлебка из моллюсков" },
	[8150] = { 165, "Обработанная плотная шкура", 185, "Зажигательные химеровые отбивные Могиля", 202, "Петарда 'Змеиное жало'" },
	[8151] = { 165, "Большая вудуистская маска", 165, "Большое вудуистское одеяние", 202, "Гномские очки", 202, "Уменьшающий луч гномов", 755, "Аквамариновый перстень", 755, "Статуэтка вепря из истинного серебра", 755, "Статуэтка краба из истинного серебра", 755, "Статуэтка пантеры из черного жемчуга" },
	[8152] = { 165, "Большие вудуистские штаны", 165, "Большой вудуистский плащ", 755, "Статуэтка рубиновой змеи" },
	[8153] = { 164, "Доспех дикого терна", 164, "Мрачнолесская секира", 165, "Волкоголовый шлем", 165, "Дикарские кожаные наплечники", 165, "Дикарские кожаные поножи", 165, "Дикарские кожаные сапоги", 165, "Дикарский кожаный жилет", 165, "Дикарский кожаный плащ", 165, "Дикарский кожаный шлем", 165, "Поножи Буйного Пера", 171, "Зелье из дикой лозы", 197, "Венец из ткани Грез", 197, "Жилет из ткани Грез", 197, "Перчатки из ткани Грез", 202, "Зеленая линза", 333, "Чары для обуви - ловкость IV", 333, "Чары для перчаток - слабое ускорение" },
	[8154] = { 165, "Жесткая кираса из чешуи скорпида", 165, "Жесткие наплечники из чешуи скорпида", 165, "Жесткие наручи из чешуи скорпида", 165, "Жесткие перчатки из чешуи скорпида", 165, "Жесткие поножи из чешуи скорпида", 165, "Жесткие сапоги из чешуи скорпида", 165, "Жесткий шлем из чешуи скорпида" },
	[8165] = { 165, "Кираса из чешуи дракона", 165, "Поножи Драконоборца", 165, "Рукавицы из чешуи дракона" },
	[8167] = { 165, "Кираса из черепашьего панциря", 165, "Наручи из черепашьего панциря", 165, "Перчатки из черепашьего панциря", 165, "Поножи из черепашьего панциря", 165, "Шлем из черепашьего панциря" },
	[8169] = { 165, "Обработанная плотная шкура" },
	[8170] = { 164, "Вулканический молот", 164, "Зачарованные ториевые клинки", 164, "Зачарованный боевой молот", 164, "Изысканный ториевый одноручный топор", 164, "Императорские латные наплечники", 164, "Императорский латный пояс", 164, "Инкрустированный ториевый молот", 164, "Лезвие Рассвета", 164, "Мрачнолесская секира", 164, "Огромный ториевый боевой топор", 164, "Порча", 164, "Руническое лезвие", 164, "Ториевые сапоги", 164, "Ториевый большой меч", 165, "Броня огров Гордока", 165, "Вулканическая кираса", 165, "Вулканические наплечники", 165, "Вулканические поножи", 165, "Гибельная кожаная головная повязка", 165, "Гибельные кожаные наручи", 165, "Гибельные кожаные рукавицы", 165, "Гибельные кожаные штаны", 165, "Гибельный кожаный доспех", 165, "Гибельный кожаный пояс", 165, "Доспех Грозового Покрова", 165, "Ежевичный шлем", 165, "Железноперая кираса", 165, "Железноперые наплечники", 165, "Жилет из толстой чешуи скорпида", 165, "Зимние сапоги", 165, "Кираса Жизни", 165, "Кираса из чешуи Ониксии", 165, "Кираса из чешуи зеленого дракона", 165, "Кираса из чешуи красного дракона", 165, "Кираса из чешуи синего дракона", 165, "Кираса из чешуи черного дракона", 165, "Кираса чешуи сна", 165, "Короткие штаны боевого медведя", 165, "Мангустовые сапоги", 165, "Мощь Древобрюхов", 165, "Мундир из кожи ледопарда", 165, "Накладки из грубой кожи", 165, "Наплечники Грозового Покрова", 165, "Наплечники жизни", 165, "Наплечники из толстой чешуи скорпида", 165, "Наплечники из чешуи синего дракона", 165, "Наплечники из чешуи черного дракона", 165, "Наручи из толстой чешуи скорпида", 165, "Наручи стремительного полета", 165, "Перчатки из кожи ледопарда", 165, "Поножи Буйного Пера", 165, "Поножи Драконоборца", 165, "Поножи Черной бури", 165, "Поножи дьявозавра", 165, "Поножи жизни", 165, "Поножи из кожи ледопарда", 165, "Поножи из толстой чешуи скорпида", 165, "Поножи из чешуи зеленого дракона", 165, "Поножи из чешуи синего дракона", 165, "Поножи из чешуи черного дракона", 165, "Портупея боевого медведя", 165, "Пояс гончей Недр", 165, "Пояс из толстой чешуи скорпида", 165, "Разноцветный плащ", 165, "Рассветные ботфорты", 165, "Ремень Прозрения", 165, "Рукавицы дьявозавра", 165, "Рукавицы из толстой чешуи скорпида", 165, "Рукавицы из чешуи зеленого дракона", 165, "Руническая кожаная головная повязка", 165, "Рунические кожаные наплечники", 165, "Рунические кожаные наручи", 165, "Рунические кожаные рукавицы", 165, "Рунические кожаные штаны", 165, "Рунический кожаный доспех", 165, "Рунический кожаный пояс", 165, "Сапоги из кожи ледопарда", 165, "Сень Природы", 165, "Химерические перчатки", 165, "Химерические поножи", 165, "Химерические сапоги", 165, "Химерический жилет", 165, "Шлем из толстой чешуи скорпида", 165, "Штаны Грозового Покрова", 197, "Броня огров Гордока", 197, "Наплечники из рунической ткани", 197, "Наплечники из ткани Скверны", 197, "Сапоги из рунической ткани", 197, "Сапоги из ткани Скверны", 197, "Сума душ", 197, "Сумка из рунической ткани", 202, "Большая связка зеленых фейерверков", 202, "Большая связка красных фейерверков", 202, "Большая связка синих фейерверков", 202, "Винтовка из черного железа", 202, "Манекен-мишень искусной работы", 202, "Механическая жаба", 202, "Мощный сефориевый заряд", 333, "Зачарованная кожа" },
	[8171] = { 165, "Обработанная грубая шкура" },
	[8172] = { 165, "Волкоголовый шлем", 165, "Дикарские кожаные наплечники", 165, "Дикарские кожаные поножи", 165, "Дикарские кожаные сапоги", 165, "Дикарский кожаный жилет", 165, "Дикарский кожаный плащ", 165, "Дикарский кожаный шлем", 165, "Кираса из чешуи дракона", 165, "Колчан быстрой тетивы", 165, "Оперенная перьями кираса", 165, "Подсумок из плотной кожи", 165, "Поножи Буйного Пера", 165, "Поножи Драконоборца", 165, "Поножи Черной бури", 165, "Рукавицы Моря", 165, "Рукавицы из чешуи дракона", 165, "Шлем огня" },
	[8343] = { 165, "Большая вудуистская маска", 165, "Большие вудуистские штаны", 165, "Большое вудуистское одеяние", 165, "Большой вудуистский плащ", 165, "Волкоголовый шлем", 165, "Жесткие наплечники из чешуи скорпида", 165, "Жесткие поножи из чешуи скорпида", 165, "Жесткий шлем из чешуи скорпида", 165, "Кираса из черепашьего панциря", 165, "Кираса из чешуи дракона", 165, "Наручи из черепашьего панциря", 165, "Ночные сапоги", 165, "Оперенная перьями кираса", 165, "Перчатки из черепашьего панциря", 165, "Поножи из черепашьего панциря", 165, "Рукавицы Моря", 165, "Рукавицы из чешуи дракона", 165, "Тенекожаные перчатки", 165, "Шлем из черепашьего панциря", 165, "Шлем огня", 197, "Адмиральская шляпа", 197, "Белая бандитская маска", 197, "Белое свадебное платье", 197, "Брюки под смокинг", 197, "Венец из ткани Грез", 197, "Головная повязка из штормовой ткани", 197, "Жилет из ткани Грез", 197, "Жилет из штормовой ткани", 197, "Зачарованный мешочек из магической ткани", 197, "Ковер-самолет", 197, "Красная головная повязка из магической ткани", 197, "Красная сумка из магической ткани", 197, "Красные наплечники из магической ткани", 197, "Красные перчатки из магической ткани", 197, "Красные штаны из магической ткани", 197, "Красный жилет из магической ткани", 197, "Куртка Халискана", 197, "Куртка-смокинг", 197, "Кюлоты Халискана", 197, "Лиловая рубашка из магической ткани", 197, "Наплечники из штормовой ткани", 197, "Одеяние из пепельной ткани", 197, "Оранжевая воинская рубашка", 197, "Оранжевая рубашка из магической ткани", 197, "Перчатки из ткани Грез", 197, "Перчатки из штормовой ткани", 197, "Простое черное платье", 197, "Розовая рубашка из магической ткани", 197, "Рубашка под смокинг", 197, "Сапоги из пепельной ткани", 197, "Сапоги из штормовой ткани", 197, "Тенетканая маска", 197, "Тенетканое одеяние", 197, "Тенетканые наплечники", 197, "Тенетканые перчатки", 197, "Тенетканые сапоги", 197, "Тенетканые штаны", 197, "Черная повязка из магической ткани", 197, "Черное одеяние из магической ткани", 197, "Черные наплечники из магической ткани", 197, "Черные перчатки из магической ткани", 197, "Черные сапоги из магической ткани", 197, "Штаны из штормовой ткани" },
	[8365] = { 185, "Мифрилоголовая форель" },
	[8831] = { 171, "Зелье защиты от магии", 171, "Зелье из дикой лозы", 171, "Зелье спокойного сна", 171, "Сильный эликсир подводного дыхания", 171, "Философский камень", 171, "Эликсир снозрения", 197, "Кенарийская сумка для трав", 333, "Простое масло маны", 333, "Сверкающее масло маны" },
	[8836] = { 171, "'Дар Артаса'", 171, "Эликсир обнаружения нежити" },
	[8838] = { 171, "Большой флакон с зельем маны", 171, "Большой флакон с лечебным зельем", 171, "Зелье невидимости", 171, "Наилучший эликсир защиты", 171, "Сильный эликсир ловкости", 171, "Эликсир великанов", 333, "Чары для перчаток - травничество II" },
	[8839] = { 171, "'Дар Артаса'", 171, "Большой флакон с зельем маны", 171, "Сильный эликсир интеллекта", 171, "Слабое зелье неуязвимости", 171, "Чародейский эликсир" },
	[8845] = { 171, "Зелье невидимости", 171, "Призрачная краска", 171, "Слабое зелье неуязвимости", 171, "Эликсир истребления демонов", 171, "Эликсир энергии Тьмы" },
	[8846] = { 171, "Мощное зелье ярости", 171, "Мощный эликсир тролльей крови", 171, "Настой титанов", 171, "Эликсир великанов", 171, "Эликсир грубой силы", 171, "Эликсир истребления демонов", 171, "Эликсир обнаружения демонов" },
	[8925] = { 171, "'Дар Артаса'", 171, "Большой флакон с зельем маны", 171, "Большой флакон с лечебным зельем", 171, "Воспламеняющая смесь", 171, "Зелье безумного алхимика", 171, "Зелье защиты от магии", 171, "Зелье из дикой лозы", 171, "Зелье невидимости", 171, "Зелье неудержимости", 171, "Зелье оцепенения", 171, "Зелье очищения", 171, "Зелье спокойного сна", 171, "Мощное зелье ярости", 171, "Мощный эликсир тролльей крови", 171, "Наилучший эликсир защиты", 171, "Настой великой силы", 171, "Настой всецветного сопротивления", 171, "Настой титанов", 171, "Настой чистой мудрости", 171, "Огромный флакон с зельем маны", 171, "Огромный флакон с лечебным зельем", 171, "Приводящее в сознание зелье", 171, "Призрачная краска", 171, "Сильное зелье защиты от магии льда", 171, "Сильное зелье защиты от огня", 171, "Сильное зелье защиты от светлой магии", 171, "Сильное зелье защиты от сил природы", 171, "Сильное зелье защиты от тайной магии", 171, "Сильное зелье защиты от темной магии", 171, "Сильное зелье каменного щита", 171, "Сильное зелье спокойного сна", 171, "Сильный чародейский эликсир", 171, "Сильный эликсир интеллекта", 171, "Сильный эликсир ловкости", 171, "Сильный эликсир огневой мощи", 171, "Сильный эликсир подводного дыхания", 171, "Слабое зелье неуязвимости", 171, "Чародейский эликсир", 171, "Эликсир великанов", 171, "Эликсир грубой силы", 171, "Эликсир истребления демонов", 171, "Эликсир крови волшебника", 171, "Эликсир мангуста", 171, "Эликсир мудрецов", 171, "Эликсир обнаружения демонов", 171, "Эликсир обнаружения нежити", 171, "Эликсир снозрения", 171, "Эликсир энергии Тьмы", 333, "Волшебное масло", 333, "Простое масло маны" },
	[8949] = { 165, "Колчан быстрой тетивы" },
	[8951] = { 165, "Подсумок из плотной кожи" },
	[9060] = { 202, "Боевой цыпленок гномов", 202, "Пусковая установка для фейерверков", 202, "Сверхбезопасный транспортер: Прибамбасск", 202, "Смертоносный луч гномов" },
	[9061] = { 185, "Зажигательные химеровые отбивные Могиля", 202, "Великан", 202, "Гоблинские реактивные сапоги", 202, "Гоблинский реактивный шлем", 202, "Гоблинское драконье ружье", 202, "Пусковая установка для связок фейерверков", 202, "Пусковая установка для фейерверков" },
	[9149] = { 171, "Алхимический камень" },
	[9210] = { 197, "Жилет из призрачной ткани", 197, "Одежды истинной веры", 197, "Перчатки волшебства", 197, "Перчатки из призрачной ткани", 197, "Пояс верховного мага", 197, "Пояс из призрачной ткани", 197, "Штаны из призрачной ткани" },
	[9224] = { 333, "Чары для оружия - истребитель демонов" },
	[9260] = { 171, "Гоблинское ракетное топливо" },
	[9262] = { 171, "Философский камень" },
	[10026] = { 202, "Гномские реактивные сапоги", 202, "Гоблинские реактивные сапоги" },
	[10285] = { 165, "Мглистые сапоги", 165, "Тенекожаные перчатки", 197, "Тенетканая маска", 197, "Тенетканое одеяние", 197, "Тенетканые наплечники", 197, "Тенетканые перчатки", 197, "Тенетканые сапоги", 197, "Тенетканые штаны", 202, "Гномский сетестрел", 202, "Плащ-парашют" },
	[10286] = { 171, "Большое зелье омоложения", 171, "Зелье неудержимости", 197, "Венец из ткани Грез", 197, "Жилет из ткани Грез", 197, "Перчатки из ткани Грез", 202, "Зеленая линза", 755, "Целительное кольцо из истинного серебра" },
	[10290] = { 197, "Розовая рубашка из магической ткани" },
	[10500] = { 202, "Гномские очки", 202, "Очки старшего инженера" },
	[10502] = { 202, "Очки волшебного могущества Экстрим-Плюс" },
	[10505] = { 202, "Автоматический ремонтный набор", 202, "Большой сефориевый заряд", 202, "Бронебойная мифриловая амуниция", 202, "Гномские реактивные сапоги", 202, "Гномский сетестрел", 202, "Гоблинская 'коробка с сюрпризом'", 202, "Гоблинская мина", 202, "Гоблинская мортира", 202, "Гоблинский бомбомет", 202, "Динамит 'Pro-100-брос II'", 202, "Мифриловая гиро-амуниция", 202, "Мифриловая осколочная бомба", 202, "Нестабильное пусковое устройство", 202, "Орудие: перезаряжено", 202, "Плащ-парашют", 202, "Связка зеленых фейерверков", 202, "Связка красных фейерверков", 202, "Связка синих фейерверков", 202, "Твердый динамит", 202, "Фугасная бомба" },
	[10507] = { 202, "Великан" },
	[10543] = { 202, "Гоблинский реактивный шлем" },
	[10546] = { 202, "Винтовка из черного железа", 202, "Ториевая винтовка" },
	[10558] = { 202, "Боевой цыпленок гномов", 202, "Гирохронатом", 202, "Гномская шапка контроля над разумом", 202, "Гномские очки", 202, "Гномский пульт управления танком", 202, "Гоблинская 'коробка с сюрпризом'", 202, "Гоблинская мортира", 202, "Гоблинский пульт управления танком", 202, "Механическая жаба", 202, "Модулирующий усилитель голоса", 202, "Пульт управления паровым танком", 202, "Робот 'Бей-Молоти'", 202, "Солонка", 202, "Спокойный механический йети", 202, "Твареувеличитель", 202, "Увеличитель мира" },
	[10559] = { 202, "Гномские очки", 202, "Гномские реактивные сапоги", 202, "Гномский сетестрел", 202, "Гоблинская мортира", 202, "Гоблинские реактивные сапоги", 202, "Гоблинское драконье ружье", 202, "Мифриловая крупнокалиберная винтовка", 202, "Мифриловый мушкетон", 202, "Передвижная сирена", 202, "Смертоносный луч гномов", 202, "Смертоносный прицел", 202, "Снайперский прицел", 202, "Ториевая винтовка", 202, "Уменьшающий луч гномов" },
	[10560] = { 202, "Великан", 202, "Гоблинская мина", 202, "Гоблинские реактивные сапоги", 202, "Гоблинский бомбомет", 202, "Гоблинский реактивный шлем", 202, "Гоблинское драконье ружье", 202, "Гоблинское радио", 202, "Любительское радио гномов", 202, "Мифриловая крупнокалиберная винтовка", 202, "Мифриловая осколочная бомба", 202, "Мифриловый мушкетон", 202, "Передвижная сирена", 202, "Плащ-парашют", 202, "Пояс гномов, хранящий от вреда", 202, "Пусковая установка для фейерверков", 202, "Смертоносный луч гномов", 202, "Увеличитель мира", 202, "Уменьшающий луч гномов", 202, "Фугасная бомба" },
	[10561] = { 202, "Боевой цыпленок гномов", 202, "Великан", 202, "Гоблинская 'коробка с сюрпризом'", 202, "Гоблинский бомбомет", 202, "Гоблинское радио", 202, "Любительское радио гномов", 202, "Манекен-мишень искусной работы", 202, "Мифриловая осколочная бомба", 202, "Пусковая установка для связок фейерверков", 202, "Пусковая установка для фейерверков", 202, "Солонка", 202, "Ториевая винтовка", 202, "Увеличитель мира", 202, "Фугасная бомба", 202, "Шлем ныряльщика" },
	[10576] = { 202, "Арканитовый дракончик" },
	[10577] = { 202, "Орудие: перезаряжено" },
	[10586] = { 202, "Пространственный проходчик - Круговзор" },
	[10592] = { 202, "Ультра-очки 'Кошачий глаз'" },
	[10620] = { 171, "Сильное зелье каменного щита", 186, "Выплавка тория" },
	[10647] = { 202, "Гоблинское ракетное топливо - рецепт", 202, "Инкрустированный мифриловый цилиндр - чертеж" },
	[10648] = { 202, "Гоблинское ракетное топливо - рецепт", 202, "Инкрустированный мифриловый цилиндр - чертеж", 773, "Карта тайной магии", 773, "Материал для свитка брони II", 773, "Полная схема маршрутов эвакуации", 773, "Свиток возврата II", 773, "Свиток выносливости III", 773, "Свиток духа III", 773, "Свиток интеллекта III", 773, "Свиток ловкости III", 773, "Свиток силы III", 773, "Сертификат собственности", 773, "Символ Килрогга", 773, "Символ Света небес", 773, "Символ астрального возвращения", 773, "Символ бдительности", 773, "Символ безопасного падения", 773, "Символ беса", 773, "Символ божественности", 773, "Символ быстрого исцеления", 773, "Символ взрывной ловушки", 773, "Символ внутреннего огня", 773, "Символ возрождения", 773, "Символ вскипания лавы", 773, "Символ вызывающего рева", 773, "Символ гарроты", 773, "Символ глухой обороны", 773, "Символ демона Бездны", 773, "Символ залпа", 773, "Символ защиты от магии льда", 773, "Символ защиты от темной магии", 773, "Символ исчезновения", 773, "Символ канала здоровья", 773, "Символ кольца огня", 773, "Символ кровопускания", 773, "Символ левитации", 773, "Символ ледяного шока", 773, "Символ лечения", 773, "Символ ложной смерти", 773, "Символ лунного огня", 773, "Символ молнии", 773, "Символ мудрых", 773, "Символ обжигающей ловушки", 773, "Символ обновления", 773, "Символ обновленной жизни", 773, "Символ оружия языка пламени", 773, "Символ ослабления доспеха", 773, "Символ отвлечения", 773, "Символ очищения", 773, "Символ ошеломления", 773, "Символ парализующего удара", 773, "Символ подводного дыхания", 773, "Символ подрезанного сухожилия", 773, "Символ порабощения демона", 773, "Символ порыва", 773, "Символ потрошения", 773, "Символ праведной защиты", 773, "Символ правосудия", 773, "Символ превосходства", 773, "Символ прилива сил", 773, "Символ прицельного выстрела", 773, "Символ проклятия изнеможения", 773, "Символ пытки разума", 773, "Символ разрывания", 773, "Символ раскола брони", 773, "Символ реванша", 773, "Символ роя насекомых", 773, "Символ сдерживания", 773, "Символ скачка", 773, "Символ спасения", 773, "Символ стаи", 773, "Символ страха", 773, "Символ стрелы Тьмы", 773, "Символ стылой крови", 773, "Символ ухода в тень", 773, "Символ хождения по воде", 773, "Символ целительного прикосновения", 773, "Символ чародейских стрел", 773, "Символ шока небес", 773, "Странная карта", 773, "Фолиант выживания", 773, "Фолиант королей", 773, "Фолиант рассвета" },
	[10938] = { 333, "Малый магический жезл", 333, "Рунический медный жезл", 333, "Чары для нагрудника - здоровье II", 333, "Чары для нагрудника - мана I", 333, "Чары для нагрудника - мана II", 333, "Чары для нагрудника - поглощение I", 333, "Чары для наручей - дух I", 333, "Чары для наручей - отражение I", 333, "Чары для плаща - сопротивление I" },
	[10939] = { 333, "Большой магический жезл", 333, "Рунический серебряный жезл", 333, "Чары для двуручного оружия - интеллект I", 333, "Чары для нагрудника - мана II", 333, "Чары для наручей - ловкость I", 333, "Чары для оружия - зверобой I", 333, "Чары для оружия - удар I", 333, "Чары для плаща - броня I" },
	[10940] = { 333, "Рунический медный жезл", 333, "Рунический серебряный жезл", 333, "Слабое волшебное масло", 333, "Чары для двуручного оружия - дух I", 333, "Чары для двуручного оружия - импульс I", 333, "Чары для нагрудника - здоровье I", 333, "Чары для нагрудника - здоровье II", 333, "Чары для нагрудника - здоровье III", 333, "Чары для нагрудника - поглощение I", 333, "Чары для нагрудника - поглощение II", 333, "Чары для наручей - выносливость I", 333, "Чары для наручей - здоровье I", 333, "Чары для наручей - ловкость I", 333, "Чары для наручей - отражение I", 333, "Чары для наручей - сила I", 333, "Чары для обуви - выносливость I", 333, "Чары для обуви - ловкость I", 333, "Чары для оружия - зверобой I", 333, "Чары для оружия - удар I", 333, "Чары для плаща - броня I", 333, "Чары для плаща - броня II", 333, "Чары для плаща - сопротивление I", 333, "Чары для щита - броня I", 333, "Чары для щита - выносливость I", 333, "Чары для щита - дух I" },
	[10978] = { 333, "Чары для двуручного оружия - импульс I", 333, "Чары для оружия - удар I", 333, "Чары для плаща - броня II", 333, "Чары для щита - броня I" },
	[10998] = { 333, "Чары для двуручного оружия - дух I", 333, "Чары для нагрудника - здоровье III", 333, "Чары для нагрудника - мана III", 333, "Чары для наручей - дух II", 333, "Чары для обуви - ловкость I", 333, "Чары для плаща - ловкость I", 333, "Чары для плаща - сопротивление огню II", 333, "Чары для щита - броня I", 333, "Чары для щита - выносливость I", 333, "Чары для щита - дух I" },
	[11040] = { 197, "Кенарийская сумка для трав" },
	[11082] = { 333, "Рунический золотой жезл", 333, "Чары для нагрудника - все характеристики I", 333, "Чары для нагрудника - мана III", 333, "Чары для нагрудника - поглощение II", 333, "Чары для наручей - интеллект I", 333, "Чары для плаща - сопротивление темной магии I" },
	[11083] = { 333, "Малый мистический жезл", 333, "Рунический золотой жезл", 333, "Слабое масло маны", 333, "Чары для двуручного оружия - импульс II", 333, "Чары для нагрудника - все характеристики I", 333, "Чары для нагрудника - здоровье IV", 333, "Чары для наручей - выносливость II", 333, "Чары для наручей - выносливость III", 333, "Чары для наручей - отражение II", 333, "Чары для наручей - сила II", 333, "Чары для обуви - выносливость II", 333, "Чары для обуви - ловкость II", 333, "Чары для оружия - удар II", 333, "Чары для перчаток - горное дело I", 333, "Чары для перчаток - рыбная ловля", 333, "Чары для перчаток - травничество I", 333, "Чары для плаща - защита I", 333, "Чары для щита - выносливость II", 755, "Корона лунной души" },
	[11084] = { 333, "Чары для двуручного оружия - импульс II", 333, "Чары для нагрудника - все характеристики I", 333, "Чары для нагрудника - поглощение II", 333, "Чары для оружия - удар II" },
	[11128] = { 333, "Рунический золотой жезл" },
	[11130] = { 333, "Рунический жезл истинного серебра" },
	[11134] = { 333, "Малый мистический жезл", 333, "Чары для наручей - дух III", 333, "Чары для наручей - отражение II", 333, "Чары для обуви - дух I", 333, "Чары для обуви - ловкость II", 333, "Чары для оружия - зверобой II", 333, "Чары для оружия - малое убийство элементалей", 333, "Чары для плаща - сопротивление огню", 333, "Чары для щита - выносливость II" },
	[11135] = { 333, "Большой таинственный жезл", 333, "Рунический жезл истинного серебра", 333, "Чары для нагрудника - все характеристики II", 333, "Чары для нагрудника - мана IV", 333, "Чары для обуви - дух I", 333, "Чары для оружия - могущество зимы", 333, "Чары для оружия - удар III", 333, "Чары для щита - блок I", 333, "Чары для щита - дух II" },
	[11137] = { 197, "Зачарованный мешочек из магической ткани", 333, "Большой таинственный жезл", 333, "Простое волшебное масло", 333, "Рунический жезл истинного серебра", 333, "Чары для двуручного оружия - импульс III", 333, "Чары для нагрудника - все характеристики II", 333, "Чары для нагрудника - здоровье V", 333, "Чары для наручей - дух IV", 333, "Чары для наручей - сила III", 333, "Чары для обуви - выносливость III", 333, "Чары для обуви - меткость I", 333, "Чары для оружия - могущество зимы", 333, "Чары для перчаток - горное дело II", 333, "Чары для перчаток - ловкость I", 333, "Чары для перчаток - сила I", 333, "Чары для перчаток - снятие шкур", 333, "Чары для перчаток - травничество II", 333, "Чары для плаща - защита II", 333, "Чары для щита - блок I", 333, "Чары для щита - выносливость III", 333, "Чары для щита - дух II", 755, "Статуэтка нефритовой совы" },
	[11138] = { 333, "Чары для оружия - зверобой II", 333, "Чары для оружия - малое убийство элементалей", 333, "Чары для плаща - защита I" },
	[11139] = { 333, "Чары для двуручного оружия - импульс III", 333, "Чары для нагрудника - все характеристики II", 333, "Чары для оружия - могущество зимы", 333, "Чары для оружия - удар III", 333, "Чары для щита - блок I" },
	[11144] = { 333, "Рунический жезл истинного серебра" },
	[11145] = { 333, "Рунический арканитовый жезл" },
	[11174] = { 333, "Чары для нагрудника - мана V", 333, "Чары для наручей - дух IV", 333, "Чары для наручей - интеллект II", 333, "Чары для обуви - меткость I", 333, "Чары для обуви - скорость", 333, "Чары для перчаток - ловкость I", 333, "Чары для перчаток - сила I", 333, "Чары для плаща - ловкость II", 333, "Чары для плаща - сопротивление II" },
	[11175] = { 333, "Чары для нагрудника - все характеристики III", 333, "Чары для нагрудника - мана V", 333, "Чары для наручей - отражение III", 333, "Чары для наручей - сила IV", 333, "Чары для обуви - ловкость III", 333, "Чары для оружия - удар IV", 333, "Чары для щита - дух III" },
	[11176] = { 171, "Сильное зелье защиты от тайной магии", 186, "Зачарованный торий", 197, "Одеяние из чародейской ткани", 197, "Поножи из чародейской ткани", 197, "Тюрбан из чародейской ткани", 333, "Зачарованный торий", 333, "Простое масло маны", 333, "Чары для двуручного оружия - импульс IV", 333, "Чары для нагрудника - все характеристики III", 333, "Чары для наручей - выносливость IV", 333, "Чары для наручей - дух V", 333, "Чары для наручей - отражение III", 333, "Чары для наручей - сила IV", 333, "Чары для обуви - выносливость IV", 333, "Чары для оружия - истребитель демонов", 333, "Чары для перчаток - навык верховой езды", 333, "Чары для щита - выносливость IV", 333, "Чары для щита - дух III" },
	[11177] = { 333, "Чары для обуви - скорость", 333, "Чары для оружия - истребитель демонов", 333, "Чары для оружия - огненное оружие" },
	[11178] = { 333, "Чары для двуручного оружия - импульс IV", 333, "Чары для нагрудника - все характеристики III", 333, "Чары для оружия - удар IV", 333, "Чары для перчаток - навык верховой езды", 333, "Чары для перчаток - слабое ускорение", 333, "Чары для щита - сопротивление льду", 755, "Опаловое ожерелье столкновения" },
	[11291] = { 202, "Ветролет", 333, "Большой таинственный жезл", 333, "Малый мистический жезл" },
	[11370] = { 186, "Выплавка черного железа" },
	[11371] = { 164, "Кольчуга из черного железа", 164, "Латы из черного железа", 164, "Наплечники из черного железа", 164, "Наручи из черного железа", 164, "Пламенные плетеные наплечники", 164, "Пламенный плетеный ремень", 164, "Поножи из черного железа", 164, "Разоритель из черного железа", 164, "Разрушитель из черного железа", 164, "Распылитель из черного железа", 164, "Рассекатель из черного железа", 164, "Рукавицы из черного железа", 164, "Сапоги из черного железа", 164, "Сульфуронский молот", 164, "Сумерки", 164, "Увещеватель", 164, "Черное неистовство", 164, "Черное прощение", 164, "Черный Страж", 164, "Шлем из черного железа", 164, "Эбеновая рука", 202, "Бомба из черного железа", 202, "Винтовка из черного железа", 202, "Гипер-излучающий отражатель пламени", 202, "Прицел 'Бизникс' 247x128", 202, "Ультра-вспышечный отражатель тьмы", 755, "Статуэтка скорпида из черного железа" },
	[11382] = { 164, "Разоритель из черного железа", 164, "Разрушитель из черного железа", 164, "Рукавицы из черного железа", 164, "Сульфуронский молот", 164, "Черное прощение", 755, "Корона Крови" },
	[11754] = { 164, "Темнорунический шлем", 165, "Мангустовые сапоги", 755, "Радужный черный бриллиант", 755, "Статуэтка черного алмазного краба" },
	[12037] = { 185, "Десерт из мертвечины", 185, "Загадочная похлебка", 185, "Мясо в соусе 'Дыхание дракона'" },
	[12184] = { 185, "Жареный ящер" },
	[12202] = { 185, "Похлебка 'Джунгли'" },
	[12203] = { 185, "Острая волчья грудинка" },
	[12204] = { 185, "Сытная похлебка из кодо" },
	[12205] = { 185, "Паучья колбаска" },
	[12206] = { 185, "Острое крабовое чили" },
	[12207] = { 185, "Чудовищный омлет" },
	[12208] = { 185, "Нежный стейк из волчатины" },
	[12223] = { 185, "Хрустящее крылышко летучей мыши" },
	[12359] = { 164, "Аннигилятор", 164, "Вулканический молот", 164, "Выкованная демоном кираса", 164, "Доспех дикого терна", 164, "Зачарованные ториевые клинки", 164, "Зачарованный боевой молот", 164, "Изысканный ториевый одноручный топор", 164, "Императорские латные наплечники", 164, "Императорские латные наручи", 164, "Императорские латные поножи", 164, "Императорские латные сапоги", 164, "Императорский латный пояс", 164, "Императорский латный шлем", 164, "Имперское зерцало", 164, "Инкрустированный ториевый молот", 164, "Кираса кровавого духа", 164, "Кираса ледяной погибели", 164, "Кираса темного духа", 164, "Лезвие Рассвета", 164, "Молот титанов", 164, "Мрачнолесская секира", 164, "Наплечники Вестника Рассвета", 164, "Наплечники кровавого духа", 164, "Наплечники темного духа", 164, "Наручи ледяной погибели", 164, "Огненные латные рукавицы", 164, "Огромный ториевый боевой топор", 164, "Поножи темного духа", 164, "Порча", 164, "Ремень рассвета", 164, "Рукавицы Бури", 164, "Рукавицы кровавого духа", 164, "Рукавицы ледяной погибели", 164, "Руническая кираса", 164, "Рунические латные наплечники", 164, "Рунические латные поножи", 164, "Рунические латные сапоги", 164, "Рунический латный шлем", 164, "Руническое лезвие", 164, "Светозарная кираса", 164, "Светозарные перчатки", 164, "Светозарные поножи", 164, "Светозарные сапоги", 164, "Светозарный венец", 164, "Светозарный пояс", 164, "Темноруническая кираса", 164, "Темнорунические рукавицы", 164, "Темнорунический шлем", 164, "Ториевая броня", 164, "Ториевые наручи", 164, "Ториевые поножи", 164, "Ториевые сапоги", 164, "Ториевый большой меч", 164, "Ториевый пояс", 164, "Ториевый шип для щита", 164, "Ториевый шлем", 164, "Тяжелый пояс Древобрюхов", 164, "Шлем Львиного Сердца", 164, "Шлем великого вождя", 164, "Шлем чистой души", 171, "Трансмутация: арканит", 186, "Зачарованный торий", 202, "Амуниция с ториевым наконечником", 202, "Гномский тревого-бот", 202, "Полевой ремонтный робот 74A", 202, "Солонка", 202, "Ториевая винтовка", 202, "Ториевая граната", 202, "Ториевая труба", 202, "Ториевое устройство", 202, "Чародейская бомба", 333, "Зачарованный торий", 755, "Изумрудная корона разрушения", 755, "Корона Крови", 755, "Статуэтка изумрудной совы", 755, "Статуэтка черного алмазного краба", 755, "Ториевая оправа" },
	[12360] = { 164, "Аннигилятор", 164, "Арканитовая отмычка", 164, "Арканитовый жезл", 164, "Арканитовый жнец", 164, "Арканитовый защитник", 164, "Безмятежность", 164, "Зачарованная ториевая кираса", 164, "Зачарованные ториевые поножи", 164, "Зачарованный ториевый шлем", 164, "Кираса железной лозы", 164, "Кираса ледяной погибели", 164, "Клинок мудреца", 164, "Кровавый коготь", 164, "Ледяной страж", 164, "Молот титанов", 164, "Наплечники Вестника Рассвета", 164, "Наручи ледяной погибели", 164, "Неуязвимый доспех", 164, "Перчатки рассвета", 164, "Поножи титанов", 164, "Порча", 164, "Пронзатель сердец", 164, "Рукавицы ледяной погибели", 164, "Рукавицы цитадели", 164, "Руническая кираса", 164, "Рунические латные наплечники", 164, "Рунические латные поножи", 164, "Рунические латные сапоги", 164, "Рунический латный шлем", 164, "Сульфуронский молот", 164, "Сумерки", 164, "Тяжелые сапоги Древобрюхов", 164, "Увещеватель", 164, "Черное неистовство", 164, "Черное прощение", 164, "Черный Страж", 164, "Шлем Львиного Сердца", 164, "Эбеновая рука", 186, "Выплавка элементия", 197, "Плащ стражи", 202, "Отличная арканитовая винтовка", 202, "Реактивный диск", 202, "Сверхточный арканитовый преобразователь", 202, "Снайперская винтовка Недр", 755, "Изумрудная корона разрушения", 755, "Ожерелье Адамантовой башни", 755, "Подвеска из арканитового меча", 755, "Статуэтка изумрудной совы", 755, "Статуэтка скорпида из черного железа", 755, "Статуэтка черного алмазного краба" },
	[12361] = { 164, "Безмятежность", 164, "Выкованная демоном кираса", 164, "Зачарованные ториевые поножи", 164, "Инкрустированный ториевый молот", 164, "Ледяной страж", 164, "Лезвие Рассвета", 164, "Порча", 164, "Рукавицы Бури", 164, "Рукавицы цитадели", 164, "Ториевая броня", 164, "Шлем Львиного Сердца", 202, "Винтовка из черного железа", 202, "Гирозамораживающий ледяной отражатель", 755, "Изумрудная корона разрушения", 755, "Сапфировая подвеска зимней ночи", 755, "Сапфировый перстень" },
	[12363] = { 171, "Трансмутация: арканит", 333, "Чародейная пыль", 755, "Кольцо жестоких теней" },
	[12364] = { 164, "Аннигилятор", 164, "Безмятежность", 164, "Доспех дикого терна", 164, "Зачарованная ториевая кираса", 164, "Зачарованные ториевые поножи", 164, "Зачарованный боевой молот", 164, "Молот бури искусной работы", 164, "Наплечники Вестника Рассвета", 164, "Неуязвимый доспех", 164, "Рунический латный шлем", 164, "Сумерки", 164, "Толстая обсидиановая кираса", 164, "Черное копье", 164, "Шлем великого вождя", 197, "Перчатки волшебства", 202, "Очки старшего инженера", 755, "Изумрудная корона разрушения", 755, "Изумрудное кольцо льва", 755, "Подвеска из животворного изумруда", 755, "Статуэтка изумрудной совы" },
	[12365] = { 164, "Массивное грузило", 164, "Массивное точило", 164, "Массивный шлифовальный камень", 164, "Точило стихий", 202, "Концентрированное взрывчатое вещество", 755, "Статуя из массивного камня" },
	[12607] = { 165, "Разноцветный плащ" },
	[12644] = { 164, "Аннигилятор", 164, "Арканитовая отмычка", 164, "Арканитовый жезл", 164, "Арканитовый жнец", 164, "Арканитовый защитник", 164, "Изысканный ториевый одноручный топор", 164, "Кровавый коготь", 164, "Ледяной страж", 164, "Лезвие Рассвета", 164, "Мрачнолесская секира", 164, "Огромный ториевый боевой топор", 164, "Порча", 164, "Пронзатель сердец", 164, "Пылающая рапира", 164, "Руническое лезвие", 164, "Ториевый большой меч", 164, "Ториевый шип для щита", 164, "Черное копье" },
	[12655] = { 164, "Безмятежность", 164, "Доспех дикого терна", 164, "Зачарованная ториевая кираса", 164, "Зачарованные ториевые клинки", 164, "Зачарованные ториевые поножи", 164, "Зачарованный боевой молот", 164, "Зачарованный ториевый шлем", 164, "Звездчатый обсидиановый щит", 164, "Кираса железной лозы", 164, "Кровавый коготь", 164, "Лезвие Рассвета", 164, "Молот бури искусной работы", 164, "Неуязвимый доспех", 164, "Огненные латные рукавицы", 164, "Перчатки железной лозы", 164, "Поножи титанов", 164, "Пояс железной лозы", 164, "Пронзатель сердец", 164, "Пылающая рапира", 164, "Рукавицы Бури", 164, "Рукавицы цитадели", 164, "Толстая обсидиановая кираса", 164, "Тяжелый обсидиановый пояс", 164, "Черное копье", 164, "Шлем великого вождя", 164, "Шлем чистой души" },
	[12662] = { 164, "Выкованная демоном кираса", 164, "Кровавый коготь", 164, "Порча", 197, "Наплечники из ткани Скверны", 197, "Одеяние Бездны", 197, "Одеяние из ткани Скверны", 197, "Перчатки из ткани Скверны", 755, "Кольцо жестоких теней" },
	[12753] = { 164, "Увещеватель", 165, "Изменчивый плащ" },
	[12799] = { 164, "Арканитовый защитник", 164, "Безмятежность", 164, "Зачарованный ториевый шлем", 164, "Изысканный ториевый одноручный топор", 164, "Кираса темного духа", 164, "Молот бури искусной работы", 164, "Мрачнолесская секира", 164, "Наплечники темного духа", 164, "Поножи темного духа", 164, "Пронзатель сердец", 164, "Рукавицы цитадели", 164, "Руническое лезвие", 164, "Шлем великого вождя", 202, "Винтовка из черного железа", 202, "Модулирующий усилитель голоса", 202, "Ультра-вспышечный отражатель тьмы", 755, "Изумрудная корона разрушения", 755, "Опаловое ожерелье столкновения", 755, "Простое опаловое кольцо" },
	[12800] = { 164, "Арканитовый защитник", 164, "Зачарованная ториевая кираса", 164, "Зачарованный ториевый шлем", 164, "Ледяной страж", 164, "Неуязвимый доспех", 164, "Обсидиановый кольчужный мундир", 164, "Пронзатель сердец", 164, "Пылающая рапира", 164, "Черное копье", 164, "Шлем Львиного Сердца", 164, "Шлем чистой души", 164, "Эбеновая рука", 197, "Венец из луноткани", 202, "Гипер-излучающий отражатель пламени", 202, "Линза кровавой лозы", 202, "Отличная арканитовая винтовка", 202, "Ультра-вспышечный отражатель тьмы", 755, "Бриллиантовое кольцо концентрации", 755, "Ожерелье Адамантовой башни", 755, "Светящееся ториевое кольцо", 755, "Статуэтка черного алмазного краба" },
	[12803] = { 164, "Доспех дикого терна", 164, "Кираса железной лозы", 164, "Мрачнолесская секира", 164, "Перчатки железной лозы", 164, "Пояс железной лозы", 164, "Тяжелые сапоги Древобрюхов", 164, "Тяжелый пояс Древобрюхов", 165, "Ежевичные сапоги", 165, "Ежевичный пояс", 165, "Ежевичный шлем", 165, "Жакет из кожи древней летучей мыши", 165, "Золотое оплечье рассвета", 165, "Кираса Жизни", 165, "Кираса чешуи сна", 165, "Кулачные перчатки Древобрюхов", 165, "Мощь Древобрюхов", 165, "Наплечники жизни", 165, "Наручи из кожи древней летучей мыши", 165, "Перчатки из кожи древней летучей мыши", 165, "Поножи жизни", 165, "Химерические перчатки", 165, "Химерические поножи", 165, "Химерические сапоги", 165, "Химерический жилет", 171, "Трансмутация: жизнь в землю", 197, "Лесная корона", 197, "Лесной жилет", 197, "Лесные наплечники", 197, "Мудрость Древобрюхов", 197, "Облачение Геи", 197, "Оплечье Древобрюхов", 202, "Механическая жаба", 202, "Реактивный диск", 202, "Ультра-вспышечный отражатель тьмы", 333, "Чары для оружия - похищение жизни", 333, "Чары для плаща - сопротивление силам природы I", 755, "Кольцо природного огня", 755, "Подвеска из животворного изумруда" },
	[12804] = { 164, "Безмятежность", 164, "Зачарованный боевой молот", 164, "Черное копье", 165, "Кулачные перчатки Древобрюхов", 165, "Ремень Прозрения", 171, "Амулет безумия Гурубаши", 197, "Жилет кровавой лозы", 197, "Поножи кровавой лозы", 202, "Линза кровавой лозы", 202, "Очки кровавой лозы", 755, "Кольцо нападения", 755, "Подвеска из животворного изумруда", 755, "Статуэтка изумрудной совы" },
	[12808] = { 164, "Аннигилятор", 164, "Порча", 164, "Увещеватель", 171, "Трансмутация: нежити в воду", 185, "Эфемерная селедка", 197, "Одеяние Бездны", 197, "Одеяние зимней ночи", 197, "Перчатки из ткани Скверны", 202, "Смертоносный луч гномов", 202, "Ультра-вспышечный отражатель тьмы", 333, "Чары для оружия - нечестивое оружие", 333, "Чары для оружия - похищение жизни", 333, "Чары для перчаток - энергия Тьмы", 755, "Кольцо жестоких теней", 755, "Сапфировая подвеска зимней ночи" },
	[12809] = { 164, "Молот титанов", 164, "Обсидиановый кольчужный мундир", 164, "Черный Страж", 165, "Золотое оплечье рассвета", 165, "Рассветные ботфорты", 197, "Плащ стражи", 197, "Серебристые наплечники", 197, "Серебристые сапоги" },
	[12810] = { 164, "Аннигилятор", 164, "Арканитовый жнец", 164, "Арканитовый защитник", 164, "Клинок мудреца", 164, "Легкий обсидиановый пояс", 164, "Ледяной страж", 164, "Молот бури искусной работы", 164, "Молот титанов", 164, "Обсидиановый кольчужный мундир", 164, "Пронзатель сердец", 164, "Разоритель из черного железа", 164, "Разрушитель из черного железа", 164, "Рукавицы кровавого духа", 164, "Темнорунические рукавицы", 164, "Черный напоясник разрушителя", 165, "Ежевичные сапоги", 165, "Ежевичный пояс", 165, "Золотое оплечье рассвета", 165, "Изменчивый плащ", 165, "Кулачные перчатки Древобрюхов", 165, "Наплечники из чешуи синего дракона", 165, "Перчатки Грозового Покрова", 165, "Рунические кожаные наплечники", 165, "Рунические кожаные штаны", 165, "Рунический кожаный доспех", 165, "Снежные наручи", 165, "Снежные перчатки", 165, "Снежный мундир", 197, "Большая зачарованная сумка", 197, "Венец из луноткани", 197, "Напульсники пламенных недр", 197, "Оплечье пламенных недр", 197, "Перчатки волшебства", 197, "Перчатки пламенных недр", 197, "Рунические стигийские сапоги", 197, "Рунический стигийский пояс", 197, "Серебристые сапоги", 197, "Сумка из ткани Скверны", 202, "Отличная арканитовая винтовка", 202, "Очки волшебного могущества Экстрим-Плюс", 202, "Очки кровавой лозы", 202, "Очки старшего инженера" },
	[12811] = { 164, "Арканитовый защитник", 164, "Перчатки рассвета", 164, "Ремень рассвета", 197, "Одежды истинной веры", 333, "Чары для оружия - рыцарь", 333, "Чары для перчаток - целительная сила" },
	[12938] = { 171, "Амулет безумия Гурубаши", 755, "Корона Крови" },
	[13422] = { 171, "Масло каменного угря" },
	[13423] = { 171, "Зелье оцепенения", 171, "Наилучший эликсир защиты", 171, "Настой титанов", 171, "Сильное зелье каменного щита" },
	[13444] = { 333, "Чары для обуви - живучесть I" },
	[13446] = { 333, "Чары для нагрудника - здоровье VII", 333, "Чары для обуви - живучесть I" },
	[13463] = { 171, "Большое зелье омоложения", 171, "Настой великой силы", 171, "Настой чистой мудрости", 171, "Огромный флакон с зельем маны", 171, "Сильное зелье защиты от магии льда", 171, "Сильное зелье защиты от огня", 171, "Сильное зелье защиты от светлой магии", 171, "Сильное зелье защиты от сил природы", 171, "Сильное зелье защиты от тайной магии", 171, "Сильное зелье защиты от темной магии", 171, "Сильное зелье спокойного сна", 171, "Сильный чародейский эликсир", 171, "Эликсир адепта", 171, "Эликсир крови волшебника", 171, "Эликсир мудрецов" },
	[13464] = { 171, "Большое зелье омоложения", 171, "Огромный флакон с лечебным зельем", 171, "Сильное зелье спокойного сна", 171, "Флакон с летучим лечебным зельем", 171, "Эликсир целительной силы" },
	[13465] = { 171, "Большой эликсир силы", 171, "Зелье неудержимости", 171, "Настой великой силы", 171, "Настой всецветного сопротивления", 171, "Огромный флакон с лечебным зельем", 171, "Сильный чародейский эликсир", 171, "Эликсир мангуста", 171, "Эликсир натиска" },
	[13466] = { 171, "Зелье очищения", 171, "Мощный эликсир тролльей крови", 171, "Эликсир грубой силы", 171, "Эликсир крови волшебника", 171, "Эликсир мангуста", 171, "Эликсир мудрецов" },
	[13467] = { 171, "Зелье неудержимости", 171, "Зелье очищения", 171, "Настой всецветного сопротивления", 171, "Настой чистой мудрости", 171, "Огромный флакон с зельем маны", 202, "Гирозамораживающий ледяной отражатель", 333, "Чары для оружия - леденящая стужа" },
	[13468] = { 171, "Амулет безумия Гурубаши", 171, "Настой великой силы", 171, "Настой всецветного сопротивления", 171, "Настой титанов", 171, "Настой чистой мудрости", 197, "Сумка Кенария" },
	[13503] = { 171, "Алхимический камень искупителя", 171, "Алхимический камень стража", 171, "Алхимический камень убийцы", 171, "Алхимический камень чародея" },
	[13510] = { 164, "Поножи титанов" },
	[13512] = { 164, "Клинок мудреца", 164, "Черный напоясник разрушителя" },
	[13754] = { 185, "Мощь-рыба в кляре" },
	[13755] = { 185, "Кальмар-гриль" },
	[13756] = { 185, "Окунь горячего копчения" },
	[13757] = { 185, "Буреветчина" },
	[13758] = { 185, "Филе краснобородки" },
	[13759] = { 185, "Суп из ночного луциана" },
	[13760] = { 185, "Вареный солнечный лосось" },
	[13888] = { 185, "Похлебка из омаров" },
	[13889] = { 185, "Печеный лосось" },
	[13893] = { 185, "Стейк из мощь-рыбы" },
	[13926] = { 197, "Одежды истинной веры", 197, "Одеяние из луноткани", 197, "Перчатки волшебства", 197, "Перчатки из луноткани", 197, "Серебристые сапоги", 333, "Рунический арканитовый жезл", 333, "Чары для оружия - сила заклинаний" },
	[14044] = { 165, "Плащ из чешуи Ониксии" },
	[14047] = { 129, "Бинты из рунической ткани", 129, "Плотные бинты из рунической ткани", 164, "Массивное грузило", 165, "Руническая кожаная головная повязка", 165, "Рунические кожаные наплечники", 165, "Рунические кожаные рукавицы", 165, "Рунические кожаные штаны", 165, "Рунический кожаный доспех", 165, "Рунический кожаный пояс", 197, "Рулон рунической ткани", 202, "Большой атомарный перенаправлятор", 202, "Бомба из черного железа", 202, "Концентрированный динамит", 202, "Манекен-мишень искусной работы", 202, "Очки волшебного могущества Экстрим-Плюс", 202, "Петарда 'Змеиное жало'", 202, "Ториевая граната", 202, "Ториевое устройство", 202, "Чародейская бомба" },
	[14048] = { 165, "Броня огров Гордока", 197, "Бездонная сумка", 197, "Большая зачарованная сумка", 197, "Броня огров Гордока", 197, "Венец из луноткани", 197, "Головная повязка из рунической ткани", 197, "Жилет из луноткани", 197, "Жилет из пепельной ткани", 197, "Жилет из призрачной ткани", 197, "Зачарованная сумка из рунической ткани", 197, "Зеленые зимние одежды", 197, "Инфернальные перчатки", 197, "Капюшон из ткани Скверны", 197, "Кенарийская сумка для трав", 197, "Красные зимние одежды", 197, "Ледовые накулачники", 197, "Ледовые перчатки", 197, "Ледовый жилет", 197, "Ледовый плащ", 197, "Лесная корона", 197, "Лесной жилет", 197, "Лесные наплечники", 197, "Мудрость Древобрюхов", 197, "Мундир из ледяной ткани", 197, "Мундир из рунической ткани", 197, "Наплечники из луноткани", 197, "Наплечники из рунической ткани", 197, "Наплечники из ткани Скверны", 197, "Облачение Геи", 197, "Одежды истинной веры", 197, "Одеяние Бездны", 197, "Одеяние верховного мага", 197, "Одеяние зимней ночи", 197, "Одеяние из ледяной ткани", 197, "Одеяние из луноткани", 197, "Одеяние из рунической ткани", 197, "Одеяние из ткани Скверны", 197, "Одеяние из чародейской ткани", 197, "Одеяние из яркой ткани", 197, "Оплечье пламенных недр", 197, "Перчатки волшебства", 197, "Перчатки из ледяной ткани", 197, "Перчатки из луноткани", 197, "Перчатки из пепельной ткани", 197, "Перчатки из призрачной ткани", 197, "Перчатки из рунической ткани", 197, "Перчатки из ткани Скверны", 197, "Перчатки из яркой ткани", 197, "Перчатки пламенных недр", 197, "Плащ из пепельной ткани", 197, "Плащ из рунической ткани", 197, "Плащ из яркой ткани", 197, "Плащ огня", 197, "Плащ стражи", 197, "Поножи из луноткани", 197, "Поножи из чародейской ткани", 197, "Пояс верховного мага", 197, "Пояс из призрачной ткани", 197, "Пояс из рунической ткани", 197, "Праздничное платье", 197, "Праздничный красный костюм", 197, "Рунические стигийские поножи", 197, "Рунические стигийские сапоги", 197, "Рунический стигийский пояс", 197, "Сапоги из луноткани", 197, "Сапоги из рунической ткани", 197, "Сапоги из ткани Скверны", 197, "Серебристые сапоги", 197, "Сума душ", 197, "Сумка Кенария", 197, "Сумка из луноткани", 197, "Сумка из рунической ткани", 197, "Тюрбан из чародейской ткани", 197, "Штаны из ледяной ткани", 197, "Штаны из пепельной ткани", 197, "Штаны из призрачной ткани", 197, "Штаны из рунической ткани", 197, "Штаны из ткани Скверны", 197, "Штаны из яркой ткани" },
	[14227] = { 165, "Кираса из ледяной чешуи", 165, "Кулачные перчатки Древобрюхов", 165, "Лавовый пояс", 165, "Наплечники Грозового Покрова", 165, "Наручи из ледяной чешуи", 165, "Оплавленный пояс", 165, "Перчатки Грозового Покрова", 165, "Пояс гончей Недр", 165, "Разноцветные рукавицы", 165, "Рукавицы из ледяной чешуи", 165, "Снежные наручи", 165, "Снежные перчатки", 165, "Снежный мундир", 197, "Большая зачарованная сумка", 197, "Жилет кровавой лозы", 197, "Ледовые накулачники", 197, "Ледовые перчатки", 197, "Ледовый жилет", 197, "Ледовый плащ", 197, "Лесная корона", 197, "Лесной жилет", 197, "Лесные наплечники", 197, "Мудрость Древобрюхов", 197, "Мундир из рунической ткани", 197, "Наплечники из рунической ткани", 197, "Облачение Геи", 197, "Одеяние из рунической ткани", 197, "Одеяние пламенных недр", 197, "Оплечье Древобрюхов", 197, "Плащ из рунической ткани", 197, "Поножи кровавой лозы", 197, "Поножи пламенных недр", 197, "Рунические стигийские поножи", 197, "Рунические стигийские сапоги", 197, "Рунический стигийский пояс", 197, "Сапоги кровавой лозы", 197, "Серебристые наплечники", 197, "Серебристые сапоги", 197, "Сумка Кенария", 197, "Сумка из сердцевинной ткани Скверны", 197, "Сумка из ткани Скверны", 197, "Штаны из рунической ткани", 202, "Гоблинский кабельный макси-дефибриллятор", 202, "Сверхточный арканитовый преобразователь" },
	[14256] = { 165, "Гибельный кожаный доспех", 197, "Капюшон из ткани Скверны", 197, "Луноткань", 197, "Наплечники из ткани Скверны", 197, "Одеяние Бездны", 197, "Одеяние зимней ночи", 197, "Одеяние из ткани Скверны", 197, "Перчатки из ткани Скверны", 197, "Рунические стигийские поножи", 197, "Рунические стигийские сапоги", 197, "Рунический стигийский пояс", 197, "Сапоги из ткани Скверны", 197, "Сумка из сердцевинной ткани Скверны", 197, "Сумка из ткани Скверны", 197, "Штаны из ткани Скверны" },
	[14341] = { 165, "Броня огров Гордока", 165, "Вулканическая кираса", 165, "Вулканические наплечники", 165, "Вулканические поножи", 165, "Вычурная багровая шляпа", 165, "Вычурная лиловая шляпа", 165, "Вычурная походная шляпа", 165, "Вычурная тропическая шляпа", 165, "Гибельная кожаная головная повязка", 165, "Гибельные кожаные наручи", 165, "Гибельные кожаные рукавицы", 165, "Гибельные кожаные штаны", 165, "Гибельный кожаный доспех", 165, "Гибельный кожаный пояс", 165, "Доспех Грозового Покрова", 165, "Жакет из кожи древней летучей мыши", 165, "Железноперая кираса", 165, "Железноперые наплечники", 165, "Жилет дренейского дикаря", 165, "Жилет из толстой чешуи скорпида", 165, "Зимние сапоги", 165, "Золотая кираса Драконоборца", 165, "Золотое оплечье рассвета", 165, "Изменчивый плащ", 165, "Кираса Жизни", 165, "Кираса живых кристаллов", 165, "Кираса из чешуи Ониксии", 165, "Кираса из чешуи зеленого дракона", 165, "Кираса из чешуи красного дракона", 165, "Кираса из чешуи синего дракона", 165, "Кираса из чешуи черного дракона", 165, "Кираса извечного шторма", 165, "Кираса кровавого тигра", 165, "Кираса ловца Скверны", 165, "Кираса чешуи сна", 165, "Колчан из узловатой кожи", 165, "Короткие штаны боевого медведя", 165, "Мангустовые сапоги", 165, "Мощь Древобрюхов", 165, "Мундир из кожи ледопарда", 165, "Накладки из кожи Недр", 165, "Наплечники жизни", 165, "Наплечники из толстой чешуи скорпида", 165, "Наплечники из чешуи синего дракона", 165, "Наплечники из чешуи черного дракона", 165, "Наплечники кровавого тигра", 165, "Наручи из кожи древней летучей мыши", 165, "Наручи из толстой чешуи скорпида", 165, "Наручи ловца Скверны", 165, "Наручи стремительного полета", 165, "Оплавленный шлем", 165, "Перчатки дренейского дикаря", 165, "Перчатки из кожи древней летучей мыши", 165, "Перчатки из кожи ледопарда", 165, "Перчатки из сквернокожи", 165, "Плащ из чешуи Ониксии", 165, "Подсумок из узловатой кожи", 165, "Поножи Буйного Пера", 165, "Поножи Драконоборца", 165, "Поножи Черной бури", 165, "Поножи дренейского дикаря", 165, "Поножи дьявозавра", 165, "Поножи жизни", 165, "Поножи из кожи ледопарда", 165, "Поножи из сквернокожи", 165, "Поножи из толстой чешуи скорпида", 165, "Поножи из чешуи зеленого дракона", 165, "Поножи из чешуи синего дракона", 165, "Поножи из чешуи черного дракона", 165, "Поножи неистовства пустоты", 165, "Портупея боевого медведя", 165, "Пояс глубокой тени", 165, "Пояс из толстой чешуи скорпида", 165, "Пояс ловца Скверны", 165, "Пояс неистовства пустоты", 165, "Пояс природной силы", 165, "Пояс сезона дождей", 165, "Пояс черного орла", 165, "Разноцветный плащ", 165, "Рассветные ботфорты", 165, "Ремень Прозрения", 165, "Рукавицы дьявозавра", 165, "Рукавицы из толстой чешуи скорпида", 165, "Рукавицы из чешуи зеленого дракона", 165, "Руническая кожаная головная повязка", 165, "Рунические кожаные наплечники", 165, "Рунические кожаные наручи", 165, "Рунические кожаные рукавицы", 165, "Рунические кожаные штаны", 165, "Рунический кожаный доспех", 165, "Рунический кожаный пояс", 165, "Сапоги багрового ястреба", 165, "Сапоги гончей Недр", 165, "Сапоги дренейского дикаря", 165, "Сапоги из кожи ледопарда", 165, "Сапоги из сквернокожи", 165, "Сапоги из чешуи черного дракона", 165, "Сапоги неистовства пустоты", 165, "Сапоги непроглядной тьмы", 165, "Сапоги природной милости", 165, "Сапоги урагана", 165, "Сень Природы", 165, "Скверночешуйчатая кираса", 165, "Скверночешуйчатые перчатки", 165, "Скверночешуйчатые сапоги", 165, "Скверночешуйчатые штаны", 165, "Сумка кожевника", 165, "Сумка множества шкур", 165, "Тяжелые поножи из шкуры копытня", 165, "Тяжелые сапоги из шкуры копытня", 165, "Тяжелый панцирь из шкуры копытня", 165, "Утолщенная дренейская безрукавка", 165, "Утолщенные дренейские перчатки", 165, "Утолщенные дренейские сапоги", 165, "Утолщенные дренейские штаны", 165, "Химерические перчатки", 165, "Химерические поножи", 165, "Химерические сапоги", 165, "Химерический жилет", 165, "Чешуйчатая дренейская безрукавка", 165, "Чешуйчатые дренейские перчатки", 165, "Чешуйчатые дренейские сапоги", 165, "Чешуйчатые дренейские штаны", 165, "Шлем из толстой чешуи скорпида", 165, "Штаны Грозового Покрова", 197, "Бездонная сумка", 197, "Броня огров Гордока", 197, "Венец из луноткани", 197, "Головная повязка из рунической ткани", 197, "Жилет из луноткани", 197, "Жилет из пепельной ткани", 197, "Жилет из ткани Душ", 197, "Жилет пламенного сердца", 197, "Зачарованная сумка из рунической ткани", 197, "Зеленые зимние одежды", 197, "Золотая чародейская нить", 197, "Инфернальные перчатки", 197, "Капюшон из ткани Скверны", 197, "Кенарийская сумка для трав", 197, "Красные зимние одежды", 197, "Мундир из ледяной ткани", 197, "Мундир из прочной ткани Пустоты", 197, "Мундир из рунической ткани", 197, "Мундир из ткани Пустоты", 197, "Наплечники из луноткани", 197, "Наплечники из рунической ткани", 197, "Наплечники из ткани Душ", 197, "Наплечники из ткани Скверны", 197, "Напульсники пламенных недр", 197, "Наручи из тайной ткани", 197, "Наручи из ткани Пустоты", 197, "Наручи пламенного сердца", 197, "Одежды истинной веры", 197, "Одеяние Бездны", 197, "Одеяние верховного мага", 197, "Одеяние зимней ночи", 197, "Одеяние из ледяной ткани", 197, "Одеяние из луноткани", 197, "Одеяние из прочной ткани Пустоты", 197, "Одеяние из рунической ткани", 197, "Одеяние из тайной ткани", 197, "Одеяние из ткани Пустоты", 197, "Одеяние из ткани Скверны", 197, "Одеяние из чародейской ткани", 197, "Оплечье пламенных недр", 197, "Перчатки волшебства", 197, "Перчатки из ледяной ткани", 197, "Перчатки из луноткани", 197, "Перчатки из пепельной ткани", 197, "Перчатки из рунической ткани", 197, "Перчатки из ткани Душ", 197, "Перчатки из ткани Пустоты", 197, "Перчатки из ткани Скверны", 197, "Перчатки пламенного сердца", 197, "Перчатки пламенных недр", 197, "Плащ из пепельной ткани", 197, "Плащ огня", 197, "Плащ стражи", 197, "Поножи из луноткани", 197, "Поножи из чародейской ткани", 197, "Пояс верховного мага", 197, "Пояс взрыва", 197, "Пояс дальней дороги", 197, "Пояс из рунической ткани", 197, "Пояс из ткани Пустоты", 197, "Праздничное платье", 197, "Праздничный красный костюм", 197, "Руническая чародейская нить", 197, "Сапоги взрыва", 197, "Сапоги дальней дороги", 197, "Сапоги из луноткани", 197, "Сапоги из прочной ткани Пустоты", 197, "Сапоги из рунической ткани", 197, "Сапоги из тайной ткани", 197, "Сапоги из ткани Пустоты", 197, "Сапоги из ткани Скверны", 197, "Серебряная чародейская нить", 197, "Сума душ", 197, "Сумка из луноткани", 197, "Сумка из рунической ткани", 197, "Сумка из ткани Пустоты", 197, "Таинственная чародейская нить", 197, "Тюрбан из чародейской ткани", 197, "Штаны из ледяной ткани", 197, "Штаны из пепельной ткани", 197, "Штаны из прочной ткани Пустоты", 197, "Штаны из рунической ткани", 197, "Штаны из ткани Пустоты", 197, "Штаны из ткани Скверны" },
	[14342] = { 165, "Кираса Жизни", 197, "Бездонная сумка", 197, "Венец из луноткани", 197, "Жилет из луноткани", 197, "Жилет кровавой лозы", 197, "Лесная корона", 197, "Наплечники из луноткани", 197, "Напульсники пламенных недр", 197, "Одежды истинной веры", 197, "Одеяние из луноткани", 197, "Одеяние пламенных недр", 197, "Оплечье Древобрюхов", 197, "Перчатки волшебства", 197, "Перчатки из луноткани", 197, "Поножи из луноткани", 197, "Поножи кровавой лозы", 197, "Поножи пламенных недр", 197, "Пояс верховного мага", 197, "Сапоги из луноткани", 197, "Сапоги кровавой лозы", 197, "Серебристые наплечники", 197, "Сумка Кенария", 197, "Сумка из луноткани" },
	[14343] = { 333, "Дымящееся сердце горы", 333, "Чары для нагрудника - здоровье VI", 333, "Чары для оружия - леденящая стужа" },
	[14344] = { 197, "Бездонная сумка", 197, "Большая зачарованная сумка", 197, "Пояс верховного мага", 333, "Рунический арканитовый жезл", 333, "Рунический жезл из оскверненного железа", 333, "Сверкающее волшебное масло", 333, "Сверкающее масло маны", 333, "Чары для двуручного оружия - дух II", 333, "Чары для двуручного оружия - импульс V", 333, "Чары для двуручного оружия - интеллект II", 333, "Чары для двуручного оружия - ловкость I", 333, "Чары для нагрудника - все характеристики IV", 333, "Чары для нагрудника - здоровье VII", 333, "Чары для наручей - целительная сила", 333, "Чары для оружия - ловкость I", 333, "Чары для оружия - могучий дух", 333, "Чары для оружия - могучий интеллект", 333, "Чары для оружия - нечестивое оружие", 333, "Чары для оружия - похищение жизни", 333, "Чары для оружия - рыцарь", 333, "Чары для оружия - сила", 333, "Чары для оружия - сила заклинаний", 333, "Чары для оружия - удар V", 333, "Чары для оружия - целительная сила", 333, "Чары для перчаток - сила льда", 333, "Чары для перчаток - сила огня", 333, "Чары для перчаток - целительная сила", 333, "Чары для перчаток - энергия Тьмы" },
	[15407] = { 165, "Гибельные кожаные штаны", 165, "Гибельный кожаный доспех", 165, "Доспех Грозового Покрова", 165, "Ежевичные сапоги", 165, "Ежевичный пояс", 165, "Ежевичный шлем", 165, "Жакет из кожи древней летучей мыши", 165, "Железноперая кираса", 165, "Золотое оплечье рассвета", 165, "Кираса Жизни", 165, "Кираса духовного огня", 165, "Кираса из ледяной чешуи", 165, "Кираса из чешуи синего дракона", 165, "Кираса из чешуи черного дракона", 165, "Кираса кровавого тигра", 165, "Кираса песчаного ловца", 165, "Кулачные перчатки Древобрюхов", 165, "Мангустовые сапоги", 165, "Мощь Древобрюхов", 165, "Мундир из кожи ледопарда", 165, "Наплечники из толстой чешуи скорпида", 165, "Наплечники из чешуи синего дракона", 165, "Наплечники из чешуи черного дракона", 165, "Наплечники кровавого тигра", 165, "Наручи из кожи древней летучей мыши", 165, "Наручи из ледяной чешуи", 165, "Наручи стремительного полета", 165, "Перчатки из кожи древней летучей мыши", 165, "Поножи дьявозавра", 165, "Поножи жизни", 165, "Поножи из чешуи синего дракона", 165, "Поножи из чешуи черного дракона", 165, "Рассветные ботфорты", 165, "Ремень Прозрения", 165, "Рукавицы духовного огня", 165, "Рукавицы из ледяной чешуи", 165, "Рукавицы из чешуи зеленого дракона", 165, "Рукавицы песчаного ловца", 165, "Рунические кожаные наплечники", 165, "Рунический кожаный доспех", 165, "Сень Природы", 165, "Снежные наручи", 165, "Снежные перчатки", 165, "Снежный мундир", 165, "Шлем из толстой чешуи скорпида", 202, "Спокойный механический йети" },
	[15408] = { 165, "Жилет из толстой чешуи скорпида", 165, "Кираса из ледяной чешуи", 165, "Наплечники из толстой чешуи скорпида", 165, "Наручи из ледяной чешуи", 165, "Наручи из толстой чешуи скорпида", 165, "Поножи из толстой чешуи скорпида", 165, "Пояс из толстой чешуи скорпида", 165, "Рукавицы из ледяной чешуи", 165, "Рукавицы из толстой чешуи скорпида", 165, "Шлем из толстой чешуи скорпида" },
	[15409] = { 165, "Обработанная грубая шкура" },
	[15410] = { 165, "Кираса из чешуи Ониксии", 165, "Плащ из чешуи Ониксии" },
	[15412] = { 165, "Кираса из чешуи зеленого дракона", 165, "Поножи из чешуи зеленого дракона", 165, "Рукавицы из чешуи зеленого дракона" },
	[15414] = { 165, "Кираса из чешуи красного дракона", 165, "Разноцветный плащ" },
	[15415] = { 165, "Кираса из чешуи синего дракона", 165, "Наплечники из чешуи синего дракона", 165, "Поножи из чешуи синего дракона" },
	[15416] = { 165, "Золотая кираса Драконоборца", 165, "Кираса из чешуи Ониксии", 165, "Кираса из чешуи черного дракона", 165, "Наплечники из чешуи черного дракона", 165, "Поножи из чешуи черного дракона", 165, "Разноцветный плащ", 165, "Сапоги из чешуи черного дракона" },
	[15417] = { 164, "Увещеватель", 165, "Поножи дьявозавра", 165, "Рукавицы дьявозавра" },
	[15419] = { 165, "Короткие штаны боевого медведя", 165, "Портупея боевого медведя" },
	[15992] = { 202, "Амуниция с ториевым наконечником", 202, "Большая связка зеленых фейерверков", 202, "Большая связка красных фейерверков", 202, "Большая связка синих фейерверков", 202, "Бомба из черного железа", 202, "Концентрированный динамит", 202, "Мощный сефориевый заряд", 202, "Петарда 'Змеиное жало'", 202, "Ториевая граната" },
	[15994] = { 202, "Бомба из черного железа", 202, "Гирозамораживающий ледяной отражатель", 202, "Гоблинский кабельный макси-дефибриллятор", 202, "Манекен-мишень искусной работы", 202, "Механическая жаба", 202, "Модулирующий усилитель голоса", 202, "Мощный сефориевый заряд", 202, "Мощный фонарь", 202, "Спокойный механический йети", 202, "Ториевая винтовка", 202, "Ториевая граната", 202, "Увеличитель мира" },
	[16000] = { 202, "Большой атомарный перенаправлятор", 202, "Винтовка из черного железа", 202, "Манекен-мишень искусной работы", 202, "Отличная арканитовая винтовка", 202, "Прицел 'Бизникс' 247x128", 202, "Снайперская винтовка Недр" },
	[16006] = { 202, "Арканитовый дракончик", 202, "Гоблинский ракетомет", 202, "Модулирующий усилитель голоса", 202, "Пояс почти-неуязвимости", 202, "Прицел 'Бизникс' 247x128", 202, "Реактивный диск", 202, "Снайперская винтовка Недр", 202, "Удаленный конденсатор выхлопов", 202, "Чародейская бомба" },
	[16202] = { 333, "Зачарованная кожа", 333, "Чары для наручей - восполнение маны", 333, "Чары для наручей - дух V", 333, "Чары для наручей - интеллект III", 333, "Чары для наручей - целительная сила", 333, "Чары для обуви - ловкость IV", 333, "Чары для перчаток - ловкость II", 333, "Чары для перчаток - сила II" },
	[16203] = { 197, "Зачарованная сумка из рунической ткани", 333, "Рунический арканитовый жезл", 333, "Рунический жезл из оскверненного железа", 333, "Чары для двуручного оружия - дух II", 333, "Чары для двуручного оружия - интеллект II", 333, "Чары для наручей - сила V", 333, "Чары для обуви - дух II", 333, "Чары для оружия - могучий дух", 333, "Чары для оружия - могучий интеллект", 333, "Чары для оружия - сила заклинаний", 333, "Чары для оружия - удар V", 333, "Чары для оружия - целительная сила", 333, "Чары для щита - Живучесть" },
	[16204] = { 333, "Волшебное масло", 333, "Рунический арканитовый жезл", 333, "Чары для двуручного оружия - импульс V", 333, "Чары для нагрудника - все характеристики IV", 333, "Чары для нагрудника - мана VI", 333, "Чары для наручей - восполнение маны", 333, "Чары для наручей - выносливость V", 333, "Чары для наручей - сила V", 333, "Чары для наручей - целительная сила", 333, "Чары для оружия - могучий дух", 333, "Чары для оружия - могучий интеллект", 333, "Чары для перчаток - ловкость II", 333, "Чары для перчаток - сила II", 333, "Чары для плаща - защита III", 333, "Чары для щита - Живучесть" },
	[16206] = { 333, "Рунический арканитовый жезл" },
	[16207] = { 333, "Рунический жезл из оскверненного железа" },
	[17010] = { 164, "Наручи из черного железа", 164, "Пламенные плетеные наплечники", 164, "Пламенный плетеный ремень", 164, "Поножи из черного железа", 164, "Разоритель из черного железа", 164, "Рукавицы из черного железа", 164, "Сапоги из черного железа", 164, "Сульфуронский молот", 164, "Сумерки", 164, "Черное неистовство", 164, "Черное прощение", 164, "Черный Страж", 164, "Шлем из черного железа", 164, "Эбеновая рука", 165, "Оплавленный пояс", 165, "Оплавленный шлем", 165, "Пояс гончей Недр", 165, "Разноцветные рукавицы", 165, "Сапоги гончей Недр", 165, "Сапоги из чешуи черного дракона", 186, "Выплавка элементия", 197, "Напульсники пламенных недр", 197, "Одеяние пламенных недр", 197, "Оплечье пламенных недр", 197, "Перчатки пламенных недр", 197, "Поножи пламенных недр", 202, "Снайперская винтовка Недр" },
	[17011] = { 164, "Наручи из черного железа", 164, "Пламенные плетеные наплечники", 164, "Пламенный плетеный ремень", 164, "Поножи из черного железа", 164, "Разрушитель из черного железа", 164, "Рукавицы из черного железа", 164, "Сапоги из черного железа", 164, "Сульфуронский молот", 164, "Сумерки", 164, "Черное неистовство", 164, "Черное прощение", 164, "Черный Страж", 164, "Шлем из черного железа", 164, "Эбеновая рука", 165, "Лавовый пояс", 165, "Оплавленный пояс", 165, "Оплавленный шлем", 165, "Разноцветные рукавицы", 165, "Сапоги гончей Недр", 165, "Сапоги из чешуи черного дракона", 197, "Одеяние пламенных недр", 197, "Оплечье пламенных недр", 197, "Поножи пламенных недр", 202, "Прицел 'Бизникс' 247x128", 202, "Снайперская винтовка Недр" },
	[17012] = { 164, "Рукавицы из черного железа", 164, "Сапоги из черного железа", 165, "Лавовый пояс", 165, "Накладки из кожи Недр", 165, "Оплавленный пояс", 165, "Оплавленный шлем", 165, "Пояс гончей Недр", 165, "Разноцветные рукавицы", 165, "Сапоги гончей Недр", 197, "Бездонная сумка", 197, "Сумка из сердцевинной ткани Скверны" },
	[17020] = { 202, "Величайший" },
	[17034] = { 333, "Слабое волшебное масло", 333, "Слабое масло маны" },
	[17035] = { 333, "Простое волшебное масло" },
	[17056] = { 165, "Железноперая кираса", 165, "Железноперые наплечники", 165, "Колчан тысячи оперений", 165, "Оперенная перьями кираса", 165, "Поножи Буйного Пера" },
	[17194] = { 185, "Гоголь-моголь", 185, "Горячий яблочный сидр", 185, "Имбирное печенье" },
	[17196] = { 185, "Гоголь-моголь", 185, "Горячий яблочный сидр" },
	[17202] = { 202, "Создатель снега 9000" },
	[17203] = { 164, "Сульфуронский молот" },
	[18232] = { 202, "Дживс" },
	[18240] = { 165, "Броня огров Гордока", 197, "Броня огров Гордока" },
	[18255] = { 185, "Десерт из корня Рун-Тум" },
	[18256] = { 171, "Большое зелье защиты от магии льда", 171, "Большое зелье защиты от огня", 171, "Большое зелье защиты от светлой магии", 171, "Большое зелье защиты от сил природы", 171, "Большое зелье защиты от тайной магии", 171, "Большое зелье защиты от темной магии", 171, "Большое зелье омоложения", 171, "Большое зелье спокойного сна", 171, "Большой эликсир защиты", 171, "Большой эликсир крови волшебника", 171, "Большой эликсир ловкости", 171, "Большой эликсир огневой мощи", 171, "Большой эликсир силы", 171, "Большой эликсир силы льда", 171, "Большой эликсир стойкости", 171, "Большой эликсир энергии Тьмы", 171, "Гигантский флакон с зельем маны", 171, "Гигантский флакон с зельем омоложения", 171, "Гигантский флакон с лечебным зельем", 171, "Зелье адреналина", 171, "Зелье безумной силы", 171, "Зелье быстроты", 171, "Зелье героизма", 171, "Зелье дикой магии", 171, "Зелье железного щита", 171, "Зелье лазутчика", 171, "Зелье несокрушимости", 171, "Зелье ночных кошмаров", 171, "Зелье покровов", 171, "Зелье разрушения", 171, "Зелье сумасшедшего алхимика", 171, "Зелье ускорения", 171, "Малый настой сопротивления", 171, "Мощное зелье защиты от магии льда", 171, "Мощное зелье защиты от огня", 171, "Мощное зелье защиты от сил природы", 171, "Мощное зелье защиты от тайной магии", 171, "Мощное зелье защиты от темной магии", 171, "Мощное зелье омоложения", 171, "Мощный эликсир защиты", 171, "Мощный эликсир крови волшебника", 171, "Мощный эликсир ловкости", 171, "Мощный эликсир разума", 171, "Мощный эликсир силы", 171, "Мощный эликсир стойкости", 171, "Настой Слепящего света", 171, "Настой безжалостного убийцы", 171, "Настой всецветного чуда", 171, "Настой крепости", 171, "Настой могучего восстановления", 171, "Настой сопротивления", 171, "Настой укрепления", 171, "Настой чистой смерти", 171, "Оскверненное зелье маны", 171, "Оскверненное зелье регенерации", 171, "Оскверненный эликсир силы", 171, "Охранный эликсир", 171, "Рунический флакон с зельем маны", 171, "Рунический флакон с лечебным зельем", 171, "Слабый настой крепости", 171, "Флакон с бодрящим лечебным зельем", 171, "Флакон с ледяным зельем маны", 171, "Флакон с летучим лечебным зельем", 171, "Флакон с нестойким зельем маны", 171, "Эликсир 'Зоркий глаз'", 171, "Эликсир адепта", 171, "Эликсир власти", 171, "Эликсир гнева", 171, "Эликсир гуру", 171, "Эликсир дренейской мудрости", 171, "Эликсир духа", 171, "Эликсир железной шкуры", 171, "Эликсир земли", 171, "Эликсир маскировки", 171, "Эликсир мастерства", 171, "Эликсир меткости", 171, "Эликсир молниеносности", 171, "Эликсир натиска", 171, "Эликсир подавления", 171, "Эликсир пробивания брони", 171, "Эликсир силы заклинаний", 171, "Эликсир смертельных ударов", 171, "Эликсир хождения по воде", 171, "Эликсир целительной силы", 333, "Превосходное волшебное масло", 333, "Превосходное масло маны", 333, "Сверкающее волшебное масло", 333, "Сверкающее масло маны" },
	[18335] = { 755, "Статуэтка черного алмазного краба" },
	[18512] = { 165, "Ежевичные сапоги", 165, "Кираса песчаного ловца", 165, "Наручи песчаного ловца", 165, "Наручи стремительного полета", 165, "Рукавицы песчаного ловца", 165, "Сень Природы" },
	[18562] = { 186, "Выплавка элементия" },
	[18567] = { 186, "Выплавка элементия" },
	[18631] = { 202, "Большой атомарный перенаправлятор", 202, "Гипер-излучающий отражатель пламени", 202, "Гирозамораживающий ледяной отражатель", 202, "Гоблинский кабельный макси-дефибриллятор", 202, "Пространственный проходчик - Круговзор", 202, "Сверхбезопасный транспортер: Прибамбасск", 202, "Спокойный механический йети", 202, "Ультра-вспышечный отражатель тьмы" },
	[19441] = { 129, "Мощное противоядие" },
	[19726] = { 164, "Кираса железной лозы", 164, "Перчатки железной лозы", 165, "Ежевичный шлем", 197, "Жилет кровавой лозы", 197, "Лесной жилет", 197, "Облачение Геи", 197, "Поножи кровавой лозы", 197, "Сапоги кровавой лозы", 202, "Линза кровавой лозы", 202, "Очки кровавой лозы" },
	[19767] = { 165, "Жакет из кожи древней летучей мыши", 165, "Наручи из кожи древней летучей мыши", 165, "Перчатки из кожи древней летучей мыши" },
	[19768] = { 165, "Кираса кровавого тигра", 165, "Наплечники кровавого тигра" },
	[19774] = { 164, "Кираса кровавого духа", 164, "Кираса темного духа", 164, "Наплечники кровавого духа", 164, "Наплечники темного духа", 164, "Поножи темного духа", 164, "Рукавицы кровавого духа" },
	[19943] = { 171, "Амулет безумия Гурубаши" },
	[20381] = { 165, "Кираса чешуи сна" },
	[20424] = { 185, "Копченые пустынные клецки" },
	[20498] = { 165, "Кираса духовного огня", 165, "Кираса песчаного ловца", 165, "Наручи духовного огня", 165, "Наручи песчаного ловца", 165, "Рукавицы духовного огня", 165, "Рукавицы песчаного ловца" },
	[20500] = { 165, "Кираса духовного огня", 165, "Наручи духовного огня", 165, "Рукавицы духовного огня" },
	[20501] = { 165, "Кираса песчаного ловца", 165, "Наручи песчаного ловца", 165, "Рукавицы песчаного ловца" },
	[20520] = { 164, "Темноруническая кираса", 164, "Темнорунические рукавицы", 164, "Темнорунический шлем", 164, "Увещеватель", 197, "Рунические стигийские поножи", 197, "Рунические стигийские сапоги", 197, "Рунический стигийский пояс", 197, "Сумка из ткани Скверны" },
	[20725] = { 164, "Клинок мудреца", 333, "Преображение кристалла-источника" },
	[20816] = { 202, "Кабельная система с плавкими предохранителями", 755, "Изысканное ожерелье тигрового глаза", 755, "Кольцо золотого дракона", 755, "Кольцо с тигровым глазом", 755, "Малахитовая подвеска", 755, "Мрачное кольцо", 755, "Оплетенное медное кольцо", 755, "Плетеное медное кольцо", 755, "Толстое бронзовое ожерелье", 755, "Тяжелое медное кольцо" },
	[20817] = { 755, "Амулет Луны", 755, "Бронзовое кольцо силы", 755, "Бронзовое ожерелье", 755, "Варварский железный ошейник", 755, "Мрачное кольцо", 755, "Подвеска Агатового Щита", 755, "Подвеска серебряной розы", 755, "Простое жемчужное кольцо", 755, "Сверкающее ожерелье", 755, "Тяжелое нефритовое кольцо", 755, "Тяжелое серебряное кольцо", 755, "Цитриновая подвеска исцеления" },
	[20963] = { 755, "Аквамариновая подвеска воина", 755, "Нефритовая подвеска взрыва", 755, "Опаловое ожерелье столкновения", 755, "Пылающее цитриновое кольцо", 755, "Статуэтка нефритовой совы", 755, "Чеканное кольцо из истинного серебра" },
	[21024] = { 185, "Зажигательные химеровые отбивные Могиля" },
	[21071] = { 185, "Копченый шалфокунь" },
	[21153] = { 185, "Деликатес из шалфокуня" },
	[21752] = { 755, "Аквамариновый оберег", 755, "Бриллиантовое кольцо концентрации", 755, "Изумрудное кольцо льва", 755, "Кольцо нападения", 755, "Красное кольцо разрушения", 755, "Ожерелье Адамантовой башни", 755, "Опаловое ожерелье столкновения", 755, "Простое опаловое кольцо", 755, "Рубиновая корона восстановления", 755, "Рубиновая подвеска огня", 755, "Сапфировая подвеска зимней ночи", 755, "Сапфировый перстень", 755, "Светящееся ториевое кольцо", 755, "Украшенное самоцветами кольцо" },
	[21840] = { 197, "Жилет пламенного сердца", 197, "Ковер-самолет", 197, "Мундир из ткани Пустоты", 197, "Наручи жизненной силы", 197, "Наручи из тайной ткани", 197, "Наручи из ткани Пустоты", 197, "Наручи пламенного сердца", 197, "Одеяние из тайной ткани", 197, "Одеяние из ткани Пустоты", 197, "Одеяние пламени Пустоты", 197, "Перчатки из ткани Пустоты", 197, "Перчатки пламенного сердца", 197, "Поножи жизненной силы", 197, "Пояс жизненной силы", 197, "Пояс из ткани Пустоты", 197, "Пояс пламени Пустоты", 197, "Рулон прочной ткани Пустоты", 197, "Рулон ткани Душ", 197, "Сапоги из тайной ткани", 197, "Сапоги из ткани Пустоты", 197, "Сапоги пламени Пустоты", 197, "Сумка из ткани Пустоты", 197, "Штаны из ткани Пустоты", 202, "Облегченные экстремальные реактивые сапоги" },
	[21842] = { 197, "Белая лечебная накидка", 197, "Изначальная луноткань", 197, "Капюшон боевого заклятья", 197, "Мантия быстрого исцеления", 197, "Мантия сообразительности", 197, "Мешочек для драгоценностей", 197, "Мундир из прочной ткани Пустоты", 197, "Наручи Разора", 197, "Наручи Черного удара", 197, "Наручи непреклонности", 197, "Наручи сообразительности", 197, "Наручи стража духа", 197, "Одеяние из прочной ткани Пустоты", 197, "Плащ вечности", 197, "Плащ защиты от чар", 197, "Плащ черной бездны", 197, "Повязки быстрого исцеления", 197, "Поножи стража духа", 197, "Пояс взрыва", 197, "Пояс дальней дороги", 197, "Предел ночи", 197, "Ремень стража духа", 197, "Сапоги из прочной ткани Пустоты", 197, "Сумка из прочной ткани Пустоты", 197, "Ткань Теней", 197, "Туфли стража духа", 197, "Чароткань", 197, "Черный пояс знания", 197, "Штаны боевого заклятья", 197, "Штаны из прочной ткани Пустоты" },
	[21844] = { 165, "Нагрудный доспех сумеречного татя", 165, "Плащ Тьмы", 197, "Жилет из ткани Душ", 197, "Наплечники из ткани Душ", 197, "Перчатки из ткани Душ" },
	[21845] = { 197, "Ботаническая сумка Микаа", 197, "Капюшон белого целителя", 197, "Мантия быстрого исцеления", 197, "Накидка твердости", 197, "Наплечники из изначальной луноткани", 197, "Одеяние вечного света", 197, "Одеяние из изначальной луноткани", 197, "Перчатки вечного света", 197, "Повязки быстрого исцеления", 197, "Покров силы магии из ветроткани", 197, "Пояс из изначальной луноткани", 197, "Ремень Непреклонности", 197, "Сапоги дальней дороги", 197, "Старообрядческий пояс из шелка", 197, "Сумка из изначальной луноткани", 197, "Шаль силы духа из редкого шелка", 197, "Штаны Белого целителя", 202, "Облегченные биооптические очки целителя" },
	[21877] = { 129, "Бинты из ледяной ткани Пустоты", 129, "Бинты из ткани Пустоты", 129, "Плотные бинты из ткани Пустоты", 164, "Адамантитовое грузило", 164, "Грузило Скверны", 197, "Рулон ткани Пустоты", 197, "Сеть из ткани Пустоты", 197, "Тяжелая сеть из ткани Пустоты", 202, "Белая дымовая сигнальная ракета", 202, "Зеленая дымовая сигнальная ракета", 202, "Красная дымовая сигнальная ракета", 202, "Ледяные взрывчатые запалы", 202, "Лиловая дымовая сигнальная ракета", 202, "Механическая пелерина претендента", 202, "Механический плащ претендента", 202, "Превосходная мина", 202, "Синяя дымовая сигнальная ракета" },
	[21881] = { 197, "Застывшее тенетканое одеяние", 197, "Застывшие тенетканые наплечники", 197, "Застывшие тенетканые сапоги", 197, "Мундир из прочной ткани Пустоты", 197, "Наплечники из изначальной луноткани", 197, "Наручи жизненной силы", 197, "Одеяние из изначальной луноткани", 197, "Одеяние из огненной чароткани", 197, "Одеяние из прочной ткани Пустоты", 197, "Одеяние пламени Пустоты", 197, "Перчатки из огненной чароткани", 197, "Плащ защиты от чар", 197, "Поножи жизненной силы", 197, "Пояс жизненной силы", 197, "Пояс из изначальной луноткани", 197, "Пояс из огненной чароткани", 197, "Пояс пламени Пустоты", 197, "Сапоги из прочной ткани Пустоты", 197, "Сапоги пламени Пустоты", 197, "Сумка из изначальной луноткани", 197, "Сумка из огненной чароткани", 197, "Сумка из прочной ткани Пустоты", 197, "Черная сумка теней", 197, "Штаны из прочной ткани Пустоты" },
	[21882] = { 197, "Рулон ткани Душ" },
	[21884] = { 164, "Адамантитовая кираса", 164, "Адамантитовые латные наручи", 164, "Адамантитовые латные перчатки", 164, "Боевой доспех из закаленного кория", 164, "Закаленный в лаве боевой молот", 164, "Кираса из яростной стали", 164, "Кираса ледяного стража", 164, "Кираса огненной гибели", 164, "Красный пояс битвы", 164, "Кулачные перчатки из закаленного кория", 164, "Молот Драконьей длани", 164, "Наплечники из яростной стали", 164, "Наплечники рассветной стали", 164, "Наручи огненной гибели", 164, "Наручи рассветной стали", 164, "Перчатки из яростной стали", 164, "Перчатки огненной гибели", 164, "Поножи ледяного стража", 164, "Сапоги красного хаоса", 164, "Шепчущие ножи из оскверненной стали", 164, "Шип для щита из оскверненной стали", 164, "Шлем из яростной стали", 164, "Шлем ледяного стража", 164, "Шлем огненной гибели", 165, "Взрывостойкие сапоги", 165, "Взрывостойкие штаны", 165, "Взрывостойкий пояс", 165, "Вычурная багровая шляпа", 165, "Золотая кираса Драконоборца", 165, "Накладки сопротивления магии льда", 165, "Огненночешуйчатые поножи", 165, "Огненночешуйчатые сапоги", 165, "Огненночешуйчатый пояс", 165, "Перчатки дракона Пустоты", 165, "Перчатки налетевшего ветра", 165, "Черная кираса из чешуи дракона Пустоты", 165, "Черные наручи из чешуи дракона Пустоты", 165, "Черный пояс из чешуи дракона Пустоты", 165, "Шлем дракона Пустоты", 171, "Алхимический камень чародея", 171, "Большое зелье защиты от огня", 171, "Котел великой защиты от огня", 171, "Трансмутация: алмаз небесного огня", 171, "Трансмутация: изначальная мощь", 171, "Трансмутация: изначальный огонь в землю", 171, "Трансмутация: изначальный огонь в ману", 186, "Разложение огня", 197, "Жилет пламенного сердца", 197, "Наручи Черного удара", 197, "Наручи пламенного сердца", 197, "Одеяние из огненной чароткани", 197, "Одеяние пламени Пустоты", 197, "Перчатки из огненной чароткани", 197, "Перчатки пламенного сердца", 197, "Пояс взрыва", 197, "Пояс из огненной чароткани", 197, "Пояс пламени Пустоты", 197, "Ремень опустошения", 197, "Сапоги пламени Пустоты", 197, "Ткань Теней", 197, "Чароткань", 202, "Гиро-балансированный кориевый Разрушитель", 202, "Гномские боевые очки", 202, "Гномские силовые очки", 202, "Гоблинский ракетомет", 202, "Голографические очки аннигиляции", 202, "Кориевое силовое ядро", 202, "Проекционные очки резни", 202, "Пространственный проходчик - Зона 52", 202, "Укрепленный шлем старшины", 333, "Чары для наручей - сила заклинаний I", 333, "Чары для оружия - солнечный огонь", 333, "Чары для плаща - сопротивление IV", 755, "Застывшее око", 755, "Инфернальное кориевое кольцо", 755, "Подвеска Оттепели", 755, "Подвеска замерзшего пламени", 755, "Пылающее этерниевое кольцо", 755, "Статуэтка багровой змейки", 755, "Статуэтка змеи из животворного рубина" },
	[21885] = { 164, "Благословенные наручи", 164, "Гром", 164, "Закаленный бурей топор", 164, "Закаленный бурей хауберк", 164, "Кираса Солнечного благословения", 164, "Кираса ледяного стража", 164, "Кираса огненной гибели", 164, "Кориевые сапоги", 164, "Кориевые штаны", 164, "Кориевый пояс", 164, "Наручи огненной гибели", 164, "Перчатки огненной гибели", 164, "Поножи ледяного стража", 164, "Пояс хранителя", 164, "Сапоги защитника", 164, "Шлем бури", 164, "Шлем ледяного стража", 164, "Шлем огненной гибели", 165, "Взрывостойкие сапоги", 165, "Взрывостойкие штаны", 165, "Взрывостойкий пояс", 165, "Капюшон изначальной жизни", 165, "Накладки сопротивления огню", 165, "Наплечники молниеносной реакции", 165, "Наручники молниеносной реакции", 165, "Огненночешуйчатые поножи", 165, "Огненночешуйчатые сапоги", 165, "Огненночешуйчатый пояс", 165, "Поножи неистовства пустоты", 165, "Пояс неистовства пустоты", 165, "Пояс сезона дождей", 165, "Сапоги неистовства пустоты", 165, "Сапоги урагана", 171, "Большое зелье защиты от магии льда", 171, "Котел великой защиты от магии льда", 171, "Трансмутация: алмаз земной бури", 171, "Трансмутация: изначальная мощь", 171, "Трансмутация: первичная вода в воздух", 171, "Трансмутация: первичная вода в тьму", 197, "Застывшее тенетканое одеяние", 197, "Застывшие тенетканые наплечники", 197, "Застывшие тенетканые сапоги", 197, "Изначальная луноткань", 197, "Наручи жизненной силы", 197, "Перчатки вечного света", 197, "Поножи жизненной силы", 197, "Пояс дальней дороги", 197, "Пояс жизненной силы", 202, "Гипер-увеличивающие лунные очки", 202, "Гномские силовые очки", 202, "Исцеляющий рассеиватель теней XT68", 202, "Ледяные взрывчатые запалы", 202, "Очки изначальной гармонии", 333, "Чары для наручей - сила заклинаний I", 333, "Чары для оружия - военачальник", 333, "Чары для оружия - ледяная душа", 333, "Чары для оружия - лечение I", 333, "Чары для оружия - смертельный мороз", 333, "Чары для плаща - сопротивление IV", 755, "Застывшее око", 755, "Кориевое кольцо льда", 755, "Подвеска Оттепели", 755, "Подвеска замерзшего пламени" },
	[21886] = { 164, "Кираса Мира", 164, "Кираса Солнечного благословения", 164, "Кираса дикого стража", 164, "Наручи зеленой крепости", 164, "Поножи дикого стража", 164, "Рукавицы Солнечного благословения", 164, "Тенестальной ремень", 164, "Тенестальные наголенники", 164, "Тенестальные наручи", 164, "Тенестальные сабо", 164, "Шлем дикого стража", 164, "Шлем хранителя клятвы", 165, "Воинский пояс скованных душ", 165, "Вычурная походная шляпа", 165, "Животворный шлем из чешуи дракона", 165, "Капюшон изначальной жизни", 165, "Кираса живых кристаллов", 165, "Кожаные рукавицы Солнца", 165, "Кушак искупленной души", 165, "Мокасины искупленной души", 165, "Набедренники искупленной души", 165, "Наголенники скованных душ", 165, "Накладки сопротивления темной магии", 165, "Накулачники искупленной души", 165, "Наплечные пластины обновленной жизни", 165, "Наручи обновленной жизни", 165, "Наручи скованных душ", 165, "Перчатки Живого прикосновения", 165, "Пояс природной силы", 165, "Пронизанные солнцем чешуйчатые перчатки", 165, "Сапоги природной милости", 165, "Сапоги скованных душ", 171, "Алхимический камень искупителя", 171, "Большое зелье защиты от светлой магии", 171, "Большое зелье защиты от сил природы", 171, "Котел великой защиты от сил природы", 171, "Переменчивый камень", 171, "Трансмутация: первичная жизнь в землю", 197, "Белая лечебная накидка", 197, "Золотая чародейская нить", 197, "Изначальная луноткань", 197, "Мантия быстрого исцеления", 197, "Наплечники из изначальной луноткани", 197, "Наручи жизненной силы", 197, "Наручи стража духа", 197, "Перчатки вечного света", 197, "Плащ защиты от чар", 197, "Повязки быстрого исцеления", 197, "Поножи жизненной силы", 197, "Поножи стража духа", 197, "Пояс дальней дороги", 197, "Пояс жизненной силы", 197, "Пояс из изначальной луноткани", 197, "Предел ночи", 197, "Ремень стража духа", 197, "Серебряная чародейская нить", 197, "Туфли стража духа", 202, "Гипер-увеличивающие лунные очки", 202, "Линза могущественного целителя-9000", 202, "Очки 'Воздаятель-3000'", 202, "Очки изначальной гармонии", 202, "Пояс почти-неуязвимости", 202, "Удаленный конденсатор выхлопов", 333, "Чары для наручей - лечение II", 333, "Чары для оружия - лечение I", 333, "Чары для перчаток - лечение I", 333, "Чары для перчаток - угроза", 755, "Венок Зеленого Пламени", 755, "Кольцо бьющего ключа", 755, "Кориевое кольцо листвы", 755, "Подвеска края теней", 755, "Подвеска увядания", 755, "Природный оберег", 773, "Старшая карта Новолуния" },
	[21887] = { 164, "Адамантитовые латные перчатки", 164, "Адамантитовый кинжал", 165, "Колчан из узловатой кожи", 165, "Накладки из узловатой кожи", 165, "Перчатки дренейского дикаря", 165, "Подсумок из узловатой кожи", 165, "Поножи дренейского дикаря", 165, "Сапоги дренейского дикаря", 165, "Скверночешуйчатые перчатки", 165, "Скверночешуйчатые сапоги", 165, "Скверночешуйчатые штаны", 165, "Сумка кожевника", 165, "Толстая узловатая кожа", 165, "Удобные стельки", 165, "Утолщенные дренейские перчатки", 165, "Утолщенные дренейские сапоги", 165, "Утолщенные дренейские штаны", 165, "Чешуйчатые дренейские перчатки", 165, "Чешуйчатые дренейские штаны", 197, "Мешочек для драгоценностей", 197, "Наручи жизненной силы", 197, "Перчатки из ткани Душ", 197, "Перчатки из ткани Пустоты", 197, "Пояс жизненной силы", 197, "Пояс пламени Пустоты", 197, "Сапоги из прочной ткани Пустоты", 197, "Сапоги из ткани Пустоты", 197, "Сапоги пламени Пустоты", 202, "Набор для инъекций маны", 202, "Набор для лечебных инъекций" },
	[21929] = { 171, "Трансмутация: алмаз небесного огня", 202, "Умножающие силу очки", 755, "Блистающий пламенный спессарит", 755, "Гибельный пламенный спессарит", 755, "Кольцо природного огня", 755, "Могущественный пламенный спессарит", 755, "Покрытый письменами пламенный спессарит", 755, "Сверкающая драгоценность", 755, "Светоносный пламенный спессарит", 755, "Сокрытый пламенный спессарит" },
	[22202] = { 164, "Звездчатый обсидиановый щит", 164, "Легкий обсидиановый пояс", 164, "Обсидиановый кольчужный мундир", 164, "Толстая обсидиановая кираса", 164, "Тяжелый обсидиановый пояс", 164, "Черный напоясник разрушителя" },
	[22203] = { 164, "Звездчатый обсидиановый щит", 164, "Обсидиановый кольчужный мундир", 164, "Толстая обсидиановая кираса", 164, "Черный напоясник разрушителя" },
	[22445] = { 164, "Зачарованная адамантитовая кираса", 164, "Зачарованные адамантитовые поножи", 164, "Зачарованные адамантитовые сапоги", 164, "Зачарованный адамантитовый пояс", 165, "Ездовой хлыст", 197, "Ковер-самолет", 197, "Наручи из тайной ткани", 197, "Одеяние из тайной ткани", 197, "Рулон прочной ткани Пустоты", 197, "Сапоги из тайной ткани", 202, "Очки прядильщика", 202, "Полюсный птицефикатор гномов", 202, "Умножающие силу очки", 333, "Превосходное волшебное масло", 333, "Превосходное масло маны", 333, "Рунический этерниевый жезл", 333, "Чары для двуручного оружия - ловкость II", 333, "Чары для двуручного оружия - резня II", 333, "Чары для двуручного оружия - свирепость", 333, "Чары для кольца - удар", 333, "Чары для кольца - целительная сила", 333, "Чары для нагрудника - быстрое восполнение маны", 333, "Чары для нагрудника - восстановление маны II", 333, "Чары для нагрудника - все характеристики V", 333, "Чары для нагрудника - защита I", 333, "Чары для нагрудника - защита III", 333, "Чары для нагрудника - здоровье VII", 333, "Чары для нагрудника - устойчивость I", 333, "Чары для наручей - все характеристики", 333, "Чары для наручей - все характеристики III", 333, "Чары для наручей - грубая сила", 333, "Чары для наручей - дух VII", 333, "Чары для наручей - защита", 333, "Чары для наручей - мастерство II", 333, "Чары для наручей - сила заклинаний IV", 333, "Чары для наручей - стойкость", 333, "Чары для наручей - штурм I", 333, "Чары для наручей - штурм III", 333, "Чары для обуви - дух IV", 333, "Чары для обуви - живучесть I", 333, "Чары для обуви - живучесть клыкарра II", 333, "Чары для обуви - ледопроходец II", 333, "Чары для обуви - ловкость VI", 333, "Чары для обуви - стойкость I", 333, "Чары для обуви - стойкость III", 333, "Чары для обуви - стремительность", 333, "Чары для оружия - берсерк II", 333, "Чары для оружия - всплеск чар", 333, "Чары для оружия - дух III", 333, "Чары для оружия - ловкость II", 333, "Чары для оружия - мангуст", 333, "Чары для оружия - мангуст II", 333, "Чары для оружия - меткость II", 333, "Чары для оружия - могущество I", 333, "Чары для оружия - палач", 333, "Чары для оружия - сила заклинаний IV", 333, "Чары для оружия - удар VI", 333, "Чары для перчаток - взрыв I", 333, "Чары для перчаток - крушитель II", 333, "Чары для перчаток - мастерство II", 333, "Чары для перчаток - сила III", 333, "Чары для перчаток - сила заклинаний III", 333, "Чары для перчаток - точные удары", 333, "Чары для перчаток - штурм I", 333, "Чары для плаща - броня III", 333, "Чары для плаща - ловкость III", 333, "Чары для плаща - ловкость VI", 333, "Чары для плаща - могучая броня II", 333, "Чары для плаща - пронзающие заклинания II", 333, "Чары для плаща - проникающая способность заклинаний", 333, "Чары для плаща - скорость III", 333, "Чары для плаща - сопротивление V", 333, "Чары для плаща - ткань титанов II", 333, "Чары для посоха - сила заклинаний III", 333, "Чары для щита - блок II", 333, "Чары для щита - блок III", 333, "Чары для щита - выносливость V", 333, "Чары для щита - выносливость VI", 333, "Чары для щита - защита II", 333, "Чары для щита - интеллект III", 333, "Чары для щита - прочный щит", 755, "Слеза забвения", 755, "Слеза миража" },
	[22446] = { 197, "Сумка из огненной чароткани", 197, "Сумка из прочной ткани Пустоты", 333, "Рунический адамантитовый жезл", 333, "Рунический этерниевый жезл", 333, "Чары для двуручного оружия - ловкость II", 333, "Чары для двуручного оружия - резня II", 333, "Чары для кольца - сила заклинаний I", 333, "Чары для кольца - целительная сила", 333, "Чары для нагрудника - восстановление маны II", 333, "Чары для нагрудника - все характеристики V", 333, "Чары для нагрудника - дух", 333, "Чары для нагрудника - защита I", 333, "Чары для нагрудника - устойчивость I", 333, "Чары для нагрудника - устойчивость III", 333, "Чары для наручей - быстрое восполнение маны", 333, "Чары для наручей - все характеристики III", 333, "Чары для наручей - выносливость VII", 333, "Чары для наручей - дух VII", 333, "Чары для наручей - лечение II", 333, "Чары для наручей - мастерство II", 333, "Чары для наручей - сила заклинаний IV", 333, "Чары для наручей - стойкость", 333, "Чары для наручей - штурм III", 333, "Чары для обуви - дух IV", 333, "Чары для обуви - живучесть клыкарра II", 333, "Чары для обуви - ловкость VI", 333, "Чары для обуви - стремительность", 333, "Чары для обуви - штурм III", 333, "Чары для оружия - берсерк II", 333, "Чары для оружия - всплеск чар", 333, "Чары для оружия - интеллект I", 333, "Чары для оружия - ледяная душа", 333, "Чары для оружия - ловкость II", 333, "Чары для оружия - мангуст", 333, "Чары для оружия - могущество I", 333, "Чары для оружия - могущество IV", 333, "Чары для оружия - палач", 333, "Чары для оружия - сила заклинаний I", 333, "Чары для оружия - солнечный огонь", 333, "Чары для оружия - удар VI", 333, "Чары для оружия - черная магия II", 333, "Чары для перчаток - крушитель II", 333, "Чары для перчаток - лечение I", 333, "Чары для перчаток - ловкость III", 333, "Чары для перчаток - ловкость V", 333, "Чары для перчаток - сила III", 333, "Чары для перчаток - сила заклинаний I", 333, "Чары для перчаток - точные удары", 333, "Чары для перчаток - угроза", 333, "Чары для плаща - колосс", 333, "Чары для плаща - ловкость III", 333, "Чары для плаща - ловкость VI", 333, "Чары для плаща - могучая броня II", 333, "Чары для плаща - мудрость II", 333, "Чары для плаща - незаметность", 333, "Чары для плаща - проникающая способность заклинаний", 333, "Чары для плаща - скорость III", 333, "Чары для плаща - скрытность", 333, "Чары для плаща - сопротивление IV", 333, "Чары для плаща - сопротивление V", 333, "Чары для плаща - сопротивление огню III", 333, "Чары для плаща - сопротивление силам природы I", 333, "Чары для плаща - стальная ткань", 333, "Чары для плаща - уклонение", 333, "Чары для щита - блок II", 333, "Чары для щита - блок III", 333, "Чары для щита - интеллект I" },
	[22447] = { 333, "Чары для нагрудника - быстрое восполнение маны", 333, "Чары для наручей - все характеристики", 333, "Чары для наручей - интеллект IV", 333, "Чары для обуви - стойкость III", 333, "Чары для перчаток - взрыв I", 333, "Чары для перчаток - сила заклинаний III", 333, "Чары для щита - устойчивость", 333, "Чары для щита - устойчивость II" },
	[22448] = { 165, "Ездовой хлыст", 202, "Ультраскопические очки обнаружения", 333, "Большой радужный осколок", 333, "Чары для наручей - защита", 333, "Чары для перчаток - ловкость III", 333, "Чары для перчаток - сила льда", 333, "Чары для перчаток - сила огня", 333, "Чары для перчаток - угроза", 333, "Чары для перчаток - целительная сила", 333, "Чары для перчаток - энергия Тьмы", 333, "Чары для плаща - колосс", 333, "Чары для плаща - незаметность", 333, "Чары для плаща - скрытность", 333, "Чары для плаща - сопротивление огню III", 333, "Чары для плаща - сопротивление силам природы I", 333, "Чары для плаща - уклонение" },
	[22449] = { 164, "Зачарованная адамантитовая кираса", 164, "Зачарованные адамантитовые поножи", 164, "Зачарованные адамантитовые сапоги", 164, "Зачарованный адамантитовый пояс", 164, "Перчатки из быстростали", 202, "Очки гиперзрения", 202, "Полюсный птицефикатор гномов", 333, "Малый радужный осколок", 333, "Радужная сфера", 333, "Рунический адамантитовый жезл", 333, "Чары для двуручного оружия - ловкость II", 333, "Чары для двуручного оружия - свирепость", 333, "Чары для кольца - все характеристики", 333, "Чары для кольца - сила заклинаний I", 333, "Чары для кольца - удар", 333, "Чары для кольца - целительная сила", 333, "Чары для нагрудника - все характеристики V", 333, "Чары для нагрудника - все характеристики VIII", 333, "Чары для нагрудника - устойчивость III", 333, "Чары для наручей - сила заклинаний I", 333, "Чары для наручей - сила заклинаний IV", 333, "Чары для наручей - стойкость", 333, "Чары для обуви - быстрота вепря", 333, "Чары для обуви - верный шаг", 333, "Чары для обуви - живучесть клыкарра II", 333, "Чары для обуви - проворство кошки", 333, "Чары для обуви - штурм III", 333, "Чары для оружия - военачальник", 333, "Чары для оружия - всплеск чар", 333, "Чары для оружия - дух III", 333, "Чары для оружия - интеллект I", 333, "Чары для оружия - ледяная душа", 333, "Чары для оружия - лечение I", 333, "Чары для оружия - ловкость II", 333, "Чары для оружия - ловкость IV", 333, "Чары для оружия - мангуст", 333, "Чары для оружия - мангуст II", 333, "Чары для оружия - могущество I", 333, "Чары для оружия - могущество IV", 333, "Чары для оружия - палач", 333, "Чары для оружия - сила заклинаний I", 333, "Чары для оружия - сила заклинаний IV", 333, "Чары для оружия - солнечный огонь", 333, "Чары для оружия - удар VI", 333, "Чары для оружия - черная магия II", 333, "Чары для перчаток - крушитель II", 333, "Чары для перчаток - лечение I", 333, "Чары для перчаток - ловкость V", 333, "Чары для перчаток - оружейник II", 333, "Чары для перчаток - сила заклинаний I", 333, "Чары для перчаток - точные удары", 333, "Чары для плаща - ловкость VI", 333, "Чары для плаща - сопротивление тайной магии I", 333, "Чары для плаща - сопротивление темной магии II", 333, "Чары для посоха - сила заклинаний III", 333, "Чары для щита - сопротивление", 333, "Чары для щита - сопротивление II", 333, "Чары для щита - устойчивость", 333, "Чары для щита - устойчивость II" },
	[22450] = { 164, "Тенестальной ремень", 164, "Тенестальные наголенники", 164, "Тенестальные наручи", 164, "Тенестальные сабо", 165, "Воинский пояс скованных душ", 165, "Кушак искупленной души", 165, "Мокасины искупленной души", 165, "Набедренники искупленной души", 165, "Наголенники скованных душ", 165, "Накулачники искупленной души", 165, "Наручи скованных душ", 165, "Сапоги скованных душ", 197, "Наручи стража духа", 197, "Поножи стража духа", 197, "Предел ночи", 197, "Ремень стража духа", 197, "Туфли стража духа", 333, "Дробление кристалла Бездны", 333, "Пустая сфера", 333, "Чары для двуручного оружия - резня II", 333, "Чары для кольца - все характеристики", 333, "Чары для нагрудника - все характеристики VIII", 333, "Чары для наручей - выносливость VII", 333, "Чары для обуви - верный шаг", 333, "Чары для оружия - берсерк II", 333, "Чары для оружия - военачальник", 333, "Чары для оружия - ледяная душа", 333, "Чары для оружия - мангуст", 333, "Чары для оружия - мангуст II", 333, "Чары для оружия - меткость II", 333, "Чары для оружия - могущество IV", 333, "Чары для оружия - палач", 333, "Чары для оружия - сила заклинаний IV", 333, "Чары для оружия - солнечный огонь", 333, "Чары для оружия - черная магия II", 333, "Чары для плаща - мудрость II", 333, "Чары для посоха - сила заклинаний III" },
	[22451] = { 164, "Большой топор небесной кузни", 164, "Гром", 164, "Закаленная ветрами рапира", 164, "Закаленный бурей топор", 164, "Закаленный бурей хауберк", 164, "Кулачные перчатки из закаленного кория", 164, "Лунный Серп", 164, "Наплечники из быстростали", 164, "Наручи из быстростали", 164, "Перчатки из быстростали", 164, "Плетеная рубашка Пустоты", 164, "Пылкий страж", 164, "Шепчущие ножи из оскверненной стали", 164, "Шлем бури", 165, "Ветрочешуйчатый капюшон", 165, "Капюшон из чешуи кобры", 165, "Кираса извечного шторма", 165, "Кираса ловца Скверны", 165, "Кираса удара Пустоты", 165, "Колчан тысячи оперений", 165, "Накладки для поножей из кожи кобры", 165, "Накладки для поножей из чешуи кобры", 165, "Наплечники живой земли", 165, "Наплечники молниеносного удара", 165, "Наплечники молниеносной реакции", 165, "Наплечные пластины обновленной жизни", 165, "Напульсники ветроубийцы", 165, "Наручи легкокрылого ястреба", 165, "Наручи ловца Скверны", 165, "Наручи молниеносного удара", 165, "Наручи обновленной жизни", 165, "Наручи удара Пустоты", 165, "Наручники живой земли", 165, "Наручники молниеносной реакции", 165, "Перчатки из чешуи кобры", 165, "Перчатки налетевшего ветра", 165, "Плотная кираса из чешуи дракона Пустоты", 165, "Подсумок из узловатой кожи", 165, "Пояс глубокой тени", 165, "Пояс легкокрылого ястреба", 165, "Пояс ловца Скверны", 165, "Пояс природной силы", 165, "Пояс удара Пустоты", 165, "Пояс черного орла", 165, "Сапоги багрового ястреба", 165, "Стрелецкие перчатки Феникса", 165, "Хауберк легкокрылого ястреба", 171, "Алхимический камень стража", 171, "Трансмутация: алмаз небесного огня", 171, "Трансмутация: изначальная мощь", 171, "Трансмутация: первичный воздух в огонь", 197, "Плащ отмщения", 202, "Гиро-балансированный кориевый Разрушитель", 202, "Гномские силовые очки", 202, "Зачарованный шлем штейгера", 202, "Иссеченные молниями очки", 202, "Очки верного удара модель 3.0", 202, "Сверхбезопасный транспортер: станция Тошли", 333, "Чары для обуви - проворство кошки", 333, "Чары для оружия - ловкость II", 333, "Чары для оружия - ловкость IV", 333, "Чары для перчаток - ловкость III", 333, "Чары для плаща - ловкость III", 333, "Чары для плаща - сопротивление IV", 755, "Кольцо из закаленного кория" },
	[22452] = { 164, "Адамантитовая кираса", 164, "Адамантитовые латные наручи", 164, "Адамантитовые латные перчатки", 164, "Большой молот земной кузни", 164, "Кираса Мира", 164, "Лунный Серп", 164, "Молот Драконьей длани", 164, "Окованный камнем клеймор", 164, "Пояс хранителя", 164, "Рукавицы Железной башни", 164, "Тяжелая броня земной кузни", 164, "Шип для щита из оскверненной стали", 164, "Шлем стойкого защитника", 165, "Вычурная тропическая шляпа", 165, "Земляные сапоги из чешуи дракона Пустоты", 165, "Кираса извечного шторма", 165, "Нагрудный доспех сумеречного татя", 165, "Накладки для брони воздаятеля", 165, "Накладки для поножей из кожи копытня", 165, "Накладки для поножей из шкуры копытня", 165, "Наплечники живой земли", 165, "Напульсники ветроубийцы", 165, "Наручники живой земли", 165, "Перчатки Живого прикосновения", 165, "Плотная кираса из чешуи дракона Пустоты", 165, "Подсумок из чешуи дракона Пустоты", 165, "Тяжелые поножи из шкуры копытня", 165, "Тяжелые сапоги из шкуры копытня", 165, "Тяжелый панцирь из шкуры копытня", 165, "Укрепленная шахтерская сумка", 165, "Упрочнения для перчаток", 171, "Переменчивый камень", 171, "Трансмутация: алмаз земной бури", 171, "Трансмутация: изначальная мощь", 171, "Трансмутация: первичная земля в воду", 171, "Трансмутация: первичная земля в жизнь", 186, "Расщепление земли", 197, "Накидка твердости", 197, "Наручи Разора", 197, "Наручи непреклонности", 197, "Плащ вечности", 197, "Ремень Непреклонности", 202, "Адамантитовая рамка", 202, "Гномские боевые очки", 202, "Гномские силовые очки", 202, "Гоблинский ракетомет", 202, "Очки 'Воздаятель-3000'", 202, "Укрепленный шлем старшины", 333, "Чары для нагрудника - защита III", 333, "Чары для обуви - быстрота вепря", 333, "Чары для перчаток - оружейник II", 333, "Чары для плаща - сопротивление IV", 333, "Чары для плаща - стальная ткань", 333, "Чары для плаща - уклонение", 333, "Чары для щита - блок II", 333, "Чары для щита - блок III", 333, "Чары для щита - защита II", 333, "Чары для щита - прочный щит", 755, "Изначальная каменная статуя", 755, "Переменчивый адамантит", 755, "Статуэтка вепря из оскверненной стали", 755, "Статуэтка кориевого вепря" },
	[22456] = { 164, "Боевой доспех из закаленного кория", 164, "Кираса дикого стража", 164, "Кулачные перчатки из закаленного кория", 164, "Огненный страж", 164, "Плетеная рубашка Пустоты", 164, "Плоскостная кромка", 164, "Поножи дикого стража", 164, "Тенестальной ремень", 164, "Тенестальные наголенники", 164, "Тенестальные наручи", 164, "Тенестальные сабо", 164, "Черные наручи из оскверненной стали", 164, "Шлем дикого стража", 165, "Воинский пояс скованных душ", 165, "Вычурная лиловая шляпа", 165, "Капюшон из чешуи кобры", 165, "Кушак искупленной души", 165, "Мокасины искупленной души", 165, "Набедренники искупленной души", 165, "Наголенники скованных душ", 165, "Нагрудный доспех сумеречного татя", 165, "Накладки сопротивления силам природы", 165, "Накулачники искупленной души", 165, "Наручи скованных душ", 165, "Перчатки вечного сумрака", 165, "Перчатки из сквернокожи", 165, "Перчатки из чешуи кобры", 165, "Плащ Тьмы", 165, "Поножи из сквернокожи", 165, "Пояс глубокой тени", 165, "Сапоги из сквернокожи", 165, "Сапоги непроглядной тьмы", 165, "Сапоги скованных душ", 165, "Черная кираса из чешуи дракона Пустоты", 165, "Черные наручи из чешуи дракона Пустоты", 165, "Черный пояс из чешуи дракона Пустоты", 171, "Алхимический камень убийцы", 171, "Большое зелье защиты от темной магии", 171, "Котел великой защиты от темной магии", 171, "Трансмутация: изначальная Тень в воду", 197, "Наручи Разора", 197, "Наручи стража духа", 197, "Одеяние пламени Пустоты", 197, "Плащ черной бездны", 197, "Поножи стража духа", 197, "Пояс пламени Пустоты", 197, "Предел ночи", 197, "Ремень стража духа", 197, "Сапоги пламени Пустоты", 197, "Ткань Теней", 197, "Туфли стража духа", 202, "Гномские боевые очки", 202, "Голографические очки аннигиляции", 202, "Очки квадри-смертельного удара X44", 202, "Пояс почти-неуязвимости", 333, "Чары для оружия - ледяная душа", 333, "Чары для оружия - смертельный мороз", 333, "Чары для плаща - колосс", 333, "Чары для плаща - скрытность", 333, "Чары для плаща - сопротивление темной магии II", 755, "Кориевое кольцо теней", 755, "Подвеска края теней", 755, "Подвеска увядания", 755, "Природный оберег", 755, "Статуэтка пантеры Песни Теней", 755, "Статуэтка пантеры из ока ночи" },
	[22457] = { 164, "Глубокий гром", 164, "Кориевые сапоги", 164, "Кориевые штаны", 164, "Кориевый пояс", 164, "Лунный колун", 164, "Огненный страж", 164, "Оплот королей", 164, "Плетеная рубашка Круговерти Пустоты", 164, "Шлем стойкого защитника", 165, "Ветрочешуйчатый капюшон", 165, "Животворный шлем из чешуи дракона", 165, "Зачарованные перчатки из шкуры копытня", 165, "Зачарованные поножи из шкуры копытня", 165, "Зачарованные сапоги из шкуры копытня", 165, "Зачарованные скверночешуйчатые перчатки", 165, "Зачарованные скверночешуйчатые поножи", 165, "Зачарованные скверночешуйчатые сапоги", 165, "Земляные сапоги из чешуи дракона Пустоты", 165, "Кираса удара Пустоты", 165, "Накладки для брони магистра", 165, "Накладки сопротивления тайной магии", 165, "Наручи удара Пустоты", 165, "Перчатки дракона Пустоты", 165, "Поножи неистовства пустоты", 165, "Пояс неистовства пустоты", 165, "Пояс удара Пустоты", 165, "Сапоги неистовства пустоты", 165, "Шлем дракона Пустоты", 171, "Большое зелье защиты от тайной магии", 171, "Котел великой защиты от тайной магии", 171, "Переменчивый камень", 171, "Трансмутация: изначальная мощь", 171, "Трансмутация: первичная мана в огонь", 197, "Мантия сообразительности", 197, "Наручи сообразительности", 197, "Одеяние из изначальной луноткани", 197, "Плащ защиты от чар", 197, "Плащ из ткани маны", 197, "Плащ черной бездны", 197, "Руническая чародейская нить", 197, "Таинственная чародейская нить", 197, "Чароткань", 197, "Черный пояс знания", 202, "Голографические очки аннигиляции", 202, "Зачарованный шлем штейгера", 202, "Исцеляющий рассеиватель теней XT68", 202, "Линза могущественного целителя-9000", 202, "Очки 'Воздаятель-3000'", 202, "Очки изначальной гармонии", 202, "Превосходная мина", 333, "Чары для перчаток - сила заклинаний I", 333, "Чары для плаща - проникающая способность заклинаний", 333, "Чары для плаща - сопротивление тайной магии I", 755, "Венец Чародейской мощи", 755, "Кольцо чародейской защиты", 755, "Кориевое кольцо тайной магии", 755, "Подвеска пустой руны", 755, "Статуэтка морского альбатроса", 755, "Статуэтка таласситовой совы" },
	[22459] = { 755, "Сфера отрицания" },
	[22461] = { 333, "Рунический адамантитовый жезл" },
	[22462] = { 333, "Рунический этерниевый жезл" },
	[22463] = { 333, "Рунический титановый жезл" },
	[22572] = { 333, "Чары для щита - сопротивление", 333, "Чары для щита - сопротивление II" },
	[22573] = { 164, "Адамантитовое точило", 164, "Точило Скверны", 171, "Зелье железного щита", 202, "Взрывчатое вещество стихий", 333, "Чары для щита - сопротивление", 333, "Чары для щита - сопротивление II" },
	[22574] = { 171, "Большой эликсир огневой мощи", 202, "Взрывчатое вещество стихий", 333, "Чары для щита - сопротивление", 333, "Чары для щита - сопротивление II" },
	[22577] = { 185, "Испорченные моллюски" },
	[22578] = { 171, "Большой эликсир силы льда", 333, "Чары для обуви - ледопроходец II", 333, "Чары для щита - сопротивление", 333, "Чары для щита - сопротивление II", 755, "Ожерелье глубин" },
	[22644] = { 185, "Хрустящий паучий десерт" },
	[22682] = { 164, "Кираса ледяной погибели", 164, "Наручи ледяной погибели", 164, "Рукавицы ледяной погибели", 165, "Кираса из ледяной чешуи", 165, "Наручи из ледяной чешуи", 165, "Рукавицы из ледяной чешуи", 165, "Снежные наручи", 165, "Снежные перчатки", 165, "Снежный мундир", 197, "Ледовые накулачники", 197, "Ледовые перчатки", 197, "Ледовый жилет", 197, "Ледовый плащ" },
	[22785] = { 171, "Большой эликсир ловкости", 171, "Большой эликсир силы", 171, "Большой эликсир стойкости", 171, "Гигантский флакон с зельем маны", 171, "Гигантский флакон с лечебным зельем", 171, "Зелье лазутчика", 171, "Оскверненное зелье регенерации", 171, "Флакон с летучим лечебным зельем", 171, "Флакон с нестойким зельем маны", 171, "Эликсир адепта", 171, "Эликсир власти", 171, "Эликсир дренейской мудрости", 171, "Эликсир маскировки", 171, "Эликсир натиска" },
	[22786] = { 171, "Большое зелье спокойного сна", 171, "Гигантский флакон с зельем маны", 171, "Гигантский флакон с зельем омоложения", 171, "Настой всецветного чуда", 171, "Настой крепости", 171, "Настой могучего восстановления", 171, "Настой текущей воды", 171, "Эликсир земли", 171, "Эликсир целительной силы" },
	[22787] = { 171, "Большой эликсир стойкости", 171, "Зелье безумного алхимика", 171, "Зелье лазутчика", 171, "Зелье покровов", 171, "Настой драконьего разума", 171, "Флакон с нестойким зельем маны", 171, "Эликсир 'Зоркий глаз'", 171, "Эликсир железной шкуры", 171, "Эликсир земли", 171, "Эликсир маскировки" },
	[22789] = { 171, "Большой эликсир защиты", 171, "Большой эликсир ловкости", 171, "Зелье безумной силы", 171, "Зелье героизма", 171, "Зелье ускорения", 171, "Настой безжалостного убийцы", 171, "Настой крепости", 171, "Настой силы титана", 171, "Оскверненный эликсир силы", 171, "Эликсир 'Зоркий глаз'", 171, "Эликсир власти", 171, "Эликсир дренейской мудрости" },
	[22790] = { 171, "Большой эликсир защиты", 171, "Большой эликсир крови волшебника", 171, "Большой эликсир огневой мощи", 171, "Большой эликсир силы льда", 171, "Большой эликсир энергии Тьмы", 171, "Зелье героизма", 171, "Зелье железного щита", 171, "Настой стальной кожи", 171, "Настой укрепления", 171, "Эликсир железной шкуры" },
	[22791] = { 171, "Большой эликсир крови волшебника", 171, "Гигантский флакон с зельем омоложения", 171, "Гигантский флакон с лечебным зельем", 171, "Зелье покровов", 171, "Зелье разрушения", 171, "Зелье ускорения", 171, "Настой Слепящего света", 171, "Настой всецветного чуда", 171, "Настой драконьего разума", 171, "Эликсир подавления", 333, "Превосходное масло маны" },
	[22792] = { 171, "Большое зелье спокойного сна", 171, "Большой эликсир энергии Тьмы", 171, "Зелье разрушения", 171, "Настой сопротивления", 171, "Настой чистой смерти", 171, "Оскверненное зелье маны", 171, "Оскверненное зелье регенерации", 171, "Оскверненный эликсир силы", 333, "Превосходное волшебное масло" },
	[22793] = { 171, "Большое зелье защиты от магии льда", 171, "Большое зелье защиты от огня", 171, "Большое зелье защиты от светлой магии", 171, "Большое зелье защиты от сил природы", 171, "Большое зелье защиты от тайной магии", 171, "Большое зелье защиты от темной магии", 171, "Гигантский флакон с зельем омоложения", 171, "Котел великой защиты от магии льда", 171, "Котел великой защиты от огня", 171, "Котел великой защиты от сил природы", 171, "Котел великой защиты от тайной магии", 171, "Котел великой защиты от темной магии", 171, "Настой Слепящего света", 171, "Настой безжалостного убийцы", 171, "Настой могучего восстановления", 171, "Настой силы титана", 171, "Настой стальной кожи", 171, "Настой текущей воды", 171, "Настой укрепления", 171, "Настой чистой смерти", 171, "Оскверненное зелье маны", 171, "Эликсир подавления" },
	[22794] = { 171, "Алхимический камень", 171, "Настой Слепящего света", 171, "Настой безжалостного убийцы", 171, "Настой всецветного чуда", 171, "Настой драконьего разума", 171, "Настой могучего восстановления", 171, "Настой силы титана", 171, "Настой стальной кожи", 171, "Настой текущей воды", 171, "Настой укрепления", 171, "Настой чистой смерти", 197, "Ботаническая сумка Микаа", 333, "Чары для плаща - незаметность" },
	[22824] = { 164, "Кираса из яростной стали", 164, "Перчатки из яростной стали", 164, "Шлем из яростной стали", 333, "Чары для оружия - палач" },
	[22829] = { 202, "Набор для лечебных инъекций" },
	[22831] = { 164, "Перчатки из быстростали" },
	[22832] = { 202, "Набор для инъекций маны" },
	[23077] = { 171, "Трансмутация: алмаз небесного огня", 202, "Очки прядильщика", 755, "Изысканный кровавый гранат", 755, "Каплевидный кровавый гранат", 755, "Кровавое кольцо из оскверненного железа", 755, "Рельефный кровавый гранат", 755, "Рунический кровавый гранат", 755, "Сверкающая драгоценность", 755, "Статуэтка вепря из оскверненной стали", 755, "Яркий кровавый гранат" },
	[23079] = { 171, "Трансмутация: алмаз земной бури", 202, "Ультраскопические очки обнаружения", 755, "Зазубренный хризолит", 755, "Лазурное кольцо из лунного камня", 755, "Ослепительный хризолит", 755, "Отверделый хризолит", 755, "Сверкающая драгоценность", 755, "Светозарный хризолит" },
	[23107] = { 171, "Трансмутация: алмаз земной бури", 755, "Заряженный сумрачный дренит", 755, "Изменчивый сумрачный дренит", 755, "Королевский сумрачный дренит", 755, "Сбалансированный сумрачный дренит", 755, "Сверкающая драгоценность", 755, "Светящийся сумрачный дренит", 755, "Царственный сумрачный дренит" },
	[23112] = { 171, "Трансмутация: алмаз земной бури", 197, "Ковер-самолет", 202, "Адамантитовый прицел", 755, "Великий золотой дренит", 755, "Гладкий золотой дренит", 755, "Золотое кольцо с дренитом", 755, "Искристый золотой дренит", 755, "Матовый золотой дренит", 755, "Объятия рассвета", 755, "Прочный золотой дренит", 755, "Сверкающая драгоценность", 755, "Сверкающий золотой дренит", 755, "Статуэтка краба из зоревика" },
	[23117] = { 171, "Трансмутация: алмаз небесного огня", 755, "Блестящий лазурный лунный камень", 755, "Грозовой лазурный лунный камень", 755, "Искрящийся лазурный лунный камень", 755, "Лазурное кольцо из лунного камня", 755, "Сверкающая драгоценность", 755, "Цельный лазурный лунный камень", 755, "Цепь Сумеречной Совы" },
	[23424] = { 186, "Выплавка оскверненного железа" },
	[23425] = { 186, "Выплавка адамантита" },
	[23426] = { 186, "Выплавка кория" },
	[23427] = { 186, "Выплавка этерния", 333, "Чары для нагрудника - защита I" },
	[23436] = { 202, "Гномские боевые очки", 202, "Очки механического шторма", 202, "Очки смертельного удара X11", 202, "Яростные механические очки", 755, "Блистательный животворный рубин", 755, "Изысканный животворный рубин", 755, "Изящный животворный рубин", 755, "Каплевидный животворный рубин", 755, "Подвеска из животворного рубина", 755, "Пунцовое солнце", 755, "Рельефный животворный рубин", 755, "Роза Кайли", 755, "Рунический животворный рубин", 755, "Сердце дона Хулио", 755, "Статуэтка змеи из животворного рубина", 755, "Яркий животворный рубин" },
	[23437] = { 202, "Гномские силовые очки", 202, "Танкатронные очки", 202, "Увеличивающие лунные очки", 755, "Венок Зеленого Пламени", 755, "Зазубренный талассит", 755, "Мощный талассит", 755, "Неизменный талассит", 755, "Ослепительный талассит", 755, "Отверделый талассит", 755, "Светозарный талассит", 755, "Статуэтка таласситовой совы" },
	[23438] = { 202, "Голографические очки уничтожения", 202, "Стабилизированный этерниевый прицел", 755, "Блестящая Звезда Элуны", 755, "Венец Чародейской мощи", 755, "Грозовая Звезда Элуны", 755, "Искрящаяся Звезда Элуны", 755, "Падающая звезда", 755, "Цельная звезда Элуны" },
	[23439] = { 202, "Живые реплицирующие очки", 202, "Линза могущественного целителя-4000", 202, "Узорчатая кориевая винтовка", 755, "Блистающий благородный топаз", 755, "Гибельный благородный топаз", 755, "Могущественный благородный топаз", 755, "Покрытый письменами благородный топаз", 755, "Светоносный благородный топаз", 755, "Сокрытый благородный топаз", 755, "Тревожный благородный топаз" },
	[23440] = { 202, "Исцеляющий рассеиватель теней XT40", 202, "Кориевый прицел", 202, "Очки 'Воздаятель 2000'", 755, "Великий зоревик", 755, "Гладкий зоревик", 755, "Грань вечности", 755, "Искристый зоревик", 755, "Камень клинков", 755, "Матовый зоревик", 755, "Мистический зоревик", 755, "Мягкий зоревик", 755, "Прочный зоревик", 755, "Сверкающий зоревик", 755, "Статуэтка краба из зоревика", 755, "Статуэтка неземной черепахи", 755, "Янтарная кровь" },
	[23441] = { 202, "Очки верного удара модель 2.0", 202, "Очки гиперзрения", 755, "Заряженное око ночи", 755, "Изменчивое око ночи", 755, "Королевское око ночи", 755, "Монаршее око ночи", 755, "Око ночи", 755, "Сбалансированное око ночи", 755, "Светящееся око ночи", 755, "Статуэтка пантеры из ока ночи", 755, "Царственное око ночи" },
	[23445] = { 164, "Большой меч из оскверненного железа", 164, "Грузило Скверны", 164, "Жезл из оскверненного железа", 164, "Кираса из оскверненного железа", 164, "Кираса из яростной стали", 164, "Кираса огненной гибели", 164, "Латные набедренники из оскверненного железа", 164, "Латные перчатки из оскверненного железа", 164, "Латные сапоги из оскверненного железа", 164, "Латный пояс из оскверненного железа", 164, "Молот из оскверненного железа", 164, "Наплечники из яростной стали", 164, "Наручи огненной гибели", 164, "Перчатки из яростной стали", 164, "Перчатки огненной гибели", 164, "Плетеные наручи из оскверненного железа", 164, "Плетеные перчатки из оскверненного железа", 164, "Плетеный капюшон из оскверненного железа", 164, "Плетеный мундир из оскверненного железа", 164, "Секира из оскверненного железа", 164, "Точило Скверны", 164, "Шлем из яростной стали", 164, "Шлем огненной гибели", 186, "Выплавка оскверненной стали", 202, "Амуниция из оскверненного железа", 202, "Горсть винтов из оскверненного железа", 202, "Обшивка из оскверненного железа", 202, "Ящик для инструментов из оскверненного железа", 755, "Золотое кольцо с дренитом", 755, "Кровавое кольцо из оскверненного железа", 755, "Лазурное кольцо из лунного камня" },
	[23446] = { 164, "Адамантитовая кираса", 164, "Адамантитовая кувалда", 164, "Адамантитовая шпага", 164, "Адамантитовое грузило", 164, "Адамантитовое точило", 164, "Адамантитовые латные наручи", 164, "Адамантитовые латные перчатки", 164, "Адамантитовый жезл", 164, "Адамантитовый кинжал", 164, "Адамантитовый колун", 164, "Большой молот земной кузни", 164, "Большой топор небесной кузни", 164, "Закаленная ветрами рапира", 164, "Закаленный бурей топор", 164, "Закаленный бурей хауберк", 164, "Закаленный в лаве боевой молот", 164, "Колчедановая цепь для оружия", 164, "Колчедановый шип для щита", 164, "Окованный камнем клеймор", 164, "Простая охранная руна", 164, "Простой оберег", 164, "Тенестальной ремень", 164, "Тенестальные наголенники", 164, "Тенестальные наручи", 164, "Тенестальные сабо", 164, "Тяжелая броня земной кузни", 186, "Выплавка закаленного адамантита", 202, "Адамантитовая граната", 202, "Адамантитовая рамка", 202, "Адамантитовый прицел", 202, "Набор для снятия ограничителя", 202, "Полевой ремонтный робот 110G", 202, "Станок адамантитовой амуниции", 202, "Станок для адамантитовых патронов", 202, "Трицикл", 202, "Турботрицикл", 202, "Угрозодетектор R19", 755, "Толстое адамантитовое ожерелье", 755, "Тяжелое адамантитовое кольцо" },
	[23447] = { 164, "Кираса Королей", 164, "Колчедановая цепь для оружия", 164, "Колчедановый шип для щита", 164, "Латные сапоги кузнеца света", 164, "Лунный Серп", 164, "Молот Драконьей длани", 164, "Рука Вечности", 164, "Сильный оберег", 164, "Этерниевый жезл", 164, "Этерниевый рунический клинок", 186, "Выплавка оскверненной стали", 202, "Набор для снятия ограничителя", 202, "Трицикл", 202, "Турботрицикл", 202, "Угрозодетектор R19", 333, "Чары для плаща - ткань титанов II", 755, "Изысканное этерниевое кольцо", 755, "Кольцо чародейской защиты", 755, "Наследный камень императора", 755, "Объятия рассвета", 755, "Ограненный камень хиджальских гор", 755, "Оплетенная этерниевая кольчуга", 755, "Пылающее этерниевое кольцо", 755, "Сверкающее жемчужное кольцо", 755, "Статуэтка багровой змейки", 755, "Статуэтка морского альбатроса", 755, "Статуэтка таласситовой совы" },
	[23448] = { 164, "Боевой топор с кромкой Скверны", 164, "Длинный меч из оскверненной стали", 164, "Жнец из оскверненной стали", 164, "Закаленная Скверной кувалда", 164, "Кираса дикого стража", 164, "Молот праведной мощи", 164, "Наплечники из быстростали", 164, "Наручи из быстростали", 164, "Огненный страж", 164, "Перчатки из быстростали", 164, "Перчатки из оскверненной стали", 164, "Плетеная рубашка Пустоты", 164, "Плоскостная кромка", 164, "Погребальный Плач", 164, "Поножи дикого стража", 164, "Поножи из оскверненной стали", 164, "Рукавицы стальной хватки", 164, "Рукавицы ярости Скверны", 164, "Рунический молот", 164, "Черная плоскостная кромка", 164, "Черные наручи из оскверненной стали", 164, "Шепчущие ножи из оскверненной стали", 164, "Шип для щита из оскверненной стали", 164, "Шлем дикого стража", 164, "Шлем из оскверненной стали", 202, "Армированные биооптические очки защитника", 202, "Стабилизатор из оскверненной стали", 755, "Венец Чародейской мощи", 755, "Подвеска Оттепели", 755, "Подвеска замерзшего пламени", 755, "Подвеска края теней", 755, "Подвеска пустой руны", 755, "Подвеска увядания", 755, "Природный оберег", 755, "Статуэтка вепря из оскверненной стали", 755, "Статуэтка змеи из животворного рубина", 755, "Толстое ожерелье из оскверненной стали", 755, "Тяжелое кольцо из оскверненной стали" },
	[23449] = { 164, "Адамантитовая оружейная цепь", 164, "Боевой доспех из закаленного кория", 164, "Боевой топор с кромкой Скверны", 164, "Ботфорты кузни погибели", 164, "Гром", 164, "Длинный меч из оскверненной стали", 164, "Жнец из оскверненной стали", 164, "Закаленная Скверной кувалда", 164, "Кираса Королей", 164, "Кираса Солнечного благословения", 164, "Кираса из яростной стали", 164, "Кираса ледяного стража", 164, "Клинок Львиного сердца", 164, "Кориевые сапоги", 164, "Кориевые штаны", 164, "Кориевый защитник", 164, "Кориевый пояс", 164, "Молот Драконьей длани", 164, "Молот праведной мощи", 164, "Наплечники из яростной стали", 164, "Наплечники рассветной стали", 164, "Наручи рассветной стали", 164, "Перчатки из яростной стали", 164, "Плетеная рубашка Пустоты", 164, "Погребальный Плач", 164, "Поножи ледяного стража", 164, "Рука Вечности", 164, "Рунический молот", 164, "Сильная охранная руна", 164, "Шлем из яростной стали", 164, "Шлем ледяного стража", 164, "Этерниевый рунический клинок", 186, "Выплавка закаленного кория", 202, "Армированные биооптические очки целителя", 202, "Гиро-балансированный кориевый Разрушитель", 202, "Кориевое силовое ядро", 202, "Кориевый прицел", 202, "Очки гиперзрения", 202, "Узорчатая кориевая винтовка", 202, "Ультраскопические очки обнаружения", 755, "Венок Зеленого Пламени", 755, "Застывшее око", 755, "Инфернальное кориевое кольцо", 755, "Кориевое кольцо листвы", 755, "Кориевое кольцо льда", 755, "Кориевое кольцо тайной магии", 755, "Кориевое кольцо теней", 755, "Корона морской ведьмы", 755, "Подвеска из животворного рубина", 755, "Резонирующее кольцо гнева", 755, "Статуэтка кориевого вепря", 755, "Статуэтка краба из зоревика", 755, "Статуэтка неземной черепахи", 755, "Усиливающее слух кольцо преступника", 755, "Цепь Сумеречной Совы" },
	[23563] = { 164, "Плетеная рубашка Круговерти Пустоты" },
	[23564] = { 164, "Облачение Круговерти Пустоты" },
	[23571] = { 164, "Благословенные наручи", 164, "Боевой топор с кромкой Скверны", 164, "Длинный меч из оскверненной стали", 164, "Драконья Пасть", 164, "Жнец из оскверненной стали", 164, "Закаленная Скверной кувалда", 164, "Защитник Львиного сердца", 164, "Кираса Королей", 164, "Клинок Львиного сердца", 164, "Кориевый защитник", 164, "Лунный Серп", 164, "Молот праведной мощи", 164, "Плоскостная кромка", 164, "Погребальный Плач", 164, "Рука Вечности", 164, "Рукавицы Железной башни", 164, "Рукавицы Солнечного благословения", 164, "Рукавицы стальной хватки", 164, "Рукавицы ярости Скверны", 164, "Рунический молот", 164, "Шлем хранителя клятвы", 164, "Этерниевый рунический клинок", 165, "Ездовой хлыст", 165, "Жилет упреждающего удара", 165, "Кожаные рукавицы Солнца", 165, "Кожаный нагрудный доспех солнца", 165, "Наручи легкокрылого ястреба", 165, "Наручи упреждающего удара", 165, "Облачение Феникса", 165, "Панцирь Солнца и Тени", 165, "Перчатки вечного сумрака", 165, "Пояс легкокрылого ястреба", 165, "Пояс упреждающего удара", 165, "Пронизанные солнцем чешуйчатые перчатки", 165, "Пронизанный солнцем нагрудный доспех", 165, "Стрелецкие перчатки Феникса", 165, "Хауберк легкокрылого ястреба", 171, "Алхимический камень", 197, "Капюшон белого целителя", 197, "Капюшон боевого заклятья", 197, "Капюшон сокрушительной магии", 197, "Штаны Белого целителя", 197, "Штаны боевого заклятья", 197, "Штаны сокрушительной магии", 202, "Голографические очки уничтожения", 202, "Живые реплицирующие очки", 202, "Иссеченные молниями очки", 202, "Исцеляющий рассеиватель теней XT40", 202, "Линза могущественного целителя-4000", 202, "Очки 'Воздаятель 2000'", 202, "Очки верного удара модель 2.0", 202, "Очки из закаленного кория", 202, "Очки механического шторма", 202, "Очки смертельного удара X11", 202, "Танкатронные очки", 202, "Увеличивающие лунные очки", 202, "Яростные механические очки", 333, "Рунический адамантитовый жезл", 333, "Чары для оружия - солнечный огонь", 755, "Кольцо скованной мощи" },
	[23572] = { 164, "Благословенные наручи", 164, "Боевой доспех из закаленного кория", 164, "Боевой топор с кромкой Скверны", 164, "Ботфорты кузни погибели", 164, "Глубокий гром", 164, "Длинный меч из оскверненной стали", 164, "Драконья Пасть", 164, "Жнец из оскверненной стали", 164, "Закаленная Скверной кувалда", 164, "Защитник Львиного сердца", 164, "Кираса Солнечного благословения", 164, "Кираса дикого стража", 164, "Кираса ледяного стража", 164, "Кориевый защитник", 164, "Латные сапоги кузнеца света", 164, "Лунный колун", 164, "Молот праведной мощи", 164, "Наручи зеленой крепости", 164, "Оплот королей", 164, "Плетеная рубашка Круговерти Пустоты", 164, "Погребальный Плач", 164, "Поножи дикого стража", 164, "Поножи ледяного стража", 164, "Пылкий страж", 164, "Рука Вечности", 164, "Рукавицы Железной башни", 164, "Рукавицы стальной хватки", 164, "Рукавицы ярости Скверны", 164, "Рунический молот", 164, "Сапоги защитника", 164, "Сапоги красного хаоса", 164, "Утраченные сапоги ремесленника", 164, "Черная плоскостная кромка", 164, "Черные наручи из оскверненной стали", 164, "Шлем бури", 164, "Шлем дикого стража", 164, "Шлем ледяного стража", 164, "Шлем стойкого защитника", 164, "Шлем хранителя клятвы", 164, "Этерниевый рунический клинок", 165, "Ветрочешуйчатый капюшон", 165, "Гнилостный пояс из шкур вурдалаков", 165, "Животворный шлем из чешуи дракона", 165, "Жилет упреждающего удара", 165, "Земляные сапоги из чешуи дракона Пустоты", 165, "Капюшон из чешуи кобры", 165, "Капюшон изначальной жизни", 165, "Кираса удара Пустоты", 165, "Кожаный нагрудный доспех солнца", 165, "Колчан тысячи оперений", 165, "Нагрудный доспех сумеречного татя", 165, "Накладки для поножей из кожи копытня", 165, "Накладки для поножей из чешуи кобры", 165, "Напульсники ветроубийцы", 165, "Облачение Феникса", 165, "Опоясок с ножами для снятия шкур", 165, "Панцирь Солнца и Тени", 165, "Перчатки Живого прикосновения", 165, "Перчатки дракона Пустоты", 165, "Перчатки из чешуи кобры", 165, "Перчатки налетевшего ветра", 165, "Плащ Тьмы", 165, "Плотная кираса из чешуи дракона Пустоты", 165, "Подсумок из чешуи дракона Пустоты", 165, "Пояс легкокрылого ястреба", 165, "Пояс удара Пустоты", 165, "Пояс упреждающего удара", 165, "Поясное хранилище тяжелых игл", 165, "Пронизанный солнцем нагрудный доспех", 165, "Сапоги багрового ястреба", 165, "Сапоги непроглядной тьмы", 165, "Сапоги природной милости", 165, "Сапоги урагана", 165, "Уплотненный пояс из электрохимеры", 165, "Хауберк легкокрылого ястреба", 165, "Черная кираса из чешуи дракона Пустоты", 165, "Черный пояс из чешуи дракона Пустоты", 165, "Шлем дракона Пустоты", 197, "Золотая чародейская нить", 197, "Капюшон белого целителя", 197, "Капюшон боевого заклятья", 197, "Капюшон сокрушительной магии", 197, "Летний пояс мага-новичка", 197, "Накидка твердости", 197, "Одеяние Солнечного огня", 197, "Одеяние вечного света", 197, "Плащ из ткани маны", 197, "Плащ отмщения", 197, "Покров силы магии из ветроткани", 197, "Ремень Непреклонности", 197, "Ремень опустошения", 197, "Руническая чародейская нить", 197, "Сапоги взрыва", 197, "Сапоги дальней дороги", 197, "Старообрядческий пояс из шелка", 197, "Черный пояс знания", 197, "Шаль силы духа из редкого шелка", 197, "Штаны Белого целителя", 197, "Штаны боевого заклятья", 197, "Штаны сокрушительной магии", 202, "Активная наручная защита ХМ-52 \"Титан\"", 202, "Гипер-увеличивающие лунные очки", 202, "Гиро-балансированный кориевый Разрушитель", 202, "Голографические очки аннигиляции", 202, "Иссеченные молниями очки", 202, "Исцеляющий рассеиватель теней XT68", 202, "Линза могущественного целителя-9000", 202, "Наручная маскировка ХТ-92 \"Леший\"", 202, "Наручная электрозащита ХЕ-89 \"Буря\"", 202, "Наручные подавители боли ХМ-51 \"Узурпатор\"", 202, "Наручный инъектор ХЕ-39 \"Водяной\"", 202, "Наручный источник сил ХМ-75 \"Очищение\"", 202, "Наручный сканер слабостей ХТ-27 \"Трепет\"", 202, "Наручный целеуказатель ХЕ-41 \"Раптор\"", 202, "Очки 'Воздаятель-3000'", 202, "Очки верного удара модель 3.0", 202, "Очки из закаленного кория", 202, "Очки изначальной гармонии", 202, "Очки квадри-смертельного удара X44", 202, "Проекционные очки резни", 755, "Колье из закаленного кория", 755, "Кольцо полуночного неба", 755, "Наследный камень императора", 755, "Ограненный камень хиджальских гор", 755, "Резонирующее кольцо гнева", 755, "Сфера отрицания", 755, "Треснутая вневременная яшма", 755, "Треснутая зазубренная яшма", 755, "Треснутая замысловатая яшма", 755, "Треснутая крепкая яшма", 755, "Треснутая лучистая яшма", 755, "Треснутая мощная яшма", 755, "Треснутая насыщенная яшма", 755, "Треснутая неизменная яшма", 755, "Треснутая непрозрачная яшма", 755, "Треснутая ослепительная яшма", 755, "Треснутая отверделая яшма", 755, "Треснутая плотная яшма", 755, "Треснутая померкшая яшма", 755, "Треснутая раздробленная яшма", 755, "Треснутая расколотая яшма", 755, "Треснутая светозарная яшма", 755, "Треснутая сияющая яшма", 755, "Треснутая смутная яшма", 755, "Треснутая усиленная яшма", 755, "Треснутая яшма провидца", 755, "Треснутый блестящий зефирит", 755, "Треснутый блистательный сердолик", 755, "Треснутый блистающий гессонит", 755, "Треснутый броский гессонит", 755, "Треснутый всевластный камень ночи", 755, "Треснутый гессонит авангарда", 755, "Треснутый гессонит варвара", 755, "Треснутый гессонит защитника", 755, "Треснутый гессонит проворства", 755, "Треснутый гессонит фехтовальщика", 755, "Треснутый гибельный гессонит", 755, "Треснутый гладкий алицит", 755, "Треснутый глянцевый гессонит", 755, "Треснутый гравированный гессонит", 755, "Треснутый грозовой зефирит", 755, "Треснутый грубый гессонит", 755, "Треснутый заряженный камень ночи", 755, "Треснутый застывший гессонит", 755, "Треснутый затвердевший гессонит", 755, "Треснутый идеально ограненный гессонит", 755, "Треснутый изменчивый камень ночи", 755, "Треснутый изысканный сердолик", 755, "Треснутый изящный сердолик", 755, "Треснутый искрящийся зефирит", 755, "Треснутый камень ночи защитника", 755, "Треснутый камень ночи стража", 755, "Треснутый королевский камень ночи", 755, "Треснутый краеугольный гессонит", 755, "Треснутый матовый алицит", 755, "Треснутый мерцающий гессонит", 755, "Треснутый мистический алицит", 755, "Треснутый могущественный гессонит", 755, "Треснутый монарший камень ночи", 755, "Треснутый монументальный камень ночи", 755, "Треснутый мягкий алицит", 755, "Треснутый надежный гессонит", 755, "Треснутый наделенный силой гессонит", 755, "Треснутый непоколебимый сердолик", 755, "Треснутый непрочный камень ночи", 755, "Треснутый нетронутый гессонит", 755, "Треснутый округленный гессонит", 755, "Треснутый очищенный камень ночи", 755, "Треснутый покрытый письменами гессонит", 755, "Треснутый прозрачный гессонит", 755, "Треснутый прочный алицит", 755, "Треснутый растрескавшийся сердолик", 755, "Треснутый рельефный сердолик", 755, "Треснутый рунический сердолик", 755, "Треснутый сбалансированный камень ночи", 755, "Треснутый сверкающий алицит", 755, "Треснутый светоносный гессонит", 755, "Треснутый светящийся камень ночи", 755, "Треснутый смертоносный гессонит", 755, "Треснутый сокрытый гессонит", 755, "Треснутый стойкий алицит", 755, "Треснутый стойкий гессонит", 755, "Треснутый таинственный камень ночи", 755, "Треснутый тревожный гессонит", 755, "Треснутый царственный камень ночи", 755, "Треснутый цельный зефирит", 755, "Треснутый яркий сердолик", 755, "Треснутый ясный сердолик", 755, "Усиливающее слух кольцо преступника" },
	[23573] = { 164, "Адамантитовая оружейная цепь", 164, "Благословенные наручи", 164, "Боевой доспех из закаленного кория", 164, "Гром", 164, "Зачарованная адамантитовая кираса", 164, "Зачарованные адамантитовые поножи", 164, "Зачарованные адамантитовые сапоги", 164, "Зачарованный адамантитовый пояс", 164, "Кираса Королей", 164, "Кираса Мира", 164, "Кираса Солнечного благословения", 164, "Клинок Львиного сердца", 164, "Кориевый защитник", 164, "Красный пояс битвы", 164, "Наплечники из быстростали", 164, "Наплечники рассветной стали", 164, "Наручи зеленой крепости", 164, "Наручи из быстростали", 164, "Наручи рассветной стали", 164, "Плетеная рубашка Пустоты", 164, "Плоскостная кромка", 164, "Пояс хранителя", 164, "Рука Вечности", 164, "Рукавицы Железной башни", 164, "Сапоги защитника", 164, "Сапоги красного хаоса", 164, "Утраченные сапоги ремесленника", 164, "Шлем бури", 164, "Шлем стойкого защитника", 164, "Шлем хранителя клятвы", 164, "Этерниевый рунический клинок", 186, "Выплавка закаленного кория", 202, "Армированные биооптические очки бойца", 202, "Труба из закаленного адамантита", 202, "Укрепленный шлем старшины", 755, "Кольцо полуночного неба", 755, "Око ночи", 755, "Статуэтка пантеры Песни Теней", 755, "Статуэтка пантеры из ока ночи" },
	[23676] = { 185, "Жареная вырезка лунного оленя" },
	[23781] = { 202, "Адамантитовая граната", 202, "Амуниция из оскверненного железа", 202, "Белая дымовая сигнальная ракета", 202, "Бомба из оскверненного железа", 202, "Величайший", 202, "Ветролет", 202, "Зеленая дымовая сигнальная ракета", 202, "Красная дымовая сигнальная ракета", 202, "Ледяные взрывчатые запалы", 202, "Лиловая дымовая сигнальная ракета", 202, "Огненная турель гномов", 202, "Превосходная мина", 202, "Сефориевый заряд стихий", 202, "Синяя дымовая сигнальная ракета", 202, "Станок для адамантитовых патронов" },
	[23782] = { 171, "Котел великой защиты от магии льда", 171, "Котел великой защиты от огня", 171, "Котел великой защиты от сил природы", 171, "Котел великой защиты от тайной магии", 171, "Котел великой защиты от темной магии", 202, "Адамантитовая винтовка", 202, "Бомба из оскверненного железа", 202, "Величайший", 202, "Ветролет", 202, "Гномский пульт управления танком", 202, "Гоблинский пульт управления танком", 202, "Замораживающие гранаты", 202, "Мушкет из оскверненного железа", 202, "Набор для инъекций маны", 202, "Набор для лечебных инъекций", 202, "Огненная турель гномов", 202, "Робот 'Бей-Молоти'", 202, "Сефориевый заряд стихий", 202, "Удаленный конденсатор выхлопов", 202, "Ящик для инструментов из оскверненного железа" },
	[23783] = { 202, "Адамантитовая винтовка", 202, "Адамантитовая граната", 202, "Бомба из оскверненного железа", 202, "Величайший", 202, "Ветролет", 202, "Гномский пульт управления танком", 202, "Гоблинский пульт управления танком", 202, "Замораживающие гранаты", 202, "Мушкет из оскверненного железа", 202, "Набор для инъекций маны", 202, "Набор для лечебных инъекций", 202, "Огненная турель гномов", 202, "Огнестрел из оскверненной стали", 202, "Полевой ремонтный робот 110G", 202, "Пространственный проходчик - Зона 52", 202, "Робот 'Бей-Молоти'", 202, "Сверхбезопасный транспортер: станция Тошли", 202, "Сефориевый заряд стихий", 202, "Станок адамантитовой амуниции", 202, "Твареувеличитель", 202, "Удаленный конденсатор выхлопов", 202, "Узорчатая кориевая винтовка", 202, "Ящик для инструментов из оскверненного железа" },
	[23784] = { 202, "Адамантитовая винтовка", 202, "Армированные биооптические очки бойца", 202, "Армированные биооптические очки защитника", 202, "Армированные биооптические очки целителя", 202, "Облегченные биооптические очки заклинателя", 202, "Облегченные биооптические очки целителя", 202, "Огненная турель гномов", 202, "Повышающие проворство биооптические очки бойца", 202, "Повышающие проворство биооптические очки заклинателя", 202, "Повышающие проворство биооптические очки целителя", 202, "Пространственный проходчик - Зона 52", 202, "Робот 'Бей-Молоти'", 202, "Сверхбезопасный транспортер: станция Тошли", 202, "Смертоносные биооптические очки бойца", 202, "Смертоносные биооптические очки заклинателя", 202, "Смертоносные биооптические очки целителя", 202, "Твареувеличитель", 202, "Турбоветролет" },
	[23785] = { 202, "Активная наручная защита ХМ-52 \"Титан\"", 202, "Гиро-балансированный кориевый Разрушитель", 202, "Гоблинский ракетомет", 202, "Голографические очки уничтожения", 202, "Живые реплицирующие очки", 202, "Исцеляющий рассеиватель теней XT40", 202, "Кориевый прицел", 202, "Линза могущественного целителя-4000", 202, "Облегченные экстремальные реактивые сапоги", 202, "Огнестрел из оскверненной стали", 202, "Очки 'Воздаятель 2000'", 202, "Очки верного удара модель 2.0", 202, "Очки механического шторма", 202, "Очки смертельного удара X11", 202, "Полюсный птицефикатор гномов", 202, "Стабилизированный этерниевый прицел", 202, "Танкатронные очки", 202, "Увеличивающие лунные очки", 202, "Узорчатая кориевая винтовка", 202, "Экстремальные реактивные сапоги", 202, "Яростные механические очки" },
	[23786] = { 202, "Гоблинский ракетомет", 202, "Голографические очки уничтожения", 202, "Живые реплицирующие очки", 202, "Исцеляющий рассеиватель теней XT40", 202, "Линза могущественного целителя-4000", 202, "Наручные подавители боли ХМ-51 \"Узурпатор\"", 202, "Наручный сканер слабостей ХТ-27 \"Трепет\"", 202, "Наручный целеуказатель ХЕ-41 \"Раптор\"", 202, "Облегченные экстремальные реактивые сапоги", 202, "Очки 'Воздаятель 2000'", 202, "Очки верного удара модель 2.0", 202, "Очки механического шторма", 202, "Очки смертельного удара X11", 202, "Полевой ремонтный робот 110G", 202, "Полюсный птицефикатор гномов", 202, "Пояс почти-неуязвимости", 202, "Пространственный проходчик - Зона 52", 202, "Сверхбезопасный транспортер: станция Тошли", 202, "Танкатронные очки", 202, "Турбоветролет", 202, "Увеличивающие лунные очки", 202, "Экстремальные реактивные сапоги", 202, "Яростные механические очки" },
	[23787] = { 202, "Гиро-балансированный кориевый Разрушитель", 202, "Гоблинский ракетомет", 202, "Голографические очки уничтожения", 202, "Живые реплицирующие очки", 202, "Исцеляющий рассеиватель теней XT40", 202, "Линза могущественного целителя-4000", 202, "Наручная маскировка ХТ-92 \"Леший\"", 202, "Наручная электрозащита ХЕ-89 \"Буря\"", 202, "Наручный инъектор ХЕ-39 \"Водяной\"", 202, "Наручный источник сил ХМ-75 \"Очищение\"", 202, "Облегченные экстремальные реактивые сапоги", 202, "Огнестрел из оскверненной стали", 202, "Очки 'Воздаятель 2000'", 202, "Очки верного удара модель 2.0", 202, "Очки механического шторма", 202, "Очки смертельного удара X11", 202, "Сверхбезопасный транспортер: станция Тошли", 202, "Стабилизированный этерниевый прицел", 202, "Танкатронные очки", 202, "Турбоветролет", 202, "Увеличивающие лунные очки", 202, "Экстремальные реактивные сапоги", 202, "Яростные механические очки" },
	[23793] = { 164, "Шепчущие ножи из оскверненной стали", 165, "Барабаны битвы", 165, "Барабаны войны", 165, "Барабаны восстановления", 165, "Барабаны паники", 165, "Барабаны скорости", 165, "Ветрочешуйчатый капюшон", 165, "Взрывостойкие сапоги", 165, "Взрывостойкие штаны", 165, "Взрывостойкий пояс", 165, "Вычурная багровая шляпа", 165, "Вычурная лиловая шляпа", 165, "Вычурная походная шляпа", 165, "Вычурная тропическая шляпа", 165, "Гнилостный пояс из шкур вурдалаков", 165, "Ездовой хлыст", 165, "Животворный шлем из чешуи дракона", 165, "Жилет дренейского дикаря", 165, "Жилет упреждающего удара", 165, "Зачарованные перчатки из шкуры копытня", 165, "Зачарованные поножи из шкуры копытня", 165, "Зачарованные сапоги из шкуры копытня", 165, "Зачарованные скверночешуйчатые перчатки", 165, "Зачарованные скверночешуйчатые поножи", 165, "Зачарованные скверночешуйчатые сапоги", 165, "Земляные сапоги из чешуи дракона Пустоты", 165, "Золотая кираса Драконоборца", 165, "Капюшон из чешуи кобры", 165, "Капюшон изначальной жизни", 165, "Кираса живых кристаллов", 165, "Кираса извечного шторма", 165, "Кираса ловца Скверны", 165, "Кираса удара Пустоты", 165, "Кожаные рукавицы Солнца", 165, "Кожаный нагрудный доспех солнца", 165, "Колчан тысячи оперений", 165, "Нагрудный доспех сумеречного татя", 165, "Накладки для брони воздаятеля", 165, "Накладки для брони магистра", 165, "Накладки для поножей из кожи кобры", 165, "Накладки для поножей из кожи копытня", 165, "Накладки для поножей из чешуи кобры", 165, "Накладки для поножей из шкуры копытня", 165, "Накладки из толстой узловатой кожи", 165, "Накладки сопротивления магии льда", 165, "Накладки сопротивления огню", 165, "Накладки сопротивления силам природы", 165, "Накладки сопротивления тайной магии", 165, "Накладки сопротивления темной магии", 165, "Наплечники живой земли", 165, "Наплечники молниеносного удара", 165, "Наплечники молниеносной реакции", 165, "Наплечные пластины обновленной жизни", 165, "Напульсники ветроубийцы", 165, "Наручи легкокрылого ястреба", 165, "Наручи ловца Скверны", 165, "Наручи молниеносного удара", 165, "Наручи обновленной жизни", 165, "Наручи удара Пустоты", 165, "Наручи упреждающего удара", 165, "Наручники живой земли", 165, "Наручники молниеносной реакции", 165, "Облачение Феникса", 165, "Огненночешуйчатые поножи", 165, "Огненночешуйчатые сапоги", 165, "Огненночешуйчатый пояс", 165, "Панцирь Солнца и Тени", 165, "Перчатки Живого прикосновения", 165, "Перчатки вечного сумрака", 165, "Перчатки дракона Пустоты", 165, "Перчатки из сквернокожи", 165, "Перчатки из чешуи кобры", 165, "Перчатки налетевшего ветра", 165, "Плащ Тьмы", 165, "Плотная кираса из чешуи дракона Пустоты", 165, "Подсумок из чешуи дракона Пустоты", 165, "Поножи из сквернокожи", 165, "Поножи неистовства пустоты", 165, "Пояс глубокой тени", 165, "Пояс легкокрылого ястреба", 165, "Пояс ловца Скверны", 165, "Пояс неистовства пустоты", 165, "Пояс природной силы", 165, "Пояс сезона дождей", 165, "Пояс удара Пустоты", 165, "Пояс упреждающего удара", 165, "Пояс черного орла", 165, "Поясное хранилище тяжелых игл", 165, "Пронизанные солнцем чешуйчатые перчатки", 165, "Пронизанный солнцем нагрудный доспех", 165, "Сапоги багрового ястреба", 165, "Сапоги из сквернокожи", 165, "Сапоги неистовства пустоты", 165, "Сапоги непроглядной тьмы", 165, "Сапоги природной милости", 165, "Сапоги урагана", 165, "Скверночешуйчатая кираса", 165, "Стрелецкие перчатки Феникса", 165, "Сумка множества шкур", 165, "Тяжелые поножи из шкуры копытня", 165, "Тяжелые сапоги из шкуры копытня", 165, "Тяжелый панцирь из шкуры копытня", 165, "Укрепленная шахтерская сумка", 165, "Упрочнения для перчаток", 165, "Утолщенная дренейская безрукавка", 165, "Хауберк легкокрылого ястреба", 165, "Черная кираса из чешуи дракона Пустоты", 165, "Черные наручи из чешуи дракона Пустоты", 165, "Черный пояс из чешуи дракона Пустоты", 165, "Чешуйчатая дренейская безрукавка", 165, "Чешуйчатые дренейские сапоги", 165, "Шлем дракона Пустоты", 202, "Гномские боевые очки", 202, "Голографические очки уничтожения", 202, "Живые реплицирующие очки", 202, "Исцеляющий рассеиватель теней XT40", 202, "Линза могущественного целителя-4000", 202, "Очки 'Воздаятель 2000'", 202, "Очки верного удара модель 2.0", 202, "Очки гиперзрения", 202, "Очки механического шторма", 202, "Очки прядильщика", 202, "Очки смертельного удара X11", 202, "Повышающие проворство биооптические очки бойца", 202, "Повышающие проворство биооптические очки заклинателя", 202, "Повышающие проворство биооптические очки целителя", 202, "Пояс почти-неуязвимости", 202, "Танкатронные очки", 202, "Увеличивающие лунные очки", 202, "Ультраскопические очки обнаружения", 202, "Умножающие силу очки", 202, "Экстремальные реактивные сапоги", 202, "Яростные механические очки" },
	[23826] = { 202, "Пространственный проходчик - Зона 52" },
	[24243] = { 755, "Переменчивый адамантит" },
	[24271] = { 197, "Капюшон сокрушительной магии", 197, "Летний пояс мага-новичка", 197, "Мантия сообразительности", 197, "Наручи сообразительности", 197, "Одеяние Солнечного огня", 197, "Одеяние из огненной чароткани", 197, "Перчатки из огненной чароткани", 197, "Плащ из ткани маны", 197, "Повязки солнечного огня", 197, "Покров силы магии из ветроткани", 197, "Пояс из огненной чароткани", 197, "Сапоги взрыва", 197, "Сапоги дальней дороги", 197, "Сумка из огненной чароткани", 197, "Штаны сокрушительной магии", 202, "Гномские силовые очки", 202, "Облегченные биооптические очки заклинателя" },
	[24272] = { 197, "Застывшее тенетканое одеяние", 197, "Застывшие тенетканые наплечники", 197, "Застывшие тенетканые сапоги", 197, "Летний пояс мага-новичка", 197, "Одеяние Солнечного огня", 197, "Плащ отмщения", 197, "Повязки солнечного огня", 197, "Ремень опустошения", 197, "Сапоги взрыва", 197, "Старообрядческий пояс из шелка", 197, "Черная сумка теней", 197, "Шаль силы духа из редкого шелка", 202, "Зачарованный шлем штейгера" },
	[24477] = { 185, "Батончик из мяса моллюска" },
	[24478] = { 755, "Корона морской ведьмы", 755, "Ожерелье глубин", 755, "Очищенная жемчужина джаггала", 755, "Сверкающее жемчужное кольцо" },
	[24479] = { 755, "Корона морской ведьмы", 755, "Ожерелье глубин", 755, "Очищенная сумрачная жемчужина", 755, "Черная жемчужина" },
	[25649] = { 165, "Узловатая кожа" },
	[25699] = { 165, "Кираса живых кристаллов", 165, "Кираса ловца Скверны", 165, "Наручи ловца Скверны", 165, "Огненночешуйчатые поножи", 165, "Огненночешуйчатые сапоги", 165, "Огненночешуйчатый пояс", 165, "Опоясок с ножами для снятия шкур", 165, "Поножи неистовства пустоты", 165, "Пояс ловца Скверны", 165, "Пояс неистовства пустоты", 165, "Сапоги неистовства пустоты", 165, "Уплотненный пояс из электрохимеры" },
	[25700] = { 165, "Барабаны войны", 165, "Воинский пояс скованных душ", 165, "Зачарованные скверночешуйчатые перчатки", 165, "Зачарованные скверночешуйчатые поножи", 165, "Зачарованные скверночешуйчатые сапоги", 165, "Наголенники скованных душ", 165, "Наручи скованных душ", 165, "Сапоги скованных душ", 165, "Скверночешуйчатая кираса", 165, "Скверночешуйчатые перчатки", 165, "Скверночешуйчатые сапоги", 165, "Скверночешуйчатые штаны", 165, "Сумка кожевника", 165, "Чешуйчатая дренейская безрукавка", 165, "Чешуйчатые дренейские перчатки", 165, "Чешуйчатые дренейские сапоги", 165, "Чешуйчатые дренейские штаны" },
	[25707] = { 165, "Барабаны паники", 165, "Взрывостойкие сапоги", 165, "Взрывостойкие штаны", 165, "Взрывостойкий пояс", 165, "Кираса ловца Скверны", 165, "Кушак искупленной души", 165, "Мокасины искупленной души", 165, "Набедренники искупленной души", 165, "Накулачники искупленной души", 165, "Наручи ловца Скверны", 165, "Панцирь Солнца и Тени", 165, "Перчатки вечного сумрака", 165, "Перчатки из сквернокожи", 165, "Поножи из сквернокожи", 165, "Пояс ловца Скверны", 165, "Сапоги из сквернокожи", 165, "Сумка кожевника", 165, "Сумка множества шкур", 202, "Смертоносные биооптические очки заклинателя" },
	[25708] = { 165, "Барабаны битвы", 165, "Зачарованные перчатки из шкуры копытня", 165, "Зачарованные поножи из шкуры копытня", 165, "Зачарованные сапоги из шкуры копытня", 165, "Кожаные рукавицы Солнца", 165, "Кожаный нагрудный доспех солнца", 165, "Накладки для поножей из кожи копытня", 165, "Накладки для поножей из шкуры копытня", 165, "Сумка множества шкур", 165, "Тяжелые поножи из шкуры копытня", 165, "Тяжелые сапоги из шкуры копытня", 165, "Тяжелый панцирь из шкуры копытня" },
	[25719] = { 165, "Колчан из узловатой кожи" },
	[25843] = { 333, "Рунический жезл из оскверненного железа" },
	[25844] = { 333, "Рунический адамантитовый жезл" },
	[25845] = { 333, "Рунический этерниевый жезл" },
	[25867] = { 171, "Алхимический камень", 755, "Алмаз жестокой земной бури", 755, "Вечный алмаз земной бури", 755, "Грубый алмаз земной бури", 755, "Крепкий алмаз земной бури", 755, "Могущественный алмаз земной бури", 755, "Нерушимый алмаз земной бури", 755, "Провидческий алмаз земной бури" },
	[25868] = { 171, "Алхимический камень", 755, "Громовой алмаз небесного огня", 755, "Загадочный алмаз небесного огня", 755, "Мистический алмаз небесного огня", 755, "Разрушительный алмаз небесного огня", 755, "Стремительный алмаз небесного огня", 755, "Угасающий алмаз небесного огня", 755, "Хаотический алмаз небесного огня" },
	[27422] = { 185, "Копченая форель", 185, "Тушеная форель" },
	[27425] = { 185, "Лакомство из сквернохвоста" },
	[27429] = { 185, "Копченый спороус" },
	[27435] = { 185, "Жареная ильница" },
	[27437] = { 185, "Вареный луфарь" },
	[27438] = { 185, "Палочки из золотой рыбки" },
	[27439] = { 185, "Рак с пряностями" },
	[27503] = { 164, "Наплечники из яростной стали" },
	[27515] = { 185, "Рыбацкая услада" },
	[27516] = { 185, "Жареная форель" },
	[27668] = { 185, "Стейк из рысятины" },
	[27669] = { 185, "Закуска из летучей мыши" },
	[27671] = { 185, "'Кит и кот'", 185, "Закуска из канюка" },
	[27674] = { 185, "Сосиска из мяса опустошителя" },
	[27676] = { 185, "Закуска спорлингов" },
	[27677] = { 185, "Копченый василиск" },
	[27678] = { 185, "Буреветчина", 185, "Жареное мясо копытня" },
	[27681] = { 185, "Котлета из прыгуаны" },
	[27682] = { 185, "Острый стейк из талбука", 185, "Стейк из талбука" },
	[27860] = { 755, "Очищенная жемчужина джаггала", 755, "Очищенная сумрачная жемчужина" },
	[28425] = { 164, "Пылкий страж" },
	[28426] = { 164, "Пылкое неистовство" },
	[28428] = { 164, "Защитник Львиного сердца" },
	[28429] = { 164, "Палач Львиного сердца" },
	[28431] = { 164, "Черная плоскостная кромка" },
	[28432] = { 164, "Гибельный край миров" },
	[28434] = { 164, "Лунный колун" },
	[28435] = { 164, "Кровавая луна" },
	[28437] = { 164, "Драконья Пасть" },
	[28438] = { 164, "Драконий удар" },
	[28440] = { 164, "Глубокий гром" },
	[28441] = { 164, "Штормовестник" },
	[28483] = { 164, "Оплот королей" },
	[28484] = { 164, "Оплот древних королей" },
	[29539] = { 165, "Вычурная багровая шляпа", 165, "Вычурная лиловая шляпа", 165, "Вычурная походная шляпа", 165, "Вычурная тропическая шляпа", 165, "Капюшон из чешуи кобры", 165, "Накладки для поножей из кожи кобры", 165, "Накладки для поножей из чешуи кобры", 165, "Перчатки из чешуи кобры" },
	[29547] = { 165, "Барабаны скорости", 165, "Ветрочешуйчатый капюшон", 165, "Наплечники живой земли", 165, "Наплечники молниеносной реакции", 165, "Напульсники ветроубийцы", 165, "Наручи легкокрылого ястреба", 165, "Наручники живой земли", 165, "Наручники молниеносной реакции", 165, "Облачение Феникса", 165, "Перчатки налетевшего ветра", 165, "Пояс легкокрылого ястреба", 165, "Пояс сезона дождей", 165, "Пояс черного орла", 165, "Сапоги багрового ястреба", 165, "Сапоги урагана", 165, "Стрелецкие перчатки Феникса", 165, "Сумка множества шкур", 165, "Хауберк легкокрылого ястреба", 202, "Смертоносные биооптические очки бойца" },
	[29548] = { 165, "Барабаны восстановления", 165, "Животворный шлем из чешуи дракона", 165, "Земляные сапоги из чешуи дракона Пустоты", 165, "Кираса удара Пустоты", 165, "Наручи удара Пустоты", 165, "Перчатки дракона Пустоты", 165, "Плотная кираса из чешуи дракона Пустоты", 165, "Подсумок из чешуи дракона Пустоты", 165, "Пояс удара Пустоты", 165, "Пронизанные солнцем чешуйчатые перчатки", 165, "Пронизанный солнцем нагрудный доспех", 165, "Сумка множества шкур", 165, "Черная кираса из чешуи дракона Пустоты", 165, "Черные наручи из чешуи дракона Пустоты", 165, "Черный пояс из чешуи дракона Пустоты", 165, "Шлем дракона Пустоты", 202, "Смертоносные биооптические очки целителя" },
	[30183] = { 164, "Гибельный край миров", 164, "Драконий удар", 164, "Красный пояс битвы", 164, "Кровавая луна", 164, "Облачение Круговерти Пустоты", 164, "Оплот древних королей", 164, "Палач Львиного сердца", 164, "Пояс хранителя", 164, "Пылкое неистовство", 164, "Штормовестник", 165, "Пояс глубокой тени", 165, "Пояс природной силы", 165, "Пояс сезона дождей", 165, "Пояс черного орла", 171, "Алхимический камень искупителя", 171, "Алхимический камень стража", 171, "Алхимический камень убийцы", 171, "Алхимический камень чародея", 171, "Трансмутация мглистого алмаза", 197, "Пояс взрыва", 197, "Пояс дальней дороги", 755, "Слеза утопии" },
	[30816] = { 185, "Пряная хлебная запеканка" },
	[30817] = { 185, "Аппетитный кекс", 185, "Вкусный шоколадный торт", 185, "Поминальный хлеб", 185, "Хлеб с пряностями" },
	[31079] = { 755, "Амулет бьющего ключа", 755, "Венец Чародейской мощи", 755, "Венок Зеленого Пламени", 755, "Застывшее око", 755, "Изысканное этерниевое кольцо", 755, "Инфернальное кориевое кольцо", 755, "Кольцо бьющего ключа", 755, "Кольцо из закаленного кория", 755, "Кольцо скованной мощи", 755, "Кориевое кольцо листвы", 755, "Кориевое кольцо льда", 755, "Кориевое кольцо тайной магии", 755, "Кориевое кольцо теней", 755, "Корона морской ведьмы", 755, "Объятия рассвета", 755, "Око ночи", 755, "Оплетенная этерниевая кольчуга", 755, "Подвеска Оттепели", 755, "Подвеска замерзшего пламени", 755, "Подвеска из животворного рубина", 755, "Подвеска края теней", 755, "Подвеска пустой руны", 755, "Подвеска солнечного огня", 755, "Подвеска увядания", 755, "Природный оберег", 755, "Пылающее этерниевое кольцо", 755, "Толстое адамантитовое ожерелье", 755, "Толстое ожерелье из оскверненной стали", 755, "Тяжелое адамантитовое кольцо", 755, "Тяжелое кольцо из оскверненной стали", 755, "Цепь Сумеречной Совы", 755, "Черная жемчужина" },
	[31670] = { 185, "Ребрышки Мок'Натала" },
	[31671] = { 185, "Поджаристый змей" },
	[32227] = { 755, "Блистательная пунцовая шпинель", 755, "Изысканная пунцовая шпинель", 755, "Изящная пунцовая шпинель", 755, "Каплевидная пунцовая шпинель", 755, "Подвеска солнечного огня", 755, "Рельефная пунцовая шпинель", 755, "Руническая пунцовая шпинель", 755, "Статуэтка багровой змейки", 755, "Яркая пунцовая шпинель" },
	[32228] = { 755, "Блестящий неземной сапфир", 755, "Грозовой неземной сапфир", 755, "Искрящийся неземной сапфир", 755, "Подвеска солнечного огня", 755, "Статуэтка неземной черепахи", 755, "Цельный неземной сапфир" },
	[32229] = { 755, "Великий львиный глаз", 755, "Гладкий львиный глаз", 755, "Искристый львиный глаз", 755, "Матовый львиный глаз", 755, "Мистический львиный глаз", 755, "Мягкий львиный глаз", 755, "Прочный львиный глаз", 755, "Сверкающий львиный глаз" },
	[32230] = { 755, "Заряженный аметист Песни Теней", 755, "Изменчивый аметист Песни Теней", 755, "Королевский аметист Песни Теней", 755, "Очищенный аметист Песни Теней", 755, "Сбалансированный аметист Песни Теней", 755, "Светящийся аметист Песни Теней", 755, "Статуэтка пантеры Песни Теней", 755, "Царственный аметист Песни Теней" },
	[32231] = { 755, "Блистающий огнекамень", 755, "Гибельный огнекамень", 755, "Могущественный огнекамень", 755, "Покрытый письменами огнекамень", 755, "Светоносный огнекамень", 755, "Сокрытый огнекамень", 755, "Статуэтка кориевого вепря", 755, "Тревожный огнекамень" },
	[32249] = { 755, "Амулет бьющего ключа", 755, "Зазубренный морской изумруд", 755, "Мощный морской изумруд", 755, "Неизменный морской изумруд", 755, "Ослепительный морской изумруд", 755, "Отверделый морской изумруд", 755, "Светозарный морской изумруд", 755, "Статуэтка морского альбатроса" },
	[32423] = { 202, "Замораживающие гранаты" },
	[32428] = { 164, "Ботфорты кузни погибели", 164, "Латные сапоги кузнеца света", 164, "Наплечники из быстростали", 164, "Наплечники рассветной стали", 164, "Наручи из быстростали", 164, "Наручи рассветной стали", 164, "Тенестальной ремень", 164, "Тенестальные наголенники", 164, "Тенестальные наручи", 164, "Тенестальные сабо", 164, "Утраченные сапоги ремесленника", 165, "Воинский пояс скованных душ", 165, "Гнилостный пояс из шкур вурдалаков", 165, "Кушак искупленной души", 165, "Мокасины искупленной души", 165, "Набедренники искупленной души", 165, "Наголенники скованных душ", 165, "Накулачники искупленной души", 165, "Наплечники живой земли", 165, "Наплечники молниеносного удара", 165, "Наплечники молниеносной реакции", 165, "Наплечные пластины обновленной жизни", 165, "Наручи молниеносного удара", 165, "Наручи обновленной жизни", 165, "Наручи скованных душ", 165, "Наручники живой земли", 165, "Наручники молниеносной реакции", 165, "Опоясок с ножами для снятия шкур", 165, "Поясное хранилище тяжелых игл", 165, "Сапоги скованных душ", 165, "Уплотненный пояс из электрохимеры", 197, "Летний пояс мага-новичка", 197, "Мантия быстрого исцеления", 197, "Мантия сообразительности", 197, "Наручи сообразительности", 197, "Наручи стража духа", 197, "Повязки быстрого исцеления", 197, "Покров силы магии из ветроткани", 197, "Поножи стража духа", 197, "Предел ночи", 197, "Ремень стража духа", 197, "Старообрядческий пояс из шелка", 197, "Туфли стража духа", 197, "Шаль силы духа из редкого шелка", 202, "Активная наручная защита ХМ-52 \"Титан\"", 202, "Наручная маскировка ХТ-92 \"Леший\"", 202, "Наручная электрозащита ХЕ-89 \"Буря\"", 202, "Наручные подавители боли ХМ-51 \"Узурпатор\"", 202, "Наручный инъектор ХЕ-39 \"Водяной\"", 202, "Наручный источник сил ХМ-75 \"Очищение\"", 202, "Наручный сканер слабостей ХТ-27 \"Трепет\"", 202, "Наручный целеуказатель ХЕ-41 \"Раптор\"", 755, "Кольцо полуночного неба", 755, "Наследный камень императора", 755, "Ограненный камень хиджальских гор", 755, "Резонирующее кольцо гнева", 755, "Усиливающее слух кольцо преступника" },
	[32461] = { 202, "Проекционные очки резни" },
	[32472] = { 202, "Очки 'Воздаятель-3000'" },
	[32473] = { 202, "Очки из закаленного кория" },
	[32474] = { 202, "Очки верного удара модель 3.0" },
	[32475] = { 202, "Очки изначальной гармонии" },
	[32476] = { 202, "Иссеченные молниями очки" },
	[32478] = { 202, "Очки квадри-смертельного удара X44" },
	[32479] = { 202, "Исцеляющий рассеиватель теней XT68" },
	[32480] = { 202, "Гипер-увеличивающие лунные очки" },
	[32494] = { 202, "Голографические очки аннигиляции" },
	[32495] = { 202, "Линза могущественного целителя-9000" },
	[33447] = { 171, "Бездонный флакон с лечебным зельем" },
	[33448] = { 171, "Бездонный флакон с зельем маны" },
	[33470] = { 129, "Бинты из ледяной ткани", 129, "Бинты из ледяной ткани Пустоты", 129, "Плотные бинты из ледяной ткани", 197, "Рулон ледяной ткани", 197, "Сеть из ледяной ткани", 202, "Взрывчатая приманка", 202, "Гоблинский планер", 202, "Механическая пелерина претендента", 202, "Механический плащ претендента", 202, "Пружинистая паутинка", 202, "Эластичная подкладка" },
	[33567] = { 165, "Борейская кожа" },
	[33568] = { 165, "Арктические накулачники", 165, "Арктические наплечные пластины", 165, "Арктические перчатки", 165, "Арктические поножи", 165, "Арктические сапоги", 165, "Арктический нагрудник", 165, "Арктический пояс", 165, "Арктический шлем", 165, "Нагрудный доспех жителя льдов", 165, "Нагрудный доспех из обмерзшей чешуи", 165, "Накладки из борейской кожи", 165, "Накулачники жителя льдов", 165, "Наплечники из обмерзшей чешуи", 165, "Наплечные пластины жителя льдов", 165, "Наручи из обмерзшей чешуи", 165, "Нерубские наплечники", 165, "Нерубские наручи", 165, "Нерубские перчатки", 165, "Нерубские поножи", 165, "Нерубские сапоги", 165, "Нерубский нагрудный доспех", 165, "Нерубский пояс", 165, "Нерубский шлем", 165, "Перчатки жителя льдов", 165, "Перчатки из обмерзшей чешуи", 165, "Плащ суровых ветров", 165, "Поножи жителя льдов", 165, "Поножи из обмерзшей чешуи", 165, "Пояс жителя льдов", 165, "Пояс из обмерзшей чешуи", 165, "Сапоги жителя льдов", 165, "Сапоги из обмерзшей чешуи", 165, "Толстая борейская кожа", 165, "Шлем жителя льдов", 165, "Шлем из обмерзшей чешуи", 202, "Механизированные снегозащитные очки" },
	[33823] = { 185, "Зажаренный на открытом огне афиохаракс" },
	[33824] = { 185, "Суп из рыбы-черепа" },
	[34052] = { 197, "Одеяние Мерлина", 202, "Гномские рентгеновские очки", 333, "Иллюзорное волшебное масло", 333, "Иллюзорное масло маны", 333, "Рунический титановый жезл", 333, "Чары для двуручного оружия - проклятие Плети", 333, "Чары для нагрудника - все характеристики VII", 333, "Чары для нагрудника - все характеристики VIII", 333, "Чары для нагрудника - устойчивость II", 333, "Чары для нагрудника - устойчивость III", 333, "Чары для наручей - сила заклинаний III", 333, "Чары для наручей - сила заклинаний IV", 333, "Чары для обуви - живучесть клыкарра", 333, "Чары для обуви - живучесть клыкарра II", 333, "Чары для обуви - штурм II", 333, "Чары для обуви - штурм III", 333, "Чары для оружия - берсерк", 333, "Чары для оружия - берсерк II", 333, "Чары для оружия - дух II", 333, "Чары для оружия - дух III", 333, "Чары для оружия - истребитель великанов", 333, "Чары для оружия - ледорез", 333, "Чары для оружия - ловкость III", 333, "Чары для оружия - ловкость IV", 333, "Чары для оружия - мангуст II", 333, "Чары для оружия - меткость", 333, "Чары для оружия - меткость II", 333, "Чары для оружия - могущество III", 333, "Чары для оружия - могущество IV", 333, "Чары для оружия - оберег", 333, "Чары для оружия - сила заклинаний III", 333, "Чары для оружия - сила заклинаний IV", 333, "Чары для оружия - титановый страж", 333, "Чары для оружия - черная магия", 333, "Чары для оружия - черная магия II", 333, "Чары для перчаток - взрыв II", 333, "Чары для перчаток - крушитель", 333, "Чары для перчаток - крушитель II", 333, "Чары для перчаток - ловкость IV", 333, "Чары для перчаток - ловкость V", 333, "Чары для перчаток - оружейник", 333, "Чары для перчаток - оружейник II", 333, "Чары для плаща - ловкость V", 333, "Чары для плаща - ловкость VI", 333, "Чары для плаща - ткань титанов", 333, "Чары для плаща - ткань титанов II", 333, "Чары для посоха - сила заклинаний II", 333, "Чары для посоха - сила заклинаний III", 333, "Чары для щита - сопротивление II", 333, "Чары для щита - устойчивость II", 755, "Перстень грез" },
	[34053] = { 333, "Чары для плаща - колосс" },
	[34054] = { 164, "Чародейский клинок из титановой стали", 197, "Рулон прочной ледяной ткани", 333, "Иллюзорное волшебное масло", 333, "Иллюзорное масло маны", 333, "Рунический титановый жезл", 333, "Чары для двуручного оружия - проклятие Плети", 333, "Чары для двуручного оружия - резня", 333, "Чары для двуручного оружия - резня II", 333, "Чары для двуручного оружия - свирепость II", 333, "Чары для кольца - выносливость III", 333, "Чары для кольца - сила заклинаний II", 333, "Чары для кольца - штурм I", 333, "Чары для нагрудника - восстановление маны", 333, "Чары для нагрудника - восстановление маны II", 333, "Чары для нагрудника - все характеристики VI", 333, "Чары для нагрудника - защита II", 333, "Чары для нагрудника - защита III", 333, "Чары для нагрудника - здоровье IX", 333, "Чары для нагрудника - мана VII", 333, "Чары для наручей - все характеристики II", 333, "Чары для наручей - все характеристики III", 333, "Чары для наручей - дух VI", 333, "Чары для наручей - дух VII", 333, "Чары для наручей - интеллект II", 333, "Чары для наручей - мастерство", 333, "Чары для наручей - мастерство II", 333, "Чары для наручей - сила заклинаний II", 333, "Чары для наручей - сила заклинаний III", 333, "Чары для наручей - сила заклинаний IV", 333, "Чары для наручей - удар III", 333, "Чары для наручей - штурм II", 333, "Чары для наручей - штурм III", 333, "Чары для обуви - дух III", 333, "Чары для обуви - дух IV", 333, "Чары для обуви - живучесть II", 333, "Чары для обуви - живучесть клыкарра", 333, "Чары для обуви - живучесть клыкарра II", 333, "Чары для обуви - ледопроходец", 333, "Чары для обуви - ледопроходец II", 333, "Чары для обуви - ловкость V", 333, "Чары для обуви - ловкость VI", 333, "Чары для обуви - стойкость II", 333, "Чары для обуви - стойкость III", 333, "Чары для обуви - штурм I", 333, "Чары для оружия - берсерк", 333, "Чары для оружия - берсерк II", 333, "Чары для оружия - вытягивание крови", 333, "Чары для оружия - дух II", 333, "Чары для оружия - дух III", 333, "Чары для оружия - мангуст II", 333, "Чары для оружия - меткость", 333, "Чары для оружия - меткость II", 333, "Чары для оружия - могущество II", 333, "Чары для оружия - могущество III", 333, "Чары для оружия - сила заклинаний II", 333, "Чары для оружия - сила заклинаний III", 333, "Чары для оружия - сила заклинаний IV", 333, "Чары для перчаток - взрыв II", 333, "Чары для перчаток - крушитель", 333, "Чары для перчаток - крушитель II", 333, "Чары для перчаток - мастерство", 333, "Чары для перчаток - мастерство II", 333, "Чары для перчаток - рыболов", 333, "Чары для перчаток - сила заклинаний II", 333, "Чары для перчаток - сила заклинаний III", 333, "Чары для перчаток - штурм II", 333, "Чары для плаща - ловкость IV", 333, "Чары для плаща - ловкость V", 333, "Чары для плаща - ловкость VI", 333, "Чары для плаща - могучая броня", 333, "Чары для плаща - могучая броня II", 333, "Чары для плаща - пронзающие заклинания I", 333, "Чары для плаща - пронзающие заклинания II", 333, "Чары для плаща - скорость I", 333, "Чары для плаща - скорость II", 333, "Чары для плаща - скорость III", 333, "Чары для плаща - сопротивление V", 333, "Чары для плаща - сопротивление магии льда", 333, "Чары для плаща - сопротивление силам природы II", 333, "Чары для плаща - сопротивление тайной магии II", 333, "Чары для плаща - сопротивление темной магии III", 333, "Чары для плаща - теневая броня", 333, "Чары для плаща - ткань титанов", 333, "Чары для плаща - ткань титанов II", 333, "Чары для посоха - сила заклинаний I", 333, "Чары для посоха - сила заклинаний II", 333, "Чары для посоха - сила заклинаний III", 333, "Чары для щита - блок III", 333, "Чары для щита - выносливость VI", 333, "Чары для щита - защита", 333, "Чары для щита - защита II", 333, "Чары для щита - интеллект II", 333, "Чары для щита - интеллект III", 755, "Зачарованная жемчужина", 755, "Зачарованная слеза", 755, "Слеза забвения", 755, "Слеза кошмаров", 755, "Слеза миража" },
	[34055] = { 165, "Заколдованная нерубская кираса", 333, "Рунический титановый жезл", 333, "Чары для двуручного оружия - резня", 333, "Чары для двуручного оружия - резня II", 333, "Чары для двуручного оружия - свирепость II", 333, "Чары для кольца - выносливость III", 333, "Чары для кольца - сила заклинаний II", 333, "Чары для кольца - штурм I", 333, "Чары для нагрудника - восстановление маны", 333, "Чары для нагрудника - восстановление маны II", 333, "Чары для нагрудника - здоровье IX", 333, "Чары для нагрудника - здоровье VIII", 333, "Чары для нагрудника - устойчивость II", 333, "Чары для нагрудника - устойчивость III", 333, "Чары для наручей - все характеристики II", 333, "Чары для наручей - все характеристики III", 333, "Чары для наручей - выносливость VI", 333, "Чары для наручей - выносливость VII", 333, "Чары для наручей - дух VI", 333, "Чары для наручей - дух VII", 333, "Чары для наручей - мастерство", 333, "Чары для наручей - мастерство II", 333, "Чары для наручей - сила заклинаний III", 333, "Чары для наручей - сила заклинаний IV", 333, "Чары для наручей - штурм II", 333, "Чары для наручей - штурм III", 333, "Чары для обуви - дух III", 333, "Чары для обуви - дух IV", 333, "Чары для обуви - живучесть II", 333, "Чары для обуви - живучесть клыкарра", 333, "Чары для обуви - живучесть клыкарра II", 333, "Чары для обуви - ловкость V", 333, "Чары для обуви - ловкость VI", 333, "Чары для обуви - штурм II", 333, "Чары для обуви - штурм III", 333, "Чары для оружия - Отведение удара", 333, "Чары для оружия - берсерк", 333, "Чары для оружия - берсерк II", 333, "Чары для оружия - истребитель великанов", 333, "Чары для оружия - меткость", 333, "Чары для оружия - меткость II", 333, "Чары для оружия - могущество III", 333, "Чары для оружия - могущество IV", 333, "Чары для оружия - сила заклинаний II", 333, "Чары для оружия - черная магия", 333, "Чары для оружия - черная магия II", 333, "Чары для перчаток - крушитель", 333, "Чары для перчаток - крушитель II", 333, "Чары для перчаток - ловкость IV", 333, "Чары для перчаток - ловкость V", 333, "Чары для перчаток - собиратель", 333, "Чары для перчаток - точность", 333, "Чары для перчаток - штурм II", 333, "Чары для плаща - колосс", 333, "Чары для плаща - ловкость V", 333, "Чары для плаща - ловкость VI", 333, "Чары для плаща - могучая броня", 333, "Чары для плаща - могучая броня II", 333, "Чары для плаща - мудрость", 333, "Чары для плаща - мудрость II", 333, "Чары для плаща - скорость II", 333, "Чары для плаща - скорость III", 333, "Чары для плаща - сопротивление V", 333, "Чары для плаща - сопротивление магии льда", 333, "Чары для плаща - сопротивление огню IV", 333, "Чары для плаща - сопротивление силам природы II", 333, "Чары для посоха - сила заклинаний I", 333, "Чары для щита - блок III" },
	[34056] = { 333, "Чары для нагрудника - все характеристики VI", 333, "Чары для наручей - сила заклинаний II", 333, "Чары для обуви - стойкость II", 333, "Чары для обуви - стойкость III", 333, "Чары для обуви - штурм I", 333, "Чары для оружия - могущество II", 333, "Чары для перчаток - сила заклинаний II", 333, "Чары для перчаток - сила заклинаний III", 333, "Чары для плаща - сопротивление темной магии III", 333, "Чары для щита - устойчивость II" },
	[34057] = { 165, "Черные хитиновые наручи", 333, "Иллюзорное волшебное масло", 333, "Иллюзорное масло маны", 333, "Обледенение Бездны", 333, "Чары для двуручного оружия - резня", 333, "Чары для двуручного оружия - резня II", 333, "Чары для нагрудника - все характеристики VII", 333, "Чары для нагрудника - все характеристики VIII", 333, "Чары для наручей - выносливость VI", 333, "Чары для наручей - выносливость VII", 333, "Чары для оружия - Отведение удара", 333, "Чары для оружия - берсерк", 333, "Чары для оружия - берсерк II", 333, "Чары для оружия - вытягивание крови", 333, "Чары для оружия - мангуст II", 333, "Чары для оружия - меткость", 333, "Чары для оружия - меткость II", 333, "Чары для оружия - могущество III", 333, "Чары для оружия - могущество IV", 333, "Чары для оружия - сила заклинаний III", 333, "Чары для оружия - сила заклинаний IV", 333, "Чары для оружия - черная магия", 333, "Чары для оружия - черная магия II", 333, "Чары для плаща - мудрость", 333, "Чары для плаща - мудрость II", 333, "Чары для плаща - теневая броня", 333, "Чары для посоха - сила заклинаний II", 333, "Чары для посоха - сила заклинаний III" },
	[34113] = { 202, "Дживс" },
	[34249] = { 202, "Турбоветролет" },
	[34412] = { 185, "Горячий яблочный сидр" },
	[34664] = { 164, "Кулачные перчатки из закаленного кория", 164, "Рукавицы Солнечного благословения", 165, "Кожаные рукавицы Солнца", 165, "Перчатки вечного сумрака", 165, "Пронизанные солнцем чешуйчатые перчатки", 165, "Стрелецкие перчатки Феникса", 197, "Перчатки вечного света", 197, "Повязки солнечного огня", 755, "Кольцо бьющего ключа", 755, "Кольцо из закаленного кория", 755, "Кольцо скованной мощи" },
	[34736] = { 185, "'Пир на весь мир'", 185, "Кушанье из мамонта", 185, "Мамонтятина не первой свежести", 185, "Пир для великанов", 185, "Пряное лакомство из мамонта", 185, "Пряное лакомство из мамонта c приправами", 185, "Сытное кушанье из мамонта", 185, "Сытное кушанье из мамонта с приправами" },
	[35128] = { 164, "Кулачные перчатки из закаленного кория", 164, "Рукавицы Солнечного благословения", 202, "Очки из закаленного кория", 755, "Колье из закаленного кория", 755, "Кольцо бьющего ключа", 755, "Кольцо из закаленного кория", 755, "Кольцо скованной мощи" },
	[35562] = { 185, "Кебаб из медвежатины на углях", 185, "Сочная котлета из медвежатины" },
	[35622] = { 164, "Извечная поясная пряжка", 164, "Изысканное саронитовое наплечье", 164, "Изысканное саронитовое наплечье претендента", 164, "Изысканный саронитовый воинский пояс", 164, "Изысканный саронитовый воинский пояс претендента", 164, "Костомолы леденящего ада", 164, "Наголенники праведности", 164, "Нагрудный доспех ледяной погибели", 164, "Ремень ледяной погибели", 164, "Рукавицы праведности", 164, "Сапоги ледяной погибели", 164, "Саронитовое наплечье свирепости", 164, "Саронитовое наплечье свирепости претендента", 164, "Саронитовый воинский пояс свирепости", 164, "Саронитовый воинский пояс свирепости претендента", 165, "Ботфорты загробника", 165, "Высокие ботинки штормового укрытия", 165, "Высокие ботинки штормового укрытия претендента", 165, "Захваты штормового укрытия", 165, "Захваты штормового укрытия претендента", 165, "Кираса загробника", 165, "Кираса рыцаря из чешуи дракона", 165, "Корона штормового укрытия", 165, "Корона штормового укрытия претендента", 165, "Набедренники земледарения", 165, "Набедренники тяжелых увечий", 165, "Набедренники штормового укрытия", 165, "Набедренники штормового укрытия претендента", 165, "Наголовник угрюмости", 165, "Наголовник угрюмости претендента", 165, "Нагрудный доспех из ледяной чешуи", 165, "Нагрудный доспех угрюмости", 165, "Нагрудный доспех угрюмости претендента", 165, "Накулачники штормового укрытия", 165, "Накулачники штормового укрытия претендента", 165, "Наплеч угрюмости", 165, "Наплеч угрюмости претендента", 165, "Наплечники штормового укрытия", 165, "Наплечники штормового укрытия претендента", 165, "Наручи рыцаря из чешуи дракона", 165, "Наручи тяжелых увечий", 165, "Наручи угрюмости", 165, "Наручи угрюмости претендента", 165, "Повязки угрюмости", 165, "Повязки угрюмости претендента", 165, "Поножи ветроруба", 165, "Поножи угрюмости", 165, "Поножи угрюмости претендента", 165, "Пояс из ледяной чешуи", 165, "Пояс угрюмости", 165, "Пояс угрюмости претендента", 165, "Пояс штормового укрытия", 165, "Пояс штормового укрытия претендента", 165, "Рукавицы морского прибоя", 165, "Сапоги ветроруба", 165, "Сапоги земледарения", 165, "Сапоги из ледяной чешуи", 165, "Сапоги угрюмости", 165, "Сапоги угрюмости претендента", 165, "Снежные сапоги", 165, "Снежный жилет", 165, "Снежный шнурованный ремень", 165, "Хауберк штормового укрытия", 165, "Хауберк штормового укрытия претендента", 171, "Трансмутация: извечная вода в воздух", 171, "Трансмутация: извечная вода в огонь", 171, "Трансмутация: извечная сила", 197, "Ледовое одеяние", 197, "Ледовые туфли", 197, "Ледовый боевой пояс", 197, "Тончайший плащ", 202, "Бронированный боевой дробовик", 202, "Генератор червоточины: Нордскол", 202, "Гномский генератор молний", 202, "Межпространственный тоннель: К-3", 202, "Снегозащитные очки острого зрения", 333, "Чары для плаща - сопротивление огню IV", 755, "Кольцо хладных слез", 755, "Титановое кольцо ледяного стража", 755, "Титановое кольцо чародейского удара", 755, "Титановое ожерелье чародейского удара" },
	[35623] = { 164, "Изысканные саронитовые наручи", 164, "Изысканные саронитовые наручи претендента", 164, "Изысканные саронитовые ножные латы", 164, "Изысканные саронитовые ножные латы претендента", 164, "Ножные латы из чистой стали", 164, "Саронитовые наручи свирепости", 164, "Саронитовые наручи свирепости претендента", 164, "Саронитовые ножные латы свирепости", 164, "Саронитовые ножные латы свирепости претендента", 165, "Ботфорты потрошителя", 165, "Ботфорты претендента", 165, "Воинский пояс потрошителя", 165, "Воинский пояс претендента", 165, "Заколдованная нерубская кираса", 165, "Заряженные молнией поножи", 165, "Кираса рассекающего удара", 165, "Маска потрошителя", 165, "Маска потрошителя претендента", 165, "Набедренники потрошителя", 165, "Набедренники претендента", 165, "Набедренники тяжелых увечий", 165, "Нагрудный доспех потрошителя", 165, "Нагрудный доспех претендента", 165, "Наплечные пластины потрошителя", 165, "Наплечные пластины претендента", 165, "Наплечные щитки быстрой стрелы", 165, "Наплечные щитки быстрой стрелы претендента", 165, "Наручи быстрой стрелы", 165, "Наручи быстрой стрелы претендента", 165, "Наручи отражения", 165, "Наручи тяжелых увечий", 165, "Наручники потрошителя", 165, "Наручники претендента", 165, "Поножи быстрой стрелы", 165, "Поножи быстрой стрелы претендента", 165, "Поножи ветроруба", 165, "Поножи интуитивного боя", 165, "Пояс быстрой стрелы", 165, "Пояс быстрой стрелы претендента", 165, "Рукавицы быстрой стрелы", 165, "Рукавицы быстрой стрелы претендента", 165, "Рукавицы потрошителя", 165, "Рукавицы претендента", 165, "Сапоги быстрой стрелы", 165, "Сапоги быстрой стрелы претендента", 165, "Сапоги ветроруба", 165, "Сапоги духа земли", 165, "Хауберк быстрой стрелы", 165, "Хауберк быстрой стрелы претендента", 165, "Шлем быстрой стрелы", 165, "Шлем быстрой стрелы претендента", 171, "Трансмутация алмаза небесного сияния", 171, "Трансмутация: величественный циркон", 171, "Трансмутация: извечная сила", 171, "Трансмутация: извечный воздух в воду", 171, "Трансмутация: извечный воздух в землю", 202, "Бронированный боевой дробовик", 202, "Генератор червоточины: Нордскол", 202, "Гномский генератор молний", 202, "МЯЛЛ-И", 202, "Межпространственный тоннель: К-3", 202, "Спектральный выявитель слабости", 202, "Электропотоковое улучшение зрения", 333, "Чары для оружия - ловкость III", 333, "Чары для оружия - ловкость IV", 755, "Кольцо огненного ветра", 755, "Титановое колье сотрясения", 755, "Титановое кольцо чародейского удара" },
	[35624] = { 164, "Гнездо в наручах", 164, "Защитники жизни", 164, "Извечная поясная пряжка", 164, "Изысканный саронитовый хауберк", 164, "Изысканный саронитовый хауберк претендента", 164, "Сапоги королевского бунта", 164, "Саронитовый хауберк свирепости", 164, "Саронитовый хауберк свирепости претендента", 164, "Столпы мощи", 164, "Устрашающие боевые рукавицы", 164, "Устрашающие ножные латы", 165, "Земляные накладки для поножей", 165, "Набедренники из осколков драконьих костей", 165, "Несносимые ботфорты", 165, "Прочные земляные накладки для поножей", 171, "Трансмутация: извечная земля в воздух", 171, "Трансмутация: извечная земля в тьму", 171, "Трансмутация: извечная сила", 186, "Выплавка титановой стали", 197, "Пелерина ледяного стража", 202, "Бронированные титановые очки", 202, "Нерушимые усилители исцеления", 202, "Укрепленный решетчатый каркас", 333, "Чары для нагрудника - защита II", 333, "Чары для нагрудника - защита III", 333, "Чары для перчаток - оружейник", 333, "Чары для перчаток - оружейник II", 333, "Чары для плаща - сопротивление тайной магии II", 333, "Чары для щита - блок III", 333, "Чары для щита - защита", 333, "Чары для щита - защита II", 755, "Кольцо камнестража", 755, "Кольцо силы земли", 755, "Кольцо темного могущества", 755, "Кольцо тени земли", 755, "Нефритовое кольцо истребления", 755, "Нефритовый кинжал-подвеска", 755, "Ожерелье Кровавого солнца", 755, "Титановая цепь стража земли", 755, "Титановое кольцо стража земли" },
	[35625] = { 164, "Кираса Белого Рыцаря", 164, "Кираса Кузни Солнца", 164, "Наручи Кузни Солнца", 165, "Благословенные кенарийские сапоги", 165, "Боевые наручи лунной тени", 165, "Бриджи одичавшей природы", 165, "Кираса рыцаря из чешуи дракона", 165, "Набедренники земледарения", 165, "Одеяния лунного затмения", 165, "Сапоги земледарения", 171, "Переменчивый алхимический камень", 171, "Переменчивый алхимический камень претендента", 171, "Трансмутация: извечная жизнь в огонь", 171, "Трансмутация: извечная жизнь в тьму", 171, "Трансмутация: царский янтарь", 197, "Лунный тюль", 197, "Прочная сверкающая чародейская нить", 197, "Сверкающая чародейская нить", 197, "Тончайший плащ", 202, "Очки с зелеными стеклами", 333, "Иллюзорное масло маны", 333, "Чары для оружия - оберег", 333, "Чары для плаща - сопротивление темной магии III", 755, "Титановая цепь стража земли", 755, "Титановое кольцо стража земли", 773, "Карта Новолуния: Север", 773, "Сумеречный фолиант" },
	[35627] = { 164, "Гнездо в перчатках", 164, "Извечная поясная пряжка", 164, "Изысканные саронитовые сапоги", 164, "Изысканные саронитовые сапоги претендента", 164, "Изысканный саронитовый шлем", 164, "Изысканный саронитовый шлем претендента", 164, "Колчедановый шип для щита", 164, "Ножные латы мучительной смерти", 164, "Саронитовые сапоги свирепости", 164, "Саронитовые сапоги свирепости претендента", 164, "Саронитовый шлем свирепости", 164, "Саронитовый шлем свирепости претендента", 164, "Титановая обшивка", 165, "Капюшон ночного штурма", 165, "Наручи быстрой смерти", 165, "Опаленный смертью пояс", 165, "Панцирь рыцарского проклятья", 165, "Плащ ледяного убийцы", 165, "Поножи клинка", 165, "Ремень ночного штурма", 165, "Сапоги надвигающейся смерти", 165, "Сапоги тишины", 165, "Тролльский тканый наплеч", 165, "Тролльский тканый ремень", 171, "Трансмутация: аметрин", 171, "Трансмутация: извечная тьма в жизнь", 171, "Трансмутация: извечная тьма в землю", 171, "Трансмутация: страхолит", 186, "Выплавка титановой стали", 197, "Иссиня-черная ткань", 197, "Плащ багрового снега", 197, "Плащ смертельной стужи", 202, "Генератор червоточины: Нордскол", 202, "Затуманивающие взор очки", 202, "Механизированные снегозащитные очки", 202, "Эрнестуэй 4000", 333, "Иллюзорное волшебное масло", 333, "Чары для плаща - колосс", 333, "Чары для плаща - сопротивление силам природы II", 755, "Кольцо алых теней", 755, "Кольцо темного могущества", 755, "Титановое кольцо сотрясения", 755, "Титановое ожерелье чародейского удара", 773, "Книга ритуалов новолуния" },
	[35948] = { 185, "Кунгалуш" },
	[35949] = { 185, "Кунгалуш" },
	[36766] = { 755, "Яркий Глаз химеры" },
	[36767] = { 755, "Цельный Глаз химеры" },
	[36782] = { 185, "Даларанская похлебка из моллюсков", 185, "Даларанская похлебка из моллюсков со специями", 185, "Испорченные моллюски" },
	[36783] = { 197, "Мистические ледотканые наплечники", 197, "Мистические ледотканые напульсники", 197, "Мистическое ледотканое одеяние", 197, "Плащ заледеневших душ", 197, "Плащ луны", 755, "Зачарованная жемчужина", 755, "Кольцо хладных слез" },
	[36784] = { 197, "Плащ смертельной стужи", 197, "Тончайший плащ", 755, "Зачарованная слеза" },
	[36860] = { 164, "Изысканные саронитовые рукавицы", 164, "Изысканные саронитовые рукавицы претендента", 164, "Костомолы леденящего ада", 164, "Нагрудный доспех ледяной погибели", 164, "Наручники отмщения", 164, "Ремень ледяной погибели", 164, "Сапоги ледяной погибели", 164, "Саронитовые рукавицы свирепости", 164, "Саронитовые рукавицы свирепости претендента", 164, "Шлем властности", 165, "Нагрудный доспех из ледяной чешуи", 165, "Наплеч ожесточения", 165, "Плащ ледяного убийцы", 165, "Пояс из ледяной чешуи", 165, "Сапоги из ледяной чешуи", 165, "Снежные сапоги", 165, "Снежный жилет", 165, "Снежный шнурованный ремень", 165, "Тролльский тканый наплеч", 165, "Тролльский тканый ремень", 171, "Трансмутация: алмаз землеправителя", 171, "Трансмутация: багровый рубин", 171, "Трансмутация: извечная сила", 171, "Трансмутация: извечный огонь в воду", 171, "Трансмутация: извечный огонь в жизнь", 186, "Выплавка титановой стали", 197, "Колдовская ткань", 197, "Ледовое одеяние", 197, "Ледовые туфли", 197, "Ледовый боевой пояс", 197, "Плащ смертельной стужи", 197, "Прочная сапфировая чародейская нить", 197, "Сапфировая чародейская нить", 202, "Генератор червоточины: Нордскол", 202, "Заряженные титановые очки", 202, "Межпространственный тоннель: К-3", 202, "Эрнестуэй 4000", 333, "Чары для оружия - ледорез", 333, "Чары для плаща - сопротивление магии льда", 755, "Кольцо огненного ветра", 755, "Титановая печатка свирепости", 755, "Титановое колье сотрясения", 755, "Титановое кольцо ледяного стража", 755, "Титановое кольцо свирепости", 755, "Титановое кольцо сотрясения" },
	[36901] = { 171, "Зелье ночных кошмаров", 171, "Зелье сумасшедшего алхимика", 171, "Исследование трав Нордскола", 171, "Мощный эликсир крови волшебника", 171, "Мощный эликсир ловкости", 171, "Мощный эликсир стойкости", 171, "Настой бесконечной ярости", 171, "Настой крепости", 171, "Настой силы титана", 171, "Переменчивый алхимический камень", 171, "Переменчивый алхимический камень претендента", 171, "Рунический флакон с зельем маны", 171, "Рунический флакон с лечебным зельем", 171, "Слабый настой крепости", 171, "Флакон с бодрящим лечебным зельем", 171, "Эликсир гнева", 171, "Эликсир мастерства", 171, "Эликсир силы заклинаний", 171, "Эликсир смертельных ударов" },
	[36903] = { 171, "Зелье быстроты", 171, "Исследование трав Нордскола", 171, "Могущественный алхимический камень", 171, "Могущественный алхимический камень претендента", 171, "Мощный эликсир ловкости", 171, "Эликсир мастерства", 171, "Эликсир смертельных ударов" },
	[36904] = { 171, "Могущественный алхимический камень", 171, "Могущественный алхимический камень претендента", 171, "Мощный эликсир силы", 171, "Эликсир меткости", 171, "Эликсир пробивания брони", 171, "Эликсир силы заклинаний" },
	[36905] = { 171, "Зелье дикой магии", 171, "Мощное зелье омоложения", 171, "Мощный эликсир крови волшебника", 171, "Настой бесконечной ярости", 171, "Настой драконьего разума", 171, "Настой каменной крови", 171, "Настой ледяного змея", 171, "Настой силы титана", 171, "Настой стальной кожи", 171, "Рунический флакон с зельем маны" },
	[36906] = { 171, "Зелье адреналина", 171, "Зелье несокрушимости", 171, "Мощный эликсир защиты", 171, "Настой драконьего разума", 171, "Настой ледяного змея", 171, "Настой текущей воды", 171, "Настой чистого колдунства", 171, "Охранный эликсир", 171, "Рунический флакон с лечебным зельем" },
	[36907] = { 171, "Зелье ночных кошмаров", 171, "Исследование трав Нордскола", 171, "Мощное зелье омоложения", 171, "Мощный эликсир разума", 171, "Флакон с ледяным зельем маны", 171, "Эликсир духа", 171, "Эликсир меткости" },
	[36908] = { 171, "Могущественный алхимический камень", 171, "Могущественный алхимический камень претендента", 171, "Настой бесконечной ярости", 171, "Настой драконьего разума", 171, "Настой каменной крови", 171, "Настой ледяного змея", 171, "Настой севера", 171, "Настой силы титана", 171, "Настой стальной кожи", 171, "Настой текущей воды", 171, "Настой чистого колдунства", 171, "Несокрушимый алхимический камень", 171, "Несокрушимый алхимический камень претендента", 171, "Переменчивый алхимический камень", 171, "Переменчивый алхимический камень претендента", 197, "Изумрудный вьюк" },
	[36909] = { 186, "Выплавка кобальта" },
	[36910] = { 186, "Выплавка титана" },
	[36912] = { 186, "Выплавка саронита" },
	[36913] = { 164, "Ботфорты кузни погибели", 164, "Бригантина завоевания", 164, "Булава стража из титановой стали", 164, "Гнездо в наручах", 164, "Гнездо в перчатках", 164, "Деревянная рапира саронитовой справедливости", 164, "Закаленная саронитовая кираса", 164, "Закаленные сапоги из титановой стали", 164, "Закаленные саронитовые наплечники", 164, "Закаленные саронитовые наручи", 164, "Закаленные саронитовые ножные латы", 164, "Закаленные саронитовые рукавицы", 164, "Закаленные саронитовые сапоги", 164, "Закаленный саронитовый пояс", 164, "Закаленный саронитовый шлем", 164, "Закаленный шлем из титановой стали", 164, "Заточенный кобальтовый колун", 164, "Извечная поясная пряжка", 164, "Изысканное саронитовое наплечье", 164, "Изысканное саронитовое наплечье претендента", 164, "Изысканные саронитовые наручи", 164, "Изысканные саронитовые наручи претендента", 164, "Изысканные саронитовые ножные латы", 164, "Изысканные саронитовые ножные латы претендента", 164, "Изысканные саронитовые рукавицы", 164, "Изысканные саронитовые рукавицы претендента", 164, "Изысканные саронитовые сапоги", 164, "Изысканные саронитовые сапоги претендента", 164, "Изысканный саронитовый воинский пояс", 164, "Изысканный саронитовый воинский пояс претендента", 164, "Изысканный саронитовый хауберк", 164, "Изысканный саронитовый хауберк претендента", 164, "Изысканный саронитовый шлем", 164, "Изысканный саронитовый шлем претендента", 164, "Кобальтовый тесак свирепости", 164, "Колчедановая цепь для оружия", 164, "Костекрушитель из титановой стали", 164, "Наголенники праведности", 164, "Нагрудный доспех ледяной погибели", 164, "Наручники отмщения", 164, "Ножные латы завоевания", 164, "Осадный щит из титановой стали", 164, "Пронзатель из титановой стали", 164, "Проржавевшее саронитовое лезвие", 164, "Проржавевший саронитовый изранитель", 164, "Разрушитель из титановой стали", 164, "Ремень ледяной погибели", 164, "Рукавицы праведности", 164, "Сапоги ледяной погибели", 164, "Саронитовая ударная палица ярости", 164, "Саронитовое наплечье свирепости", 164, "Саронитовое наплечье свирепости претендента", 164, "Саронитовые мечеломы", 164, "Саронитовые наручи свирепости", 164, "Саронитовые наручи свирепости претендента", 164, "Саронитовые ножные латы свирепости", 164, "Саронитовые ножные латы свирепости претендента", 164, "Саронитовые рукавицы свирепости", 164, "Саронитовые рукавицы свирепости претендента", 164, "Саронитовые сапоги свирепости", 164, "Саронитовые сапоги свирепости претендента", 164, "Саронитовый воинский пояс свирепости", 164, "Саронитовый воинский пояс свирепости претендента", 164, "Саронитовый защитник", 164, "Саронитовый мозголом", 164, "Саронитовый нож", 164, "Саронитовый оплот", 164, "Саронитовый разбойничий кинжал", 164, "Саронитовый страж", 164, "Саронитовый хауберк свирепости", 164, "Саронитовый хауберк свирепости претендента", 164, "Саронитовый чародейский клинок", 164, "Саронитовый шлем свирепости", 164, "Саронитовый шлем свирепости претендента", 164, "Сверкающая саронитовая кираса", 164, "Сверкающее саронитовое наплечье", 164, "Сверкающие сапоги из титановой стали", 164, "Сверкающие саронитовые наручи", 164, "Сверкающие саронитовые ножные латы", 164, "Сверкающие саронитовые рукавицы", 164, "Сверкающие саронитовые сапоги", 164, "Сверкающий саронитовый пояс", 164, "Сверкающий саронитовый шлем", 164, "Сверкающий шлем из титановой стали", 164, "Смертоносный саронитовый кортик", 164, "Титановая отмычка", 164, "Титановая цепь для оружия", 164, "Титановый жезл", 164, "Титановый шип для щита", 164, "Устрашающие боевые рукавицы", 164, "Устрашающие ножные латы", 164, "Утраченные сапоги ремесленника", 164, "Шипастые сапоги из титановой стали", 164, "Шипастый шлем из титановой стали", 164, "Шлем властности", 171, "Трансмутация: титан", 202, "Активная наручная защита ХМ-52 \"Титан\"", 202, "Армированные биооптические очки бойца", 202, "Бронированный боевой дробовик", 202, "Гиперскоростные ускорители", 202, "Гномский армейский нож", 202, "Гномский генератор молний", 202, "Гоблинский лучевой трансформатор", 202, "Детали для набора инъекций маны", 202, "Детали для набора лечебных инъекций", 202, "Комплект для сборки Хламобота", 202, "МЯЛЛ-И", 202, "Мамонтобои", 202, "Механизированные снегозащитные очки", 202, "Механическая пелерина претендента", 202, "Механический плащ претендента", 202, "Нарукавная зажигательная ракетница", 202, "Наручная электрозащита ХЕ-89 \"Буря\"", 202, "Наручные подавители боли ХМ-51 \"Узурпатор\"", 202, "Наручный инъектор ХЕ-39 \"Водяной\"", 202, "Наручный источник сил ХМ-75 \"Очищение\"", 202, "Наручный целеуказатель ХЕ-41 \"Раптор\"", 202, "Огнестрел модели 'С'", 202, "Острейшая саронитовая амуниция", 202, "Прицел 'Пронзатель сердец'", 202, "Сверхмощный заряд термической саперной взрывчатки", 202, "Статические гиперускорители", 202, "Титановый ящик с инструментами", 202, "Транслятор нервных импульсов", 202, "Угрозодетектор R19", 202, "Укрепленный решетчатый каркас", 202, "Ящик бомб" },
	[36916] = { 164, "Выверенный сюрикен", 164, "Закаленная саронитовая кираса", 164, "Закаленные саронитовые ножные латы", 164, "Закаленные саронитовые сапоги", 164, "Закаленный саронитовый пояс", 164, "Заточенный кобальтовый колун", 164, "Зубчатая кобальтовая секира", 164, "Кобальтовая отмычка", 164, "Кобальтовые наплечники", 164, "Кобальтовые наручи", 164, "Кобальтовые ножные латы", 164, "Кобальтовые рукавицы", 164, "Кобальтовые сапоги", 164, "Кобальтовый нагрудник", 164, "Кобальтовый пояс", 164, "Кобальтовый тесак свирепости", 164, "Кобальтовый треугольный щит", 164, "Кобальтовый шлем", 164, "Кобальтодробитель", 164, "Кованый кобальтовый клеймор", 164, "Латные сапоги кузнеца света", 164, "Прочный кобальтовый быстрый клинок", 164, "Рогатый кобальтовый шлем", 164, "Саронитовый защитник", 164, "Саронитовый разбойничий кинжал", 164, "Саронитовый страж", 164, "Сверкающие саронитовые наручи", 164, "Сверкающие саронитовые ножные латы", 164, "Сверкающие саронитовые рукавицы", 164, "Сверкающий саронитовый пояс", 164, "Усиленные кобальтовые наплечники", 164, "Усиленные кобальтовые ножные латы", 164, "Усиленный кобальтовый нагрудник", 164, "Усиленный кобальтовый шлем", 164, "Шипастые кобальтовые наплечники", 164, "Шипастые кобальтовые наручи", 164, "Шипастые кобальтовые ножные латы", 164, "Шипастые кобальтовые рукавицы", 164, "Шипастые кобальтовые сапоги", 164, "Шипастый кобальтовый нагрудник", 164, "Шипастый кобальтовый пояс", 164, "Шипастый кобальтовый шлем", 202, "Армированные биооптические очки целителя", 202, "Заостренная кирка", 202, "Кирка-молот", 202, "Наременные осколочные бомбы", 202, "Неустойчивый детонатор", 202, "Перегруженный конденсатор", 202, "Пригоршня кобальтовых болтов", 202, "Труба из ледяной стали" },
	[36917] = { 171, "Трансмутация алмаза небесного сияния", 755, "Блистательный кровавый камень", 755, "Изысканный кровавый камень", 755, "Изящный кровавый камень", 755, "Кольцо кровавого камня", 755, "Ожерелье Кровавого солнца", 755, "Растрескавшийся кровавый камень", 755, "Рельефный кровавый камень", 755, "Рунический кровавый камень", 755, "Яркий кровавый камень", 755, "Ясный кровавый камень" },
	[36918] = { 171, "Трансмутация: багровый рубин", 202, "Затуманивающие взор очки", 202, "Спектральный выявитель слабости", 333, "Чары для оружия - вытягивание крови", 755, "Алый перстень", 755, "Алый перстень претендента", 755, "Блистательный алый рубин", 755, "Изумрудный кабан", 755, "Изысканный алый рубин", 755, "Изящный алый рубин", 755, "Кольцо алых теней", 755, "Растрескавшийся алый рубин", 755, "Рельефный алый рубин", 755, "Рубиновый заяц", 755, "Рунический алый рубин", 755, "Яркий алый рубин", 755, "Ясный алый рубин" },
	[36919] = { 197, "Наручи волшебника с самоцветами", 755, "Блистательный багровый рубин", 755, "Изысканный багровый рубин", 755, "Изящный багровый рубин", 755, "Непоколебимый багровый рубин", 755, "Растрескавшийся багровый рубин", 755, "Рельефный багровый рубин", 755, "Рунический багровый рубин", 755, "Яркий багровый рубин", 755, "Ясный багровый рубин" },
	[36920] = { 202, "Набор для снятия ограничителя", 202, "Солнечный прицел", 755, "Гладкий солнечный хрусталь", 755, "Кольцо Солнечного Камня", 755, "Матовый солнечный хрусталь", 755, "Мистический солнечный хрусталь", 755, "Мягкий солнечный хрусталь", 755, "Ожерелье Кровавого солнца", 755, "Прочный солнечный хрусталь", 755, "Сверкающий солнечный хрусталь" },
	[36921] = { 171, "Трансмутация: царский янтарь", 202, "Набор для снятия ограничителя", 202, "Солнечный прицел", 202, "Электропотоковое улучшение зрения", 755, "Гладкое сияние осени", 755, "Матовое сияние осени", 755, "Мистическое сияние осени", 755, "Мягкое сияние осени", 755, "Прочное сияние осени", 755, "Рубиновый заяц", 755, "Сверкающее сияние осени" },
	[36922] = { 197, "Королевское одеяние из лунного тюля", 202, "Дживс", 755, "Гладкий царский янтарь", 755, "Матовый царский янтарь", 755, "Мистический царский янтарь", 755, "Мягкий царский янтарь", 755, "Прочный царский янтарь", 755, "Сверкающий царский янтарь", 755, "Стойкий царский янтарь" },
	[36923] = { 171, "Трансмутация алмаза небесного сияния", 755, "Амулет с кристаллом кальцедония", 755, "Блестящий кальцедоний", 755, "Грозовой кальцедоний", 755, "Искрящийся кальцедоний", 755, "Ледяная призма", 755, "Ожерелье Кровавого солнца", 755, "Цельный кальцедоний" },
	[36924] = { 171, "Трансмутация: величественный циркон", 202, "Бронированные титановые очки", 755, "Амулет из небесного сапфира", 755, "Амулет из небесного сапфира претендента", 755, "Блестящий небесный сапфир", 755, "Грозовой небесный сапфир", 755, "Искрящийся небесный сапфир", 755, "Сапфировая сова", 755, "Цельный небесный сапфир" },
	[36925] = { 164, "Кираса Белого Рыцаря", 197, "Наручи волшебника с самоцветами", 755, "Блестящий Глаз химеры", 755, "Блестящий величественный циркон", 755, "Блистательный Глаз химеры", 755, "Гладкий Глаз химеры", 755, "Грозовой Глаз химеры", 755, "Грозовой величественный циркон", 755, "Изысканный Глаз химеры", 755, "Изящный Глаз химеры", 755, "Искрящийся Глаз химеры", 755, "Искрящийся величественный циркон", 755, "Матовый Глаз химеры", 755, "Мистический Глаз химеры", 755, "Мягкий Глаз химеры", 755, "Непоколебимый Глаз химеры", 755, "Прочный Глаз химеры", 755, "Растрескавшийся Глаз химеры", 755, "Рельефный Глаз химеры", 755, "Рунический Глаз химеры", 755, "Сверкающий Глаз химеры", 755, "Стойкий Глаз химеры", 755, "Цельный Глаз химеры", 755, "Цельный величественный циркон", 755, "Яркий Глаз химеры", 755, "Ясный Глаз химеры" },
	[36926] = { 755, "Всевластный сумрачный кристалл", 755, "Заряженный сумрачный кристалл", 755, "Изменчивый сумрачный кристалл", 755, "Кольцо тени земли", 755, "Королевский сумрачный кристалл", 755, "Ледяная призма", 755, "Монарший сумрачный кристалл", 755, "Непрочный сумрачный кристалл", 755, "Очищенный сумрачный кристалл", 755, "Сбалансированный сумрачный кристалл", 755, "Светящийся сумрачный кристалл", 755, "Сумрачный кристалл защитника", 755, "Сумрачный кристалл стража", 755, "Таинственный сумрачный кристалл", 755, "Фокусирующая линза из сумрачного кристалла", 755, "Фокусирующая линза из сумрачного нефрита", 755, "Царственный сумрачный кристалл" },
	[36927] = { 171, "Трансмутация: страхолит", 202, "Прицел 'Пронзатель сердец'", 202, "Снегозащитные очки острого зрения", 202, "Угрозодетектор R19", 755, "Всевластный сумеречный опал", 755, "Заряженный сумеречный опал", 755, "Изменчивый сумеречный опал", 755, "Королевский сумеречный опал", 755, "Монарший сумеречный опал", 755, "Непрочный сумеречный опал", 755, "Очищенный сумеречный опал", 755, "Рунический перстень маны", 755, "Рунический перстень маны претендента", 755, "Сбалансированный сумеречный опал", 755, "Светящийся сумеречный опал", 755, "Сумеречная змея", 755, "Сумеречный опал защитника", 755, "Сумеречный опал стража", 755, "Таинственный сумеречный опал", 755, "Царственный сумеречный опал" },
	[36928] = { 755, "Блестящий Глаз химеры", 755, "Блистательный Глаз химеры", 755, "Всевластный страхолит", 755, "Гладкий Глаз химеры", 755, "Грозовой Глаз химеры", 755, "Заряженный страхолит", 755, "Изменчивый страхолит", 755, "Изысканный Глаз химеры", 755, "Изящный Глаз химеры", 755, "Искрящийся Глаз химеры", 755, "Королевский страхолит", 755, "Матовый Глаз химеры", 755, "Мистический Глаз химеры", 755, "Монарший страхолит", 755, "Монументальный страхолит", 755, "Мягкий Глаз химеры", 755, "Непоколебимый Глаз химеры", 755, "Непрочный страхолит", 755, "Очищенный страхолит", 755, "Прочный Глаз химеры", 755, "Растрескавшийся Глаз химеры", 755, "Рельефный Глаз химеры", 755, "Рунический Глаз химеры", 755, "Сбалансированный страхолит", 755, "Сверкающий Глаз химеры", 755, "Светящийся страхолит", 755, "Стойкий Глаз химеры", 755, "Страхолит защитника", 755, "Страхолит стража", 755, "Таинственный страхолит", 755, "Царственный страхолит", 755, "Цельный Глаз химеры", 755, "Яркий Глаз химеры", 755, "Ясный Глаз химеры" },
	[36929] = { 171, "Трансмутация: алмаз землеправителя", 755, "Блистающий огромный цитрин", 755, "Броский огромный цитрин", 755, "Гибельный огромный цитрин", 755, "Глянцевый огромный цитрин", 755, "Гравированный огромный цитрин", 755, "Застывший огромный цитрин", 755, "Затвердевший огромный цитрин", 755, "Идеально ограненный огромный цитрин", 755, "Мерцающий огромный цитрин", 755, "Могущественный огромный цитрин", 755, "Надежный огромный цитрин", 755, "Наделенный силой огромный цитрин", 755, "Нетронутый огромный цитрин", 755, "Нефритовый кинжал-подвеска", 755, "Огромный цитрин воителя", 755, "Огромный цитрин проворства", 755, "Ожерелье с кристаллом цитрина", 755, "Покрытый письменами огромный цитрин", 755, "Прозрачный огромный цитрин", 755, "Светоносный огромный цитрин", 755, "Смертоносный огромный цитрин", 755, "Сокрытый огромный цитрин", 755, "Стойкий огромный цитрин", 755, "Тревожный огромный цитрин" },
	[36930] = { 171, "Трансмутация: аметрин", 197, "Великолепный ковер-самолет", 202, "Заряженные титановые очки", 755, "Блистающий императорский топаз", 755, "Броский императорский топаз", 755, "Гибельный императорский топаз", 755, "Глянцевый императорский топаз", 755, "Гравированный императорский топаз", 755, "Застывший императорский топаз", 755, "Затвердевший императорский топаз", 755, "Идеально ограненный императорский топаз", 755, "Императорский топаз воителя", 755, "Императорский топаз проворства", 755, "Королевский краб", 755, "Мерцающий императорский топаз", 755, "Могущественный императорский топаз", 755, "Надежный императорский топаз", 755, "Наделенный силой императорский топаз", 755, "Нетронутый императорский топаз", 755, "Покрытый письменами императорский топаз", 755, "Прозрачный императорский топаз", 755, "Светоносный императорский топаз", 755, "Смертоносный императорский топаз", 755, "Сокрытый императорский топаз", 755, "Стойкий императорский топаз", 755, "Сумеречная змея", 755, "Тревожный императорский топаз" },
	[36931] = { 755, "Аметрин авангарда", 755, "Аметрин варвара", 755, "Аметрин защитника", 755, "Аметрин проворства", 755, "Аметрин фехтовальщика", 755, "Блистающий аметрин", 755, "Броский аметрин", 755, "Гибельный аметрин", 755, "Глянцевый аметрин", 755, "Гравированный аметрин", 755, "Грубый аметрин", 755, "Застывший аметрин", 755, "Затвердевший аметрин", 755, "Идеально ограненный аметрин", 755, "Краеугольный аметрин", 755, "Мерцающий аметрин", 755, "Могущественный аметрин", 755, "Надежный аметрин", 755, "Наделенный силой аметрин", 755, "Нетронутый аметрин", 755, "Округленный аметрин", 755, "Покрытый письменами аметрин", 755, "Прозрачный аметрин", 755, "Светоносный аметрин", 755, "Смертоносный аметрин", 755, "Сокрытый аметрин", 755, "Стойкий аметрин", 755, "Тревожный аметрин" },
	[36932] = { 171, "Трансмутация: алмаз землеправителя", 755, "Вневременной темный нефрит", 755, "Зазубренный темный нефрит", 755, "Замысловатый темный нефрит", 755, "Ледяная призма", 755, "Лучистый темный нефрит", 755, "Мощный темный нефрит", 755, "Насыщенный темный нефрит", 755, "Неизменный темный нефрит", 755, "Непрозрачный темный нефрит", 755, "Нефритовое кольцо истребления", 755, "Нефритовый кинжал-подвеска", 755, "Ослепительный темный нефрит", 755, "Отверделый темный нефрит", 755, "Плотный темный нефрит", 755, "Померкший темный нефрит", 755, "Раздробленный темный нефрит", 755, "Расколотый темный нефрит", 755, "Светозарный темный нефрит", 755, "Сияющий темный нефрит", 755, "Смутный темный нефрит", 755, "Темный нефрит провидца", 755, "Усиленный темный нефрит", 755, "Фокусирующая линза из сумрачного нефрита", 755, "Фокусирующая линза из темного нефрита" },
	[36933] = { 171, "Трансмутация: Око Зула", 202, "Нерушимые усилители исцеления", 202, "Очки с зелеными стеклами", 755, "Вневременной лесной изумруд", 755, "Зазубренный лесной изумруд", 755, "Замысловатый лесной изумруд", 755, "Изумрудное колье", 755, "Изумрудное колье претендента", 755, "Изумрудный кабан", 755, "Королевский краб", 755, "Лесной изумруд провидца", 755, "Лучистый лесной изумруд", 755, "Мощный лесной изумруд", 755, "Насыщенный лесной изумруд", 755, "Неизменный лесной изумруд", 755, "Непрозрачный лесной изумруд", 755, "Ослепительный лесной изумруд", 755, "Отверделый лесной изумруд", 755, "Перстень грез", 755, "Плотный лесной изумруд", 755, "Померкший лесной изумруд", 755, "Раздробленный лесной изумруд", 755, "Расколотый лесной изумруд", 755, "Сапфировая сова", 755, "Светозарный лесной изумруд", 755, "Сияющий лесной изумруд", 755, "Смутный лесной изумруд", 755, "Усиленный лесной изумруд" },
	[36934] = { 197, "Наручи волшебника с самоцветами", 755, "Блестящий Глаз химеры", 755, "Блистательный Глаз химеры", 755, "Вневременное Око Зула", 755, "Гладкий Глаз химеры", 755, "Грозовой Глаз химеры", 755, "Зазубренное Око Зула", 755, "Замысловатое Око Зула", 755, "Изысканный Глаз химеры", 755, "Изящный Глаз химеры", 755, "Искрящийся Глаз химеры", 755, "Крепкое Око Зула", 755, "Лучистое Око Зула", 755, "Матовый Глаз химеры", 755, "Мистический Глаз химеры", 755, "Мощное Око Зула", 755, "Мягкий Глаз химеры", 755, "Насыщенное Око Зула", 755, "Неизменное Око Зула", 755, "Непоколебимый Глаз химеры", 755, "Непрозрачное Око Зула", 755, "Око Зула провидца", 755, "Ослепительное Око Зула", 755, "Отверделое Око Зула", 755, "Плотное Око Зула", 755, "Померкшее Око Зула", 755, "Прочный Глаз химеры", 755, "Раздробленное Око Зула", 755, "Расколотое Око Зула", 755, "Растрескавшийся Глаз химеры", 755, "Рельефный Глаз химеры", 755, "Рунический Глаз химеры", 755, "Сверкающий Глаз химеры", 755, "Светозарное Око Зула", 755, "Сияющее Око Зула", 755, "Смутное Око Зула", 755, "Стойкий Глаз химеры", 755, "Усиленное Око Зула", 755, "Цельный Глаз химеры", 755, "Яркий Глаз химеры", 755, "Ясный Глаз химеры" },
	[37101] = { 773, "Свиток выносливости", 773, "Свиток духа", 773, "Свиток интеллекта", 773, "Свиток ловкости", 773, "Свиток силы" },
	[37663] = { 164, "Ботфорты кузни погибели", 164, "Булава стража из титановой стали", 164, "Закаленные сапоги из титановой стали", 164, "Закаленный шлем из титановой стали", 164, "Защитники жизни", 164, "Зубчатые смертеносы", 164, "Кираса Белого Рыцаря", 164, "Кираса Кузни Солнца", 164, "Костекрушитель из титановой стали", 164, "Костомолы леденящего ада", 164, "Латные сапоги военачальника", 164, "Латные сапоги кузнеца света", 164, "Латный ремень правоты", 164, "Наручи Кузни Солнца", 164, "Несокрушимый латный ремень", 164, "Нити судьбы", 164, "Ножные латы из чистой стали", 164, "Ножные латы мучительной смерти", 164, "Осадный щит из титановой стали", 164, "Пояс титанов", 164, "Пронзатель из титановой стали", 164, "Разрушитель из титановой стали", 164, "Сапоги королевского бунта", 164, "Саронитовые мечеломы", 164, "Сверкающие сапоги из титановой стали", 164, "Сверкающий шлем из титановой стали", 164, "Столпы мощи", 164, "Титановые нагрудные пластины", 164, "Титановые шипованные наручи", 164, "Утраченные сапоги ремесленника", 164, "Чародейский клинок из титановой стали", 164, "Шипастые сапоги из титановой стали", 164, "Шипастый шлем из титановой стали", 202, "Анжинерский чоппер", 202, "Дживс", 202, "Механоцикл", 202, "Трицикл", 202, "Турботрицикл", 202, "Чоппер изгоя", 333, "Чары для оружия - Отведение удара", 333, "Чары для оружия - титановый страж", 755, "Кольцо полуночного неба", 755, "Наследный камень императора", 755, "Ограненный камень хиджальских гор", 755, "Резонирующее кольцо гнева", 755, "Усиливающее слух кольцо преступника" },
	[37700] = { 164, "Смертоносный саронитовый кортик", 165, "Плащ суровых ветров", 165, "Плащ томимых небес", 202, "Гиперскоростные ускорители", 202, "Статические гиперускорители" },
	[37701] = { 164, "Бригантина завоевания", 164, "Закаленная саронитовая кираса", 164, "Закаленные саронитовые ножные латы", 164, "Закаленный саронитовый шлем", 164, "Ножные латы завоевания", 164, "Саронитовая ударная палица ярости", 171, "Мощное зелье защиты от тайной магии", 171, "Охранный эликсир", 197, "Клобук ледяной ярости", 197, "Клобук ледяной ярости претендента", 197, "Наплечники ледяной ярости", 197, "Наплечники ледяной ярости претендента", 197, "Наручи ледяной ярости", 197, "Наручи ледяной ярости претендента", 197, "Одеяние ледяной ярости", 197, "Одеяние ледяной ярости претендента", 197, "Перчатки ледяной ярости", 197, "Перчатки ледяной ярости претендента", 197, "Поножи ледяной ярости", 197, "Поножи ледяной ярости претендента", 197, "Пояс ледяной ярости", 197, "Пояс ледяной ярости претендента", 197, "Сапоги ледяной ярости", 197, "Сапоги ледяной ярости претендента", 202, "Осколочные патроны", 202, "Перегруженный конденсатор", 755, "Амулет с кристаллом кальцедония", 755, "Кольцо Солнечного Камня", 755, "Кольцо кровавого камня", 755, "Ожерелье с кристаллом цитрина" },
	[37702] = { 164, "Заточенный кобальтовый колун", 164, "Кобальтовый тесак свирепости", 164, "Проржавевшее саронитовое лезвие", 164, "Проржавевший саронитовый изранитель", 164, "Саронитовый мозголом", 164, "Саронитовый чародейский клинок", 171, "Мощное зелье защиты от магии льда", 197, "Клобук ледяной ярости", 197, "Клобук ледяной ярости претендента", 197, "Лазурная чародейская нить", 197, "Наплечники ледяной ярости", 197, "Наплечники ледяной ярости претендента", 197, "Наручи ледяной ярости", 197, "Наручи ледяной ярости претендента", 197, "Одеяние ледяной ярости", 197, "Одеяние ледяной ярости претендента", 197, "Перчатки ледяной ярости", 197, "Перчатки ледяной ярости претендента", 197, "Поножи ледяной ярости", 197, "Поножи ледяной ярости претендента", 197, "Пояс ледяной ярости", 197, "Пояс ледяной ярости претендента", 197, "Сапоги ледяной ярости", 197, "Сапоги ледяной ярости претендента", 202, "Гоблинский лучевой трансформатор", 202, "Нарукавная зажигательная ракетница" },
	[37703] = { 164, "Саронитовый нож", 164, "Саронитовый разбойничий кинжал", 165, "Темные поножи жителя льдов", 165, "Темный нагрудный доспех жителя льдов", 165, "Черные полярные поножи", 165, "Черный полярный нагрудник", 165, "Чешуйчатые ледоступы", 171, "Мощное зелье защиты от сил природы", 197, "Сапоги из сумеречной ткани", 202, "Амуниция с ледяным наконечником" },
	[37704] = { 171, "Мощное зелье защиты от темной магии", 171, "Мощный эликсир защиты", 171, "Настой каменной крови", 171, "Настой стальной кожи", 171, "Эликсир молниеносности", 197, "Сияющая чародейская нить" },
	[37705] = { 164, "Деревянная рапира саронитовой справедливости", 164, "Сверкающая саронитовая кираса", 164, "Сверкающие саронитовые ножные латы", 164, "Сверкающий саронитовый шлем", 164, "Усиленные кобальтовые наплечники", 164, "Усиленные кобальтовые ножные латы", 164, "Усиленный кобальтовый нагрудник", 164, "Усиленный кобальтовый шлем", 165, "Плащ томимых небес", 165, "Темная кираса из обмерзшей чешуи", 165, "Темные нерубские поножи", 165, "Темные поножи из обмерзшей чешуи", 165, "Темный нерубский нагрудник", 165, "Черные полярные сапоги", 171, "Мощное зелье защиты от огня", 202, "Гоблинский лучевой трансформатор", 202, "Детали для набора инъекций маны", 202, "Неустойчивый детонатор", 202, "Труба из ледяной стали", 333, "Чары для обуви - ледопроходец", 333, "Чары для обуви - ледопроходец II" },
	[37921] = { 171, "Мощный эликсир разума", 171, "Настой крепости", 171, "Несокрушимый алхимический камень", 171, "Несокрушимый алхимический камень претендента", 171, "Слабый настой крепости", 171, "Эликсир гнева", 171, "Эликсир молниеносности" },
	[38425] = { 165, "Барабаны дикой природы", 165, "Барабаны забытых королей", 165, "Боевые наручи лунной тени", 165, "Ботфорты загробника", 165, "Ботфорты потрошителя", 165, "Ботфорты претендента", 165, "Воинский пояс потрошителя", 165, "Воинский пояс претендента", 165, "Высокие ботинки штормового укрытия", 165, "Высокие ботинки штормового укрытия претендента", 165, "Гнилостный пояс из шкур вурдалаков", 165, "Захваты штормового укрытия", 165, "Захваты штормового укрытия претендента", 165, "Йормунгарские накладки для поножей", 165, "Капюшон ночного штурма", 165, "Кираса загробника", 165, "Кираса из борейской кожи", 165, "Кираса рассекающего удара", 165, "Корона штормового укрытия", 165, "Корона штормового укрытия претендента", 165, "Маска потрошителя", 165, "Маска потрошителя претендента", 165, "Набедренники земледарения", 165, "Набедренники потрошителя", 165, "Набедренники претендента", 165, "Набедренники тяжелых увечий", 165, "Набедренники штормового укрытия", 165, "Набедренники штормового укрытия претендента", 165, "Наголовник угрюмости", 165, "Наголовник угрюмости претендента", 165, "Нагрудный доспех из ледяной чешуи", 165, "Нагрудный доспех потрошителя", 165, "Нагрудный доспех претендента", 165, "Нагрудный доспех угрюмости", 165, "Нагрудный доспех угрюмости претендента", 165, "Накладки из толстой борейской кожи", 165, "Накулачники штормового укрытия", 165, "Накулачники штормового укрытия претендента", 165, "Наплеч ожесточения", 165, "Наплеч угрюмости", 165, "Наплеч угрюмости претендента", 165, "Наплечники штормового укрытия", 165, "Наплечники штормового укрытия претендента", 165, "Наплечные пластины потрошителя", 165, "Наплечные пластины претендента", 165, "Наплечные щитки быстрой стрелы", 165, "Наплечные щитки быстрой стрелы претендента", 165, "Наручи быстрой смерти", 165, "Наручи быстрой стрелы", 165, "Наручи быстрой стрелы претендента", 165, "Наручи отражения", 165, "Наручи тяжелых увечий", 165, "Наручи угрюмости", 165, "Наручи угрюмости претендента", 165, "Наручники потрошителя", 165, "Наручники претендента", 165, "Нерубские накладки для поножей", 165, "Одеяния лунного затмения", 165, "Опоясок с ножами для снятия шкур", 165, "Панцирь рыцарского проклятья", 165, "Плащ томимых небес", 165, "Повязки угрюмости", 165, "Повязки угрюмости претендента", 165, "Подсумок из драконьей чешуи", 165, "Поножи быстрой стрелы", 165, "Поножи быстрой стрелы претендента", 165, "Поножи ветроруба", 165, "Поножи интуитивного боя", 165, "Поножи угрюмости", 165, "Поножи угрюмости претендента", 165, "Походная сума зверолова", 165, "Пояс быстрой стрелы", 165, "Пояс быстрой стрелы претендента", 165, "Пояс из ледяной чешуи", 165, "Пояс полярной жизни", 165, "Пояс угрюмости", 165, "Пояс угрюмости претендента", 165, "Пояс штормового укрытия", 165, "Пояс штормового укрытия претендента", 165, "Поясное хранилище тяжелых игл", 165, "Ремень ночного штурма", 165, "Рукавицы быстрой стрелы", 165, "Рукавицы быстрой стрелы претендента", 165, "Рукавицы морского прибоя", 165, "Рукавицы потрошителя", 165, "Рукавицы претендента", 165, "Рюкзак с бесчисленными карманами", 165, "Сапоги быстрой стрелы", 165, "Сапоги быстрой стрелы претендента", 165, "Сапоги ветроруба", 165, "Сапоги земледарения", 165, "Сапоги из ледяной чешуи", 165, "Сапоги угрюмости", 165, "Сапоги угрюмости претендента", 165, "Снежные сапоги", 165, "Снежный жилет", 165, "Снежный шнурованный ремень", 165, "Темная кираса из обмерзшей чешуи", 165, "Темные нерубские поножи", 165, "Темные поножи жителя льдов", 165, "Темные поножи из обмерзшей чешуи", 165, "Темный нагрудный доспех жителя льдов", 165, "Темный нерубский нагрудник", 165, "Тролльский тканый наплеч", 165, "Тролльский тканый ремень", 165, "Уплотненный пояс из электрохимеры", 165, "Усиленный нерубский колчан", 165, "Хауберк быстрой стрелы", 165, "Хауберк быстрой стрелы претендента", 165, "Хауберк штормового укрытия", 165, "Хауберк штормового укрытия претендента", 165, "Черные полярные поножи", 165, "Черный полярный нагрудник", 165, "Шахтерская сумка из шкуры мамонта", 165, "Шлем быстрой стрелы", 165, "Шлем быстрой стрелы претендента", 197, "Туфли утренней зари", 197, "Шелковые сапоги ледяных осколков", 202, "Бронированные титановые очки", 202, "Заряженные титановые очки", 202, "Затуманивающие взор очки", 202, "Механическая пелерина претендента", 202, "Механический плащ претендента", 202, "Наручная маскировка ХТ-92 \"Леший\"", 202, "Наручный сканер слабостей ХТ-27 \"Трепет\"", 202, "Нерушимые усилители исцеления", 202, "Очки с зелеными стеклами", 202, "Смертоносные биооптические очки бойца", 202, "Смертоносные биооптические очки заклинателя", 202, "Смертоносные биооптические очки целителя", 202, "Снегозащитные очки острого зрения", 202, "Спектральный выявитель слабости", 202, "Электропотоковое улучшение зрения" },
	[38426] = { 197, "Благословенные полуперчатки Света", 197, "Вышивка в виде рукояти меча", 197, "Вышивка темного сияния", 197, "Иссиня-черное одеяние", 197, "Иссиня-черные перчатки", 197, "Клобук из сумеречной ткани", 197, "Клобук ледяной ярости", 197, "Клобук ледяной ярости претендента", 197, "Ледовая сумка", 197, "Ледовое одеяние", 197, "Ледовые туфли", 197, "Ледовый боевой пояс", 197, "Ледовый шнурованный ремень", 197, "Ледотканое одеяние", 197, "Ледотканые наплечники", 197, "Ледотканые напульсники", 197, "Ледотканые перчатки", 197, "Ледотканые поножи", 197, "Ледотканые сапоги", 197, "Ледотканый пояс", 197, "Ледотканый шлем", 197, "Мистические ледотканые наплечники", 197, "Мистические ледотканые напульсники", 197, "Мистическое ледотканое одеяние", 197, "Наплечники из сумеречной ткани", 197, "Наплечники ледяной ярости", 197, "Наплечники ледяной ярости претендента", 197, "Напульсники из сумеречной ткани", 197, "Наручи ледяной ярости", 197, "Наручи ледяной ярости претендента", 197, "Одеяние из колдовской ткани", 197, "Одеяние из лунного тюля", 197, "Одеяние из сумеречной ткани", 197, "Одеяние ледяной ярости", 197, "Одеяние ледяной ярости претендента", 197, "Освященная чародейская нить", 197, "Перчатки из колдовской ткани", 197, "Перчатки из лунного тюля", 197, "Перчатки из сумеречной ткани", 197, "Перчатки ледяной ярости", 197, "Перчатки ледяной ярости претендента", 197, "Поножи из сумеречной ткани", 197, "Поножи ледяной ярости", 197, "Поножи ледяной ярости претендента", 197, "Пояс из сумеречной ткани", 197, "Пояс ледяной ярости", 197, "Пояс ледяной ярости претендента", 197, "Сапоги из сумеречной ткани", 197, "Сапоги ледяной ярости", 197, "Сапоги ледяной ярости претендента", 197, "Светлотканая вышивка", 197, "Сумка Бездны", 197, "Сумка из ледяной ткани", 197, "Таинственная котомка", 197, "Туфли утренней зари", 197, "Чародейская нить наставника", 197, "Черное одеяние из сумеречной ткани", 197, "Черные напульсники из сумеречной ткани", 197, "Черные поножи из сумеречной ткани", 197, "Шелковые сапоги ледяных осколков", 197, "Шляпа безрадостной судьбы", 197, "Штаны холодной луны" },
	[38557] = { 165, "Барабаны забытых королей", 165, "Высокие драконьи ботинки", 165, "Гнилостный пояс из шкур вурдалаков", 165, "Заряженные молнией поножи", 165, "Кираса рыцаря из чешуи дракона", 165, "Набедренники из осколков драконьих костей", 165, "Нагрудный доспех из ледяной чешуи", 165, "Накладки для поножей из ледяной чешуи", 165, "Наручи орлиной погибели", 165, "Наручи рыцаря из чешуи дракона", 165, "Несносимые ботфорты", 165, "Подсумок из драконьей чешуи", 165, "Пояс драконов", 165, "Пояс из ледяной чешуи", 165, "Поясное хранилище тяжелых игл", 165, "Прочные накладки для поножей из ледяной чешуи", 165, "Сапоги духа земли", 165, "Сапоги зимней закалки", 165, "Сапоги из ледяной чешуи", 165, "Сапоги ударившей молнии", 165, "Чешуйчатые ледоступы", 202, "Повышающие проворство биооптические очки целителя" },
	[38558] = { 165, "Гнилостный пояс из шкур вурдалаков", 165, "Жукохрусты", 165, "Заколдованная нерубская кираса", 165, "Надежная накидка из нерубской шкуры", 165, "Накладки для поножей из снежной шкуры", 165, "Наплеч безукоризненных рогов", 165, "Нерубские накладки для поножей", 165, "Нерубское усиление поножей", 165, "Опоясок с ножами для снятия шкур", 165, "Поножи клинка", 165, "Поясное хранилище тяжелых игл", 165, "Прочные накладки для поножей из снежной шкуры", 165, "Сапоги надвигающейся смерти", 165, "Синий пояс Хаоса", 165, "Снежные сапоги", 165, "Снежный жилет", 165, "Снежный шнурованный ремень", 165, "Уплотненный пояс из электрохимеры", 165, "Усиленный нерубский колчан", 165, "Черные полярные сапоги", 165, "Черные хитиновые наручи", 202, "Повышающие проворство биооптические очки заклинателя" },
	[38561] = { 165, "Барабаны дикой природы", 165, "Благословенные кенарийские сапоги", 165, "Бриджи одичавшей природы", 165, "Йормунгарские накладки для поножей", 165, "Йормунгарское усиление поножей", 165, "Опоясок с ножами для снятия шкур", 165, "Сапоги из живой чешуи", 165, "Сапоги из жормунгальской чешуи", 165, "Уплотненный пояс из электрохимеры", 202, "Повышающие проворство биооптические очки бойца" },
	[39151] = { 773, "Бежевые чернила", 773, "Чернила лунного сияния" },
	[39334] = { 773, "Полуночные чернила" },
	[39338] = { 773, "Чернила царя зверей" },
	[39339] = { 773, "Чернила нефритового пламени" },
	[39340] = { 773, "Астрономические чернила" },
	[39341] = { 773, "Мерцающие чернила" },
	[39342] = { 773, "Астральные чернила" },
	[39343] = { 773, "Чернила моря" },
	[39354] = { 773, "Исследование малого начертания", 773, "Карта таинства", 773, "Материал для свитка брони", 773, "Материал для свитка оружия", 773, "Мистический том", 773, "Свиток возврата", 773, "Свиток выносливости", 773, "Свиток выносливости II", 773, "Свиток духа", 773, "Свиток духа II", 773, "Свиток интеллекта", 773, "Свиток интеллекта II", 773, "Свиток ловкости", 773, "Свиток ловкости II", 773, "Свиток силы", 773, "Свиток силы II", 773, "Символ безграничного возрождения", 773, "Символ бесконечного дыхания", 773, "Символ благословения королей", 773, "Символ благословения могущества", 773, "Символ благословения мудрости", 773, "Символ боевого крика", 773, "Символ взлома", 773, "Символ водного облика", 773, "Символ водного щита", 773, "Символ возложения рук", 773, "Символ воскрешения питомца", 773, "Символ гнева", 773, "Символ гнева деревьев", 773, "Символ дезориентирующего выстрела", 773, "Символ дикой природы", 773, "Символ дразнящего удара", 773, "Символ духовного созвучия", 773, "Символ жизнеотвода", 773, "Символ замедленного падения", 773, "Символ защиты от огня", 773, "Символ инстинкта выживания", 773, "Символ камня здоровья", 773, "Символ когтя", 773, "Символ кольца льда", 773, "Символ кровавой ярости", 773, "Символ ледяного доспеха", 773, "Символ лечения питомца", 773, "Символ ментального крика", 773, "Символ метки охотника", 773, "Символ молота правосудия", 773, "Символ морозного доспеха", 773, "Символ обшаривания карманов", 773, "Символ овладения силой", 773, "Символ огненного шока", 773, "Символ огромной скорости", 773, "Символ омоложения", 773, "Символ отпугивания зверя", 773, "Символ пингвина", 773, "Символ порчи", 773, "Символ похищения души", 773, "Символ призрачного волка", 773, "Символ растворения в тени", 773, "Символ рывка", 773, "Символ связки души", 773, "Символ сковывания нежити", 773, "Символ слова силы: Щит", 773, "Символ стойкости", 773, "Символ стремительного рывка", 773, "Символ тотема каменного когтя", 773, "Символ трепки", 773, "Символ удара в спину", 773, "Символ удара героя", 773, "Символ удара грома", 773, "Символ удара ящера", 773, "Символ укуса змеи", 773, "Символ ускользания", 773, "Символ чародейского взрыва", 773, "Символ чародейского выстрела", 773, "Символ чародейского интеллекта", 773, "Символ чутья на нежить", 773, "Символ шипов", 773, "Символ щита молний" },
	[39469] = { 773, "Исследование малого начертания", 773, "Материал для свитка брони", 773, "Свиток возврата" },
	[39501] = { 773, "Карта Новолуния", 773, "Карта тени", 773, "Книга звезд", 773, "Книга полета", 773, "Материал для свитка оружия II", 773, "Руководство по глотанию огня", 773, "Свиток выносливости IV", 773, "Свиток выносливости V", 773, "Свиток выносливости VI", 773, "Свиток духа IV", 773, "Свиток духа V", 773, "Свиток духа VI", 773, "Свиток интеллекта IV", 773, "Свиток интеллекта V", 773, "Свиток интеллекта VI", 773, "Свиток ловкости IV", 773, "Свиток ловкости V", 773, "Свиток ловкости VI", 773, "Свиток силы IV", 773, "Свиток силы V", 773, "Свиток силы VI", 773, "Символ болезни", 773, "Символ взрыва трупа", 773, "Символ воскрешения мертвых", 773, "Символ вспышки Света", 773, "Символ вульгарных оскорблений", 773, "Символ дубовой кожи", 773, "Символ жгучей боли", 773, "Символ замораживающей ловушки", 773, "Символ защиты от страха", 773, "Символ звездного огня", 773, "Символ казни", 773, "Символ камня души", 773, "Символ кары", 773, "Символ коварного удара", 773, "Символ костяного щита", 773, "Символ ледяного прикосновения", 773, "Символ ледяного удара", 773, "Символ ледяной глыбы", 773, "Символ ледяной преграды", 773, "Символ ложного выпада", 773, "Символ малой волны исцеления", 773, "Символ мора", 773, "Символ мясорубки", 773, "Символ объятий смерти", 773, "Символ ожога", 773, "Символ ожога Тьмы", 773, "Символ оружия жизни земли", 773, "Символ освящения", 773, "Символ отрыва", 773, "Символ подавления боли", 773, "Символ полосования", 773, "Символ расправы", 773, "Символ рассеивания заклинаний", 773, "Символ рассечения", 773, "Символ самоцвета маны", 773, "Символ сезона дождей", 773, "Символ спринта", 773, "Символ тотема гнева", 773, "Символ тотема исцеляющего потока", 773, "Символ удара воина Света", 773, "Символ удара чумы", 773, "Символ хватки смерти", 773, "Символ хозяина вод", 773, "Символ черной смерти", 773, "Символ щита земли", 773, "Символ экзорцизма", 773, "Фолиант грозовых оков" },
	[39502] = { 773, "Великое начертание журавлиного крыла", 773, "Великое начертание клыка тигра", 773, "Великое начертание когтя тигра", 773, "Великое начертание рога быка", 773, "Исследование нордскольского начертания", 773, "Карта Новолуния: Север", 773, "Книга крови", 773, "Книга молитв", 773, "Книга ритуалов новолуния", 773, "Книга хитрых советов", 773, "Контракт с Абимайскими искателями", 773, "Контракт с Артелем Барханного Ветра", 773, "Контракт с Гилнеасом", 773, "Контракт с Изгнанниками Вайш'ира", 773, "Контракт с Картеля Трюмных Вод", 773, "Контракт с Орденом Белого Тигра", 773, "Контракт с Орденом Красного Журавля", 773, "Контракт с Эльдранилом", 773, "Лики Судьбы", 773, "Материал для свитка брони III", 773, "Материал для свитка оружия III", 773, "Рунический свиток стойкости", 773, "Свиток беса скверны", 773, "Свиток возврата III", 773, "Свиток выносливости IX", 773, "Свиток выносливости VII", 773, "Свиток выносливости VIII", 773, "Свиток высвобожденного элементаля", 773, "Свиток грызунов", 773, "Свиток духа IX", 773, "Свиток духа VII", 773, "Свиток духа VIII", 773, "Свиток интеллекта IX", 773, "Свиток интеллекта VII", 773, "Свиток интеллекта VIII", 773, "Свиток ловкости IX", 773, "Свиток ловкости VII", 773, "Свиток ловкости VIII", 773, "Свиток наблюдателя", 773, "Свиток повелителя Бездны", 773, "Свиток силы IX", 773, "Свиток силы VII", 773, "Свиток силы VIII", 773, "Свиток стража гнева", 773, "Свиток упыря", 773, "Свиток шиварры", 773, "Символ Слова Тьмы: Боль", 773, "Символ Тьмы", 773, "Символ ангелов", 773, "Символ антимагического панциря", 773, "Символ ауры меткого выстрела", 773, "Символ безудержного восстановления", 773, "Символ берсерка", 773, "Символ блокирования", 773, "Символ блуждающего духа", 773, "Символ божественной бури", 773, "Символ буйного роста", 773, "Символ быстрины", 773, "Символ быстрого восстановления", 773, "Символ быстрого разложения", 773, "Символ быстрой стрельбы", 773, "Символ веера клинков", 773, "Символ верного выстрела", 773, "Символ взрывной волны", 773, "Символ вихря", 773, "Символ вихря клинков", 773, "Символ властности", 773, "Символ вмешательства", 773, "Символ внезапного удара", 773, "Символ волны исцеления", 773, "Символ восстановления", 773, "Символ воющего ветра", 773, "Символ воя ужаса", 773, "Символ всеполгощающей тьмы", 773, "Символ вурдалака", 773, "Символ выброса адреналина", 773, "Символ выстрела химеры", 773, "Символ вытягивания жизни", 773, "Символ гимна надежды", 773, "Символ глубокой заморозки", 773, "Символ глубокой раны", 773, "Символ гнева карателя", 773, "Символ града стрел", 773, "Символ грозы", 773, "Символ грома", 773, "Символ грома и молнии", 773, "Символ громового удара", 773, "Символ грохочущей мощи", 773, "Символ демонического круга", 773, "Символ дикого рева", 773, "Символ духа воздаяния", 773, "Символ духа гадюки", 773, "Символ духа дикого волка", 773, "Символ духа зверя", 773, "Символ душ", 773, "Символ жажды убийства", 773, "Символ жертвенного огня", 773, "Символ живой бомбы", 773, "Символ жизнецвета", 773, "Символ захвата рун", 773, "Символ звездной пыли", 773, "Символ звездопада", 773, "Символ звериного гнева", 773, "Символ зеркального изображения", 773, "Символ зимнего горна", 773, "Символ змеиной ловушки", 773, "Символ извечной воды", 773, "Символ изгнания зла", 773, "Символ испепеления", 773, "Символ исповеди", 773, "Символ иссушения разума", 773, "Символ исчадия Тьмы", 773, "Символ калечащего яда", 773, "Символ колодца Света", 773, "Символ кольца света", 773, "Символ контроля над разумом", 773, "Символ кровавого удара", 773, "Символ крови вампира", 773, "Символ кровожадности", 773, "Символ кровоизлияния", 773, "Символ кровоотвода", 773, "Символ круга исцеления", 773, "Символ крылатого отмщения", 773, "Символ лавы", 773, "Символ ледяного копья", 773, "Символ ледяного огня", 773, "Символ ледяной ловушки", 773, "Символ ледяной стрелы", 773, "Символ ледяных оков", 773, "Символ лика смерти", 773, "Символ магического доспеха", 773, "Символ маленьких хитростей", 773, "Символ маскировки", 773, "Символ массового рассеивания", 773, "Символ метаморфозы", 773, "Символ молитвы исцеления", 773, "Символ молота гнева", 773, "Символ молота праведника", 773, "Символ мощи тайной магии", 773, "Символ мясника", 773, "Символ невидимости", 773, "Символ незыблемости льда", 773, "Символ неистового восстановления", 773, "Символ ненасытной стужи", 773, "Символ неоспоримой победы", 773, "Символ несокрушимой брони", 773, "Символ нестабильного колдовства", 773, "Символ неутомимости", 773, "Символ нечестивой порчи", 773, "Символ оберегающего духа", 773, "Символ огненного взрыва", 773, "Символ огненного шара", 773, "Символ озарения", 773, "Символ оружия неистовства ветра", 773, "Символ отражения заклинания", 773, "Символ отчаянной защиты", 773, "Символ охотника Скверны", 773, "Символ переполняющей мощи", 773, "Символ печати Света", 773, "Символ печати мудрости", 773, "Символ печати отмщения", 773, "Символ печати повиновения", 773, "Символ печати праведности", 773, "Символ пира для воронов", 773, "Символ пламени Тьмы", 773, "Символ плаща Теней", 773, "Символ победного ража", 773, "Символ подготовки", 773, "Символ поджигания", 773, "Символ покорения стихий", 773, "Символ покровительства природы", 773, "Символ превращения", 773, "Символ призрачного удара", 773, "Символ провокации", 773, "Символ проклятия агонии", 773, "Символ размашистого удара", 773, "Символ разрывного выстрела", 773, "Символ раскаленного доспеха", 773, "Символ рваной раны", 773, "Символ рунического удара", 773, "Символ рыка", 773, "Символ святой клятвы", 773, "Символ священного гнева", 773, "Символ сглаза", 773, "Символ сдерживания Плети", 773, "Символ слияния с Тьмой", 773, "Символ слова Тьмы: Смерть", 773, "Символ смертельного броска", 773, "Символ смертельного удара", 773, "Символ смертельной стужи", 773, "Символ смерти и разложения", 773, "Символ снятия проклятия", 773, "Символ сокрушения", 773, "Символ стража Скверны", 773, "Символ стрелы Хаоса", 773, "Символ стремительного омоложения", 773, "Символ суккуба", 773, "Символ тайфуна", 773, "Символ танца теней", 773, "Символ танцующего рунического оружия", 773, "Символ темной власти", 773, "Символ тления", 773, "Символ тотема прилива маны", 773, "Символ тотема элементаля огня", 773, "Символ убийственного выстрела", 773, "Символ увеличения питомца", 773, "Символ увечья", 773, "Символ удара Плети", 773, "Символ удара бури", 773, "Символ удара в сердце", 773, "Символ удара смерти", 773, "Символ ударной волны", 773, "Символ удушения", 773, "Символ укуса виверны", 773, "Символ уничтожения", 773, "Символ фокусирования", 773, "Символ цепного исцеления", 773, "Символ цепной молнии", 773, "Символ чародейского обстрела", 773, "Символ чародейской вспышки", 773, "Символ частицы Света", 773, "Символ череды убийств", 773, "Символ черепов", 773, "Символ шквала клинков", 773, "Символ шока", 773, "Символ щита мстителя", 773, "Символ щита праведности", 773, "Символ элементаля воды", 773, "Символ ястреба", 773, "Старшая карта Новолуния", 773, "Сумеречный фолиант", 773, "Таинственная карта удачи", 773, "Фолиант адского огня", 773, "Фолиант в железном переплете" },
	[39681] = { 202, "Активная наручная защита ХМ-52 \"Титан\"", 202, "Анжинерский чоппер", 202, "Армированные биооптические очки бойца", 202, "Армированные биооптические очки защитника", 202, "Армированные биооптические очки целителя", 202, "Генератор шума", 202, "Гномские рентгеновские очки", 202, "Детали для набора лечебных инъекций", 202, "Дживс", 202, "Кобальтовая осколочная бомба", 202, "Межпространственный тоннель: К-3", 202, "Механоцикл", 202, "Наручная маскировка ХТ-92 \"Леший\"", 202, "Наручная электрозащита ХЕ-89 \"Буря\"", 202, "Наручные подавители боли ХМ-51 \"Узурпатор\"", 202, "Наручный инъектор ХЕ-39 \"Водяной\"", 202, "Наручный источник сил ХМ-75 \"Очищение\"", 202, "Наручный сканер слабостей ХТ-27 \"Трепет\"", 202, "Наручный целеуказатель ХЕ-41 \"Раптор\"", 202, "Нитроускорители", 202, "Облегченные биооптические очки заклинателя", 202, "Облегченные биооптические очки целителя", 202, "Повышающие проворство биооптические очки бойца", 202, "Повышающие проворство биооптические очки заклинателя", 202, "Повышающие проворство биооптические очки целителя", 202, "Рефракторный прицел с бриллиантовой огранкой", 202, "Смертоносные биооптические очки бойца", 202, "Смертоносные биооптические очки заклинателя", 202, "Смертоносные биооптические очки целителя", 202, "Титановый ящик с инструментами", 202, "Трицикл", 202, "Турботрицикл", 202, "Усилитель звука", 202, "Чоппер изгоя" },
	[39682] = { 202, "Генератор шума", 202, "Гоблинский планер", 202, "Персональный генератор электромагнитных импульсов", 202, "Пружинистая паутинка", 202, "Усилитель звука", 202, "Эластичная подкладка" },
	[39683] = { 202, "Активная наручная защита ХМ-52 \"Титан\"", 202, "Генератор шума", 202, "Межпространственный тоннель: К-3", 202, "Набор для снятия ограничителя", 202, "Наручная маскировка ХТ-92 \"Леший\"", 202, "Наручная электрозащита ХЕ-89 \"Буря\"", 202, "Наручные подавители боли ХМ-51 \"Узурпатор\"", 202, "Наручный инъектор ХЕ-39 \"Водяной\"", 202, "Наручный источник сил ХМ-75 \"Очищение\"", 202, "Наручный сканер слабостей ХТ-27 \"Трепет\"", 202, "Наручный целеуказатель ХЕ-41 \"Раптор\"", 202, "Огнестрел модели 'С'", 202, "Рефракторный прицел с бриллиантовой огранкой", 202, "Солнечный прицел", 202, "Транслятор нервных импульсов", 202, "Усилитель звука" },
	[39684] = { 165, "Укомплектованный ящик с инструментами", 202, "Колчедановый детонатор", 202, "Летучий громоотвод", 202, "Лечебная граната истинного золота", 202, "Огнестрел модели 'С'", 202, "Ударный шорох" },
	[39690] = { 202, "Взрывчатая приманка", 202, "Кобальтовая осколочная бомба", 202, "Мамонтобои", 202, "Наременные осколочные бомбы", 202, "Нитроускорители", 202, "Сверхмощный заряд термической саперной взрывчатки", 202, "Ящик бомб" },
	[39774] = { 773, "Карта таинства", 773, "Материал для свитка оружия", 773, "Мистический том", 773, "Свиток выносливости II", 773, "Свиток духа II", 773, "Свиток интеллекта II", 773, "Свиток ловкости II", 773, "Свиток силы II", 773, "Символ благословения могущества", 773, "Символ благословения мудрости", 773, "Символ боевого крика", 773, "Символ возложения рук", 773, "Символ воскрешения питомца", 773, "Символ гнева", 773, "Символ дикой природы", 773, "Символ духовного созвучия", 773, "Символ жизнеотвода", 773, "Символ замедленного падения", 773, "Символ камня здоровья", 773, "Символ когтя", 773, "Символ кольца льда", 773, "Символ кровавой ярости", 773, "Символ ледяного доспеха", 773, "Символ лечения питомца", 773, "Символ ментального крика", 773, "Символ метки охотника", 773, "Символ молота правосудия", 773, "Символ морозного доспеха", 773, "Символ обшаривания карманов", 773, "Символ овладения силой", 773, "Символ огненного шока", 773, "Символ огромной скорости", 773, "Символ омоложения", 773, "Символ отпугивания зверя", 773, "Символ пингвина", 773, "Символ порчи", 773, "Символ похищения души", 773, "Символ растворения в тени", 773, "Символ рывка", 773, "Символ слова силы: Щит", 773, "Символ стойкости", 773, "Символ стремительного рывка", 773, "Символ тотема каменного когтя", 773, "Символ трепки", 773, "Символ удара в спину", 773, "Символ удара героя", 773, "Символ удара грома", 773, "Символ удара ящера", 773, "Символ укуса змеи", 773, "Символ ускользания", 773, "Символ чародейского интеллекта", 773, "Символ шипов", 773, "Символ щита молний" },
	[39970] = { 171, "Малый настой сопротивления", 171, "Настой сопротивления" },
	[40111] = { 755, "Рельефный сердолик", 755, "Треснутый рельефный сердолик" },
	[40112] = { 755, "Изысканный сердолик", 755, "Треснутый изысканный сердолик" },
	[40113] = { 755, "Рунический сердолик", 755, "Треснутый рунический сердолик" },
	[40114] = { 755, "Треснутый яркий сердолик", 755, "Яркий сердолик" },
	[40115] = { 755, "Изящный сердолик", 755, "Треснутый изящный сердолик" },
	[40116] = { 755, "Блистательный сердолик", 755, "Треснутый блистательный сердолик" },
	[40117] = { 755, "Растрескавшийся сердолик", 755, "Треснутый растрескавшийся сердолик" },
	[40118] = { 755, "Треснутый ясный сердолик", 755, "Ясный сердолик" },
	[40119] = { 755, "Треснутый цельный зефирит", 755, "Цельный зефирит" },
	[40120] = { 755, "Искрящийся зефирит", 755, "Треснутый искрящийся зефирит" },
	[40121] = { 755, "Блестящий зефирит", 755, "Треснутый блестящий зефирит" },
	[40122] = { 755, "Грозовой зефирит", 755, "Треснутый грозовой зефирит" },
	[40123] = { 755, "Сверкающий алицит", 755, "Треснутый сверкающий алицит" },
	[40124] = { 755, "Гладкий алицит", 755, "Треснутый гладкий алицит" },
	[40125] = { 755, "Прочный алицит", 755, "Треснутый прочный алицит" },
	[40126] = { 755, "Матовый алицит", 755, "Треснутый матовый алицит" },
	[40127] = { 755, "Мистический алицит", 755, "Треснутый мистический алицит" },
	[40128] = { 755, "Мягкий алицит", 755, "Треснутый мягкий алицит" },
	[40129] = { 755, "Треснутый царственный камень ночи", 755, "Царственный камень ночи" },
	[40130] = { 755, "Изменчивый камень ночи", 755, "Треснутый изменчивый камень ночи" },
	[40131] = { 755, "Непрочный камень ночи", 755, "Треснутый непрочный камень ночи" },
	[40132] = { 755, "Светящийся камень ночи", 755, "Треснутый светящийся камень ночи" },
	[40133] = { 755, "Очищенный камень ночи", 755, "Треснутый очищенный камень ночи" },
	[40134] = { 755, "Королевский камень ночи", 755, "Треснутый королевский камень ночи" },
	[40135] = { 755, "Таинственный камень ночи", 755, "Треснутый таинственный камень ночи" },
	[40136] = { 755, "Сбалансированный камень ночи", 755, "Треснутый сбалансированный камень ночи" },
	[40137] = { 755, "Заряженный камень ночи", 755, "Треснутый заряженный камень ночи" },
	[40138] = { 755, "Монарший камень ночи", 755, "Треснутый монарший камень ночи" },
	[40139] = { 755, "Камень ночи защитника", 755, "Треснутый камень ночи защитника" },
	[40140] = { 755, "Всевластный камень ночи", 755, "Треснутый всевластный камень ночи" },
	[40141] = { 755, "Камень ночи стража", 755, "Треснутый камень ночи стража" },
	[40142] = { 755, "Покрытый письменами гессонит", 755, "Треснутый покрытый письменами гессонит" },
	[40143] = { 755, "Гравированный гессонит", 755, "Треснутый гравированный гессонит" },
	[40144] = { 755, "Гессонит защитника", 755, "Треснутый гессонит защитника" },
	[40145] = { 755, "Глянцевый гессонит", 755, "Треснутый глянцевый гессонит" },
	[40146] = { 755, "Броский гессонит", 755, "Треснутый броский гессонит" },
	[40147] = { 755, "Смертоносный гессонит", 755, "Треснутый смертоносный гессонит" },
	[40148] = { 755, "Блистающий гессонит", 755, "Треснутый блистающий гессонит" },
	[40149] = { 755, "Прозрачный гессонит", 755, "Треснутый прозрачный гессонит" },
	[40150] = { 755, "Гессонит проворства", 755, "Треснутый гессонит проворства" },
	[40151] = { 755, "Светоносный гессонит", 755, "Треснутый светоносный гессонит" },
	[40152] = { 755, "Могущественный гессонит", 755, "Треснутый могущественный гессонит" },
	[40153] = { 755, "Сокрытый гессонит", 755, "Треснутый сокрытый гессонит" },
	[40154] = { 755, "Надежный гессонит", 755, "Треснутый надежный гессонит" },
	[40155] = { 755, "Тревожный гессонит", 755, "Треснутый тревожный гессонит" },
	[40156] = { 755, "Гибельный гессонит", 755, "Треснутый гибельный гессонит" },
	[40157] = { 755, "Нетронутый гессонит", 755, "Треснутый нетронутый гессонит" },
	[40158] = { 755, "Наделенный силой гессонит", 755, "Треснутый наделенный силой гессонит" },
	[40159] = { 755, "Застывший гессонит", 755, "Треснутый застывший гессонит" },
	[40160] = { 755, "Стойкий гессонит", 755, "Треснутый стойкий гессонит" },
	[40161] = { 755, "Мерцающий гессонит", 755, "Треснутый мерцающий гессонит" },
	[40162] = { 755, "Идеально ограненный гессонит", 755, "Треснутый идеально ограненный гессонит" },
	[40163] = { 755, "Затвердевший гессонит", 755, "Треснутый затвердевший гессонит" },
	[40164] = { 755, "Вневременная яшма", 755, "Треснутая вневременная яшма" },
	[40165] = { 755, "Зазубренная яшма", 755, "Треснутая зазубренная яшма" },
	[40166] = { 755, "Насыщенная яшма", 755, "Треснутая насыщенная яшма" },
	[40167] = { 755, "Отверделая яшма", 755, "Треснутая отверделая яшма" },
	[40168] = { 755, "Неизменная яшма", 755, "Треснутая неизменная яшма" },
	[40169] = { 755, "Мощная яшма", 755, "Треснутая мощная яшма" },
	[40170] = { 755, "Треснутая яшма провидца", 755, "Яшма провидца" },
	[40171] = { 755, "Смутная яшма", 755, "Треснутая смутная яшма" },
	[40172] = { 755, "Сияющая яшма", 755, "Треснутая сияющая яшма" },
	[40173] = { 755, "Померкшая яшма", 755, "Треснутая померкшая яшма" },
	[40174] = { 755, "Замысловатая яшма", 755, "Треснутая замысловатая яшма" },
	[40175] = { 755, "Ослепительная яшма", 755, "Треснутая ослепительная яшма" },
	[40176] = { 755, "Расколотая яшма", 755, "Треснутая расколотая яшма" },
	[40177] = { 755, "Лучистая яшма", 755, "Треснутая лучистая яшма" },
	[40178] = { 755, "Непрозрачная яшма", 755, "Треснутая непрозрачная яшма" },
	[40179] = { 755, "Треснутая усиленная яшма", 755, "Усиленная яшма" },
	[40180] = { 755, "Светозарная яшма", 755, "Треснутая светозарная яшма" },
	[40181] = { 755, "Плотная яшма", 755, "Треснутая плотная яшма" },
	[40182] = { 755, "Раздробленная яшма", 755, "Треснутая раздробленная яшма" },
	[40195] = { 171, "Зелье адреналина", 171, "Зелье быстроты", 171, "Зелье дикой магии", 171, "Настой текущей воды", 171, "Настой чистого колдунства", 171, "Несокрушимый алхимический камень", 171, "Несокрушимый алхимический камень претендента", 171, "Эликсир гуру" },
	[40199] = { 171, "Карломасло" },
	[40411] = { 171, "Бездонный флакон с зельем маны", 171, "Бездонный флакон с лечебным зельем", 171, "Исследование трав Нордскола", 171, "Настой бесконечной ярости", 171, "Настой драконьего разума", 171, "Настой каменной крови", 171, "Настой ледяного змея", 171, "Настой севера", 171, "Настой силы титана", 171, "Настой стальной кожи", 171, "Настой текущей воды", 171, "Настой чистого колдунства" },
	[40533] = { 202, "Бронированный боевой дробовик", 202, "Огнестрел модели 'С'", 202, "Тонко отлаженный шприцевик", 202, "Шпашко-метатель", 202, "Эрнестуэй 4000" },
	[40769] = { 202, "Дживс" },
	[41146] = { 202, "Эрнестуэй 4000" },
	[41163] = { 164, "Колчедановая цепь для оружия", 164, "Колчедановый шип для щита", 164, "Титановая обшивка", 164, "Титановая отмычка", 164, "Титановая цепь для оружия", 164, "Титановый жезл", 164, "Титановый шип для щита", 186, "Выплавка титановой стали", 202, "Армированные биооптические очки защитника", 202, "Бронированные титановые очки", 202, "Бронированный боевой дробовик", 202, "Генератор червоточины: Нордскол", 202, "Гномские рентгеновские очки", 202, "Гномский генератор молний", 202, "Заряженные титановые очки", 202, "Затуманивающие взор очки", 202, "Нерушимые усилители исцеления", 202, "Очки с зелеными стеклами", 202, "Снегозащитные очки острого зрения", 202, "Спектральный выявитель слабости", 202, "Титановый ящик с инструментами", 202, "Электропотоковое улучшение зрения", 202, "Эрнестуэй 4000", 333, "Чары для плаща - ткань титанов", 333, "Чары для плаща - ткань титанов II", 755, "Алый перстень", 755, "Алый перстень претендента", 755, "Амулет из небесного сапфира", 755, "Амулет из небесного сапфира претендента", 755, "Изумрудное колье", 755, "Изумрудное колье претендента", 755, "Изумрудный кабан", 755, "Кольцо алых теней", 755, "Кольцо огненного ветра", 755, "Кольцо силы земли", 755, "Кольцо хладных слез", 755, "Королевский краб", 755, "Перстень грез", 755, "Рубиновый заяц", 755, "Рунический перстень маны", 755, "Рунический перстень маны претендента", 755, "Сапфировая сова", 755, "Сумеречная змея", 755, "Титановая печатка свирепости", 755, "Титановая цепь стража земли", 755, "Титановое колье сотрясения", 755, "Титановое кольцо ледяного стража", 755, "Титановое кольцо свирепости", 755, "Титановое кольцо сотрясения", 755, "Титановое кольцо стража земли", 755, "Титановое кольцо чародейского удара", 755, "Титановое ожерелье чародейского удара" },
	[41245] = { 164, "Титановые нагрудные пластины" },
	[41266] = { 755, "Бездушный алмаз небесного сияния", 755, "Громовой алмаз небесного сияния", 755, "Жалкий алмаз небесного сияния", 755, "Загадочный алмаз небесного сияния", 755, "Лучезарный алмаз небесного сияния", 755, "Неустанный алмаз небесного сияния", 755, "Оживляющий алмаз небесного сияния", 755, "Разрушительный алмаз небесного сияния", 755, "Стремительный алмаз небесного сияния", 755, "Угасающий алмаз небесного сияния", 755, "Хаотический алмаз небесного сияния", 773, "Книга молитв" },
	[41334] = { 755, "Алмаз жестокого землеправителя", 755, "Алмаз строгого землеправителя", 755, "Вечный алмаз землеправителя", 755, "Живительный алмаз землеправителя", 755, "Заостренный алмаз землеправителя", 755, "Лучащийся алмаз землеправителя", 755, "Могущественный алмаз землеправителя", 755, "Незыблемый алмаз землеправителя", 755, "Нерушимый алмаз землеправителя", 755, "Провидческий алмаз землеправителя", 773, "Книга крови" },
	[41355] = { 164, "Титановые шипованные наручи" },
	[41510] = { 197, "Грубая рубашка рабочего", 197, "Желтая рубашка дровосека", 197, "Зеленая рубашка дровосека", 197, "Зеленая рубашка рабочего", 197, "Клобук из сумеречной ткани", 197, "Красная рубашка дровосека", 197, "Красная рубашка рабочего", 197, "Ледотканое одеяние", 197, "Ледотканые наплечники", 197, "Ледотканые напульсники", 197, "Ледотканые перчатки", 197, "Ледотканые поножи", 197, "Ледотканые сапоги", 197, "Ледотканый пояс", 197, "Ледотканый шлем", 197, "Мистические ледотканые наплечники", 197, "Мистические ледотканые напульсники", 197, "Мистическое ледотканое одеяние", 197, "Наплечники из сумеречной ткани", 197, "Напульсники из сумеречной ткани", 197, "Одеяние из сумеречной ткани", 197, "Перчатки из сумеречной ткани", 197, "Плащ заледеневших душ", 197, "Плащ луны", 197, "Поножи из сумеречной ткани", 197, "Пояс из сумеречной ткани", 197, "Рулон прочной ледяной ткани", 197, "Сапоги из сумеречной ткани", 197, "Синяя рубашка дровосека", 197, "Синяя рубашка рабочего" },
	[41511] = { 197, "Благословенные полуперчатки Света", 197, "Великолепный ковер-самолет", 197, "Иссиня-черная ткань", 197, "Иссиня-черное одеяние", 197, "Иссиня-черные перчатки", 197, "Клобук ледяной ярости", 197, "Клобук ледяной ярости претендента", 197, "Колдовская ткань", 197, "Ледовое одеяние", 197, "Ледовые туфли", 197, "Ледовый боевой пояс", 197, "Ледовый шнурованный ремень", 197, "Лунный тюль", 197, "Наплечники ледяной ярости", 197, "Наплечники ледяной ярости претендента", 197, "Наручи ледяной ярости", 197, "Наручи ледяной ярости претендента", 197, "Одеяние из колдовской ткани", 197, "Одеяние из лунного тюля", 197, "Одеяние ледяной ярости", 197, "Одеяние ледяной ярости претендента", 197, "Пелерина ледяного стража", 197, "Перчатки из колдовской ткани", 197, "Перчатки из лунного тюля", 197, "Перчатки ледяной ярости", 197, "Перчатки ледяной ярости претендента", 197, "Плащ багрового снега", 197, "Плащ смертельной стужи", 197, "Поножи ледяной ярости", 197, "Поножи ледяной ярости претендента", 197, "Пояс ледяной ярости", 197, "Пояс ледяной ярости претендента", 197, "Сапоги ледяной ярости", 197, "Сапоги ледяной ярости претендента", 197, "Сумка из ледяной ткани", 197, "Тончайший плащ", 197, "Туфли утренней зари", 197, "Черное одеяние из сумеречной ткани", 197, "Черные напульсники из сумеречной ткани", 197, "Черные поножи из сумеречной ткани", 197, "Шелковые сапоги ледяных осколков", 197, "Шляпа безрадостной судьбы", 197, "Штаны холодной луны" },
	[41520] = { 197, "Сапоги из сумеречной ткани" },
	[41593] = { 197, "Вышивка темного сияния", 197, "Заиндевевший ковер-самолет", 197, "Иссиня-черное одеяние", 197, "Иссиня-черные перчатки", 197, "Кушак древней силы", 197, "Ледовая сумка", 197, "Летний пояс мага-новичка", 197, "Одеяние Мерлина", 197, "Поножи паутины смерти", 197, "Сапоги смертной стужи", 197, "Старообрядческий пояс из шелка", 197, "Сумка Бездны", 197, "Туфли тонких чар", 197, "Шаль силы духа из редкого шелка", 197, "Шляпа безрадостной судьбы" },
	[41594] = { 197, "Благословенные полуперчатки Света", 197, "Заиндевевший ковер-самолет", 197, "Изумрудный вьюк", 197, "Королевские наручи из лунного тюля", 197, "Королевское одеяние из лунного тюля", 197, "Ледовая сумка", 197, "Одеяние из лунного тюля", 197, "Перчатки из лунного тюля", 197, "Покров силы магии из ветроткани", 197, "Сандалии освящения", 197, "Светлотканая вышивка", 197, "Светлотканые поножи", 197, "Старообрядческий пояс из шелка", 197, "Таинственная котомка", 197, "Туфли спасителя", 197, "Туфли утренней зари", 197, "Шаль силы духа из редкого шелка", 197, "Шнурованный ремень светлого утра", 197, "Штаны холодной луны", 202, "Облегченные биооптические очки целителя" },
	[41595] = { 197, "Вышивка в виде рукояти меча", 197, "Заиндевевший ковер-самолет", 197, "Кушак древней силы", 197, "Ледовый шнурованный ремень", 197, "Летний пояс мага-новичка", 197, "Наручи волшебника с самоцветами", 197, "Одеяние Мерлина", 197, "Одеяние из колдовской ткани", 197, "Перчатки из колдовской ткани", 197, "Покров силы магии из ветроткани", 197, "Поножи паутины смерти", 197, "Сапоги смертной стужи", 197, "Сумка Бездны", 197, "Таинственная котомка", 197, "Туфли тонких чар", 197, "Шелковые сапоги ледяных осколков", 202, "Облегченные биооптические очки заклинателя" },
	[41745] = { 333, "Рунический титановый жезл" },
	[41800] = { 185, "Пир для великанов" },
	[41801] = { 185, "Стейк из каракатицы", 185, "Стейк из каракатицы с приправами" },
	[41802] = { 185, "Печеный морской дьявол", 185, "Стейк из королевского ската", 185, "Стейк из королевского ската со специями" },
	[41803] = { 185, "Копченый камнеперый окунь", 185, "Пир для великанов" },
	[41805] = { 185, "Черный студень", 185, "Черный студень с приправами" },
	[41806] = { 185, "Вареный северный подкаменщик", 185, "Подкаменщик-гриль", 185, "Рыбный пир", 185, "Рыбный пир со специями" },
	[41807] = { 185, "Подкопченная дракоперая рыба-ангел", 185, "Подкопченная дракоперая рыба-ангел с приправами", 185, "Филе дракоперой рыбы-ангела", 185, "Филе дракоперой рыбы-ангела с приправами" },
	[41808] = { 185, "Костечешуйный луциан - гриль", 185, "Луциан особого приготовления", 185, "Луциан особого приготовления с приправами" },
	[41809] = { 185, "Копченый лосось", 185, "Лосось с дымком", 185, "Пир для карликов", 185, "Подкопченный лосось со специями", 185, "Рыбный пир", 185, "Рыбный пир со специями" },
	[41810] = { 185, "Маринованная клыкозубая сельдь", 185, "Острая жареная сельдь", 185, "Эфемерная селедка" },
	[41812] = { 185, "Соте из бычков" },
	[41813] = { 185, "Вареная медуза", 185, "Медуза с приправами", 185, "Пир для карликов", 185, "Рыбный пир", 185, "Рыбный пир со специями", 185, "Синяя медуза с пряностями" },
	[41814] = { 171, "Эфириальное масло" },
	[42142] = { 755, "Рельефный Глаз химеры" },
	[42143] = { 755, "Изысканный Глаз химеры" },
	[42144] = { 755, "Рунический Глаз химеры" },
	[42145] = { 755, "Искрящийся Глаз химеры" },
	[42146] = { 755, "Блестящий Глаз химеры" },
	[42148] = { 755, "Сверкающий Глаз химеры" },
	[42149] = { 755, "Гладкий Глаз химеры" },
	[42150] = { 755, "Мягкий Глаз химеры" },
	[42151] = { 755, "Изящный Глаз химеры" },
	[42152] = { 755, "Блистательный Глаз химеры" },
	[42153] = { 755, "Растрескавшийся Глаз химеры" },
	[42154] = { 755, "Ясный Глаз химеры" },
	[42155] = { 755, "Грозовой Глаз химеры" },
	[42156] = { 755, "Прочный Глаз химеры" },
	[42157] = { 755, "Матовый Глаз химеры" },
	[42158] = { 755, "Мистический Глаз химеры" },
	[42225] = { 755, "Блестящее око дракона", 755, "Блистательное око дракона", 755, "Гладкое око дракона", 755, "Грозовое око дракона", 755, "Изысканное око дракона", 755, "Изящное око дракона", 755, "Искрящееся око дракона", 755, "Матовое око дракона", 755, "Мистическое око дракона", 755, "Мягкое око дракона", 755, "Непоколебимое око дракона", 755, "Прочное око дракона", 755, "Растрескавшееся око дракона", 755, "Рельефное око дракона", 755, "Руническое око дракона", 755, "Сверкающее око дракона", 755, "Слеза забвения", 755, "Слеза кошмаров", 755, "Слеза миража", 755, "Стойкое око дракона", 755, "Титановая цепь стража земли", 755, "Титановое колье сотрясения", 755, "Титановое кольцо сотрясения", 755, "Титановое кольцо стража земли", 755, "Титановое кольцо чародейского удара", 755, "Титановое ожерелье чародейского удара", 755, "Цельное око дракона", 755, "Яркое око дракона", 755, "Ясное око дракона" },
	[42253] = { 197, "Благословенные полуперчатки Света", 197, "Великолепный ковер-самолет", 197, "Лазурная чародейская нить", 197, "Ледовый шнурованный ремень", 197, "Пелерина ледяного стража", 197, "Плащ багрового снега", 197, "Прочная сапфировая чародейская нить", 197, "Прочная сверкающая чародейская нить", 197, "Сапфировая чародейская нить", 197, "Сверкающая чародейская нить", 197, "Сияющая чародейская нить", 197, "Туфли утренней зари", 197, "Черное одеяние из сумеречной ткани", 197, "Черные напульсники из сумеречной ткани", 197, "Черные поножи из сумеречной ткани", 197, "Шелковые сапоги ледяных осколков", 197, "Шляпа безрадостной судьбы", 197, "Штаны холодной луны" },
	[42546] = { 202, "Межпространственный тоннель: К-3" },
	[43007] = { 185, "Вареный северный подкаменщик", 185, "Даларанская похлебка из моллюсков со специями", 185, "Завтрак следопыта", 185, "Карпаччо из ворга", 185, "Корм для зверька", 185, "Котлета из змея с пряностями", 185, "Лосось с дымком", 185, "Луциан особого приготовления", 185, "Луциан особого приготовления с приправами", 185, "Люторожий змеестейк", 185, "Люторожий змеестейк с приправами", 185, "Медуза с приправами", 185, "Нежный стейк из черпорога", 185, "Острая жареная сельдь", 185, "Пережаренное мясо ворга", 185, "Пир для великанов", 185, "Пир для карликов", 185, "Подкопченная дракоперая рыба-ангел", 185, "Подкопченная дракоперая рыба-ангел с приправами", 185, "Подкопченный лосось со специями", 185, "Подкопченный стейк из ворга", 185, "Пряное лакомство из мамонта", 185, "Пряное лакомство из мамонта c приправами", 185, "Рыбный пир", 185, "Рыбный пир со специями", 185, "Синяя медуза с пряностями", 185, "Сочное мясо люторога", 185, "Сочное мясо люторога со специями", 185, "Сочные сосиски из люторога", 185, "Сочные сосиски из люторога с приправами", 185, "Стейк из каракатицы", 185, "Стейк из каракатицы с приправами", 185, "Стейк из королевского ската", 185, "Стейк из королевского ската со специями", 185, "Сытное кушанье из мамонта", 185, "Сытное кушанье из мамонта с приправами", 185, "Филе дракоперой рыбы-ангела", 185, "Филе дракоперой рыбы-ангела с приправами", 185, "Черный студень с приправами" },
	[43009] = { 185, "'Пир на весь мир'", 185, "Завтрак следопыта", 185, "Нежный стейк из черпорога", 185, "Стейк из черпорога" },
	[43010] = { 185, "'Пир на весь мир'", 185, "Деликатес из змея", 185, "Котлета из змея с пряностями", 185, "Люторожий змеестейк", 185, "Люторожий змеестейк с приправами" },
	[43011] = { 185, "Жареный ворг", 185, "Карпаччо из ворга", 185, "Пережаренное мясо ворга", 185, "Подкопченный стейк из ворга" },
	[43012] = { 185, "Люторожий змеестейк", 185, "Люторожий змеестейк с приправами", 185, "Пир для карликов", 185, "Сосиски из люторога", 185, "Сочное мясо люторога", 185, "Сочное мясо люторога со специями", 185, "Сочные сосиски из люторога", 185, "Сочные сосиски из люторога с приправами" },
	[43013] = { 185, "'Пир на весь мир'", 185, "Корм для зверька", 185, "Северная похлебка" },
	[43102] = { 164, "Булава стража из титановой стали", 164, "Закаленные сапоги из титановой стали", 164, "Закаленный шлем из титановой стали", 164, "Изысканное саронитовое наплечье претендента", 164, "Изысканные саронитовые наручи претендента", 164, "Изысканные саронитовые ножные латы претендента", 164, "Изысканные саронитовые рукавицы претендента", 164, "Изысканные саронитовые сапоги претендента", 164, "Изысканный саронитовый воинский пояс претендента", 164, "Изысканный саронитовый хауберк претендента", 164, "Изысканный саронитовый шлем претендента", 164, "Костекрушитель из титановой стали", 164, "Нагрудный доспех ледяной погибели", 164, "Осадный щит из титановой стали", 164, "Пронзатель из титановой стали", 164, "Разрушитель из титановой стали", 164, "Ремень ледяной погибели", 164, "Сапоги ледяной погибели", 164, "Саронитовое наплечье свирепости претендента", 164, "Саронитовые наручи свирепости претендента", 164, "Саронитовые ножные латы свирепости претендента", 164, "Саронитовые рукавицы свирепости претендента", 164, "Саронитовые сапоги свирепости претендента", 164, "Саронитовый воинский пояс свирепости претендента", 164, "Саронитовый хауберк свирепости претендента", 164, "Саронитовый шлем свирепости претендента", 164, "Сверкающие сапоги из титановой стали", 164, "Сверкающий шлем из титановой стали", 164, "Чародейский клинок из титановой стали", 164, "Шипастые сапоги из титановой стали", 164, "Шипастый шлем из титановой стали", 165, "Ботфорты загробника", 165, "Ботфорты претендента", 165, "Воинский пояс претендента", 165, "Высокие ботинки штормового укрытия претендента", 165, "Захваты штормового укрытия претендента", 165, "Земляные накладки для поножей", 165, "Кираса загробника", 165, "Корона штормового укрытия претендента", 165, "Маска потрошителя претендента", 165, "Набедренники земледарения", 165, "Набедренники претендента", 165, "Набедренники тяжелых увечий", 165, "Набедренники штормового укрытия претендента", 165, "Наголовник угрюмости претендента", 165, "Нагрудный доспех из ледяной чешуи", 165, "Нагрудный доспех претендента", 165, "Нагрудный доспех угрюмости претендента", 165, "Надежная накидка из нерубской шкуры", 165, "Накладки для поножей из ледяной чешуи", 165, "Накладки для поножей из снежной шкуры", 165, "Накулачники штормового укрытия претендента", 165, "Наплеч угрюмости претендента", 165, "Наплечники штормового укрытия претендента", 165, "Наплечные пластины претендента", 165, "Наплечные щитки быстрой стрелы претендента", 165, "Наручи быстрой стрелы претендента", 165, "Наручи тяжелых увечий", 165, "Наручи угрюмости претендента", 165, "Наручники претендента", 165, "Плащ ледяного убийцы", 165, "Повязки угрюмости претендента", 165, "Поножи быстрой стрелы претендента", 165, "Поножи ветроруба", 165, "Поножи угрюмости претендента", 165, "Пояс быстрой стрелы претендента", 165, "Пояс из ледяной чешуи", 165, "Пояс угрюмости претендента", 165, "Пояс штормового укрытия претендента", 165, "Прочные земляные накладки для поножей", 165, "Прочные накладки для поножей из ледяной чешуи", 165, "Прочные накладки для поножей из снежной шкуры", 165, "Рукавицы быстрой стрелы претендента", 165, "Рукавицы претендента", 165, "Сапоги быстрой стрелы претендента", 165, "Сапоги ветроруба", 165, "Сапоги земледарения", 165, "Сапоги из ледяной чешуи", 165, "Сапоги угрюмости претендента", 165, "Снежные сапоги", 165, "Снежный жилет", 165, "Снежный шнурованный ремень", 165, "Тролльский тканый наплеч", 165, "Тролльский тканый ремень", 165, "Хауберк быстрой стрелы претендента", 165, "Хауберк штормового укрытия претендента", 165, "Шлем быстрой стрелы претендента", 171, "Могущественный алхимический камень претендента", 171, "Несокрушимый алхимический камень претендента", 171, "Переменчивый алхимический камень претендента", 197, "Заиндевевший ковер-самолет", 197, "Иссиня-черное одеяние", 197, "Иссиня-черные перчатки", 197, "Клобук ледяной ярости претендента", 197, "Ледовое одеяние", 197, "Ледовые туфли", 197, "Ледовый боевой пояс", 197, "Наплечники ледяной ярости претендента", 197, "Наручи ледяной ярости претендента", 197, "Одеяние из колдовской ткани", 197, "Одеяние из лунного тюля", 197, "Одеяние ледяной ярости претендента", 197, "Перчатки из колдовской ткани", 197, "Перчатки из лунного тюля", 197, "Перчатки ледяной ярости претендента", 197, "Плащ смертельной стужи", 197, "Поножи ледяной ярости претендента", 197, "Пояс ледяной ярости претендента", 197, "Прочная сапфировая чародейская нить", 197, "Прочная сверкающая чародейская нить", 197, "Сапоги ледяной ярости претендента", 197, "Сапфировая чародейская нить", 197, "Сверкающая чародейская нить", 197, "Тончайший плащ", 202, "Бронированные титановые очки", 202, "Бронированный боевой дробовик", 202, "Заряженные титановые очки", 202, "Затуманивающие взор очки", 202, "Механическая пелерина претендента", 202, "Механический плащ претендента", 202, "Нерушимые усилители исцеления", 202, "Очки с зелеными стеклами", 202, "Снегозащитные очки острого зрения", 202, "Спектральный выявитель слабости", 202, "Электропотоковое улучшение зрения", 202, "Эрнестуэй 4000", 755, "Алый перстень претендента", 755, "Амулет из небесного сапфира претендента", 755, "Изумрудное колье претендента", 755, "Ледяная призма", 755, "Рунический перстень маны претендента", 755, "Титановая цепь стража земли", 755, "Титановое колье сотрясения", 755, "Титановое кольцо ледяного стража", 755, "Титановое кольцо сотрясения", 755, "Титановое кольцо стража земли", 755, "Титановое кольцо чародейского удара", 755, "Титановое ожерелье чародейского удара", 773, "Книга крови", 773, "Книга молитв", 773, "Лики Судьбы", 773, "Фолиант в железном переплете" },
	[43103] = { 773, "Чернила охотника" },
	[43104] = { 773, "Чернила утренней звезды" },
	[43105] = { 773, "Королевские чернила" },
	[43106] = { 773, "Огненные чернила" },
	[43107] = { 773, "Небесные чернила" },
	[43108] = { 773, "Чернила черного огня" },
	[43109] = { 773, "Чернила снегопада" },
	[43115] = { 773, "Карта таинства", 773, "Мистический том" },
	[43116] = { 773, "Символ Килрогга", 773, "Символ Света небес", 773, "Символ безграничного возрождения", 773, "Символ беса", 773, "Символ бесконечного дыхания", 773, "Символ благословения королей", 773, "Символ божественности", 773, "Символ быстрого исцеления", 773, "Символ взлома", 773, "Символ внутреннего огня", 773, "Символ водного облика", 773, "Символ водного щита", 773, "Символ гарроты", 773, "Символ глухой обороны", 773, "Символ гнева деревьев", 773, "Символ дезориентирующего выстрела", 773, "Символ дразнящего удара", 773, "Символ защиты от магии льда", 773, "Символ защиты от огня", 773, "Символ исчезновения", 773, "Символ канала здоровья", 773, "Символ кольца огня", 773, "Символ кровопускания", 773, "Символ лечения", 773, "Символ лунного огня", 773, "Символ молнии", 773, "Символ обжигающей ловушки", 773, "Символ оружия языка пламени", 773, "Символ ослабления доспеха", 773, "Символ отвлечения", 773, "Символ подводного дыхания", 773, "Символ подрезанного сухожилия", 773, "Символ потрошения", 773, "Символ правосудия", 773, "Символ призрачного волка", 773, "Символ раскола брони", 773, "Символ связки души", 773, "Символ скачка", 773, "Символ сковывания нежити", 773, "Символ спасения", 773, "Символ страха", 773, "Символ ухода в тень", 773, "Символ целительного прикосновения", 773, "Символ чародейских стрел", 773, "Символ чародейского взрыва", 773, "Символ чародейского выстрела", 773, "Символ чутья на нежить", 773, "Странная карта", 773, "Фолиант выживания", 773, "Фолиант рассвета" },
	[43117] = { 773, "Странная карта", 773, "Фолиант выживания", 773, "Фолиант рассвета" },
	[43118] = { 773, "Карта тайной магии", 773, "Полная схема маршрутов эвакуации", 773, "Свиток выносливости III", 773, "Свиток духа III", 773, "Свиток интеллекта III", 773, "Свиток ловкости III", 773, "Свиток силы III", 773, "Символ астрального возвращения", 773, "Символ взрывной ловушки", 773, "Символ возрождения", 773, "Символ вскипания лавы", 773, "Символ вызывающего рева", 773, "Символ демона Бездны", 773, "Символ залпа", 773, "Символ защиты от темной магии", 773, "Символ левитации", 773, "Символ ледяного шока", 773, "Символ ложной смерти", 773, "Символ мудрых", 773, "Символ обновления", 773, "Символ обновленной жизни", 773, "Символ очищения", 773, "Символ ошеломления", 773, "Символ парализующего удара", 773, "Символ порабощения демона", 773, "Символ порыва", 773, "Символ праведной защиты", 773, "Символ превосходства", 773, "Символ прилива сил", 773, "Символ прицельного выстрела", 773, "Символ проклятия изнеможения", 773, "Символ пытки разума", 773, "Символ реванша", 773, "Символ роя насекомых", 773, "Символ стрелы Тьмы", 773, "Символ стылой крови", 773, "Символ хождения по воде", 773, "Фолиант королей" },
	[43119] = { 773, "Карта тайной магии", 773, "Полная схема маршрутов эвакуации", 773, "Фолиант королей" },
	[43120] = { 773, "Карта тени", 773, "Книга звезд", 773, "Материал для свитка брони II", 773, "Материал для свитка оружия II", 773, "Руководство по глотанию огня", 773, "Свиток возврата II", 773, "Свиток выносливости IV", 773, "Свиток духа IV", 773, "Свиток интеллекта IV", 773, "Свиток ловкости IV", 773, "Свиток силы IV", 773, "Сертификат собственности", 773, "Символ бдительности", 773, "Символ безопасного падения", 773, "Символ вульгарных оскорблений", 773, "Символ дубовой кожи", 773, "Символ жгучей боли", 773, "Символ звездного огня", 773, "Символ камня души", 773, "Символ кары", 773, "Символ коварного удара", 773, "Символ ледяной глыбы", 773, "Символ ледяной преграды", 773, "Символ малой волны исцеления", 773, "Символ мясорубки", 773, "Символ ожога", 773, "Символ освящения", 773, "Символ отрыва", 773, "Символ разрывания", 773, "Символ рассеивания заклинаний", 773, "Символ рассечения", 773, "Символ сдерживания", 773, "Символ стаи", 773, "Символ тотема исцеляющего потока", 773, "Символ удара воина Света", 773, "Символ шока небес" },
	[43121] = { 773, "Карта тени", 773, "Книга звезд", 773, "Материал для свитка оружия II", 773, "Руководство по глотанию огня" },
	[43122] = { 773, "Карта Новолуния", 773, "Книга полета", 773, "Свиток выносливости V", 773, "Свиток выносливости VI", 773, "Свиток духа V", 773, "Свиток духа VI", 773, "Свиток интеллекта V", 773, "Свиток ловкости V", 773, "Свиток силы V", 773, "Символ болезни", 773, "Символ замораживающей ловушки", 773, "Символ защиты от страха", 773, "Символ казни", 773, "Символ костяного щита", 773, "Символ ледяного прикосновения", 773, "Символ ледяного удара", 773, "Символ ожога Тьмы", 773, "Символ подавления боли", 773, "Символ полосования", 773, "Символ расправы", 773, "Символ самоцвета маны", 773, "Символ сезона дождей", 773, "Символ спринта", 773, "Символ тотема гнева", 773, "Символ хватки смерти", 773, "Символ хозяина вод", 773, "Символ черной смерти", 773, "Символ щита земли", 773, "Символ экзорцизма", 773, "Фолиант грозовых оков" },
	[43123] = { 773, "Карта Новолуния", 773, "Книга полета", 773, "Фолиант грозовых оков" },
	[43124] = { 773, "Книга хитрых советов", 773, "Свиток интеллекта VI", 773, "Свиток ловкости VI", 773, "Свиток силы VI", 773, "Символ Слова Тьмы: Боль", 773, "Символ берсерка", 773, "Символ блуждающего духа", 773, "Символ божественной бури", 773, "Символ буйного роста", 773, "Символ быстрины", 773, "Символ быстрой стрельбы", 773, "Символ взрыва трупа", 773, "Символ вихря", 773, "Символ вихря клинков", 773, "Символ внезапного удара", 773, "Символ воскрешения мертвых", 773, "Символ воющего ветра", 773, "Символ вспышки Света", 773, "Символ вурдалака", 773, "Символ выстрела химеры", 773, "Символ гимна надежды", 773, "Символ глубокой заморозки", 773, "Символ глубокой раны", 773, "Символ грома", 773, "Символ духа дикого волка", 773, "Символ жажды убийства", 773, "Символ живой бомбы", 773, "Символ захвата рун", 773, "Символ зимнего горна", 773, "Символ извечной воды", 773, "Символ испепеления", 773, "Символ исповеди", 773, "Символ кольца света", 773, "Символ кровавого удара", 773, "Символ крови вампира", 773, "Символ кровоотвода", 773, "Символ ледяной ловушки", 773, "Символ ложного выпада", 773, "Символ магического доспеха", 773, "Символ метаморфозы", 773, "Символ молота праведника", 773, "Символ мора", 773, "Символ мощи тайной магии", 773, "Символ неистового восстановления", 773, "Символ ненасытной стужи", 773, "Символ неоспоримой победы", 773, "Символ несокрушимой брони", 773, "Символ нечестивой порчи", 773, "Символ оберегающего духа", 773, "Символ объятий смерти", 773, "Символ оружия жизни земли", 773, "Символ оружия неистовства ветра", 773, "Символ отражения заклинания", 773, "Символ печати повиновения", 773, "Символ плаща Теней", 773, "Символ размашистого удара", 773, "Символ разрывного выстрела", 773, "Символ слияния с Тьмой", 773, "Символ стрелы Хаоса", 773, "Символ суккуба", 773, "Символ танца теней", 773, "Символ танцующего рунического оружия", 773, "Символ удара Плети", 773, "Символ удара смерти", 773, "Символ удара чумы", 773, "Символ ударной волны", 773, "Символ чародейского обстрела", 773, "Символ чародейской вспышки", 773, "Символ частицы Света", 773, "Символ череды убийств", 773, "Старшая карта Новолуния", 773, "Фолиант адского огня" },
	[43125] = { 773, "Великое начертание журавлиного крыла", 773, "Великое начертание клыка тигра", 773, "Великое начертание когтя тигра", 773, "Великое начертание рога быка", 773, "Книга хитрых советов", 773, "Старшая карта Новолуния", 773, "Фолиант адского огня" },
	[43126] = { 773, "Великое начертание журавлиного крыла", 773, "Великое начертание клыка тигра", 773, "Великое начертание когтя тигра", 773, "Великое начертание рога быка", 773, "Исследование нордскольского начертания", 773, "Карта Новолуния: Север", 773, "Книга крови", 773, "Книга молитв", 773, "Книга ритуалов новолуния", 773, "Лики Судьбы", 773, "Материал для свитка брони III", 773, "Материал для свитка оружия III", 773, "Свиток возврата III", 773, "Свиток выносливости IX", 773, "Свиток выносливости VII", 773, "Свиток выносливости VIII", 773, "Свиток духа IX", 773, "Свиток духа VII", 773, "Свиток духа VIII", 773, "Свиток интеллекта IX", 773, "Свиток интеллекта VII", 773, "Свиток интеллекта VIII", 773, "Свиток ловкости IX", 773, "Свиток ловкости VII", 773, "Свиток ловкости VIII", 773, "Свиток силы IX", 773, "Свиток силы VII", 773, "Свиток силы VIII", 773, "Символ Тьмы", 773, "Символ антимагического панциря", 773, "Символ ауры меткого выстрела", 773, "Символ безудержного восстановления", 773, "Символ блокирования", 773, "Символ быстрого восстановления", 773, "Символ быстрого разложения", 773, "Символ веера клинков", 773, "Символ верного выстрела", 773, "Символ взрывной волны", 773, "Символ властности", 773, "Символ вмешательства", 773, "Символ волны исцеления", 773, "Символ восстановления", 773, "Символ воя ужаса", 773, "Символ выброса адреналина", 773, "Символ вытягивания жизни", 773, "Символ гнева карателя", 773, "Символ града стрел", 773, "Символ грозы", 773, "Символ грома и молнии", 773, "Символ грохочущей мощи", 773, "Символ демонического круга", 773, "Символ дикого рева", 773, "Символ духа воздаяния", 773, "Символ духа гадюки", 773, "Символ духа зверя", 773, "Символ душ", 773, "Символ жертвенного огня", 773, "Символ жизнецвета", 773, "Символ звездопада", 773, "Символ звериного гнева", 773, "Символ зеркального изображения", 773, "Символ змеиной ловушки", 773, "Символ изгнания зла", 773, "Символ инстинкта выживания", 773, "Символ иссушения разума", 773, "Символ исчадия Тьмы", 773, "Символ калечащего яда", 773, "Символ колодца Света", 773, "Символ контроля над разумом", 773, "Символ кровожадности", 773, "Символ кровоизлияния", 773, "Символ круга исцеления", 773, "Символ лавы", 773, "Символ ледяного копья", 773, "Символ ледяного огня", 773, "Символ ледяной стрелы", 773, "Символ ледяных оков", 773, "Символ лика смерти", 773, "Символ маленьких хитростей", 773, "Символ массового рассеивания", 773, "Символ молитвы исцеления", 773, "Символ молота гнева", 773, "Символ невидимости", 773, "Символ незыблемости льда", 773, "Символ нестабильного колдовства", 773, "Символ неутомимости", 773, "Символ огненного взрыва", 773, "Символ огненного шара", 773, "Символ озарения", 773, "Символ отчаянной защиты", 773, "Символ охотника Скверны", 773, "Символ печати Света", 773, "Символ печати мудрости", 773, "Символ печати отмщения", 773, "Символ печати праведности", 773, "Символ пламени Тьмы", 773, "Символ победного ража", 773, "Символ подготовки", 773, "Символ поджигания", 773, "Символ покорения стихий", 773, "Символ покровительства природы", 773, "Символ превращения", 773, "Символ призрачного удара", 773, "Символ провокации", 773, "Символ проклятия агонии", 773, "Символ раскаленного доспеха", 773, "Символ рваной раны", 773, "Символ рунического удара", 773, "Символ рыка", 773, "Символ святой клятвы", 773, "Символ священного гнева", 773, "Символ сглаза", 773, "Символ сдерживания Плети", 773, "Символ слова Тьмы: Смерть", 773, "Символ смертельного броска", 773, "Символ смертельного удара", 773, "Символ смерти и разложения", 773, "Символ снятия проклятия", 773, "Символ сокрушения", 773, "Символ стража Скверны", 773, "Символ стремительного омоложения", 773, "Символ тайфуна", 773, "Символ темной власти", 773, "Символ тотема прилива маны", 773, "Символ тотема элементаля огня", 773, "Символ убийственного выстрела", 773, "Символ увечья", 773, "Символ удара бури", 773, "Символ удара в сердце", 773, "Символ удушения", 773, "Символ укуса виверны", 773, "Символ уничтожения", 773, "Символ фокусирования", 773, "Символ цепного исцеления", 773, "Символ цепной молнии", 773, "Символ шквала клинков", 773, "Символ шока", 773, "Символ щита мстителя", 773, "Символ щита праведности", 773, "Символ элементаля воды", 773, "Символ ястреба", 773, "Сумеречный фолиант", 773, "Таинственная карта удачи", 773, "Фолиант в железном переплете" },
	[43127] = { 773, "Великое начертание журавлиного крыла", 773, "Великое начертание клыка тигра", 773, "Великое начертание когтя тигра", 773, "Великое начертание рога быка", 773, "Исследование нордскольского начертания", 773, "Карта Новолуния: Север", 773, "Книга крови", 773, "Книга молитв", 773, "Лики Судьбы", 773, "Мастерское начертание бури", 773, "Мастерское начертание вершины", 773, "Мастерское начертание секиры", 773, "Мастерское начертание скалы", 773, "Рунический свиток стойкости", 773, "Свиток беса скверны", 773, "Свиток высвобожденного элементаля", 773, "Свиток грызунов", 773, "Свиток наблюдателя", 773, "Свиток повелителя Бездны", 773, "Свиток стража гнева", 773, "Свиток упыря", 773, "Свиток шиварры", 773, "Символ ангелов", 773, "Символ всеполгощающей тьмы", 773, "Символ громового удара", 773, "Символ звездной пыли", 773, "Символ крылатого отмщения", 773, "Символ маскировки", 773, "Символ мясника", 773, "Символ переполняющей мощи", 773, "Символ пира для воронов", 773, "Символ смертельной стужи", 773, "Символ тления", 773, "Символ увеличения питомца", 773, "Символ черепов", 773, "Фолиант в железном переплете" },
	[43501] = { 185, "Аппетитный кекс" },
	[44128] = { 165, "Благословенные кенарийские сапоги", 165, "Боевые наручи лунной тени", 165, "Бриджи одичавшей природы", 165, "Гнилостный пояс из шкур вурдалаков", 165, "Заколдованная нерубская кираса", 165, "Заряженные молнией поножи", 165, "Земляные накладки для поножей", 165, "Кираса рыцаря из чешуи дракона", 165, "Меховая подкладка - выносливость", 165, "Меховая подкладка - сила атаки", 165, "Меховая подкладка - сила заклинаний", 165, "Меховая подкладка - сопротивление магии льда", 165, "Меховая подкладка - сопротивление огню", 165, "Меховая подкладка - сопротивление силам природы", 165, "Меховая подкладка - сопротивление тайной магии", 165, "Меховая подкладка - сопротивление темной магии", 165, "Набедренники из осколков драконьих костей", 165, "Надежная накидка из нерубской шкуры", 165, "Накладки для поножей из ледяной чешуи", 165, "Накладки для поножей из снежной шкуры", 165, "Наручи быстрой смерти", 165, "Наручи рыцаря из чешуи дракона", 165, "Несносимые ботфорты", 165, "Одеяния лунного затмения", 165, "Опаленный смертью пояс", 165, "Опоясок с ножами для снятия шкур", 165, "Панцирь рыцарского проклятья", 165, "Плащ ледяного убийцы", 165, "Поножи клинка", 165, "Пояс драконов", 165, "Пояс полярной жизни", 165, "Поясное хранилище тяжелых игл", 165, "Прочные земляные накладки для поножей", 165, "Прочные накладки для поножей из ледяной чешуи", 165, "Прочные накладки для поножей из снежной шкуры", 165, "Сапоги духа земли", 165, "Сапоги зимней закалки", 165, "Сапоги из живой чешуи", 165, "Сапоги надвигающейся смерти", 165, "Сапоги тишины", 165, "Сапоги ударившей молнии", 165, "Синий пояс Хаоса", 165, "Уплотненный пояс из электрохимеры", 165, "Черные хитиновые наручи", 202, "Анжинерский чоппер", 202, "Гоблинский планер", 202, "Механоцикл", 202, "Трицикл", 202, "Турботрицикл", 202, "Чоппер изгоя" },
	[44499] = { 202, "Анжинерский чоппер", 202, "Механоцикл", 202, "Чоппер изгоя" },
	[44500] = { 202, "Анжинерский чоппер", 202, "Механоцикл", 202, "Чоппер изгоя" },
	[44501] = { 202, "Анжинерский чоппер", 202, "Гоблинский планер", 202, "Механоцикл", 202, "Трицикл", 202, "Турботрицикл", 202, "Чоппер изгоя" },
	[44834] = { 185, "Запеченная индейка" },
	[44835] = { 185, "Запеченная индейка", 185, "Засахаренный батат", 185, "Пряная хлебная запеканка" },
	[44853] = { 185, "Запеченная индейка", 185, "Засахаренный батат", 185, "Клюквенный соус", 185, "Тыквенный пирог" },
	[44854] = { 185, "Клюквенный соус" },
	[44855] = { 185, "Засахаренный батат" },
	[44958] = { 171, "Эликсир хождения по воде", 333, "Чары для перчаток - рыболов" },
	[45087] = { 164, "Зубчатые смертеносы", 164, "Латные сапоги военачальника", 164, "Латный ремень правоты", 164, "Несокрушимый латный ремень", 164, "Нити судьбы", 164, "Пояс титанов", 165, "Опаленный смертью пояс", 165, "Пояс драконов", 165, "Пояс полярной жизни", 165, "Сапоги зимней закалки", 165, "Сапоги из живой чешуи", 165, "Сапоги тишины", 165, "Сапоги ударившей молнии", 165, "Синий пояс Хаоса", 197, "Кушак древней силы", 197, "Туфли спасителя", 197, "Туфли тонких чар", 197, "Шнурованный ремень светлого утра" },
	[46784] = { 185, "Тыквенный пирог" },
	[46793] = { 185, "Клюквенный соус" },
	[46796] = { 185, "Тыквенный пирог" },
	[46797] = { 185, "Засахаренный батат" },
	[47556] = { 164, "Кираса Белого Рыцаря", 164, "Кираса Кузни Солнца", 164, "Наручи Кузни Солнца", 164, "Саронитовые мечеломы", 164, "Титановые нагрудные пластины", 164, "Титановые шипованные наручи", 165, "Боевые наручи лунной тени", 165, "Заколдованная нерубская кираса", 165, "Кираса рыцаря из чешуи дракона", 165, "Наручи быстрой смерти", 165, "Наручи рыцаря из чешуи дракона", 165, "Одеяния лунного затмения", 165, "Панцирь рыцарского проклятья", 165, "Черные хитиновые наручи", 197, "Королевские наручи из лунного тюля", 197, "Королевское одеяние из лунного тюля", 197, "Наручи волшебника с самоцветами", 197, "Одеяние Мерлина" },
	[49908] = { 164, "Защитники жизни", 164, "Костомолы леденящего ада", 164, "Ножные латы из чистой стали", 164, "Ножные латы мучительной смерти", 164, "Сапоги королевского бунта", 164, "Столпы мощи", 165, "Благословенные кенарийские сапоги", 165, "Бриджи одичавшей природы", 165, "Заряженные молнией поножи", 165, "Набедренники из осколков драконьих костей", 165, "Несносимые ботфорты", 165, "Поножи клинка", 165, "Сапоги духа земли", 165, "Сапоги надвигающейся смерти", 197, "Поножи паутины смерти", 197, "Сандалии освящения", 197, "Сапоги смертной стужи", 197, "Светлотканые поножи", 202, "Армированные биооптические очки бойца", 202, "Армированные биооптические очки защитника", 202, "Армированные биооптические очки целителя", 202, "Облегченные биооптические очки заклинателя", 202, "Облегченные биооптические очки целителя", 202, "Повышающие проворство биооптические очки бойца", 202, "Повышающие проворство биооптические очки заклинателя", 202, "Повышающие проворство биооптические очки целителя", 202, "Смертоносные биооптические очки бойца", 202, "Смертоносные биооптические очки заклинателя", 202, "Смертоносные биооптические очки целителя" },
	[51950] = { 164, "Большой меч кровавой расправы", 164, "Варварский меч", 164, "Заточка иссушения разума", 164, "Изысканная кираса из закаленного колчедана", 164, "Изысканные ботинки из закаленного колчедана", 164, "Изысканные набедренники из закаленного колчедана", 164, "Изысканные наплечники из закаленного колчедана", 164, "Изысканные наручи из закаленного колчедана", 164, "Изысканные рукавицы из закаленного колчедана", 164, "Изысканный пояс из закаленного колчедана", 164, "Изысканный шлем из закаленного колчедана", 164, "Испытующий топор", 164, "Колчедановые пластины", 164, "Колчедановый щит рассвета", 164, "Колчедановый щит сумерек", 164, "Копье удлинившихся теней", 164, "Поводья разрушителя-железнонога", 164, "Призрачный осколок искусной работы", 164, "Укрепленная кираса из закаленного колчедана", 164, "Укрепленные ботинки из закаленного колчедана", 164, "Укрепленные набедренники из закаленного колчедана", 164, "Укрепленные наплечники из закаленного колчедана", 164, "Укрепленные наручи из закаленного колчедана", 164, "Укрепленные рукавицы из закаленного колчедана", 164, "Укрепленный пояс из закаленного колчедана", 164, "Укрепленный шлем из закаленного колчедана", 164, "Шипастая кираса из закаленного колчедана", 164, "Шипастые ботинки из закаленного колчедана", 164, "Шипастые набедренники из закаленного колчедана", 164, "Шипастые наплечники из закаленного колчедана", 164, "Шипастые наручи из закаленного колчедана", 164, "Шипастые рукавицы из закаленного колчедана", 164, "Шипастый пояс из закаленного колчедана", 164, "Шипастый шлем из закаленного колчедана", 164, "Яунгольский факел", 171, "Трансмутация: истинное золото", 202, "Автоматический молот", 202, "Амуниция с колчедановым наконечником", 202, "Гоблинское бургербекю", 202, "Затемненный зеркальный прицел", 202, "Колчедановый детонатор", 202, "Механокот модели Х-995", 202, "Образцовый гномский армейский нож", 202, "Прицел быстрорукого Джека", 202, "Термическая наковальня" },
	[52177] = { 171, "Трансмутация мглистого алмаза", 755, "Блистательный сердолик", 755, "Изысканный сердолик", 755, "Изящный сердолик", 755, "Непоколебимый сердолик", 755, "Растрескавшийся сердолик", 755, "Резонирующее кольцо гнева", 755, "Рельефный сердолик", 755, "Рунический сердолик", 755, "Треснутый блистательный сердолик", 755, "Треснутый изысканный сердолик", 755, "Треснутый изящный сердолик", 755, "Треснутый непоколебимый сердолик", 755, "Треснутый растрескавшийся сердолик", 755, "Треснутый рельефный сердолик", 755, "Треснутый рунический сердолик", 755, "Треснутый яркий сердолик", 755, "Треснутый ясный сердолик", 755, "Яркий сердолик", 755, "Ясный сердолик" },
	[52178] = { 171, "Трансмутация мглистого алмаза", 755, "Блестящий зефирит", 755, "Грозовой зефирит", 755, "Искрящийся зефирит", 755, "Кольцо полуночного неба", 755, "Ограненный камень хиджальских гор", 755, "Треснутый блестящий зефирит", 755, "Треснутый грозовой зефирит", 755, "Треснутый искрящийся зефирит", 755, "Треснутый цельный зефирит", 755, "Цельный зефирит" },
	[52179] = { 171, "Трансмутация мглистого алмаза", 755, "Гладкий алицит", 755, "Матовый алицит", 755, "Мистический алицит", 755, "Мягкий алицит", 755, "Прочный алицит", 755, "Сверкающий алицит", 755, "Стойкий алицит", 755, "Треснутый гладкий алицит", 755, "Треснутый матовый алицит", 755, "Треснутый мистический алицит", 755, "Треснутый мягкий алицит", 755, "Треснутый прочный алицит", 755, "Треснутый сверкающий алицит", 755, "Треснутый стойкий алицит", 755, "Усиливающее слух кольцо преступника" },
	[52180] = { 171, "Трансмутация мглистого алмаза", 755, "Всевластный камень ночи", 755, "Заряженный камень ночи", 755, "Изменчивый камень ночи", 755, "Камень ночи защитника", 755, "Камень ночи стража", 755, "Кольцо полуночного неба", 755, "Королевский камень ночи", 755, "Монарший камень ночи", 755, "Монументальный камень ночи", 755, "Наследный камень императора", 755, "Непрочный камень ночи", 755, "Очищенный камень ночи", 755, "Сбалансированный камень ночи", 755, "Светящийся камень ночи", 755, "Таинственный камень ночи", 755, "Треснутый всевластный камень ночи", 755, "Треснутый заряженный камень ночи", 755, "Треснутый изменчивый камень ночи", 755, "Треснутый камень ночи защитника", 755, "Треснутый камень ночи стража", 755, "Треснутый королевский камень ночи", 755, "Треснутый монарший камень ночи", 755, "Треснутый монументальный камень ночи", 755, "Треснутый непрочный камень ночи", 755, "Треснутый очищенный камень ночи", 755, "Треснутый сбалансированный камень ночи", 755, "Треснутый светящийся камень ночи", 755, "Треснутый таинственный камень ночи", 755, "Треснутый царственный камень ночи", 755, "Царственный камень ночи" },
	[52181] = { 171, "Трансмутация мглистого алмаза", 755, "Блистающий гессонит", 755, "Броский гессонит", 755, "Гессонит авангарда", 755, "Гессонит варвара", 755, "Гессонит защитника", 755, "Гессонит проворства", 755, "Гессонит фехтовальщика", 755, "Гибельный гессонит", 755, "Глянцевый гессонит", 755, "Гравированный гессонит", 755, "Грубый гессонит", 755, "Застывший гессонит", 755, "Затвердевший гессонит", 755, "Идеально ограненный гессонит", 755, "Краеугольный гессонит", 755, "Мерцающий гессонит", 755, "Могущественный гессонит", 755, "Надежный гессонит", 755, "Наделенный силой гессонит", 755, "Наследный камень императора", 755, "Нетронутый гессонит", 755, "Округленный гессонит", 755, "Покрытый письменами гессонит", 755, "Прозрачный гессонит", 755, "Светоносный гессонит", 755, "Смертоносный гессонит", 755, "Сокрытый гессонит", 755, "Стойкий гессонит", 755, "Тревожный гессонит", 755, "Треснутый блистающий гессонит", 755, "Треснутый броский гессонит", 755, "Треснутый гессонит авангарда", 755, "Треснутый гессонит варвара", 755, "Треснутый гессонит защитника", 755, "Треснутый гессонит проворства", 755, "Треснутый гессонит фехтовальщика", 755, "Треснутый гибельный гессонит", 755, "Треснутый глянцевый гессонит", 755, "Треснутый гравированный гессонит", 755, "Треснутый грубый гессонит", 755, "Треснутый застывший гессонит", 755, "Треснутый затвердевший гессонит", 755, "Треснутый идеально ограненный гессонит", 755, "Треснутый краеугольный гессонит", 755, "Треснутый мерцающий гессонит", 755, "Треснутый могущественный гессонит", 755, "Треснутый надежный гессонит", 755, "Треснутый наделенный силой гессонит", 755, "Треснутый нетронутый гессонит", 755, "Треснутый округленный гессонит", 755, "Треснутый покрытый письменами гессонит", 755, "Треснутый прозрачный гессонит", 755, "Треснутый светоносный гессонит", 755, "Треснутый смертоносный гессонит", 755, "Треснутый сокрытый гессонит", 755, "Треснутый стойкий гессонит", 755, "Треснутый тревожный гессонит", 755, "Усиливающее слух кольцо преступника" },
	[52182] = { 171, "Трансмутация мглистого алмаза", 755, "Вневременная яшма", 755, "Зазубренная яшма", 755, "Замысловатая яшма", 755, "Крепкая Яшма", 755, "Лучистая яшма", 755, "Мощная яшма", 755, "Насыщенная яшма", 755, "Неизменная яшма", 755, "Непрозрачная яшма", 755, "Ограненный камень хиджальских гор", 755, "Ослепительная яшма", 755, "Отверделая яшма", 755, "Плотная яшма", 755, "Померкшая яшма", 755, "Раздробленная яшма", 755, "Расколотая яшма", 755, "Резонирующее кольцо гнева", 755, "Светозарная яшма", 755, "Сияющая яшма", 755, "Смутная яшма", 755, "Треснутая вневременная яшма", 755, "Треснутая зазубренная яшма", 755, "Треснутая замысловатая яшма", 755, "Треснутая крепкая яшма", 755, "Треснутая лучистая яшма", 755, "Треснутая мощная яшма", 755, "Треснутая насыщенная яшма", 755, "Треснутая неизменная яшма", 755, "Треснутая непрозрачная яшма", 755, "Треснутая ослепительная яшма", 755, "Треснутая отверделая яшма", 755, "Треснутая плотная яшма", 755, "Треснутая померкшая яшма", 755, "Треснутая раздробленная яшма", 755, "Треснутая расколотая яшма", 755, "Треснутая светозарная яшма", 755, "Треснутая сияющая яшма", 755, "Треснутая смутная яшма", 755, "Треснутая усиленная яшма", 755, "Треснутая яшма провидца", 755, "Усиленная яшма", 755, "Яшма провидца" },
	[52183] = { 165, "Троекратно укрепленная шахтерская сумка", 186, "Выплавка колчедана" },
	[52185] = { 165, "Троекратно укрепленная шахтерская сумка", 186, "Выплавка элементия" },
	[52186] = { 164, "Элементиевое грузило", 164, "Элементиевое точило", 164, "Элементиевые пластины", 164, "Элементиевый щит рассвета", 164, "Элементиевый щит сумерек", 171, "Трансмутация: слиток колчедана", 186, "Выплавка закаленного элементия", 202, "Большой папочка", 202, "Гоблинское барбекю", 202, "Куробойка повышенной мощности", 202, "Летучий громоотвод", 202, "Летучий сефориевый взрывпакет", 202, "Прицел быстрорукого Джека", 202, "Прицел судьбы лорда Бумтингона", 202, "Синтетические очки типа \"B-ANK-J1R:\"", 202, "Синтетические очки типа \"B-ANK-M3D\"", 202, "Синтетические очки типа \"B-ANK-UK162\"", 202, "Синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Синтетические очки типа \"CHM-BK1N1-W1Z\"", 202, "Синтетические очки типа \"GA-CH1-M3D\"", 202, "Синтетические очки типа \"GA-CH1-UK162\"", 202, "Синтетические очки типа \"GA-CH1-W1Z\"", 202, "Синтетические очки типа \"L0-SKUT-M3D\"", 202, "Синтетические очки типа \"L0-SKUT-W1Z\"", 202, "Термостойкая вращающаяся наживка", 202, "Тонко отлаженный шприцевик", 202, "Элементиевые снаряды", 202, "Элементиевый дракончик" },
	[52188] = { 755, "Изысканное кольцо", 755, "Кольцо оступившегося льва", 755, "Мечта о Море", 755, "Ожерелье небесного мага", 755, "Ожерелье пылкого ума", 755, "Перстень повелителя", 755, "Подвеска с тигровым опалом", 755, "Сердце земли" },
	[52190] = { 165, "Роскошная шелковая сумка для самоцветов", 171, "Трансмутация: изначальный алмаз", 171, "Трансмутация: первозданный рубин", 202, "Летучий громоотвод", 202, "Синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Синтетические очки типа \"L0-SKUT-W1Z\"", 202, "Ударный шорох", 755, "Ожерелье пылкого ума", 755, "Поводья кристаллического охотника", 773, "Контракт с Картеля Трюмных Вод" },
	[52191] = { 165, "Роскошная шелковая сумка для самоцветов", 171, "Трансмутация: изначальный алмаз", 171, "Трансмутация: сердце реки", 202, "Синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Синтетические очки типа \"L0-SKUT-M3D\"", 755, "Изысканное кольцо", 755, "Поводья кристаллического охотника", 773, "Контракт с Изгнанниками Вайш'ира" },
	[52192] = { 165, "Роскошная шелковая сумка для самоцветов", 171, "Трансмутация: изначальный алмаз", 171, "Трансмутация: солнцесвет", 202, "Синтетические очки типа \"B-ANK-UK162\"", 202, "Синтетические очки типа \"GA-CH1-W1Z\"", 755, "Изысканное кольцо", 773, "Контракт с Орденом Белого Тигра", 773, "Контракт с Орденом Красного Журавля" },
	[52193] = { 165, "Роскошная шелковая сумка для самоцветов", 171, "Трансмутация: изначальный алмаз", 171, "Трансмутация: императорский аметист", 202, "Синтетические очки типа \"B-ANK-M3D\"", 202, "Синтетические очки типа \"GA-CH1-UK162\"", 202, "Тонко отлаженный шприцевик", 202, "Шпашко-метатель", 755, "Ожерелье пылкого ума", 773, "Контракт с Эльдранилом" },
	[52194] = { 165, "Роскошная шелковая сумка для самоцветов", 171, "Трансмутация: изначальный алмаз", 171, "Трансмутация: самородный нефрит", 202, "Синтетические очки типа \"B-ANK-J1R:\"", 202, "Синтетические очки типа \"GA-CH1-M3D\"", 755, "Ожерелье пылкого ума", 755, "Поводья кристаллического охотника", 773, "Контракт с Гилнеасом" },
	[52195] = { 165, "Роскошная шелковая сумка для самоцветов", 171, "Трансмутация: закатный оникс", 171, "Трансмутация: изначальный алмаз", 202, "Куробойка повышенной мощности", 202, "Курогилятор", 202, "Прицел судьбы лорда Бумтингона", 202, "Синтетические очки типа \"CHM-BK1N1-W1Z\"", 755, "Изысканное кольцо", 755, "Поводья кристаллического охотника", 773, "Контракт с Абимайскими искателями", 773, "Контракт с Артелем Барханного Ветра", 773, "Руководство по исследованию подземелий" },
	[52303] = { 755, "Бездушный мглистый алмаз", 755, "Вечный мглистый алмаз", 755, "Громовой мглистый алмаз", 755, "Жалкий мглистый алмаз", 755, "Жестокий мглистый алмаз", 755, "Живительный мглистый алмаз", 755, "Загадочный мглистый алмаз", 755, "Заостренный мглистый алмаз", 755, "Лучащийся мглистый алмаз", 755, "Лучезарный мглистый алмаз", 755, "Могущественный мглистый алмаз", 755, "Незыблемый мглистый алмаз", 755, "Нерушимый мглистый алмаз", 755, "Неустанный мглистый алмаз", 755, "Оживляющий мглистый алмаз", 755, "Провидческий мглистый алмаз", 755, "Разрушительный мглистый алмаз", 755, "Стремительный мглистый алмаз", 755, "Строгий мглистый алмаз", 755, "Угасающий мглистый алмаз", 755, "Хаотический мглистый алмаз" },
	[52325] = { 129, "Масло из улетной рыбы", 164, "Большой меч кровавой расправы", 164, "Бритва обезглавливателя", 164, "Изысканная кираса из закаленного колчедана", 164, "Изысканные ботинки из закаленного колчедана", 164, "Изысканные набедренники из закаленного колчедана", 164, "Изысканные наплечники из закаленного колчедана", 164, "Изысканные наручи из закаленного колчедана", 164, "Изысканные рукавицы из закаленного колчедана", 164, "Изысканный пояс из закаленного колчедана", 164, "Изысканный шлем из закаленного колчедана", 164, "Испытующий топор", 164, "Копье удлинившихся теней", 164, "Обсидиановый палач", 164, "Укрепленная кираса из закаленного колчедана", 164, "Укрепленные ботинки из закаленного колчедана", 164, "Укрепленные набедренники из закаленного колчедана", 164, "Укрепленные наплечники из закаленного колчедана", 164, "Укрепленные наручи из закаленного колчедана", 164, "Укрепленные рукавицы из закаленного колчедана", 164, "Укрепленный пояс из закаленного колчедана", 164, "Укрепленный шлем из закаленного колчедана", 164, "Факел очищения", 164, "Шипастая кираса из закаленного колчедана", 164, "Шипастые ботинки из закаленного колчедана", 164, "Шипастые набедренники из закаленного колчедана", 164, "Шипастые наплечники из закаленного колчедана", 164, "Шипастые наручи из закаленного колчедана", 164, "Шипастые рукавицы из закаленного колчедана", 164, "Шипастый пояс из закаленного колчедана", 164, "Шипастый шлем из закаленного колчедана", 164, "Элементиевый щит рассвета", 164, "Яунгольский факел", 165, "Яростные наплечники мрачных глубин", 165, "Яростные наплечники приручителя протодраконов", 165, "Яростные наручи мрачных глубин", 165, "Яростные наручи приручителя протодраконов", 165, "Яростные перчатки мрачных глубин", 165, "Яростные перчатки приручителя протодраконов", 165, "Яростные поножи мрачных глубин", 165, "Яростные поножи приручителя протодраконов", 165, "Яростные сапоги мрачных глубин", 165, "Яростные сапоги приручителя протодраконов", 165, "Яростный нагрудный доспех мрачных глубин", 165, "Яростный нагрудный доспех приручителя протодраконов", 165, "Яростный пояс мрачных глубин", 165, "Яростный пояс приручителя протодраконов", 165, "Яростный шлем мрачных глубин", 165, "Яростный шлем приручителя протодраконов", 171, "Трансмутация: истинное золото", 202, "Генератор червоточины: Фельярд", 202, "Летучий громоотвод", 202, "Термостойкая вращающаяся наживка", 202, "Ударный шорох" },
	[52326] = { 129, "Концентрат энергии Кришадалиса", 164, "Колчедановый щит рассвета", 164, "Призрачный осколок", 164, "Призрачный осколок искусной работы", 164, "Факел очищения", 164, "Яунгольский факел", 165, "Искусно изготовленный плащ защитника пределов", 165, "Нетронутые глубоководные накладки для поножей", 165, "Поводья выносливой винторогой гарны", 165, "Таинственные наплечники мрачных глубин", 165, "Таинственные наплечники приручителя протодраконов", 165, "Таинственные наручи мрачных глубин", 165, "Таинственные наручи приручителя протодраконов", 165, "Таинственные перчатки мрачных глубин", 165, "Таинственные перчатки приручителя протодраконов", 165, "Таинственные поножи мрачных глубин", 165, "Таинственные поножи приручителя протодраконов", 165, "Таинственные сапоги мрачных глубин", 165, "Таинственные сапоги приручителя протодраконов", 165, "Таинственный нагрудный доспех мрачных глубин", 165, "Таинственный нагрудный доспех приручителя протодраконов", 165, "Таинственный пояс мрачных глубин", 165, "Таинственный пояс приручителя протодраконов", 165, "Таинственный шлем мрачных глубин", 165, "Таинственный шлем приручителя протодраконов", 171, "Трансмутация: истинное золото", 197, "Реликвия прошлого: Портняжное дело", 202, "Генератор червоточины: Фельярд", 773, "Инкрустированный серебром посох", 773, "Покрытый шипами посох" },
	[52327] = { 129, "Бальзам с глазом огра", 164, "Варварский меч", 164, "Изысканная кираса из закаленного обсидиана", 164, "Изысканные ботинки из закаленного обсидиана", 164, "Изысканные набедренники из закаленного обсидиана", 164, "Изысканные наплечники из закаленного обсидиана", 164, "Изысканные наручи из закаленного обсидиана", 164, "Изысканные рукавицы из закаленного обсидиана", 164, "Изысканный пояс из закаленного обсидиана", 164, "Изысканный шлем из закаленного обсидиана", 164, "Копье удлинившихся теней", 164, "Обсидиановый бердыш", 164, "Обсидиановый палач", 164, "Прочный меч", 164, "Укрепленная кираса из закаленного обсидиана", 164, "Укрепленные ботинки из закаленного обсидиана", 164, "Укрепленные набедренники из закаленного обсидиана", 164, "Укрепленные наплечники из закаленного обсидиана", 164, "Укрепленные наручи из закаленного обсидиана", 164, "Укрепленные рукавицы из закаленного обсидиана", 164, "Укрепленный пояс из закаленного обсидиана", 164, "Укрепленный шлем из закаленного обсидиана", 164, "Шипастая кираса из закаленного обсидиана", 164, "Шипастые ботинки из закаленного обсидиана", 164, "Шипастые набедренники из закаленного обсидиана", 164, "Шипастые наплечники из закаленного обсидиана", 164, "Шипастые наручи из закаленного обсидиана", 164, "Шипастые рукавицы из закаленного обсидиана", 164, "Шипастый пояс из закаленного обсидиана", 164, "Шипастый шлем из закаленного обсидиана", 164, "Элементиевый щит сумерек", 165, "Нетронутые укрепленные накладки для поножей", 171, "Трансмутация: слиток колчедана", 186, "Выплавка закаленного элементия", 202, "Генератор червоточины: Фельярд", 202, "Электростатический конденсатор", 773, "Покрытый шипами посох" },
	[52328] = { 164, "Заточка иссушения разума", 164, "Заточка холодной закалки", 164, "Колчедановый щит сумерек", 164, "Копье удлинившихся теней", 164, "Обсидиановый бердыш", 165, "Искусно изготовленная накидка борца со смертью", 165, "Нетронутые жестокие накладки для поножей", 165, "Поводья выносливой винторогой гарны", 171, "Трансмутация: истинное золото", 202, "Генератор червоточины: Фельярд", 202, "Синтетические очки типа \"B-ANK-J1R:\"", 202, "Синтетические очки типа \"B-ANK-M3D\"", 202, "Синтетические очки типа \"B-ANK-UK162\"", 202, "Синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Синтетические очки типа \"CHM-BK1N1-W1Z\"", 202, "Синтетические очки типа \"GA-CH1-M3D\"", 202, "Синтетические очки типа \"GA-CH1-UK162\"", 202, "Синтетические очки типа \"GA-CH1-W1Z\"", 202, "Синтетические очки типа \"L0-SKUT-M3D\"", 202, "Синтетические очки типа \"L0-SKUT-W1Z\"", 773, "Ключ к иным мирам" },
	[52329] = { 129, "Противоядие Седой Лапы", 165, "Изысканные наплечники мрачных глубин", 165, "Изысканные наплечники приручителя протодраконов", 165, "Изысканные наручи мрачных глубин", 165, "Изысканные наручи приручителя протодраконов", 165, "Изысканные перчатки мрачных глубин", 165, "Изысканные перчатки приручителя протодраконов", 165, "Изысканные поножи мрачных глубин", 165, "Изысканные поножи приручителя протодраконов", 165, "Изысканные сапоги мрачных глубин", 165, "Изысканные сапоги приручителя протодраконов", 165, "Изысканный нагрудный доспех мрачных глубин", 165, "Изысканный нагрудный доспех приручителя протодраконов", 165, "Изысканный пояс мрачных глубин", 165, "Изысканный пояс приручителя протодраконов", 165, "Изысканный шлем мрачных глубин", 165, "Изысканный шлем приручителя протодраконов", 165, "Поводья выносливой винторогой гарны", 165, "Сумка мастера травника", 171, "Алхимический дзен-камень", 171, "Великий котел войны", 171, "Котел войны", 171, "Малый настой весенних цветов", 171, "Малый настой земли", 171, "Малый настой кусачих морозов", 171, "Малый настой ласкового солнца", 171, "Малый настой опадающих листьев", 171, "Настой весенних цветов", 171, "Настой земли", 171, "Настой кусачих морозов", 171, "Настой ласкового солнца", 171, "Настой опадающих листьев", 171, "Трансмутация: живые стихии", 197, "Ковер-самолет древней знати", 197, "Песня жизни", 197, "Реликвия прошлого: Портняжное дело", 202, "Колчедановый детонатор", 202, "Лечебная граната истинного золота", 202, "Образцовый гномский армейский нож", 773, "Божественный спутник", 773, "Инкрустированный серебром посох", 773, "Рунический посох" },
	[52555] = { 333, "Поводья манапарда чародея", 333, "Простая божественная субстанция", 333, "Фельярдские чары для нагрудника - броня", 333, "Фельярдские чары для нагрудника - восполнение маны", 333, "Фельярдские чары для нагрудника - выносливость", 333, "Фельярдские чары для нагрудника - дух", 333, "Фельярдские чары для нагрудника - защита", 333, "Фельярдские чары для нагрудника - интеллект", 333, "Фельярдские чары для нагрудника - критический удар", 333, "Фельярдские чары для нагрудника - ловкость", 333, "Фельярдские чары для нагрудника - мастерство", 333, "Фельярдские чары для нагрудника - меткость", 333, "Фельярдские чары для нагрудника - парирование", 333, "Фельярдские чары для нагрудника - показатель блокирования", 333, "Фельярдские чары для нагрудника - пробивание брони", 333, "Фельярдские чары для нагрудника - проникающая способность заклинаний", 333, "Фельярдские чары для нагрудника - рейтинг блокирования", 333, "Фельярдские чары для нагрудника - сила", 333, "Фельярдские чары для нагрудника - сила атаки", 333, "Фельярдские чары для нагрудника - сила заклинаний", 333, "Фельярдские чары для нагрудника - скорость", 333, "Фельярдские чары для нагрудника - сопротивление стихиям", 333, "Фельярдские чары для нагрудника - уклонение", 333, "Фельярдские чары для нагрудника - устойчивость", 333, "Фельярдские чары для наручей - броня", 333, "Фельярдские чары для наручей - восполнение маны", 333, "Фельярдские чары для наручей - выносливость", 333, "Фельярдские чары для наручей - дух", 333, "Фельярдские чары для наручей - защита", 333, "Фельярдские чары для наручей - интеллект", 333, "Фельярдские чары для наручей - критический удар", 333, "Фельярдские чары для наручей - ловкость", 333, "Фельярдские чары для наручей - мастерство", 333, "Фельярдские чары для наручей - меткость", 333, "Фельярдские чары для наручей - парирование", 333, "Фельярдские чары для наручей - показатель блокирования", 333, "Фельярдские чары для наручей - пробивание брони", 333, "Фельярдские чары для наручей - проникающая способность заклинаний", 333, "Фельярдские чары для наручей - рейтинг блокирования", 333, "Фельярдские чары для наручей - сила", 333, "Фельярдские чары для наручей - сила атаки", 333, "Фельярдские чары для наручей - сила заклинаний", 333, "Фельярдские чары для наручей - скорость", 333, "Фельярдские чары для наручей - сопротивление стихиям", 333, "Фельярдские чары для наручей - уклонение", 333, "Фельярдские чары для наручей - устойчивость", 333, "Фельярдские чары для обуви - броня", 333, "Фельярдские чары для обуви - восполнение маны", 333, "Фельярдские чары для обуви - выносливость", 333, "Фельярдские чары для обуви - дух", 333, "Фельярдские чары для обуви - защита", 333, "Фельярдские чары для обуви - интеллект", 333, "Фельярдские чары для обуви - критический удар", 333, "Фельярдские чары для обуви - ловкость", 333, "Фельярдские чары для обуви - мастерство", 333, "Фельярдские чары для обуви - меткость", 333, "Фельярдские чары для обуви - парирование", 333, "Фельярдские чары для обуви - показатель блокирования", 333, "Фельярдские чары для обуви - пробивание брони", 333, "Фельярдские чары для обуви - проникающая способность заклинаний", 333, "Фельярдские чары для обуви - рейтинг блокирования", 333, "Фельярдские чары для обуви - сила", 333, "Фельярдские чары для обуви - сила атаки", 333, "Фельярдские чары для обуви - сила заклинаний", 333, "Фельярдские чары для обуви - скорость", 333, "Фельярдские чары для обуви - сопротивление стихиям", 333, "Фельярдские чары для обуви - уклонение", 333, "Фельярдские чары для обуви - устойчивость", 333, "Фельярдские чары для перчаток - броня", 333, "Фельярдские чары для перчаток - восполнение маны", 333, "Фельярдские чары для перчаток - выносливость", 333, "Фельярдские чары для перчаток - дух", 333, "Фельярдские чары для перчаток - защита", 333, "Фельярдские чары для перчаток - интеллект", 333, "Фельярдские чары для перчаток - критический удар", 333, "Фельярдские чары для перчаток - ловкость", 333, "Фельярдские чары для перчаток - мастерство", 333, "Фельярдские чары для перчаток - меткость", 333, "Фельярдские чары для перчаток - парирование", 333, "Фельярдские чары для перчаток - показатель блокирования", 333, "Фельярдские чары для перчаток - пробивание брони", 333, "Фельярдские чары для перчаток - проникающая способность заклинаний", 333, "Фельярдские чары для перчаток - рейтинг блокирования", 333, "Фельярдские чары для перчаток - сила", 333, "Фельярдские чары для перчаток - сила атаки", 333, "Фельярдские чары для перчаток - сила заклинаний", 333, "Фельярдские чары для перчаток - скорость", 333, "Фельярдские чары для перчаток - сопротивление стихиям", 333, "Фельярдские чары для перчаток - уклонение", 333, "Фельярдские чары для перчаток - устойчивость", 333, "Фельярдские чары для плаща - броня", 333, "Фельярдские чары для плаща - восполнение маны", 333, "Фельярдские чары для плаща - выносливость", 333, "Фельярдские чары для плаща - дух", 333, "Фельярдские чары для плаща - защита", 333, "Фельярдские чары для плаща - интеллект", 333, "Фельярдские чары для плаща - критический удар", 333, "Фельярдские чары для плаща - ловкость", 333, "Фельярдские чары для плаща - мастерство", 333, "Фельярдские чары для плаща - меткость", 333, "Фельярдские чары для плаща - парирование", 333, "Фельярдские чары для плаща - показатель блокирования", 333, "Фельярдские чары для плаща - пробивание брони", 333, "Фельярдские чары для плаща - проникающая способность заклинаний", 333, "Фельярдские чары для плаща - рейтинг блокирования", 333, "Фельярдские чары для плаща - сила", 333, "Фельярдские чары для плаща - сила атаки", 333, "Фельярдские чары для плаща - сила заклинаний", 333, "Фельярдские чары для плаща - скорость", 333, "Фельярдские чары для плаща - сопротивление стихиям", 333, "Фельярдские чары для плаща - уклонение", 333, "Фельярдские чары для плаща - устойчивость", 333, "Фельярдские чары для щита - броня", 333, "Фельярдские чары для щита - восполнение маны", 333, "Фельярдские чары для щита - выносливость", 333, "Фельярдские чары для щита - дух", 333, "Фельярдские чары для щита - защита", 333, "Фельярдские чары для щита - интеллект", 333, "Фельярдские чары для щита - критический удар", 333, "Фельярдские чары для щита - мастерство", 333, "Фельярдские чары для щита - меткость", 333, "Фельярдские чары для щита - парирование", 333, "Фельярдские чары для щита - показатель блокирования", 333, "Фельярдские чары для щита - пробивание брони", 333, "Фельярдские чары для щита - проникающая способность заклинаний", 333, "Фельярдские чары для щита - рейтинг блокирования", 333, "Фельярдские чары для щита - сила", 333, "Фельярдские чары для щита - сила заклинаний", 333, "Фельярдские чары для щита - скорость", 333, "Фельярдские чары для щита - сопротивление стихиям", 333, "Фельярдские чары для щита - уклонение", 333, "Фельярдские чары для щита - устойчивость", 333, "Фельярские чары для двуручного оружия - благодать Ранульфа", 333, "Фельярские чары для двуручного оружия - дыхание Сиф", 333, "Фельярские чары для двуручного оружия - мощь Бьорна", 333, "Фельярские чары для двуручного оружия - оберег Исулдофа", 333, "Фельярские чары для двуручного оружия - пламя Фенгира", 333, "Фельярские чары для двуручного оружия - проклятие Имирона", 333, "Фельярские чары для двуручного оружия - увядание Галдора", 333, "Фельярские чары для двуручного оружия - чародейство Квалда", 333, "Фельярские чары для одноручного оружия - благодать Ранульфа", 333, "Фельярские чары для одноручного оружия - дыхание Сиф", 333, "Фельярские чары для одноручного оружия - мощь Бьорна", 333, "Фельярские чары для одноручного оружия - оберег Исулдофа", 333, "Фельярские чары для одноручного оружия - пламя Фенгира", 333, "Фельярские чары для одноручного оружия - проклятие Имирона", 333, "Фельярские чары для одноручного оружия - увядание Галдора", 333, "Фельярские чары для одноручного оружия - чародейство Квалда", 333, "Чары для двуручного оружия - пламя Фенгира", 333, "Чары для двуручного оружия - увядание Галдора", 333, "Чары для двуручного оружия - чародейство Квалда", 333, "Чары для нагрудника - броня", 333, "Чары для нагрудника - броня II", 333, "Чары для нагрудника - восполнение маны III", 333, "Чары для нагрудника - восполнение маны IV", 333, "Чары для нагрудника - все характеристики IX", 333, "Чары для нагрудника - все характеристики X", 333, "Чары для нагрудника - защита IV", 333, "Чары для нагрудника - защита V", 333, "Чары для нагрудника - мастерство", 333, "Чары для нагрудника - мастерство II", 333, "Чары для нагрудника - меткость", 333, "Чары для нагрудника - меткость II", 333, "Чары для нагрудника - устойчивость IV", 333, "Чары для нагрудника - устойчивость V", 333, "Чары для наручей - броня II", 333, "Чары для наручей - восполнение маны III", 333, "Чары для наручей - выносливость IX", 333, "Чары для наручей - дух IX", 333, "Чары для наручей - интеллект VI", 333, "Чары для наручей - ловкость III", 333, "Чары для наручей - мастерство IV", 333, "Чары для наручей - сила VII", 333, "Чары для наручей - сила атаки II", 333, "Чары для наручей - сила заклинаний VI", 333, "Чары для обуви - выносливость", 333, "Чары для обуви - сила атаки", 333, "Чары для обуви - сила заклинаний", 333, "Чары для одноручного оружия - пламя Фенгира", 333, "Чары для одноручного оружия - увядание Галдора", 333, "Чары для одноручного оружия - чародейство Квалда", 333, "Чары для перчаток - восполнение маны", 333, "Чары для перчаток - выносливость", 333, "Чары для перчаток - мастерство III", 333, "Чары для перчаток - сила атаки", 333, "Чары для плаща - броня", 333, "Чары для плаща - броня II", 333, "Чары для плаща - восполнение маны", 333, "Чары для плаща - восполнение маны II", 333, "Чары для плаща - выносливость", 333, "Чары для плаща - выносливость II", 333, "Чары для плаща - защита", 333, "Чары для плаща - защита II", 333, "Чары для плаща - ловкость VII", 333, "Чары для плаща - ловкость VIII", 333, "Чары для плаща - мастерство", 333, "Чары для плаща - мастерство II", 333, "Чары для плаща - меткость", 333, "Чары для плаща - меткость II", 333, "Чары для плаща - пронзающие заклинания III", 333, "Чары для плаща - сила атаки", 333, "Чары для плаща - сила атаки II", 333, "Чары для плаща - сила заклинаний", 333, "Чары для плаща - сила заклинаний II", 333, "Чары для плаща - скорость III", 333, "Чары для плаща - скорость IV", 333, "Чары для плаща - сопротивление VI", 333, "Чары для плаща - сопротивление VII", 333, "Чары для щита - блокирование II", 333, "Чары для щита - восполнение маны II", 333, "Чары для щита - выносливость II", 333, "Чары для щита - защита II", 333, "Чары для щита - интеллект II", 333, "Чары для щита - показатель блокирования II", 333, "Чары для щита - сила заклинаний II", 333, "Чары для щита - сопротивление VII", 333, "Чары для щита - устойчивость II" },
	[52718] = { 165, "Трансцендентная сумка", 333, "Малый небесный осколок", 333, "Распыление простой божественная субстанция", 333, "Распыление простой божественной субстанции", 333, "Фельярдские чары для нагрудника - броня", 333, "Фельярдские чары для нагрудника - восполнение маны", 333, "Фельярдские чары для нагрудника - выносливость", 333, "Фельярдские чары для нагрудника - дух", 333, "Фельярдские чары для нагрудника - защита", 333, "Фельярдские чары для нагрудника - интеллект", 333, "Фельярдские чары для нагрудника - критический удар", 333, "Фельярдские чары для нагрудника - ловкость", 333, "Фельярдские чары для нагрудника - мастерство", 333, "Фельярдские чары для нагрудника - меткость", 333, "Фельярдские чары для нагрудника - парирование", 333, "Фельярдские чары для нагрудника - показатель блокирования", 333, "Фельярдские чары для нагрудника - пробивание брони", 333, "Фельярдские чары для нагрудника - проникающая способность заклинаний", 333, "Фельярдские чары для нагрудника - рейтинг блокирования", 333, "Фельярдские чары для нагрудника - сила", 333, "Фельярдские чары для нагрудника - сила атаки", 333, "Фельярдские чары для нагрудника - сила заклинаний", 333, "Фельярдские чары для нагрудника - скорость", 333, "Фельярдские чары для нагрудника - сопротивление стихиям", 333, "Фельярдские чары для нагрудника - уклонение", 333, "Фельярдские чары для нагрудника - устойчивость", 333, "Фельярдские чары для наручей - броня", 333, "Фельярдские чары для наручей - восполнение маны", 333, "Фельярдские чары для наручей - выносливость", 333, "Фельярдские чары для наручей - дух", 333, "Фельярдские чары для наручей - защита", 333, "Фельярдские чары для наручей - интеллект", 333, "Фельярдские чары для наручей - критический удар", 333, "Фельярдские чары для наручей - ловкость", 333, "Фельярдские чары для наручей - мастерство", 333, "Фельярдские чары для наручей - меткость", 333, "Фельярдские чары для наручей - парирование", 333, "Фельярдские чары для наручей - показатель блокирования", 333, "Фельярдские чары для наручей - пробивание брони", 333, "Фельярдские чары для наручей - проникающая способность заклинаний", 333, "Фельярдские чары для наручей - рейтинг блокирования", 333, "Фельярдские чары для наручей - сила", 333, "Фельярдские чары для наручей - сила атаки", 333, "Фельярдские чары для наручей - сила заклинаний", 333, "Фельярдские чары для наручей - скорость", 333, "Фельярдские чары для наручей - сопротивление стихиям", 333, "Фельярдские чары для наручей - уклонение", 333, "Фельярдские чары для наручей - устойчивость", 333, "Фельярдские чары для обуви - броня", 333, "Фельярдские чары для обуви - восполнение маны", 333, "Фельярдские чары для обуви - выносливость", 333, "Фельярдские чары для обуви - дух", 333, "Фельярдские чары для обуви - защита", 333, "Фельярдские чары для обуви - интеллект", 333, "Фельярдские чары для обуви - критический удар", 333, "Фельярдские чары для обуви - ловкость", 333, "Фельярдские чары для обуви - мастерство", 333, "Фельярдские чары для обуви - меткость", 333, "Фельярдские чары для обуви - парирование", 333, "Фельярдские чары для обуви - показатель блокирования", 333, "Фельярдские чары для обуви - пробивание брони", 333, "Фельярдские чары для обуви - проникающая способность заклинаний", 333, "Фельярдские чары для обуви - рейтинг блокирования", 333, "Фельярдские чары для обуви - сила", 333, "Фельярдские чары для обуви - сила атаки", 333, "Фельярдские чары для обуви - сила заклинаний", 333, "Фельярдские чары для обуви - скорость", 333, "Фельярдские чары для обуви - сопротивление стихиям", 333, "Фельярдские чары для обуви - уклонение", 333, "Фельярдские чары для обуви - устойчивость", 333, "Фельярдские чары для перчаток - броня", 333, "Фельярдские чары для перчаток - восполнение маны", 333, "Фельярдские чары для перчаток - выносливость", 333, "Фельярдские чары для перчаток - дух", 333, "Фельярдские чары для перчаток - защита", 333, "Фельярдские чары для перчаток - интеллект", 333, "Фельярдские чары для перчаток - критический удар", 333, "Фельярдские чары для перчаток - ловкость", 333, "Фельярдские чары для перчаток - мастерство", 333, "Фельярдские чары для перчаток - меткость", 333, "Фельярдские чары для перчаток - парирование", 333, "Фельярдские чары для перчаток - показатель блокирования", 333, "Фельярдские чары для перчаток - пробивание брони", 333, "Фельярдские чары для перчаток - проникающая способность заклинаний", 333, "Фельярдские чары для перчаток - рейтинг блокирования", 333, "Фельярдские чары для перчаток - сила", 333, "Фельярдские чары для перчаток - сила атаки", 333, "Фельярдские чары для перчаток - сила заклинаний", 333, "Фельярдские чары для перчаток - скорость", 333, "Фельярдские чары для перчаток - сопротивление стихиям", 333, "Фельярдские чары для перчаток - уклонение", 333, "Фельярдские чары для перчаток - устойчивость", 333, "Фельярдские чары для плаща - броня", 333, "Фельярдские чары для плаща - восполнение маны", 333, "Фельярдские чары для плаща - выносливость", 333, "Фельярдские чары для плаща - дух", 333, "Фельярдские чары для плаща - защита", 333, "Фельярдские чары для плаща - интеллект", 333, "Фельярдские чары для плаща - критический удар", 333, "Фельярдские чары для плаща - ловкость", 333, "Фельярдские чары для плаща - мастерство", 333, "Фельярдские чары для плаща - меткость", 333, "Фельярдские чары для плаща - парирование", 333, "Фельярдские чары для плаща - показатель блокирования", 333, "Фельярдские чары для плаща - пробивание брони", 333, "Фельярдские чары для плаща - проникающая способность заклинаний", 333, "Фельярдские чары для плаща - рейтинг блокирования", 333, "Фельярдские чары для плаща - сила", 333, "Фельярдские чары для плаща - сила атаки", 333, "Фельярдские чары для плаща - сила заклинаний", 333, "Фельярдские чары для плаща - скорость", 333, "Фельярдские чары для плаща - сопротивление стихиям", 333, "Фельярдские чары для плаща - уклонение", 333, "Фельярдские чары для плаща - устойчивость", 333, "Фельярдские чары для щита - броня", 333, "Фельярдские чары для щита - восполнение маны", 333, "Фельярдские чары для щита - выносливость", 333, "Фельярдские чары для щита - дух", 333, "Фельярдские чары для щита - защита", 333, "Фельярдские чары для щита - интеллект", 333, "Фельярдские чары для щита - критический удар", 333, "Фельярдские чары для щита - мастерство", 333, "Фельярдские чары для щита - меткость", 333, "Фельярдские чары для щита - парирование", 333, "Фельярдские чары для щита - показатель блокирования", 333, "Фельярдские чары для щита - пробивание брони", 333, "Фельярдские чары для щита - проникающая способность заклинаний", 333, "Фельярдские чары для щита - рейтинг блокирования", 333, "Фельярдские чары для щита - сила", 333, "Фельярдские чары для щита - сила заклинаний", 333, "Фельярдские чары для щита - скорость", 333, "Фельярдские чары для щита - сопротивление стихиям", 333, "Фельярдские чары для щита - уклонение", 333, "Фельярдские чары для щита - устойчивость", 333, "Чары для двуручного оружия - мощь Бьорна", 333, "Чары для двуручного оружия - проклятие Имирона", 333, "Чары для нагрудника - броня", 333, "Чары для нагрудника - броня II", 333, "Чары для нагрудника - восполнение маны III", 333, "Чары для нагрудника - восполнение маны IV", 333, "Чары для нагрудника - все характеристики IX", 333, "Чары для нагрудника - все характеристики X", 333, "Чары для нагрудника - защита IV", 333, "Чары для нагрудника - защита V", 333, "Чары для нагрудника - мастерство", 333, "Чары для нагрудника - мастерство II", 333, "Чары для нагрудника - меткость", 333, "Чары для нагрудника - меткость II", 333, "Чары для нагрудника - устойчивость IV", 333, "Чары для нагрудника - устойчивость V", 333, "Чары для наручей - броня", 333, "Чары для наручей - восполнение маны II", 333, "Чары для наручей - выносливость VIII", 333, "Чары для наручей - дух VIII", 333, "Чары для наручей - интеллект V", 333, "Чары для наручей - ловкость II", 333, "Чары для наручей - мастерство III", 333, "Чары для наручей - сила VI", 333, "Чары для наручей - сила атаки", 333, "Чары для наручей - сила заклинаний V", 333, "Чары для обуви - броня", 333, "Чары для обуви - восполнение маны", 333, "Чары для обуви - выносливость", 333, "Чары для обуви - меткость II", 333, "Чары для одноручного оружия - мощь Бьорна", 333, "Чары для одноручного оружия - проклятие Имирона", 333, "Чары для перчаток - восполнение маны", 333, "Чары для перчаток - восполнение маны II", 333, "Чары для перчаток - выносливость", 333, "Чары для перчаток - выносливость II", 333, "Чары для перчаток - мастерство III", 333, "Чары для перчаток - мастерство IV", 333, "Чары для перчаток - сила атаки", 333, "Чары для перчаток - сила атаки II", 333, "Чары для перчаток - сила заклинаний IV", 333, "Чары для плаща - броня", 333, "Чары для плаща - восполнение маны", 333, "Чары для плаща - выносливость", 333, "Чары для плаща - защита", 333, "Чары для плаща - ловкость VII", 333, "Чары для плаща - мастерство", 333, "Чары для плаща - меткость", 333, "Чары для плаща - сила атаки", 333, "Чары для плаща - сила заклинаний", 333, "Чары для плаща - скорость III", 333, "Чары для плаща - сопротивление VI", 333, "Чары для щита - блокирование", 333, "Чары для щита - блокирование II", 333, "Чары для щита - восполнение маны", 333, "Чары для щита - восполнение маны II", 333, "Чары для щита - выносливость", 333, "Чары для щита - выносливость II", 333, "Чары для щита - защита", 333, "Чары для щита - защита II", 333, "Чары для щита - интеллект", 333, "Чары для щита - интеллект II", 333, "Чары для щита - показатель блокирования", 333, "Чары для щита - показатель блокирования II", 333, "Чары для щита - сила заклинаний", 333, "Чары для щита - сила заклинаний II", 333, "Чары для щита - сопротивление VI", 333, "Чары для щита - сопротивление VII", 333, "Чары для щита - устойчивость", 333, "Чары для щита - устойчивость II" },
	[52719] = { 333, "Поводья манапарда чародея", 333, "Фельярские чары для двуручного оружия - благодать Ранульфа", 333, "Фельярские чары для двуручного оружия - дыхание Сиф", 333, "Фельярские чары для двуручного оружия - мощь Бьорна", 333, "Фельярские чары для двуручного оружия - оберег Исулдофа", 333, "Фельярские чары для двуручного оружия - пламя Фенгира", 333, "Фельярские чары для двуручного оружия - проклятие Имирона", 333, "Фельярские чары для двуручного оружия - увядание Галдора", 333, "Фельярские чары для двуручного оружия - чародейство Квалда", 333, "Фельярские чары для одноручного оружия - благодать Ранульфа", 333, "Фельярские чары для одноручного оружия - дыхание Сиф", 333, "Фельярские чары для одноручного оружия - мощь Бьорна", 333, "Фельярские чары для одноручного оружия - оберег Исулдофа", 333, "Фельярские чары для одноручного оружия - пламя Фенгира", 333, "Фельярские чары для одноручного оружия - проклятие Имирона", 333, "Фельярские чары для одноручного оружия - увядание Галдора", 333, "Фельярские чары для одноручного оружия - чародейство Квалда", 333, "Чары для двуручного оружия - благодать Ранульфа", 333, "Чары для двуручного оружия - дыхание Сиф", 333, "Чары для двуручного оружия - оберег Исулдофа", 333, "Чары для двуручного оружия - руническая вязь Нарфи", 333, "Чары для нагрудника - броня", 333, "Чары для нагрудника - броня II", 333, "Чары для нагрудника - восполнение маны III", 333, "Чары для нагрудника - восполнение маны IV", 333, "Чары для нагрудника - все характеристики IX", 333, "Чары для нагрудника - все характеристики X", 333, "Чары для нагрудника - защита IV", 333, "Чары для нагрудника - защита V", 333, "Чары для нагрудника - мастерство", 333, "Чары для нагрудника - мастерство II", 333, "Чары для нагрудника - меткость", 333, "Чары для нагрудника - меткость II", 333, "Чары для нагрудника - устойчивость IV", 333, "Чары для нагрудника - устойчивость V", 333, "Чары для наручей - броня", 333, "Чары для наручей - броня II", 333, "Чары для наручей - восполнение маны II", 333, "Чары для наручей - восполнение маны III", 333, "Чары для наручей - выносливость IX", 333, "Чары для наручей - выносливость VIII", 333, "Чары для наручей - дух IX", 333, "Чары для наручей - дух VIII", 333, "Чары для наручей - интеллект V", 333, "Чары для наручей - интеллект VI", 333, "Чары для наручей - ловкость II", 333, "Чары для наручей - ловкость III", 333, "Чары для наручей - мастерство III", 333, "Чары для наручей - мастерство IV", 333, "Чары для наручей - сила VI", 333, "Чары для наручей - сила VII", 333, "Чары для наручей - сила атаки", 333, "Чары для наручей - сила атаки II", 333, "Чары для наручей - сила заклинаний V", 333, "Чары для наручей - сила заклинаний VI", 333, "Чары для обуви - броня II", 333, "Чары для обуви - восполнение маны II", 333, "Чары для обуви - выносливость II", 333, "Чары для обуви - меткость III", 333, "Чары для обуви - сила атаки", 333, "Чары для обуви - сила атаки II", 333, "Чары для обуви - сила заклинаний", 333, "Чары для обуви - сила заклинаний II", 333, "Чары для одноручного оружия - благодать Ранульфа", 333, "Чары для одноручного оружия - дыхание Сиф", 333, "Чары для одноручного оружия - оберег Исулдофа", 333, "Чары для одноручного оружия - руническая вязь Нарфи", 333, "Чары для щита - блокирование", 333, "Чары для щита - восполнение маны", 333, "Чары для щита - защита", 333, "Чары для щита - показатель блокирования", 333, "Чары для щита - сила заклинаний", 333, "Чары для щита - сопротивление VI", 333, "Чары для щита - устойчивость" },
	[52720] = { 165, "Трансцендентная сумка", 333, "Чары для двуручного оружия - дыхание Сиф", 333, "Чары для двуручного оружия - мощь Бьорна", 333, "Чары для двуручного оружия - оберег Исулдофа", 333, "Чары для двуручного оружия - пламя Фенгира", 333, "Чары для двуручного оружия - проклятие Имирона", 333, "Чары для двуручного оружия - руническая вязь Нарфи", 333, "Чары для наручей - броня II", 333, "Чары для наручей - восполнение маны III", 333, "Чары для наручей - выносливость IX", 333, "Чары для наручей - дух IX", 333, "Чары для наручей - интеллект VI", 333, "Чары для наручей - ловкость III", 333, "Чары для наручей - мастерство IV", 333, "Чары для наручей - сила VII", 333, "Чары для наручей - сила атаки II", 333, "Чары для наручей - сила заклинаний VI", 333, "Чары для обуви - броня II", 333, "Чары для обуви - восполнение маны II", 333, "Чары для обуви - выносливость II", 333, "Чары для обуви - меткость III", 333, "Чары для обуви - сила атаки II", 333, "Чары для обуви - сила заклинаний II", 333, "Чары для одноручного оружия - дыхание Сиф", 333, "Чары для одноручного оружия - мощь Бьорна", 333, "Чары для одноручного оружия - оберег Исулдофа", 333, "Чары для одноручного оружия - пламя Фенгира", 333, "Чары для одноручного оружия - проклятие Имирона", 333, "Чары для одноручного оружия - руническая вязь Нарфи", 333, "Чары для перчаток - восполнение маны II", 333, "Чары для перчаток - выносливость II", 333, "Чары для перчаток - мастерство IV", 333, "Чары для перчаток - сила атаки II", 333, "Чары для перчаток - сила заклинаний IV", 333, "Чары для плаща - броня II", 333, "Чары для плаща - восполнение маны II", 333, "Чары для плаща - выносливость II", 333, "Чары для плаща - защита II", 333, "Чары для плаща - ловкость VIII", 333, "Чары для плаща - мастерство II", 333, "Чары для плаща - меткость II", 333, "Чары для плаща - пронзающие заклинания III", 333, "Чары для плаща - сила атаки II", 333, "Чары для плаща - сила заклинаний II", 333, "Чары для плаща - скорость IV", 333, "Чары для плаща - сопротивление VII", 333, "Чары для щита - блокирование II", 333, "Чары для щита - восполнение маны II", 333, "Чары для щита - выносливость II", 333, "Чары для щита - защита II", 333, "Чары для щита - интеллект II", 333, "Чары для щита - показатель блокирования II", 333, "Чары для щита - сила заклинаний II", 333, "Чары для щита - сопротивление VII", 333, "Чары для щита - устойчивость II" },
	[52721] = { 333, "Дробление небесного осколока", 333, "Космический осколок", 333, "Фельярские чары для двуручного оружия - благодать Ранульфа", 333, "Фельярские чары для двуручного оружия - дыхание Сиф", 333, "Фельярские чары для двуручного оружия - мощь Бьорна", 333, "Фельярские чары для двуручного оружия - оберег Исулдофа", 333, "Фельярские чары для двуручного оружия - пламя Фенгира", 333, "Фельярские чары для двуручного оружия - проклятие Имирона", 333, "Фельярские чары для двуручного оружия - увядание Галдора", 333, "Фельярские чары для двуручного оружия - чародейство Квалда", 333, "Фельярские чары для одноручного оружия - благодать Ранульфа", 333, "Фельярские чары для одноручного оружия - дыхание Сиф", 333, "Фельярские чары для одноручного оружия - мощь Бьорна", 333, "Фельярские чары для одноручного оружия - оберег Исулдофа", 333, "Фельярские чары для одноручного оружия - пламя Фенгира", 333, "Фельярские чары для одноручного оружия - проклятие Имирона", 333, "Фельярские чары для одноручного оружия - увядание Галдора", 333, "Фельярские чары для одноручного оружия - чародейство Квалда", 333, "Чары для двуручного оружия - благодать Ранульфа", 333, "Чары для двуручного оружия - увядание Галдора", 333, "Чары для двуручного оружия - чародейство Квалда", 333, "Чары для нагрудника - броня II", 333, "Чары для нагрудника - восполнение маны IV", 333, "Чары для нагрудника - все характеристики X", 333, "Чары для нагрудника - защита V", 333, "Чары для нагрудника - мастерство II", 333, "Чары для нагрудника - меткость II", 333, "Чары для нагрудника - устойчивость V", 333, "Чары для одноручного оружия - благодать Ранульфа", 333, "Чары для одноручного оружия - увядание Галдора", 333, "Чары для одноручного оружия - чародейство Квалда" },
	[52976] = { 165, "Изысканные наплечники с клеймом тьмы", 165, "Изысканные наплечники цунами", 165, "Изысканные наручи с клеймом тьмы", 165, "Изысканные наручи цунами", 165, "Изысканные перчатки с клеймом тьмы", 165, "Изысканные перчатки цунами", 165, "Изысканные поножи с клеймом тьмы", 165, "Изысканные поножи цунами", 165, "Изысканные сапоги с клеймом тьмы", 165, "Изысканные сапоги цунами", 165, "Изысканный нагрудный доспех с клеймом тьмы", 165, "Изысканный нагрудный доспех цунами", 165, "Изысканный пояс с клеймом тьмы", 165, "Изысканный пояс цунами", 165, "Изысканный шлем с клеймом тьмы", 165, "Изысканный шлем цунами", 165, "Накидка борца со смертью", 165, "Нетронутые жестокие накладки для поножей", 165, "Плащ защитника пределов", 165, "Сильно огрубелая кожа", 165, "Таинственные наплечники с клеймом тьмы", 165, "Таинственные наплечники цунами", 165, "Таинственные наручи с клеймом тьмы", 165, "Таинственные наручи цунами", 165, "Таинственные перчатки с клеймом тьмы", 165, "Таинственные перчатки цунами", 165, "Таинственные поножи с клеймом тьмы", 165, "Таинственные поножи цунами", 165, "Таинственные сапоги с клеймом тьмы", 165, "Таинственные сапоги цунами", 165, "Таинственный нагрудный доспех с клеймом тьмы", 165, "Таинственный нагрудный доспех цунами", 165, "Таинственный пояс с клеймом тьмы", 165, "Таинственный пояс цунами", 165, "Таинственный шлем с клеймом тьмы", 165, "Таинственный шлем цунами", 165, "Яростные наплечники с клеймом тьмы", 165, "Яростные наплечники цунами", 165, "Яростные наручи с клеймом тьмы", 165, "Яростные наручи цунами", 165, "Яростные перчатки с клеймом тьмы", 165, "Яростные перчатки цунами", 165, "Яростные поножи с клеймом тьмы", 165, "Яростные поножи цунами", 165, "Яростные сапоги с клеймом тьмы", 165, "Яростные сапоги цунами", 165, "Яростный нагрудный доспех с клеймом тьмы", 165, "Яростный нагрудный доспех цунами", 165, "Яростный пояс с клеймом тьмы", 165, "Яростный пояс цунами", 165, "Яростный шлем с клеймом тьмы", 165, "Яростный шлем цунами", 202, "Куробойка повышенной мощности", 202, "Курогилятор", 202, "Подлинные очки мл. инженера" },
	[52980] = { 165, "Изысканные наплечники мрачных глубин", 165, "Изысканные наплечники приручителя протодраконов", 165, "Изысканные наручи мрачных глубин", 165, "Изысканные наручи приручителя протодраконов", 165, "Изысканные перчатки мрачных глубин", 165, "Изысканные перчатки приручителя протодраконов", 165, "Изысканные поножи мрачных глубин", 165, "Изысканные поножи приручителя протодраконов", 165, "Изысканные сапоги мрачных глубин", 165, "Изысканные сапоги приручителя протодраконов", 165, "Изысканный нагрудный доспех мрачных глубин", 165, "Изысканный нагрудный доспех приручителя протодраконов", 165, "Изысканный пояс мрачных глубин", 165, "Изысканный пояс приручителя протодраконов", 165, "Изысканный шлем мрачных глубин", 165, "Изысканный шлем приручителя протодраконов", 165, "Нетронутые глубоководные накладки для поножей", 165, "Нетронутые жестокие накладки для поножей", 165, "Нетронутые укрепленные накладки для поножей", 165, "Поводья выносливой винторогой гарны", 165, "Таинственные наплечники мрачных глубин", 165, "Таинственные наплечники приручителя протодраконов", 165, "Таинственные наручи мрачных глубин", 165, "Таинственные наручи приручителя протодраконов", 165, "Таинственные перчатки мрачных глубин", 165, "Таинственные перчатки приручителя протодраконов", 165, "Таинственные поножи мрачных глубин", 165, "Таинственные поножи приручителя протодраконов", 165, "Таинственные сапоги мрачных глубин", 165, "Таинственные сапоги приручителя протодраконов", 165, "Таинственный нагрудный доспех мрачных глубин", 165, "Таинственный нагрудный доспех приручителя протодраконов", 165, "Таинственный пояс мрачных глубин", 165, "Таинственный пояс приручителя протодраконов", 165, "Таинственный шлем мрачных глубин", 165, "Таинственный шлем приручителя протодраконов", 165, "Яростные наплечники мрачных глубин", 165, "Яростные наплечники приручителя протодраконов", 165, "Яростные наручи мрачных глубин", 165, "Яростные наручи приручителя протодраконов", 165, "Яростные перчатки мрачных глубин", 165, "Яростные перчатки приручителя протодраконов", 165, "Яростные поножи мрачных глубин", 165, "Яростные поножи приручителя протодраконов", 165, "Яростные сапоги мрачных глубин", 165, "Яростные сапоги приручителя протодраконов", 165, "Яростный нагрудный доспех мрачных глубин", 165, "Яростный нагрудный доспех приручителя протодраконов", 165, "Яростный пояс мрачных глубин", 165, "Яростный пояс приручителя протодраконов", 165, "Яростный шлем мрачных глубин", 165, "Яростный шлем приручителя протодраконов" },
	[52982] = { 165, "Барабаны неистовства", 165, "Глубоководные накладки для поножей", 165, "Изысканные наплечники мрачных глубин", 165, "Изысканные наручи мрачных глубин", 165, "Изысканные перчатки мрачных глубин", 165, "Изысканные поножи мрачных глубин", 165, "Изысканные сапоги мрачных глубин", 165, "Изысканный нагрудный доспех мрачных глубин", 165, "Изысканный пояс мрачных глубин", 165, "Изысканный шлем мрачных глубин", 165, "Искусно изготовленный плащ защитника пределов", 165, "Нетронутые глубоководные накладки для поножей", 165, "Плащ защитника пределов", 165, "Поводья выносливой винторогой гарны", 165, "Сумка из великолепной шкуры", 165, "Таинственные наплечники мрачных глубин", 165, "Таинственные наручи мрачных глубин", 165, "Таинственные перчатки мрачных глубин", 165, "Таинственные поножи мрачных глубин", 165, "Таинственные сапоги мрачных глубин", 165, "Таинственный нагрудный доспех мрачных глубин", 165, "Таинственный пояс мрачных глубин", 165, "Таинственный шлем мрачных глубин", 165, "Яростные наплечники мрачных глубин", 165, "Яростные наручи мрачных глубин", 165, "Яростные перчатки мрачных глубин", 165, "Яростные поножи мрачных глубин", 165, "Яростные сапоги мрачных глубин", 165, "Яростный нагрудный доспех мрачных глубин", 165, "Яростный пояс мрачных глубин", 165, "Яростный шлем мрачных глубин" },
	[52983] = { 165, "Сумка мастера травника", 171, "Алхимический дзен-камень", 171, "Алхимический камень жизни", 171, "Зелье маны мастера", 171, "Зелье поиска сокровищ Фельярда", 171, "Зелье чистой ярости", 171, "Малый настой ласкового солнца", 171, "Малый настой опадающих листьев", 171, "Малый эликсир азарта", 171, "Малый эликсир ведьмы", 171, "Малый эликсир вооружения", 171, "Настой ласкового солнца", 171, "Настой опадающих листьев", 171, "Неустойчивый алхимический камень", 171, "Переменчивый алхимический камень", 171, "Резонирующий алхимический камень", 171, "Трансмутация: угасающий топаз", 171, "Эликсир азарта", 171, "Эликсир ведьмы", 171, "Эликсир вооружения" },
	[52984] = { 171, "Алхимический дзен-камень", 171, "Алхимический камень жизни", 171, "Зелье поиска сокровищ Фельярда", 171, "Зелье чистой магии", 171, "Малый настой кусачих морозов", 171, "Малый эликсир азарта", 171, "Малый эликсир монаха", 171, "Малый эликсир стремительности", 171, "Настой кусачих морозов", 171, "Неустойчивый алхимический камень", 171, "Переменчивый алхимический камень", 171, "Резонирующий алхимический камень", 171, "Трансмутация: изумруд грез", 171, "Эликсир азарта", 171, "Эликсир монаха", 171, "Эликсир стремительности" },
	[52985] = { 165, "Сумка мастера травника", 171, "Алхимический дзен-камень", 171, "Алхимический камень жизни", 171, "Зелье поиска сокровищ Фельярда", 171, "Малый настой кусачих морозов", 171, "Малый настой опадающих листьев", 171, "Малый эликсир безупречности", 171, "Малый эликсир отражений", 171, "Малый эликсир подземелий", 171, "Малый эликсир упорства", 171, "Настой кусачих морозов", 171, "Настой опадающих листьев", 171, "Неустойчивый алхимический камень", 171, "Переменчивый алхимический камень", 171, "Резонирующий алхимический камень", 171, "Трансмутация: морской сапфир", 171, "Эликсир безупречности", 171, "Эликсир отражений", 171, "Эликсир подземелий", 171, "Эликсир упорства" },
	[52986] = { 171, "Алхимический дзен-камень", 171, "Алхимический камень жизни", 171, "Зелье непреклонности", 171, "Зелье поиска сокровищ Фельярда", 171, "Малый настой земли", 171, "Малый настой ласкового солнца", 171, "Малый эликсир вооружения", 171, "Малый эликсир наставника", 171, "Малый эликсир отражений", 171, "Малый эликсир спокойствия", 171, "Настой земли", 171, "Настой ласкового солнца", 171, "Неустойчивый алхимический камень", 171, "Переменчивый алхимический камень", 171, "Резонирующий алхимический камень", 171, "Трансмутация: инфернальный рубин", 171, "Эликсир вооружения", 171, "Эликсир наставника", 171, "Эликсир отражений", 171, "Эликсир спокойствия" },
	[52987] = { 165, "Сумка мастера травника", 171, "Алхимический дзен-камень", 171, "Алхимический камень жизни", 171, "Алхимическое зелье омоложения", 171, "Зелье поиска сокровищ Фельярда", 171, "Лечебное зелье мастера", 171, "Малый настой весенних цветов", 171, "Малый эликсир безупречности", 171, "Малый эликсир ведьмы", 171, "Малый эликсир монаха", 171, "Малый эликсир подземелий", 171, "Настой весенних цветов", 171, "Неустойчивый алхимический камень", 171, "Переменчивый алхимический камень", 171, "Резонирующий алхимический камень", 171, "Трансмутация: око демона", 171, "Эликсир безупречности", 171, "Эликсир ведьмы", 171, "Эликсир монаха", 171, "Эликсир подземелий" },
	[52988] = { 171, "Алхимический дзен-камень", 171, "Алхимический камень жизни", 171, "Алхимическое зелье омоложения", 171, "Зелье маны мастера", 171, "Зелье поиска сокровищ Фельярда", 171, "Малый настой весенних цветов", 171, "Малый настой земли", 171, "Малый эликсир наставника", 171, "Малый эликсир спокойствия", 171, "Малый эликсир стремительности", 171, "Малый эликсир упорства", 171, "Настой весенних цветов", 171, "Настой земли", 171, "Неустойчивый алхимический камень", 171, "Переменчивый алхимический камень", 171, "Резонирующий алхимический камень", 171, "Трансмутация: янтарный самоцвет", 171, "Эликсир наставника", 171, "Эликсир спокойствия", 171, "Эликсир стремительности", 171, "Эликсир упорства" },
	[53038] = { 165, "Троекратно укрепленная шахтерская сумка", 186, "Выплавка обсидиана" },
	[53039] = { 164, "Большой меч кровавой расправы", 164, "Изысканная кираса из закаленного колчедана", 164, "Изысканные ботинки из закаленного колчедана", 164, "Изысканные набедренники из закаленного колчедана", 164, "Изысканные наплечники из закаленного колчедана", 164, "Изысканные наручи из закаленного колчедана", 164, "Изысканные рукавицы из закаленного колчедана", 164, "Изысканный пояс из закаленного колчедана", 164, "Изысканный шлем из закаленного колчедана", 164, "Поводья разрушителя-железнонога", 164, "Укрепленная кираса из закаленного колчедана", 164, "Укрепленные ботинки из закаленного колчедана", 164, "Укрепленные набедренники из закаленного колчедана", 164, "Укрепленные наплечники из закаленного колчедана", 164, "Укрепленные наручи из закаленного колчедана", 164, "Укрепленные рукавицы из закаленного колчедана", 164, "Укрепленный пояс из закаленного колчедана", 164, "Укрепленный шлем из закаленного колчедана", 164, "Шипастая кираса из закаленного колчедана", 164, "Шипастые ботинки из закаленного колчедана", 164, "Шипастые набедренники из закаленного колчедана", 164, "Шипастые наплечники из закаленного колчедана", 164, "Шипастые наручи из закаленного колчедана", 164, "Шипастые рукавицы из закаленного колчедана", 164, "Шипастый пояс из закаленного колчедана", 164, "Шипастый шлем из закаленного колчедана", 164, "Элементиевая цепь для оружия", 164, "Элементиевый шип для щита", 202, "Заряженные синтетические очки типа \"B-ANK-J1R:\"", 202, "Заряженные синтетические очки типа \"B-ANK-M3D\"", 202, "Заряженные синтетические очки типа \"B-ANK-UK162\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-W1Z\"", 202, "Заряженные синтетические очки типа \"GA-CH1-M3D\"", 202, "Заряженные синтетические очки типа \"GA-CH1-UK162\"", 202, "Заряженные синтетические очки типа \"GA-CH1-W1Z\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-M3D\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-W1Z\"", 202, "Затемненный зеркальный прицел", 202, "Механокот модели Х-995", 202, "Прицел быстрорукого Джека" },
	[54849] = { 164, "Гнутый обсидиан", 202, "Высокомощный крепежный пистолет", 202, "Горсть обсидиановых болтов", 202, "Затемненный зеркальный прицел", 202, "Зеркальный прицел", 202, "Искрящийся эфир", 202, "Обсидиановый дракончик", 202, "Подлинные очки мл. инженера", 202, "Электростатический конденсатор" },
	[56516] = { 165, "Барабаны неистовства", 165, "Жестокие накладки для поножей", 165, "Изысканные наплечники с клеймом тьмы", 165, "Изысканные наплечники цунами", 165, "Изысканные наручи с клеймом тьмы", 165, "Изысканные наручи цунами", 165, "Изысканные перчатки с клеймом тьмы", 165, "Изысканные перчатки цунами", 165, "Изысканные поножи с клеймом тьмы", 165, "Изысканные поножи цунами", 165, "Изысканные сапоги с клеймом тьмы", 165, "Изысканные сапоги цунами", 165, "Изысканный нагрудный доспех с клеймом тьмы", 165, "Изысканный нагрудный доспех цунами", 165, "Изысканный пояс с клеймом тьмы", 165, "Изысканный пояс цунами", 165, "Изысканный шлем с клеймом тьмы", 165, "Изысканный шлем цунами", 165, "Искусно изготовленная накидка борца со смертью", 165, "Искусно изготовленный плащ защитника пределов", 165, "Нетронутая шкура", 165, "Роскошная шелковая сумка для самоцветов", 165, "Сумка из великолепной шкуры", 165, "Сумка королевского начертателя", 165, "Сумка мастера травника", 165, "Таинственные наплечники с клеймом тьмы", 165, "Таинственные наплечники цунами", 165, "Таинственные наручи с клеймом тьмы", 165, "Таинственные наручи цунами", 165, "Таинственные перчатки с клеймом тьмы", 165, "Таинственные перчатки цунами", 165, "Таинственные поножи с клеймом тьмы", 165, "Таинственные поножи цунами", 165, "Таинственные сапоги с клеймом тьмы", 165, "Таинственные сапоги цунами", 165, "Таинственный нагрудный доспех с клеймом тьмы", 165, "Таинственный нагрудный доспех цунами", 165, "Таинственный пояс с клеймом тьмы", 165, "Таинственный пояс цунами", 165, "Таинственный шлем с клеймом тьмы", 165, "Таинственный шлем цунами", 165, "Трансцендентная сумка", 165, "Троекратно укрепленная шахтерская сумка", 165, "Укомплектованный ящик с инструментами", 165, "Яростные наплечники с клеймом тьмы", 165, "Яростные наплечники цунами", 165, "Яростные наручи с клеймом тьмы", 165, "Яростные наручи цунами", 165, "Яростные перчатки с клеймом тьмы", 165, "Яростные перчатки цунами", 165, "Яростные поножи с клеймом тьмы", 165, "Яростные поножи цунами", 165, "Яростные сапоги с клеймом тьмы", 165, "Яростные сапоги цунами", 165, "Яростный нагрудный доспех с клеймом тьмы", 165, "Яростный нагрудный доспех цунами", 165, "Яростный пояс с клеймом тьмы", 165, "Яростный пояс цунами", 165, "Яростный шлем с клеймом тьмы", 165, "Яростный шлем цунами" },
	[58480] = { 164, "Большой меч кровавой расправы", 164, "Варварский меч", 164, "Заточка иссушения разума", 164, "Испытующий топор", 164, "Колчедановый щит рассвета", 164, "Колчедановый щит сумерек", 164, "Копье удлинившихся теней", 164, "Призрачный осколок искусной работы", 164, "Яунгольский факел", 202, "Курогилятор", 202, "Лечебная граната истинного золота", 202, "Образцовый гномский армейский нож", 202, "Ударный шорох", 202, "Шпашко-метатель", 773, "Божественный спутник", 773, "Инкрустированный серебром посох", 773, "Ключ к иным мирам", 773, "Руководство по исследованию подземелий" },
	[60109] = { 755, "Стойкий алицит", 755, "Треснутый стойкий алицит" },
	[60110] = { 755, "Непоколебимый сердолик", 755, "Треснутый непоколебимый сердолик" },
	[60116] = { 755, "Слеза утопии" },
	[60224] = { 202, "Автоматический молот", 202, "Высокомощный крепежный пистолет", 202, "Гоблинское барбекю", 202, "Гоблинское бургербекю", 202, "Заряженные синтетические очки типа \"B-ANK-J1R:\"", 202, "Заряженные синтетические очки типа \"B-ANK-M3D\"", 202, "Заряженные синтетические очки типа \"B-ANK-UK162\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-W1Z\"", 202, "Заряженные синтетические очки типа \"GA-CH1-M3D\"", 202, "Заряженные синтетические очки типа \"GA-CH1-UK162\"", 202, "Заряженные синтетические очки типа \"GA-CH1-W1Z\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-M3D\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-W1Z\"", 202, "Затемненный зеркальный прицел", 202, "Зеркальный прицел", 202, "Колчедановый детонатор", 202, "Куробойка повышенной мощности", 202, "Курогилятор", 202, "Лечебная граната истинного золота", 202, "Механокот модели Х-995", 202, "Образцовый гномский армейский нож", 202, "Обсидиановый дракончик", 202, "Прицел быстрорукого Джека", 202, "Прицел судьбы лорда Бумтингона", 202, "Синтетические очки типа \"B-ANK-J1R:\"", 202, "Синтетические очки типа \"B-ANK-M3D\"", 202, "Синтетические очки типа \"B-ANK-UK162\"", 202, "Синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Синтетические очки типа \"CHM-BK1N1-W1Z\"", 202, "Синтетические очки типа \"GA-CH1-M3D\"", 202, "Синтетические очки типа \"GA-CH1-UK162\"", 202, "Синтетические очки типа \"GA-CH1-W1Z\"", 202, "Синтетические очки типа \"L0-SKUT-M3D\"", 202, "Синтетические очки типа \"L0-SKUT-W1Z\"", 202, "Термическая наковальня", 202, "Термостойкая вращающаяся наживка", 202, "Тонко отлаженный шприцевик", 202, "Шпашко-метатель", 202, "Электростатический конденсатор", 202, "Элементиевый дракончик" },
	[61978] = { 165, "Сумка королевского начертателя", 773, "Поводья акварельного лиса", 773, "Покрытый шипами посох", 773, "Рунический посох", 773, "Свиток абиссала", 773, "Свиток всех характеристик", 773, "Свиток критического удара", 773, "Свиток критического удара заклинаний", 773, "Свиток поганища", 773, "Свиток силы атаки", 773, "Свиток скорости", 773, "Свиток снижения урона", 773, "Свиток урона", 773, "Свиток эффективности лечения", 773, "Символ божественного вмешательства", 773, "Символ великого благословения", 773, "Символ воскрешения мертвых", 773, "Символ выгорания", 773, "Символ гальки", 773, "Символ дара дикой природы", 773, "Символ десертного угощения", 773, "Символ дикого гриба", 773, "Символ карманной коробки", 773, "Символ кровавого панциря", 773, "Символ мерцающего пламени", 773, "Символ молитвы духа", 773, "Символ молитвы защиты от темной магии", 773, "Символ молитвы стойкости", 773, "Символ неистового восстановления кошмара", 773, "Символ нокаута", 773, "Символ огненного рывка", 773, "Символ окоченевшего панциря", 773, "Символ перерождения", 773, "Символ подводного дыхания", 773, "Символ призрачного растворения", 773, "Символ пути леса", 773, "Символ пылающей ярости", 773, "Символ ритуала Рока", 773, "Символ столпа света", 773, "Символ уменьшения питомца", 773, "Символ чародейской гениальности", 773, "Символ щедрого угощения" },
	[61979] = { 773, "Воодушевление Аскеладда", 773, "Воодушевление Торкелля", 773, "Воодушевление Торфина", 773, "Мрачно-коричневые чернила", 773, "Фельярдский свиток возвращения", 773, "Фельярдский свиток защиты", 773, "Фельярдский свиток исцеления", 773, "Фельярдский свиток скорости" },
	[61980] = { 773, "Чернила Преисподней" },
	[61981] = { 773, "Божественный спутник", 773, "Инкрустированный серебром посох", 773, "Ключ к иным мирам", 773, "Контракт с Абимайскими искателями", 773, "Контракт с Артелем Барханного Ветра", 773, "Контракт с Гилнеасом", 773, "Контракт с Изгнанниками Вайш'ира", 773, "Контракт с Картеля Трюмных Вод", 773, "Контракт с Орденом Белого Тигра", 773, "Контракт с Орденом Красного Журавля", 773, "Контракт с Эльдранилом", 773, "Поводья акварельного лиса", 773, "Руководство по исследованию подземелий", 773, "Свиток всех характеристик", 773, "Свиток критического удара", 773, "Свиток критического удара заклинаний", 773, "Свиток силы атаки", 773, "Свиток скорости", 773, "Свиток снижения урона", 773, "Свиток урона", 773, "Свиток эффективности лечения", 773, "Символ пути леса" },
	[63274] = { 164, "Заточка иссушения разума" },
	[63311] = { 171, "Оскверненное масло" },
	[63314] = { 164, "Яунгольский факел" },
	[63316] = { 164, "Призрачный осколок искусной работы" },
	[63318] = { 202, "Ударный шорох" },
	[63319] = { 164, "Большой меч кровавой расправы" },
	[63322] = { 773, "Рунический посох" },
	[63323] = { 773, "Ключ к иным мирам" },
	[63327] = { 202, "Курогилятор" },
	[63328] = { 171, "Оскверненное масло" },
	[63337] = { 164, "Варварский меч" },
	[63341] = { 773, "Инкрустированный серебром посох" },
	[63342] = { 202, "Шпашко-метатель" },
	[63343] = { 164, "Испытующий топор" },
	[65365] = { 164, "Бритва обезглавливателя", 164, "Заточка холодной закалки", 164, "Изысканная кираса из закаленного обсидиана", 164, "Изысканные ботинки из закаленного обсидиана", 164, "Изысканные набедренники из закаленного обсидиана", 164, "Изысканные наплечники из закаленного обсидиана", 164, "Изысканные наручи из закаленного обсидиана", 164, "Изысканные рукавицы из закаленного обсидиана", 164, "Изысканный пояс из закаленного обсидиана", 164, "Изысканный шлем из закаленного обсидиана", 164, "Обсидиановая отмычка", 164, "Обсидиановая цепь для оружия", 164, "Обсидиановое грузило", 164, "Обсидиановое точило", 164, "Обсидиановый бердыш", 164, "Обсидиановый палач", 164, "Обсидиановый шип для щита", 164, "Поводья разрушителя-железнонога", 164, "Призрачный осколок", 164, "Прочный меч", 164, "Укрепленная кираса из закаленного обсидиана", 164, "Укрепленные ботинки из закаленного обсидиана", 164, "Укрепленные набедренники из закаленного обсидиана", 164, "Укрепленные наплечники из закаленного обсидиана", 164, "Укрепленные наручи из закаленного обсидиана", 164, "Укрепленные рукавицы из закаленного обсидиана", 164, "Укрепленный пояс из закаленного обсидиана", 164, "Укрепленный шлем из закаленного обсидиана", 164, "Факел очищения", 164, "Шипастая кираса из закаленного обсидиана", 164, "Шипастые ботинки из закаленного обсидиана", 164, "Шипастые набедренники из закаленного обсидиана", 164, "Шипастые наплечники из закаленного обсидиана", 164, "Шипастые наручи из закаленного обсидиана", 164, "Шипастые рукавицы из закаленного обсидиана", 164, "Шипастый пояс из закаленного обсидиана", 164, "Шипастый шлем из закаленного обсидиана", 165, "Укомплектованный ящик с инструментами" },
	[67319] = { 129, "Бальзам с глазом огра", 773, "Покрытый шипами посох" },
	[67749] = { 165, "Укомплектованный ящик с инструментами", 202, "Автоматический молот", 202, "Большой папочка", 202, "Высокомощный крепежный пистолет", 202, "Генератор червоточины: Фельярд", 202, "Заряженные синтетические очки типа \"B-ANK-J1R:\"", 202, "Заряженные синтетические очки типа \"B-ANK-M3D\"", 202, "Заряженные синтетические очки типа \"B-ANK-UK162\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-W1Z\"", 202, "Заряженные синтетические очки типа \"GA-CH1-M3D\"", 202, "Заряженные синтетические очки типа \"GA-CH1-UK162\"", 202, "Заряженные синтетические очки типа \"GA-CH1-W1Z\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-M3D\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-W1Z\"", 202, "Куробойка повышенной мощности", 202, "Курогилятор", 202, "Летучий громоотвод", 202, "Летучий сефориевый взрывпакет", 202, "Механокот модели Х-995", 202, "Образцовый гномский армейский нож", 202, "Обсидиановый дракончик", 202, "Синтетические очки типа \"B-ANK-J1R:\"", 202, "Синтетические очки типа \"B-ANK-M3D\"", 202, "Синтетические очки типа \"B-ANK-UK162\"", 202, "Синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Синтетические очки типа \"CHM-BK1N1-W1Z\"", 202, "Синтетические очки типа \"GA-CH1-M3D\"", 202, "Синтетические очки типа \"GA-CH1-UK162\"", 202, "Синтетические очки типа \"GA-CH1-W1Z\"", 202, "Синтетические очки типа \"L0-SKUT-M3D\"", 202, "Синтетические очки типа \"L0-SKUT-W1Z\"", 202, "Термическая наковальня", 202, "Тонко отлаженный шприцевик", 202, "Ударный шорох", 202, "Шпашко-метатель", 202, "Элементиевый дракончик" },
	[72988] = { 129, "Бинты из ветрошерсти", 129, "Плотные бинты из ветрошерсти", 197, "Императорский шелк", 197, "Рулон ветрошерстной ткани", 202, "Обсидиановый дракончик" },
	[74247] = { 333, "Дробление космического осколока", 333, "Поводья манапарда чародея", 333, "Фельярские чары для двуручного оружия - благодать Ранульфа", 333, "Фельярские чары для двуручного оружия - дыхание Сиф", 333, "Фельярские чары для двуручного оружия - мощь Бьорна", 333, "Фельярские чары для двуручного оружия - оберег Исулдофа", 333, "Фельярские чары для двуручного оружия - пламя Фенгира", 333, "Фельярские чары для двуручного оружия - проклятие Имирона", 333, "Фельярские чары для двуручного оружия - увядание Галдора", 333, "Фельярские чары для двуручного оружия - чародейство Квалда", 333, "Фельярские чары для одноручного оружия - благодать Ранульфа", 333, "Фельярские чары для одноручного оружия - дыхание Сиф", 333, "Фельярские чары для одноручного оружия - мощь Бьорна", 333, "Фельярские чары для одноручного оружия - оберег Исулдофа", 333, "Фельярские чары для одноручного оружия - пламя Фенгира", 333, "Фельярские чары для одноручного оружия - проклятие Имирона", 333, "Фельярские чары для одноручного оружия - увядание Галдора", 333, "Фельярские чары для одноручного оружия - чародейство Квалда", 333, "Чары для двуручного оружия - благодать Ранульфа", 333, "Чары для двуручного оружия - дыхание Сиф", 333, "Чары для двуручного оружия - мощь Бьорна", 333, "Чары для двуручного оружия - оберег Исулдофа", 333, "Чары для двуручного оружия - пламя Фенгира", 333, "Чары для двуручного оружия - проклятие Имирона", 333, "Чары для двуручного оружия - руническая вязь Нарфи", 333, "Чары для двуручного оружия - увядание Галдора", 333, "Чары для двуручного оружия - чародейство Квалда", 333, "Чары для одноручного оружия - благодать Ранульфа", 333, "Чары для одноручного оружия - дыхание Сиф", 333, "Чары для одноручного оружия - мощь Бьорна", 333, "Чары для одноручного оружия - оберег Исулдофа", 333, "Чары для одноручного оружия - пламя Фенгира", 333, "Чары для одноручного оружия - проклятие Имирона", 333, "Чары для одноручного оружия - руническая вязь Нарфи", 333, "Чары для одноручного оружия - увядание Галдора", 333, "Чары для одноручного оружия - чародейство Квалда" },
	[74659] = { 185, "Курица с арахисом на вертеле", 202, "Гоблинское бургербекю" },
	[74660] = { 185, "Пиво индивидуальных ощущений", 185, "Пикантный йогурт", 185, "Разрезанные персики", 185, "Сушеные персики" },
	[74661] = { 185, "Большое угощение в горшочке", 185, "Большое угощение на гриле", 185, "Жареная дичь", 185, "Жаренный на углях стейк из оленины", 185, "Крабовый сюрприз на пару", 185, "Лосось духов огня", 185, "Ребрышки с черным перцем и раками", 185, "Суп из клубящегося тумана", 185, "Сушеные опята", 185, "Угощение в горшочке", 185, "Угощение на гриле", 202, "Гоблинское барбекю" },
	[74662] = { 185, "Большое освежающее угощение", 185, "Большое угощение вок", 185, "Большое угощение из печи", 185, "Большое угощение на пару", 185, "Женьшеневый чай", 185, "Зеленый карри с рыбой", 185, "Клецки с раками-богомолами", 185, "Освежающее угощение", 185, "Пирожок с красной фасолью", 185, "Угощение вок", 185, "Угощение из печи", 185, "Угощение на пару", 185, "Хаустлундские фриттеры", 202, "Гоблинское бургербекю" },
	[74832] = { 185, "Большое освежающее угощение", 185, "Дамайча", 185, "Освежающее угощение" },
	[74833] = { 185, "Жаренный на углях стейк из оленины" },
	[74834] = { 185, "Ребрышки с черным перцем и раками" },
	[74837] = { 185, "Тушеное волчье мясо", 185, "Угощение на гриле", 202, "Гоблинское барбекю" },
	[74838] = { 185, "Крабовый сюрприз на пару", 185, "Суп из шустрого краба" },
	[74839] = { 185, "Жареная дичь", 185, "Стир-фрай долины", 185, "Суп из дичи с женьшенем", 185, "Угощение из печи" },
	[74840] = { 185, "Ребрышки с черным перцем и раками" },
	[74841] = { 185, "Освежающее угощение", 185, "Пассерованная морковь", 185, "Тушеное волчье мясо", 185, "Угощение вок" },
	[74842] = { 185, "Пиво индивидуальных ощущений", 185, "Угощение в горшочке" },
	[74843] = { 185, "Рисовая лапша морских туманов", 185, "Угощение вок" },
	[74844] = { 185, "Завтрак безумца", 185, "Лосось духов огня" },
	[74845] = { 185, "Большое освежающее угощение", 185, "Женьшеневый чай", 185, "Освежающее угощение", 185, "Суп из дичи с женьшенем" },
	[74846] = { 185, "Отвар нефритовой ведьмы", 185, "Пиво индивидуальных ощущений" },
	[74847] = { 185, "Острые овощные чипсы", 185, "Отвар нефритовой ведьмы", 185, "Угощение вок", 202, "Гоблинское барбекю" },
	[74848] = { 185, "Освежающее угощение", 185, "Рыба по-дольски" },
	[74849] = { 185, "Завтрак безумца", 185, "Острые овощные чипсы" },
	[74850] = { 185, "Крабовый сюрприз на пару" },
	[74851] = { 185, "Большое угощение вок", 185, "Зеленый карри с рыбой", 185, "Рисовый пудинг", 185, "Торт из молотого риса", 185, "Угощение вок" },
	[74852] = { 185, "Большое освежающее угощение", 185, "Домашний сыр из молока черпорога", 185, "Освежающее угощение", 185, "Пикантный йогурт", 185, "Рисовый пудинг", 185, "Чай с перламутровым молоком" },
	[74853] = { 185, "Курица с арахисом на вертеле", 185, "Пассерованная морковь", 185, "Пиво индивидуальных ощущений", 185, "Стир-фрай долины", 185, "Суп из шустрого краба" },
	[74854] = { 185, "Идеальная лапша быстрого приготовления" },
	[74856] = { 185, "Суп из клубящегося тумана", 185, "Угощение в горшочке" },
	[74857] = { 185, "Клецки с раками-богомолами", 185, "Ребрышки с черным перцем и раками", 185, "Угощение на гриле" },
	[74859] = { 185, "Лосось духов огня" },
	[74860] = { 185, "Зеленый карри с рыбой", 185, "Подрумяненная соленая рыба", 185, "Угощение в горшочке", 185, "Угощение из печи" },
	[74861] = { 185, "Рисовая лапша морских туманов", 185, "Рыбный пирог" },
	[74863] = { 185, "Крабовый сюрприз на пару", 185, "Рыба по-дольски" },
	[74864] = { 171, "Оскверненное масло", 185, "Стир-фрай долины", 185, "Угощение на пару" },
	[74865] = { 185, "Блюдо из двух рыб", 185, "Угощение на гриле", 185, "Хаустлундские фриттеры" },
	[74866] = { 185, "Консоме из золотистого карпа", 185, "Угощение на пару" },
	[75014] = { 185, "Рисовая лапша морских туманов" },
	[76078] = { 171, "Поводья мутагенного исчадия" },
	[76080] = { 171, "Поводья мутагенного исчадия" },
	[76083] = { 171, "Великий котел войны" },
	[76084] = { 171, "Великий котел войны", 171, "Поводья мутагенного исчадия" },
	[76085] = { 171, "Великий котел войны", 171, "Поводья мутагенного исчадия" },
	[76087] = { 171, "Великий котел войны", 171, "Поводья мутагенного исчадия" },
	[76088] = { 171, "Великий котел войны", 171, "Поводья мутагенного исчадия" },
	[76130] = { 171, "Трансмутация: александрит", 171, "Трансмутация: плутовской камень", 171, "Трансмутация: угасающий топаз", 755, "Броский тигровый опал", 755, "Варварский тигровый опал", 755, "Великолепный тигровый опал", 755, "Гибельный тигровый опал", 755, "Глянцевый тигровый опал", 755, "Грубый тигровый опал", 755, "Затвердевший тигровый опал", 755, "Изначальный алмаз", 755, "Изысканное кольцо", 755, "Искусный тигровый опал", 755, "Коварный тигровый опал", 755, "Краеугольный тигровый опал", 755, "Мастерский тигровый опал", 755, "Могущественный тигровый опал", 755, "Неподатливый тигровый опал", 755, "Округленный тигровый опал", 755, "Острый тигровый опал", 755, "Подвеска с тигровым опалом", 755, "Покрытый письменами тигровый опал", 755, "Полированный тигровый опал", 755, "Прозрачный тигровый опал", 755, "Смертоносный тигровый опал", 755, "Стойкий тигровый опал", 755, "Тигровый опал авангарда", 755, "Тигровый опал адепта", 755, "Тигровый опал воителя", 755, "Тигровый опал проворства", 755, "Тигровый опал фехтовальщика", 755, "Тонкий тигровый опал", 755, "Тончайший тигровый опал", 755, "Тревожный тигровый опал" },
	[76131] = { 171, "Трансмутация: сердце реки", 171, "Трансмутация: солнцесвет", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-W1Z\"", 755, "Блистательный первозданный рубин", 755, "Изящный первозданный рубин", 755, "Непоколебимый первозданный рубин", 755, "Перстень повелителя", 755, "Растрескавшийся первозданный рубин", 755, "Рельефный первозданный рубин", 755, "Рунический первозданный рубин", 755, "Хрупкий первозданный рубин", 755, "Яркий первозданный рубин", 755, "Ясный первозданный рубин" },
	[76132] = { 755, "Бездушный изначальный алмаз", 755, "Вечный изначальный алмаз", 755, "Горящий изначальный алмаз", 755, "Жалкий изначальный алмаз", 755, "Загадочный изначальный алмаз", 755, "Звонкий изначальный алмаз", 755, "Кольцо оступившегося льва", 755, "Лучезарный изначальный алмаз", 755, "Мечта о Море", 755, "Могучий изначальный алмаз", 755, "Неограненный изначальный алмаз", 755, "Ожерелье небесного мага", 755, "Оживляющий изначальный алмаз", 755, "Перстень повелителя", 755, "Поводья кристаллического охотника", 755, "Подвеска с тигровым опалом", 755, "Разрушительный изначальный алмаз", 755, "Рокочущий изначальный алмаз", 755, "Сердце земли", 755, "Стремительный изначальный алмаз", 755, "Угасающий изначальный алмаз" },
	[76133] = { 171, "Трансмутация: врайкульский гранат", 171, "Трансмутация: морской сапфир", 171, "Трансмутация: солнечный камень", 755, "Блестящий лазурит", 755, "Грозовой лазурит", 755, "Изначальный алмаз", 755, "Изысканное кольцо", 755, "Искрящийся лазурит", 755, "Мечта о Море", 755, "Цельный лазурит" },
	[76134] = { 171, "Трансмутация: врайкульский гранат", 171, "Трансмутация: лазурит", 171, "Трансмутация: янтарный самоцвет", 202, "Автоматический молот", 202, "Затемненный зеркальный прицел", 202, "Зеркальный прицел", 755, "Гладкий солнечный камень", 755, "Изначальный алмаз", 755, "Изысканное кольцо", 755, "Кольцо оступившегося льва", 755, "Матовый солнечный камень", 755, "Мистический солнечный камень", 755, "Мягкий солнечный камень", 755, "Прочный солнечный камень", 755, "Сверкающий солнечный камень", 755, "Широкий солнечный камень" },
	[76135] = { 171, "Трансмутация: александрит", 171, "Трансмутация: око демона", 171, "Трансмутация: тигровый опал", 755, "Блистающий плутовской камень", 755, "Вневременной плутовской камень", 755, "Гравированный плутовской камень", 755, "Идеально ограненный плутовской камень", 755, "Изменчивый плутовской камень", 755, "Изначальный алмаз", 755, "Крепкий плутовской камень", 755, "Мстительный плутовской камень", 755, "Ожерелье небесного мага", 755, "Ожерелье пылкого ума", 755, "Очищенный плутовской камень", 755, "Плутовской камень защитника", 755, "Плутовской камень стража", 755, "Плутовской камень убийцы", 755, "Сокрытый плутовской камень", 755, "Таинственный плутовской камень", 755, "Царственный плутовской камень", 755, "Шершавый плутовской камень" },
	[76136] = { 171, "Трансмутация: инфернальный рубин", 171, "Трансмутация: лазурит", 171, "Трансмутация: солнечный камень", 202, "Термическая наковальня", 755, "Блистательный врайкульский гранат", 755, "Изначальный алмаз", 755, "Изящный врайкульский гранат", 755, "Непоколебимый врайкульский гранат", 755, "Ожерелье пылкого ума", 755, "Растрескавшийся врайкульский гранат", 755, "Рельефный врайкульский гранат", 755, "Рунический врайкульский гранат", 755, "Хрупкий врайкульский гранат", 755, "Яркий врайкульский гранат", 755, "Ясный врайкульский гранат" },
	[76137] = { 171, "Трансмутация: изумруд грез", 171, "Трансмутация: плутовской камень", 171, "Трансмутация: тигровый опал", 202, "Подлинные очки мл. инженера", 755, "Александрит сенсея", 755, "Всевластный александрит", 755, "Живой александрит", 755, "Зазубренный александрит", 755, "Изначальный алмаз", 755, "Искаженный александрит", 755, "Лучезарный александрит", 755, "Молниевый александрит", 755, "Монарший александрит", 755, "Мощный александрит", 755, "Насыщенный александрит", 755, "Неизменный александрит", 755, "Ожерелье пылкого ума", 755, "Плотный александрит", 755, "Померкший александрит", 755, "Прожигающий александрит", 755, "Промерзший александрит", 755, "Раздробленный александрит", 755, "Сбалансированный александрит", 755, "Светозарный александрит", 755, "Сердце земли", 755, "Смутный александрит", 755, "Усиленный александрит" },
	[76138] = { 171, "Трансмутация: первозданный рубин", 171, "Трансмутация: солнцесвет", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-M3D\"", 755, "Блестящее сердце реки", 755, "Грозовое сердце реки", 755, "Искрящееся сердце реки", 755, "Цельное сердце реки" },
	[76139] = { 171, "Трансмутация: закатный оникс", 171, "Трансмутация: императорский аметист", 202, "Заряженные синтетические очки типа \"B-ANK-J1R:\"", 202, "Заряженные синтетические очки типа \"GA-CH1-M3D\"", 755, "Всевластный самородный нефрит", 755, "Живой самородный нефрит", 755, "Зазубренный самородный нефрит", 755, "Искаженный самородный нефрит", 755, "Лучезарный самородный нефрит", 755, "Молниевый самородный нефрит", 755, "Монарший самородный нефрит", 755, "Мощный самородный нефрит", 755, "Насыщенный самородный нефрит", 755, "Неизменный самородный нефрит", 755, "Плотный самородный нефрит", 755, "Померкший самородный нефрит", 755, "Прожигающий самородный нефрит", 755, "Промерзший самородный нефрит", 755, "Раздробленный самородный нефрит", 755, "Самородный нефрит сенсея", 755, "Сбалансированный самородный нефрит", 755, "Светозарный самородный нефрит", 755, "Смутный самородный нефрит", 755, "Усиленный самородный нефрит" },
	[76140] = { 171, "Трансмутация: императорский аметист", 171, "Трансмутация: самородный нефрит", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-W1Z\"", 755, "Броский закатный оникс", 755, "Варварский закатный оникс", 755, "Великолепный закатный оникс", 755, "Гибельный закатный оникс", 755, "Глянцевый закатный оникс", 755, "Грубый закатный оникс", 755, "Закатный оникс авангарда", 755, "Закатный оникс адепта", 755, "Закатный оникс воителя", 755, "Закатный оникс проворства", 755, "Закатный оникс фехтовальщика", 755, "Затвердевший закатный оникс", 755, "Искусный закатный оникс", 755, "Коварный закатный оникс", 755, "Краеугольный закатный оникс", 755, "Мастерский закатный оникс", 755, "Могущественный закатный оникс", 755, "Неподатливый закатный оникс", 755, "Округленный закатный оникс", 755, "Острый закатный оникс", 755, "Покрытый письменами закатный оникс", 755, "Полированный закатный оникс", 755, "Прозрачный закатный оникс", 755, "Смертоносный закатный оникс", 755, "Стойкий закатный оникс", 755, "Тонкий закатный оникс", 755, "Тончайший закатный оникс", 755, "Тревожный закатный оникс" },
	[76141] = { 171, "Трансмутация: закатный оникс", 171, "Трансмутация: самородный нефрит", 202, "Заряженные синтетические очки типа \"B-ANK-M3D\"", 202, "Заряженные синтетические очки типа \"GA-CH1-UK162\"", 202, "Прицел быстрорукого Джека", 755, "Блистающий императорский аметист", 755, "Вневременной императорский аметист", 755, "Гравированный императорский аметист", 755, "Идеально ограненный императорский аметист", 755, "Изменчивый императорский аметист", 755, "Императорский аметист защитника", 755, "Императорский аметист стража", 755, "Императорский аметист убийцы", 755, "Крепкий императорский аметист", 755, "Мстительный императорский аметист", 755, "Очищенный императорский аметист", 755, "Сокрытый императорский аметист", 755, "Таинственный императорский аметист", 755, "Царственный императорский аметист", 755, "Шершавый императорский аметист" },
	[76142] = { 171, "Трансмутация: первозданный рубин", 171, "Трансмутация: сердце реки", 202, "Заряженные синтетические очки типа \"B-ANK-UK162\"", 202, "Заряженные синтетические очки типа \"GA-CH1-W1Z\"", 755, "Гладкий солнцесвет", 755, "Матовый солнцесвет", 755, "Мистический солнцесвет", 755, "Мягкий солнцесвет", 755, "Прочный солнцесвет", 755, "Сверкающий солнцесвет", 755, "Широкий солнцесвет" },
	[79101] = { 165, "Барабаны неистовства", 165, "Изысканные наплечники приручителя протодраконов", 165, "Изысканные наручи приручителя протодраконов", 165, "Изысканные перчатки приручителя протодраконов", 165, "Изысканные поножи приручителя протодраконов", 165, "Изысканные сапоги приручителя протодраконов", 165, "Изысканный нагрудный доспех приручителя протодраконов", 165, "Изысканный пояс приручителя протодраконов", 165, "Изысканный шлем приручителя протодраконов", 165, "Искусно изготовленная накидка борца со смертью", 165, "Накидка борца со смертью", 165, "Нетронутые укрепленные накладки для поножей", 165, "Поводья выносливой винторогой гарны", 165, "Сумка из великолепной шкуры", 165, "Таинственные наплечники приручителя протодраконов", 165, "Таинственные наручи приручителя протодраконов", 165, "Таинственные перчатки приручителя протодраконов", 165, "Таинственные поножи приручителя протодраконов", 165, "Таинственные сапоги приручителя протодраконов", 165, "Таинственный нагрудный доспех приручителя протодраконов", 165, "Таинственный пояс приручителя протодраконов", 165, "Таинственный шлем приручителя протодраконов", 165, "Укрепленные накладки для поножей", 165, "Яростные наплечники приручителя протодраконов", 165, "Яростные наручи приручителя протодраконов", 165, "Яростные перчатки приручителя протодраконов", 165, "Яростные поножи приручителя протодраконов", 165, "Яростные сапоги приручителя протодраконов", 165, "Яростный нагрудный доспех приручителя протодраконов", 165, "Яростный пояс приручителя протодраконов", 165, "Яростный шлем приручителя протодраконов" },
	[79740] = { 773, "Инкрустированный серебром посох", 773, "Ключ к иным мирам", 773, "Покрытый шипами посох", 773, "Рунический посох" },
	[81214] = { 129, "Противоядие Седой Лапы" },
	[82441] = { 197, "Ковер-самолет древней знати", 197, "Лазурная чародейская нить", 197, "Лунношелковое одеяние", 197, "Лунношелковые наплечники", 197, "Лунношелковые наручи", 197, "Лунношелковые перчатки", 197, "Лунношелковые поножи", 197, "Лунношелковые туфли", 197, "Лунношелковый клобук", 197, "Лунношелковый пояс", 197, "Накидка борца со смертью", 197, "Накидка ткача таинств", 197, "Пелерина сотворителя жизни", 197, "Перламутровая чародейская нить", 197, "Песня жизни", 197, "Плащ защитника пределов", 197, "Реликвия прошлого: Портняжное дело", 197, "Смертошелковое одеяние", 197, "Смертошелковые наплечники", 197, "Смертошелковые наручи", 197, "Смертошелковые перчатки", 197, "Смертошелковые поножи", 197, "Смертошелковые туфли", 197, "Смертошелковый клобук", 197, "Смертошелковый пояс", 197, "Троекратно укрепленная сумка" },
	[82447] = { 197, "Великая лазурная чародейская нить", 197, "Великая перламутровая чародейская нить", 197, "Искусно изготовленная накидка борца со смертью", 197, "Искусно изготовленная накидка ткача таинств", 197, "Искусно изготовленная пелерина сотворителя жизни", 197, "Искусно изготовленное лунношелковое одеяние", 197, "Искусно изготовленное смертошелковое одеяние", 197, "Искусно изготовленные лунношелковые наплечники", 197, "Искусно изготовленные лунношелковые наручи", 197, "Искусно изготовленные лунношелковые перчатки", 197, "Искусно изготовленные лунношелковые поножи", 197, "Искусно изготовленные лунношелковые туфли", 197, "Искусно изготовленные смертошелковые наплечники", 197, "Искусно изготовленные смертошелковые наручи", 197, "Искусно изготовленные смертошелковые перчатки", 197, "Искусно изготовленные смертошелковые поножи", 197, "Искусно изготовленные смертошелковые туфли", 197, "Искусно изготовленный лунношелковый клобук", 197, "Искусно изготовленный лунношелковый пояс", 197, "Искусно изготовленный плащ защитника пределов", 197, "Искусно изготовленный смертошелковый клобук", 197, "Искусно изготовленный смертошелковый пояс", 197, "Ковер-самолет древней знати", 197, "Лунношелковый вышитый талисман", 197, "Реликвия прошлого: Портняжное дело", 197, "Смертошелковые вышитый талисман", 197, "Стихийношелковый вышитый талисман", 197, "Троекратно укрепленная сумка" },
	[85583] = { 185, "Сушеные опята" },
	[85584] = { 185, "Большое угощение из печи", 185, "Отварная куколка шелкопряда", 185, "Угощение из печи" },
	[85585] = { 185, "Пирожок с красной фасолью" },
	[87701] = { 202, "Гоблинское бургербекю" },
	[87702] = { 185, "Большое угощение на гриле" },
	[87703] = { 185, "Большое угощение на гриле" },
	[87705] = { 185, "Большое угощение из печи" },
	[87707] = { 185, "Большое освежающее угощение", 185, "Большое угощение вок" },
	[87708] = { 185, "Большое угощение в горшочке" },
	[87709] = { 185, "Большое угощение вок" },
	[87713] = { 185, "Большое угощение вок" },
	[87714] = { 185, "Большое освежающее угощение" },
	[87723] = { 185, "Большое угощение на пару" },
	[87724] = { 185, "Большое угощение из печи" },
	[87725] = { 185, "Большое угощение в горшочке", 202, "Гоблинское бургербекю" },
	[87726] = { 185, "Большое угощение в горшочке" },
	[87728] = { 185, "Большое угощение на гриле" },
	[87729] = { 185, "Большое угощение на пару" },
	[92960] = { 202, "Элементиевый дракончик" },
	[97600] = { 755, "Гессонит варвара", 755, "Треснутый гессонит варвара" },
	[97601] = { 755, "Грубый гессонит", 755, "Треснутый грубый гессонит" },
	[97602] = { 755, "Округленный гессонит", 755, "Треснутый округленный гессонит" },
	[97603] = { 755, "Гессонит фехтовальщика", 755, "Треснутый гессонит фехтовальщика" },
	[97604] = { 755, "Гессонит авангарда", 755, "Треснутый гессонит авангарда" },
	[97605] = { 755, "Краеугольный гессонит", 755, "Треснутый краеугольный гессонит" },
	[97606] = { 755, "Монументальный камень ночи", 755, "Треснутый монументальный камень ночи" },
	[97607] = { 755, "Крепкая Яшма", 755, "Треснутая крепкая яшма" },
	[102351] = { 164, "Большой меч кровавой расправы", 164, "Варварский меч", 164, "Заточка иссушения разума", 164, "Изысканная кираса из закаленного колчедана", 164, "Изысканные ботинки из закаленного колчедана", 164, "Изысканные набедренники из закаленного колчедана", 164, "Изысканные наплечники из закаленного колчедана", 164, "Изысканные наручи из закаленного колчедана", 164, "Изысканные рукавицы из закаленного колчедана", 164, "Изысканный пояс из закаленного колчедана", 164, "Изысканный шлем из закаленного колчедана", 164, "Испытующий топор", 164, "Колчедановый щит рассвета", 164, "Колчедановый щит сумерек", 164, "Копье удлинившихся теней", 164, "Поводья разрушителя-железнонога", 164, "Призрачный осколок искусной работы", 164, "Укрепленная кираса из закаленного колчедана", 164, "Укрепленные ботинки из закаленного колчедана", 164, "Укрепленные набедренники из закаленного колчедана", 164, "Укрепленные наплечники из закаленного колчедана", 164, "Укрепленные наручи из закаленного колчедана", 164, "Укрепленные рукавицы из закаленного колчедана", 164, "Укрепленный пояс из закаленного колчедана", 164, "Укрепленный шлем из закаленного колчедана", 164, "Шипастая кираса из закаленного колчедана", 164, "Шипастые ботинки из закаленного колчедана", 164, "Шипастые набедренники из закаленного колчедана", 164, "Шипастые наплечники из закаленного колчедана", 164, "Шипастые наручи из закаленного колчедана", 164, "Шипастые рукавицы из закаленного колчедана", 164, "Шипастый пояс из закаленного колчедана", 164, "Шипастый шлем из закаленного колчедана", 164, "Яунгольский факел", 165, "Изысканные наплечники мрачных глубин", 165, "Изысканные наплечники приручителя протодраконов", 165, "Изысканные наручи мрачных глубин", 165, "Изысканные наручи приручителя протодраконов", 165, "Изысканные перчатки мрачных глубин", 165, "Изысканные перчатки приручителя протодраконов", 165, "Изысканные поножи мрачных глубин", 165, "Изысканные поножи приручителя протодраконов", 165, "Изысканные сапоги мрачных глубин", 165, "Изысканные сапоги приручителя протодраконов", 165, "Изысканный нагрудный доспех мрачных глубин", 165, "Изысканный нагрудный доспех приручителя протодраконов", 165, "Изысканный пояс мрачных глубин", 165, "Изысканный пояс приручителя протодраконов", 165, "Изысканный шлем мрачных глубин", 165, "Изысканный шлем приручителя протодраконов", 165, "Искусно изготовленная накидка борца со смертью", 165, "Искусно изготовленный плащ защитника пределов", 165, "Поводья выносливой винторогой гарны", 165, "Таинственные наплечники мрачных глубин", 165, "Таинственные наплечники приручителя протодраконов", 165, "Таинственные наручи мрачных глубин", 165, "Таинственные наручи приручителя протодраконов", 165, "Таинственные перчатки мрачных глубин", 165, "Таинственные перчатки приручителя протодраконов", 165, "Таинственные поножи мрачных глубин", 165, "Таинственные поножи приручителя протодраконов", 165, "Таинственные сапоги мрачных глубин", 165, "Таинственные сапоги приручителя протодраконов", 165, "Таинственный нагрудный доспех мрачных глубин", 165, "Таинственный нагрудный доспех приручителя протодраконов", 165, "Таинственный пояс мрачных глубин", 165, "Таинственный пояс приручителя протодраконов", 165, "Таинственный шлем мрачных глубин", 165, "Таинственный шлем приручителя протодраконов", 165, "Яростные наплечники мрачных глубин", 165, "Яростные наплечники приручителя протодраконов", 165, "Яростные наручи мрачных глубин", 165, "Яростные наручи приручителя протодраконов", 165, "Яростные перчатки мрачных глубин", 165, "Яростные перчатки приручителя протодраконов", 165, "Яростные поножи мрачных глубин", 165, "Яростные поножи приручителя протодраконов", 165, "Яростные сапоги мрачных глубин", 165, "Яростные сапоги приручителя протодраконов", 165, "Яростный нагрудный доспех мрачных глубин", 165, "Яростный нагрудный доспех приручителя протодраконов", 165, "Яростный пояс мрачных глубин", 165, "Яростный пояс приручителя протодраконов", 165, "Яростный шлем мрачных глубин", 165, "Яростный шлем приручителя протодраконов", 171, "Алхимический камень жизни", 171, "Неустойчивый алхимический камень", 171, "Переменчивый алхимический камень", 171, "Поводья мутагенного исчадия", 171, "Резонирующий алхимический камень", 197, "Искусно изготовленная накидка борца со смертью", 197, "Искусно изготовленная накидка ткача таинств", 197, "Искусно изготовленная пелерина сотворителя жизни", 197, "Искусно изготовленное лунношелковое одеяние", 197, "Искусно изготовленное смертошелковое одеяние", 197, "Искусно изготовленные лунношелковые наплечники", 197, "Искусно изготовленные лунношелковые наручи", 197, "Искусно изготовленные лунношелковые перчатки", 197, "Искусно изготовленные лунношелковые поножи", 197, "Искусно изготовленные лунношелковые туфли", 197, "Искусно изготовленные смертошелковые наплечники", 197, "Искусно изготовленные смертошелковые наручи", 197, "Искусно изготовленные смертошелковые перчатки", 197, "Искусно изготовленные смертошелковые поножи", 197, "Искусно изготовленные смертошелковые туфли", 197, "Искусно изготовленный лунношелковый клобук", 197, "Искусно изготовленный лунношелковый пояс", 197, "Искусно изготовленный плащ защитника пределов", 197, "Искусно изготовленный смертошелковый клобук", 197, "Искусно изготовленный смертошелковый пояс", 197, "Ковер-самолет древней знати", 202, "Заряженные синтетические очки типа \"B-ANK-J1R:\"", 202, "Заряженные синтетические очки типа \"B-ANK-M3D\"", 202, "Заряженные синтетические очки типа \"B-ANK-UK162\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-M3D\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-UK162\"", 202, "Заряженные синтетические очки типа \"CHM-BK1N1-W1Z\"", 202, "Заряженные синтетические очки типа \"GA-CH1-M3D\"", 202, "Заряженные синтетические очки типа \"GA-CH1-UK162\"", 202, "Заряженные синтетические очки типа \"GA-CH1-W1Z\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-M3D\"", 202, "Заряженные синтетические очки типа \"L0-SKUT-W1Z\"", 202, "Курогилятор", 202, "Механокот модели Х-995", 202, "Образцовый гномский армейский нож", 202, "Ударный шорох", 202, "Шпашко-метатель", 202, "Элементиевый дракончик", 333, "Поводья манапарда чародея", 333, "Чары для двуручного оружия - благодать Ранульфа", 333, "Чары для двуручного оружия - дыхание Сиф", 333, "Чары для двуручного оружия - мощь Бьорна", 333, "Чары для двуручного оружия - оберег Исулдофа", 333, "Чары для двуручного оружия - проклятие Имирона", 333, "Чары для двуручного оружия - руническая вязь Нарфи", 333, "Чары для двуручного оружия - увядание Галдора", 333, "Чары для двуручного оружия - чародейство Квалда", 333, "Чары для одноручного оружия - благодать Ранульфа", 333, "Чары для одноручного оружия - дыхание Сиф", 333, "Чары для одноручного оружия - мощь Бьорна", 333, "Чары для одноручного оружия - оберег Исулдофа", 333, "Чары для одноручного оружия - проклятие Имирона", 333, "Чары для одноручного оружия - руническая вязь Нарфи", 333, "Чары для одноручного оружия - увядание Галдора", 333, "Чары для одноручного оружия - чародейство Квалда", 755, "Кольцо оступившегося льва", 755, "Мечта о Море", 755, "Ожерелье небесного мага", 755, "Перстень повелителя", 755, "Поводья кристаллического охотника", 755, "Подвеска с тигровым опалом", 755, "Сердце земли", 773, "Божественный спутник", 773, "Инкрустированный серебром посох", 773, "Ключ к иным мирам", 773, "Поводья акварельного лиса", 773, "Руководство по исследованию подземелий" },
	[102359] = { 129, "Масло из улетной рыбы" },
	[102361] = { 165, "Сильно огрубелая кожа" },
	[102371] = { 197, "Искусно изготовленная накидка борца со смертью", 197, "Искусно изготовленная накидка ткача таинств", 197, "Искусно изготовленная пелерина сотворителя жизни", 197, "Искусно изготовленное лунношелковое одеяние", 197, "Искусно изготовленное смертошелковое одеяние", 197, "Искусно изготовленные лунношелковые наплечники", 197, "Искусно изготовленные лунношелковые наручи", 197, "Искусно изготовленные лунношелковые перчатки", 197, "Искусно изготовленные лунношелковые поножи", 197, "Искусно изготовленные лунношелковые туфли", 197, "Искусно изготовленные смертошелковые наплечники", 197, "Искусно изготовленные смертошелковые наручи", 197, "Искусно изготовленные смертошелковые перчатки", 197, "Искусно изготовленные смертошелковые поножи", 197, "Искусно изготовленные смертошелковые туфли", 197, "Искусно изготовленный лунношелковый клобук", 197, "Искусно изготовленный лунношелковый пояс", 197, "Искусно изготовленный плащ защитника пределов", 197, "Искусно изготовленный смертошелковый клобук", 197, "Искусно изготовленный смертошелковый пояс", 197, "Лунношелковое одеяние", 197, "Лунношелковые наплечники", 197, "Лунношелковые наручи", 197, "Лунношелковые перчатки", 197, "Лунношелковые поножи", 197, "Лунношелковые туфли", 197, "Лунношелковый клобук", 197, "Лунношелковый пояс", 197, "Накидка борца со смертью", 197, "Накидка ткача таинств", 197, "Пелерина сотворителя жизни", 197, "Плащ защитника пределов", 197, "Реликвия прошлого: Портняжное дело", 197, "Смертошелковое одеяние", 197, "Смертошелковые наплечники", 197, "Смертошелковые наручи", 197, "Смертошелковые перчатки", 197, "Смертошелковые поножи", 197, "Смертошелковые туфли", 197, "Смертошелковый клобук", 197, "Смертошелковый пояс", 197, "Троекратно укрепленная сумка" },
	[149184] = { 755, "Стойкий Глаз химеры" },
	[149185] = { 755, "Непоколебимый Глаз химеры" },
	[177422] = { 185, "Большое угощение вок", 185, "Большое угощение на пару", 185, "Пиво индивидуальных ощущений", 185, "Стир-фрай долины" },
	[177423] = { 185, "Большое угощение на гриле", 185, "Зеленый карри с рыбой", 185, "Лосось духов огня", 185, "Ребрышки с черным перцем и раками", 202, "Гоблинское бургербекю" },
	[177424] = { 185, "Большое освежающее угощение", 185, "Большое угощение в горшочке", 185, "Большое угощение из печи", 185, "Крабовый сюрприз на пару" },
	[177469] = { 171, "Котел войны" },
	[177470] = { 171, "Котел войны" },
	[177471] = { 171, "Котел войны" },
	[177472] = { 171, "Котел войны" },
	[177684] = { 171, "Котел войны" },
	[177847] = { 129, "Бальзам с глазом огра", 129, "Концентрат энергии Кришадалиса", 129, "Масло из улетной рыбы", 129, "Противоядие Седой Лапы", 171, "Алхимическое зелье омоложения", 171, "Зелье маны мастера", 171, "Зелье непреклонности", 171, "Зелье поиска сокровищ Фельярда", 171, "Зелье чистой магии", 171, "Зелье чистой ярости", 171, "Лечебное зелье мастера", 171, "Малый настой весенних цветов", 171, "Малый настой земли", 171, "Малый настой кусачих морозов", 171, "Малый настой ласкового солнца", 171, "Малый настой опадающих листьев", 171, "Малый эликсир азарта", 171, "Малый эликсир безупречности", 171, "Малый эликсир ведьмы", 171, "Малый эликсир вооружения", 171, "Малый эликсир монаха", 171, "Малый эликсир наставника", 171, "Малый эликсир отражений", 171, "Малый эликсир подземелий", 171, "Малый эликсир спокойствия", 171, "Малый эликсир стремительности", 171, "Малый эликсир упорства", 171, "Настой весенних цветов", 171, "Настой земли", 171, "Настой кусачих морозов", 171, "Настой ласкового солнца", 171, "Настой опадающих листьев", 171, "Оскверненное масло", 171, "Эликсир азарта", 171, "Эликсир безупречности", 171, "Эликсир ведьмы", 171, "Эликсир вооружения", 171, "Эликсир монаха", 171, "Эликсир наставника", 171, "Эликсир отражений", 171, "Эликсир подземелий", 171, "Эликсир спокойствия", 171, "Эликсир стремительности", 171, "Эликсир упорства" },
	[177848] = { 165, "Сумка королевского начертателя", 773, "Божественный спутник", 773, "Воодушевление Аскеладда", 773, "Воодушевление Торкелля", 773, "Воодушевление Торфина", 773, "Поводья акварельного лиса", 773, "Руководство по исследованию подземелий", 773, "Свиток абиссала", 773, "Свиток всех характеристик", 773, "Свиток критического удара", 773, "Свиток критического удара заклинаний", 773, "Свиток поганища", 773, "Свиток силы атаки", 773, "Свиток скорости", 773, "Свиток снижения урона", 773, "Свиток урона", 773, "Свиток эффективности лечения", 773, "Символ божественного вмешательства", 773, "Символ великого благословения", 773, "Символ воскрешения мертвых", 773, "Символ выгорания", 773, "Символ гальки", 773, "Символ дара дикой природы", 773, "Символ десертного угощения", 773, "Символ дикого гриба", 773, "Символ карманной коробки", 773, "Символ кровавого панциря", 773, "Символ мерцающего пламени", 773, "Символ молитвы духа", 773, "Символ молитвы защиты от темной магии", 773, "Символ молитвы стойкости", 773, "Символ неистового восстановления кошмара", 773, "Символ нокаута", 773, "Символ огненного рывка", 773, "Символ окоченевшего панциря", 773, "Символ перерождения", 773, "Символ подводного дыхания", 773, "Символ призрачного растворения", 773, "Символ пути леса", 773, "Символ пылающей ярости", 773, "Символ ритуала Рока", 773, "Символ столпа света", 773, "Символ уменьшения питомца", 773, "Символ чародейской гениальности", 773, "Символ щедрого угощения", 773, "Фельярдский свиток возвращения", 773, "Фельярдский свиток защиты", 773, "Фельярдский свиток исцеления", 773, "Фельярдский свиток скорости" },
	[177853] = { 186, "Выплавка колчедана", 202, "Амуниция с колчедановым наконечником", 202, "Элементиевые снаряды" },
	[177860] = { 129, "Концентрат энергии Кришадалиса" },
	[177929] = { 164, "Обсидиановое грузило", 164, "Обсидиановое точило", 164, "Элементиевое грузило", 164, "Элементиевое точило", 171, "Трансмутация: закатный оникс", 171, "Трансмутация: императорский аметист", 171, "Трансмутация: первозданный рубин", 171, "Трансмутация: самородный нефрит", 171, "Трансмутация: сердце реки", 171, "Трансмутация: солнцесвет", 197, "Лунношелковый вышитый талисман", 197, "Смертошелковые вышитый талисман", 197, "Стихийношелковый вышитый талисман" },
	[290024] = { 185, "Даларанская похлебка из моллюсков со специями", 185, "Луциан особого приготовления с приправами", 185, "Люторожий змеестейк с приправами", 185, "Медуза с приправами", 185, "Подкопченная дракоперая рыба-ангел с приправами", 185, "Подкопченный лосось со специями", 185, "Пряное лакомство из мамонта c приправами", 185, "Рыбный пир со специями", 185, "Сочное мясо люторога со специями", 185, "Сочные сосиски из люторога с приправами", 185, "Стейк из каракатицы с приправами", 185, "Стейк из королевского ската со специями", 185, "Сытное кушанье из мамонта с приправами", 185, "Филе дракоперой рыбы-ангела с приправами", 185, "Черный студень с приправами" },
}

----------------------------------------------------------------------------------------------
-- Где добыть (бывший аддон WhereToGet): источники предмета на карте через Questie, кнопка у миникарты.
-- Отдельная функция — свои локальные переменные, не мешают остальному коду.
;(function()
-- Предмет, перетащенный на кнопку у миникарты (или щелчок по реагенту в плане), отмечается на карте
-- через Questie: где выпадает (мобы), добывается (объекты) или продаётся (торговцы).
-- Повторный вызов для того же предмета убирает отметки.

-- Рыба старого мира: поправки Questie стирают у неё косяки (objectDrops = {}), хотя сами косяки
-- с координатами в базе есть. Списки — из базы Questie (wotlkItemDB) до поправок
local POOL_OBJECTS = {
	[6358] = { 180248, 180582, 180664, 180682, 180750, 180900 }, -- Oily Blackmouth
	[6359] = { 180248, 180657, 180661, 180683, 180752, 180902 }, -- Firefin Snapper
	[6522] = { 180658 },                                         -- Deviate Fish
	[13422] = { 180248, 180712 },                                -- Stonescale Eel
	[21071] = { 180656, 180663 },                                -- Raw Sagefish
	[21153] = { 180684, 184956 },                                -- Raw Greater Sagefish
}

-- Косяки на карте: значок рыбы такого размера; по этим словам в названии объекта Questie узнаём косяк
local POOL_SCALE = 1.3
local POOL_WORDS = { "School", "Pool", "Swarm", "Shoal", "Wreckage", "Debris", "Floating", "Oil Spill" }

local MAX_SOURCES = 40 -- больше не рисуем, чтобы не завалить карту (например, ткань падает почти со всех)

-- Ореол: под каждой меткой крупное мягкое свечение, рядом стоящие сливаются в пятно-область
local HALO_TEXTURE = "Interface\\AddOns\\CraftPlan\\halo"
local HALO_SCALE = 3
local HALO_TYP_NPC = "wtg_halo_npc"
local HALO_TYP_OBJECT = "wtg_halo_object"

local function HaloEnabled()
	return not (WhereToGetDB and WhereToGetDB.halo == false)
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Где добыть:|r " .. msg)
end

-- itemID -> список { id, typ } для QuestieMap:UnloadManualFrames
-- (обычные метки: typ = nil, NPC id > 0, объекты id < 0; ореолы: свой typ, id > 0)
local shownByItem = {}
-- itemID -> { name = "[Название]", area = areaId зоны, где меток больше всего } — для кнопки у миникарты
local shownInfo = {}
local lastItemID -- последний отмеченный предмет

-- Открыть карту мира на зоне (areaId) через Questie
local function OpenMapAt(areaId)
	local ZoneDB = QuestieLoader and QuestieLoader:ImportModule("ZoneDB")
	local wmf = QuestieCompat and QuestieCompat.WorldMapFrame
	if not (areaId and ZoneDB and ZoneDB.GetUiMapIdByAreaId and wmf) then return false end
	local ok, shown = pcall(function()
		local uiMapId = ZoneDB:GetUiMapIdByAreaId(areaId)
		if uiMapId then
			wmf:Show()
			wmf:SetMapID(uiMapId)
			return true
		end
	end)
	return ok and shown
end

local function UnloadEntries(QuestieMap, entries)
	for _, e in ipairs(entries) do
		QuestieMap:UnloadManualFrames(e[1], e[2])
	end
end

-- Показать на карте источники предмета по номеру (вызывается и из других аддонов, например CraftPlan).
-- Повторный вызов для того же предмета убирает отметки.
function WhereToGet_ShowItem(itemID, link)
	local itemName = GetItemInfo(itemID)
	local name = (link and link:match("|h(%[.-%])|h")) or (itemName and ("[" .. itemName .. "]")) or ("предмет " .. itemID)

	if not QuestieLoader then
		Print("Questie не загружен.")
		return
	end
	local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
	local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
	if not (QuestieDB and QuestieMap and QuestieDB.QueryItem and QuestieMap.ShowNPC) then
		Print("не удалось подключиться к Questie.")
		return
	end

	-- Повторное нажатие на тот же предмет — убрать отметки
	if shownByItem[itemID] then
		UnloadEntries(QuestieMap, shownByItem[itemID])
		shownByItem[itemID] = nil
		shownInfo[itemID] = nil
		if lastItemID == itemID then lastItemID = next(shownInfo) end
		Print(name .. ": отметки убраны с карты.")
		return
	end

	local QuestieCorrections = QuestieLoader:ImportModule("QuestieCorrections")
	if QuestieCorrections and QuestieCorrections.questItemBlacklist and QuestieCorrections.questItemBlacklist[itemID] then
		Print(name .. ": Questie не хранит мобов для этого предмета — он падает со слишком многих (например, ткань). Показываю только то, что есть.")
	end

	local ok, sources = pcall(QuestieDB.QueryItem, itemID, { "npcDrops", "objectDrops", "vendors" })
	if not ok or not sources then
		Print(name .. ": нет в базе Questie.")
		return
	end
	if POOL_OBJECTS[itemID] and not next(sources[2] or {}) then sources[2] = POOL_OBJECTS[itemID] end

	local entries, total, counts, skipped = {}, 0, { npc = 0, object = 0, vendor = 0 }, 0
	local halo = HaloEnabled()
	local zoneCounts = {} -- areaId -> число источников с местами появления в этой зоне
	local function countZones(spawns)
		for areaId in pairs(spawns) do
			zoneCounts[areaId] = (zoneCounts[areaId] or 0) + 1
		end
	end
	local function addNPC(npcID, kind)
		local spawns = QuestieDB.QueryNPCSingle(npcID, "spawns")
		if spawns then
			if total >= MAX_SOURCES then skipped = skipped + 1 return end
			countZones(spawns)
			if halo then -- ореол рисуем первым, чтобы он был под меткой
				QuestieMap:ShowNPC(npcID, HALO_TEXTURE, HALO_SCALE, nil, nil, true, HALO_TYP_NPC)
				entries[#entries + 1] = { npcID, HALO_TYP_NPC }
			end
			QuestieMap:ShowNPC(npcID)
			entries[#entries + 1] = { npcID }
			total = total + 1
			counts[kind] = counts[kind] + 1
		end
	end
	for _, npcID in pairs(sources[1] or {}) do addNPC(npcID, "npc") end
	-- косяк рыбы — крупная метка со значком самой рыбы, иначе стандартная точка Questie плохо видна
	local itemIcon = select(10, GetItemInfo(itemID))
	local function PoolIcon(objectID)
		if not itemIcon then return nil end
		if POOL_OBJECTS[itemID] then return itemIcon, POOL_SCALE end
		local oname = QuestieDB.QueryObjectSingle(objectID, "name") or ""
		for _, word in ipairs(POOL_WORDS) do
			if oname:find(word) then return itemIcon, POOL_SCALE end
		end
	end
	for _, objectID in pairs(sources[2] or {}) do
		local spawns = QuestieDB.QueryObjectSingle(objectID, "spawns")
		if spawns then
			if total >= MAX_SOURCES then
				skipped = skipped + 1
			else
				countZones(spawns)
				if halo then
					QuestieMap:ShowObject(objectID, HALO_TEXTURE, HALO_SCALE, nil, nil, true, HALO_TYP_OBJECT)
					entries[#entries + 1] = { objectID, HALO_TYP_OBJECT }
				end
				local icon, scale = PoolIcon(objectID)
				QuestieMap:ShowObject(objectID, icon, scale)
				entries[#entries + 1] = { -objectID }
				total = total + 1
				counts.object = counts.object + 1
			end
		end
	end
	for _, npcID in pairs(sources[3] or {}) do addNPC(npcID, "vendor") end
	local ids = entries

	if total == 0 then
		Print(name .. ": в базе Questie нет источников с координатами.")
		return
	end
	shownByItem[itemID] = ids
	shownInfo[itemID] = { name = name }
	lastItemID = itemID
	local msg = string.format("%s: мобы — %d, объекты — %d, торговцы — %d. Откройте карту (M). Повторное нажатие — убрать.",
		name, counts.npc, counts.object, counts.vendor)
	if skipped > 0 then
		msg = msg .. string.format(" Ещё %d источников не показано (слишком много).", skipped)
	end
	Print(msg)

	-- В каких зонах искать: текущая зона подсвечивается, остальные — по числу источников
	local TrackerUtils = QuestieLoader:ImportModule("TrackerUtils")
	if TrackerUtils and TrackerUtils.GetZoneNameByID then
		local here = GetRealZoneText()
		local list, hereCount, hereArea = {}, 0, nil
		for areaId, n in pairs(zoneCounts) do
			local zoneName = TrackerUtils:GetZoneNameByID(areaId)
			if zoneName == here then
				hereCount = hereCount + n
				hereArea = areaId
			else
				list[#list + 1] = { zoneName, n, areaId }
			end
		end
		table.sort(list, function(a, b) return a[2] > b[2] end)
		local parts = {}
		for i = 1, math.min(#list, 6) do
			parts[#parts + 1] = list[i][1] .. " (" .. list[i][2] .. ")"
		end
		if #list > 6 then parts[#parts + 1] = "и ещё " .. (#list - 6) end
		if hereCount > 0 then
			Print("|cff00ff00В этой зоне: " .. hereCount .. ".|r" .. (#parts > 0 and (" Также: " .. table.concat(parts, ", ")) or ""))
		else
			Print("|cffff8800В этой зоне нет.|r Зоны: " .. table.concat(parts, ", "))
		end

		-- открыть карту мира на зоне с метками: текущей, если источники есть здесь, иначе на той,
		-- где их больше всего (иначе карта откроется на текущей зоне, и меток не будет видно)
		local targetArea = hereArea or (list[1] and list[1][3])
		shownInfo[itemID].area = targetArea
		OpenMapAt(targetArea)
	end
end

-- Убрать отметки всех предметов сразу, без наведения на предмет
function WhereToGet_ClearAll()
	local QuestieMap = QuestieLoader and QuestieLoader:ImportModule("QuestieMap")
	local count = 0
	for itemID, entries in pairs(shownByItem) do
		if QuestieMap then
			UnloadEntries(QuestieMap, entries)
		end
		shownByItem[itemID] = nil
		shownInfo[itemID] = nil
		count = count + 1
	end
	if count > 0 then
		Print("метки убраны с карты (предметов: " .. count .. ").")
	else
		Print("на карте нет меток.")
	end
end

-- /wtg clear — убрать все метки; /wtg — справка
SLASH_WHERETOGET1 = "/wtg"
SlashCmdList["WHERETOGET"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "clear" then
		WhereToGet_ClearAll()
	elseif msg == "button" then
		WhereToGetDB = WhereToGetDB or {}
		WhereToGetDB.hideButton = not WhereToGetDB.hideButton
		WhereToGet_UpdateButton()
		Print("кнопка у миникарты " .. (WhereToGetDB.hideButton and "скрыта" or "показана") .. ".")
	elseif msg == "halo" then
		WhereToGetDB = WhereToGetDB or {}
		WhereToGetDB.halo = not HaloEnabled()
		Print("ореол " .. (WhereToGetDB.halo and "включён" or "выключен") .. ". Применится к новым меткам.")
	else
		Print("Кнопка у миникарты: перетащите на неё предмет — покажет источники; щелчок — карта на зоне меток; правый щелчок — убрать все метки.")
		Print("/wtg clear — убрать все метки, /wtg button — скрыть/показать кнопку у миникарты, /wtg halo — включить/выключить ореол (сейчас: " .. (HaloEnabled() and "вкл" or "выкл") .. ").")
	end
end

-- Shift+щелчок по метке Questie убирает метку — убираем вместе с ней и её ореол
local haloHook = CreateFrame("Frame")
haloHook:RegisterEvent("PLAYER_LOGIN")
haloHook:SetScript("OnEvent", function()
	local QuestieMap = QuestieLoader and QuestieLoader:ImportModule("QuestieMap")
	if not (QuestieMap and QuestieMap.UnloadManualFrames) then return end
	hooksecurefunc(QuestieMap, "UnloadManualFrames", function(self, id, typ)
		if (typ ~= nil and typ ~= "any") or type(id) ~= "number" then return end
		if id > 0 then
			QuestieMap:UnloadManualFrames(id, HALO_TYP_NPC)
		elseif id < 0 then
			QuestieMap:UnloadManualFrames(-id, HALO_TYP_OBJECT)
		end
	end)
end)

-- Кнопка у миникарты: перетащить предмет на кнопку — показать источники; щелчок — открыть карту
-- на зоне меток; правый щелчок — убрать все метки; перетаскивание кнопки — сдвинуть по кругу.
local mmButton

local function ButtonPosition()
	local angle = math.rad((WhereToGetDB and WhereToGetDB.buttonPos) or 200)
	local x, y = math.cos(angle), math.sin(angle)
	local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
	if shape == "SQUARE" then
		x = math.max(-80, math.min(x * 103.137, 80))
		y = math.max(-80, math.min(y * 103.137, 80))
	else
		x, y = x * 80, y * 80
	end
	mmButton:ClearAllPoints()
	mmButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Предмет, который держат на курсоре (взяли из сумки): показать его источники
local function TakeCursorItem()
	local kind, itemID, link = GetCursorInfo()
	if kind ~= "item" or not itemID then return false end
	ClearCursor()
	WhereToGet_ShowItem(itemID, link)
	return true
end

local function ButtonTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("Где добыть")
	local any = false
	for _, info in pairs(shownInfo) do
		if not any then GameTooltip:AddLine("Отмечено на карте:", 1, 0.82, 0) end
		any = true
		GameTooltip:AddLine("  " .. info.name, 1, 1, 1)
	end
	if not any then GameTooltip:AddLine("На карте нет меток.", 0.6, 0.6, 0.6) end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Перетащите предмет на кнопку — показать, где его добыть", 0.6, 0.8, 1, true)
	GameTooltip:AddLine("Щелчок — открыть карту на зоне меток", 0.6, 0.8, 1, true)
	GameTooltip:AddLine("Правый щелчок — убрать все метки", 0.6, 0.8, 1, true)
	GameTooltip:AddLine("Перетащить кнопку — сдвинуть", 0.6, 0.6, 0.6, true)
	GameTooltip:Show()
end

local function CreateMinimapButton()
	local b = CreateFrame("Button", "WhereToGetMinimapButton", Minimap)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:SetWidth(31); b:SetHeight(31)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetWidth(53); border:SetHeight(53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")
	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetWidth(20); icon:SetHeight(20)
	icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	icon:SetPoint("TOPLEFT", 7, -5)

	b:SetScript("OnClick", function(self, button)
		if TakeCursorItem() then return end
		if button == "RightButton" then
			WhereToGet_ClearAll()
		else
			local info = lastItemID and shownInfo[lastItemID]
			if not info then
				Print("на карте нет меток. Перетащите предмет на кнопку или щёлкните по реагенту в CraftPlan.")
			elseif not OpenMapAt(info.area) then
				ToggleFrame(WorldMapFrame)
			end
		end
		if GameTooltip:IsOwned(self) then ButtonTooltip(self) end
	end)
	b:SetScript("OnReceiveDrag", function(self)
		TakeCursorItem()
		ButtonTooltip(self)
	end)
	b:SetScript("OnDragStart", function(self)
		GameTooltip:Hide()
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			WhereToGetDB = WhereToGetDB or {}
			WhereToGetDB.buttonPos = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
			ButtonPosition()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", ButtonTooltip)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	mmButton = b
end

function WhereToGet_UpdateButton()
	if not mmButton then CreateMinimapButton() end
	ButtonPosition()
	if WhereToGetDB and WhereToGetDB.hideButton then mmButton:Hide() else mmButton:Show() end
end

local buttonInit = CreateFrame("Frame")
buttonInit:RegisterEvent("PLAYER_LOGIN")
buttonInit:SetScript("OnEvent", WhereToGet_UpdateButton)
end)()
