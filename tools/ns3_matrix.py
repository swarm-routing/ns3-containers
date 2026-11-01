#!/usr/bin/env python3
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Generate the ns3-dev image matrix from upstream ns-3 release tags.

    tools/ns3_matrix.py [--tags-file F] [--versions 3.48,3.49] [--sha SHA]
                        [--missing-only] [--image REF]

Prints a GitHub Actions matrix, {"include": [...]}, on stdout. The version
window is never typed by hand: it is the WINDOW newest ns-3 minor releases
(newest patch of each), read from `git ls-remote` of ns-3-dev (or --tags-file,
one tag per line, for tests). Tiers:

    latest LATEST versions  ubuntu   x default, debug, sanitized, optimized
                            debian   x default, debug
                            slim     x default, debug
    the rest of the window  ubuntu   x default, debug
    newest version only     alpine   x debug (experimental: may fail)

Tags of one entry (ver = minor, e.g. 3.46; a patch release, e.g. 3.46.1, is
also tagged under its full number):

    ubuntu   :<ver>-<profile>, and :<ver> for `default`
    others   :<ver>-<os>-<profile>, and :<ver>-<os> for `default`
    newest ubuntu default also :latest
    every tag but :latest also gets an immutable -<sha7> twin

--missing-only keeps only versions whose plain :<full-version> tag is not yet
published (anonymous GHCR check): the weekly run builds new releases only.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request

UPSTREAM = "https://gitlab.com/nsnam/ns-3-dev.git"
IMAGE = "ghcr.io/swarm-routing/ns3-dev"
WINDOW = 10
LATEST = 3

# Base images, pinned by digest (ns3-containers invariant 13). Bump a digest
# here; the Dockerfile only receives it as BASE_IMAGE.
BASES = {
    "ubuntu": "ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852",
    "debian": "debian:13@sha256:2dc419c6d7fe3dad0a2f9fd469c34cc90b0f9ba642d8fde837fe3d7d34a0e7f1",
    "slim": "debian:13-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4",
    "alpine": "alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a",
}

FULL = ["default", "debug", "sanitized", "optimized"]
LIGHT = ["default", "debug"]

TAG_RE = re.compile(r"^ns-3\.(\d+)(?:\.(\d+))?$")


def parse_tags(lines):
    """Upstream tag names -> {minor: newest full version}, e.g. {46: '3.46.1'}."""
    best = {}
    for line in lines:
        name = line.strip().split("refs/tags/")[-1]
        if name.endswith("^{}"):
            continue
        m = TAG_RE.match(name)
        if not m:
            continue  # RCs, -dev and anything else that is not a release
        minor, patch = int(m.group(1)), int(m.group(2) or 0)
        if minor not in best or patch > best[minor][0]:
            best[minor] = (patch, name[len("ns-"):])
    return {minor: full for minor, (_, full) in best.items()}


def window(versions):
    """The WINDOW newest minors, newest first, as (minor_str, full) pairs."""
    minors = sorted(versions, reverse=True)[:WINDOW]
    return [(f"3.{m}", versions[m]) for m in minors]


def tags_for(minor, full, os_, profile, newest, sha7):
    labels = [minor] + ([full] if full != minor else [])
    tags = []
    for label in labels:
        stem = label if os_ == "ubuntu" else f"{label}-{os_}"
        tags.append(f"{stem}-{profile}")
        if profile == "default":
            tags.append(stem)
    pinned = [f"{t}-{sha7}" for t in tags] if sha7 else []
    latest = ["latest"] if newest and os_ == "ubuntu" and profile == "default" else []
    return tags + latest + pinned


def entries(win, sha7=""):
    out = []
    for i, (minor, full) in enumerate(win):
        plan = [("ubuntu", p) for p in (FULL if i < LATEST else LIGHT)]
        if i < LATEST:
            plan += [(os_, p) for os_ in ("debian", "slim") for p in LIGHT]
        if i == 0:
            plan += [("alpine", "debug")]
        for os_, profile in plan:
            out.append({
                "version": full,
                "minor": minor,
                "os": os_,
                "profile": profile,
                "base_image": BASES[os_],
                "experimental": os_ == "alpine",
                "name": f"{minor}-{os_}-{profile}" if os_ != "ubuntu" else f"{minor}-{profile}",
                "cache": f"{minor}-{os_}-{profile}",
                "tags": " ".join(tags_for(minor, full, os_, profile, i == 0, sha7)),
            })
    return out


def published(image, tag):
    """True when image:tag exists, checked anonymously (the package is public)."""
    repo = image.split("/", 1)[1]
    host = image.split("/", 1)[0]
    try:
        with urllib.request.urlopen(f"https://{host}/token?scope=repository:{repo}:pull", timeout=30) as r:
            token = json.load(r)["token"]
        req = urllib.request.Request(
            f"https://{host}/v2/{repo}/manifests/{tag}", method="HEAD",
            headers={"Authorization": f"Bearer {token}", "Accept": ", ".join([
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.v2+json"])})
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status == 200
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tags-file", help="upstream tag names, one per line (default: git ls-remote)")
    ap.add_argument("--versions", help="comma-separated full versions to keep (e.g. 3.48,3.46.1)")
    ap.add_argument("--sha", default="", help="commit SHA for the immutable -<sha7> tags")
    ap.add_argument("--missing-only", action="store_true", help="drop versions already published")
    ap.add_argument("--image", default=IMAGE)
    args = ap.parse_args(argv)

    if args.tags_file:
        with open(args.tags_file) as f:
            lines = f.readlines()
    else:
        lines = subprocess.run(["git", "ls-remote", "--tags", UPSTREAM, "ns-3.*"],
                               check=True, capture_output=True, text=True).stdout.splitlines()
    win = window(parse_tags(lines))
    if len(win) < WINDOW:
        sys.exit(f"ns3_matrix: only {len(win)} ns-3 releases found upstream")
    matrix = entries(win, args.sha[:7])
    if args.versions:
        keep = {v.strip() for v in args.versions.split(",") if v.strip()}
        unknown = keep - {e["version"] for e in matrix}
        if unknown:
            sys.exit(f"ns3_matrix: not in the window: {', '.join(sorted(unknown))}")
        matrix = [e for e in matrix if e["version"] in keep]
    if args.missing_only:
        have = {v for v in {e["version"] for e in matrix} if published(args.image, v)}
        matrix = [e for e in matrix if e["version"] not in have]
    json.dump({"include": matrix}, sys.stdout, separators=(",", ":"))
    print()
    print(f"ns3_matrix: {len(matrix)} images: "
          + ", ".join(sorted({e['version'] for e in matrix}, key=lambda v: [int(x) for x in v.split('.')])),
          file=sys.stderr)


if __name__ == "__main__":
    main()
