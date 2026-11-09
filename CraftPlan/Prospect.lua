-- CraftPlan 2.0 — prospecting (jewelcrafting): chances (Data/ProspectData.lua), the own log "ore -> what dropped",
-- ore/gem tooltips, data for the "Просеивание" tab and its "Просеять" button (on hover of an ore row; one press — one prospect).
-- Button on the bar right of the window icon: spell icon, number = how many prospects without touching stack ore;
-- on hover a column of ore from the bags, click an ore = one prospect.
local CP = CraftPlan
local W = CP.W

local PROSPECT_SPELL = 31252 -- Prospecting
local ORES = CP.ORES -- ore that can be prospected (Core.lua)
local IS_ORE = {}
for _, id in ipairs(ORES) do IS_ORE[id] = true end
local SIZE = 32 -- bar icon size (UI/Bar.lua)

-- Chances per prospect: Data/ProspectData.lua (Sirus knowledge base, Tools/sirusdb.py); skill needed to prospect
local DATA = CraftPlan_ProspectData or {}
local PROSPECT = {} -- [ore] = { gem, ... } by chance
for ore, list in pairs(DATA) do
	local t = {}
	for _, g in ipairs(list) do t[#t + 1] = g[1] end
	PROSPECT[ore] = t
end
local PROSPECT_REQ = { [2770] = 20, [2771] = 50, [2772] = 125, [3858] = 175, [10620] = 250,
	[23424] = 275, [23425] = 325, [36909] = 350, [36912] = 400, [36910] = 450 }

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCraftPlan (просеивание):|r " .. msg) end

-- CraftPlanDB.prospect: fail[ore] = skill at which the game refused (skill too low).
-- (The own log of drops, prospect.ore, was removed in 2.1.4: chances come only from the Sirus knowledge base.)
local function PDB()
	local db = CP.DB()
	local p = db.prospect or {}
	db.prospect = p
	p.ore = nil
	p.fail = p.fail or {}
	return p
end

local function JewelRank()
	local l = CP.SkillLines()["Ювелирное дело"]
	return l and l.rank or 0
end

-- ore the game refused at the current skill is skipped
local function Usable(id)
	local failAt = PDB().fail[id]
	return GetItemCount(id) >= 5 and not (failAt and JewelRank() <= failAt)
end

-- Slot with a stack of 5+ ore
local function OreSlot(id)
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			if CP.ItemOfLink(GetContainerItemLink(bag, slot)) == id then
				local _, count = GetContainerItemInfo(bag, slot)
				if (count or 0) >= 5 then return bag, slot end
			end
		end
	end
end

----------------------------------------------------------------------------------------------
-- For the "Просеивание" tab
function CP.Pct(v) return (math.floor(v * 10 + 0.5) / 10) .. "%" end
CP.JewelRank = JewelRank
function CP.ProspectReq(ore) return PROSPECT_REQ[ore] or 0 end
function CP.ProspectData(ore) return DATA[ore] end
-- Static index of DATA, built once: byGem[gem] = { { ore, pct, avg } }, gemList = every gem (shared — not changed
-- by callers), baseTip[gem] = { { ore, pct } } — the first entry of each ore, in CP.ORES order (tooltips)
local byGem, gemList, baseTip
local function Index()
	if byGem then return end
	byGem, gemList, baseTip = {}, {}, {}
	for ore, list in pairs(DATA) do
		for _, g in ipairs(list) do
			local t = byGem[g[1]]
			if not t then t = {}; byGem[g[1]] = t; gemList[#gemList + 1] = g[1] end
			t[#t + 1] = { ore = ore, pct = g[2], avg = g[5], min = g[3], max = g[4] }
		end
	end
	for _, ore in ipairs(ORES) do
		local seen = {}
		for _, g in ipairs(DATA[ore] or {}) do
			if not seen[g[1]] then
				seen[g[1]] = true
				local t = baseTip[g[1]] or {}
				baseTip[g[1]] = t
				t[#t + 1] = { ore = ore, pct = g[2] }
			end
		end
	end
end
-- gem -> ores it comes from: { ore, pct (base), own (own chance or nil), per (expected pieces per prospect) }
function CP.ProspectOres(gem)
	Index()
	local list = byGem[gem]
	if not list then return nil end
	local out = {}
	for _, b in ipairs(list) do
		out[#out + 1] = { ore = b.ore, pct = b.pct, per = b.pct / 100 * b.avg, req = PROSPECT_REQ[b.ore] or 0, min = b.min, max = b.max }
	end
	return out
end
-- the ore with the highest chance for a gem (ore the skill allows first); onlyCan — only such ore
function CP.ProspectTopOre(gem, onlyCan)
	local rank, best = JewelRank(), nil
	for _, o in ipairs(CP.ProspectOres(gem) or {}) do
		local can = rank >= o.req
		if can or not onlyCan then
			if not best or (can and not best.can) or (can == best.can and o.per > best.per) then
				best = o
				best.can = can
			end
		end
	end
	return best
end
-- Ore for `need` pieces of a gem with probability CONF (85%) (not on average): one prospect gives the gem with chance
-- p, min..max pieces then (equally likely). Distribution of the pieces after n prospects, capped at need. Memoized
local CONF = 0.85
local needMemo = {}
function CP.ProspectNeed(o, need)
	if need <= 0 then return 0 end
	local p = (o.pct or 0) / 100
	if p <= 0 then return 0 end
	local a, b = o.min or 1, o.max or o.min or 1
	if b < a then b = a end
	local key = p .. "|" .. a .. "|" .. b .. "|" .. need
	local hit = needMemo[key]
	if hit then return hit end
	local w = p / (b - a + 1)
	local d, n = { [0] = 1 }, 0
	while n < 2000 and (d[need] or 0) < CONF do
		n = n + 1
		local nd = {}
		for k = 0, need do
			local v = d[k]
			if v and v > 0 then
				nd[k] = (nd[k] or 0) + v * (1 - p)
				for x = a, b do
					local j = math.min(need, k + x)
					nd[j] = (nd[j] or 0) + v * w
				end
			end
		end
		d = nd
	end
	needMemo[key] = n * 5
	return n * 5
end
-- which ore and how much closes the missing gems: each gem — its top ore; gems with the same ore share it
-- (one prospect gives several gems). nodes: { id, short }. -> { { ore, need, can, gems = { node, ... } }, ... }
function CP.ProspectPlan(nodes, onlyCan)
	local out, byOre = {}, {}
	for _, n in ipairs(nodes) do
		local o = CP.ProspectTopOre(n.id, onlyCan)
		if o then
			local c = byOre[o.ore]
			if not c then c = { ore = o.ore, need = 0, avg = 0, can = o.can, gems = {} }; byOre[o.ore] = c; out[#out + 1] = c end
			c.gems[#c.gems + 1] = n
			c.need = math.max(c.need, CP.ProspectNeed(o, n.short)) -- 85% for each gem
			c.avg = math.max(c.avg, math.ceil(n.short / o.per) * 5) -- on average, for the tooltip
		end
	end
	return out
end
-- prospecting is available: the spell is in the spellbook
function CP.CanProspect()
	local spell = GetSpellInfo(PROSPECT_SPELL)
	return spell and GetSpellInfo(spell) and true or false
end
function CP.IsProspectGem(id) Index(); return byGem[id] ~= nil end
-- every gem prospecting gives (shared list — don't change it)
function CP.ProspectGemList() Index(); return gemList end

-- Tooltip lines are built as entries: { text, r, g, b, wrap } or { text, r, g, b, right = text } (double line, white)
local BLUE, GREY, WHITE = { 0.4, 0.8, 1 }, { 0.6, 0.6, 0.6 }, { 1, 1, 1 }
local function Line(out, text, c, wrap) out[#out + 1] = { text = text, c = c, wrap = wrap } end
local function Double(out, text, right) out[#out + 1] = { text = text, c = WHITE, right = right } end

-- chances from the Sirus knowledge base
local function OreTooltipLines(out, id)
	if not DATA[id] then return end
	Line(out, "Просеивание, шанс за раз:", BLUE)
	for i, g in ipairs(DATA[id]) do
		if i > 12 then Line(out, "  и ещё " .. (#DATA[id] - 12), GREY) break end
		Double(out, "  " .. CP.ItemName(g[1]), CP.Pct(g[2]))
	end
end

local clickAt, clickOre = 0, nil -- which ore was prospected by a click (for the "skill too low" refusal)

----------------------------------------------------------------------------------------------
-- "Просеять" on hover of an ore row in the tab: one floating secure button (UIParent, not inside the
-- redrawn canvas), placed over the row out of combat only
local rowBtn = CreateFrame("Button", "CraftPlanProspectRowButton", UIParent, "SecureActionButtonTemplate,UIPanelButtonTemplate")
rowBtn:SetText("Просеять")
rowBtn:SetWidth(rowBtn:GetFontString():GetStringWidth() + 20)
rowBtn:SetHeight(18)
rowBtn:SetFrameStrata("DIALOG")
rowBtn:RegisterForClicks("LeftButtonUp")
rowBtn:SetAttribute("type1", "macro")
rowBtn:Hide()
rowBtn:HookScript("OnClick", function(self) clickAt, clickOre = GetTime(), self.ore end)
rowBtn:SetScript("OnEnter", function(self) if self.area then W.TipEnter(self.area) end end)
rowBtn:SetScript("OnLeave", W.TipLeave)
rowBtn:SetScript("OnUpdate", function(self)
	if InCombatLockdown() then return end
	local a = self.area
	if not a or not a:IsVisible() or a.prOre ~= self.ore or not (MouseIsOver(self) or MouseIsOver(a)) then self:Hide() end
end)
-- area: the row (canvas Area with .prOre), x: offset from the row's left edge
function CP.ProspectHover(area, ore, x)
	if InCombatLockdown() or not area.prOre then return end
	local spell = GetSpellInfo(PROSPECT_SPELL)
	local bag, slot = OreSlot(ore)
	if not (spell and GetSpellInfo(spell) and bag and Usable(ore)) then return end
	local s = area:GetEffectiveScale() / UIParent:GetEffectiveScale()
	rowBtn:ClearAllPoints()
	rowBtn:SetPoint("LEFT", UIParent, "BOTTOMLEFT", (area:GetLeft() + x) * s, ((area:GetTop() + area:GetBottom()) / 2) * s)
	rowBtn:SetAttribute("macrotext1", "/cast " .. spell .. "\n/use " .. bag .. " " .. slot)
	rowBtn.area, rowBtn.ore = area, ore
	rowBtn:Show()
end

----------------------------------------------------------------------------------------------
-- Bar button (secure): right of the window icon, the bar leaves room for it (UI/Bar.lua)
-- How much ore the stacks need; free for prospecting = everything (bags + bank) minus that, no more than in the bags
local function StackNeed(id)
	local n = CP.MergedAll().nodes[id]
	return n and n.gross or 0
end
local function FreeOre(id)
	local bags = GetItemCount(id)
	local need = StackNeed(id)
	local total = CP.Have(id)
	return math.max(0, math.min(bags, total - need)), need, bags, total - bags
end

local frame = CreateFrame("Frame", "CraftPlanProspectFrame", UIParent)
frame:SetWidth(SIZE)
frame:SetHeight(SIZE)
frame:SetPoint("LEFT", CP.mapButton, "RIGHT", 6, 0)
frame:SetFrameStrata("MEDIUM")
frame:Hide()
CP.prospectFrame = frame

local function SecureButton(name, parent)
	local b = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
	b:SetWidth(SIZE)
	b:SetHeight(SIZE)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetAttribute("type1", "macro")
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints(b)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
	-- Ctrl+drag moves the bar, same as from its icons
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", CP.BarDragStart)
	b:SetScript("OnDragStop", CP.BarDragStop)
	return b
end

local button = SecureButton("CraftPlanProspect", frame)
button:SetAllPoints(frame)
button.border = button:CreateTexture(nil, "OVERLAY")
button.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
button.border:SetBlendMode("ADD")
button.border:SetWidth(SIZE * 1.8)
button.border:SetHeight(SIZE * 1.8)
button.border:SetPoint("CENTER", button, "CENTER", 0, 0)
button.border:SetVertexColor(0.4, 0.8, 1)
button.warn = button:CreateTexture(nil, "OVERLAY") -- ore is needed by stacks
button.warn:SetWidth(14)
button.warn:SetHeight(14)
button.warn:SetPoint("TOPRIGHT", button, "TOPRIGHT", 2, 2)
button.warn:SetTexture(W.TEX.alert)

local flyOres = {}
button:SetScript("OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT") -- the ore column is below
	GameTooltip:AddLine("Просеивание")
	GameTooltip:AddLine("Число — сколько раз можно просеять, не трогая руду стеков.", 1, 1, 1, true)
	for _, id in ipairs(flyOres) do
		local free, need = FreeOre(id)
		GameTooltip:AddDoubleLine("  " .. CP.ItemName(id), math.floor(free / 5) .. " раз" .. (need > 0 and ("  (стекам нужно " .. need .. ")") or ""),
			1, 1, 1, need > 0 and 1 or 0.25, need > 0 and 0.82 or 1, need > 0 and 0 or 0.25)
	end
	GameTooltip:AddLine("Щелчок по руде в столбике — одно просеивание.", 0.6, 0.8, 1, true)
	GameTooltip:Show()
end)
button:SetScript("OnLeave", W.TipLeave)

-- Column under the button: ore icon, number = how many prospects without stack ore; click = one prospect
local fly = CreateFrame("Frame", "CraftPlanProspectFly", frame)
fly:SetPoint("TOP", frame, "BOTTOM", 0, -16) -- below the percentage under the window icon
fly:SetWidth(SIZE)
fly:Hide()
local flyButtons = {}
local function FlyButton(i)
	local b = flyButtons[i]
	if b then return b end
	b = SecureButton("CraftPlanProspectFly" .. i, fly)
	b:SetPoint("TOP", fly, "TOP", 0, -(i - 1) * (SIZE + 4))
	b:HookScript("OnClick", function(self, mouse)
		if mouse ~= "RightButton" then clickAt, clickOre = GetTime(), self.ore end
	end)
	b:SetScript("OnEnter", function(self)
		local id = self.ore
		if not id then return end
		local free, need, bags, bank = FreeOre(id)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(CP.ItemName(id) .. ": в сумках " .. bags .. (bank > 0 and (", в банке " .. bank) or "") .. " шт.")
		if need > 0 then
			GameTooltip:AddLine("Стекам нужно " .. need .. " — свободно " .. free .. ", можно просеять " .. math.floor(free / 5) .. " раз.",
				free >= 5 and 0.25 or 1, free >= 5 and 1 or 0.4, free >= 5 and 0.25 or 0.4, true)
		else
			GameTooltip:AddLine("Стекам не нужна — можно просеять " .. math.floor(bags / 5) .. " раз.", 0.25, 1, 0.25, true)
		end
		local out = {}
		OreTooltipLines(out, id)
		for _, l in ipairs(out) do
			if l.right then GameTooltip:AddDoubleLine(l.text, l.right, l.c[1], l.c[2], l.c[3], 1, 1, 1)
			else GameTooltip:AddLine(l.text, l.c[1], l.c[2], l.c[3], l.wrap) end
		end
		GameTooltip:AddLine("Щелчок — одно просеивание этой руды.", 0.6, 0.8, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", W.TipLeave)
	flyButtons[i] = b
	return b
end

-- set up the column (out of combat only)
local function FlySetup(spell)
	wipe(flyOres)
	for _, id in ipairs(ORES) do
		if Usable(id) and OreSlot(id) then flyOres[#flyOres + 1] = id end
	end
	for i, id in ipairs(flyOres) do
		local b = FlyButton(i)
		local bag, slot = OreSlot(id)
		b.ore = id
		b:SetAttribute("macrotext1", "/cast " .. spell .. "\n/use " .. bag .. " " .. slot)
		b.icon:SetTexture(GetItemIcon(id))
		local times = math.floor(FreeOre(id) / 5)
		b.count:SetText((times > 0 and "" or "|cffff6060") .. times .. (times > 0 and "" or "|r"))
		b:Show()
	end
	for i = #flyOres + 1, #flyButtons do
		flyButtons[i].ore = nil
		flyButtons[i]:SetAttribute("macrotext1", nil)
		flyButtons[i]:Hide()
	end
	fly:SetHeight(math.max(1, #flyOres * (SIZE + 4)))
	if #flyOres < 1 then fly:Hide() end
end

-- show on button hover; hide when the cursor has left both the button and the column
button:HookScript("OnEnter", function()
	if #flyOres >= 1 and not InCombatLockdown() then fly:Show() end
end)
fly:SetScript("OnUpdate", function(self, elapsed)
	if InCombatLockdown() then return end
	if MouseIsOver(frame) or MouseIsOver(self) then
		self.away = 0
	else
		self.away = (self.away or 0) + elapsed
		if self.away > 0.3 then
			self.away = 0
			self:Hide()
		end
	end
end)

local pending = false
local function UpdateButton()
	if InCombatLockdown() then pending = true return end
	pending = false
	local was = frame:IsShown()
	local spell = GetSpellInfo(PROSPECT_SPELL)
	local known = spell and GetSpellInfo(spell) -- is in the spellbook
	if known then FlySetup(spell) else fly:Hide() end
	if known and #flyOres > 0 and not CP.DB().collapsed then
		local times, needed = 0, false
		for _, id in ipairs(flyOres) do
			local free, need = FreeOre(id)
			times = times + math.floor(free / 5)
			if need > 0 then needed = true end
		end
		button.icon:SetTexture(select(3, GetSpellInfo(PROSPECT_SPELL)))
		button.count:SetText((times > 0 and "" or "|cffff6060") .. times .. (times > 0 and "" or "|r"))
		if needed then button.warn:Show() else button.warn:Hide() end
		frame:Show()
	else
		frame:Hide()
	end
	if was ~= frame:IsShown() and CP.RefreshBar then CP.RefreshBar() end -- the bar shifts its icons
end
CP.ProspectUpdate = UpdateButton
CP.OnChange(UpdateButton)

----------------------------------------------------------------------------------------------
local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "LEARNED_SPELL_IN_TAB", "UI_ERROR_MESSAGE", "PLAYER_REGEN_DISABLED" }) do
	events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "UI_ERROR_MESSAGE" then
		-- refusal containing "навык" right after a click: mark the ore as "skill too low" and skip it for now
		if GetTime() - clickAt < 2 and clickOre and arg1 and arg1:find("навык") then
			PDB().fail[clickOre] = JewelRank()
			Print(CP.ItemName(clickOre) .. ": игра пишет, что навыка мало, — пока пропускаю её.")
			UpdateButton()
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		rowBtn:Hide()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pending then UpdateButton() end
	else
		UpdateButton()
	end
end)

----------------------------------------------------------------------------------------------
-- Tooltips: for ore — what drops from it; for a gem — which ore it comes from.
-- The finished lines are kept per item until CP.DropCache (Bagnon re-sets the item every 0.2 s while hovering);
-- a tooltip gets them once until it is cleared (OnTooltipSetItem may fire again for the same item).
local tipMemo = {}
CP.OnDrop(function() tipMemo = {} end)
local function TipLines(id)
	local out = {}
	if IS_ORE[id] then
		OreTooltipLines(out, id) -- typical drops (Sirus knowledge base)
		return out
	end
	-- dropped by veins along with their ore (Data/VeinData.lua): the three likeliest veins
	local vs = CP.VeinSources and CP.VeinSources(id)
	if vs and vs[1] then
		local parts = {}
		for i = 1, math.min(3, #vs) do parts[#parts + 1] = vs[i].name .. " " .. CP.Pct(vs[i].pct) end
		Line(out, "С жил: " .. table.concat(parts, ", "), BLUE, true)
	end
	local parts = {}
	Index()
	for _, b in ipairs(baseTip[id] or {}) do
		parts[#parts + 1] = CP.ItemName(b.ore) .. " " .. CP.Pct(b.pct) .. " (навык " .. PROSPECT_REQ[b.ore] .. ")"
	end
	if #parts > 0 then Line(out, "Просеиванием: " .. table.concat(parts, ", "), BLUE, true) end
	return out
end

local function AddTip(tip)
	if tip.cpProspect then return end
	local _, link = tip:GetItem()
	local id = CP.ItemOfLink(link)
	if not id then return end
	local owner = tip:GetOwner()
	if owner and owner.ore then return end -- the "Просеять" button shows the row tooltip
	tip.cpProspect = true
	local out = tipMemo[id]
	if not out then out = TipLines(id); tipMemo[id] = out end
	if not out[1] then return end
	for _, l in ipairs(out) do
		if l.right then tip:AddDoubleLine(l.text, l.right, l.c[1], l.c[2], l.c[3], 1, 1, 1)
		else tip:AddLine(l.text, l.c[1], l.c[2], l.c[3], l.wrap) end
	end
	tip:Show()
end
for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
	tip:HookScript("OnTooltipSetItem", AddTip)
	tip:HookScript("OnTooltipCleared", function(self) self.cpProspect = nil end)
end
