# AGENTS.md — guide for AI coding agents

Operational guide for LLM agents working in `swarm-routing/ns3-containers`. Read this
before changing anything. Org-wide conventions:
[`swarm-routing/.github` CONTRIBUTING.md](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md). Shape and rules mirror
[AntHocNet's AGENTS.md](https://github.com/danieljoppi/AntHocNet/blob/main/AGENTS.md), the source repository.

## What this repo is

Builds and publishes `ghcr.io/swarm-routing/ns3-dev` (public): ns-3
pre-configured and pre-built with Ninja at `/opt/ns-3`, so a downstream contrib
module compiles alone in seconds. Automatic pipelines build only the release
ns-3 supports (its latest); older releases are built on demand and kept as
history (`tools/ns3_matrix.py`; bases and tags: README "Which image"). Profiles: `default` (ns-3 `-d default`, the plain `:<ver>` tag),
`debug` (CI default), `sanitized` (ASan+LSan+UBSan), `optimized` (ns-3
`-d release`, campaigns only). Bases: Ubuntu 24.04 (default), Debian 13,
Debian 13 slim, Alpine (experimental). `ns3-build-contrib` links mounted
modules into the tree and builds them.

```
docker/Dockerfile                 BASE_IMAGE x NS3_VERSION x BUILD_PROFILE image
tools/ns3_matrix.py               supported release vs on-demand releases, base digests and tags (+ test_ns3_matrix.py)
docker/scripts/build-contrib.sh   -> /usr/local/bin/ns3-build-contrib
test/run.sh                       every test stage against one image ref (the candidate digest in CI); `security` runs Trivy (pinned by digest) on the host
.trivyignore                      accepted Dockerfile findings, each with its reason (the vuln and secret scans take none)
test/structure.sh                 image contract: tree, tools, env, configure record, CMake cache vs profile, C++ standard
test/profile.sh                   the profile keeps its promise: asserts/logs on or off, sanitizers catch planted bugs, no AVX
test/smoke.sh                     image smoke (incremental build + test.py + guards)
test/integration.sh               ns-3 simulates: tutorial `first` + manet-canary AODV/OLSR/DSDV dense/sparse under a wall-clock budget
test/unit.sh                      ns-3's own QUICK unit suites for the modules in test/ns3-suites.txt (full on debug/sanitized)
test/ns3-suites.txt               which modules' suites the unit stage runs, per profile group
test/known-failures.txt           upstream bugs expected on one exact ns-3 version (strict XFAIL, shown in the summary)
test/fixtures/swarm-hello/        minimal contrib module (C++17..C++23) used by the smoke (GPL-2.0-only: an ns-3 module)
test/fixtures/manet-canary/       short MANET program for the integration stage (GPL-2.0-only)
test/fixtures/profile-probe/      one deliberate assert/log/memory bug per mode, for the profile stage (GPL-2.0-only)
.github/workflows/publish-images.yml   resolve -> build once (candidate in ns3-dev-ci) -> test by digest -> promote = retag the same digest (main) -> sign -> attest -> latest-* -> discard this run's candidates (PRs too); weekly new release; `versions` = on demand
.github/workflows/candidates-cleanup.yml   daily: ns3-dev-ci candidates left by failed runs (> 7 days), untagged ns3-dev-cache versions (> 1 day); never ns3-dev
.github/workflows/licence.yml     licence headers (tooling MIT OR GPL-2.0-only, rest GPL-2.0-only)
.github/ISSUE_TEMPLATE/           the org's forms (copied: a repo folder replaces the org defaults) + image-request.yml
```

## Build & verify

```bash
python3 -m unittest discover -s tools                               # matrix generator
docker build -f docker/Dockerfile --build-arg NS3_VERSION=3.48 \
    --build-arg BUILD_PROFILE=debug -t ns3-dev:3.48-debug .        # ~8-15 min on 4 cores
EXPECT_VERSION=3.48 EXPECT_PROFILE=debug EXPECT_OS=ubuntu \
    test/run.sh ns3-dev:3.48-debug                                 # every test stage, as CI runs them
shellcheck docker/scripts/build-contrib.sh test/*.sh
actionlint .github/workflows/*.yml
```

The smoke must report a small Ninja step count (8 today, gate 40): a larger
number means the warm cache was missed. Behind a TLS-intercepting proxy, build
from a scratch copy of the Dockerfile with the proxy CA added; never commit
that layer. The PR's own `publish-images` run is the authoritative check.

## Golden rules (invariants — do not break)

Org-wide (1–9), then this repo's own.

1. **Licensing per directory, as AntHocNet** ([`LICENSING.md`](LICENSING.md);
   AntHocNet [LICENSING.md](https://github.com/danieljoppi/AntHocNet/blob/main/LICENSING.md),
   [ADR-0028](https://github.com/danieljoppi/AntHocNet/blob/main/docs/adr/0028-core-is-dual-licensed.md)). A
   simulator-free `core/` and the standalone tooling are `MIT OR GPL-2.0-only`;
   ns-3 modules, the site, docs and data are `GPL-2.0-only`. Every original
   `.h`/`.hpp`/`.cc`/`.cpp`/`.py`/`.sh` starts with
   `// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)` +
   `// SPDX-License-Identifier: <MIT OR GPL-2.0-only | GPL-2.0-only>` (`#`
   comments where needed), matching its directory in `LICENSING.md`. CI
   (`reusable-licence-check.yml`) checks it. A new directory gets its row in
   `LICENSING.md` in the same PR.
2. **The licence boundary only goes one way.** GPL code may use the dual
   parts; dual code never pulls GPL-only code in: a `core/` file includes only
   the C++ standard library and other `core/` files (CI checks it), and a dual
   script imports no GPL-only code. Code coming from AntHocNet keeps its
   licence: its `core/`/`tools/` (dual) may land in dual or GPL paths here; its
   `ns3/` modules and `web/` (GPL-2.0-only) only in GPL paths. Third-party code
   (AntHocNet's vendored `aomdv`/`gpsr`, IITP RAS) lands only in GPL paths with
   its provenance recorded. Write clean implementations against public ns-3
   interfaces rather than copying ns-3's `src/aodv`/`src/olsr`.
3. **Wire formats are POD + versioned.** Control headers are
   simulator-independent POD structs with bounds-checked little-endian
   readers/writers, a leading version byte, and deterministic roundtrip + fuzz
   tests. Changing a field or its units bumps the version byte.
4. **No contrib module named `core`** (collides with ns-3's `src/core`). The
   shared module is `swarm-core` (`#include "ns3/swarm-core-module.h"`).
5. **Determinism.** A fixed `--seed=<N>` gives byte-identical output. All
   randomness through the simulator's seeded streams or an injected RNG port;
   never libc `rand()`, wall-clock time, or unordered-container iteration order
   in anything that reaches an output.
6. **Comparisons are paired.** Per-seed deltas across >= 20 seeds, emitting the
   canonical `##CONFIG##`, `##RUN##`, `##BENCH##`, `##DIAG##` lines. A
   comparator arm (a protocol we did not design) counts only after its three
   gates: a fidelity sheet from its paper, the per-PR delivery smoke, and an
   anchor reproducing the paper's own trend.
7. **Keep bounded structures bounded** (visited paths, dedup histories, queues
   carry a configured cap).
8. **CI hygiene.** Actions pinned by full commit SHA with a `# vX.Y.Z` comment;
   buildx caches scoped per profile; transient artifacts `retention-days` <= 7.
9. **Nothing shipped depends on `.claude/`.** Skills hold procedures; scripts
   that anything shipped needs live in `tools/` (AntHocNet ADR-0014).
10. **The configure line is shared.** `docker/Dockerfile` and `build-contrib.sh` must pass identical profile flags, `--enable-examples --enable-tests --disable-werror` and module list (the Dockerfile records them in `/opt/ns-3/.swarm-configure.env`); only the contrib list and the examples/tests filter may differ. Drift forces a full ns-3 rebuild in every downstream job — the smoke's step-count gate catches it.
11. **`optimized` is ns-3's `release` profile, never ns-3's `optimized`** (`-march=native` makes an image SIGILL on another CPU).
12. **CI consumes `debug`/`sanitized`, never `optimized`.** Asserts catch real bugs (AntHocNet #123).
13. **Pinned inputs.** The base image by digest; actions by SHA. A published number pins the immutable `:<ver>-<profile>-<sha7>` tag, not the rolling one.
14. **One buildx cache scope per version x base x profile** (`mode=max`, registry cache in `ns3-dev-cache`); delete a scope's tag when its version stops being the supported release.
15. **The version list is generated, never typed.** `tools/ns3_matrix.py` reads upstream tags; a hand-pinned version would silently stop following ns-3's supported release.
16. **Automatic pipelines build only the release ns-3 supports** (its latest; the generator's default). Older releases are history: never rebuild them as a side effect; the `versions` input is a deliberate, manual, on-demand build.
17. **What is tested is what is tagged.** Each image is built once; every test runs on that build by digest, in the same run; tags are a carbon copy of that digest (`imagetools create`), never a rebuild. A new test stage goes into `test/run.sh`, so automatic and on-demand builds (and fork PRs) all run it (#36, #37). A known upstream bug is a `test/known-failures.txt` entry for one exact ns-3 version with its tracking issue, never a skipped or loosened check.

## Conventions

- Issues follow the org taxonomy ([CONTRIBUTING.md](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md#issues), from
  [AntHocNet ADR-0013](https://github.com/danieljoppi/AntHocNet/blob/main/docs/adr/0013-track-bugs-and-findings-as-issues.md)): one type label
  (`bug`/`enhancement`/`chore`/`documentation`/`verification`, plus `epic` for
  umbrellas), area label(s) (`protocol`/`adapter`/`ns3`/`benchmark`/
  `observability`/`packaging`/`learn-site`/`literature`), one `model:*`
  recommendation, one `priority:P1|P2|P3` on non-epic issues, a
  `release:vX.Y.Z` label only when a roadmap gates the issue. Labels come from
  `labels.json` via the `sync-labels` workflow.
- Issue bodies: **Context** (evidence, numbers, links) · **Scope** ·
  **Acceptance criteria** (checkboxes) · **Depends on** (cross-repo form
  `swarm-routing/<repo>#N`) · **References**. Children of an epic say "Part of
  #N" and are linked as sub-issues. Comments you post end with the Claude Code
  footer.
- Issues migrated from AntHocNet carry `migrated` and start with *Migrated from
  `danieljoppi/AntHocNet#N`*.
- Make minimal, reviewable changes; update the relevant doc/ADR when you change
  a documented decision.

## Git workflow

- Branch from `main` (`claude/<short-topic>`), one focused change per PR.
- **Always open a PR to `main`** once the branch is pushed — every change is
  tracked through one.
- **PRs are squash-merged** (the only merge method enabled). The PR title is
  the commit on `main`, so it is a lowercase Conventional Commit
  (`feat:`/`fix:`/`docs:`/`chore:`/`ci:`…, optional scope).
- Push with `git push -u origin <branch>`; merge when CI is green.

## Where to look

| You want to… | Go to |
|--------------|-------|
| Add an ns-3 version | nothing: the weekly run picks up a new upstream release (`tools/ns3_matrix.py`); an older one is built on demand with `workflow_dispatch` `versions` |
| Change what a release gets, a base image digest, or add a profile | `tools/ns3_matrix.py` (+ its test) and the `Dockerfile` profile `case` |
| Handle an image request (another distro, compiler, version) | the *Image request* form's issue; supported set and its reasons in README "Need another distribution…" and #19. When the org's forms in `swarm-routing/.github` change, re-copy them into `.github/ISSUE_TEMPLATE/` |
| Add a stock ns-3 module to the images | `NS3_MODULES` in `docker/Dockerfile` (every downstream repo inherits it) |
| Change how contrib modules build | `docker/scripts/build-contrib.sh` (+ `test/smoke.sh`) |
| The reference image this was derived from | AntHocNet `docker/Dockerfile.ns3`, `.github/workflows/images.yml` |
| The org's invariants, labels, issue shape | [`swarm-routing/.github` CONTRIBUTING.md](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md) |
| The reference implementation and its history | [`danieljoppi/AntHocNet`](https://github.com/danieljoppi/AntHocNet) (`AGENTS.md`, `CONTEXT.md`, `docs/adr/`) |
| Pick up open work | this repo's issues — highest open `priority:P*` first; newest open `handoff` issue for work in flight |
