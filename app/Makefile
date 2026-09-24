# Top-level Makefile for Latchkey.
#
#   make            build everything from scratch (libtailscale + app for sim)
#   make test       build, then run the UI tests on the simulator
#   make device     build (Release), install and launch on the paired iPhone
#   make ipa        archive + export a dev-signed .ipa for a real device
#   make look       screenshot the booted sim + describe it with a vision sub-pi
#   make clean      remove app build artifacts (keeps the TailscaleKit xcframework)
#
# The libtailscale build needs Go and the iOS SDK; the app build needs Xcode.
# Latchkey builds both on Go 1.27.1 / Xcode 27 (docs/DECISIONS.md). Both are
# slow the first time. `make` skips re-running the
# libtailscale build if the xcframework already exists.

# ----- config -----
PROJECT      := Latchkey.xcodeproj
SCHEME       := Latchkey
CONFIG       := Debug
# UI tests build with the Testing configuration, the only one that compiles
# in LATCHKEY_TEST_HOOKS (revision R15): scripts/run-uitests.sh and
# ../scripts/test-offline.sh pass -configuration Testing. Debug -- what
# Xcode's Run installs on the phone -- carries no test hooks at all.
SIM_NAME     ?= iPhone 17
DERIVED      := build/DerivedData

XCFRAMEWORK  := ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework
# Rebuild the generated framework when a tracked libtailscale source changes.
# Depending only on the xcframework's existence silently packaged stale native
# code into new archives (especially dangerous for local edits to the vendored
# tree).
#
# Since the R16 vendoring this list also covers tailscale-patched/: when it was
# a nested submodule, `git ls-files` here did not descend into it, so an edit
# to the patched Go tree never triggered a rebuild -- a latent stale-binary
# bug that the vendoring fixes for free. Files not yet added count too (-co),
# as they are while a change is being written and tested; generated headers
# are gitignored, so they do not.
LIBTSCALE_SOURCES := $(shell git -C ThirdParty/libtailscale ls-files -co --exclude-standard '*.go' '*.c' '*.h' 'swift/TailscaleKit/*.swift' 'swift/TailscaleKit/**/*.swift' | sed 's|^|ThirdParty/libtailscale/|')
# What the framework was built from: a hash of those sources' contents,
# written next to it by the rule that built it (check-framework).
FRAMEWORK_STAMP := $(XCFRAMEWORK:.xcframework=.sources-sha256)
SOURCES_HASH = printf '%s\n' $(LIBTSCALE_SOURCES) | xargs cat | shasum -a 256 | cut -d' ' -f1
LIBTSCALEDIR := ThirdParty/libtailscale/swift

# Device IPA build (see `make ipa`). Archive + export live under build/.
ARCHIVE      := build/Latchkey.xcarchive
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
framework: $(XCFRAMEWORK) check-framework  ## Build TailscaleKit.xcframework (skipped if current)

$(XCFRAMEWORK): $(LIBTSCALE_SOURCES)
	@echo
	@echo "::: Building TailscaleKit.xcframework (vendored libtailscale) :::"
	@echo "(needs Go; slow the first time)"
	# libtailscale's own c-archive targets have no prerequisites: once built
	# they are never rebuilt, so ios-fat re-linked the old Go code and a Go
	# change was silently left out (R29's tsnet.log was). Remove them first.
	cd ThirdParty/libtailscale && rm -f libtailscale_ios.a libtailscale_ios_sim.a \
		libtailscale_ios_sim_arm64.a libtailscale_ios_sim_x86_64.a
	cd $(LIBTSCALEDIR) && make ios-fat
	@$(SOURCES_HASH) > $(FRAMEWORK_STAMP)

# The framework was built, by the rule above, from exactly the sources on disk
# now. Runs on every `make framework`, so a failed or interrupted build, or a
# framework from elsewhere, stays an error until it is rebuilt -- rather than
# the next run finding the xcframework newer than its sources and moving on.
.PHONY: check-framework
check-framework:
	@test -f $(FRAMEWORK_STAMP) && [ "$$(cat $(FRAMEWORK_STAMP))" = "$$($(SOURCES_HASH))" ] \
		|| { echo "STALE: TailscaleKit.xcframework was not built from the current libtailscale sources; run 'make -B framework'" >&2; exit 1; }
	@echo "framework: built from the current libtailscale sources"

# ----- app -----
.PHONY: app
app: framework  ## Build the Latchkey app for the simulator
	@echo
	@echo "::: Building Latchkey for $(SIM_NAME) simulator :::"
	$(XCB) build \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination 'platform=iOS Simulator,name=$(SIM_NAME)' \
		-derivedDataPath $(DERIVED) $(SWIFT_SANDBOX_FLAGS) | $(XCPRETTIFIER)

# ----- device (the M1 device check's install step) -----
.PHONY: device
device: framework  ## Build (Release), install and launch on the paired iPhone (team: app/.dev-team)
	@./scripts/device-run.sh

# ----- device ipa (real device install) -----
.PHONY: ipa
ipa: framework  ## Archive + export a dev-signed .ipa for a real iOS device
	@./scripts/unlock-keychain.sh
	@echo
	@echo "::: Archiving Latchkey for generic iOS (Release) :::"
	@echo "(needs a valid signing identity + provisioning profile for your team; for the"
	@echo " M1 device check use make device instead. The login keychain must be unlocked;"
	@echo " unlock-keychain.sh above prompts, or aborts if stdin is not a terminal)"
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
	@echo "  xcrun devicectl device install app --device <udid-or-name> $(IPA_DIR)/Latchkey.ipa"

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
test-policy:  ## Run the host-only unit tests (fast; no simulator, no framework)
	@./scripts/test-proxy-policy.sh
	@./scripts/test-hostname-qualifier.sh
	@./scripts/test-log-redaction.sh
	@./scripts/test-gateway-address.sh
	@./scripts/test-page-scripts.sh
	@./scripts/test-navigation-policy.sh
	@./scripts/test-content-process-recovery.sh
	@./scripts/test-proxy-config.sh
	@./scripts/test-control-plane.sh
	@./scripts/test-token-input.sh
	@./scripts/test-gateway-candidates.sh
	@./scripts/test-diagnostics.sh
	@./scripts/test-socks-relay-policy.sh
	@./scripts/test-signout.sh
	@./scripts/test-fixture-tailnets.sh
	@./scripts/test-workspace-store.sh
	@./scripts/test-session-manager.sh
	@./scripts/test-browser-view-model.sh

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
