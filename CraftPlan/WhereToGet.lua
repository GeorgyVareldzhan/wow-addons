-- CraftPlan 2.0: "where to get" (Questie) — item sources on the map, and NPCs such as profession trainers
----------------------------------------------------------------------------------------------
-- Where to get (formerly the WhereToGet addon): item sources on the map via Questie, a minimap button.
-- A separate function — its own locals, not interfering with the rest of the code.
(function()
-- An item dropped onto the minimap button (or a click on a reagent in the plan) gets marked on the map
-- via Questie: where it drops (mobs), is gathered (objects) or is sold (vendors).
-- Calling again for the same item removes the marks.

-- Old-world fish: Questie corrections wipe its pools (objectDrops = {}), although the pools themselves
-- with coordinates are in the database. The lists come from the Questie database (wotlkItemDB) before corrections
local POOL_OBJECTS = {
	[6358] = { 180248, 180582, 180664, 180682, 180750, 180900 }, -- Oily Blackmouth
	[6359] = { 180248, 180657, 180661, 180683, 180752, 180902 }, -- Firefin Snapper
	[6522] = { 180658 },                                         -- Deviate Fish
	[13422] = { 180248, 180712 },                                -- Stonescale Eel
	[21071] = { 180656, 180663 },                                -- Raw Sagefish
	[21153] = { 180684, 184956 },                                -- Raw Greater Sagefish
}

-- Pools on the map: a fish icon of this size; these words in a Questie object name identify a pool
local POOL_SCALE = 1.3
local POOL_WORDS = { "School", "Pool", "Swarm", "Shoal", "Wreckage", "Debris", "Floating", "Oil Spill" }

local MAX_SOURCES = 40 -- don't draw more than this, so the map isn't flooded (e.g. cloth drops from almost everything)

-- Halo: a large soft glow under each mark; nearby ones merge into an area blob
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

-- itemID -> list of { id, typ } for QuestieMap:UnloadManualFrames
-- (regular marks: typ = nil, NPC id > 0, objects id < 0; halos: their own typ, id > 0)
local shownByItem = {}
-- itemID -> { name = "[Name]", area = areaId of the zone with the most marks } — for the minimap button
local shownInfo = {}
local lastItemID -- last marked item

-- Open the world map on a zone (areaId) via Questie
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

-- Show an item's sources on the map by id (also called from other addons, e.g. CraftPlan).
-- Calling again for the same item removes the marks.
function WhereToGet_ShowItem(itemID, link, quiet)
	local Print = quiet and function() end or Print -- quiet: no chat, no map (map marks from CraftPlan "Где фармить")
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
	if type(QuestieDB.QueryNPCSingle) ~= "function" or type(QuestieDB.QueryItem) ~= "function" then
		Print("Questie ещё загружается — попробуйте через минуту.")
		return
	end

	-- Pressing again on the same item — remove the marks (quiet calls never remove)
	if shownByItem[itemID] and quiet then return end
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
	local zoneCounts = {} -- areaId -> number of sources with spawn points in this zone
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
			if halo then -- draw the halo first so it sits under the mark
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
	-- a fish pool gets a large mark with the fish icon, otherwise the standard Questie dot is hard to see
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

	-- Which zones to search: the current zone is highlighted, the rest by number of sources
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

		-- open the world map on the zone with marks: the current one if there are sources here, otherwise the one
		-- with the most (otherwise the map opens on the current zone and the marks aren't visible)
		local targetArea = hereArea or (list[1] and list[1][3])
		shownInfo[itemID].area = targetArea
		if not quiet then OpenMapAt(targetArea) end
	end
end

-- NPCs on the map by id (CraftPlan: trainers of a profession). key — what to remember the marks by;
-- calling again with the same key removes them
function WhereToGet_ShowNPCs(key, npcs, title)
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local QuestieMap = QuestieLoader and QuestieLoader:ImportModule("QuestieMap")
	if not (QuestieDB and QuestieMap and QuestieMap.ShowNPC) then Print("Questie не загружен.") return end
	-- before Questie finishes its start-up (it may rebuild its database after a client restart) the queries are not set up
	if type(QuestieDB.QueryNPCSingle) ~= "function" then Print("Questie ещё загружается — попробуйте через минуту.") return end
	if shownByItem[key] then
		UnloadEntries(QuestieMap, shownByItem[key])
		shownByItem[key], shownInfo[key] = nil, nil
		if lastItemID == key then lastItemID = next(shownInfo) end
		Print(title .. ": отметки убраны с карты.")
		return
	end
	local entries, zoneCounts, total = {}, {}, 0
	for _, npcID in ipairs(npcs) do
		local spawns = QuestieDB.QueryNPCSingle(npcID, "spawns")
		if spawns and next(spawns) then
			for areaId in pairs(spawns) do zoneCounts[areaId] = (zoneCounts[areaId] or 0) + 1 end
			QuestieMap:ShowNPC(npcID)
			entries[#entries + 1] = { npcID }
			total = total + 1
		end
	end
	if total == 0 then Print(title .. ": в базе Questie нет координат.") return end
	shownByItem[key], shownInfo[key], lastItemID = entries, { name = title }, key
	local TrackerUtils = QuestieLoader:ImportModule("TrackerUtils")
	local here, hereArea, list = GetRealZoneText(), nil, {}
	for areaId, n in pairs(zoneCounts) do
		local zn = TrackerUtils and TrackerUtils.GetZoneNameByID and TrackerUtils:GetZoneNameByID(areaId) or tostring(areaId)
		if zn == here then hereArea = areaId else list[#list + 1] = { zn, n, areaId } end
	end
	table.sort(list, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
	local parts = {}
	for i = 1, math.min(#list, 8) do parts[#parts + 1] = list[i][1] end
	if #list > 8 then parts[#parts + 1] = "и ещё " .. (#list - 8) end
	Print(title .. ": " .. total .. " на карте. " .. (hereArea and "|cff00ff00Есть в этой зоне.|r " or "") ..
		(parts[1] and ("Зоны: " .. table.concat(parts, ", ") .. ".") or "") .. " Повторный щелчок — убрать.")
	local target = hereArea or (list[1] and list[1][3])
	shownInfo[key].area = target
	OpenMapAt(target)
end

-- For CraftPlan: is the item marked; open the world map on a Questie area
function WhereToGet_IsShown(itemID) return shownByItem[itemID] ~= nil end
WhereToGet_OpenMapAt = OpenMapAt

-- Remove the marks of all items at once, without hovering an item
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

-- /wtg clear — remove all marks; /wtg — help
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

-- Shift+click on a Questie mark removes the mark — remove its halo along with it
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

-- Minimap button: drop an item onto it to show sources; click to open the map
-- on the marks' zone; right click removes all marks; drag the button to move it around the ring.
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

-- An item held on the cursor (taken from a bag): show its sources
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
