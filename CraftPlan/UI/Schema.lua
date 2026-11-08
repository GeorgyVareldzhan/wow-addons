-- CraftPlan 2.0 — "Схема": a tab of the stack panel in "План" (after "Материалы"). What is made from what
-- for the selected stacks (none selected — all). Columns by depth: raw materials on the left, stack recipes on the right;
-- lines with right-angle bends. Click on something craftable (stack recipe, setting, bar…) —
-- highlight its tree down to raw materials, the rest dimmed; click again or on empty space to clear.
local CP = CraftPlan

local ROWH, ICON = 46, 34
local PAL = { { 0.79, 0.64, 0.15 }, { 0.4, 0.8, 1 }, { 1, 0.5, 0.25 }, { 0.5, 0.88, 0.25 }, { 0.82, 0.5, 1 }, { 1, 0.38, 0.5 } }
local DIM = 0.25
local MADE, SHORT, COUNT = { 0.4, 0.8, 1 }, { 1, 0.38, 0.38 }, { 1, 0.82, 0 }

-- cv is the "План" canvas, y is the top, Wd is the width; returns the bottom
function CP.DrawSchema(cv, y, Wd, M, data)
	if not M.ents[1] then
		cv:Text("Стек пуст.", 14, y - 6, "GameFontDisable")
		return y - 26
	end
	local top = y - 6
	-- depth: direct recipe reagents — 1, their reagents — 2, ...
	local depth = {}
	local function SetD(id, d)
		if (depth[id] or 0) >= d or d > 12 then return end
		depth[id] = d
		local n = M.nodes[id]
		for _, k in ipairs(n and n.kids or {}) do SetD(k, d + 1) end
	end
	for _, x in ipairs(M.ents) do for _, rg in ipairs(x.rec.reag) do SetD(rg.id, 1) end end
	local maxD = 1
	for _, d in pairs(depth) do maxD = math.max(maxD, d) end
	-- columns split the panel width (no horizontal scrolling)
	local COLW = math.max(130, math.floor((Wd - 30) / (maxD + 1)))
	local cnt, pos = {}, {}
	local function Place(key, col)
		cnt[col] = (cnt[col] or 0) + 1
		pos[key] = { x = 14 + col * COLW, y = top - (cnt[col] - 1) * ROWH }
	end
	for _, id in ipairs(M.ord) do if depth[id] then Place("i" .. id, maxD - depth[id]) end end
	for _, x in ipairs(M.ents) do Place(x.key, maxD) end
	local rows = 0
	for _, v in pairs(cnt) do rows = math.max(rows, v) end
	local bottom = top - rows * ROWH

	-- highlight: what is under the clicked node (downward — what it's made of)
	local down = {} -- [key] = { reagent keys }
	for _, x in ipairs(M.ents) do
		local t, seen = {}, {}
		for _, rg in ipairs(x.rec.reag) do if not seen[rg.id] then seen[rg.id] = true; t[#t + 1] = "i" .. rg.id end end
		down[x.key] = t
	end
	for _, id in ipairs(M.ord) do
		local t = {}
		for _, k in ipairs(M.nodes[id].kids) do t[#t + 1] = "i" .. k end
		down["i" .. id] = t
	end
	local focus = CP.schemaFocus
	if focus and not pos[focus] then focus = nil; CP.schemaFocus = nil end
	local lit = {}
	if focus then
		local function Walk(k)
			if lit[k] then return end
			lit[k] = true
			for _, c in ipairs(down[k] or {}) do Walk(c) end
		end
		Walk(focus)
	end
	local function On(k) return not focus or lit[k] end
	-- drawn objects by key, to re-dim on hover without a redraw
	local nodeObjs, linkObjs = {}, {}
	local function Apply(fk)
		local set = {}
		if fk then
			local function W2(k)
				if set[k] then return end
				set[k] = true
				for _, c in ipairs(down[k] or {}) do W2(c) end
			end
			W2(fk)
		end
		local function on(k) return not fk or set[k] end
		for k, o in pairs(nodeObjs) do
			local a = on(k) and 1 or DIM
			o.b:SetAlpha(a)
			o.fs:SetAlpha(a)
		end
		for _, l in ipairs(linkObjs) do
			local al = (on(l.a) and on(l.b)) and 0.75 or 0.12
			for _, r in ipairs(l.rects) do r:SetAlpha(al / 0.75) end
		end
	end
	-- hovering something craftable shows its tree; leaving — back to the clicked one (or none)
	local function Hover(k)
		return function(on)
			if CP.schemaFocus then return end
			Apply(on and k or nil)
		end
	end
	local function Pick(k)
		return function()
			CP.schemaFocus = (CP.schemaFocus ~= k) and k or nil
			CP.RefreshWindow()
		end
	end
	-- empty space of the schema — clear the highlight
	cv:Area(10, top + 4, Wd - 20, top - bottom + 8, { level = 1, action = function()
		if CP.schemaFocus then CP.schemaFocus = nil; CP.RefreshWindow() end
	end })

	-- lines: right from the label, a vertical before the product column, right to the icon
	local function Link(a, b, ci)
		local pa, pb = pos[a], pos[b]
		if not (pa and pb) then return end
		local c = PAL[(ci - 1) % #PAL + 1]
		local al = (On(a) and On(b)) and 0.75 or 0.12
		local x1, y1 = pa.x + COLW - 40, pa.y - ICON / 2
		local x2, y2 = pb.x - 4, pb.y - ICON / 2
		local mx = x2 - 10 - (ci % 4) * 4
		local r1 = cv:Rect(x1, y1, mx - x1, 2, c[1], c[2], c[3], 0.75)
		local r2 = cv:Rect(mx, math.max(y1, y2) + 1, 2, math.abs(y2 - y1) + 2, c[1], c[2], c[3], 0.75)
		local r3 = cv:Rect(mx, y2, x2 - mx, 2, c[1], c[2], c[3], 0.75)
		for _, r in ipairs({ r1, r2, r3 }) do r:SetAlpha(al / 0.75) end
		linkObjs[#linkObjs + 1] = { a = a, b = b, rects = { r1, r2, r3 } }
	end
	for i, x in ipairs(M.ents) do
		for _, k in ipairs(down[x.key]) do Link(k, x.key, i) end
	end
	for j, id in ipairs(M.ord) do
		for _, k in ipairs(M.nodes[id].kids) do Link("i" .. k, "i" .. id, j + 3) end
	end
	-- material icons
	for _, id in ipairs(M.ord) do
		local key = "i" .. id
		local p = pos[key]
		if p then
			local n = M.nodes[id]
			local craft = n.prod or CP.Producer(id) -- crafted by a recipe — clickable
			local a = On(key) and 1 or DIM
			local lines = { "Нужно " .. n.gross .. ", есть " .. n.have .. (n.made > 0 and (", создать " .. n.made) or "") .. (n.short > 0 and (", не хватает " .. n.short) or "") }
			if craft then
				lines[#lines + 1] = "Создаётся: " .. craft.rec.name .. " (" .. craft.prof .. ")" .. (craft.why and (" — " .. craft.why) or "")
				lines[#lines + 1] = "Щелчок — показать, из чего делается."
			end
			lines[#lines + 1] = "Правый щелчок — где взять."
			local b = cv:Icon(CP.ItemIcon(id), p.x, p.y, ICON, { level = 4, alpha = a, count = n.have, countColor = n.short > 0 and SHORT or nil,
				link = "item:" .. id, lines = lines, action = craft and Pick(key) or nil, hover = craft and Hover(key) or nil,
				where = id, locked = focus == key })
			local fs = cv:Text(CP.ItemName(id), p.x + ICON + 6, p.y - 4, "GameFontHighlightSmall", COLW - ICON - 50, nil, n.made > 0 and MADE or nil)
			fs:SetAlpha(a)
			nodeObjs[key] = { b = b, fs = fs }
		end
	end
	-- stack recipe icons
	for _, x in ipairs(M.ents) do
		local p = pos[x.key]
		local L = data.lines[x.prof]
		local kind = L and CP.KindAt(x.rec.y, x.rec.g, L.rank) or "trivial"
		local a = On(x.key) and 1 or DIM
		local b = cv:Icon(CP.ItemIcon(x.rec.item > 0 and x.rec.item or nil), p.x, p.y, ICON, { level = 4, alpha = a, count = "x" .. x.e.n, countColor = COUNT,
			link = x.rec.item > 0 and ("item:" .. x.rec.item) or nil, lines = { x.prof .. ": создать " .. x.e.n .. " раз", "Щелчок — показать, из чего делается." },
			action = Pick(x.key), hover = Hover(x.key), locked = focus == x.key })
		local fs = cv:Text(x.rec.name, p.x + ICON + 6, p.y - 4, "GameFontHighlightSmall", COLW - ICON - 20, nil, CP.KIND_COLOR[kind])
		fs:SetAlpha(a)
		nodeObjs[x.key] = { b = b, fs = fs }
	end
	return bottom - 6
end
