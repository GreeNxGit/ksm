SHELL := /bin/bash

.PHONY: test test-zsh test-all clean install-local lint

test: test-zsh

test-zsh:
	@tests/run.sh

test-all:
	@tests/run.sh tests/*.zsh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck install.sh tests/*.sh; \
	else \
		echo "shellcheck not installed (brew install shellcheck)"; \
	fi

# Install from this checkout (no curl) — useful for local development.
install-local:
	@KSM_LOCAL_DIR=$(CURDIR) KSM_HOME=$$HOME/.ksm ./install.sh

clean:
	@rm -rf tests/tmp
