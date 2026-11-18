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
	"CraftPlan", "CraftPlan_ProspectData", "CraftPlan_Trainers", "CraftPlan_VeinData", "CraftPlanDB",
	"CraftPlanItemType", "CraftPlanRouteData", "CraftPlanSubName", "CraftPlanThresholds",
	"SLASH_CRAFTPLAN1", "SLASH_WHERETOGET1", "SlashCmdList", "StaticPopupDialogs",
	"WhereToGet_ClearAll", "WhereToGet_IsShown", "WhereToGet_OpenMapAt", "WhereToGet_ShowItem",
	"WhereToGet_ShowNPCs", "WhereToGet_UpdateButton", "WhereToGetDB",
}

-- Только читаем: API и фреймы игры, другие аддоны, свои глобальные из других файлов и имена фреймов.
-- Новое имя, которого здесь нет, luacheck покажет — опечатка или его надо дописать сюда
read_globals = {
	"BANK_CONTAINER", "BuyMerchantItem", "BuyTrainerService", "ChatEdit_GetActiveWindow",
	"ChatEdit_InsertLink", "CLASS_TRAINER_SKILLS_DISPLAYED", "ClassTrainerFrame",
	"ClassTrainerFrame_Update", "ClassTrainerTrainButton", "ClearCursor", "CloseDropDownMenus",
	"CopyTable", "CraftPlanBar", "CraftPlanWindow", "CreateFrame", "DEFAULT_CHAT_FRAME",
	"DressUpItemLink", "ExpandTradeSkillSubClass", "FauxScrollFrame_GetOffset",
	"FauxScrollFrame_OnVerticalScroll", "FauxScrollFrame_SetOffset", "FauxScrollFrame_Update",
	"FishPlanDB", "GameTooltip", "GameTooltip_ShowCompareItem", "GatherMate", "GetContainerItemInfo",
	"GetContainerItemLink", "GetContainerNumSlots", "GetCursorInfo", "GetCursorPosition",
	"GetEquipmentSetInfo", "GetEquipmentSetItemIDs", "GetInventoryItemLink", "GetNumEquipmentSets",
	"GetCVarBool", "GetItemCount", "GetItemIcon", "GetItemInfo", "GetMerchantItemInfo",
	"GetMerchantItemLink", "GetMerchantItemMaxStack", "GetMerchantNumItems", "GetMinimapShape",
	"GetMoney", "GetNumSkillLines", "GetNumTradeSkills", "GetNumTrainerServices", "GetRealZoneText",
	"GetSkillLineInfo", "GetSpellInfo", "GetTime", "GetTradeSkillInfo", "GetTradeSkillInvSlotFilter",
	"GetTradeSkillItemLevelFilter", "GetTradeSkillLine", "GetTradeskillRepeatCount",
	"GetTradeSkillSubClassFilter", "GetTrainerServiceCost", "GetTrainerServiceInfo",
	"GetTrainerServiceSkillLine", "GetTrainerServiceSkillReq", "hooksecurefunc", "InCombatLockdown",
	"IsAddOnLoaded", "IsControlKeyDown", "IsEquippableItem", "IsModifiedClick", "IsShiftKeyDown",
	"IsTradeSkillLinked", "IsTradeskillTrainer", "ItemRefTooltip", "MERCHANT_ITEMS_PER_PAGE",
	"MerchantFrame", "MerchantFrame_UpdateMerchantInfo", "Minimap", "MouseIsOver", "NO",
	"NUM_BAG_SLOTS", "NUM_BANKBAGSLOTS", "OpenStackSplitFrame", "QuestieCompat", "QuestieLoader",
	"SEARCH", "SetMapZoom", "ShoppingTooltip1", "ShoppingTooltip2", "ShoppingTooltip3", "ShowUIPanel",
	"StackSplitFrame", "StaticPopup_Show", "strsplit", "time", "tinsert", "ToggleFrame",
	"TRADE_SKILLS_DISPLAYED", "TradeSkillFrame", "TradeSkillFrame_SetSelection",
	"TradeSkillFrame_Update", "TradeSkillFrameAvailableFilterCheckButton", "TradeSkillFrameEditBox",
	"TradeSkillInputBox", "UIDropDownMenu_AddButton", "UIDropDownMenu_CreateInfo",
	"UIDropDownMenu_Initialize", "UIDropDownMenu_SetWidth", "UIParent", "UISpecialFrames",
	"UnitCastingInfo", "UnitFactionGroup", "UnitLevel", "UnitName", "wipe", "WorldMapFrame", "YES",
}
