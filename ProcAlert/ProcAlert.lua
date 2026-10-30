-- ProcAlert: два ряда иконок в центре экрана.
--  * Нижний ряд — сработавшие способности (Превосходство, Казнь и т.д.), крупные иконки.
--    Показываются, пока условие выполнено; при нехватке ярости — тусклые и синеватые,
--    как кнопка на панели команд.
--  * Верхний ряд — обычные удары, которые можно применить прямо сейчас (хватает ярости,
--    нет перезарядки, цель в зоне досягаемости), иконки поменьше.
--  * В обоих рядах только то, что применяется в текущей стойке.
-- Пока ничего не сработало, обычные удары стоят на месте нижнего ряда; когда срабатывает
-- способность, они плавно уезжают вверх, а на их место встают сработавшие.

-- Номера заклинаний; названия берутся из клиента (GetSpellInfo), поэтому совпадают с русским переводом.
-- Стойки: стойка, в которой удар применяется. Без stances — в любой стойке.
-- В другой стойке иконка не показывается; переключились — иконка уходит.
local BATTLE, DEFENSIVE, BERSERKER = "battle", "defensive", "berserker"
local STANCE_SPELLS = { [BATTLE] = 2457, [DEFENSIVE] = 71, [BERSERKER] = 2458 }

-- buff — эффект таланта на вас, открывающий удар; пока он висит, под иконкой отсчёт секунд,
-- в конце иконка мигает. buffOnly — показывать удар только при этом эффекте.
local PROCS = {
	{ id = 7384,  stances = { BATTLE }, buff = 60503 },            -- Превосходство; эффект «Вкус крови» (Taste for Blood)
	{ id = 5308,  stances = { BATTLE, BERSERKER }, buff = 52437, sound = true, soundBuff = true }, -- Казнь; эффект «Внезапная смерть» (Sudden Death)
	{ id = 6572,  stances = { DEFENSIVE } },                       -- Реванш (Revenge): после блока, парирования или уклонения
	-- sound — звук при появлении, даже если общий звук выключен (/pa alert); soundBuff — только при этом эффекте
	{ id = 1464,  buff = 46916, buffOnly = true, sound = true },   -- Мощный удар мгновенный; эффект «Мощный удар!» (Bloodsurge)
	{ id = 23922, buff = 50227, cond = "ShieldSlamProc" },         -- Мощный удар щитом: бесплатно по эффекту «Щит и меч» (Sword and Board),
	                                                               -- а в оборонительной — всегда, когда готов (раньше Смертельного удара)
	{ id = 772,   stances = { BATTLE }, cond = "RendProc" },       -- Кровопускание в боевой: всегда, когда его нет на цели
	{ id = 12294, cond = "MortalProc" },                           -- Смертельный удар: в берсерка — когда готов; в боевой — то же, но если нужно
	                                                               -- Кровопускание, то только при ярости на оба; в оборонительной — Реванша нет,
	                                                               -- Мощному удару щитом до готовности больше SLAM_WAIT с, ярости хватает
	{ id = 1680,  stances = { BERSERKER }, cond = "WhirlwindReady" }, -- Вихрь (Whirlwind): когда готов
	-- imba — «ИМБА»: первыми в ряду, золотая пульсирующая рамка
	{ id = 2565,  stances = { DEFENSIVE }, cond = "ShieldBlockProc", imba = true }, -- Блок щитом: цель бьёт вас, готов, ещё не висит (нужен щит)
	{ id = 20230, stances = { BATTLE }, cond = "RetaliationProc", imba = true },    -- Возмездие (Retaliation): то же в боевой
	{ id = 1719,  stances = { BERSERKER }, cond = "RecklessProc", imba = true },    -- Безрассудство (Recklessness): в бою, готово, ещё не висит
	-- cond — имя условия из CONDS (ниже); anyTarget — показывать и без враждебной цели;
	-- alts — показать первую готовую из списка (иконка меняется)
	{ id = 18499, anyTarget = true, cond = "Feared" },             -- Ярость берсерка: на вас страх, ошеломление и т. п.
	{ id = 355, alts = { 355, 694, 1161 }, stances = { DEFENSIVE }, cond = "NotOnMe" }, -- Провокация / Дразнящий удар / Вызывающий крик: цель бьёт не вас
}

-- Обычные удары в порядке показа. skipDebuff — не показывать, если ваш дебафф с этим
-- заклинанием уже висит на цели (иначе иконка торчала бы всегда).
-- Прерывания: показываются крупно над рядами, когда цель или фокус (враг) читает заклинание,
-- которое можно сбить. reflect — только если заклинание летит в вас.
local KICKS = {
	{ id = 6552,  stances = { BERSERKER } },                       -- Зуботычина (Pummel)
	{ id = 72,    stances = { BATTLE, DEFENSIVE } },               -- Удар щитом (Shield Bash), нужен щит
	{ id = 12809 },                                                -- Оглушающий удар (Concussion Blow), талант Защиты
	{ id = 23920, stances = { BATTLE, DEFENSIVE }, reflect = true }, -- Отражение заклинания (Spell Reflection), нужен щит
}

local REGULAR = {
	-- Смертельный удар и Вихрь — в «Срабатываниях»
	{ id = 23881 },                                         -- Кровожадность (Bloodthirst)
	{ id = 23922 },                                         -- Мощный удар щитом (Shield Slam)
	{ id = 1464,  stances = { BATTLE, BERSERKER } },        -- Мощный удар (Slam): не в оборонительной (мгновенный по «Мощный удар!» — в «Срабатываниях» везде)
	{ id = 78 },                                            -- Удар героя (Heroic Strike)
	{ id = 845 },                                           -- Рассекающий удар (Cleave)
	{ id = 6343,  stances = { DEFENSIVE }, cond = "Crowd" },               -- Удар грома (Thunder Clap): только в оборонительной, как Рассекающий — от CLEAVE_ENEMIES врагов рядом
	{ id = 772,   stances = { DEFENSIVE }, skipDebuff = true, saveExec = true }, -- Кровопускание (Rend): в «Ударах», пока его нет на цели (в боевой — в «Срабатываниях»)
	{ id = 20252, stances = { BERSERKER } },                -- Перехват (Intercept)
	{ id = 7386, alts = { 20243, 7386 }, stances = { DEFENSIVE }, cond = "NeedSunder", sunder = true, longFight = true }, -- Сокрушение / Раскол брони: только в оборонительной; на цели меньше 5 или скоро спадёт
	{ id = 6673, alts = { "shout" }, anyTarget = true, cond = "NoShout", saveExec = true }, -- Боевой / Командирский крик: на вас нет ни одного
	{ id = 1160, stances = { DEFENSIVE }, skipDebuff = true },                -- Деморализующий крик: нет на цели
	{ id = 1715, stances = { BATTLE, BERSERKER }, skipDebuff = true, cond = "PvPRunner" }, -- Подрезать сухожилия: цель-игрок бежит, вашего замедления нет
}
-- Удар героя и Рассекающий удар — только при лишней ярости: хватает на сам удар и ещё на самый
-- дорогой из изученных главных ударов, доступных в текущей стойке. Удары по условию (proc —
-- Казнь, Превосходство, Реванш) учитываются, только когда условие сработало прямо сейчас.
-- /pa hs <число> — свой порог, /pa hs auto — так
local DUMP_SPELLS = { [78] = true, [845] = true }
-- Копить ярость на Казнь: когда у цели здоровья не больше EXECUTE_PCT + SAVE_PCT процентов,
-- Удар героя и Рассекающий удар не показываются (в стойках, где есть Казнь)
local EXECUTE_PCT = 20
local SAVE_PCT = 10
local SLAM_WAIT = 2 -- Мощному удару щитом осталось меньше стольких секунд — Смертельный в оборонительной не показываем
local RESERVE_SPELLS = {
	{ id = 12294 },                                -- Смертельный удар
	{ id = 23881 },                                -- Кровожадность
	{ id = 23922 },                                -- Мощный удар щитом
	{ id = 20243 },                                -- Сокрушение
	{ id = 1680, stances = { BERSERKER } },         -- Вихрь
	{ id = 5308, stances = { BATTLE, BERSERKER }, proc = true }, -- Казнь: цель ниже 20% или «Внезапная смерть»
	{ id = 7384, stances = { BATTLE }, proc = true },            -- Превосходство: после уклонения или «Вкус крови»
	{ id = 6572, stances = { DEFENSIVE }, proc = true },         -- Реванш: после блока, парирования, уклонения
	{ id = 772, stances = { BATTLE, DEFENSIVE }, rend = true },  -- Кровопускание: пока его нет на цели или осталось меньше REND_RESERVE с
}
-- Что снимает Ярость берсерка: страх, ошеломление, паралич (названия берутся из клиента)
local FEAR_SPELLS = { 5782, 5484, 8122, 5246, 6358, 10326, 1513, 6770, 1776, 20066 }
local SUNDER_REFRESH = 5 -- за сколько секунд до конца Раскола брони напоминать
local REND_FORGOT = 3     -- в бою с целью столько секунд нет вашего Кровопускания — его значок мигает
local RendAlert           -- задаётся ниже (нужна анимации значков)
local REND_REFRESH = 3   -- за сколько секунд до конца Кровопускания его значок у мобов справа мигает
local REND_RESERVE = 3   -- за сколько секунд до конца Кровопускания держать на него ярость (запас Удара героя)
local LOW_LEVEL_DIFF = 5  -- цель ниже вас на столько уровней (обычная) — бой короткий: без Кровопускания,
                          -- Раскола брони и без копления на Казнь
local KILL_MARGIN = 0.9   -- оценку «Казнь добьёт» берём с запасом (урон x 0.9)
local OVERFLOW_RAGE = 90  -- от стольких ярости Удар героя / Рассекающий пульсируют: ярость скоро пропадёт
local CLEAVE_ENEMIES = 2  -- от стольких врагов в ближнем бою — Рассекающий вместо Удара героя

local CHECK_INTERVAL = 0.1 -- как часто проверять доступность, сек
local PROC_SIZE = 52       -- размер иконок сработавших способностей
local REGULAR_SIZE = 36    -- размер иконок обычных ударов
local KICK_SIZE = 60       -- размер иконок прерываний
local KICK_Y = 125         -- высота ряда прерываний над нижним рядом
local ROW_SPACING = 14     -- расстояние между рядами по вертикали
local DEFAULT_GAP = 18     -- расстояние между иконками в ряду; меняется командой /pa gap <число>
local SLIDE_SPEED = 10     -- скорость сдвига (больше — быстрее)
local POP_TIME = 0.25      -- длительность «пульса» при появлении сработавшей способности, сек
local POP_SCALE = 1.5      -- во сколько раз иконка больше в начале «пульса»
local FADE_IN = 0.15
local FADE_OUT = 0.35
local BLINK_TIME = 1.5     -- за сколько секунд до конца эффекта иконка начинает мигать
local NO_RAGE_ALPHA = 0.45 -- прозрачность сработавшей способности при нехватке ярости
local GCD_MAX = 1.6        -- перезарядка короче — это общая (GCD), её не считаем
local TEST_TIME = 3        -- сколько держатся иконки в /pa test, сек

-- Защитные способности: в оборонительной стойке при низком здоровье — слева, под «Сближением»
local DEFENSIVE_CDS = {
	871,   -- Глухая оборона (Shield Wall)
	12975, -- Ни шагу назад (Last Stand)
	2565,  -- Блок щитом (Shield Block)
}
local DEF_HEALTH = 0.4     -- показывать, когда здоровья меньше этой доли
local DEF_SIZE = 56        -- размер иконок
local DEF_GAP = 10         -- расстояние между иконками по вертикали
local DEF_X, DEF_Y = -220, 0 -- центр колонки; по высоте её ставит PlaceLeftColumn (под «Сближением»)

-- Сближение: колонка слева от персонажа (над защитными), пока есть враждебная цель. Сверху — текущая стойка,
-- под ней Рывок и Перехват: готов ли, хватает ли ярости
local RUSH_SPELLS = {
	{ id = 100 },   -- Рывок (Charge): боевая стойка вне боя; с талантом «Вестник войны» — в любой и в бою
	{ id = 20252 },  -- Перехват (Intercept): стойка берсерка
}
local RUSH_SIZE = 48
local STANCE_SIZE = 36
local RUSH_GAP = 10        -- расстояние между иконками по вертикали
local RUSH_X, RUSH_Y = -220, 0 -- центр колонки; вместе с защитными — по центру экрана по высоте
local COLUMN_SEP = 20          -- промежуток между «Сближением» и защитными

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffff7f00ProcAlert:|r " .. msg)
end

local function SoundEnabled() -- по умолчанию без звука; /pa sound
	return ProcAlertDB and ProcAlertDB.sound == true
end

local function AlertEnabled() -- звук «Внезапной смерти» и «Мощного удара!»; по умолчанию включён; /pa alert
	return not (ProcAlertDB and ProcAlertDB.alert == false)
end

local function KeysEnabled() -- по умолчанию клавиши не подписываются; /pa keys
	return ProcAlertDB and ProcAlertDB.showKeys == true
end

local function RegularEnabled() -- по умолчанию верхний ряд включён; /pa normal
	return not (ProcAlertDB and ProcAlertDB.regular == false)
end

local function RageBarEnabled() -- по умолчанию включено; /pa rage
	return not (ProcAlertDB and ProcAlertDB.rageBar == false)
end

local function RushEnabled() -- по умолчанию включено; /pa rush
	return not (ProcAlertDB and ProcAlertDB.rush == false)
end

local function DefEnabled() -- по умолчанию включено; /pa def
	return not (ProcAlertDB and ProcAlertDB.def == false)
end

local function GetGap()
	return (ProcAlertDB and ProcAlertDB.gap) or DEFAULT_GAP
end

-- Точка, вокруг которой центрируются ряды
local anchor = CreateFrame("Frame", "ProcAlertFrame", UIParent)
anchor:SetWidth(1)
anchor:SetHeight(1)
anchor:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
anchor:SetFrameStrata("HIGH")

----------------------------------------------------------------------------------------------
-- Клавиша, назначенная на ячейку панели команд со способностью
-- Ячейки: 1-12 главная панель, 25-36 правая, 37-48 правая 2, 49-60 нижняя правая,
-- 61-72 нижняя левая, 73-120 — главная панель в стойках (подменяет 1-12)
local function BindingForSlot(slot)
	if slot >= 73 or slot <= 12 then return "ACTIONBUTTON" .. ((slot - 1) % 12 + 1) end
	if slot >= 61 then return "MULTIACTIONBAR1BUTTON" .. (slot - 60) end
	if slot >= 49 then return "MULTIACTIONBAR2BUTTON" .. (slot - 48) end
	if slot >= 37 then return "MULTIACTIONBAR4BUTTON" .. (slot - 36) end
	if slot >= 25 then return "MULTIACTIONBAR3BUTTON" .. (slot - 24) end
	return nil -- 13-24: вторая страница главной панели, своей клавиши нет
end

local function SlotHasSpell(slot, spellName)
	local actionType, id, subType, globalID = GetActionInfo(slot)
	if actionType == "spell" then
		return (globalID and GetSpellInfo(globalID) == spellName)
			or (id and GetSpellInfo(id) == spellName)
			or (id and GetSpellName(id, subType or BOOKTYPE_SPELL) == spellName)
	elseif actionType == "macro" then
		return GetMacroSpell(id) == spellName
	end
end

local function FindKey(spellName)
	if not KeysEnabled() then return nil end
	local order = {}
	local bonus = GetBonusBarOffset() -- 1-3: стойки воина
	if bonus and bonus > 0 then
		local first = 72 + (bonus - 1) * 12
		for s = first + 1, first + 12 do order[#order + 1] = s end
	else
		for s = 1, 12 do order[#order + 1] = s end
	end
	for s = 25, 72 do order[#order + 1] = s end
	for s = 1, 12 do order[#order + 1] = s end
	for _, slot in ipairs(order) do
		if HasAction(slot) and SlotHasSpell(slot, spellName) then
			local command = BindingForSlot(slot)
			local key = command and GetBindingKey(command)
			if key then return GetBindingText(key, "KEY_", 1) end
		end
	end
end

----------------------------------------------------------------------------------------------
-- Ряды иконок
local function NewRow(size, keyFont, ordered)
	return { size = size, keyFont = keyFont, ordered = ordered, items = {}, bySpell = {}, pool = {}, y = 0, targetY = 0 }
end
local procRow = NewRow(PROC_SIZE, 18, false)       -- порядок появления
local regularRow = NewRow(REGULAR_SIZE, 14, true)  -- порядок как в списке REGULAR
local kickRow = NewRow(KICK_SIZE, 18, false)       -- прерывания
local rows = { procRow, regularRow, kickRow }

local regularOrder = {}
for i, r in ipairs(REGULAR) do regularOrder[r.id] = i end

local function CreateItem(row)
	local f = CreateFrame("Frame", nil, anchor)
	f:SetWidth(row.size)
	f:SetHeight(row.size)
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetPoint("CENTER", f, "CENTER", 0, 0)
	f.key = f:CreateFontString(nil, "OVERLAY")
	f.key:SetFont("Fonts\\FRIZQT__.TTF", row.keyFont, "THICKOUTLINE")
	f.key:SetPoint("TOP", f, "BOTTOM", 0, -4)
	f.key:SetTextColor(1, 1, 1)
	f.cd = CreateFrame("Cooldown", nil, f) -- затемнение-«часы», как на кнопке панели
	f.cd:SetAllPoints(f)
	local over = CreateFrame("Frame", nil, f) -- отсчёт эффекта поверх «часов»
	over:SetAllPoints(f)
	over:SetFrameLevel(f.cd:GetFrameLevel() + 1)
	f.timer = over:CreateFontString(nil, "OVERLAY")
	f.timer:SetFont("Fonts\\FRIZQT__.TTF", math.floor(row.size * 0.4), "THICKOUTLINE")
	f.timer:SetPoint("CENTER", f, "CENTER", 0, 0)
	f.timer:SetTextColor(1, 0.85, 0)
	f.rage = over:CreateFontString(nil, "OVERLAY") -- сколько ярости есть от нужной, при нехватке
	f.rage:SetFont("Fonts\\FRIZQT__.TTF", math.floor(row.size * 0.3), "THICKOUTLINE")
	f.rage:SetPoint("BOTTOM", f, "BOTTOM", 0, 2)
	f.rage:SetTextColor(0.6, 0.75, 1)
	f.badge = over:CreateTexture(nil, "OVERLAY") -- маленький значок в углу (например, нужная стойка)
	f.badge:SetWidth(math.floor(row.size * 0.45))
	f.badge:SetHeight(math.floor(row.size * 0.45))
	f.badge:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -4, -4)
	f.badge:Hide()
	-- Удар героя / Рассекающий заряжен на следующий удар оружием — подсветка, как у нажатой кнопки панели
	f.queued = over:CreateTexture(nil, "OVERLAY")
	f.queued:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	f.queued:SetBlendMode("ADD")
	f.queued:SetPoint("TOPLEFT", f.icon, "TOPLEFT", 0, 0)
	f.queued:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT", 0, 0)
	f.queued:Hide()
	-- «ИМБА» — золотая рамка вокруг иконки, пульсирует
	f.glow = over:CreateTexture(nil, "OVERLAY")
	f.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	f.glow:SetBlendMode("ADD")
	f.glow:SetVertexColor(1, 0.8, 0.2)
	f.glow:SetWidth(row.size * 1.9)
	f.glow:SetHeight(row.size * 1.9)
	f.glow:SetPoint("CENTER", f, "CENTER", 0, 0)
	f.glow:Hide()
	return f
end

local function Layout(row)
	if row.ordered then
		table.sort(row.items, function(a, b) return (regularOrder[a.spellID] or 0) < (regularOrder[b.spellID] or 0) end)
	else -- «ИМБА» — первыми, остальные в порядке появления
		local imba, rest = {}, {}
		for _, f in ipairs(row.items) do
			if f.imba then imba[#imba + 1] = f else rest[#rest + 1] = f end
		end
		for _, f in ipairs(rest) do imba[#imba + 1] = f end
		row.items = imba
	end
	local gap, total = GetGap(), 0
	for i, f in ipairs(row.items) do
		total = total + row.size + (i > 1 and gap or 0)
	end
	local x = -total / 2
	for _, f in ipairs(row.items) do
		f.targetX = x + row.size / 2
		if not f.x then f.x = f.targetX end -- новая иконка сразу на своём месте
		x = x + row.size + gap
	end
end

local function AddItem(row, spellID, name, texture, pop)
	local f = tremove(row.pool) or CreateItem(row)
	f.spellID = spellID
	f.spellName = name
	f.icon:SetTexture(texture)
	f.key:SetText(FindKey(name) or "")
	f.bornAt = GetTime()
	f.pop = pop
	f.alpha = 0
	f.x = nil
	f.removing = false
	f.noMana = false
	f.blocked = false
	f.cdStart = nil
	f.cdKey = nil
	f.cd:Hide()
	f.buffExpires = nil
	f.timer:SetText("")
	f.rage:SetText("")
	f.badge:Hide()
	f.imba = nil
	f.glow:Hide()
	f.icon:SetAlpha(1)
	f.expiresAt = nil
	f:SetAlpha(0)
	f:Show()
	row.items[#row.items + 1] = f
	row.bySpell[spellID] = f
	Layout(row)
	if pop and SoundEnabled() then PlaySound("RaidWarning") end
	return f
end

local function RemoveItem(row, f)
	for i, v in ipairs(row.items) do
		if v == f then tremove(row.items, i) break end
	end
	if row.bySpell[f.spellID] == f then row.bySpell[f.spellID] = nil end
	f:Hide()
	row.pool[#row.pool + 1] = f
	Layout(row)
end

-- Есть ли в ряду иконки, которые не исчезают
local function HasVisible(row)
	for _, f in ipairs(row.items) do
		if not f.removing then return true end
	end
	return false
end

----------------------------------------------------------------------------------------------
-- Анимация: сдвиг рядов и иконок, «пульс», появление/исчезновение, вид при нехватке ярости
anchor:SetScript("OnUpdate", function(_, elapsed)
	local now = GetTime()
	local k = math.min(1, elapsed * SLIDE_SPEED)

	-- обычные удары поднимаются над сработавшими, если те есть
	procRow.targetY = 0
	kickRow.targetY = KICK_Y
	regularRow.targetY = HasVisible(procRow) and (PROC_SIZE / 2 + ROW_SPACING + REGULAR_SIZE / 2) or 0

	for _, row in ipairs(rows) do
		row.y = row.y + (row.targetY - row.y) * k
		for i = #row.items, 1, -1 do
			local f = row.items[i]
			if f.expiresAt and now >= f.expiresAt then f.removing = true end

			f.x = f.x + (f.targetX - f.x) * k
			f:ClearAllPoints()
			f:SetPoint("CENTER", anchor, "CENTER", f.x, row.y)

			local size = row.size
			local age = now - f.bornAt
			if f.pop and age < POP_TIME then
				size = row.size * (POP_SCALE - (POP_SCALE - 1) * (age / POP_TIME))
			end
			f.icon:SetWidth(size)
			f.icon:SetHeight(size)
			if f.imba then
				f.glow:SetAlpha(0.5 + 0.5 * math.abs(math.sin(now * 4)))
				f.glow:Show()
			else
				f.glow:Hide()
			end
			if DUMP_SPELLS[f.spellID] and f.spellName and IsCurrentSpell(f.spellName) then
				f.queued:Show()
			else
				f.queued:Hide()
			end

			local dim = f.cdStart or f.noMana or f.blocked
			local targetAlpha = f.removing and 0 or (dim and NO_RAGE_ALPHA or 1)
			local step = elapsed / (targetAlpha < f.alpha and FADE_OUT or FADE_IN)
			if f.alpha < targetAlpha then
				f.alpha = math.min(targetAlpha, f.alpha + step)
			else
				f.alpha = math.max(targetAlpha, f.alpha - step)
			end
			f:SetAlpha(f.alpha)
			-- Кровопускание забыли или оно не попало (уклонение, парирование, промах) — мигает
			if f.spellID == 772 and not f.removing and RendAlert and RendAlert() then
				f:SetAlpha(f.alpha * (0.35 + 0.65 * math.abs(math.sin(now * 6))))
			end

			if f.cdStart or f.blocked then
				f.icon:SetVertexColor(0.4, 0.4, 0.4) -- на перезарядке: серая
			elseif f.noMana then
				f.icon:SetVertexColor(0.5, 0.5, 1) -- как кнопка на панели при нехватке ярости
			else
				f.icon:SetVertexColor(1, 1, 1)
			end

			-- отсчёт эффекта таланта и мигание в конце
			local left = f.buffExpires and f.buffExpires > 0 and (f.buffExpires - now)
			if left and left > 0 then
				f.timer:SetText(left >= 3 and tostring(math.floor(left + 0.5)) or string.format("%.1f", left))
				f.icon:SetAlpha(left < BLINK_TIME and (0.55 + 0.45 * math.abs(math.sin(now * 8))) or 1)
			else
				f.timer:SetText("")
				-- ярость почти полная: Удар героя / Рассекающий пульсируют
				f.icon:SetAlpha(f.overflow and (0.45 + 0.55 * math.abs(math.sin(now * 6))) or 1)
			end

			if f.removing and f.alpha <= 0 then
				RemoveItem(row, f)
			end
		end
	end
end)

-- Подписи клавиш обновляются при смене назначений, панелей или стойки
local function RefreshKeys()
	for _, row in ipairs(rows) do
		for _, f in ipairs(row.items) do
			f.key:SetText(FindKey(f.spellName) or "")
		end
	end
end
local keyWatcher = CreateFrame("Frame")
for _, event in ipairs({ "UPDATE_BINDINGS", "ACTIONBAR_SLOT_CHANGED", "UPDATE_BONUS_ACTIONBAR", "ACTIONBAR_PAGE_CHANGED" }) do
	keyWatcher:RegisterEvent(event)
end
keyWatcher:SetScript("OnEvent", RefreshKeys)

----------------------------------------------------------------------------------------------
-- Проверка доступности
local function HasEnemyTarget()
	return UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")
end

-- Текущая стойка воина: сравниваем название активной формы с названиями стоек из клиента
-- (номер формы зависит от того, какие стойки изучены, поэтому по номеру не определяем)
local stanceByName
local function CurrentStance()
	if not stanceByName then
		stanceByName = {}
		for key, spellID in pairs(STANCE_SPELLS) do
			local name = GetSpellInfo(spellID)
			if name then stanceByName[name] = key end
		end
	end
	local form = GetShapeshiftForm()
	if not form or form == 0 then return nil end
	local _, name = GetShapeshiftFormInfo(form)
	return name and stanceByName[name]
end

local function StanceAllows(stances)
	if not stances then return true end
	local current = CurrentStance()
	for _, s in ipairs(stances) do
		if s == current then return true end
	end
	return false
end

-- Ваш дебафф на цели: true и сколько секунд осталось (nil — бессрочный)
local function HasMyDebuff(name)
	for i = 1, 40 do
		local dName, _, _, _, _, _, expires, caster = UnitDebuff("target", i)
		if not dName then return false end
		if dName == name and caster == "player" then
			return true, (expires and expires > 0) and (expires - GetTime()) or nil
		end
	end
	return false
end

-- Сколько врагов рядом в ближнем бою: цель и те, кто за последние MELEE_WINDOW секунд бил вас
-- с руки или кого били вы (по журналу боя). Полоски над головами не годятся: видны и дальние мобы
local MELEE_WINDOW = 4
local MeleeEnemies
do
	local seen = {} -- GUID врага -> когда последний раз был в ближнем бою
	local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40
	local f = CreateFrame("Frame")
	f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	f:SetScript("OnEvent", function(_, event, _, sub, srcGUID, _, srcFlags, dstGUID, _, dstFlags)
		if event == "PLAYER_REGEN_ENABLED" then wipe(seen) return end
		if sub == "UNIT_DIED" then seen[dstGUID] = nil return end
		local me = UnitGUID("player")
		if dstGUID == me and (sub == "SWING_DAMAGE" or sub == "SWING_MISSED") then
			if srcFlags and bit.band(srcFlags, HOSTILE) > 0 then seen[srcGUID] = GetTime() end
		elseif srcGUID == me and (sub == "SWING_DAMAGE" or sub == "SWING_MISSED" or sub == "SPELL_DAMAGE" or sub == "SPELL_MISSED") then
			if dstFlags and bit.band(dstFlags, HOSTILE) > 0 then seen[dstGUID] = GetTime() end
		end
	end)
	MeleeEnemies = function()
		local now, count = GetTime(), 0
		local target = UnitExists("target") and UnitCanAttack("player", "target") and UnitGUID("target")
		for guid, t in pairs(seen) do
			if now - t > MELEE_WINDOW then
				seen[guid] = nil
			elseif guid ~= target then
				count = count + 1
			end
		end
		return count + (target and 1 or 0)
	end
end

-- Любая текущая перезарядка способности, включая общую: начало и длительность или nil
local function AnyCooldownOf(name)
	local start, duration = GetSpellCooldown(name)
	if start and start > 0 and duration and duration > 0 then return start, duration end
end

-- Перезарядка способности (без общей): начало и длительность или nil
local function CooldownOf(name)
	local start, duration = AnyCooldownOf(name)
	if start and duration > GCD_MAX then return start, duration end
end

-- «Часы» на иконке: при общей перезарядке только «часы», при своей — ещё и серая иконка (f.cdStart)
local function SetItemCooldown(f, start, duration)
	local key = start and (start .. ":" .. duration)
	if key == f.cdKey then return end
	f.cdKey = key
	f.cdStart = start and duration > GCD_MAX and start or nil
	if start then
		f.cd:SetCooldown(start, duration)
		f.cd:Show()
	else
		f.cd:Hide()
	end
end

-- Ваш эффект с этим номером заклинания: true и время окончания (0 — бессрочный) или nil
local function MyBuff(spellID)
	local buffName = GetSpellInfo(spellID)
	for i = 1, 40 do
		local name, _, _, _, _, _, expires, _, _, _, id = UnitBuff("player", i)
		if not name then return nil end
		if id == spellID or (buffName and name == buffName) then return true, expires or 0 end
	end
end

-- Благословение могущества (обычное или великое): с ним Боевой крик не применяется
local function MightBlessed()
	return MyBuff(19740) or MyBuff(25782)
end

local function PlayerRage()
	return UnitPower and UnitPower("player", 1) or UnitMana("player")
end

-- Стоимость в ярости из клиента или nil
local function RageCost(name)
	local cost = select(4, GetSpellInfo(name))
	if cost and cost > 0 then return cost end
end

-- Сколько ярости есть из нужной: "3/5" или "" (если стоимость неизвестна)
local function RageText(name)
	local cost = RageCost(name)
	return cost and (PlayerRage() .. "/" .. cost) or ""
end

-- Условие способности выполнено (даже если не хватает ярости) и не хватает ли ярости.
-- Ярость проверяем и сами: IsUsableSpell на сервере может сообщать о нехватке неточно.
local function ProcState(name)
	local usable, noMana = IsUsableSpell(name)
	local ready = (usable or noMana) and true or false
	local cost = RageCost(name)
	if ready and cost and PlayerRage() < cost then noMana = true end
	return ready, noMana and true or false
end

local function Known(spellID)
	local name, _, texture = GetSpellInfo(spellID)
	if name and GetSpellInfo(name) then return name, texture end -- есть в книге заклинаний
end

----------------------------------------------------------------------------------------------
-- Особые условия показа (поле cond в PROCS и REGULAR)
local fearNames
local function InGroup()
	return (GetNumRaidMembers() or 0) > 0 or (GetNumPartyMembers() or 0) > 0
end
local function SunderInfo() -- стаки Раскола брони на цели (от любого воина) и время окончания
	local sunderName = GetSpellInfo(7386)
	for i = 1, 40 do
		local name, _, _, count, _, _, expires = UnitDebuff("target", i)
		if not name then return 0 end
		if name == sunderName then return count or 1, expires end
	end
	return 0
end
-- Короткий бой: обычная цель заметно ниже вас по уровню
local function LowTarget()
	local lvl = UnitLevel("target")
	local c = UnitClassification("target")
	return lvl and lvl > 0 and (c == "normal" or c == "trivial" or c == "minus")
		and UnitLevel("player") - lvl >= LOW_LEVEL_DIFF
end

local function TargetPct()
	local max = UnitHealthMax("target")
	return (max and max > 0) and (UnitHealth("target") / max * 100) or 100
end

----------------------------------------------------------------------------------------------
-- Оценка Казни в процентах здоровья цели. Абсолютного здоровья чужих мобов игра не даёт, поэтому:
-- сколько процентов цели снимает 1 единица вашего урона (по текущему бою, иначе — по прошлым мобам
-- с тем же именем), средний обычный удар оружием и урон Казни от ярости (по вашим прошлым Казням)
local fight = { guid = nil } -- текущая цель: стартовые %, ваш урон, чужой урон
local swingAvg               -- средний урон удара оружием (без критов), за сеанс
local execRage               -- ярость в момент применения Казни
local function ExecDB()
	ProcAlertDB = ProcAlertDB or {}
	ProcAlertDB.mobPct = ProcAlertDB.mobPct or {} -- [имя] = процентов за 1 урона
	ProcAlertDB.exec = ProcAlertDB.exec or { n = 0, r = 0, d = 0, rr = 0, rd = 0 }
	return ProcAlertDB
end

-- Процентов цели за 1 единицу урона или nil
local function PctPerDamage()
	if fight.guid == UnitGUID("target") and not fight.dirty and fight.dmg > 0 then
		local drop = fight.startPct - TargetPct()
		if drop >= 5 then return drop / fight.dmg end
	end
	local name = UnitName("target")
	return name and ExecDB().mobPct[name]
end

-- Ожидаемый урон Казни при ярости rage (прямая по вашим Казням без критов) или nil
local function ExecDamage(rage)
	local e = ExecDB().exec
	if e.n < 1 then return nil end
	local meanR, meanD = e.r / e.n, e.d / e.n
	local varR = e.rr / e.n - meanR * meanR
	if e.n < 3 or varR < 1 then return meanD end
	local b = (e.rd / e.n - meanR * meanD) / varR
	return meanD + b * (rage - meanR)
end

-- Что делать с Казнью сейчас: "skip" — добьёт и обычный удар, "kill" — Казнь добьёт,
-- "weak" — не добьёт, nil — данных нет
local function ExecAdvice()
	local ppd = PctPerDamage()
	if not ppd then return nil end
	local left = TargetPct()
	if swingAvg and swingAvg * ppd * KILL_MARGIN >= left then return "skip" end
	local dmg = ExecDamage(PlayerRage())
	if not dmg then return nil end
	return (dmg * ppd * KILL_MARGIN >= left) and "kill" or "weak"
end

local CONDS = {
	ShieldSlamProc = function()
		if MyBuff(50227) then return true end
		if CurrentStance() ~= DEFENSIVE then return false end
		local ss = Known(23922)
		return ss and not CooldownOf(ss) and true or false
	end,
	WhirlwindReady = function()
		local ww = Known(1680)
		return ww and not CooldownOf(ww) and true or false
	end,
	RendProc = function()
		local rend = Known(772)
		return rend and not HasMyDebuff(rend) and true or false
	end,
	MortalProc = function()
		local ms = Known(12294)
		if not ms or CooldownOf(ms) then return false end
		local cost = RageCost(ms)
		if cost and PlayerRage() < cost then return false end -- в любой стойке: только когда ярости хватает
		local stance = CurrentStance()
		if stance == BATTLE then
			-- Кровопускание нужно: Смертельный — только если ярости хватает на оба
			-- (то же условие, что RendProc: CONDS внутри своей же таблицы ещё не виден)
			local rend = Known(772)
			if rend and not HasMyDebuff(rend) then
				return PlayerRage() >= (RageCost(ms) or 0) + (RageCost(rend) or 0)
			end
			return true
		end
		if stance ~= DEFENSIVE then return true end
		local rev = Known(6572) -- Реванш доступен — сначала он
		if rev and not CooldownOf(rev) and IsUsableSpell(rev) then return false end
		local ss = Known(23922)
		if ss then
			local usable, noMana = IsUsableSpell(ss) -- без щита Мощный удар щитом не применить
			if usable or noMana then
				local start, duration = CooldownOf(ss)
				if not start or start + duration - GetTime() <= SLAM_WAIT then return false end
			end
		end
		return true
	end,
	Crowd = function()
		return MeleeEnemies() >= CLEAVE_ENEMIES
	end,
	Feared = function()
		if not fearNames then
			fearNames = {}
			for _, id in ipairs(FEAR_SPELLS) do
				local n = GetSpellInfo(id)
				if n then fearNames[n] = true end
			end
		end
		for i = 1, 40 do
			local name = UnitDebuff("player", i)
			if not name then return false end
			if fearNames[name] then return true end
		end
		return false
	end,
	ShieldBlockProc = function()
		local sb = Known(2565)
		if not sb or CooldownOf(sb) or MyBuff(2565) then return false end
		return UnitAffectingCombat("player") and UnitExists("targettarget") and UnitIsUnit("targettarget", "player") and true or false
	end,
	RecklessProc = function()
		local r = Known(1719)
		if not r or CooldownOf(r) or MyBuff(1719) then return false end
		return UnitAffectingCombat("player") and true or false
	end,
	RetaliationProc = function()
		local r = Known(20230)
		if not r or CooldownOf(r) or MyBuff(20230) then return false end
		return UnitAffectingCombat("player") and UnitExists("targettarget") and UnitIsUnit("targettarget", "player") and true or false
	end,
	NotOnMe = function()
		return InGroup() and UnitAffectingCombat("target") and UnitExists("targettarget")
			and not UnitIsUnit("targettarget", "player") and UnitIsFriend("player", "targettarget")
	end,
	NeedSunder = function()
		local count, expires = SunderInfo()
		return count < 5 or (expires and expires - GetTime() < SUNDER_REFRESH)
	end,
	PvPRunner = function()
		if not (UnitIsPlayer("target") and UnitCanAttack("player", "target")) then return false end
		return not GetUnitSpeed or (GetUnitSpeed("target") or 0) > 0
	end,
	NoShout = function()
		if not (UnitAffectingCombat("player") or HasEnemyTarget()) then return false end
		if MyBuff(469) then return false end
		-- под благословением могущества нужен только Командирский крик
		if MightBlessed() then return Known(469) and true or false end
		return not MyBuff(6673)
	end,
}

-- Сколько ярости нужно, чтобы показать удар-«сброс» name
local function DumpRage(name)
	if ProcAlertDB and ProcAlertDB.hsRage then return ProcAlertDB.hsRage end
	local reserve = 0
	for _, r in ipairs(RESERVE_SPELLS) do
		local n = StanceAllows(r.stances) and Known(r.id)
		if n and r.proc then
			local usable, noMana = IsUsableSpell(n) -- условие сработало (ярости может и не хватать)
			if not (usable or noMana) then n = nil end
		end
		if n and r.rend then
			local has, left = HasMyDebuff(n)
			if has and not (left and left < REND_RESERVE) then n = nil end -- висит — запас на него не нужен
		end
		local cost = n and RageCost(n)
		if cost and cost > reserve then reserve = cost end
	end
	return (name and RageCost(name) or 0) + reserve
end

-- Обычный удар: можно применить прямо сейчас
local function RegularReady(name, r)
	if not StanceAllows(r.stances) then return false end
	if r.cond and not CONDS[r.cond]() then return false end
	local saving = TargetPct() <= EXECUTE_PCT + SAVE_PCT and StanceAllows({ BATTLE, BERSERKER })
		and Known(5308) and not LowTarget() -- скоро Казнь: ярость копим на неё (не на слабых мобах)
	if r.longFight and LowTarget() then return false end -- моб умрёт раньше, чем это отработает
	if r.saveExec and saving then return false end
	if DUMP_SPELLS[r.id] then
		if PlayerRage() < DumpRage(name) then return false end
		if saving then return false end
	end
	if not IsUsableSpell(name) then return false end -- не хватает ярости
	if CooldownOf(name) then return false end
	if IsSpellInRange(name, "target") == 0 then return false end
	if r.skipDebuff then
		local has, left = HasMyDebuff(name)
		if has and not (r.refresh and left and left < r.refresh) then return false end
	end
	if DUMP_SPELLS[r.id] then
		-- второй враг рядом — Рассекающий, один — Удар героя
		local enemies = MeleeEnemies()
		if r.id == 78 and enemies >= CLEAVE_ENEMIES and Known(845) then return false end
		if r.id == 845 and enemies < CLEAVE_ENEMIES then return false end
	end
	return true
end

-- Какую способность показать для записи: без alts — саму; с alts — первую изученную и
-- готовую (без перезарядки и применимую), иначе первую изученную. "shout" — крик,
-- которым вы пользовались последним (по умолчанию Боевой); под благословением могущества — Командирский
local function Resolve(e)
	if not e.alts then return Known(e.id) end
	local list = e.alts
	if list[1] == "shout" then
		if MightBlessed() then
			list = { 469 }
		else
			list = (ProcAlertDB and ProcAlertDB.shout == 469) and { 469, 6673 } or { 6673, 469 }
		end
	end
	local firstName, firstTex
	for _, id in ipairs(list) do
		local name, texture = Known(id)
		if name then
			local usable, noMana = IsUsableSpell(name)
			if not CooldownOf(name) and (usable or noMana) then return name, texture end
			firstName, firstTex = firstName or name, firstTex or texture
		end
	end
	return firstName, firstTex
end

----------------------------------------------------------------------------------------------
-- Защитные способности: все изученные из DEFENSIVE_CDS, с видом доступности:
-- яркая — можно применить, синеватая — не хватает ярости, серая с «часами» — перезарядка
-- или нельзя применить (например, нет щита)
local defFrame = CreateFrame("Frame", "ProcAlertDefFrame", UIParent)
defFrame:SetWidth(1)
defFrame:SetHeight(1)
defFrame:SetPoint("CENTER", UIParent, "CENTER", DEF_X, DEF_Y)
defFrame:SetFrameStrata("HIGH")
defFrame:SetAlpha(0)
defFrame.targetAlpha = 0
local defItems = {}
local defTestUntil = 0

defFrame:SetScript("OnUpdate", function(self, elapsed)
	local alpha = self:GetAlpha()
	if alpha < self.targetAlpha then
		self:SetAlpha(math.min(self.targetAlpha, alpha + elapsed / FADE_IN))
	elseif alpha > self.targetAlpha then
		self:SetAlpha(math.max(self.targetAlpha, alpha - elapsed / FADE_OUT))
	end
end)

local function DefItem(i)
	local f = defItems[i]
	if not f then
		f = CreateFrame("Frame", nil, defFrame)
		f:SetWidth(DEF_SIZE)
		f:SetHeight(DEF_SIZE)
		f.icon = f:CreateTexture(nil, "ARTWORK")
		f.icon:SetAllPoints(f)
		f.cd = CreateFrame("Cooldown", nil, f)
		f.cd:SetAllPoints(f)
		f.cd:Hide()
		defItems[i] = f
	end
	return f
end

local function LowHealth()
	local max = UnitHealthMax("player")
	return max and max > 0 and not UnitIsDeadOrGhost("player") and UnitHealth("player") / max < DEF_HEALTH
end

local function UpdateDefensive()
	local active = GetTime() < defTestUntil
		or (DefEnabled() and CurrentStance() == DEFENSIVE and LowHealth())
	defFrame.targetAlpha = active and 1 or 0
	if not active and defFrame:GetAlpha() == 0 then return end

	local total = 0
	for _, spellID in ipairs(DEFENSIVE_CDS) do
		if Known(spellID) then total = total + 1 end
	end
	defFrame.height = total > 0 and (total * DEF_SIZE + (total - 1) * DEF_GAP) or 0
	local n = 0
	for _, spellID in ipairs(DEFENSIVE_CDS) do
		local name, texture = Known(spellID)
		if name then
			n = n + 1
			local f = DefItem(n)
			f.icon:SetTexture(texture)
			SetItemCooldown(f, CooldownOf(name))
			local usable, noMana = IsUsableSpell(name)
			if f.cdStart or not (usable or noMana) then
				f.icon:SetVertexColor(0.4, 0.4, 0.4)
				f:SetAlpha(NO_RAGE_ALPHA)
			elseif noMana then
				f.icon:SetVertexColor(0.5, 0.5, 1)
				f:SetAlpha(NO_RAGE_ALPHA)
			else
				f.icon:SetVertexColor(1, 1, 1)
				f:SetAlpha(1)
			end
			f:ClearAllPoints()
			f:SetPoint("CENTER", defFrame, "CENTER", 0, ((total + 1) / 2 - n) * (DEF_SIZE + DEF_GAP))
			f:Show()
		end
	end
	for i = n + 1, #defItems do defItems[i]:Hide() end
end

----------------------------------------------------------------------------------------------
-- Сближение (см. RUSH_SPELLS): яркая — можно применить; синеватая — не хватает ярости;
-- серая — перезарядка или нельзя сейчас (не та стойка, в бою, дальность)
local rushFrame = CreateFrame("Frame", "ProcAlertRushFrame", UIParent)
rushFrame:SetWidth(1)
rushFrame:SetHeight(1)
rushFrame:SetPoint("CENTER", UIParent, "CENTER", RUSH_X, RUSH_Y)
rushFrame:SetFrameStrata("HIGH")
rushFrame:SetAlpha(0)
rushFrame.targetAlpha = 0
rushFrame:SetScript("OnUpdate", defFrame:GetScript("OnUpdate"))
local rushItems = {}
local rushTestUntil = 0

local function RushItem(i, size)
	local f = rushItems[i]
	if not f then
		f = CreateFrame("Frame", nil, rushFrame)
		f:SetWidth(size)
		f:SetHeight(size)
		f.icon = f:CreateTexture(nil, "ARTWORK")
		f.icon:SetAllPoints(f)
		f.cd = CreateFrame("Cooldown", nil, f)
		f.cd:SetAllPoints(f)
		f.cd:Hide()
		local over = CreateFrame("Frame", nil, f) -- надпись ярости поверх «часов», как у остальных иконок
		over:SetAllPoints(f)
		over:SetFrameLevel(f.cd:GetFrameLevel() + 1)
		f.rage = over:CreateFontString(nil, "OVERLAY")
		f.rage:SetFont("Fonts\\FRIZQT__.TTF", math.floor(size * 0.3), "THICKOUTLINE")
		f.rage:SetPoint("BOTTOM", f, "BOTTOM", 0, 2)
		f.rage:SetTextColor(0.6, 0.75, 1)
		f.cdText = over:CreateFontString(nil, "OVERLAY") -- сколько секунд осталось до готовности
		f.cdText:SetFont("Fonts\\FRIZQT__.TTF", math.floor(size * 0.3), "THICKOUTLINE")
		f.cdText:SetPoint("CENTER", f, "CENTER", 0, 0)
		f.cdText:SetTextColor(1, 1, 1)
		rushItems[i] = f
	end
	return f
end

-- Можно ли применить сейчас: nil — да, "cd" — перезарядка, "rage" — не хватает ярости
-- (сравниваем сами, в любой стойке), "no" — нельзя (не та стойка, в бою без таланта, дальность)
local function RushState(name)
	if CooldownOf(name) then return "cd" end
	local usable, noMana = IsUsableSpell(name)
	local cost = RageCost(name)
	if noMana or (cost and PlayerRage() < cost) then return "rage" end
	if not usable then return "no" end
	if IsSpellInRange(name, "target") == 0 then return "no" end
end

local function UpdateRush()
	local test = GetTime() < rushTestUntil
	local active = test or (RushEnabled() and HasEnemyTarget())
	rushFrame.targetAlpha = active and 1 or 0
	if not active and rushFrame:GetAlpha() == 0 then return end

	-- изученные способности; колонка (стойка + они) центрируется по вертикали
	local known = {}
	for _, r in ipairs(RUSH_SPELLS) do
		local name, texture = Known(r.id)
		if name then known[#known + 1] = { name = name, texture = texture } end
	end
	rushFrame.height = STANCE_SIZE + #known * (RUSH_SIZE + RUSH_GAP)
	local y = rushFrame.height / 2

	-- сверху текущая стойка
	local stance = CurrentStance()
	local sf = RushItem(1, STANCE_SIZE)
	local _, _, stanceTex = GetSpellInfo(STANCE_SPELLS[stance or BATTLE])
	sf.icon:SetTexture(stanceTex)
	sf:SetAlpha(stance and 1 or 0.4)
	sf:ClearAllPoints()
	sf:SetPoint("CENTER", rushFrame, "CENTER", 0, y - STANCE_SIZE / 2)
	sf:Show()
	y = y - STANCE_SIZE - RUSH_GAP

	for i, k in ipairs(known) do
		local f = RushItem(i + 1, RUSH_SIZE)
		f.icon:SetTexture(k.texture)
		SetItemCooldown(f, CooldownOf(k.name))
		local state = RushState(k.name)
		if test then state = nil end
		local cdStart, cdDur = CooldownOf(k.name)
		local cdLeft = cdStart and (cdStart + cdDur - GetTime())
		f.cdText:SetText(cdLeft and cdLeft > 0 and (cdLeft >= 60 and (math.ceil(cdLeft / 60) .. "м") or tostring(math.ceil(cdLeft))) or "")
		f.rage:SetText(state == "rage" and (test and "3/10" or RageText(k.name)) or "")
		if state == "cd" or state == "no" then
			f.icon:SetVertexColor(0.4, 0.4, 0.4)
			f:SetAlpha(NO_RAGE_ALPHA)
		elseif state == "rage" then
			f.icon:SetVertexColor(0.5, 0.5, 1)
			f:SetAlpha(NO_RAGE_ALPHA)
		else
			f.icon:SetVertexColor(1, 1, 1)
			f:SetAlpha(1)
		end
		f:ClearAllPoints()
		f:SetPoint("CENTER", rushFrame, "CENTER", 0, y - RUSH_SIZE / 2)
		f:Show()
		y = y - RUSH_SIZE - RUSH_GAP
	end
	for i = #known + 2, #rushItems do rushItems[i]:Hide() end
end

-- Левый столбик: «Сближение» сверху, защитные снизу; вместе — по центру экрана по высоте,
-- растут вверх и вниз поровну. Показан один блок — он сам по центру
local function PlaceLeftColumn()
	local rushH = (rushFrame.targetAlpha > 0) and (rushFrame.height or 0) or 0
	local defH = (defFrame.targetAlpha > 0) and (defFrame.height or 0) or 0
	local total = rushH + defH + ((rushH > 0 and defH > 0) and COLUMN_SEP or 0)
	local rushY = (rushH > 0) and (total / 2 - rushH / 2) or 0
	local defY = (defH > 0) and (-total / 2 + defH / 2) or 0
	if rushFrame.placedY ~= rushY then
		rushFrame:ClearAllPoints()
		rushFrame:SetPoint("CENTER", UIParent, "CENTER", RUSH_X, RUSH_Y + rushY)
		rushFrame.placedY = rushY
	end
	if defFrame.placedY ~= defY then
		defFrame:ClearAllPoints()
		defFrame:SetPoint("CENTER", UIParent, "CENTER", DEF_X, DEF_Y + defY)
		defFrame.placedY = defY
	end
end

----------------------------------------------------------------------------------------------
-- Уклонения цели (для Превосходства из стойки берсерка) и сколько ярости остаётся при смене стойки
local DODGE_WINDOW = 5 -- сколько секунд после уклонения цели доступно Превосходство
local dodgeAt = 0
local rendMissAt = 0 -- когда ваше Кровопускание по цели не попало
local swing = { at = 0, speed = 0 } -- таймер замаха основной руки
local stanceWatch = CreateFrame("Frame")
stanceWatch:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
stanceWatch:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
local lastRage, lastStance = 0, nil
stanceWatch:SetScript("OnEvent", function(_, event, ...)
	if event == "UPDATE_SHAPESHIFT_FORM" then
		local st = CurrentStance()
		if lastStance and st ~= lastStance then
			-- ярость после смены стойки меньше, чем была: столько и сохраняется
			local now = PlayerRage()
			if lastRage > now then
				ProcAlertDB = ProcAlertDB or {}
				ProcAlertDB.stanceKeep = math.max(ProcAlertDB.stanceKeep or 0, now)
			end
		end
		lastStance = st
		return
	end
	local _, sub, srcGUID, _, _, dstGUID = ...
	if srcGUID ~= UnitGUID("player") then return end
	if sub == "SWING_DAMAGE" or sub == "SWING_MISSED" then
		swing.at, swing.speed = GetTime(), UnitAttackSpeed("player") or 0
		if sub == "SWING_MISSED" and select(9, ...) == "DODGE" and dstGUID == UnitGUID("target") then dodgeAt = GetTime() end
	elseif sub == "SPELL_DAMAGE" or sub == "SPELL_MISSED" then
		local spellName = select(10, ...)
		-- Удар героя и Рассекающий заменяют замах — таймер начинается заново
		if spellName == GetSpellInfo(78) or spellName == GetSpellInfo(845) then
			swing.at, swing.speed = GetTime(), UnitAttackSpeed("player") or 0
		end
		if sub == "SPELL_MISSED" and select(12, ...) == "DODGE" and dstGUID == UnitGUID("target") then dodgeAt = GetTime() end
		if sub == "SPELL_MISSED" and spellName == GetSpellInfo(772) and dstGUID == UnitGUID("target") then rendMissAt = GetTime() end
	end
end)

-- Мигать ли значку Кровопускания: в бою с сильной целью вашего Кровопускания нет REND_FORGOT с
-- (или оно не попало) — отсчёт идёт с начала боя с целью или с момента, когда оно спало
local rendGuid, rendSince = nil, 0
RendAlert = function()
	local guid = UnitGUID("target")
	if not (guid and UnitCanAttack("player", "target") and not UnitIsDead("target") and UnitAffectingCombat("player")) then
		rendGuid = nil
		return false
	end
	local name = Known(772)
	if not name or LowTarget() then return false end
	local now = GetTime()
	if HasMyDebuff(name) then
		rendGuid, rendSince = guid, now
		return false
	end
	if rendGuid ~= guid then rendGuid, rendSince = guid, now end
	return now - rendSince >= REND_FORGOT or rendMissAt > rendSince
end
local rageWatch = CreateFrame("Frame") -- ярость перед сменой стойки
rageWatch:SetScript("OnUpdate", function() lastRage = PlayerRage() end)

local function StanceKeep() -- сколько ярости сохраняется при смене стойки (по наблюдению; сначала 10)
	return (ProcAlertDB and ProcAlertDB.stanceKeep) or 10
end
local function RageCostOr(name, default) return RageCost(name) or default end

-- Какой крик вы применили последним — его и напоминать (Боевой или Командирский)
-- Журнал боя: ваш урон по цели, проценты цели, урон Казни от ярости
local tracker = CreateFrame("Frame")
tracker:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
tracker:RegisterEvent("PLAYER_TARGET_CHANGED")
tracker:RegisterEvent("UNIT_SPELLCAST_SENT")
tracker:RegisterEvent("UNIT_HEALTH")
local function SaveFight()
	if fight.guid and not fight.dirty and fight.dmg > 0 and fight.name then
		local drop = fight.startPct - (fight.lastPct or fight.startPct)
		if drop >= 30 then -- достаточно данных: запомнить для мобов с этим именем
			local ppd = drop / fight.dmg
			local db = ExecDB().mobPct
			db[fight.name] = db[fight.name] and (db[fight.name] * 0.7 + ppd * 0.3) or ppd
		end
	end
end
local function NewFight()
	SaveFight()
	local guid = UnitGUID("target")
	fight = { guid = guid, name = UnitName("target"), startPct = TargetPct(), dmg = 0 }
	fight.lastPct = fight.startPct
end
tracker:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_TARGET_CHANGED" then
		NewFight()
		return
	elseif event == "UNIT_HEALTH" then
		if ... == "target" and fight.guid == UnitGUID("target") and fight.dmg > 0 then fight.lastPct = TargetPct() end
		return
	elseif event == "UNIT_SPELLCAST_SENT" then
		local unit, spellName = ...
		if unit == "player" and spellName == GetSpellInfo(5308) then execRage = PlayerRage() end
		return
	end
	local _, sub, srcGUID, _, _, dstGUID = ...
	if not fight.guid or dstGUID ~= fight.guid then return end
	local dmg, overkill, crit
	if sub == "SWING_DAMAGE" then
		dmg, overkill = select(9, ...), select(10, ...)
		crit = select(15, ...)
	elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" then
		dmg, overkill = select(12, ...), select(13, ...)
		crit = select(18, ...)
	else
		return
	end
	if not dmg then return end
	if srcGUID ~= UnitGUID("player") then
		fight.dirty = true -- бьёт кто-то ещё: по этому бою проценты не считаем
		return
	end
	local real = dmg - ((overkill and overkill > 0) and overkill or 0)
	if fight.dmg == 0 then fight.startPct = TargetPct() + 0 end
	fight.dmg = fight.dmg + real
	fight.lastPct = TargetPct()
	if not crit then
		if sub == "SWING_DAMAGE" then
			swingAvg = swingAvg and (swingAvg * 0.8 + dmg * 0.2) or dmg
		elseif select(10, ...) == GetSpellInfo(5308) and execRage then
			local e = ExecDB().exec
			e.n, e.r, e.d = e.n + 1, e.r + execRage, e.d + dmg
			e.rr, e.rd = e.rr + execRage * execRage, e.rd + execRage * dmg
			execRage = nil
		end
	end
end)

-- Полоска ярости: внизу, под персонажем — над панелью стоек; видна в бою или с враждебной целью.
-- Белая черта — сколько ярости нужно для Удара героя (порог /pa hs), цифра справа — ярость сейчас
local RAGE_W, RAGE_H = 220, 12
local rageBar = CreateFrame("StatusBar", "ProcAlertRageBar", UIParent)
rageBar:SetWidth(RAGE_W)
rageBar:SetHeight(RAGE_H)
rageBar:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 200) -- до входа в игру; точное место — ниже
-- Над панелью стоек: нижний край полоски замаха (она под полоской ярости) на RAGE_GAP выше кнопок
-- стоек. Панель стоек может сдвигаться (вторая панель снизу) — ставим заново при входе и смене панелей
do
	local RAGE_GAP = 12
	local BELOW = 14 + 4 -- под полоской ярости: число порога и полоска замаха
	local function Place()
		local stance = ShapeshiftButton1
		local top = stance and stance:IsVisible() and stance:GetTop()
		if top then top = top * stance:GetEffectiveScale() / UIParent:GetEffectiveScale() end
		local y = (top or 120) + RAGE_GAP + BELOW
		rageBar:ClearAllPoints()
		rageBar:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, y)
	end
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_ENTERING_WORLD")
	f:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
	f:RegisterEvent("ACTIONBAR_SHOWGRID")
	f:RegisterEvent("ACTIONBAR_HIDEGRID")
	f:RegisterEvent("CVAR_UPDATE")
	f:SetScript("OnEvent", Place)
	if UIParent_ManageFramePositions then hooksecurefunc("UIParent_ManageFramePositions", Place) end
end
rageBar:SetFrameStrata("HIGH")
rageBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
rageBar:SetStatusBarColor(0.85, 0.1, 0.1)
rageBar:SetMinMaxValues(0, 100)
rageBar:SetAlpha(0)
rageBar.bg = rageBar:CreateTexture(nil, "BACKGROUND")
rageBar.bg:SetAllPoints(rageBar)
rageBar.bg:SetTexture(0, 0, 0, 0.55)
rageBar.text = rageBar:CreateFontString(nil, "OVERLAY") -- число ярости едет вместе с краем заполнения
rageBar.text:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
rageBar.mark = rageBar:CreateTexture(nil, "OVERLAY") -- порог Удара героя
rageBar.mark:SetWidth(2)
rageBar.mark:SetHeight(RAGE_H + 4)
rageBar.mark:SetTexture(1, 1, 1, 0.9)
rageBar.markText = rageBar:CreateFontString(nil, "OVERLAY") -- число порога под чертой (над полоской — ярость)
rageBar.markText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
rageBar.markText:SetPoint("TOP", rageBar.mark, "BOTTOM", 0, -1)
rageBar:SetScript("OnUpdate", function(self, elapsed)
	local show = RageBarEnabled() and (UnitAffectingCombat("player") or HasEnemyTarget())
	local a = self:GetAlpha()
	local target = show and 1 or 0
	if a < target then self:SetAlpha(math.min(target, a + elapsed / FADE_IN))
	elseif a > target then self:SetAlpha(math.max(target, a - elapsed / FADE_OUT)) end
	if self:GetAlpha() == 0 then return end
	local max = UnitPowerMax and UnitPowerMax("player", 1) or 100
	if not max or max <= 0 then max = 100 end
	local rage = PlayerRage()
	self:SetMinMaxValues(0, max)
	self:SetValue(rage)
	self.text:SetText(rage)
	-- над краем заполнения (у левого края — не выходит за полоску)
	local edge = math.max(8, RAGE_W * math.min(rage, max) / max)
	self.text:ClearAllPoints()
	self.text:SetPoint("BOTTOM", self, "TOPLEFT", edge, 1)
	-- почти полная — полоска пульсирует (ярость скоро начнёт пропадать)
	if rage >= OVERFLOW_RAGE then
		local k = 0.6 + 0.4 * math.abs(math.sin(GetTime() * 6))
		self:SetStatusBarColor(1 * k, 0.25 * k, 0.1 * k)
	else
		self:SetStatusBarColor(0.85, 0.1, 0.1)
	end
	local heroic = Known(78)
	local need = heroic and DumpRage(heroic)
	if need and need > 0 and need < max then
		self.mark:ClearAllPoints()
		self.mark:SetPoint("CENTER", self, "LEFT", RAGE_W * need / max, 0)
		self.mark:Show()
		self.markText:SetText(need)
		self.markText:Show()
	else
		self.mark:Hide()
		self.markText:Hide()
	end
end)

-- Таймер замаха: тонкая полоска под «Яростью» — сколько осталось до следующего удара оружием.
-- Оранжевая — Удар героя / Рассекающий заряжен на этот замах; мигает красным — заряжен, но ярости
-- на него уже не хватает (не пройдёт)
local swingBar = CreateFrame("StatusBar", "ProcAlertSwingBar", UIParent)
swingBar:SetWidth(RAGE_W)
swingBar:SetHeight(4)
swingBar:SetPoint("TOP", rageBar, "BOTTOM", 0, -14) -- под числом порога
swingBar:SetFrameStrata("HIGH")
swingBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
swingBar:SetMinMaxValues(0, 1)
swingBar:SetAlpha(0)
swingBar.bg = swingBar:CreateTexture(nil, "BACKGROUND")
swingBar.bg:SetAllPoints(swingBar)
swingBar.bg:SetTexture(0, 0, 0, 0.55)
swingBar:SetScript("OnUpdate", function(self, elapsed)
	local show = RageBarEnabled() and UnitAffectingCombat("player") and swing.speed > 0
	local a = self:GetAlpha()
	local target = show and 1 or 0
	if a < target then self:SetAlpha(math.min(target, a + elapsed / FADE_IN))
	elseif a > target then self:SetAlpha(math.max(target, a - elapsed / FADE_OUT)) end
	if self:GetAlpha() == 0 then return end
	local p = swing.speed > 0 and math.min(1, (GetTime() - swing.at) / swing.speed) or 0
	self:SetValue(p)
	local queued
	for _, id in ipairs({ 78, 845 }) do
		local n = Known(id)
		if n and IsCurrentSpell(n) then queued = n end
	end
	if queued then
		local cost = RageCost(queued)
		if cost and PlayerRage() < cost then
			local k = 0.5 + 0.5 * math.abs(math.sin(GetTime() * 8))
			self:SetStatusBarColor(1 * k, 0.1 * k, 0.1 * k)
		else
			self:SetStatusBarColor(1, 0.55, 0.1)
		end
	else
		self:SetStatusBarColor(0.85, 0.85, 0.85)
	end
end)

local shoutWatcher = CreateFrame("Frame")
shoutWatcher:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
shoutWatcher:SetScript("OnEvent", function(_, _, unit, spellName)
	if unit ~= "player" then return end
	for _, id in ipairs({ 6673, 469 }) do
		if spellName == GetSpellInfo(id) then
			ProcAlertDB = ProcAlertDB or {}
			ProcAlertDB.shout = id
		end
	end
end)

local checker = CreateFrame("Frame")
local elapsedTotal = 0
checker:SetScript("OnUpdate", function(_, elapsed)
	elapsedTotal = elapsedTotal + elapsed
	if elapsedTotal < CHECK_INTERVAL then return end
	elapsedTotal = 0
	local enemy = HasEnemyTarget()
	UpdateDefensive()
	UpdateRush()
	PlaceLeftColumn()

	-- Казнь и Превосходство показываются по своим срабатываниям, оба сразу (яркие или синеватые — по ярости)
	local suppress = {}

	for _, p in ipairs(PROCS) do
		local spellID = p.id
		local name, texture = Resolve(p)
		if name then
			local ready, noMana = false, false
			local hasBuff, buffExpires
			if p.buff then hasBuff, buffExpires = MyBuff(p.buff) end
			if (enemy or p.anyTarget) and StanceAllows(p.stances) and (hasBuff or not p.buffOnly)
				and (not p.cond or CONDS[p.cond]()) and not suppress[spellID] then
				ready, noMana = ProcState(name)
			end
			local f = procRow.bySpell[spellID]
			if f and f.expiresAt then
				-- иконка из /pa test: не трогаем
			elseif ready then
				if not f and p.sound and (hasBuff or not p.soundBuff) and AlertEnabled() and not SoundEnabled() then
					PlaySound("RaidWarning")
				end
				f = f or AddItem(procRow, spellID, name, texture, true)
				if f.imba ~= p.imba then
					f.imba = p.imba
					Layout(procRow)
				end
				f.icon:SetTexture(texture) -- у записей с alts иконка может смениться
				f.spellName = name
				f.removing = false
				f.noMana = noMana
				f.blocked = false
				f.rage:SetText(noMana and RageText(name) or "")
				f.buffExpires = hasBuff and buffExpires or nil
				if p.myDebuff then -- отсчёт: сколько осталось вашему эффекту на цели
					local has, left = HasMyDebuff(name)
					f.buffExpires = has and left and (GetTime() + left) or nil
				end
				SetItemCooldown(f, AnyCooldownOf(name))
			elseif f then
				f.removing = true
			end
		end
	end

	-- Превосходство из стойки берсерка: цель уклонилась (5 с) или «Вкус крови» — значок боевой стойки
	-- в углу: перейдите в боевую и бейте. Только если при смене стойки почти не потеряете ярость
	do
		local key = -7384
		local opName, opTex = Known(7384)
		local ready = false
		if enemy and opName and Known(STANCE_SPELLS[BATTLE]) and CurrentStance() == BERSERKER
			and not CooldownOf(opName) and (GetTime() - dodgeAt < DODGE_WINDOW or MyBuff(60503))
			and PlayerRage() <= StanceKeep() + RageCostOr(opName, 5) then
			ready = true
		end
		local f = procRow.bySpell[key]
		if f and f.expiresAt then
			-- /pa test
		elseif ready then
			f = f or AddItem(procRow, key, opName, opTex, true)
			f.removing = false
			f.badge:SetTexture(select(3, GetSpellInfo(STANCE_SPELLS[BATTLE])))
			f.badge:Show()
			local tfb, tfbExp = MyBuff(60503)
			f.buffExpires = tfb and tfbExp or (dodgeAt + DODGE_WINDOW)
		elseif f then
			f.removing = true
		end
	end

	-- Прерывания: чьё заклинание сбивать — цели, иначе фокуса
	local castUnit, castEnds
	for _, unit in ipairs({ "target", "focus" }) do
		if UnitExists(unit) and UnitCanAttack("player", unit) and not UnitIsDead(unit) then
			local name, _, _, _, _, endTime, _, _, notInterruptible = UnitCastingInfo(unit)
			if not name then
				name, _, _, _, _, endTime, _, notInterruptible = UnitChannelInfo(unit)
			end
			if name and not notInterruptible then
				castUnit, castEnds = unit, endTime / 1000
				break
			end
		end
	end
	for _, kk in ipairs(KICKS) do
		local name, texture = Known(kk.id)
		if name then
			local ready = castUnit and StanceAllows(kk.stances)
				and (not kk.reflect or UnitIsUnit(castUnit .. "target", "player"))
			local f = kickRow.bySpell[kk.id]
			if f and f.expiresAt then
				-- иконка из /pa test: не трогаем
			elseif ready then
				local usable, noMana = IsUsableSpell(name)
				local cost = RageCost(name)
				if (usable or noMana) and cost and PlayerRage() < cost then usable, noMana = false, true end
				f = f or AddItem(kickRow, kk.id, name, texture, true)
				f.removing = false
				f.noMana = noMana and true or false
				f.rage:SetText(noMana and RageText(name) or "")
				-- серая: нельзя применить (нет щита) или цель далеко
				f.blocked = not (usable or noMana) or (not kk.reflect and IsSpellInRange(name, castUnit) == 0)
				f.buffExpires = castEnds -- отсчёт: сколько осталось до конца заклинания врага
				SetItemCooldown(f, AnyCooldownOf(name))
			elseif f then
				f.removing = true
			end
		end
	end

	for _, r in ipairs(REGULAR) do
		local name, texture = Resolve(r)
		if name then
			local proc = procRow.bySpell[r.id] -- уже показан крупно в нижнем ряду
			local ready = (enemy or r.anyTarget) and RegularEnabled() and not (proc and not proc.removing) and RegularReady(name, r)
			local f = regularRow.bySpell[r.id]
			if f and f.expiresAt then
				-- иконка из /pa test: не трогаем
			elseif ready then
				f = f or AddItem(regularRow, r.id, name, texture, false)
				f.icon:SetTexture(texture)
				f.spellName = name
				if r.sunder then -- стаки «3/5» и время до конца Раскола брони
					local count, expires = SunderInfo()
					f.rage:SetText(count .. "/5")
					f.buffExpires = expires
				elseif r.buff then
					local has, expires = MyBuff(r.buff)
					f.buffExpires = has and expires or nil
				end
				f.overflow = DUMP_SPELLS[r.id] and PlayerRage() >= OVERFLOW_RAGE or nil
				f.removing = false
			elseif f then
				f.removing = true
			end
		end
	end
end)

----------------------------------------------------------------------------------------------
-- Команды
local function Test()
	-- сначала обычные удары, затем по очереди сработавшие — видно, как обычные уезжают вверх
	for _, r in ipairs(REGULAR) do
		local name, texture = Known(r.id)
		if name and not regularRow.bySpell[r.id] then
			AddItem(regularRow, r.id, name, texture, false).expiresAt = GetTime() + TEST_TIME + 2
		end
	end
	defTestUntil = GetTime() + TEST_TIME + 2
	rushTestUntil = defTestUntil
	for _, kk in ipairs(KICKS) do
		local name, texture = Known(kk.id)
		if name and not kickRow.bySpell[kk.id] then
			local f = AddItem(kickRow, kk.id, name, texture, true)
			f.expiresAt = GetTime() + TEST_TIME + 2
			f.buffExpires = f.expiresAt
		end
	end
	local delay = 1
	for i, p in ipairs(PROCS) do
		local spellID = p.id
		local name, _, texture = GetSpellInfo(spellID)
		if name then
			local startAt = GetTime() + delay
			local timer = CreateFrame("Frame")
			timer:SetScript("OnUpdate", function(self)
				if GetTime() < startAt then return end
				self:SetScript("OnUpdate", nil)
				if procRow.bySpell[spellID] then return end
				local f = AddItem(procRow, spellID, name, texture, true)
				f.expiresAt = GetTime() + TEST_TIME
				f.noMana = (i == 2)
				if f.noMana then f.rage:SetText("3/5") end
				if p.buff then f.buffExpires = f.expiresAt end
			end)
			delay = delay + 0.6
		end
	end
end

-- /pa — справка; /pa test, /pa sound, /pa keys, /pa normal, /pa gap <число>
SLASH_PROCALERT1 = "/pa"
SlashCmdList["PROCALERT"] = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	ProcAlertDB = ProcAlertDB or {}
	local function onoff(v) return v and "вкл" or "выкл" end
	if msg == "sound" then
		ProcAlertDB.sound = not SoundEnabled() and true or false
		Print("звук: " .. onoff(ProcAlertDB.sound) .. ".")
	elseif msg == "keys" then
		ProcAlertDB.showKeys = not KeysEnabled() and true or false
		RefreshKeys()
		Print("подписи клавиш: " .. onoff(ProcAlertDB.showKeys) .. ".")
	elseif msg == "normal" then
		ProcAlertDB.regular = not RegularEnabled()
		Print("ряд обычных ударов: " .. onoff(ProcAlertDB.regular) .. ".")
	elseif msg:match("^gap") then
		local n = tonumber(msg:match("^gap%s+(%-?%d+)$"))
		if n and n >= 0 and n <= 200 then
			ProcAlertDB.gap = n
			Layout(procRow)
			Layout(regularRow)
			Print("расстояние между иконками: " .. n .. ".")
		else
			Print("укажите число от 0 до 200, например /pa gap 18 (сейчас: " .. GetGap() .. ").")
		end
	elseif msg == "debug" then
		-- что аддон видит по сработавшим способностям прямо сейчас
		Print("стойка: " .. tostring(CurrentStance()) .. ", ярость: " .. PlayerRage())
		for _, p in ipairs(PROCS) do
			local name = Known(p.id)
			if name then
				local usable, noMana = IsUsableSpell(name)
				local start, duration = GetSpellCooldown(name)
				Print(string.format("%s: usable=%s noMana=%s cd=%.1f/%.1f стоимость=%s стойка=%s",
					name, tostring(usable), tostring(noMana),
					(start and start > 0) and (start + duration - GetTime()) or 0, duration or 0,
					tostring(RageCost(name)), tostring(StanceAllows(p.stances))))
			end
		end
	elseif msg:match("^hs") then
		local n = tonumber(msg:match("^hs%s+(%d+)$"))
		local heroic = Known(78)
		if msg:match("^hs%s+auto$") then
			ProcAlertDB.hsRage = nil
			Print("Удар героя — при ярости на него и ещё на самый дорогой из ваших главных ударов в этой стойке; Казнь, Превосходство и Реванш — только когда сработали (сейчас от " .. DumpRage(heroic) .. ").")
		elseif n and n <= 100 then
			ProcAlertDB.hsRage = n
			Print("Удар героя и Рассекающий удар — при ярости от " .. n .. ". Вернуть авто: /pa hs auto.")
		else
			Print("/pa hs <0-100> — свой порог, /pa hs auto — авто (сейчас: от " .. DumpRage(heroic) .. ").")
		end
	elseif msg == "rage" then
		ProcAlertDB.rageBar = not RageBarEnabled()
		Print("полоска ярости: " .. onoff(ProcAlertDB.rageBar) .. ".")
	elseif msg == "alert" then
		ProcAlertDB.alert = not AlertEnabled()
		Print("звук «Внезапной смерти» и «Мощного удара!»: " .. onoff(ProcAlertDB.alert) .. ".")
	elseif msg == "def" then
		ProcAlertDB.def = not DefEnabled()
		Print("защитные способности при здоровье ниже " .. (DEF_HEALTH * 100) .. "%: " .. onoff(ProcAlertDB.def) .. ".")
	elseif msg == "enemies" then
		ProcAlertDB.enemies = ProcAlertDB.enemies == false
		Print("список врагов справа: " .. onoff(ProcAlertDB.enemies) .. ".")
	elseif msg == "rush" then
		ProcAlertDB.rush = not RushEnabled()
		Print("стойка, Рывок и Перехват слева при враждебной цели: " .. onoff(ProcAlertDB.rush) .. ".")
	elseif msg == "stance" then
		ProcAlertDB.stanceLine = ProcAlertDB.stanceLine == false
		Print("значок стойки слева от срабатываний: " .. onoff(ProcAlertDB.stanceLine) .. ".")
	elseif msg == "test" then
		Test()
	else
		Print("/pa test — пример; /pa normal — ряд обычных ударов (" .. onoff(RegularEnabled()) .. "); /pa def — защитные (" .. onoff(DefEnabled()) .. "); /pa rush — стойка, Рывок и Перехват (" .. onoff(RushEnabled()) .. "); /pa enemies — список врагов справа (" .. onoff(ProcAlertDB.enemies ~= false) .. "); /pa stance — значок стойки (" .. onoff(ProcAlertDB.stanceLine ~= false) .. "); /pa hs <число> или auto — ярость для Удара героя; /pa alert — звук важных срабатываний (" .. onoff(AlertEnabled()) .. "); /pa rage — полоска ярости (" .. onoff(RageBarEnabled()) .. "); /pa keys — клавиши ("
			.. onoff(KeysEnabled()) .. "); /pa sound — звук (" .. onoff(SoundEnabled()) .. "); /pa gap <число> — расстояние (" .. GetGap() .. ").")
	end
end

----------------------------------------------------------------------------------------------
-- Враги рядом: список справа от центра — кто бьёт вас или кого бьёте вы, их здоровье и ваши
-- ослабления с отсчётом. Можно выключить полоски над головами. Точное здоровье и ослабления игра
-- даёт для цели, фокуса, моба под курсором и (новые полоски Sirus) мобов с видимой полоской над
-- головой; для остальных — по журналу боя: что и когда
-- вы наложили, длительность — по прошлому разу (выучена с цели) или по таблице. /pa enemies
;(function()
local X, Y = 240, 90         -- левый верхний угол столбика остальных врагов от центра экрана
-- строка вашей цели: справа от «Срабатываний», на их высоте — перед глазами и не на головах мобов.
-- Место постоянное (не ездит, когда срабатываний становится больше или меньше)
local TARGET_X = 130         -- левый край от центра ряда срабатываний
local TARGET_Y = PROC_SIZE / 2 -- верх строки: значки ослаблений — на одной линии со срабатываниями, их размера
local MAX_ROWS = 6
local ROW_H = 50
local FACE = 40              -- портрет моба (вместо имени)
local TARGET_FACE = 64       -- портрет вашей цели (строка по центру)
local TARGET_HP_W, TARGET_HP_H = 128, 8 -- полоска здоровья цели под портретом
local ICON = 34
-- Главные ослабления — первыми (все значки одного размера ICON): замедление — моб не убежит,
-- Кровопускание — от него «Вкус крови» и Превосходство, Раскол брони — стаки
local PRIORITY = {
	[GetSpellInfo(1715) or "?"] = 4,  -- Подрезать сухожилия
	[GetSpellInfo(12323) or "?"] = 4, -- Пронзительный вой
	[GetSpellInfo(772) or "?"] = 3,   -- Кровопускание
	[GetSpellInfo(7386) or "?"] = 2,  -- Раскол брони
}
local ROUND = "Interface\\CharacterFrame\\TempPortraitAlphaMask" -- белый круг
-- Кровопускание и Подрезать сухожилия: у мобов справа, когда кончаются, — крупнее и мигают
local ENDING_ALERT = { [GetSpellInfo(772) or "?"] = true, [GetSpellInfo(1715) or "?"] = true }
local REND_BIG = 46
local UNKNOWN_FACE = "Interface\\Icons\\INV_Misc_QuestionMark" -- портрет ещё не видели
local TIMEOUT = 8            -- столько секунд без ударов — враг пропадает (если нет ваших ослаблений)
local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40
local UNITS = { "target", "focus", "mouseover" }
-- длительность, пока не выучена с цели (по названию заклинания)
local FALLBACK = {
	[GetSpellInfo(772) or "?"] = 15,   -- Кровопускание
	[GetSpellInfo(7386) or "?"] = 30,  -- Раскол брони
	[GetSpellInfo(1715) or "?"] = 15,  -- Подрезать сухожилия
	[GetSpellInfo(12721) or "?"] = 6,  -- Глубокие раны
	[GetSpellInfo(6343) or "?"] = 30,  -- Удар грома
	[GetSpellInfo(1160) or "?"] = 30,  -- Деморализующий крик
}

local function Enabled() return not (ProcAlertDB and ProcAlertDB.enemies == false) end
local function Learned()
	ProcAlertDB = ProcAlertDB or {}
	ProcAlertDB.debuffDur = ProcAlertDB.debuffDur or {}
	return ProcAlertDB.debuffDur
end

local enemies = {} -- GUID -> { name, seen, hp (%), debuffs = { [название] = { icon, count, expires } } }

local function Enemy(guid, name)
	local e = enemies[guid]
	if not e then
		e = { name = name or "?", debuffs = {} }
		enemies[guid] = e
	end
	if name then e.name = name end
	e.seen = GetTime()
	return e
end

-- кадры портретов (см. Face ниже): убранный враг возвращает свой в запас
local facePool = {}
local function FreeFace(e)
	if e.face then
		e.face:Hide()
		tinsert(facePool, e.face)
		e.face = nil
	end
end
local function Remove(guid)
	local e = enemies[guid]
	if e then FreeFace(e) end
	enemies[guid] = nil
end

local log = CreateFrame("Frame")
log:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
log:RegisterEvent("PLAYER_REGEN_ENABLED")
log:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_REGEN_ENABLED" then
		for guid in pairs(enemies) do Remove(guid) end
		return
	end
	local _, sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags = ...
	if sub == "UNIT_DIED" or sub == "PARTY_KILL" then Remove(dstGUID) return end
	local me = UnitGUID("player")
	if dstGUID == me and srcGUID ~= me then
		-- бьют вас
		if srcFlags and bit.band(srcFlags, HOSTILE) > 0 and (sub:find("_DAMAGE$") or sub:find("_MISSED$")) then
			Enemy(srcGUID, srcName)
		end
		return
	end
	if srcGUID ~= me or not (dstFlags and bit.band(dstFlags, HOSTILE) > 0) then return end
	-- ваши действия по врагу
	if sub:find("_DAMAGE$") or sub:find("_MISSED$") then
		Enemy(dstGUID, dstName)
	elseif sub:find("^SPELL_AURA") then
		local spellId, spellName, _, auraType, amount = select(9, ...)
		if auraType ~= "DEBUFF" then return end
		if sub == "SPELL_AURA_REMOVED" then
			-- снятие не добавляет врага в список (иначе после боя он появился бы снова)
			local e = enemies[dstGUID]
			if e then e.debuffs[spellName] = nil end
			return
		end
		local e = Enemy(dstGUID, dstName)
		do
			local d = e.debuffs[spellName] or {}
			d.icon = select(3, GetSpellInfo(spellId))
			d.spellId = spellId
			if sub == "SPELL_AURA_APPLIED_DOSE" or sub == "SPELL_AURA_REMOVED_DOSE" then
				d.count = amount
			elseif sub == "SPELL_AURA_APPLIED" then
				d.count = 1
			end
			if sub ~= "SPELL_AURA_REMOVED_DOSE" then
				local dur = Learned()[spellName] or FALLBACK[spellName]
				d.expires = dur and (GetTime() + dur) or nil
			end
			e.debuffs[spellName] = d
		end
	end
end)

-- Цель, фокус, моб под курсором: точные здоровье и ослабления, заодно выучить длительности
local function Sync(unit)
	local guid = UnitGUID(unit)
	local e = guid and enemies[guid]
	if not e then return end
	local max = UnitHealthMax(unit)
	if max and max > 0 then e.hp = UnitHealth(unit) / max * 100 end
	-- в бою с вами (в списке угрозы), но бьёт не вас — красная рамка (кого провоцировать)
	local tanking, status = UnitDetailedThreatSituation("player", unit)
	if status ~= nil then e.notOnMe = not tanking else e.notOnMe = nil end
	e.faceUnit = e.faceUnit or unit -- портрет снять при отрисовке, пока моб доступен по этой метке
	local exact = {}
	for i = 1, 40 do
		local name, _, icon, count, _, duration, expires, caster, _, _, spellId = UnitDebuff(unit, i)
		if not name then break end
		if caster == "player" then
			exact[name] = { icon = icon, count = count, expires = (expires and expires > 0) and expires or nil, spellId = spellId }
			if duration and duration > 0 then Learned()[name] = duration end
		end
	end
	e.debuffs = exact
end

----------------------------------------------------------------------------------------------
local frame = CreateFrame("Frame", "ProcAlertEnemies", UIParent)
frame:SetWidth(FACE + 6 + 6 * (ICON + 2))
frame:SetHeight(MAX_ROWS * ROW_H)
frame:SetPoint("TOPLEFT", UIParent, "CENTER", X, Y)
frame:SetFrameStrata("HIGH")

local rows = {}
local function Row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Frame", nil, frame)
	r:SetWidth(frame:GetWidth())
	r:SetHeight(ROW_H)
	if i > 0 then r:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(i - 1) * ROW_H) end
	r.border = r:CreateTexture(nil, "BORDER") -- жёлтая рамка — ваша цель
	-- портрет круглый, поэтому и рамки — круги (белый круг-маска, перекрашенный)
	r.border:SetWidth(FACE + 6)
	r.border:SetHeight(FACE + 6)
	r.border:SetTexture(ROUND)
	r.border:SetVertexColor(1, 0.82, 0, 1)
	r.warn = r:CreateTexture(nil, "BACKGROUND") -- красная рамка шире (под жёлтой) — бьёт не вас
	r.warn:SetPoint("CENTER", r.border, "CENTER", 0, 0)
	r.warn:SetWidth(FACE + 12)
	r.warn:SetHeight(FACE + 12)
	r.warn:SetTexture(ROUND)
	r.warn:SetVertexColor(1, 0.1, 0.1, 1)
	r.hp = CreateFrame("StatusBar", nil, r)
	r.hp:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -(FACE + 4))
	r.hp:SetWidth(FACE)
	r.hp:SetHeight(5)
	r.hp:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	r.hp:SetStatusBarColor(0.9, 0.15, 0.15)
	r.hp:SetMinMaxValues(0, 100)
	r.hp.bg = r.hp:CreateTexture(nil, "BACKGROUND")
	r.hp.bg:SetAllPoints(r.hp)
	r.hp.bg:SetTexture(0, 0, 0, 0.6)
	r.icons = {}
	rows[i] = r
	return r
end

-- Подсказка к значку ослабления — как у стандартных: если моб сейчас доступен по метке (цель, фокус,
-- под курсором, полоска над головой) — точная (SetUnitDebuff), иначе — описание заклинания и остаток
local function TipUnit(guid)
	for _, unit in ipairs(UNITS) do
		if UnitGUID(unit) == guid then return unit end
	end
	if C_NamePlate and C_NamePlate.GetNamePlates then
		for _, plate in pairs(C_NamePlate.GetNamePlates() or {}) do
			local unit = plate.namePlateUnitToken
			if unit and UnitGUID(unit) == guid then return unit end
		end
	end
end
local function DebuffTooltip(f)
	if not f.guid or not f.debuffName then return end
	GameTooltip:SetOwner(f, "ANCHOR_BOTTOMRIGHT")
	local unit = TipUnit(f.guid)
	if unit then
		for i = 1, 40 do
			local name, _, _, _, _, _, _, caster = UnitDebuff(unit, i)
			if not name then break end
			if name == f.debuffName and caster == "player" then
				GameTooltip:SetUnitDebuff(unit, i)
				return
			end
		end
	end
	if f.spellId then
		GameTooltip:SetHyperlink("spell:" .. f.spellId)
	else
		GameTooltip:AddLine(f.debuffName, 1, 0.82, 0)
	end
	local e = enemies[f.guid]
	local d = e and e.debuffs[f.debuffName]
	if d and d.expires then
		GameTooltip:AddLine(string.format("Осталось: %d с", math.max(0, math.ceil(d.expires - GetTime()))), 1, 1, 1)
	end
	GameTooltip:Show()
end

local function Icon(r, k)
	local f = r.icons[k]
	if f then return f end
	f = CreateFrame("Frame", nil, r)
	f:EnableMouse(true)
	f:SetScript("OnEnter", DebuffTooltip)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.tex = f:CreateTexture(nil, "ARTWORK")
	f.tex:SetAllPoints(f)
	f.time = f:CreateFontString(nil, "OVERLAY")
	f.time:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
	f.time:SetPoint("TOP", f, "BOTTOM", 0, 1)
	f.count = f:CreateFontString(nil, "OVERLAY")
	f.count:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
	f.count:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1, 0)
	r.icons[k] = f
	return f
end

-- Портрет живёт на своём кадре у врага (картинку из SetPortraitTexture потом не получить заново)
local function Face(e)
	if e.face then return e.face end
	local f = tremove(facePool)
	if not f then
		f = CreateFrame("Frame", nil, frame)
		f:SetWidth(FACE)
		f:SetHeight(FACE)
		f:SetFrameLevel(frame:GetFrameLevel() + 3)
		f.tex = f:CreateTexture(nil, "ARTWORK")
		f.tex:SetAllPoints(f)
	end
	SetPortraitToTexture(f.tex, UNKNOWN_FACE) -- знак вопроса тоже круглый, как портрет
	f.tex:SetTexCoord(0, 1, 0, 1)
	f.real = false
	e.face = f
	return f
end

local elapsedSum = 0
frame:SetScript("OnUpdate", function(_, elapsed)
	elapsedSum = elapsedSum + elapsed
	if elapsedSum < 0.1 then return end
	elapsedSum = 0
	local now = GetTime()
	for _, unit in ipairs(UNITS) do Sync(unit) end
	-- новые полоски Sirus (C_NamePlate): у каждой своя метка «nameplateN» — точные здоровье,
	-- ослабления и портрет для мобов с видимой полоской. Нужно только для столбика справа:
	-- враг один (только цель) — полоски не перебираем, цель и так читается напрямую
	local count = 0
	for _ in pairs(enemies) do
		count = count + 1
		if count > 1 then break end
	end
	if count > 1 and C_NamePlate and C_NamePlate.GetNamePlates then
		for _, plate in pairs(C_NamePlate.GetNamePlates() or {}) do
			if plate.namePlateUnitToken then Sync(plate.namePlateUnitToken) end
		end
	end

	local list = {}
	local target = UnitGUID("target")
	for guid, e in pairs(enemies) do
		for name, d in pairs(e.debuffs) do
			if d.expires and d.expires <= now then e.debuffs[name] = nil end
		end
		if now - e.seen > TIMEOUT and not next(e.debuffs) then
			Remove(guid)
		else
			e.guid = guid
			list[#list + 1] = e
		end
	end
	-- вне боя список не нужен: прячем (данные остаются до конца боя, после него — очищаются)
	if not Enabled() or not UnitAffectingCombat("player") then
		for _, e in ipairs(list) do if e.face then e.face:Hide() end end
		list = {}
	end
	table.sort(list, function(a, b) return a.seen > b.seen end)

	-- ваша цель — отдельной строкой по центру под срабатываниями, остальные — столбиком справа
	local targetEntry
	for i, e in ipairs(list) do
		if e.guid == target then targetEntry = tremove(list, i) break end
	end
	-- vertical — строка цели в центре: крупный портрет сверху, под ним здоровье и ряд ослаблений
	local function Draw(r, e, vertical)
		if not e then
			if r then r:Hide() end
			return
		end
		local fs = vertical and TARGET_FACE or FACE
		local face = Face(e)
		if not face.real and e.faceUnit and UnitGUID(e.faceUnit) == e.guid then
			SetPortraitTexture(face.tex, e.faceUnit)
			face.tex:SetTexCoord(0, 1, 0, 1)
			face.real = true
		end
		e.faceUnit = nil
		face:SetWidth(fs)
		face:SetHeight(fs)

		local names = {}
		for name in pairs(e.debuffs) do names[#names + 1] = name end
		table.sort(names, function(a, b)
			local sa, sb = PRIORITY[a] or 0, PRIORITY[b] or 0
			if sa ~= sb then return sa > sb end
			return a < b
		end)
		-- Кровопускание / Подрезать сухожилия кончается (меньше REND_REFRESH с) — значок мигает; у мобов справа ещё и крупнее
		-- (у цели размер не меняем: значки в одну линию со срабатываниями)
		local function Ending(name)
			local d = e.debuffs[name]
			return ENDING_ALERT[name] and d.expires and (d.expires - now) < REND_REFRESH
		end
		-- у цели значки размером со срабатывания и с тем же промежутком
		local base = vertical and PROC_SIZE or ICON
		local gap = vertical and GetGap() or 3
		local iconsW, maxSize = 0, 0
		for k, name in ipairs(names) do
			local size = (Ending(name) and not vertical) and REND_BIG or base
			iconsW = iconsW + size + (k > 1 and gap or 0)
			if size > maxSize then maxSize = size end
		end

		-- ширина строки и место портрета
		local width, x, iconsTop
		if vertical then -- цель: без портрета — ослабления в ряд со срабатываниями, под ними здоровье
			width = math.max(iconsW, TARGET_HP_W)
			x = (width - iconsW) / 2
			iconsTop = 0
		else
			width = fs + 6 + iconsW
			face:ClearAllPoints()
			face:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -2)
			x = fs + 6
		end
		if vertical then face:Hide() else face:Show() end
		r.border:SetWidth(fs + 6)
		r.border:SetHeight(fs + 6)
		r.border:ClearAllPoints()
		r.border:SetPoint("CENTER", face, "CENTER", 0, 0)
		r.warn:SetWidth(fs + 12)
		r.warn:SetHeight(fs + 12)
		if e.guid == target and not vertical then r.border:Show() else r.border:Hide() end
		if e.notOnMe and not vertical then r.warn:Show() else r.warn:Hide() end
		r.hp:SetWidth(vertical and TARGET_HP_W or fs)
		r.hp:SetHeight(vertical and TARGET_HP_H or 5)
		r.hp:ClearAllPoints()
		if vertical then
			r.hp:SetPoint("TOP", r, "TOPLEFT", width / 2, -(PROC_SIZE + 8))
		else
			r.hp:SetPoint("TOP", face, "BOTTOM", 0, -2)
		end
		if e.hp then
			r.hp:SetValue(e.hp)
			r.hp:Show()
		else
			r.hp:Hide()
		end

		for k, name in ipairs(names) do
			local d = e.debuffs[name]
			local f = Icon(r, k)
			local ending = Ending(name)
			local size = (ending and not vertical) and REND_BIG or base
			if f.size ~= size or f.vertical ~= vertical then
				f.size, f.vertical = size, vertical
				f:SetWidth(size)
				f:SetHeight(size)
				f.time:ClearAllPoints()
				if vertical then -- как у срабатываний: отсчёт крупно по центру значка
					f.time:SetFont("Fonts\\FRIZQT__.TTF", math.floor(size * 0.4), "THICKOUTLINE")
					f.time:SetPoint("CENTER", f, "CENTER", 0, 0)
					f.count:SetFont("Fonts\\FRIZQT__.TTF", math.floor(size * 0.3), "OUTLINE")
				else
					local font = ending and 18 or 14
					f.time:SetFont("Fonts\\FRIZQT__.TTF", font, "OUTLINE")
					f.time:SetPoint("TOP", f, "BOTTOM", 0, 1)
					f.count:SetFont("Fonts\\FRIZQT__.TTF", font, "OUTLINE")
				end
			end
			f:ClearAllPoints()
			if vertical then -- ряд под портретом, значки выровнены по центру ряда
				f:SetPoint("TOPLEFT", r, "TOPLEFT", x, iconsTop - (maxSize - size) / 2)
			else -- справа от портрета, по центру портрета по высоте
				f:SetPoint("TOPLEFT", r, "TOPLEFT", x, -2 - fs / 2 + size / 2)
			end
			x = x + size + gap
			f.guid, f.debuffName, f.spellId = e.guid, name, d.spellId
			f.tex:SetTexture(d.icon)
			local left = d.expires and (d.expires - now)
			f.time:SetText(left and string.format("%d", math.ceil(left)) or "")
			if left and left < 3 then
				f.time:SetTextColor(1, 0.3, 0.3)
			elseif vertical then
				f.time:SetTextColor(1, 0.85, 0) -- жёлтый, как отсчёт у срабатываний
			else
				f.time:SetTextColor(1, 1, 1)
			end
			f.count:SetText((d.count and d.count > 1) and d.count or "")
			f:SetAlpha(ending and (0.35 + 0.65 * math.abs(math.sin(now * 6))) or 1)
			f:Show()
		end
		for k = #names + 1, #r.icons do r.icons[k]:Hide() end
		r:Show()
		return width
	end

	local tr = targetEntry and Row(0) or rows[0]
	local width = Draw(tr, targetEntry, true)
	if width then
		tr:ClearAllPoints()
		tr:SetPoint("TOPLEFT", anchor, "CENTER", TARGET_X, TARGET_Y)
	end
	for i = 1, MAX_ROWS do
		local e = list[i]
		Draw(e and Row(i) or rows[i], e)
	end
	for i = MAX_ROWS + 1, #list do -- не влезли в список — их портреты не показываем
		if list[i].face then list[i].face:Hide() end
	end
end)
end)()

----------------------------------------------------------------------------------------------
-- Слева от срабатываний: значок текущей стойки.
-- Рамка мигает красным, если стойка и щит не сходятся: в оборонительной нет щита или щит в боевой / берсерка
;(function()
local SIZE = PROC_SIZE -- как у срабатываний
local RIGHT_X = -120 -- правый край значка от центра ряда срабатываний (цель с ослаблениями — справа, на 130)

local function NewIcon(x)
	local f = CreateFrame("Frame", nil, anchor)
	f:SetWidth(SIZE)
	f:SetHeight(SIZE)
	f:SetPoint("RIGHT", anchor, "CENTER", x, 0)
	f.border = f:CreateTexture(nil, "BACKGROUND") -- рамка: чёрная, при несовпадении — красная
	f.border:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
	f.border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
	f.border:SetTexture(0, 0, 0)
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetAllPoints(f)
	f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	f:Hide()
	return f
end
local stanceIcon = NewIcon(RIGHT_X)

local function HasShield()
	local link = GetInventoryItemLink("player", 17)
	return link and select(9, GetItemInfo(link)) == "INVTYPE_SHIELD"
end

local elapsedSum, wrong = 0, false
local holder = CreateFrame("Frame", nil, anchor)
holder:SetScript("OnUpdate", function(_, elapsed)
	if wrong then -- мигание рамки, как у кончающихся ослаблений
		local a = 0.35 + 0.65 * math.abs(math.sin(GetTime() * 6))
		stanceIcon.border:SetTexture(a, 0.1 * a, 0.1 * a)
	end
	elapsedSum = elapsedSum + elapsed
	if elapsedSum < 0.2 then return end
	elapsedSum = 0
	local stance = CurrentStance()
	local form = GetShapeshiftForm()
	local stanceTex = form and form > 0 and GetShapeshiftFormInfo(form)
	if (ProcAlertDB and ProcAlertDB.stanceLine == false) or not stance or not stanceTex or UnitIsDeadOrGhost("player") then
		stanceIcon:Hide()
		wrong = false
		return
	end
	wrong = (stance == DEFENSIVE) ~= (HasShield() and true or false)
	if not wrong then
		stanceIcon.border:SetTexture(0, 0, 0)
	end
	stanceIcon.icon:SetTexture(stanceTex)
	stanceIcon:Show()
end)
end)()
