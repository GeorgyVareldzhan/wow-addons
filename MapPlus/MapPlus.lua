-- MapPlus: дополнения к карте мира.
-- Кнопка «Путь к ближайшей полётке» — стрелка TomTom к ближайшему распорядителю полётов (ниже).
-- Туман войны: галочка на карте мира дорисовывает районы, где вы ещё не были, — чуть темнее
-- исследованных. Только картинка: исследование районов и достижения не засчитываются.
-- Районы — из MapPlusFogData (Data.lua), рисуем так же, как сам интерфейс рисует исследованные
-- (WorldMapFrame_Update): текстура режется на куски 256x256 с номерами 1, 2, 3…

local TILE = 256
local UNEXPLORED_COLOR = { 0.6, 0.6, 0.6 } -- неисследованные районы темнее

local function DB()
	MapPlusDB = MapPlusDB or {}
	return MapPlusDB
end

local function FogRemoved()
	return DB().noFog == true
end

----------------------------------------------------------------------------------------------
-- Неисследованные районы
local textures = {} -- свои текстуры на WorldMapDetailFrame, переиспользуются
local used = 0

local function GetTexture()
	used = used + 1
	local t = textures[used]
	if not t then
		t = WorldMapDetailFrame:CreateTexture(nil, "ARTWORK")
		textures[used] = t
	end
	return t
end

-- Размер файла куска: степень двойки от 16, не меньше нужного (так считает и интерфейс)
local function FileSize(pixels)
	local size = 16
	while size < pixels do size = size * 2 end
	return size
end

local function DrawOverlay(path, width, height, offsetX, offsetY)
	local wide, tall = math.ceil(width / TILE), math.ceil(height / TILE)
	for j = 1, tall do
		local pixelH, fileH = TILE, TILE
		if j == tall then
			pixelH = height % TILE
			if pixelH == 0 then pixelH = TILE end
			fileH = FileSize(pixelH)
		end
		for k = 1, wide do
			local pixelW, fileW = TILE, TILE
			if k == wide then
				pixelW = width % TILE
				if pixelW == 0 then pixelW = TILE end
				fileW = FileSize(pixelW)
			end
			local t = GetTexture()
			t:ClearAllPoints()
			t:SetWidth(pixelW)
			t:SetHeight(pixelH)
			t:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
			t:SetPoint("TOPLEFT", WorldMapDetailFrame, "TOPLEFT", offsetX + TILE * (k - 1), -(offsetY + TILE * (j - 1)))
			t:SetTexture(path .. ((j - 1) * wide + k))
			t:SetVertexColor(UNEXPLORED_COLOR[1], UNEXPLORED_COLOR[2], UNEXPLORED_COLOR[3])
			t:Show()
		end
	end
end

local function UpdateFog()
	used = 0
	local mapFile = GetMapInfo()
	local list = FogRemoved() and mapFile and MapPlusFogData and MapPlusFogData[mapFile]
	if list and (GetCurrentMapDungeonLevel() or 0) == 0 then
		-- уже исследованные рисует сам интерфейс — их пропускаем
		local explored = {}
		for i = 1, GetNumMapOverlays() do
			local name = GetMapOverlayInfo(i)
			local base = name and name:match("([^\\]+)$")
			if base then explored[base:upper()] = true end
		end
		local prefix = "Interface\\WorldMap\\" .. mapFile .. "\\"
		for _, entry in ipairs(list) do
			local name, w, h, x, y = entry:match("^([^:]+):(%d+):(%d+):(%d+):(%d+)$")
			if name and not explored[name] then
				DrawOverlay(prefix .. name, tonumber(w), tonumber(h), tonumber(x), tonumber(y))
			end
		end
	end
	for i = used + 1, #textures do textures[i]:Hide() end
end

hooksecurefunc("WorldMapFrame_Update", UpdateFog)

----------------------------------------------------------------------------------------------
-- Галочка на карте мира, под картой слева
local check = CreateFrame("CheckButton", "MapPlusFogCheck", WorldMapFrame, "OptionsCheckButtonTemplate")
check:SetWidth(24)
check:SetHeight(24)
check:SetPoint("TOPLEFT", WorldMapDetailFrame, "BOTTOMLEFT", 0, -2)
check:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 5)
_G[check:GetName() .. "Text"]:SetText("Убрать туман войны")
check:SetScript("OnClick", function(self)
	DB().noFog = self:GetChecked() and true or false
	UpdateFog()
end)
check:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Убрать туман войны")
	GameTooltip:AddLine("Показать районы, где вы ещё не были (они чуть темнее). Исследование и достижения от этого не засчитываются.", 1, 1, 1, true)
	GameTooltip:Show()
end)
check:SetScript("OnLeave", function() GameTooltip:Hide() end)

----------------------------------------------------------------------------------------------
-- Путь к ближайшей полётке: распорядители полётов вашей фракции из базы Questie, расстояние —
-- по мировым координатам (на том же континенте), путь — TomTom через Questie
local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r " .. msg) end

-- Где вы: мировые координаты и континент. Карта мира могла быть открыта на другой зоне —
-- на миг переключаем её на вашу и возвращаем обратно
local function PlayerWorld()
	local HBD = QuestieCompat and QuestieCompat.HBD
	if not HBD then return end
	local prevArea, prevLevel, prevCont = GetCurrentMapAreaID(), GetCurrentMapDungeonLevel(), GetCurrentMapContinent()
	SetMapToCurrentZone()
	local x, y = GetPlayerMapPosition("player")
	local ui = QuestieCompat.GetCurrentUiMapID()
	if WorldMapFrame:IsShown() then
		if prevArea and prevArea > 0 then
			SetMapByID(prevArea - 1) -- в 3.3.5 номер на 1 меньше GetCurrentMapAreaID (так делает и Questie)
			if prevLevel and prevLevel > 0 then SetDungeonMapLevel(prevLevel) end
		else
			SetMapZoom(prevCont) -- карта мира или континента
		end
	end
	if not (x and x > 0) then return end
	return HBD:GetWorldCoordinatesFromZone(x, y, ui)
end

local function NearestFlightMaster()
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local ZoneDB = QuestieLoader and QuestieLoader:ImportModule("ZoneDB")
	local list = Questie and Questie.db and Questie.db.global.townsfolk and Questie.db.global.townsfolk["Flight Master"]
	if not (QuestieDB and ZoneDB and list) then return nil, "база Questie ещё не загружена — попробуйте через минуту." end
	local px, py, pInst = PlayerWorld()
	if not px then return nil, "не удалось определить, где вы (в подземелье путь не строится)." end
	local HBD = QuestieCompat.HBD
	local faction = (UnitFactionGroup("player") == "Horde") and "H" or "A"
	local best, bestD
	for _, id in ipairs(list) do
		local f = QuestieDB.QueryNPCSingle(id, "friendlyToFaction")
		if f and f:find(faction, 1, true) then
			for area, spots in pairs(QuestieDB.QueryNPCSingle(id, "spawns") or {}) do
				local ui = ZoneDB:GetUiMapIdByAreaId(area)
				for _, spot in ipairs(ui and spots or {}) do
					local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(spot[1] / 100, spot[2] / 100, ui)
					if wx and inst == pInst then
						local d = ((wx - px) ^ 2 + (wy - py) ^ 2) ^ 0.5
						if not bestD or d < bestD then
							best, bestD = { id = id, area = area, x = spot[1], y = spot[2] }, d
						end
					end
				end
			end
		end
	end
	if not best then return nil, "на этом континенте полёток вашей фракции в базе Questie нет." end
	best.name = QuestieDB.QueryNPCSingle(best.id, "name") or "Распорядитель полётов"
	return best, bestD
end

-- Путь TomTom через Questie; если Questie не может (например, Даларан — не зона в списке
-- клиента), ставим точку на карте континента по тем же координатам
local CONTINENT_BY_INSTANCE = { [1] = 1, [0] = 2, [530] = 3, [571] = 4 }
local function SetWaypoint(title, area, x, y)
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	if TrackerUtils and TrackerUtils.SetTomTomTarget
		and pcall(TrackerUtils.SetTomTomTarget, TrackerUtils, title, area, x, y) then
		return true
	end
	local ZoneDB = QuestieLoader and QuestieLoader:ImportModule("ZoneDB")
	local HBD = QuestieCompat and QuestieCompat.HBD
	if not (TomTom and TomTom.AddZWaypoint and ZoneDB and HBD) then return false end
	local ui = ZoneDB:GetUiMapIdByAreaId(area)
	if not ui then return false end
	local wx, wy = HBD:GetWorldCoordinatesFromZone(x / 100, y / 100, ui)
	local cont = ui
	while cont and HBD.mapData[cont] and HBD.mapData[cont].mapType ~= 2 do cont = HBD.mapData[cont].parent end
	local data = cont and HBD.mapData[cont]
	local C = data and CONTINENT_BY_INSTANCE[data.instance]
	local cx, cy
	if wx and C then cx, cy = HBD:GetZoneCoordinatesFromWorld(wx, wy, cont) end
	if not cx then return false end
	local db = Questie and Questie.db and Questie.db.char
	if db and db._tom_waypoint and TomTom.RemoveWaypoint then pcall(TomTom.RemoveWaypoint, TomTom, db._tom_waypoint) end
	local uid = TomTom:AddZWaypoint(C, 0, cx * 100, cy * 100, title)
	if db then db._tom_waypoint = uid end
	return uid ~= nil
end

local function WaypointToFlight()
	if not TomTom then Print("нужен аддон TomTom.") return end
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	local best, d = NearestFlightMaster()
	if not best then Print(d) return end
	if not (TrackerUtils and TrackerUtils.SetTomTomTarget) then Print("нужен Questie.") return end
	local zone = TrackerUtils.GetZoneNameByID and TrackerUtils:GetZoneNameByID(best.area) or "?"
	if not SetWaypoint(best.name .. " (полёты)", best.area, best.x, best.y) then Print("не удалось поставить точку TomTom.") return end
	Print(string.format("путь TomTom: %s, %s (%.0f, %.0f), примерно %d ярдов по прямой.", best.name, zone, best.x, best.y, math.floor(d + 0.5)))
end

local flight = CreateFrame("Button", "MapPlusFlightButton", WorldMapFrame, "UIPanelButtonTemplate")
flight:SetWidth(200)
flight:SetHeight(22)
flight:SetPoint("LEFT", _G[check:GetName() .. "Text"], "RIGHT", 20, 0)
flight:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 5)
flight:SetText("Путь к ближайшей полётке")
flight:SetScript("OnClick", WaypointToFlight)
flight:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Путь к ближайшей полётке")
	GameTooltip:AddLine("Ставит стрелку TomTom к ближайшему от вас распорядителю полётов вашей фракции на этом континенте (по базе Questie, по прямой).", 1, 1, 1, true)
	GameTooltip:Show()
end)
flight:SetScript("OnLeave", function() GameTooltip:Hide() end)

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
	check:SetChecked(FogRemoved())
	DB().taxi, DB().taxiV, DB().noFlightPins = nil, nil, nil -- от убранных значков полёток
	if WorldMapFrame:IsShown() then UpdateFog() end
end)

-- /mapplus fog — то же, что галочка
SLASH_MAPPLUS1 = "/mapplus"
SlashCmdList["MAPPLUS"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "fly" then
		WaypointToFlight()
	elseif msg == "fog" then
		DB().noFog = not FogRemoved()
		check:SetChecked(FogRemoved())
		UpdateFog()
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r туман войны " .. (FogRemoved() and "убран" or "показан") .. ".")
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r /mapplus fog — убрать или вернуть туман войны (или галочка под картой мира), /mapplus fly — путь к ближайшей полётке.")
	end
end
