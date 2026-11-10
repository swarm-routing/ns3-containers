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
# EXPECT_VERSION, EXPECT_PROFILE, EXPECT_OS (the pipeline's matrix entry),
# EXPECT_REVISION (the commit that built it) and EXPECT_BUILD_RUN (the run)
# are passed to the stages that compare against them; unset, those
# comparisons are skipped and say so.
#
# UNIT_SET=full|light picks the unit stage's group in test/ns3-suites.txt;
# unset (a local run, a push to main, a schedule or dispatch run), the
# profile picks it (test/unit.sh). The pipeline sets it to `light` only on a
# pull request, for the Debian, slim and Alpine images (ns3-containers#87).
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
times=$(mktemp)
print_notes() {
    if [ -s "$times" ]; then
        { echo; echo "Slowest unit suites (s):"; echo; echo '```'; cat "$times"; echo '```'; } >> "$summary"
    fi
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
    grep -E '^ *TIME ' "$out" | head -15 | sed 's/^ *TIME *//' >> "$times" || true
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
        -e EXPECT_OS="${EXPECT_OS:-}" -e UNIT_SET="${UNIT_SET:-}" "$image" "$@"
}

# OCI labels, read from the image config on the runner (ns3-containers#39).
labels() {
    local fails=0 key want got
    for pair in "org.opencontainers.image.source=https://github.com/swarm-routing/ns3-containers" \
                "org.opencontainers.image.licenses=GPL-2.0-only" \
                "org.opencontainers.image.version=${EXPECT_VERSION:-}" \
                "io.github.swarm-routing.ns3.profile=${EXPECT_PROFILE:-}" \
                "io.github.swarm-routing.ns3.base=${EXPECT_OS:-}" \
                "org.opencontainers.image.revision=${EXPECT_REVISION:-}" \
                "io.github.swarm-routing.build-run=${EXPECT_BUILD_RUN:-}"; do
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

# Security (ns3-containers#38, #30), on the host with a digest-pinned Trivy.
# Gates: fixable vulnerabilities of MEDIUM or higher (the maintainer's
# threshold), any secret in the image (files, and ENV/history in its config), HIGH+ Dockerfile misconfigurations
# except the ones accepted with a reason in .trivyignore. Behind a
# TLS-intercepting proxy set TRIVY_CA to its CA bundle.
TRIVY=ghcr.io/aquasecurity/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c
trivy() {
    local cache=${TRIVY_CACHE:-${RUNNER_TEMP:-/tmp}/trivy-cache} extra=()
    mkdir -p "$cache"
    if [ -n "${TRIVY_CA:-}" ]; then extra+=(-e SSL_CERT_FILE=/ca.crt -v "$TRIVY_CA:/ca.crt:ro"); fi
    if [ -n "${HTTPS_PROXY:-}" ]; then extra+=(-e HTTPS_PROXY); fi
    docker run --rm --network host -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$cache:/root/.cache" -v "$repo:/repo:ro" "${extra[@]}" "$TRIVY" "$@"
}
security() {
    local fails=0
    echo "security: vulnerabilities (fixable, MEDIUM or higher)"
    if trivy image --quiet --scanners vuln --ignore-unfixed --severity MEDIUM,HIGH,CRITICAL \
        --exit-code 1 --format table "$image"; then
        echo "  ok    no fixable MEDIUM/HIGH/CRITICAL vulnerability"
    else
        echo "  FAIL  fixable vulnerabilities above (rebuild with refreshed packages, #27)" >&2; fails=$((fails + 1))
    fi
    echo "security: secrets"
    if trivy image --quiet --scanners secret --image-config-scanners secret --exit-code 1 --format table "$image"; then
        echo "  ok    no secret in the image"
    else
        echo "  FAIL  secrets found in the image" >&2; fails=$((fails + 1))
    fi
    echo "security: Dockerfile misconfigurations (HIGH or higher, .trivyignore applied)"
    if trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 \
        --ignorefile /repo/.trivyignore /repo/docker; then
        echo "  ok    no HIGH/CRITICAL misconfiguration outside .trivyignore"
    else
        echo "  FAIL  Dockerfile misconfigurations above" >&2; fails=$((fails + 1))
    fi
    [ "$fails" -eq 0 ]
}

{
    echo "### Tests on \`$image\`"
    echo
    if [ -n "${UNIT_SET:-}" ]; then
        echo "Unit set: \`$UNIT_SET\` (UNIT_SET; the pipeline sets \`light\` on pull requests for the Debian, slim and Alpine images)"
    else
        echo "Unit set: the profile's group (\`full\` on debug and sanitized, \`light\` on default and optimized)"
    fi
    echo
    echo "| Stage | Result | Time |"
    echo "|---|---|---|"
} >> "$summary"

stage labels labels
stage security security
stage structure in_image bash /src/test/structure.sh
stage profile in_image bash /src/test/profile.sh
stage smoke in_image bash /src/test/smoke.sh
stage integration in_image bash /src/test/integration.sh
stage unit in_image bash /src/test/unit.sh
