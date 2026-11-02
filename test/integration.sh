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
#   aodv-example          ns-3's AODV example: 10-node chain, 10 s of pings; must deliver
#   dsdv-manet            ns-3's DSDV example: 20 nodes, random waypoint, 30 s, data from 10 s
#   olsr-hna              ns-3's OLSR HNA example; must deliver
#   dense-<proto>         manet-canary, 16 nodes, 500 m, range 175 m, 60 s: must finish and deliver
#   sparse-<proto>        the same with range 100 m: partitioned, must finish
# for proto in aodv, olsr, dsdv. A run that exceeds its budget is a hang. The
# stock examples are the routing modules' own (src/<module>/examples); ns-3's
# examples/routing/manet-routing-compare is not used: it hard-codes 200 s of
# simulated time (~3.5 min per protocol on debug) and, with its defaults, does
# not trigger the 3.49 AODV livelock (#35), which the sparse canary does.
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
# The filter enables the routing modules' examples; only the targets named
# below are built, so no test library is compiled.
filter="core;aodv;olsr;dsdv"
if ./ns3 configure --help 2>/dev/null | grep -q -- --filter-module-examples-and-tests; then
    filter_flag=(--filter-module-examples-and-tests="$filter")
else
    filter_flag=()
fi
# shellcheck disable=SC2086  # NS3_PROFILE_FLAGS word-splits on purpose
./ns3 configure -G Ninja $NS3_PROFILE_FLAGS --enable-examples --enable-tests \
    --disable-werror "${filter_flag[@]}" \
    --enable-modules="$NS3_MODULES" >/tmp/configure.log 2>&1 \
    || { tail -30 /tmp/configure.log; echo "integration: configure failed" >&2; exit 1; }
./ns3 build scratch/manet-canary/manet-canary >/tmp/build.log 2>&1 \
    || { tail -40 /tmp/build.log; echo "integration: build of manet-canary failed" >&2; exit 1; }
canary=$(compgen -G "$NS3/build/scratch/manet-canary/ns3*-manet-canary*" | head -1)
[ -x "$canary" ] || { echo "integration: built manet-canary executable not found" >&2; exit 1; }
# Stock examples, built one by one. A target this release does not have is
# skipped; a target it has that fails to build fails the stage.
stock_fail=0
first="" aodv_ex="" dsdv_ex="" olsr_ex=""
stock() {  # stock VAR TARGET GLOB -> sets VAR to the executable, or empty
    local log
    printf -v "$1" '%s' ""
    if ! log=$(./ns3 build "$2" 2>&1); then
        echo "$log" >> /tmp/build.log
        grep -q "Target to build does not exist" <<<"$log" && return 0
        echo "  FAIL  $2: the release has this target but it does not build" >&2
        tail -20 <<<"$log" >&2
        stock_fail=1; return 0
    fi
    local g pats
    read -ra pats <<<"$3"  # GLOB may list several patterns; the first match wins
    for g in "${pats[@]}"; do
        printf -v "$1" '%s' "$(compgen -G "$NS3/build/$g" | head -1)"
        [ -z "${!1}" ] || return 0
    done
}
stock first first "examples/tutorial/ns3*-first*"
# ns-3.40-3.42 call the AODV example `aodv`, later releases `aodv-example`.
stock aodv_ex aodv-example "src/aodv/examples/ns3*-aodv-example*"
# Release-profile executables carry no profile suffix (ns3.40-aodv).
[ -n "$aodv_ex" ] || stock aodv_ex aodv "src/aodv/examples/ns3*-aodv src/aodv/examples/ns3*-aodv-*"
stock dsdv_ex dsdv-manet "src/dsdv/examples/ns3*-dsdv-manet*"
stock olsr_ex olsr-hna "src/olsr/examples/ns3*-olsr-hna*"
[ "$stock_fail" -eq 0 ] || { echo "integration: a stock example failed to build" >&2; exit 1; }
echo "integration: built manet-canary and the stock examples; budget ${BUDGET} s per run"

expected() {  # expected NAME -> prints the expected outcome, or nothing
    awk -v v="$NS3_VERSION" -v n="$1" '!/^#/ && $1 == v && $2 == n {print $4 " (" $3 ")"}' \
        /src/test/known-failures.txt
}

# run NAME DELIVERY-REGEX BIN ARGS...  (an empty regex: finishing is enough)
run() {
    local name=$1 deliver=$2; shift 2
    local start out rc took outcome xf
    start=$(date +%s)
    out=$(cd /tmp && timeout "$BUDGET" "$@" 2>&1); rc=$?
    took=$(( $(date +%s) - start ))
    # POST (optional): a command whose output joins the program's, run after it
    # exits cleanly, so timeout supervises the program itself, never a wrapper.
    if [ "$rc" -eq 0 ] && [ -n "${POST:-}" ]; then out+=$'\n'$($POST 2>&1); fi
    # GNU timeout exits 124; BusyBox's (Alpine) is killed by SIGTERM, 143.
    if [ "$rc" -eq 124 ] || { [ "$rc" -eq 143 ] && [ "$took" -ge "$BUDGET" ]; }; then
        outcome=timeout
    elif [ "$rc" -ne 0 ]; then
        outcome="exit $rc"
    elif [ -n "$deliver" ] && ! grep -qE "$deliver" <<<"$out"; then
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

optional() {  # optional NAME BIN DELIVERY-REGEX ARGS...
    local name=$1 bin=$2 deliver=$3; shift 3
    if [ -n "$bin" ]; then
        run "$name" "$deliver" "$bin" "$@"
    else
        echo "  SKIP  $name: this release has no such example target"
    fi
}
optional first "$first" ""
optional aodv-example "$aodv_ex" ' [1-9][0-9]* received' --time=10 --size=10
# dsdv-manet logs delivery with NS_LOG_UNCOND (compiled out in optimized), but
# its CSV counts received packets in every profile: sum that column afterwards.
dsdv_received() {
    awk -F, 'NR > 1 { s += $3 } END { printf "dsdv-received=%d\n", s }' /tmp/dsdv-manet.csv
}
if [ -n "$dsdv_ex" ]; then
    POST=dsdv_received run dsdv-manet 'dsdv-received=[1-9]' "$dsdv_ex" \
        --totalTime=30 --dataStart=10 --nWifis=20 --nSinks=5 --CSVfileName=/tmp/dsdv-manet.csv
else
    echo "  SKIP  dsdv-manet: this release has no such example target"
fi
# olsr-hna reports delivery with NS_LOG_UNCOND, which the optimized profile
# compiles out: there it only has to finish.
if [ "$BUILD_PROFILE" = optimized ]; then
    echo "  SKIP  olsr-hna delivery check: its output is NS_LOG_UNCOND, compiled out in optimized"
    optional olsr-hna "$olsr_ex" ""
else
    optional olsr-hna "$olsr_ex" 'Received one packet'
fi
for p in aodv olsr dsdv; do
    run "dense-$p" 'received=[1-9]' "$canary" --protocol="$p" --range=175
    run "sparse-$p" "" "$canary" --protocol="$p" --range=100
done

if [ "$fails" -gt 0 ]; then
    echo "integration: $fails run(s) failed" >&2
    exit 1
fi
echo "integration: OK (ns-$NS3_VERSION, $BUILD_PROFILE)"
