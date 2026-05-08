# proton-asio — Design

Status: investigation pass. **Stop here for review before implementation.**

## Goal

`PROTON_ASIO=1 proton-asio %command%` in a game's Steam launch options is the
entire user-facing surface for getting ASIO into that game's prefix. No Proton
fork, no per-game setup, idempotent on every relaunch.

## Upstream investigation

### wineasio — https://github.com/wineasio/wineasio

- Latest tag **v1.3.0**, maintained by falkTX (Filipe Coelho, KXStudio).
- Build: plain `Makefile`. `make 32` → `wineasio32.dll(.so)`, `make 64` →
  `wineasio64.dll(.so)`. Both bitnesses are first-class.
- Backend: **JACK only**. On any modern PipeWire desktop the `pipewire-jack`
  shim provides the JACK API transparently, so end users do not need a real
  JACK server.
- License: GPL-2.0 (GUI) + LGPL-2.1 (library).
- v1.3.0 dynamically `dlopen`s `libjack.so.0`, which removes a hard build dep
  and lets the same DLL run on JACK or pipewire-jack systems.

### pwasio — https://github.com/golfiros/pwasio

- No tagged releases yet; active 2025–2026.
- Build: `Makefile`. Documented target produces only
  `lib/wine/x86_64-windows/pwasio.dll` — **64-bit only** in upstream as of this
  pass. Adding 32-bit would mean carrying a local patch.
- Backend: native PipeWire, requires PipeWire ≥ 1.6.
- License: GPL-3.0-or-later.
- Registry layout: `HKCU\Software\ASIO\pwasio`
  (`buffer_size`/`sample_rate`/`priority`/`host_priority`/`inputs`/`outputs`).

## Decisions

### Language: **Python 3 (stdlib only), single-file executable**

The wrapper is argv munging, file copies, one `wine regedit` call, and `exec`.
Python 3.9+ is present in Steam's Sniper runtime container and on every target
desktop. Cold-start cost (~40 ms) is negligible against Proton's own startup.
Ships as one auditable file; the only thing that needs cross-compilation
(mingw-w64) is the bridge DLLs themselves, which the Makefile handles. A Go
rewrite buys nothing here and complicates the build.

### Default bridge: **wineasio**, with `PROTON_ASIO_BRIDGE=pwasio` opt-in

Three reasons wineasio wins as default:

1. **32-bit games are still common** (Reaper x86, older middleware, lots of
   VST hosts). wineasio ships both bitnesses upstream; pwasio does not.
2. **Zero-config on PipeWire desktops** is already real: `pipewire-jack` is
   the default on Fedora, Arch, Ubuntu 22.04+, openSUSE TW. wineasio's
   dynamic `dlopen("libjack.so.0")` finds the PipeWire shim with no extra
   setup.
3. **Maturity**: wineasio has years of bug-fix iteration; pwasio is
   promising but young and pre-release.

pwasio is exposed as `PROTON_ASIO_BRIDGE=pwasio` for users on PipeWire ≥ 1.6
running 64-bit-only titles who want the lower-latency native path. If selected
on a 32-bit game we log a clear error and fall through to launching the game
without ASIO — never abort.

### Wine binary discovery

The tool's argv after its own args is the original Proton invocation, whose
shape is:

```
<runtime-entry-point> --verb=<verb> -- <PROTON_DIR>/proton <verb> <exe> [args...]
```

Algorithm:

1. Scan argv left-to-right. Pick the first arg whose basename is exactly
   `proton` AND whose immediate next arg is one of the known Proton verbs
   (`run`, `runinprefix`, `waitforexitandrun`, `getcompatpath`,
   `getnativepath`).
2. `PROTON_DIR = dirname(that arg)`.
3. Resolve Wine binaries in this priority order, taking the first that exists:
   - `$PROTON_DIR/files/bin/wine64` and `…/wine` (modern Proton, Proton-GE,
     Proton-CachyOS).
   - `$PROTON_DIR/dist/bin/wine64` and `…/wine` (legacy GE builds).
4. If neither pair exists, log a `[proton-asio]` error and `exec` the
   original argv unchanged. We never substitute a system Wine — prefix Wine
   version must match Proton's.

The prefix path comes from `STEAM_COMPAT_DATA_PATH/pfx`, with a sanity check
that the directory exists; if it doesn't, we skip setup, exec Proton (which
will create the prefix), and let the next launch do the install.

### Marker file

Path: `$STEAM_COMPAT_DATA_PATH/pfx/.proton_asio_installed`

Format: a single line, no newline:

```
v1|<bridge>|<bridge_version>|<tool_version>|<dll_sha256_12>
```

Where `<dll_sha256_12>` is the first 12 hex chars of `sha256(concat(
read(wineasio32.dll), read(wineasio64.dll)))` (or just the 64-bit DLL for
pwasio). On launch we recompute the expected line from the currently-installed
DLLs in `/usr/lib/proton-asio/` (or `~/.local/share/proton-asio/`) and
byte-compare. Mismatch → reinstall. `PROTON_ASIO_FORCE_REINSTALL=1` skips the
check. The `v1` prefix lets us bump the schema later without false hits.

This catches: tool upgrade, bridge upgrade, user swapping bridges, DLL on
disk being touched/replaced. It does not depend on mtimes (which aren't
preserved by every install path) — a content hash is more reliable.

## Top-level flow

```
proton-asio argv:
  1. PROTON_ASIO != "1"      → exec argv[1:] unchanged. Done.
  2. resolve PROTON_DIR + wine binary from argv (above)
  3. resolve PFX = STEAM_COMPAT_DATA_PATH/pfx
  4. if PFX missing                       → warn, exec argv[1:]
  5. read marker; if matches expected     → goto 8
  6. copy DLLs into pfx/drive_c/windows/{system32,syswow64}
     run `<wine64> regedit /S <bundled.reg>`
     write marker file
     (any failure here logs WARN and proceeds — install is best-effort,
      the DLLs+regs being partially in place is recoverable next launch)
  7. (verify pipewire-jack/JACK reachable only if PROTON_ASIO_DEBUG=1;
      do not block on this)
  8. exec argv[1:]   ← unmodified Proton invocation
```

Setup is one Wine invocation total: a single `regedit /S` against a static,
build-time-generated `.reg` file containing both the COM CLSID registration
and the `HKCU\Software\Wine\WineASIO` (or `HKCU\Software\ASIO\pwasio`)
defaults. No `regsvr32`, no per-launch shellouts beyond the one `regedit`.

## Layout

```
proton-asio/
├── proton-asio                  # Python 3 entrypoint, installed on PATH
├── share/proton-asio/
│   ├── wineasio/wineasio32.dll
│   ├── wineasio/wineasio64.dll
│   ├── wineasio/wineasio.reg    # generated at build time
│   ├── pwasio/pwasio64.dll
│   └── pwasio/pwasio.reg
├── build/
│   ├── Makefile                 # fetch + cross-compile bridges
│   └── gen-reg.py               # produces .reg files from CLSID constants
├── tests/
│   └── harness.sh               # given a prefix + wine bin, run install
├── Makefile                     # install/uninstall (~/.local or /usr)
├── README.md
├── BUILDING.md
├── DESIGN.md                    # this file
└── COPYING                      # GPL-2.0-or-later
```

DLLs ship via release artifacts (built in CI from pinned upstream tags with
checksums); end users with mingw-w64 can also `make build` locally. Source
tree contains no prebuilt binaries.

## Open questions parked for implementation

- Exact pinned commits/tags for wineasio (v1.3.0) and pwasio (latest `main`
  at build time, recorded by SHA in a `BRIDGES.lock` file).
- Whether to detect EAC/BattlEye by file presence (`EasyAntiCheat/`,
  `BattlEye/`) and warn under `PROTON_ASIO_DEBUG=1`. Cheap; will include.
- Final CLSID values: extracted at build time from each bridge's source
  rather than hardcoded, so a bridge upgrade can't desync the `.reg`.
