-- MapPlus: дополнения к карте мира.
-- Кнопка «Путь к ближайшей полётке» — стрелка TomTom к ближайшему распорядителю полётов (ниже).
-- Полётки на карте: значки распорядителей, открыта ли полётка, щелчок — путь TomTom.
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

local function WaypointToFlight()
	if not TomTom then Print("нужен аддон TomTom.") return end
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	local best, d = NearestFlightMaster()
	if not best then Print(d) return end
	if not (TrackerUtils and TrackerUtils.SetTomTomTarget) then Print("нужен Questie.") return end
	local zone = TrackerUtils.GetZoneNameByID and TrackerUtils:GetZoneNameByID(best.area) or "?"
	TrackerUtils:SetTomTomTarget(best.name .. " (полёты)", best.area, best.x, best.y)
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

----------------------------------------------------------------------------------------------
-- Полётки на карте мира: значок у каждого распорядителя полётов вашей фракции (база Questie).
-- Зелёный — полётка открыта, красный — не открыта, серый — ещё неизвестно. Открытые игра
-- сообщает только при открытой карте полётов: на TAXIMAP_OPENED запоминаем все известные точки
-- этого континента (в мировых координатах). Распорядитель «открыт», если рядом есть такая точка
local KNOWN_RANGE = 150 -- ярдов: точка карты полётов и место распорядителя совпадают не идеально
local PIN_SIZE = 16
local fmCache -- { { id, name, area, x, y, wx, wy, inst }, ... }

local function FlightMasters()
	if fmCache then return fmCache end
	local QuestieDB = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	local ZoneDB = QuestieLoader and QuestieLoader:ImportModule("ZoneDB")
	local list = Questie and Questie.db and Questie.db.global.townsfolk and Questie.db.global.townsfolk["Flight Master"]
	local HBD = QuestieCompat and QuestieCompat.HBD
	if not (QuestieDB and ZoneDB and list and HBD) then return nil end
	local faction = (UnitFactionGroup("player") == "Horde") and "H" or "A"
	fmCache = {}
	for _, id in ipairs(list) do
		local f = QuestieDB.QueryNPCSingle(id, "friendlyToFaction")
		if f and f:find(faction, 1, true) then
			local name = QuestieDB.QueryNPCSingle(id, "name") or "Распорядитель полётов"
			for area, spots in pairs(QuestieDB.QueryNPCSingle(id, "spawns") or {}) do
				local ui = ZoneDB:GetUiMapIdByAreaId(area)
				for _, spot in ipairs(ui and spots or {}) do
					local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(spot[1] / 100, spot[2] / 100, ui)
					if wx then
						fmCache[#fmCache + 1] = { id = id, name = name, area = area, x = spot[1], y = spot[2], wx = wx, wy = wy, inst = inst }
					end
				end
			end
		end
	end
	return fmCache
end

-- Открыта ли полётка: true / false; nil — карту полётов на этом континенте ещё не открывали
local function FlightKnown(fm)
	local nodes = DB().taxi and DB().taxi[fm.inst]
	if not nodes then return nil end
	for _, n in ipairs(nodes) do
		if ((n[2] - fm.wx) ^ 2 + (n[3] - fm.wy) ^ 2) ^ 0.5 <= KNOWN_RANGE then return true, n[1] end
	end
	return false
end

-- Прямая t = a·r + b по парам { r, t } (метод наименьших квадратов); nil — мало точек или нелепый масштаб
local function LinFit(p)
	if #p < 3 then return nil end
	local mr, mt = 0, 0
	for _, q in ipairs(p) do mr, mt = mr + q[1], mt + q[2] end
	mr, mt = mr / #p, mt / #p
	local srr, srt = 0, 0
	for _, q in ipairs(p) do srr, srt = srr + (q[1] - mr) ^ 2, srt + (q[1] - mr) * (q[2] - mt) end
	if srr < 1e-6 then return nil end
	local a = srt / srr
	if a < 0.5 or a > 2 then return nil end
	return a, mt - a * mr
end

-- Сдвиг при известном масштабе a (когда точек меньше трёх)
local function ShiftFit(p, a)
	if #p == 0 then return nil end
	local s = 0
	for _, q in ipairs(p) do s = s + q[2] - a * q[1] end
	return s / #p
end

-- Карта полётов открыта: известные точки континента. TaxiNodePosition — доли карты полётов: ось Y
-- снизу вверх, масштаб и сдвиг иные, чем у карты континента (проверено по Восточным королевствам).
-- Поэтому подгоняем: каждую точку сопоставляем с ближайшим распорядителем из базы Questie и по парам
-- уточняем масштаб и сдвиг по каждой оси (три прохода, допуск сужается)
local function RememberTaxi()
	local HBD = QuestieCompat and QuestieCompat.HBD
	if not HBD then return end
	SetMapToCurrentZone()
	SetMapZoom(GetCurrentMapContinent())
	local contUi = QuestieCompat.GetCurrentUiMapID()
	SetMapToCurrentZone()
	local data = HBD.mapData[contUi]
	if not (data and data[1] and data[1] > 0) then return end
	local inst, w, h = data.instance, data[1], data[2]
	local raw = {}
	for i = 1, NumTaxiNodes() do
		local x, y = TaxiNodePosition(i)
		if TaxiNodeGetType(i) ~= "NONE" and x then raw[#raw + 1] = { TaxiNodeName(i), x, 1 - y } end
	end
	if #raw == 0 then return end
	local real = {}
	for _, fm in ipairs(FlightMasters() or {}) do
		if fm.inst == inst then
			local rx, ry = HBD:GetZoneCoordinatesFromWorld(fm.wx, fm.wy, contUi, true)
			if rx then real[#real + 1] = { rx, ry } end
		end
	end
	local ax, bx, ay, by = 1, 0, 1, 0
	for _, lim in ipairs({ 2000, 800, 300 }) do
		local px, py = {}, {}
		for _, n in ipairs(raw) do
			local gx, gy = (n[2] - bx) / ax, (n[3] - by) / ay
			local best, bd
			for _, r in ipairs(real) do
				local d = (((r[1] - gx) * w) ^ 2 + ((r[2] - gy) * h) ^ 2) ^ 0.5
				if not bd or d < bd then best, bd = r, d end
			end
			if best and bd <= lim then
				px[#px + 1] = { best[1], n[2] }
				py[#py + 1] = { best[2], n[3] }
			end
		end
		local a1, b1 = LinFit(px)
		local a2, b2 = LinFit(py)
		if a1 and a2 then
			ax, bx, ay, by = a1, b1, a2, b2
		else
			bx = ShiftFit(px, ax) or bx
			by = ShiftFit(py, ay) or by
		end
	end
	local nodes = {}
	for _, n in ipairs(raw) do
		local wx, wy = HBD:GetWorldCoordinatesFromZone((n[2] - bx) / ax, (n[3] - by) / ay, contUi)
		if wx then nodes[#nodes + 1] = { n[1], wx, wy } end
	end
	if #nodes > 0 then
		DB().taxi = DB().taxi or {}
		DB().taxi[inst] = nodes
		DB().taxiV = 2
	end
end

local pins, pinsUsed = {}, 0
local function PinEnter(self)
	local fm = self.fm
	local known, node = FlightKnown(fm)
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	local zone = TrackerUtils and TrackerUtils.GetZoneNameByID and TrackerUtils:GetZoneNameByID(fm.area)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(fm.name)
	GameTooltip:AddLine("Распорядитель полётов" .. (zone and (", " .. zone) or ""), 0.8, 0.8, 0.8)
	if known then
		GameTooltip:AddLine("Полётка открыта" .. (node and (": " .. node) or ""), 0.25, 1, 0.25)
	elseif known == false then
		GameTooltip:AddLine("Полётка не открыта — поговорите с распорядителем", 1, 0.3, 0.3, true)
	else
		GameTooltip:AddLine("Неизвестно: на этом континенте карту полётов ещё не открывали (поговорите с любым распорядителем)", 0.7, 0.7, 0.7, true)
	end
	GameTooltip:AddLine("Щелчок — путь TomTom", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end
local function PinClick(self)
	local fm = self.fm
	local TrackerUtils = QuestieLoader and QuestieLoader:ImportModule("TrackerUtils")
	if not (TomTom and TrackerUtils and TrackerUtils.SetTomTomTarget) then Print("нужны TomTom и Questie.") return end
	TrackerUtils:SetTomTomTarget(fm.name .. " (полёты)", fm.area, fm.x, fm.y)
	Print("путь TomTom: " .. fm.name .. ".")
end
local function GetPin()
	pinsUsed = pinsUsed + 1
	local b = pins[pinsUsed]
	if not b then
		b = CreateFrame("Button", nil, WorldMapButton)
		b:SetWidth(PIN_SIZE)
		b:SetHeight(PIN_SIZE)
		b.icon = b:CreateTexture(nil, "OVERLAY")
		b.icon:SetAllPoints()
		b.icon:SetTexture("Interface\\Minimap\\Tracking\\FlightMaster")
		b:SetScript("OnEnter", PinEnter)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("OnClick", PinClick)
		pins[pinsUsed] = b
	end
	b:SetFrameLevel(WorldMapButton:GetFrameLevel() + 6)
	return b
end

local function UpdatePins()
	pinsUsed = 0
	local HBD = QuestieCompat and QuestieCompat.HBD
	local list = DB().noFlightPins ~= true and WorldMapFrame:IsShown() and HBD and FlightMasters()
	if list then
		local ui = QuestieCompat.GetCurrentUiMapID()
		local data = HBD.mapData[ui]
		local W, H = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
		for _, fm in ipairs(data and list or {}) do
			if fm.inst == data.instance then
				local x, y = HBD:GetZoneCoordinatesFromWorld(fm.wx, fm.wy, ui)
				if x then
					local b = GetPin()
					b.fm = fm
					b:ClearAllPoints()
					b:SetPoint("CENTER", WorldMapButton, "TOPLEFT", x * W, -y * H)
					local known = FlightKnown(fm)
					if known then b.icon:SetVertexColor(0.3, 1, 0.3)
					elseif known == false then b.icon:SetVertexColor(1, 0.3, 0.3)
					else b.icon:SetVertexColor(0.7, 0.7, 0.7) end
					b:Show()
				end
			end
		end
	end
	for i = pinsUsed + 1, #pins do pins[i]:Hide() end
end
hooksecurefunc("WorldMapFrame_Update", function() pcall(UpdatePins) end)

local pinCheck = CreateFrame("CheckButton", "MapPlusFlightCheck", WorldMapFrame, "OptionsCheckButtonTemplate")
pinCheck:SetWidth(24)
pinCheck:SetHeight(24)
pinCheck:SetPoint("LEFT", flight, "RIGHT", 12, 0)
pinCheck:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 5)
_G[pinCheck:GetName() .. "Text"]:SetText("Полётки на карте")
pinCheck:SetScript("OnClick", function(self)
	DB().noFlightPins = not self:GetChecked()
	pcall(UpdatePins)
end)
pinCheck:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Полётки на карте")
	GameTooltip:AddLine("Значки распорядителей полётов вашей фракции: зелёный — открыта, красный — не открыта, серый — неизвестно (откройте карту полётов на этом континенте). Наведите — подробности, щёлкните — путь TomTom.", 1, 1, 1, true)
	GameTooltip:Show()
end)
pinCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

local taxiEvents = CreateFrame("Frame")
taxiEvents:RegisterEvent("TAXIMAP_OPENED")
taxiEvents:SetScript("OnEvent", function() pcall(RememberTaxi) end)

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
	check:SetChecked(FogRemoved())
	pinCheck:SetChecked(DB().noFlightPins ~= true)
	if DB().taxiV ~= 2 then DB().taxi = nil end -- точки 0.1.2 пересчитаны неверно: забыть, запомнятся заново
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
