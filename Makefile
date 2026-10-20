# Toolchain settings for machines with only the Command Line Tools (no Xcode).
# Override on the command line if needed, e.g. `make test CLT=/Applications/Xcode.app/Contents/Developer`.
CLT ?= /Library/Developer/CommandLineTools
FRAMEWORKS := $(CLT)/Library/Developer/Frameworks
TEST_LIBS := $(CLT)/Library/Developer/usr/lib

export DEVELOPER_DIR := $(CLT)
export PATH := $(CLT)/usr/bin:$(PATH)
export SDKROOT := $(CLT)/SDKs/MacOSX.sdk

# Command Line Tools ship the `_Testing_Foundation` overlay without module files,
# so tests that import Foundation and Testing together need cross-import overlays off.
TEST_FLAGS := -Xswiftc -F$(FRAMEWORKS) \
	-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
	-Xlinker -rpath -Xlinker $(FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TEST_LIBS)

.PHONY: build run test clean app dmg install icon

build:
	swift build

run:
	swift run MacCleaner

test:
	swift test $(TEST_FLAGS)

clean:
	swift package clean

# Packaging. VERSION=1.2.0 and SIGN_IDENTITY="Developer ID Application: …" are passed through.
app:
	scripts/build-app.sh

dmg: app
	scripts/make-dmg.sh

install: app
	rm -rf /Applications/MacCleaner.app
	ditto dist/MacCleaner.app /Applications/MacCleaner.app
	@echo "Installed /Applications/MacCleaner.app"

# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	swift scripts/make-icon.swift .build/AppIcon.iconset
	iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns

