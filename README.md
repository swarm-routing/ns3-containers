# ns3-containers

<!-- org-sync:begin badges -->
[![CI](https://github.com/swarm-routing/ns3-containers/actions/workflows/publish-images.yml/badge.svg)](https://github.com/swarm-routing/ns3-containers/actions/workflows/publish-images.yml)
[![Release](https://img.shields.io/github/v/release/swarm-routing/ns3-containers?sort=semver&cacheSeconds=1800)](https://github.com/swarm-routing/ns3-containers/releases)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.24202109.svg)](https://doi.org/10.5281/zenodo.24202109)
[![Cite](https://img.shields.io/badge/cite-CITATION.cff-blue)](CITATION.cff)
[![Licence: MIT OR GPL-2.0-only tooling](https://img.shields.io/badge/licence-MIT%20OR%20GPL--2.0--only%20tooling-blue)](LICENSING.md)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow)](https://www.conventionalcommits.org)
[![Colony Arena: ns3-containers](https://img.shields.io/badge/Colony%20Arena-project%20page-orange)](https://swarm-routing.github.io/projects/ns3-containers/)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/swarm-routing/ns3-containers/badge)](https://scorecard.dev/viewer/?uri=github.com/swarm-routing/ns3-containers)
[![GHCR: ns3-dev](https://img.shields.io/badge/ghcr.io-swarm--routing%2Fns3--dev-blue?logo=docker)](https://github.com/orgs/swarm-routing/packages/container/package/ns3-dev)
[![Images signed: cosign](https://img.shields.io/badge/images%20signed-cosign-success)](SECURITY.md#verifying-what-it-ships)
[![Container Security (Hadolint & Trivy)](https://github.com/swarm-routing/ns3-containers/actions/workflows/container-security.yml/badge.svg)](https://github.com/swarm-routing/ns3-containers/actions/workflows/container-security.yml)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=swarm-routing_ns3-containers&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=swarm-routing_ns3-containers)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=swarm-routing_ns3-containers&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=swarm-routing_ns3-containers)
[![Hadolint](https://img.shields.io/github/check-runs/swarm-routing/ns3-containers/main?nameFilter=hadolint&label=Hadolint&logo=docker)](https://github.com/swarm-routing/ns3-containers/actions/workflows/container-security.yml)
[![Trivy](https://img.shields.io/github/check-runs/swarm-routing/ns3-containers/main?nameFilter=trivy-config&label=Trivy&logo=aquasecurity)](https://github.com/swarm-routing/ns3-containers/security/code-scanning)
[![CodeRabbit Pull Request Reviews](https://img.shields.io/coderabbit/prs/github/swarm-routing/ns3-containers?utm_source=oss&utm_medium=github&utm_campaign=swarm-routing%2Fns3-containers&labelColor=171717&color=FF570A&link=https%3A%2F%2Fcoderabbit.ai&label=CodeRabbit+Reviews)](https://coderabbit.ai)
<!-- org-sync:end badges -->

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
it alone. Follow it with the `latest-*` tags. An OS security refresh is the
*Publish images* workflow dispatched with `refresh: true`: it rebuilds the
supported release only, with its OS-package layer rerun (`REFRESH=<run id>`)
so the distribution's fixes since the base digest are installed, then tests
and promotes it like any build (the rolling tags move; the `-<sha7>` pins stay).

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

CI tools: the `debug` and `sanitized` images carry `gcovr` (pinned, see
`--coverage` below); `debug` also carries `unzip`, `curl` and `gnupg`, which
the org's `reusable-ns3-ci.yml` SonarQube step uses to fetch and verify the
scanner (#88). Both steps install them by apt only when they are missing.

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

`ns3-build-contrib [--test] [--suite S]... [--modules "a;b"] [--run "PROG ARGS"]... [--strict-warnings] [--coverage] <dir|name=dir>...`
symlinks each directory into `/opt/ns-3/contrib/<name>`, reconfigures with the
image's own flags (stored in `/opt/ns-3/.swarm-configure.env`), builds, then
runs the test suites and programs. Dependencies go first:

```bash
ns3-build-contrib swarm-core=/src/ns3-swarm-core ara=/src/ARA/ns3 --test
```

Two quality options touch the named modules only, never ns-3, so the build
stays incremental:

- `--strict-warnings` compiles them with `-Wall -Wextra -Wpedantic -Wshadow
  -Wnon-virtual-dtor -Wold-style-cast -Wcast-align -Woverloaded-virtual
  -Wnull-dereference -Wformat=2 -Werror`; ns-3's headers are `-isystem` for
  them, so only the module's own code is judged (its own headers too, also
  when included as `ns3/<header>.h`). A call to a `[[deprecated]]` API stays
  a warning (`-Wno-error=deprecated-declarations`), so a dependency that
  deprecates before it removes (swarm-core's two-step policy) does not break
  the module's build (#167).
- `--coverage` compiles and links them with `--coverage` (gcov); after
  `--test`, the `.gcda` files are under `/opt/ns-3/cmake-cache/contrib/<name>/`.
  The `debug` and `sanitized` images carry `gcovr` (pinned with hashes in
  [`docker/gcovr-requirements.txt`](docker/gcovr-requirements.txt), in its own
  venv at `/opt/gcovr`); the `.gcda` files go with the container, so report in
  the same run:

  ```bash
  docker run --rm -v "$PWD:/src/ara:ro" ghcr.io/swarm-routing/ns3-dev:latest-debug bash -c '
      ns3-build-contrib --coverage --test ara=/src/ara/ns3 &&
      cd /opt/ns-3/cmake-cache && gcovr --root /src/ara/ns3 --filter /src/ara/ns3/ .'
  ```

- `--quality-modules "a;b"` limits both to those modules (default: every
  module given), so a dependency built alongside is not judged:
  `ns3-build-contrib --strict-warnings --quality-modules ara swarm-core=/src/ns3-swarm-core ara=/src/ara/ns3`.

The org's `reusable-ns3-ci.yml` turns them on with its `strict-warnings` and
`coverage` inputs.

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
test/run.sh --stages structure,smoke ns3-dev:3.48-debug   # some of them (see "Split test jobs")
```

`test/run.sh <image>` runs every test stage against one image: `labels` on
the host from the image config, every other stage in a fresh container with
this repository mounted read-only (pass `EXPECT_VERSION`, `EXPECT_PROFILE`,
`EXPECT_OS`, `EXPECT_REVISION` to compare against what the image should be; CI
passes its matrix entry and commit):

| Stage | Checks |
|---|---|
| `labels` | the OCI labels: source, licence, ns-3 version, profile, base, revision |
| `structure` | `/opt/ns-3` configured and built, `ns3-build-contrib` on `PATH`, the environment, the recorded configure line and module list (equal to the Dockerfile's, every module built), the CMake cache matching the profile (build type, asserts, logs, sanitizers, no native optimizations, examples and tests on), the C++ standard the tree requires, `gcovr` at its pinned version on `debug` and `sanitized`, `unzip`, `curl` and `gpg` on `debug` |
| `profile` | the profile does what its name says: asserts abort and `NS_LOG` prints (`default`, `debug`, `sanitized`) or both are compiled out (`optimized`); on `sanitized`, a planted use-after-free, leak and signed overflow are each reported by ASan, LSan and UBSan; no AVX/AVX-512 instruction in the stock core library (nothing built for the build machine's CPU) |
| `smoke` | builds `test/fixtures/swarm-hello`, runs its test.py suite, fails above 40 Ninja steps (the warm cache was missed); `--strict-warnings`, `--quality-modules` and `--coverage` do what they promise, and the image's `gcovr` reports the module's coverage |

| `integration` | ns-3 actually simulates: the tutorial `first`; the routing modules' own examples `aodv-example` (must deliver), `dsdv-manet` and `olsr-hna` (must deliver); and [`manet-canary`](test/fixtures/manet-canary/) (16 nodes, random waypoint) with AODV, OLSR and DSDV, dense (must deliver) and sparse (partitioned), each under a wall-clock budget: a run that does not finish is a hang |

| `unit` | ns-3's own QUICK unit suites (`test.py -c unit -f QUICK`) for the modules in [`test/ns3-suites.txt`](test/ns3-suites.txt): the MANET stack (core, network, internet, mobility, wifi, propagation, aodv, olsr, dsdv, mesh, the `full` group) on `debug` and `sanitized`, core/network/internet (`light`) on `default` and `optimized`; `UNIT_SET=full\|light` overrides the profile's group. Their test libraries are built in the throwaway container. Every suite's time is in the job log, the 15 slowest in the step summary |

Unit-stage cost per image (ns-3.49, GitHub-hosted runner, measured in #51's run):

| Image | Group | Suites | Test-library build | test.py |
|---|---|---|---|---|
| `3.49-debug` | full | 213 | 365 s | 486 s |
| `3.49-sanitized` | full | 213 | 646 s | 2631 s |
| `3.49-debian-debug` | full | 213 | 497 s | 636 s |
| `3.49-slim-debug` | full | 213 | 504 s | 619 s |
| `3.49-alpine-debug` | full | 213 | 749 s | 811 s |
| `3.49` (default) | light | 134 | 167 s | 51 s |
| `3.49-optimized` | light | 134 | 203 s | 32 s |
| `3.49-debian` | light | 134 | 257 s | 90 s |
| `3.49-slim` | light | 134 | 251 s | 90 s |

The sanitized image's unit stage (~55 min) sets the length of a pipeline run.

**Split test jobs (#86).** A profile with a `split <profile> <N>` line in
[`test/ns3-suites.txt`](test/ns3-suites.txt) is tested by parallel jobs of
the same run, all on the same candidate digest. One job runs every stage but
`unit` (`test/run.sh --stages labels,...,integration`). The unit stage runs
as one job (N = 1) or as N shards (`--stages unit --unit-shard i/N`), each
listed as `shard <group> i/N <module>...`. The shards must list every module
of the group exactly once: `tools/ns3_matrix.py --check-suites` fails the
pipeline's first job otherwise, and `test/unit.sh` refuses such a shard at
run time. Each job leaves its own pass marker, and promote tags the digest
only when every job of the image passed (`tools/pass_markers.py`).
`test/run.sh` with no option still runs everything, as local runs, fork PRs
and on-demand builds do.

Today only `sanitized` is split, as `split sanitized 1`: the stages but unit
(712 s in #89's run) run beside the unit stage (2475 s). The unit stage stays
one job because its wall time is one suite. `ns3-tcp-cubic` (internet) takes
1936 s under ASan+UBSan, and the other 212 suites (5022 s of suite time) fit
on the remaining three cores beside it. No shard split can finish below that
suite, and an internet-only shard would save about 6 more minutes for about
23 more runner-minutes.

**Pull requests run a smaller unit set (#87).** On a pull request the
Debian, slim and Alpine images run the `light` group: they differ from
Ubuntu's only in the base OS, and the `full` group on all three cost about
40 runner-minutes per PR run. Ubuntu `debug` and `sanitized` still run
`full` on every PR. A PR never tags anything: every push to `main` runs every
stage on every image, each with its profile's group (`full` on every debug
and sanitized image), before the digest is promoted. The workflow sets
`UNIT_SET` from the event and the matrix entry (`pr_unit_set` in
`tools/ns3_matrix.py`); `test/run.sh` without it runs the profile's group,
as a local run, a schedule or a dispatch does.
The step summary says which set ran and why.

**Some suites run on `main` only (#86, maintainer decision (c)).** On a pull
request (`UNIT_PR=1`, set by the workflow) every image's unit stage leaves
out the suites on the `main-only` line of
[`test/ns3-suites.txt`](test/ns3-suites.txt), whatever its group. Today that
is `ns3-tcp-cubic` (internet, so in both groups): one upstream suite that
took 1343–1936 s under ASan+UBSan, 470 s on `debug` and 348 of the 350 s of
`test.py` on the light Debian images, and so set both the sanitized job's
wall time and most of a PR run's runner minutes. The job log and the step
summary name each deferred suite (a SKIP note). Pushes to `main`, schedule
and dispatch runs, and any run without `UNIT_PR`, run it; promotion happens
only on `main`, so every published image is still tested with it.

**Pull requests test only the images they affect (#86, #87).** Every image
is still built (mostly cache hits), then the `select` job
([`tools/pr_tests.py`](tools/pr_tests.py)) compares each candidate with the
image its versioned tag (e.g. `3.49-debug`) points to, the one `main` last
tested and promoted. The digests always differ (each build stamps its commit
and run into two labels), so it compares the content: the layers and the
config without those two labels. Then:

| The PR's image | Test inputs* changed since `main` tested it | Tests |
|---|---|---|
| same content | none | none ("unchanged digest, already tested on main") |
| same content | some | the stages they feed (plus `labels`), on the representative images only |
| different content, or nothing to compare with | any | every test job, as before |

\* `test/` (each script and fixture feeds its own stage; `test/run.sh` and
unknown files feed every stage), `.trivyignore` (security), and the test
wiring: `tools/ns3_matrix.py`, `tools/pass_markers.py`, `tools/pr_tests.py`,
`publish-images.yml` (every stage). The diff runs from the commit the
reference was tested at (its `revision` label) to the PR's head.

The representatives are Ubuntu `debug`, `sanitized` and `optimized`, Debian
`debug`, slim `default` and Alpine `debug`: every base and every profile
once (`REPRESENTATIVES` in [`tools/ns3_matrix.py`](tools/ns3_matrix.py)).
The step summary has a line per image saying what ran and why, and
`images gate` passes when images are skipped. A fork PR makes the same choice
read-only in its build job. Pushes to `main`, schedule and dispatch runs test
every image with every stage, and only they promote: what is tagged is what
was tested.

[`test/known-failures.txt`](test/known-failures.txt) lists upstream ns-3 bugs
expected on one exact ns-3 version; each shows in the step summary as XFAIL,
and an expected failure that passes fails the stage. Today:
**ns-3.49's stock AODV hangs in the sparse run** (#35).

More stages are coming (#36): fixed-seed regression.

**Downstream canary** (#44). Before `latest-*` moves, every org ns-3 module
listed in [`test/downstream.txt`](test/downstream.txt) is built and tested on
the new ubuntu `debug` candidate by `test/downstream.sh <image>`: today all
seven lines are built and tested: `ns3-swarm-core` (`swarm-core`), `ns3-tools`
(`routing-bench` + its stock-arm delivery check, without `aodv` while #35
lasts), AntHocNet (its six modules staged by `make install-ns3`, its suites
and `anthocnet-example`), and ARA, BeeAdHoc, Termite and HOPNET (each
protocol's `ns3/` module on `swarm-core`, its own suite). A line whose module
directory does not exist yet is skipped with the reason, so a repository can
be listed before it has an `ns3/` module. Each consumer runs in a fresh container
under a wall-clock budget, at the commit of its `main` shown in the step
summary.

- **The contract for a consumer:** one line in `test/downstream.txt`
  (`name | owner/repo@ref | ns-3 range | modules | suites | stage | run`), or
  a `ci/canary.sh` in the consumer's repository, which then runs instead
  (in its checkout, inside the image; exit 0 = pass). The ns-3 range
  (`3.42+`, `3.36-3.48`) decides which on-demand `versions` builds run it.
- **The gate:** on `main`, `latest-*` moves only if every consumer passes;
  a failure leaves `latest` on the previous digest and opens (or comments on)
  an issue here per consumer and release, with the log. The versioned and
  `-<sha7>` tags are not held back: the image passed its own tests.
- **Pull requests** run the canary as an advisory job (a consumer's own
  breakage must not fail an unrelated image PR); fork PRs, which push no
  candidate, skip it.

**What is tested is what is published.**
[`publish-images.yml`](.github/workflows/publish-images.yml) builds each image
**once** and pushes it to the candidate package `ghcr.io/swarm-routing/ns3-dev-ci`
(not for consumers; each clean run, PRs included, deletes its own, and a daily job sweeps leftovers and the cache's untagged versions). The tests run on that candidate
**by digest** (in one job, or in parallel jobs on that same digest for a
split profile). Only an image all of whose test jobs passed gets its `ns3-dev` tags, as a
byte-identical copy of the tested digest (no rebuild), then a keyless cosign
signature, a provenance attestation and a CycloneDX SBOM attestation (the
OS packages plus ns-3 itself; see [SECURITY.md](SECURITY.md#verifying-what-it-ships)),
all on that digest, so every tag of it carries them. The `latest-*` tags move last, and
only when every required image of the run passed. On-demand builds of older
releases go through the same tests. The buildx cache lives in
`ghcr.io/swarm-routing/ns3-dev-cache`, one tag per version × base × profile.

## Known issues and findings

Found by the image test pipeline (#36). Each one has an issue with the full
evidence; this is the summary a user of the images needs.

| ns-3 | What | Status |
|---|---|---|
| **3.49** (the supported release, `latest`) | **Stock AODV never finishes a sparse MANET run.** ns-3.49's new `Ipv4L3Protocol::SendIcmpNoRoute` (RFC 1812 ICMP "net unreachable") feeds back into AODV's deferred route output: the ICMP error has no route either, is queued through loopback into the full request queue, whose drop raises another ICMP error, all at one simulated instant (1,284,336 errors at +8.146253127 s in one run). Simulated time stops; the process spins until killed. OLSR and DSDV are unaffected; AODV-derived protocols (AntHocNet's vendored AOMDV) hang too. Reproducer, stock models only: [`manet-canary`](test/fixtures/manet-canary/) `--protocol=aodv --range=100`, which finishes in 2 s on 3.48 and never on 3.49; stock `manet-routing-compare` with its defaults does *not* trigger it. ns-3-dev still has the code (2026-11-01); no upstream report filed yet. | upstream bug; reproduced on every run as a strict expected failure (`test/known-failures.txt`); [#35](https://github.com/swarm-routing/ns3-containers/issues/35), [AntHocNet#843](https://github.com/swarm-routing/AntHocNet/issues/843) |
| **3.48** (history, on demand) | **Four wifi unit suites fail** (`wifi-txop`, `wifi-mlo`, `wifi-gcr`, `wifi-emlsr-basic-exchanges`) with the images' 16-module set, on both profiles; they **pass** on 3.48 with every ns-3 module and on 3.49 with the images' set. With the images' set the simulation transmits fewer frames than the test expects, and the test then indexes past its frame list (UBSan: member call on an invalid `WifiMacHeader` at `wifi-txop-test.cc:1427`, a SIGSEGV without sanitizers). The suites test 802.11ax/be machinery (EMLSR, MLO, groupcast, TXOP limits) that 802.11a/b ad-hoc MANET work does not use. | cause not yet classified (module dependency vs ns-3 test bug); an on-demand 3.48 build fails the `unit` stage until it is; [#49](https://github.com/swarm-routing/ns3-containers/issues/49) |

Corrections that came out of the tests:

- **C++ standard per release**, read from each tree's
  `CMAKE_CXX_STANDARD_MINIMUM`: C++17 for 3.40, C++20 for 3.41–3.45, C++23 from
  3.46 (this README used to say C++20 up to 3.48).
- **Release-profile binaries have no profile suffix** (`ns3.49-first`, not
  `ns3.49-first-optimized`): scripts that glob `ns3*-<name>-*` find nothing on
  `optimized` images; use `ns3*-<name>*`.
- **Alpine's `timeout` is BusyBox's**: a timed-out command exits 143 (SIGTERM),
  not GNU's 124.
- **`./ns3 configure` keeps cached options**: reconfiguring without
  `--enable-modules` or `--filter-module-examples-and-tests` keeps the previous
  values from `cmake-cache/`; pass them explicitly (as `ns3-build-contrib` and
  the test stages do), or delete `cmake-cache/` for a fresh configure.

<!-- org-sync:begin citing -->
## Releases & citing

Versions follow [SemVer](https://semver.org) ([CHANGELOG.md](CHANGELOG.md)). Each release is listed under [Releases](https://github.com/swarm-routing/ns3-containers/releases), built by the org's release workflow and archived on [Zenodo](https://zenodo.org) with its own DOI.

To cite this repository, use the “Cite this repository” button (from [CITATION.cff](CITATION.cff)):

| DOI | resolves to |
|---|---|
| [`10.5281/zenodo.24202109`](https://doi.org/10.5281/zenodo.24202109) | **concept DOI**: always the latest release. This is the badge above, and the right citation when you mean this project. |

Each release also has its own **version DOI**, listed on [its Zenodo record](https://doi.org/10.5281/zenodo.24202109): cite that one when you reproduce a number measured at that release.

Please also cite the work it builds on:

- G. F. Riley, T. R. Henderson, *The ns-3 Network Simulator*, Modeling and Tools for Network Simulation, pp. 15–34, 2010, [doi:10.1007/978-3-642-12331-3_2](https://doi.org/10.1007/978-3-642-12331-3_2). The simulator every image builds, configured and pre-built at /opt/ns-3.

Using it in your work? Contributions are welcome, and citing the DOI helps just as much.
<!-- org-sync:end citing -->

## Epics

<!-- epics:begin -->
<!-- Generated by swarm-routing/.github tools/epics/epics.py from the issues labelled `epic`; edit the issues, then re-run it. -->

What is planned and in progress here: the issues labelled [`epic`](https://github.com/swarm-routing/ns3-containers/issues?q=label%3Aepic). An epic's open sub-issues carry a `priority:*` and a `model:*` label, so a contributor or an AI agent can pick one up ([how issues work](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md#issues)). The whole org's plan: the [roadmap](https://github.com/swarm-routing/.github/blob/main/ROADMAP.md#epics).

| Epic | Status | Sub-issues closed |
|------|--------|-------------------|
| [#19](https://github.com/swarm-routing/ns3-containers/issues/19) OS and compiler coverage — the platforms ns-3 supports and researchers use | In progress | 2 / 6 |
| [#36](https://github.com/swarm-routing/ns3-containers/issues/36) image test pipeline — every image built is tested by digest (security, structure, unit, profile, integration, regression, downstream) before any tag moves | In progress | 5 / 9 |
| [#11](https://github.com/swarm-routing/ns3-containers/issues/11) multi-platform ns3-dev images (linux/amd64 + linux/arm64) with docker buildx | Planned | no sub-issues yet |
| [#12](https://github.com/swarm-routing/ns3-containers/issues/12) developer documentation for the ns3-dev images (usage, per-image pages, debugging, CI/CD) kept current by AI review | Planned | 0 / 7 |
| [#27](https://github.com/swarm-routing/ns3-containers/issues/27) security refresh — keep the supported ns-3 release's images patched (scheduled base refresh + scan-triggered rebuilds; older releases on demand) | Planned | 0 / 4 |

<details><summary>Closed: 1 epic</summary>

| Epic | Closed |
|------|--------|
| [#3](https://github.com/swarm-routing/ns3-containers/issues/3) ns3-dev image matrix — top 10 ns-3 versions, full profiles on the latest 3, Ubuntu/Debian/slim bases | Done 2026-11-02 |

</details>

<!-- epics:end -->

## Licence

Per directory, as AntHocNet ([LICENSING.md](LICENSING.md)): the image tooling
(`docker/`, the `test/*.sh` stage scripts, `tools/`, the workflows) is `MIT OR GPL-2.0-only`; the ns-3
fixture module and everything else is `GPL-2.0-only`. The published images
contain ns-3 and are distributed under GPL-2.0.
