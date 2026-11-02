#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Profile checks (ns3-containers#41), run inside an ns3-dev image with this
# repository mounted at /src:
#
#   docker run --rm -v "$PWD:/src:ro" <image> bash /src/test/profile.sh
#
# Each profile makes a promise that downstream CI relies on. This builds
# test/fixtures/profile-probe in the throwaway container (the image's own
# configure line, so no stock library is rebuilt) and checks it:
#
#   profile    asserts   NS_LOG   sanitizers (uaf, leak, overflow)
#   default    abort     on       -
#   debug      abort     on       -
#   sanitized  abort     on       each one reported (negative tests)
#   optimized  off       off      -
#
# Every profile: no AVX/AVX-512 instruction in the stock core library, i.e.
# nothing was built for the build machine's CPU (rule 11; -march=native would
# make an image SIGILL on another runner).
# ok() always returns 0, so `test && ok ... || bad ...` is a true if/else here.
# shellcheck disable=SC2015
set -uo pipefail

NS3=${NS3DIR:-/opt/ns-3}
fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*" >&2; fails=$((fails + 1)); }
skip() { echo "  SKIP  $*"; }

cd "$NS3" || exit 2
# shellcheck source=/dev/null
. ./.swarm-configure.env

mkdir -p scratch/profile-probe
cp /src/test/fixtures/profile-probe/profile-probe.cc scratch/profile-probe/
# shellcheck disable=SC2086  # NS3_PROFILE_FLAGS word-splits on purpose
./ns3 configure -G Ninja $NS3_PROFILE_FLAGS --enable-examples --enable-tests \
    --disable-werror --filter-module-examples-and-tests=core \
    --enable-modules="$NS3_MODULES" >/tmp/configure.log 2>&1 \
    || { tail -30 /tmp/configure.log; echo "profile: configure failed" >&2; exit 1; }
./ns3 build scratch/profile-probe/profile-probe >/tmp/build.log 2>&1 \
    || { tail -40 /tmp/build.log; echo "profile: build failed" >&2; exit 1; }
probe=$(compgen -G "$NS3/build/scratch/profile-probe/ns3*-profile-probe*" | head -1)
[ -x "$probe" ] || { echo "profile: no profile-probe binary" >&2; exit 1; }

# probe MODE -> sets $out and $rc
probe() { out=$(cd /tmp && timeout 60 env NS_LOG="${NS_LOG_SPEC:-}" "$probe" --mode="$1" 2>&1); rc=$?; }

echo "profile: $BUILD_PROFILE"
case "$BUILD_PROFILE" in
    optimized) asserts=off ;;
    *)         asserts=on ;;
esac

probe assert
if [ "$asserts" = on ]; then
    [ "$rc" -ne 0 ] && grep -q "deliberate assert" <<<"$out" \
        && ok "NS_ASSERT aborts (exit $rc)" || bad "NS_ASSERT did not abort (exit $rc): $out"
else
    [ "$rc" -eq 0 ] && grep -q "not compiled in" <<<"$out" \
        && ok "NS_ASSERT compiled out" || bad "NS_ASSERT is active in $BUILD_PROFILE (exit $rc): $out"
fi

NS_LOG_SPEC="ProfileProbe=info" probe log
if [ "$asserts" = on ]; then
    grep -q "profile-probe: log line" <<<"$out" && ok "NS_LOG prints" || bad "NS_LOG printed nothing: $out"
else
    ! grep -q "profile-probe: log line" <<<"$out" && ok "NS_LOG compiled out" || bad "NS_LOG is active in $BUILD_PROFILE"
fi

if [ "$BUILD_PROFILE" = sanitized ]; then
    # Negative tests: each planted bug must be reported and fail the run.
    for spec in "uaf:heap-use-after-free" "leak:detected memory leaks" "overflow:signed integer overflow"; do
        mode=${spec%%:*}; want=${spec#*:}
        probe "$mode"
        if [ "$rc" -ne 0 ] && grep -q "$want" <<<"$out"; then
            ok "$mode caught: $want (exit $rc)"
        else
            bad "$mode NOT caught (exit $rc): sanitizers are not active"
        fi
    done
else
    skip "sanitizer negative tests: only the sanitized profile has sanitizers"
fi

# No instruction for a newer CPU than the x86-64 baseline in the stock tree.
# Every AVX/AVX2/AVX-512 instruction is VEX/EVEX-encoded, which objdump prints
# with a `v` mnemonic (vmovaps, vpxor, vzeroupper, ...), whatever its
# registers; the baseline's only v-mnemonics are verr/verw.
# avx_in DISASSEMBLY -> 1 when it contains a VEX/EVEX mnemonic. Mnemonics may
# carry underscores (vcmplt_oqps) and braces-free suffixes; verr/verw excluded.
avx_in() {
    awk '$1 ~ /^[0-9a-f]+:$/ && $2 ~ /^v[a-z0-9_]+$/ && $2 !~ /^ver[rw]$/ {found = 1; exit}
         END {exit found ? 1 : 0}' "$1"
}
avx_scan() {  # avx_scan LIB -> 0 clean, 1 AVX found, 2 objdump failed
    local dis
    dis=$(mktemp)
    if ! objdump -d --no-show-raw-insn "$1" > "$dis" 2>/dev/null; then rm -f "$dis"; return 2; fi
    # One awk over the file, no pipe: a pipe into an early-exiting grep -q can
    # SIGPIPE objdump/grep and, under pipefail, turn a match into a miss.
    avx_in "$dis"
    local rc=$?
    rm -f "$dis"
    return "$rc"
}
core=$(compgen -G "$NS3/build/lib/libns3*-core*.so" | grep -v -- "-core-test" | head -1)
case "$(uname -m)" in
    x86_64)
        if ! command -v objdump >/dev/null; then
            skip "AVX scan: objdump not in this image"
        else
            avx_scan "$core"
            case $? in
                0) ok "no AVX/AVX-512 instruction in $(basename "$core")" ;;
                1) bad "$(basename "$core") contains AVX/AVX-512 (VEX/EVEX) instructions: built for the build machine's CPU" ;;
                *) bad "objdump could not disassemble $(basename "$core")" ;;
            esac
            # Self-check of the matcher on objdump-shaped lines: an underscore
            # mnemonic is AVX, verr is not.
            printf '  10:\tvcmplt_oqps %%xmm1,%%xmm2,%%xmm3\n' > /tmp/avx-us.txt
            printf '  10:\tverr   %%ax\n' > /tmp/avx-verr.txt
            avx_in /tmp/avx-us.txt; us=$?
            avx_in /tmp/avx-verr.txt; vr=$?
            [ "$us" -eq 1 ] && [ "$vr" -eq 0 ] && ok "AVX matcher self-check: vcmplt_oqps flagged, verr not" \
                || bad "AVX matcher self-check failed (vcmplt_oqps=$us, verr=$vr)"
            # Self-check: the scan must see AVX in a library built with -mavx.
            if printf 'void f(float*a,float*b){for(int i=0;i<64;i++)a[i]+=b[i];}\n' > /tmp/avx.c \
                && c++ -x c++ -O2 -mavx -fPIC -shared -o /tmp/libavx.so /tmp/avx.c 2>/dev/null; then
                avx_scan /tmp/libavx.so
                [ $? -eq 1 ] && ok "AVX scan self-check: detects -mavx code" \
                    || bad "AVX scan self-check: missed AVX in a -mavx library"
            else
                skip "AVX scan self-check: could not build a -mavx library"
            fi
        fi ;;
    *) skip "AVX scan: not an x86-64 image ($(uname -m))" ;;
esac

if [ "$fails" -gt 0 ]; then
    echo "profile: $fails check(s) failed" >&2
    exit 1
fi
echo "profile: OK ($BUILD_PROFILE, ns-$NS3_VERSION)"
