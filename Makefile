# Makefile: short commands for common jobs.
#   make test     run the offline test suite
#   make lint     check all scripts with ShellCheck
#   make install  link os-buddy into ~/.local/bin

SCRIPTS := bin/os-buddy lib/*.sh install.sh tests/*.sh tests/fixtures/fake-curl.sh

.PHONY: test lint install

test:
	bash tests/run.sh

lint:
	@command -v shellcheck >/dev/null || { echo "install shellcheck first: sudo apt install shellcheck"; exit 1; }
	shellcheck $(SCRIPTS)

install:
	bash install.sh
