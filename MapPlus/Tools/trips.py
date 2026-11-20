#!/usr/bin/env python3
"""MapPlus trips log (MapPlusDB.trips in SavedVariables) -> Tools/trips.md. Usage: python3 Tools/trips.py"""
import datetime
import glob
import os
import re


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


HERE = os.path.dirname(os.path.abspath(__file__))
WTF = os.path.join(HERE, "..", "..", "..", "..", "WTF", "Account")
OUT = os.path.join(HERE, "trips.md")


def hms(sec):
    sec = int(sec)
    return "%d:%02d:%02d" % (sec // 3600, sec // 60 % 60, sec % 60)


def when(t):
    return datetime.datetime.fromtimestamp(int(t)).strftime("%Y-%m-%d %H:%M")


def main():
    files = glob.glob(os.path.join(WTF, "*", "SavedVariables", "MapPlus.lua"))
    trips = []
    for f in files:
        db = LuaReader(open(f, encoding="utf-8", errors="replace").read()).globals().get("MapPlusDB") or {}
        t = db.get("trips") or {}
        trips += [t[k] for k in sorted(t)]
    def vph(t):  # жил в час по времени в движении; меньше минуты - нет
        mv = t.get("moving", 0)
        return t.get("veins", 0) * 3600 / mv if mv >= 60 else None
    trips.sort(key=lambda t: (vph(t) is not None, vph(t) or 0, t.get("start", 0)), reverse=True)
    out = ["# Поездки за рудой (MapPlus)", "",
           "По жилам в час, лучшие сверху (меньше минуты в движении - в конце). Время в движении - только в полёте (пешком и стоя не считается); в час - по нему.", ""]
    for t in trips:
        mv = t.get("moving", 0)
        ore = t.get("ore", 0)
        rate = ore * 3600 / mv if mv >= 60 else 0
        out.append("## %s - %s, %s%s" % (when(t["start"]), datetime.datetime.fromtimestamp(int(t["finish"])).strftime("%H:%M"),
                                         t.get("zone", "?"), (": " + t["route"]) if t.get("route") else ""))
        out.append("")
        v = vph(t)
        out.append("Всего %s, в движении %s. Жил %d, руды %d%s." % (
            hms(t["finish"] - t["start"]), hms(mv), t.get("veins", 0), ore,
            (", в час: жил %d, руды %d" % (v, rate)) if v is not None else ""))
        if t.get("pts"):
            ps = t.get("passed", 0)
            pr = t.get("prog", ps)
            out.append("")
            out.append("Точек пройдено %d из %d (%d%%), жила на месте %d из %d долетевших (%d%%)." % (
                pr, t["pts"], pr * 100 // t["pts"], t.get("found", 0), ps, t.get("found", 0) * 100 // ps if ps else 0))
        out.append("")
        items = t.get("items") or {}
        if items:
            out += ["| Предмет | Сколько |", "|---|---|"]
            for name, n in sorted(items.items(), key=lambda kv: -kv[1]):
                out.append("| %s | %d |" % (name, n))
            out.append("")
    open(OUT, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print("%s: поездок %d" % (OUT, len(trips)))


if __name__ == "__main__":
    main()
