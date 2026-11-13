#!/usr/bin/env python3
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Select the buildx cache tags of releases ns-3 no longer supports.

    tools/cache_tags.py < versions > ids-to-delete 2> report

The buildx registry cache, ghcr.io/swarm-routing/ns3-dev-cache, has one tag
per scope, `<ver>-<base>-<profile>` (the `cache` of a tools/ns3_matrix.py
entry, e.g. 3.49-ubuntu-debug). Only the supported release is built by the
automatic pipelines, so only its scopes have a reader: candidates-cleanup.yml
deletes the others daily (golden rule 14, ns3-containers#146; maintainer
decision 2026-11-13). The scope an on-demand build of an older release
writes goes the same way at the next cleanup: such a build is rare and its
images are history, so its cache has no later reader.

Standard input holds the package's tagged versions, one JSON object per
line: {"id": <version id>, "tags": [<tag>, ...]}. For each version to delete
this prints `<id> <tag>[,<tag>...]` on stdout; the workflow deletes exactly
those ids. It deletes nothing itself and never names another package. What
is kept and what is selected goes to stderr as Markdown list lines, which
the workflow appends to the step summary. It takes no argument and opens no
file.

The supported release is read as ns3_matrix.py reads it, from upstream's
tags (`git ls-remote`): never typed (rule 15).

What is kept, always:
  - a scope of the supported release;
  - a tag that is not `<ver>-<base>-<profile>` with a base and profile
    ns3_matrix.py knows: kept and reported, never deleted;
  - a scope of a release newer than the supported one (the upstream tag list
    was read short): kept and reported;
  - a version one of whose tags is kept.

Nothing is selected, and the report says why (`nothing deleted: ...`, which
the workflow also raises as a warning), when
the supported release cannot be determined (upstream unreachable, no
release tag), or when the package has no scope of the supported release
(a new upstream release whose images are not built yet; this also covers a
selection that would delete every tag). Exit status is 0 in those cases:
the cleanup is retried the next day. A listing that does not have the shape
above is an error (exit 1, nothing on stdout).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys

import ns3_matrix

SCOPE_RE = re.compile(
    r"(\d+)\.(\d+)-(?:%s)-(?:%s)" % ("|".join(ns3_matrix.BASES), "|".join(ns3_matrix.FULL)))
MINOR_RE = re.compile(r"(\d+)\.(\d+)")


def supported_release(lines):
    """The supported release's minor ('3.49') from upstream tag lines, or None."""
    rel = ns3_matrix.releases(ns3_matrix.parse_tags(lines))
    return rel[0][0] if rel else None


def select(tags, supported):
    """(keep, delete, unparsed, newer): the tags of `supported`, of older releases,
    those that are not a cache scope, and those of a newer release. Only `delete` goes."""
    m = MINOR_RE.fullmatch(supported or "")
    if not m:
        raise ValueError(f"not a release minor: {supported!r}")
    sup = (int(m.group(1)), int(m.group(2)))
    keep, delete, unparsed, newer = [], [], [], []
    for tag in tags:
        s = SCOPE_RE.fullmatch(tag)
        if not s:
            unparsed.append(tag)
            continue
        ver = (int(s.group(1)), int(s.group(2)))
        (keep if ver == sup else delete if ver < sup else newer).append(tag)
    return keep, delete, unparsed, newer


def plan(versions, supported):
    """What to do with the package's versions ({"id", "tags"}); untagged ones are ignored.

    -> {"delete": [version], "keep": [version], "unparsed": [tag], "newer": [tag], "refused": why or ""}
    """
    tagged = [v for v in versions if v["tags"]]
    out = {"delete": [], "keep": tagged, "unparsed": [], "newer": [], "refused": ""}
    try:
        keep, delete, unparsed, newer = select([t for v in tagged for t in v["tags"]], supported)
    except ValueError:
        out["refused"] = "the supported release could not be determined"
        return out
    out["unparsed"], out["newer"] = unparsed, newer
    if delete and not keep:
        out["refused"] = (f"no scope of the supported release {supported} in the package "
                          "(its images are not built yet, or the release was read wrong)")
        return out
    gone = set(delete)
    out["delete"] = [v for v in tagged if all(t in gone for t in v["tags"])]
    out["keep"] = [v for v in tagged if not all(t in gone for t in v["tags"])]
    return out


def read_versions(lines):
    versions = []
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            v = json.loads(line)
        except ValueError:
            v = None
        if (not isinstance(v, dict) or type(v.get("id")) is not int or not isinstance(v.get("tags"), list)
                or not all(isinstance(t, str) for t in v["tags"])):
            sys.exit(f"cache_tags: line {n}: not {{\"id\": <int>, \"tags\": [<str>, ...]}}")
        versions.append(v)
    return versions


def code(tags):
    return ", ".join(f"`{t}`" for t in sorted(tags)) or "none"


def main():
    versions = read_versions(sys.stdin)
    supported, why = None, ""
    try:
        supported = supported_release(ns3_matrix.ls_remote())
    except (OSError, subprocess.SubprocessError) as e:
        why = f" ({type(e).__name__})"
    p = plan(versions, supported)

    kept = [t for v in p["keep"] for t in v["tags"]]
    scopes = [t for t in kept if t not in p["unparsed"] and t not in p["newer"]]
    out = [f"ns3-dev-cache tags; supported release: {supported or 'unknown'}"]
    if p["refused"]:
        out.append(f"nothing deleted: {p['refused']}{why}; kept {len(kept)}: {code(kept)}")
    else:
        out.append(f"kept {len(scopes)}: {code(scopes)}")
        if p["unparsed"]:
            out.append(f"not `<ver>-<base>-<profile>`, kept: {code(p['unparsed'])}")
        if p["newer"]:
            out.append(f"newer than the supported release, kept: {code(p['newer'])}")
        out.append(f"to delete: {len(p['delete'])}")
    print("".join(f"- {line}\n" for line in out), end="", file=sys.stderr)
    for v in p["delete"]:
        print(v["id"], ",".join(v["tags"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
