#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
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
#   --strict-warnings  compile the given modules (only) with -Wall -Wextra
#                      -Wpedantic -Wshadow ... -Werror; ns-3's headers exempt;
#                      a deprecated call stays a warning
#                      (-Wno-error=deprecated-declarations)
#   --coverage         compile and link the given modules (only) with --coverage
#                      (gcov); .gcda files land under $NS3DIR/cmake-cache
#   --quality-modules "a;b"  apply the two options above to these modules only
#                      (default: every module given), e.g. to leave out a
#                      dependency built alongside the module under test
#
# A module's name is its directory's basename, and must match the `LIBNAME` of
# its `build_lib()` call (e.g. swarm-core/ -> libns3.49-swarm-core). List
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
usage() { sed -n '5,29p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[ -f "$ENVFILE" ] || die "$ENVFILE missing: not a swarm-routing ns3-dev image?"
# shellcheck source=/dev/null
. "$ENVFILE"

HOOK=${NS3_BUILD_CONTRIB_HOOK:-/usr/local/share/ns3-build-contrib/swarm-quality.cmake}

run_tests=0
strict=OFF
coverage=OFF
suites=()
runs=()
extra_modules=""
quality_modules=""
dirs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --test) run_tests=1 ;;
        --suite) [ $# -ge 2 ] || die "--suite needs a value"; suites+=("$2"); run_tests=1; shift ;;
        --modules) [ $# -ge 2 ] || die "--modules needs a value"; extra_modules="$2"; shift ;;
        --run) [ $# -ge 2 ] || die "--run needs a value"; runs+=("$2"); shift ;;
        --strict-warnings) strict=ON ;;
        --coverage) coverage=ON ;;
        --quality-modules) [ $# -ge 2 ] || die "--quality-modules needs a value"; quality_modules=$2; shift ;;
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
if [ -n "$quality_modules" ]; then
    IFS=';' read -ra qm <<< "$quality_modules"
    for q in "${qm[@]}"; do
        case ";$contrib_list;" in *";$q;"*) ;; *) die "--quality-modules: '$q' is not one of the modules given ($contrib_list)" ;; esac
    done
else
    quality_modules=$contrib_list
fi

[ -f "$HOOK" ] || die "quality hook $HOOK missing"

cd "$NS3DIR"
# Same flags as the Dockerfile, except the examples/tests filter. The quality
# hook's cache variables are always passed (OFF unless asked), so a previous
# call's ON never lingers; they change only the contrib modules' targets.
# shellcheck disable=SC2086  # NS3_PROFILE_FLAGS word-splits on purpose
./ns3 configure -G Ninja $NS3_PROFILE_FLAGS --enable-examples --enable-tests \
    --disable-werror --filter-module-examples-and-tests="$contrib_list" \
    --enable-modules="$modules" \
    -- -DCMAKE_PROJECT_INCLUDE="$HOOK" -DSWARM_CONTRIB_MODULES="$quality_modules" \
    -DSWARM_STRICT_WARNINGS="$strict" -DSWARM_COVERAGE="$coverage"
start=$(date +%s)
./ns3 build
echo "ns3-build-contrib: build took $(( $(date +%s) - start )) s (profile $BUILD_PROFILE, ns-$NS3_VERSION; strict-warnings $strict, coverage $coverage)"

if [ "$run_tests" = 1 ]; then
    [ ${#suites[@]} -gt 0 ] || suites=("${names[@]}")
    for s in "${suites[@]}"; do
        ./test.py --no-build --verbose-failed -s "$s"
    done
fi
for r in "${runs[@]}"; do
    ./ns3 run --no-build "$r"
done
