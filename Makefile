PREFIX ?= $(HOME)/.local
BINDIR  = $(PREFIX)/bin

.PHONY: install uninstall test lint help

help:
	@echo "Targets:"
	@echo "  install    Install sideapt to $(BINDIR)/sideapt"
	@echo "  uninstall  Remove sideapt from $(BINDIR)"
	@echo "  test       Run bats tests"
	@echo "  lint       Run shellcheck on bin/sideapt"
	@echo ""
	@echo "Override PREFIX to change install location: make install PREFIX=$$HOME/bin"

install:
	@mkdir -p "$(BINDIR)"
	@install -m 0755 bin/sideapt "$(BINDIR)/sideapt"
	@echo "installed: $(BINDIR)/sideapt"
	@echo ""
	@echo "Make sure $(BINDIR) is in your PATH, then run:"
	@echo "  sideapt init"

uninstall:
	@rm -f "$(BINDIR)/sideapt"
	@echo "uninstalled: $(BINDIR)/sideapt"

test:
	@command -v bats >/dev/null || { echo "bats not found; install with 'apt download bats && sideapt install bats'"; exit 1; }
	@bats test/

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck not found"; exit 1; }
	@shellcheck bin/sideapt
