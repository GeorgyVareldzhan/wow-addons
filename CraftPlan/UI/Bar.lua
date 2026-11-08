-- CraftPlan 2.0 — bar at the top of the screen: window icon with the % gathered for the stacks, and stack recipes
-- that can be crafted from what you have (or, with "На полосе только сырьё", the missing raw materials;
-- for a jeweler, gems that allowed ore gives are replaced by that ore).
local CP = CraftPlan
local W = CP.W
local DB = CP.DB

local SIZE, GAP, MAX = 32, 6, 14
local GREEN, RED = { 0.3, 1, 0.3 }, { 1, 0.3, 0.3 }

local bar = CreateFrame("Frame", "CraftPlanBar", UIParent)
bar:SetWidth(SIZE)
bar:SetHeight(SIZE + 14)
bar:SetPoint("TOP", UIParent, "TOP", 0, -12)
bar:SetMovable(true)
bar:EnableMouse(false)
bar:SetClampedToScreen(true)

-- Ctrl+drag any icon to move the bar; the position is remembered
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
	-- under a raw material icon — the percentage gathered
	b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.sub:SetPoint("TOP", b, "BOTTOM", 0, -1)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnEnter", W.TipEnter)
	b:SetScript("OnLeave", W.TipLeave)
	b:SetScript("OnClick", W.OnClick) -- action; right click: rightAction or .where (item id: where to get)
	return b
end

-- window icon
local mapBtn = Button(bar)
mapBtn:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
mapBtn.tex:SetTexture("Interface\\Icons\\Trade_BlackSmithing")
mapBtn.border:Hide()
mapBtn.percent = mapBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
mapBtn.percent:SetPoint("TOP", mapBtn, "BOTTOM", 0, -1)
mapBtn.action = function() CP.ToggleWindow() end
mapBtn.title = "CraftPlan"
CP.mapButton = mapBtn

-- "У учителя": stack recipes you can learn now and a new profession rank; new ones also go to the chat
local remindBtn = Button(bar)
remindBtn.tex:SetTexture("Interface\\Icons\\INV_Misc_Book_11")
remindBtn.border:SetVertexColor(0.3, 1, 0.3)
remindBtn.title = "У учителя"
remindBtn:Hide()
-- computed once per change (CP.DropCache clears it): { list = tooltip lines, n, profs, news = { { key, text } } };
-- the chat notification is a separate listener (Notify), the bar only shows the result
local remindSeen, remindFirst = {}, true
local remindMemo
CP.OnDrop(function() remindMemo = nil end)
local function Reminders()
	if remindMemo then return remindMemo end
	local data = CP.Compute()
	local lines, db = CP.SkillLines(), DB()
	local byProf, profs = {}, {}
	local function E(prof)
		if not byProf[prof] then byProf[prof] = { prof = prof, recs = {} }; profs[#profs + 1] = prof end
		return byProf[prof]
	end
	-- a new rank: the skill is 25 below the cap and the cap is not the last one
	for prof in pairs(CP.SKILL_ID) do
		local L = lines[prof]
		if L and L.max > 0 and L.max < 450 and L.rank >= L.max - 25 then E(prof).up = L.max + 75 end
	end
	-- stack recipes learned at the trainer, not learned yet, skill enough (known only for scanned professions)
	local seen = {}
	for _, si in ipairs(data.order) do
		for _, x in ipairs(data.trees[si].ents) do
			local prof, name = x.prof, x.rec.name
			local sk, L = CP.SKILL_ID[prof], lines[prof]
			local t = sk and db.learn and db.learn[sk] and db.learn[sk][name]
			if t and L and not t.used and not seen[prof .. "|" .. name] and db.profs[prof] and not CP.KnownRecipe(prof, name)
				and (t.req or 0) <= L.rank then
				seen[prof .. "|" .. name] = true
				local e = E(prof)
				e.recs[#e.recs + 1] = name
			end
		end
	end
	table.sort(profs)
	local list, news, n = {}, {}, 0
	for _, prof in ipairs(profs) do
		local e = byProf[prof]
		local parts = {}
		if e.recs[1] then parts[#parts + 1] = table.concat(e.recs, ", ") end
		if e.up then parts[#parts + 1] = "новый ранг, до " .. e.up end
		list[#list + 1] = CP.ProfText(prof) .. ": " .. table.concat(parts, "; ")
		n = n + #e.recs + (e.up and 1 or 0)
		for _, name in ipairs(e.recs) do
			news[#news + 1] = { key = prof .. "|" .. name, text = CP.ProfText(prof) .. ": можно выучить «" .. name .. "»" }
		end
		if e.up then
			news[#news + 1] = { key = prof .. "|rank" .. e.up, text = CP.ProfText(prof) .. ": можно выучить новый ранг, до " .. e.up }
		end
	end
	remindMemo = { list = list, n = n, profs = profs, news = news }
	return remindMemo
end
-- to the chat: on login everything waiting in one line, later only what is new
local function Notify()
	local msgs = {}
	for _, m in ipairs(Reminders().news) do
		if not remindSeen[m.key] then remindSeen[m.key] = true; msgs[#msgs + 1] = m.text end
	end
	if msgs[1] then
		if remindFirst then CP.Print("у учителя ждёт: " .. table.concat(msgs, "; "))
		else for _, m in ipairs(msgs) do CP.Print(m) end end
		remindFirst = false
	end
end
CP.OnChange(Notify)
-- click: trainers of these professions on the map (Questie; your faction), again — remove
local remindProfs = {}
remindBtn.action = function()
	if not CraftPlan_Trainers then CP.Print("список учителей появится после перезапуска клиента.") return end
	if not WhereToGet_ShowNPCs then return end
	local fac = UnitFactionGroup("player")
	fac = fac == "Alliance" and "A" or (fac == "Horde" and "H" or nil)
	local npcs, names = {}, {}
	for _, prof in ipairs(remindProfs) do
		local t = CraftPlan_Trainers[CP.SKILL_ID[prof]] or {}
		for i = 1, #t, 2 do
			local f = t[i + 1]
			if not fac or f == "" or f == "AH" or f == fac then npcs[#npcs + 1] = t[i] end
		end
		names[#names + 1] = CP.ProfText(prof)
	end
	if npcs[1] then WhereToGet_ShowNPCs("trainers", npcs, "Учителя (" .. table.concat(names, ", ") .. ")") end
end

-- "Дальше": compass icon; on hover a column with the next step of each stack (click — select it in the profession window)
local nextBtn = Button(bar)
nextBtn.tex:SetTexture("Interface\\Icons\\Ability_Hunter_Pathfinding")
nextBtn.border:Hide()
nextBtn:Hide()
local fly = CreateFrame("Frame", nil, nextBtn)
fly:SetPoint("TOP", nextBtn, "BOTTOM", 0, -4)
fly:SetWidth(SIZE)
fly:Hide()
local flyRows = {}
local function FlyRow(i)
	local r = flyRows[i]
	if r then return r end
	r = Button(fly)
	r:SetPoint("TOPLEFT", fly, "TOPLEFT", 0, -(i - 1) * (SIZE + 4))
	r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.label:SetPoint("LEFT", r, "RIGHT", 6, 0)
	r.border:Hide()
	flyRows[i] = r
	return r
end
nextBtn:HookScript("OnEnter", function() if flyRows[1] and flyRows[1]:IsShown() then fly:Show() end end)
fly:SetScript("OnUpdate", function(self, elapsed)
	if MouseIsOver(nextBtn) or MouseIsOver(self) then
		self.away = 0
	else
		self.away = (self.away or 0) + elapsed
		if self.away > 0.3 then self.away = 0; self:Hide() end
	end
end)
local function Up(v) return math.ceil(v - 1e-9) end
local function StepText(st) return st.rec.name .. " x" .. st.n .. " (" .. Up(st.from) .. " - " .. Up(st.to) .. ")" end
local function StepPick(st) return function() CP.SelectRecipe(st.prof, st.rec.name, st.n) end end
local function RefreshNext(data, show)
	local first = show and CP.Steps(data)[1]
	if not first then nextBtn:Hide(); fly:Hide(); return false end
	nextBtn.title = "Дальше: " .. StepText(first)
	nextBtn.lines = { "Наведите — следующее по каждому стеку. Щелчок — выбрать в окне профессии." }
	nextBtn.action = StepPick(first)
	local n = 0
	local bySi = W.StepsBy(data, function(l) return l.si end) -- steps of each stack, one pass over the log
	for _, si in ipairs(data.order) do
		local st = bySi[si] and bySi[si][1]
		if st then
			n = n + 1
			local r = FlyRow(n)
			r.tex:SetTexture(CP.ItemIcon(st.rec.item > 0 and st.rec.item or nil))
			r.count:SetText(st.n)
			r.label:SetText("Стек " .. CP.StackNum(si))
			r.title = "Стек " .. CP.StackNum(si) .. ": " .. StepText(st)
			r.lines = { "Щелчок — выбрать в окне профессии." }
			r.link = st.rec.item > 0 and ("item:" .. st.rec.item) or nil
			r.action = StepPick(st)
			r:Show()
		end
	end
	for i = n + 1, #flyRows do flyRows[i]:Hide() end
	fly:SetHeight(math.max(1, n * (SIZE + 4)))
	nextBtn:Show()
	return true
end

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
	CP.RefreshBar()
	if CP.ProspectUpdate then CP.ProspectUpdate() end -- the prospecting button collapses together with the bar
end

function CP.RefreshBar()
	local db = DB()
	collapsed = db.collapsed
	local data = CP.Compute()
	local all = CP.MergedAll()
	-- percentage gathered for all stacks: have / (have + missing) over raw materials
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
	-- icons
	local list = {}
	if not collapsed then
		if db.rawOnly then
			-- jeweler: missing gems that the allowed ore gives -> that ore (highest chance), total for all stacks
			local skip = {}
			if CP.CanProspect and CP.CanProspect() then
				local gems = {}
				for _, id in ipairs(all.ord) do
					local n = all.nodes[id]
					if n.made == 0 and n.short > 0 and CP.ProspectTopOre(id, true) then gems[#gems + 1] = n end
				end
				for _, c in ipairs(CP.ProspectPlan(gems, true)) do
					local ore = c.ore
					local craft = all.nodes[ore] and all.nodes[ore].gross or 0
					local need, have = craft + c.need, CP.Have(ore)
					local names = {}
					for _, n in ipairs(c.gems) do names[#names + 1] = CP.ItemName(n.id); skip[n.id] = true end
					skip[ore] = true
					local lines = { "Есть " .. have .. " из " .. need .. ".", "Просеять " .. c.need .. ": " .. table.concat(names, ", ") }
					local veins = CP.VeinsFor and CP.VeinsFor(ore, need - have)
					if veins then lines[#lines + 1] = "Жил обойти: около " .. veins end
					if craft > 0 then lines[#lines + 1] = "На крафт: " .. craft end
					lines[#lines + 1] = "Правый щелчок — метки на карте."
					list[#list + 1] = { tex = CP.ItemIcon(ore), count = veins or "", pct = math.min(1, have / math.max(1, need)),
						border = have >= need and GREEN or RED, link = "item:" .. ore, lines = lines, where = ore }
				end
			end
			for _, id in ipairs(all.ord) do
				local n = all.nodes[id]
				local veins = n.made == 0 and n.short > 0 and CP.VeinsFor and CP.VeinsFor(id, n.short)
				if n.made == 0 and n.short > 0 and not skip[id] then list[#list + 1] = { tex = CP.ItemIcon(id), count = veins or "",
					pct = math.min(1, n.have / math.max(1, n.gross)), border = RED,
					link = "item:" .. id, lines = { "Есть " .. n.have .. " из " .. n.gross .. "." .. (veins and (" Жил обойти: около " .. veins .. ".") or ""), "Правый щелчок — метки на карте." },
					where = id } end
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
	-- right of the window icon — the prospecting button (Prospect.lua), if shown
	if CP.prospectFrame and CP.prospectFrame:IsShown() then x = x + SIZE + GAP end
	-- "У учителя" (also when collapsed)
	local rem = Reminders()
	local rl, rn = rem.list, rem.n
	remindProfs = rem.profs
	if rn > 0 then
		remindBtn:ClearAllPoints()
		remindBtn:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
		remindBtn.count:SetText(rn)
		local tl = {}
		for i, l in ipairs(rl) do tl[i] = l end
		tl[#tl + 1] = "Щелчок — учителя на карте."
		remindBtn.lines = tl
		remindBtn:Show()
		x = x + SIZE + GAP
	else
		remindBtn:Hide()
	end
	-- then "Дальше" (not with "only raw materials" and not when collapsed)
	if RefreshNext(data, not collapsed and not db.rawOnly) then
		nextBtn:ClearAllPoints()
		nextBtn:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
		x = x + SIZE + GAP
	end
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
			local p = it.pct -- red (0%) -> yellow (50%) -> green (100%)
			b.sub:SetText(math.floor(p * 100) .. "%")
			b.sub:SetTextColor(p < 0.5 and 1 or 2 * (1 - p), p < 0.5 and 2 * p or 1, 0.25)
		else
			b.sub:SetText("")
		end
		b.link, b.lines, b.action, b.where, b.title = it.link, it.lines, it.action, it.where, nil
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
