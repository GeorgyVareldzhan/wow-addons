-- MapPlus: сколько руды в час — строка под стрелкой TomTom — и журнал поездок (MapPlusDB.trips).
-- Руда — предметы со словом «руда» из добычи сразу после «Горного дела». Время идёт только пока
-- вы летите (IsFlying и скорость > 0): пешком, верхом по земле и стоя — отсчёт стоит.
-- Поездка: с «В начало» или /mapplus ore (иначе — с первой жилы после входа) до следующей
-- такой же команды или выхода. В ней: зона и руда маршрута, начало и конец (время), время в
-- движении, жил, руды, все предметы из жил. Хранятся последние KEEP; выгрузка — make -C MapPlus/Tools trips.

local WINDOW = 5    -- секунд после добычи, когда окно добычи считается её
local MIN_TIME = 60 -- раньше в час не пересчитываем (мало данных)
local KEEP = 100    -- поездок в журнале
local MIN_SHARE = 0.05 -- поездку по маршруту, где пройдено меньше этой доли точек, не храним

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

local function DropIfWorthless(t)
	if not (t and Worthless(t)) then return end
	local list = Trips()
	for i = #list, 1, -1 do if list[i] == t then table.remove(list, i) break end end
end

-- pts — точек в круге маршрута (nil — поездка без маршрута)
local function NewTrip(zone, route, pts)
	local list = Trips()
	DropIfWorthless(trip)
	local now = time()
	trip = { zone = zone or GetRealZoneText(), route = route, start = now, finish = now,
		moving = 0, veins = 0, ore = 0, items = {}, pts = pts, passed = 0, prog = 0 }
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
	if trip.pts and trip.pts > 0 then
		s = s .. string.format(", пройдено %d%%", math.floor((trip.prog or 0) * 100 / trip.pts))
		local ps = trip.passed or 0
		if ps > 0 then
			s = s .. string.format("\nЖила на месте: %d из %d (%d%%)", trip.found or 0, ps, math.floor((trip.found or 0) * 100 / ps))
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
		DropIfWorthless(trip) -- выход и /reload: короткую поездку по маршруту в журнал не пишем
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

-- новая поездка: zone, route — зона и руда маршрута («В начало»), без них — просто заново
function MapPlusOreReset(zone, route, pts)
	NewTrip(zone, route, pts)
	Show()
end

-- продолжить поездку («Продолжить» в MapPlus): после /reload — последнюю из журнала, если она
-- по той же зоне и руде; идущую — не трогаем
function MapPlusOreContinue(zone, route, pts)
	if trip then return end
	local list = Trips()
	local last = list[#list]
	if last and last.zone == zone and last.route == route then trip = last else NewTrip(zone, route, pts) end
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

function MapPlusOreFinish()
	local p = function(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMapPlus:|r " .. msg) end
	local t = trip
	if not t then p("поездки нет.") return end
	trip = nil
	t.finish = time()
	local ph = (t.moving or 0) >= MIN_TIME and math.floor(t.ore * 3600 / t.moving + 0.5)
	p(string.format("%s%s: %s (в движении %s), %sжил %d, руды %d%s.",
		t.zone or "?", t.route and (", " .. t.route) or "", HMS(t.finish - t.start), HMS(t.moving),
		t.pts and string.format("точек %d из %d (%d%%), жила на месте %d из %d (%d%%), ", t.prog or t.passed or 0, t.pts,
			math.floor((t.prog or t.passed or 0) * 100 / t.pts), t.found or 0, t.passed or 0,
			(t.passed or 0) > 0 and math.floor((t.found or 0) * 100 / t.passed) or 0) or "",
		t.veins, t.ore, ph and (", в час " .. ph) or ""))
	if Worthless(t) then
		DropIfWorthless(t)
		p(t.pts and "в журнал не записана: пройдено меньше 5% точек." or "в журнал не записана: ни одной жилы.")
	end
	Show()
end
