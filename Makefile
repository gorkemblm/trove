APP_NAME  := Clipboard
CONFIG    ?= release
SIGN_ID   ?= Developer ID Application
# Build products stay outside the Seafile folder, so they do not sync.
SCRATCH   := $(HOME)/Library/Caches/$(APP_NAME)-build
APP       := build/$(APP_NAME).app
# Zetetic LLC, publisher of the official SQLCipher.xcframework.
SQLCIPHER_TEAM := PD7G6HRMGV
SWIFT     := swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

.PHONY: help build test layout window-check icon app run stop restart logs verify clean

help:
	@echo "make build    Compile ($(CONFIG))"
	@echo "make test     Run unit tests (release, with timing checks)"
	@echo "make layout   Render the panel to build/snapshots and run layout stability checks"
	@echo "make window-check  Layout checks plus one that opens a real window on screen"
	@echo "make icon     Redraw Resources/AppIcon.icns"
	@echo "make app      Compile, assemble and sign $(APP)"
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
	cp -R Resources/en.lproj Resources/tr.lproj "$(APP)/Contents/Resources/"; \
	for b in "$$BIN"/*.bundle; do [ -e "$$b" ] && cp -R "$$b" "$(APP)/Contents/Resources/"; done; \
	FW="$$BIN/SQLCipher.framework"; \
	codesign --verify --strict "$$FW" || { echo "SQLCipher.framework: invalid signature"; exit 1; }; \
	codesign -dv "$$FW" 2>&1 | grep -q "TeamIdentifier=$(SQLCIPHER_TEAM)" || { echo "SQLCipher.framework: not signed by Zetetic"; exit 1; }; \
	mkdir -p "$(APP)/Contents/Frameworks"; \
	ditto "$$FW" "$(APP)/Contents/Frameworks/SQLCipher.framework"; \
	install_name_tool -add_rpath @executable_path/../Frameworks "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_ID)" "$(APP)/Contents/Frameworks/SQLCipher.framework"; \
	codesign --force --options runtime --timestamp=none \
		--entitlements Resources/$(APP_NAME).entitlements \
		--sign "$(SIGN_ID)" "$(APP)"
	@echo "Built $(APP)"

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
