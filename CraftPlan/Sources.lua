-- CraftPlan 2.0 — where to learn a recipe: at the trainer (db.learn: skill, cost) or a recipe item
-- ("Чертеж: …" from the Questie database): which vendors of your faction sell it and at what skill.
-- The Questie database is big — we scan it once per session, a little per frame.
local CP = CraftPlan
local DB = CP.DB

local PER_FRAME = 1500

-- Lowercase and "е" instead of "ё": Questie has "Рецепт: копченый шалфокунь", the game "Копченый шалфокунь"
local function Norm(str)
	str = str:gsub("\208\129", "\208\149"):gsub("\209\145", "\208\181")
	str = str:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end)
	str = str:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end)
	return str:lower()
end

-- Norm with a memo: recipe names are looked up again and again (the set of names is bounded)
local normMemo = {}
local function NormC(str)
	local v = normMemo[str]
	if not v then v = Norm(str); normMemo[str] = v end
	return v
end

-- The Questie database is ready (built after login); nil when Questie isn't there or not built yet
local function QuestieReady()
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	return QuestieDB and QuestieDB.ItemPointers and QuestieDB.QueryItem and QuestieDB or nil
end

local items     -- after the scan: [profession|normalized name] = recipe item id
local scanning

-- Price in copper -> "1g 2s 30c" with coin icons
function CP.Money(copper)
	copper = math.floor(copper + 0.5)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local t = {}
	if g > 0 then t[#t + 1] = g .. "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t" end
	if s > 0 then t[#t + 1] = s .. "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t" end
	if c > 0 or #t == 0 then t[#t + 1] = c .. "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" end
	return table.concat(t, " ")
end

-- Recipe item for a recipe, or nil (also nil while the database isn't scanned yet)
function CP.RecipeItem(prof, name)
	return items and items[prof .. "|" .. NormC(name)]
end

-- The recipe name a recipe ITEM teaches: "Чертеж: X" -> "X"; Sirus "Формула чар для X: Y" -> "Чары для X - Y".
-- Second value: the plain part after the prefix ("Y"). nil when the name has no "Prefix: " part.
function CP.RecipeNameFromItem(itemName)
	local pre, rec = (itemName or ""):match("^([^:]+):%s*(.+)$")
	if not rec then return nil end
	local part = pre:match("^Формула чар для (.+)$")
	if part then return "Чары для " .. part .. " - " .. rec, rec end
	return rec, rec
end

-- Vendors of your faction that sell the item: { { text, name, area, spot } }
local vendorCache = {}
function CP.VendorsOf(item)
	if vendorCache[item] then return vendorCache[item] end
	local Townsfolk = QuestieLoader and QuestieLoader:ImportModule("Townsfolk")
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	local list = {}
	local ok, set = false, nil
	if Townsfolk and Townsfolk.PopulateVendors and QuestieDB and QuestieReady() then
		ok, set = pcall(Townsfolk.PopulateVendors, Townsfolk, { item }, {})
	end
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
	-- Questie not ready yet (or the call failed) — answer empty, but ask again next time
	if ok or not IsAddOnLoaded("Questie-335") then vendorCache[item] = list end
	return list
end

-- Where to find an item (Questie database): what it's gathered from, which mobs, which vendors, which zones.
-- Tooltip lines; nil — no Questie or nothing is known about the item
local srcCache = {}
function CP.ItemSources(item)
	if srcCache[item] ~= nil then return srcCache[item] or nil end
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	if not (QuestieDB and QuestieDB.QueryItem and QuestieReady()) then return nil end -- not ready: ask again later
	local ok, src = pcall(QuestieDB.QueryItem, item, { "npcDrops", "objectDrops", "vendors" })
	if not ok then return nil end -- failed: don't remember "nothing"
	if not src then srcCache[item] = false return nil end
	local zones = {} -- zone -> number of sources
	local function Count(spawns)
		for area in pairs(spawns or {}) do zones[area] = (zones[area] or 0) + 1 end
	end
	local out = {}
	-- objects (veins, herbs, chests): names without duplicates
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
	-- mobs: how many
	local mobs = 0
	for _, npc in pairs(src[1] or {}) do
		mobs = mobs + 1
		Count(QuestieDB.QueryNPCSingle(npc, "spawns"))
	end
	if mobs > 0 then out[#out + 1] = "Падает с мобов: " .. mobs .. "." end
	-- vendors of your faction
	local vendors = CP.VendorsOf(item)
	for i = 1, math.min(2, #vendors) do out[#out + 1] = "Продаёт: " .. vendors[i].text end
	if #vendors > 2 then out[#out + 1] = "и ещё торговцев: " .. (#vendors - 2) end
	-- zones with the most sources
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

-- Where to learn: tooltip lines (nil — nothing to say)
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
	if not items then return { "Ищу в базе Questie..." } end
	return { "Скорее всего у учителя: откройте его окно с «Недоступными» — аддон запишет, с какого навыка." }
end

-- Scan of the Questie database: names "Prefix: recipe" that exist in the recipe table
local function StartScan()
	if items or scanning then return end
	local QuestieDB = QuestieReady()
	local ptrs = QuestieDB and QuestieDB.ItemPointers
	if not (ptrs and QuestieDB.QueryItemSingle) then return end
	scanning = true
	local byName = {} -- normalized name -> { profession, name as in the game }
	for prof, id in pairs(CP.SKILL_ID) do
		for _, rec in ipairs(CP.Recipes(id)) do byName[Norm(rec.name)] = { prof, rec.name } end
	end
	local found, key = {}, nil
	local function Batch()
		for _ = 1, PER_FRAME do
			key = next(ptrs, key)
			if not key then return true end
			local name = QuestieDB.QueryItemSingle(key, "name")
			-- the plain part first, then the Sirus enchanting form ("Формула чар для X: Y" is "Чары для X - Y")
			local taught, plain = CP.RecipeNameFromItem(name)
			local hit = plain and byName[Norm(plain)]
			if not hit and taught and taught ~= plain then hit = byName[Norm(taught)] end
			if hit then found[hit[1] .. "|" .. Norm(hit[2])] = key end
		end
	end
	local f = CreateFrame("Frame")
	f:SetScript("OnUpdate", function(self)
		local ok, done = pcall(Batch)
		if ok and not done then return end
		-- finished, or an error: stop with what was found so far
		self:SetScript("OnUpdate", nil)
		if not ok then CP.Print("|cffff4040ошибка поиска рецептов в Questie:|r " .. tostring(done)) end
		items, scanning = found, false
		CP.Changed()
	end)
end

-- Questie builds its database after login — start a bit later and retry until it works
-- (not at all without Questie; give up after MAX_WAITS tries)
local MAX_WAITS = 60 -- 5 s each
local waitFrame, waited, tries = CreateFrame("Frame"), 0, 0
waitFrame:SetScript("OnUpdate", function(self, elapsed)
	waited = waited + elapsed
	if waited < 5 then return end
	waited = 0
	tries = tries + 1
	if not IsAddOnLoaded("Questie-335") or tries > MAX_WAITS then
		self:SetScript("OnUpdate", nil)
		if not (items or scanning) then items = {} end -- no recipe items to know: stop "searching"
		return
	end
	StartScan()
	if items or scanning then self:SetScript("OnUpdate", nil) end
end)

----------------------------------------------------------------------------------------------
-- "Где фармить": in which zones to get the missing raw materials.
-- Veins and herbs — from GatherMate (nodes you or your imports have found), mobs (not above your level + 5),
-- gathering objects and vendors of your faction — from Questie. Zones are compared by their localized names.

-- Ore / stone → GatherMate mining node ids (GatherMate/Constants.lua), as in 0.12
-- (more than CP.ORES / CP.STONE: also ore that can't be prospected; local — nothing else reads it)
local ORE_NODES = {
	[2770] = { 201 }, [2771] = { 202 }, [2772] = { 203 }, [2775] = { 204, 209 }, [2776] = { 205, 210 },
	[3858] = { 206, 207 }, [7911] = { 208, 211 }, [10620] = { 212, 213, 214, 215 }, [11370] = { 217 },
	[3340] = { 219 }, [4278] = { 218 }, [5833] = { 220 }, [23424] = { 221 }, [23425] = { 222, 223 },
	[23426] = { 224 }, [36909] = { 228, 229 }, [36912] = { 231, 232 }, [36910] = { 230 },
	-- stones are mined from the same veins
	[2835] = { 201 }, [2836] = { 202, 204, 209 }, [2838] = { 203, 205, 210 }, [7912] = { 206, 207, 208, 211 },
	[12365] = { 212, 213, 214, 215 },
}

-- Veins (Data/VeinData.lua, Sirus knowledge base): per ore — the ordinary vein (the one with the least ore per node:
-- an honest "how many veins"), and what else drops from the veins of this ore
local veinBase, veinOf
local function VeinIndex()
	if veinBase then return end
	veinBase, veinOf = {}, {}
	for _, v in pairs(CraftPlan_VeinData or {}) do
		local per
		for _, d in ipairs(v) do if d[1] == v.ore then per = d[2] / 100 * d[5] end end
		if per and per > 0 then
			local b = veinBase[v.ore]
			if not b or per < b.per then
				local drops = {}
				for _, d in ipairs(v) do if d[1] ~= v.ore then drops[d[1]] = d[2] / 100 * d[5] end end
				veinBase[v.ore] = { per = per, name = v.name, drops = drops }
			end
		end
		for _, d in ipairs(v) do
			if d[1] ~= v.ore then
				local t = veinOf[d[1]] or {}
				veinOf[d[1]] = t
				local cur = t[v.name]
				if not cur or d[2] > cur.pct then t[v.name] = { pct = d[2], ore = v.ore, name = v.name } end
			end
		end
	end
end
-- ordinary vein of an ore: { per = ore per node, name, drops = { [item] = expected pieces per node } }
function CP.VeinBase(ore) VeinIndex(); return veinBase[ore] end
-- how many veins for n ore (nil — no data)
function CP.VeinsFor(ore, n)
	local b = CP.VeinBase(ore)
	return b and n > 0 and math.ceil(n / b.per - 1e-9) or nil
end
-- veins an item drops from (not their own ore): { { name, pct, ore }, ... } by chance
function CP.VeinSources(item)
	VeinIndex()
	local out = {}
	for _, e in pairs(veinOf[item] or {}) do out[#out + 1] = e end
	table.sort(out, function(a, b) if a.pct ~= b.pct then return a.pct > b.pct end return a.name < b.name end)
	return out
end
local MOB_LEVEL_UP = 5
local CONTAINER_WORDS = { "сундук", "ящик", "сейф", "бочк", "бочон", "мешок", "кулек", "кулёк", "корзин", "тайник", "ларец", "шкатулк",
	"chest", "crate", "box", "barrel", "sack", "cache", "strongbox" }

-- GatherMate: count nodes of a set per zone name -> { [zone] = n }
local function GMZones(dbName, set)
	local out = {}
	local nodes = _G[dbName]
	if not (GatherMate and GatherMate.zoneData and nodes) then return out end
	local seen = {}
	for zoneName, zd in pairs(GatherMate.zoneData) do
		local idx = zd[3]
		local db = idx and nodes[idx]
		if db and not seen[idx] then
			seen[idx] = true
			local c = 0
			for _, nodeID in pairs(db) do if set[nodeID] then c = c + 1 end end
			if c > 0 then out[zoneName] = c end
		end
	end
	return out
end

-- Herb item -> GatherMate herb node id (by name)
local function HerbNode(item)
	local ids = GatherMate and GatherMate.nodeIDs and GatherMate.nodeIDs["Herb Gathering"]
	if not ids then return nil end
	local name = Norm(CP.ItemName(item))
	for nodeName, id in pairs(ids) do
		if Norm(nodeName) == name then return id end
	end
end

-- Sources of one item by zone: { [zone] = { veins, herbs, mobs, objects, vendors, area } } (cached for the session
-- once GatherMate and Questie have answered; while one of them is loaded but not ready the answer isn't kept)
local zoneCache = {}
function CP.ItemZones(item)
	if zoneCache[item] then return zoneCache[item] end
	local out = {}
	local ready = not GatherMate or GatherMate.zoneData ~= nil
	local function Z(zone)
		local z = out[zone]
		if not z then z = { veins = 0, herbs = 0, mobs = 0, objects = 0, vendors = 0 }; out[zone] = z end
		return z
	end
	-- veins: of this ore/stone, or veins that drop this item along the way (gems, crystals)
	local veinSet
	if ORE_NODES[item] then
		veinSet = {}
		for _, n in ipairs(ORE_NODES[item]) do veinSet[n] = true end
	else
		for _, e in ipairs(CP.VeinSources(item)) do
			for _, n in ipairs(ORE_NODES[e.ore] or {}) do veinSet = veinSet or {}; veinSet[n] = true end
		end
	end
	if veinSet then
		for zone, n in pairs(GMZones("GatherMateMineDB", veinSet)) do Z(zone).veins = n end
	end
	if not ORE_NODES[item] then
		local herb = HerbNode(item)
		if herb then
			for zone, n in pairs(GMZones("GatherMateHerbDB", { [herb] = true })) do Z(zone).herbs = n end
		end
	end
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	if IsAddOnLoaded("Questie-335") and not QuestieReady() then ready = false end
	if QuestieDB and QuestieDB.QueryItem and TrackerUtils and TrackerUtils.GetZoneNameByID then
		local ok, src = pcall(QuestieDB.QueryItem, item, { "npcDrops", "objectDrops", "vendors" })
		if not ok then ready = false end
		if ok and src then
			local function Areas(spawns, field, area0)
				for area in pairs(spawns or {}) do
					local zone = TrackerUtils:GetZoneNameByID(area)
					if zone then
						local z = Z(zone)
						z[field] = z[field] + 1
						z.area = z.area or area
					end
				end
			end
			local maxLevel = UnitLevel("player") + MOB_LEVEL_UP
			for _, npc in pairs(src[1] or {}) do
				local lvl = QuestieDB.QueryNPCSingle(npc, "minLevel")
				if not lvl or lvl <= maxLevel then Areas(QuestieDB.QueryNPCSingle(npc, "spawns"), "mobs") end
			end
			if not ORE_NODES[item] then -- veins come from GatherMate; Questie objects for ore are chests and such
				for _, obj in pairs(src[2] or {}) do
					local nm = Norm(QuestieDB.QueryObjectSingle(obj, "name") or "")
					local container = false
					for _, w in ipairs(CONTAINER_WORDS) do if nm:find(w, 1, true) then container = true break end end
					if not container then Areas(QuestieDB.QueryObjectSingle(obj, "spawns"), "objects") end
				end
			end
		end
		for _, v in ipairs(CP.VendorsOf(item)) do
			if v.area then
				local zone = TrackerUtils:GetZoneNameByID(v.area)
				if zone then local z = Z(zone); z.vendors = z.vendors + 1; z.area = z.area or v.area end
			end
		end
	end
	if ready then zoneCache[item] = out end
	return out
end

-- Zones for a list of missing items { { id, short } }: sorted by how many of the items can be got there,
-- then by the number of sources; the zone you are in goes first when it has anything.
-- -> { { zone, area, here, items = { { id, short, veins, herbs, mobs, objects, vendors } } } }
function CP.FarmZones(missing)
	local byZone = {}
	for _, m in ipairs(missing) do
		for zone, z in pairs(CP.ItemZones(m.id)) do
			local e = byZone[zone]
			if not e then e = { zone = zone, area = z.area, items = {}, total = 0 }; byZone[zone] = e end
			e.area = e.area or z.area
			e.items[#e.items + 1] = { id = m.id, short = m.short, veins = z.veins, herbs = z.herbs, mobs = z.mobs, objects = z.objects, vendors = z.vendors }
			e.total = e.total + z.veins + z.herbs + z.mobs + z.objects + z.vendors
		end
	end
	local here = GetRealZoneText()
	local list = {}
	for _, e in pairs(byZone) do e.here = (e.zone == here); list[#list + 1] = e end
	table.sort(list, function(a, b)
		if a.here ~= b.here then return a.here end
		if #a.items ~= #b.items then return #a.items > #b.items end
		if a.total ~= b.total then return a.total > b.total end
		return a.zone < b.zone
	end)
	return list
end

-- Where a not learned recipe is learned: { at = true, cost } — at the trainer; { at = false } — not at the trainer
-- (a recipe item exists, or the trainer list of this profession is known and lacks it); nil — unknown
function CP.LearnInfo(sk, prof, name)
	local learn = DB().learn and DB().learn[sk]
	local t = learn and learn[name]
	if t then return { at = true, cost = t.cost or 0 } end
	if (learn and next(learn)) or CP.RecipeItem(prof, name) then return { at = false } end
end
