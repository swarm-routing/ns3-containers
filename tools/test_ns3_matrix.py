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


class Window(unittest.TestCase):
    def test_top_ten_newest_patch(self):
        win = m.window(m.parse_tags(LS_REMOTE))
        self.assertEqual([f for _, f in win],
                         ["3.49", "3.48", "3.47", "3.46.1", "3.45", "3.44", "3.43", "3.42", "3.41", "3.40"])
        self.assertIn(("3.46", "3.46.1"), win)

    def test_rc_and_dev_tags_ignored(self):
        self.assertNotIn(50, m.parse_tags(LS_REMOTE))

    def test_new_release_shifts_window_and_tiers(self):
        mx = run(LS_REMOTE + ["ttt\trefs/tags/ns-3.50"])
        versions = sorted({e["minor"] for e in mx}, key=lambda v: int(v.split(".")[1]))
        self.assertEqual(versions[0], "3.41")
        self.assertEqual(versions[-1], "3.50")
        full = {e["minor"] for e in mx if e["profile"] == "sanitized"}
        self.assertEqual(full, {"3.48", "3.49", "3.50"})


class Matrix(unittest.TestCase):
    def setUp(self):
        self.mx = run(LS_REMOTE, "--sha", "290685fdeadbeef")

    def test_size_and_tiers(self):
        # 3 x (4 ubuntu + 2 debian + 2 slim) + 7 x 2 ubuntu + 1 alpine
        self.assertEqual(len(self.mx), 24 + 14 + 1)
        rest = [e for e in self.mx if e["minor"] == "3.43"]
        self.assertEqual({(e["os"], e["profile"]) for e in rest},
                         {("ubuntu", "default"), ("ubuntu", "debug")})
        alpine = [e for e in self.mx if e["os"] == "alpine"]
        self.assertEqual([(e["minor"], e["profile"], e["experimental"]) for e in alpine],
                         [("3.49", "debug", True)])
        self.assertFalse(any(e["experimental"] for e in self.mx if e["os"] != "alpine"))

    def test_no_sanitized_on_alpine_or_optimized_outside_ubuntu(self):
        for e in self.mx:
            if e["profile"] in ("sanitized", "optimized"):
                self.assertEqual(e["os"], "ubuntu")

    def test_tags(self):
        def tags(minor, os_, profile):
            (e,) = [e for e in self.mx if (e["minor"], e["os"], e["profile"]) == (minor, os_, profile)]
            return e["tags"].split()
        self.assertEqual(tags("3.49", "ubuntu", "default"),
                         ["3.49-default", "3.49", "latest", "3.49-default-290685f", "3.49-290685f"])
        self.assertEqual(tags("3.48", "ubuntu", "sanitized"), ["3.48-sanitized", "3.48-sanitized-290685f"])
        self.assertEqual(tags("3.47", "slim", "default"),
                         ["3.47-slim-default", "3.47-slim", "3.47-slim-default-290685f", "3.47-slim-290685f"])
        self.assertEqual(tags("3.46", "ubuntu", "debug"),
                         ["3.46-debug", "3.46.1-debug", "3.46-debug-290685f", "3.46.1-debug-290685f"])
        self.assertNotIn("latest", tags("3.48", "ubuntu", "default"))

    def test_entries_carry_build_inputs(self):
        (e,) = [e for e in self.mx if e["name"] == "3.46-default"]
        self.assertEqual(e["version"], "3.46.1")
        self.assertEqual(e["cache"], "3.46-ubuntu-default")
        self.assertTrue(e["base_image"].startswith("ubuntu:24.04@sha256:"))
        for e in self.mx:
            self.assertIn("@sha256:", e["base_image"])

    def test_versions_filter(self):
        mx = run(LS_REMOTE, "--versions", "3.46.1")
        self.assertEqual({e["version"] for e in mx}, {"3.46.1"})
        with self.assertRaises(SystemExit):
            run(LS_REMOTE, "--versions", "3.36")


if __name__ == "__main__":
    unittest.main()
