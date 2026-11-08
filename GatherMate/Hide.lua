-- patched: hide mining nodes for their respawn time.
-- Reached a node and walked away: hidden (gathered, or empty - taken by
-- someone). Hovering the vein in the world or a "skill too low" error proves
-- it is there, so it stays.
local GatherMate = LibStub("AceAddon-3.0"):GetAddon("GatherMate")

local TYPE = "Mining"
local NEAR = 30            -- yards from the stored point that count as "at the node"
local DEF_RESPAWN = 900    -- vein not in Respawn.lua
local TICK = 0.5

local miningSpell = (GetSpellInfo(2575))
local tipText = _G["GameTooltipTextLeft1"]
local watch = {}           -- key -> {zone, coord, id, t, present, gathered}
local hidden               -- SV: key -> unix time when the node shows again

local function Key(zone, coord) return zone .. "|" .. coord end

function GatherMate:IsNodeHidden(nodeType, zone, coord)
	if nodeType ~= TYPE or not hidden then return false end
	local k = Key(zone, coord)
	local t = hidden[k]
	if t ~= nil and t > time() then return true end
	-- visited and about to be hidden: do not flash it on the way out
	local w = watch[k]
	return w ~= nil and (w.gathered or not w.present)
end

local function Respawn(id, zone, coord)
	local R = GatherMate_Respawn and GatherMate_Respawn[GatherMate:GetNameForNode(TYPE, id) or ""]
	if not R then return DEF_RESPAWN end
	local z = R[zone]
	if not z then return R["*"] or DEF_RESPAWN end
	local x, y = GatherMate:getXY(coord)
	x, y = x * 100, y * 100
	for i = 2, #z do
		local e = z[i]
		if math.abs(e[1] - x) <= 1.5 and math.abs(e[2] - y) <= 1.5 then return e[3] end
	end
	return z[1]
end

local function Refresh()
	local D = GatherMate:GetModule("Display", true)
	if D then
		D:UpdateMiniMap(true)
		D:UpdateWorldMap(true)
	end
end

local function Hide(w)
	hidden[Key(w.zone, w.coord)] = time() + Respawn(w.id, w.zone, w.coord)
	watch[Key(w.zone, w.coord)] = nil
	Refresh()
end

local function Here()
	local zone = GatherMate:ResolveZone(GetRealZoneText())
	if not zone or zone == "" or not rawget(GatherMate.zoneData, zone) then return end
	local x, y = GetPlayerMapPosition("player")
	if x == 0 and y == 0 then return end
	return zone, x, y
end

-- nearest watched node to the player (the one being mined or hovered)
local function Nearest(radius)
	local zone, x, y = Here()
	if not zone then return end
	local best, bestID, bd
	for coord, id in GatherMate:FindNearbyNode(zone, x, y, TYPE, radius, true) do
		local nx, ny = GatherMate:getXY(coord)
		local d = GatherMate:NodeDistanceSquared(x, y, nx, ny, zone)
		if not bd or d < bd then best, bestID, bd = coord, id, d end
	end
	if not best then return end
	local k = Key(zone, best)
	local w = watch[k]
	if not w then
		w = { zone = zone, coord = best, id = bestID, t = GetTime() }
		watch[k] = w
	end
	return w
end

-- the vein is there: keep it shown, even if it was hidden
local function Present()
	local w = Nearest(NEAR + 5)
	if not w then return end
	w.present = true
	local k = Key(w.zone, w.coord)
	if hidden[k] then hidden[k] = nil; Refresh() end
end

local function Tick()
	local now = time()
	local expired
	for k, t in pairs(hidden) do
		if t <= now then hidden[k] = nil; expired = true end
	end
	if expired then Refresh() end

	local zone, x, y = Here()
	if not zone then return end
	local near = {}
	for coord, id in GatherMate:FindNearbyNode(zone, x, y, TYPE, NEAR, true) do
		local k = Key(zone, coord)
		if not hidden[k] then
			near[k] = true
			if not watch[k] then
				watch[k] = { zone = zone, coord = coord, id = id, t = GetTime() }
			end
		end
	end
	for k, w in pairs(watch) do
		if not near[k] then
			if w.present and not w.gathered then watch[k] = nil else Hide(w) end
		end
	end
end

local f = CreateFrame("Frame")
local acc = 0
f:SetScript("OnUpdate", function(_, e)
	acc = acc + e
	if acc < TICK or not hidden then return end
	acc = 0
	Tick()
end)
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("UI_ERROR_MESSAGE")
f:SetScript("OnEvent", function(_, ev, a1, a2)
	if ev == "PLAYER_LOGIN" then
		GatherMate.db.char.hiddenNodes = GatherMate.db.char.hiddenNodes or {}
		hidden = GatherMate.db.char.hiddenNodes
		Refresh()
	elseif not hidden then
		return
	elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
		if a1 == "player" and a2 == miningSpell then
			local w = Nearest(NEAR + 5)
			if w then w.gathered = true end
		end
	elseif ev == "UI_ERROR_MESSAGE" then
		if a1 and miningSpell and a1:find(miningSpell, 1, true) then
			Present()
		end
	end
end)

-- hovering the vein itself in the world proves it is still there
GameTooltip:HookScript("OnShow", function(self)
	if not hidden or self:GetUnit() or MouseIsOver(MinimapCluster) then return end
	local text = tipText:GetText()
	if text and GatherMate:GetIDForNode(TYPE, text) then
		Present()
	end
end)

-- /gmh: what the hider sees right now
SLASH_GMHIDE1 = "/gmh"
SlashCmdList.GMHIDE = function()
	local p = function(...) DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00GM hide:|r " .. string.format(...)) end
	if not hidden then p("не запущен (нет PLAYER_LOGIN)") return end
	local zone, x, y = Here()
	if not zone then p("зона не найдена: %s", tostring(GetRealZoneText())) return end
	local nh, nw = 0, 0
	for _ in pairs(hidden) do nh = nh + 1 end
	for _ in pairs(watch) do nw = nw + 1 end
	p("%s %.1f,%.1f  скрыто %d, рядом %d", zone, x * 100, y * 100, nh, nw)
	local best, bd, bid
	for coord, id in GatherMate:FindNearbyNode(zone, x, y, TYPE, 200, true) do
		local nx, ny = GatherMate:getXY(coord)
		local d = GatherMate:Distance(x, y, nx, ny, zone)
		if not bd or d < bd then best, bd, bid = coord, d, id end
	end
	if best then
		local w = watch[Key(zone, best)]
		p("ближайшая: %s, %d ярд., респ %d с, %s", GatherMate:GetNameForNode(TYPE, bid) or "?", bd,
			Respawn(bid, zone, best), w and ((w.gathered and "добыта") or (w.present and "руда есть") or "отслеживается") or "нет")
	else
		p("руды в 200 ярдах нет")
	end
end
