# AGENTS.md — guide for AI coding agents

Operational guide for LLM agents working in `swarm-routing/ns3-containers`. Read this
before changing anything. Org-wide conventions:
[`swarm-routing/.github` CONTRIBUTING.md](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md). Shape and rules mirror
[AntHocNet's AGENTS.md](https://github.com/danieljoppi/AntHocNet/blob/main/AGENTS.md), the source repository.

## What this repo is

Builds and publishes `ghcr.io/swarm-routing/ns3-dev:<ns3-version>-<profile>`:
ns-3 pre-configured and pre-built with Ninja at `/opt/ns-3`, so a downstream
contrib module compiles alone in seconds. Profiles: `debug` (CI default),
`sanitized` (ASan+LSan+UBSan), `optimized` (ns-3 `-d release`, campaigns only).
`ns3-build-contrib` links mounted modules into the tree and builds them.

```
docker/Dockerfile                 NS3_VERSION x BUILD_PROFILE image
docker/scripts/build-contrib.sh   -> /usr/local/bin/ns3-build-contrib
test/smoke.sh                     image smoke (incremental build + test.py + guards)
test/fixtures/swarm-hello/        minimal C++20 contrib module used by the smoke
.github/workflows/publish-images.yml   build -> smoke -> push (main) per version x profile
```

## Build & verify

```bash
docker build -f docker/Dockerfile --build-arg NS3_VERSION=3.43 \
    --build-arg BUILD_PROFILE=debug -t ns3-dev:3.43-debug .        # ~8 min on 4 cores
docker run --rm -v "$PWD:/src:ro" ns3-dev:3.43-debug bash /src/test/smoke.sh
shellcheck docker/scripts/build-contrib.sh test/smoke.sh
actionlint .github/workflows/*.yml
```

The smoke must report a small Ninja step count (8 today, gate 40): a larger
number means the warm cache was missed. Behind a TLS-intercepting proxy, build
from a scratch copy of the Dockerfile with the proxy CA added; never commit
that layer. The PR's own `publish-images` run is the authoritative check.

## Golden rules (invariants — do not break)

Org-wide (1–9), then this repo's own.

1. **SPDX header on every original source file.** `.h`, `.cc`, `.cpp`, `.py`
   (and scripts, workflows) start with
   `// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)` +
   `// SPDX-License-Identifier: MIT` (`#` comments where needed). CI checks it.
2. **No GPL code in an MIT repo.** Never copy from ns-3's `src/aodv`, `src/olsr`
   or any other ns-3 module; implement against public ns-3 interfaces. From
   AntHocNet, only the `MIT OR GPL-2.0-only` paths (`core/`, `tools/`,
   `ns3/tools/`, `docs/tools/`) may be extracted as-is. Its `ns3/` modules
   (the `adaptive` arms, `routing-bench`, `oracle`) are **GPL-2.0-only**:
   bringing one here needs the copyright holder's explicit relicensing
   decision recorded in an issue first. `ns3/baselines/aomdv` and `gpsr` are
   third-party GPL and never come here.
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
14. **One buildx cache scope per version x profile** (`mode=max`); drop a scope when its version leaves the matrix.

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
| Add an ns-3 version or profile | `publish-images.yml` matrix + `Dockerfile` profile `case` |
| Add a stock ns-3 module to the images | `NS3_MODULES` in `docker/Dockerfile` (every downstream repo inherits it) |
| Change how contrib modules build | `docker/scripts/build-contrib.sh` (+ `test/smoke.sh`) |
| The reference image this was derived from | AntHocNet `docker/Dockerfile.ns3`, `.github/workflows/images.yml` |
| The org's invariants, labels, issue shape | [`swarm-routing/.github` CONTRIBUTING.md](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md) |
| The reference implementation and its history | [`danieljoppi/AntHocNet`](https://github.com/danieljoppi/AntHocNet) (`AGENTS.md`, `CONTEXT.md`, `docs/adr/`) |
| Pick up open work | this repo's issues — highest open `priority:P*` first; newest open `handoff` issue for work in flight |
