# ns3-containers

Pre-built **ns-3** images for `swarm-routing` contrib modules:
`ghcr.io/swarm-routing/ns3-dev` (public, no login needed). The ns-3 tree at
`/opt/ns-3` is already configured and built (Ninja), so a downstream module
compiles alone instead of rebuilding ns-3.

## Which image

**Only the release ns-3 supports is maintained.** ns-3 maintains its latest
release only (no maintenance branches, no backports; fixes arrive as a new
release or, rarely, a point release such as 3.46.1). So the automatic
pipelines build **the latest ns-3 release** only, read from upstream's tags by
[`tools/ns3_matrix.py`](tools/ns3_matrix.py): a new release is picked up
within a week, and every image change or OS security refresh (#27) rebuilds
it alone. Follow it with the `latest-*` tags.

| Release | Base | Profiles |
|---|---|---|
| the supported release (3.49 today) | Ubuntu 24.04 | `default`, `debug`, `sanitized`, `optimized` |
| the supported release | Debian 13, Debian 13 slim | `default`, `debug` |
| the supported release | Alpine 3.24 — **experimental**, may be missing | `debug` |
| any older release, **on demand** | Ubuntu 24.04 | `default`, `debug` |

**Older releases are history.** 3.40–3.48 were published once, on 2026-11-01,
and their tags keep working, but no automatic pipeline rebuilds them (no new
base image, no OS security fix). A maintainer builds any ns-3 release on demand
with the *Publish images* workflow's `versions` input (e.g. `3.36,3.42`); to
ask for one, [open an image request](#need-another-distribution-version-or-compiler).
Releases older than 3.40 have not been smoke-tested on these bases: an
on-demand build reports whether the smoke test passes.

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
| `:latest`, `:latest-debug`, `:latest-sanitized`, `:latest-slim`, … | the supported release; moves to the next ns-3 release when it ships |
| `:3.49`, `:3.49-debug` (`-default`, `-sanitized`, `-optimized`) | Ubuntu, that release and profile |
| `:3.49-debian-debug`, `:3.49-slim` (`= -slim-default`) | other bases |
| `:3.46-debug` and `:3.46.1-debug` | a patch release is tagged under both numbers |
| any versioned tag + `-<sha7>` | immutable: the ns3-containers commit that built it |

CI that should track ns-3 uses `latest-debug` / `latest-sanitized`; anything
that produces a published number pins a versioned `-<sha7>` tag.

Toolchains: Ubuntu 24.04 gcc-13 / CMake 3.28; Debian 13 gcc-14 / CMake 3.31;
each tree builds in its own C++ standard (ns-3's `CMAKE_CXX_STANDARD_MINIMUM`:
C++17 for 3.40, C++20 for 3.41–3.45, C++23 from 3.46; the structure test reads
it from the tree and checks the build used it). *Slim* only means the smaller `debian:13-slim`
base: the image is mostly the built ns-3 tree, which cannot be trimmed without
losing the warm incremental build. Alpine (musl) is outside ns-3's supported
platforms and can never have a `sanitized` image (no ASan/LSan on musl).

Modules built: `core network internet wifi mesh mobility energy flow-monitor
applications point-to-point csma aodv olsr dsdv dsr stats` (plus their
dependencies).

## Need another distribution, version or compiler?

The published set is deliberately small: the release ns-3 supports (older
releases on demand), on **Ubuntu, Debian (and debian-slim) and Alpine**, built
with each distribution's own gcc. There are **no Windows or macOS images**: on those
hosts run these Linux images through Docker Desktop, Colima or WSL2.

If your work needs something else (another distribution or release, such as
Rocky Linux or Ubuntu 22.04; a specific compiler, such as clang or an older
gcc; an older ns-3 release that should be built or maintained; extra ns-3 modules or features such
as MPI or Python bindings), **[open an *Image request* issue](https://github.com/swarm-routing/ns3-containers/issues/new?template=image-request.yml)**
with your ns-3 requirements: version, distribution, compiler, profile,
architecture, the modules you need, and why an existing image does not fit.
Requests that name a concrete lab, cluster or CI constraint are what get an
image added.

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
test/run.sh ns3-dev:3.48-debug                             # every test stage, as CI runs them
```

`test/run.sh <image>` runs every test stage against one image: `labels` on
the host from the image config, every other stage in a fresh container with
this repository mounted read-only (pass `EXPECT_VERSION`, `EXPECT_PROFILE`,
`EXPECT_OS`, `EXPECT_REVISION` to compare against what the image should be; CI
passes its matrix entry and commit):

| Stage | Checks |
|---|---|
| `labels` | the OCI labels: source, licence, ns-3 version, profile, base, revision |
| `structure` | `/opt/ns-3` configured and built, `ns3-build-contrib` on `PATH`, the environment, the recorded configure line and module list (equal to the Dockerfile's, every module built), the CMake cache matching the profile (build type, asserts, logs, sanitizers, no native optimizations, examples and tests on), the C++ standard the tree requires |
| `profile` | the profile does what its name says: asserts abort and `NS_LOG` prints (`default`, `debug`, `sanitized`) or both are compiled out (`optimized`); on `sanitized`, a planted use-after-free, leak and signed overflow are each reported by ASan, LSan and UBSan; no AVX/AVX-512 instruction in the stock core library (nothing built for the build machine's CPU) |
| `smoke` | builds `test/fixtures/swarm-hello`, runs its test.py suite, fails above 40 Ninja steps (the warm cache was missed) |

| `integration` | ns-3 actually simulates: the tutorial `first`, and [`manet-canary`](test/fixtures/manet-canary/) (16 nodes, random waypoint) with AODV, OLSR and DSDV, dense (must deliver) and sparse (partitioned), each under a wall-clock budget: a run that does not finish is a hang |

| `unit` | ns-3's own QUICK unit suites (`test.py -c unit -f QUICK`) for the modules in [`test/ns3-suites.txt`](test/ns3-suites.txt): the MANET stack (core, network, internet, mobility, wifi, propagation, aodv, olsr, dsdv, mesh) on `debug` and `sanitized`, core/network/internet on `default` and `optimized`; their test libraries are built in the throwaway container |

[`test/known-failures.txt`](test/known-failures.txt) lists upstream ns-3 bugs
expected on one exact ns-3 version; each shows in the step summary as XFAIL,
and an expected failure that passes fails the stage. Today:
**ns-3.49's stock AODV hangs in the sparse run** (#35).

More stages are coming (#36): security, fixed-seed regression and a
downstream canary.

**What is tested is what is published.**
[`publish-images.yml`](.github/workflows/publish-images.yml) builds each image
**once** and pushes it to the candidate package `ghcr.io/swarm-routing/ns3-dev-ci`
(not for consumers; each clean run, PRs included, deletes its own, and a daily job sweeps leftovers and the cache's untagged versions). The tests run on that candidate
**by digest**. Only an image whose tests passed gets its `ns3-dev` tags, as a
byte-identical copy of the tested digest (no rebuild), then a keyless cosign
signature and a provenance attestation. The `latest-*` tags move last, and
only when every required image of the run passed. On-demand builds of older
releases go through the same tests. The buildx cache lives in
`ghcr.io/swarm-routing/ns3-dev-cache`, one tag per version × base × profile.

## Licence

Per directory, as AntHocNet ([LICENSING.md](LICENSING.md)): the image tooling
(`docker/`, `test/smoke.sh`, the workflows) is `MIT OR GPL-2.0-only`; the ns-3
fixture module and everything else is `GPL-2.0-only`. The published images
contain ns-3 and are distributed under GPL-2.0.
