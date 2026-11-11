#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# ns-3's own unit suites (ns3-containers#40), run inside an ns3-dev image with
# this repository mounted at /src:
#
#   docker run --rm -v "$PWD:/src:ro" <image> bash /src/test/unit.sh
#
# The debug and sanitized images ship with the `full` group's test libraries
# built (docker/Dockerfile, #86, #87), the others with only `core`'s. This
# reconfigures the tree in the throwaway container with the image's own
# recorded flags and the examples/tests filter set to the modules of one group
# in test/ns3-suites.txt, builds `test-runner` and the test libraries it links
# (no examples: test.py -c unit runs none; up to date on debug and sanitized
# but for the link), and runs `test.py -c unit -f QUICK`, all within one
# BUDGET (default 90 min). The published image is never changed.
#
# UNIT_SET=full|light picks the group. Unset, the profile picks it: `full` on
# debug and sanitized, `light` on default and optimized. The pipeline sets
# UNIT_SET=light only on a pull request, for the Debian, slim and Alpine images
# (ns3-containers#87); a push to main and any run without UNIT_SET run the
# profile's group. Every suite's time is printed (`TIME <s> <suite>`, slowest
# first) so the stage's cost can be split on measured numbers (#86).
#
# UNIT_SHARD=i/N runs shard i of N: the modules test/ns3-suites.txt lists on
# its `shard <group> i/N` line (#86). The N shards of a group must list every
# module of the group exactly once; if they do not, the stage fails before it
# builds anything, so no suite is ever silently dropped.
#
# UNIT_PR=1 marks a pull-request run: the suites on test/ns3-suites.txt's
# `main-only` line are left out of test.py's list, and the stage says which
# (a SKIP line per suite, and in the group line the step summary shows).
# Unset, every suite of the group runs, as on main, schedule and dispatch
# runs, where the image is promoted (ns3-containers#86, #87).
# Suites listed for this exact ns-3 version in test/known-failures.txt
# (`unit:<suite>`) must fail; any other failure fails the stage.
set -uo pipefail

NS3=${NS3DIR:-/opt/ns-3}
BUDGET=${BUDGET:-5400}
# One deadline for the whole stage: configure, build and test.py share it, so
# a hang anywhere fails the stage instead of stalling the job.
if [ "${UNIT_DEADLINE_SET:-}" != 1 ]; then
    UNIT_DEADLINE_SET=1 timeout "$BUDGET" bash "$0" "$@"
    rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
        echo "unit: stage did not finish within ${BUDGET} s; last output:" >&2
        for f in /tmp/test.log /tmp/build.log /tmp/configure.log; do
            [ -s "$f" ] && { echo "--- $f" >&2; tail -20 "$f" >&2; break; }
        done
    fi
    exit "$rc"
fi
cd "$NS3" || exit 2
# shellcheck source=/dev/null
. ./.swarm-configure.env

case "$BUILD_PROFILE" in debug|sanitized) group=full ;; *) group=light ;; esac
why="the $BUILD_PROFILE profile's group"
if [ -n "${UNIT_SET:-}" ]; then
    case "$UNIT_SET" in full|light) ;; *) echo "unit: UNIT_SET must be full or light, not '$UNIT_SET'" >&2; exit 2 ;; esac
    group=$UNIT_SET
    why="UNIT_SET=$UNIT_SET"
fi
mods=$(awk -v g="$group" '!/^#/ && $1 == g {$1=""; print}' /src/test/ns3-suites.txt | xargs)
[ -n "$mods" ] || { echo "unit: no '$group' group in test/ns3-suites.txt" >&2; exit 2; }
if [ -n "${UNIT_SHARD:-}" ]; then
    n=${UNIT_SHARD#*/}
    shard_mods=$(awk -v g="$group" -v s="$UNIT_SHARD" '!/^#/ && $1 == "shard" && $2 == g && $3 == s {$1=$2=$3=""; print}' \
        /src/test/ns3-suites.txt | xargs)
    covered=$(awk -v g="$group" -v n="$n" '!/^#/ && $1 == "shard" && $2 == g && $3 ~ ("^[0-9]+/" n "$") {for (i = 4; i <= NF; i++) print $i}' \
        /src/test/ns3-suites.txt | sort)
    want=$(tr ' ' '\n' <<<"$mods" | sort)
    if [ "$covered" != "$want" ]; then
        echo "unit: the '$group' shards of $n in test/ns3-suites.txt do not cover the group exactly once" >&2
        diff <(echo "$want") <(echo "$covered") | sed 's/^/  /' >&2
        exit 2
    fi
    [ -n "$shard_mods" ] || { echo "unit: no 'shard $group $UNIT_SHARD' line in test/ns3-suites.txt" >&2; exit 2; }
    mods=$shard_mods
    why="$why, shard $UNIT_SHARD"
fi
deferred=""
case "${UNIT_PR:-}" in
    "") ;;
    1) deferred=$(awk '{sub(/#.*/, "")} $1 == "main-only" {$1=""; print}' /src/test/ns3-suites.txt | xargs)
       [ -z "$deferred" ] || why="$why; pull request: $deferred deferred to main" ;;
    *) echo "unit: UNIT_PR must be 1 or unset, not '$UNIT_PR'" >&2; exit 2 ;;
esac
echo "unit: $group group ($why): $mods"

if ./ns3 configure --help 2>/dev/null | grep -q -- --filter-module-examples-and-tests; then
    # shellcheck disable=SC2086  # NS3_PROFILE_FLAGS word-splits on purpose
    ./ns3 configure -G Ninja $NS3_PROFILE_FLAGS --enable-examples --enable-tests \
        --disable-werror --filter-module-examples-and-tests="${mods// /;}" \
        --enable-modules="$NS3_MODULES" >/tmp/configure.log 2>&1 \
        || { tail -30 /tmp/configure.log; echo "unit: configure failed" >&2; exit 1; }
else
    echo "  SKIP  filter: this release has no --filter-module-examples-and-tests; running every built suite"
fi
start=$(date +%s)
./ns3 build test-runner >/tmp/build.log 2>&1 || { tail -40 /tmp/build.log; echo "unit: build failed" >&2; exit 1; }
echo "unit: test libraries built in $(( $(date +%s) - start )) s ($(grep -cE '^\[[0-9]+/[0-9]+\]' /tmp/build.log) Ninja steps)"

if [ -n "$deferred" ]; then
    # test.py has no exclude option: it runs what the test runner's
    # --print-test-name-list prints. In this throwaway container the runner
    # is wrapped so that list leaves the deferred suites out.
    mapfile -t runners < <(find build/utils -maxdepth 1 -type f -name '*test-runner*' ! -name '*.real')
    [ ${#runners[@]} -eq 1 ] || { echo "unit: expected one test runner in build/utils, found ${#runners[@]}" >&2; exit 1; }
    runner=${runners[0]}
    tr ' ' '\n' <<<"$deferred" >/tmp/unit-deferred.txt
    for s in $deferred; do
        if "$runner" --print-test-name-list | grep -xF "$s" >/dev/null; then  # not -q: an early exit SIGPIPEs the runner
            echo "  SKIP  unit:$s: deferred to main on pull requests (main-only in test/ns3-suites.txt, #86)"
        else
            echo "  SKIP  unit:$s: main-only in test/ns3-suites.txt, but not a suite of this build"
        fi
    done
    mv "$runner" "$runner.real"
    cat >"$runner" <<'EOF'
#!/usr/bin/env bash
# Written by test/unit.sh on a pull request: leaves the main-only suites out of the suite list.
if [[ " $* " == *" --print-test-name-list "* ]]; then
    "$0.real" "$@" | { grep -vxF -f /tmp/unit-deferred.txt || true; }
    exit "${PIPESTATUS[0]}"
fi
exec "$0.real" "$@"
EOF
    chmod +x "$runner"
    echo "unit: deferred to main (UNIT_PR=1): $deferred; every push to main runs them before it promotes the image"
fi

start=$(date +%s)
./test.py --no-build --nocolor --duration -c unit -f QUICK >/tmp/test.log 2>&1
rc=$?
took=$(( $(date +%s) - start ))
echo "unit: test.py took ${took} s (exit $rc)"
# An empty run (no suite discovered) must not read as a pass.
summary=$(grep -E '^[0-9]+ of [0-9]+ tests passed' /tmp/test.log | tail -1)
echo "${summary:-unit: no test.py completion summary}"
if ! grep -qE '^[0-9]+ of [1-9][0-9]* tests passed' <<<"$summary"; then
    tail -20 /tmp/test.log >&2
    echo "unit: test.py ran no suite" >&2
    exit 1
fi
# Per-suite wall time, slowest first. With --duration test.py writes
# "[i/N] PASS (12.345): TestSuite <name>".
sed -nE 's/^\[[0-9]+\/[0-9]+\] [A-Z]+ \(([0-9.]+)\): TestSuite ([^ ]+).*/\1 \2/p' /tmp/test.log \
    | sort -k1,1gr | awk '{printf "  TIME  %8.1f %s\n", $1, $2}'
mapfile -t failed < <(sed -nE 's/^\[[0-9]+\/[0-9]+\] (FAIL|CRASH|VALGR)( \([0-9.]+\))?: TestSuite ([^ ]+).*/\3/p' /tmp/test.log | sort -u)
if [ "$rc" -ne 0 ] && [ ${#failed[@]} -eq 0 ]; then
    tail -30 /tmp/test.log >&2
    echo "unit: test.py failed (exit $rc) without naming a failed suite" >&2
    exit 1
fi

expected=$(awk -v v="$NS3_VERSION" '!/^#/ && $1 == v && $2 ~ /^unit:/ {sub(/^unit:/, "", $2); print $2 " " $3}' \
    /src/test/known-failures.txt)
fails=0
for s in "${failed[@]}"; do
    issue=$(awk -v s="$s" '$1 == s {print $2}' <<<"$expected")
    if [ -n "$issue" ]; then
        echo "  XFAIL unit:$s: fails, expected on ns-$NS3_VERSION ($issue)"
    else
        echo "  FAIL  unit:$s" >&2
        fails=$((fails + 1))
    fi
done
mapfile -t passed < <(sed -nE 's/^\[[0-9]+\/[0-9]+\] PASS( \([0-9.]+\))?: TestSuite ([^ ]+).*/\2/p' /tmp/test.log | sort -u)
while read -r s issue; do
    [ -n "$s" ] || continue
    if printf '%s\n' "${failed[@]}" | grep -qxF "$s"; then
        continue    # reported as XFAIL above
    elif printf '%s\n' "${passed[@]}" | grep -qxF "$s"; then
        echo "  FAIL  unit:$s passed, but test/known-failures.txt expects it to fail ($issue); remove the entry" >&2
        fails=$((fails + 1))
    else
        echo "  SKIP  unit:$s: listed in test/known-failures.txt ($issue) but not run in the $group group"
    fi
done <<<"$expected"

if [ "$fails" -gt 0 ]; then
    grep -E '^\[[0-9]+/[0-9]+\] (FAIL|CRASH|VALGR)' /tmp/test.log >&2
    echo "unit: $fails unexpected result(s)" >&2
    exit 1
fi
echo "unit: OK (ns-$NS3_VERSION, $BUILD_PROFILE, $group group, $why)"
