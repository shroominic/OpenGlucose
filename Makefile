.PHONY: setup hooks analyze format format-check test check

# One-time setup after cloning: install git hooks.
setup hooks:
	./scripts/install-hooks.sh

# Static analysis over the Flutter app.
analyze:
	cd openhealth && flutter analyze

# Format all Dart code in place.
format:
	cd openhealth && dart format .

# Verify formatting without writing (used in CI / hooks).
format-check:
	cd openhealth && dart format --output=none --set-exit-if-changed .

# Run the test suite.
test:
	cd openhealth && flutter test

# Run everything the way CI does.
check: format-check analyze test
