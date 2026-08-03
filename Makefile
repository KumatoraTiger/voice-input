# VoiceInput — thin wrapper around Scripts/*.sh.
#
# Xcode is NOT required and must not be used: everything goes through
# `swift build` / `swift test` plus a hand-assembled .app bundle.
#
#   make build     compile every target (debug)
#   make app       assemble build/VoiceInput.app (release)
#   make run       build the bundle and launch it, tailing its logs
#   make test      build all targets + run the unit tests
#   make lint      swift-format lint (skipped when the tool is unavailable)
#   make format    swift-format --in-place
#   make check     check-secrets + lint + test   <- run this before committing
#   make install   assemble and copy to /Applications
#   make clean     remove .build/ and build/

SHELL := /bin/bash
SCRIPTS := Scripts

.DEFAULT_GOAL := build
.PHONY: build app run test lint format check check-secrets install clean release help

# Prints the header block above (everything up to the first blank line after it).
help:
	@sed -n '1,20{/^#/{s/^# \{0,2\}//;p;};}' $(MAKEFILE_LIST)

build:
	swift build

release:
	swift build -c release

app:
	$(SCRIPTS)/build_app.sh

run:
	$(SCRIPTS)/run.sh

test:
	$(SCRIPTS)/test.sh

lint:
	$(SCRIPTS)/lint.sh

format:
	$(SCRIPTS)/lint.sh --fix

check-secrets:
	$(SCRIPTS)/check_secrets.sh

# The pre-commit gate. Secrets first — it is the cheapest and the most important.
check: check-secrets lint test

install:
	$(SCRIPTS)/build_app.sh --install

clean:
	rm -rf .build build
	@echo "removed .build/ and build/"
