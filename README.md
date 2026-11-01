# ns3-containers

Pre-built **ns-3** images for `swarm-routing` contrib modules:
`ghcr.io/swarm-routing/ns3-dev:<ns3-version>-<profile>`. The ns-3 tree at
`/opt/ns-3` is already configured and built (Ninja), so a downstream module
compiles alone instead of rebuilding ns-3.

| Tag | ns-3 build profile | Use |
|---|---|---|
| `3.43-debug` | `-d debug` (asserts + `NS_LOG`) | CI default |
| `3.43-sanitized` | `-d debug --enable-sanitizers` (ASan + LSan + UBSan) | CI memory-safety leg |
| `3.43-optimized` | `-d release` (-O3, no asserts/logs) | benchmark campaigns only |

Each also gets an immutable `-<sha7>` tag (the ns3-containers commit that built
it); pin that in anything producing a published number. `optimized` maps to
ns-3's **`release`** profile, not ns-3's `optimized`: the latter adds
`-march=native`, which makes an image built on one runner crash with SIGILL on
another CPU.

Modules built: `core network internet wifi mobility energy flow-monitor
applications point-to-point csma aodv olsr dsdv dsr stats` (plus their
dependencies). Toolchain: Ubuntu 24.04, gcc-13, CMake 3.28, C++20.

## Building a contrib module

```bash
docker run --rm -v "$PWD:/src/ara:ro" ghcr.io/swarm-routing/ns3-dev:3.43-debug \
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
docker build -f docker/Dockerfile --build-arg NS3_VERSION=3.43 \
    --build-arg BUILD_PROFILE=debug -t ns3-dev:3.43-debug .
docker run --rm -v "$PWD:/src:ro" ns3-dev:3.43-debug bash /src/test/smoke.sh
```

`test/smoke.sh` builds the `test/fixtures/swarm-hello` module, runs its
test.py suite, and fails if the build took more than 40 Ninja steps (i.e. the
warm cache was missed). [`publish-images.yml`](.github/workflows/publish-images.yml)
runs the same smoke on every PR and pushes to GHCR from `main`, one buildx GHA
cache scope per version × profile.

## Licence

The repository's own files are MIT. The images contain ns-3, which is GPL-2.0-only.
