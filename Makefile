# Toolchain settings for machines with only the Command Line Tools (no Xcode).
# Override on the command line if needed, e.g. `make test CLT=/Applications/Xcode.app/Contents/Developer`.
CLT ?= /Library/Developer/CommandLineTools
FRAMEWORKS := $(CLT)/Library/Developer/Frameworks
TEST_LIBS := $(CLT)/Library/Developer/usr/lib

export DEVELOPER_DIR := $(CLT)
export PATH := $(CLT)/usr/bin:$(PATH)
unexport SDKROOT

# Command Line Tools ship the `_Testing_Foundation` overlay without module files,
# so tests that import Foundation and Testing together need cross-import overlays off.
TEST_FLAGS := -Xswiftc -F$(FRAMEWORKS) \
	-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
	-Xlinker -rpath -Xlinker $(FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(TEST_LIBS)

.PHONY: build run test clean

build:
	swift build

run:
	swift run MacCleaner

test:
	swift test $(TEST_FLAGS)

clean:
	swift package clean
