#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT
#
# Image smoke test, run inside an ns3-dev image with this repo mounted at /src:
#
#   docker run --rm -v "$PWD:/src:ro" ghcr.io/swarm-routing/ns3-dev:3.43-debug \
#       bash /src/test/smoke.sh
#
# Proves the three things downstream repos rely on:
#   1. ns3-build-contrib builds a mounted C++20 contrib module and its test
#      suite passes under test.py;
#   2. the cache is warm: Ninja's step count for that build stays small, i.e.
#      the stock libraries were NOT recompiled. A configure-flag drift between
#      the Dockerfile and the script would show up here as a full rebuild.
#   3. the guard against a module named `core` holds.
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
echo "smoke: OK (profile ${BUILD_PROFILE}, ns-${NS3_VERSION})"
