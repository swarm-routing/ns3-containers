# Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)
# SPDX-License-Identifier: MIT OR GPL-2.0-only
#
# Pre-built ns-3 for swarm-routing contrib modules.
#
#   docker build -f docker/Dockerfile \
#       --build-arg NS3_VERSION=3.43 --build-arg BUILD_PROFILE=debug \
#       -t ghcr.io/swarm-routing/ns3-dev:3.43-debug .
#
# BUILD_PROFILE:
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

FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852 AS build

ARG NS3_VERSION=3.43
ARG BUILD_PROFILE=debug
# Routing-essential modules only; ns-3 resolves their dependencies.
ARG NS3_MODULES="core;network;internet;wifi;mobility;energy;flow-monitor;applications;point-to-point;csma;aodv;olsr;dsdv;dsr;stats"

ENV DEBIAN_FRONTEND=noninteractive

# Ubuntu 24.04: gcc-13 (C++20, ns-3.43's minimum standard), CMake 3.28, Ninja.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates git g++ cmake ninja-build python3 make \
 && rm -rf /var/lib/apt/lists/*

COPY docker/scripts/build-contrib.sh /usr/local/bin/ns3-build-contrib

RUN case "${BUILD_PROFILE}" in \
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
 && ./ns3 show profile \
 && chmod 755 /usr/local/bin/ns3-build-contrib

ENV NS3_VERSION=${NS3_VERSION} \
    BUILD_PROFILE=${BUILD_PROFILE} \
    NS3DIR=/opt/ns-3

LABEL org.opencontainers.image.source="https://github.com/swarm-routing/ns3-containers" \
      org.opencontainers.image.description="ns-3 with a warm Ninja build for swarm-routing contrib modules" \
      org.opencontainers.image.licenses="GPL-2.0-only"

WORKDIR /opt/ns-3
CMD ["bash"]
