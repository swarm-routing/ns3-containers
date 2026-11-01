# ns3-containers

Pre-built **ns-3** images for `swarm-routing` contrib modules:
`ghcr.io/swarm-routing/ns3-dev` (public, no login needed). The ns-3 tree at
`/opt/ns-3` is already configured and built (Ninja), so a downstream module
compiles alone instead of rebuilding ns-3.

## Which image

The window is the **ten newest ns-3 releases** (3.40–3.49 as of 2026-11-01),
generated from upstream's tags by [`tools/ns3_matrix.py`](tools/ns3_matrix.py);
a weekly run builds a new release as soon as it is tagged, and a version that
leaves the window stops rebuilding (its tags stay).

| Versions | Base | Profiles |
|---|---|---|
| latest 3 (3.47, 3.48, 3.49) | Ubuntu 24.04 | `default`, `debug`, `sanitized`, `optimized` |
| latest 3 | Debian 13, Debian 13 slim | `default`, `debug` |
| the other 7 (3.40–3.46.1) | Ubuntu 24.04 | `default`, `debug` |
| newest only (3.49) | Alpine 3.24 — **experimental**, may be missing | `debug` |

| Profile | ns-3 configure | What it is for |
|---|---|---|
| `default` | `-d default`: `-Os -g`, asserts + `NS_LOG` on | general use; what a tree configured without `-d` gets |
| `debug` | `-d debug`: `-O0 -g`, asserts + `NS_LOG` on | CI default — asserts catch real bugs |
| `sanitized` | `-d debug --enable-sanitizers` (ASan + LSan + UBSan) | CI memory-safety leg: out-of-bounds, use-after-free, leaks, UB |
| `optimized` | `-d release`: `-O3`, asserts and logs compiled out | benchmark campaigns only, never CI |

`optimized` maps to ns-3's **`release`** profile, not ns-3's `optimized`: the
latter adds `-march=native`, which makes an image built on one runner crash
with SIGILL on another CPU.

| Tag | Image |
|---|---|
| `:3.49`, `:latest` | Ubuntu, `default` profile |
| `:3.49-debug` (`-default`, `-sanitized`, `-optimized`) | Ubuntu, that profile |
| `:3.49-debian-debug`, `:3.49-slim` (`= -slim-default`) | other bases |
| `:3.46-debug` and `:3.46.1-debug` | a patch release is tagged under both numbers |
| any of the above + `-<sha7>` | immutable: the ns3-containers commit that built it |

Pin the `-<sha7>` tag in anything that produces a published number. The
`3.43-sanitized` and `3.43-optimized` images from the first publish stay
available, frozen (3.43 is no longer in the latest-3 tier).

Toolchains: Ubuntu 24.04 gcc-13 / CMake 3.28; Debian 13 gcc-14 / CMake 3.31;
each tree builds in its own C++ standard (C++17 for 3.40, C++20 for
3.41–3.48, C++23 for 3.49). *Slim* only means the smaller `debian:13-slim`
base: the image is mostly the built ns-3 tree, which cannot be trimmed without
losing the warm incremental build. Alpine (musl) is outside ns-3's supported
platforms and can never have a `sanitized` image (no ASan/LSan on musl).

Modules built: `core network internet wifi mesh mobility energy flow-monitor
applications point-to-point csma aodv olsr dsdv dsr stats` (plus their
dependencies).

## Building a contrib module

```bash
docker run --rm -v "$PWD:/src/ara:ro" ghcr.io/swarm-routing/ns3-dev:3.49-debug \
    ns3-build-contrib --test /src/ara
```

`ns3-build-contrib [--test] [--suite S]... [--modules "a;b"] [--run "PROG ARGS"]... <dir|name=dir>...`
symlinks each directory into `/opt/ns-3/contrib/<name>`, reconfigures with the
image's own flags (stored in `/opt/ns-3/.swarm-configure.env`), builds, then
runs the test suites and programs. Dependencies go first:

```bash
ns3-build-contrib swarm-core=/src/ns3-swarm-core ara=/src/ARA/ns3 --test
```

The name must match the module's `build_lib(LIBNAME …)`; `core` and stock
module names are refused. CI repos use
[`reusable-ns3-ci.yml`](https://github.com/swarm-routing/.github/blob/main/.github/workflows/reusable-ns3-ci.yml)
instead of calling this by hand.

## Building the images

```bash
python3 tools/ns3_matrix.py | python3 -m json.tool | less   # what CI will build
docker build -f docker/Dockerfile --build-arg NS3_VERSION=3.48 \
    --build-arg BUILD_PROFILE=debug -t ns3-dev:3.48-debug .  # BASE_IMAGE/BASE_OS for other bases
docker run --rm -v "$PWD:/src:ro" ns3-dev:3.48-debug bash /src/test/smoke.sh
```

`test/smoke.sh` builds the `test/fixtures/swarm-hello` module, runs its
test.py suite, and fails if the build took more than 40 Ninja steps (i.e. the
warm cache was missed). [`publish-images.yml`](.github/workflows/publish-images.yml)
runs the same smoke on every PR and pushes to GHCR from `main`, signed
(keyless cosign) with a provenance attestation; the buildx cache lives in
`ghcr.io/swarm-routing/ns3-dev-cache`, one tag per version × base × profile.

## Licence

Per directory, as AntHocNet ([LICENSING.md](LICENSING.md)): the image tooling
(`docker/`, `test/smoke.sh`, the workflows) is `MIT OR GPL-2.0-only`; the ns-3
fixture module and everything else is `GPL-2.0-only`. The published images
contain ns-3 and are distributed under GPL-2.0.
