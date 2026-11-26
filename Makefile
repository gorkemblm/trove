APP_NAME  := Trove
CONFIG    ?= release
SIGN_ID   ?= Developer ID Application
# Build products stay outside the Seafile folder, so they do not sync.
SCRATCH   := $(HOME)/Library/Caches/$(APP_NAME)-build
APP       := build/$(APP_NAME).app
VERSION   := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
# The public repository: source, releases (disk images) and the website (GitHub Pages).
RELEASES_REPO := gorkemblm/trove
# Zetetic LLC, publisher of the official SQLCipher.xcframework.
SQLCIPHER_TEAM := PD7G6HRMGV
SWIFT     := swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"
# Daily builds sign without Apple's timestamp server; `make release` uses it (notarization needs it).
TIMESTAMP ?= --timestamp=none
# Hardened runtime for Developer ID builds (notarization needs it). An ad-hoc build
# (SIGN_ID=-, for your own Mac, no Apple account) leaves it out.
RUNTIME   := $(if $(filter -,$(SIGN_ID)),,--options runtime)
# The team's App Store Connect API key ("Hashdrop notarization", Developer access), saved in the
# keychain as this notarytool profile. A team key works for every app of the team.
NOTARY_PROFILE ?= hashdrop-notary

.PHONY: help build test layout demos window-check icon app release appcast site cask version run stop restart logs verify clean

help:
	@echo "make build    Compile ($(CONFIG))"
	@echo "make test     Run unit tests (release, with timing checks)"
	@echo "make layout   Render the panel to build/snapshots and run layout stability checks"
	@echo "make window-check  Layout checks plus one that opens a real window on screen"
	@echo "make icon     Redraw Resources/AppIcon.icns"
	@echo "make app      Compile, assemble and sign $(APP)"
	@echo "make release  Signed with a timestamp, notarized, stapled: build/releases/$(APP_NAME)-<version>.dmg"
	@echo "make appcast  Sparkle update list for build/releases, with release notes from CHANGELOG.md"
	@echo "make site     Website and appcast for GitHub Pages, in build/site"
	@echo "make cask     Homebrew cask for the current version, in build/Casks"
	@echo "make version NEW=x.y.z  Set the version (Info.plist, README badge, website)"
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
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(git rev-list --count HEAD)" "$(APP)/Contents/Info.plist"; \
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; \
	cp -R Resources/en.lproj Resources/tr.lproj Resources/Licenses "$(APP)/Contents/Resources/"; \
	for b in "$$BIN"/*.bundle; do [ -e "$$b" ] && cp -R "$$b" "$(APP)/Contents/Resources/"; done; \
	FW="$$BIN/SQLCipher.framework"; \
	codesign --verify --strict "$$FW" || { echo "SQLCipher.framework: invalid signature"; exit 1; }; \
	codesign -dv "$$FW" 2>&1 | grep -q "TeamIdentifier=$(SQLCIPHER_TEAM)" || { echo "SQLCipher.framework: not signed by Zetetic"; exit 1; }; \
	mkdir -p "$(APP)/Contents/Frameworks"; \
	ditto "$$FW" "$(APP)/Contents/Frameworks/SQLCipher.framework"; \
	install_name_tool -add_rpath @executable_path/../Frameworks "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	codesign --force $(RUNTIME) $(TIMESTAMP) --sign "$(SIGN_ID)" "$(APP)/Contents/Frameworks/SQLCipher.framework"; \
	SP="$$BIN/Sparkle.framework"; \
	[ -d "$$SP" ] || { echo "Sparkle.framework missing in $$BIN"; exit 1; }; \
	ditto "$$SP" "$(APP)/Contents/Frameworks/Sparkle.framework"; \
	SPV="$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B"; \
	codesign --force $(RUNTIME) $(TIMESTAMP) --sign "$(SIGN_ID)" "$$SPV/XPCServices/Installer.xpc"; \
	codesign --force $(RUNTIME) $(TIMESTAMP) --entitlements Resources/SparkleDownloader.entitlements \
		--sign "$(SIGN_ID)" "$$SPV/XPCServices/Downloader.xpc"; \
	codesign --force $(RUNTIME) $(TIMESTAMP) --sign "$(SIGN_ID)" "$$SPV/Autoupdate"; \
	codesign --force $(RUNTIME) $(TIMESTAMP) --sign "$(SIGN_ID)" "$$SPV/Updater.app"; \
	codesign --force $(RUNTIME) $(TIMESTAMP) --sign "$(SIGN_ID)" "$(APP)/Contents/Frameworks/Sparkle.framework"; \
	codesign --force $(RUNTIME) $(TIMESTAMP) \
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
	mkdir -p build/releases
	cp build/$(APP_NAME).dmg "build/releases/$(APP_NAME)-$(VERSION).dmg"
	python3 Scripts/release_notes.py $(VERSION) "build/releases/$(APP_NAME)-$(VERSION).html"
	@echo "Notarized: build/releases/$(APP_NAME)-$(VERSION).dmg"

# The update list (Sparkle appcast) for the notarized disk images in build/releases. Each
# image is signed with the EdDSA key in the login keychain (generate_keys made it once), and
# its release notes (from CHANGELOG.md) are embedded. Each image is downloaded from its own
# GitHub release: .../releases/download/v<version>/Trove-<version>.dmg.
SPARKLE_BIN = $(SCRATCH)/artifacts/sparkle/Sparkle/bin
DOWNLOADS = https://github.com/$(RELEASES_REPO)/releases/download
appcast:
	@ls build/releases/$(APP_NAME)-*.dmg >/dev/null 2>&1 || { echo "No disk images in build/releases: run make release first"; exit 1; }
	"$(SPARKLE_BIN)/generate_appcast" --embed-release-notes \
		--download-url-prefix "$(DOWNLOADS)/" --link "https://github.com/$(RELEASES_REPO)" build/releases
	sed -E -i '' 's#$(DOWNLOADS)/($(APP_NAME)-([0-9][0-9.]*)\.dmg)#$(DOWNLOADS)/v\2/\1#g' build/releases/appcast.xml
	@grep -o 'url="[^"]*"' build/releases/appcast.xml
	@echo "Appcast: build/releases/appcast.xml"

# The website and update list for GitHub Pages (the gh-pages branch), in build/site.
site:
	rm -rf build/site && mkdir -p build/site/demos
	cp Site/index.html build/site/index.html
	cp Docs/icon.png build/site/icon.png
	cp Docs/demos/*.gif build/site/demos/
	touch build/site/.nojekyll
	@if [ -f build/releases/appcast.xml ]; then cp build/releases/appcast.xml build/site/appcast.xml; else echo "No appcast yet: run make appcast"; fi
	@echo "Site: build/site"

# The Homebrew cask for the current version (Homebrew/trove.rb.in), in build/Casks/trove.rb.
# It goes into the tap repository gorkemblm/homebrew-tap, folder Casks.
cask:
	@[ -f "build/releases/$(APP_NAME)-$(VERSION).dmg" ] || { echo "No build/releases/$(APP_NAME)-$(VERSION).dmg: run make release first"; exit 1; }
	mkdir -p build/Casks
	sed -e "s/@VERSION@/$(VERSION)/" -e "s/@SHA256@/$$(shasum -a 256 "build/releases/$(APP_NAME)-$(VERSION).dmg" | cut -d' ' -f1)/" Homebrew/trove.rb.in > build/Casks/trove.rb
	@echo "Cask: build/Casks/trove.rb"

# make version NEW=0.2.0: the version in Info.plist and the README badge. Then add a
# "## 0.2.0" section to CHANGELOG.md.
version:
	@[ -n "$(NEW)" ] || { echo "Set NEW=x.y.z"; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(NEW)" Resources/Info.plist
	sed -E -i '' 's#badge/version-[0-9.]+-#badge/version-$(NEW)-#; s#alt="Version [0-9.]+"#alt="Version $(NEW)"#; s#$(APP_NAME)-[0-9][0-9.]*[0-9]\.dmg#$(APP_NAME)-$(NEW).dmg#g' README.md
	sed -E -i '' 's#download/v[0-9.]+/$(APP_NAME)-[0-9.]+\.dmg#download/v$(NEW)/$(APP_NAME)-$(NEW).dmg#; s#<span id="version">[0-9.]+</span>#<span id="version">$(NEW)</span>#' Site/index.html
	@grep -q "^## $(NEW)$$" CHANGELOG.md || echo "Now add a '## $(NEW)' section to CHANGELOG.md"

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
