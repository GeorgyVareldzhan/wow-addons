-- CraftPlan 2.0 — the "План по руде" tab of the stack panel (drawing only; the calculation, CP.OrePlan and the
-- stacks made from a plan are in OrePlan.lua). All ore on the left (normal — gives skill; grey — gives none;
-- red — skill too low), the plan of the selected one on the right.
local CP = CraftPlan
local W = CP.W

-- tab state (session only): the selected ore and the professions unticked in its plan
local state = { ore = nil, off = {} }
local GOLD, DIM = { 1, 0.82, 0 }, { 0.5, 0.5, 0.5 }
local LABEL, HEAD, NAME, RED = { 0.91, 0.85, 0.66 }, { 0.78, 0.72, 0.56 }, { 0.91, 0.89, 0.83 }, { 1, 0.38, 0.38 }
local SEL_BG, SEL_BORDER = { 0.23, 0.18, 0.07 }, { 0.79, 0.64, 0.15 }
local COL_MID, COL_GREEN, COL_ORANGE, COL_YELLOW, COL_LEARN = { 0.6, 0.6, 0.6 }, { 0.25, 0.75, 0.25 }, { 1, 0.5, 0.25 }, { 1, 1, 0 }, { 0.4, 0.8, 1 }
local CHECK_UP, CHECK_ON = "Interface\\Buttons\\UI-CheckBox-Up", "Interface\\Buttons\\UI-CheckBox-Check"
local TIP_STOCK = { "С галкой — в дело идёт всё из сумок, банка и хранилища, в том числе другие материалы рецептов. Без — чисто руда." }
local TIP_NEXT = { "Качать только до навыка, с которого следующая руда даёт оранжевые рецепты." }

local function Check(cv, x, y, on, label, color, action, tip)
	cv:Icon(CHECK_UP, x, y + 2, 20, { plain = true, action = action, lines = tip })
	if on then cv:Icon(CHECK_ON, x, y + 2, 20, { plain = true, action = action, lines = tip, level = 5 }) end
	local fs = cv:Text(label, x + 23, y - 2, "GameFontHighlightSmall", nil, nil, color)
	return x + 23 + fs:GetStringWidth() + 18
end
local function Abbr(p) return (p:match("^(%S+)") or p):sub(1, 10) .. "." end -- utf-8: 10 bytes = 5 Cyrillic letters
local function Pick(ore) return function() state.ore, state.off = ore, {}; CP.RefreshWindow() end end

-- "Дальше:" — which ore takes over each profession and from what skill (click opens its plan)
local function DrawNext(cv, P, X, y)
	local byOre, order, profs = {}, {}, {}
	for p in pairs(P.nextOre) do profs[#profs + 1] = p end
	table.sort(profs)
	for _, p in ipairs(profs) do
		local N = P.nextOre[p]
		if not state.off[p] then
			if not byOre[N] then byOre[N] = {}; order[#order + 1] = N end
			byOre[N][#byOre[N] + 1] = Abbr(p) .. " с " .. P.cap[p]
		end
	end
	for _, N in ipairs(order) do
		y = y - 4
		local fs = cv:Text("Дальше:", X, y - 4, "GameFontDisableSmall")
		local lx = X + fs:GetStringWidth() + 8
		local label = CP.ItemName(N) .. "  |cffffd100" .. table.concat(byOre[N], ", ") .. "|r"
		local tf = cv:Text(label, lx + 22, y - 4, "GameFontHighlightSmall")
		cv:Icon(CP.ItemIcon(N), lx, y, 18, { level = 2 })
		cv:Area(lx - 2, y + 2, 22 + tf:GetStringWidth() + 8, 22, { hl = true, level = 1, link = "item:" .. N, action = Pick(N) })
		y = y - 24
	end
	return y
end

-- all ore with a one-line summary, sorted: gives skill (most first), gives none, skill too low
local RANK_ST = { ok = 0, grey = 1, red = 2 }
local function OreList(useStock, toNext)
	local list = {}
	for i, ore in ipairs(CP.ORES) do
		local P = CP.OrePlan(ore, ore == state.ore and state.off or {}, useStock, toNext)
		local total, parts = 0, {}
		local profs = {}
		for p in pairs(P.start) do profs[#profs + 1] = p end
		table.sort(profs)
		for _, p in ipairs(profs) do
			local a, z = math.floor(P.start[p] + 1e-9), math.floor(P.rank[p] + 1e-9)
			if z > a then total = total + z - a; parts[#parts + 1] = Abbr(p) .. " " .. a .. "-" .. z end
		end
		local st = (P.steps[1] and P.used > 0) and "ok" or (P.anyUsable and "grey" or "red") -- a plan without this ore is not its plan
		list[#list + 1] = { ore = ore, i = i, P = P, total = total, st = st,
			sum = st == "ok" and table.concat(parts, ", ") or (st == "grey" and "навыка не даст" or "мало навыка") }
	end
	table.sort(list, function(a, b)
		if a.st ~= b.st then return RANK_ST[a.st] < RANK_ST[b.st] end
		if a.total ~= b.total then return a.total > b.total end
		return a.i < b.i
	end)
	return list
end

-- the left column; returns its bottom
local function DrawOres(cv, list, cur, y, LW)
	for _, x in ipairs(list) do
		local ok = x.st == "ok"
		if x.ore == cur.ore then cv:Box(8, y, LW, 36, SEL_BG, SEL_BORDER) end
		cv:Area(8, y, LW, 36, { hl = ok, level = 1, link = "item:" .. x.ore, action = ok and Pick(x.ore) or nil })
		cv:Icon(CP.ItemIcon(x.ore), 14, y - 3, 30, { gray = not ok, alpha = ok and 1 or 0.6, level = 2 })
		local nameCol = ok and NAME or (x.st == "grey" and DIM or RED)
		local fs = cv:Text(CP.ItemName(x.ore), 50, y - 4, "GameFontHighlightSmall", nil, nil, nameCol)
		cv:Text(tostring(CP.Have(x.ore)), 50 + fs:GetStringWidth() + 6, y - 4, "GameFontDisableSmall")
		cv:Text(x.sum, 50, y - 19, "GameFontHighlightSmall", LW - 46, nil, ok and GOLD or nameCol)
		y = y - 38
	end
	return y
end

-- "Руды: …" summary line of a plan
local function DrawTotals(cv, P, X, y, RW, useStock)
	local t = "Руды: " .. math.ceil(P.used - 1e-9)
	local rest = ""
	if useStock then
		t = t .. ", есть " .. P.have
		if P.mined > 0 then
			t = t .. ", добыть |cffffd100" .. math.ceil(P.mined - 1e-9) .. "|r"
			if P.veins then t, rest = t .. " (", P.veins .. " жил)" end
		end
	end
	rest = rest .. "   |cff9a9a9a" .. (P.canProspect and ("просеять " .. P.prospects .. " раз (" .. P.prospects * 5 .. "), ") or "") .. "переплавить " .. P.smelt .. "|r"
	if rest:sub(1, 1) == " " then
		cv:Text(t .. rest, X, y, "GameFontHighlight", RW)
	else
		-- "~" in this font sits above the digits: draw it apart, a bit lower
		local x = X + cv:Text(t, X, y, "GameFontHighlight"):GetStringWidth()
		x = x + cv:Text("~", x, y - 3, "GameFontHighlight"):GetStringWidth()
		cv:Text(rest, x, y, "GameFontHighlight")
	end
end

-- the plan's crafts, by profession
local function DrawSteps(cv, P, X, y, RW)
	local lastProf
	for _, s in ipairs(P.steps) do
		local c = s.c
		if c.prof ~= lastProf then
			y = y - 4
			cv:Text(c.prof, X, y, "GameFontNormal", nil, nil, HEAD)
			y = y - 18
			cv:Rect(X, y, RW, 1, 0.18, 0.15, 0.1, 1)
			y = y - 4
			lastProf = c.prof
		end
		local from = math.floor(s.from + 1e-9)
		local col = s.mid and COL_MID or (s.green and COL_GREEN or (from < c.rec.y and COL_ORANGE or COL_YELLOW))
		cv:Icon(CP.ItemIcon(c.rec.item > 0 and c.rec.item or nil), X + 4, y - 1, 20, { link = c.rec.item > 0 and ("item:" .. c.rec.item) or nil })
		local fs = cv:Text(c.rec.name, X + 30, y - 4, "GameFontHighlightSmall", nil, nil, col)
		if P.learn[c] then cv:Text("выучить", X + 30 + fs:GetStringWidth() + 8, y - 4, "GameFontHighlightSmall", nil, nil, COL_LEARN) end
		cv:Text("x" .. s.n, X + RW - 150, y - 4, "GameFontNormal", 50, "CENTER", GOLD)
		cv:Text(from .. " - " .. math.floor(s.to + 1e-9), X + RW - 96, y - 4, "GameFontHighlightSmall", 90, "CENTER", HEAD)
		y = y - 24
	end
	return y
end

-- draws the tab at y (canvas cv, content width Wd); returns the new y
function CP.DrawOrePlan(cv, y, Wd)
	local useStock = CP.orePlanStock ~= false
	local toNext = CP.orePlanNext == true
	local list = OreList(useStock, toNext)
	local cur
	for _, x in ipairs(list) do if x.ore == state.ore and x.st == "ok" then cur = x end end
	if not cur then
		cur = list[1]
		if state.ore ~= cur.ore then state.ore, state.off = cur.ore, {} end
	end
	local P = CP.OrePlan(cur.ore, state.off, useStock, toNext)
	local top = y
	-- left: all ore
	local LW = 270
	local leftY = DrawOres(cv, list, cur, y, LW)
	cv:Rect(8 + LW + 8, top, 1, top - leftY, 0.23, 0.19, 0.12, 1)
	-- right: plan of the selected ore
	local X = 8 + LW + 20
	local RW = Wd - X - 10
	y = top
	cv:Text(CP.ItemName(cur.ore), X, y - 2, "GameFontNormalLarge", nil, nil, LABEL)
	local btn = cv:Button("Создать стек из плана", 0, y + 2, nil, 22, { action = function() CP.OrePlanToStack(P) end })
	btn:ClearAllPoints()
	btn:SetPoint("TOPRIGHT", btn:GetParent(), "TOPLEFT", Wd - 10, y + 2)
	y = y - 28
	local x = Check(cv, X, y, useStock, "Используя всё из сумок", LABEL,
		function() CP.orePlanStock = not useStock; CP.RefreshWindow() end, TIP_STOCK)
	Check(cv, x, y, toNext, "До следующей руды", LABEL,
		function() CP.orePlanNext = not toNext; CP.RefreshWindow() end, TIP_NEXT)
	x = X
	y = y - 22
	for _, p in ipairs(P.profs) do
		local label = p .. " |cffffd100" .. math.floor(P.start[p] + 1e-9) .. " - " .. math.floor(P.rank[p] + 1e-9) .. "|r"
		local w = 23 + W.Measure(label, "GameFontHighlightSmall") + 18 -- wraps to the next line when it does not fit
		if x + w > Wd - 10 then x = X; y = y - 22 end
		x = Check(cv, x, y, not state.off[p], label, HEAD,
			function() state.off[p] = not state.off[p] or nil; CP.RefreshWindow() end)
	end
	y = y - 26
	if not P.steps[1] then
		cv:Text("Навыка с этой руды не получить.", X, y, "GameFontDisableSmall")
		y = DrawNext(cv, P, X, y - 20)
	else
		DrawTotals(cv, P, X, y, RW, useStock)
		y = DrawSteps(cv, P, X, y - 22, RW)
		y = DrawNext(cv, P, X, y)
		if P.left[1] then
			y = y - 6
			local fs = cv:Text("Останется:", X, y - 3, "GameFontDisableSmall")
			local items = {}
			for _, e in ipairs(P.left) do items[#items + 1] = { id = e.id, label = CP.ItemName(e.id) .. " |cffffd100" .. e.n .. "|r" } end
			y = cv:Chips(items, X + fs:GetStringWidth() + 8, y, X, Wd - 10)
			y = y - 24
		end
		-- the leftovers could go into these recipes, only other materials are missing
		for i, e in ipairs(P.blocked or {}) do
			if i > 3 then break end
			local c = e.c
			cv:Icon(CP.ItemIcon(c.rec.item > 0 and c.rec.item or nil), X + 4, y - 1, 20, { link = c.rec.item > 0 and ("item:" .. c.rec.item) or nil })
			local fs = cv:Text(c.rec.name .. " |cffffd100x" .. e.n .. "|r  |cffffff00+" .. math.floor(e.gain + 0.5) .. "|r  |cff9a9a9aне хватает:|r",
				X + 30, y - 4, "GameFontHighlightSmall", nil, nil, HEAD)
			local items = {}
			for _, m in ipairs(e.miss) do items[#items + 1] = { id = m.id, label = CP.ItemName(m.id) .. " |cffff6060" .. m.n .. "|r" } end
			y = cv:Chips(items, X + 30 + fs:GetStringWidth() + 8, y, X + 30, Wd - 10)
			y = y - 24
		end
	end
	return math.min(y, leftY) - 6
end
