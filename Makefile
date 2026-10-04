# HanReader — MIT licensed. See LICENSE.
#
# The front door. `make run` is the one command a stranger with nothing but
# Xcode needs: it fetches its own pinned tooling, generates the Xcode project,
# builds, and launches.
#
# If you would rather not use make at all, `open Package.swift` builds every
# library target and runs the whole test suite with no additional tooling. make
# is only needed to produce a runnable application bundle.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TOOLS      := .tools/bin
XCODEGEN   := $(TOOLS)/xcodegen
SWIFTLINT  := $(TOOLS)/swiftlint
SWIFTFORMAT := $(TOOLS)/swiftformat

# Single stamp written by bootstrap.sh on success. Targets depend on this rather
# than on the tool binaries for two reasons: bootstrap deliberately leaves a
# skipped tool's mtime alone, so binary-based prerequisites re-trigger it
# forever once tools.lock is touched by a checkout; and one shared prerequisite
# means `make -j` cannot run two concurrent bootstraps over the same files.
TOOLS_STAMP := .tools/.bootstrap-stamp

PROJECT    := HanReader.xcodeproj
BUILD_DIR  := .build/xcode
IOS_DEVICE ?= iPhone 17

# Keep in step with the deployment targets in Package.swift.
MACOS_DEST := platform=macOS
IOS_DEST   := platform=iOS Simulator,name=$(IOS_DEVICE)

.PHONY: help bootstrap generate open run run-ios test test-all test-macos test-ios \
        lint format format-check dict clean distclean doctor

help: ## Show this help
	@printf 'HanReader\n\n'
	@printf 'Common targets:\n'
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'
	@printf '\nFirst time here?  make run\n'

# ── Tooling ──────────────────────────────────────────────────────────────────

bootstrap: ## Install pinned developer tooling into .tools/
	@./Scripts/bootstrap.sh

$(TOOLS_STAMP): Scripts/tools.lock
	@./Scripts/bootstrap.sh

doctor: ## Report toolchain and environment status
	@printf 'Swift:     %s\n' "$$(swift --version 2>&1 | awk 'NR==1')"
	@printf 'Xcode:     %s (pinned for CI: %s)\n' \
		"$$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $$2}')" \
		"$$(tr -d '[:space:]' < .xcode-version)"
	@# `grep -c` exits 1 on a zero count, so swallow the status rather than
	@# letting a fallback append a second number.
	@printf 'iOS sims:  %s runtime(s)\n' \
		"$$(xcrun simctl list runtimes 2>/dev/null | grep -c '^iOS ' || true)"
	@printf 'Tools:     %s\n' "$$([ -d .tools/bin ] && ls .tools/bin | tr '\n' ' ' || echo 'not installed — run make bootstrap')"

# ── Dictionary pipeline ──────────────────────────────────────────────────────

dict: ## Compile the bundled dictionary into Resources/Generated
	@mkdir -p Resources/Generated
	@printf 'Dictionary compilation arrives in milestone M3.\n'
	@swift run -q hanreader-dictgen --version

# ── Xcode project ────────────────────────────────────────────────────────────

generate: $(TOOLS_STAMP) ## Regenerate the Xcode project from project.yml
	@# One shell block on purpose. Make runs each recipe line in its own shell,
	@# so an early `exit 0` in a guard would end only that line and the
	@# following commands would still run.
	@if [ ! -f project.yml ]; then \
		printf 'project.yml does not exist yet — the app targets arrive in milestone M1 PR 3.\n'; \
	else \
		$(XCODEGEN) generate --quiet; \
		mkdir -p $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm; \
		cp Package.resolved $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; \
		printf 'Generated %s\n' "$(PROJECT)"; \
	fi
	@# The copy above matters: xcodebuild reads Package.resolved from inside the
	@# generated project, not from the repository root. Without it the committed
	@# pins are ignored and every build silently re-resolves dependencies.

open: generate ## Generate the project and open it in Xcode
	@if [ -d $(PROJECT) ]; then open $(PROJECT); else open Package.swift; fi

# ── Build and run ────────────────────────────────────────────────────────────

run: generate ## Build and launch the macOS app
	@if [ ! -d $(PROJECT) ]; then \
		printf 'No app target yet. Until milestone M1 PR 3, use:  make test\n'; \
		exit 1; \
	fi
	@xcodebuild build \
		-project $(PROJECT) -scheme HanReader-macOS -configuration Debug \
		-destination '$(MACOS_DEST)' -derivedDataPath $(BUILD_DIR) -quiet
	@open "$(BUILD_DIR)/Build/Products/Debug/HanReader.app"

run-ios: generate ## Build and launch the app in the iOS Simulator
	@# Captured before grepping. Piping into `grep -q` lets it close the pipe on
	@# the first match, simctl takes SIGPIPE, and under pipefail the probe reports
	@# failure -- telling a machine that HAS a runtime that it has none.
	@runtimes="$$(xcrun simctl list runtimes 2>/dev/null || true)"; \
	if ! printf '%s\n' "$$runtimes" | grep -q '^iOS '; then \
		printf 'error: no iOS simulator runtime installed.\n'; \
		printf '  Install one with:  xcodebuild -downloadPlatform iOS   (~10 GB)\n'; \
		exit 1; \
	fi
	@if [ ! -d $(PROJECT) ]; then \
		printf 'No app target yet. Until milestone M1 PR 3, use:  make test\n'; \
		exit 1; \
	fi
	@xcodebuild build \
		-project $(PROJECT) -scheme HanReader-iOS -configuration Debug \
		-destination '$(IOS_DEST)' -derivedDataPath $(BUILD_DIR) -quiet
	@# Target the requested device by UDID throughout. `simctl install booted`
	@# would install into whichever simulator happens to be booted -- a different
	@# device than the one just built for, or none at all.
	@udid="$$(xcrun simctl list devices available -j \
		| python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; \
print(next((x['udid'] for v in d.values() for x in v if x['name']=='$(IOS_DEVICE)'), ''))")"; \
	if [ -z "$$udid" ]; then \
		printf 'error: no available simulator named %s\n' "$(IOS_DEVICE)"; \
		printf '  Available:\n'; xcrun simctl list devices available | grep -E '^    ' | head -12; \
		printf '  Override with: make run-ios IOS_DEVICE="iPhone 16"\n'; \
		exit 1; \
	fi; \
	xcrun simctl bootstatus "$$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$$udid"; \
	open -a Simulator --args -CurrentDeviceUDID "$$udid"; \
	xcrun simctl install "$$udid" "$(BUILD_DIR)/Build/Products/Debug-iphonesimulator/HanReader.app"; \
	xcrun simctl launch "$$udid" org.openipc.hanreader

# ── Tests ────────────────────────────────────────────────────────────────────

test: ## Run the Swift package tests (fast; no simulator needed)
	@swift build --build-tests -Xswiftc -warnings-as-errors
	@swift test --skip-build

test-macos: generate
	@xcodebuild test -project $(PROJECT) -scheme HanReader-macOS \
		-destination '$(MACOS_DEST)' -derivedDataPath $(BUILD_DIR) -quiet

test-ios: generate
	@xcodebuild test -project $(PROJECT) -scheme HanReader-iOS \
		-destination '$(IOS_DEST)' -derivedDataPath $(BUILD_DIR) -quiet

test-all: test ## Run package tests plus both application test suites
	@if [ -f project.yml ]; then $(MAKE) test-macos test-ios; \
	else printf 'App targets arrive in milestone M1 PR 3; ran package tests only.\n'; fi

# ── Lint and format ──────────────────────────────────────────────────────────

lint: $(TOOLS_STAMP) ## Check formatting and lint rules
	@$(SWIFTFORMAT) --lint .
	@$(SWIFTLINT) lint --strict --quiet

format: $(TOOLS_STAMP) ## Apply formatting
	@$(SWIFTFORMAT) .

format-check: $(TOOLS_STAMP)
	@$(SWIFTFORMAT) --lint .

# ── Housekeeping ─────────────────────────────────────────────────────────────

clean: ## Remove build products
	@rm -rf .build $(PROJECT) Resources/Generated/*.hanreaderdict
	@printf 'Cleaned build products.\n'

distclean: clean ## Also remove the downloaded tooling
	@rm -rf .tools
	@printf 'Removed .tools — the next make target will re-bootstrap.\n'
