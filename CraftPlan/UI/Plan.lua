-- CraftPlan 2.0 — "План": stack tiles, editing, the panel of selected stacks (skill bars,
-- "Материалы" as a tree, "Просеивание", "Схема" (UI/Schema.lua), "Собрать и купить", "Где фармить").
local CP = CraftPlan
local W = CP.W
local DB = CP.DB

local frame = CreateFrame("Frame", nil, CP.body)
frame:SetAllPoints(CP.body)
frame:Hide()

-- top of the tab (doesn't scroll): "Стеки" and the checkboxes
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4)
title:SetText("Стеки")
local mapCheck = W.Check(frame, "CraftPlanMapMarks", "Показать на карте зоны, где добыть",
	function() return DB().routeMap end,
	function(v) DB().routeMap = v; CP.UpdateMapMarks() end,
	"Метки Questie на карте: мобы, места сбора и торговцы недостающего сырья всех стеков. Снять галочку — убрать все метки.")
mapCheck:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -mapCheck.label:GetStringWidth() - 12, 0)
local rawCheck = W.Check(frame, "CraftPlanRawOnly", "На полосе только сырьё",
	function() return DB().rawOnly end,
	function(v) DB().rawOnly = v or nil; CP.Changed() end,
	"На полосе сверху вместо рецептов — недостающее сырьё стеков «есть/нужно».")
rawCheck:SetPoint("TOPRIGHT", mapCheck, "TOPLEFT", -rawCheck.label:GetStringWidth() - 24, 0)

local scroll = CreateFrame("ScrollFrame", "CraftPlanPlanScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -28)
scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 0)
local content = CreateFrame("Frame", nil, scroll)
content:SetWidth(900)
content:SetHeight(400)
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function() if frame:IsShown() and not CP.sizing then CP.RefreshWindow() end end) -- the grip redraws on release
local cv = W.Canvas(content)

-- the "Показывать рецепты" checkbox lives inside the scroll area (placed on every redraw)
local recCheck = W.Check(content, "CraftPlanShowRecipes", "Показывать рецепты",
	function() return DB().showRec ~= false end,
	function(v) DB().showRec = v; CP.RefreshWindow() end)

local GOLD, GREY = { 1, 0.82, 0 }, { 0.6, 0.55, 0.45 }
local HEAD = { 0.78, 0.72, 0.56 }
local MADE, LOW, NONE, SHORT = { 0.4, 0.8, 1 }, { 0.88, 0.75, 0.38 }, { 0.43, 0.4, 0.34 }, { 1, 0.31, 0.31 }
local OK_GREEN, REDDISH = { 0.25, 0.85, 0.25 }, { 1, 0.38, 0.38 }

-- "Показать на карте зоны, где добыть": Questie marks for every missing raw material of all stacks (quietly);
-- off — remove all marks
function CP.UpdateMapMarks()
	if not WhereToGet_ShowItem then return end
	if not DB().routeMap then
		if WhereToGet_ClearAll then WhereToGet_ClearAll() end
		return
	end
	local M = CP.MergedAll()
	for _, id in ipairs(M.ord) do
		local n = M.nodes[id]
		if n.made == 0 and n.short > 0 and not (WhereToGet_IsShown and WhereToGet_IsShown(id)) then WhereToGet_ShowItem(id, nil, true) end
	end
end
-- collapsed recipe trees in "Материалы": [stack table] = { [recipe name] = true } (session only; keyed by the
-- stack itself, so removing another stack doesn't move the marks)
CP.coll = setmetatable({}, { __mode = "k" })
local function Collapsed(st, name) local t = st and CP.coll[st]; return t and t[name] or nil end
local function SetCollapsed(st, name, v)
	if not st then return end
	local t = CP.coll[st]
	if not t then t = {}; CP.coll[st] = t end
	t[name] = v or nil
end
-- "Пересчитать" of a stack made by "План по руде": tooltip and action (stack tile icon and the table button)
local function RecalcLines(st) return { "Стек из плана по руде «" .. CP.ItemName(st.orePlan.ore) .. "»: заново по текущим сумкам и навыку." } end
local function Recalc(si) return function() CP.RecalcOreStack(si) end end
local KHEX = CP.KIND_HEX

local function KindOf(rec, rank)
	return CP.KindAt(rec.y, rec.g, rank)
end

----------------------------------------------------------------------------------------------
-- Stack tiles
local function DrawTiles(y, Wd, data)
	local g = CP.Goal()
	local _, editSi = CP.Editing()
	local GAP, MINW = 10, 200
	local cols = math.max(1, math.floor((Wd + GAP) / (MINW + GAP)))
	local TW = math.floor((Wd - (cols - 1) * GAP) / cols)
	local chip = math.floor((TW - 16 - 4 * 3) / 5)
	-- tile contents first, to get a common height
	local tiles = {}
	for num, si in ipairs(data.order) do
		local st, t = g.stacks[si], data.trees[si]
		local profs, seen = {}, {}
		for _, x in ipairs(t.ents) do
			if not seen[x.prof] then
				seen[x.prof] = true
				local L = data.lines[x.prof]
				profs[#profs + 1] = { name = x.prof, rank = L and L.rank or "?", gain = data.gain[si][x.prof] }
			end
		end
		local kinds, pieces = CP.Shortage(t)
		local raw = {}
		for _, id in ipairs(t.ord) do
			local n = t.nodes[id]
			if n.made == 0 then raw[#raw + 1] = n end
		end
		table.sort(raw, function(a, b)
			if a.short ~= b.short then return a.short > b.short end
			return a.gross > b.gross
		end)
		local nChips = (#raw > 10) and 10 or #raw
		local h = 10 + 20 + #profs * 25 + 26 + math.ceil(nChips / 5) * (chip + 3) + 8
		tiles[#tiles + 1] = { si = si, num = num, st = st, t = t, profs = profs, kinds = kinds, pieces = pieces, raw = raw, h = h,
			empty = (#t.ents == 0 and not next(st.add)) }
	end
	local TH = 120
	for _, tl in ipairs(tiles) do TH = math.max(TH, tl.h) end
	local i = 0
	local function Pos()
		local c, r = i % cols, math.floor(i / cols)
		i = i + 1
		return c * (TW + GAP), y - r * (TH + GAP)
	end
	for _, tl in ipairs(tiles) do
		local x, ty = Pos()
		local sel = CP.sel[tl.si]
		local edit = (tl.si == editSi)
		local dim = (editSi and not edit) and 0.6 or 1
		local border = edit and { 1, 0.82, 0 } or (sel and { 0.79, 0.64, 0.15 } or { 0.24, 0.2, 0.15 })
		cv:Box(x, ty, TW, TH, { sel and 0.13 or 0.09, sel and 0.11 or 0.08, 0.06, dim }, { border[1], border[2], border[3], dim }, (sel or edit) and 2 or 1)
		cv:Area(x, ty, TW, TH, { level = 1, action = function()
			if editSi then return end
			CP.sel[tl.si] = (not CP.sel[tl.si]) or nil
			CP.RefreshWindow()
		end })
		cv:Text("Стек " .. tl.num, x + 8, ty - 8, "GameFontNormal", nil, nil, GOLD):SetAlpha(dim)
		if not editSi then
			cv:Icon(W.TEX.pencil, x + TW - 26, ty - 6, 16, { level = 6, plain = true, title = "Редактировать стек", action = function() CP.BeginEdit(tl.si) end })
			local st = tl.st
			if st and st.orePlan then
				cv:Icon(W.TEX.refresh, x + TW - 48, ty - 5, 18, { level = 6, plain = true, title = "Пересчитать",
					lines = RecalcLines(st), action = Recalc(tl.si) })
			end
		end
		local yy = ty - 28
		for _, p in ipairs(tl.profs) do
			-- one sum, colored by its least reliable part: green / yellow (expected) or orange (exact)
			local rg = CP.RoundGain(p.gain)
			local col = rg.g > 0 and "|cff40c040" or (rg.y > 0 and "|cffffff00" or "|cffff8040")
			local txt = p.name .. "  |cff9a8a66" .. p.rank .. "|r" .. (rg.t > 0 and ("  " .. col .. "+" .. rg.t .. "|r") or "")
			cv:Icon(CP.PROF_ICON[p.name], x + 8, yy + 3, 22, { alpha = dim, level = 3 })
			cv:Text(txt, x + 36, yy - 2, "GameFontHighlight", TW - 44):SetAlpha(dim)
			yy = yy - 25
		end
		local kind, text, col
		if tl.empty then kind, text, col = "info", "Пусто", { 0.43, 0.65, 1 }
		elseif tl.kinds > 0 then kind, text, col = "alert", "Не хватает: " .. tl.kinds .. " мат. (" .. tl.pieces .. " шт.)", { 1, 0.38, 0.31 }
		else kind, text, col = "ok", "Всё собрано", { 0.25, 0.85, 0.25 } end
		cv:Status(kind, x + 8, yy + 3, 22):SetAlpha(dim)
		cv:Text(text, x + 36, yy - 2, "GameFontHighlight", TW - 44, nil, col):SetAlpha(dim)
		yy = yy - 26
		local shown = (#tl.raw > 10) and 9 or #tl.raw
		for k = 1, shown do
			local n = tl.raw[k]
			local cx = x + 8 + ((k - 1) % 5) * (chip + 3)
			local cy = yy - math.floor((k - 1) / 5) * (chip + 3)
			cv:Icon(CP.ItemIcon(n.id), cx, cy, chip, { alpha = dim, count = (n.short > 0) and n.short or n.gross,
				countColor = (n.short > 0) and REDDISH or nil, link = "item:" .. n.id,
				lines = { n.short > 0 and ("Не хватает " .. n.short .. " из " .. n.gross) or ("Нужно " .. n.gross) } })
		end
		if #tl.raw > 10 then
			local cx = x + 8 + 4 * (chip + 3)
			local cy = yy - (chip + 3)
			cv:Rect(cx, cy, chip, chip, 0.18, 0.15, 0.1, dim)
			cv:Text("+" .. (#tl.raw - 9), cx, cy - chip / 2 + 6, "GameFontHighlightSmall", chip, "CENTER", GREY)
		end
	end
	-- "+ Создать стек"
	local x, ty = Pos()
	local dim = editSi and 0.6 or 1
	cv:Box(x, ty, TW, TH, { 0.09, 0.08, 0.06, dim }, { 0.42, 0.35, 0.23, dim })
	cv:Text("+", x, ty - TH / 2 + 30, "GameFontNormalHuge", TW, "CENTER", GOLD):SetAlpha(dim)
	cv:Text("Создать стек", x, ty - TH / 2 - 4, "GameFontNormal", TW, "CENTER", GOLD):SetAlpha(dim)
	cv:Area(x, ty, TW, TH, { level = 1, hl = not editSi, action = function() if not editSi then CP.NewStack(); if CP.ToggleRecipes then CP.ToggleRecipes(true) end end end })
	local rows = math.ceil(i / cols)
	return y - rows * (TH + GAP) - 4
end

----------------------------------------------------------------------------------------------
-- Materials table
local function Columns(Wd)
	-- centers of the numeric columns from the right edge: Need, Have, Craft, Missing, "+"
	local R = Wd - 30
	return { need = R - 300, have = R - 230, make = R - 150, short = R - 60, plus = Wd - 22 }
end

local function DrawTable(y, Wd, M, data, list)
	local editSt = CP.Editing()
	local showRec = (DB().showRec ~= false) or editSt ~= nil
	local C = Columns(Wd)
	local nodes = M.nodes
	local function shared(n)
		local c = 0
		for _ in pairs(n.parents) do c = c + 1 end
		return c > 1
	end
	-- header
	if not editSt then
		recCheck:ClearAllPoints()
		recCheck:SetPoint("TOPLEFT", content, "TOPLEFT", 10, y)
		recCheck:SetChecked(DB().showRec ~= false)
		recCheck:Show()
		-- one stack made by "План по руде" is selected — rebuild it from the current bags and skill
		local st = #list == 1 and CP.Goal().stacks[list[1]]
		if st and st.orePlan then
			cv:Button("Пересчитать", Wd - 130, y, 120, 22, { title = "Пересчитать", lines = RecalcLines(st), action = Recalc(list[1]) })
		end
		y = y - 26
	else
		recCheck:Hide()
	end
	cv:Text(showRec and "Рецепты" or "Материал", 10, y, "GameFontNormal", nil, nil, HEAD)
	for _, c in ipairs({ { "need", "Нужно" }, { "have", "Есть" }, { "make", "Создать" }, { "short", "Не хватает" } }) do
		cv:Text(c[2], C[c[1]] - 45, y - 2, "GameFontDisableSmall", 90, "CENTER")
	end
	y = y - 18
	cv:Rect(10, y, Wd - 20, 1, 0.18, 0.15, 0.1, 1)
	y = y - 4
	local rowY = {} -- the item is already shown as a row (for "Разное")
	local function Num(v, cx, yy, color)
		cv:Text(tostring(v), cx - 45, yy, "GameFontHighlight", 90, "CENTER", color)
	end
	local function Branch(depth, yy, h)
		if depth <= 0 then return end
		local bx = 10 + (depth - 1) * 22 + 10
		cv:Rect(bx, yy + 6, 1, h / 2 + 4, 0.35, 0.29, 0.16, 1)
		cv:Rect(bx, yy - h / 2 + 2, 10, 1, 0.35, 0.29, 0.16, 1)
	end
	-- material row: need / have (low — have is short of need) / craft / missing; lines[1] is filled here,
	-- prod (who makes it) adds a line
	local function Row(id, depth, need, have, low, make, short, lines, prod)
		local h = 28
		local x0 = 10 + depth * 22
		Branch(depth, y, h)
		lines[1] = "Нужно " .. need .. ", есть " .. have .. (make > 0 and (", создать " .. make) or "") .. (short > 0 and (", не хватает " .. short) or "")
		if prod then lines[#lines + 1] = "Создаётся: " .. prod.rec.name .. " (" .. prod.prof .. ")" .. (prod.why and (" — " .. prod.why) or "") end
		cv:Area(4, y + 2, Wd - 8, h, { hl = true, level = 1, where = id })
		cv:Icon(CP.ItemIcon(id), x0, y - 2, 22, { link = "item:" .. id, lines = lines, where = id })
		cv:Text(CP.ItemName(id), x0 + 28, y - 7, "GameFontHighlight", math.max(60, C.need - 50 - x0 - 28), nil, make > 0 and MADE or nil)
		Num(need, C.need, y - 7)
		Num(have, C.have, y - 7, low and LOW or nil)
		Num(make > 0 and make or "-", C.make, y - 7, make > 0 and MADE or NONE)
		if short > 0 then Num(short, C.short, y - 7, SHORT) elseif make == 0 then cv:Status("ok", C.short - 8, y - 6, 16) end
		if editSt then
			cv:PlusMinus("Plus", C.plus - 8, y - 6, function() CP.AddMat(id, W.Step()) end, "Добавить в стек на правке (Shift — 10).")
			if editSt.add[id] then cv:PlusMinus("Minus", C.plus - 26, y - 6, function() CP.AddMat(id, -W.Step()) end, "Убрать (Shift — 10).") end
		end
		rowY[id] = y
		y = y - h
	end
	-- material row with the totals of all branches
	local function FullRow(id, depth)
		local n = nodes[id]
		Row(id, depth, n.gross, n.have, n.have < n.gross, n.made, n.short, {}, n.prod)
	end
	local function Head(text)
		y = y - 6
		cv:Text(text, 10, y, "GameFontNormal", nil, nil, HEAD)
		y = y - 20
	end
	-- Replays the stack calculation (Calc.lua, BuildStack) by the same rules and in the same order, but each
	-- recipe gets its own tree: stock is handed out in row order. Stacks outside the selection are counted silently
	-- (they reserve their share); rows are drawn only for the selected ones.
	local stock, alloc, sharedLines = {}, {}, {}
	local function Need(id, amt, depth, busy, owner, draw)
		if stock[id] == nil then stock[id] = CP.Have(id) end
		local h0 = math.min(stock[id], amt)
		stock[id] = stock[id] - h0
		local left = amt - h0
		local pr = CP.Producer(id)
		local make, short, times = 0, 0, 0
		if left > 0 and pr and depth < 6 and not busy[id] then
			local made = pr.rec.made or 1
			times = math.ceil(left / made)
			make = times * made
		else
			short = left
		end
		if draw then
			-- material row in a recipe branch: its own share (need / taken from stock / craft / missing)
			local lines = {}
			local n = nodes[id]
			local isShared = n and shared(n)
			local shown = isShared and h0 or CP.Have(id) -- shared: how much this branch got, otherwise — how many we have
			Row(id, depth, amt, shown, h0 < amt, make, short, lines, make > 0 and pr or nil)
			if isShared then
				alloc[id] = alloc[id] or {}
				alloc[id][#alloc[id] + 1] = owner .. " — " .. h0
				sharedLines[#sharedLines + 1] = { id = id, lines = lines }
			end
		end
		if make > 0 then
			busy[id] = true
			for _, rg in ipairs(pr.rec.reag) do Need(rg.id, rg.count * times, depth + 1, busy, CP.ItemName(id), draw) end
			busy[id] = nil
			stock[id] = stock[id] + make - left -- surplus from "several per craft"
		end
	end
	local chosen = {}
	for _, si in ipairs(list or {}) do chosen[si] = true end
	if showRec then
		local g = CP.Goal()
		local function Rec(x, st)
			local h = 32
			-- collapse/expand the recipe's tree (session only; the calculation is the same, only rows are hidden)
			local name = x.rec.name
			local closed = Collapsed(st, name)
			cv:PlusMinus(closed and "Plus" or "Minus", 8, y - 7, function() SetCollapsed(st, name, not closed); CP.RefreshWindow() end,
				closed and "Показать материалы рецепта." or "Свернуть материалы рецепта.")
			local isEdit = editSt and x.e and (function() for _, e in ipairs(editSt.list) do if e == x.e then return true end end end)()
			local L = data.lines[x.prof]
			local kind = L and KindOf(x.rec, L.rank) or "trivial"
			local known = CP.KnownRecipe(x.prof, x.rec.name)
			local pick = function() if known then CP.SelectRecipe(x.prof, x.rec.name, x.e.n) end end
			cv:Area(4, y + 2, Wd - 8, h, { hl = true, level = 1, action = pick })
			cv:Icon(CP.ItemIcon(x.rec.item > 0 and x.rec.item or nil), 28, y - 2, 26, { alpha = known and 1 or 0.6, link = x.rec.item > 0 and ("item:" .. x.rec.item) or nil,
				title = x.rec.name, lines = { x.prof .. ": создать " .. x.e.n .. " раз", known and "Изучен. Щелчок — выбрать в окне профессии." or "Не изучен." }, action = pick })
			-- never reached the learn skill in this plan: "учится с N" in red; otherwise skill range and gain of this recipe
			local early = CP.early[x.e]
			local sp = data.span and data.span[x.e]
			local extra = ""
			if early then extra = "  |cffff6060учится с " .. early .. "|r"
			elseif sp then
				local up = function(v) return math.ceil(v - 1e-9) end
				extra = "  |cffc8b98f" .. up(sp.from) .. " - " .. up(sp.to) .. "|r  " .. CP.GainString(data.egain and data.egain[x.e])
			end
			-- not learned and not at the trainer: say so (the trainer price is shown in "Все рецепты")
			local li = not known and CP.LearnInfo(x.rec.sk, x.prof, x.rec.name)
			if li and not li.at then extra = extra .. "  |cffff8060не у учителя|r" end
			cv:Text(KHEX[kind] .. x.rec.name .. "|r" .. extra, 60, y - 8, "GameFontNormal", math.max(60, C.need - 110))
			if isEdit then
				local e = x.e
				-- the number changes at once, the recalc runs after a pause in clicks
				local num = cv:Text(tostring(e.n), C.make - 12, y - 8, "GameFontNormal", 24, "CENTER", GOLD)
				local function bump(d) local n = CP.Bump(e.sk, e.name, d); if n then num:SetText(tostring(n)) end end
				cv:PlusMinus("Minus", C.make - 30, y - 7, function() bump(-W.Step()) end, "Меньше (Shift — 10).")
				cv:PlusMinus("Plus", C.make + 14, y - 7, function() bump(W.Step()) end, "Больше (Shift — 10).")
				cv:Icon(W.TEX.clear, C.make + 34, y - 8, 14, { level = 5, plain = true, title = "Убрать из стека", action = function() CP.RemoveFromEdit(e.sk, e.name) end })
			else
				Num(x.e.n .. " раз", C.make, y - 8)
			end
			y = y - h
		end
		for _, si in ipairs(data.order) do
			local draw = chosen[si]
			local st = g.stacks[si]
			for _, x in ipairs(data.trees[si].ents) do
				if draw then Rec(x, st) end
				local branch = draw and not Collapsed(st, x.rec.name)
				-- the same material in a recipe — a single row
				local sum, ord = {}, {}
				for _, rg in ipairs(x.rec.reag) do
					if not sum[rg.id] then sum[rg.id] = 0; ord[#ord + 1] = rg.id end
					sum[rg.id] = sum[rg.id] + rg.count * x.e.n
				end
				for _, id in ipairs(ord) do Need(id, sum[id], 1, {}, x.rec.name, branch) end
			end
			-- manual additions also reserve stock (as in the calculation); their rows go to "Разное"
			for id, n in pairs(st and st.add or {}) do
				if n > 0 then Need(id, n, 1, {}, "добавлено вручную", false) end
			end
		end
		-- shared material: the tooltip shows the total we have and who got how much
		for _, r in ipairs(sharedLines) do
			r.lines[#r.lines + 1] = "Всего есть " .. CP.Have(r.id) .. ": " .. table.concat(alloc[r.id], ", ") .. "."
		end
		-- "Итого": materials used in several branches — one row with the totals, then what they are made of
		local sh = {}
		for _, id in ipairs(M.ord) do if shared(nodes[id]) then sh[#sh + 1] = id end end
		if sh[1] then
			Head("Итого")
			local done = {}
			local function Sub(id, depth)
				if done[id] or not nodes[id] then return end
				done[id] = true
				FullRow(id, depth)
				for _, k in ipairs(nodes[id].kids) do Sub(k, depth + 1) end
			end
			for _, id in ipairs(sh) do Sub(id, 0) end
		end
		-- "Разное": added manually and not needed by recipes
		local misc = {}
		for _, id in ipairs(M.ord) do
			local n = nodes[id]
			local onlyAdd = true
			for k in pairs(n.parents) do if not k:find("add$") then onlyAdd = false end end
			if onlyAdd and not rowY[id] then misc[#misc + 1] = id end
		end
		if misc[1] then
			Head("Разное")
			for _, id in ipairs(misc) do FullRow(id, 0) end
		end
	else
		-- without recipes: a simple tree, a shared material as a single row (in the first branch where it appears)
		local done = {}
		local function Walk(id, depth)
			if done[id] or not nodes[id] then return end
			done[id] = true
			FullRow(id, depth)
			for _, k in ipairs(nodes[id].kids) do Walk(k, depth + 1) end
		end
		for _, x in ipairs(M.ents) do for _, rg in ipairs(x.rec.reag) do Walk(rg.id, 0) end end
		for _, id in ipairs(M.ord) do Walk(id, 0) end
	end
	if not M.ents[1] and not M.ord[1] then
		cv:Text("Стек пуст.", 10, y - 6, "GameFontDisable")
		y = y - 26
	end
	return y
end

----------------------------------------------------------------------------------------------
-- "Где фармить": zones where the missing raw materials of the selected stacks can be got
local function OpenZoneMap(z)
	if z.area and WhereToGet_OpenMapAt and WhereToGet_OpenMapAt(z.area) then return end
	-- a zone known only from GatherMate: find it among the map zones by name
	for c, zones in pairs(GatherMate and GatherMate.continentData or {}) do
		if type(zones) == "table" then
			for zi, name in pairs(zones) do
				if zi ~= 0 and name == z.zone then
					ShowUIPanel(WorldMapFrame)
					SetMapZoom(c, zi)
					return
				end
			end
		end
	end
	ShowUIPanel(WorldMapFrame)
end
local function SrcText(it)
	local t = {}
	if it.veins > 0 then t[#t + 1] = "жилы " .. it.veins end
	if it.herbs > 0 then t[#t + 1] = "травы " .. it.herbs end
	if it.objects > 0 then t[#t + 1] = "места сбора " .. it.objects end
	if it.mobs > 0 then t[#t + 1] = "мобы " .. it.mobs end
	if it.vendors > 0 then t[#t + 1] = "торговцы " .. it.vendors end
	return table.concat(t, ", ")
end
local MAX_ZONES = 8
local function DrawFarm(y, Wd, M)
	local missing = {}
	for _, id in ipairs(M.ord) do
		local n = M.nodes[id]
		if n.made == 0 and n.short > 0 then missing[#missing + 1] = { id = id, short = n.short } end
	end
	if not missing[1] then
		cv:Status("ok", 14, y - 2, 16)
		cv:Text("Всё собрано.", 34, y - 3, "GameFontHighlight", nil, nil, { 0.25, 0.85, 0.25 })
		return y - 26
	end
	local zones = CP.FarmZones(missing)
	if not zones[1] then
		cv:Text("Нет данных, где добыть.", 14, y, "GameFontDisableSmall", Wd - 28)
		return y - 24
	end
	for i = 1, math.min(MAX_ZONES, #zones) do
		local z = zones[i]
		cv:Text(z.zone .. (z.here and "  |cff40ff40(вы здесь)|r" or ""), 14, y - 2, "GameFontNormal", Wd - 140, nil, GOLD)
		cv:Button("На карте", Wd - 110, y + 2, 96, 20, { action = function()
			for _, it in ipairs(z.items) do
				if WhereToGet_ShowItem and not (WhereToGet_IsShown and WhereToGet_IsShown(it.id)) then WhereToGet_ShowItem(it.id, nil, true) end
			end
			OpenZoneMap(z)
		end })
		y = y - 22
		for _, it in ipairs(z.items) do
			cv:Icon(CP.ItemIcon(it.id), 24, y + 1, 18, { link = "item:" .. it.id, lines = { "Не хватает " .. it.short .. ". Правый щелчок — где взять (все зоны)." },
				where = it.id })
			cv:Text(CP.ItemName(it.id) .. "  |cffff6060" .. it.short .. "|r  |cff9a9a9a" .. SrcText(it) .. "|r", 48, y - 1, "GameFontHighlightSmall", Wd - 70)
			y = y - 20
		end
		y = y - 8
	end
	if #zones > MAX_ZONES then
		cv:Text("и ещё зон: " .. (#zones - MAX_ZONES), 14, y, "GameFontDisableSmall")
		y = y - 18
	end
	return y
end

----------------------------------------------------------------------------------------------
-- "Просеивание": gems of jewelcrafting stacks, which ore they come from and with what chance
local JC = "Ювелирное дело"
local function JewelStacks(data, list)
	local out = {}
	for _, si in ipairs(list) do
		for _, x in ipairs(data.trees[si].ents) do
			if x.prof == JC then out[#out + 1] = si break end
		end
	end
	return out
end
local DIM = { 0.6, 0.55, 0.45 }
local ENOUGH = { 0.63, 0.63, 0.56 }
local function OreRows(id, rank)
	local ores = CP.ProspectOres(id) or {}
	table.sort(ores, function(a, b)
		local ca, cb = rank >= a.req, rank >= b.req
		if ca ~= cb then return ca end
		return a.per > b.per
	end)
	return ores
end
local function DrawProspect(y, Wd, data, list)
	local C = Columns(Wd)
	local rank = CP.JewelRank()
	local function Num(v, cx, yy, color) cv:Text(tostring(v), cx - 45, yy, "GameFontHighlightSmall", 90, "CENTER", color) end
	for _, si in ipairs(JewelStacks(data, list)) do
		local t = data.trees[si]
		cv:Text("Стек " .. CP.StackNum(si), 10, y, "GameFontNormal", nil, nil, HEAD)
		for _, c in ipairs({ { C.need, "Шанс" }, { C.have, "Даст" }, { C.make, "Есть" }, { C.short, "Нужно руды" } }) do
			cv:Text(c[2], c[1] - 45, y - 2, "GameFontDisableSmall", 90, "CENTER")
		end
		y = y - 18
		cv:Rect(10, y, Wd - 20, 1, 0.18, 0.15, 0.1, 1)
		y = y - 4
		local miss, ok = {}, {}
		for _, id in ipairs(t.ord) do
			local n = t.nodes[id]
			if n.made == 0 and CP.IsProspectGem(id) then
				if n.short > 0 then miss[#miss + 1] = n else ok[#ok + 1] = n end
			end
		end
		if not miss[1] and not ok[1] then
			cv:Text("Камней не нужно.", 14, y - 6, "GameFontDisableSmall")
			y = y - 26
		end
		for _, n in ipairs(miss) do
			local id = n.id
			cv:Icon(CP.ItemIcon(id), 14, y - 3, 22, { link = "item:" .. id })
			local fs = cv:Text(CP.ItemName(id), 42, y - 8, "GameFontHighlight")
			cv:Text((n.gross - n.short) .. "/" .. n.gross, 42 + fs:GetStringWidth() + 8, y - 8, "GameFontHighlight", nil, nil, { 1, 0.38, 0.38 })
			y = y - 28
			for _, o in ipairs(OreRows(id, rank)) do
				local ore = o.ore
				local can = rank >= o.req
				local have = CP.Have(ore)
				local lines = {}
				if not can then lines[#lines + 1] = "|cffff6060Просеивание с " .. o.req .. ", у вас " .. rank .. "|r" end
				if o.own then lines[#lines + 1] = "|cff66ccffВаш шанс: " .. CP.Pct(o.own) .. "|r (база " .. CP.Pct(o.pct) .. ")" end
				local nameFs = cv:Text(CP.ItemName(ore), 58, y - 4, "GameFontHighlightSmall", nil, nil, can and { 0.91, 0.89, 0.83 } or { 1, 0.38, 0.38 })
				local bx = 58 + nameFs:GetStringWidth() + 6 - 10
				local area
				area = cv:Area(10, y + 2, Wd - 20, 22, { hl = true, level = 5, link = "item:" .. ore, lines = lines[1] and lines or nil, prOre = ore,
					hover = function(on) if on and area then CP.ProspectHover(area, ore, bx) end end })
				cv:Icon(CP.ItemIcon(ore), 36, y, 18, { level = 2 })
				Num(CP.Pct(o.own or o.pct), C.need, y - 4, o.own and { 0.4, 0.8, 1 } or { 0.78, 0.72, 0.56 })
				if have >= 5 then
					-- "~" in this font sits above the digits: draw it apart, a bit lower
					local gives = cv:Text(tostring(math.floor(math.floor(have / 5) * o.per)), C.have - 45, y - 4, "GameFontHighlightSmall", 90, "CENTER", { 0.25, 0.85, 0.25 })
					cv:Text("~", C.have - gives:GetStringWidth() / 2 - 60, y - 7, "GameFontHighlightSmall", 58, "RIGHT", { 0.25, 0.85, 0.25 })
				else
					Num("-", C.have, y - 4, { 0.25, 0.85, 0.25 })
				end
				Num(have > 0 and have or "-", C.make, y - 4, have >= 5 and { 0.91, 0.89, 0.83 } or DIM)
				Num(math.ceil(n.short / o.per) * 5, C.short, y - 4, GOLD)
				y = y - 22
			end
			y = y - 4
		end
		-- total: for each missing gem the ore with the highest chance; gems with the same ore share it
		for _, best in ipairs(CP.ProspectPlan(miss)) do
			local have = CP.Have(best.ore)
			local names = {}
			for _, n in ipairs(best.gems) do names[#names + 1] = CP.ItemName(n.id) end
			local fs = cv:Text("Итого:", 14, y - 4, "GameFontNormalSmall", nil, nil, { 0.78, 0.72, 0.56 })
			local x = 14 + fs:GetStringWidth() + 6
			cv:Icon(CP.ItemIcon(best.ore), x, y, 18, { link = "item:" .. best.ore })
			x = x + 22
			fs = cv:Text(CP.ItemName(best.ore) .. "  |cffffd100" .. best.need .. "|r  " .. (have >= best.need and "|cff40ff40" or "|cffff6060") .. "есть " .. have .. "|r  |cff9a9a9a- " .. table.concat(names, ", ") .. "|r",
				x, y - 4, "GameFontHighlightSmall", Wd - x - 20, nil, best.can and { 0.91, 0.89, 0.83 } or { 1, 0.38, 0.38 })
			y = y - math.max(22, fs:GetStringHeight() + 8)
		end
		-- gems that are already enough: one line
		if ok[1] then
			cv:Status("ok", 14, y - 2, 14)
			local fs = cv:Text("Хватает:", 32, y - 3, "GameFontDisableSmall")
			local items = {}
			for _, n in ipairs(ok) do
				items[#items + 1] = { id = n.id, label = CP.ItemName(n.id), color = ENOUGH, lines = { (n.gross - n.short) .. "/" .. n.gross } }
			end
			y = cv:Chips(items, 32 + fs:GetStringWidth() + 8, y, 32, Wd - 10)
			y = y - 24
		end
		y = y - 10
	end
	-- gems in bags and bank that no stack needs
	local all = CP.MergedAll()
	local extra = {}
	for _, id in ipairs(CP.ProspectGemList()) do
		local n = CP.Have(id) - (all.nodes[id] and all.nodes[id].gross or 0)
		if n > 0 then extra[#extra + 1] = { id = id, n = n } end
	end
	if extra[1] then
		table.sort(extra, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.id < b.id end)
		local fs = cv:Text("Свободные камни", 10, y, "GameFontNormal", nil, nil, HEAD)
		cv:Area(10, y + 2, fs:GetStringWidth(), 16, { lines = { "Есть в сумках и банке, стекам не нужны." } })
		y = y - 18
		cv:Rect(10, y, Wd - 20, 1, 0.18, 0.15, 0.1, 1)
		y = y - 8
		local items = {}
		for _, e in ipairs(extra) do items[#items + 1] = { id = e.id, label = CP.ItemName(e.id) .. "  |cffffd100" .. e.n .. "|r" } end
		y = cv:Chips(items, 14, y, 14, Wd - 10, true)
		y = y - 34
	end
	return y
end

----------------------------------------------------------------------------------------------
-- "Собрать и купить": missing raw materials as chips, most missing first
local function DrawBuy(y, Wd, M)
	local items = {}
	for _, id in ipairs(M.ord) do
		local n = M.nodes[id]
		if n.made == 0 and n.short > 0 then items[#items + 1] = n end
	end
	table.sort(items, function(a, b) return a.short > b.short end)
	for i, n in ipairs(items) do
		items[i] = { id = n.id, label = CP.ItemName(n.id) .. "  |cffff6060" .. n.short .. "|r",
			lines = { "Не хватает " .. n.short .. ". Правый щелчок — где взять." }, where = n.id }
	end
	y = cv:Chips(items, 14, y, 14, Wd - 10, true)
	if not items[1] then cv:Status("ok", 14, y - 2, 16); cv:Text("Всё собрано.", 34, y - 3, "GameFontHighlight", nil, nil, OK_GREEN) end
	return y - 34
end

----------------------------------------------------------------------------------------------
-- Panel of the selected stacks
local function DrawPanel(y, Wd, data)
	local _, editSi = CP.Editing()
	local selIds = {}
	for _, si in ipairs(data.order) do if CP.sel[si] then selIds[#selIds + 1] = si end end
	local list = selIds[1] and selIds or data.order
	local M = CP.Merge(data.trees, list)
	local top = y
	local setH = cv:Box(4, top, Wd - 8, 100, { 0.1, 0.085, 0.06 }, { 0.35, 0.29, 0.16 }) -- height is set at the end
	-- title
	local titleText
	if #selIds == 1 then titleText = "Стек " .. CP.StackNum(selIds[1])
	elseif #selIds > 1 then
		local nums = {}
		for _, si in ipairs(selIds) do nums[#nums + 1] = CP.StackNum(si) end
		titleText = "Стеки " .. table.concat(nums, ", ")
	else titleText = "Все стеки" end
	y = y - 10
	cv:Text(titleText, 14, y, "GameFontNormalLarge", nil, nil, GOLD)
	if #selIds == 1 then
		local kinds, pieces = CP.Shortage(M)
		local tx = 14 + 110
		if kinds > 0 then
			cv:Status("alert", tx, y + 4, 28)
			cv:Text("Не хватает: " .. kinds .. " мат. (" .. pieces .. " шт.)", tx + 34, y - 2, "GameFontNormalLarge", nil, nil, { 1, 0.38, 0.31 })
		elseif M.ents[1] then
			cv:Status("ok", tx, y + 4, 28)
			cv:Text("Всё собрано", tx + 34, y - 2, "GameFontNormalLarge", nil, nil, { 0.25, 0.85, 0.25 })
		end
		if not editSi then
			local si = selIds[1]
			cv:Button("Удалить", Wd - 110, y + 2, 100, 22, { color = { 1, 0.5, 0.45 }, action = function()
				StaticPopup_Show("CRAFTPLAN_DROP_STACK", tostring(CP.StackNum(si)), nil, si)
			end })
			cv:Button("Редактировать", Wd - 236, y + 2, 120, 22, { action = function() CP.BeginEdit(si) end })
		end
	end
	y = y - 30
	-- skill bars per profession of the selected stacks
	local gsum, seen, profs = {}, {}, {}
	for _, si in ipairs(list) do
		for _, x in ipairs(data.trees[si].ents) do if not seen[x.prof] then seen[x.prof] = true; profs[#profs + 1] = x.prof end end
		for p, v in pairs(data.gain[si]) do
			local q = gsum[p]
			if not q then q = { o = 0, y = 0, g = 0 }; gsum[p] = q end
			q.o, q.y, q.g = q.o + v.o, q.y + v.y, q.g + v.g
			q.ym, q.gm = (q.ym or 0) + (v.ym or 0), (q.gm or 0) + (v.gm or 0)
			if not seen[p] then seen[p] = true; profs[#profs + 1] = p end -- e.g. mining from smelting intermediates
		end
	end
	table.sort(profs)
	-- steps of each profession in the selected stacks (one pass over the log)
	local chosen = {}
	for _, si in ipairs(list) do chosen[si] = true end
	local stepsOf = W.StepsBy(data, function(l) return chosen[l.si] and l.prof or nil end)
	local up = function(v) return math.ceil(v - 1e-9) end
	for _, p in ipairs(profs) do
		local L = data.lines[p]
		if L then
			cv:Icon(CP.PROF_ICON[p], 14, y + 4, 28, { level = 3 })
			cv:Text(p, 48, y - 3, "GameFontNormalLarge", nil, nil, { 0.91, 0.85, 0.66 })
			y = y - 28
			-- tooltip over the bar: steps of this profession in the selected stacks
			local rg = CP.RoundGain(gsum[p])
			local tl = {}
			for _, st in ipairs(stepsOf[p] or {}) do
				tl[#tl + 1] = st.rec.name .. " x" .. st.n .. ": " .. up(st.from) .. " - " .. up(st.to)
			end
			y = cv:SkillBar(14, y, Wd - 40, L.rank, L.max, gsum[p], { title = p .. ": " .. L.rank .. " - " .. math.min(L.max, L.rank + rg.t), lines = tl }) - 6
		end
	end
	-- panel tabs
	local hasJewel = JewelStacks(data, list)[1] ~= nil
	local sub = CP.sub or "mat"
	if (sub == "prospect" and not hasJewel) or (sub == "ore" and not (CP.HasOrePlanTab and CP.HasOrePlanTab())) then sub = "mat" end
	local tabs = { { "mat", "Материалы" } }
	if hasJewel then tabs[#tabs + 1] = { "prospect", "Просеивание" } end
	local hasOre = CP.HasOrePlanTab and CP.HasOrePlanTab()
	if hasOre then tabs[#tabs + 1] = { "ore", "План по руде" } end
	for _, t in ipairs({ { "graph", "Схема" }, { "buy", "Собрать и купить" }, { "farm", "Где фармить" } }) do tabs[#tabs + 1] = t end
	local bx = 14
	for _, s in ipairs(tabs) do
		local key = s[1]
		local b = cv:Button(s[2], bx, y, nil, 22, { locked = (sub == key), color = (sub == key) and GOLD or { 0.7, 0.7, 0.7 }, action = function() CP.sub = key; CP.RefreshWindow() end })
		bx = bx + b:GetWidth() + 4
	end
	y = y - 26
	cv:Rect(10, y, Wd - 20, 1, 0.23, 0.19, 0.12, 1)
	y = y - 6
	if sub == "mat" then
		y = DrawTable(y, Wd, M, data, list)
	elseif sub == "prospect" then
		recCheck:Hide()
		y = DrawProspect(y, Wd, data, list)
	elseif sub == "ore" then
		recCheck:Hide()
		y = CP.DrawOrePlan(cv, y, Wd)
	elseif sub == "graph" then
		recCheck:Hide()
		y = CP.DrawSchema(cv, y, Wd, M, data)
	else
		recCheck:Hide()
		if sub == "buy" then
			y = DrawBuy(y, Wd, M)
		else
			y = DrawFarm(y, Wd, M)
		end
	end
	setH(top - y + 8)
	return y - 12
end

StaticPopupDialogs["CRAFTPLAN_DROP_STACK"] = {
	text = "Удалить стек %s?", button1 = YES, button2 = NO, timeout = 0, whileDead = 1, hideOnEscape = 1,
	OnAccept = function(self, si) CP.RemoveStack(si or self.data); CP.Changed() end,
}

local function Refresh()
	local Wd = math.max(600, scroll:GetWidth() - 4)
	content:SetWidth(Wd)
	cv:Reset()
	local data = CP.Compute()
	local y = -4
	y = DrawTiles(y, Wd, data)
	local _, editSi = CP.Editing()
	if editSi then
		cv:Box(0, y, Wd, 34, { 0.13, 0.11, 0.07 }, { 0.79, 0.64, 0.15 })
		cv:Text("Правка: Стек " .. CP.StackNum(editSi), 10, y - 11, "GameFontNormal", Wd - 250, nil, GOLD)
		cv:Button("Сохранить", Wd - 112, y - 6, 100, 22, { action = function() CP.SaveEdit() end })
		cv:Button("Отмена", Wd - 218, y - 6, 100, 22, { color = { 1, 1, 1 }, action = function() CP.CancelEdit() end })
		y = y - 44
	end
	if data.order[1] then
		y = DrawPanel(y, Wd, data)
	else
		recCheck:Hide()
		-- no stacks: the panel has nothing to show, but "План по руде" does not depend on stacks
		if CP.HasOrePlanTab and CP.HasOrePlanTab() then
			local top = y
			local setH = cv:Box(4, top, Wd - 8, 100, { 0.1, 0.085, 0.06 }, { 0.35, 0.29, 0.16 })
			y = y - 10
			cv:Button("План по руде", 14, y, nil, 22, { locked = true, color = GOLD })
			y = y - 26
			cv:Rect(10, y, Wd - 20, 1, 0.23, 0.19, 0.12, 1)
			y = y - 6
			y = CP.DrawOrePlan(cv, y, Wd)
			setH(top - y + 8)
			y = y - 12
		end
	end
	content:SetHeight(-y + 10)
	scroll:UpdateScrollChildRect()
end

CP.tabs.plan = { frame = frame, Refresh = Refresh }
