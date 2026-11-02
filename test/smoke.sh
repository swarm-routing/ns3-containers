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
#      a planted -Wshadow fails, and the build stays incremental;
#   5. --coverage instruments the module: its .gcda files appear after the tests.
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

ns3-build-contrib --coverage --test "$work/swarm-hello" > "$log" 2>&1 || {
    cat "$log"; echo "FAIL: --coverage build or tests failed" >&2; exit 1; }
gcda=$(find "$NS3DIR/cmake-cache/contrib/swarm-hello" -name '*.gcda' | wc -l)
[ "$gcda" -gt 0 ] || { echo "FAIL: --coverage left no .gcda for the module" >&2; exit 1; }
other=$(find "$NS3DIR/cmake-cache/src" -name '*.gcda' 2>/dev/null | wc -l)
[ "$other" = 0 ] || { echo "FAIL: --coverage instrumented stock ns-3 ($other .gcda under src/)" >&2; exit 1; }
echo "smoke: --coverage instruments the module only ($gcda .gcda files)"

echo "smoke: OK (profile ${BUILD_PROFILE}, ns-${NS3_VERSION})"
