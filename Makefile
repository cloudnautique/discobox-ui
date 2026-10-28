SHELL := /bin/bash
.DEFAULT_GOAL := help

# SwiftPM and packaging share an output directory. Keep even `make -j ci`
# sequential to avoid competing builds or partially copied bundles.
.NOTPARALLEL:
.PHONY: help build ghostty test lint vet fmt-go verify ci

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build and ad-hoc sign dist/Discobox.app (does not launch it)
	bash scripts/build-app.sh

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
