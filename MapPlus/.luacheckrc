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
	"MapPlusDB", "MapPlusFogData", "SLASH_MAPPLUS1", "SlashCmdList",
}

-- Только читаем: API и фреймы игры, другие аддоны, свои глобальные из других файлов и имена фреймов.
-- Новое имя, которого здесь нет, luacheck покажет — опечатка или его надо дописать сюда
read_globals = {
	"CreateFrame", "DEFAULT_CHAT_FRAME", "GameTooltip", "GetCurrentMapAreaID",
	"GetCurrentMapContinent", "GetCurrentMapDungeonLevel", "GetMapInfo", "GetMapOverlayInfo",
	"GetNumMapOverlays", "GetPlayerMapPosition", "hooksecurefunc", "Questie", "QuestieCompat",
	"QuestieLoader", "SetDungeonMapLevel", "SetMapByID", "SetMapToCurrentZone", "SetMapZoom",
	"TomTom", "UnitFactionGroup", "WorldMapDetailFrame", "WorldMapFrame",
}
