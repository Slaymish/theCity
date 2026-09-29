DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/TheCity.app

.PHONY: run build install test project replay clean companion phone

run: build
	Tools/Dev/relaunch.sh -workspace "$(CURDIR)/SampleWorkspace"

replay: build
	Tools/Dev/relaunch.sh -workspace "$(CURDIR)/SampleWorkspace" -replay "$(CURDIR)/fixtures/three-rooms.jsonl"

build: project
	xcodebuild -project TheCity.xcodeproj -scheme TheCity -configuration Debug -derivedDataPath $(DERIVED) -quiet build

install: build
	rm -rf /Applications/TheCity.app
	cp -R $(APP) /Applications/TheCity.app

# The iPhone app, for the simulator. To run it on a phone, open the project in Xcode with THECITY_TEAM set.
companion: project
	xcodebuild -project TheCity.xcodeproj -scheme TheCityCompanion -destination "generic/platform=iOS Simulator" -configuration Debug -derivedDataPath $(DERIVED) -quiet CODE_SIGNING_ALLOWED=NO build

# The iPhone app, on your phone over Wi-Fi. Needs THECITY_TEAM; see Docs/Companion.md.
phone:
	Tools/Dev/install-phone.sh

test:
	cd Packages/OfficeCore && swift test

project:
	xcodegen generate --quiet

clean:
	rm -rf $(DERIVED) TheCity.xcodeproj
