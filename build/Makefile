# Build the ASIO bridges into ../share/proton-asio/<bridge>/.
#
# Inputs:
#   build/BRIDGES.lock        pinned commits + tarball SHA-256s
#   build/templates/*.reg.in  registry templates with @CLSID@ placeholders
#
# Outputs:
#   ../share/proton-asio/wineasio/{wineasio32.dll,wineasio64.dll,
#       wineasio.reg.template,wineasio-uninstall.reg,manifest.txt}
#   ../share/proton-asio/pwasio/{pwasio64.dll,pwasio.reg.template,
#       pwasio-uninstall.reg,manifest.txt}
#
# Toolchain: Wine devel (winegcc, winebuild) + the upstream Makefile of each
# bridge. See ../BUILDING.md.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

BUILD_DIR  := $(abspath .)
REPO_ROOT  := $(abspath ..)
WORK_DIR   := $(BUILD_DIR)/.work
SHARE_DIR  := $(REPO_ROOT)/share/proton-asio
TEMPLATES  := $(BUILD_DIR)/templates
LOCK       := $(BUILD_DIR)/BRIDGES.lock

GEN_REG     := python3 $(BUILD_DIR)/gen-reg.py
EXTRACT     := python3 $(BUILD_DIR)/extract-clsid.py
LOCK_SCRIPT := python3 $(BUILD_DIR)/lock.py

# Wine library directory. Modern Wine (10.x+) splits libraries by host
# arch under <prefix>/lib/wine/{x86_64,i386}-unix/. WoW64-only Wine
# installs (Arch's wine 11.x, Fedora rolling, etc.) ship only the
# x86_64-unix tree — the i386-unix dir is missing entirely, and 32-bit
# Wine PE/ELF DLLs cannot be built. We probe per-arch below.
WINE_LIB_DIR ?= /usr/lib/wine
WINE64_UNIX_DIR := $(WINE_LIB_DIR)/x86_64-unix
WINE32_UNIX_DIR := $(WINE_LIB_DIR)/i386-unix

# Deterministic output: SOURCE_DATE_EPOCH is set per-bridge from the upstream
# commit's author date inside the per-bridge target.
export LC_ALL := C

# Read a key from a [section] in BRIDGES.lock. Used by per-bridge targets.
# Usage: $(call lock_get,section,key)
define lock_get
$(shell awk -v section="$(1)" -v key="$(2)" '\
  /^\[/ { in_section = ($$0 == "[" section "]") } \
  in_section && $$1 == key && $$2 == "=" { print $$3; exit }' $(LOCK))
endef

.PHONY: build build-wineasio build-pwasio clean lock check-lock dirs

build: build-wineasio build-pwasio
	@echo "build complete: $(SHARE_DIR)"

dirs:
	@mkdir -p "$(WORK_DIR)" "$(SHARE_DIR)"

lock:
	$(LOCK_SCRIPT)

# Refuse to build if the lockfile is unresolved.
check-lock: $(LOCK)
	@for s in wineasio pwasio; do \
	    commit=$$(awk -v sect="[$$s]" '\
	        $$0 == sect { in_section = 1; next } \
	        /^\[/       { in_section = 0 } \
	        in_section && $$1 == "commit" { print $$3; exit }' $(LOCK)); \
	    sha=$$(awk -v sect="[$$s]" '\
	        $$0 == sect { in_section = 1; next } \
	        /^\[/       { in_section = 0 } \
	        in_section && $$1 == "archive_sha256" { print $$3; exit }' $(LOCK)); \
	    if [[ -z "$$commit" || -z "$$sha" ]]; then \
	        echo "BRIDGES.lock for [$$s] is unresolved (commit/sha empty)." >&2; \
	        echo "Run 'make -C build lock' to populate it." >&2; \
	        exit 1; \
	    fi; \
	done

# ---------------------------------------------------------------------------
# wineasio
# ---------------------------------------------------------------------------

WINEASIO_URL    = $(call lock_get,wineasio,url)
WINEASIO_COMMIT = $(call lock_get,wineasio,commit)
WINEASIO_SHA    = $(call lock_get,wineasio,archive_sha256)
WINEASIO_REF    = $(call lock_get,wineasio,ref)
WINEASIO_TAR    = $(WORK_DIR)/wineasio-$(WINEASIO_COMMIT).tar.gz
WINEASIO_SRC    = $(WORK_DIR)/wineasio-$(WINEASIO_COMMIT)
WINEASIO_OUT    = $(SHARE_DIR)/wineasio

build-wineasio: check-lock dirs
	@echo "[wineasio] commit $(WINEASIO_COMMIT)"
	@if [[ ! -f "$(WINEASIO_TAR)" ]]; then \
	    echo "[wineasio] downloading tarball..."; \
	    curl -fLsS -o "$(WINEASIO_TAR).part" \
	        "https://codeload.github.com/$$( \
	          echo $(WINEASIO_URL) | sed -E 's|https?://github\.com/||; s|\.git$$||')/\
tar.gz/$(WINEASIO_COMMIT)"; \
	    mv "$(WINEASIO_TAR).part" "$(WINEASIO_TAR)"; \
	fi
	@echo "[wineasio] verifying sha256..."
	@printf '%s  %s\n' "$(WINEASIO_SHA)" "$(WINEASIO_TAR)" | sha256sum -c -
	@rm -rf "$(WINEASIO_SRC)" "$(WINEASIO_SRC).extract"
	@mkdir -p "$(WINEASIO_SRC).extract"
	@tar -xzf "$(WINEASIO_TAR)" -C "$(WINEASIO_SRC).extract"
	@mv "$(WINEASIO_SRC).extract"/wineasio-* "$(WINEASIO_SRC)"
	@rmdir "$(WINEASIO_SRC).extract"
	@# 64-bit build. LIBRARY_PATH must point at the host's Wine arch-lib
	@# dir; modern Wine doesn't ship symlinks at /usr/lib that the bridge's
	@# upstream Makefile expects, so without this winegcc fails to find
	@# winecrt0.o et al. on Arch / Fedora-rolling.
	@if [[ ! -d "$(WINE64_UNIX_DIR)" ]]; then \
	    echo "[wineasio] WARN: $(WINE64_UNIX_DIR) not found — install" \
	         "wine-devel and re-run, or set WINE_LIB_DIR=…" >&2; \
	    exit 1; \
	fi
	@echo "[wineasio] building 64-bit (LIBRARY_PATH=$(WINE64_UNIX_DIR))..."
	@cd "$(WINEASIO_SRC)" && \
	    SOURCE_DATE_EPOCH=$$(git -C "$(WINEASIO_SRC)" log -1 --format=%ct 2>/dev/null \
	        || echo 1700000000) \
	    LIBRARY_PATH="$(WINE64_UNIX_DIR)$${LIBRARY_PATH:+:$$LIBRARY_PATH}" \
	    $(MAKE) 64
	@# 32-bit build. Skip cleanly on WoW64-only Wine installs.
	@if [[ -d "$(WINE32_UNIX_DIR)" ]]; then \
	    echo "[wineasio] building 32-bit (LIBRARY_PATH=$(WINE32_UNIX_DIR))..."; \
	    cd "$(WINEASIO_SRC)" && \
	        SOURCE_DATE_EPOCH=$$(git -C "$(WINEASIO_SRC)" log -1 --format=%ct 2>/dev/null \
	            || echo 1700000000) \
	        LIBRARY_PATH="$(WINE32_UNIX_DIR)$${LIBRARY_PATH:+:$$LIBRARY_PATH}" \
	        $(MAKE) 32; \
	    HAS_32=1; \
	else \
	    echo "[wineasio] WARN: $(WINE32_UNIX_DIR) is missing — host Wine" \
	         "is WoW64-only. Skipping 32-bit build. 32-bit Windows games" \
	         "in any prefix using this build will not see ASIO."; \
	    echo "[wineasio]       To get 32-bit support you need legacy" \
	         "(non-WoW64) Wine: see BUILDING.md."; \
	    HAS_32=0; \
	fi; \
	mkdir -p "$(WINEASIO_OUT)"; \
	cp "$(WINEASIO_SRC)/build64/wineasio64.dll" "$(WINEASIO_OUT)/wineasio64.dll" 2>/dev/null \
	    || cp "$(WINEASIO_SRC)/wineasio64.dll" "$(WINEASIO_OUT)/wineasio64.dll"; \
	if [[ "$$HAS_32" == "1" ]]; then \
	    cp "$(WINEASIO_SRC)/build32/wineasio32.dll" "$(WINEASIO_OUT)/wineasio32.dll" 2>/dev/null \
	        || cp "$(WINEASIO_SRC)/wineasio32.dll" "$(WINEASIO_OUT)/wineasio32.dll"; \
	fi; \
	echo "$$HAS_32" > "$(WINEASIO_OUT)/.has_32"
	@echo "[wineasio] extracting CLSID from source..."
	@CLSID=$$($(EXTRACT) "$(WINEASIO_SRC)" CLSID_WineASIO); \
	    echo "[wineasio] CLSID = $$CLSID"; \
	    $(GEN_REG) --clsid "$$CLSID" \
	        --in "$(TEMPLATES)/wineasio.reg.in" \
	        --out "$(WINEASIO_OUT)/wineasio.reg.template"; \
	    $(GEN_REG) --clsid "$$CLSID" \
	        --in "$(TEMPLATES)/wineasio-uninstall.reg.in" \
	        --out "$(WINEASIO_OUT)/wineasio-uninstall.reg"
	@HAS_32=$$(cat "$(WINEASIO_OUT)/.has_32"); \
	{ \
	    printf 'version=%s\n' "$(WINEASIO_REF)"; \
	    printf 'target=wineasio.dll\n'; \
	    printf 'dll64=wineasio64.dll\n'; \
	    if [[ "$$HAS_32" == "1" ]]; then printf 'dll32=wineasio32.dll\n'; fi; \
	    printf 'reg=wineasio.reg.template\n'; \
	    printf 'uninstall_reg=wineasio-uninstall.reg\n'; \
	} > "$(WINEASIO_OUT)/manifest.txt"
	@rm -f "$(WINEASIO_OUT)/.has_32"
	@echo "[wineasio] -> $(WINEASIO_OUT)"

# ---------------------------------------------------------------------------
# pwasio
# ---------------------------------------------------------------------------

PWASIO_URL    = $(call lock_get,pwasio,url)
PWASIO_COMMIT = $(call lock_get,pwasio,commit)
PWASIO_SHA    = $(call lock_get,pwasio,archive_sha256)
PWASIO_REF    = $(call lock_get,pwasio,ref)
PWASIO_TAR    = $(WORK_DIR)/pwasio-$(PWASIO_COMMIT).tar.gz
PWASIO_SRC    = $(WORK_DIR)/pwasio-$(PWASIO_COMMIT)
PWASIO_OUT    = $(SHARE_DIR)/pwasio

build-pwasio: check-lock dirs
	@echo "[pwasio] commit $(PWASIO_COMMIT)"
	@if [[ ! -f "$(PWASIO_TAR)" ]]; then \
	    echo "[pwasio] downloading tarball..."; \
	    curl -fLsS -o "$(PWASIO_TAR).part" \
	        "https://codeload.github.com/$$( \
	          echo $(PWASIO_URL) | sed -E 's|https?://github\.com/||; s|\.git$$||')/\
tar.gz/$(PWASIO_COMMIT)"; \
	    mv "$(PWASIO_TAR).part" "$(PWASIO_TAR)"; \
	fi
	@echo "[pwasio] verifying sha256..."
	@printf '%s  %s\n' "$(PWASIO_SHA)" "$(PWASIO_TAR)" | sha256sum -c -
	@rm -rf "$(PWASIO_SRC)" "$(PWASIO_SRC).extract"
	@mkdir -p "$(PWASIO_SRC).extract"
	@tar -xzf "$(PWASIO_TAR)" -C "$(PWASIO_SRC).extract"
	@mv "$(PWASIO_SRC).extract"/pwasio-* "$(PWASIO_SRC)"
	@rmdir "$(PWASIO_SRC).extract"
	@echo "[pwasio] building (64-bit)..."
	@cd "$(PWASIO_SRC)" && SOURCE_DATE_EPOCH=1700000000 $(MAKE)
	@mkdir -p "$(PWASIO_OUT)"
	@# Upstream produces lib/wine/x86_64-windows/pwasio.dll. Locate it
	@# robustly across release layouts.
	@DLL=$$(find "$(PWASIO_SRC)" -name pwasio.dll -path '*x86_64-windows*' \
	    -o -name pwasio.dll | head -1); \
	    if [[ -z "$$DLL" ]]; then \
	        echo "pwasio.dll not produced — check upstream Makefile" >&2; \
	        exit 1; \
	    fi; \
	    cp "$$DLL" "$(PWASIO_OUT)/pwasio64.dll"
	@# pwasio handles its own COM registration via DllRegisterServer
	@# (which writes more than just CLSID + InprocServer32: it also adds
	@# the HKLM driver-list entry and any other state pwasio decides it
	@# needs). proton-asio drives that with `wine regsvr32 pwasio.dll`
	@# at install time rather than reproducing it from a hand-built .reg.
	@# Build-time we only ship the user-config template, which targets
	@# HKCU\Software\ASIO\pwasio and is independent of the CLSID.
	@cp "$(TEMPLATES)/pwasio-config.reg.in" \
	    "$(PWASIO_OUT)/pwasio-config.reg.template"
	@cp "$(TEMPLATES)/pwasio-config-uninstall.reg" \
	    "$(PWASIO_OUT)/pwasio-config-uninstall.reg"
	@{ \
	    printf 'version=%s+%s\n' \
	        "$(PWASIO_REF)" "$$(echo $(PWASIO_COMMIT) | cut -c1-12)"; \
	    printf 'target=pwasio.dll\n'; \
	    printf 'install_method=regsvr32\n'; \
	    printf 'dll64=pwasio64.dll\n'; \
	    printf 'config_reg=pwasio-config.reg.template\n'; \
	    printf 'config_uninstall_reg=pwasio-config-uninstall.reg\n'; \
	} > "$(PWASIO_OUT)/manifest.txt"
	@echo "[pwasio] -> $(PWASIO_OUT)"

clean:
	rm -rf "$(WORK_DIR)" "$(SHARE_DIR)"
