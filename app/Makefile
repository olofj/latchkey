# Top-level Makefile for Aperture.
#
#   make            build everything from scratch (libtailscale + app for sim)
#   make test       build, then run the UI tests on the simulator
#   make ipa        archive + export a dev-signed .ipa for a real device
#   make look       screenshot the booted sim + describe it with a vision sub-pi
#   make subtrac    preserve HEAD + nested submodule commits in main.trac
#   make clean      remove app build artifacts (not the libtailscale submodule)
#
# The libtailscale build needs Go and the iOS SDK; the app build needs Xcode.
# Latchkey builds both on Go 1.27.1 / Xcode 27 (docs/DECISIONS.md). Both are
# slow the first time. `make` skips re-running the
# libtailscale build if the xcframework already exists.

# ----- config -----
PROJECT      := Aperture.xcodeproj
SCHEME       := Aperture
CONFIG       := Debug
SIM_NAME     ?= iPhone 17
DERIVED      := build/DerivedData

XCFRAMEWORK  := ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework
# Rebuild the generated framework when a tracked libtailscale source changes.
# Depending only on the xcframework's existence silently packaged stale native
# code into new archives (especially dangerous for local submodule edits).
LIBTSCALE_SOURCES := $(shell git -C ThirdParty/libtailscale ls-files '*.go' '*.c' '*.h' 'swift/TailscaleKit/*.swift' 'swift/TailscaleKit/**/*.swift' | sed 's|^|ThirdParty/libtailscale/|')
LIBTSCALEDIR := ThirdParty/libtailscale/swift
SUBTRAC       := go tool git-subtrac
SUBTRAC_BRANCH := $(shell git branch --show-current)

# Device IPA build (see `make ipa`). Archive + export live under build/.
ARCHIVE      := build/Aperture.xcarchive
IPA_DIR      := build/ipa
EXPORT_OPTS  := ExportOptions.plist

# Pipe xcodebuild through xcpretty if installed, else cat. Use pipefail so a
# failed xcodebuild isn't masked by the prettifier's exit status (matches the
# libtailscale Makefile's approach).
XCPRETTIFIER := xcpretty
ifeq (, $(shell which $(XCPRETTIFIER)))
	XCPRETTIFIER := cat
endif
XCB := set -o pipefail; xcodebuild

# Latchkey divergence: nested-sandbox detection.
#
# Swift macro plugins (@State, @Model, …) are expanded by swift-plugin-server,
# which swift-frontend runs under its own seatbelt profile via sandbox-exec.
# If THIS build is already running inside a sandbox that forbids nested
# sandbox_apply — an AI coding agent's shell, some CI runners — every macro
# expansion fails with:
#
#   error: external macro implementation type 'SwiftUIMacros.StateMacro' could
#   not be found for macro 'State()'; '…/swift-plugin-server' produced
#   malformed response
#
# and the build then drowns in hundreds of misleading downstream errors
# ("cannot find '$binding' in scope", "cannot assign to property: 'self' is
# immutable"). Passing -disable-sandbox to the Swift driver skips the nested
# sandbox and the build succeeds.
#
# This is detected, not configured: on an ordinary Mac the probe below
# succeeds, SANDBOX_FLAGS stays empty, and macro sandboxing is untouched.
# Override with NESTED_SANDBOX=1 (force the flag) or NESTED_SANDBOX=0
# (never add it).
NESTED_SANDBOX ?= $(shell sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1 && echo 0 || echo 1)
ifeq ($(NESTED_SANDBOX),1)
  SWIFT_SANDBOX_FLAGS := OTHER_SWIFT_FLAGS='$$(inherited) -disable-sandbox'
else
  SWIFT_SANDBOX_FLAGS :=
endif

# ----- default -----
.PHONY: all
all: framework app  ## Build the libtailscale xcframework and the app for the simulator

.PHONY: test-lock-resume
test-lock-resume: framework  ## Background + genuinely freeze app process; assert prompt resume
	scripts/test-lock-resume.sh

# ----- libtailscale -----
.PHONY: framework
framework: $(XCFRAMEWORK)  ## Build TailscaleKit.xcframework (skipped if it exists)

$(XCFRAMEWORK): $(LIBTSCALE_SOURCES)
	@echo
	@echo "::: Building TailscaleKit.xcframework (libtailscale submodule) :::"
	@echo "(needs Go 1.26.5; slow the first time)"
	cd $(LIBTSCALEDIR) && make ios-fat

# ----- app -----
.PHONY: app
app: framework  ## Build the Aperture app for the simulator
	@echo
	@echo "::: Building Aperture for $(SIM_NAME) simulator :::"
	$(XCB) build \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination 'platform=iOS Simulator,name=$(SIM_NAME)' \
		-derivedDataPath $(DERIVED) $(SWIFT_SANDBOX_FLAGS) | $(XCPRETTIFIER)

# ----- device ipa (real device install) -----
.PHONY: ipa
ipa: framework  ## Archive + export a dev-signed .ipa for a real iOS device
	@./scripts/unlock-keychain.sh
	@echo
	@echo "::: Archiving Aperture for generic iOS (Release) :::"
	@echo "(needs a valid signing identity + provisioning profile for team W5364U7YZB;"
	@echo " the login keychain must be unlocked — unlock-keychain.sh above prompts"
	@echo " interactively if it's locked, or aborts if stdin isn't a terminal)"
	$(XCB) archive \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE) \
		-derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates | $(XCPRETTIFIER)
	@echo
	@echo "::: Exporting dev-signed IPA → $(IPA_DIR)/ :::"
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE) \
		-exportPath $(IPA_DIR) \
		-exportOptionsPlist $(EXPORT_OPTS) \
		-allowProvisioningUpdates
	@echo
	@echo "✅ IPA: $$(ls -1 $(IPA_DIR)/*.ipa 2>/dev/null | head -1)"
	@echo "Install on a plugged-in device with Xcode locally:"
	@echo "  xcrun devicectl device install app --device <udid-or-name> $(IPA_DIR)/Aperture.ipa"

# ----- test -----
# An auth key automates login on a fresh sim so the connected tests run.
# Resolution order: `make test AUTHKEY=...` > APERTURE_TEST_AUTHKEY env >
# ~/.aperture-ios-authkey. Without any of these, connected tests FAIL (they no
# longer skip) — a broken connection must be loud, not silently green.
# ----- split-tunnel policy unit tests (host-only, ~2s) -----
# Compiles the real TSNet/TailnetProxyPolicy.swift against stubs and asserts the
# routing rules: tailnet hosts proxied, public hosts DIRECT. No xcframework, no
# simulator, no signing. See scripts/proxy-semantics/ for how the expectations
# were measured against a real SOCKS proxy.
.PHONY: test-policy
test-policy:  ## Run split-tunnel and hostname-qualification unit tests (fast, host-only)
	@./scripts/test-proxy-policy.sh
	@./scripts/test-hostname-qualifier.sh

.PHONY: test-ios-ui
test-ios-ui: framework app  ## Run every required iOS UI test on the simulator
	@echo
	@echo "::: Running required iOS UI tests on $(SIM_NAME) :::"
	@if [ -n "$(AUTHKEY)" ]; then \
	    APERTURE_TEST_AUTHKEY='$(AUTHKEY)' ./scripts/run-uitests.sh "$(SIM_NAME)"; \
	else \
	    ./scripts/run-uitests.sh "$(SIM_NAME)"; \
	fi

.PHONY: test
test: test-policy test-ios-ui  ## Run the complete required iOS suite

# ----- process-log crash recovery + symbolication test -----
# A real Go panic is retained by the global filch, uploaded to the local fake
# log service after relaunch, and symbolicated through TailscaleKit's dSYM.
.PHONY: crashtest
crashtest: app  ## Verify real Go panic recovery through global logtail
	@echo
	@echo "::: Running process-log crash recovery test on $(SIM_NAME) :::"
	./scripts/run-crashtest.sh "$(SIM_NAME)"

# ----- commit/submodule history preservation -----
# Run after EVERY commit. git-subtrac is content-addressed/idempotent, so this
# is cheap when HEAD is already represented. The moving refs make detached
# nested-submodule commits fetchable while subtrac recursively records them.
.PHONY: subtrac
subtrac:  ## Preserve HEAD and all nested submodule commits in <branch>.trac
	@test -n "$(SUBTRAC_BRANCH)" || { echo "error: top-level HEAD is detached" >&2; exit 1; }
	@git -C ThirdParty/libtailscale/tailscale-patched update-ref \
		refs/heads/aperture-subtrac HEAD
	@git -C ThirdParty/libtailscale update-ref refs/heads/aperture-subtrac HEAD
	@$(SUBTRAC) update
	@want="$$($(SUBTRAC) cid HEAD)"; \
	 got="$$(git rev-parse '$(SUBTRAC_BRANCH).trac')"; \
	 test "$$want" = "$$got" || { \
	   echo "error: $(SUBTRAC_BRANCH).trac=$$got, expected $$want" >&2; exit 1; \
	 }; \
	 echo "::: $(SUBTRAC_BRANCH).trac -> $$got (HEAD and nested submodules preserved) :::"

# ----- vision helper (manual / for debugging) -----
.PHONY: look
look:  ## Screenshot the booted sim + describe it with a vision sub-pi (ask Q=...)
	./scripts/look.sh "$(Q)"

# ----- clean -----
.PHONY: clean
clean:  ## Remove app build artifacts (keeps the libtailscale xcframework)
	@echo "::: Cleaning app build artifacts :::"
	rm -rf $(DERIVED) $(ARCHIVE) $(IPA_DIR) $(IPA_APPSTORE_DIR)

.PHONY: clean-all
clean-all: clean  ## Also remove the libtailscale build artifacts (xcframework etc.)
	cd $(LIBTSCALEDIR) && make clean

# ----- help -----
.PHONY: help
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-][a-zA-Z0-9_-]*:.*##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := all
