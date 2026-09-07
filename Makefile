# Terminal-first workflow. No user-specific absolute paths anywhere.
.DEFAULT_GOAL := build
.PHONY: build test run app assets clean preview lint audit

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

## Fetch Clawd pose data onto this machine and generate local grids.
## Build-time only — the app never fetches at runtime. Output is gitignored;
## this repository redistributes no Anthropic artwork. See docs/branding.md.
assets:
	./Scripts/fetch-clawd-assets.sh

## Render PNG previews of each Touch Bar state into PreviewOutput/ (gitignored).
preview:
	swift run -c debug TouchBarUsage --render-previews PreviewOutput

## Remove build products and generated bundles.
## Remove build products. Generated Clawd assets are kept: re-fetching them
## needs the network, and they are not build output in the usual sense.
clean:
	swift package clean
	rm -rf .build dist PreviewOutput

## Scan the working tree for credential-shaped strings and machine-specific paths.
audit:
	./Scripts/audit.sh
