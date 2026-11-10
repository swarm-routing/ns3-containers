# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Tests for ns3_matrix.py: python3 -m unittest discover -s tools"""

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.dirname(__file__))
import ns3_matrix as m  # noqa: E402

# git ls-remote shape, as upstream had it on 2026-11-01 (plus noise).
LS_REMOTE = [
    "aaa\trefs/tags/ns-3.36", "bbb\trefs/tags/ns-3.36.1", "ccc\trefs/tags/ns-3.36.1^{}",
    "ddd\trefs/tags/ns-3.37", "eee\trefs/tags/ns-3.38", "fff\trefs/tags/ns-3.39",
    "ggg\trefs/tags/ns-3.40", "hhh\trefs/tags/ns-3.41", "iii\trefs/tags/ns-3.42",
    "jjj\trefs/tags/ns-3.43", "kkk\trefs/tags/ns-3.44", "lll\trefs/tags/ns-3.45",
    "mmm\trefs/tags/ns-3.46", "nnn\trefs/tags/ns-3.46.1", "ooo\trefs/tags/ns-3.47",
    "ppp\trefs/tags/ns-3.48", "qqq\trefs/tags/ns-3.49", "rrr\trefs/tags/ns-3.50-RC1",
    "sss\trefs/tags/ns-3-dev-foo",
]


def run(tags, *args):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(tags))
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            m.main(["--tags-file", f.name, *args])
    finally:
        os.unlink(f.name)
    return json.loads(out.getvalue().splitlines()[0])["include"]


class Releases(unittest.TestCase):
    def test_newest_patch_per_minor(self):
        rel = m.releases(m.parse_tags(LS_REMOTE))
        self.assertEqual(rel[0], ("3.49", "3.49"))
        self.assertIn(("3.46", "3.46.1"), rel)
        self.assertIn(("3.36", "3.36.1"), rel)

    def test_rc_and_dev_tags_ignored(self):
        self.assertNotIn(50, m.parse_tags(LS_REMOTE))


class Supported(unittest.TestCase):
    """The automatic pipelines build only the release ns-3 supports: its latest."""

    def setUp(self):
        self.mx = run(LS_REMOTE, "--sha", "290685fdeadbeef")

    def test_only_the_latest_release(self):
        self.assertEqual({e["version"] for e in self.mx}, {"3.49"})
        # 4 ubuntu + 2 debian + 2 slim + 1 alpine
        self.assertEqual(len(self.mx), 9)
        alpine = [e for e in self.mx if e["os"] == "alpine"]
        self.assertEqual([(e["profile"], e["experimental"]) for e in alpine], [("debug", True)])
        self.assertFalse(any(e["experimental"] for e in self.mx if e["os"] != "alpine"))

    def test_new_release_replaces_it(self):
        mx = run(LS_REMOTE + ["ttt\trefs/tags/ns-3.50"])
        self.assertEqual({e["version"] for e in mx}, {"3.50"})

    def test_no_sanitized_or_optimized_outside_ubuntu(self):
        for e in self.mx:
            if e["profile"] in ("sanitized", "optimized"):
                self.assertEqual(e["os"], "ubuntu")

    def test_tags(self):
        def tags(os_, profile):
            (e,) = [e for e in self.mx if (e["os"], e["profile"]) == (os_, profile)]
            return e["tags"].split(), e["latest_tags"].split()
        self.assertEqual(tags("ubuntu", "default"),
                         (["3.49-default", "3.49", "3.49-default-290685f", "3.49-290685f"],
                          ["latest-default", "latest"]))
        self.assertEqual(tags("ubuntu", "sanitized"),
                         (["3.49-sanitized", "3.49-sanitized-290685f"], ["latest-sanitized"]))
        self.assertEqual(tags("slim", "default"),
                         (["3.49-slim-default", "3.49-slim", "3.49-slim-default-290685f", "3.49-slim-290685f"],
                          ["latest-slim-default", "latest-slim"]))

    def test_entries_carry_build_inputs(self):
        for e in self.mx:
            self.assertIn("@sha256:", e["base_image"])
        (e,) = [e for e in self.mx if e["name"] == "3.49-default"]
        self.assertEqual(e["cache"], "3.49-ubuntu-default")


class OnDemand(unittest.TestCase):
    """--versions builds any upstream release by hand (ubuntu x default, debug)."""

    def test_old_release_outside_any_window(self):
        mx = run(LS_REMOTE, "--versions", "3.36", "--sha", "abcdef0")
        self.assertEqual({e["version"] for e in mx}, {"3.36.1"})
        self.assertEqual({(e["os"], e["profile"]) for e in mx},
                         {("ubuntu", "default"), ("ubuntu", "debug")})
        (d,) = [e for e in mx if e["profile"] == "debug"]
        self.assertEqual(d["tags"].split(),
                         ["3.36-debug", "3.36.1-debug", "3.36-debug-abcdef0", "3.36.1-debug-abcdef0"])
        self.assertFalse(any("latest" in e["tags"] or e["latest_tags"] for e in mx))

    def test_full_version_and_minor_both_accepted(self):
        mx = run(LS_REMOTE, "--versions", "3.46.1,3.42")
        self.assertEqual({e["version"] for e in mx}, {"3.46.1", "3.42"})

    def test_supported_release_on_demand_gets_its_full_set(self):
        self.assertEqual(len(run(LS_REMOTE, "--versions", "3.49")), 9)

    def test_unknown_version_refused(self):
        with self.assertRaises(SystemExit):
            run(LS_REMOTE, "--versions", "3.99")


class TierLatest(unittest.TestCase):
    """--tier latest: the supported release's full set only (an OS security refresh, #29)."""

    def test_same_set_as_the_automatic_pipelines(self):
        self.assertEqual(run(LS_REMOTE, "--tier", "latest", "--sha", "290685f"),
                         run(LS_REMOTE, "--sha", "290685f"))

    def test_only_supported_entries_with_latest_tags(self):
        mx = run(LS_REMOTE, "--tier", "latest")
        self.assertEqual(len(mx), 9)
        self.assertEqual({e["version"] for e in mx}, {"3.49"})
        self.assertTrue(all(e["latest_tags"] for e in mx))

    def test_supported_release_named_explicitly(self):
        # The scanner (#30) dispatches refresh with versions=<that version>.
        for v in ("3.49", "3.49,3.49"):
            mx = run(LS_REMOTE, "--tier", "latest", "--versions", v)
            self.assertEqual(len(mx), 9)

    def test_refuses_an_older_release(self):
        # Invariant 16: a refresh never rebuilds history as a side effect.
        for v in ("3.48", "3.49,3.36"):
            with self.assertRaises(SystemExit):
                run(LS_REMOTE, "--tier", "latest", "--versions", v)

    def test_unknown_tier_refused(self):
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            run(LS_REMOTE, "--tier", "all")


if __name__ == "__main__":
    unittest.main()
