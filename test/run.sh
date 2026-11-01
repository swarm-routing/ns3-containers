#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Run every test stage against one image, from the runner (or a workstation):
#
#   test/run.sh <image-ref>
#
# <image-ref> is the image built in the same pipeline run, addressed by its
# digest (ghcr.io/...@sha256:...) or, for a fork PR that cannot push, the
# image the build step loaded locally. Never a rolling tag: what is tested is
# what gets tagged (ns3-containers#37). Each stage runs in a fresh container
# with this repository mounted read-only at /src, so no stage sees another's
# changes and the image itself is never modified.
#
# The same stages run for every image the pipeline builds: the supported
# release and on-demand older releases alike (ns3-containers#36). A stage that
# cannot apply to a release says SKIP (<reason>); it never passes silently.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <image-ref>" >&2; exit 2; }
image=$1
repo=$(cd "$(dirname "$0")/.." && pwd)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

stage() {
    local name=$1; shift
    local start rc
    start=$(date +%s)
    echo "::group::stage: $name"
    set +e
    "$@"
    rc=$?
    set -e
    echo "::endgroup::"
    local took=$(( $(date +%s) - start ))
    if [ "$rc" -eq 0 ]; then
        echo "| $name | pass | ${took} s |" >> "$summary"
        echo "test/run.sh: stage $name passed (${took} s)"
    else
        echo "| $name | **FAIL** (exit $rc) | ${took} s |" >> "$summary"
        echo "test/run.sh: stage $name FAILED (exit $rc)" >&2
        exit "$rc"
    fi
}

in_image() { docker run --rm -v "$repo:/src:ro" "$image" "$@"; }

{
    echo "### Tests on \`$image\`"
    echo
    echo "| Stage | Result | Time |"
    echo "|---|---|---|"
} >> "$summary"

stage smoke in_image bash /src/test/smoke.sh
