#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Integration test (ns3-containers#42), run inside an ns3-dev image with this
# repository mounted at /src: does the image's ns-3 actually simulate?
#
#   docker run --rm -v "$PWD:/src:ro" <image> bash /src/test/integration.sh
#
# Builds test/fixtures/manet-canary in the image's tree (in this throwaway
# container only; reconfigured with the image's own flags, so no stock library
# is rebuilt) and runs, each under a wall-clock budget:
#   first                 ns-3's tutorial example (point-to-point echo)
#   dense-<proto>         16 nodes, 500 m, range 175 m, 60 s: must finish and deliver
#   sparse-<proto>        the same with range 100 m: partitioned, must finish
# for proto in aodv, olsr, dsdv. A run that exceeds its budget is a hang.
#
# test/known-failures.txt lists upstream bugs expected on one exact ns-3
# version (strict: an expected failure that passes fails the stage).
set -uo pipefail

NS3=${NS3DIR:-/opt/ns-3}
fails=0

cd "$NS3" || exit 2
# shellcheck source=/dev/null
. ./.swarm-configure.env
# Wall-clock budget per run. The slowest healthy run (dense, debug, 3.48) takes
# ~30 s; ASan/UBSan slow it several-fold. A hang never finishes at all.
case "$BUILD_PROFILE" in sanitized) BUDGET=${BUDGET:-300} ;; *) BUDGET=${BUDGET:-120} ;; esac

mkdir -p scratch/manet-canary
cp /src/test/fixtures/manet-canary/manet-canary.cc scratch/manet-canary/
# shellcheck disable=SC2086  # NS3_PROFILE_FLAGS word-splits on purpose
./ns3 configure -G Ninja $NS3_PROFILE_FLAGS --enable-examples --enable-tests \
    --disable-werror --filter-module-examples-and-tests=core \
    --enable-modules="$NS3_MODULES" >/tmp/configure.log 2>&1 \
    || { tail -30 /tmp/configure.log; echo "integration: configure failed" >&2; exit 1; }
./ns3 build scratch/manet-canary/manet-canary first >/tmp/build.log 2>&1 \
    || { tail -40 /tmp/build.log; echo "integration: build failed" >&2; exit 1; }
echo "integration: built manet-canary and first; budget ${BUDGET} s per run"
canary=$(compgen -G "$NS3/build/scratch/manet-canary/ns3*-manet-canary*" | head -1)
first=$(compgen -G "$NS3/build/examples/tutorial/ns3*-first*" | head -1)

expected() {  # expected NAME -> prints the expected outcome, or nothing
    awk -v v="$NS3_VERSION" -v n="$1" '!/^#/ && $1 == v && $2 == n {print $4 " (" $3 ")"}' \
        /src/test/known-failures.txt
}

# run NAME CHECK-DELIVERY BIN ARGS...
run() {
    local name=$1 deliver=$2; shift 2
    local start out rc took outcome xf
    start=$(date +%s)
    out=$(cd /tmp && timeout "$BUDGET" "$@" 2>&1); rc=$?
    took=$(( $(date +%s) - start ))
    if [ "$rc" -eq 124 ]; then
        outcome=timeout
    elif [ "$rc" -ne 0 ]; then
        outcome="exit $rc"
    elif [ "$deliver" = 1 ] && ! grep -qE 'received=[1-9]' <<<"$out"; then
        outcome="no packets delivered"
    else
        outcome=pass
    fi
    xf=$(expected "$name")
    if [ -n "$xf" ]; then
        if [ "${xf%% *}" = "$outcome" ]; then
            echo "  XFAIL $name: $outcome after ${took} s, expected on ns-$NS3_VERSION: $xf"
            return
        fi
        echo "  FAIL  $name: $outcome after ${took} s, but test/known-failures.txt expects $xf; update or remove the entry" >&2
        fails=$((fails + 1)); return
    fi
    if [ "$outcome" = pass ]; then
        echo "  ok    $name (${took} s) ${out##*$'\n'}"
    else
        echo "  FAIL  $name: $outcome after ${took} s (budget ${BUDGET} s)" >&2
        tail -5 <<<"$out" >&2
        fails=$((fails + 1))
    fi
}

if [ -n "$first" ]; then
    run first 0 "$first"
else
    echo "  SKIP  first: this release has no tutorial target named first"
fi
for p in aodv olsr dsdv; do
    run "dense-$p" 1 "$canary" --protocol="$p" --range=175
    run "sparse-$p" 0 "$canary" --protocol="$p" --range=100
done

if [ "$fails" -gt 0 ]; then
    echo "integration: $fails run(s) failed" >&2
    exit 1
fi
echo "integration: OK (ns-$NS3_VERSION, $BUILD_PROFILE)"
