# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Pre-built ns-3 for swarm-routing contrib modules.
#
#   docker build -f docker/Dockerfile \
#       --build-arg NS3_VERSION=3.49 --build-arg BUILD_PROFILE=debug \
#       -t ghcr.io/swarm-routing/ns3-dev:3.49-debug .
#
# NS3_VERSION is the upstream tag without its `ns-` prefix (3.46.1 for a patch
# release). BASE_IMAGE/BASE_OS pick the base; the publish workflow passes them
# from tools/ns3_matrix.py, which holds every base's digest (invariant 13).
#
# BUILD_PROFILE:
#   default    ns-3's own `-d default`: -Os -g with asserts and NS_LOG on. The
#              plain `:<ver>` tag; what a tree configured without `-d` gets.
#   optimized  ns-3's `-d release`: -O3, asserts and NS_LOG compiled out. For
#              benchmark campaigns only. Deliberately NOT `-d optimized`, which
#              adds -march=native -mtune=native: an image built on one runner's
#              CPU can then die with SIGILL on another.
#   debug      `-d debug`: asserts + NS_LOG on. What CI should consume; asserts
#              have caught real bugs (AntHocNet #123).
#   sanitized  `-d debug --enable-sanitizers` (ASan + LSan + UBSan,
#              -fno-sanitize-recover=all).
#
# The tree at /opt/ns-3 is configured once with the exact flags that
# ns3-build-contrib reuses (stored in /opt/ns-3/.swarm-configure.env), so a
# downstream build only compiles the mounted contrib module and its tests: the
# stock libraries' compile commands do not change, Ninja finds them up to date.
# Tests and examples are enabled but filtered to `core` here; the downstream
# configure swaps the filter for its own module, which changes no library flags.

ARG BASE_IMAGE=ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
FROM ${BASE_IMAGE} AS build

ARG BASE_OS=ubuntu
ARG NS3_VERSION=3.49
ARG BUILD_PROFILE=debug
# Routing-essential modules only; ns-3 resolves their dependencies. `mesh`
# (802.11s/HWMP) is a routing comparator AntHocNet's harness links.
ARG NS3_MODULES="core;network;internet;wifi;mesh;mobility;energy;flow-monitor;applications;point-to-point;csma;aodv;olsr;dsdv;dsr;stats"

ENV DEBIAN_FRONTEND=noninteractive

# Toolchain from the distribution. ubuntu 24.04: gcc-13, CMake 3.28. debian 13
# (and -slim): gcc-14, CMake 3.31. alpine (experimental, musl): bash is needed
# by ns3-build-contrib, samurai provides `ninja`. Every ns-3 in the window
# (3.40-3.49) needs CMake >= 3.10..3.25 and C++17..C++23, all covered.
# The base is pinned by digest (invariant 13) and can lag its distribution's
# security archive by days, so the packages already in it are upgraded too
# (#29): the image's security stage fails on any fixable vulnerability. A
# security rebuild of an unchanged Dockerfile passes a new REFRESH (a date or
# run id) to rerun this layer; an unchanged REFRESH keeps the cache.
ARG REFRESH=none
RUN echo "package refresh: ${REFRESH}" \
 && if command -v apt-get >/dev/null; then \
        apt-get update \
     && apt-get upgrade -y --no-install-recommends \
     && apt-get install -y --no-install-recommends \
            ca-certificates git g++ cmake ninja-build python3 make \
     && rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null; then \
        apk upgrade --no-cache \
     && apk add --no-cache bash ca-certificates git g++ cmake samurai python3 make linux-headers; \
    else echo "unsupported base image" >&2; exit 1; fi

RUN case "${BUILD_PROFILE}" in \
        default)   flags="-d default" ;; \
        optimized) flags="-d release" ;; \
        debug)     flags="-d debug" ;; \
        sanitized) flags="-d debug --enable-sanitizers" ;; \
        *) echo "unknown BUILD_PROFILE=${BUILD_PROFILE}" >&2; exit 1 ;; \
    esac \
 && git clone --depth 1 --branch "ns-${NS3_VERSION}" \
        https://gitlab.com/nsnam/ns-3-dev.git /opt/ns-3 \
 && rm -rf /opt/ns-3/.git \
 && cd /opt/ns-3 \
 && printf 'NS3_VERSION=%s\nBUILD_PROFILE=%s\nNS3_PROFILE_FLAGS="%s"\nNS3_MODULES="%s"\n' \
        "${NS3_VERSION}" "${BUILD_PROFILE}" "${flags}" "${NS3_MODULES}" > .swarm-configure.env \
 && ./ns3 configure -G Ninja ${flags} --enable-examples --enable-tests \
        --disable-werror --filter-module-examples-and-tests=core \
        --enable-modules="${NS3_MODULES}" \
 && ./ns3 build \
 && ./ns3 show profile

# After the ns-3 build, so editing the script or the hook never invalidates
# the (long) build layer above.
COPY --chmod=755 docker/scripts/build-contrib.sh /usr/local/bin/ns3-build-contrib
COPY --chmod=644 docker/scripts/swarm-quality.cmake /usr/local/share/ns3-build-contrib/swarm-quality.cmake

ENV NS3_VERSION=${NS3_VERSION} \
    BUILD_PROFILE=${BUILD_PROFILE} \
    BASE_OS=${BASE_OS} \
    NS3DIR=/opt/ns-3

# The ns3-containers commit that built the image. Declared here, after every
# build step, so a new commit changes only the image config, not a cached layer.
ARG REVISION=unknown
# The pipeline run that built the image: two runs of one commit would otherwise
# produce byte-identical candidates from the cache, and one run's cleanup
# could delete what the other is still testing (ns3-containers#52).
ARG BUILD_RUN=local
LABEL org.opencontainers.image.source="https://github.com/swarm-routing/ns3-containers" \
      org.opencontainers.image.revision="${REVISION}" \
      io.github.swarm-routing.build-run="${BUILD_RUN}" \
      org.opencontainers.image.version="${NS3_VERSION}" \
      io.github.swarm-routing.ns3.profile="${BUILD_PROFILE}" \
      io.github.swarm-routing.ns3.base="${BASE_OS}" \
      org.opencontainers.image.description="ns-3 with a warm Ninja build for swarm-routing contrib modules" \
      org.opencontainers.image.licenses="GPL-2.0-only"

WORKDIR /opt/ns-3
CMD ["bash"]
