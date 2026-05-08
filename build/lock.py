#!/usr/bin/env python3
"""Resolve `ref` -> `commit` + `archive_sha256` in BRIDGES.lock.

For each bridge, this asks the GitHub API to resolve `ref` to a commit SHA,
downloads the matching tarball, computes its SHA-256, and rewrites
BRIDGES.lock in place. After this runs, `make build` is reproducible.

Run from the repo root:
    python3 build/lock.py

SPDX-License-Identifier: GPL-2.0-or-later
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

LOCK_PATH = Path(__file__).resolve().parent / "BRIDGES.lock"


def parse_lock(text: str) -> list[dict]:
    sections: list[dict] = []
    cur: dict | None = None
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("[") and s.endswith("]"):
            cur = {"name": s[1:-1], "_keys": []}
            sections.append(cur)
            continue
        if cur is None:
            raise SystemExit(f"key outside section: {line!r}")
        k, _, v = s.partition("=")
        cur[k.strip()] = v.strip()
        cur["_keys"].append(k.strip())
    return sections


def serialize_lock(original: str, updated: list[dict]) -> str:
    """Rewrite the file in place, preserving comments. We do a line-oriented
    edit so user comments survive a `make lock` run."""
    by_name = {s["name"]: s for s in updated}
    out: list[str] = []
    cur_name: str | None = None
    for line in original.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            cur_name = s[1:-1]
            out.append(line)
            continue
        if cur_name and s and not s.startswith("#") and "=" in s:
            k, _, _ = s.partition("=")
            k = k.strip()
            new_v = by_name[cur_name].get(k, "")
            # Preserve original indentation/spacing.
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f"{indent}{k} = {new_v}".rstrip())
            continue
        out.append(line)
    return "\n".join(out) + "\n"


def gh_api(url: str) -> dict:
    req = urllib.request.Request(
        url, headers={"Accept": "application/vnd.github+json",
                      "User-Agent": "proton-asio-lock"}
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def resolve_ref(repo_url: str, ref: str) -> str:
    m = re.match(r"https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", repo_url)
    if not m:
        raise SystemExit(f"unsupported url (need a github.com URL): {repo_url}")
    owner, repo = m.groups()
    info = gh_api(f"https://api.github.com/repos/{owner}/{repo}/commits/{ref}")
    return info["sha"]


def tarball_url(repo_url: str, commit: str) -> str:
    m = re.match(r"https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", repo_url)
    assert m
    owner, repo = m.groups()
    return f"https://codeload.github.com/{owner}/{repo}/tar.gz/{commit}"


def sha256_url(url: str) -> str:
    h = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=120) as r:
        for chunk in iter(lambda: r.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    original = LOCK_PATH.read_text()
    sections = parse_lock(original)

    for s in sections:
        name = s["name"]
        url = s["url"]
        ref = s["ref"]
        print(f"[{name}] resolving {ref} via {url}...")
        commit = resolve_ref(url, ref)
        print(f"[{name}] commit = {commit}")
        turl = tarball_url(url, commit)
        print(f"[{name}] hashing {turl}...")
        sha = sha256_url(turl)
        print(f"[{name}] sha256 = {sha}")
        s["commit"] = commit
        s["archive_sha256"] = sha

    LOCK_PATH.write_text(serialize_lock(original, sections))
    print(f"updated {LOCK_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
