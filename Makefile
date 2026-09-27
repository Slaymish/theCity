DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/TheCity.app

.PHONY: run build install test project replay clean

run: build
	open $(APP) --args -workspace "$(CURDIR)/SampleWorkspace"

replay: build
	open $(APP) --args -workspace "$(CURDIR)/SampleWorkspace" -replay "$(CURDIR)/fixtures/three-rooms.jsonl"

build: project
	xcodebuild -project TheCity.xcodeproj -scheme TheCity -configuration Debug -derivedDataPath $(DERIVED) -quiet build

install: build
	rm -rf /Applications/TheCity.app
	cp -R $(APP) /Applications/TheCity.app

test:
	cd Packages/OfficeCore && swift test

project:
	xcodegen generate --quiet

clean:
	rm -rf $(DERIVED) TheCity.xcodeproj
