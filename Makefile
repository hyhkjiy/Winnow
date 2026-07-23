SHELL := /bin/sh

CONFIGURATION ?= debug
APP_BUNDLE := .build/app/Winnow.app

.PHONY: help build test run format app verify clean

help:
	@echo "Winnow development commands:"
	@echo "  make build    Compile the Swift package"
	@echo "  make test     Run the test suite"
	@echo "  make run      Run Winnow from SwiftPM"
	@echo "  make format   Format Swift sources"
	@echo "  make app      Build and ad-hoc sign Winnow.app"
	@echo "  make verify   Build and verify Winnow.app"
	@echo "  make clean    Remove SwiftPM build artifacts"

build:
	swift build --configuration $(CONFIGURATION)

test:
	swift test --configuration $(CONFIGURATION)

run: app
	$(APP_BUNDLE)/Contents/MacOS/Winnow

format:
	swift format --in-place --recursive Sources Tests Package.swift

app:
	CONFIGURATION=$(CONFIGURATION) ./Scripts/build-app.sh

verify: app
	plutil -lint $(APP_BUNDLE)/Contents/Info.plist
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)

clean:
	swift package clean
