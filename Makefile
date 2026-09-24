SHELL := /bin/sh

CONFIGURATION ?= debug
APP_BUNDLE := .build/app/Winnow.app

.PHONY: help build test run format app app-adhoc verify verify-signing clean

help:
	@echo "Winnow development commands:"
	@echo "  make build    Compile the Swift package"
	@echo "  make test     Run the test suite"
	@echo "  make run      Build and launch the stable signed app bundle"
	@echo "  make format   Format Swift sources"
	@echo "  make app      Build Winnow.app with a stable signing identity"
	@echo "  make app-adhoc  Build a separate ad hoc package for testing only"
	@echo "  make verify   Build and verify stable signing continuity"
	@echo "  make verify-signing  Verify the existing runnable app signature"
	@echo "  make clean    Remove SwiftPM build artifacts"

build:
	swift build --configuration $(CONFIGURATION)

test:
	swift test --configuration $(CONFIGURATION)

run: app
	./Scripts/verify-signing.sh --require-stable $(APP_BUNDLE)
	open -W $(APP_BUNDLE)

format:
	swift format --in-place --recursive Sources Tests Package.swift

app:
	CONFIGURATION=$(CONFIGURATION) ./Scripts/build-app.sh

app-adhoc:
	OUTPUT_DIR=.build/app-adhoc WINNOW_CODE_SIGN_IDENTITY=- WINNOW_ALLOW_ADHOC=1 \
		CONFIGURATION=$(CONFIGURATION) ./Scripts/build-app.sh

verify: app
	plutil -lint $(APP_BUNDLE)/Contents/Info.plist
	./Scripts/verify-signing.sh --require-stable $(APP_BUNDLE)

verify-signing:
	./Scripts/verify-signing.sh --require-stable $(APP_BUNDLE)

clean:
	swift package clean
