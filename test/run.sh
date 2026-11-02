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
# EXPECT_VERSION, EXPECT_PROFILE, EXPECT_OS (the pipeline's matrix entry) and
# EXPECT_REVISION (the commit that built it)
# are passed to the stages that compare against them; unset, those
# comparisons are skipped and say so.
#
# The same stages run for every image the pipeline builds: the supported
# release and on-demand older releases alike (ns3-containers#36). A stage that
# cannot apply to a release says SKIP (<reason>); it never passes silently.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <image-ref>" >&2; exit 2; }
image=$1
repo=$(cd "$(dirname "$0")/.." && pwd)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

notes=$(mktemp)
print_notes() {
    [ -s "$notes" ] || return 0
    { echo; echo "Notes (expected failures and skips):"; echo; sed 's/^/- /' "$notes"; } >> "$summary"
}
trap print_notes EXIT

stage() {
    local name=$1; shift
    local start rc out
    start=$(date +%s)
    out=$(mktemp)
    echo "::group::stage: $name"
    set +e
    "$@" 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    set -e
    echo "::endgroup::"
    grep -E '^ *(XFAIL|SKIP) ' "$out" | sed "s/^ */[$name] /" >> "$notes" || true
    rm -f "$out"
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

in_image() {
    docker run --rm -v "$repo:/src:ro" \
        -e EXPECT_VERSION="${EXPECT_VERSION:-}" -e EXPECT_PROFILE="${EXPECT_PROFILE:-}" \
        -e EXPECT_OS="${EXPECT_OS:-}" "$image" "$@"
}

# OCI labels, read from the image config on the runner (ns3-containers#39).
labels() {
    local fails=0 key want got
    for pair in "org.opencontainers.image.source=https://github.com/swarm-routing/ns3-containers" \
                "org.opencontainers.image.licenses=GPL-2.0-only" \
                "org.opencontainers.image.version=${EXPECT_VERSION:-}" \
                "io.github.swarm-routing.ns3.profile=${EXPECT_PROFILE:-}" \
                "io.github.swarm-routing.ns3.base=${EXPECT_OS:-}" \
                "org.opencontainers.image.revision=${EXPECT_REVISION:-}"; do
        key=${pair%%=*}; want=${pair#*=}
        got=$(docker image inspect --format "{{ index .Config.Labels \"$key\" }}" "$image")
        if [ -z "$want" ]; then
            echo "  SKIP  $key=$got (nothing to compare)"
        elif [ "$got" = "$want" ]; then
            echo "  ok    $key=$got"
        else
            echo "  FAIL  $key='$got', expected '$want'" >&2; fails=$((fails + 1))
        fi
    done
    [ "$fails" -eq 0 ]
}

{
    echo "### Tests on \`$image\`"
    echo
    echo "| Stage | Result | Time |"
    echo "|---|---|---|"
} >> "$summary"

stage labels labels
stage structure in_image bash /src/test/structure.sh
stage smoke in_image bash /src/test/smoke.sh
stage integration in_image bash /src/test/integration.sh
