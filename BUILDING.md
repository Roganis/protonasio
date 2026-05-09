# Building proton-asio from source

This is for people building from a clean checkout. End users should use a
release tarball (which already contains pre-built bridge DLLs in
`share/proton-asio/`) and skip directly to `make install`.

## What gets built

The wrapper itself (`proton-asio`) is a single Python 3 file with no
dependencies and no build step. The work is in producing the **bridge
fake-DLLs** and rendering their registry templates from the upstream
sources pinned in `build/BRIDGES.lock`.

Each Wine bridge ships as **two files per bitness**: a PE stub
(`<bridge>.dll`) and the matching ELF library (`<bridge>.dll.so`).
Wine's `load_builtin` resolves the PE stub by dlopen'ing the .dll.so
from `WINEDLLPATH` — if either half is missing the bridge fails to
load with `c0000135 / DLL_NOT_FOUND`. The build extracts both halves
out of each bridge's source tree and lays them out under
`share/proton-asio/<bridge>/`:

```
share/proton-asio/wineasio/
    wineasio64.dll        wineasio64.dll.so
    wineasio32.dll        wineasio32.dll.so   (if built — see WoW64 below)
    wineasio.reg.template wineasio-uninstall.reg manifest.txt
share/proton-asio/pwasio/
    pwasio64.dll          pwasio64.dll.so
    pwasio-config.reg.template pwasio-config-uninstall.reg manifest.txt
```

The wrapper deploys the PE halves into the prefix's `system32` /
`syswow64` and the ELF halves into a prefix-local
`proton-asio-libs/<arch>-unix/` tree at install time, then injects
`WINEDLLPATH` at launch so Wine finds the .dll.so without us touching
the (often root-owned and update-clobbered) Proton tree.

## Toolchain

You need:

- **Wine devel** providing `winegcc`, `winebuild`, and Wine PE/ELF headers.
  Both bridges are Wine DLLs (PE-wrapped ELF), not regular Win32 DLLs, so
  you cannot build them with mingw-w64 alone.
- **Multilib support** so that 32-bit DLLs can be cross-compiled on a
  64-bit host. **Most distros gate this behind extra packages, AND most
  rolling distros have already moved their default Wine package to
  WoW64 mode where 32-bit Wine libraries don't exist at all.** See
  [32-bit support and WoW64](#32-bit-support-and-wow64) below.
- **mingw-w64** as a fallback / completeness toolchain (some bridge
  Makefiles call it directly).
- **Python 3.9+** to drive the build scripts.
- `curl`, `tar`, `sha256sum`, GNU `make`.

## 32-bit support and WoW64

Mainline Wine has been transitioning from a "true multilib" build (separate
32-bit and 64-bit Wine builds, with both copies of every Wine library on
disk) to a **WoW64-only** build (a single 64-bit Wine that runs 32-bit
Windows programs through a Wow64 thunk layer, with no 32-bit Wine libraries
on the host). This is the upstream direction, not a distro quirk:

- Arch's `wine` 11.x (current) ships **WoW64-only**.
  `/usr/lib/wine/i386-unix/` does not exist.
- Fedora rolling and openSUSE Tumbleweed are following the same path.
- Debian stable, Ubuntu LTS, and Wine-Staging branches typically still
  ship the legacy multilib build with `/usr/lib/wine/i386-unix/` populated.

What this means in practice for proton-asio's build:

- **64-bit wineasio always builds.** This covers ~all 64-bit Windows games.
- **32-bit wineasio requires legacy non-WoW64 Wine on the build host.**
  Without `/usr/lib/wine/i386-unix/` present, `winegcc -m32` cannot find
  `winecrt0.o` and friends, and no amount of mingw-w64 will substitute
  for the missing Wine arch-libs.

`make build` probes `/usr/lib/wine/i386-unix/` (or wherever
`WINE_LIB_DIR` points) before building 32-bit. If the directory is
missing it skips the 32-bit step with a clear warning rather than failing
the whole build. The output `share/proton-asio/wineasio/manifest.txt`
reflects what was actually produced — `dll32=` is omitted on
WoW64-only hosts — and the runtime wrapper warns clearly when a
WoW64-capable prefix has only the 64-bit DLL installed.

If you need 32-bit support, your options are:

1. **Build in a Debian / Ubuntu chroot or container** where the older
   multilib `wine` and `wine32-tools` packages are still available.
   `debootstrap` a `bookworm` rootfs, install `wine wine32` per the
   Debian instructions below, run `make build` inside.
2. **Use a Wine-Staging build** that explicitly retains the legacy
   multilib layout. (Check that `/usr/lib/wine/i386-unix/` exists before
   trusting the package name.)
3. **Skip 32-bit support.** For most current titles this is fine — the
   long tail of 32-bit-only games that benefit from ASIO is small, and
   pwasio is 64-bit-only by design anyway.

Override the probed location with `WINE_LIB_DIR`, e.g. for a non-standard
install:

```sh
make -C build build-wineasio WINE_LIB_DIR=/opt/wine-stable/lib/wine
```

### Debian / Ubuntu

```sh
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install \
    build-essential \
    wine wine-tools wine64-tools wine32 \
    libwine-dev:i386 libwine-dev \
    gcc-mingw-w64-x86-64-posix gcc-mingw-w64-i686-posix \
    python3 curl ca-certificates
```

CI builds on Debian 12 (bookworm) with these packages. The exact bookworm
image digest is recorded in `.github/workflows/release.yml`.

### Fedora

```sh
sudo dnf install -y \
    @development-tools \
    wine wine-devel wine-devel.i686 wine-core.i686 \
    mingw64-gcc mingw32-gcc \
    python3 curl
```

### Arch Linux

Enable `multilib` in `/etc/pacman.conf` first.

```sh
sudo pacman -S --needed \
    base-devel wine wine-mono \
    lib32-gcc-libs \
    mingw-w64-gcc \
    python curl
```

Note: Arch's `wine` package is **WoW64-only** as of Wine 11.x.
`/usr/lib/wine/i386-unix/` will not exist, so `make build` will skip the
32-bit wineasio target with a warning. This is fine for 64-bit games (the
common case). See [32-bit support and WoW64](#32-bit-support-and-wow64).

## Build steps

### 1. Resolve the lockfile (once, when bumping pins)

```sh
make -C build lock
```

This contacts the GitHub API, resolves each bridge's `ref` to a commit
SHA, downloads the corresponding tarball, and records both the commit and
the tarball SHA-256 in `build/BRIDGES.lock`. Commit the lockfile.

The lockfile in a fresh clone should already be populated for tagged
releases. You only need to re-run `make -C build lock` when bumping `ref`.

### 2. Build the bridges

```sh
make build
```

This:

1. Refuses to proceed unless `BRIDGES.lock` has both `commit` and
   `archive_sha256` for every bridge.
2. Downloads each tarball to `build/.work/` (cached) and verifies the
   SHA-256.
3. Cross-compiles each bridge with the upstream Makefile.
4. Runs `build/extract-clsid.py` against each source tree to get the COM
   GUID, then `build/gen-reg.py` to render
   `share/proton-asio/<bridge>/<bridge>.reg.template` and
   `…/<bridge>-uninstall.reg`.
5. Writes `share/proton-asio/<bridge>/manifest.txt`.

Reproducibility: builds run with `SOURCE_DATE_EPOCH` set to the upstream
commit's author date and `LC_ALL=C`. As long as you use the same Wine /
mingw versions documented above, the resulting DLLs should be
byte-identical to the release artifacts; CI publishes a `SHA256SUMS` file
alongside each release for verification.

### 3. Install

```sh
make install                 # to ~/.local
# or
make install PREFIX=/usr/local DESTDIR=/tmp/staging   # for packaging
```

The install target lays out:

```
$PREFIX/bin/proton-asio
$PREFIX/share/proton-asio/wineasio/{wineasio32.dll,wineasio64.dll,
                                    wineasio.reg.template,
                                    wineasio-uninstall.reg,
                                    manifest.txt}
$PREFIX/share/proton-asio/pwasio/{pwasio64.dll,
                                  pwasio.reg.template,
                                  pwasio-uninstall.reg,
                                  manifest.txt}
```

## Packaging

The tree is packaging-friendly: `make install PREFIX=/usr DESTDIR=…` lays
everything under standard XDG paths with no symlinks, no post-install
scripts, and no compiled state.

- **.deb**: a basic `debian/rules` would call `make build && make install
  PREFIX=/usr DESTDIR=$$(pwd)/debian/proton-asio`. Build-deps as above;
  runtime-deps are just `python3 (>= 3.9)` and recommends
  `pipewire-jack` (Debian) / `pipewire-libjack-0_3` (Ubuntu).
- **PKGBUILD**: pacman package — same `make build && make install` flow,
  with `PREFIX=/usr DESTDIR=$pkgdir`. Runtime depends `python` and
  `pipewire-jack`.
- **Flatpak**: not the natural delivery for a Steam-launch-time tool, but
  if you needed it, the layout would sit happily under `/app/bin` +
  `/app/share/proton-asio`. Set `PROTON_ASIO_SHARE_DIR=/app/share/proton-asio`
  in the manifest to bypass discovery.

## Self-checks

```sh
make check
```

This parses every Python file, smoke-tests the no-op passthrough, and
validates the layout of `share/proton-asio/` if it exists.

For exercising a real install path against a prefix + Wine binary, use
the test harness:

```sh
bash tests/harness.sh --run \
    ~/.local/share/Steam/steamapps/compatdata/<appid> \
    ~/.local/share/Steam/steamapps/common/Proton\ 9.0/files/bin/wine64
```

The harness runs proton-asio with a synthetic Steam env three times:
first-time install, idempotent second run (must short-circuit on the
marker), and a `PROTON_ASIO_FORCE_REINSTALL=1` run.

## Known build wrinkles

- **WoW64-only Wine hosts skip 32-bit wineasio.** See
  [32-bit support and WoW64](#32-bit-support-and-wow64). The build emits
  a warning, the manifest omits `dll32`, and the wrapper warns at install
  time if the target prefix could host 32-bit games.
- **No 32-bit pwasio at all.** Upstream's Makefile ships only a 64-bit
  target by design. If upstream adds a 32-bit target, drop a matching
  `dll32` entry into the manifest written by `build-pwasio` in
  `build/Makefile`.
- **`LIBRARY_PATH` for 64-bit wineasio.** The upstream Makefile's
  hard-coded `-L` paths don't include `/usr/lib/wine/x86_64-unix/`,
  which is where modern Wine actually keeps `winecrt0.o`. Our build sets
  `LIBRARY_PATH=$(WINE_LIB_DIR)/x86_64-unix` automatically; if you build
  by hand without our Makefile and get "cannot find -lwinecrt0" or
  similar, that's the fix.
- **wineasio output filename.** Recent Wine versions want `.so` instead
  of `.dll.so`; the Makefile already tolerates both by `cp`ing the file
  with the canonical `.dll` suffix into `share/proton-asio/wineasio/`.
- **Wine version skew.** Bridges built against Wine N may fail to load in
  a Proton prefix using a *much* older or newer Wine N±many. In practice
  building against any Wine 8.x – 11.x is fine for current Proton; CI
  uses the Wine in Debian 12.
