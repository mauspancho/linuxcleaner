SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT := $(CURDIR)
TOOLS_BIN := $(ROOT)/.tools/bin
NODE_BIN := $(ROOT)/node_modules/.bin

export PATH := $(TOOLS_BIN):$(NODE_BIN):$(PATH)

.PHONY: help setup tools node-deps check format test scan install uninstall clean

help:
	@printf '%s\n' \
		'LinuxCleaner' \
		'' \
		'Uso:' \
		'  make setup      Descarga ShellCheck/shfmt e instala dependencias Node' \
		'  make check      Valida sintaxis, formato, regla de PolicyKit y ESLint' \
		'  make format     Aplica shfmt, Prettier y ESLint --fix' \
		'  make test       Ejecuta las pruebas de humo' \
		'  make scan       Analiza el sistema sin abrir la interfaz gráfica' \
		'  make install    Instala LinuxCleaner (requiere sudo)' \
		'  make uninstall  Desinstala LinuxCleaner (requiere sudo)' \
		'  make clean      Elimina node_modules, .tools y dist'

setup: tools node-deps

tools:
	@./scripts/bootstrap-tools.sh

node-deps: package.json package-lock.json
	@npm ci --no-audit --no-fund

check:
	@./scripts/check.sh --strict

format:
	@./scripts/format.sh

test:
	@./tests/smoke.sh

scan:
	@./cleaner.sh --scan

install: check
	@sudo ./install.sh

uninstall:
	@sudo ./install.sh --uninstall

clean:
	@rm -rf node_modules .tools dist
