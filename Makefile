DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/TheOffice.app

.PHONY: run build test project replay clean

run: build
	open $(APP) --args -workspace "$(CURDIR)/SampleWorkspace"

replay: build
	open $(APP) --args -workspace "$(CURDIR)/SampleWorkspace" -replay "$(CURDIR)/fixtures/three-rooms.jsonl"

build: project
	xcodebuild -project TheOffice.xcodeproj -scheme TheOffice -configuration Debug -derivedDataPath $(DERIVED) -quiet build

test:
	cd Packages/OfficeCore && swift test

project:
	xcodegen generate --quiet

clean:
	rm -rf $(DERIVED) TheOffice.xcodeproj
