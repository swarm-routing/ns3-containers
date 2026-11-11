# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
"""Tests for pr_tests.py: python3 -m unittest discover -s tools"""

import copy
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(__file__))
import ns3_matrix as m  # noqa: E402
import pr_tests as pt  # noqa: E402

REV = "b84689c" + "0" * 33
SPLITS = {"sanitized": 1}


def oci(rev=REV, run="42866856191-1", layers=("sha256:aa", "sha256:bb"), env=("NS3_VERSION=3.49",)):
    """`docker buildx imagetools inspect --format '{{json .Image}}'` of one image."""
    return {"created": "2026-11-10T16:42:13Z", "architecture": "amd64", "os": "linux",
            "config": {"Env": list(env), "Cmd": ["bash"], "WorkingDir": "/opt/ns-3",
                       "Labels": {"org.opencontainers.image.revision": rev,
                                  "io.github.swarm-routing.build-run": run,
                                  "io.github.swarm-routing.ns3.profile": "debug"}},
            "rootfs": {"type": "layers", "diff_ids": list(layers)},
            "history": [{"created": "2026-11-10T16:00:00Z"}]}


def docker(img):
    """The same image as `docker image inspect` shows it (a fork PR's loaded build)."""
    c = img["config"]
    return [{"Os": img["os"], "Architecture": img["architecture"],
             "Config": {"Env": c["Env"], "Cmd": c["Cmd"], "WorkingDir": c["WorkingDir"], "Entrypoint": None,
                        "User": "", "Labels": c["Labels"], "Hostname": "", "Image": ""},
             "RootFS": {"Type": "layers", "Layers": img["rootfs"]["diff_ids"]}}]


def images():
    return m.entries([("3.49", "3.49")], "3.49", "abcdef0", splits=SPLITS)


def entry(name):
    (e,) = [e for e in images() if e["name"] == name]
    return e


def changed(files):
    return lambda rev: files


class Stages(unittest.TestCase):
    def test_each_input_maps_to_its_stage(self):
        self.assertEqual(pt.stages_for(["test/smoke.sh"]), ["smoke"])
        self.assertEqual(pt.stages_for(["test/fixtures/swarm-hello/model/swarm-hello.cc"]), ["smoke"])
        self.assertEqual(pt.stages_for(["test/fixtures/manet-canary/manet-canary.cc"]), ["integration"])
        self.assertEqual(pt.stages_for(["test/ns3-suites.txt", "test/structure.sh"]), ["structure", "unit"])
        self.assertEqual(pt.stages_for(["test/known-failures.txt"]), ["integration", "unit"])
        self.assertEqual(pt.stages_for([".trivyignore"]), ["security"])

    def test_wiring_and_run_sh_rerun_everything(self):
        for f in ("test/run.sh", "tools/pass_markers.py", "tools/ns3_matrix.py", "tools/pr_tests.py",
                  ".github/workflows/publish-images.yml", "test/new-stage.sh"):
            self.assertEqual(pt.stages_for([f]), list(m.STAGES), f)

    def test_not_test_inputs(self):
        self.assertEqual(pt.stages_for(["docker/Dockerfile", "tools/test_ns3_matrix.py", "README.md",
                                        ".github/workflows/licence.yml", "testdata/x"]), [])


class Content(unittest.TestCase):
    def test_per_build_labels_and_times_ignored(self):
        self.assertEqual(pt.fingerprint(oci()), pt.fingerprint(oci(rev="c" * 40, run="1-2")))

    def test_layers_env_and_other_labels_count(self):
        self.assertNotEqual(pt.fingerprint(oci()), pt.fingerprint(oci(layers=("sha256:aa", "sha256:cc"))))
        self.assertNotEqual(pt.fingerprint(oci()), pt.fingerprint(oci(env=("NS3_VERSION=3.50",))))
        other = oci()
        other["config"]["Labels"]["io.github.swarm-routing.ns3.profile"] = "sanitized"
        self.assertNotEqual(pt.fingerprint(oci()), pt.fingerprint(other))

    def test_docker_inspect_equals_registry_inspect(self):
        self.assertEqual(pt.fingerprint(docker(oci())), pt.fingerprint(oci(run="x")))
        self.assertEqual(pt.revision(docker(oci())), REV)

    def test_per_platform_map(self):
        self.assertEqual(pt.fingerprint({"linux/amd64": oci()}), pt.fingerprint(oci()))
        self.assertEqual(pt.revision({"linux/amd64": oci()}), REV)

    def test_no_layers_is_an_error(self):
        with self.assertRaises(ValueError):
            pt.content(oci(layers=()))


class Plan(unittest.TestCase):
    def test_content_differs_runs_everything(self):
        e = entry("3.49-debug")
        parts, why = pt.plan(e, oci(layers=("sha256:new",)), oci(), changed([]))
        self.assertEqual(parts, e["test_parts"])
        self.assertIn("content differs", why)

    def test_no_reference_or_candidate_runs_everything(self):
        e = entry("3.49-sanitized")
        self.assertEqual(pt.plan(e, oci(), None, changed([]))[0], e["test_parts"])
        self.assertEqual(pt.plan(e, None, oci(), changed([]))[0], e["test_parts"])
        self.assertEqual(pt.plan(e, oci(layers=()), oci(), changed([]))[0], e["test_parts"])

    def test_undiffable_revision_runs_everything(self):
        e = entry("3.49-debug")
        parts, why = pt.plan(e, oci(), oci(), lambda rev: None)
        self.assertEqual(parts, e["test_parts"])
        self.assertIn("cannot diff", why)

    def test_unchanged_and_no_test_input_skips(self):
        for e in images():
            parts, why = pt.plan(e, oci(run="new"), oci(), changed(["docker/README.md", "tools/test_ns3_matrix.py"]))
            self.assertEqual(parts, [], e["name"])
            self.assertIn("unchanged digest, already tested on main", why)

    def test_diff_runs_from_the_reference_revision(self):
        seen = []
        pt.plan(entry("3.49-debug"), oci(), oci(), lambda rev: seen.append(rev) or [])
        self.assertEqual(seen, [REV])

    def test_test_change_runs_on_representatives_only(self):
        ran = {}
        for e in images():
            parts, _ = pt.plan(e, oci(), oci(), changed(["test/smoke.sh"]))
            if parts:
                ran[e["name"]] = [p["stages"] for p in parts]
        self.assertEqual(ran, {
            "3.49-debug": ["labels,smoke"], "3.49-optimized": ["labels,smoke"],
            "3.49-sanitized": ["labels,smoke"],  # the base part only: no unit job
            "3.49-debian-debug": ["labels,smoke"], "3.49-slim-default": ["labels,smoke"],
            "3.49-alpine-debug": ["labels,smoke"]})

    def test_unit_change_on_a_split_image_runs_its_unit_part_only(self):
        parts, _ = pt.plan(entry("3.49-sanitized"), oci(), oci(), changed(["test/unit.sh"]))
        self.assertEqual([(p["part"], p["stages"]) for p in parts], [("unit", "unit")])

    def test_wiring_change_runs_every_stage_on_representatives(self):
        e = entry("3.49-sanitized")
        parts, _ = pt.plan(e, oci(), oci(), changed([".github/workflows/publish-images.yml"]))
        self.assertEqual([p["part"] for p in parts], ["base", "unit"])
        self.assertEqual(parts[0]["stages"], e["test_parts"][0]["stages"])
        parts, _ = pt.plan(entry("3.49-debug"), oci(), oci(), changed(["test/run.sh"]))
        self.assertEqual([p["stages"] for p in parts], [",".join(m.STAGES)])
        self.assertEqual(pt.plan(entry("3.49-default"), oci(), oci(), changed(["test/run.sh"]))[0], [])


class Select(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, name, kind, img):
        with open(os.path.join(self.dir, f"{name}.{kind}.json"), "w") as f:
            json.dump(img, f)

    def test_matrix_and_summary(self):
        imgs = images()
        for e in imgs:
            self.put(e["name"], "reference", oci())
            self.put(e["name"], "candidate", oci(run="new"))
        self.put("3.49-debug", "candidate", oci(layers=("sha256:changed",)))  # the Dockerfile changed debug
        tests, lines = pt.select(imgs, self.dir, changed([]))
        self.assertEqual([t["test_name"] for t in tests], ["3.49-debug"])
        self.assertEqual(len(lines), 9)
        self.assertEqual(sum("unchanged digest, already tested on main" in ln for ln in lines), 8)
        self.assertNotIn("test_parts", tests[0])

    def test_missing_files_run_everything(self):
        imgs = images()
        tests, _ = pt.select(imgs, self.dir, changed([]))
        self.assertEqual(tests, m.test_matrix(imgs))

    def test_refs(self):
        imgs = images()
        os.makedirs(os.path.join(self.dir, "digest-3.49-debug"))
        with open(os.path.join(self.dir, "digest-3.49-debug", "digest"), "w") as f:
            f.write("sha256:" + "a" * 64 + "\n")
        lines = pt.refs(imgs, self.dir, "ghcr.io/o/ns3-dev-ci", "ghcr.io/o/ns3-dev")
        self.assertIn("3.49-debug candidate ghcr.io/o/ns3-dev-ci@sha256:" + "a" * 64, lines)
        self.assertIn("3.49-debug reference ghcr.io/o/ns3-dev:3.49-debug", lines)
        self.assertIn("3.49-default reference ghcr.io/o/ns3-dev:3.49-default", lines)
        self.assertEqual(sum(" candidate " in ln for ln in lines), 1)

    def test_refs_single_image_flat_digest(self):
        one = images()[:1]
        with open(os.path.join(self.dir, "digest"), "w") as f:
            f.write("sha256:" + "b" * 64)
        self.assertIn(f"{one[0]['name']} candidate c@sha256:" + "b" * 64, pt.refs(one, self.dir, "c", "i"))
        self.assertEqual(pt.refs(images()[:2], self.dir, "c", "i")[0].split()[1], "reference")


class Decide(unittest.TestCase):
    def run_decide(self, e, cand, ref):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for n, img in (("c", cand), ("r", ref)):
                paths.append(os.path.join(d, n))
                with open(paths[-1], "w") as f:
                    json.dump(img, f)
            out = io.StringIO()
            with redirect_stdout(out):
                pt.main(["decide", "--entry", json.dumps(e), "--candidate", paths[0], "--reference", paths[1]])
        return json.loads(out.getvalue())

    def test_fork_full_and_skip(self):
        e = entry("3.49-debug")
        self.assertEqual(self.run_decide(e, docker(oci(layers=("sha256:x",))), oci())["stages"], "")
        self.assertTrue(self.run_decide(e, docker(oci(layers=("sha256:x",))), oci())["run"])
        self.assertTrue(self.run_decide(e, docker(oci()), "not an image")["run"])

    def test_fork_unchanged_skips_when_git_sees_no_test_change(self):
        e = copy.deepcopy(entry("3.49-debug"))
        orig = pt.git_changed
        pt.git_changed = lambda rev, head="HEAD": ["test/smoke.sh"]
        try:
            got = self.run_decide(e, docker(oci()), oci())
            self.assertEqual((got["run"], got["stages"]), (True, "labels,smoke"))
            pt.git_changed = lambda rev, head="HEAD": []
            self.assertFalse(self.run_decide(e, docker(oci()), oci())["run"])
        finally:
            pt.git_changed = orig


if __name__ == "__main__":
    unittest.main()
