#!/usr/bin/env python3
"""Выгрузка экипировки персонажа: характеристики персонажа, надетое (с чарами и камнями), наборы экипировки
и таблица характеристик каждого предмета.

Источник — сохранения аддона GearPlan (WTF/.../<персонаж>/SavedVariables/GearPlan.lua: gear, equipSets, bagGear,
stats, itemInfo),
пишутся во время игры и при /reload. Названия чар — из таблиц клиента
(SpellItemEnchantment.dbc через mpq.py/dbc.py), названия и уровни предметов — из кеша клиента (itemcache.wdb),
чего там нет — из базы Sirus (кеш Tools/.cache). Нет данных GearPlan или --armory — арморка Sirus
(на последний выход, без наборов и чар).

Примеры:
  python3 Tools/gear.py                  # Tools/GearPlan/gear.md, персонаж Чигурх
  python3 Tools/gear.py --char Раба
  python3 Tools/gear.py --stdout         # в терминал, без файла
  python3 Tools/gear.py --json           # Tools/GearPlan/gear.json
  python3 Tools/gear.py --armory         # только арморка
"""
import argparse
import datetime
import glob
import os
import re
import struct
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "GearPlan"
CACHE = HERE / ".cache"
CHAR = "Чигурх"  # персонаж по умолчанию
REALM = 22       # Neverest x3 (список миров: https://sirus.su/api/v2/data)
API = "https://api.sirus.su/api/base/{realm}/{path}?lang=ru"
UA = "Mozilla/5.0 (X11; Linux x86_64)"

SLOTS = {
    "head": "Голова", "neck": "Шея", "shoulders": "Плечи", "back": "Спина",
    "chest": "Грудь", "body": "Рубашка", "tabard": "Гербовая накидка",
    "wrists": "Запястья", "hands": "Кисти рук", "waist": "Пояс", "legs": "Ноги",
    "feet": "Ступни", "finger1": "Палец 1", "finger2": "Палец 2",
    "trinket1": "Аксессуар 1", "trinket2": "Аксессуар 2",
    "mainhand": "Правая рука", "offhand": "Левая рука", "ranged": "Дальний бой",
}
QUALITY = {0: "серый", 1: "белый", 2: "зелёный", 3: "синий", 4: "фиолетовый",
           5: "оранжевый", 6: "артефакт", 7: "наследие"}


def fetch(path, realm):
    url = API.format(realm=realm, path=path)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def gem_name(entry, realm):
    """Название камня по id предмета, с постоянным кешем."""
    CACHE.mkdir(exist_ok=True)
    f = CACHE / f"item_{realm}_{entry}.json"
    if f.exists():
        data = json.loads(f.read_text(encoding="utf-8"))
    else:
        time.sleep(2)  # чужой сайт: не частим
        try:
            data = fetch(f"details/item/{entry}", realm)
        except Exception:
            return f"камень {entry}"
        f.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    item = data.get("item") or data.get("tooltip") or {}
    return item.get("name") or f"камень {entry}"


def collect(char, realm, ench=None, cache=None):
    try:
        data = fetch("character/" + urllib.parse.quote(char), realm)
    except Exception as e:
        sys.exit(f"не удалось получить персонажа «{char}»: {e}")
    if "character" not in data:
        sys.exit(f"персонаж «{char}» не найден: {data.get('message', data)}")
    c = data["character"]
    items = []
    for x in data.get("equipments") or []:
        name = x.get("name")
        items.append({
            "slot": x.get("key"),
            "slotName": SLOTS.get(x.get("key"), x.get("key")),
            "entry": x.get("entry"),
            "name": name,
            "itemLevel": x.get("itemLevel"),
            "quality": QUALITY.get(x.get("quality"), x.get("quality")) if name else None,
            "gems": [gem_text(g["entry"], ench or {}, cache or {}, realm) for g in x.get("gems") or [] if g.get("entry")],
        })
    return {
        "char": c.get("name"), "level": c.get("level"), "class": c.get("className"),
        "race": c.get("raceName"), "ilvl": c.get("ilvl"), "realm": realm, "items": items,
    }


GAME = HERE.parents[3]  # .../World of Warcraft Sirus
WTF = GAME / "WTF" / "Account"

# inventory slot -> name (GetInventoryItemLink slot ids)
INV = {1: "Голова", 2: "Шея", 3: "Плечи", 4: "Рубашка", 5: "Грудь", 6: "Пояс", 7: "Ноги", 8: "Ступни",
       9: "Запястья", 10: "Кисти рук", 11: "Палец 1", 12: "Палец 2", 13: "Аксессуар 1", 14: "Аксессуар 2",
       15: "Спина", 16: "Правая рука", 17: "Левая рука", 18: "Дальний бой", 19: "Гербовая накидка"}


# --------------------------------------------------------------------------------------------
# SavedVariables: a small reader of the Lua tables the game writes
class LuaReader:
    def __init__(self, text):
        self.s, self.i = text, 0

    def ws(self):
        s = self.s
        while self.i < len(s):
            if s[self.i] in " \t\r\n,;":
                self.i += 1
            elif s.startswith("--", self.i):
                j = s.find("\n", self.i)
                self.i = len(s) if j < 0 else j
            else:
                break

    def value(self):
        self.ws()
        s, c = self.s, self.s[self.i]
        if c == "{":
            return self.table()
        if c == '"':
            return self.string()
        for word, v in (("true", True), ("false", False), ("nil", None)):
            if s.startswith(word, self.i):
                self.i += len(word)
                return v
        m = re.compile(r"-?[0-9.eE+-]+").match(s, self.i)
        self.i = m.end()
        t = m.group(0)
        return float(t) if any(ch in t for ch in ".eE") else int(t)

    def string(self):
        s, i, out = self.s, self.i + 1, []
        while s[i] != '"':
            if s[i] == "\\":
                n = s[i + 1]
                if n.isdigit():
                    m = re.compile(r"\d{1,3}").match(s, i + 1)
                    out.append(chr(int(m.group(0))))
                    i = m.end()
                    continue
                out.append({"n": "\n", "t": "\t"}.get(n, n))
                i += 2
            else:
                out.append(s[i])
                i += 1
        self.i = i + 1
        raw = "".join(out)
        try:
            return raw.encode("latin-1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return raw

    def table(self):
        self.i += 1
        t, n = {}, 1
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                return t
            if self.s[self.i] == "[":
                self.i += 1
                k = self.value()
                self.ws()
                self.i += 1  # ]
                self.ws()
                self.i += 1  # =
                t[k] = self.value()
            else:
                v = self.value()
                if v is not None:  # the game writes { nil, x, ... } for tables starting at [2]
                    t[n] = v
                n += 1

    def globals(self):
        out = {}
        while True:
            self.ws()
            m = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*=").match(self.s, self.i)
            if not m:
                return out
            self.i = m.end()
            out[m.group(1)] = self.value()


def sv_path(char):
    hits = glob.glob(str(WTF / "*" / "*" / char / "SavedVariables" / "GearPlan.lua"))
    return Path(max(hits, key=os.path.getmtime)) if hits else None


def seq(t):
    return [t[k] for k in sorted(k for k in (t or {}) if isinstance(k, int))]


# --------------------------------------------------------------------------------------------
# client data: enchant names (DBC), item names and levels (itemcache.wdb)
def enchant_names():
    import dbc
    import mpq
    data = GAME / "Data"
    files = glob.glob(str(data / "*.[mM][pP][qQ]")) + glob.glob(str(data / "ruRU" / "*.mpq"))

    def key(p):
        b = os.path.basename(p).lower()
        suf = b.replace("patch-ruru", "").replace("patch", "").replace(".mpq", "").strip("-")
        return (b.startswith("patch"), "ruru" in b, suf != "", suf)
    for p in sorted(files, key=key, reverse=True):
        try:
            raw = mpq.Archive(p).read("DBFilesClient\\SpellItemEnchantment.dbc")
        except Exception:
            raw = None
        if raw:
            rows, st = dbc.parse(raw)
            clean = lambda t: re.sub(r"\|c[0-9A-Fa-f]{8}|\|r", "", t)
            # 22: ruRU name, 33: the gem item of a gem's effect
            return {r[0]: (clean(dbc.string(st, r[22])), r[33]) for r in rows}
    return {}


def gem_text(eid, ench, cache, realm):
    """A gem in a link (and in the armory) is its effect id from SpellItemEnchantment, not the gem item."""
    effect, item = ench.get(eid, (None, 0))
    if not item:
        return effect or f"камень {eid}"
    name = cache[item][0] if item in cache else gem_name(item, realm)
    return f"{name} ({effect})" if effect else name


def item_cache():
    """itemcache.wdb -> {id: (name, item level)}: what the client has seen."""
    out = {}
    f = GAME / "Cache" / "WDB" / "ruRU" / "itemcache.wdb"
    if not f.exists():
        return out
    b, o = f.read_bytes(), 24
    while o + 8 <= len(b):
        e, sz = struct.unpack_from("<iI", b, o)
        o += 8
        if e == 0 and sz == 0:
            break
        r = b[o:o + sz]
        o += sz
        try:
            q, names = 12, []
            for _ in range(4):
                z = r.index(b"\0", q)
                names.append(r[q:z].decode("utf-8", "replace"))
                q = z + 1
            # display, quality, flags, flags2, buy, sell, inventory type, classes, races, item level
            ilvl = struct.unpack_from("<10i", r, q)[9]
            out[e] = (names[0], ilvl)
        except (ValueError, struct.error):
            pass
    return out


LINK = re.compile(r"\|Hitem:(-?\d+):(-?\d+):(-?\d+):(-?\d+):(-?\d+):(-?\d+)[^|]*\|h\[([^\]]*)\]")


def parse_link(link):
    m = LINK.search(link or "")
    if not m:
        return None
    v = [int(x) for x in m.groups()[:6]]
    return {"id": v[0], "enchant": v[1], "gems": [g for g in v[2:6] if g], "name": m.group(7)}


def describe(link, ench, cache, realm, infos=None):
    p = parse_link(link)
    if not p:
        return None
    name, ilvl = cache.get(p["id"], (p["name"], None))
    info = (infos or {}).get(link) or {}
    return {"id": p["id"], "name": p["name"] or name, "itemLevel": info.get("ilvl") or ilvl,
            "enchant": ench.get(p["enchant"], (f"чары {p['enchant']}",))[0] if p["enchant"] else None,
            "gems": [gem_text(g, ench, cache, realm) for g in p["gems"]],
            "type": info.get("type"), "equipSlot": info.get("slot"),
            "stats": info.get("stats") or {}, "effects": seq(info.get("effects"))}


def collect_sv(char, realm):
    path = sv_path(char)
    if not path:
        return None
    db = LuaReader(path.read_text(encoding="utf-8", errors="replace")).globals().get("GearPlanDB") or {}
    if not db.get("gear") and not db.get("equipSets"):
        return None
    ench, cache = enchant_names(), item_cache()
    infos = db.get("itemInfo") or {}
    items = []
    for slot in range(1, 20):
        d = describe((db.get("gear") or {}).get(slot), ench, cache, realm, infos)
        items.append({"slot": slot, "slotName": INV[slot], **(d or {"name": None})})
    # links by item id: bags, then what is worn (sets keep only ids)
    where = {}
    for place, links in (("сумки", seq(db.get("bagGear"))),
                         ("надето", [(db.get("gear") or {}).get(s) for s in range(1, 20)])):
        for link in links:
            p = parse_link(link)
            if p:
                where[p["id"]] = (place, link)
    sets = []
    for st in seq(db.get("equipSets")):
        rows = []
        for slot in range(1, 20):
            iid = (st.get("items") or {}).get(slot) or 0
            if iid in (0, 1):
                continue  # 0 - empty, 1 - the set leaves the slot alone
            place, link = where.get(iid, ("не в сумках", None))
            d = describe(link, ench, cache, realm, infos) if link else {
                "id": iid, "name": cache.get(iid, (f"предмет {iid}", None))[0],
                "itemLevel": cache.get(iid, (None, None))[1], "enchant": None, "gems": []}
            rows.append({"slot": slot, "slotName": INV[slot], "where": place, **d})
        sets.append({"name": st.get("name"), "items": rows})
    stamp = db.get("gearTime")
    return {"char": char, "source": f"GearPlan ({path.parent.parent.parent.name})",
            "time": datetime.datetime.fromtimestamp(stamp).strftime("%Y-%m-%d %H:%M") if stamp else "?",
            "stats": db.get("stats"), "items": items, "sets": sets}


# --------------------------------------------------------------------------------------------
def line(i):
    s = f"{i['name']}" + (f" [{i['itemLevel']}]" if i.get("itemLevel") else "")
    if i.get("enchant"):
        s += f"; чары: {i['enchant']}"
    if i.get("gems"):
        s += "; камни: " + ", ".join(i["gems"])
    return s


STAT = {1: "Сила", 2: "Ловкость", 3: "Выносливость", 4: "Интеллект", 5: "Дух"}
SCHOOL = {2: "Свет", 3: "Огонь", 4: "Природа", 5: "Лёд", 6: "Тьма", 7: "Тайная магия"}
RATING = {  # CR_* -> название рейтинга
    2: "Рейтинг защиты", 3: "Рейтинг уклонения", 4: "Рейтинг парирования", 5: "Рейтинг блока",
    6: "Рейтинг меткости (ближний бой)", 7: "Рейтинг меткости (дальний бой)", 8: "Рейтинг меткости (заклинания)",
    9: "Рейтинг крит. удара (ближний бой)", 10: "Рейтинг крит. удара (дальний бой)",
    11: "Рейтинг крит. удара (заклинания)", 15: "Устойчивость", 18: "Рейтинг скорости (ближний бой)",
    19: "Рейтинг скорости (дальний бой)", 20: "Рейтинг скорости (заклинания)", 24: "Рейтинг мастерства",
    25: "Рейтинг пробивания брони",
}


def num(v, digits=2):
    if v is None:
        return "—"
    if isinstance(v, float) and not v.is_integer():
        return f"{v:.{digits}f}".rstrip("0").rstrip(".") if digits else str(round(v))
    return str(int(v))


def cell(t):
    return re.sub(r"\|c[0-9A-Fa-f]{8}|\|r", "", str(t)).replace("|", "\\|").replace("\n", " ")


def stats_rows(s):
    """Характеристики персонажа -> [(название, значение)]."""
    rows = [("Персонаж", f"{s.get('race', '')} {s.get('class', '')}, {num(s.get('level'))} ур."),
            ("Таланты", s.get("talents") or "—")]
    rows += [(STAT[i], num(s.get(f"stat{i}"))) for i in range(1, 6)]
    rows += [("Здоровье", num(s.get("health")))]
    if s.get("mana"):
        rows.append(("Мана", num(s.get("mana"))))
    rows += [("Броня", num(s.get("armor"))), ("Сила атаки", num(s.get("ap"))),
             ("Сила атаки дальнего боя", num(s.get("rap")))]
    if s.get("dmgMax"):
        rows.append(("Урон правой рукой", f"{num(s.get('dmgMin'), 0)}-{num(s.get('dmgMax'), 0)}, "
                     f"скорость {num(s.get('speedMain'))}"))
    if s.get("speedOff"):
        rows.append(("Урон левой рукой", f"{num(s.get('dmgOffMin'), 0)}-{num(s.get('dmgOffMax'), 0)}, "
                     f"скорость {num(s.get('speedOff'))}"))
    if s.get("dmgRangedMax"):
        rows.append(("Урон дальнего боя", f"{num(s.get('dmgRangedMin'), 0)}-{num(s.get('dmgRangedMax'), 0)}, "
                     f"скорость {num(s.get('speedRanged'))}"))
    rows += [("Крит. удар ближнего боя", num(s.get("critMelee")) + "%"),
             ("Крит. удар дальнего боя", num(s.get("critRanged")) + "%")]
    sp, sc = s.get("spellPower") or {}, s.get("spellCrit") or {}
    if len(set(sp.values())) <= 1:
        rows.append(("Сила заклинаний", num(max(sp.values(), default=None))))
    else:
        rows += [(f"Сила заклинаний ({SCHOOL[k]})", num(sp[k])) for k in sorted(sp)]
    rows.append(("Бонус к исцелению", num(s.get("healing"))))
    if len(set(sc.values())) <= 1:
        rows.append(("Крит. удар заклинаниями", num(max(sc.values(), default=None)) + "%"))
    else:
        rows += [(f"Крит. удар заклинаниями ({SCHOOL[k]})", num(sc[k]) + "%") for k in sorted(sc)]
    if s.get("spellPen"):
        rows.append(("Проникающая способность заклинаний", num(s.get("spellPen"))))
    if s.get("mana"):
        rows.append(("Восполнение маны за 5 с (вне/во время произнесения)",
                     f"{num(s.get('mp5'), 0)} / {num(s.get('mp5Casting'), 0)}"))
    rows += [("Защита", num(s.get("defense"))), ("Уклонение", num(s.get("dodge")) + "%"),
             ("Парирование", num(s.get("parry")) + "%"), ("Блок", num(s.get("block")) + "%")]
    if s.get("blockValue"):
        rows.append(("Показатель блокирования", num(s.get("blockValue"))))
    rows.append(("Мастерство", num(s.get("expertise"))))
    if s.get("armorPen"):
        rows.append(("Пробивание брони", num(s.get("armorPen")) + "%"))
    rating, bonus = s.get("rating") or {}, s.get("ratingBonus") or {}
    for cr, name in RATING.items():
        if rating.get(cr):
            unit = "" if cr in (2, 24) else "%"  # defense and expertise: skill points, not percent
            rows.append((name, f"{num(rating[cr])} (+{num(bonus.get(cr))}{unit})"))
    res = s.get("res") or {}
    rows += [(f"Сопротивление: {SCHOOL[i + 1]}", num(res[i])) for i in sorted(res) if res[i]]
    return rows


# item stat labels as the Sirus client gives them ("к силе") -> the usual names, in display order
STAT_LABEL = {
    "к броне": "Броня", "к урону в секунду": "Урон в секунду",
    "к силе": "Сила", "к ловкости": "Ловкость", "к выносливости": "Выносливость", "к интеллекту": "Интеллект",
    "к духу": "Дух", "к здоровью": "Здоровье", "к мане": "Мана",
    "к силе атаки": "Сила атаки", "к силе атаки дальнего боя": "Сила атаки дальнего боя",
    "к силе атаки в облике зверя": "Сила атаки в облике зверя", "к силе заклинаний": "Сила заклинаний",
    "к проникающей способности заклинаний": "Проникающая способность заклинаний",
    "к рейтингу меткости": "Рейтинг меткости", "к рейтингу критического удара": "Рейтинг критического удара",
    "к рейтингу скорости": "Рейтинг скорости", "к рейтингу мастерства": "Рейтинг мастерства",
    "к рейтингу пробивания брони": "Рейтинг пробивания брони",
    "к рейтингу защиты": "Рейтинг защиты", "к рейтингу уклонения": "Рейтинг уклонения",
    "к рейтингу парирования": "Рейтинг парирования", "к рейтингу блока": "Рейтинг блока",
    "к показателю блокирования": "Показатель блокирования", "к рейтингу устойчивости": "Рейтинг устойчивости",
    "к восполнению здоровья": "Восполнение здоровья", "к восполнению маны": "Восполнение маны за 5 с",
}
STAT_ORDER = {v: n for n, v in enumerate(STAT_LABEL.values())}


def stat_label(k):
    k = str(k)
    if k in STAT_LABEL:
        return STAT_LABEL[k]
    if k.startswith("к рейтингу "):
        return "Рейтинг " + k[len("к рейтингу "):]
    if k.startswith("к "):
        k = k[2:]
    return k[:1].upper() + k[1:]


def item_table(title, i):
    out = ["", f"### {title}: {i['name']}", "", "| Характеристика | Значение |", "|---|---|"]
    if i.get("itemLevel"):
        out.append(f"| Уровень предмета | {i['itemLevel']} |")
    kind = ", ".join(x for x in (i.get("equipSlot"), i.get("type")) if x)
    if kind:
        out.append(f"| Тип | {cell(kind)} |")
    stats = {stat_label(k): v for k, v in (i.get("stats") or {}).items()}
    for k in sorted(stats, key=lambda k: (STAT_ORDER.get(k, len(STAT_ORDER)), k)):
        out.append(f"| {cell(k)} | {num(stats[k])} |")
    if i.get("enchant"):
        out.append(f"| Чары | {cell(i['enchant'])} |")
    for gem in i.get("gems") or []:
        out.append(f"| Камень | {cell(gem)} |")
    for e in i.get("effects") or []:
        out.append(f"| Эффект | {cell(e)} |")
    if len(out) == 5:
        out.append("| — | нет данных |")
    return out


def to_md(g):
    when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    out = []
    if "sets" in g:
        out += [f"# Экипировка: {g['char']}", "",
                f"Сохранено аддоном GearPlan: {g['time']}. Выгружено {when}.", ""]
        if g.get("stats"):
            out += ["## Характеристики персонажа", "", "С баффами на момент сохранения.", "",
                    "| Характеристика | Значение |", "|---|---|"]
            out += [f"| {cell(k)} | {cell(v)} |" for k, v in stats_rows(g["stats"])]
            out.append("")
        out += ["## Надето", "",
                "| Слот | Предмет |", "|---|---|"]
        for i in g["items"]:
            out.append(f"| {i['slotName']} | {line(i) if i['name'] else '—'} |")
        for st in g["sets"]:
            out += ["", f"## Набор: {st['name']}", "", "| Слот | Предмет | Где |", "|---|---|---|"]
            for i in st["items"]:
                out.append(f"| {i['slotName']} | {line(i)} | {i['where']} |")
        if not g["sets"]:
            out += ["", "Наборов экипировки нет."]
        out += ["", "## Характеристики предметов"]
        seen = set()
        for i in g["items"]:
            if i["name"]:
                seen.add(i.get("id"))
                out += item_table(i["slotName"], i)
        for st in g["sets"]:
            for i in st["items"]:
                if i.get("id") not in seen:
                    seen.add(i.get("id"))
                    out += item_table(f"{i['slotName']} ({st['name']}, {i['where']})", i)
    else:
        out += [f"# Экипировка: {g['char']}", "",
                f"{g['race']} {g['class']}, {g['level']} ур., средний уровень предметов {g['ilvl']}. "
                f"Арморка Sirus, мир {g['realm']} (на последний выход, без чар и наборов). Выгружено {when}.",
                "", "| Слот | Предмет |", "|---|---|"]
        for i in g["items"]:
            if not i["name"]:
                out.append(f"| {i['slotName']} | — |")
                continue
            s = f"{i['name']} [{i['itemLevel']}, {i['quality']}]"
            if i["gems"]:
                s += "; камни: " + ", ".join(i["gems"])
            out.append(f"| {i['slotName']} | {s} |")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Выгрузка экипировки персонажа (аддон GearPlan / арморка Sirus)")
    ap.add_argument("--char", default=CHAR, help=f"персонаж (по умолчанию {CHAR})")
    ap.add_argument("--realm", type=int, default=REALM, help=f"id мира (по умолчанию {REALM})")
    ap.add_argument("--json", action="store_true", help="JSON вместо Markdown")
    ap.add_argument("--stdout", action="store_true", help="вывести в терминал, не писать файл")
    ap.add_argument("--armory", action="store_true", help="только арморка Sirus")
    ap.add_argument("-o", "--out", type=Path, help="файл выгрузки")
    a = ap.parse_args()

    sys.path.insert(0, str(HERE))
    g = None if a.armory else collect_sv(a.char, a.realm)
    if g is None:
        if not a.armory:
            print("нет данных аддона GearPlan (зайдите в игру с ним и /reload) - арморка", file=sys.stderr)
        g = collect(a.char, a.realm, enchant_names(), item_cache())
    text = json.dumps(g, ensure_ascii=False, indent=2) + "\n" if a.json else to_md(g)
    if a.stdout:
        print(text, end="")
        return
    out = a.out or OUT / ("gear.json" if a.json else "gear.md")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(f"{g['char']} -> {out}")


if __name__ == "__main__":
    main()
