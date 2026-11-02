#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# ns-3's own unit suites (ns3-containers#40), run inside an ns3-dev image with
# this repository mounted at /src:
#
#   docker run --rm -v "$PWD:/src:ro" <image> bash /src/test/unit.sh
#
# The images ship with only `core`'s tests built. This reconfigures the tree in
# the throwaway container with the image's own recorded flags and the
# examples/tests filter set to the modules in test/ns3-suites.txt (`full` on
# debug and sanitized, `light` on default and optimized), builds their test
# libraries, and runs `test.py -c unit -f QUICK`. The published image is never
# changed. Suites listed for this exact ns-3 version in test/known-failures.txt
# (`unit:<suite>`) must fail; any other failure fails the stage.
set -uo pipefail

NS3=${NS3DIR:-/opt/ns-3}
BUDGET=${BUDGET:-5400}
cd "$NS3" || exit 2
# shellcheck source=/dev/null
. ./.swarm-configure.env

case "$BUILD_PROFILE" in debug|sanitized) group=full ;; *) group=light ;; esac
mods=$(awk -v g="$group" '!/^#/ && $1 == g {$1=""; print}' /src/test/ns3-suites.txt | xargs)
[ -n "$mods" ] || { echo "unit: no '$group' group in test/ns3-suites.txt" >&2; exit 2; }
echo "unit: $group group ($BUILD_PROFILE): $mods"

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
./ns3 build >/tmp/build.log 2>&1 || { tail -40 /tmp/build.log; echo "unit: build failed" >&2; exit 1; }
echo "unit: test libraries built in $(( $(date +%s) - start )) s"

start=$(date +%s)
timeout "$BUDGET" ./test.py --no-build --nocolor -c unit -f QUICK >/tmp/test.log 2>&1
rc=$?
took=$(( $(date +%s) - start ))
grep -E '^[0-9]+ of [0-9]+ tests passed' /tmp/test.log || true
echo "unit: test.py took ${took} s (exit $rc)"
if [ "$rc" -eq 124 ] || { [ "$rc" -eq 143 ] && [ "$took" -ge "$BUDGET" ]; }; then
    echo "unit: test.py did not finish within ${BUDGET} s" >&2
    tail -20 /tmp/test.log >&2
    exit 1
fi
mapfile -t failed < <(sed -nE 's/^\[[0-9]+\/[0-9]+\] (FAIL|CRASH|VALGR): TestSuite ([^ ]+).*/\2/p' /tmp/test.log | sort -u)
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
while read -r s issue; do
    [ -n "$s" ] || continue
    if ! printf '%s\n' "${failed[@]}" | grep -qxF "$s"; then
        echo "  FAIL  unit:$s passed, but test/known-failures.txt expects it to fail ($issue); remove the entry" >&2
        fails=$((fails + 1))
    fi
done <<<"$expected"

if [ "$fails" -gt 0 ]; then
    grep -E '^\[[0-9]+/[0-9]+\] (FAIL|CRASH|VALGR)' /tmp/test.log >&2
    echo "unit: $fails unexpected result(s)" >&2
    exit 1
fi
echo "unit: OK (ns-$NS3_VERSION, $BUILD_PROFILE, $group)"
