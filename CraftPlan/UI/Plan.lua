-- CraftPlan 2.0 — вкладка «План»: плитки стеков, правка, панель выбранных стеков (полосы навыка,
-- «Материалы» деревом, «Собрать и купить», «Где фармить»).
local CP = CraftPlan
local W = CP.W
local DB = CP.DB

local frame = CreateFrame("Frame", nil, CP.body)
frame:SetAllPoints(CP.body)
frame:Hide()

-- верх вкладки (не прокручивается): «Стеки» и галочки
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4)
title:SetText("Стеки")
local mapCheck = W.Check(frame, "CraftPlanMapMarks", "Показать на карте зоны, где добыть",
	function() return DB().routeMap end,
	function(v) DB().routeMap = v; if CP.UpdateMapMarks then CP.UpdateMapMarks(true) end end,
	"Метки Questie в зоне, где вы сейчас: мобы, места сбора и торговцы недостающего для стеков.")
mapCheck:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -mapCheck.label:GetStringWidth() - 8, 0)
local rawCheck = W.Check(frame, "CraftPlanRawOnly", "На полосе только сырьё",
	function() return DB().rawOnly end,
	function(v) DB().rawOnly = v or nil; CP.Changed() end,
	"На полосе сверху вместо рецептов — недостающее сырьё стеков «есть/нужно».")
rawCheck:SetPoint("TOPRIGHT", mapCheck, "TOPLEFT", -rawCheck.label:GetStringWidth() - 18, 0)

local scroll = CreateFrame("ScrollFrame", "CraftPlanPlanScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -28)
scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 0)
local content = CreateFrame("Frame", nil, scroll)
content:SetWidth(900)
content:SetHeight(400)
scroll:SetScrollChild(content)
scroll:SetScript("OnSizeChanged", function() if frame:IsShown() then CP.RefreshWindow() end end)
local cv = W.Canvas(content)

-- галочка «Показывать рецепты» живёт внутри прокрутки (ставится при каждой перерисовке)
local recCheck = W.Check(content, "CraftPlanShowRecipes", "Показывать рецепты",
	function() return DB().showRec ~= false end,
	function(v) DB().showRec = v; CP.RefreshWindow() end)

local GOLD, GREY = { 1, 0.82, 0 }, { 0.6, 0.55, 0.45 }
local KHEX = CP.KIND_HEX

local function KindOf(rec, rank)
	return CP.KindAt(rec.y, rec.g, rank)
end

----------------------------------------------------------------------------------------------
-- Плитки стеков
local function DrawTiles(y, Wd, data)
	local g = CP.Goal()
	local editSt, editSi = CP.Editing()
	local GAP, MINW = 10, 200
	local cols = math.max(1, math.floor((Wd + GAP) / (MINW + GAP)))
	local TW = math.floor((Wd - (cols - 1) * GAP) / cols)
	local chip = math.floor((TW - 16 - 4 * 3) / 5)
	-- содержимое плиток, чтобы взять общую высоту
	local tiles = {}
	for num, si in ipairs(data.order) do
		local st, t = g.stacks[si], data.trees[si]
		local profs, seen = {}, {}
		for _, x in ipairs(t.ents) do
			if not seen[x.prof] then
				seen[x.prof] = true
				local L = data.lines[x.prof]
				profs[#profs + 1] = { name = x.prof, rank = L and L.rank or "?", gain = data.gain[si][x.prof] or 0 }
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
		end
		local yy = ty - 28
		for _, p in ipairs(tl.profs) do
			local txt = p.name .. "  |cff9a8a66" .. p.rank .. "|r" .. (p.gain > 0 and ("  |cffff8040+" .. p.gain .. "|r") or "")
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
				countColor = (n.short > 0) and { 1, 0.38, 0.38 } or nil, link = "item:" .. n.id,
				lines = { n.short > 0 and ("Не хватает " .. n.short .. " из " .. n.gross) or ("Нужно " .. n.gross) } })
		end
		if #tl.raw > 10 then
			local cx = x + 8 + 4 * (chip + 3)
			local cy = yy - (chip + 3)
			cv:Rect(cx, cy, chip, chip, 0.18, 0.15, 0.1, dim)
			cv:Text("+" .. (#tl.raw - 9), cx, cy - chip / 2 + 6, "GameFontHighlightSmall", chip, "CENTER", GREY)
		end
	end
	-- «+ Создать стек»
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
-- Таблица материалов
local function Columns(Wd)
	-- центры числовых колонок от правого края: Нужно, Есть, Создать, Не хватает, «+»
	local R = Wd - 30
	return { need = R - 300, have = R - 230, make = R - 150, short = R - 60, plus = Wd - 22, w = 70 }
end

local function DrawTable(y, Wd, M, data)
	local editSt = CP.Editing()
	local showRec = (DB().showRec ~= false) or editSt ~= nil
	local C = Columns(Wd)
	local nodes = M.nodes
	local function shared(n)
		local c = 0
		for _ in pairs(n.parents) do c = c + 1 end
		return c > 1
	end
	-- шапка
	if not editSt then
		recCheck:ClearAllPoints()
		recCheck:SetPoint("TOPLEFT", content, "TOPLEFT", 10, y)
		recCheck:SetChecked(DB().showRec ~= false)
		recCheck:Show()
		y = y - 26
	else
		recCheck:Hide()
	end
	cv:Text(showRec and "Рецепты" or "Материал", 10, y, "GameFontNormal", nil, nil, { 0.78, 0.72, 0.56 })
	for _, c in ipairs({ { "need", "Нужно" }, { "have", "Есть" }, { "make", "Создать" }, { "short", "Не хватает" } }) do
		cv:Text(c[2], C[c[1]] - 45, y - 2, "GameFontDisableSmall", 90, "CENTER")
	end
	y = y - 18
	cv:Rect(10, y, Wd - 20, 1, 0.18, 0.15, 0.1, 1)
	y = y - 4
	local rowY = {} -- где стоит полная строка предмета (для ссылок)
	local left = {} -- общий материал: сколько покрытого ещё не раздано ссылкам (по порядку строк)
	-- покрыто = из запаса + то, что реально можно создать (доля по самому дефицитному материалу ниже)
	local covMemo = {}
	local function Covered(id, seen)
		if covMemo[id] then return covMemo[id] end
		local n = nodes[id]
		if not n or seen[id] then return 0 end
		seen[id] = true
		local ratio = 1
		for _, k in ipairs(n.kids) do
			local kn = nodes[k]
			if kn and kn.gross > 0 then ratio = math.min(ratio, Covered(k, seen) / kn.gross) end
		end
		local v = math.max(0, math.min(n.gross, (n.gross - n.made - n.short) + math.floor(n.made * ratio)))
		covMemo[id] = v
		return v
	end
	local refs = {}
	local function Num(v, col, cx, yy, color)
		cv:Text(tostring(v), cx - 45, yy, "GameFontHighlight", 90, "CENTER", color)
	end
	local function Branch(depth, yy, h)
		if depth <= 0 then return end
		local bx = 10 + (depth - 1) * 22 + 10
		cv:Rect(bx, yy + 6, 1, h / 2 + 4, 0.35, 0.29, 0.16, 1)
		cv:Rect(bx, yy - h / 2 + 2, 10, 1, 0.35, 0.29, 0.16, 1)
	end
	local function FullRow(id, depth)
		local n = nodes[id]
		local h = 28
		local x0 = 10 + depth * 22
		Branch(depth, y, h)
		local lines = { "Нужно " .. n.gross .. ", есть " .. n.have .. (n.made > 0 and (", создать " .. n.made) or "") .. (n.short > 0 and (", не хватает " .. n.short) or "") }
		if n.prod then lines[#lines + 1] = "Создаётся: " .. n.prod.rec.name .. " (" .. n.prod.prof .. ")" end
		cv:Area(4, y + 2, Wd - 8, h, { hl = true, level = 1,
			rightAction = function() if WhereToGet_ShowItem then WhereToGet_ShowItem(id) end end })
		cv:Icon(CP.ItemIcon(id), x0, y - 2, 22, { link = "item:" .. id, lines = lines,
			rightAction = function() if WhereToGet_ShowItem then WhereToGet_ShowItem(id) end end })
		cv:Text(CP.ItemName(id), x0 + 28, y - 7, "GameFontHighlight", math.max(60, C.need - 50 - x0 - 28), nil, n.made > 0 and { 0.4, 0.8, 1 } or nil)
		Num(n.gross, "need", C.need, y - 7)
		Num(n.have, "have", C.have, y - 7, n.have < n.gross and { 0.88, 0.75, 0.38 } or nil)
		Num(n.made > 0 and n.made or "-", "make", C.make, y - 7, n.made > 0 and { 0.4, 0.8, 1 } or { 0.43, 0.4, 0.34 })
		if n.short > 0 then Num(n.short, "short", C.short, y - 7, { 1, 0.31, 0.31 }) else cv:Status("ok", C.short - 8, y - 6, 16) end
		if editSt then
			local id2 = id
			cv:PlusMinus("Plus", C.plus - 8, y - 6, function() CP.AddMat(id2, W.Step()) end, "Добавить в стек на правке (Shift — 10).")
			if editSt.add[id] then cv:PlusMinus("Minus", C.plus - 26, y - 6, function() CP.AddMat(id2, -W.Step()) end, "Убрать (Shift — 10).") end
		end
		rowY[id] = y
		y = y - h
	end
	local function RefRow(id, depth, amt)
		local h = 22
		local x0 = 10 + depth * 22
		Branch(depth, y, h)
		local b = cv:TextButton(CP.ItemName(id), x0, y - 4, 200, { color = { 0.4, 0.8, 1 }, underline = true, lines = { "Полная строка — ниже, в «Общих». Щёлкните — прокрутить." },
			action = function() if rowY[id] then scroll:SetVerticalScroll(math.max(0, -rowY[id] - 40)) end end })
		b:SetWidth(b.text:GetStringWidth() + 2)
		-- хватает ли этому рецепту: покрытое (есть + создать) раздаётся потребителям по порядку строк
		local n = nodes[id]
		if left[id] == nil then left[id] = Covered(id, {}) end
		local take = math.min(amt, left[id])
		left[id] = left[id] - take
		local lack = amt - take
		local tx = x0 + b.text:GetStringWidth() + 8
		if lack <= 0 then
			cv:Status("ok", tx, y - 2, 14)
			cv:Text(tostring(amt), tx + 16, y - 4, "GameFontHighlightSmall", nil, nil, { 0.25, 0.85, 0.25 })
		else
			cv:Text("x" .. amt .. "  |cffff5050(ещё " .. lack .. ")|r", tx, y - 4, "GameFontHighlightSmall", nil, nil, { 0.6, 0.55, 0.45 })
		end
		y = y - h
	end
	local function Head(text)
		y = y - 6
		cv:Text(text, 10, y, "GameFontNormal", nil, nil, { 0.78, 0.72, 0.56 })
		y = y - 20
	end
	local function Emit(id, depth, pk)
		local n = nodes[id]
		if not n then return end
		if shared(n) then RefRow(id, depth, n.parents[pk] or 0) return end
		FullRow(id, depth)
		for _, k in ipairs(n.kids) do Emit(k, depth + 1, "i" .. id) end
	end
	if showRec then
		for _, x in ipairs(M.ents) do
			local h = 32
			local isEdit = editSt and x.e and (function() for _, e in ipairs(editSt.list) do if e == x.e then return true end end end)()
			local L = data.lines[x.prof]
			local kind = L and KindOf(x.rec, L.rank) or "trivial"
			local known = CP.KnownRecipe(x.prof, x.rec.name)
			local pick = function() if known then CP.SelectRecipe(x.prof, x.rec.name, x.e.n) end end
			cv:Area(4, y + 2, Wd - 8, h, { hl = true, level = 1, action = pick })
			cv:Icon(CP.ItemIcon(x.rec.item > 0 and x.rec.item or nil), 10, y - 2, 26, { alpha = known and 1 or 0.6, link = x.rec.item > 0 and ("item:" .. x.rec.item) or nil,
				title = x.rec.name, lines = { x.prof .. ": создать " .. x.e.n .. " раз", known and "Изучен. Щелчок — выбрать в окне профессии." or "Не изучен." }, action = pick })
			cv:Text(KHEX[kind] .. x.rec.name .. "|r", 42, y - 8, "GameFontNormal", math.max(60, C.need - 92))
			if isEdit then
				local e = x.e
				-- число меняется сразу, пересчёт — после паузы в щелчках
				local num = cv:Text(tostring(e.n), C.make - 12, y - 8, "GameFontNormal", 24, "CENTER", GOLD)
				local function bump(d) local n = CP.Bump(e.sk, e.name, d); if n then num:SetText(tostring(n)) end end
				cv:PlusMinus("Minus", C.make - 30, y - 7, function() bump(-W.Step()) end, "Меньше (Shift — 10).")
				cv:PlusMinus("Plus", C.make + 14, y - 7, function() bump(W.Step()) end, "Больше (Shift — 10).")
				cv:Icon(W.TEX.clear, C.make + 34, y - 8, 14, { level = 5, plain = true, title = "Убрать из стека", action = function() CP.RemoveFromEdit(e.sk, e.name) end })
			else
				Num(x.e.n .. " раз", "make", C.make, y - 8)
			end
			y = y - h
			local seen = {}
			for _, rg in ipairs(x.rec.reag) do
				if not seen[rg.id] then seen[rg.id] = true; Emit(rg.id, 1, x.key) end
			end
		end
		local sh = {}
		for _, id in ipairs(M.ord) do if shared(nodes[id]) then sh[#sh + 1] = id end end
		if sh[1] then
			Head("Общие")
			for _, id in ipairs(sh) do
				FullRow(id, 0)
				for _, k in ipairs(nodes[id].kids) do Emit(k, 1, "i" .. id) end
			end
		end
		-- «Разное»: добавлено вручную и не нужно рецептам
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
		-- без рецептов: простое дерево, общий материал — одной строкой (в первой ветке, где встретился)
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
		cv:Text("Стек пуст: добавьте рецепты в «Все рецепты» или Shift+щелчком по предмету в сумке.", 10, y - 6, "GameFontDisable")
		y = y - 26
	end
	return y
end

----------------------------------------------------------------------------------------------
-- Панель выбранных стеков
local function DrawPanel(y, Wd, data)
	local g = CP.Goal()
	local editSt, editSi = CP.Editing()
	local selIds = {}
	for _, si in ipairs(data.order) do if CP.sel[si] then selIds[#selIds + 1] = si end end
	local list = selIds[1] and selIds or data.order
	local M = CP.Merge(data.trees, list)
	local top = y
	local setH = cv:Box(4, top, Wd - 8, 100, { 0.1, 0.085, 0.06 }, { 0.35, 0.29, 0.16 }) -- высота — в конце
	-- заголовок
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
	-- полосы навыка по профессиям выбранных стеков
	local gsum, seen, profs = {}, {}, {}
	for _, si in ipairs(list) do
		for _, x in ipairs(data.trees[si].ents) do if not seen[x.prof] then seen[x.prof] = true; profs[#profs + 1] = x.prof end end
		for p, v in pairs(data.gain[si]) do gsum[p] = (gsum[p] or 0) + v end
	end
	table.sort(profs)
	for _, p in ipairs(profs) do
		local L = data.lines[p]
		if L then
			cv:Icon(CP.PROF_ICON[p], 14, y + 4, 28, { level = 3 })
			cv:Text(p, 48, y - 3, "GameFontNormalLarge", nil, nil, { 0.91, 0.85, 0.66 })
			y = y - 28
			y = cv:SkillBar(14, y, Wd - 40, L.rank, L.max, gsum[p] or 0) - 6
		end
	end
	-- вкладки панели
	local sub = CP.sub or "mat"
	local bx = 14
	for _, s in ipairs({ { "mat", "Материалы" }, { "buy", "Собрать и купить" }, { "farm", "Где фармить" } }) do
		local key = s[1]
		local b = cv:Button(s[2], bx, y, nil, 22, { locked = (sub == key), color = (sub == key) and GOLD or { 0.7, 0.7, 0.7 }, action = function() CP.sub = key; CP.RefreshWindow() end })
		bx = bx + b:GetWidth() + 4
	end
	y = y - 26
	cv:Rect(10, y, Wd - 20, 1, 0.23, 0.19, 0.12, 1)
	y = y - 6
	if sub == "mat" then
		y = DrawTable(y, Wd, M, data)
	else
		recCheck:Hide()
		if sub == "buy" then
			local items = {}
			for _, id in ipairs(M.ord) do
				local n = M.nodes[id]
				if n.made == 0 and n.short > 0 then items[#items + 1] = n end
			end
			table.sort(items, function(a, b) return a.short > b.short end)
			local x = 14
			for _, n in ipairs(items) do
				local label = CP.ItemName(n.id) .. "  |cffff6060" .. n.short .. "|r"
				local fs = cv:Text(label, 0, 0, "GameFontHighlightSmall")
				local w = 26 + fs:GetStringWidth() + 14
				fs:SetText("")
				if x + w > Wd - 10 then x = 14; y = y - 28 end
				cv:Rect(x, y, w, 24, 0.16, 0.13, 0.09, 1)
				cv:Icon(CP.ItemIcon(n.id), x + 3, y - 3, 18, { link = "item:" .. n.id, lines = { "Не хватает " .. n.short .. ". Правый щелчок — где взять." },
					rightAction = function() if WhereToGet_ShowItem then WhereToGet_ShowItem(n.id) end end })
				cv:Text(label, x + 26, y - 6, "GameFontHighlightSmall")
				x = x + w + 6
			end
			if not items[1] then cv:Status("ok", 14, y - 2, 16); cv:Text("Всё собрано.", 34, y - 3, "GameFontHighlight", nil, nil, { 0.25, 0.85, 0.25 }) end
			y = y - 34
			cv:Text("Правый щелчок по значку — где взять (Questie).", 14, y, "GameFontDisableSmall")
			y = y - 18
		else
			cv:Text("Скоро: локации, где больше всего недостающего для выбранных стеков (жилы GatherMate, мобы и места сбора Questie).", 14, y, "GameFontDisableSmall", Wd - 28)
			y = y - 30
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
	local editSt, editSi = CP.Editing()
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
	end
	content:SetHeight(-y + 10)
	scroll:UpdateScrollChildRect()
end

CP.tabs.plan = { frame = frame, Refresh = Refresh }
