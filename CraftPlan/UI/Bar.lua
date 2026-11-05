-- CraftPlan 2.0 — полоса вверху экрана: значок окна с процентом собранного по стекам и рецепты стеков,
-- которые можно создать из того, что есть (или, с «На полосе только сырьё», недостающее сырьё «есть/нужно»).
local CP = CraftPlan
local W = CP.W
local DB = CP.DB

local SIZE, GAP, MAX = 32, 6, 14

local bar = CreateFrame("Frame", "CraftPlanBar", UIParent)
bar:SetWidth(SIZE)
bar:SetHeight(SIZE + 14)
bar:SetPoint("TOP", UIParent, "TOP", 0, -12)
bar:SetMovable(true)
bar:EnableMouse(false)
bar:SetClampedToScreen(true)

-- Ctrl+перетаскивание любого значка — передвинуть полосу; место запоминается
local function DragStart() if IsControlKeyDown() then bar:StartMoving() end end
local function DragStop()
	bar:StopMovingOrSizing()
	local p, _, rp, x, y = bar:GetPoint()
	DB().barPos = { p, rp, x, y }
end
CP.BarDragStart, CP.BarDragStop = DragStart, DragStop

local function Button(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(SIZE)
	b:SetHeight(SIZE)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", DragStart)
	b:SetScript("OnDragStop", DragStop)
	b.tex = b:CreateTexture(nil, "ARTWORK")
	b.tex:SetAllPoints(b)
	b.border = b:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	b.border:SetBlendMode("ADD")
	b.border:SetWidth(SIZE * 1.8)
	b.border:SetHeight(SIZE * 1.8)
	b.border:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
	-- под значком сырья — процент собранного
	b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.sub:SetPoint("TOP", b, "BOTTOM", 0, -1)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnEnter", W.TipEnter)
	b:SetScript("OnLeave", W.TipLeave)
	b:SetScript("OnClick", function(self, button)
		if button == "RightButton" and self.rightAction then self.rightAction() return end
		if self.action then self.action() end
	end)
	return b
end

-- значок окна
local mapBtn = Button(bar)
mapBtn:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
mapBtn.tex:SetTexture("Interface\\Icons\\INV_Misc_Note_06")
mapBtn.border:Hide()
mapBtn.percent = mapBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
mapBtn.percent:SetPoint("TOP", mapBtn, "BOTTOM", 0, -1)
mapBtn.action = function() CP.ToggleWindow() end
mapBtn.title = "CraftPlan"
CP.mapButton = mapBtn

local icons = {}
local collapsed

local collapse = CreateFrame("Button", nil, bar)
collapse:SetWidth(20)
collapse:SetHeight(20)
collapse:SetScript("OnClick", function() CP.ToggleCollapsed() end)
collapse:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:AddLine(collapsed and "Развернуть полосу" or "Свернуть полосу")
	GameTooltip:Show()
end)
collapse:SetScript("OnLeave", W.TipLeave)

function CP.ToggleCollapsed()
	local db = DB()
	db.collapsed = not db.collapsed or nil
	if CP.ProspectUpdate then CP.ProspectUpdate() end -- кнопка «Просеивание» сворачивается вместе с полосой
	CP.RefreshBar()
end

function CP.RefreshBar()
	local db = DB()
	collapsed = db.collapsed
	local data = CP.Compute()
	local all = CP.Merge(data.trees, data.order)
	-- процент собранного по всем стекам: есть / (есть + не хватает) по сырью
	local hv, sh = 0, 0
	for _, id in ipairs(all.ord) do
		local n = all.nodes[id]
		if n.made == 0 then hv, sh = hv + math.min(n.have, n.gross), sh + n.short end
	end
	if hv + sh > 0 then
		local pct = math.floor(hv / (hv + sh) * 100)
		local col = pct >= 100 and "|cff40ff40" or (pct >= 50 and "|cffffd200" or "|cffff6060")
		mapBtn.percent:SetText(col .. pct .. "%|r")
		mapBtn.lines = { "Собрано материалов на все стеки: " .. pct .. "% (не хватает " .. sh .. " шт.).", "Щелчок — окно, Ctrl+перетаскивание — передвинуть полосу." }
	else
		mapBtn.percent:SetText("")
		mapBtn.lines = { "Щелчок — окно, Ctrl+перетаскивание — передвинуть полосу." }
	end
	-- значки
	local list = {}
	if not collapsed then
		if db.rawOnly then
			for _, id in ipairs(all.ord) do
				local n = all.nodes[id]
				if n.made == 0 and n.short > 0 then list[#list + 1] = { tex = CP.ItemIcon(id), count = "",
					pct = math.min(1, n.have / math.max(1, n.gross)), border = { 1, 0.3, 0.3 },
					link = "item:" .. id, lines = { "Есть " .. n.have .. " из " .. n.gross .. ". Правый щелчок — метки на карте." },
					right = function() if WhereToGet_ShowItem then WhereToGet_ShowItem(id) end end } end
			end
		else
			for _, si in ipairs(data.order) do
				for _, x in ipairs(data.trees[si].ents) do
					local can = x.e.n
					for _, rg in ipairs(x.rec.reag) do can = math.min(can, math.floor(CP.Have(rg.id) / rg.count)) end
					local known = CP.KnownRecipe(x.prof, x.rec.name)
					if can > 0 and known then
						local L = data.lines[x.prof]
						local kind = L and CP.KindAt(x.rec.y, x.rec.g, L.rank) or "trivial"
						list[#list + 1] = { tex = CP.ItemIcon(x.rec.item > 0 and x.rec.item or nil), count = can, border = CP.KIND_COLOR[kind],
							link = x.rec.item > 0 and ("item:" .. x.rec.item) or nil,
							lines = { x.prof .. ": можно создать " .. can .. " из " .. x.e.n .. ". Щелчок — выбрать в окне профессии." },
							action = function() CP.SelectRecipe(x.prof, x.rec.name, can) end }
					end
				end
			end
		end
	end
	local x = SIZE + GAP
	-- справа от значка окна — кнопка «Просеивание» (Prospect.lua), если показана
	if CP.prospectFrame and CP.prospectFrame:IsShown() then x = x + SIZE + GAP end
	for i = 1, math.min(MAX, #list) do
		local b = icons[i] or Button(bar)
		icons[i] = b
		local it = list[i]
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
		b.tex:SetTexture(it.tex)
		b.border:SetVertexColor(it.border[1], it.border[2], it.border[3])
		b.border:Show()
		b.count:SetText(it.count)
		if it.pct then
			local p = it.pct -- красный (0%) -> жёлтый (50%) -> зелёный (100%)
			b.sub:SetText(math.floor(p * 100) .. "%")
			b.sub:SetTextColor(p < 0.5 and 1 or 2 * (1 - p), p < 0.5 and 2 * p or 1, 0.25)
		else
			b.sub:SetText("")
		end
		b.link, b.lines, b.action, b.rightAction, b.title = it.link, it.lines, it.action, it.right, nil
		b:Show()
		x = x + SIZE + GAP
	end
	for i = math.min(MAX, #list) + 1, #icons do icons[i]:Hide() end
	collapse:ClearAllPoints()
	collapse:SetPoint("LEFT", bar, "TOPLEFT", x - GAP + 4, -SIZE / 2)
	collapse:SetNormalTexture(collapsed and "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up" or "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
	if #list == 0 and not collapsed then collapse:Hide() else collapse:Show() end
	bar:SetWidth(x + 20)
end
CP.OnChange(CP.RefreshBar)

CP.OnLogin = function()
	local db = DB()
	if db.barPos then
		bar:ClearAllPoints()
		bar:SetPoint(db.barPos[1], UIParent, db.barPos[2], db.barPos[3], db.barPos[4])
	end
end
