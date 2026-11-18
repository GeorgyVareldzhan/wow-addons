# Инструменты аддона. Запуск из этой папки (make lint) или из AddOns: make -C <Аддон>/Tools lint
PY     ?= python3
IMAGE  ?= nginx:alpine
BACKUP ?= $(HOME)/WoW-backups
LUABAL ?= $(BACKUP)/tools/luabal.py
NAME   := $(shell basename "$$(cd .. && pwd)")
# бэкапы ветки 2.x — в CraftPlan2
DEST   ?= $(BACKUP)/CraftPlan2

.PHONY: help lint bal version backup

help:
	@echo "make lint     — синтаксис (luac 5.1) и luacheck (.luacheckrc рядом) в одноразовом docker"
	@echo "make bal      — быстрая проверка баланса блоков Lua, без docker"
	@echo "make version  — версия из .toc"
	@echo "make backup   — копия аддона в ~/WoW-backups/$(NAME)/<версия>/"

# Lua 5.1 и luacheck ставятся только внутри контейнера, папка аддона — только для чтения
lint:
	@docker run --rm -v "$$(cd .. && pwd):/src:ro" -w /src $(IMAGE) sh -c '\
		apk add -q lua5.1 luacheck >/dev/null || exit 2; \
		rc=0; for f in $$(find . -name "*.lua" -not -path "./Tools/*" | sort); do \
			luac5.1 -p "$$f" || rc=1; \
		done; [ $$rc = 0 ] || exit 1; \
		[ ! -f Tools/.luacheckrc ] || luacheck --config Tools/.luacheckrc --exclude-files "Tools/*" \
			--codes --no-color -q --no-cache .'

bal:
	@find .. -name "*.lua" -not -path "../Tools/*" | sort | while read -r f; do \
		printf '%s: ' "$${f#../}"; $(PY) "$(LUABAL)" "$$f" | tail -1; \
	done

version:
	@sed -n 's/^## Version: *//p' "../$(NAME).toc" | tr -d '\r'

backup:
	@v=$$(sed -n 's/^## Version: *//p' "../$(NAME).toc" | tr -d '\r'); \
	[ -n "$$v" ] || { echo "нет версии в $(NAME).toc"; exit 1; }; \
	dst="$(DEST)/$$v"; mkdir -p "$$dst"; \
	rsync -a --exclude Tools --exclude .cache --exclude __pycache__ ../ "$$dst/"; \
	echo "$(NAME) $$v -> $$dst"
