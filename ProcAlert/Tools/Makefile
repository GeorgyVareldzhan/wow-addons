PY ?= python3
CHAR ?=
CHAR_ARG = $(if $(CHAR),--char "$(CHAR)")

.PHONY: help macros macros-json macros-print txt

help:
	@echo "запуск из этой папки (make macros) или из AddOns: make -C ProcAlert/Tools macros"
	@echo "make macros               — Markdown в Macros/macros.md"
	@echo "make macros-json          — JSON в Macros/macros.json"
	@echo "make macros-print         — вывести в терминал"
	@echo "make txt                  — Macros/macros.txt, один персонаж (по умолчанию Чигурх)"
	@echo "CHAR=Имя — только этот персонаж (и общие макросы его аккаунта)"

macros:
	$(PY) macros.py $(CHAR_ARG)

macros-json:
	$(PY) macros.py --json $(CHAR_ARG)

txt:
	$(PY) macros.py --txt $(CHAR_ARG)

macros-print:
	$(PY) macros.py --stdout $(CHAR_ARG)