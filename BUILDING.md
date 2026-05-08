# Building proton-asio from source

This is for people building from a clean checkout. End users should use a
release tarball (which already contains pre-built bridge DLLs in
`share/proton-asio/`) and skip directly to `make install`.

## What gets built

The wrapper itself (`proton-asio`) is a single Python 3 file with no
dependencies and no build step. The work is in producing the **bridge
DLLs** (`wineasio32.dll`, `wineasio64.dll`, `pwasio64.dll`) and rendering
their registry templates from the upstream sources pinned in
`build/BRIDGES.lock`.

## Toolchain

You need:

- **Wine devel** providing `winegcc`, `winebuild`, and Wine PE/ELF headers.
  Both bridges are Wine DLLs (PE-wrapped ELF), not regular Win32 DLLs, so
  you cannot build them with mingw-w64 alone.
- **Multilib support** so that 32-bit DLLs can be cross-compiled on a
  64-bit host. Most distros gate this behind extra packages.
- **mingw-w64** as a fallback / completeness toolchain (some bridge
  Makefiles call it directly).
- **Python 3.9+** to drive the build scripts.
- `curl`, `tar`, `sha256sum`, GNU `make`.

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

- **No 32-bit pwasio.** Upstream's Makefile ships only a 64-bit target.
  The build records this in the manifest as a missing `dll32` field, and
  proton-asio refuses to install pwasio into syswow64 with a clear
  warning. If upstream adds a 32-bit target, drop a matching `dll32`
  entry into the manifest written by `build-pwasio` in `build/Makefile`.
- **wineasio output filename.** Recent Wine versions want `.so` instead
  of `.dll.so`; the Makefile already tolerates both by `cp`ing the file
  with the canonical `.dll` suffix into `share/proton-asio/wineasio/`.
- **Wine version skew.** Bridges built against Wine N may fail to load in
  a Proton prefix using a *much* older or newer Wine N±many. In practice
  building against any Wine 8.x or 9.x is fine for current Proton; CI
  uses the Wine in Debian 12.
