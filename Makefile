APP_NAME := claude-code-sentinel
SRC := Sources/ClaudeCodeSentinel/main.swift
OUT := release/$(APP_NAME)

.PHONY: build test clean settings install-managed uninstall-managed sample-permission sample-stop

build: $(OUT)

$(OUT): $(SRC)
	mkdir -p release
	swiftc -O -o $(OUT) $(SRC)

test: $(OUT)
	$(OUT) test

settings: $(OUT)
	$(OUT) print-settings

install-managed: $(OUT)
	node scripts/install-managed-settings.js $(OUT)

uninstall-managed:
	node scripts/install-managed-settings.js --uninstall

sample-permission: $(OUT)
	$(OUT) sample-permission

sample-stop: $(OUT)
	$(OUT) sample-stop

clean:
	rm -rf release
