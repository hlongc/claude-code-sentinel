APP_NAME := claude-code-sentinel
SRC := Sources/ClaudeCodeSentinel/main.swift
OUT := release/$(APP_NAME)
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: build test clean settings install install-managed uninstall-managed doctor sample-permission sample-stop

build: $(OUT)

$(OUT): $(SRC)
	mkdir -p release
	swiftc -O -o $(OUT) $(SRC)

test: $(OUT)
	$(OUT) test

settings: $(OUT)
	$(OUT) print-settings

install: $(OUT)
	mkdir -p $(BINDIR)
	cp $(OUT) $(BINDIR)/$(APP_NAME)
	chmod +x $(BINDIR)/$(APP_NAME)
	$(BINDIR)/$(APP_NAME) install-managed

install-managed: $(OUT)
	$(OUT) install-managed

uninstall-managed: $(OUT)
	$(OUT) uninstall-managed

doctor: $(OUT)
	$(OUT) doctor

sample-permission: $(OUT)
	$(OUT) sample-permission

sample-stop: $(OUT)
	$(OUT) sample-stop

clean:
	rm -rf release
