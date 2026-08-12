SHELL := /bin/sh

.DEFAULT_GOAL := help

.PHONY: help bootstrap tooling-bootstrap tooling-check hooks format \
	format-check lint typecheck test-unit test-integration test-e2e test \
	build build-android build-web build-ios test-ios-native \
	verify-android-release-signing check

platform_checks :=
ifeq ($(shell uname -s),Darwin)
platform_checks := build-ios test-ios-native
endif

help: ## Show the repository command contract.
	@awk 'BEGIN {FS = ":.*## "; printf "OpenGlucose engineering commands:\n\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

bootstrap: ## Restore the locked app and resolve library dependencies.
	@./scripts/flutter-workspace.sh doctor
	@./scripts/flutter-workspace.sh pub-get

tooling-bootstrap: ## Install checksum-pinned repository quality tools.
	@./scripts/install-quality-tools.sh

tooling-check: tooling-bootstrap ## Run ShellCheck and actionlint with pinned versions.
	@./scripts/check-tooling.sh

hooks: ## Install the pinned Lefthook Git hooks.
	@./scripts/install-lefthook.sh

format: ## Format Dart source in the app and every package.
	@./scripts/flutter-workspace.sh format

format-check: ## Check Dart formatting without modifying files.
	@./scripts/flutter-workspace.sh format-check

lint: ## Run each package's configured analyzer and lints.
	@./scripts/flutter-workspace.sh analyze

typecheck: ## Run Dart/Flutter static type analysis.
	@./scripts/flutter-workspace.sh analyze

test-unit: ## Run app widget/unit tests and every package unit test.
	@./scripts/flutter-workspace.sh test-unit

test-integration: ## Run every tagged or directory-based integration test.
	@./scripts/flutter-workspace.sh test-integration

test-e2e: ## Report the explicitly deferred device end-to-end lane.
	@./scripts/flutter-workspace.sh test-e2e

test: test-unit test-integration ## Run all locally configured automated tests.

build: build-android build-web ## Build the portable Android and web targets.

build-android: ## Build the Android debug APK.
	@./scripts/flutter-workspace.sh build-android

build-web: ## Build the web demo.
	@./scripts/flutter-workspace.sh build-web

build-ios: ## Build unsigned iOS and verify the native lockfile is unchanged.
	@./scripts/flutter-workspace.sh build-ios

test-ios-native: ## Run RunnerTests on the pinned iOS simulator destination.
	@./scripts/flutter-workspace.sh test-ios-native

verify-android-release-signing: ## Prove Android release signing fails closed without credentials.
	@./scripts/flutter-workspace.sh verify-android-release-signing

check: tooling-check format-check lint test build verify-android-release-signing $(platform_checks) ## Run every required CI gate supported by this host.
