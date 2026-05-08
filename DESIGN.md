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

Primary path: **`STEAM_COMPAT_TOOL_PATHS`**. This is a colon-separated list of
the compat-tool directories Steam has bind-mounted into the game's environment
(documented in steam-runtime-tools' `steam-compat-tool-interface.md` as
"a colon-delimited list of paths to Steam compatibility tools in use, such as
Proton and the Steam Linux Runtime"). Iterate the entries; pick the first
whose directory contains both a `proton` script (executable) AND a
`files/bin/wine64` (or `dist/bin/wine64` for legacy GE). That entry is the
Proton dir. The Steam Linux Runtime entries are skipped naturally because
they have neither.

Fallback path (when `STEAM_COMPAT_TOOL_PATHS` is unset, malformed, or contains
no entry that looks like Proton): scan argv left-to-right and pick the first
arg whose basename is exactly `proton` AND whose immediate next arg is one of
the known Proton verbs (`run`, `runinprefix`, `waitforexitandrun`,
`getcompatpath`, `getnativepath`). Take its directory.

Either way, resolve Wine binaries against the resulting `PROTON_DIR` in this
order, taking the first that exists:

- `$PROTON_DIR/files/bin/wine64` and `…/wine` (modern Proton, Proton-GE,
  Proton-CachyOS).
- `$PROTON_DIR/dist/bin/wine64` and `…/wine` (legacy GE builds).

If neither pair exists, log a `[proton-asio]` error and `exec` the original
argv unchanged. We never substitute a system Wine — prefix Wine version must
match Proton's.

The prefix path comes from `STEAM_COMPAT_DATA_PATH/pfx`, with a sanity check
that the directory exists; if it doesn't, we skip setup, exec Proton (which
will create the prefix), and let the next launch do the install.

### Marker file

Path: `$STEAM_COMPAT_DATA_PATH/pfx/.proton_asio_installed`

Format: a single line, no trailing newline:

```
v1|<bridge>|<bridge_version>|<tool_version>|<dll_sha256_full>
```

Where `<dll_sha256_full>` is the full 64-hex-char SHA-256 of
`concat(read(wineasio32.dll), read(wineasio64.dll))` for wineasio, or
`sha256(read(pwasio64.dll))` for pwasio. On launch we recompute the expected
line from the currently-installed DLLs in `/usr/lib/proton-asio/` (or
`~/.local/share/proton-asio/`) and byte-compare against the marker. Mismatch
→ reinstall. `PROTON_ASIO_FORCE_REINSTALL=1` skips the check. The `v1` prefix
lets us bump the schema later without false hits.

Full SHA-256 rather than a truncation: a marker file is checked once per game
launch and is a few hundred bytes. There's no size or speed argument for
truncating, and the full hash means we don't have to reason about birthday
collisions when the catalogue of bridge+version+tool tuples grows. If we
weren't going to commit the bytes for a real hash we'd skip the hash entirely
and rely on `<bridge>|<bridge_version>|<tool_version>` plus the install path
mtime — but that's fragile across packaging paths, so we go with the full
hash and call it the source of truth.

### Prefix regeneration and bridge switching

Two related state-change cases the marker has to handle correctly.

**Prefix regenerated by Proton** (Proton version change, user clicks "Force a
specific Proton version", manual `compatdata` wipe). The whole `pfx/` is
recreated, which takes our marker file with it. Next launch sees no marker →
full install runs. No special handling needed — the marker living *inside*
`pfx/` is the whole point.

**User switches `PROTON_ASIO_BRIDGE`** between launches (`wineasio` →
`pwasio` or back). The marker's `<bridge>` field mismatches the expected
line, so a reinstall fires. But naive reinstall would *add* the new bridge's
DLLs and `.reg` on top of the old bridge's, leaving stale `system32/wineasio64.dll`
+ `HKCR\CLSID\…` entries from the previous bridge in the prefix. To keep
prefixes clean and predictable:

- Before installing the active bridge, run an **uninstall sweep** for any
  *other* known bridge whose marker we've seen or whose files we can detect.
  Concretely: delete `system32/{wineasio64,pwasio,pwasio64}.dll`,
  `syswow64/{wineasio32,wineasio,pwasio}.dll`, then apply a small
  `<bridge>-uninstall.reg` (also build-time-generated) that issues
  `[-HKCR\…]` deletions for the other bridge's CLSID and HKCU keys.
- Then install the active bridge as normal and write the new marker.

This sweep is cheap — it's `unlink` + one extra `regedit /S` only on bridge
*change*, not on every launch. Steady-state launches still match the marker
on the first compare and fast-path straight to `exec`.

We do not attempt to clean up an installed bridge when `PROTON_ASIO` is unset
or removed from a game's launch options. The DLLs/reg entries sit dormant in
the prefix; ASIO is dormant unless an app asks for it. A `proton-asio
--uninstall <prefix>` subcommand handles the explicit-removal case for users
who want it.

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

## Reproducible build inputs

Goal: a third party should be able to reproduce the bytes we ship in a
release artifact from this repo at a given tag. We track the inputs in a
checked-in `BRIDGES.lock`:

```
# BRIDGES.lock — pinned bridge sources, regenerated only by `make lock`.
wineasio:
  url:       https://github.com/wineasio/wineasio
  ref:       v1.3.0                # git tag
  commit:    <full 40-char sha>    # filled in at lock time
  archive_sha256: <sha256 of the resolved tarball>
pwasio:
  url:       https://github.com/golfiros/pwasio
  ref:       <branch name, e.g. main>
  commit:    <full 40-char sha>
  archive_sha256: <sha256 of the resolved tarball>
```

The build Makefile downloads each source as a tarball at the pinned commit,
verifies `archive_sha256`, then cross-compiles. It does **not** clone +
checkout, because a shallow clone's tree hash isn't stable across git
versions; tarball-by-commit gives us a byte-stable input.

Toolchain pin: CI builds in a Debian 12 (bookworm) container, using the
distro packages `gcc-mingw-w64-i686-posix` and `gcc-mingw-w64-x86-64-posix`
(MinGW-w64 11.0.x as shipped in bookworm). Both compilers are invoked with
`-fno-asynchronous-unwind-tables -ffile-prefix-map=$PWD=. -no-canonical-prefixes`
and built with `SOURCE_DATE_EPOCH` set to the upstream commit's author date,
so DLL timestamps are deterministic. The exact Debian image digest is
recorded in `.github/workflows/release.yml` and bumped explicitly.

`BUILDING.md` documents the same toolchain for local reproduction; users on
other distros can install equivalent mingw-w64 11.x packages and get the
same bytes as long as `SOURCE_DATE_EPOCH` and the flags match. CI publishes
both the DLLs and a `SHA256SUMS` file alongside the release.

## Open questions parked for implementation

- Initial values to write into `BRIDGES.lock` for wineasio v1.3.0 and the
  pinned pwasio `main` commit (resolved at first `make lock`).
- Whether to detect EAC/BattlEye by file presence (`EasyAntiCheat/`,
  `BattlEye/`) and warn under `PROTON_ASIO_DEBUG=1`. Cheap; will include.
- Final CLSID values: extracted at build time from each bridge's source
  rather than hardcoded, so a bridge upgrade can't desync the `.reg`.
