#!/usr/bin/env python3
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Pick the test jobs a pull request's images need (ns3-containers#86, #87).

    tools/pr_tests.py refs --matrix JSON --digests DIR --candidate REF --image REF
    tools/pr_tests.py select --matrix JSON --inspect DIR [--summary FILE]
    tools/pr_tests.py decide --entry JSON --candidate FILE --reference FILE

On a pull request, publish-images.yml builds every image (mostly buildx cache
hits) and then asks, per image, whether its tests can tell anything new:

  * Its content equals the image `main` last tested and promoted: the one its
    first versioned tag (e.g. 3.49-debug) points to, which promote moves only
    after every test job of that image passed on main (latest-* waits for
    the whole run, so it can lag one image's promotion). The digests themselves always differ: each
    build stamps its commit and run into two labels (revision, build-run;
    #52). So the comparison is the image's content: its layers (rootfs
    diff_ids), its platform and its config (env, cmd, workdir, the other
    labels...) without those two labels.
  * And no test input changed since the commit that reference was tested at
    (its revision label), up to this run's HEAD: the files under test/, the
    test wiring (tools/ns3_matrix.py, tools/pass_markers.py, this file,
    publish-images.yml) and .trivyignore. The diff runs from that commit, not
    from the PR's base, so a test change merged to main after the reference
    was promoted counts too.

Content equal, no test input changed: the image is not tested again ("unchanged
digest, already tested on main"). Content equal, some stages' inputs changed:
those stages (plus `labels`, beside them) run on the image only if it is a
`representative` (tools/ns3_matrix.py), the others are skipped. Content
different, no reference, an unreadable reference or a revision git cannot
diff from: every test job of the image runs, as before. A file under test/
this table does not know reruns every stage (fail closed).

Only pull requests use this. Pushes to main, schedule and dispatch runs test
every image with every stage, and only main promotes, so what is tagged is
still what was tested (golden rule 17).

`refs` prints `<name> candidate <ref>` and `<name> reference <ref>` lines for
the workflow to inspect (`docker buildx imagetools inspect --format
'{{json .Image}}'`) into <DIR>/<name>.candidate.json and
<DIR>/<name>.reference.json; an image whose build left no digest gets no
candidate line. `select` reads those files and prints the test job matrix,
{"include": [...]}, as tools/ns3_matrix.py's test_matrix() builds it, with
one summary line per image. `decide` is the same decision for one image (a
fork PR, whose build job tests in place): it prints {"run": bool, "stages":
"a,b" (empty: every stage), "reason": "..."}.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns3_matrix  # noqa: E402

STAGES = ns3_matrix.STAGES
ALL = tuple(STAGES)
# The two labels that differ on every build of the same content.
PER_BUILD_LABELS = {"org.opencontainers.image.revision", "io.github.swarm-routing.build-run"}
CONFIG_KEYS = ("Env", "Cmd", "Entrypoint", "WorkingDir", "User", "ExposedPorts", "Volumes", "StopSignal")

# Changed file -> the stages it feeds. First match wins; a path under test/
# that matches nothing reruns every stage. Anything else (docker/, the
# matrix's own tests, docs) is not a test input: what it changes in an image
# shows in the image's content.
TEST_INPUTS = [
    (r"test/run\.sh", ALL),
    (r"test/structure\.sh", ("structure",)),
    (r"test/(profile\.sh|fixtures/profile-probe/.*)", ("profile",)),
    (r"test/(smoke\.sh|fixtures/swarm-hello/.*)", ("smoke",)),
    (r"test/(integration\.sh|fixtures/manet-canary/.*)", ("integration",)),
    (r"test/(unit\.sh|ns3-suites\.txt)", ("unit",)),
    (r"test/known-failures\.txt", ("integration", "unit")),
    (r"\.trivyignore", ("security",)),
    (r"tools/(ns3_matrix|pass_markers|pr_tests)\.py", ALL),
    (r"\.github/workflows/publish-images\.yml", ALL),
    (r"test/.*", ALL),
]


def stages_for(files):
    """The stages (in run order) whose inputs are among `files`."""
    hit = set()
    for f in files:
        for pattern, stages in TEST_INPUTS:
            if re.fullmatch(pattern, f):
                hit.update(stages)
                break
    return [s for s in STAGES if s in hit]


def _blank(v):
    return None if v in (None, "", [], {}) else v


def content(inspect):
    """An image's content, from `imagetools inspect --format '{{json .Image}}'` (OCI)
    or `docker image inspect` (Docker): what two builds of the same inputs share."""
    if isinstance(inspect, list):  # docker image inspect
        (img,) = inspect
        cfg, layers = img.get("Config") or {}, (img.get("RootFS") or {}).get("Layers") or []
        os_, arch = img.get("Os"), img.get("Architecture")
    else:
        img = inspect
        if "rootfs" not in img:  # one entry per platform
            img = img.get("linux/amd64") or next(v for v in img.values() if "rootfs" in v)
        cfg, layers = img.get("config") or {}, img["rootfs"].get("diff_ids") or []
        os_, arch = img.get("os"), img.get("architecture")
    if not layers:
        raise ValueError("no layers in the inspect output")
    labels = {k: v for k, v in (cfg.get("Labels") or {}).items() if k not in PER_BUILD_LABELS}
    return {"os": os_, "architecture": arch, "layers": list(layers),
            "config": {**{k: _blank(cfg.get(k)) for k in CONFIG_KEYS}, "Labels": labels}}


def fingerprint(inspect):
    return hashlib.sha256(json.dumps(content(inspect), sort_keys=True).encode()).hexdigest()


def revision(inspect):
    """The commit a reference image was built (and tested) at, from its label."""
    img = inspect[0] if isinstance(inspect, list) else inspect
    if isinstance(img, dict) and "rootfs" not in img and "Config" not in img:
        img = img.get("linux/amd64") or next(v for v in img.values() if "rootfs" in v)
    cfg = img.get("Config") or img.get("config") or {}
    return (cfg.get("Labels") or {}).get("org.opencontainers.image.revision", "")


def git_changed(rev, head="HEAD"):
    """Files changed from `rev` to `head`, or None when git cannot tell."""
    if not re.fullmatch(r"[0-9a-f]{7,40}", rev or ""):
        return None
    r = subprocess.run(["git", "diff", "--name-only", "--no-renames", rev, head],
                       capture_output=True, text=True)
    return r.stdout.split() if r.returncode == 0 else None


def plan(entry, candidate, reference, changed=None):
    """(test parts to run, reason) for one image; no parts means skip it."""
    changed = changed or git_changed
    full = entry["test_parts"]
    if candidate is None:
        return full, "no candidate digest: every test job"
    if reference is None:
        return full, "nothing on main to compare with: every test job"
    try:
        same = fingerprint(candidate) == fingerprint(reference)
    except (ValueError, KeyError, StopIteration, TypeError, AttributeError) as e:
        return full, f"cannot compare with main ({e}): every test job"
    if not same:
        return full, "content differs from what main tested: every test job"
    try:
        rev = revision(reference)
    except (StopIteration, AttributeError):
        rev = ""
    files = changed(rev)
    if files is None:
        return full, f"cannot diff from main's tested revision '{rev[:7]}': every test job"
    stages = stages_for(files)
    tested = f"main tested it at {rev[:7]}"
    if not stages:
        return [], f"unchanged digest, already tested on main ({tested}; no test input changed since)"
    if not entry.get("representative"):
        return [], (f"unchanged digest, already tested on main ({tested}); the changed stages "
                    f"({','.join(stages)}) run on the representative images")
    parts = []
    for p in full:
        have = p["stages"].split(",") if p["stages"] else list(STAGES)
        run = [s for s in have if s in stages]
        if not run:
            continue
        if "labels" in have and "labels" not in run:
            run.insert(0, "labels")
        parts.append({**p, "stages": ",".join(run)})
    return parts, f"unchanged digest ({tested}); test inputs changed: stages {','.join(stages)} (representative)"


def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _digest(root, name, count):
    """The digest the build recorded: <root>/digest-<name>/digest, or <root>/digest
    when the run built one image (download-artifact unpacks a single match flat)."""
    for path in [os.path.join(root, f"digest-{name}", "digest")] + (
            [os.path.join(root, "digest")] if count == 1 else []):
        try:
            with open(path) as f:
                d = f.read().strip()
        except OSError:
            continue
        if re.fullmatch(r"sha256:[0-9a-f]{64}", d):
            return d
    return None


def refs(images, digests, candidate, image):
    out = []
    for e in images:
        d = _digest(digests, e["name"], len(images))
        if d:
            out.append(f"{e['name']} candidate {candidate}@{d}")
        tags = e["tags"].split()
        if tags:
            out.append(f"{e['name']} reference {image}:{tags[0]}")
    return out


def select(images, inspect_dir, changed=None):
    """(test matrix entries, summary lines) for a pull request's images."""
    chosen, lines = [], []
    for e in images:
        cand = _load(os.path.join(inspect_dir, f"{e['name']}.candidate.json"))
        ref = _load(os.path.join(inspect_dir, f"{e['name']}.reference.json"))
        parts, why = plan(e, cand, ref, changed)
        jobs = len(parts)
        lines.append(f"| {e['name']} | {f'{jobs} job(s)' if jobs else 'skipped'} | {why} |")
        if parts:
            chosen.append({**e, "test_parts": parts})
    return ns3_matrix.test_matrix(chosen), lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("refs")
    r.add_argument("--matrix", required=True)
    r.add_argument("--digests", required=True)
    r.add_argument("--candidate", required=True)
    r.add_argument("--image", required=True)
    s = sub.add_parser("select")
    s.add_argument("--matrix", required=True)
    s.add_argument("--inspect", required=True)
    s.add_argument("--summary", default=os.devnull)
    d = sub.add_parser("decide")
    d.add_argument("--entry", required=True)
    d.add_argument("--candidate", required=True)
    d.add_argument("--reference", required=True)
    a = ap.parse_args(argv)

    if a.cmd == "refs":
        print("\n".join(refs(json.loads(a.matrix)["include"], a.digests, a.candidate, a.image)))
    elif a.cmd == "select":
        tests, lines = select(json.loads(a.matrix)["include"], a.inspect)
        with open(a.summary, "a") as f:
            f.write("### Tests this pull request needs (tools/pr_tests.py)\n\n"
                    "| Image | Tests | Why |\n|---|---|---|\n" + "\n".join(lines) + "\n")
        json.dump({"include": tests}, sys.stdout, separators=(",", ":"))
        print()
    else:
        entry = json.loads(a.entry)
        parts, why = plan(entry, _load(a.candidate), _load(a.reference))
        stages = {s for p in parts for s in (p["stages"].split(",") if p["stages"] else STAGES)}
        everything = parts == entry["test_parts"] or stages == set(STAGES)
        json.dump({"run": bool(parts), "stages": "" if everything else ",".join(x for x in STAGES if x in stages),
                   "reason": why}, sys.stdout)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
