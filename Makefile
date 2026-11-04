SHELL := /usr/bin/env bash

SHELL_FILES := mini-git-server.sh tests/run.sh tests/integration.sh tests/install-e2e.sh tests/fake-ssh

.PHONY: test test-integration test-install lint check

test:
	bash tests/run.sh

# Needs root and gitolite3. Creates and removes a temporary hosting account.
test-integration:
	bash tests/integration.sh

# Runs the real install. It changes the system, so it only runs on a
# disposable Debian 13 system or container, with MGS_E2E_DISPOSABLE=1 set.
test-install:
	bash tests/install-e2e.sh

lint:
	@for file in $(SHELL_FILES); do echo "bash -n $$file"; bash -n "$$file" || exit 1; done
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(SHELL_FILES); \
	else \
		echo "shellcheck not installed; skipped"; \
	fi

check: lint test
