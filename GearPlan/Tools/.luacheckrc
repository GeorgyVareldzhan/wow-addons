-- luacheck для make lint. Lua 5.1, как в WoW 3.3.5
std = "lua51"
max_line_length = false
ignore = {
	"212", -- неиспользуемый аргумент (обработчики событий)
}

-- Глобальные, которые аддон создаёт или меняет
globals = { "GearPlanDB" }

-- API игры
read_globals = {
	"CreateFrame", "GetContainerItemLink", "GetContainerNumSlots", "GetEquipmentSetInfo", "GetEquipmentSetItemIDs",
	"GetInventoryItemLink", "GetNumEquipmentSets", "GetTime", "IsEquippableItem", "NUM_BAG_SLOTS", "time",
	"GetArmorPenetration", "GetBlockChance", "GetCombatRating", "GetCombatRatingBonus", "GetCritChance", "GetDodgeChance",
	"GetExpertise", "GetItemInfo", "GetItemStats", "GetManaRegen", "GetNumTalentTabs", "GetParryChance",
	"GetRangedCritChance", "GetShieldBlock", "GetSpellBonusDamage", "GetSpellBonusHealing", "GetSpellCritChance",
	"GetSpellPenetration", "GetTalentTabInfo", "UnitArmor", "UnitAttackPower", "UnitAttackSpeed", "UnitClass",
	"UnitDamage", "UnitDefense", "UnitHealthMax", "UnitLevel", "UnitPowerMax", "UnitRace", "UnitRangedAttackPower",
	"UnitRangedDamage", "UnitResistance", "UnitStat", "WorldFrame",
}
