-- GearPlan: what is worn (links carry enchant and gems), equipment sets (they live on the server, not in WTF),
-- wearable items in the bags, character stats and the stats of every item - written to SavedVariables for
-- Tools/gear.py (make gear) outside the game.
-- GearPlanDB.gear = { [slot 1-19] = link }, gearTime; GearPlanDB.equipSets = { { name, icon, items = { [slot] = itemID } } }
-- (itemID 0 - empty, 1 - the set leaves the slot alone); GearPlanDB.bagGear = { link, ... }
-- GearPlanDB.stats = { stat1..5, health, ap, rating = { [CR] = n }, ... } (with the buffs at save time)
-- GearPlanDB.itemInfo = { [link] = { ilvl, type, slot, stats = { [label] = n }, effects = { text } } }
-- On Sirus the bags and the worn items are already gone at PLAYER_LOGOUT: saved while playing (2 s after login and
-- after changes), at logout only what is still there.

local function DB()
	GearPlanDB = GearPlanDB or {}
	return GearPlanDB
end

local function WearLinks(bag, into)
	for slot = 1, GetContainerNumSlots(bag) or 0 do
		local link = GetContainerItemLink(bag, slot)
		if link and IsEquippableItem(link) then into[#into + 1] = link end
	end
	return into
end

-- ---------------------------------------------------------------------------------------------
-- character stats
local function Stats()
	local s = {}
	s.level, s.class, s.race = UnitLevel("player"), UnitClass("player"), UnitRace("player")
	local talents = {}
	for i = 1, GetNumTalentTabs() or 0 do
		local _, _, spent = GetTalentTabInfo(i)
		talents[#talents + 1] = spent or 0
	end
	s.talents = table.concat(talents, "/")
	for i = 1, 5 do
		local _, v = UnitStat("player", i)
		s["stat" .. i] = v
	end
	s.health, s.mana = UnitHealthMax("player"), UnitPowerMax("player", 0)
	s.armor = select(2, UnitArmor("player"))
	local b, p, n = UnitAttackPower("player")
	s.ap = b + p + n
	b, p, n = UnitRangedAttackPower("player")
	s.rap = b + p + n
	s.speedMain, s.speedOff = UnitAttackSpeed("player")
	s.dmgMin, s.dmgMax, s.dmgOffMin, s.dmgOffMax = UnitDamage("player")
	local _, rspeed, rmin, rmax = UnitRangedDamage("player")
	s.speedRanged, s.dmgRangedMin, s.dmgRangedMax = rspeed, rmin, rmax
	s.critMelee, s.critRanged = GetCritChance(), GetRangedCritChance()
	s.spellCrit, s.spellPower, s.res = {}, {}, {}
	for school = 2, 7 do
		s.spellCrit[school] = GetSpellCritChance(school)
		s.spellPower[school] = GetSpellBonusDamage(school)
	end
	s.healing = GetSpellBonusHealing()
	s.spellPen = GetSpellPenetration and GetSpellPenetration()
	b, p = GetManaRegen()
	s.mp5, s.mp5Casting = (b or 0) * 5, (p or 0) * 5
	b, p = UnitDefense("player")
	s.defense = (b or 0) + (p or 0)
	s.dodge, s.parry, s.block = GetDodgeChance(), GetParryChance(), GetBlockChance()
	s.blockValue = GetShieldBlock()
	s.expertise = GetExpertise()
	s.armorPen = GetArmorPenetration and GetArmorPenetration()
	for i = 1, 6 do
		local _, total = UnitResistance("player", i)
		s.res[i] = total
	end
	s.rating, s.ratingBonus = {}, {}
	for cr = 1, 25 do
		s.rating[cr] = GetCombatRating(cr)
		s.ratingBonus[cr] = GetCombatRatingBonus(cr)
	end
	return s
end

-- ---------------------------------------------------------------------------------------------
-- item stats: GetItemStats (base stats, sockets) and the effect lines of the tooltip
local tip
local function Tip()
	tip = tip or CreateFrame("GameTooltip", "GearPlanScanTip", nil, "GameTooltipTemplate")
	tip:SetOwner(WorldFrame, "ANCHOR_NONE")
	return tip
end

local prefixes
local function IsEffect(text)
	if not prefixes then
		prefixes = {}
		for _, k in ipairs({ "ITEM_SPELL_TRIGGER_ONEQUIP", "ITEM_SPELL_TRIGGER_ONUSE", "ITEM_SPELL_TRIGGER_ONPROC",
			"ITEM_SOCKET_BONUS", "ITEM_SET_BONUS" }) do
			local v = type(_G[k]) == "string" and _G[k]:gsub("%%.*$", "")
			if v and v ~= "" then prefixes[#prefixes + 1] = v end
		end
	end
	local s = text:gsub("^%(%d+%) ", "")
	for _, p in ipairs(prefixes) do
		if s:sub(1, #p) == p then return true end
	end
end

local function ItemInfo(link)
	local _, _, _, ilvl, _, _, subType, _, equipLoc = GetItemInfo(link)
	if not ilvl then return nil end -- not in the client cache yet
	local info = { ilvl = ilvl, type = subType, slot = equipLoc and _G[equipLoc] or equipLoc, stats = {}, effects = {} }
	if GetItemStats then
		for key, v in pairs(GetItemStats(link) or {}) do
			info.stats[type(_G[key]) == "string" and _G[key] or key] = v
		end
	end
	local t = Tip()
	t:ClearLines()
	t:SetHyperlink(link)
	for i = 2, t:NumLines() do
		local fs = _G["GearPlanScanTipTextLeft" .. i]
		local text = fs and fs:GetText()
		if text and IsEffect(text) then info.effects[#info.effects + 1] = text end
	end
	t:Hide()
	return info
end

local infoCache = {}
local function Infos(lists)
	local out = {}
	for _, list in ipairs(lists) do
		for _, link in pairs(list) do
			if not out[link] then
				infoCache[link] = infoCache[link] or ItemInfo(link)
				out[link] = infoCache[link]
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------
-- atLogout: an empty read keeps what was saved; stats and item stats only while playing
local function Save(atLogout)
	local db = DB()
	local gear, any = {}, false
	for slot = 1, 19 do
		gear[slot] = GetInventoryItemLink("player", slot)
		any = any or gear[slot] ~= nil
	end
	if any or not atLogout then db.gear, db.gearTime = gear, time() end
	local sets = {}
	for i = 1, GetNumEquipmentSets() do
		local name, icon = GetEquipmentSetInfo(i)
		if name then sets[#sets + 1] = { name = name, icon = icon, items = GetEquipmentSetItemIDs(name) } end
	end
	if sets[1] or not atLogout then db.equipSets = sets end
	local bags = {}
	for bag = 0, NUM_BAG_SLOTS do WearLinks(bag, bags) end
	if bags[1] or not atLogout then db.bagGear = bags end
	if atLogout then return end
	local ok, stats = pcall(Stats)
	if ok then db.stats = stats end
	local ok2, infos = pcall(Infos, { gear, bags })
	if ok2 then db.itemInfo = infos end
end

-- while playing: 2 s after the last change
local f = CreateFrame("Frame")
f:Hide()
f:SetScript("OnUpdate", function(self)
	if GetTime() < self.at then return end
	self:Hide()
	Save()
end)
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED", "EQUIPMENT_SETS_CHANGED", "BAG_UPDATE",
	"PLAYER_LEVEL_UP", "CHARACTER_POINTS_CHANGED", "PLAYER_LOGOUT" }) do
	f:RegisterEvent(e)
end
f:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_LOGOUT" then
		Save(true)
	else
		self.at = GetTime() + 2
		self:Show()
	end
end)
