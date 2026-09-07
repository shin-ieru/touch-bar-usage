# Terminal-first workflow. No user-specific absolute paths anywhere.
.DEFAULT_GOAL := build
.PHONY: build test run app clean preview lint audit

CONFIGURATION ?= release
APP := dist/Touch Bar Usage.app

## Compile everything (debug is faster for iteration: CONFIGURATION=debug)
build:
	swift build -c $(CONFIGURATION)

## Run the unit test suite. No network, keychain, Touch Bar or Claude Code needed.
test:
	swift test

## Build the .app bundle and launch it as a background utility.
run: app
	open "$(APP)"

## Assemble the signed-for-development .app bundle.
app:
	CONFIGURATION=$(CONFIGURATION) ./Scripts/make_app.sh

## Render PNG previews of each Touch Bar state into PreviewOutput/ (gitignored).
preview:
	swift run -c debug TouchBarUsage --render-previews PreviewOutput

## Remove build products and generated bundles.
clean:
	swift package clean
	rm -rf .build dist PreviewOutput

## Scan the working tree for credential-shaped strings and machine-specific paths.
audit:
	./Scripts/audit.sh
