SHELL := /usr/bin/env bash

.PHONY: test lint check

test:
	bash tests/run.sh

lint:
	bash -n mini-git-server.sh
	bash -n tests/run.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck mini-git-server.sh tests/run.sh; \
	else \
		echo "shellcheck not installed; skipped"; \
	fi

check: lint test
