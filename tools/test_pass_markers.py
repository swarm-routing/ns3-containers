# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Tests for pass_markers.py: python3 -m unittest discover -s tools"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import pass_markers as pm  # noqa: E402

PARTS = [{"part": "base"}, {"part": "unit-1-of-2"}, {"part": "unit-2-of-2"}]


class PassMarkers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def mark(self, name, part, digest="sha256:aa"):
        d = os.path.join(self.root, f"passed-{name}--{part}")
        os.makedirs(d)
        with open(os.path.join(d, "digest"), "w") as f:
            f.write(digest + "\n")

    def mark_flat(self, digest="sha256:aa"):
        # The layout of a single-match download without merge-multiple and of
        # the old upload (path: pass/digest): it names no image or part (#101).
        with open(os.path.join(self.root, "digest"), "w") as f:
            f.write(digest + "\n")

    def test_one_matching_artifact(self):
        # 3.49-default is tested in one part: the pattern matches one artifact.
        self.mark("3.49-default", "all")
        self.assertEqual(pm.digest_of(self.root, "3.49-default", [{"part": "all"}]), "sha256:aa")
        self.assertEqual(pm.main([self.root, "3.49-default", '[{"part": "all"}]']), 0)

    def test_several_matching_artifacts(self):
        self.mark("3.49-sanitized", "base")
        self.mark("3.49-sanitized", "unit")
        self.assertEqual(
            pm.digest_of(self.root, "3.49-sanitized", [{"part": "base"}, {"part": "unit"}]), "sha256:aa")

    def test_every_image_in_one_download(self):
        # The latest job downloads passed-* for every image at once.
        self.mark("3.49-debug", "all", "sha256:d1")
        self.mark("3.49-sanitized", "base", "sha256:s1")
        self.mark("3.49-sanitized", "unit", "sha256:s1")
        self.assertEqual(pm.digest_of(self.root, "3.49-debug", [{"part": "all"}]), "sha256:d1")
        self.assertEqual(
            pm.digest_of(self.root, "3.49-sanitized", [{"part": "base"}, {"part": "unit"}]), "sha256:s1")
        with self.assertRaisesRegex(ValueError, "did not pass"):
            pm.digest_of(self.root, "3.49-alpine-debug", [{"part": "all"}])

    def test_a_bare_digest_never_counts(self):
        # It could be any image's: neither a one-part image nor a split one
        # may be promoted (or get latest-*) from it.
        self.mark_flat()
        with self.assertRaisesRegex(ValueError, "did not pass"):
            pm.digest_of(self.root, "3.49-default", [{"part": "all"}])
        with self.assertRaisesRegex(ValueError, "did not pass"):
            pm.digest_of(self.root, "3.49-sanitized", [{"part": "base"}, {"part": "unit"}])
        self.assertEqual(pm.main([self.root, "3.49-default", '[{"part": "all"}]']), 1)

    def test_no_marker_at_all_blocks(self):
        with self.assertRaisesRegex(ValueError, "did not pass"):
            pm.digest_of(self.root, "3.49-default", [{"part": "all"}])
        with self.assertRaisesRegex(ValueError, "did not pass"):
            pm.digest_of(os.path.join(self.root, "missing"), "3.49-default", [{"part": "all"}])

    def test_every_part_passed(self):
        for p in PARTS:
            self.mark("3.49-sanitized", p["part"])
        self.assertEqual(pm.digest_of(self.root, "3.49-sanitized", PARTS), "sha256:aa")

    def test_one_shard_missing_blocks(self):
        self.mark("3.49-sanitized", "base")
        self.mark("3.49-sanitized", "unit-1-of-2")
        with self.assertRaisesRegex(ValueError, "unit-2-of-2"):
            pm.digest_of(self.root, "3.49-sanitized", PARTS)

    def test_different_digests_block(self):
        self.mark("3.49-sanitized", "base")
        self.mark("3.49-sanitized", "unit-1-of-2")
        self.mark("3.49-sanitized", "unit-2-of-2", "sha256:bb")
        with self.assertRaisesRegex(ValueError, "different digests"):
            pm.digest_of(self.root, "3.49-sanitized", PARTS)

    def test_another_images_markers_do_not_count(self):
        # 3.49-debug's marker must not satisfy 3.49-debian-debug, nor the reverse.
        self.mark("3.49-debug", "all")
        with self.assertRaises(ValueError):
            pm.digest_of(self.root, "3.49-debian-debug", [{"part": "all"}])
        self.assertEqual(pm.digest_of(self.root, "3.49-debug", [{"part": "all"}]), "sha256:aa")

    def test_names_that_leave_the_root_are_refused(self):
        # name and part come from argv; neither may climb out of <dir> (Sonar S8707).
        outside = os.path.join(self.root, "outside")
        os.makedirs(os.path.join(outside, "x"))
        with open(os.path.join(outside, "x", "digest"), "w") as f:
            f.write("sha256:aa\n")
        sub = os.path.join(self.root, "sub")
        os.makedirs(sub)
        for name, part in (("../outside/x", "all"), ("3.49-debug", "../../outside/x"),
                           ("3.49/debug", "all"), ("3.49-debug", ".."), ("", "all")):
            with self.assertRaisesRegex(ValueError, "did not pass"):
                pm.digest_of(sub, name, [{"part": part}])

    def test_cli_exit_codes(self):
        self.mark("3.49-debug", "all")
        self.assertEqual(pm.main([self.root, "3.49-debug", '[{"part": "all"}]']), 0)
        self.assertEqual(pm.main([self.root, "3.49-default", '[{"part": "all"}]']), 1)


WORKFLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".github", "workflows", "publish-images.yml")


def marker_downloads(text):
    """(line number, step text) of each download-artifact step whose pattern is a pass marker's."""
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith("      - ")]
    out = []
    for a, b in zip(starts, starts[1:] + [len(lines)]):
        step = "\n".join(lines[a:b])
        if "uses: actions/download-artifact@" in step and "pattern: passed-" in step:
            out.append((a + 1, step))
    return out


class WorkflowReaders(unittest.TestCase):
    """Every job that reads pass markers downloads them the way digest_of expects (#101, #147)."""

    def test_the_nested_layout_is_refused(self):
        # Several matching artifacts without merge-multiple: each is unpacked
        # into <dir>/<artifact name>/, one level too deep.
        with tempfile.TemporaryDirectory() as root:
            for part in ("base", "unit"):
                d = os.path.join(root, f"passed-3.49-debug--{part}", f"passed-3.49-debug--{part}")
                os.makedirs(d)
                with open(os.path.join(d, "digest"), "w") as f:
                    f.write("sha256:aa\n")
            with self.assertRaisesRegex(ValueError, "did not pass"):
                pm.digest_of(root, "3.49-debug", [{"part": "base"}, {"part": "unit"}])

    def test_every_marker_download_merges(self):
        with open(WORKFLOW) as f:
            steps = marker_downloads(f.read())
        # promote, canary and latest read the markers.
        self.assertEqual(len(steps), 3, [line for line, _ in steps])
        for line, step in steps:
            self.assertRegex(step, r"(?m)^\s+merge-multiple: true$",
                             f"publish-images.yml line {line}: a passed-* download without merge-multiple: true")

    def test_the_parser_sees_a_missing_merge(self):
        text = "\n".join([
            "    steps:",
            "      - uses: actions/download-artifact@abc # v8",
            "        with:",
            "          pattern: passed-${{ matrix.name }}--*",
            "          path: pass",
            "      - uses: actions/download-artifact@abc # v8",
            "        with:",
            "          pattern: digest-*",
            "      - name: next",
            "        run: 'true'"])
        steps = marker_downloads(text)
        self.assertEqual([line for line, _ in steps], [2])
        self.assertNotIn("merge-multiple", steps[0][1])


if __name__ == "__main__":
    unittest.main()
