-- CraftPlan 2.0 — hooks into game windows: "- N +" in profession and trainer rows, "+" at vendors
-- on recipe items, Shift+click on an item (into the stack being edited), a line in the item tooltip.
local CP = CraftPlan

local function Tip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("CraftPlan — стек")
	GameTooltip:AddLine(self.tipText, 1, 1, 1, true)
	GameTooltip:Show()
end
local function Add(prof, name, delta)
	local rec = CP.FindByName(prof, name)
	if not rec then
		CP.Print("«" .. name .. "» нет в данных рецептов CraftPlan — в стек не добавить.")
		return
	end
	CP.Bump(rec.sk, rec.name, delta)
end
local function CountOf(prof, name)
	local rec = CP.FindByName(prof, name)
	return rec and CP.CountIn(rec.sk, rec.name) or 0
end
local function MiniBtn(parent, tex, tipText)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(16)
	b:SetHeight(16)
	b:SetNormalTexture("Interface\\Buttons\\UI-" .. tex .. "Button-Up")
	b:SetPushedTexture("Interface\\Buttons\\UI-" .. tex .. "Button-Down")
	b:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
	b.tipText = tipText
	b:SetScript("OnEnter", Tip)
	return b
end

-- "- N +" right in the recipe list row, shown on row hover when a stack is being edited
local function RowPlus(prefix, count, prof, info)
	for i = 1, count do
		local row = _G[prefix .. i]
		if row and not row.cpPlus then
			local box = CreateFrame("Frame", nil, row)
			box:SetWidth(60)
			box:SetHeight(16)
			box:SetPoint("RIGHT", row, "RIGHT", -2, 0)
			box:SetFrameLevel(row:GetFrameLevel() + 3)
			box:Hide()
			local plus = MiniBtn(box, "Plus", "В стек на правке / ещё 1 (Shift — 10).")
			plus:SetPoint("RIGHT", box, "RIGHT", 0, 0)
			local num = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			num:SetPoint("RIGHT", plus, "LEFT", -2, 0)
			local minus = MiniBtn(box, "Minus", "Меньше на 1 (Shift — 10); до нуля — убрать из стека.")
			minus:SetPoint("RIGHT", num, "LEFT", -2, 0)
			local function Name()
				local id = row:GetID()
				return id and id > 0 and info(id), id
			end
			local function Update()
				local name, id = Name()
				local n = name and CountOf(prof(id), name) or 0
				num:SetText(n > 0 and ("|cffffd200" .. n .. "|r") or "")
				if n > 0 then minus:Show() else minus:Hide() end
			end
			local function Leave()
				GameTooltip:Hide()
				if not row:IsMouseOver() then box:Hide() end
			end
			local function Click(delta)
				local ok, err = pcall(function()
					local name, id = Name()
					if name then Add(prof(id), name, delta) end
					Update()
				end)
				if not ok then CP.Print("ошибка: " .. tostring(err)) end
			end
			plus:SetScript("OnLeave", Leave)
			minus:SetScript("OnLeave", Leave)
			plus:SetScript("OnClick", function() Click(CP.W.Step()) end)
			minus:SetScript("OnClick", function() Click(-CP.W.Step()) end)
			row:HookScript("OnEnter", function()
				if CP.Editing() and Name() then
					pcall(Update)
					box:Show()
				end
			end)
			row:HookScript("OnLeave", function() if not row:IsMouseOver() then box:Hide() end end)
			row.cpPlus = box
		end
	end
end
-- green check on the left of the row: the recipe is in some stack (hover shows which)
-- state(id) (trainer only): "used" — learned (check), "available" — can learn now (book), "unavailable" — too early (lock)
local MARK_TEX = { used = "ok", available = "book", unavailable = "lock" }
local function MarkRows(prefix, count, prof, info, state)
	for i = 1, count do
		local row = _G[prefix .. i]
		if row then
			local m = row.cpMark
			if not m then
				m = CreateFrame("Frame", nil, row)
				m:SetWidth(14)
				m:SetHeight(14)
				m:SetPoint("LEFT", row, "LEFT", 2, 0) -- recipe rows are empty on the left (the "+" is only on headers)
				m:SetFrameLevel(row:GetFrameLevel() + 3)
				m:EnableMouse(true)
				m.tex = m:CreateTexture(nil, "OVERLAY")
				m.tex:SetAllPoints(m)
				m.tex:SetTexture(CP.W.TEX.ok)
				m:SetScript("OnEnter", Tip)
				m:SetScript("OnLeave", function() GameTooltip:Hide() end)
				row.cpMark = m
			end
			local id = row:IsShown() and row:GetID()
			local name = id and id > 0 and info(id)
			local rec = name and CP.FindByName(prof(id), name)
			local where = rec and CP.StacksWith(rec.sk, rec.name)
			m.tipText = where and ("В стеке: " .. where) or nil
			local kind = where and state and MARK_TEX[state(id)] or "ok"
			m.tex:SetTexture(CP.W.TEX[kind])
			if kind == "book" then m.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) else m.tex:SetTexCoord(0, 1, 0, 1) end
			m.tex:SetDesaturated(kind == "lock")
			if where and kind == "lock" and GetTrainerServiceSkillReq then
				local _, req = GetTrainerServiceSkillReq(id)
				local L = CP.SkillLines()[prof(id) or ""]
				if req then m.tipText = m.tipText .. "\nУчится с " .. req .. (L and (", у вас " .. L.rank) or "") end
			end
			if where then m:Show() else m:Hide() end
		end
	end
end
local function TSProf() return (GetTradeSkillLine()) end
local function TSInfo(id)
	local name, kind = GetTradeSkillInfo(id)
	if name and kind ~= "header" then return name end
end
local function TRProf(id) return GetTrainerServiceSkillLine and GetTrainerServiceSkillLine(id) end
local function TRInfo(id)
	local name, _, kind = GetTrainerServiceInfo(id)
	if name and kind ~= "header" then return name end
end
local function MarkTS() MarkRows("TradeSkillSkill", TRADE_SKILLS_DISPLAYED or 8, TSProf, TSInfo) end
local function TRState(id) return select(3, GetTrainerServiceInfo(id)) end
local function MarkTR() MarkRows("ClassTrainerSkill", CLASS_TRAINER_SKILLS_DISPLAYED or 11, TRProf, TRInfo, TRState) end
local hookedTS, hookedTR
local function TradeSkill()
	if not TradeSkillFrame then return end
	RowPlus("TradeSkillSkill", TRADE_SKILLS_DISPLAYED or 8, TSProf, TSInfo)
	if not hookedTS and TradeSkillFrame_Update then
		hookedTS = true
		hooksecurefunc("TradeSkillFrame_Update", function() pcall(MarkTS) end)
	end
	pcall(MarkTS)
end
local function Trainer()
	if not ClassTrainerFrame then return end
	RowPlus("ClassTrainerSkill", CLASS_TRAINER_SKILLS_DISPLAYED or 11, TRProf, TRInfo)
	if not hookedTR and ClassTrainerFrame_Update then
		hookedTR = true
		hooksecurefunc("ClassTrainerFrame_Update", function() pcall(MarkTR) end)
	end
	pcall(MarkTR)
end
-- stacks changed — refresh the checks in open windows
CP.OnChange(function()
	if TradeSkillFrame and TradeSkillFrame:IsShown() then pcall(MarkTS) end
	if ClassTrainerFrame and ClassTrainerFrame:IsShown() then pcall(MarkTR) end
end)
-- at vendors: "+" in the corner of a recipe item icon ("Чертеж: X" -> recipe X; "Формула чар для X: Y" -> "Чары для X - Y")
local function RecipeOf(link)
	local name = link and link:match("%[(.-)%]")
	return name and (CP.RecipeNameFromItem(name))
end
local function Merchant()
	for i = 1, MERCHANT_ITEMS_PER_PAGE or 10 do
		local item = _G["MerchantItem" .. i .. "ItemButton"]
		if item then
			local b = _G["CraftPlanStackM" .. i]
			if not b then
				b = CreateFrame("Button", "CraftPlanStackM" .. i, item)
				b:SetWidth(18)
				b:SetHeight(18)
				b:SetPoint("TOPRIGHT", item, "TOPRIGHT", 6, 6)
				b:SetFrameLevel(item:GetFrameLevel() + 3)
				b:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
				b:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
				b:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
				b.tipText = "Добавить рецепт в стек на правке."
				b:SetScript("OnEnter", Tip)
				b:SetScript("OnLeave", function() GameTooltip:Hide() end)
				b:SetScript("OnClick", function()
					local rec = RecipeOf(GetMerchantItemLink(item:GetID()))
					if rec then Add(nil, rec, 1) end
				end)
			end
			local link = CP.Editing() and MerchantFrame.selectedTab == 1 and item:IsShown() and GetMerchantItemLink(item:GetID())
			if RecipeOf(link) then b:Show() else b:Hide() end
		end
	end
end
if MerchantFrame_UpdateMerchantInfo then hooksecurefunc("MerchantFrame_UpdateMerchantInfo", function() pcall(Merchant) end) end
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED") -- the profession and trainer windows load on first open
f:RegisterEvent("TRADE_SKILL_SHOW")
f:RegisterEvent("TRAINER_SHOW")
f:RegisterEvent("MERCHANT_SHOW")
f:SetScript("OnEvent", function(_, ev)
	pcall(TradeSkill)
	pcall(Trainer)
	if ev == "MERCHANT_SHOW" then pcall(Merchant) end
end)

-- Shift+click on an item (bags, profession window, vendor) with the CraftPlan window open and a stack being edited:
-- a recipe item ("Чертеж: …") adds the recipe, anything else adds +1 material. The "split stack" window is closed after the click
local splitAt
hooksecurefunc("HandleModifiedItemClick", function(link)
	if not (link and IsModifiedClick("CHATLINK")) then return end
	if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return end -- chat is open — it's a chat link
	if not (CP.win and CP.win:IsShown() and CP.Editing()) then return end
	local item = CP.ItemOfLink(link)
	if not item then return end
	splitAt = GetTime()
	local taught, plain = CP.RecipeNameFromItem(GetItemInfo(item))
	local rec = taught and CP.FindByName(nil, taught)
	if not rec and plain and plain ~= taught then rec = CP.FindByName(nil, plain) end
	if rec then
		CP.Bump(rec.sk, rec.name, 1)
		CP.Print("в стек: " .. rec.name .. ".")
	else
		CP.AddMat(item, 1)
		CP.Print("в стек: " .. CP.ItemName(item) .. " +1.")
	end
end)
if OpenStackSplitFrame then
	hooksecurefunc("OpenStackSplitFrame", function()
		if splitAt == GetTime() and StackSplitFrame then StackSplitFrame:Hide() end
	end)
end

-- Item tooltip: how many the stacks need and how many are missing; for raw materials — where to find
local function Ours(f) -- tooltip from the CraftPlan window or bar
	while f do
		if f == CraftPlanWindow or f == CraftPlanBar then return true end
		f = f:GetParent()
	end
end
local function Sources(tip, id)
	local src = CP.ItemSources and CP.ItemSources(id)
	if not src then return end
	tip:AddLine("Где искать:", 1, 0.82, 0)
	for _, l in ipairs(src) do tip:AddLine("  " .. l, 1, 1, 1, true) end
end
-- "Пригодится": recipes of your professions that use the item (from the addon recipe table).
-- Learned ones in the recipe color, not learned in red (with the color they would have); grey ones are skipped.
-- If only grey recipes use it — what it turns into via your learned recipes that still give skill ("через …"),
-- otherwise "не актуален". Built only for your professions; rebuilt when that set changes.
local uses -- [item] = { { prof, rec } }
local usesProfs -- [prof] = true: the professions "uses" was built for
local function Uses()
	local lines = CP.SkillLines()
	if uses then
		local same = true
		for prof in pairs(CP.SKILL_ID) do
			if (lines[prof] ~= nil) ~= (usesProfs[prof] == true) then same = false break end
		end
		if same then return uses end
	end
	uses, usesProfs = {}, {}
	for prof, sk in pairs(CP.SKILL_ID) do
		if lines[prof] then
			usesProfs[prof] = true
			for _, rec in ipairs(CP.Recipes(sk)) do
				for _, rg in ipairs(rec.reag) do
					local u = uses[rg.id]
					if not u then u = {}; uses[rg.id] = u end
					u[#u + 1] = { prof = prof, rec = rec }
				end
			end
		end
	end
	return uses
end
local PER_PROF = 6
local function UsefulTip(tip, id)
	local U = Uses()
	local list = U[id]
	if not list then return end
	local lines = CP.SkillLines()
	local byProf, profs, anyGrey = {}, {}, false
	for _, u in ipairs(list) do
		local L = lines[u.prof]
		if L then
			local kind = CP.KindAt(u.rec.y, u.rec.g, L.rank)
			if kind == "trivial" then
				anyGrey = true
			else
				if not byProf[u.prof] then byProf[u.prof] = {}; profs[#profs + 1] = u.prof end
				local t = byProf[u.prof]
				t[#t + 1] = { rec = u.rec, kind = kind, known = CP.KnownRecipe(u.prof, u.rec.name) and true, rank = L.rank }
			end
		end
	end
	if not profs[1] then
		if not anyGrey then return end
		-- grey everywhere: what it is made into by learned recipes that still give skill
		local via, seen = {}, {}
		local function Walk(item, depth)
			if depth > 3 or seen[item] then return end
			seen[item] = true
			for _, u in ipairs(U[item] or {}) do
				local L = lines[u.prof]
				if L and CP.KnownRecipe(u.prof, u.rec.name) and u.rec.item > 0 then
					local nextUses = U[u.rec.item] or {}
					for _, v in ipairs(nextUses) do
						local L2 = lines[v.prof]
						if L2 and CP.KindAt(v.rec.y, v.rec.g, L2.rank) ~= "trivial" then via[u.rec.item] = v.prof end
					end
					Walk(u.rec.item, depth + 1)
				end
			end
		end
		Walk(id, 0)
		local names = {}
		for item, prof in pairs(via) do names[#names + 1] = CP.ItemName(item) .. " (" .. prof .. ")" end
		table.sort(names)
		if names[1] then
			tip:AddLine("CraftPlan — пригодится через: " .. table.concat(names, ", ", 1, math.min(3, #names)), 0.4, 0.8, 1, true)
		else
			tip:AddLine("CraftPlan — не актуален: рецепты с ним навыка уже не дадут", 0.6, 0.6, 0.6, true)
		end
		return
	end
	tip:AddLine("CraftPlan — пригодится:", 0.4, 0.8, 1)
	table.sort(profs)
	local ORDER = { optimal = 1, medium = 2, easy = 3 }
	for _, prof in ipairs(profs) do
		local t = byProf[prof]
		table.sort(t, function(a, b)
			if a.known ~= b.known then return a.known end
			if ORDER[a.kind] ~= ORDER[b.kind] then return ORDER[a.kind] < ORDER[b.kind] end
			if a.rec.y ~= b.rec.y then return a.rec.y < b.rec.y end
			return a.rec.name < b.rec.name
		end)
		tip:AddLine(prof .. " (" .. t[1].rank .. ")", 1, 0.82, 0)
		for k = 1, math.min(PER_PROF, #t) do
			local e = t[k]
			local sure = e.rec.y - e.rank -- orange crafts left: exact skill
			local right = CP.KIND_HEX[e.kind] .. ((e.kind == "optimal" and sure > 0) and ("+" .. sure .. " точно") or (e.kind == "medium" and "жёлтый" or "зелёный")) .. "|r"
			tip:AddDoubleLine("  " .. (e.known and "" or "|cffff4040") .. e.rec.name .. (e.known and "" or " (не изучен)|r"), right, 1, 1, 1)
		end
		if #t > PER_PROF then tip:AddLine("  и ещё " .. (#t - PER_PROF), 0.6, 0.6, 0.6) end
	end
end

-- Bagnon re-fires OnTooltipSetItem every 0.2 s while a bag item is hovered, so the finished lines are memoized
-- per item id (dropped in CP.DropCache). "Где искать" isn't memoized: CP.ItemSources has its own cache and
-- returns nil until Questie is ready, and the CraftPlan-window case depends on the tooltip owner.
local tipMemo = {} -- [id] = { lines = { { method, argCount, args... } }, src = true/false/nil }
CP.OnDrop(function() tipMemo = {} end)
local function Recorder()
	local r = { lines = {} }
	function r:AddLine(...) self.lines[#self.lines + 1] = { "AddLine", select("#", ...), ... } end
	function r:AddDoubleLine(...) self.lines[#self.lines + 1] = { "AddDoubleLine", select("#", ...), ... } end
	return r
end
local function BuildTip(id)
	local r = Recorder()
	UsefulTip(r, id)
	local n
	if CraftPlanDB and CraftPlanDB.goal and CraftPlanDB.goal.stacks and CraftPlanDB.goal.stacks[1] then
		local ok, M = pcall(CP.MergedAll)
		if ok then n = M.nodes[id] end
	end
	if n then
		r:AddLine("CraftPlan: нужно стекам " .. n.gross .. (n.short > 0 and (", не хватает " .. n.short) or ", хватает"), 0.4, 0.8, 1)
	end
	-- src: true — in stacks, raw (show sources); false — in stacks, crafted; nil — not in any stack
	local src
	if n then src = (n.made == 0) end
	return { lines = r.lines, src = src }
end
local function AddTip(tip)
	local _, link = tip:GetItem()
	local id = CP.ItemOfLink(link)
	if not id or (tip.cpGuard and tip.cpTipItem == id) then return end -- already added to this tooltip
	tip.cpTipItem = id
	local m = tipMemo[id]
	if not m then
		m = BuildTip(id)
		tipMemo[id] = m
	end
	for _, l in ipairs(m.lines) do tip[l[1]](tip, unpack(l, 3, l[2] + 2)) end
	if m.src then
		Sources(tip, id)
	elseif m.src == nil and Ours(tip:GetOwner()) and not CP.Producer(id) then
		-- a material in the CraftPlan window (e.g. in "Все рецепты") that isn't in any stack
		Sources(tip, id)
	end
	tip:Show()
end
local tipErrors = {} -- error messages already printed this session
local function SafeAddTip(tip)
	local ok, err = pcall(AddTip, tip)
	if not ok then
		err = tostring(err)
		if not tipErrors[err] then
			tipErrors[err] = true
			CP.Print("|cffff4040ошибка подсказки:|r " .. err)
		end
	end
end
for _, t in ipairs({ GameTooltip, ItemRefTooltip }) do
	t:HookScript("OnTooltipSetItem", SafeAddTip)
	if t:HasScript("OnTooltipCleared") then -- without it the flag couldn't be reset: no double-fire guard then
		t.cpGuard = true
		t:HookScript("OnTooltipCleared", function(self) self.cpTipItem = nil end)
	end
end

----------------------------------------------------------------------------------------------
-- Trainer: "Выучить нужное" — learn the stack recipes available now, one by one, after a confirmation
local MAX_LEARN = 30
local function LearnList()
	local list, total = {}, 0
	for i = 1, GetNumTrainerServices() do
		local name, _, kind = GetTrainerServiceInfo(i)
		if name and kind == "available" then
			local skill = GetTrainerServiceSkillLine and GetTrainerServiceSkillLine(i)
			local rec = CP.FindByName(skill, name)
			if rec and CP.StacksWith(rec.sk, rec.name) then
				local cost = GetTrainerServiceCost(i) or 0
				list[#list + 1] = { name = name, cost = cost }
				total = total + cost
			end
		end
	end
	return list, total
end
local learnQueue
local learnTimer = CreateFrame("Frame")
learnTimer:Hide()
learnTimer:SetScript("OnUpdate", function(self, elapsed)
	self.wait = (self.wait or 0) - elapsed
	if self.wait > 0 then return end
	self.wait = 0.4 -- the trainer list updates after each purchase: find the next one again by name
	local nextName = learnQueue and table.remove(learnQueue, 1)
	if not nextName or not (ClassTrainerFrame and ClassTrainerFrame:IsShown()) then self:Hide(); learnQueue = nil; return end
	for i = 1, GetNumTrainerServices() do
		local name, _, kind = GetTrainerServiceInfo(i)
		if name == nextName and kind == "available" then
			if (GetTrainerServiceCost(i) or 0) <= GetMoney() then BuyTrainerService(i) end
			break
		end
	end
end)
StaticPopupDialogs["CRAFTPLAN_LEARN"] = {
	text = "%s", button1 = YES, button2 = NO, timeout = 0, whileDead = 1, hideOnEscape = 1,
	OnAccept = function()
		local list = LearnList()
		learnQueue = {}
		for k = 1, math.min(MAX_LEARN, #list) do learnQueue[k] = list[k].name end
		learnTimer.wait = 0
		learnTimer:Show()
	end,
}
local learnBtn
local function UpdateLearnBtn()
	if not (ClassTrainerFrame and ClassTrainerTrainButton) then return end
	if not learnBtn then
		learnBtn = CreateFrame("Button", "CraftPlanLearnButton", ClassTrainerFrame, "UIPanelButtonTemplate")
		learnBtn:SetHeight(22)
		learnBtn:SetPoint("RIGHT", ClassTrainerTrainButton, "LEFT", -4, 0)
		learnBtn:SetScript("OnEnter", function(self)
			local list, total = LearnList()
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine("CraftPlan: выучить рецепты стеков")
			for _, it in ipairs(list) do GameTooltip:AddDoubleLine(it.name, CP.Money(it.cost), 1, 1, 1, 1, 1, 1) end
			if list[1] then GameTooltip:AddDoubleLine("Итого", CP.Money(total), 1, 0.82, 0, 1, 0.82, 0) end
			if total > GetMoney() then GameTooltip:AddLine("Не хватает денег", 1, 0.3, 0.3) end
			GameTooltip:Show()
		end)
		learnBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		learnBtn:SetScript("OnClick", function()
			local list, total = LearnList()
			if not list[1] then return end
			local t = { "Выучить у учителя:" }
			for _, it in ipairs(list) do t[#t + 1] = it.name .. ", " .. CP.Money(it.cost) end
			t[#t + 1] = "Итого: " .. CP.Money(total)
			StaticPopup_Show("CRAFTPLAN_LEARN", table.concat(t, "\n"))
		end)
	end
	local isProf = IsTradeskillTrainer and IsTradeskillTrainer()
	local list = isProf and LearnList() or {}
	learnBtn:SetText("Выучить нужное (" .. #list .. ")")
	learnBtn:SetWidth(learnBtn:GetFontString():GetStringWidth() + 24)
	if isProf then learnBtn:Show() else learnBtn:Hide() end
	if list[1] then learnBtn:Enable() else learnBtn:Disable() end
end

----------------------------------------------------------------------------------------------
-- Merchant: "Купить для стеков" — buy the missing raw materials of all stacks this vendor sells (after a confirmation)
local MAX_PURCHASES = 50
local function BuyList()
	local M = CP.MergedAll()
	local list, total = {}, 0
	for i = 1, GetMerchantNumItems() do
		local id = CP.ItemOfLink(GetMerchantItemLink(i))
		local n = id and M.nodes[id]
		if n and n.made == 0 and n.short > 0 then
			local name, texture, price, per, available, _, extendedCost = GetMerchantItemInfo(i)
			if price and price > 0 and not extendedCost then
				per = math.max(1, per or 1)
				local buys = math.min(math.ceil(n.short / per), MAX_PURCHASES)
				if available and available >= 0 then buys = math.min(buys, available) end
				if buys > 0 then
					list[#list + 1] = { index = i, name = name, texture = texture, per = per, buys = buys, count = buys * per, cost = buys * price }
					total = total + buys * price
				end
			end
		end
	end
	return list, total
end
StaticPopupDialogs["CRAFTPLAN_BUY"] = {
	text = "%s", button1 = YES, button2 = NO, timeout = 0, whileDead = 1, hideOnEscape = 1,
	OnAccept = function()
		if not (MerchantFrame and MerchantFrame:IsShown()) then return end
		local list = BuyList()
		local spent, got, purchases = 0, 0, 0
		for _, b in ipairs(list) do
			local price = b.cost / b.buys
			if b.per > 1 then
				-- sold in packs: one call = one pack
				for _ = 1, b.buys do
					if purchases >= MAX_PURCHASES or GetMoney() - spent < price then break end
					BuyMerchantItem(b.index)
					spent, got, purchases = spent + price, got + b.per, purchases + 1
				end
			else
				-- single items: up to a full stack per call
				local maxStack = math.max(1, (GetMerchantItemMaxStack and GetMerchantItemMaxStack(b.index)) or 1)
				local left = b.buys
				while left > 0 do
					local q = math.min(left, maxStack, MAX_PURCHASES - purchases, math.floor((GetMoney() - spent) / price))
					if q <= 0 then break end
					BuyMerchantItem(b.index, q)
					spent, got, purchases, left = spent + q * price, got + q, purchases + q, left - q
				end
			end
		end
		CP.Print(got > 0 and ("куплено для стеков: " .. got .. " шт. за " .. CP.Money(spent) .. ".") or "не хватает денег.")
	end,
}
local buyBtn = CreateFrame("Button", "CraftPlanBuyButton", MerchantFrame, "UIPanelButtonTemplate")
buyBtn:SetHeight(22)
buyBtn:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 2, -50) -- right of the merchant window, as in 0.12
buyBtn:Hide()
buyBtn:SetScript("OnEnter", function(self)
	local list, total = BuyList()
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("CraftPlan: купить для стеков")
	for _, b in ipairs(list) do
		GameTooltip:AddDoubleLine("|T" .. (b.texture or "") .. ":16|t " .. b.name .. " x" .. b.count, CP.Money(b.cost), 1, 1, 1, 1, 1, 1)
	end
	if list[1] then GameTooltip:AddDoubleLine("Итого", CP.Money(total), 1, 0.82, 0, 1, 0.82, 0) end
	if total > GetMoney() then GameTooltip:AddLine("Не хватает денег: купится, сколько хватит", 1, 0.3, 0.3, true) end
	GameTooltip:Show()
end)
buyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
buyBtn:SetScript("OnClick", function()
	local list, total = BuyList()
	if not list[1] then return end
	local t = { "Купить для стеков:" }
	for _, b in ipairs(list) do t[#t + 1] = b.name .. " x" .. b.count .. ", " .. CP.Money(b.cost) end
	t[#t + 1] = "Итого: " .. CP.Money(total)
	StaticPopup_Show("CRAFTPLAN_BUY", table.concat(t, "\n"))
end)
local function UpdateBuyBtn()
	if not (MerchantFrame and MerchantFrame:IsShown()) or MerchantFrame.selectedTab ~= 1 then buyBtn:Hide() return end
	local list = BuyList()
	if not list[1] then buyBtn:Hide() return end
	buyBtn:SetText("Купить для стеков (" .. #list .. ")")
	buyBtn:SetWidth(buyBtn:GetFontString():GetStringWidth() + 24)
	buyBtn:Show()
end
if MerchantFrame_UpdateMerchantInfo then hooksecurefunc("MerchantFrame_UpdateMerchantInfo", function() pcall(UpdateBuyBtn) end) end
local ev2 = CreateFrame("Frame")
-- bag changes reach the buy button through CP.OnChange below (after the throttle); here only the window opening
for _, e in ipairs({ "MERCHANT_SHOW", "TRAINER_SHOW", "TRAINER_UPDATE" }) do ev2:RegisterEvent(e) end
ev2:SetScript("OnEvent", function(_, e)
	if e == "MERCHANT_SHOW" then pcall(UpdateBuyBtn) end
	if e == "TRAINER_SHOW" or e == "TRAINER_UPDATE" then pcall(UpdateLearnBtn) end
end)
CP.OnChange(function()
	pcall(UpdateBuyBtn)
	if ClassTrainerFrame and ClassTrainerFrame:IsShown() then pcall(UpdateLearnBtn) end
end)
