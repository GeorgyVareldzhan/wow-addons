-- MapPlus: сколько руды в час — строка под стрелкой TomTom — и журнал поездок (MapPlusDB.trips).
-- Руда — предметы со словом «руда» из добычи сразу после «Горного дела». Время идёт только пока
-- вы летите (IsFlying и скорость > 0): пешком, верхом по земле и стоя — отсчёт стоит.
-- Поездка: с «В начало» или /mapplus ore (иначе — с первой жилы после входа) до следующей
-- такой же команды или выхода. В ней: зона и руда маршрута, начало и конец (время), время в
-- движении, жил, руды, все предметы из жил. Хранятся последние KEEP; выгрузка — make -C MapPlus/Tools trips.
-- Поездка по маршруту — один круг. Сессия (MapPlusDB.session, по окончании — в MapPlusDB.sessions): все круги
-- от «В начало» до «Закончить» (или до следующего «В начало»): круги, жил, руды, предметы, выручка.

local WINDOW = 5    -- секунд после добычи, когда окно добычи считается её
local MIN_TIME = 60 -- раньше в час не пересчитываем (мало данных)
local KEEP = 100    -- поездок в журнале
local MIN_SHARE = 0.25 -- поездку по маршруту, где пройдено меньше этой доли точек, не храним

local miningSpell = (GetSpellInfo(2575))
local minedAt, counted = 0, true
local trip -- текущая поездка (запись в MapPlusDB.trips) или nil

local function Trips()
	MapPlusDB = MapPlusDB or {}
	MapPlusDB.trips = MapPlusDB.trips or {}
	return MapPlusDB.trips
end

-- не хранить: по маршруту продвинулись меньше чем на MIN_SHARE точек круга; без маршрута — ни одной жилы
local function Worthless(t)
	if t.pts and t.pts > 0 then return (t.prog or t.passed or 0) < t.pts * MIN_SHARE end
	return t.veins == 0
end

local Value, Gold -- ниже

-- сессия: итоги кругов; круг добавляется в неё, когда закрыт (t.added — уже добавлен)
local function AddToSession(t)
	local ss = MapPlusDB and MapPlusDB.session
	if not (t and ss and t.session == ss.start) or t.added then return end
	t.added = true
	ss.laps = ss.laps + 1
	ss.veins, ss.ore, ss.moving = ss.veins + t.veins, ss.ore + t.ore, ss.moving + (t.moving or 0)
	for n, c in pairs(t.items) do ss.items[n] = (ss.items[n] or 0) + c end
	ss.finish = t.finish
end

local function NewSession(zone, route)
	Trips()
	MapPlusDB.session = { start = time(), finish = time(), zone = zone, route = route, laps = 0, veins = 0, ore = 0,
		moving = 0, items = {} }
end

local function CloseSession()
	local ss = MapPlusDB and MapPlusDB.session
	if not ss then return end
	MapPlusDB.session = nil
	if ss.veins == 0 then return end
	ss.value = Value(ss.items)
	MapPlusDB.sessions = MapPlusDB.sessions or {}
	local list = MapPlusDB.sessions
	list[#list + 1] = ss
	while #list > KEEP do table.remove(list, 1) end
	local mv = ss.moving
	DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff66ccffMapPlus:|r |cffffd100сессия|r %s: кругов %d, за %d мин (в полёте %d), жил %d, руды %d%s.",
		ss.route or ss.zone or "?", ss.laps, math.floor((ss.finish - ss.start) / 60 + 0.5), math.floor(mv / 60 + 0.5),
		ss.veins, ss.ore, ss.value and (", выручка " .. Gold(ss.value) .. (mv >= MIN_TIME and (" (в час " .. Gold(ss.value * 3600 / mv) .. ")") or "")) or ""))
end

local function DropIfWorthless(t)
	if not (t and Worthless(t)) then return end
	local list = Trips()
	for i = #list, 1, -1 do if list[i] == t then table.remove(list, i) break end end
end

-- круг сессии, оставшийся в журнале после /reload и не продолженный: в сессию, короткий — из журнала
local function Adopt()
	local ss, list = MapPlusDB and MapPlusDB.session, MapPlusDB and MapPlusDB.trips
	local last = list and list[#list]
	if ss and last and last.session == ss.start and not last.added then
		AddToSession(last)
		DropIfWorthless(last)
	end
end

-- pts — точек в круге маршрута (nil — поездка без маршрута)
local function NewTrip(zone, route, pts)
	local list = Trips()
	DropIfWorthless(trip)
	local now = time()
	trip = { zone = zone or GetRealZoneText(), route = route, start = now, finish = now,
		moving = 0, veins = 0, ore = 0, items = {}, pts = pts, passed = 0, prog = 0,
		session = route and MapPlusDB.session and MapPlusDB.session.start or nil }
	list[#list + 1] = trip
	while #list > KEEP do table.remove(list, 1) end
end

-- сколько ещё жил по плану CraftPlan (руда, которой больше всего в поездке; руды с жилы — по поездке) и сколько
-- на это полёта в этом темпе
local function PlanLine(mv)
	if not (CraftPlan and CraftPlan.ShortByName) then return nil end
	-- руда: которой больше всего в этой поездке; пока её нет — та, что была в прошлый раз (MapPlusDB.planOre)
	local name, best = nil, 0
	for n, c in pairs(trip.items) do
		if (n:find("руда", 1, true) or n:find("Руда", 1, true)) and c > best then name, best = n, c end
	end
	if name then MapPlusDB.planOre = name else name = MapPlusDB.planOre end
	if not name then return nil end
	local ok, short = pcall(CraftPlan.ShortByName, name)
	if not ok then return nil end
	-- руды в плане нет: слитков хватает или стеки с ней выключены — так и пишем, а не прячем строку
	if not short then return "По плану " .. name .. " не нужна" end
	if short <= 0 then return "По плану руды хватает" end
	-- в жилах (руды с жилы — по поездке); пока жил нет — в руде; время — после MIN_TIME полёта
	if trip.veins <= 0 or best <= 0 then return string.format("По плану ещё %d руды", short) end
	local veins = math.ceil(short / (best / trip.veins))
	if mv < MIN_TIME then return string.format("По плану ещё %d жил", veins) end
	local sec = veins / (trip.veins / mv)
	return string.format("По плану ещё %d жил: около %d:%02d полёта", veins, math.floor(sec / 3600), math.floor(sec / 60) % 60)
end

-- стоимость добытого по ценам аукциона (Auctionator), как продаём: саронит — слитками (2 руды = слиток),
-- кристаллизованное — вечным (10 = 1); остальное — как есть. Без цены — не считается
local CONV = {
	[36912] = { 36913, 0.5 }, -- саронитовая руда → слиток
	[37700] = { 35623, 0.1 }, [37701] = { 35624, 0.1 }, [37702] = { 36860, 0.1 }, -- воздух, земля, огонь
	[37703] = { 35627, 0.1 }, [37704] = { 35625, 0.1 }, [37705] = { 35622, 0.1 }, -- тьма, жизнь, вода
}
local ids = {}
local function ItemID(name)
	if ids[name] == nil then
		local _, link = GetItemInfo(name)
		local id = link and tonumber(link:match("item:(%d+)"))
		if not id then return nil end
		ids[name] = id
	end
	return ids[name]
end
local function Price(id)
	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	if not (api and api.GetAuctionPriceByItemID) then return nil end
	local ok, v = pcall(api.GetAuctionPriceByItemID, "MapPlus", id)
	return ok and v or nil
end
-- медь, nil — ни одной цены
Value = function(items)
	local sum, any = 0, false
	for name, c in pairs(items or {}) do
		local id = ItemID(name)
		if id then
			local cv = CONV[id]
			local pr = Price(cv and cv[1] or id)
			if pr then sum, any = sum + c * (cv and cv[2] or 1) * pr, true end
		end
	end
	return any and sum or nil
end
Gold = function(copper) return string.format("%dз", math.floor(copper / 10000 + 0.5)) end

local text
local function Show()
	if not text then
		local arrow = TomTomCrazyArrow
		if not arrow then return end
		text = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		text:SetPoint("TOP", arrow.tta or arrow, "BOTTOM", 0, -2)
	end
	if not trip or (trip.ore == 0 and trip.moving < 1) then text:SetText("") return end
	local mv = trip.moving
	local s = string.format("Руда: %d за %d:%02d", trip.ore, math.floor(mv / 60), math.floor(mv % 60))
	if mv >= MIN_TIME then s = s .. string.format(", в час: %d", math.floor(trip.ore * 3600 / mv + 0.5)) end
	local v = Value(trip.items)
	if v then
		s = s .. "\nВыручка: " .. Gold(v)
		if mv >= MIN_TIME then s = s .. ", в час: " .. Gold(v * 3600 / mv) end
	end
	if trip.pts and trip.pts > 0 then
		s = s .. string.format(", пройдено %d%%", math.floor((trip.prog or 0) * 100 / trip.pts))
		local ps = trip.passed or 0
		if ps > 0 then
			s = s .. string.format("\nЖила на месте: %d из %d (%d%%)", trip.found or 0, ps, math.floor((trip.found or 0) * 100 / ps))
		end
	end
	local ss = MapPlusDB.session
	if ss and trip.session == ss.start then
		local items = {}
		for n, c in pairs(ss.items) do items[n] = c end
		if not trip.added then for n, c in pairs(trip.items) do items[n] = (items[n] or 0) + c end end
		local smv = ss.moving + (trip.added and 0 or mv)
		local sv = Value(items)
		s = s .. string.format("\nСессия: круг %d, руды %d", ss.laps + (trip.added and 0 or 1), ss.ore + (trip.added and 0 or trip.ore))
		if sv then
			s = s .. ", выручка " .. Gold(sv)
			if smv >= MIN_TIME then s = s .. ", в час " .. Gold(sv * 3600 / smv) end
		end
	end
	local plan = PlanLine(mv)
	if plan then s = s .. "\n" .. plan end
	text:SetText(s)
end

local f = CreateFrame("Frame")
local acc = 0
f:SetScript("OnUpdate", function(_, el)
	if trip and IsFlying() and GetUnitSpeed("player") > 0 then
		trip.moving = trip.moving + el
		trip.finish = time()
	end
	acc = acc + el
	if acc >= 1 then acc = 0; Show() end
end)
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("LOOT_OPENED")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function(_, ev, unit, spell)
	if ev == "PLAYER_LOGOUT" then
		-- выход и /reload: короткую поездку по маршруту в журнал не пишем; круг идущей сессии — оставляем
		-- («Продолжить» подхватит его, иначе он уйдёт в сессию при её закрытии — Adopt)
		local ss = MapPlusDB and MapPlusDB.session
		if not (trip and ss and trip.session == ss.start) then DropIfWorthless(trip) end
	elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
		if unit == "player" and spell == miningSpell then minedAt, counted = GetTime(), false end
	elseif not counted and GetTime() - minedAt <= WINDOW then
		counted = true
		if not trip then NewTrip() end
		trip.veins = trip.veins + 1
		local r = MapPlusRouteMined and MapPlusRouteMined()
		if r == "found" then
			trip.found = (trip.found or 0) + 1
		elseif r == "extra" and trip.pts then -- жила вне маршрута: ещё одна точка круга, пройдена, с жилой
			trip.pts, trip.prog = trip.pts + 1, (trip.prog or 0) + 1
			trip.passed, trip.found = (trip.passed or 0) + 1, (trip.found or 0) + 1
			trip.extra = (trip.extra or 0) + 1
		end
		for i = 1, GetNumLootItems() do
			local _, name, qty = GetLootSlotInfo(i)
			if name and name ~= "" then
				qty = qty or 1
				trip.items[name] = (trip.items[name] or 0) + qty
				if name:find("руда", 1, true) or name:find("Руда", 1, true) then trip.ore = trip.ore + qty end
			end
		end
		trip.finish = time()
		Show()
	end
end)

-- новая поездка: zone, route — зона и руда маршрута («В начало»), без них — просто заново; lap — следующий
-- круг той же сессии (иначе прежняя сессия закрывается и начинается новая)
function MapPlusOreReset(zone, route, pts, lap)
	if not lap then
		if trip then trip.finish = time(); AddToSession(trip) else Adopt() end
		CloseSession()
		if route then NewSession(zone, route) end
	end
	NewTrip(zone, route, pts)
	Show()
end

-- продолжить поездку («Продолжить» в MapPlus): после /reload — последнюю из журнала, если она
-- по той же зоне и руде; идущую — не трогаем
function MapPlusOreContinue(zone, route, pts)
	if trip then return end
	local list = Trips()
	local last = list[#list]
	if route and not MapPlusDB.session then NewSession(zone, route) end
	if last and last.zone == zone and last.route == route and not last.added then trip = last else NewTrip(zone, route, pts) end
	if route then trip.session = MapPlusDB.session.start end
	Show()
end

-- маршрут дошёл до очередной точки
-- стрелка ушла вперёд по кругу на d точек (долетели, перескок через скрытые, «Следующая точка»)
function MapPlusOreProgress(d)
	if trip and trip.pts and d and d > 0 then trip.prog = (trip.prog or 0) + d end
end

function MapPlusOrePassed()
	if trip and trip.pts then trip.passed = (trip.passed or 0) + 1 end
end

-- жила на месте у точки, добытая раньше, чем стрелка до неё дошла; passedToo — точку перескочили (не долетали)
function MapPlusOreFound(passedToo)
	if not (trip and trip.pts) then return end
	trip.found = (trip.found or 0) + 1
	if passedToo then trip.passed = (trip.passed or 0) + 1 end
end

-- конец маршрута («Закончить»): поездка закрыта, кратко в чат; короткая (Worthless) — не хранится
local function HMS(sec)
	sec = math.floor(sec or 0)
	return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

-- lap — круг пройден, сессия идёт дальше; иначе («Закончить») закрывается и сессия
function MapPlusOreFinish(lap)
	local p = function(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r " .. msg) end
	local t = trip
	if not t then
		if not lap then
			local had = MapPlusDB and MapPlusDB.session
			Adopt()
			CloseSession()
			if not had then p("поездки нет.") end
		end
		return
	end
	trip = nil
	t.finish = time()
	t.value = Value(t.items)
	AddToSession(t)
	local ph = (t.moving or 0) >= MIN_TIME and math.floor(t.ore * 3600 / t.moving + 0.5)
	local v = t.value
	local vs = v and (", выручка " .. Gold(v) .. ((t.moving or 0) >= MIN_TIME and (" (в час " .. Gold(v * 3600 / t.moving) .. ")") or "")) or ""
	p(string.format("%s%s: %s (в движении %s), %sжил %d, руды %d%s%s.",
		t.zone or "?", t.route and (", " .. t.route) or "", HMS(t.finish - t.start), HMS(t.moving),
		t.pts and string.format("точек %d из %d (%d%%), жила на месте %d из %d (%d%%), ", t.prog or t.passed or 0, t.pts,
			math.floor((t.prog or t.passed or 0) * 100 / t.pts), t.found or 0, t.passed or 0,
			(t.passed or 0) > 0 and math.floor((t.found or 0) * 100 / t.passed) or 0) or "",
		t.veins, t.ore, ph and (", в час " .. ph) or "", vs))
	if Worthless(t) then
		DropIfWorthless(t)
		p(t.pts and "в журнал не записана: пройдено меньше 25% точек." or "в журнал не записана: ни одной жилы.")
	end
	if not lap then CloseSession() end
	Show()
end
