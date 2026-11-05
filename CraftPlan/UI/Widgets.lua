-- CraftPlan 2.0 — общие виджеты: одинаковые везде (поиск, галочки, списки, иконки, кнопки, полоса навыка).
-- Холст (Canvas) — область, которая перерисовывается целиком: элементы берутся из пулов и прячутся при Reset.
local CP = CraftPlan
local W = {}
CP.W = W

W.WHITE = "Interface\\Buttons\\WHITE8X8"
W.GOLD = { 1, 0.82, 0 }

-- значки состояний (текстуры игры)
W.TEX = {
	ok = "Interface\\RaidFrame\\ReadyCheck-Ready",         -- зелёная галочка
	no = "Interface\\RaidFrame\\ReadyCheck-NotReady",      -- красный крестик
	alert = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew", -- «!» в треугольнике
	info = "Interface\\FriendsFrame\\InformationIcon",     -- «i»
	question = "Interface\\GossipFrame\\IncompleteQuestIcon", -- серый «?»
	lock = "Interface\\LFGFrame\\UI-LFG-ICON-LOCK",          -- замок
	book = "Interface\\Icons\\INV_Misc_Book_09",            -- книга: можно выучить
	pencil = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up", -- правка (жёлтая заметка, как в списке гильдии)
	clear = "Interface\\FriendsFrame\\ClearBroadcastIcon",  -- крестик очистки поля
}

local function TipEnter(self)
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
local function TipLeave() GameTooltip:Hide() end
local function OnClick(self, button)
	if button == "RightButton" and self.rightAction then self.rightAction() return end
	if self.action then self.action() end
end
W.TipEnter, W.TipLeave = TipEnter, TipLeave

----------------------------------------------------------------------------------------------
-- Холст
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

-- Текст. justify — "LEFT" (по умолчанию), "CENTER", "RIGHT" (тогда x — правый край при width)
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
	return fs
end

-- Прямоугольник цветом
function Canvas:Rect(x, y, w, h, r, g, b, a, layer)
	local c = self.content
	local t = self:Pool("rect", function() return c:CreateTexture(nil, "ARTWORK") end)
	t:SetDrawLayer(layer or "ARTWORK") -- плашки (Box) — BACKGROUND/BORDER, всё внутри — ARTWORK/OVERLAY
	t:SetTexture(W.WHITE)
	t:SetVertexColor(r, g, b, a or 1)
	Place(self, t, x, y)
	t:SetWidth(math.max(1, w))
	t:SetHeight(math.max(1, h))
	return t
end
-- Плашка: рамка (слой BACKGROUND) и фон (слой BORDER) — ниже всего, что рисуется внутри.
-- Возвращает функцию «поменять высоту» (для панелей, высота которых известна в конце)
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

-- Невидимая кнопка-область (щелчок, подсказка), подсветка при наведении — по желанию
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
	b.link, b.title, b.lines, b.action, b.rightAction = opts.link, opts.title, opts.lines, opts.action, opts.rightAction
	return b
end

-- Строка-кнопка текстом
function Canvas:TextButton(text, x, y, width, opts)
	local c = self.content
	local b = self:Pool("tbtn", function()
		local b = CreateFrame("Button", nil, c)
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.text:SetPoint("LEFT", b, "LEFT", 0, 0)
		b.text:SetJustifyH("LEFT")
		b.line = b:CreateTexture(nil, "OVERLAY") -- подчёркивание при наведении (ссылки)
		b.line:SetTexture(W.WHITE)
		b.line:SetHeight(1)
		b.line:Hide()
		b:SetScript("OnEnter", function(self)
			if self.underline then
				local r, g, bl = self.text:GetTextColor()
				self.line:SetVertexColor(r, g, bl, 0.9)
				self.line:ClearAllPoints()
				self.line:SetPoint("TOPLEFT", self.text, "BOTTOMLEFT", 0, -1)
				self.line:SetWidth(self.text:GetStringWidth())
				self.line:Show()
			end
			TipEnter(self)
		end)
		b:SetScript("OnLeave", function(self) self.line:Hide(); TipLeave() end)
		b:SetScript("OnClick", OnClick)
		return b
	end)
	b.text:SetFontObject(opts.font or "GameFontHighlightSmall")
	b.text:SetWidth(width)
	b.text:SetText(text)
	if opts.color then b.text:SetTextColor(opts.color[1], opts.color[2], opts.color[3]) else b.text:SetTextColor(1, 1, 1) end
	b:SetWidth(width)
	b:SetHeight(math.max(14, b.text:GetStringHeight() + 2))
	Place(self, b, x, y)
	b:SetFrameLevel(c:GetFrameLevel() + 3)
	b.underline = opts.underline
	b.link, b.title, b.lines, b.action = opts.link, opts.title, opts.lines, opts.action
	if opts.hl then b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD") else b:SetHighlightTexture(nil) end
	return b
end

-- Обычная кнопка игры (UIPanelButtonTemplate)
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

-- Иконка: текстура (предмет/рецепт), обрезанные края, число справа внизу
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
	-- plain: значок-глиф без чёрной подложки и обрезки, при наведении — подсветка самим глифом
	local plain = opts.plain
	if plain then b.bg:Hide() else b.bg:Show() end
	b.tex:ClearAllPoints()
	local m = plain and 0 or 1
	b.tex:SetPoint("TOPLEFT", b, "TOPLEFT", m, -m)
	b.tex:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -m, m)
	if plain then b.tex:SetTexCoord(0, 1, 0, 1) else b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	b:SetHighlightTexture(plain and tex or "Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b.tex:SetDesaturated(opts.gray and true or false)
	b:SetAlpha(opts.alpha or 1)
	b.count:SetFontObject(size >= 30 and "NumberFontNormal" or "NumberFontNormalSmall")
	b.count:SetText(opts.count or "")
	local cc = opts.countColor
	if cc then b.count:SetTextColor(cc[1], cc[2], cc[3]) else b.count:SetTextColor(1, 1, 1) end
	b.link, b.title, b.lines, b.action, b.rightAction = opts.link, opts.title, opts.lines, opts.action, opts.rightAction
	return b
end

-- Значок состояния (галочка, «!», «i», «?», замок, книга)
function Canvas:Status(kind, x, y, size)
	local c = self.content
	local t = self:Pool("status", function() return c:CreateTexture(nil, "OVERLAY") end)
	t:SetTexture(W.TEX[kind])
	t:SetTexCoord(0, 1, 0, 1)
	t:SetDesaturated(false)
	t:SetVertexColor(1, 1, 1, 1)
	if kind == "book" then t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	if kind == "lock" or kind == "question" then t:SetDesaturated(true) end
	Place(self, t, x, y)
	t:SetWidth(size or 14)
	t:SetHeight(size or 14)
	return t
end

-- Кнопки «-» и «+» (стандартные текстуры игры)
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

-- Полоса навыка 0–450: заполнено до навыка (градиент тёмно→светло-зелёный), светлый отрезок прироста,
-- после изученного максимума — чёрное, золотая чёрточка на максимуме; подписи сверху без наложения
function Canvas:SkillBar(x, y, w, rank, max, gain)
	local TOP = CP.TOP_SKILL
	local h = 12
	local function px(v) return math.floor(v / TOP * w + 0.5) end
	gain = math.max(0, math.min(gain or 0, max - rank))
	local labelY = y
	local barY = y - 16
	self:Rect(x, barY, w, h, 0.2, 0.18, 0.14, 1, "ARTWORK") -- дорожка; всё остальное — OVERLAY поверх
	local f = px(rank)
	if f > 0 then
		local t = self:Rect(x, barY, f, h, 1, 1, 1, 1, "OVERLAY")
		local k = rank / TOP
		t:SetGradient("HORIZONTAL", 0.12, 0.42, 0.12, 0.12 + 0.31 * k, 0.42 + 0.58 * k, 0.12 + 0.31 * k)
	end
	if gain > 0 then
		self:Rect(x + f, barY, math.max(1, px(rank + gain) - f), h, 0.55, 1, 0.55, 0.65, "OVERLAY")
		local plus = self:Text("+" .. gain, x + f, barY - 1, "GameFontNormalSmall", math.max(1, px(rank + gain) - f), "CENTER", { 0.05, 0.16, 0.05 })
		if plus:GetStringWidth() > px(rank + gain) - f then plus:SetText("") end
	end
	if max < TOP then
		self:Rect(x + px(max), barY, w - px(max), h, 0, 0, 0, 1, "OVERLAY")
		self:Rect(x + px(max) - 1, barY, 2, h, 1, 0.82, 0, 1, "OVERLAY")
	end
	-- подписи: [x1,x2] каждой; наложились — уступает менее важная
	local placed = {}
	local function Label(text, cx, align, color, font, prio)
		local fs = self:Text(text, 0, labelY, font or "GameFontHighlightSmall", nil, nil, color)
		local tw = fs:GetStringWidth()
		local lx = (align == "right") and (cx - tw - 3) or (align == "left") and (cx + 3) or (cx - tw / 2)
		lx = math.max(x, math.min(x + w - tw, lx))
		for _, p in ipairs(placed) do
			if lx < p[2] + 4 and p[1] < lx + tw + 4 then
				if prio == "below" then
					fs:ClearAllPoints()
					fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", lx, barY - h - 2)
					return
				end
				fs:SetText("")
				return
			end
		end
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", self.content, "TOPLEFT", lx, labelY)
		placed[#placed + 1] = { lx, lx + tw }
	end
	Label(tostring(rank), x + f, "right", { 1, 1, 1 })
	if gain > 0 then Label(tostring(rank + gain), x + px(rank + gain), "left", { 0.55, 1, 0.55 }, "GameFontNormalSmall") end
	if max < TOP then Label(tostring(max), x + px(max), "center", { 0.78, 0.72, 0.56 }, nil, "below") end
	Label("0", x, "left-edge", { 0.43, 0.4, 0.34 }, "GameFontDisableSmall")
	if max < TOP then Label(tostring(TOP), x + w, "right-edge", { 0.43, 0.4, 0.34 }, "GameFontDisableSmall") end
	return barY - h - 4
end

----------------------------------------------------------------------------------------------
-- Поле поиска: рамка поля игры + крестик очистки (текстура игры), виден только при тексте
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

-- Галочка с подписью (UICheckButtonTemplate)
function W.Check(parent, name, label, get, set, tip)
	local b = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	b:SetWidth(22)
	b:SetHeight(22)
	local fs = _G[name .. "Text"]
	fs:SetText(label)
	fs:SetFontObject("GameFontHighlightSmall")
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

-- Выпадающий список: items = { { key, text } }
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

-- Окно-рамка в стиле игры: тёмный непрозрачный фон, рамка диалога
function W.Backdrop(f)
	f:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
	f:SetBackdropColor(0.06, 0.06, 0.06, 1)
end

-- Шаг для «- N +»: Shift — по 10
function W.Step() return IsShiftKeyDown() and 10 or 1 end
