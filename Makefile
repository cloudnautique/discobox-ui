SHELL := /bin/bash
.DEFAULT_GOAL := help

# SwiftPM and packaging share an output directory. Keep even `make -j ci`
# sequential to avoid competing builds or partially copied bundles.
.NOTPARALLEL:
.PHONY: upstream brand-tokens help build smoke smoke-approvals ghostty test lint vet fmt-go verify ci

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

upstream: ## Clone or update discobox/ to the revision pinned in UPSTREAM_REVISION
	bash scripts/upstream.sh sync

brand-tokens: ## Regenerate the native palette from the pinned upstream brand tokens
	python3 scripts/generate-brand.py

build: ## Build and ad-hoc sign dist/Discobox.app (does not launch it)
	bash scripts/build-app.sh

smoke: ## Build the isolated debug smoke executable and fixture app bundle
	bash scripts/build-smoke.sh

# SwiftUI can recover from a cycle before the fixture assertions run. Treat
# its diagnostic as a failure too, and bound the run if the UI never recovers.
smoke-approvals: smoke ## Exercise native approval sheets and check for layout cycles
	@set -o pipefail; AG_PRINT_CYCLES=1 perl -e 'alarm 120; exec @ARGV or die $$!' \
	    .build/DiscoboxSmoke.app/Contents/MacOS/DiscoboxSmoke --approval-workflow-smoke 2>&1 | \
	    awk '/AttributeGraph: cycle detected/ { if (!cycles++) print; next } { print } END { if (cycles) exit 1 }'

ghostty: ## Build the pinned Ghostty SDK (first-time setup; requires Zig/Metal)
	bash scripts/build-ghostty-sdk.sh

test: ## Run Swift tests, Go race tests, and Go vet using isolated fixtures
	bash scripts/test.sh

lint: ## Check Swift warnings, Go formatting, script syntax, plist, and diff whitespace
	bash scripts/check.sh lint

vet: ## Run Go static analysis for the companion
	bash scripts/check.sh vet

fmt-go: ## Apply gofmt to companion source and tests
	bash scripts/check.sh fmt-go

verify: ## Verify the existing app bundle's signature and Info.plist
	bash scripts/check.sh verify

ci: ## Run lint, tests/vet, release packaging, and signature checks in order
	$(MAKE) lint
	$(MAKE) test
	$(MAKE) build
	$(MAKE) verify
