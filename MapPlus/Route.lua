-- MapPlus: маршрут сбора руды на карте мира — замкнутый круг через все жилы выбранной руды
-- в открытой зоне. Жилы — из базы GatherMate (что вы сами нашли). Редкие жилы, что растут на
-- месте обычных (богатый саронит, титан на месте саронита), идут вместе с обычной.
-- Путь: ближайший сосед, 2-opt (убирает пересечения), Or-opt (переносит 1-3 точки в лучшее место).
-- Жилы в пещерах (копали в помещении) убираются. Дальние — по выгоде: жилы в час =
-- n * min(1/T, 1/R), T = круг / скорость + OCC * n * GATHER, R — время появления (Respawn.lua
-- GatherMate). Убираем по одной самую дорогую (крюк на находку), оставляем лучший вариант.
-- Скорость — ваша наибольшая в полёте (запоминается), без неё 280%. Считается по кадрам.
-- Маршрут один — в одной зоне.

local TYPE = "Mining"
local MERGE = 15        -- ярдов: жилы ближе — одна точка маршрута
local MAXPTS = 800      -- больше точек не строим (долго)
local LINE_W = 24       -- толщина линии (текстура полётов, линия в середине)
local LF2 = (128 / 126) / 2 -- как TAXIROUTE_LINEFACTOR_2 в интерфейсе
local RUN = 7           -- ярдов в секунду пешком; полёт 280% = 3,8 раза
local CELL = 15         -- ярдов: клетка учёта находок и пещер
local MINPTS = 3        -- меньше точек не оставляем
local GATHER = 8        -- секунд на жилу: сесть, добыть, забрать
local OCC = 0.5         -- доля точек, где жила на месте (база этого не знает; оценка)
local DEF_RESPAWN = 900
local BUDGET = 20000    -- шагов расчёта за кадр

local function DB()
	MapPlusDB = MapPlusDB or {}
	MapPlusDB.route = MapPlusDB.route or {}
	MapPlusDB.hits = MapPlusDB.hits or {} -- [зона][клетка] = сколько раз вы там копали
	MapPlusDB.cave = MapPlusDB.cave or {} -- [зона][клетка] = true — копали в помещении (пещера)
	MapPlusDB.rev = MapPlusDB.rev or 0    -- меняется при каждой записи — маршрут пересчитать
	return MapPlusDB
end

local function Cell(x, y) return math.floor(x / CELL) .. ":" .. math.floor(y / CELL) end

-- учёт ваших находок: GatherMate добавляет жилу при каждом сборе (x, y — доли зоны)
local function Record(gm, zone, x, y, nodeType)
	if nodeType ~= TYPE or not (zone and gm.zoneData and rawget(gm.zoneData, zone)) then return end
	local zd = gm.zoneData[zone]
	local key = Cell(x * zd[1], y * zd[2])
	local db = DB()
	db.hits[zone] = db.hits[zone] or {}
	db.hits[zone][key] = (db.hits[zone][key] or 0) + 1
	if IsIndoors() then
		db.cave[zone] = db.cave[zone] or {}
		db.cave[zone][key] = true
	end
	db.rev = db.rev + 1
end

local function GM()
	local ace = LibStub and LibStub("AceAddon-3.0", true)
	return ace and ace:GetAddon("GatherMate", true)
end

-- зона GatherMate, открытая на карте мира (nil — карта континента/мира, подземелье, нет GatherMate)
-- название — из списка зон игры сейчас (GatherMate:MapZoneName): continentData строится при загрузке,
-- а на Sirus номера зон потом сдвигаются (карта Шолазара читалась как другая зона)
local function ViewZone(gm)
	if (GetCurrentMapDungeonLevel() or 0) > 0 then return end
	local zone
	if gm.MapZoneName then
		zone = gm:MapZoneName()
	else
		local cont = gm.continentData and gm.continentData[GetCurrentMapContinent()]
		zone = cont and cont[GetCurrentMapZone()]
	end
	if zone and rawget(gm.zoneData, zone) then return zone end
end

local function Rares(gm)
	local c = gm:GetModule("Collector", true)
	return c and c.rareNodes or {}
end

-- руды зоны для списка: { id, name, n }, по убыванию числа жил
local function Ores(gm, zone)
	local cnt = {}
	for _, id in gm:GetNodesForZone(zone, TYPE, true) do cnt[id] = (cnt[id] or 0) + 1 end
	local rares, list = Rares(gm), {}
	for id, n in pairs(cnt) do
		local base = rares[id]
		local own = true -- редкая без своей обычной в зоне — отдельной строкой
		if base then for b in pairs(base) do if cnt[b] then own = false end end end
		if own then
			if not base then
				for r, bs in pairs(rares) do if bs[id] and cnt[r] then n = n + cnt[r] end end
			end
			list[#list + 1] = { id = id, name = gm:GetNameForNode(TYPE, id) or ("#" .. id), n = n }
		end
	end
	table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
	return list
end

-- точки выбранной руды (с её редкими) в ярдах, близкие склеены
local function Points(gm, zone, base)
	local rares = Rares(gm)
	local zd = gm.zoneData[zone]
	local w, h = zd[1], zd[2]
	local db = DB()
	local hits, cave = db.hits[zone] or {}, db.cave[zone] or {}
	local pts, n, caves = {}, 0, 0
	for coord, id in gm:GetNodesForZone(zone, TYPE, true) do
		if id == base or (rares[id] and rares[id][base]) then
			local x, y = gm:getXY(coord)
			x, y = x * w, y * h
			local key = Cell(x, y)
			local near
			for i = 1, n do
				local p = pts[i]
				local dx, dy = p[1] - x, p[2] - y
				if dx * dx + dy * dy <= MERGE * MERGE then near = p; break end
			end
			if not near and n < MAXPTS then n = n + 1; near = { x, y, 1, false, {} }; pts[n] = near end
			if near then
				near[5][#near[5] + 1] = coord -- жилы GatherMate в этой точке (для скрытых)
				near[3] = near[3] + (hits[key] or 0) -- вес: 1 + сколько раз там копали
				if cave[key] then near[4] = true end
			end
		end
	end
	local out = {} -- пещеры — вон
	for i = 1, n do
		if pts[i][4] then caves = caves + 1 else out[#out + 1] = pts[i] end
	end
	return out, w, h, caves
end

local function Dist(a, b)
	local dx, dy = a[1] - b[1], a[2] - b[2]
	return (dx * dx + dy * dy) ^ 0.5
end

-- расчёт идёт в сопрограмме: каждые BUDGET шагов — до следующего кадра
local ops = 0
local function Y(k)
	ops = ops + (k or 1)
	if ops >= BUDGET then
		ops = 0
		if coroutine.running() then coroutine.yield() end
	end
end

local function Len(t)
	local len, n = 0, #t
	for i = 1, n do len = len + Dist(t[i], t[i % n + 1]) end
	return len
end

-- Or-opt: кусок из 1-3 точек переносим (можно задом наперёд) туда, где он короче
local function OrOpt(t)
	local n = #t
	if n < 6 then return end
	for _ = 1, 20 do
		local moved = false
		for k = 1, 3 do
			for i = 1, n do
				local p, q = t[(i - 2) % n + 1], t[(i + k - 1) % n + 1]
				local s1, s2 = t[i], t[(i + k - 2) % n + 1]
				local gain = Dist(p, s1) + Dist(s2, q) - Dist(p, q)
				local bj, bc, brev
				for j = 1, n do
					-- ребро j -> j+1 вне куска и не соседнее с ним
					local off = (j - i) % n
					if off >= k and off ~= n - 1 then
						local a, b = t[j], t[j % n + 1]
						local ab = Dist(a, b)
						local c1 = Dist(a, s1) + Dist(s2, b) - ab
						local c2 = Dist(a, s2) + Dist(s1, b) - ab
						if c1 < gain - 0.01 and (not bc or c1 < bc) then bj, bc, brev = j, c1, false end
						if c2 < gain - 0.01 and (not bc or c2 < bc) then bj, bc, brev = j, c2, true end
					end
				end
				Y(n)
				if bj then
					local seg, rest = {}, {}
					for m = 0, k - 1 do seg[#seg + 1] = t[(i + m - 1) % n + 1] end
					if brev then for a = 1, math.floor(k / 2) do seg[a], seg[k - a + 1] = seg[k - a + 1], seg[a] end end
					local after = t[bj]
					for m = 0, n - k - 1 do rest[#rest + 1] = t[(i + k + m - 1) % n + 1] end
					local out = {}
					for _, v in ipairs(rest) do
						out[#out + 1] = v
						if v == after then for _, sv in ipairs(seg) do out[#out + 1] = sv end end
					end
					for m = 1, n do t[m] = out[m] end
					moved = true
				end
			end
		end
		if not moved then break end
	end
end

-- замкнутый круг через все точки
local function Tour(pts)
	local n = #pts
	if n < 2 then return pts end
	local t, used = { pts[1] }, { [1] = true }
	for k = 2, n do
		Y(n)
		local last, best, bd = t[k - 1], nil, nil
		for i = 2, n do
			if not used[i] then
				local d = Dist(last, pts[i])
				if not bd or d < bd then best, bd = i, d end
			end
		end
		used[best] = true
		t[k] = pts[best]
	end
	for _ = 1, 30 do
		local better = false
		for i = 1, n - 2 do
			local a, b = t[i], t[i + 1]
			local dab = Dist(a, b)
			for j = i + 2, (i == 1) and n - 1 or n do
				local c, d = t[j], t[j % n + 1]
				if Dist(a, c) + Dist(b, d) < dab + Dist(c, d) - 0.01 then
					local lo, hi = i + 1, j
					while lo < hi do t[lo], t[hi] = t[hi], t[lo]; lo, hi = lo + 1, hi - 1 end
					b = t[i + 1]
					dab = Dist(a, b)
					better = true
				end
			end
			Y(n)
		end
		if not better then break end
	end
	OrOpt(t)
	return t
end

-- жил в час для круга из n точек длиной len (ярдов): скорость v ярд/с, появление r с
local function Rate(n, len, v, r)
	local T = len / v + OCC * n * GATHER
	if T <= 0 then return 0, 0 end
	return 3600 * OCC * n * math.min(1 / T, 1 / r), T
end

-- убрать невыгодные жилы: по одной самую дорогую (крюк на её находку), пока растёт выгода
local function Prune(t, v, r)
	local n = #t
	if n <= MINPTS then return t, 0 end
	local len = Len(t)
	local bestRate, best = Rate(n, len, v, r), nil
	local work = {}
	for i = 1, n do work[i] = t[i] end
	while n > MINPTS do
		local bi, bv, bd
		for i = 1, n do
			local a, p, b = work[(i - 2) % n + 1], work[i], work[i % n + 1]
			local d = Dist(a, p) + Dist(p, b) - Dist(a, b)
			local val = d / (p[3] or 1)
			if not bv or val > bv then bi, bv, bd = i, val, d end
		end
		Y(n)
		table.remove(work, bi)
		n, len = n - 1, len - bd
		local rt = Rate(n, len, v, r)
		if rt > bestRate + 1e-6 then
			bestRate = rt
			best = {}
			for i = 1, n do best[i] = work[i] end
		end
	end
	if not best then return t, 0 end
	return Tour(best), #t - #best
end

----------------------------------------------------------------------------------------------
-- рисование: отрезки текстурой линии полётов, поворот — через SetTexCoord (как DrawRouteLine)
local layer = CreateFrame("Frame", nil, WorldMapDetailFrame)
layer:SetAllPoints(WorldMapDetailFrame)
layer:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 1)
local lines, nLines = {}, 0

local function Line(sx, sy, ex, ey, w)
	nLines = nLines + 1
	local T = lines[nLines]
	if not T then
		T = layer:CreateTexture(nil, "ARTWORK")
		T:SetTexture("Interface\\TaxiFrame\\UI-Taxi-Line")
		T:SetVertexColor(1, 0.75, 0.1, 0.9)
		lines[nLines] = T
	end
	local dx, dy = ex - sx, ey - sy
	local cx, cy = (sx + ex) / 2, (sy + ey) / 2
	if dx < 0 then dx, dy = -dx, -dy end
	local l = (dx * dx + dy * dy) ^ 0.5
	T:ClearAllPoints()
	if l == 0 then T:Hide() return end
	local s, c = -dy / l, dx / l
	local sc = s * c
	local Bwid, Bhgt, BLx, BLy, TLx, TLy, TRx, TRy, BRx, BRy
	if dy >= 0 then
		Bwid = ((l * c) - (w * s)) * LF2
		Bhgt = ((w * c) - (l * s)) * LF2
		BLx, BLy, BRy = (w / l) * sc, s * s, (l / w) * sc
		BRx, TLx, TLy, TRx = 1 - BLy, BLy, 1 - BRy, 1 - BLx
		TRy = BRx
	else
		Bwid = ((l * c) + (w * s)) * LF2
		Bhgt = ((w * c) + (l * s)) * LF2
		BLx, BLy, BRx = s * s, -(l / w) * sc, 1 + (w / l) * sc
		BRy, TLx, TLy, TRy = BLx, 1 - BRx, 1 - BLx, 1 - BLy
		TRx = TLy
	end
	T:SetTexCoord(TLx, TLy, BLx, BLy, TRx, TRy, BRx, BRy)
	T:SetPoint("BOTTOMLEFT", layer, "BOTTOMLEFT", cx - Bwid, cy - Bhgt)
	T:SetPoint("TOPRIGHT", layer, "BOTTOMLEFT", cx + Bwid, cy + Bhgt)
	T:Show()
end

local cacheKey, cacheTour, cacheLen, cacheW, cacheH, cacheCaves, cacheFar, cacheV, cacheR
local job, jobKey -- идущий расчёт
local UpdateRoute

-- ваша скорость полёта (ярд/с): наибольшая замеченная, без неё 280%
local function FlySpeed() return DB().fly or RUN * 3.8 end

local function Respawn(gm, zone, base)
	local R = GatherMate_Respawn and GatherMate_Respawn[gm:GetNameForNode(TYPE, base) or ""]
	if not R then return DEF_RESPAWN end
	local z = R[zone]
	return (z and z[1]) or R["*"] or DEF_RESPAWN
end

local runner = CreateFrame("Frame")
runner:Hide()
runner:SetScript("OnUpdate", function(self)
	if not job then self:Hide() return end
	local ok, err = coroutine.resume(job)
	if not ok then
		job, jobKey = nil, nil
		self:Hide()
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r ошибка расчёта маршрута: " .. tostring(err))
	elseif coroutine.status(job) == "dead" then
		job, jobKey = nil, nil
		self:Hide()
		UpdateRoute()
	end
end)
local shown -- { zone, name, pts, len } — для подсказки
local startBtn, contBtn, endBtn -- кнопки «В начало», «Продолжить», «Закончить» (создаются ниже)
local Following -- идёт ли ведение по этому маршруту (ниже)
local CanContinue -- есть ли что продолжать (ниже)

UpdateRoute = function()
	nLines = 0
	shown = nil
	local gm = GM()
	local zone = gm and WorldMapFrame:IsShown() and ViewZone(gm)
	local base = zone and DB().route[zone]
	if base then
		local cnt = 0
		for _ in gm:GetNodesForZone(zone, TYPE, true) do cnt = cnt + 1 end
		local v, r = FlySpeed(), Respawn(gm, zone, base)
		local key = zone .. "|" .. base .. "|" .. cnt .. "|" .. DB().rev .. "|" .. math.floor(v) .. "|" .. r
		if key ~= cacheKey and key ~= jobKey then
			jobKey = key
			job = coroutine.create(function()
				local pts, w, h, caves = Points(gm, zone, base)
				local t, far = Prune(Tour(pts), v, r)
				cacheTour, cacheFar, cacheW, cacheH, cacheCaves = t, far, w, h, caves
				cacheLen, cacheV, cacheR = Len(t), v, r
				cacheKey = key
			end)
			runner:Show()
		end
		local t, n = cacheTour, cacheTour and #cacheTour or 0
		if key ~= cacheKey then n = 0 end -- старый маршрут не рисуем, ждём новый
		if n >= 2 then
			local W, H = WorldMapDetailFrame:GetWidth(), WorldMapDetailFrame:GetHeight()
			for i = 1, n do
				local a, b = t[i], t[i % n + 1]
				Line(a[1] / cacheW * W, (1 - a[2] / cacheH) * H, b[1] / cacheW * W, (1 - b[2] / cacheH) * H, LINE_W)
			end
		end
		if key == cacheKey then
			shown = { zone = zone, name = gm:GetNameForNode(TYPE, base) or "?", pts = n, len = cacheLen,
				caves = cacheCaves, far = cacheFar, v = cacheV, r = cacheR,
				tour = cacheTour, w = cacheW, h = cacheH, file = GetMapInfo() } -- файл карты — для TomTom
		end
	end
	for i = nLines + 1, #lines do lines[i]:Hide() end
	if startBtn then
		local ok = shown and shown.pts > 0 and TomTom and TomTom.AddZWaypoint
		if ok then startBtn:Show() else startBtn:Hide() end
		if ok and CanContinue() then contBtn:Show() else contBtn:Hide() end
		if ok and Following() then endBtn:Show() else endBtn:Hide() end
	end
end

----------------------------------------------------------------------------------------------
-- выпадающий список под картой: «Маршрут: нет» / руды открытой зоны
local drop = CreateFrame("Frame", "MapPlusRouteDrop", WorldMapFrame, "UIDropDownMenuTemplate")
drop:SetPoint("LEFT", MapPlusFlightButton, "RIGHT", 0, -2)
drop:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 5)
UIDropDownMenu_SetWidth(drop, 190)

local function SetText()
	local gm = GM()
	-- без GatherMate списка нет совсем
	if gm then drop:Show() else drop:Hide() return end
	local zone = gm and ViewZone(gm)
	local base = zone and DB().route[zone]
	MapPlusRouteDropText:SetText("Маршрут: " .. (base and (gm:GetNameForNode(TYPE, base) or "?") or "нет"))
end

local function Choose(zone, id)
	wipe(DB().route) -- маршрут один — только в этой зоне
	DB().route[zone] = id
	CloseDropDownMenus()
	SetText()
	UpdateRoute()
end

UIDropDownMenu_Initialize(drop, function(self, level)
	local gm = GM()
	local zone = gm and ViewZone(gm)
	local info = UIDropDownMenu_CreateInfo()
	if not zone then
		info.text = "Откройте карту зоны"
		info.disabled = true
		info.notCheckable = true
		UIDropDownMenu_AddButton(info, level)
		return
	end
	local cur = DB().route[zone]
	info.text = "Нет"
	info.checked = not cur
	info.func = function() Choose(zone, nil) end
	UIDropDownMenu_AddButton(info, level)
	for _, o in ipairs(Ores(gm, zone)) do
		info = UIDropDownMenu_CreateInfo()
		info.text = o.name .. " (" .. o.n .. ")"
		info.checked = (cur == o.id)
		info.func = function() Choose(zone, o.id) end
		UIDropDownMenu_AddButton(info, level)
	end
end)

drop:EnableMouse(true)
drop:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Маршрут по руде")
	if shown then
		GameTooltip:AddLine(string.format("%s: %d точек, круг %d ярдов", shown.name, shown.pts, shown.len), 1, 1, 1)
		local rate, T = Rate(shown.pts, shown.len, shown.v, shown.r)
		GameTooltip:AddLine(string.format("Круг примерно %.1f мин (полёт %d%%), около %d жил в час, появление %d мин",
			T / 60, math.floor(shown.v / RUN * 100 - 100 + 0.5), math.floor(rate + 0.5), math.floor(shown.r / 60 + 0.5)), 1, 1, 1)
		if shown.far > 0 or shown.caves > 0 then
			GameTooltip:AddLine(string.format("Убрано: невыгодных %d, в пещерах %d", shown.far, shown.caves), 1, 1, 1)
		end
	elseif job then
		GameTooltip:AddLine("Считаю маршрут...", 1, 1, 1)
	end
	GameTooltip:AddLine(string.format("Круг через жилы выбранной руды в этой зоне (GatherMate). Дальние жилы убираются, если без них за час выходит больше. Оценка: %d с на жилу, жила на месте в %d%% точек; скорость - ваша наибольшая в полёте.", GATHER, OCC * 100), 0.8, 0.8, 0.8, true)
	GameTooltip:Show()
end)
drop:SetScript("OnLeave", function() GameTooltip:Hide() end)

----------------------------------------------------------------------------------------------
-- ведение по кругу стрелкой TomTom (только если есть TomTom). Долетели (ARRIVE ярдов) — стрелка сама
-- переходит на следующую жилу; жилы, скрытые до появления (собраны, GatherMate), пропускаются.
-- Номер в подписи — от точки старта: «1/500» — первая точка этого круга (круг замкнут, точек всегда все).
-- «В начало»: новый круг и новая поездка (статистика заново). Старт — следующая точка круга, если
-- вы уже по нему шли, иначе ближайшая к вам; скрытые пропускаются.
-- «Продолжить»: метку TomTom убрали (или /reload) — та же точка, тот же номер, та же поездка.
-- Метку убрали руками — ведение на паузе. Маршрут сменили или TomTom выключили — ведение снято.
local ARRIVE = 30
local follow -- { zone, base, name, tour, w, h, c, z, idx, start, uid, paused }
local selfClear = false -- снимаем свою же метку (не пауза)

local function HasTomTom() return TomTom and TomTom.AddZWaypoint and true or false end

-- ваше место в зоне маршрута (ярды) или nil, если вы не в ней
local function Me(gm, zone, w, h)
	if ViewZone(gm) ~= zone then
		if WorldMapFrame:IsShown() then return end -- карту, которую вы смотрите, не трогаем
		SetMapToCurrentZone()
		if ViewZone(gm) ~= zone then return end
	end
	local px, py = GetPlayerMapPosition("player")
	if px and px > 0 then return { px * w, py * h } end
end

local function Unmark(uid)
	if uid and TomTom and TomTom.RemoveWaypoint then
		selfClear = true
		pcall(TomTom.RemoveWaypoint, TomTom, uid)
		selfClear = false
	end
end

-- точка скрыта (жилу собрали, ещё не выросла)
local function Hidden(gm, zone, p)
	if not (gm.IsNodeHidden and p[5]) then return false end
	for _, coord in ipairs(p[5]) do
		if gm:IsNodeHidden(TYPE, zone, coord) then return true end
	end
	return false
end

-- с i по кругу первая нескрытая (все скрыты — сама i)
local function Visible(gm, f, i)
	local n = #f.tour
	for k = 0, n - 1 do
		local j = (i - 1 + k) % n + 1
		if not Hidden(gm, f.zone, f.tour[j]) then return j end
	end
	return i
end

local Renew -- новый круг по окончании прежнего (ниже)
local lastPassed -- последняя пройденная точка { p, zone, w, h, found } (Passed, ниже)

-- noProgress — старт круга: шаг от прежней точки не считать продвижением
local function Point(i, noProgress)
	local f = follow
	local p = f.tour[i]
	local n = #f.tour
	-- продвижение по кругу (и перескок через скрытые) — в «пройдено», как номер в подписи
	local lapDone = false
	if not noProgress and f.idx then
		local d = (i - f.idx) % n
		if MapPlusOreProgress then MapPlusOreProgress(d) end
		f.steps = (f.steps or 0) + d
		lapDone = f.steps >= n -- все точки круга пройдены (или перескочены)
		-- перескоченные точки (от прежней цели до новой; долетевшую уже засчитала Passed):
		-- добыли там жилу раньше стрелки — долетели и жила на месте; подлетали к ней на этом круге (f.near) —
		-- долетели, жилы нет; не подлетали — не считаем
		for k = 0, d - 1 do
			local q = f.tour[(f.idx + k - 1) % n + 1]
			if not (lastPassed and lastPassed.p == q) then
				if f.mined and f.mined[q] then
					f.mined[q] = nil
					if MapPlusOreFound then MapPlusOreFound(true) end
				elseif f.near and f.near[q] then
					if MapPlusOrePassed then MapPlusOrePassed() end
				end
			end
		end
	end
	f.idx, f.paused = i, nil
	Unmark(f.uid)
	-- persistent = false: метки маршрута TomTom не хранит между перезагрузками
	f.uid = TomTom:AddZWaypoint(f.c, f.z, p[1] / f.w * 100, p[2] / f.h * 100,
		string.format("%s: %d/%d", f.name, (i - f.start) % n + 1 + (f.extra or 0), n + (f.extra or 0)), false)
	DB().follow = { zone = f.zone, base = f.base, idx = i, start = f.start, n = n, extra = f.extra, steps = f.steps }
	if lapDone then Renew() end
end

-- круг пройден: итог в чат и в журнал, новый круг с текущей точки — по свежему маршруту этой зоны и руды,
-- если он уже посчитан (cacheTour), и новая поездка (как «В начало»)
Renew = function()
	local f = follow
	if MapPlusOreFinish then MapPlusOreFinish() end
	local cur, tour, idx = f.tour[f.idx], f.tour, f.idx
	local prefix = f.zone .. "|" .. f.base .. "|"
	if cacheTour and cacheTour ~= f.tour and #cacheTour > 0 and cacheKey and cacheKey:sub(1, #prefix) == prefix then
		tour = cacheTour
		local bd
		for k = 1, #tour do
			local d = Dist(cur, tour[k])
			if not bd or d < bd then idx, bd = k, d end
		end
	end
	f.tour, f.idx = tour, idx
	f.start, f.extra, f.mined, f.steps, f.near = idx, 0, nil, 0, nil
	Point(idx, true)
	if MapPlusOreReset then MapPlusOreReset(f.zone, f.name, #tour) end
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r круг пройден - начат новый.")
end

-- номер материка и зоны для TomTom — по файлу карты из его же списка (TomTom:GetCZ): номера зон
-- GatherMate и игры могут не совпадать с номерами TomTom
local function ContZ(gm, zone, file)
	if file and TomTom.GetCZ then
		local c, z = TomTom:GetCZ(file)
		if c and z and z > 0 then return c, z end
	end
	for ci, zones in pairs(gm.continentData or {}) do
		for zi, name in pairs(zones) do
			if name == zone then return ci, zi end
		end
	end
end

-- ведение по показанному маршруту (без старта: start/idx задаёт вызвавший)
local function Follow(gm)
	local c, z = ContZ(gm, shown.zone, shown.file)
	if not c then return end
	local old = follow and follow.uid
	return { zone = shown.zone, base = DB().route[shown.zone], name = shown.name, tour = shown.tour,
		w = shown.w, h = shown.h, c = c, z = z, uid = old }
end

-- тот же маршрут (зона и руда); точки ведения — свои (маршрут пересчитывается после каждой жилы,
-- а ведение остаётся на круге, с которого начали)
local function SameRoute(f)
	return f and shown and f.zone == shown.zone and f.base == DB().route[shown.zone]
end

local function StartRoute()
	if not HasTomTom() then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r нужен аддон TomTom.") return end
	local gm = GM()
	if not (gm and shown and shown.pts > 0) then return end
	local idx, f = 1
	if SameRoute(follow) then
		f, idx = follow, follow.idx -- уже шли: старт — следующая точка того же круга
	else
		f = Follow(gm)
		if not f then return end
		local me = Me(gm, shown.zone, shown.w, shown.h)
		if me then
			local bd
			for i = 1, #f.tour do
				local d = Dist(me, f.tour[i])
				if not bd or d < bd then idx, bd = i, d end
			end
		end
		follow = f
	end
	idx = Visible(gm, f, idx)
	f.start, f.extra, f.mined, f.steps, f.near = idx, 0, nil, 0, nil -- новый круг: ни жил вне маршрута, ни добытых впереди, ни посещённых
	Point(idx, true)
	if MapPlusOreReset then MapPlusOreReset(shown.zone, shown.name, #f.tour) end -- новый круг — новая поездка
end

CanContinue = function()
	if SameRoute(follow) then return follow.paused or not follow.uid end
	local s = DB().follow
	return s and shown and s.zone == shown.zone and s.base == DB().route[shown.zone] and s.n == #shown.tour
end

Following = function() return SameRoute(follow) and true or false end

-- закончить: стрелку снять, ведение и место на круге забыть, поездку закрыть (итог в чат)
local function EndRoute()
	if follow then Unmark(follow.uid) end
	follow = nil
	DB().follow = nil
	if MapPlusOreFinish then MapPlusOreFinish() end
	UpdateRoute()
end

local function ContinueRoute()
	if not HasTomTom() then return end
	local gm = GM()
	if not (gm and shown and shown.pts > 0) then return end
	if not SameRoute(follow) then
		local s = DB().follow
		local f = Follow(gm)
		if not (f and s and s.zone == shown.zone and s.base == f.base and s.n == #shown.tour) then return end
		f.idx, f.start, f.extra, f.steps = s.idx, s.start, s.extra, s.steps
		follow = f
	end
	Point(Visible(gm, follow, follow.idx))
	if MapPlusOreContinue then MapPlusOreContinue(shown.zone, shown.name, #follow.tour) end
	UpdateRoute()
end

-- пройденная точка: в «пройдено»; была ли там жила — решит добыча рядом (MapPlusRouteMined)
local FOUND_NEAR = 45 -- ярдов: добыча так близко к последней пройденной точке — жила там была
local function Passed(f, p)
	lastPassed = { p = p, zone = f.zone, w = f.w, h = f.h, found = false }
	if MapPlusOrePassed then MapPlusOrePassed() end
	-- жилу здесь уже добыли, пока стрелка вела к другой точке: жила на месте
	if f.mined and f.mined[p] then
		f.mined[p] = nil
		lastPassed.found = true
		if MapPlusOreFound then MapPlusOreFound(false) end
	end
end

-- добыли жилу (из Stats.lua): рядом с последней пройденной точкой — «жила была», true один раз на точку
-- Ответ: "found" — у последней пройденной точки; "extra" — жила вне маршрута (дальше FOUND_NEAR от всех
-- точек круга): ещё одна точка круга (167/168), пройдена и с жилой; nil — не засчитывать
function MapPlusRouteMined()
	local f, gm = follow, GM()
	if not (f and gm) then return nil end
	local me = Me(gm, f.zone, f.w, f.h)
	if not me then return nil end
	local lp = lastPassed
	if lp and lp.zone == f.zone and Dist(me, lp.p) <= FOUND_NEAR then
		if lp.found then return nil end
		lp.found = true
		return "found"
	end
	-- у другой точки круга: впереди (до половины круга от стрелки) — запомнить, засчитается, когда стрелка
	-- до неё дойдёт или перескочит; позади — уже пройдена, не считаем
	local n, bi, bd = #f.tour, nil, nil
	for i, p in ipairs(f.tour) do
		local d = Dist(me, p)
		if d <= FOUND_NEAR and (not bd or d < bd) then bi, bd = i, d end
	end
	if bi then
		if (bi - f.idx) % n <= n / 2 then
			f.mined = f.mined or {}
			f.mined[f.tour[bi]] = true
		end
		return nil
	end
	f.extra = (f.extra or 0) + 1
	if f.uid and not f.paused then Point(f.idx, true) end -- подпись метки: новое число точек
	return "extra"
end

-- метку убрали не мы: долетели (TomTom сам снимает у точки) — дальше, иначе пауза
if TomTom and TomTom.ClearWaypoint then
	hooksecurefunc(TomTom, "ClearWaypoint", function(_, uid)
		local f = follow
		if selfClear or not f or uid ~= f.uid then return end
		f.uid = nil
		local gm = GM()
		local me = gm and Me(gm, f.zone, f.w, f.h)
		if me and Dist(me, f.tour[f.idx]) <= ARRIVE * 2 then
			Passed(f, f.tour[f.idx])
			Point(Visible(gm, f, f.idx % #f.tour + 1))
		else
			f.paused = true
			if WorldMapFrame:IsShown() then UpdateRoute() end
		end
	end)
end

local tick = CreateFrame("Frame")
local acc = 0
tick:SetScript("OnUpdate", function(_, el)
	acc = acc + el
	if acc < 0.3 or not follow then return end
	acc = 0
	local f, gm = follow, GM()
	if not HasTomTom() or not gm or DB().route[f.zone] ~= f.base then -- нет TomTom или маршрут сменили
		Unmark(f.uid)
		follow = nil
		return
	end
	if f.paused then return end
	local me = Me(gm, f.zone, f.w, f.h)
	if not me then return end
	-- точки круга, к которым вы подлетали на ARRIVE (засчитаются, если стрелка их потом перескочит)
	for _, p in ipairs(f.tour) do
		if Dist(me, p) <= ARRIVE then
			f.near = f.near or {}
			f.near[p] = true
		end
	end
	if Dist(me, f.tour[f.idx]) <= ARRIVE then
		Passed(f, f.tour[f.idx])
		Point(Visible(gm, f, f.idx % #f.tour + 1))
	end
	-- до следующих точек не перескакиваем: стрелка ждёт текущую; жилу, добытую у точки впереди, засчитает
	-- Passed/Point, когда очередь дойдёт до неё (f.mined)
end)

-- кнопка «Следующая точка» под стрелкой TomTom (под строкой руды): текущую пропустить, в «пройдено» не идёт
local nextBtn
local function NextPoint()
	local f, gm = follow, GM()
	if not (f and gm and not f.paused) then return end
	Point(Visible(gm, f, f.idx % #f.tour + 1))
end
local function NextBtnUpdate()
	local arrow = TomTomCrazyArrow
	if not arrow then return end
	if not nextBtn then
		nextBtn = CreateFrame("Button", "MapPlusRouteNext", arrow, "UIPanelButtonTemplate")
		nextBtn:SetWidth(130)
		nextBtn:SetHeight(20)
		nextBtn:SetPoint("TOP", arrow.tta or arrow, "BOTTOM", 0, -52) -- ниже трёх строк руды
		nextBtn:SetText("Следующая точка")
		nextBtn:SetScript("OnClick", NextPoint)
	end
	if follow and not follow.paused and follow.uid then nextBtn:Show() else nextBtn:Hide() end
end
local nbAcc = 0
CreateFrame("Frame"):SetScript("OnUpdate", function(_, el)
	nbAcc = nbAcc + el
	if nbAcc >= 0.3 then nbAcc = 0; NextBtnUpdate() end
end)

local start = CreateFrame("Button", "MapPlusRouteStart", WorldMapFrame, "UIPanelButtonTemplate")
start:SetWidth(90)
start:SetHeight(22)
start:SetPoint("LEFT", drop, "RIGHT", -6, 2)
start:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 5)
start:SetText("В начало")
start:SetScript("OnClick", function() StartRoute(); UpdateRoute() end)
start:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("В начало")
	GameTooltip:AddLine("Новый круг с точки 1 и новая поездка (статистика заново). Если уже шли по кругу - старт со следующей точки, иначе с ближайшей к вам; собранные жилы пропускаются.", 1, 1, 1, true)
	GameTooltip:Show()
end)
start:SetScript("OnLeave", function() GameTooltip:Hide() end)
start:Hide()
startBtn = start

local stop = CreateFrame("Button", "MapPlusRouteEnd", WorldMapFrame, "UIPanelButtonTemplate")
stop:SetWidth(90)
stop:SetHeight(22)
stop:SetPoint("LEFT", start, "RIGHT", 2, 0)
stop:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 5)
stop:SetText("Закончить")
stop:SetScript("OnClick", EndRoute)
stop:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Закончить")
	GameTooltip:AddLine("Снять стрелку и закончить поездку: итог в чат. Если пройдено меньше 5% точек - в журнал не пишется.", 1, 1, 1, true)
	GameTooltip:Show()
end)
stop:SetScript("OnLeave", function() GameTooltip:Hide() end)
stop:Hide()
endBtn = stop

local cont = CreateFrame("Button", "MapPlusRouteContinue", WorldMapFrame, "UIPanelButtonTemplate")
cont:SetWidth(100)
cont:SetHeight(22)
cont:SetPoint("LEFT", MapPlusRouteEnd, "RIGHT", 2, 0)
cont:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 5)
cont:SetText("Продолжить")
cont:SetScript("OnClick", ContinueRoute)
cont:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Продолжить")
	GameTooltip:AddLine("Вернуть стрелку на ту же точку круга, нумерация и поездка - прежние.", 1, 1, 1, true)
	GameTooltip:Show()
end)
cont:SetScript("OnLeave", function() GameTooltip:Hide() end)
cont:Hide()
contBtn = cont

hooksecurefunc("WorldMapFrame_Update", function()
	SetText()
	UpdateRoute()
end)
WorldMapDetailFrame:HookScript("OnSizeChanged", UpdateRoute)

-- ваша наибольшая скорость в полёте (без рывков: только если держится 2 замера подряд)
local spd = CreateFrame("Frame")
local sAcc, sLast = 0, 0
spd:SetScript("OnUpdate", function(_, el)
	sAcc = sAcc + el
	if sAcc < 1 then return end
	sAcc = 0
	if not (IsFlying and GetUnitSpeed and IsFlying()) then sLast = 0 return end
	local s = GetUnitSpeed("player") or 0
	local v = math.min(s, sLast)
	sLast = s
	if v > RUN * 1.5 and v > (DB().fly or 0) + 0.5 then
		DB().fly = v
		if WorldMapFrame:IsShown() then UpdateRoute() end
	end
end)

-- учёт находок: после загрузки GatherMate подцепляемся к добавлению жилы
local rec = CreateFrame("Frame")
rec:RegisterEvent("PLAYER_LOGIN")
rec:SetScript("OnEvent", function()
	local gm = GM()
	if gm and gm.AddNode then
		hooksecurefunc(gm, "AddNode", function(self, zone, x, y, nodeType) Record(self, zone, x, y, nodeType) end)
	end
end)
