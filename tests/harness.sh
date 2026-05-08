#!/usr/bin/env bash
# tests/harness.sh — exercise proton-asio's install path against a real
# (or fake) prefix + Wine binary, without going through Steam.
#
# Modes:
#   --self-check
#       Static checks only: parse proton-asio, dry-run no-op passthrough,
#       sanity-check share/proton-asio/ layout if present. No Wine needed.
#       This is what `make check` runs.
#
#   --run <prefix> <wine64> [--bridge wineasio|pwasio]
#       Sets up a synthetic Steam env pointing at <prefix>, invokes
#       proton-asio with PROTON_ASIO=1 and PROTON_ASIO_DEBUG=1, and
#       reports first-run install + idempotent second run. <prefix> is
#       <STEAM_COMPAT_DATA_PATH>; the Wine prefix lives at <prefix>/pfx
#       and must already be initialized (run `WINEPREFIX=<prefix>/pfx
#       <wine64> wineboot -u` first). Pass --bridge to test the non-default.
#
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PA="$REPO/proton-asio"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

self_check() {
    bold "[harness] self-check"
    python3 -c "import ast; ast.parse(open('$PA').read())"
    "$PA" --version >/dev/null
    PROTON_ASIO=0 "$PA" /bin/true
    if [[ -d "$REPO/share/proton-asio" ]]; then
        for b in wineasio pwasio; do
            d="$REPO/share/proton-asio/$b"
            if [[ -d "$d" ]]; then
                if [[ ! -f "$d/manifest.txt" ]]; then
                    red "  $d exists but has no manifest.txt"
                    return 1
                fi
                # Spot-check that everything the manifest names exists.
                while IFS='=' read -r k v; do
                    case "$k" in
                        dll64|dll32|reg|uninstall_reg)
                            if [[ ! -f "$d/$v" ]]; then
                                red "  $d/$v listed in manifest but missing"
                                return 1
                            fi ;;
                    esac
                done < "$d/manifest.txt"
                green "  $b: manifest + files OK"
            fi
        done
    else
        echo "  no share/proton-asio/ yet (run 'make build')"
    fi
    green "[harness] self-check passed"
}

run_full() {
    local compat="$1" wine="$2" bridge="${3:-wineasio}"

    if [[ ! -d "$compat" ]]; then
        red "compat dir does not exist: $compat"
        return 2
    fi
    if [[ ! -d "$compat/pfx" ]]; then
        red "$compat/pfx is missing — initialize the prefix first:"
        red "    WINEPREFIX='$compat/pfx' '$wine' wineboot -u"
        return 2
    fi
    if [[ ! -x "$wine" ]]; then
        red "$wine is not executable"
        return 2
    fi

    # Discover the Proton dir from the wine path: .../files/bin/wine64 ->
    # PROTON_DIR=.../, so we can populate STEAM_COMPAT_TOOL_PATHS for the
    # primary discovery path.
    local proton_dir
    proton_dir="$(dirname "$(dirname "$(dirname "$wine")")")"
    if [[ ! -f "$proton_dir/proton" ]]; then
        red "could not derive a Proton dir from $wine; no 'proton' script at $proton_dir"
        return 2
    fi

    bold "[harness] first run (expect: install $bridge)"
    PROTON_ASIO=1 \
    PROTON_ASIO_BRIDGE="$bridge" \
    PROTON_ASIO_DEBUG=1 \
    STEAM_COMPAT_DATA_PATH="$compat" \
    STEAM_COMPAT_TOOL_PATHS="$proton_dir" \
    SteamAppId="0" \
        "$PA" /bin/true

    if [[ ! -f "$compat/pfx/.proton_asio_installed" ]]; then
        red "[harness] no marker file written — install failed"
        return 1
    fi
    green "[harness] marker present: $(cat "$compat/pfx/.proton_asio_installed")"

    bold "[harness] second run (expect: marker match, no reinstall)"
    PROTON_ASIO=1 \
    PROTON_ASIO_BRIDGE="$bridge" \
    PROTON_ASIO_DEBUG=1 \
    STEAM_COMPAT_DATA_PATH="$compat" \
    STEAM_COMPAT_TOOL_PATHS="$proton_dir" \
    SteamAppId="0" \
        "$PA" /bin/true 2>&1 | tee /tmp/proton-asio-run2.log
    if grep -q "marker matches" /tmp/proton-asio-run2.log; then
        green "[harness] idempotent second run confirmed"
    else
        red "[harness] second run did NOT short-circuit on marker"
        return 1
    fi

    bold "[harness] forced reinstall"
    PROTON_ASIO=1 \
    PROTON_ASIO_BRIDGE="$bridge" \
    PROTON_ASIO_DEBUG=1 \
    PROTON_ASIO_FORCE_REINSTALL=1 \
    STEAM_COMPAT_DATA_PATH="$compat" \
    STEAM_COMPAT_TOOL_PATHS="$proton_dir" \
    SteamAppId="0" \
        "$PA" /bin/true

    green "[harness] full run passed"
}

main() {
    if [[ $# -eq 0 ]]; then usage; fi
    case "$1" in
        --self-check)
            self_check ;;
        --run)
            shift
            if [[ $# -lt 2 ]]; then usage; fi
            local compat="$1" wine="$2"; shift 2
            local bridge="wineasio"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --bridge) bridge="$2"; shift 2 ;;
                    *) red "unknown arg: $1"; usage ;;
                esac
            done
            run_full "$compat" "$wine" "$bridge" ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
}

main "$@"
