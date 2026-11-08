#!/usr/bin/env python3
"""Sync profession data from the Sirus knowledge base (api.sirus.su) into CraftPlan data files.

What can be synced:
  prospect  - prospecting: ore -> gems (fixed list of 10 ores)      -> Data/ProspectData.lua
  mill      - milling: herb -> pigments (found by walking           -> Data/MillData.lua
              herb -> pigment -> herb links from a few seed herbs)
  veins     - mining nodes of the 10 ores: what a vein drops        -> Data/VeinData.lua
              (ore, stone, gems) with chances
  all       - everything above (default)

Disenchanting is not supported: the base lists "disenchanted from" capped at 300 items,
and per-item data would need thousands of requests.

Examples:
  python3 sirusdb.py                  # all, from cache where possible
  python3 sirusdb.py prospect         # prospecting only
  python3 sirusdb.py mill --json      # milling, write Tools/mill.json instead of Lua
  python3 sirusdb.py all --refresh    # download everything again
  python3 sirusdb.py 1                # old form: all, JSON

Polite by design: one request at a time, a delay with jitter between requests, responses cached
in Tools/.cache (re-runs do not hit the site), stops on the first HTTP error.
"""
import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
DATA_DIR = os.path.normpath(os.path.join(HERE, "..", "Data"))

REALM = 22  # Neverest x3 - 3.3.5a+ (from https://sirus.su/api/v2/data)
API = "https://api.sirus.su/api/base/{realm}/details/{kind}/{item}?lang=ru"
UA = "Mozilla/5.0 (X11; Linux x86_64) CraftPlan-datafetch (low rate)"

ORES = [  # itemID, comment
    (2770, "copper"), (2771, "tin"), (2772, "iron"), (3858, "mithril"), (10620, "thorium"),
    (23424, "fel iron"), (23425, "adamantite"),
    (36909, "cobalt"), (36912, "saronite"), (36910, "titanium"),
]
# one herb per milling tier; the rest is found through the base (IDs checked against the Questie DB)
MILL_SEEDS = [2447, 2450, 3356, 8838, 13463, 22785, 36901]  # Peacebloom .. Goldclover

TTY = sys.stderr.isatty()


# ---------------------------------------------------------------------------------------------
# Terminal output: a progress line that redraws itself on a terminal, plain lines otherwise
class Progress:
    SPIN = "|/-\\"

    def __init__(self, title):
        self.title = title
        self.done = 0
        self.total = 0
        self.spin = 0
        self.last = ""

    def bar(self, width=24):
        if self.total <= 0:
            return "[" + " " * width + "]"
        fill = int(width * self.done / self.total)
        return "[" + "#" * fill + "." * (width - fill) + "]"

    def show(self, msg):
        line = f"{self.title:9} {self.bar()} {self.done}/{self.total}  {msg}"
        if TTY:
            sys.stderr.write("\r\033[K" + line)
            sys.stderr.flush()
        elif msg != self.last:
            print(line, file=sys.stderr, flush=True)
        self.last = msg

    def wait(self, seconds, msg):
        end = time.monotonic() + seconds
        while True:
            left = end - time.monotonic()
            if left <= 0:
                break
            if TTY:
                self.spin = (self.spin + 1) % 4
                self.show(f"{self.SPIN[self.spin]} {msg}, пауза {left:4.1f} с")
            time.sleep(min(0.2, left))

    def finish(self, msg):
        if TTY:
            sys.stderr.write("\r\033[K")
        print(f"{self.title:9} {self.bar()} {self.done}/{self.total}  {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------------------------
# Fetch with cache and polite delay
class Fetcher:
    def __init__(self, delay, refresh):
        self.delay = delay
        self.refresh = refresh
        self.last = None
        self.requests = 0
        self.cached = 0
        os.makedirs(CACHE, exist_ok=True)

    def path(self, item, kind="item"):
        return os.path.join(CACHE, f"{item}.json" if kind == "item" else f"{kind}_{item}.json")

    def is_cached(self, item, kind="item"):
        return not self.refresh and os.path.exists(self.path(item, kind))

    def get(self, item, prog, kind="item"):
        path = self.path(item, kind)
        if self.is_cached(item, kind):
            self.cached += 1
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        if self.last is not None:
            wait = self.delay + random.uniform(0, self.delay / 2) - (time.monotonic() - self.last)
            if wait > 0:
                prog.wait(wait, f"следующий {item}")
        prog.show(f"запрос {item} ...")
        req = urllib.request.Request(API.format(realm=REALM, kind=kind, item=item),
                                     headers={"User-Agent": UA, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            prog.finish(f"ошибка HTTP {e.code} на {item}")
            sys.exit(f"Остановлено: HTTP {e.code} на предмете {item}. Скачанное лежит в кеше.")
        except urllib.error.URLError as e:
            prog.finish(f"нет связи на {item}")
            sys.exit(f"Остановлено: {e.reason}. Скачанное лежит в кеше.")
        finally:
            self.last = time.monotonic()
        self.requests += 1
        data = json.loads(body)
        with open(path, "w", encoding="utf-8") as f:
            f.write(body)
        return data


def tab(d, name):
    return next((t for t in d.get("tabs", []) if t.get("id") == name), None)


def drops(t):
    """Rows of a prospecting/milling tab -> [{id, name, pct, min, max, avg}] by chance."""
    out = []
    for r in t["items"]:
        lo, hi = (r.get("stack") or [1, 1])[:2]
        avg = (lo + hi) / 2
        if r.get("pctstack"):
            ps = json.loads(r["pctstack"])
            tot = sum(ps.values())
            if tot > 0:
                avg = sum(int(k) * v for k, v in ps.items()) / tot
        out.append({"id": r["entry"], "name": r["name"], "pct": round(float(r["percent"]), 3),
                    "min": lo, "max": hi, "avg": round(avg, 3)})
    out.sort(key=lambda g: (-g["pct"], g["id"]))
    return out


# ---------------------------------------------------------------------------------------------
# Sources
def sync_prospect(fx):
    prog = Progress("prospect")
    prog.total = len(ORES)
    out = []
    for item, note in ORES:
        prog.show(f"{item} {note}")
        d = fx.get(item, prog)
        t = tab(d, "prospecting")
        prog.done += 1
        if not t:
            prog.show(f"{item}: нет вкладки просеивания")
            continue
        out.append({"src": item, "name": d["item"]["name"], "note": note, "drops": drops(t)})
    prog.finish(f"руды: {len(out)}")
    return out


def sync_mill(fx):
    prog = Progress("mill")
    herbs, pigments = list(MILL_SEEDS), []
    seen_h, seen_p = set(herbs), set()
    out = []
    i = 0
    while i < len(herbs) or pigments:
        prog.total = len(herbs) + len(seen_p)
        if pigments:  # pigment page: which herbs it is milled from
            pg = pigments.pop(0)
            prog.show(f"краситель {pg}")
            d = fx.get(pg, prog)
            prog.done += 1
            t = tab(d, "milled_from")
            for r in (t or {}).get("items", []):
                if r["entry"] not in seen_h:
                    seen_h.add(r["entry"])
                    herbs.append(r["entry"])
            continue
        herb = herbs[i]
        i += 1
        prog.show(f"трава {herb}")
        d = fx.get(herb, prog)
        prog.done += 1
        t = tab(d, "milling")
        if not t:
            continue
        ds = drops(t)
        out.append({"src": herb, "name": d["item"]["name"], "note": "", "drops": ds})
        for g in ds:
            if g["id"] not in seen_p:
                seen_p.add(g["id"])
                pigments.append(g["id"])
    prog.total = prog.done
    out.sort(key=lambda o: o["src"])
    prog.finish(f"травы: {len(out)}, красители: {len(seen_p)}")
    return out


def sync_veins(fx):
    """Mining nodes of the ores: vein -> what it drops (ore, stone, gems), from the ore's "mined from" tab."""
    prog = Progress("veins")
    veins, seen = [], set()
    for item, note in ORES:  # ore pages: which veins drop them
        d = fx.get(item, prog)
        for r in (tab(d, "mined_from_object") or {}).get("items", []):
            if r["entry"] not in seen:
                seen.add(r["entry"])
                veins.append((r["entry"], item))
    prog.total = len(veins)
    out = []
    for obj, ore in veins:
        prog.show(f"жила {obj}")
        d = fx.get(obj, prog, kind="object")
        prog.done += 1
        t = tab(d, "contains")
        if not t:
            continue
        name = (d.get("object") or {}).get("name", str(obj))
        out.append({"src": obj, "name": name, "note": f"ore {ore}", "ore": ore, "drops": drops(t)})
    out.sort(key=lambda o: (o["note"], o["src"]))
    prog.finish(f"жилы: {len(out)}")
    return out


SOURCES = {
    "prospect": (sync_prospect, "ProspectData", "CraftPlan_ProspectData", "prospect.json",
                 "[ore] = { { gem, pct, min, max, avg }, ... }; pct = chance per prospect (5 ore)"),
    "mill": (sync_mill, "MillData", "CraftPlan_MillData", "mill.json",
             "[herb] = { { pigment, pct, min, max, avg }, ... }; pct = chance per milling (5 herbs)"),
    "veins": (sync_veins, "VeinData", "CraftPlan_VeinData", "veins.json",
              "[vein object] = { { item, pct, min, max, avg }, ... }; pct = chance per node (ore, stone, gems)"),
}


def write_lua(rows, name, var, doc):
    path = os.path.join(DATA_DIR, name + ".lua")
    if var == "CraftPlan_VeinData":  # veins also carry their ore and name
        lines = [f"-- Generated by Tools/sirusdb.py from the Sirus knowledge base (realm {REALM}), do not edit.",
                 f"-- {doc};", "-- [vein] = { ore = ore item, name = vein name, { item, pct, min, max, avg }, ... }", f"{var} = {{"]
        for o in rows:
            lines.append(f"\t[{o['src']}] = {{ ore = {o['ore']}, name = \"{o['name']}\",")
            for g in o["drops"]:
                lines.append(f"\t\t{{ {g['id']}, {g['pct']}, {g['min']}, {g['max']}, {g['avg']} }}, -- {g['name']}")
            lines.append("\t},")
        lines.append("}")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        return path
    lines = [
        f"-- Generated by Tools/sirusdb.py from the Sirus knowledge base (realm {REALM}), do not edit.",
        f"-- {doc},",
        "-- avg = average pieces when it drops.",
        f"{var} = {{",
    ]
    for o in rows:
        note = f" ({o['note']})" if o["note"] else ""
        lines.append(f"\t[{o['src']}] = {{ -- {o['name']}{note}")
        for g in o["drops"]:
            lines.append(f"\t\t{{ {g['id']}, {g['pct']}, {g['min']}, {g['max']}, {g['avg']} }}, -- {g['name']}")
        lines.append("\t},")
    lines.append("}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return path


def main():
    argv = sys.argv[1:]
    legacy_json = bool(argv) and argv[0] == "1"  # old form: "sirusdb.py 1" = all, JSON
    if legacy_json:
        argv = argv[1:]
    ap = argparse.ArgumentParser(description="Синхронизация данных профессий с базой знаний Sirus.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("what", nargs="*", default=["all"], choices=["all"] + list(SOURCES),
                    help="что синхронизировать (по умолчанию all)")
    ap.add_argument("-j", "--json", action="store_true", help="писать Tools/<что>.json вместо Data/*.lua")
    ap.add_argument("-r", "--refresh", action="store_true", help="не брать кеш, скачать заново")
    ap.add_argument("-d", "--delay", type=float, default=4.0, help="пауза между запросами, с (по умолчанию 4)")
    a = ap.parse_args(argv)
    as_json = a.json or legacy_json
    what = list(SOURCES) if "all" in a.what else list(dict.fromkeys(a.what))
    if a.delay < 1:
        sys.exit("Пауза меньше 1 с — слишком часто для чужого сайта.")

    print(f"База знаний Sirus, мир {REALM}. Синхронизация: {', '.join(what)}.", file=sys.stderr)
    print(f"Кеш: {CACHE}{' (не используется, --refresh)' if a.refresh else ''}", file=sys.stderr)
    print(f"Пауза между запросами: {a.delay:g}-{a.delay * 1.5:g} с. Вывод: {'JSON в Tools/' if as_json else 'Lua в Data/'}",
          file=sys.stderr)
    if "prospect" in what:
        miss = sum(1 for o, _ in ORES if a.refresh or not os.path.exists(os.path.join(CACHE, f"{o}.json")))
        print(f"  prospect: {len(ORES)} руд, скачать {miss} (~{int(miss * a.delay * 1.25)} с)", file=sys.stderr)
    if "veins" in what:
        print("  veins: жилы берутся со страниц руды (~40 предметов)", file=sys.stderr)
    if "mill" in what:
        print(f"  mill: {len(MILL_SEEDS)} стартовых трав, остальное найдётся по ссылкам (~50 предметов)", file=sys.stderr)

    fx = Fetcher(a.delay, a.refresh)
    t0 = time.monotonic()
    written = []
    for key in what:
        fn, name, var, jname, doc = SOURCES[key]
        rows = fn(fx)
        if as_json:
            path = os.path.join(HERE, jname)
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"realm": REALM, "kind": key, "rows": rows}, f, ensure_ascii=False, indent=1)
        else:
            path = write_lua(rows, name, var, doc)
        written.append(path)
    secs = int(time.monotonic() - t0)
    print(f"Готово за {secs} с: запросов к сайту {fx.requests}, из кеша {fx.cached}.", file=sys.stderr)
    for p in written:
        print(f"  записано: {p}", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit("\nПрервано. Скачанное лежит в кеше, повторный запуск продолжит с него.")
