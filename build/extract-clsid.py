#!/usr/bin/env python3
"""Extract a COM CLSID GUID from a bridge's source tree.

Both wineasio and pwasio define their CLSID as a `static const CLSID` (or
similar) struct literal in C. We grep every `.c`/`.h` in the source for a
recognizable struct shape and reformat it into the canonical Windows GUID
string `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`.

Usage:
    extract-clsid.py <bridge-source-dir> <symbol>

Where <symbol> is e.g. `CLSID_WineASIO` or `CLSID_pwasio`. Prints the GUID
to stdout. Exits non-zero if not found or ambiguous.

SPDX-License-Identifier: GPL-2.0-or-later
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


# Match a struct literal of the form
#   { 0xXXXXXXXX, 0xXXXX, 0xXXXX, { 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX } }
GUID_LITERAL = re.compile(
    r"\{\s*0x([0-9a-fA-F]{1,8})\s*,"
    r"\s*0x([0-9a-fA-F]{1,4})\s*,"
    r"\s*0x([0-9a-fA-F]{1,4})\s*,"
    r"\s*\{\s*"
    r"((?:0x[0-9a-fA-F]{1,2}\s*,?\s*){8})"
    r"\}\s*\}"
)


def parse_guid(literal: str) -> str:
    m = GUID_LITERAL.search(literal)
    if not m:
        raise ValueError(f"not a GUID literal: {literal!r}")
    d1, d2, d3, byte_block = m.groups()
    bytes_ = re.findall(r"0x([0-9a-fA-F]{1,2})", byte_block)
    if len(bytes_) != 8:
        raise ValueError(f"expected 8 trailing bytes, got {len(bytes_)}")
    return (
        f"{{{int(d1,16):08X}-{int(d2,16):04X}-{int(d3,16):04X}-"
        f"{int(bytes_[0],16):02X}{int(bytes_[1],16):02X}-"
        f"{''.join(f'{int(b,16):02X}' for b in bytes_[2:])}}}"
    )


def find_in_source(src: Path, symbol: str) -> str:
    # Match a single-line OR multi-line declaration of the form
    #   <type> <symbol> [=] { ... };
    pattern = re.compile(
        r"\b" + re.escape(symbol) + r"\b\s*=?\s*(\{[^;]*\})\s*;",
        re.DOTALL,
    )
    candidates: list[str] = []
    for path in src.rglob("*"):
        if path.suffix.lower() not in (".c", ".h", ".cpp", ".cc", ".rs"):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in pattern.finditer(text):
            try:
                guid = parse_guid(m.group(1))
            except ValueError:
                continue
            candidates.append(guid)

    if not candidates:
        raise SystemExit(
            f"could not find a GUID literal for symbol {symbol!r} under {src}"
        )
    unique = sorted(set(candidates))
    if len(unique) > 1:
        raise SystemExit(
            f"found multiple distinct GUIDs for {symbol!r}: {unique}"
        )
    return unique[0]


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src = Path(argv[1])
    symbol = argv[2]
    if not src.is_dir():
        print(f"not a directory: {src}", file=sys.stderr)
        return 2
    guid = find_in_source(src, symbol)
    print(guid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
