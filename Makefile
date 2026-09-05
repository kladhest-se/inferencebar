# SwiftPM's own build-time sandbox (plugin/macro execution during `swift
# build`/`swift test`), not the app's runtime App Sandbox entitlement —
# InferenceBar ships unsandboxed at runtime too, since it has to shell out
# to llama-server/mlx_lm.server/vllm-mlx and Homebrew, and read/write
# arbitrary user-chosen model paths outside any sandbox container.
SWIFT_FLAGS := --disable-sandbox
CACHE_ENV := CLANG_MODULE_CACHE_PATH="$(CURDIR)/work/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$(CURDIR)/work/swift-cache"
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' work/Info.plist)
ARCHIVE := outputs/InferenceBar-$(VERSION)-source.tar.gz
RELEASE_ARCHIVE := outputs/InferenceBar-$(VERSION)-macos.zip
DMG := outputs/InferenceBar-$(VERSION)-macos.dmg
SOURCE_FILES := Package.swift Makefile README.md CHANGELOG.md LICENSE LICENSE.md Sources Tests Assets work/Info.plist
APP_DIR := work/package/InferenceBar.app
APP_CONTENTS := $(APP_DIR)/Contents
DMG_ROOT := work/dmg
NOTARY_SUBMIT_ZIP := work/package/notarize-submit.zip

# A real "Developer ID Application" identity, if one is in the keychain,
# beats the ad-hoc "-" fallback -- ad-hoc signing satisfies `codesign
# --verify` locally but is not what Gatekeeper wants from a file that has
# actually been downloaded (quarantined). CODESIGN_IDENTITY=... on the
# command line, or in the environment, still overrides this outright --
# `?=` only fills it in when nothing already set it. With more than one
# Developer ID Application identity in the keychain, this takes the first
# `security find-identity` lists, which is not guaranteed to be the
# intended one: pass CODESIGN_IDENTITY explicitly in that case.
DETECTED_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)".*/\1/')
CODESIGN_IDENTITY ?= $(if $(DETECTED_IDENTITY),$(DETECTED_IDENTITY),-)
APP_DEST ?= /Applications

# A signature alone -- even a real Developer ID one, not just ad-hoc --
# still trips Gatekeeper on a fresh download until Apple has notarized the
# build and the ticket has been stapled to it. Off by default so nothing
# here changes for a checkout with no notary credentials configured; set
# up once with `xcrun notarytool store-credentials <name>` (see `make
# notarize-help`) and pass that name here, or export NOTARY_PROFILE so
# every invocation picks it up without repeating it.
NOTARY_PROFILE ?=

.PHONY: all help clean macos-build macos-run macos-open macos-test macos-archive macos-app macos-install macos-release macos-package signing-identities notarize-help notarize-setup cli install-cli

all:
	$(CACHE_ENV) swift build -c release $(SWIFT_FLAGS)

help:
	@echo "  make                 Build the release executable"
	@echo "  make macos-build     Build the release executable"
	@echo "  make macos-run       Build, sign, and launch the app bundle"
	@echo "  make macos-open      Open the Swift package in Xcode"
	@echo "  make macos-test      Run all tests"
	@echo "  make macos-install   Install the signed app in APP_DEST ($(APP_DEST))"
	@echo "  make macos-release   Create a signed release ZIP in outputs/"
	@echo "  make macos-package   Create a signed release DMG in outputs/"
	@echo "  make macos-archive   Create a source archive in outputs/"
	@echo "  make cli             Build the inferencebar-cli command-line tool"
	@echo "  make install-cli     Build the CLI and install it on your PATH as 'inferencebar'"
	@echo "  make clean           Remove local build and packaging products"
	@echo "  make signing-identities  List available signing identities"
	@echo "  make notarize-help   Explain notarizing macos-package/macos-release for real"
	@echo "  make notarize-setup  Find the team ID and Apple ID and set up notarization"
	@echo ""
	@echo "  Signing identity : $(CODESIGN_IDENTITY)"
	@echo "  Notary profile   : $(if $(NOTARY_PROFILE),$(NOTARY_PROFILE),(not set -- macos-package/macos-release will sign but not notarize))"

macos-build: all

macos-run: macos-app
	open "$(APP_DIR)"

macos-open:
	open Package.swift

macos-test:
	$(CACHE_ENV) swift test $(SWIFT_FLAGS)

macos-app: all
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_CONTENTS)/MacOS" "$(APP_CONTENTS)/Resources"
	cp .build/release/InferenceBar "$(APP_CONTENTS)/MacOS/InferenceBar"
	cp work/Info.plist "$(APP_CONTENTS)/Info.plist"
	cp Assets/AppIcons/AppIcon.icns "$(APP_CONTENTS)/Resources/AppIcon.icns"
	cp Assets/Credits.rtf LICENSE LICENSE.md "$(APP_CONTENTS)/Resources/"
	cp .build/release/inferencebar-cli "$(APP_CONTENTS)/Resources/inferencebar"
	codesign --force --deep --options runtime --sign "$(CODESIGN_IDENTITY)" "$(APP_DIR)"
	codesign --verify --deep --strict --verbose=2 "$(APP_DIR)"

macos-install: macos-app
	@if [ -w "$(APP_DEST)" ]; then \
		ditto "$(APP_DIR)" "$(APP_DEST)/InferenceBar.app"; \
	else \
		sudo mkdir -p "$(APP_DEST)"; \
		sudo ditto "$(APP_DIR)" "$(APP_DEST)/InferenceBar.app"; \
	fi
	@echo "Installed $(APP_DEST)/InferenceBar.app"

macos-release: macos-app
	mkdir -p outputs
	rm -f "$(RELEASE_ARCHIVE)" "$(RELEASE_ARCHIVE).sha256"
ifneq ($(strip $(NOTARY_PROFILE)),)
	@echo "Submitting for notarization (this waits on Apple; it can take a few minutes)..."
	rm -f "$(NOTARY_SUBMIT_ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_DIR)" "$(NOTARY_SUBMIT_ZIP)"
	xcrun notarytool submit "$(NOTARY_SUBMIT_ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	rm -f "$(NOTARY_SUBMIT_ZIP)"
	xcrun stapler staple "$(APP_DIR)"
	xcrun stapler validate "$(APP_DIR)"
else
	@echo "NOTARY_PROFILE not set -- $(RELEASE_ARCHIVE) will be signed but not notarized."
	@echo "A fresh download will still trip Gatekeeper. See 'make notarize-help'."
endif
	ditto -c -k --sequesterRsrc --keepParent "$(APP_DIR)" "$(RELEASE_ARCHIVE)"
	shasum -a 256 "$(RELEASE_ARCHIVE)" > "$(RELEASE_ARCHIVE).sha256"
	@echo "Created $(RELEASE_ARCHIVE)"

macos-package: macos-app
	rm -rf "$(DMG_ROOT)"
	mkdir -p "$(DMG_ROOT)" outputs
	ditto "$(APP_DIR)" "$(DMG_ROOT)/InferenceBar.app"
	ln -s /Applications "$(DMG_ROOT)/Applications"
	rm -f "$(DMG)" "$(DMG).sha256"
	hdiutil create -volname "InferenceBar $(VERSION)" -srcfolder "$(DMG_ROOT)" -ov -format UDZO "$(DMG)"
	codesign --force --sign "$(CODESIGN_IDENTITY)" "$(DMG)"
	codesign --verify --verbose=2 "$(DMG)"
ifneq ($(strip $(NOTARY_PROFILE)),)
	@echo "Submitting for notarization (this waits on Apple; it can take a few minutes)..."
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
else
	@echo "NOTARY_PROFILE not set -- $(DMG) is signed but not notarized."
	@echo "A fresh download will still trip Gatekeeper. See 'make notarize-help'."
endif
	shasum -a 256 "$(DMG)" > "$(DMG).sha256"
	@echo "Created $(DMG)"

macos-archive:
	mkdir -p outputs
	tar -czf "$(ARCHIVE)" $(SOURCE_FILES)
	@echo "Created $(ARCHIVE)"

# Builds just the CLI companion (see Sources/InferenceBarCLI) without the
# GUI app -- useful when developing from source rather than installing it
# from within InferenceBar's own Settings (AppStore.installCLITool()),
# which instead copies the copy already embedded in the app bundle by
# macos-app above.
cli:
	$(CACHE_ENV) swift build -c release $(SWIFT_FLAGS) --product inferencebar-cli

# Mirrors the destination logic in CLIInstallPolicy (Models.swift): prefer
# /opt/homebrew/bin when it's writable (already on PATH for anyone who
# used Homebrew to install InferenceBar's own runtimes), falling back to
# ~/.local/bin otherwise. No sudo either way.
install-cli: cli
	@dest="/opt/homebrew/bin"; \
	if [ ! -w "$$dest" ]; then dest="$(HOME)/.local/bin"; fi; \
	mkdir -p "$$dest"; \
	cp .build/release/inferencebar-cli "$$dest/inferencebar"; \
	chmod 755 "$$dest/inferencebar"; \
	echo "Installed $$dest/inferencebar"; \
	case ":$$PATH:" in \
		*":$$dest:"*) ;; \
		*) echo "$$dest is not on your PATH -- add it, or run with the full path." ;; \
	esac

signing-identities:
	@security find-identity -v -p codesigning || true

notarize-setup:
	@bin/notarize-setup.sh $(if $(NOTARY_PROFILE),$(NOTARY_PROFILE),inferencebar)

notarize-help:
	@echo "Signing (codesign) and notarizing (Apple's notary service) are separate"
	@echo "steps. Both are needed for a downloaded macos-package/macos-release build"
	@echo "to open without a Gatekeeper warning -- a real Developer ID signature"
	@echo "alone still gets flagged on a file carrying the quarantine attribute a"
	@echo "browser or GitLab download adds."
	@echo ""
	@echo "One-time setup, once you have a Developer ID Application certificate"
	@echo "(from a paid Apple Developer Program membership) in this Mac's keychain:"
	@echo ""
	@echo "  make notarize-setup"
	@echo ""
	@echo "finds the team ID (from that certificate) and the Apple ID (from the"
	@echo "account this Mac is signed into, shown for confirmation) automatically,"
	@echo "so the only thing left to type is the app-specific password notarytool"
	@echo "itself prompts for -- generated at appleid.apple.com, under Sign-In and"
	@echo "Security > App-Specific Passwords, not your Apple ID password itself."
	@echo "Pass a different profile name with NOTARY_PROFILE=name."
	@echo ""
	@echo "Equivalently, by hand:"
	@echo ""
	@echo "  xcrun notarytool store-credentials inferencebar \\"
	@echo "      --apple-id you@example.com --team-id TEAMID"
	@echo ""
	@echo "(leave off --password and it prompts for it, masked, rather than it"
	@echo "sitting in shell history; an App Store Connect API key works too, as a"
	@echo "different set of flags). Either way this stores the credential in the"
	@echo "keychain under that profile name, not in this repo or in any script here."
	@echo ""
	@echo "Then every macos-package / macos-release run:"
	@echo ""
	@echo "  make macos-package NOTARY_PROFILE=inferencebar"
	@echo ""
	@echo "or export it once per shell session (or in your shell profile) so it"
	@echo "applies without repeating it:"
	@echo ""
	@echo "  export NOTARY_PROFILE=inferencebar"
	@echo "  make macos-package"
	@echo ""
	@echo "CODESIGN_IDENTITY is separate and usually does not need setting by hand:"
	@echo "a Developer ID Application identity already in the keychain is detected"
	@echo "automatically (run 'make signing-identities' to see what is available);"
	@echo "it only needs overriding if more than one such identity is present and"
	@echo "the wrong one gets picked."

clean:
	rm -rf .build work/package work/dmg work/test-app work/swift-cache work/clang-cache
	@echo "Removed Swift build and app packaging products"

# work/swift-cache and work/clang-cache hold Clang/SwiftPM module caches
# keyed in part by this checkout's own absolute path (CACHE_ENV above uses
# $(CURDIR)). Move or rename the project folder — or copy it to a new
# location instead of extracting a fresh checkout there — and the old
# cache's baked-in path stops matching, which fails with something like
# "was compiled with module cache path X, but the path is currently Y" /
# "missing required module 'SwiftShims'". `make clean` covers exactly this;
# it's not a code problem, just a stale cache tied to wherever it was first
# built.
