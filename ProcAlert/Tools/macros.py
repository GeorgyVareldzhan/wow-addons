#!/usr/bin/env python3
"""Выгрузка макросов WoW из WTF/Account/*/macros-cache.txt.

Общие макросы аккаунта: WTF/Account/<аккаунт>/macros-cache.txt
Макросы персонажа:      WTF/Account/<аккаунт>/<мир>/<персонаж>/macros-cache.txt

Примеры:
  python3 Tools/macros.py                 # Markdown в Tools/Macros/macros.md
  python3 Tools/macros.py --json          # JSON в Tools/Macros/macros.json
  python3 Tools/macros.py --char Чигурх   # только этот персонаж (и общие его аккаунта)
  python3 Tools/macros.py --stdout        # в терминал, без файла
  python3 Tools/macros.py --txt           # Tools/Macros/macros.txt, персонаж Чигурх
  python3 Tools/macros.py --txt --char Раба
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ADDONS = HERE.parent.parent  # ProcAlert/Tools -> AddOns
GAME = ADDONS.parent.parent
WTF = GAME / "WTF" / "Account"
OUT = HERE / "Macros"
TXT_CHAR = "Чигурх"  # персонаж по умолчанию для --txt

HEADER = re.compile(r'^MACRO (\d+) "(.*)" (\S+)\s*$')


def parse(path):
    macros, cur = [], None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.rstrip("\r")
        if cur is None:
            m = HEADER.match(line)
            if m:
                cur = {"id": int(m.group(1)), "name": m.group(2), "icon": m.group(3), "body": []}
        elif line == "END":
            cur["body"] = "\n".join(cur["body"])
            macros.append(cur)
            cur = None
        else:
            cur["body"].append(line)
    return macros


def collect(char=None):
    groups = []
    if not WTF.is_dir():
        sys.exit(f"нет папки {WTF}")
    for f in sorted(WTF.rglob("macros-cache.txt")):
        rel = f.relative_to(WTF).parts[:-1]
        if len(rel) == 1:
            scope = {"kind": "account", "account": rel[0], "realm": None, "char": None}
        elif len(rel) == 3:
            scope = {"kind": "char", "account": rel[0], "realm": rel[1], "char": rel[2]}
        else:
            continue
        macros = parse(f)
        if macros:
            groups.append({**scope, "macros": macros, "mtime": f.stat().st_mtime})
    groups.sort(key=lambda g: (g["account"], g["kind"] != "account", g["realm"] or "", g["char"] or ""))
    if char:
        accounts = {g["account"] for g in groups if g["char"] == char}
        if not accounts:
            sys.exit(f"персонаж «{char}» не найден")
        groups = [g for g in groups if g["char"] == char or (g["kind"] == "account" and g["account"] in accounts)]
    return groups


def title(g):
    if g["kind"] == "account":
        return f"Общие — {g['account']}"
    return f"{g['char']} — {g['realm']} ({g['account']})"


def to_markdown(groups):
    out = ["# Макросы", ""]
    for g in groups:
        out += [f"## {title(g)}", ""]
        for m in g["macros"]:
            out += [f"### {m['name']}", "", f"Иконка: `{m['icon']}`", "", "```", m["body"], "```", ""]
    return "\n".join(out)


def to_txt(groups, char):
    # один персонаж; если он есть на нескольких мирах — самый свежий файл
    chars = [g for g in groups if g["char"] == char]
    if not chars:
        sys.exit(f"у персонажа «{char}» нет макросов")
    g = max(chars, key=lambda g: g["mtime"])
    when = datetime.datetime.fromtimestamp(g["mtime"]).strftime("%Y-%m-%d %H:%M")
    out = [f"Макросы {char} ({g['realm']}), из macros-cache.txt от {when}, макросов: {len(g['macros'])}", ""]
    for m in sorted(g["macros"], key=lambda m: m["name"].lower()):
        icon = "" if m["icon"] == "INV_Misc_QuestionMark" else f"  (иконка {m['icon']})"
        out += [f"=== {m['name']} ==={icon}", m["body"].rstrip(), ""]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="Выгрузка макросов WoW")
    ap.add_argument("--json", action="store_true", help="JSON вместо Markdown")
    ap.add_argument("--txt", action="store_true", help="текст: один персонаж (по умолчанию Чигурх) в Macros/macros.txt")
    ap.add_argument("--char", help="только этот персонаж и общие макросы его аккаунта")
    ap.add_argument("--stdout", action="store_true", help="вывести в терминал, не писать файл")
    ap.add_argument("-o", "--out", type=Path, help="файл выгрузки")
    a = ap.parse_args()

    if a.txt:
        char = a.char or TXT_CHAR
        text = to_txt(collect(char), char)
        if a.stdout:
            print(text)
            return
        out = a.out or OUT / "macros.txt"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8")
        print(f"{char} -> {out}")
        return

    groups = collect(a.char)
    for g in groups:
        g.pop("mtime", None)
    text = json.dumps(groups, ensure_ascii=False, indent=2) if a.json else to_markdown(groups)
    if a.stdout:
        print(text)
        return
    out = a.out or OUT / ("macros.json" if a.json else "macros.md")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text + "\n", encoding="utf-8")
    total = sum(len(g["macros"]) for g in groups)
    print(f"{total} макросов в {len(groups)} наборах -> {out}")


if __name__ == "__main__":
    main()
