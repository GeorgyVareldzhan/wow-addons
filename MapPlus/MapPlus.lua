-- MapPlus: дополнения к карте мира.
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

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
	check:SetChecked(FogRemoved())
	if WorldMapFrame:IsShown() then UpdateFog() end
end)

-- /mapplus fog — то же, что галочка
SLASH_MAPPLUS1 = "/mapplus"
SlashCmdList["MAPPLUS"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "fog" then
		DB().noFog = not FogRemoved()
		check:SetChecked(FogRemoved())
		UpdateFog()
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r туман войны " .. (FogRemoved() and "убран" or "показан") .. ".")
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r /mapplus fog — убрать или вернуть туман войны (или галочка под картой мира).")
	end
end
