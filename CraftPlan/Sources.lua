-- CraftPlan 2.0 — где учить рецепт: у учителя (db.learn: с какого навыка, цена) или рецепт-предмет
-- («Чертеж: …» из базы Questie): у каких торговцев вашей фракции и с какого навыка.
-- База Questie большая — перебираем её один раз за сессию, понемногу за кадр.
local CP = CraftPlan
local DB = CP.DB

local PER_FRAME = 1500

-- Строчные буквы и «е» вместо «ё»: в базе Questie «Рецепт: копченый шалфокунь», в игре «Копченый шалфокунь»
local function Norm(str)
	str = str:gsub("\208\129", "\208\149"):gsub("\209\145", "\208\181")
	str = str:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end)
	str = str:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end)
	return str:lower()
end

local items     -- после перебора: [профессия|норм. название] = номер рецепта-предмета
local scanning

-- Цена в медных монетах -> «1з 2с 30м» значками монет
function CP.Money(copper)
	copper = math.floor(copper + 0.5)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local t = {}
	if g > 0 then t[#t + 1] = g .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t" end
	if s > 0 then t[#t + 1] = s .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t" end
	if c > 0 or #t == 0 then t[#t + 1] = c .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" end
	return table.concat(t, " ")
end

-- Рецепт-предмет для рецепта или nil (nil и пока база не перебрана)
function CP.RecipeItem(prof, name)
	return items and items[prof .. "|" .. Norm(name)]
end

-- Торговцы вашей фракции, у которых продаётся предмет: { { text, name, area, spot } }
local vendorCache = {}
function CP.VendorsOf(item)
	if vendorCache[item] then return vendorCache[item] end
	local Townsfolk = QuestieLoader and QuestieLoader:ImportModule("Townsfolk")
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	local list = {}
	local ok, set = false, nil
	if Townsfolk and Townsfolk.PopulateVendors then ok, set = pcall(Townsfolk.PopulateVendors, Townsfolk, { item }, {}) end
	local faction = (UnitFactionGroup("player") == "Horde") and "H" or "A"
	for npc in pairs(ok and set or {}) do
		local f = QuestieDB.QueryNPCSingle(npc, "friendlyToFaction")
		if f and f:find(faction, 1, true) then
			local zone, area1, spot
			for area, pts in pairs(QuestieDB.QueryNPCSingle(npc, "spawns") or {}) do
				zone = TrackerUtils and TrackerUtils.GetZoneNameByID and TrackerUtils:GetZoneNameByID(area)
				area1, spot = area, pts[1]
				break
			end
			local name = QuestieDB.QueryNPCSingle(npc, "name") or "?"
			list[#list + 1] = { text = name .. (zone and (" (" .. zone .. ")") or ""), name = name, area = area1, spot = spot }
		end
	end
	table.sort(list, function(a, b) return a.text < b.text end)
	vendorCache[item] = list
	return list
end

-- Где искать предмет (база Questie): с чего добывается, с каких мобов, у каких торговцев, в каких зонах.
-- Строки для подсказки; nil — Questie нет или о предмете ничего не известно
local srcCache = {}
function CP.ItemSources(item)
	if srcCache[item] ~= nil then return srcCache[item] or nil end
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	if not (QuestieDB and QuestieDB.QueryItem) then return nil end
	local ok, src = pcall(QuestieDB.QueryItem, item, { "npcDrops", "objectDrops", "vendors" })
	if not ok or not src then srcCache[item] = false return nil end
	local zones = {} -- зона -> число источников
	local function Count(spawns)
		for area in pairs(spawns or {}) do zones[area] = (zones[area] or 0) + 1 end
	end
	local out = {}
	-- объекты (жилы, травы, сундуки): названия без повторов
	local names, seen = {}, {}
	for _, obj in pairs(src[2] or {}) do
		local nm = QuestieDB.QueryObjectSingle(obj, "name")
		Count(QuestieDB.QueryObjectSingle(obj, "spawns"))
		if nm and not seen[nm] then seen[nm] = true names[#names + 1] = nm end
	end
	table.sort(names)
	if #names > 0 then
		out[#out + 1] = "Добывается: " .. table.concat(names, ", ", 1, math.min(3, #names)) .. (#names > 3 and (" и ещё " .. (#names - 3)) or "") .. "."
	end
	-- мобы: сколько
	local mobs = 0
	for _, npc in pairs(src[1] or {}) do
		mobs = mobs + 1
		Count(QuestieDB.QueryNPCSingle(npc, "spawns"))
	end
	if mobs > 0 then out[#out + 1] = "Падает с мобов: " .. mobs .. "." end
	-- торговцы вашей фракции
	local vendors = CP.VendorsOf(item)
	for i = 1, math.min(2, #vendors) do out[#out + 1] = "Продаёт: " .. vendors[i].text end
	if #vendors > 2 then out[#out + 1] = "и ещё торговцев: " .. (#vendors - 2) end
	-- зоны, где больше всего источников
	if TrackerUtils and TrackerUtils.GetZoneNameByID and next(zones) then
		local list = {}
		for area, n in pairs(zones) do list[#list + 1] = { TrackerUtils:GetZoneNameByID(area) or "?", n } end
		table.sort(list, function(a, b) return a[2] > b[2] end)
		local parts = {}
		for i = 1, math.min(4, #list) do parts[i] = list[i][1] end
		out[#out + 1] = "Зоны: " .. table.concat(parts, ", ") .. (#list > 4 and (" и ещё " .. (#list - 4)) or "") .. "."
	end
	srcCache[item] = #out > 0 and out or false
	return srcCache[item] or nil
end

-- Где учить: строки для подсказки (nil — нечего сказать)
function CP.RecipeSource(prof, name)
	local sk = CP.SKILL_ID[prof]
	local learn = DB().learn and DB().learn[sk]
	local t = learn and learn[name]
	if t then
		return { "Учитель профессии, с навыка " .. t.req .. (t.cost > 0 and (", " .. CP.Money(t.cost)) or "") .. "." }
	end
	local item = CP.RecipeItem(prof, name)
	if item then
		local req = CP.BookReq(item, prof)
		local itemName = GetItemInfo(item) or ("рецепт-предмет " .. item)
		local out = { itemName .. (req and (", с навыка " .. req) or "") .. "." }
		local vendors = CP.VendorsOf(item)
		if #vendors == 0 then
			out[#out + 1] = "У торговцев вашей фракции не продаётся: добыча, задание или репутация."
		else
			for i = 1, math.min(3, #vendors) do out[#out + 1] = "Продаёт: " .. vendors[i].text end
			if #vendors > 3 then out[#out + 1] = "и ещё " .. (#vendors - 3) end
		end
		return out
	end
	if learn then return { "У учителя нет — видимо, рецепт с добычи или за задание." } end
	if not items then return { "Ищу в базе Questie…" } end
	return { "Скорее всего у учителя: откройте его окно с «Недоступными» — аддон запишет, с какого навыка." }
end

-- Перебор базы Questie: имена «Префикс: рецепт», которые есть в таблице порогов
local function StartScan()
	if items or scanning or not CraftPlanThresholds then return end
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local ptrs = QuestieDB and QuestieDB.ItemPointers
	if not (ptrs and QuestieDB.QueryItemSingle) then return end
	scanning = true
	local byName = {} -- норм. название -> { профессия, название как в игре }
	for prof, id in pairs(CP.SKILL_ID) do
		for name in pairs(CraftPlanThresholds[id] or {}) do byName[Norm(name)] = { prof, name } end
	end
	local found, key = {}, nil
	local f = CreateFrame("Frame")
	f:SetScript("OnUpdate", function(self)
		for _ = 1, PER_FRAME do
			key = next(ptrs, key)
			if not key then
				self:SetScript("OnUpdate", nil)
				items, scanning = found, false
				CP.Changed()
				return
			end
			local name = QuestieDB.QueryItemSingle(key, "name")
			local pre, rec
			if name then pre, rec = name:match("^([^:]+):%s*(.+)$") end
			local hit = rec and byName[Norm(rec)]
			-- «Формула чар для нагрудника: мана I» — это «Чары для нагрудника - мана I»
			local part = not hit and pre and pre:match("^Формула чар для (.+)$")
			if part then hit = byName[Norm("Чары для " .. part .. " - " .. rec)] end
			if hit then found[hit[1] .. "|" .. Norm(hit[2])] = key end
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
	if items or scanning then self:SetScript("OnUpdate", nil) end
end)
