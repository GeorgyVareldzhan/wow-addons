-- CraftPlan 2.0 — вкладка «Схема»: что из чего делается для стеков (выбранных на «Плане» или всех).
-- Колонки по глубине: сырьё слева, рецепты стеков справа; линии с изломом под прямым углом.
local CP = CraftPlan
local W = CP.W

local frame = CreateFrame("Frame", nil, CP.body)
frame:SetAllPoints(CP.body)
frame:Hide()

local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -6)
hint:SetText("Стеки, выбранные на «Плане» (ничего не выбрано — все). Наведите на значок — подсказка, правый щелчок по материалу — где взять.")

local scroll = CreateFrame("ScrollFrame", "CraftPlanSchemaScroll", frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -24)
scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 0)
local content = CreateFrame("Frame", nil, scroll)
content:SetWidth(900)
content:SetHeight(400)
scroll:SetScrollChild(content)
-- Shift+колесо — влево/вправо
local defaultWheel = scroll:GetScript("OnMouseWheel")
scroll:SetScript("OnMouseWheel", function(self, delta)
	if IsShiftKeyDown() then
		local maxX = math.max(0, content:GetWidth() - self:GetWidth())
		self:SetHorizontalScroll(math.min(maxX, math.max(0, self:GetHorizontalScroll() - delta * 80)))
	elseif defaultWheel then
		defaultWheel(self, delta)
	end
end)
local cv = W.Canvas(content)

local COLW, ROWH, ICON = 200, 46, 34
local PAL = { { 0.79, 0.64, 0.15 }, { 0.4, 0.8, 1 }, { 1, 0.5, 0.25 }, { 0.5, 0.88, 0.25 }, { 0.82, 0.5, 1 }, { 1, 0.38, 0.5 } }

local function Refresh()
	cv:Reset()
	local data = CP.Compute()
	local list = {}
	for _, si in ipairs(data.order) do if CP.sel[si] then list[#list + 1] = si end end
	if not list[1] then list = data.order end
	local M = CP.Merge(data.trees, list)
	if not M.ents[1] then
		cv:Text("Стеков нет. Создайте стек на вкладке «План».", 10, -10, "GameFontDisable")
		content:SetHeight(100)
		return
	end
	-- глубина: прямые материалы рецептов — 1, их материалы — 2, ...
	local depth = {}
	local function SetD(id, d)
		if (depth[id] or 0) >= d then return end
		depth[id] = d
		local n = M.nodes[id]
		for _, k in ipairs(n and n.kids or {}) do SetD(k, d + 1) end
	end
	for _, x in ipairs(M.ents) do for _, rg in ipairs(x.rec.reag) do SetD(rg.id, 1) end end
	local maxD = 1
	for _, d in pairs(depth) do maxD = math.max(maxD, d) end
	local cnt, pos = {}, {}
	local function Place(key, col)
		cnt[col] = (cnt[col] or 0) + 1
		pos[key] = { x = 10 + col * COLW, y = -10 - (cnt[col] - 1) * ROWH }
	end
	for _, id in ipairs(M.ord) do if depth[id] then Place("i" .. id, maxD - depth[id]) end end
	for i, x in ipairs(M.ents) do Place(x.key, maxD) end
	-- линии: вправо от подписи, вертикаль перед колонкой изделия, вправо к значку
	local function Link(a, b, ci)
		local pa, pb = pos[a], pos[b]
		if not (pa and pb) then return end
		local c = PAL[(ci - 1) % #PAL + 1]
		local x1, y1 = pa.x + COLW - 40, pa.y - ICON / 2
		local x2, y2 = pb.x - 4, pb.y - ICON / 2
		local mx = x2 - 10 - (ci % 4) * 4
		cv:Rect(x1, y1, mx - x1, 2, c[1], c[2], c[3], 0.75)
		cv:Rect(mx, math.max(y1, y2) + 1, 2, math.abs(y2 - y1) + 2, c[1], c[2], c[3], 0.75)
		cv:Rect(mx, y2, x2 - mx, 2, c[1], c[2], c[3], 0.75)
	end
	for i, x in ipairs(M.ents) do
		local seen = {}
		for _, rg in ipairs(x.rec.reag) do
			if not seen[rg.id] then seen[rg.id] = true; Link("i" .. rg.id, x.key, i) end
		end
	end
	for j, id in ipairs(M.ord) do
		for _, k in ipairs(M.nodes[id].kids) do Link("i" .. k, "i" .. id, j + 3) end
	end
	-- значки
	for _, id in ipairs(M.ord) do
		local p = pos["i" .. id]
		if p then
			local n = M.nodes[id]
			local lines = { "Нужно " .. n.gross .. ", есть " .. n.have .. (n.made > 0 and (", создать " .. n.made) or "") .. (n.short > 0 and (", не хватает " .. n.short) or "") }
			if n.prod then lines[#lines + 1] = "Создаётся: " .. n.prod.rec.name .. " (" .. n.prod.prof .. ")" end
			lines[#lines + 1] = "Правый щелчок — где взять."
			cv:Icon(CP.ItemIcon(id), p.x, p.y, ICON, { count = n.have, countColor = n.short > 0 and { 1, 0.38, 0.38 } or nil, link = "item:" .. id, lines = lines,
				rightAction = function() if WhereToGet_ShowItem then WhereToGet_ShowItem(id) end end })
			cv:Text(CP.ItemName(id), p.x + ICON + 6, p.y - 4, "GameFontHighlightSmall", COLW - ICON - 50, nil, n.made > 0 and { 0.4, 0.8, 1 } or nil)
		end
	end
	for _, x in ipairs(M.ents) do
		local p = pos[x.key]
		local L = data.lines[x.prof]
		local kind = L and CP.KindAt(x.rec.y, x.rec.g, L.rank) or "trivial"
		local c = CP.KIND_COLOR[kind]
		cv:Icon(CP.ItemIcon(x.rec.item > 0 and x.rec.item or nil), p.x, p.y, ICON, { count = "x" .. x.e.n, countColor = { 1, 0.82, 0 },
			link = x.rec.item > 0 and ("item:" .. x.rec.item) or nil, lines = { x.prof .. ": создать " .. x.e.n .. " раз" } })
		cv:Text(x.rec.name, p.x + ICON + 6, p.y - 4, "GameFontHighlightSmall", COLW - ICON - 20, nil, c)
	end
	local rows = 0
	for _, v in pairs(cnt) do rows = math.max(rows, v) end
	content:SetWidth(math.max(scroll:GetWidth(), 20 + (maxD + 1) * COLW))
	content:SetHeight(20 + rows * ROWH)
	scroll:UpdateScrollChildRect()
end

CP.tabs.graph = { frame = frame, Refresh = Refresh }
