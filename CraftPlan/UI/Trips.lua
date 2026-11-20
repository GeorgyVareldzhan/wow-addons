-- CraftPlan — окно «Поездки» справа от главного (на месте «Все рецепты», одно из двух): журнал
-- поездок за рудой из MapPlus (MapPlusDB.trips). Сверху список (по жилам в час), снизу выбранная:
-- время всего и в движении, жилы, руда, руда в час, все предметы из жил. Без MapPlus кнопки нет.
local CP = CraftPlan
local W = CP.W

local PW = 440
local ROWH = 18
local NROWS = 10   -- строк списка
local NITEMS = 14  -- строк предметов

local f = CreateFrame("Frame", "CraftPlanTrips", CP.win)
f:SetWidth(PW)
f:SetPoint("TOPLEFT", CP.win, "TOPRIGHT", -4, 0)
f:SetPoint("BOTTOMLEFT", CP.win, "BOTTOMRIGHT", -4, 0)
W.Backdrop(f)
f:EnableMouse(true)
f:Hide()

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -18)
title:SetText("Поездки")
local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

local function Trips()
	local t = MapPlusDB and MapPlusDB.trips
	return type(t) == "table" and t or {}
end

local function HMS(sec)
	sec = math.floor(sec or 0)
	return string.format("%d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

local function PerHour(t)
	if (t.moving or 0) < 60 then return nil end
	return math.floor((t.ore or 0) * 3600 / t.moving + 0.5)
end

-- жил в час (по времени в движении); меньше минуты — нет
local function VeinsPerHour(t)
	if (t.moving or 0) < 60 then return nil end
	return math.floor((t.veins or 0) * 3600 / t.moving + 0.5)
end

-- журнал по жилам в час, лучшие первыми; без оценки (меньше минуты) — в конце, новые первыми
local function Sorted()
	local src, list = Trips(), {}
	for i = 1, #src do list[i] = src[i] end
	table.sort(list, function(a, b)
		local va, vb = VeinsPerHour(a), VeinsPerHour(b)
		if va and vb and va ~= vb then return va > vb end
		if (va == nil) ~= (vb == nil) then return va ~= nil end
		return (a.start or 0) > (b.start or 0)
	end)
	return list
end

local sel -- выбранная поездка (таблица из журнала)
local Refresh

----------------------------------------------------------------------------------------------
-- список
local sc = CreateFrame("ScrollFrame", "CraftPlanTripsScroll", f, "FauxScrollFrameTemplate")
sc:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -46)
sc:SetWidth(PW - 52)
sc:SetHeight(NROWS * ROWH)
sc:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, ROWH, function() Refresh() end) end)

local rows = {}
for i = 1, NROWS do
	local r = CreateFrame("Button", nil, f)
	r:SetHeight(ROWH)
	r:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, -(i - 1) * ROWH)
	r:SetPoint("RIGHT", sc, "RIGHT", 0, 0)
	r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	r.sel = r:CreateTexture(nil, "BACKGROUND")
	r.sel:SetAllPoints(r)
	r.sel:SetTexture(W.WHITE)
	r.sel:SetVertexColor(1, 0.82, 0, 0.15)
	r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.left:SetPoint("LEFT", r, "LEFT", 4, 0)
	r.left:SetJustifyH("LEFT")
	r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.right:SetPoint("RIGHT", r, "RIGHT", -4, 0)
	r.right:SetJustifyH("RIGHT")
	r.left:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
	r:SetScript("OnClick", function(self) sel = self.trip; Refresh() end)
	r:SetScript("OnEnter", function(self)
		local t = self.trip
		if not (t and t.route) then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(t.route)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	rows[i] = r
end

----------------------------------------------------------------------------------------------
-- выбранная поездка
local head = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
head:SetPoint("TOPLEFT", sc, "BOTTOMLEFT", 2, -14)
head:SetPoint("RIGHT", f, "RIGHT", -20, 0)
head:SetJustifyH("LEFT")
local sum = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sum:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -6)
sum:SetPoint("RIGHT", f, "RIGHT", -20, 0)
sum:SetJustifyH("LEFT")

local items = {}
for i = 1, NITEMS do
	local r = CreateFrame("Frame", nil, f)
	r:SetHeight(16)
	r:SetPoint("TOPLEFT", sum, "BOTTOMLEFT", 0, -8 - (i - 1) * 17)
	r:SetPoint("RIGHT", f, "RIGHT", -20, 0)
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetWidth(16)
	r.icon:SetHeight(16)
	r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
	r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
	r.name:SetJustifyH("LEFT")
	r.n = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.n:SetPoint("RIGHT", r, "RIGHT", 0, 0)
	items[i] = r
end
local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
empty:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, -4)
empty:SetText("Поездок пока нет")

Refresh = function()
	if not f:IsShown() then return end
	local list = Sorted()
	local n = #list
	FauxScrollFrame_Update(sc, n, NROWS, ROWH)
	local off = FauxScrollFrame_GetOffset(sc)
	local found = false
	for i = 1, n do if list[i] == sel then found = true end end
	if not found then sel = list[1] end
	for i = 1, NROWS do
		local r = rows[i]
		local t = list[off + i]
		if t then
			r.trip = t
			r.left:SetText(string.format("%s - %s  %s", date("%d.%m %H:%M", t.start or 0), date("%H:%M", t.finish or 0), t.zone or "?"))
			local vh = VeinsPerHour(t)
			r.right:SetText(string.format("%d жил%s, %d руды", t.veins or 0, vh and (" (" .. vh .. "/ч)") or "", t.ore or 0))
			if t == sel then r.sel:Show() else r.sel:Hide() end
			r:Show()
		else
			r.trip = nil
			r:Hide()
		end
	end
	if n == 0 then empty:Show() else empty:Hide() end
	local t = sel
	if not t then
		head:SetText("")
		sum:SetText("")
		for i = 1, NITEMS do items[i]:Hide() end
		return
	end
	head:SetText((t.zone or "?") .. (t.route and (": " .. t.route) or ""))
	local ph = PerHour(t)
	sum:SetText(string.format("%s - %s, всего %s, в движении %s\nЖил %d, руды %d%s",
		date("%d.%m %H:%M", t.start or 0), date("%H:%M", t.finish or 0),
		HMS((t.finish or 0) - (t.start or 0)), HMS(t.moving), t.veins or 0, t.ore or 0,
		ph and (string.format(", в час: жил %d, руды %d", VeinsPerHour(t), ph)) or "")
		.. (t.pts and string.format("\nТочек %d из %d (%d%%), жила на месте %d из %d (%d%%)", t.prog or t.passed or 0, t.pts,
			math.floor((t.prog or t.passed or 0) * 100 / t.pts), t.found or 0, t.passed or 0,
			(t.passed or 0) > 0 and math.floor((t.found or 0) * 100 / t.passed) or 0) or ""))
	local its = {}
	for name, cnt in pairs(t.items or {}) do its[#its + 1] = { name, cnt } end
	table.sort(its, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
	for i = 1, NITEMS do
		local r, it = items[i], its[i]
		if it and i == NITEMS and #its > NITEMS then
			r.icon:SetTexture(nil)
			r.name:SetText(string.format("и ещё %d", #its - NITEMS + 1))
			r.n:SetText("")
			r:Show()
		elseif it then
			local _, link, _, _, _, _, _, _, _, tex = GetItemInfo(it[1])
			r.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
			r.name:SetText(link or it[1])
			r.n:SetText(it[2])
			r:Show()
		else
			r:Hide()
		end
	end
end

-- пока окно открыто — текущая поездка идёт, раз в 2 с перерисовать
local acc = 0
f:SetScript("OnUpdate", function(_, el)
	acc = acc + el
	if acc >= 2 then acc = 0; Refresh() end
end)

----------------------------------------------------------------------------------------------
-- кнопка в заголовке, слева от «Все рецепты»; окно — одно из двух справа
local btn = CreateFrame("Button", nil, CP.win, "UIPanelButtonTemplate")
btn:SetText("Поездки")
btn:SetWidth(80)
btn:SetHeight(22)
btn:SetPoint("RIGHT", CP.recipesBtn, "LEFT", -4, 0)

local function Toggle(on)
	if on == nil then on = not f:IsShown() end
	if on then
		if CP.ToggleRecipes then CP.ToggleRecipes(false) end
		f:Show()
		btn:LockHighlight()
		Refresh()
	else
		f:Hide()
		btn:UnlockHighlight()
	end
end
btn:SetScript("OnClick", function() Toggle() end)
close:SetScript("OnClick", function() Toggle(false) end)
hooksecurefunc(CP, "ToggleRecipes", function(on)
	if on ~= false and f:IsShown() then Toggle(false) end
end)

-- кнопка — только если журнал MapPlus есть
CP.win:HookScript("OnShow", function()
	if MapPlusDB or IsAddOnLoaded("MapPlus") then btn:Show() else btn:Hide(); Toggle(false) end
end)
