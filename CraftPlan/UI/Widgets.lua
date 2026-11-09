-- CraftPlan 2.0 — shared widgets, the same everywhere (search, checkboxes, dropdowns, icons, buttons, skill bar).
-- Canvas — an area redrawn as a whole: elements come from pools and are hidden on Reset.
local CP = CraftPlan
local W = {}
CP.W = W

W.WHITE = "Interface\\Buttons\\WHITE8X8"
W.GOLD = { 1, 0.82, 0 }

-- status icons (game textures)
W.TEX = {
	ok = "Interface\\RaidFrame\\ReadyCheck-Ready",         -- green check
	no = "Interface\\RaidFrame\\ReadyCheck-NotReady",      -- red cross
	alert = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew", -- "!" in a triangle
	info = "Interface\\FriendsFrame\\InformationIcon",     -- «i»
	question = "Interface\\GossipFrame\\IncompleteQuestIcon", -- grey "?"
	lock = "Interface\\LFGFrame\\UI-LFG-ICON-LOCK",          -- lock
	book = "Interface\\Icons\\INV_Misc_Book_09",            -- book: can be learned
	pencil = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up", -- edit (yellow note, as in the guild roster)
	clear = "Interface\\FriendsFrame\\ClearBroadcastIcon",  -- clear-field cross
	refresh = "Interface\\Buttons\\UI-RefreshButton",     -- circular arrow (LFR "refresh")
}

local function TipEnter(self)
	if self.onHover then self.onHover(true) end -- optional hover hook (schema highlight)
	if not (self.link or self.title or self.lines) then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if self.link then
		GameTooltip:SetHyperlink(self.link)
		if self.title or self.lines then GameTooltip:AddLine(" ") end
	end
	if self.title then GameTooltip:AddLine(self.title, 1, 0.82, 0) end
	for _, l in ipairs(self.lines or {}) do GameTooltip:AddLine(l, 1, 1, 1, true) end
	GameTooltip:Show()
end
local function TipLeave(self)
	GameTooltip:Hide()
	if self and self.onHover then self.onHover(false) end
end
-- Shared click handler. Right click: rightAction, or opts.where = item id — "where to get" (WhereToGet.lua)
local function OnClick(self, button)
	if button == "RightButton" then
		if self.rightAction then self.rightAction() return end
		if self.where then
			if WhereToGet_ShowItem then WhereToGet_ShowItem(self.where) end
			return
		end
	end
	if self.action then self.action() end
end
W.TipEnter, W.TipLeave, W.OnClick = TipEnter, TipLeave, OnClick

-- Natural width of a text in a font: one hidden (alpha 0) single-point font string per font
local measureFrame, measures = nil, {}
function W.Measure(text, font)
	font = font or "GameFontHighlightSmall"
	local fs = measures[font]
	if not fs then
		if not measureFrame then
			measureFrame = CreateFrame("Frame", nil, UIParent)
			measureFrame:SetWidth(1)
			measureFrame:SetHeight(1)
			measureFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
			measureFrame:SetAlpha(0)
		end
		fs = measureFrame:CreateFontString(nil, "OVERLAY", font)
		fs:SetPoint("TOPLEFT", measureFrame, "TOPLEFT", 0, 0) -- single point: no wrapping
		measures[font] = fs
	end
	fs:SetText(text)
	return fs:GetStringWidth()
end

-- Crafting steps grouped in one pass over the log: key(l) -> group key (nil — left out). Each group is exactly
-- CP.Steps(data, function(l) return key(l) == k end) (same merging of consecutive crafts) -> { [k] = steps }
function W.StepsBy(data, key)
	local out = {}
	for _, l in ipairs(data.log or {}) do
		local k = not (l.mid and l.to <= l.from) and key(l)
		if k then
			local list = out[k]
			if not list then list = {}; out[k] = list end
			local last = list[#list]
			if last and last.rec == l.rec and last.si == l.si then
				last.n = last.n + 1
				last.to = l.to
			else
				list[#list + 1] = { si = l.si, e = l.e, rec = l.rec, prof = l.prof, mid = l.mid, n = 1, from = l.from, to = l.to }
			end
		end
	end
	return out
end

----------------------------------------------------------------------------------------------
-- Canvas
local Canvas = {}
Canvas.__index = Canvas
function W.Canvas(content)
	return setmetatable({ content = content, pools = {} }, Canvas)
end
function Canvas:Pool(kind, make)
	local p = self.pools[kind]
	if not p then p = { n = 0 }; self.pools[kind] = p end
	p.n = p.n + 1
	local f = p[p.n]
	if not f then f = make(); p[p.n] = f end
	f:Show()
	return f
end
function Canvas:Reset()
	for _, p in pairs(self.pools) do
		for i = 1, #p do p[i]:Hide() end
		p.n = 0
	end
end
local function Place(self, f, x, y)
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", self.content, "TOPLEFT", x, y)
end

-- Text. justify — "LEFT" (default), "CENTER", "RIGHT" (then x is the right edge when width is set)
function Canvas:Text(text, x, y, font, width, justify, color)
	font = font or "GameFontHighlightSmall"
	local c = self.content
	local fs = self:Pool("text:" .. font, function() return c:CreateFontString(nil, "OVERLAY", font) end)
	Place(self, fs, x, y)
	fs:SetWidth(width or 0)
	fs:SetHeight(0)
	fs:SetJustifyH(justify or "LEFT")
	fs:SetText(text)
	if color then fs:SetTextColor(color[1], color[2], color[3]) else fs:SetTextColor(1, 1, 1) end
	fs:SetAlpha(1) -- from the pool: alpha may have been left over (dimmed schema labels)
	return fs
end

-- Solid-color rectangle
function Canvas:Rect(x, y, w, h, r, g, b, a, layer)
	local c = self.content
	local t = self:Pool("rect", function() return c:CreateTexture(nil, "ARTWORK") end)
	t:SetDrawLayer(layer or "ARTWORK") -- panels (Box) — BACKGROUND/BORDER, everything inside — ARTWORK/OVERLAY
	t:SetTexture(W.WHITE)
	t:SetVertexColor(r, g, b, a or 1)
	t:SetAlpha(1) -- from the pool: alpha may have been left over (dimmed schema lines)
	Place(self, t, x, y)
	t:SetWidth(math.max(1, w))
	t:SetHeight(math.max(1, h))
	return t
end
-- Panel: border (BACKGROUND layer) and fill (BORDER layer) — below everything drawn inside.
-- Returns a "set height" function (for panels whose height is known only at the end)
function Canvas:Box(x, y, w, h, bg, border, borderW)
	borderW = borderW or 1
	local o, i
	if border then
		o = self:Rect(x, y, w, h, border[1], border[2], border[3], border[4] or 1, "BACKGROUND")
		i = self:Rect(x + borderW, y - borderW, w - 2 * borderW, h - 2 * borderW, bg[1], bg[2], bg[3], bg[4] or 1, "BORDER")
	else
		i = self:Rect(x, y, w, h, bg[1], bg[2], bg[3], bg[4] or 1, "BORDER")
	end
	return function(nh)
		if o then o:SetHeight(math.max(1, nh)) end
		i:SetHeight(math.max(1, nh - (o and 2 * borderW or 0)))
	end
end

-- Invisible area button (click, tooltip), optional hover highlight
function Canvas:Area(x, y, w, h, opts)
	local c = self.content
	local b = self:Pool("area", function()
		local b = CreateFrame("Button", nil, c)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnEnter", TipEnter)
		b:SetScript("OnLeave", TipLeave)
		b:SetScript("OnClick", OnClick)
		b.hl = b:CreateTexture(nil, "HIGHLIGHT")
		b.hl:SetAllPoints(b)
		b.hl:SetTexture(W.WHITE)
		return b
	end)
	Place(self, b, x, y)
	b:SetWidth(w)
	b:SetHeight(h)
	b.hl:SetVertexColor(1, 0.82, 0, opts.hl and 0.06 or 0)
	b:SetFrameLevel(c:GetFrameLevel() + (opts.level or 1))
	b.link, b.title, b.lines, b.action, b.rightAction, b.where = opts.link, opts.title, opts.lines, opts.action, opts.rightAction, opts.where
	b.onHover, b.prOre = opts.hover, opts.prOre -- pooled: always overwrite
	return b
end

-- Regular game button (UIPanelButtonTemplate)
function Canvas:Button(text, x, y, w, h, opts)
	local c = self.content
	local b = self:Pool("btn", function()
		local b = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
		b:SetScript("OnEnter", TipEnter)
		b:SetScript("OnLeave", TipLeave)
		b:SetScript("OnClick", OnClick)
		return b
	end)
	b:SetText(text)
	b:SetWidth(w or (b:GetFontString():GetStringWidth() + 24))
	b:SetHeight(h or 22)
	Place(self, b, x, y)
	b:SetFrameLevel(c:GetFrameLevel() + 3)
	local fs = b:GetFontString()
	local col = opts.color or W.GOLD
	fs:SetTextColor(col[1], col[2], col[3])
	if opts.locked then b:LockHighlight() else b:UnlockHighlight() end
	b.link, b.title, b.lines, b.action = opts.link, opts.title, opts.lines, opts.action
	return b
end

-- Icon: texture (item/recipe), cropped edges, number bottom right
function Canvas:Icon(tex, x, y, size, opts)
	opts = opts or {}
	local c = self.content
	local b = self:Pool("icon", function()
		local b = CreateFrame("Button", nil, c)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b.bg = b:CreateTexture(nil, "BACKGROUND")
		b.bg:SetAllPoints(b)
		b.bg:SetTexture(W.WHITE)
		b.bg:SetVertexColor(0, 0, 0, 1)
		b.tex = b:CreateTexture(nil, "ARTWORK")
		b.tex:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
		b.tex:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
		b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
		b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		b:SetScript("OnEnter", TipEnter)
		b:SetScript("OnLeave", TipLeave)
		b:SetScript("OnClick", OnClick)
		return b
	end)
	b:SetWidth(size)
	b:SetHeight(size)
	Place(self, b, x, y)
	b:SetFrameLevel(c:GetFrameLevel() + (opts.level or 4))
	b.tex:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
	-- plain: a glyph icon without the black backing or cropping; on hover it highlights with the glyph itself
	local plain = opts.plain
	if plain then b.bg:Hide() else b.bg:Show() end
	b.tex:ClearAllPoints()
	local m = plain and 0 or 1
	b.tex:SetPoint("TOPLEFT", b, "TOPLEFT", m, -m)
	b.tex:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -m, m)
	if plain then b.tex:SetTexCoord(0, 1, 0, 1) else b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	b:SetHighlightTexture(plain and tex or "Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b.tex:SetDesaturated(opts.gray and true or false)
	local tc = opts.color -- tint {r, g, b}; pooled: always set
	if tc then b.tex:SetVertexColor(tc[1], tc[2], tc[3]) else b.tex:SetVertexColor(1, 1, 1) end
	b:SetAlpha(opts.alpha or 1)
	b.count:SetFontObject(size >= 30 and "NumberFontNormal" or "NumberFontNormalSmall")
	b.count:SetText(opts.count or "")
	local cc = opts.countColor
	if cc then b.count:SetTextColor(cc[1], cc[2], cc[3]) else b.count:SetTextColor(1, 1, 1) end
	b.link, b.title, b.lines, b.action, b.rightAction, b.where = opts.link, opts.title, opts.lines, opts.action, opts.rightAction, opts.where
	b.onHover = opts.hover
	if opts.locked then b:LockHighlight() else b:UnlockHighlight() end -- pooled: always set
	return b
end

-- Status icon (check, "!", "i", "?", lock, book)
function Canvas:Status(kind, x, y, size)
	local c = self.content
	local t = self:Pool("status", function() return c:CreateTexture(nil, "OVERLAY") end)
	t:SetTexture(W.TEX[kind])
	t:SetTexCoord(0, 1, 0, 1)
	t:SetDesaturated(false)
	t:SetVertexColor(1, 1, 1, 1)
	t:SetAlpha(1) -- from the pool: alpha may have been left over (dimmed tiles)
	if kind == "book" then t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	if kind == "lock" or kind == "question" then t:SetDesaturated(true) end
	Place(self, t, x, y)
	t:SetWidth(size or 14)
	t:SetHeight(size or 14)
	return t
end

-- Item chips in rows: icon + label, wrapped to x0 when a chip would pass maxX. Starts at x on row y; returns the
-- y of the last row. items = { { id, label, color, lines, where } }. boxed: on a dark plate (18 px icon, rows 28 px
-- apart), otherwise bare (16 px icon, rows 22 px apart)
function Canvas:Chips(items, x, y, x0, maxX, boxed)
	for _, it in ipairs(items) do
		local tw = W.Measure(it.label, "GameFontHighlightSmall")
		local opts = { link = "item:" .. it.id, lines = it.lines, where = it.where }
		if boxed then
			local w = 26 + tw + 14
			if x + w > maxX then x = x0; y = y - 28 end
			self:Rect(x, y, w, 24, 0.16, 0.13, 0.09, 1)
			self:Icon(CP.ItemIcon(it.id), x + 3, y - 3, 18, opts)
			self:Text(it.label, x + 26, y - 6, "GameFontHighlightSmall", nil, nil, it.color)
			x = x + w + 6
		else
			local w = 20 + tw + 12
			if x + w > maxX then x = x0; y = y - 22 end
			self:Icon(CP.ItemIcon(it.id), x, y, 16, opts)
			self:Text(it.label, x + 20, y - 3, "GameFontHighlightSmall", nil, nil, it.color)
			x = x + w
		end
	end
	return y
end

-- "-" and "+" buttons (standard game textures)
function Canvas:PlusMinus(kind, x, y, action, tip)
	local c = self.content
	local b = self:Pool("pm", function()
		local b = CreateFrame("Button", nil, c)
		b:SetWidth(16)
		b:SetHeight(16)
		b:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
		b:SetScript("OnEnter", TipEnter)
		b:SetScript("OnLeave", TipLeave)
		b:SetScript("OnClick", OnClick)
		return b
	end)
	b:SetNormalTexture("Interface\\Buttons\\UI-" .. kind .. "Button-Up")
	b:SetPushedTexture("Interface\\Buttons\\UI-" .. kind .. "Button-Down")
	Place(self, b, x, y)
	b:SetFrameLevel(c:GetFrameLevel() + 5)
	b.action, b.lines, b.title, b.link = action, tip and { tip } or nil, nil, nil
	return b
end

-- Skill bar 0–450: filled up to the skill (dark→light green gradient), a light segment for the gain,
-- black after the learned max, a gold tick at the max. Above: skill, total, max — each at its point, in a row
-- without overlapping (max is not repeated when the skill or the total is on it; total at max colors the max).
-- Below, from the skill point: gain parts in their colors — orange exact, yellow and green expected.
-- q = { o, y, g, ym, gm } (CP.RoundGain rounds it); tip = { title, lines } — tooltip over the bar (optional)
function Canvas:SkillBar(x, y, w, rank, max, q, tip)
	local TOP = CP.TOP_SKILL
	local h = 12
	local function px(v) return math.floor(v / TOP * w + 0.5) end
	local rg = CP.RoundGain(q)
	local gain = math.max(0, math.min(rg.t, max - rank))
	local labelY = y
	local barY = y - 16
	self:Rect(x, barY, w, h, 0.2, 0.18, 0.14, 1, "ARTWORK") -- track; everything else is OVERLAY on top
	local f = px(rank)
	if f > 0 then
		local t = self:Rect(x, barY, f, h, 1, 1, 1, 1, "OVERLAY")
		local k = rank / TOP
		t:SetGradient("HORIZONTAL", 0.12, 0.42, 0.12, 0.12 + 0.31 * k, 0.42 + 0.58 * k, 0.12 + 0.31 * k)
	end
	if gain > 0 then
		self:Rect(x + f, barY, math.max(1, px(rank + gain) - f), h, 0.55, 1, 0.55, 0.65, "OVERLAY")
	end
	if max < TOP then
		self:Rect(x + px(max), barY, w - px(max), h, 0, 0, 0, 1, "OVERLAY")
		self:Rect(x + px(max) - 1, barY, 2, h, 1, 0.82, 0, 1, "OVERLAY")
	end
	-- a row of labels: desired left edges, then pushed right (no overlap) and back from the right edge
	local function Row(list, yy, x0, x1)
		local prevR = x0 - 4
		for _, l in ipairs(list) do
			l.fs = self:Text(l.text, 0, yy, l.font or "GameFontHighlightSmall", nil, nil, l.color)
			l.w = l.fs:GetStringWidth()
			l.x = math.max(x0, l.want or x0, prevR + 4)
			prevR = l.x + l.w
		end
		local lim = x1
		for i = #list, 1, -1 do
			local l = list[i]
			l.x = math.max(x0, math.min(l.x, lim - l.w))
			lim = l.x - 4
		end
		for _, l in ipairs(list) do
			l.fs:ClearAllPoints()
			l.fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", l.x, yy)
		end
		return list
	end
	local total = rank + gain
	local atMax = gain > 0 and total == max and max < TOP
	local GREEN = { 0.55, 1, 0.55 }
	local top = {}
	top[#top + 1] = { text = tostring(rank), color = { 1, 1, 1 }, want = x + f - W.Measure(tostring(rank), "GameFontHighlightSmall") - 3 }
	if gain > 0 and not atMax then top[#top + 1] = { text = tostring(total), color = GREEN, font = "GameFontNormalSmall", want = x + px(total) + 3 } end
	if max < TOP and max ~= rank then
		top[#top + 1] = { text = tostring(max), color = atMax and GREEN or { 0.78, 0.72, 0.56 }, font = atMax and "GameFontNormalSmall" or nil,
			want = x + px(max) - W.Measure(tostring(max), "GameFontHighlightSmall") / 2 }
	end
	Row(top, labelY, x, x + w)
	local first, last = top[1], top[#top]
	if first.x > x + 16 then self:Text("0", x, labelY, "GameFontDisableSmall", nil, nil, { 0.43, 0.4, 0.34 }) end
	if max < TOP and last.x + last.w < x + w - 28 then
		local fs = self:Text(tostring(TOP), 0, labelY, "GameFontDisableSmall", nil, nil, { 0.43, 0.4, 0.34 })
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", x + w - fs:GetStringWidth(), labelY)
	end
	-- gain parts under the bar, from the skill point
	if tip then self:Area(x, barY + 2, w, h + 4, { level = 2, title = tip.title, lines = tip.lines }) end
	local parts = {}
	for _, p in ipairs(CP.GainParts(q)) do
		parts[#parts + 1] = { text = p.text, color = p.color, font = "GameFontNormalSmall", want = x + f }
	end
	if parts[1] then
		Row(parts, barY - h - 2, x, x + w)
		return barY - h - 18
	end
	return barY - h - 4
end

----------------------------------------------------------------------------------------------
-- Search box: the game's input frame + clear cross (game texture), visible only when there is text
function W.SearchBox(parent, name, width, onChange)
	local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
	box:SetAutoFocus(false)
	box:SetWidth(width)
	box:SetHeight(20)
	box:SetTextInsets(0, 18, 0, 0)
	local clear = CreateFrame("Button", nil, box)
	clear:SetWidth(14)
	clear:SetHeight(14)
	clear:SetPoint("RIGHT", box, "RIGHT", -3, 0)
	clear:SetNormalTexture(W.TEX.clear)
	clear:SetHighlightTexture(W.TEX.clear, "ADD")
	clear:Hide()
	clear:SetScript("OnClick", function() box:SetText(""); box:ClearFocus() end)
	clear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Очистить")
		GameTooltip:Show()
	end)
	clear:SetScript("OnLeave", TipLeave)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	box:SetScript("OnTextChanged", function(self)
		local t = self:GetText() or ""
		if t ~= "" then clear:Show() else clear:Hide() end
		if onChange then onChange(t) end
	end)
	return box
end

-- Checkbox with a label (UICheckButtonTemplate)
function W.Check(parent, name, label, get, set, tip)
	local b = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	b:SetWidth(22)
	b:SetHeight(22)
	local fs = _G[name .. "Text"]
	fs:SetText(label)
	fs:SetFontObject("GameFontHighlightSmall")
	-- a bit more room after the box; the label is centered on the box (+1: the font sits low)
	fs:ClearAllPoints()
	fs:SetPoint("LEFT", b, "RIGHT", 3, 1)
	b:SetScript("OnShow", function(self) self:SetChecked(get()) end)
	b:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	if tip then
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(label)
			GameTooltip:AddLine(tip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", TipLeave)
	end
	b.label = fs
	b.Refresh = function() b:SetChecked(get()) end
	return b
end

-- Dropdown: items = { { key, text } }
function W.Dropdown(parent, name, width, items, get, set)
	local d = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
	UIDropDownMenu_SetWidth(d, width)
	local function TextOf(key)
		for _, it in ipairs(items) do if it[1] == key then return it[2] end end
		return items[1][2]
	end
	UIDropDownMenu_Initialize(d, function(self, level)
		for _, it in ipairs(items) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = it[2]
			info.checked = (get() == it[1])
			info.func = function()
				set(it[1])
				_G[name .. "Text"]:SetText(it[2])
				CloseDropDownMenus()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end)
	d.Refresh = function() _G[name .. "Text"]:SetText(TextOf(get())) end
	d.Refresh()
	return d
end

-- Game-style frame: dark opaque background, dialog border
function W.Backdrop(f)
	f:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
	f:SetBackdropColor(0.06, 0.06, 0.06, 1)
end

-- Step for "- N +": Shift — by 10
function W.Step() return IsShiftKeyDown() and 10 or 1 end
