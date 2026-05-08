#!/usr/bin/env python3
"""Render a build-time .reg.template + uninstall.reg from a .reg.in template
and an extracted CLSID.

This handles only build-time substitutions (currently @CLSID@). Runtime
substitutions (@INPUTS_HEX@, @BUFFER_HEX@, @SAMPLE_RATE_HEX@, etc.) are left
untouched for proton-asio to fill in at install time.

Usage:
    gen-reg.py --clsid <GUID> --in <template.reg.in> --out <output.reg.template>

SPDX-License-Identifier: GPL-2.0-or-later
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


GUID_RE = re.compile(r"^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--clsid", required=True)
    p.add_argument("--in", dest="src", required=True, type=Path)
    p.add_argument("--out", dest="dst", required=True, type=Path)
    args = p.parse_args(argv[1:])

    if not GUID_RE.match(args.clsid):
        print(f"--clsid {args.clsid!r} is not a canonical {{XX...XX}} GUID",
              file=sys.stderr)
        return 2

    text = args.src.read_text()
    text = text.replace("@CLSID@", args.clsid)

    args.dst.parent.mkdir(parents=True, exist_ok=True)
    args.dst.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
