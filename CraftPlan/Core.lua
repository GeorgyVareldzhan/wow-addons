-- CraftPlan 2.0 — core: database (CraftPlanDB), professions, "have" counts, reading game windows, events.
-- Stacks and material calculation are in Calc.lua, windows in UI/*.lua.

CraftPlan = CraftPlan or {}
local CP = CraftPlan

CP.VERSION = "2.1.15"

BINDING_HEADER_CRAFTPLAN = "CraftPlan (профессии)"
BINDING_NAME_CRAFTPLAN_MAP = "Открыть/закрыть окно CraftPlan"
BINDING_NAME_CRAFTPLAN_COLLAPSE = "Свернуть/развернуть полосу"

function CP.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCraftPlan:|r " .. msg)
end

function CP.DB()
	CraftPlanDB = CraftPlanDB or {}
	CraftPlanDB.profs = CraftPlanDB.profs or {}
	return CraftPlanDB
end
local DB = CP.DB

----------------------------------------------------------------------------------------------
-- Professions: name <-> skill id (for the CraftPlanRouteData table)
CP.SKILL_ID = {
	["Кузнечное дело"] = 164, ["Кожевничество"] = 165, ["Алхимия"] = 171, ["Кулинария"] = 185,
	["Горное дело"] = 186, ["Портняжное дело"] = 197, ["Инженерное дело"] = 202, ["Наложение чар"] = 333,
	["Ювелирное дело"] = 755, ["Начертание"] = 773, ["Первая помощь"] = 129,
}
CP.SKILL_NAME = {}
for name, id in pairs(CP.SKILL_ID) do CP.SKILL_NAME[id] = name end

-- Profession colors (text): profession name in its color
CP.PROF_COLOR = {
	["Кузнечное дело"] = "ff9955", ["Ювелирное дело"] = "66ccff", ["Горное дело"] = "c8a060", ["Инженерное дело"] = "ffd040",
	["Кулинария"] = "ffb36b", ["Первая помощь"] = "ff5555", ["Алхимия"] = "66ff99", ["Портняжное дело"] = "e080ff",
	["Кожевничество"] = "b08050", ["Наложение чар"] = "b380ff", ["Начертание"] = "a0e0e0",
}
function CP.ProfText(prof)
	local c = CP.PROF_COLOR[prof]
	return c and ("|cff" .. c .. prof .. "|r") or prof
end

-- Profession icons (game textures)
CP.PROF_ICON = {
	["Кузнечное дело"] = "Interface\\Icons\\Trade_BlackSmithing", ["Кожевничество"] = "Interface\\Icons\\Trade_LeatherWorking",
	["Алхимия"] = "Interface\\Icons\\Trade_Alchemy", ["Кулинария"] = "Interface\\Icons\\INV_Misc_Food_15",
	["Горное дело"] = "Interface\\Icons\\Trade_Mining", ["Портняжное дело"] = "Interface\\Icons\\Trade_Tailoring",
	["Инженерное дело"] = "Interface\\Icons\\Trade_Engineering", ["Наложение чар"] = "Interface\\Icons\\Trade_Engraving",
	["Ювелирное дело"] = "Interface\\Icons\\INV_Misc_Gem_01", ["Начертание"] = "Interface\\Icons\\INV_Inscription_Tradeskill01",
	["Первая помощь"] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
}

CP.TOP_SKILL = 450 -- skill cap in 3.3.5 (the skill bar is drawn up to it)

-- Random drops with a 85% margin (prospecting, veins). A drop entry { item, pct, min, max, avg } (Data/*) ->
-- st = { m = expected pieces per try, v = variance per try } (pieces min..max equally likely when it drops).
-- Sums over many tries — normal approximation: CP.Low85(n, st) — pieces n tries give with 85%,
-- CP.Tries85(M, st) — tries that give M pieces with 85%
CP.CONF = 0.85
CP.SKILL_CONF = 0.95 -- skill from yellow and green crafts (Calc.lua RoundGain, OrePlan.lua)
local Z85 = 1.0364 -- 85% one-sided quantile of the normal distribution
function CP.DropStat(d)
	local p, a, b = d[2] / 100, d[3] or 1, d[4] or d[3] or 1
	if b < a then b = a end
	local e2 = 0
	for x = a, b do e2 = e2 + x * x end
	e2 = e2 / (b - a + 1)
	local m = p * (d[5] or (a + b) / 2)
	return { m = m, v = math.max(0, p * e2 - m * m) }
end
function CP.Low85(n, st)
	if n <= 0 or st.m <= 0 then return 0 end
	return math.max(0, math.floor(n * st.m - Z85 * math.sqrt(n * st.v) + 1e-9))
end
function CP.Tries85(M, st)
	if M <= 0 then return 0 end
	if st.m <= 0 then return math.huge end
	local zs = Z85 * math.sqrt(st.v)
	local s = (zs + math.sqrt(zs * zs + 4 * st.m * M)) / (2 * st.m)
	return math.ceil(s * s - 1e-9)
end

-- Recipe colors, as in the game
CP.KIND_COLOR = {
	optimal = { 1, 0.5, 0.25 }, medium = { 1, 1, 0 }, easy = { 0.25, 0.75, 0.25 }, trivial = { 0.5, 0.5, 0.5 },
}
CP.KIND_HEX = { optimal = "|cffff8040", medium = "|cffffff00", easy = "|cff40c040", trivial = "|cff808080" }

-- Skill-up chance (common 3.3.5 formula), the single place it is computed: 0 at/over the profession max
-- (max may be nil — no cap), then by the floored skill k: 1 below yellow, 0 at/over grey (or grey <= yellow),
-- otherwise (grey - k) / (grey - yellow)
local function ChanceYG(y, g, rank, max)
	if max and rank >= max then return 0 end
	local k = math.floor(rank + 1e-9)
	if k < y then return 1 end
	if k >= g or g <= y then return 0 end
	return (g - k) / (g - y)
end
function CP.ChanceAt(rec, rank, max) return ChanceYG(rec.y, rec.g, rank, max) end
-- the same for bare thresholds (no profession max)
function CP.Chance(y, g, r) return ChanceYG(y, g, r) end

-- Recipe color at a skill: orange below the yellow threshold, yellow up to the midpoint, green up to grey
function CP.KindAt(y, g, rank)
	if ChanceYG(y, g, rank) <= 0 then return "trivial" end
	if rank < y then return "optimal" end
	if rank < math.floor((y + g) / 2) then return "medium" end
	return "easy"
end

-- Current skill and max of a profession (from the skills list, without the profession window)
-- Take the larger skill of the skills list and the profession window: after a craft the profession window updates at once,
-- the skills list a bit later (otherwise the "skill + gain" total would shrink for a moment or for good)
-- The result is cached and SHARED: callers must not change it. Dropped in CP.DropCache and on the skill /
-- profession window events.
local skillLines
function CP.DropSkillLines() skillLines = nil end
function CP.SkillLines()
	if skillLines then return skillLines end
	local t = {}
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank, _, _, max = GetSkillLineInfo(i)
		if name and not isHeader then t[name] = { rank = rank, max = max } end
	end
	if TradeSkillFrame and TradeSkillFrame:IsShown() and not (IsTradeSkillLinked and IsTradeSkillLinked()) then
		local prof, rank, max = GetTradeSkillLine()
		local l = prof and t[prof]
		if l and rank and rank > l.rank then l.rank = rank end
		if l and max and max > l.max then l.max = max end
	end
	skillLines = t
	return t
end

-- Ore that can be prospected (in display order) and the stone mined from the same veins
CP.ORES = { 2770, 2771, 2772, 3858, 10620, 23424, 23425, 36909, 36912, 36910 }
CP.STONE = { [2770] = 2835, [2771] = 2836, [2772] = 2838, [3858] = 7912, [10620] = 12365 }

----------------------------------------------------------------------------------------------
-- Items: name and icon (game cache, otherwise the Questie database, otherwise "предмет N")
local function ItemOfLink(link) return link and tonumber(link:match("item:(%d+)")) end
CP.ItemOfLink = ItemOfLink

function CP.ItemName(id)
	if not id then return "?" end
	local name = GetItemInfo(id)
	if name then return name end
	local q = QuestieLoader and QuestieLoader:ImportModule("QuestieDB")
	if q and q.QueryItemSingle then
		local ok, n = pcall(q.QueryItemSingle, id, "name")
		if ok and n then return n end
	end
	return "предмет " .. id
end

function CP.ItemIcon(id)
	return (id and GetItemIcon(id)) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

----------------------------------------------------------------------------------------------
-- How many of an item we have: bags + the Sirus reagent storage (container -4; crafting takes from it
-- anywhere; its contents are remembered when the game doesn't return them right now) + bank (remembered).
-- Add the items of one container to into[id]
local function CountBag(bag, into)
	for slot = 1, GetContainerNumSlots(bag) or 0 do
		local id = ItemOfLink(GetContainerItemLink(bag, slot))
		if id then
			local _, count = GetContainerItemInfo(bag, slot)
			into[id] = (into[id] or 0) + (count or 1)
		end
	end
	return into
end
-- Backpack and bags -> { [id] = count }
local function CountBags()
	local into = {}
	for bag = 0, NUM_BAG_SLOTS do CountBag(bag, into) end
	return into
end

do
	local REAGENT_BAG = -4
	local ids, stamp
	local function Scan()
		ids = CountBags()
		local live = CountBag(REAGENT_BAG, {})
		-- an empty answer away from the bank doesn't wipe what we remembered (storage may not have loaded yet)
		-- db.reagentBag = { [id] = count } (older versions: a list of { id, name, count })
		if next(live) or CP.bankIsOpen then DB().reagentBag = live end
		for k, v in pairs(DB().reagentBag or {}) do
			if type(v) == "table" then
				if v[1] then ids[v[1]] = (ids[v[1]] or 0) + (v[3] or 1) end
			else
				ids[k] = (ids[k] or 0) + v
			end
		end
	end
	-- recount at most once per frame (GetTime() is the same during one frame)
	function CP.BagCount(id)
		local now = GetTime()
		if stamp ~= now then Scan() stamp = now end
		return (id and ids[id]) or 0
	end

	-- Crafting away from the bank also takes materials from the reagent storage, and the game does not show the
	-- storage there: what a craft took beyond the bags is subtracted from the remembered contents.
	-- Bags are counted when the cast is sent/started and again a moment after it succeeded.
	local recipeOf -- [recipe name] = rec (reagents)
	local function RecipeOf(name)
		if not name then return nil end
		if not recipeOf then
			recipeOf = {}
			for _, sk in pairs(CP.SKILL_ID) do
				for _, rec in ipairs(CP.Recipes(sk)) do
					if not recipeOf[rec.name] then recipeOf[rec.name] = rec end
				end
			end
		end
		return recipeOf[name]
	end
	local before, pending = nil, {}
	local tracker = CreateFrame("Frame")
	tracker:Hide()
	tracker:RegisterEvent("UNIT_SPELLCAST_SENT")
	tracker:RegisterEvent("UNIT_SPELLCAST_START")
	tracker:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	tracker:SetScript("OnEvent", function(self, event, unit, spell)
		if unit ~= "player" then return end
		local rec = RecipeOf(spell)
		if not rec then return end
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			if before then
				pending[#pending + 1] = { rec = rec, before = before, at = GetTime() + 0.3 }
				before = nil
				self:Show()
			end
		else
			before = CountBags()
		end
	end)
	tracker:SetScript("OnUpdate", function(self)
		local p = pending[1]
		if not p then self:Hide() return end
		if GetTime() < p.at then return end
		table.remove(pending, 1)
		if next(CountBag(REAGENT_BAG, {})) then return end -- the storage is readable now: the scan has it right
		local mem = DB().reagentBag
		if type(mem) ~= "table" then return end
		local now, changed = CountBags(), false
		for _, g in ipairs(p.rec.reag) do
			local fromBags = math.max(0, (p.before[g.id] or 0) - (now[g.id] or 0))
			local fromStore = g.count - fromBags
			local v = mem[g.id]
			if fromStore > 0 and type(v) == "number" and v > 0 then
				mem[g.id] = (v - fromStore > 0) and (v - fromStore) or nil
				changed = true
			end
		end
		if changed then stamp = nil; CP.Changed() end
	end)
end
function CP.BankCount(id)
	local bank = DB().bank
	return (id and bank and bank[id]) or 0
end
function CP.Have(id) return CP.BagCount(id) + CP.BankCount(id) end

-- Bags: written to SavedVariables on logout/reload (db.bags = { [id] = count }, db.bagsTime) — for planning outside the game
local function SaveBags()
	DB().bags = CountBags()
	DB().bagsTime = time()
end

-- Bank: remember its contents while it is open
local function ScanBank()
	if not CP.bankIsOpen then return end
	local bank = CountBag(BANK_CONTAINER or -1, {})
	for b = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do CountBag(b, bank) end
	DB().bank = bank
	DB().bankTime = time()
end
-- bag events come in bursts: rescan the open bank at most once per frame
local bankTimer = CreateFrame("Frame")
bankTimer:Hide()
bankTimer:SetScript("OnUpdate", function(self)
	self:Hide()
	ScanBank()
end)
local function ScanBankSoon()
	if CP.bankIsOpen then bankTimer:Show() end
end

----------------------------------------------------------------------------------------------
-- Profession window: learned recipes. db.profs[prof] = { rank, max, scanned, known = { [recipe name] = true } }
-- (before: recipes = { full recipe snapshots } — converted by MigrateProf)
local function MigrateProf(p)
	if p.recipes then
		local known = p.known or {}
		for _, rec in ipairs(p.recipes) do if rec.name then known[rec.name] = true end end
		p.known, p.recipes = known, nil
	end
	return p
end

-- Nothing hides recipes in the window: no search text, no "have materials", no subclass / slot / level filter.
-- Anything unclear counts as filtered (then the scan only adds names, never drops them).
local function NoFilters()
	if TradeSkillFrameAvailableFilterCheckButton and TradeSkillFrameAvailableFilterCheckButton:GetChecked() then return false end
	if GetTradeSkillSubClassFilter and not GetTradeSkillSubClassFilter(0) then return false end
	if GetTradeSkillInvSlotFilter and not GetTradeSkillInvSlotFilter(0) then return false end
	if GetTradeSkillItemLevelFilter then
		local lo, hi = GetTradeSkillItemLevelFilter()
		if (lo and lo > 0) or (hi and hi > 0) then return false end
	end
	local box = TradeSkillFrameEditBox
	local text = box and box:GetText()
	if text and text ~= "" and text ~= SEARCH then return false end
	return true
end

-- -> true when rank, max or the set of learned recipes changed
local function DoScan(profName, rank, maxRank, expand)
	-- collapsed headers hide recipes — expand them, only when the window opens
	if expand then
		for i = GetNumTradeSkills(), 1, -1 do
			local _, kind, _, expanded = GetTradeSkillInfo(i)
			if kind == "header" and not expanded then ExpandTradeSkillSubClass(i) end
		end
	end
	local seen, full = {}, true
	-- headers of the profession window: db.cats[prof] = { rec = { [recipe] = header }, ord = { [header] = position } }
	local cats = DB().cats or {}
	DB().cats = cats
	local cat = cats[profName] or { rec = {}, ord = {} }
	cats[profName] = cat
	local hdr, pos = nil, 0
	for i = 1, GetNumTradeSkills() do
		local name, kind, _, expanded = GetTradeSkillInfo(i)
		if kind == "header" then
			if not expanded then full = false end
			if name then hdr = name; pos = pos + 1; cat.ord[name] = pos end
		elseif name then
			seen[name] = true
			if hdr then cat.rec[name] = hdr end
		end
	end
	if not next(seen) then full = false end -- an empty list is the window not filled yet, not "nothing learned"
	if full then
		local ok, res = pcall(NoFilters)
		full = ok and res
	end
	local profs = DB().profs
	local old = profs[profName] and MigrateProf(profs[profName])
	local oldKnown = old and old.known or {}
	-- a partial view (collapsed headers, filters) only adds names: what is hidden now stays known
	local known = seen
	if not full then
		for name in pairs(oldKnown) do known[name] = true end
	end
	local changed = not old or old.rank ~= rank or old.max ~= maxRank
	if not changed then
		for name in pairs(known) do if not oldKnown[name] then changed = true break end end
	end
	if not changed then
		for name in pairs(oldKnown) do if not known[name] then changed = true break end end
	end
	profs[profName] = { rank = rank, max = maxRank, scanned = time(), known = known }
	return changed
end

local scanning = false
function CP.ScanTradeSkill(expand)
	if scanning then return end
	if IsTradeSkillLinked and IsTradeSkillLinked() then return end -- someone else's profession via a link
	local profName, rank, maxRank = GetTradeSkillLine()
	if not profName or profName == "UNKNOWN" then return end
	scanning = true
	local ok, res = pcall(DoScan, profName, rank, maxRank, expand)
	scanning = false
	if not ok then
		CP.Print("|cffff4040ошибка:|r " .. tostring(res))
	elseif res then
		CP.Changed()
	end
end

-- The profession window sends updates often: rescan at most once every 2 seconds
-- (the last update isn't lost — we rescan once the 2 seconds have passed)
local SCAN_GAP = 2
local lastScan, scanDue = 0, nil
local scanTimer = CreateFrame("Frame")
scanTimer:Hide()
scanTimer:SetScript("OnUpdate", function(self)
	if GetTime() < scanDue then return end
	self:Hide()
	lastScan = GetTime()
	if TradeSkillFrame and TradeSkillFrame:IsShown() then CP.ScanTradeSkill(false) end
end)
function CP.NoteScan() lastScan = GetTime() end
function CP.ScanTradeSkillSoon()
	local now = GetTime()
	if now - lastScan >= SCAN_GAP and not scanTimer:IsShown() then
		lastScan = now
		CP.ScanTradeSkill(false)
	elseif not scanTimer:IsShown() then
		scanDue = lastScan + SCAN_GAP
		scanTimer:Show()
	end
end

-- Is the recipe learned (as of the last opening of the profession window): true or nil
function CP.KnownRecipe(prof, name)
	local db = DB()
	local p = db.profs[prof]
	if p then
		if p.recipes then MigrateProf(p) end
		if p.known and p.known[name] then return true end
	end
	-- just bought at the trainer: it marks the recipe as learned before the profession window is opened again
	local sk = CP.SKILL_ID[prof]
	local t = sk and db.learn and db.learn[sk] and db.learn[sk][name]
	if t and t.used then return true end
	return nil
end

----------------------------------------------------------------------------------------------
-- Trainer: which skill a recipe is learned at and its cost. learn[skill][name] = { req, cost }
local function ScanTrainer()
	if not (IsTradeskillTrainer and IsTradeskillTrainer()) then return end
	local db = DB()
	db.learn = db.learn or {}
	local changed = false
	for i = 1, GetNumTrainerServices() do
		local name, _, kind = GetTrainerServiceInfo(i)
		local ok, skill = pcall(GetTrainerServiceSkillLine, i)
		local sk = ok and skill and CP.SKILL_ID[skill]
		if name and sk and kind ~= "header" then
			local _, req = GetTrainerServiceSkillReq(i)
			local t = db.learn[sk] or {}
			db.learn[sk] = t
			local cost = GetTrainerServiceCost(i) or 0
			local old = t[name]
			local used = kind == "used" or nil -- already learned (the reminder drops it before the profession window is opened)
			if not (old and old.req == (req or 0) and old.cost == cost and old.used == used) then changed = true end
			t[name] = { req = req or 0, cost = cost, used = used }
		end
	end
	if changed then CP.Changed() end
end

-- Skill a recipe is learned at: the trainer, otherwise "Требуется: … (N)" in the recipe item's tooltip
-- (db.bookReq[item]); no data — nil
local reqTip, reqMiss, reqPrimed = nil, {}, {}
function CP.BookReq(item, prof)
	local db = DB()
	db.bookReq = db.bookReq or {}
	if db.bookReq[item] or reqMiss[item] then return db.bookReq[item] end
	reqTip = reqTip or CreateFrame("GameTooltip", "CraftPlanReqTip", UIParent, "GameTooltipTemplate")
	if not GetItemInfo(item) then
		-- not in the game cache yet: ask the server once (a hidden tooltip does it), resolve on a later call
		if not reqPrimed[item] then
			reqPrimed[item] = true
			reqTip:SetOwner(UIParent, "ANCHOR_NONE")
			reqTip:SetHyperlink("item:" .. item)
			reqTip:Hide()
		end
		return nil
	end
	reqMiss[item] = true -- no "Требуется" line — don't read the tooltip again this session
	reqTip:SetOwner(UIParent, "ANCHOR_NONE")
	reqTip:SetHyperlink("item:" .. item)
	for i = 2, reqTip:NumLines() do
		local fs = _G["CraftPlanReqTipTextLeft" .. i]
		local text = fs and fs:GetText()
		local n = text and text:find(prof, 1, true) and tonumber(text:match("%((%d+)%)"))
		if n then db.bookReq[item] = n break end
	end
	reqTip:Hide()
	return db.bookReq[item]
end

----------------------------------------------------------------------------------------------
-- Caches: every cache clear registers here (CP.OnDrop) and runs synchronously in CP.DropCache —
-- CP.Changed / CP.ChangedSettle call it at once, and the redraw tick calls it again before the listeners,
-- so a listener never sees a stale cache. Listeners (CP.OnChange) only redraw.
local droppers = {}
function CP.OnDrop(fn) droppers[#droppers + 1] = fn end
function CP.DropCache()
	for i = 1, #droppers do droppers[i]() end
end
CP.OnDrop(CP.DropSkillLines)

-- Redraw after changes: at most once per 0.3 s (BAG_UPDATE comes in bursts)
local listeners = {}
function CP.OnChange(fn) listeners[#listeners + 1] = fn end
local due
local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function(self)
	if GetTime() < due then return end
	self:Hide()
	if InCombatLockdown() then
		due = GetTime() + 1
		self:Show()
		return
	end
	CP.DropCache()
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn)
		if not ok then CP.Print("|cffff4040ошибка:|r " .. tostring(err)) end
	end
end)
function CP.Changed(delay)
	CP.DropCache()
	local t = GetTime() + (delay or 0.3)
	if not ticker:IsShown() or t < due then due = t end
	ticker:Show()
end
-- recalc sec after the LAST call (rapid "+"/"-" clicks — a single recalc)
function CP.ChangedSettle(sec)
	CP.DropCache()
	due = GetTime() + (sec or 0.5)
	ticker:Show()
end
-- one more recalc later (after a craft the game updates the skill with a delay)
local later = CreateFrame("Frame")
later:Hide()
later:SetScript("OnUpdate", function(self)
	if GetTime() < self.at then return end
	self:Hide()
	CP.Changed()
end)
function CP.ChangedLater(sec)
	later.at = GetTime() + (sec or 1.5)
	later:Show()
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "BAG_UPDATE", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "SKILL_LINES_CHANGED",
	"BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "TRAINER_SHOW", "TRAINER_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT" }) do
	events:RegisterEvent(e)
end
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		local db = DB()
		-- settings removed in 2.0
		db.allowChance, db.hideUseless, db.oreOff, db.nodeApplied, db.noBank = nil, nil, nil, nil, nil
		-- data of 0.x windows and features that no longer exist
		for _, k in ipairs({ "vendorStock", "trainers", "vendor", "probe", "map", "mapTab", "mapSize", "mapPos",
			"routeFold", "learnFull", "needShown", "apProf" }) do
			db[k] = nil
		end
		-- the fishing log moved to FishPlan: drop it once FishPlan has taken it over
		if FishPlanDB and FishPlanDB.migrated then db.fish = nil end
		-- learned recipes: full snapshots -> name sets
		for _, p in pairs(db.profs) do if type(p) == "table" then MigrateProf(p) end end
		if CP.OnLogin then CP.OnLogin() end
		CP.Changed()
	elseif event == "PLAYER_LOGOUT" then
		SaveBags()
	elseif event == "BANKFRAME_OPENED" then
		CP.bankIsOpen = true
		ScanBank()
		CP.Changed()
	elseif event == "BANKFRAME_CLOSED" then
		CP.bankIsOpen = false -- don't read: the bank is no longer available and would be saved as empty
	elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "BAG_UPDATE" then
		ScanBankSoon()
		CP.Changed()
	elseif event == "TRADE_SKILL_SHOW" then
		CP.DropSkillLines()
		CP.ScanTradeSkill(true)
		CP.NoteScan() -- expanding headers sends updates — don't rescan for them right away
	elseif event == "TRADE_SKILL_UPDATE" then
		CP.DropSkillLines()
		CP.ScanTradeSkillSoon()
	elseif event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
		pcall(ScanTrainer)
	else
		CP.Changed()
	end
end)

-- Select a recipe in the open profession window and fill in the count
function CP.SelectRecipe(prof, recipeName, count)
	if not (TradeSkillFrame and TradeSkillFrame:IsShown()) or GetTradeSkillLine() ~= prof then
		CP.Print("откройте окно профессии «" .. prof .. "» и щёлкните ещё раз.")
		return
	end
	for i = 1, GetNumTradeSkills() do
		local name, kind = GetTradeSkillInfo(i)
		if name == recipeName and kind ~= "header" then
			TradeSkillFrame_SetSelection(i)
			TradeSkillFrame_Update()
			if count and TradeSkillInputBox then TradeSkillInputBox:SetNumber(count) end
			return
		end
	end
	CP.Print("рецепт «" .. recipeName .. "» не найден в окне — снимите фильтры в окне профессии.")
end

SLASH_CRAFTPLAN1 = "/cplan"
SlashCmdList["CRAFTPLAN"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "min" then
		if CP.ToggleCollapsed then CP.ToggleCollapsed() end
	elseif msg == "reset" then
		DB().profs = {}
		CP.Print("рецепты забыты. Откройте окна профессий, чтобы аддон узнал их заново.")
		CP.Changed()
	elseif msg == "" or msg == "map" then
		if CP.ToggleWindow then CP.ToggleWindow() end
	else
		CP.Print(CP.VERSION .. ": /cplan — окно, /cplan min — свернуть полосу, /cplan reset — забыть рецепты.")
	end
end
