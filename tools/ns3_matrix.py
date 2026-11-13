#!/usr/bin/env python3
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Generate the ns3-dev image matrix from upstream ns-3 release tags.

    tools/ns3_matrix.py [--tags-file F] [--versions 3.36,3.46.1] [--sha SHA]
                        [--tier latest] [--missing-only] [--image REF]
                        [--summary FILE]

Prints a GitHub Actions matrix, {"include": [...]}, on stdout. Versions are
never typed by hand: they are read from `git ls-remote` of ns-3-dev (or
--tags-file, one tag per line, for tests), newest patch of each minor.

The automatic pipelines (push, PR, schedule) build only **the release ns-3
supports**: ns-3 maintains its latest release only, with no maintenance
branches or backports. That release gets:

    ubuntu   x default, debug, sanitized, optimized
    debian   x default, debug
    slim     x default, debug
    alpine   x debug (experimental: may fail)

Any other ns-3 release is built **on demand** with --versions (a manual
workflow_dispatch), as ubuntu x default, debug. Its images are then history:
no automatic pipeline rebuilds them.

Tags of one entry (ver = minor, e.g. 3.46; a patch release, e.g. 3.46.1, is
also tagged under its full number):

    ubuntu   :<ver>-<profile>, and :<ver> for `default`
    others   :<ver>-<os>-<profile>, and :<ver>-<os> for `default`
    every one of those also gets an immutable -<sha7> twin
    the supported release also: :latest-<profile> / :latest-<os>-<profile>,
             and :latest (ubuntu default) / :latest-<os>

An entry's `tags` are set when its image passes its tests; its `latest_tags`
(empty except for the supported release) move last, once every required image
of the run has passed (publish-images.yml).

An entry's `pr_unit_set` is the unit group its tests run on a pull request:
`light` for the Debian, slim and Alpine images (they differ from Ubuntu's
only in the base OS; Ubuntu's debug and sanitized keep `full`), empty for
Ubuntu (the profile's group). Pushes to main, schedule and dispatch runs
ignore it and run every image's profile group (ns3-containers#87).

An entry's `test_parts` are the test jobs its image gets, all on the same
digest in the same run (ns3-containers#86): one part running every stage,
or, for a profile with a `split <profile> <N>` line in test/ns3-suites.txt,
a `base` part (every stage but unit) and the unit stage as one part (N = 1)
or N shards (`test/run.sh --stages unit --unit-shard i/N`). promote tags the
digest only when every part passed. `--check-suites` validates
test/ns3-suites.txt: for N >= 2, the split profile's group has shards 1..N
that list its modules exactly once; a `main-only` line (suites test/unit.sh
leaves out on pull requests, #86) names at least one suite and is not a
group.

An entry's `representative` marks the images that stand for their kind on a
pull request whose images are all unchanged from what `main` last tested and
promoted, but whose test stages changed (tools/pr_tests.py, #86, #87): the
changed stages run on these only. They are Ubuntu debug, sanitized and
optimized, plus one image per other base: Debian debug, slim default (so the
`default` profile is covered too) and Alpine debug. An on-demand release has
only Ubuntu default and debug; debug stands for it.

--tier latest keeps only the supported release's entries (its full set, the
images the automatic pipelines own). It is what an OS security refresh
rebuilds (publish-images.yml `refresh`, #29): with --versions it refuses any
release but the supported one, so a refresh never rebuilds history as a side
effect (an older release is rebuilt only by an on-demand --versions build).

--missing-only keeps only the releases that are not yet published in full
(anonymous GHCR check): the scheduled run builds a new release once, and
builds it again while a required image of it is missing (#149). A release is
published when every required (non-experimental) image of its plan has its
own versioned tag under the release's full number (:3.50-debug,
:3.50-debian, ...: `own_tag`), not only the plain :<full-version> tag, which
is the Ubuntu default image's alone. A release with one such tag missing
keeps all its entries: the run rebuilds the release, as any automatic run
does. Alpine is experimental and never makes a release missing. The latest-*
tags are not checked: when every image was promoted and they did not move, a
consumer failed the downstream canary, and the issue the `canary` job opened
for it is the signal; rebuilding the images would not fix the consumer.
--summary FILE appends what was found, per release, to FILE (the step summary).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

UPSTREAM = "https://gitlab.com/nsnam/ns-3-dev.git"
SUITES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test", "ns3-suites.txt")
STAGES = ["labels", "security", "structure", "profile", "smoke", "integration", "unit"]
# Which unit group a profile runs (test/unit.sh's default, without UNIT_SET).
PROFILE_GROUP = {"debug": "full", "sanitized": "full", "default": "light", "optimized": "light"}
IMAGE = "ghcr.io/swarm-routing/ns3-dev"

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
# (os, profile) of the images that stand for their kind on a pull request
# that changes only test stages (tools/pr_tests.py). Every base and every
# profile of the supported release's plan has one (test_ns3_matrix.py).
REPRESENTATIVES = {("ubuntu", "debug"), ("ubuntu", "sanitized"), ("ubuntu", "optimized"),
                   ("debian", "debug"), ("slim", "default"), ("alpine", "debug")}

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


def releases(versions):
    """All upstream releases, newest first, as (minor_str, full) pairs."""
    return [(f"3.{m}", versions[m]) for m in sorted(versions, reverse=True)]


def tags_for(minor, full, os_, profile, newest, sha7):
    """(versioned + pinned tags, latest tags) of one image."""
    labels = [minor] + ([full] if full != minor else [])
    tags = []
    for label in labels:
        stem = label if os_ == "ubuntu" else f"{label}-{os_}"
        tags.append(f"{stem}-{profile}")
        if profile == "default":
            tags.append(stem)
    pinned = [f"{t}-{sha7}" for t in tags] if sha7 else []
    latest = []
    if newest:
        stem = "latest" if os_ == "ubuntu" else f"latest-{os_}"
        latest = [f"{stem}-{profile}"] + ([stem] if profile == "default" else [])
    return tags + pinned, latest


def plan_for(supported):
    """(os, profile) pairs: the full set for the supported release, else on-demand."""
    if not supported:
        return [("ubuntu", p) for p in LIGHT]
    return ([("ubuntu", p) for p in FULL]
            + [(os_, p) for os_ in ("debian", "slim") for p in LIGHT]
            + [("alpine", "debug")])


def entries(chosen, newest_full, sha7="", splits=None):
    splits = read_suites()[1] if splits is None else splits
    out = []
    for minor, full in chosen:
        newest = full == newest_full
        for os_, profile in plan_for(newest):
            tags, latest = tags_for(minor, full, os_, profile, newest, sha7)
            out.append({
                "version": full,
                "minor": minor,
                "os": os_,
                "profile": profile,
                "base_image": BASES[os_],
                "experimental": os_ == "alpine",
                "name": f"{minor}-{os_}-{profile}" if os_ != "ubuntu" else f"{minor}-{profile}",
                "cache": f"{minor}-{os_}-{profile}",
                "tags": " ".join(tags),
                "latest_tags": " ".join(latest),
                "pr_unit_set": "" if os_ == "ubuntu" else "light",
                "representative": (os_, profile) in REPRESENTATIVES,
                "test_parts": test_parts(profile, splits),
            })
    return out


def read_suites(path=SUITES):
    """test/ns3-suites.txt -> (groups {g: [mod]}, splits {profile: N}, shards {(g, N): {i: [mod]}})."""
    groups, splits, shards = {}, {}, {}
    with open(path) as f:
        for raw in f:
            w = raw.split("#", 1)[0].split()
            if not w:
                continue
            if w[0] == "split":
                splits[w[1]] = int(w[2])
            elif w[0] == "shard":
                i, n = (int(x) for x in w[2].split("/"))
                shards.setdefault((w[1], n), {})[i] = w[3:]
            elif w[0] == "main-only":
                continue  # suites deferred to main on PRs (test/unit.sh), not a group
            else:
                groups[w[0]] = w[1:]
    return groups, splits, shards


def check_suites(path=SUITES):
    """Problems in test/ns3-suites.txt, as strings (empty: valid)."""
    groups, splits, shards = read_suites(path)
    errs = []
    with open(path) as f:
        if any(raw.split("#", 1)[0].split() == ["main-only"] for raw in f):
            errs.append("a main-only line names no suite")
    for profile, n in sorted(splits.items()):
        g = PROFILE_GROUP.get(profile)
        if g not in groups:
            errs.append(f"split {profile} {n}: no '{g}' group")
            continue
        if n < 1:
            errs.append(f"split {profile} {n}: N must be 1 or more")
            continue
        if n == 1:
            continue  # the whole group in one job: nothing to cover
        got = shards.get((g, n), {})
        if sorted(got) != list(range(1, n + 1)):
            errs.append(f"split {profile} {n}: '{g}' needs shards 1..{n}, has {sorted(got) or 'none'}")
        listed = [mod for i in sorted(got) for mod in got[i]]
        missing = sorted(set(groups[g]) - set(listed))
        extra = sorted(set(listed) - set(groups[g]))
        twice = sorted({mod for mod in listed if listed.count(mod) > 1})
        for what, mods in (("missing", missing), ("not in the group", extra), ("in two shards", twice)):
            if mods:
                errs.append(f"'{g}' shards of {n}: {what}: {' '.join(mods)}")
    for (g, n) in sorted(shards):
        if g not in groups or n not in {splits[p] for p in splits if PROFILE_GROUP.get(p) == g}:
            errs.append(f"shard lines for '{g}' of {n} that no split line uses")
    return errs


def test_parts(profile, splits):
    """The test jobs of one image: everything in one job, or a base job plus the unit stage in N parts."""
    n = splits.get(profile, 0)
    if n < 1:
        return [{"part": "all", "stages": "", "unit_shard": ""}]
    base = {"part": "base", "stages": ",".join(s for s in STAGES if s != "unit"), "unit_shard": ""}
    if n == 1:
        return [base, {"part": "unit", "stages": "unit", "unit_shard": ""}]
    return [base] + [{"part": f"unit-{i}-of-{n}", "stages": "unit", "unit_shard": f"{i}/{n}"}
                     for i in range(1, n + 1)]


def test_matrix(images):
    """The `test` job's matrix: one entry per (image, part), named for the job list."""
    out = []
    for e in images:
        for p in e["test_parts"]:
            label = {"all": "", "base": " (every stage but unit)", "unit": " (unit)"}.get(
                p["part"], f" (unit {p['unit_shard']})")
            out.append({**{k: v for k, v in e.items() if k != "test_parts"}, **p, "test_name": e["name"] + label})
    return out


def own_tag(e):
    """The versioned tag only this entry's image gets, under the release's full number."""
    stem = e["version"] if e["os"] == "ubuntu" else f"{e['version']}-{e['os']}"
    return f"{stem}-{e['profile']}"


def missing_only(matrix, is_published):
    """(the entries of the releases not published in full, {version: its missing required tags})."""
    missing = {}
    for e in matrix:
        tags = missing.setdefault(e["version"], [])
        if not e["experimental"] and not is_published(own_tag(e)):
            tags.append(own_tag(e))
    return [e for e in matrix if missing[e["version"]]], missing


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
    ap.add_argument("--versions",
                    help="on demand: comma-separated ns-3 releases, minor or full (e.g. 3.36,3.46.1); "
                         "default: the supported (latest) release only")
    ap.add_argument("--sha", default="", help="commit SHA for the immutable -<sha7> tags")
    ap.add_argument("--tier", choices=["latest"],
                    help="latest: only the supported release's entries (an OS security refresh); "
                         "with --versions, refuse any other release")
    ap.add_argument("--missing-only", action="store_true",
                    help="drop the releases whose required images are all published")
    ap.add_argument("--image", default=IMAGE)
    ap.add_argument("--summary", help="with --missing-only: append what was found to this file")
    ap.add_argument("--check-suites", action="store_true",
                    help="only validate test/ns3-suites.txt (the unit shards cover each split group exactly)")
    args = ap.parse_args(argv)

    if args.check_suites:
        errs = check_suites()
        for e in errs:
            print(f"ns3_matrix: test/ns3-suites.txt: {e}", file=sys.stderr)
        sys.exit(1 if errs else 0)
    errs = check_suites()
    if errs:
        sys.exit("ns3_matrix: test/ns3-suites.txt: " + "; ".join(errs))

    if args.tags_file:
        with open(args.tags_file) as f:
            lines = f.readlines()
    else:
        lines = subprocess.run(["git", "ls-remote", "--tags", UPSTREAM, "ns-3.*"],
                               check=True, capture_output=True, text=True).stdout.splitlines()
    rel = releases(parse_tags(lines))
    if not rel:
        sys.exit("ns3_matrix: no ns-3 releases found upstream")
    newest_full = rel[0][1]
    if args.versions:
        want = {v.strip() for v in args.versions.split(",") if v.strip()}
        chosen = [(m, f) for m, f in rel if m in want or f in want]
        unknown = want - {m for m, _ in chosen} - {f for _, f in chosen}
        if unknown:
            sys.exit(f"ns3_matrix: not an upstream ns-3 release: {', '.join(sorted(unknown))}")
    else:
        chosen = rel[:1]
    if args.tier == "latest":
        older = [f for _, f in chosen if f != newest_full]
        if older:
            sys.exit(f"ns3_matrix: --tier latest refreshes the supported release ({newest_full}) only, "
                     f"not {', '.join(older)}: rebuild an older release on demand without it")
        chosen = [(m, f) for m, f in chosen if f == newest_full]
    matrix = entries(chosen, newest_full, args.sha[:7])
    if args.missing_only:
        matrix, missing = missing_only(matrix, lambda tag: published(args.image, tag))
        lines = [f"{v}: rebuilt, required images not published: " + ", ".join(f"`{t}`" for t in tags) if tags
                 else f"{v}: every required image is published, nothing to build"
                 for v, tags in missing.items()]
        print("\n".join(f"ns3_matrix: {line}" for line in lines), file=sys.stderr)
        if args.summary:
            with open(args.summary, "a") as f:
                f.write("".join(f"{line}\n" for line in lines))
    json.dump({"include": matrix}, sys.stdout, separators=(",", ":"))
    print()
    print(f"ns3_matrix: {len(matrix)} images: "
          + ", ".join(sorted({e['version'] for e in matrix}, key=lambda v: [int(x) for x in v.split('.')])),
          file=sys.stderr)


if __name__ == "__main__":
    main()
