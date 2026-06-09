APP_NAME := claude-code-sentinel
SRC := Sources/ClaudeCodeSentinel/main.swift
OUT := release/$(APP_NAME)
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: build test clean settings install install-managed install-opencode uninstall-managed uninstall-opencode doctor doctor-opencode sample-permission sample-exit-plan sample-question sample-question-supplement sample-stop

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

install-opencode: $(OUT)
	$(OUT) install-opencode

uninstall-managed: $(OUT)
	$(OUT) uninstall-managed

uninstall-opencode: $(OUT)
	$(OUT) uninstall-opencode

doctor: $(OUT)
	$(OUT) doctor

doctor-opencode: $(OUT)
	$(OUT) doctor-opencode

sample-permission: $(OUT)
	$(OUT) sample-permission

sample-exit-plan: $(OUT)
	$(OUT) sample-exit-plan

sample-question: $(OUT)
	$(OUT) sample-question

sample-question-supplement: $(OUT)
	$(OUT) sample-question-supplement

sample-stop: $(OUT)
	$(OUT) sample-stop

clean:
	rm -rf release
