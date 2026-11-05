-- CraftPlan 2.0 — расчёт: рецепты из таблицы, стеки, дерево материалов с резервом, прирост навыка.
-- db.goal = { stacks = { { list = { { sk, name, n } }, add = { [предмет] = штук }, time } }, edit = номер }
local CP = CraftPlan
local DB = CP.DB

----------------------------------------------------------------------------------------------
-- Рецепты профессии из таблицы CraftPlanRouteData:
-- "заклинание|название|жёлтый|серый|с профессией|изделие|штук|материал*кол;...|перезарядка"
local parsed = {}
function CP.Recipes(sk)
	if parsed[sk] then return parsed[sk] end
	local list, by = {}, {}
	for _, line in ipairs(CraftPlanRouteData and CraftPlanRouteData[sk] or {}) do
		local spell, name, y, g, acq, item, made, reag, cd = strsplit("|", line)
		local rec = { sk = sk, spell = tonumber(spell), name = name, y = tonumber(y) or 0, g = tonumber(g) or 0,
			item = tonumber(item) or 0, made = tonumber(made) or 1, cd = (cd == "1"), reag = {} }
		for id, c in (reag or ""):gmatch("(%d+)%*(%d+)") do rec.reag[#rec.reag + 1] = { id = tonumber(id), count = tonumber(c) } end
		list[#list + 1] = rec
		by[name] = by[name] or rec
	end
	list.by = by
	parsed[sk] = list
	return list
end
function CP.FindRec(sk, name)
	return CP.Recipes(sk).by[name]
end

-- С какого навыка учится рецепт (по учителю) или nil
function CP.LearnReq(sk, name)
	local l = DB().learn and DB().learn[sk] and DB().learn[sk][name]
	if l and l.req then return l.req end
	local prof = CP.SKILL_NAME[sk]
	local item = prof and CP.RecipeItem and CP.RecipeItem(prof, name)
	return item and CP.BookReq(item, prof) or nil
end

-- Кто делает предмет: рецепт ваших профессий (изученный — в первую очередь)
local prodCache, prodStamp
function CP.Producer(id)
	local stamp = DB().profs
	if not prodCache or prodStamp ~= stamp then
		prodCache, prodStamp = {}, stamp
		local lines = CP.SkillLines()
		for prof, sk in pairs(CP.SKILL_ID) do
			if lines[prof] then
				for _, rec in ipairs(CP.Recipes(sk)) do
					if rec.item > 0 then
						local known = CP.KnownRecipe(prof, rec.name) and true
						local cur = prodCache[rec.item]
						if not cur or (known and not cur.known) then prodCache[rec.item] = { rec = rec, prof = prof, known = known } end
					end
				end
			end
		end
	end
	return prodCache[id]
end
CP.OnChange(function() prodCache = nil end)

----------------------------------------------------------------------------------------------
-- Стеки
function CP.Goal()
	local db = DB()
	db.goal = db.goal or {}
	local g = db.goal
	g.stacks = g.stacks or {}
	-- до 0.12.15: «текущий стек» list/add — становится обычным стеком
	if g.list or g.add then
		local has = g.add and next(g.add)
		for _, e in ipairs(g.list or {}) do if e.n > 0 then has = true end end
		if has then g.stacks[#g.stacks + 1] = { list = g.list or {}, add = g.add or {}, time = time() } end
		g.list, g.add = nil, nil
	end
	for _, st in ipairs(g.stacks) do st.list, st.add = st.list or {}, st.add or {} end
	if g.edit and not g.stacks[g.edit] then g.edit = nil end
	return g
end

-- Записи стека, которые есть в таблице рецептов: { e, rec, prof }
function CP.Entries(st)
	local out = {}
	for _, e in ipairs(st.list) do
		local rec = e.n > 0 and CP.FindRec(e.sk, e.name)
		if rec then out[#out + 1] = { e = e, rec = rec, prof = CP.SKILL_NAME[e.sk] } end
	end
	return out
end

-- Порядок стеков по навыку: самый ранний навык изучения его рецептов (иначе жёлтый порог)
function CP.StackOrder()
	local g, order, keys = CP.Goal(), {}, {}
	for si, st in ipairs(g.stacks) do
		local k = 9999
		for _, x in ipairs(CP.Entries(st)) do k = math.min(k, CP.LearnReq(x.rec.sk, x.rec.name) or x.rec.y) end
		order[#order + 1] = si
		keys[si] = k
	end
	table.sort(order, function(a, b)
		if keys[a] ~= keys[b] then return keys[a] < keys[b] end
		return a < b
	end)
	return order
end
function CP.StackNum(si)
	for k, x in ipairs(CP.StackOrder()) do if x == si then return k end end
	return si
end

-- Дерево одного стека. stock — общий запас (стеки по порядку резервируют своё).
-- nodes[id] = { id, gross, made, short, have, parents = { [ключ] = штук }, kids = { id } }
local function BuildStack(si, st, stock)
	local t = { nodes = {}, ord = {}, ents = CP.Entries(st), si = si }
	local function Node(id)
		local n = t.nodes[id]
		if not n then
			n = { id = id, gross = 0, made = 0, short = 0, parents = {}, kids = {}, kidSet = {} }
			t.nodes[id] = n
			t.ord[#t.ord + 1] = id
		end
		return n
	end
	local function Need(id, amt, parent, depth)
		local n = Node(id)
		n.gross = n.gross + amt
		n.parents[parent] = (n.parents[parent] or 0) + amt
		if stock[id] == nil then stock[id] = CP.Have(id) end
		local use = math.min(stock[id], amt)
		stock[id] = stock[id] - use
		local left = amt - use
		if left <= 0 then return end
		local pr = CP.Producer(id)
		if pr and depth < 6 and not n.busy then
			local made = pr.rec.made or 1
			local times = math.ceil(left / made)
			n.made = n.made + times * made
			n.prod = pr
			n.busy = true
			for _, rg in ipairs(pr.rec.reag) do
				if not n.kidSet[rg.id] then n.kidSet[rg.id] = true; n.kids[#n.kids + 1] = rg.id end
				Need(rg.id, rg.count * times, "i" .. id, depth + 1)
			end
			n.busy = nil
			stock[id] = stock[id] + times * made - left -- лишнее от «несколько штук за раз»
		else
			n.short = n.short + left
		end
	end
	for i, x in ipairs(t.ents) do
		x.key = "s" .. si .. "r" .. i
		for _, rg in ipairs(x.rec.reag) do Need(rg.id, rg.count * x.e.n, x.key, 1) end
	end
	-- материалы, добавленные в стек вручную
	for id, n in pairs(st.add) do
		if n > 0 then Need(id, n, "s" .. si .. "add", 1) end
	end
	for _, id in ipairs(t.ord) do t.nodes[id].have = CP.Have(id) end
	return t
end

-- Все стеки по порядку навыка: trees[si] — дерево стека, gain[si][профессия] — точный прирост
-- (оранжевые создания, навык идёт по ходу через стеки)
local computed -- запоминаем до следующего изменения (CP.Changed): подсказки и полоса зовут часто
CP.OnChange(function() computed = nil end)
function CP.DropCache() computed = nil end
function CP.Compute()
	if computed then return computed end
	local g = CP.Goal()
	local stock, trees, gain, ranks = {}, {}, {}, {}
	local lines = CP.SkillLines()
	for _, si in ipairs(CP.StackOrder()) do
		local st = g.stacks[si]
		local t = BuildStack(si, st, stock)
		trees[si] = t
		local gn = {}
		local ents = {}
		for _, x in ipairs(t.ents) do ents[#ents + 1] = x end
		table.sort(ents, function(a, b) return a.rec.y < b.rec.y end)
		for _, x in ipairs(ents) do
			local L = lines[x.prof]
			if L then
				local r0 = ranks[x.prof] or L.rank
				local from = math.max(r0, CP.LearnReq(x.rec.sk, x.rec.name) or 0)
				local o = math.max(0, math.min(x.e.n, x.rec.y - from, L.max - from))
				gn[x.prof] = (gn[x.prof] or 0) + o
				ranks[x.prof] = from + o
			end
		end
		gain[si] = gn
	end
	computed = { trees = trees, gain = gain, order = CP.StackOrder(), lines = lines }
	return computed
end

-- Объединить деревья нескольких стеков (для панели: выбранные или все)
function CP.Merge(trees, list)
	local out = { nodes = {}, ord = {}, ents = {} }
	for _, si in ipairs(list) do
		local t = trees[si]
		if t then
			for _, x in ipairs(t.ents) do out.ents[#out.ents + 1] = x end
			for _, id in ipairs(t.ord) do
				local a = t.nodes[id]
				local n = out.nodes[id]
				if not n then
					n = { id = id, gross = 0, made = 0, short = 0, have = a.have, parents = {}, kids = {}, kidSet = {} }
					out.nodes[id] = n
					out.ord[#out.ord + 1] = id
				end
				n.gross, n.made, n.short = n.gross + a.gross, n.made + a.made, n.short + a.short
				n.prod = n.prod or a.prod
				for k, v in pairs(a.parents) do n.parents[k] = (n.parents[k] or 0) + v end
				for _, k in ipairs(a.kids) do
					if not n.kidSet[k] then n.kidSet[k] = true; n.kids[#n.kids + 1] = k end
				end
			end
		end
	end
	return out
end

-- Сколько видов и штук не хватает
function CP.Shortage(t)
	local kinds, pieces = 0, 0
	for _, id in ipairs(t.ord) do
		local n = t.nodes[id]
		if n.short > 0 then kinds, pieces = kinds + 1, pieces + n.short end
	end
	return kinds, pieces
end

----------------------------------------------------------------------------------------------
-- Правка стеков. Выделение (ui) — только на сессию: CP.sel = { [номер] = true }
CP.sel = {}
function CP.Editing()
	local g = CP.Goal()
	return g.edit and g.stacks[g.edit] or nil, g.edit
end
local function Copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = Copy(x) end
	return c
end
function CP.BeginEdit(si)
	local g = CP.Goal()
	if g.edit then return end
	CP.snap, CP.prevSel = Copy(g.stacks), CP.sel
	g.edit = si
	CP.sel = { [si] = true }
	CP.Changed()
end
function CP.NewStack()
	local g = CP.Goal()
	if g.edit then return end
	CP.snap, CP.prevSel = Copy(g.stacks), CP.sel
	g.stacks[#g.stacks + 1] = { list = {}, add = {}, time = time() }
	g.edit = #g.stacks
	CP.sel = { [g.edit] = true }
	CP.Changed()
end
function CP.SaveEdit()
	local g = CP.Goal()
	local st = g.edit and g.stacks[g.edit]
	g.edit = nil
	CP.sel, CP.prevSel, CP.snap = CP.prevSel or {}, nil, nil
	if st then -- пустой стек не храним
		local any = next(st.add) ~= nil
		for _, e in ipairs(st.list) do if e.n > 0 then any = true end end
		if not any then CP.RemoveStack(CP.IndexOf(st)) end
	end
	CP.Changed()
end
function CP.CancelEdit()
	local g = CP.Goal()
	if CP.snap then g.stacks = CP.snap end
	g.edit = nil
	CP.sel, CP.prevSel, CP.snap = CP.prevSel or {}, nil, nil
	CP.Changed()
end
function CP.IndexOf(st)
	for i, x in ipairs(CP.Goal().stacks) do if x == st then return i end end
end
function CP.RemoveStack(si)
	if not si then return end
	local g = CP.Goal()
	table.remove(g.stacks, si)
	if g.edit == si then g.edit = nil elseif g.edit and g.edit > si then g.edit = g.edit - 1 end
	CP.sel = {}
end
-- Сколько раз рецепт в стеке на правке (0 — нет или правки нет)
function CP.CountIn(sk, name)
	local st = CP.Editing()
	for _, e in ipairs(st and st.list or {}) do
		if e.sk == sk and e.name == name then return e.n end
	end
	return 0
end
-- В каких стеках рецепт: «Стек 1, Стек 3» или nil
function CP.StacksWith(sk, name)
	local g, out = CP.Goal(), {}
	for k, si in ipairs(CP.StackOrder()) do
		for _, e in ipairs(g.stacks[si].list or {}) do
			if e.sk == sk and e.name == name and e.n > 0 then out[#out + 1] = "Стек " .. k break end
		end
	end
	return #out > 0 and table.concat(out, ", ") or nil
end
-- Убрать рецепт из стека на правке целиком
function CP.RemoveFromEdit(sk, name)
	local st = CP.Editing()
	for k, e in ipairs(st and st.list or {}) do
		if e.sk == sk and e.name == name then
			table.remove(st.list, k)
			CP.Changed(0)
			return
		end
	end
end
-- Добавить/убрать рецепт в стеке на правке
function CP.Bump(sk, name, d)
	local st = CP.Editing()
	if not st then
		CP.Print("сначала «Создать стек» или карандаш на стеке (вкладка «План»).")
		return
	end
	for k, e in ipairs(st.list) do
		if e.sk == sk and e.name == name then
			e.n = e.n + d
			if e.n <= 0 then table.remove(st.list, k) end
			CP.ChangedSettle()
			return math.max(e.n, 0)
		end
	end
	if d > 0 then
		st.list[#st.list + 1] = { sk = sk, name = name, n = d }
		CP.ChangedSettle()
		return d
	end
	return 0
end
-- Материал в стек на правке
function CP.AddMat(id, d)
	local st = CP.Editing()
	if not st then
		CP.Print("сначала «Создать стек» или карандаш на стеке (вкладка «План»).")
		return
	end
	local v = (st.add[id] or 0) + d
	st.add[id] = (v > 0) and v or nil
	CP.Changed()
end
-- Рецепт по названию в ваших профессиях (для кнопок у учителя/торговца, Shift+щелчка)
function CP.FindByName(prof, name)
	if prof and CP.SKILL_ID[prof] then
		local rec = CP.FindRec(CP.SKILL_ID[prof], name)
		if rec then return rec end
	end
	local lines = CP.SkillLines()
	local best
	for p, sk in pairs(CP.SKILL_ID) do
		local rec = CP.FindRec(sk, name)
		if rec and (not best or (lines[p] and not lines[CP.SKILL_NAME[best.sk]])) then best = rec end
	end
	return best
end

-- Создали рецепт — минус 1 у первого по порядку стека с этим рецептом; стек, где всё создано, удаляется
local watch = CreateFrame("Frame")
watch:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
watch:SetScript("OnEvent", function(_, _, unit, spell)
	if unit ~= "player" or not spell or not CraftPlanDB or not CraftPlanDB.goal then return end
	local g = CP.Goal()
	for _, si in ipairs(CP.StackOrder()) do
		local st = g.stacks[si]
		for _, e in ipairs(st.list) do
			if e.name == spell and e.n > 0 then
				e.n = e.n - 1
				local left = false
				for _, x in ipairs(st.list) do if x.n > 0 then left = true end end
				if not left and g.edit ~= si then
					CP.RemoveStack(si)
					CP.Print("стек создан целиком.")
				end
				CP.Changed()
				CP.ChangedLater(1.5)
				return
			end
		end
	end
end)
