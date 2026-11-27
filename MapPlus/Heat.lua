-- MapPlus: где вы добывали жилы — запись каждой добычи (MapPlusDB.heat[зона] = { {x, y, жила, время}, ... })
-- и тепловая карта на карте мира (не на миникарте): поле плотности по сетке, соседние жилы сливаются в одно
-- пятно, зелёное, от прозрачного (одна жила, края) к плотному (больше всего в зоне). Режим «вся карта»: каждая
-- жила влияет на всю зону (размытие SIGMA), цвет от красного (жил нет) к зелёному (больше всего).
-- Выбор под картой: «Жилы: нет / пятна / вся карта».
-- Запись — когда GatherMate добавляет жилу (Collector:addItem): место игрока, зона GatherMate, название жилы.

local TYPE = "Mining"
local R = 80        -- ярдов: радиус пятна от одной жилы
local COLS = 200    -- клеток сетки по ширине зоны
local LEVELS = 20   -- оттенков (соседние клетки одного оттенка рисуются одной полосой)
local ALPHA_MIN, ALPHA_MAX = 0.1, 0.7 -- редко — жидко, часто — плотно
local NEW_R = 20      -- ярдов: «то же место» для счёта в чате (дальше от всех записанных — новое место)
local SAME = 8        -- ярдов: повторная добыча той же жилы
local SIGMA = 100     -- ярдов: размытие в режиме «вся карта»
local COLS_FULL = 120 -- клеток по ширине в режиме «вся карта» (считается всё поле)
local ALPHA_FULL = 0.45
local LOG_K = 1       -- «вся карта»: чем больше, тем дальше от красного уже одна жила (1 — около 30% шкалы)

local function DB()
	MapPlusDB = MapPlusDB or {}
	MapPlusDB.heat = MapPlusDB.heat or {}
	if MapPlusDB.heatOn == nil then MapPlusDB.heatOn = true end
	-- heatMode: nil — пятна, "full" — вся карта
	return MapPlusDB
end

local function GM()
	local ace = LibStub and LibStub("AceAddon-3.0", true)
	return ace and ace:GetAddon("GatherMate", true)
end

-- зона GatherMate, открытая на карте мира
local function ViewZone(gm)
	if (GetCurrentMapDungeonLevel() or 0) > 0 or not gm.MapZoneName then return end
	local zone = gm:MapZoneName()
	if zone and rawget(gm.zoneData, zone) then return zone end
end

----------------------------------------------------------------------------------------------
-- рисование: полосы одного оттенка в строке сетки
local layer = CreateFrame("Frame", nil, WorldMapDetailFrame)
layer:SetAllPoints(WorldMapDetailFrame)
layer:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 1)
local tex, nTex = {}, 0

local function Bar(x, y, w, h, q, full)
	nTex = nTex + 1
	local T = tex[nTex]
	if not T then
		T = layer:CreateTexture(nil, "BACKGROUND")
		T:SetTexture("Interface\\Buttons\\WHITE8X8")
		tex[nTex] = T
	end
	-- q: 1..LEVELS; только зелёный, плотнее: где жилы бывают часто — почти сплошной цвет,
	-- где редко — прозрачный
	-- вся карта: красный (жил нет) → жёлтый → зелёный (больше всего), прозрачность одна
	local t = (q - 1) / (LEVELS - 1)
	if full then
		T:SetVertexColor(math.min(1, (1 - t) * 2), math.min(1, t * 2), 0.15, ALPHA_FULL)
	else
		T:SetVertexColor(0.1, 1, 0.2, ALPHA_MIN + (ALPHA_MAX - ALPHA_MIN) * t)
	end
	T:ClearAllPoints()
	T:SetPoint("TOPLEFT", layer, "TOPLEFT", x, -y)
	T:SetWidth(w)
	T:SetHeight(h)
	T:Show()
end

-- поле: для каждой клетки сумма (1 - (d/R)^2) по жилам ближе R; кеш по зоне и числу записей
local cache = {}

-- вся карта: сумма exp(-d²/2σ²) по жилам (дальше 3σ — ноль); жилы сначала собраны по клеткам сетки
local function FieldFull(list, zw, zh)
	local cell = zw / COLS_FULL
	local rows = math.ceil(zh / cell)
	local w = {}
	for _, v in ipairs(list) do
		local k = math.floor(v[2] * zh / cell) * COLS_FULL + math.floor(v[1] * zw / cell)
		w[k] = (w[k] or 0) + 1
	end
	local f, mx = {}, 0
	local rc = math.ceil(3 * SIGMA / cell)
	local e = 1 / (2 * SIGMA * SIGMA)
	for k, n in pairs(w) do
		local ci, cj = k % COLS_FULL, math.floor(k / COLS_FULL)
		for j = math.max(0, cj - rc), math.min(rows - 1, cj + rc) do
			for i = math.max(0, ci - rc), math.min(COLS_FULL - 1, ci + rc) do
				local dx, dy = (i - ci) * cell, (j - cj) * cell
				local kk = j * COLS_FULL + i
				f[kk] = (f[kk] or 0) + n * math.exp(-(dx * dx + dy * dy) * e)
			end
		end
	end
	for _, s in pairs(f) do if s > mx then mx = s end end
	return f, mx, rows
end

local function Field(gm, zone, full)
	local list = DB().heat[zone] or {}
	local c = cache[zone]
	if c and c.n == #list and c.full == full then return c end
	local zw, zh = gm:GetZoneSize(zone)
	if not zw or zw == 0 then return end
	if full then
		local f, mx, rows = FieldFull(list, zw, zh)
		c = { n = #list, full = full, f = f, mx = mx, rows = rows, cols = COLS_FULL }
		cache[zone] = c
		return c
	end
	local cell = zw / COLS
	local rows = math.ceil(zh / cell)
	local f, mx = {}, 0
	local rc = math.ceil(R / cell)
	for _, v in ipairs(list) do
		local px, py = v[1] * zw, v[2] * zh
		local ci, cj = math.floor(px / cell), math.floor(py / cell)
		for j = math.max(0, cj - rc), math.min(rows - 1, cj + rc) do
			for i = math.max(0, ci - rc), math.min(COLS - 1, ci + rc) do
				local dx, dy = (i + 0.5) * cell - px, (j + 0.5) * cell - py
				local d2 = (dx * dx + dy * dy) / (R * R)
				if d2 < 1 then
					local k = j * COLS + i
					local s = (f[k] or 0) + 1 - d2
					f[k] = s
					if s > mx then mx = s end
				end
			end
		end
	end
	c = { n = #list, full = full, f = f, mx = mx, rows = rows, cols = COLS }
	cache[zone] = c
	return c
end

-- маршрут в зоне не выбран — жилы не показываем, выбор «Жилы» скрыт
local function HasRoute(zone) return zone and DB().route and DB().route[zone] and true or false end
local SetText -- ниже

local function Draw()
	nTex = 0
	local gm = GM()
	local full = DB().heatMode == "full"
	local vz = gm and WorldMapFrame:IsShown() and ViewZone(gm)
	if SetText then SetText(vz) end
	local zone = vz and DB().heatOn and HasRoute(vz) and vz
	local c = zone and Field(gm, zone, full)
	if c and c.mx > 0 then
		local W, H = WorldMapDetailFrame:GetWidth(), WorldMapDetailFrame:GetHeight()
		local zw, zh = gm:GetZoneSize(zone)
		local N = c.cols
		local cw, ch = W / N, H * (zw / N) / zh -- клетка квадратная в ярдах
		-- уровень клетки: доля от самой горячей; пятна: одна жила в центре (1.0) — не ниже 2-го оттенка;
		-- вся карта: логарифм доли самой горячей (одна жила заметна и рядом с густыми местами), пустые — 1-й (красный)
		local mx = full and c.mx or math.max(c.mx, 1)
		for j = 0, c.rows - 1 do
			local run, rq = nil, nil
			for i = 0, N do
				local s = i < N and c.f[j * N + i]
				local q
				if full then
					q = i < N and (math.floor(math.log(1 + LOG_K * (s or 0)) / math.log(1 + LOG_K * mx) * (LEVELS - 1) + 0.5) + 1) or nil
				else
					q = s and math.max(1, math.min(LEVELS, math.ceil(s / mx * LEVELS))) or nil
					if s and s < 0.15 then q = 1 end
				end
				if q ~= rq then
					if rq then Bar(run * cw, j * ch, (i - run) * cw + 0.5, ch + 0.5, rq, full) end
					run, rq = i, q
				end
			end
		end
	end
	for i = nTex + 1, #tex do tex[i]:Hide() end
end

hooksecurefunc("WorldMapFrame_Update", Draw)

-- «место» — круг NEW_R ярдов. Места зоны: записи по убыванию числа соседей, каждая ещё не взятая — центр места,
-- её соседи — в нём. Отдаёт номер места записи k (1 — самое частое), сколько мест всего
local function PlaceRank(list, k, zw, zh)
	local R2 = NEW_R * NEW_R
	local grid = {}
	local function key(i, j) return i * 100000 + j end
	for n, v in ipairs(list) do
		local g = key(math.floor(v[1] * zw / NEW_R), math.floor(v[2] * zh / NEW_R))
		grid[g] = grid[g] or {}
		table.insert(grid[g], n)
	end
	local function Near(n, fn)
		local v = list[n]
		local ci, cj = math.floor(v[1] * zw / NEW_R), math.floor(v[2] * zh / NEW_R)
		for i = ci - 1, ci + 1 do
			for j = cj - 1, cj + 1 do
				for _, m in ipairs(grid[key(i, j)] or {}) do
					local w = list[m]
					if ((w[1] - v[1]) * zw) ^ 2 + ((w[2] - v[2]) * zh) ^ 2 < R2 then fn(m) end
				end
			end
		end
	end
	local cnt, order = {}, {}
	for n = 1, #list do
		local c = 0
		Near(n, function() c = c + 1 end)
		cnt[n], order[n] = c, n
	end
	table.sort(order, function(a, b) if cnt[a] ~= cnt[b] then return cnt[a] > cnt[b] end return a < b end)
	local taken, places, rank = {}, 0, nil
	for _, n in ipairs(order) do
		if not taken[n] then
			places = places + 1
			taken[n] = true
			if n == k then rank = places end
			Near(n, function(m)
				if not taken[m] then
					taken[m] = true
					if m == k then rank = places end
				end
			end)
		end
	end
	return rank, places
end

local function Ago(sec)
	local m = math.floor(sec / 60)
	if m < 60 then return string.format("%d мин", m) end
	if m < 1440 then return string.format("%d ч %d мин", math.floor(m / 60), m % 60) end
	return string.format("%d дн.", math.floor(m / 1440))
end

-- в чат после записи k-й жилы, одной строкой (новое место в зоне с разведанным кругом — красным: перестроить маршрут): сколько раз здесь, оценка, место в зоне, когда прошлый раз
local function Report(list, k, zone, zw, zh)
	local v = list[k]
	local here, last = 0, nil
	for n, w in ipairs(list) do
		if ((w[1] - v[1]) * zw) ^ 2 + ((w[2] - v[2]) * zh) ^ 2 < NEW_R * NEW_R then
			here = here + 1
			if n ~= k and w[4] and w[4] > 0 and (not last or w[4] > last) then last = w[4] end
		end
	end
	if here == 1 and MapPlusScouted and MapPlusScouted(zone) then -- новое место у разведанного круга
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r |cffff3333обнаружена новая жила, сгенерируйте новый маршрут.|r")
		return
	end
	local grade = here == 1 and "новое место" or here <= 3 and "бывает" or here <= 6 and "хорошее место"
		or "отличное место"
	local rank, places = PlaceRank(list, k, zw, zh)
	DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff66ccffMapPlus:|r %d-й раз здесь — %s (%d из %d)%s.",
		here, grade, rank or places, places, last and (", прошлый " .. Ago(v[4] - last) .. " назад") or ""))
end

----------------------------------------------------------------------------------------------
-- запись: GatherMate засчитал добычу жилы
local last = {}
-- ведём по кругу другой зоны, а игра считает, что вы уже в соседней (точка круга у границы): место — в
-- координатах зоны круга (Astrolabe из TomTom), если оно на её карте; иначе nil
local function Across(zone)
	if not MapPlusFollowZone then return end
	local fz, fc, fzi = MapPlusFollowZone()
	if not (fz and fc and fz ~= zone and DongleStub) then return end
	local ok, A = pcall(DongleStub, "Astrolabe-0.4-Sirus")
	if not (ok and A) then return end
	local c, z, px, py = A:GetCurrentPlayerPosition()
	if not c then return end
	local x, y = A:TranslateWorldMapPosition(c, z, px, py, fc, fzi)
	if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return x, y end
end

local function Add(gm, what)
	if not (what and gm:GetIDForNode(TYPE, what)) then return end
	local zone = gm:ResolveZone(GetRealZoneText())
	if not (zone and rawget(gm.zoneData, zone)) then return end
	local x, y = Across(zone)
	if x then
		zone = MapPlusFollowZone()
	else
		if WorldMapFrame:IsShown() and ViewZone(gm) ~= zone then return end -- карта на другой зоне — место неверное
		x, y = GetPlayerMapPosition("player")
		if not x or (x == 0 and y == 0) then return end
	end
	x, y = math.floor(x * 10000 + 0.5) / 10000, math.floor(y * 10000 + 0.5) / 10000
	-- та же жила: в одну жилу копают 2–3 раза подряд — засчитываем один раз (то же название, ближе SAME ярдов, минута)
	local zw, zh = gm:GetZoneSize(zone)
	if last.zone == zone and last.what == what and GetTime() - last.t < 60 and zw and zw > 0
		and ((x - last.x) * zw) ^ 2 + ((y - last.y) * zh) ^ 2 < SAME * SAME then
		last.t = GetTime()
		return
	end
	last.zone, last.x, last.y, last.what, last.t = zone, x, y, what, GetTime()
	local db = DB()
	db.heat[zone] = db.heat[zone] or {}
	local list = db.heat[zone]
	list[#list + 1] = { x, y, what, time() }
	if zw and zw > 0 then Report(list, #list, zone, zw, zh) end
	if WorldMapFrame:IsShown() then Draw() end
end

----------------------------------------------------------------------------------------------
-- выбор «Жилы: нет / пятна / вся карта» — под кнопками маршрута (столбиком справа от карты)
local drop = CreateFrame("Frame", "MapPlusHeatDrop", WorldMapFrame, "UIDropDownMenuTemplate")
local routeStart = _G.MapPlusRouteStart
if routeStart then
	drop:SetPoint("TOPLEFT", routeStart, "BOTTOMLEFT", -16, -26 - 4)
else
	drop:SetPoint("TOPRIGHT", WorldMapDetailFrame, "BOTTOMRIGHT", 0, 0)
end
drop:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 5)
UIDropDownMenu_SetWidth(drop, 111)

local MODES = { { false, "нет" }, { "spots", "пятна" }, { "full", "вся карта" } }
local function Mode() local db = DB() return db.heatOn and (db.heatMode or "spots") or false end
SetText = function(zone)
	if zone == nil then local gm = GM() zone = gm and ViewZone(gm) end
	local on = HasRoute(zone)
	if on then drop:Show() else drop:Hide() end
	local mode = on and Mode() or false
	for _, m in ipairs(MODES) do if m[1] == mode then _G.MapPlusHeatDropText:SetText("Жилы: " .. m[2]) end end
end
-- для Route.lua: маршрут сменили — перерисовать
function MapPlusHeatRefresh() Draw() end

UIDropDownMenu_Initialize(drop, function(_, level)
	for _, m in ipairs(MODES) do
		local info = UIDropDownMenu_CreateInfo()
		info.text = m[2]
		info.checked = Mode() == m[1]
		info.func = function()
			local db = DB()
			db.heatOn = m[1] and true or false
			if m[1] then db.heatMode = m[1] == "full" and "full" or nil end
			SetText()
			Draw()
		end
		UIDropDownMenu_AddButton(info, level)
	end
end)

drop:EnableMouse(true)
drop:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Где вы добывали жилы")
	local gm = GM()
	local zone = gm and ViewZone(gm)
	if zone then
		local n = #(DB().heat[zone] or {})
		GameTooltip:AddLine(string.format("%s: %d", zone, n), 1, 1, 1)
	end
	GameTooltip:Show()
end)
drop:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- записям без названия жилы — название по умолчанию; прежние ключи — вон
local DEF_NAME = "Месторождение саронита"
local function Purge()
	local db = DB()
	for _, list in pairs(db.heat) do
		for _, w in ipairs(list) do if not w[3] then w[3] = DEF_NAME end end
	end
	db.hits, db.heatSeeded = nil, nil
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
	SetText()
	local gm = GM()
	local col = gm and gm.GetModule and gm:GetModule("Collector", true)
	Purge()
	if col and col.addItem then
		hooksecurefunc(col, "addItem", function(_, _, what) Add(gm, what) end)
	end
end)
