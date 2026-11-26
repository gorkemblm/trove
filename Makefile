APP_NAME  := Trove
CONFIG    ?= release
SIGN_ID   ?= Developer ID Application
# Build products stay outside the Seafile folder, so they do not sync.
SCRATCH   := $(HOME)/Library/Caches/$(APP_NAME)-build
APP       := build/$(APP_NAME).app
# Zetetic LLC, publisher of the official SQLCipher.xcframework.
SQLCIPHER_TEAM := PD7G6HRMGV
SWIFT     := swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"
# Daily builds sign without Apple's timestamp server; `make release` uses it (notarization needs it).
TIMESTAMP ?= --timestamp=none
# The team's App Store Connect API key ("Hashdrop notarization", Developer access), saved in the
# keychain as this notarytool profile. A team key works for every app of the team.
NOTARY_PROFILE ?= hashdrop-notary

.PHONY: help build test layout demos window-check icon app release appcast run stop restart logs verify clean

help:
	@echo "make build    Compile ($(CONFIG))"
	@echo "make test     Run unit tests (release, with timing checks)"
	@echo "make layout   Render the panel to build/snapshots and run layout stability checks"
	@echo "make window-check  Layout checks plus one that opens a real window on screen"
	@echo "make icon     Redraw Resources/AppIcon.icns"
	@echo "make app      Compile, assemble and sign $(APP)"
	@echo "make release  Signed with a timestamp, notarized, stapled, in build/$(APP_NAME).dmg"
	@echo "make run      Build the app and open it"
	@echo "make stop     Quit the running app"
	@echo "make restart  stop + run"
	@echo "make logs     Stream the app's logs"
	@echo "make verify   Show signature and entitlements"
	@echo "make clean    Remove build products"

build:
	$(SWIFT)

test:
	swift test -c release -Xswiftc -enable-testing --no-parallel --scratch-path "$(SCRATCH)"

# The snapshot runner is compiled only here (SNAPSHOTS flag), in its own build folder,
# so the shipped app does not contain it and the normal build cache stays valid.
LAYOUT_SWIFT := swift build -c $(CONFIG) --scratch-path "$(SCRATCH)-layout" -Xswiftc -DSNAPSHOTS

layout:
	$(LAYOUT_SWIFT)
	cp -R Resources/en.lproj Resources/tr.lproj "$$($(LAYOUT_SWIFT) --show-bin-path)/"
	"$$($(LAYOUT_SWIFT) --show-bin-path)/$(APP_NAME)" --snapshot build/snapshots
	"$$($(LAYOUT_SWIFT) --show-bin-path)/$(APP_NAME)" --snapshot build/snapshots-tr -AppleLanguages '(tr)'

# "How Trove Works" animations, rendered offscreen from the real panel: English and Turkish
# into the app's resources, English also for the README (Docs/demos).
demos:
	$(LAYOUT_SWIFT)
	cp -R Resources/en.lproj Resources/tr.lproj "$$($(LAYOUT_SWIFT) --show-bin-path)/"
	"$$($(LAYOUT_SWIFT) --show-bin-path)/$(APP_NAME)" --demos Resources/en.lproj/Demos -AppleLanguages '(en)'
	"$$($(LAYOUT_SWIFT) --show-bin-path)/$(APP_NAME)" --demos Resources/tr.lproj/Demos -AppleLanguages '(tr)'
	mkdir -p Docs/demos && cp Resources/en.lproj/Demos/*.gif Docs/demos/

# Opens a real window for a moment: run it only when nobody is working on this Mac.
window-check:
	$(LAYOUT_SWIFT)
	"$$($(LAYOUT_SWIFT) --show-bin-path)/$(APP_NAME)" --snapshot build/snapshots --window-checks

icon:
	swift Scripts/MakeIcon.swift "$(CURDIR)"

app: build
	@BIN="$$($(SWIFT) --show-bin-path)"; \
	rm -rf "$(APP)"; \
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"; \
	cp "$$BIN/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"; \
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; \
	cp -R Resources/en.lproj Resources/tr.lproj Resources/Licenses "$(APP)/Contents/Resources/"; \
	for b in "$$BIN"/*.bundle; do [ -e "$$b" ] && cp -R "$$b" "$(APP)/Contents/Resources/"; done; \
	FW="$$BIN/SQLCipher.framework"; \
	codesign --verify --strict "$$FW" || { echo "SQLCipher.framework: invalid signature"; exit 1; }; \
	codesign -dv "$$FW" 2>&1 | grep -q "TeamIdentifier=$(SQLCIPHER_TEAM)" || { echo "SQLCipher.framework: not signed by Zetetic"; exit 1; }; \
	mkdir -p "$(APP)/Contents/Frameworks"; \
	ditto "$$FW" "$(APP)/Contents/Frameworks/SQLCipher.framework"; \
	install_name_tool -add_rpath @executable_path/../Frameworks "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_ID)" "$(APP)/Contents/Frameworks/SQLCipher.framework"; \
	SP="$$BIN/Sparkle.framework"; \
	[ -d "$$SP" ] || { echo "Sparkle.framework missing in $$BIN"; exit 1; }; \
	ditto "$$SP" "$(APP)/Contents/Frameworks/Sparkle.framework"; \
	SPV="$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B"; \
	codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_ID)" "$$SPV/XPCServices/Installer.xpc"; \
	codesign --force --options runtime $(TIMESTAMP) --entitlements Resources/SparkleDownloader.entitlements \
		--sign "$(SIGN_ID)" "$$SPV/XPCServices/Downloader.xpc"; \
	codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_ID)" "$$SPV/Autoupdate"; \
	codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_ID)" "$$SPV/Updater.app"; \
	codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_ID)" "$(APP)/Contents/Frameworks/Sparkle.framework"; \
	codesign --force --options runtime $(TIMESTAMP) \
		--entitlements Resources/$(APP_NAME).entitlements \
		--sign "$(SIGN_ID)" "$(APP)"
	@echo "Built $(APP)"

# Notarization: Apple checks the signed app and issues a ticket; the ticket is stapled to the
# app and the disk image, so Gatekeeper accepts them offline on other Macs.
release: TIMESTAMP = --timestamp
release: app
	rm -f build/$(APP_NAME).zip build/$(APP_NAME).dmg
	ditto -c -k --keepParent "$(APP)" build/$(APP_NAME).zip
	xcrun notarytool submit build/$(APP_NAME).zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP)"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(APP)" -ov -format UDZO build/$(APP_NAME).dmg
	codesign --force --timestamp --sign "$(SIGN_ID)" build/$(APP_NAME).dmg
	xcrun notarytool submit build/$(APP_NAME).dmg --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple build/$(APP_NAME).dmg
	spctl --assess --type open --context context:primary-signature -v build/$(APP_NAME).dmg
	@echo "Notarized: build/$(APP_NAME).dmg"

# The update list (Sparkle appcast) for the notarized disk images in build/releases. Each
# image is signed with the EdDSA key in the login keychain (generate_keys made it once).
# DOWNLOAD_PREFIX is where the images are published, for example a GitHub release URL.
SPARKLE_BIN = $(SCRATCH)/artifacts/sparkle/Sparkle/bin
appcast:
	@[ -n "$(DOWNLOAD_PREFIX)" ] || { echo "Set DOWNLOAD_PREFIX=https://…/"; exit 1; }
	mkdir -p build/releases
	"$(SPARKLE_BIN)/generate_appcast" --download-url-prefix "$(DOWNLOAD_PREFIX)" build/releases
	@echo "Appcast: build/releases/appcast.xml"

run: app
	open "$(APP)"

stop:
	-pkill -x $(APP_NAME)

restart: stop run

logs:
	log stream --style compact --predicate 'subsystem == "com.iokoda.clipboard"'

verify:
	codesign --verify --deep --strict --verbose=2 "$(APP)"
	codesign -d --entitlements - "$(APP)"

clean:
	rm -rf build "$(SCRATCH)"
