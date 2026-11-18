# Проверка Lua в одноразовом контейнере: Lua 5.1 (как в WoW 3.3.5) и luacheck ставятся
# только внутри контейнера, папка аддона подключена только для чтения.
# Сначала синтаксис (luac -p), затем luacheck с настройками из .luacheckrc
IMAGE ?= nginx:alpine

.PHONY: help lint

help:
	@echo "make lint — синтаксис и luacheck всех .lua аддона (из AddOns: make -C $(lastword $(subst /, ,$(CURDIR))) lint)"

lint:
	@docker run --rm -v "$(CURDIR):/src:ro" -w /src $(IMAGE) sh -c '\
		apk add -q lua5.1 luacheck >/dev/null || exit 2; \
		rc=0; for f in $$(find . -name "*.lua" | sort); do \
			luac5.1 -p "$$f" || rc=1; \
		done; [ $$rc = 0 ] || exit 1; \
		luacheck --codes --no-color -q --no-cache .'
