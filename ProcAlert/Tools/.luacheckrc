-- luacheck для make lint. Lua 5.1, как в WoW 3.3.5
std = "lua51"
max_line_length = false
ignore = {
	"212", -- неиспользуемый аргумент (обработчики событий)
	"431", -- локальная переменная перекрывает внешнюю
	"542", -- пустая ветка if
}

-- Глобальные, которые аддон создаёт или меняет
globals = {
	"ProcAlertDB", "SLASH_PROCALERT1", "SlashCmdList",
}

-- Только читаем: API и фреймы игры, другие аддоны, свои глобальные из других файлов и имена фреймов.
-- Новое имя, которого здесь нет, luacheck покажет — опечатка или его надо дописать сюда
read_globals = {
	"bit", "BOOKTYPE_SPELL", "C_NamePlate", "CanInspect", "CheckInteractDistance",
	"COMBATLOG_OBJECT_REACTION_HOSTILE", "CreateFrame", "DEFAULT_CHAT_FRAME", "GameTooltip",
	"GetActionInfo", "GetBindingKey", "GetBindingText", "GetBonusBarOffset", "GetContainerItemInfo",
	"GetContainerItemLink", "GetContainerNumSlots", "GetInventoryItemLink", "GetInventoryItemTexture",
	"GetItemInfo", "GetMacroSpell", "GetNumPartyMembers", "GetNumRaidMembers", "GetNumSpellTabs",
	"GetNumTalents", "GetNumTalentTabs", "GetShapeshiftForm", "GetShapeshiftFormInfo",
	"GetSpellCooldown", "GetSpellInfo", "GetSpellName", "GetSpellTabInfo", "GetSpellTexture",
	"GetTalentInfo", "GetTalentTabInfo", "GetTime", "HasAction", "hooksecurefunc", "InspectFrame",
	"IsCurrentSpell", "IsPassiveSpell", "IsSpellInRange", "IsUsableSpell", "NotifyInspect",
	"PlaySound", "SetPortraitTexture", "SetPortraitToTexture", "ShapeshiftButton1",
	"SPELL_RECAST_TIME_MIN", "SPELL_RECAST_TIME_SEC", "tinsert", "tremove", "UIParent",
	"UIParent_ManageFramePositions", "UnitAffectingCombat", "UnitAttackSpeed", "UnitBuff",
	"UnitCanAttack", "UnitCastingInfo", "UnitChannelInfo", "UnitClassification", "UnitDebuff",
	"UnitDetailedThreatSituation", "UnitExists", "UnitGUID", "UnitHealth", "UnitHealthMax",
	"UnitIsDead", "UnitIsDeadOrGhost", "UnitIsFriend", "UnitIsPlayer", "UnitIsUnit", "UnitLevel",
	"UnitMana", "UnitName", "UnitPower", "UnitPowerMax", "wipe", "WorldFrame",
}
