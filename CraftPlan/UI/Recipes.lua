-- CraftPlan 2.0 — the "Все рецепты" window to the right of the main one: all recipes of your professions from the addon table
-- (learned or not), the "Навык" filter, search, "- N +" into the stack being edited.
local CP = CraftPlan
local W = CP.W
local DB = CP.DB

local PW = 440
-- Rows have their own height: name 1-2 lines + reagents 0-2 rows, 12 px padding top/bottom.
-- STEP is the scroll unit per row for the scrollbar (rows are scrolled one by one).
local STEP, MINH = 50, 56
local NAMEW = PW - 16 - 36 - 42 - 74 -- name width: panel - scroll insets - icon column - right buttons

local f = CreateFrame("Frame", "CraftPlanRecipes", CP.win)
f:SetWidth(PW)
f:SetPoint("TOPLEFT", CP.win, "TOPRIGHT", -4, 0)
f:SetPoint("BOTTOMLEFT", CP.win, "BOTTOMRIGHT", -4, 0)
W.Backdrop(f)
f:EnableMouse(true)
f:Hide()

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -18)
title:SetText("Все рецепты")
local target = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
target:SetPoint("LEFT", title, "RIGHT", 10, 0)
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
close:SetScript("OnClick", function() CP.ToggleRecipes(false) end)

-- Lower case for search: string.lower leaves Cyrillic UTF-8 alone, so А-Я and Ё (2-byte sequences) are mapped here
local LOWER = { ["\208\129"] = "\209\145" } -- Ё -> ё
for b = 0x90, 0x9F do LOWER["\208" .. string.char(b)] = "\208" .. string.char(b + 0x20) end -- А..П -> а..п
for b = 0xA0, 0xAF do LOWER["\208" .. string.char(b)] = "\209" .. string.char(b - 0x20) end -- Р..Я -> р..я
local function Lower(s) return (s:gsub("\208[\129\144-\175]", LOWER):lower()) end
local lowerName = {} -- [recipe name] = lower-case name (static)
local function LowerName(name)
	local l = lowerName[name]
	if not l then l = Lower(name); lowerName[name] = l end
	return l
end

local profBtns = {}
local query = ""
local ResetScroll -- back to the top of the list (defined with the scroll frame)
local box = W.SearchBox(f, "CraftPlanRecipesSearch", 150, function(t) query = Lower(t); if f:IsShown() then CP.RefreshRecipes() end end)
local KINDS = {
	{ "skill", "Всё, что даёт навык" }, { "orange", "Только оранжевые" }, { "oy", "Оранжевые и жёлтые" },
	{ "yellow", "Только жёлтые" }, { "green", "Только зелёные" }, { "all", "Все (и серые)" },
}
local KSET = { skill = "oyg", orange = "o", oy = "oy", yellow = "y", green = "g", all = "oygt" }
local LETTER = { optimal = "o", medium = "y", easy = "g", trivial = "t" }
local drop = W.Dropdown(f, "CraftPlanRecipesKind", 150, KINDS,
	function() return DB().apKind or "skill" end,
	function(k) DB().apKind = k; ResetScroll(); CP.RefreshRecipes() end)
-- "Только у учителя": hide recipes you'd have to buy, loot or get from a quest
local trainerCheck = W.Check(f, "CraftPlanRecipesTrainer", "Только у учителя",
	function() return DB().apTrainer end,
	function(v) DB().apTrainer = v or nil; ResetScroll(); CP.RefreshRecipes() end,
	"Только изученные и те, что учит учитель профессии. Рецепты с торговцев, добычи и заданий скрыты. Рецепты из стека на правке видны всегда.")
local skillLbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
skillLbl:SetText("Навык")

local sc = CreateFrame("ScrollFrame", "CraftPlanRecipesScroll", f, "FauxScrollFrameTemplate")
sc:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 16)
-- scrolling only refills the rows (FillRows, below); while ResetScroll moves to the top the refill is skipped —
-- its caller redraws anyway
local FillRows
local quiet = false
local function Noop() end
local function Fill() if f:IsShown() then FillRows() end end
sc:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, STEP, quiet and Noop or Fill) end)
sc:SetScript("OnSizeChanged", function() if f:IsShown() and not CP.sizing then CP.RefreshRecipes() end end) -- the grip redraws on release
ResetScroll = function()
	FauxScrollFrame_SetOffset(sc, 0)
	quiet = true
	sc:SetVerticalScroll(0)
	quiet = false
end

local rows = {}
local function Row(i)
	if rows[i] then return rows[i] end
	local r = CreateFrame("Button", nil, f)
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	r.sep = r:CreateTexture(nil, "BACKGROUND")
	r.sep:SetTexture(W.WHITE)
	r.sep:SetVertexColor(0.16, 0.13, 0.09, 1)
	r.sep:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
	r.sep:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
	r.sep:SetHeight(1)
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetWidth(30)
	r.icon:SetHeight(30)
	r.icon:SetPoint("TOPLEFT", r, "TOPLEFT", 4, -12)
	r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	r.plus = CreateFrame("Button", nil, r)
	r.plus:SetWidth(16)
	r.plus:SetHeight(16)
	r.plus:SetPoint("TOPRIGHT", r, "TOPRIGHT", -22, -12)
	r.plus:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
	r.plus:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
	r.plus:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
	r.count = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	r.count:SetPoint("RIGHT", r.plus, "LEFT", -2, 0)
	r.count:SetWidth(24)
	r.count:SetJustifyH("CENTER")
	r.minus = CreateFrame("Button", nil, r)
	r.minus:SetWidth(16)
	r.minus:SetHeight(16)
	r.minus:SetPoint("RIGHT", r.count, "LEFT", -2, 0)
	r.minus:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
	r.minus:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-Down")
	r.minus:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
	-- cross: remove the recipe from the stack being edited entirely
	r.remove = CreateFrame("Button", nil, r)
	r.remove:SetWidth(14)
	r.remove:SetHeight(14)
	r.remove:SetPoint("TOPRIGHT", r, "TOPRIGHT", -4, -13)
	r.remove:SetNormalTexture(W.TEX.clear)
	r.remove:SetHighlightTexture(W.TEX.clear, "ADD")
	r.remove:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine("Убрать из стека"); GameTooltip:Show() end)
	r.remove:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- green check in the top-left icon corner: the recipe is in some stack
	r.inStack = r:CreateTexture(nil, "OVERLAY")
	r.inStack:SetWidth(16)
	r.inStack:SetHeight(16)
	r.inStack:SetPoint("TOPLEFT", r.icon, "TOPLEFT", -4, 4) -- top-left corner of the icon
	r.inStack:SetTexture(W.TEX.ok)
	r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", r, "TOPLEFT", 42, -12)
	r.name:SetPoint("RIGHT", r, "RIGHT", -74, 0)
	-- no fixed height: the string grows with wrapping, reagents hang right under it
	r.name:SetJustifyH("LEFT")
	r.name:SetJustifyV("TOP")
	-- bottom right: status icon, "+N", learn skill
	r.status = r:CreateTexture(nil, "OVERLAY")
	r.status:SetWidth(14)
	r.status:SetHeight(14)
	r.status:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -4, 12)
	r.gain2 = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.gain2:SetPoint("RIGHT", r.status, "LEFT", -4, 0) -- centered on the status icon
	r.gain = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.gain:SetPoint("BOTTOMRIGHT", r.gain2, "TOPRIGHT", 0, 1)
	-- trainer price of a not learned recipe: bottom right, under the status icon
	r.price = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.price:SetPoint("TOPRIGHT", r.status, "BOTTOMRIGHT", 0, -1)
	r.price:SetTextColor(0.78, 0.72, 0.56)
	r.req = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.req:SetPoint("RIGHT", r.status, "LEFT", -48, 0)
	-- reagents: 3 per row, up to 2 rows
	r.rg = {}
	for k = 1, 6 do
		local t = r:CreateTexture(nil, "ARTWORK")
		t:SetWidth(14)
		t:SetHeight(14)
		t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		-- right under the name, whatever its height (1 or 2 lines)
		t:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", ((k - 1) % 3) * 72, -6 - math.floor((k - 1) / 3) * 20)
		local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", t, "RIGHT", 3, 0)
		-- hovering a reagent shows the item tooltip, as in the profession window
		local b = CreateFrame("Button", nil, r)
		b:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
		b:SetWidth(68)
		b:SetHeight(14)
		b:SetFrameLevel(r:GetFrameLevel() + 2)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnEnter", function(self)
			if not self.id then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink("item:" .. self.id)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Есть " .. CP.Have(self.id) .. ", нужно " .. self.need .. " на одно создание.", 1, 1, 1)
			GameTooltip:AddLine("Правый щелчок — где взять.", 0.5, 0.8, 1)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("OnClick", function(self, button)
			if button == "RightButton" and self.id and WhereToGet_ShowItem then WhereToGet_ShowItem(self.id) return end
			r:GetScript("OnClick")(r, button)
		end)
		r.rg[k] = { t = t, fs = fs, b = b }
	end
	-- the number changes at once, the recalc runs after a pause in clicks
	local function bump(d, step)
		local n = CP.Bump(d.rec.sk, d.rec.name, step)
		if not n then return end
		r.count:SetText(n > 0 and ("|cffffd200" .. n .. "|r") or "|cff5555550|r")
		if n > 0 then r.minus:Show(); r.remove:Show() else r.minus:Hide(); r.remove:Hide() end
	end
	r.remove:SetScript("OnClick", function(self)
		local d = self:GetParent().data
		if not d then return end
		CP.RemoveFromEdit(d.rec.sk, d.rec.name)
		r.count:SetText("|cff5555550|r")
		r.minus:Hide(); r.remove:Hide()
	end)
	r.plus:SetScript("OnClick", function(self) local d = self:GetParent().data; if d then bump(d, W.Step()) end end)
	r.minus:SetScript("OnClick", function(self) local d = self:GetParent().data; if d then bump(d, -W.Step()) end end)
	r:SetScript("OnClick", function(self, button)
		local d = self.data
		if not d then return end
		if IsModifiedClick("CHATLINK") and d.rec.item > 0 and ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then
			local _, link = GetItemInfo(d.rec.item)
			if link then ChatEdit_InsertLink(link) return end
		end
		bump(d, (button == "RightButton") and -W.Step() or W.Step())
	end)
	-- tooltip (item description, how to learn, thresholds, reagents) — only on icon hover
	r.iconBtn = CreateFrame("Button", nil, r)
	r.iconBtn:SetAllPoints(r.icon)
	r.iconBtn:SetFrameLevel(r:GetFrameLevel() + 2)
	r.iconBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	r.iconBtn:SetScript("OnClick", function(self, button) r:GetScript("OnClick")(r, button) end)
	r.iconBtn:SetScript("OnEnter", function(self)
		local d = r.data
		if not d then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if d.rec.item > 0 then GameTooltip:SetHyperlink("item:" .. d.rec.item) else GameTooltip:AddLine(d.rec.name) end
		GameTooltip:AddLine(" ")
		if d.known then
			GameTooltip:AddLine("Изучен.", 0.25, 1, 0.25)
		end
		if d.inStack then GameTooltip:AddLine("В стеке: " .. d.inStack, 0.25, 1, 0.25) end
		if not d.known then
			GameTooltip:AddLine("Не изучен" .. (d.req and (", учится с навыка " .. d.req) or "") .. ". Где учить:", 1, 0.5, 0.25)
			local src = CP.RecipeSource and CP.RecipeSource(d.prof, d.rec.name) or { "Нет данных: перезапустите игру (новый файл Sources.lua)." }
			for _, l in ipairs(src) do GameTooltip:AddLine("  " .. l, 1, 1, 1, true) end
		end
		GameTooltip:AddLine("Пороги: жёлтый с " .. d.rec.y .. ", серый с " .. d.rec.g .. ".", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Материалы на одно создание (есть / нужно):", 1, 0.82, 0)
		for _, rg in ipairs(d.rec.reag) do
			local have = CP.Have(rg.id)
			local ok = have >= rg.count
			GameTooltip:AddDoubleLine("  " .. CP.ItemName(rg.id), have .. " / " .. rg.count, 1, 1, 1, ok and 0.25 or 1, ok and 1 or 0.4, ok and 0.25 or 0.4)
		end
		GameTooltip:AddLine("Щелчок или «+» — в стек на правке, правый — убрать (Shift — по 10).", 0.5, 0.8, 1, true)
		GameTooltip:Show()
	end)
	r.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	rows[i] = r
	return r
end

-- Row height: measured with a hidden string (unwrapped width / name width = lines), cached by name
local measure = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
measure:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) -- anchored, single point (no wrapping), invisible
measure:SetAlpha(0)
local nameLines, lineH = {}, nil
local function RowHeight(rec)
	if not lineH then
		measure:SetText("Ag")
		lineH = math.max(12, math.floor((measure:GetStringHeight() or 14) + 0.5))
	end
	local n = nameLines[rec.name]
	if not n then
		measure:SetText(rec.name)
		n = math.min(3, math.max(1, math.ceil((measure:GetStringWidth() + 4) / NAMEW)))
		nameLines[rec.name] = n
	end
	local rr = #rec.reag == 0 and 0 or (#rec.reag > 3 and 2 or 1)
	local rh = rr == 0 and 0 or (6 + 14 + (rr - 1) * 20) -- gap under the name, reagent rows 20 px apart
	return math.max(MINH, 12 + n * lineH + rh + 12) -- top pad, name, reagents, bottom pad
end

-- "+expected-max" over the skill range [a, b) starting at skill from
local function Span(rec, from, a, b)
	local lo = math.max(from, a)
	if b <= lo then return nil end
	local e = 0
	for x = lo, b - 1 do e = e + CP.Chance(rec.y, rec.g, x) end
	return "+" .. math.max(1, math.floor(e + 0.5)) .. "-" .. (b - lo)
end

-- Learnable at the trainer: learned already, or in the trainer list (db.learn). Not trainer: a recipe item
-- exists, or the trainer list for this profession is known and lacks it. No data either way — kept.
local function AtTrainer(sk, prof, name, known)
	if known then return true end
	local learn = DB().learn and DB().learn[sk]
	if learn and learn[name] then return true end
	if learn and next(learn) then return false end
	if CP.RecipeItem and CP.RecipeItem(prof, name) then return false end
	return true
end

-- The filtered, sorted list of one profession; cached for one key (profession, skill, filters, search) until
-- CP.DropCache (learned recipes, the stack being edited, trainer data). Scrolling reuses it.
local listKey, listMemo
CP.OnDrop(function() listKey, listMemo = nil, nil end)
local function List(prof, rank)
	local key = prof .. "|" .. rank .. "|" .. (DB().apKind or "skill") .. "|" .. (DB().apTrainer and "t" or "") .. "|" .. query
	if listMemo and listKey == key then return listMemo end
	local sk = CP.SKILL_ID[prof]
	local set = KSET[DB().apKind or "skill"]
	local trainerOnly = DB().apTrainer
	local out = {}
	for _, rec in ipairs(CP.Recipes(sk)) do
		local kind = CP.KindAt(rec.y, rec.g, rank)
		local cnt = CP.CountIn(sk, rec.name)
		if (cnt > 0 or set:find(LETTER[kind], 1, true)) and (query == "" or LowerName(rec.name):find(query, 1, true)) then
			local known = CP.KnownRecipe(prof, rec.name) and true
			if cnt > 0 or not trainerOnly or AtTrainer(sk, prof, rec.name, known) then
				out[#out + 1] = { rec = rec, prof = prof, kind = kind, count = cnt, known = known, req = CP.LearnReq(sk, rec.name) }
			end
		end
	end
	table.sort(out, function(a, b)
		-- by the skill at which the recipe turns yellow, then by the learn skill (unknown — last)
		if a.rec.y ~= b.rec.y then return a.rec.y < b.rec.y end
		local ra, rb = a.req or 9999, b.req or 9999
		if ra ~= rb then return ra < rb end
		return a.rec.name < b.rec.name
	end)
	listKey, listMemo = key, out
	return out
end

local curProf, curRank -- the profession shown and its skill (set by CP.RefreshRecipes, used by FillRows)

function CP.RefreshRecipes()
	if not f:IsShown() then return end
	local db = DB()
	local lines = CP.SkillLines()
	local profs = {}
	for prof, sk in pairs(CP.SKILL_ID) do
		if lines[prof] and #CP.Recipes(sk) > 0 then profs[#profs + 1] = prof end
	end
	table.sort(profs)
	local cur = db.apProfName
	local okCur = false
	for _, p in ipairs(profs) do if p == cur then okCur = true end end
	if not okCur then cur = profs[1]; db.apProfName = cur end
	local _, editSi = CP.Editing()
	target:SetText(editSi and ("|cffffd200в Стек " .. CP.StackNum(editSi) .. "|r") or "")
	-- profession buttons
	local x, y = 16, -44
	for i, p in ipairs(profs) do
		local b = profBtns[i]
		if not b then
			b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
			b:SetHeight(20)
			b:SetScript("OnClick", function(self) DB().apProfName = self.prof; ResetScroll(); CP.RefreshRecipes() end)
			profBtns[i] = b
		end
		b:SetText(p .. " " .. lines[p].rank)
		b:SetWidth(b:GetFontString():GetStringWidth() + 18)
		if x > 16 and x + b:GetWidth() > PW - 16 then x, y = 16, y - 24 end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
		b.prof = p
		if p == cur then b:LockHighlight(); b:GetFontString():SetTextColor(1, 0.82, 0) else b:UnlockHighlight(); b:GetFontString():SetTextColor(0.6, 0.6, 0.6) end
		b:Show()
		x = x + b:GetWidth() + 4
	end
	for i = #profs + 1, #profBtns do profBtns[i]:Hide() end
	y = y - 30
	box:ClearAllPoints()
	box:SetPoint("TOPLEFT", f, "TOPLEFT", 24, y)
	skillLbl:ClearAllPoints()
	skillLbl:SetPoint("LEFT", box, "RIGHT", 14, 0)
	drop:ClearAllPoints()
	drop:SetPoint("LEFT", skillLbl, "RIGHT", -10, -2)
	drop.Refresh()
	y = y - 28
	trainerCheck:ClearAllPoints()
	trainerCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 20, y + 2)
	trainerCheck:SetChecked(DB().apTrainer)
	y = y - 24
	sc:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y)
	curProf, curRank = cur, cur and lines[cur].rank
	FillRows()
end

-- the visible rows of the current list from the scroll offset
FillRows = function()
	local cur, rank = curProf, curRank
	if not cur then
		for _, r in ipairs(rows) do r:Hide() end
		return
	end
	local db = DB()
	local _, editSi = CP.Editing()
	local list = List(cur, rank)
	-- how many rows fit at the very end of the list: the scroll range stops so that the last screen is full
	local area = sc:GetHeight()
	if list.fitArea ~= area then
		local fitLast, acc = 0, 0
		for j = #list, 1, -1 do
			acc = acc + RowHeight(list[j].rec)
			if acc > area then break end
			fitLast = fitLast + 1
		end
		list.fitArea, list.fitLast = area, fitLast
	end
	FauxScrollFrame_Update(sc, #list, math.max(1, list.fitLast), STEP)
	local offset = FauxScrollFrame_GetOffset(sc)
	local shown, ry = 0, 0
	for i = 1, #list - offset do
		local h = RowHeight(list[offset + i].rec)
		if ry + h > area and i > 1 then break end
		shown = i
		local r = Row(i)
		local d = list[offset + i]
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -ry)
		r:SetPoint("RIGHT", sc, "RIGHT", 0, 0)
		r:SetHeight(h)
		ry = ry + h
		r.data = d
		if d then
			local rec = d.rec
			local locked = not d.known and d.req and d.req > rank
			local hex = locked and "|cffff4040" or CP.KIND_HEX[d.kind]
			r.icon:SetTexture(CP.ItemIcon(rec.item > 0 and rec.item or nil))
			r.icon:SetDesaturated(not d.known)
			r.icon:SetAlpha(d.known and 1 or 0.6)
			r.name:SetText(hex .. rec.name .. "|r")
			local li = not d.known and CP.LearnInfo(rec.sk, d.prof, rec.name)
			r.price:SetText((li and li.at and li.cost > 0) and CP.Money(li.cost) or "")
			-- learn skill (not for grey), gain
			local mid = math.floor((rec.y + rec.g) / 2)
			local from = math.max(rank, d.req or 0)
			r.req:SetText((d.req and d.kind ~= "trivial") and ((locked and "|cffff6060" or (d.known and "|cff9a9a9a" or "|cffcccccc")) .. d.req .. "|r") or "")
			local set = KSET[db.apKind or "skill"]
			local o = (d.kind == "optimal" or locked) and rec.y > from and ("|cffff8040+" .. (rec.y - from) .. "|r") or nil
			if o and set:find("o", 1, true) then
				r.gain:SetText("")
				r.gain2:SetText(o)
			else
				local ys = set:find("y", 1, true) and Span(rec, from, rec.y, mid)
				local gs = set:find("g", 1, true) and Span(rec, from, mid, rec.g)
				if ys and gs then
					r.gain:SetText("|cffffff00" .. ys .. "|r")
					r.gain2:SetText("|cff40c040" .. gs .. "|r")
				else
					r.gain:SetText("")
					r.gain2:SetText((ys and ("|cffffff00" .. ys .. "|r")) or (gs and ("|cff40c040" .. gs .. "|r")) or "")
				end
			end
			-- icon: learned / can learn / too early / unknown
			local kind
			if d.known then kind = "ok"
			elseif locked then kind = "lock"
			elseif d.req or rec.y <= rank then kind = "book"
			else kind = "question" end
			r.status:SetTexture(W.TEX[kind])
			r.status:SetDesaturated(kind == "lock" or kind == "question")
			if kind == "book" then r.status:SetTexCoord(0.08, 0.92, 0.08, 0.92) else r.status:SetTexCoord(0, 1, 0, 1) end
			-- reagents
			for k = 1, 6 do
				local rg, slot = rec.reag[k], r.rg[k]
				if rg then
					local have = CP.Have(rg.id)
					slot.t:SetTexture(CP.ItemIcon(rg.id))
					slot.fs:SetText(((have >= rg.count) and "|cff40ff40" or "|cffff6060") .. have .. "/" .. rg.count .. "|r" .. ((k == 6 and #rec.reag > 6) and (" |cff999999+" .. (#rec.reag - 6) .. "|r") or ""))
					slot.t:Show(); slot.fs:Show()
					slot.b.id, slot.b.need = rg.id, rg.count
					slot.b:Show()
				else
					slot.t:Hide(); slot.fs:Hide(); slot.b:Hide()
				end
			end
			if editSi then
				r.count:SetText(d.count > 0 and ("|cffffd200" .. d.count .. "|r") or "|cff5555550|r")
				r.plus:Show()
				if d.count > 0 then r.minus:Show(); r.remove:Show() else r.minus:Hide(); r.remove:Hide() end
			else
				r.count:SetText("")
				r.plus:Hide()
				r.minus:Hide()
				r.remove:Hide()
			end
			d.inStack = CP.StacksWith(rec.sk, rec.name)
			if d.inStack then r.inStack:Show() else r.inStack:Hide() end
			r:Show()
		else
			r:Hide()
		end
	end
	for i = shown + 1, #rows do rows[i]:Hide() end
end

local function Highlight(on)
	if CP.recipesBtn then
		if on then CP.recipesBtn:LockHighlight() else CP.recipesBtn:UnlockHighlight() end
	end
end
function CP.ToggleRecipes(on)
	if on == nil then on = not f:IsShown() end
	DB().apOpen = on or nil
	if on then
		if not CP.win:IsShown() then
			CP.ToggleWindow() -- opens this panel too (OnWindowShow) and redraws both
		else
			f:Show()
			CP.RefreshRecipes()
		end
	else
		f:Hide()
	end
	Highlight(on)
end
-- the window is being opened (CP.ToggleWindow redraws right after): only show the panel
CP.OnWindowShow = function()
	if DB().apOpen then
		f:Show()
		Highlight(true)
	end
end
