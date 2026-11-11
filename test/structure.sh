#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Image structure test (ns3-containers#39), run inside an ns3-dev image:
#
#   docker run --rm -e EXPECT_VERSION=3.49 -e EXPECT_PROFILE=debug -e EXPECT_OS=ubuntu \
#       -v "$PWD:/src:ro" <image> bash /src/test/structure.sh
#
# Checks the contract the README promises downstream users: the pre-built tree
# at /opt/ns-3, ns3-build-contrib on PATH, the image's environment, the
# recorded configure line, and that the tree was configured the way its
# profile says (read back from CMake's cache, not from our own record), in the
# C++ standard that ns-3 release requires (read from the tree itself, never
# from a version list). EXPECT_* come from the pipeline's matrix entry; unset,
# that comparison is skipped and says so.
# ok() always returns 0, so `test && ok ... || bad ...` is a true if/else here.
# shellcheck disable=SC2015
set -uo pipefail

fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*" >&2; fails=$((fails + 1)); }
skip() { echo "  SKIP  $*"; }

NS3=${NS3DIR:-/opt/ns-3}
cache="$NS3/cmake-cache/CMakeCache.txt"
ninja="$NS3/cmake-cache/build.ninja"

echo "structure: tree and tools"
[ -x "$NS3/ns3" ] && ok "$NS3/ns3" || bad "$NS3/ns3 missing or not executable"
[ -f "$cache" ] && ok "configured ($cache)" || bad "$cache missing: tree not configured"
if compgen -G "$NS3/build/lib/libns3*-core*.so" >/dev/null; then
    ok "built: $(basename "$(compgen -G "$NS3/build/lib/libns3*-core*.so" | head -1)")"
else
    bad "no libns3*-core*.so in $NS3/build/lib: tree not built"
fi
p=$(command -v ns3-build-contrib) && [ -x "$p" ] && ok "ns3-build-contrib on PATH ($p)" \
    || bad "ns3-build-contrib not on PATH"

echo "structure: environment"
for v in NS3_VERSION BUILD_PROFILE BASE_OS NS3DIR; do
    [ -n "${!v:-}" ] && ok "$v=${!v}" || bad "$v is not set"
done
expect() {  # expect NAME ACTUAL EXPECTED-VAR
    local want=${!3:-}
    if [ -z "$want" ]; then skip "$1: no $3 given"; return; fi
    [ "$2" = "$want" ] && ok "$1 = $want" || bad "$1 = '$2', expected '$want'"
}
expect NS3_VERSION "${NS3_VERSION:-}" EXPECT_VERSION
expect BUILD_PROFILE "${BUILD_PROFILE:-}" EXPECT_PROFILE
expect BASE_OS "${BASE_OS:-}" EXPECT_OS

echo "structure: recorded configure line (.swarm-configure.env)"
envfile="$NS3/.swarm-configure.env"
if [ -f "$envfile" ]; then
    # shellcheck source=/dev/null
    rec=$(. "$envfile"; printf '%s|%s|%s|%s' "$NS3_VERSION" "$BUILD_PROFILE" "$NS3_PROFILE_FLAGS" "$NS3_MODULES")
    IFS='|' read -r r_ver r_prof r_flags r_mods <<<"$rec"
    [ "$r_ver" = "${NS3_VERSION:-}" ] && ok "records NS3_VERSION=$r_ver" || bad "records NS3_VERSION=$r_ver, image says ${NS3_VERSION:-}"
    [ "$r_prof" = "${BUILD_PROFILE:-}" ] && ok "records BUILD_PROFILE=$r_prof" || bad "records BUILD_PROFILE=$r_prof, image says ${BUILD_PROFILE:-}"
    case "${BUILD_PROFILE:-}" in
        default)   want="-d default" ;;
        optimized) want="-d release" ;;   # rule 11: never ns-3's `-d optimized`
        debug)     want="-d debug" ;;
        sanitized) want="-d debug --enable-sanitizers" ;;
        *)         want="" ;;
    esac
    [ -n "$want" ] && [ "$r_flags" = "$want" ] && ok "profile flags '$r_flags'" || bad "profile flags '$r_flags', expected '$want'"
    want_mods=$(sed -n 's/^ARG NS3_MODULES="\(.*\)"$/\1/p' /src/docker/Dockerfile 2>/dev/null)
    if [ -z "$r_mods" ]; then
        bad "no NS3_MODULES recorded"
    elif [ -z "$want_mods" ]; then
        skip "module list: no /src/docker/Dockerfile to compare with"
    elif [ "$r_mods" = "$want_mods" ]; then
        ok "module list = the Dockerfile's (${r_mods//;/ })"
    else
        bad "module list '$r_mods' differs from the Dockerfile's '$want_mods'"
    fi
    missing=""
    IFS=';' read -ra mods <<<"$r_mods"
    for m in "${mods[@]}"; do
        compgen -G "$NS3/build/lib/libns3*-${m}*.so" >/dev/null || missing="$missing $m"
    done
    [ -z "$missing" ] && ok "every listed module's library is built" || bad "listed but not built:$missing"
else
    bad "$envfile missing: ns3-build-contrib cannot reuse the configure line"
fi

echo "structure: CMake cache matches the profile"
cachevar() { sed -n "s/^$1:[A-Z]*=//p" "$cache" 2>/dev/null | head -1; }
check_cache() {  # check_cache VAR WANT
    local got
    got=$(cachevar "$1")
    if [ -z "$got" ]; then skip "$1 not in this release's CMake cache"; return; fi
    [ "$got" = "$2" ] && ok "$1=$got" || bad "$1=$got, expected $2"
}
case "${BUILD_PROFILE:-}" in
    default)   bt=default; on=ON;  san=OFF ;;
    debug)     bt=debug;   on=ON;  san=OFF ;;
    sanitized) bt=debug;   on=ON;  san=ON ;;
    optimized) bt=release; on=OFF; san=OFF ;;
    *)         bt=""; on=""; san="" ;;
esac
if [ -n "$bt" ]; then
    check_cache CMAKE_BUILD_TYPE "$bt"
    check_cache NS3_ASSERT "$on"
    check_cache NS3_LOG "$on"
    check_cache NS3_SANITIZE "$san"
fi
check_cache NS3_NATIVE_OPTIMIZATIONS OFF   # rule 11: no -march=native in any image
check_cache NS3_EXAMPLES ON                # rule 10: the shared configure line
check_cache NS3_TESTS ON
check_cache NS3_WARNINGS_AS_ERRORS OFF

echo "structure: pre-built unit test libraries (debug and sanitized: the full group)"
case "${BUILD_PROFILE:-}" in
    debug|sanitized)
        full=$(awk '{sub(/#.*/, "")} $1 == "full" {$1=""; print}' /src/test/ns3-suites.txt 2>/dev/null | xargs)
        if [ -z "$full" ]; then
            bad "no full group in /src/test/ns3-suites.txt: cannot check the pre-built test libraries"
        else
            missing=""
            for m in $full; do
                compgen -G "$NS3/build/lib/libns3*-${m}-test*.so" >/dev/null || missing="$missing $m"
            done
            [ -z "$missing" ] && ok "test libraries of the full group built ($full)" \
                || bad "test libraries not pre-built:$missing (docker/Dockerfile NS3_TEST_MODULES)"
        fi
        [ -x "$(compgen -G "$NS3/build/utils/*test-runner*" | grep -v '\.real$' | head -1)" ] \
            && ok "test-runner built" || bad "no test-runner in $NS3/build/utils" ;;
    *) skip "the ${BUILD_PROFILE:-?} profile builds its unit test libraries in the unit stage" ;;
esac

echo "structure: gcovr (debug and sanitized only)"
want_gcovr=$(sed -n 's/^gcovr==//p' /src/docker/gcovr-requirements.in 2>/dev/null)
case "${BUILD_PROFILE:-}" in
    debug|sanitized)
        if got_gcovr=$(gcovr --version 2>/dev/null | sed -n '1s/^gcovr //p') && [ -n "$got_gcovr" ]; then
            if [ -z "$want_gcovr" ]; then
                ok "gcovr $got_gcovr (no /src/docker/gcovr-requirements.in to compare with)"
            elif [ "$got_gcovr" = "$want_gcovr" ]; then
                ok "gcovr $got_gcovr, the pinned version"
            else
                bad "gcovr $got_gcovr, docker/gcovr-requirements.in pins $want_gcovr"
            fi
        else
            bad "gcovr missing or does not run: the coverage leg would fall back to apt"
        fi ;;
    *)
        if command -v gcovr >/dev/null; then
            bad "gcovr is on the ${BUILD_PROFILE:-?} profile: only debug and sanitized carry it"
        else
            ok "no gcovr on the ${BUILD_PROFILE:-?} profile"
        fi ;;
esac

if [ "${BUILD_PROFILE:-}" = debug ]; then
    echo "structure: SonarQube scan tools (debug: unzip, curl, gpg; ns3-containers#88)"
    for tool in unzip curl gpg; do
        # unzip has no --version; -v prints its version and exits 0.
        if "$tool" --version >/dev/null 2>&1 || "$tool" -v >/dev/null 2>&1; then
            ok "$tool runs"
        else
            bad "$tool missing or does not run: reusable-ns3-ci's sonar step would fall back to apt"
        fi
    done
fi

echo "structure: C++ standard and compiler"
macros="$NS3/build-support/macros-and-definitions.cmake"
need=$(grep -oE 'set\(CMAKE_CXX_STANDARD_MINIMUM [0-9]+' "$macros" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
used=$(grep -oE -- '-std=(c|gnu)\+\+[0-9a-z]+' "$ninja" 2>/dev/null | sort -u)
if [ -z "$need" ]; then
    skip "this release does not declare CMAKE_CXX_STANDARD_MINIMUM"
elif [ -z "$used" ]; then
    bad "no -std= flag found in $ninja"
elif [ "$(printf '%s\n' "$used" | wc -l)" -ne 1 ]; then
    bad "mixed standards in the build: $(echo "$used" | tr '\n' ' ')"
elif [ "${used##*++}" = "$need" ]; then
    ok "C++$need, as the tree requires ($used)"
else
    bad "built with $used, the tree requires C++$need"
fi
cxx=$(sed -n 's/^CMAKE_CXX_COMPILER:FILEPATH=//p' "$cache" 2>/dev/null)
if [ -n "$cxx" ] && "$cxx" --version >/dev/null 2>&1; then
    ok "compiler: $("$cxx" --version | head -1)"
else
    bad "compiler '$cxx' from the CMake cache does not run"
fi

if [ "$fails" -gt 0 ]; then
    echo "structure: $fails check(s) failed" >&2
    exit 1
fi
echo "structure: OK (ns-${NS3_VERSION:-?}, ${BUILD_PROFILE:-?}, ${BASE_OS:-?})"
