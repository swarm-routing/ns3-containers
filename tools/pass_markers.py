#!/usr/bin/env python3
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Check an image's test pass markers and print the digest they name.

    tools/pass_markers.py <dir> <image-name> '<test_parts JSON>'

publish-images.yml tests one image in one or more jobs (its `test_parts`
from tools/ns3_matrix.py: everything in one job, or the stages but unit plus
N unit shards, ns3-containers#86). Each job that passes uploads the digest it
tested as the artifact passed-<name>--<part>; downloaded by the pattern
passed-<name>--*, each lands at <dir>/passed-<name>--<part>/digest, except
that actions/download-artifact unpacks a pattern that matches exactly one
artifact straight into <dir>, as <dir>/digest (ns3-containers#101). That flat
marker names no part, so it counts only for an image tested in a single part:
the pattern can then only have matched that part's marker. For a split image
it never stands in for a part. The image may be promoted only when every part
left its marker and all of them name the same digest: then this prints that
digest and exits 0. Otherwise it says what is missing on stderr and exits 1.
"""

from __future__ import annotations

import json
import os
import sys


def _read(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def digest_of(root, name, parts):
    """The one digest every part's marker names, or raise ValueError saying why not."""
    if not parts:
        raise ValueError(f"{name}: no test parts")
    # The marker paths come from listing <dir>, never from joining argv into a
    # path: a name or part such as "../x" then matches no entry (Sonar S8707).
    try:
        markers = {e.name: e.path for e in os.scandir(root) if e.is_dir()}
    except OSError:
        markers = {}
    seen = {}
    for p in parts:
        marker = f"passed-{name}--{p['part']}"
        d = ""
        if marker in markers:
            d = _read(os.path.join(markers[marker], "digest"))
        elif len(parts) == 1 and not markers:
            # One part, one matching artifact: download-artifact put it flat.
            d = _read(os.path.join(root, "digest"))
        if not d:
            raise ValueError(f"{name}: test part '{p['part']}' did not pass (no {root}/{marker}/digest)")
        seen[p["part"]] = d
    if len(set(seen.values())) != 1:
        raise ValueError(f"{name}: the parts tested different digests: {seen}")
    return next(iter(seen.values()))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    root, name, parts = argv
    try:
        print(digest_of(root, name, json.loads(parts)))
    except ValueError as e:
        print(f"pass_markers: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
