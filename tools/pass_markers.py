#!/usr/bin/env python3
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Check an image's test pass markers and print the digest they name.

    tools/pass_markers.py <dir> <image-name> '<test_parts JSON>'

publish-images.yml tests one image in one or more jobs (its `test_parts`
from tools/ns3_matrix.py: everything in one job, or the stages but unit plus
N unit shards, ns3-containers#86). Each job that passes uploads the digest it
tested as the artifact passed-<name>--<part>; downloaded by pattern, each
lands at <dir>/passed-<name>--<part>/digest. The image may be promoted only
when every part left its marker and all of them name the same digest: then
this prints that digest and exits 0. Otherwise it says what is missing on
stderr and exits 1.
"""

from __future__ import annotations

import json
import os
import re
import sys

# An image name or test part is one path component: no separator, no leading dot.
SAFE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def digest_of(root, name, parts):
    """The one digest every part's marker names, or raise ValueError saying why not."""
    if not parts:
        raise ValueError(f"{name}: no test parts")
    root = os.path.realpath(root)
    seen = {}
    for p in parts:
        for what, v in (("image name", name), ("test part", p["part"])):
            if not SAFE.fullmatch(v):
                raise ValueError(f"{v!r} is not a valid {what}")
        f = os.path.realpath(os.path.join(root, f"passed-{name}--{p['part']}", "digest"))
        if os.path.commonpath([root, f]) != root:
            raise ValueError(f"{name}: marker {f} is not a valid path under {root}")
        try:
            with open(f) as fh:
                d = fh.read().strip()
        except OSError:
            d = ""
        if not d:
            raise ValueError(f"{name}: test part '{p['part']}' did not pass (no marker {f})")
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
