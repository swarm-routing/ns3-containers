#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Downstream canary (#44): build and test every org ns-3 contrib module listed
# in test/downstream.txt on one image:
#
#   test/downstream.sh <image-ref>     run the canary
#   test/downstream.sh --check         validate test/downstream.txt (no docker)
#
# <image-ref> is the candidate digest the pipeline just tested with
# test/run.sh. `latest-*` moves only when every consumer passes here, so a
# release that breaks the org's modules (#35: ns-3.49's AODV hung
# AntHocNet's CI for hours) is found while `latest` still points at the
# previous good digest.
#
# The work is swarm-routing/.github's tools/downstream/downstream.sh (moved
# there from here, swarm-routing/.github#482), the script a library's release
# dry run also runs on its consumers, so the two checks share one code path;
# its header documents the list's columns, the Ubuntu-debug-only rule, the
# budget (DOWNSTREAM_BUDGET) and DOWNSTREAM_FAILED. It is found at
# ORG_TOOLS_DIR (the workflow checks swarm-routing/.github out there), else
# ../.github next to this checkout.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
org=${ORG_TOOLS_DIR:-$repo/../.github}
script=$org/tools/downstream/downstream.sh
[ -f "$script" ] || {
    echo "downstream: $script not found: check swarm-routing/.github out next to this repository, or set ORG_TOOLS_DIR" >&2
    exit 2
}
export DOWNSTREAM_FILE=${DOWNSTREAM_FILE:-$repo/test/downstream.txt}
export DOWNSTREAM_TITLE=${DOWNSTREAM_TITLE:-Downstream canary}
exec bash "$script" "$@"
