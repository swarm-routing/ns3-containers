#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Image smoke test, run inside an ns3-dev image with this repo mounted at /src:
#
#   docker run --rm -v "$PWD:/src:ro" ghcr.io/swarm-routing/ns3-dev:latest-debug \
#       bash /src/test/smoke.sh
#
# Proves the three things downstream repos rely on:
#   1. ns3-build-contrib builds a mounted contrib module (C++17..C++23, the
#      tree's own standard) and its test
#      suite passes under test.py;
#   2. the cache is warm: Ninja's step count for that build stays small, i.e.
#      the stock libraries were NOT recompiled. A configure-flag drift between
#      the Dockerfile and the script would show up here as a full rebuild.
#   3. the guard against a module named `core` holds;
#   4. --strict-warnings judges the module's own code only: the fixture passes,
#      a planted -Wshadow fails (in a source, and in its own header reached
#      through the ns3/ include tree), a dependency left out by
#      --quality-modules is not judged, a call to a [[deprecated]] function
#      warns without failing (a dependency's two-step deprecation must not
#      break a consumer, #167), and the build stays incremental;
#   5. --coverage instruments the module: its .gcda files appear after the tests,
#      and the image's gcovr (debug, sanitized) reports them.
set -euo pipefail

MAX_STEPS=${MAX_STEPS:-40}

work=$(mktemp -d)
cp -r /src/test/fixtures/swarm-hello "$work/"

log=$(mktemp)
ns3-build-contrib --test "$work/swarm-hello" 2>&1 | tee "$log"

# Ninja prints "[done/total] ..." per step; the largest total is the build size.
steps=$(grep -oE '^\[[0-9]+/[0-9]+\]' "$log" | sed -E 's#.*/([0-9]+)\]#\1#' | sort -n | tail -1)
echo "smoke: ninja steps for the contrib build = ${steps:-0} (max $MAX_STEPS)"
if [ "${steps:-0}" -gt "$MAX_STEPS" ]; then
    echo "FAIL: warm cache missed — ${steps} steps means the stock tree was rebuilt" >&2
    exit 1
fi

mkdir -p "$work/core"
cp /src/test/fixtures/swarm-hello/CMakeLists.txt "$work/core/"
if ns3-build-contrib "$work/core" >/dev/null 2>&1; then
    echo "FAIL: a contrib module named 'core' was accepted" >&2
    exit 1
fi
steps_of() { grep -oE '^\[[0-9]+/[0-9]+\]' "$1" | sed -E 's#.*/([0-9]+)\]#\1#' | sort -n | tail -1; }

ns3-build-contrib --strict-warnings --test "$work/swarm-hello" > "$log" 2>&1 || {
    cat "$log"; echo "FAIL: the fixture does not build under --strict-warnings" >&2; exit 1; }
steps=$(steps_of "$log")
if [ "${steps:-0}" -gt "$MAX_STEPS" ]; then
    echo "FAIL: --strict-warnings rebuilt the stock tree (${steps} steps)" >&2; exit 1
fi
echo "smoke: --strict-warnings builds the fixture (${steps:-0} steps)"

shadow="$work/shadow/swarm-hello"
mkdir -p "$work/shadow" && cp -r "$work/swarm-hello" "$shadow"
cat >> "$shadow/model/swarm-hello.cc" <<'CXX'
namespace ns3 {
int SwarmHelloShadow(int x) { int y = x; { int y = 2; x += y; } return x + y; }
}  // namespace ns3
CXX
if ns3-build-contrib --strict-warnings "$shadow" > "$log" 2>&1; then
    echo "FAIL: --strict-warnings accepted a shadowed local" >&2; exit 1
fi
grep -q -- '-Werror=shadow' "$log" || { cat "$log"; echo "FAIL: the strict build failed, but not on -Wshadow" >&2; exit 1; }
echo "smoke: --strict-warnings rejects a planted -Wshadow"

# The same shadow in the module's own header, included as ns3/swarm-hello.h:
# ns-3's ns3/ tree is -isystem under --strict-warnings, so this proves the
# module's own headers keep their non-system wrappers.
hdr="$work/hdr/swarm-hello"
mkdir -p "$work/hdr" && cp -r "$work/swarm-hello" "$hdr"
sed -i 's|#include "swarm-hello.h"|#include "ns3/swarm-hello.h"|' "$hdr/model/swarm-hello.cc"
sed -i 's|^}  // namespace ns3|inline int SwarmHelloShadowH(int x) { int y = x; { int y = 2; x += y; } return x + y; }\n&|' "$hdr/model/swarm-hello.h"
if ns3-build-contrib --strict-warnings "$hdr" > "$log" 2>&1; then
    echo "FAIL: --strict-warnings accepted a shadowed local in the module's own header (ns3/ include)" >&2; exit 1
fi
grep -q -- '-Werror=shadow' "$log" || { cat "$log"; echo "FAIL: the strict build failed, but not on -Wshadow" >&2; exit 1; }
echo "smoke: --strict-warnings judges the module's own header through ns3/"

# The same for an exported .hpp header (ns-3 exports whatever HEADER_FILES
# lists, not only .h).
hpp="$work/hpp/swarm-hello"
mkdir -p "$work/hpp" && cp -r "$work/swarm-hello" "$hpp"
printf '#pragma once\nnamespace ns3 {\ninline int SwarmHelloShadowHpp(int x) { int y = x; { int y = 2; x += y; } return x + y; }\n}  // namespace ns3\n' > "$hpp/model/swarm-hello-extra.hpp"
sed -i 's|HEADER_FILES model/swarm-hello.h|HEADER_FILES model/swarm-hello.h model/swarm-hello-extra.hpp|' "$hpp/CMakeLists.txt"
sed -i 's|#include "swarm-hello.h"|#include "swarm-hello.h"\n#include "ns3/swarm-hello-extra.hpp"|' "$hpp/model/swarm-hello.cc"
if ns3-build-contrib --strict-warnings "$hpp" > "$log" 2>&1; then
    echo "FAIL: --strict-warnings accepted a shadowed local in the module's own .hpp header" >&2; exit 1
fi
grep -q -- '-Werror=shadow' "$log" || { cat "$log"; echo "FAIL: the strict build failed, but not on -Wshadow" >&2; exit 1; }
echo "smoke: --strict-warnings judges the module's own .hpp header through ns3/"

# A call to a [[deprecated]] function stays a warning (#167): a dependency
# that deprecates before it removes (swarm-core's two-step policy) must not
# break its consumers' strict builds. The declaration sits in the module's own
# header, reached through ns3/; the call is in its source.
dep_call="$work/deprecated/swarm-hello"
mkdir -p "$work/deprecated" && cp -r "$work/swarm-hello" "$dep_call"
sed -i 's|#include "swarm-hello.h"|#include "ns3/swarm-hello.h"|' "$dep_call/model/swarm-hello.cc"
sed -i 's|^}  // namespace ns3|[[deprecated("use SwarmHelloReadLe16")]] inline int SwarmHelloOld() { return 1; }\n&|' "$dep_call/model/swarm-hello.h"
cat >> "$dep_call/model/swarm-hello.cc" <<'CXX'
namespace ns3 {
int SwarmHelloCallsOld() { return SwarmHelloOld(); }
}  // namespace ns3
CXX
ns3-build-contrib --strict-warnings --test "$dep_call" > "$log" 2>&1 || {
    cat "$log"; echo "FAIL: --strict-warnings made a deprecated call an error" >&2; exit 1; }
grep -q -- '\[-Wdeprecated-declarations\]' "$log" || {
    cat "$log"; echo "FAIL: the deprecated call built without its warning" >&2; exit 1; }
steps=$(steps_of "$log")
if [ "${steps:-0}" -gt "$MAX_STEPS" ]; then
    echo "FAIL: the deprecated-call build rebuilt the stock tree (${steps} steps)" >&2; exit 1
fi
echo "smoke: --strict-warnings keeps a deprecated call a warning"

# The exception is that one warning only: the same module with a shadowed
# local added still fails, on -Wshadow.
cat >> "$dep_call/model/swarm-hello.cc" <<'CXX'
namespace ns3 {
int SwarmHelloShadowD(int x) { int y = x; { int y = 2; x += y; } return x + y; }
}  // namespace ns3
CXX
if ns3-build-contrib --strict-warnings "$dep_call" > "$log" 2>&1; then
    echo "FAIL: --strict-warnings accepted a shadowed local next to a deprecated call" >&2; exit 1
fi
grep -q -- '-Werror=shadow' "$log" || { cat "$log"; echo "FAIL: the strict build failed, but not on -Wshadow" >&2; exit 1; }
echo "smoke: --strict-warnings still rejects a planted -Wshadow next to a deprecated call"

# A private header that shares a stock header's name gets no wrapper: if it
# did, it would shadow ns3/packet.h (pulled in by the fixture's test suite)
# and the #error would fire.
priv="$work/priv/swarm-hello"
mkdir -p "$work/priv" && cp -r "$work/swarm-hello" "$priv"
printf '#error "private packet.h must not shadow ns3/packet.h"\n' > "$priv/model/packet.h"
ns3-build-contrib --strict-warnings --test "$priv" > "$log" 2>&1 || {
    cat "$log"; echo "FAIL: a private header shadowed a stock ns3/ header under --strict-warnings" >&2; exit 1; }
echo "smoke: --strict-warnings wraps exported headers only"

# A dependency built alongside but left out by --quality-modules is not
# judged: the shadowed header becomes module swarm-dep, the clean fixture the
# module under test.
dep="$work/dep/swarm-dep"
mkdir -p "$work/dep" && cp -r "$hdr" "$dep"
for f in "$dep"/model/swarm-hello.* "$dep"/test/swarm-hello-test-suite.cc; do mv "$f" "${f//swarm-hello/swarm-dep}"; done
find "$dep" -type f -exec sed -i 's/swarm-hello/swarm-dep/g; s/SwarmHello/SwarmDep/g; s/SWARM_HELLO/SWARM_DEP/g' {} +
ns3-build-contrib --strict-warnings --quality-modules swarm-hello "$dep" "$work/swarm-hello" > "$log" 2>&1 || {
    cat "$log"; echo "FAIL: --quality-modules still judged the dependency" >&2; exit 1; }
if ns3-build-contrib --quality-modules nope "$work/swarm-hello" > "$log" 2>&1; then
    echo "FAIL: --quality-modules accepted a module that was not given" >&2; exit 1
fi
echo "smoke: --quality-modules leaves a dependency unjudged"

ns3-build-contrib --coverage --test "$work/swarm-hello" > "$log" 2>&1 || {
    cat "$log"; echo "FAIL: --coverage build or tests failed" >&2; exit 1; }
gcda=$(find "$NS3DIR/cmake-cache/contrib/swarm-hello" -name '*.gcda' | wc -l)
[ "$gcda" -gt 0 ] || { echo "FAIL: --coverage left no .gcda for the module" >&2; exit 1; }
other=$(find "$NS3DIR/cmake-cache/src" -name '*.gcda' 2>/dev/null | wc -l)
[ "$other" = 0 ] || { echo "FAIL: --coverage instrumented stock ns-3 ($other .gcda under src/)" >&2; exit 1; }
echo "smoke: --coverage instruments the module only ($gcda .gcda files)"
if command -v gcovr >/dev/null; then
    # The report as reusable-ns3-ci.yml's coverage leg makes it, from the build tree.
    (cd "$NS3DIR/cmake-cache" && gcovr --root "$work/swarm-hello" --filter "$work/swarm-hello/" \
        --txt --print-summary .) > "$log" 2>&1 || {
        cat "$log"; echo "FAIL: gcovr could not report the module's coverage" >&2; exit 1; }
    if ! grep -q 'swarm-hello\.cc' "$log" || ! grep -qE '^lines: [0-9.]+%' "$log"; then
        cat "$log"; echo "FAIL: gcovr's report names no module source or line rate" >&2; exit 1
    fi
    echo "smoke: gcovr reports the module ($(grep -E '^lines:' "$log"))"
fi

echo "smoke: OK (profile ${BUILD_PROFILE}, ns-${NS3_VERSION})"
