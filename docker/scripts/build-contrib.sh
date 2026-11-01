#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Henrique Joppi
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# ns3-build-contrib — link one or more contrib modules into the image's warm
# ns-3 tree, configure with the image's own flags, build incrementally, and
# optionally run the modules' test suites.
#
#   ns3-build-contrib [options] <module-dir> [<module-dir> ...]
#
#   --test             run `test.py -s <suite>` after the build (suites default
#                      to the module names; override with --suite)
#   --suite NAME       a test suite to run (repeatable; implies --test)
#   --modules "a;b"    extra stock ns-3 modules to enable (e.g. "mesh;lte");
#                      note: a module outside the image's list is compiled here
#   --run "PROG ARGS"  `./ns3 run` a program after the build (repeatable)
#
# A module's name is its directory's basename, and must match the `LIBNAME` of
# its `build_lib()` call (e.g. swarm-core/ -> libns3.43-swarm-core). List
# dependencies first: `ns3-build-contrib /src/ns3-swarm-core /src/ARA/ns3`
# only works if the second directory is named for its module, so mount or
# check out as `.../ara`, or pass `name=dir` (e.g. `ara=/src/ARA/ns3`).
#
# Why this is fast: the image's tree was configured with the identical profile
# flags, module list and --enable-tests/--enable-examples, so the only thing
# that changes is the contrib list and the examples/tests filter. Neither alters
# a stock library's compile command, so Ninja rebuilds nothing but the new
# module. Changing the profile flags here would force a full rebuild, so this
# script never takes them as an option.
set -euo pipefail

NS3DIR=${NS3DIR:-/opt/ns-3}
ENVFILE="$NS3DIR/.swarm-configure.env"

die() { echo "ns3-build-contrib: $*" >&2; exit 2; }
usage() { sed -n '5,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[ -f "$ENVFILE" ] || die "$ENVFILE missing: not a swarm-routing ns3-dev image?"
# shellcheck source=/dev/null
. "$ENVFILE"

run_tests=0
suites=()
runs=()
extra_modules=""
dirs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --test) run_tests=1 ;;
        --suite) [ $# -ge 2 ] || die "--suite needs a value"; suites+=("$2"); run_tests=1; shift ;;
        --modules) [ $# -ge 2 ] || die "--modules needs a value"; extra_modules="$2"; shift ;;
        --run) [ $# -ge 2 ] || die "--run needs a value"; runs+=("$2"); shift ;;
        -h|--help) usage 0 ;;
        -*) die "unknown option: $1" ;;
        *) dirs+=("$1") ;;
    esac
    shift
done
[ ${#dirs[@]} -gt 0 ] || usage 2

names=()
for spec in "${dirs[@]}"; do
    case "$spec" in
        *=*) name=${spec%%=*}; dir=${spec#*=} ;;
        *) dir=$spec; name=$(basename "$(cd "$dir" 2>/dev/null && pwd)") ;;
    esac
    [ -d "$dir" ] || die "not a directory: $dir"
    dir=$(cd "$dir" && pwd)
    [ -f "$dir/CMakeLists.txt" ] || die "$dir has no CMakeLists.txt"
    case "$name" in
        core) die "a contrib module must not be named 'core' (collides with src/core); use e.g. swarm-core" ;;
    esac
    [ -e "$NS3DIR/src/$name" ] && die "'$name' collides with the stock module src/$name"
    link="$NS3DIR/contrib/$name"
    if [ -L "$link" ]; then
        rm "$link"
    elif [ -e "$link" ]; then
        die "$link exists and is not a symlink; refusing to replace it"
    fi
    ln -s "$dir" "$link"
    echo "ns3-build-contrib: contrib/$name -> $dir"
    names+=("$name")
done

contrib_list=$(IFS=';'; echo "${names[*]}")
modules="$NS3_MODULES;$contrib_list"
[ -n "$extra_modules" ] && modules="$modules;$extra_modules"

cd "$NS3DIR"
# Same flags as the Dockerfile, except the examples/tests filter.
# shellcheck disable=SC2086  # NS3_PROFILE_FLAGS word-splits on purpose
./ns3 configure -G Ninja $NS3_PROFILE_FLAGS --enable-examples --enable-tests \
    --disable-werror --filter-module-examples-and-tests="$contrib_list" \
    --enable-modules="$modules"
start=$(date +%s)
./ns3 build
echo "ns3-build-contrib: build took $(( $(date +%s) - start )) s (profile $BUILD_PROFILE, ns-$NS3_VERSION)"

if [ "$run_tests" = 1 ]; then
    [ ${#suites[@]} -gt 0 ] || suites=("${names[@]}")
    for s in "${suites[@]}"; do
        ./test.py --no-build --verbose-failed -s "$s"
    done
fi
for r in "${runs[@]}"; do
    ./ns3 run --no-build "$r"
done
