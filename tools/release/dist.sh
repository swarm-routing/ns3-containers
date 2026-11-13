#!/usr/bin/env bash
# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# dist.sh VERSION OUT-DIR: the release asset, as `make dist` runs it for
# swarm-routing/.github's reusable-release.yml:
#
#   ns3-containers-VERSION.tar.gz   the image pipeline's source at the release:
#                                   ns3-containers-VERSION/ with docker/ (the
#                                   Dockerfile, ns3-build-contrib), test/ (the
#                                   stages, fixtures, suite lists), tools/ (the
#                                   matrix generator and its tests),
#                                   .github/workflows/ (publish-images.yml, the
#                                   pipeline itself, and the other workflows;
#                                   the tools' tests read it), the build
#                                   context's .dockerignore, .hadolint.yaml,
#                                   .trivyignore, README.md, LICENSE,
#                                   LICENSE-MIT, LICENSING.md, CITATION.cff and
#                                   INSTALL.txt
#
# The images are not release assets: ghcr.io/swarm-routing/ns3-dev keeps its
# own pipeline (publish-images.yml) and its own tags (the ns-3 release). The
# release version is the pipeline's, the contract README "Which image" and
# "Building a contrib module" document.
#
# Deterministic: only files tracked by git, entries sorted with a fixed owner
# and the release commit's time, gzip -n.
#
# Then it checks what it built, so a release never ships a tree that does not
# work (the workflow stops before signing or tagging on a non-zero exit): in
# the unpacked tarball, every shell script parses (bash -n), the tools' unit
# tests pass and test/downstream.sh --check accepts the consumer list. No
# docker: an image build is publish-images.yml's (8-15 min per image).
# DIST_CHECK=0 skips the check (a quick local build).
set -euo pipefail
ver=${1:?usage: dist.sh VERSION OUT-DIR}
out=${2:?usage: dist.sh VERSION OUT-DIR}
repo=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
epoch=$(git -C "$repo" log -1 --format=%ct)
name="ns3-containers-$ver"

# --- ns3-containers-VERSION.tar.gz ------------------------------------------
pkg="$tmp/pkg/$name"
mkdir -p "$pkg"
git -C "$repo" ls-files -z -- docker test tools .github/workflows .dockerignore .hadolint.yaml \
        .trivyignore README.md LICENSE LICENSE-MIT LICENSING.md CITATION.cff |
    (cd "$repo" && xargs -0 cp --parents -t "$pkg")
cat > "$pkg/INSTALL.txt" <<TXT
ns3-containers $ver (swarm-routing/ns3-containers): the pipeline behind
ghcr.io/swarm-routing/ns3-dev, ns-3 configured and built at /opt/ns-3 so a
contrib module compiles alone. docker/, test/*.sh and tools/ are MIT OR
GPL-2.0-only; the rest, and the images, GPL-2.0-only (LICENSING.md).

The published images are the way to use it (README.md "Which image"):

  docker pull ghcr.io/swarm-routing/ns3-dev:latest-debug

Build one image from this tree and run every test stage on it:

  ver=3.48   # an ns-3 release (tools/ns3_matrix.py lists the supported one)
  docker build -f docker/Dockerfile --build-arg NS3_VERSION="\$ver" \\
      --build-arg BUILD_PROFILE=debug -t "ns3-dev:\$ver-debug" .
  EXPECT_VERSION="\$ver" EXPECT_PROFILE=debug EXPECT_OS=ubuntu \\
      test/run.sh "ns3-dev:\$ver-debug"

The release versions the pipeline and its contract (tags, profiles, bases,
ns3-build-contrib); the image tags stay the ns-3 release.
Source: https://github.com/swarm-routing/ns3-containers/tree/v$ver
TXT
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${epoch}" \
    -C "$tmp/pkg" -cf - "$name" | gzip -n > "$out/$name.tar.gz"
ls -l "$out"

[ "${DIST_CHECK:-1}" = 0 ] && { echo "dist.sh: DIST_CHECK=0, the tarball is not checked"; exit 0; }

# --- check: the unpacked tree's scripts parse, its tools pass, its list holds -
mkdir -p "$tmp/check"
tar -xzf "$out/$name.tar.gz" -C "$tmp/check"
cd "$tmp/check/$name"
while IFS= read -r -d '' f; do bash -n "$f"; done < <(find . -name '*.sh' -print0)
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools
test/downstream.sh --check
echo "dist.sh: $name.tar.gz unpacks, its scripts parse, its tools' tests pass, its consumer list holds"
