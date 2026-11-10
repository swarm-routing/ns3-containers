#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Downstream canary (ns3-containers#44): build and test every org ns-3 contrib
# module listed in test/downstream.txt on one image, from the runner (or a
# workstation):
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
# Only `debug` images on the Ubuntu base are canaried: that is the image
# every consumer's automatic CI builds against (latest-debug), asserts on.
# The other profiles and bases share ns-3's sources and configure line (rule
# 10) and consumers do not build on them; any other image prints SKIP and
# passes. Each consumer is cloned on the host (public repositories, no
# credential), then staged, built with ns3-build-contrib and tested in its
# own fresh container under a wall-clock budget (DOWNSTREAM_BUDGET seconds,
# default 3600): a consumer that does not finish is a hang and fails.
#
# DOWNSTREAM_FILE  the consumer list (default test/downstream.txt)
# DOWNSTREAM_FAILED  if set, a file that receives one line per failing
#                    consumer: <name> <repo>@<commit> <reason>
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
list=${DOWNSTREAM_FILE:-$repo/test/downstream.txt}
budget=${DOWNSTREAM_BUDGET:-3600}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
failed_file=${DOWNSTREAM_FAILED:-/dev/null}

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Consumers, one per element, fields separated by a unit separator.
entries=()
parse() {
    local n=0 line name src range modules suites stage run
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$(trim "$line")" in ''|'#'*) continue ;; esac
        IFS='|' read -r name src range modules suites stage run <<<"$line"
        name=$(trim "$name"); src=$(trim "$src"); range=$(trim "$range")
        modules=$(trim "$modules"); suites=$(trim "$suites")
        stage=$(trim "$stage"); run=$(trim "${run:-}")
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "$list:$n: bad name '$name'" >&2; return 1; }
        [[ "$src" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[A-Za-z0-9._/-]+$ ]] \
            || { echo "$list:$n: '$src' is not owner/repo@ref" >&2; return 1; }
        [[ "$range" =~ ^[0-9]+\.[0-9]+(\+|-[0-9]+\.[0-9]+)$ ]] \
            || { echo "$list:$n: ns-3 range '$range' is not 3.42+ or 3.36-3.48" >&2; return 1; }
        [ -n "$modules" ] || { echo "$list:$n: no modules" >&2; return 1; }
        for spec in $modules; do
            [[ "$spec" =~ ^[A-Za-z0-9_-]+=[A-Za-z0-9._/-]+$ ]] \
                || { echo "$list:$n: module '$spec' is not name=path" >&2; return 1; }
        done
        entries+=("$name"$'\x1f'"$src"$'\x1f'"$range"$'\x1f'"$modules"$'\x1f'"$suites"$'\x1f'"$stage"$'\x1f'"$run")
    done < "$list"
    [ ${#entries[@]} -gt 0 ] || { echo "$list: no consumer listed" >&2; return 1; }
}

# 0 when ns-3 version $1 is inside range $2 (3.42+ or 3.36-3.48), by minor.
in_range() {
    local v lo hi
    v=$(cut -d. -f1,2 <<<"$1")
    if [[ "$2" == *+ ]]; then lo=${2%+}; hi=$v; else lo=${2%-*}; hi=${2#*-}; fi
    [ "$(printf '%s\n%s\n' "$lo" "$v" | sort -V | head -1)" = "$lo" ] &&
        [ "$(printf '%s\n%s\n' "$v" "$hi" | sort -V | head -1)" = "$v" ]
}

if [ "${1:-}" = --check ]; then
    parse
    for e in "${entries[@]}"; do
        IFS=$'\x1f' read -r name src range _ <<<"$e"
        echo "ok    $name ($src, ns-3 $range)"
    done
    for v in 3.36 3.42 3.48 3.49; do
        in_range "$v" 3.42+ && ok=y || ok=n
        case "$v:$ok" in 3.36:n|3.42:y|3.48:y|3.49:y) ;; *) echo "in_range broken for $v" >&2; exit 1 ;; esac
        in_range "$v" 3.36-3.48 && ok=y || ok=n
        case "$v:$ok" in 3.36:y|3.42:y|3.48:y|3.49:n) ;; *) echo "in_range broken for $v" >&2; exit 1 ;; esac
    done
    echo "downstream.txt: ${#entries[@]} consumers"
    exit 0
fi

[ $# -eq 1 ] || { echo "usage: $0 <image-ref> | --check" >&2; exit 2; }
image=$1
parse

label() { docker image inspect --format "{{ index .Config.Labels \"$1\" }}" "$image"; }
version=$(label org.opencontainers.image.version)
profile=$(label io.github.swarm-routing.ns3.profile)
os=$(label io.github.swarm-routing.ns3.base)

{
    echo "### Downstream canary on \`$image\`"
    echo
} >> "$summary"
if [ "$profile" != debug ] || [ "$os" != ubuntu ]; then
    echo "  SKIP  downstream canary: runs on the ubuntu debug image (this is $os $profile)" | tee -a "$summary"
    exit 0
fi
echo "ns-3 $version ($os $profile)"
{
    echo "ns-3 $version ($os $profile); consumer list: \`${list#"$repo"/}\`"
    echo
    echo "| Consumer | Commit | Result | Time |"
    echo "|---|---|---|---|"
} >> "$summary"

work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/downstream.XXXXXX")
cleanup() {
    # Builds run as root in the container: remove what they wrote from there.
    docker run --rm -v "$work:/w" "$image" find /w -mindepth 1 -delete >/dev/null 2>&1 || true
    rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

# Clone every consumer first: a module's dependency is another line's checkout.
declare -A commit
for e in "${entries[@]}"; do
    IFS=$'\x1f' read -r name src _ <<<"$e"
    slug=${src%@*}; ref=${src#*@}
    dest="$work/$name"
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        git init -q "$dest"
        git -C "$dest" fetch -q --depth 1 "https://github.com/$slug.git" "$ref"
        git -C "$dest" checkout -q FETCH_HEAD
    else
        git clone -q --depth 1 --branch "$ref" "https://github.com/$slug.git" "$dest"
    fi
    commit[$name]=$(git -C "$dest" rev-parse HEAD)
done

# Runs in the image, in /w/<name>. Exit 77: nothing to build yet (skip).
inner=$(cat <<'EOF'
if [ -f ci/canary.sh ]; then
    echo "canary: the consumer's own ci/canary.sh"
    exec bash ci/canary.sh
fi
if [ -n "$C_STAGE" ]; then echo "canary: stage: $C_STAGE"; bash -euo pipefail -c "$C_STAGE"; fi
args=()
for spec in $C_MODULES; do
    d=/w/${spec#*=}
    if [ ! -d "$d" ]; then echo "  SKIP  $C_NAME: no ns-3 module yet (${spec#*=} does not exist)"; exit 77; fi
    args+=("${spec%%=*}=$d")
done
tests=(--test)
for s in $C_SUITES; do tests+=(--suite "$s"); done
ns3-build-contrib "${tests[@]}" "${args[@]}"
if [ -n "$C_RUN" ]; then echo "canary: run: $C_RUN"; bash -euo pipefail -c "$C_RUN"; fi
EOF
)

fails=0
for e in "${entries[@]}"; do
    IFS=$'\x1f' read -r name src range modules suites stage run <<<"$e"
    sha=${commit[$name]}
    short="[\`${sha::7}\`](https://github.com/${src%@*}/commit/$sha)"
    if ! in_range "$version" "$range"; then
        echo "  SKIP  $name: supports ns-3 $range, this is $version"
        echo "| $name | $short | SKIP (supports ns-3 $range) | |" >> "$summary"
        continue
    fi
    echo "::group::downstream: $name ($src at ${sha::7})"
    start=$(date +%s)
    cname="downstream-$name-$$"
    set +e
    timeout "$budget" docker run --rm --name "$cname" -v "$work:/w" -w "/w/$name" \
        -e C_NAME="$name" -e C_MODULES="$modules" -e C_SUITES="$suites" \
        -e C_STAGE="$stage" -e C_RUN="$run" "$image" bash -euo pipefail -c "$inner"
    rc=$?
    set -e
    echo "::endgroup::"
    took=$(( $(date +%s) - start ))
    case "$rc" in
        0)  echo "downstream: $name passed (${took} s)"
            echo "| $name | $short | pass | ${took} s |" >> "$summary" ;;
        77) echo "  SKIP  $name: no ns-3 module yet"
            echo "| $name | $short | SKIP (no ns-3 module yet) | |" >> "$summary" ;;
        124) docker rm -f "$cname" >/dev/null 2>&1 || true
            echo "downstream: $name did not finish within ${budget} s (hang)" >&2
            echo "| $name | $short | **FAIL** (no result within ${budget} s: hang) | ${took} s |" >> "$summary"
            echo "$name ${src%@*}@$sha hang (no result within ${budget} s)" >> "$failed_file"
            fails=$((fails + 1)) ;;
        *)  echo "downstream: $name FAILED (exit $rc)" >&2
            echo "| $name | $short | **FAIL** (exit $rc) | ${took} s |" >> "$summary"
            echo "$name ${src%@*}@$sha exit $rc" >> "$failed_file"
            fails=$((fails + 1)) ;;
    esac
done

[ "$fails" -eq 0 ] || { echo "downstream: $fails consumer(s) failed on $image" >&2; exit 1; }
echo "downstream: every consumer passed or was skipped on $image"
