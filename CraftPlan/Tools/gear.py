#!/usr/bin/env python3
"""Выгрузка экипировки персонажа: надетое (с чарами и камнями) и наборы экипировки.

Источник — сохранения CraftPlan (WTF/.../<персонаж>/SavedVariables/CraftPlan.lua: gear, equipSets, bagGear),
пишутся во время игры и при /reload. Названия чар — из таблиц клиента
(SpellItemEnchantment.dbc через mpq.py/dbc.py), названия и уровни предметов — из кеша клиента (itemcache.wdb),
чего там нет — из базы Sirus (кеш Tools/.cache). Нет данных CraftPlan или --armory — арморка Sirus
(на последний выход, без наборов и чар).

Примеры:
  python3 Tools/gear.py                  # Tools/Gear/gear.md, персонаж Чигурх
  python3 Tools/gear.py --char Раба
  python3 Tools/gear.py --stdout         # в терминал, без файла
  python3 Tools/gear.py --json           # Tools/Gear/gear.json
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
OUT = HERE / "Gear"
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
                t[n] = self.value()
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
    hits = glob.glob(str(WTF / "*" / "*" / char / "SavedVariables" / "CraftPlan.lua"))
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


def describe(link, ench, cache, realm):
    p = parse_link(link)
    if not p:
        return None
    name, ilvl = cache.get(p["id"], (p["name"], None))
    return {"id": p["id"], "name": p["name"] or name, "itemLevel": ilvl,
            "enchant": ench.get(p["enchant"], (f"чары {p['enchant']}",))[0] if p["enchant"] else None,
            "gems": [gem_text(g, ench, cache, realm) for g in p["gems"]]}


def collect_sv(char, realm):
    path = sv_path(char)
    if not path:
        return None
    db = LuaReader(path.read_text(encoding="utf-8", errors="replace")).globals().get("CraftPlanDB") or {}
    if not db.get("gear") and not db.get("equipSets"):
        return None
    ench, cache = enchant_names(), item_cache()
    items = []
    for slot in range(1, 20):
        d = describe((db.get("gear") or {}).get(slot), ench, cache, realm)
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
            d = describe(link, ench, cache, realm) if link else {
                "id": iid, "name": cache.get(iid, (f"предмет {iid}", None))[0],
                "itemLevel": cache.get(iid, (None, None))[1], "enchant": None, "gems": []}
            rows.append({"slot": slot, "slotName": INV[slot], "where": place, **d})
        sets.append({"name": st.get("name"), "items": rows})
    stamp = db.get("gearTime")
    return {"char": char, "source": f"CraftPlan ({path.parent.parent.parent.name})",
            "time": datetime.datetime.fromtimestamp(stamp).strftime("%Y-%m-%d %H:%M") if stamp else "?",
            "items": items, "sets": sets}


# --------------------------------------------------------------------------------------------
def line(i):
    s = f"{i['name']}" + (f" [{i['itemLevel']}]" if i.get("itemLevel") else "")
    if i.get("enchant"):
        s += f"; чары: {i['enchant']}"
    if i.get("gems"):
        s += "; камни: " + ", ".join(i["gems"])
    return s


def to_md(g):
    when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    out = []
    if "sets" in g:
        out += [f"# Экипировка: {g['char']}", "",
                f"Сохранено CraftPlan: {g['time']}. Выгружено {when}.", "", "## Надето", "",
                "| Слот | Предмет |", "|---|---|"]
        for i in g["items"]:
            out.append(f"| {i['slotName']} | {line(i) if i['name'] else '—'} |")
        for st in g["sets"]:
            out += ["", f"## Набор: {st['name']}", "", "| Слот | Предмет | Где |", "|---|---|---|"]
            for i in st["items"]:
                out.append(f"| {i['slotName']} | {line(i)} | {i['where']} |")
        if not g["sets"]:
            out += ["", "Наборов экипировки нет."]
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
    ap = argparse.ArgumentParser(description="Выгрузка экипировки персонажа (CraftPlan / арморка Sirus)")
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
            print("нет данных CraftPlan (выйдите из игры или /reload с CraftPlan 2.1.28+) - арморка", file=sys.stderr)
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
