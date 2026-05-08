# proton-asio top-level Makefile.
#
#   make build      cross-compile bundled bridges into share/proton-asio/
#                   (delegates to build/Makefile)
#   make install    install proton-asio + bridge files under PREFIX
#   make uninstall  remove the installed files
#   make check      quick syntax + smoke checks
#   make clean      remove build artifacts
#
# Defaults: PREFIX=$(HOME)/.local. Override with `make install PREFIX=/usr`.

PREFIX  ?= $(HOME)/.local
DESTDIR ?=
BINDIR  := $(PREFIX)/bin
DATADIR := $(PREFIX)/share/proton-asio

REPO_ROOT := $(abspath .)
SHARE_SRC := $(REPO_ROOT)/share/proton-asio

INSTALL ?= install

.PHONY: all build install uninstall check clean help

all: help

help:
	@echo "proton-asio targets:"
	@echo "  make build       cross-compile bundled bridges into share/proton-asio/"
	@echo "  make install     install to PREFIX (default $(PREFIX))"
	@echo "  make uninstall   remove installed files from PREFIX"
	@echo "  make check       quick syntax + smoke tests"
	@echo "  make clean       remove build artifacts"
	@echo
	@echo "Tip: run 'make build' before 'make install', or fetch a release"
	@echo "tarball that already contains pre-built share/proton-asio/."

build:
	$(MAKE) -C build build

install:
	@if [[ ! -d "$(SHARE_SRC)" ]]; then \
	    echo "share/proton-asio/ is empty — run 'make build' first" >&2; \
	    exit 1; \
	fi
	$(INSTALL) -Dm755 proton-asio "$(DESTDIR)$(BINDIR)/proton-asio"
	@cd "$(SHARE_SRC)" && find . -type f -print0 | while IFS= read -r -d '' f; do \
	    rel=$${f#./}; \
	    $(INSTALL) -Dm644 "$$f" "$(DESTDIR)$(DATADIR)/$$rel"; \
	done
	@echo "installed proton-asio -> $(DESTDIR)$(BINDIR)"
	@echo "installed bridges    -> $(DESTDIR)$(DATADIR)"
	@echo
	@echo "In a game's Steam launch options, set:"
	@echo "    PROTON_ASIO=1 proton-asio %command%"
	@if ! echo "$$PATH" | tr ':' '\n' | grep -qx "$(BINDIR)"; then \
	    echo; \
	    echo "NOTE: $(BINDIR) is not on \$$PATH. Either add it, or use the"; \
	    echo "absolute path in the launch option:"; \
	    echo "    PROTON_ASIO=1 $(BINDIR)/proton-asio %command%"; \
	fi

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/proton-asio"
	rm -rf "$(DESTDIR)$(DATADIR)"
	@echo "removed proton-asio from $(DESTDIR)$(PREFIX)"

check:
	@python3 -c "import ast, sys; ast.parse(open('proton-asio').read()); \
	    ast.parse(open('build/gen-reg.py').read()); \
	    ast.parse(open('build/extract-clsid.py').read()); \
	    ast.parse(open('build/lock.py').read()); \
	    print('syntax: OK')"
	@./proton-asio --version
	@PROTON_ASIO=0 ./proton-asio /bin/true && echo "no-op passthrough: OK"
	@bash tests/harness.sh --self-check

clean:
	$(MAKE) -C build clean
