#!/usr/bin/env python3
"""Выгрузить «Свою цель» CraftPlan из SavedVariables игры в Interface/AddOns/CraftPlan/Goal.lua.

Игра пишет SavedVariables только при выходе или /reload, поэтому запускать после выхода из игры.
Без аргументов берётся самый свежий файл WTF/Account/*/*/*/SavedVariables/CraftPlan.lua, где есть цель.
Можно указать файл явно: export-goal.py "путь/к/CraftPlan.lua".
На другом компьютере CraftPlan при входе возьмёт цель из Goal.lua, если она новее (или /cplan import).
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)                      # Interface/AddOns/CraftPlan
GAME = os.path.dirname(os.path.dirname(os.path.dirname(ADDON)))  # папка игры
OUT = os.path.join(ADDON, "Goal.lua")


def goal_block(text):
    """Текст таблицы ["goal"] = { ... } (с учётом вложенных скобок и строк)."""
    m = re.search(r'\["goal"\]\s*=\s*\{', text)
    if not m:
        return None
    i = m.end() - 1
    depth, j, in_str = 0, i, False
    while j < len(text):
        c = text[j]
        if in_str:
            if c == "\\":
                j += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
        j += 1
    return None


def main():
    if len(sys.argv) > 1:
        files = [sys.argv[1]]
    else:
        files = glob.glob(os.path.join(GAME, "WTF", "Account", "*", "*", "*", "SavedVariables", "CraftPlan.lua"))
    found = []
    for f in files:
        try:
            text = open(f, encoding="utf-8").read()
        except OSError as e:
            print("не прочитать:", f, e)
            continue
        block = goal_block(text)
        if block:
            found.append((os.path.getmtime(f), f, block))
    if not found:
        print("цели нет ни в одном CraftPlan.lua из SavedVariables (выйдите из игры или сделайте /reload после правки цели).")
        return 1
    found.sort()
    mtime, src, block = found[-1]
    m = re.search(r'\["time"\]\s*=\s*(\d+)', block)
    stamp = int(m.group(1)) if m else int(mtime)
    with open(OUT, "w", encoding="utf-8") as out:
        out.write("-- Своя цель CraftPlan, выгружена tools/export-goal.py из:\n")
        out.write("-- " + os.path.relpath(src, GAME) + "\n")
        out.write("CraftPlanGoalFileTime = %d\n" % stamp)
        out.write("CraftPlanGoalFile = " + block + "\n")
    n = len(re.findall(r'\["name"\]', block))
    print("записано:", OUT)
    print("из:", src)
    print("рецептов:", n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
