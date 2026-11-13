# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Tests for cache_tags.py: python3 -m unittest discover -s tools"""

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import cache_tags as c  # noqa: E402
import ns3_matrix as m  # noqa: E402

# The anonymous tag list of ghcr.io/swarm-routing/ns3-dev-cache on 2026-11-13,
# as ns3-containers#146 records it: 9 scopes of 3.49, 30 of 3.40 to 3.48.
ISSUE_146 = [
    "3.45-ubuntu-debug", "3.41-ubuntu-default", "3.49-ubuntu-optimized", "3.49-ubuntu-default",
    "3.45-ubuntu-default", "3.49-alpine-debug", "3.49-ubuntu-sanitized", "3.47-debian-debug",
    "3.49-debian-debug", "3.49-slim-debug", "3.48-ubuntu-default", "3.48-debian-default",
    "3.49-debian-default", "3.42-ubuntu-debug", "3.40-ubuntu-debug", "3.46-ubuntu-default",
    "3.47-ubuntu-optimized", "3.41-ubuntu-debug", "3.44-ubuntu-default", "3.49-ubuntu-debug",
    "3.40-ubuntu-default", "3.44-ubuntu-debug", "3.43-ubuntu-debug", "3.47-ubuntu-default",
    "3.43-ubuntu-default", "3.47-ubuntu-debug", "3.48-ubuntu-debug", "3.48-debian-debug",
    "3.48-slim-default", "3.48-ubuntu-sanitized", "3.42-ubuntu-default", "3.47-debian-default",
    "3.48-slim-debug", "3.48-ubuntu-optimized", "3.46-ubuntu-debug", "3.47-slim-debug",
    "3.49-slim-default", "3.47-slim-default", "3.47-ubuntu-sanitized",
]

# git ls-remote shape: 3.49 is the newest release (an RC is not a release).
LS_REMOTE = [f"x\trefs/tags/ns-3.{n}" for n in range(36, 50)] + [
    "y\trefs/tags/ns-3.46.1", "z\trefs/tags/ns-3.50-RC1"]


class Select(unittest.TestCase):
    def test_issue_146_keeps_the_supported_release_and_deletes_the_rest(self):
        keep, delete, unparsed, newer = c.select(ISSUE_146, "3.49")
        self.assertEqual(len(keep), 9)
        self.assertEqual(len(delete), 30)
        self.assertEqual(unparsed, [])
        self.assertEqual(newer, [])
        self.assertTrue(all(t.startswith("3.49-") for t in keep))
        self.assertIn("3.49-alpine-debug", keep)
        self.assertFalse(any(t.startswith("3.49-") for t in delete))
        self.assertEqual(sorted(keep + delete), sorted(ISSUE_146))

    def test_the_cache_scopes_of_the_supported_plan_are_all_kept(self):
        # What publish-images.yml writes for the supported release (`cache`).
        scopes = [e["cache"] for e in m.entries([("3.49", "3.49")], "3.49", splits={})]
        self.assertEqual(c.select(scopes, "3.49"), (scopes, [], [], []))

    def test_the_next_release_leaves_the_previous_set_behind(self):
        tags = ISSUE_146 + ["3.50-ubuntu-debug"]
        keep, delete, _, _ = c.select(tags, "3.50")
        self.assertEqual(keep, ["3.50-ubuntu-debug"])
        self.assertEqual(len(delete), 39)

    def test_a_tag_that_does_not_parse_is_kept_and_reported(self):
        odd = ["latest", "3.48", "3.48-ubuntu", "3.48-ubuntu-debug-abc1234", "3.48.1-ubuntu-debug",
               "3.48-fedora-debug", "3.48-ubuntu-fast", "v3.48-ubuntu-debug", "3.48-ubuntu-debug ", ""]
        keep, delete, unparsed, newer = c.select(odd + ["3.49-ubuntu-debug", "3.48-ubuntu-debug"], "3.49")
        self.assertEqual(unparsed, odd)
        self.assertEqual(delete, ["3.48-ubuntu-debug"])
        self.assertEqual(keep, ["3.49-ubuntu-debug"])
        self.assertEqual(newer, [])

    def test_a_release_newer_than_the_supported_one_is_kept_and_reported(self):
        # A truncated upstream tag list must not make the real newest release "old".
        keep, delete, unparsed, newer = c.select(["3.50-ubuntu-debug", "3.49-ubuntu-debug", "3.9-ubuntu-debug"], "3.49")
        self.assertEqual((keep, delete, unparsed, newer),
                         (["3.49-ubuntu-debug"], ["3.9-ubuntu-debug"], [], ["3.50-ubuntu-debug"]))

    def test_versions_compare_as_numbers(self):
        _, delete, _, newer = c.select(["3.100-ubuntu-debug", "4.0-ubuntu-debug", "3.5-ubuntu-debug"], "3.49")
        self.assertEqual(delete, ["3.5-ubuntu-debug"])
        self.assertEqual(newer, ["3.100-ubuntu-debug", "4.0-ubuntu-debug"])

    def test_an_unusable_supported_release_is_refused(self):
        for bad in ("", "latest", "3.49.1", None):
            with self.assertRaises(ValueError):
                c.select(ISSUE_146, bad)


def versions(tags_per_version, first_id=100):
    return [{"id": first_id + i, "tags": tags} for i, tags in enumerate(tags_per_version)]


class Plan(unittest.TestCase):
    def test_one_version_per_tag(self):
        p = c.plan(versions([[t] for t in ISSUE_146]), "3.49")
        self.assertEqual(p["refused"], "")
        self.assertEqual(len(p["delete"]), 30)
        self.assertEqual(len(p["keep"]), 9)
        ids = {v["id"] for v in p["delete"]}
        self.assertEqual(ids, {100 + i for i, t in enumerate(ISSUE_146) if not t.startswith("3.49-")})

    def test_a_version_is_deleted_only_when_every_tag_of_it_is_selected(self):
        p = c.plan(versions([["3.48-ubuntu-debug", "3.49-ubuntu-debug"], ["3.47-ubuntu-debug", "keep-me"],
                             ["3.47-slim-debug", "3.46-ubuntu-debug"], ["3.49-slim-debug"]]), "3.49")
        self.assertEqual([v["id"] for v in p["delete"]], [102])
        self.assertEqual([v["id"] for v in p["keep"]], [100, 101, 103])
        self.assertEqual(p["unparsed"], ["keep-me"])

    def test_untagged_versions_are_not_this_step_s(self):
        p = c.plan(versions([[], ["3.49-ubuntu-debug"], ["3.48-ubuntu-debug"]]), "3.49")
        self.assertEqual([v["id"] for v in p["delete"]], [102])
        self.assertEqual([v["id"] for v in p["keep"]], [101])

    def test_nothing_is_deleted_when_the_supported_release_has_no_scope(self):
        # Every parsed tag would go (a new upstream release not built yet, or a
        # wrong supported release): refuse, delete nothing.
        old = [[t] for t in ISSUE_146 if not t.startswith("3.49-")]
        for extra in ([], [["not-a-scope"]]):
            p = c.plan(versions(old + extra), "3.49")
            self.assertEqual(p["delete"], [])
            self.assertIn("no scope of the supported release 3.49", p["refused"])
            self.assertEqual(len(p["keep"]), len(old) + len(extra))
        p = c.plan(versions([[t] for t in ISSUE_146]), "3.50")
        self.assertEqual(p["delete"], [])
        self.assertTrue(p["refused"])

    def test_nothing_is_deleted_when_the_supported_release_is_unknown(self):
        for bad in ("", None, "3.49.1"):
            p = c.plan(versions([[t] for t in ISSUE_146]), bad)
            self.assertEqual(p["delete"], [])
            self.assertEqual(len(p["keep"]), 39)
            self.assertIn("supported release", p["refused"])

    def test_nothing_to_do_is_not_a_refusal(self):
        p = c.plan(versions([[t] for t in ISSUE_146 if t.startswith("3.49-")]), "3.49")
        self.assertEqual((p["delete"], p["refused"]), ([], ""))
        p = c.plan([], "3.49")
        self.assertEqual((p["delete"], p["keep"], p["refused"]), ([], [], ""))


class Supported(unittest.TestCase):
    def test_read_as_ns3_matrix_reads_it(self):
        self.assertEqual(c.supported_release(LS_REMOTE), "3.49")
        self.assertEqual(c.supported_release(LS_REMOTE), m.releases(m.parse_tags(LS_REMOTE))[0][0])
        self.assertEqual(c.supported_release(["x\trefs/tags/ns-3.46", "y\trefs/tags/ns-3.46.1"]), "3.46")

    def test_no_release_is_none(self):
        self.assertIsNone(c.supported_release([]))
        self.assertIsNone(c.supported_release(["x\trefs/tags/ns-3.50-RC1"]))


def run(version_rows, tags=LS_REMOTE):
    """main() on a listing; tags=None reads upstream (git ls-remote), as the workflow does."""
    with tempfile.TemporaryDirectory() as d:
        vf, tf, sf = (os.path.join(d, n) for n in ("versions", "tags", "summary"))
        with open(vf, "w") as f:
            f.write("".join(json.dumps(r) + "\n" for r in version_rows))
        with open(tf, "w") as f:
            f.write("\n".join(tags or []))
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = c.main(["--versions-file", vf, "--summary", sf, *([] if tags is None else ["--tags-file", tf])])
        with open(sf) as f:
            return rc, out.getvalue(), f.read(), err.getvalue()


class Cli(unittest.TestCase):
    def test_prints_one_line_per_version_to_delete_and_summarises(self):
        rc, out, summary, _ = run(versions([[t] for t in ISSUE_146]))
        self.assertEqual(rc, 0)
        lines = out.splitlines()
        self.assertEqual(len(lines), 30)
        for line in lines:
            vid, tag = line.split(" ")
            self.assertEqual(ISSUE_146[int(vid) - 100], tag)
            self.assertFalse(tag.startswith("3.49-"))
        self.assertIn("supported release: 3.49", summary)
        self.assertIn("kept 9", summary)
        self.assertIn("`3.49-alpine-debug`", summary)
        self.assertIn("to delete: 30", summary)

    def test_an_unparsed_tag_is_named_in_the_summary(self):
        rc, out, summary, _ = run(versions([["3.49-ubuntu-debug"], ["3.48-ubuntu-debug"], ["what-is-this"]]))
        self.assertEqual((rc, out), (0, "101 3.48-ubuntu-debug\n"))
        self.assertIn("not `<ver>-<base>-<profile>`, kept: `what-is-this`", summary)

    def test_no_upstream_release_deletes_nothing_and_says_so(self):
        rc, out, summary, err = run(versions([[t] for t in ISSUE_146]), tags=["x\trefs/tags/ns-3.50-RC1"])
        self.assertEqual((rc, out), (0, ""))
        self.assertIn("nothing deleted", summary)
        self.assertIn("supported release", summary)
        self.assertIn("::warning::", err)

    def test_an_unreachable_upstream_deletes_nothing_and_says_so(self):
        boom = subprocess.CalledProcessError(128, "git", stderr="fatal: unable to access")
        with mock.patch.object(c.ns3_matrix.subprocess, "run", side_effect=boom):
            rc, out, summary, _ = run(versions([[t] for t in ISSUE_146]), tags=None)
        self.assertEqual((rc, out), (0, ""))
        self.assertIn("nothing deleted", summary)
        self.assertIn("supported release", summary)

    def test_no_supported_scope_deletes_nothing_and_says_so(self):
        rc, out, summary, _ = run(versions([[t] for t in ISSUE_146 if not t.startswith("3.49-")]))
        self.assertEqual((rc, out), (0, ""))
        self.assertIn("nothing deleted: no scope of the supported release 3.49", summary)

    def test_a_malformed_listing_fails_and_deletes_nothing(self):
        for rows in ([{"id": 1}], [{"tags": ["3.48-ubuntu-debug"]}], [{"id": "1; rm", "tags": ["3.48-ubuntu-debug"]}],
                     [{"id": 1, "tags": "3.48-ubuntu-debug"}]):
            with self.assertRaises(SystemExit) as cm:
                run(rows + versions([["3.49-ubuntu-debug"]]))
            self.assertNotIn(cm.exception.code, (0, None))


if __name__ == "__main__":
    unittest.main()
