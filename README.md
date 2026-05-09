# proton-asio

Drop-in tool that adds ASIO support to **any existing Proton install** (Valve
Proton, Proton-GE, Proton-CachyOS, etc.) without forking Proton itself.
Install once, then for any game that should expose ASIO, set the launch
option to:

```
PROTON_ASIO=1 proton-asio %command%
```

That's it. proton-asio injects [wineasio] (default) or [pwasio] into the
game's Wine prefix on launch, idempotently, and execs Proton unchanged.

[wineasio]: https://github.com/wineasio/wineasio
[pwasio]:   https://github.com/golfiros/pwasio

## What you get

- The game sees a `Wine ASIO` (or `pwasio`) entry in its audio device
  picker, alongside any DirectSound/WASAPI options.
- Audio routes through your existing PipeWire (or JACK) graph, so the
  game's outputs show up like any other PipeWire client and you can patch
  them in qpwgraph / Helvum / Carla.
- 32-bit and 64-bit games both work (with wineasio; pwasio is 64-bit-only
  upstream as of this writing).
- Non-ASIO games are completely unaffected. If `PROTON_ASIO` is unset, the
  tool execs the original command and exits without touching the prefix.

## Status

Pre-1.0. The wrapper, build, and install paths are implemented and tested
statically; manual smoke testing on a real Steam + Proton + PipeWire +
Reaper setup is the open TODO before tagging 0.1.0. See
[`DESIGN.md`](DESIGN.md) for the architecture and trade-offs.

## Install

### From a release tarball (recommended)

```sh
tar xf proton-asio-<version>.tar.gz
cd proton-asio-<version>
make install                 # default: ~/.local
# or: make install PREFIX=/usr/local   (system-wide; needs root)
```

The release tarball already contains pre-built bridge DLLs in
`share/proton-asio/`, so this is the only step.

### From source

You need Wine devel (provides `winegcc`/`winebuild`) and a multilib build
host. See [`BUILDING.md`](BUILDING.md). Then:

```sh
make -C build lock           # resolve BRIDGES.lock once (needs network)
make build                   # cross-compile both bridges
make install
```

### Set the launch option

In Steam, right-click the game → Properties → Launch Options:

```
PROTON_ASIO=1 proton-asio %command%
```

If `~/.local/bin` isn't on Steam's `PATH` (it isn't always — Steam picks up
your interactive shell's environment, but launchers run differently), use
the absolute path instead:

```
PROTON_ASIO=1 /home/YOU/.local/bin/proton-asio %command%
```

The first launch installs the bridge into the game's Wine prefix
(`~/.local/share/Steam/steamapps/compatdata/<appid>/pfx/`). Subsequent
launches see the marker file and short-circuit straight to launching the
game — no measurable startup overhead.

## Verifying it worked

In the game, open the audio settings or the ASIO driver picker. You should
see one of:

- **`Wine ASIO`** — the wineasio driver. (This is what most games show.)
- **`pwasio`** or **`pwasio (PipeWire ASIO)`** — if you set
  `PROTON_ASIO_BRIDGE=pwasio`.

If neither shows up, see [Troubleshooting](#troubleshooting) below.

## Configuration

Everything is via environment variables. All optional. Set them before
`proton-asio` in the launch option, e.g.:

```
PROTON_ASIO=1 PROTON_ASIO_BRIDGE=pwasio PROTON_ASIO_BUFFER=128 proton-asio %command%
```

| Variable | Default | Notes |
| --- | --- | --- |
| `PROTON_ASIO` | unset | Set to `1` to enable. Anything else is no-op. |
| `PROTON_ASIO_BRIDGE` | `wineasio` | `wineasio` or `pwasio`. |
| `PROTON_ASIO_BUFFER` | `256` | Buffer size in samples. 16–8192. |
| `PROTON_ASIO_SR` | `48000` | Sample rate. **wineasio inherits from JACK/PipeWire and ignores this**; pwasio honors it. |
| `PROTON_ASIO_INPUTS` | `2` | Input channel count. 1–64. |
| `PROTON_ASIO_OUTPUTS` | `2` | Output channel count. 1–64. |
| `PROTON_ASIO_CLIENT_NAME` | `proton-asio-<SteamAppId>` | JACK/PipeWire client name. |
| `PROTON_ASIO_DEBUG` | unset | `1` to log every step to stderr (look for `[proton-asio]` in Steam's stdout). |
| `PROTON_ASIO_FORCE_REINSTALL` | unset | `1` to ignore the marker and reinstall on next launch. |
| `PROTON_ASIO_SHARE_DIR` | unset | Override the bridge-files search path. |

To remove ASIO from a game, just delete the launch option. The DLLs and
registry entries stay dormant in the prefix until something asks for ASIO.
For an explicit cleanup of a specific prefix:

```sh
proton-asio --uninstall ~/.local/share/Steam/steamapps/compatdata/<appid>
```

## Choosing a bridge

| | wineasio | pwasio |
| --- | --- | --- |
| Backend | JACK API (works over `pipewire-jack`) | native PipeWire |
| Bitness | 64-bit always; 32-bit only if built against legacy non-WoW64 Wine | 64-bit only (upstream) |
| Maturity | Stable, ~v1.3.0 | Pre-release, 2025–2026 |
| Min PipeWire | any (or real JACK) | **1.6** (see Sniper note below) |
| License | GPL-2.0 / LGPL-2.1 | **GPL-3.0-or-later** |

**Default is wineasio** because it works on every modern desktop where
`pipewire-jack` is installed (Fedora, Arch, Ubuntu 22.04+, openSUSE TW —
all default to it) and is the only option that supports 32-bit games.
pwasio is the lower-latency native path for 64-bit-only titles, but see
the [Sniper / PipeWire 1.4 caveat](#pwasio-and-the-steam-linux-runtime)
before relying on it.

### 32-bit games

32-bit support requires building wineasio against legacy (non-WoW64)
Wine. Most rolling distros (Arch 11.x, Fedora rolling, openSUSE TW) ship
WoW64-only Wine and **cannot produce a 32-bit wineasio**. In a release
tarball built on those hosts, `share/proton-asio/wineasio/manifest.txt`
omits `dll32=`, and proton-asio warns at install time if the target
prefix could host 32-bit games. 64-bit games are unaffected.

If you need 32-bit support, build the release on a Debian / Ubuntu LTS
box (or chroot), where `wine32` is still packaged. See
[`BUILDING.md`](BUILDING.md#32-bit-support-and-wow64).

## Troubleshooting

**`[proton-asio] warn: ...` in Steam's stdout.** Run Steam from a terminal
and grep for `[proton-asio]`. The tool prefixes every log line so it's
findable. Re-launch with `PROTON_ASIO_DEBUG=1` for verbose tracing.

**ASIO entry doesn't appear in the game.** Most likely causes, in order:

1. `proton-asio` isn't on `$PATH` from inside the Steam launcher — use the
   absolute path in the launch option.
2. The game uses an anti-cheat (Easy Anti-Cheat, BattlEye) that blocks
   loading of unsigned DLLs. There is **no fix** for this short of the
   anti-cheat allow-listing wineasio. With `PROTON_ASIO_DEBUG=1` we log a
   warning when an EAC/BattlEye install dir is detected.
3. The bridge bitness doesn't match the game's bitness. wineasio installs
   both. If you forced `PROTON_ASIO_BRIDGE=pwasio` on a 32-bit game, switch
   back to `wineasio`.

**xruns / dropouts.** Increase `PROTON_ASIO_BUFFER` (try 512, then 1024).
The default 256 is fine on a tuned PipeWire setup but borderline on stock
configurations. Also check `pw-top` for clients that are running at
incompatible quanta.

**Sample-rate mismatch.** PipeWire/JACK runs at one global rate; if the
game asks for something different, audio comes through but with quality
issues. Set PipeWire's default rate to match the game (see
`pipewire.conf` / `default.clock.rate`) or set `PROTON_ASIO_SR` for pwasio.
wineasio inherits the JACK rate and cannot override it.

### pwasio and the Steam Linux Runtime

pwasio requires PipeWire ≥ 1.6 for the buffer-negotiation API it uses.
Steam launches games through the **Sniper runtime container**, which
ships with **PipeWire 1.4 client libraries** at the time of writing. The
container's `libpipewire-0.3.so.0` is loaded in preference to the host's,
so pwasio inside Sniper sees the older API and refuses to connect — even
if your host system has 1.6+.

Symptoms: pwasio shows up in the game's ASIO picker but selecting it
fails, or the game crashes / hangs on init. With `PROTON_ASIO_DEBUG=1`
you'll see pwasio log a PipeWire version mismatch.

Workarounds:

- **Use wineasio instead.** It's the default for a reason — JACK over
  `pipewire-jack` works fine in the Sniper container.
- **Disable the Sniper runtime for the affected game.** In Steam,
  right-click the game → Properties → Compatibility, then pick a Proton
  version that doesn't force Sniper, OR add `PROTON_NO_RUNTIME=1` to the
  launch options. This bypasses the container entirely; the host's
  PipeWire libraries get loaded directly. Some games won't run outside
  Sniper, so test before relying on this.
- **Wait for Valve to bump Sniper's PipeWire.** This is moving but
  there's no committed timeline.

If pwasio works for you outside Sniper but breaks inside, this is the
cause; switch to wineasio for that game.

**Bridge switch not taking effect.** Switching `PROTON_ASIO_BRIDGE`
between launches triggers an automatic uninstall sweep of the previous
bridge before installing the new one. If something's stuck:

```sh
proton-asio --uninstall ~/.local/share/Steam/steamapps/compatdata/<appid>
```

then relaunch the game.

**Prefix doesn't exist yet.** The first time you launch a game with
Proton, Proton creates the prefix mid-launch. proton-asio detects this and
defers — it logs a warning and execs Proton normally. The *second* launch
sees the populated prefix and installs the bridge.

## Files

```
~/.local/bin/proton-asio                            # the wrapper
~/.local/share/proton-asio/wineasio/...             # bridge DLLs + .reg
~/.local/share/proton-asio/pwasio/...
<prefix>/.proton_asio_installed                     # per-prefix marker
<prefix>/drive_c/windows/system32/wineasio.dll      # 64-bit DLL
<prefix>/drive_c/windows/syswow64/wineasio.dll      # 32-bit DLL
```

## License

proton-asio (the wrapper) is **GPL-2.0-or-later**. See
[`COPYING`](COPYING). The bundled bridge DLLs retain their own licenses:
wineasio is GPL-2.0 / LGPL-2.1; pwasio is GPL-3.0-or-later.
