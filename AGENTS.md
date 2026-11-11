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
tools/pass_markers.py             promote's check: every test job of an image passed, all on one digest (+ test_pass_markers.py)
tools/ns3_matrix.py               supported release vs on-demand releases (`--tier latest`: the supported release only), base digests and tags (+ test_ns3_matrix.py)
docker/gcovr-requirements.in      gcovr's pin for the debug/sanitized images; docker/gcovr-requirements.txt: its hashed lock (uv pip compile, command in the .in)
docker/scripts/build-contrib.sh   -> /usr/local/bin/ns3-build-contrib (--strict-warnings / --coverage [--quality-modules] through swarm-quality.cmake, the contrib targets only; ns-3.43+ and 3.36-3.42 target names)
test/run.sh                       every test stage against one image ref (the candidate digest in CI); `security` runs Trivy (pinned by digest) on the host; `--stages`/`--unit-shard i/N` run a part (split test jobs, #86)
.trivyignore                      accepted Dockerfile findings, each with its reason (the vuln and secret scans take none)
.hadolint.yaml                    hadolint settings: failure at warning, apt/apk version pinning (DL3008/DL3018) ignored, trusted registries
test/structure.sh                 image contract: tree, tools, env, configure record, CMake cache vs profile, C++ standard, gcovr on debug/sanitized, unzip/curl/gpg on debug
test/profile.sh                   the profile keeps its promise: asserts/logs on or off, sanitizers catch planted bugs, no AVX
test/smoke.sh                     image smoke (incremental build + test.py + guards; --strict-warnings catches a planted -Wshadow in a source and in an own header reached through ns3/, --quality-modules leaves a dependency unjudged, --coverage instruments the module only, the image's gcovr reports it)
test/integration.sh               ns-3 simulates: tutorial `first` + manet-canary AODV/OLSR/DSDV dense/sparse under a wall-clock budget
test/unit.sh                      ns-3's own QUICK unit suites for the modules in test/ns3-suites.txt (full on debug/sanitized; UNIT_SET=light|full overrides, light on PRs for the OS variants); prints every suite's time
test/ns3-suites.txt               which modules' suites the unit stage runs, per profile group; `split`/`shard` lines: which profiles test in parallel jobs (#86); `main-only`: suites pull requests leave out (#86)
test/known-failures.txt           upstream bugs expected on one exact ns-3 version (strict XFAIL, shown in the summary)
test/downstream.sh                the downstream canary: clone, stage, ns3-build-contrib --test and run each consumer in test/downstream.txt on one image (ubuntu debug only; --check validates the list); gates latest-*
test/downstream.txt               the org's ns-3 modules the canary builds (name | repo@ref | ns-3 range | modules | suites | stage | run); a new protocol is one line
test/fixtures/swarm-hello/        minimal contrib module (C++17..C++23) used by the smoke (GPL-2.0-only: an ns-3 module)
test/fixtures/manet-canary/       short MANET program for the integration stage (GPL-2.0-only)
test/fixtures/profile-probe/      one deliberate assert/log/memory bug per mode, for the profile stage (GPL-2.0-only)
.github/workflows/publish-images.yml   resolve -> build once (candidate in ns3-dev-ci) -> test by digest -> promote = retag the same digest (main) -> sign -> attest -> CVE report to code scanning (non-blocking); downstream canary on the ubuntu debug candidate (advisory on PRs, opens/updates an issue on main) -> latest-* -> discard this run's candidates (PRs too); weekly new release; `versions` = on demand; `refresh` = OS security refresh of the supported release (REFRESH=<run id>, --tier latest); runs on every PR (other paths: empty matrix), `images gate` is the check to require
.github/workflows/container-security.yml   every push/PR: hadolint (gate) and a Trivy config scan, both as SARIF to code scanning (the image CVE report is in publish-images' promote job)
.github/workflows/pr-title.yml         the PR title is a lowercase Conventional Commit (reusable-pr-title.yml)
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
test/downstream.sh --check                                         # the consumer list parses (no docker)
test/downstream.sh ns3-dev:3.48-debug                              # every org module builds and passes on the image (latest-* gate)
hadolint docker/Dockerfile                                       # reads .hadolint.yaml; exit 0 required
shellcheck docker/scripts/build-contrib.sh test/*.sh
actionlint .github/workflows/*.yml
```

The smoke must report a small Ninja step count (8 today, gate 40): a larger
number means the warm cache was missed. Behind a TLS-intercepting proxy, build
from a scratch copy of the Dockerfile with the proxy CA added; never commit
that layer. The PR's own `publish-images` run is the authoritative check.

## Golden rules (invariants — do not break)

Org-wide (1–9), then this repo's own.

<!-- org-sync:begin org-rules -->
1. **Licensing per directory, as AntHocNet** ([`LICENSING.md`](LICENSING.md);
   AntHocNet [LICENSING.md](https://github.com/danieljoppi/AntHocNet/blob/main/LICENSING.md),
   [ADR-0028](https://github.com/danieljoppi/AntHocNet/blob/main/docs/adr/0028-core-is-dual-licensed.md)). A
   simulator-free `core/` and the standalone tooling are `MIT OR GPL-2.0-only`;
   ns-3 modules, the site, docs and data are `GPL-2.0-only`. Every original
   `.h`/`.hpp`/`.cc`/`.cpp`/`.py`/`.sh` starts with
   `// Copyright (c) 2026 Daniel Joppi (https://github.com/swarm-routing)` +
   `// SPDX-License-Identifier: <MIT OR GPL-2.0-only | GPL-2.0-only>` (`#`
   comments where needed), matching its directory in `LICENSING.md`; an
   outside contributor may add their own `Copyright (c) <year> <Name>` line
   beneath the org line, never replace it, and signs off every commit (DCO,
   CONTRIBUTING "Outside contributions"). CI (`reusable-licence-check.yml`)
   checks the SPDX line, and the org line's place when a header names more
   than one holder; a header with a single, other holder (a replaced org line,
   or third-party code) passes it, so review catches that. A new directory
   gets its row in `LICENSING.md` in the same PR.
2. **The licence boundary only goes one way.** GPL code may use the dual
   parts; dual code never pulls GPL-only code in: a `core/` file includes only
   the C++ standard library, other `core/` files and the dual-licensed `core/`
   of a dependency pinned by commit and declared as the `core-deps` input of
   every workflow that runs the licence check (one calling
   `reusable-licence-check.yml`, or one calling `reusable-ns3-ci.yml`, which
   forwards it; workflow file names differ per repo), each with the same pin,
   with `core-roots` naming the repo's own `core/`
   (without it the check skips core includes; a protocol's `core/` on
   swarm-core's; CI checks it, `check-headers.py --core-dep`), and a dual script imports no GPL-only code. Code coming from AntHocNet keeps its
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
   Every job that runs steps has a `timeout-minutes` cap (a job that only
   calls a reusable workflow cannot take one: the called workflow's jobs carry it), and every apt, npm or installer step
   its own, sized from recent green runs; `apt-get update` runs with
   `--error-on=any` inside a shell retry. Ubuntu mirror outages are the usual
   cause of a red run.
9. **Nothing shipped depends on `.claude/`.** Skills hold procedures; scripts
   that anything shipped needs live in `tools/` (AntHocNet ADR-0014).
<!-- org-sync:end org-rules -->
10. **The configure line is shared.** `docker/Dockerfile` and `build-contrib.sh` must pass identical profile flags, `--enable-examples --enable-tests --disable-werror` and module list (the Dockerfile records them in `/opt/ns-3/.swarm-configure.env`); only the contrib list, the examples/tests filter and the quality hook's cache variables (`docker/scripts/swarm-quality.cmake`, which changes only the contrib modules' targets) may differ. Drift forces a full ns-3 rebuild in every downstream job — the smoke's step-count gate catches it.
11. **`optimized` is ns-3's `release` profile, never ns-3's `optimized`** (`-march=native` makes an image SIGILL on another CPU).
12. **CI consumes `debug`/`sanitized`, never `optimized`.** Asserts catch real bugs (AntHocNet #123).
13. **Pinned inputs.** The base image by digest; actions by SHA. A published number pins the immutable `:<ver>-<profile>-<sha7>` tag, not the rolling one.
14. **One buildx cache scope per version x base x profile** (`mode=max`, registry cache in `ns3-dev-cache`); delete a scope's tag when its version stops being the supported release.
15. **The version list is generated, never typed.** `tools/ns3_matrix.py` reads upstream tags; a hand-pinned version would silently stop following ns-3's supported release.
16. **Automatic pipelines build only the release ns-3 supports** (its latest; the generator's default). Older releases are history: never rebuild them as a side effect; the `versions` input is a deliberate, manual, on-demand build.
17. **What is tested is what is tagged.** Each image is built once; every test runs on that build by digest, in the same run; tags are a carbon copy of that digest (`imagetools create`), never a rebuild. A new test stage goes into `test/run.sh`, so automatic and on-demand builds (and fork PRs) all run it (#36, #37). An image may be tested in parallel jobs (`split` in `test/ns3-suites.txt`, #86), all on the same digest in the same run; promote needs every one of them, and `test/run.sh` with no option still runs everything. PRs never tag; `main` runs every stage on every image, each with its profile's whole unit group (`full` on every debug and sanitized image, `main-only` suites included), before it promotes the digest, so every published image is tested with every suite. On a PR only, two things are smaller: the Debian, slim and Alpine images run the `light` unit group (`UNIT_SET`, set by the workflow from the event and the matrix entry; maintainer decision on #87), Ubuntu `debug` and `sanitized` keep `full`; and every image leaves out the suites on `test/ns3-suites.txt`'s `main-only` line (`UNIT_PR=1`; today `ns3-tcp-cubic`, maintainer decision (c) on #86), saying so in the job log and summary. A run without `UNIT_SET` and `UNIT_PR` (a local run, a schedule or dispatch run, a push to `main`) runs the profile's whole group. A known upstream bug is a `test/known-failures.txt` entry for one exact ns-3 version with its tracking issue, never a skipped or loosened check.

## Conventions

<!-- org-sync:begin conventions -->
- Issues follow the org taxonomy ([CONTRIBUTING.md](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md#issues), from
  [AntHocNet ADR-0013](https://github.com/danieljoppi/AntHocNet/blob/main/docs/adr/0013-track-bugs-and-findings-as-issues.md)): one type label
  (`bug`/`enhancement`/`chore`/`documentation`/`verification`, plus `epic` for
  umbrellas), area label(s) (`protocol`/`adapter`/`ns3`/`benchmark`/
  `observability`/`packaging`/`learn-site`/`literature`), one `model:*`
  recommendation, one `priority:P1|P2|P3` on non-epic issues, a
  `release:vX.Y.Z` label only when a release in the repository's ladder
  (`docs/roadmap.md`; until it lands, the org ROADMAP's release train)
  gates the issue: that label set is the version's scope,
  and the version is released when its issues are done (CONTRIBUTING
  "Cutting a release"). Labels come from `labels.json` via the `sync-labels`
  workflow.
- Issue bodies: **Context** (evidence, numbers, links) · **Scope** ·
  **Acceptance criteria** (checkboxes) · **Depends on** (cross-repo form
  `swarm-routing/<repo>#N`) · **References**. Children of an epic say "Part of
  #N" and are linked as sub-issues. Comments you post end with the Claude Code
  footer.
- Issues migrated from AntHocNet carry `migrated` and start with *Migrated from
  `danieljoppi/AntHocNet#N`*.
- Epics are listed where contributors look. In a public repository, this
  README's `## Epics` section and the org
  [ROADMAP](https://github.com/swarm-routing/.github/blob/main/ROADMAP.md#epics)
  are generated from the issues labelled `epic` by `swarm-routing/.github`'s
  `tools/epics/epics.py`. An open epic is Planned (no sub-issue closed) or In
  progress (some closed); it becomes Done or Dropped only when you close the
  epic itself (as completed or as not planned), even if every sub-issue is
  closed. Whenever you change an epic (open, close, rename or re-scope it, add
  or remove its `epic` label) or one of its sub-issues (close, reopen, add,
  unlink), refresh the lists in that PR or the next one. You need
  `swarm-routing/.github` checked out next to this repository and `gh` logged
  in (or `GH_TOKEN` set). Run `python3 ../.github/tools/epics/epics.py readme .`
  in the repository that owns the epic (for a sub-issue of another
  repository's epic, that repository, not this one), then
  `python3 tools/epics/epics.py roadmap ROADMAP.md` and
  `python3 tools/epics/epics.py profile profile/README.md` in `.github`. Never
  edit a generated section by hand; the weekly `epics` workflow in `.github`
  only reports drift. Private repositories (such as `papers`) are never listed
  and keep no generated section.
- Make minimal, reviewable changes; update the relevant doc/ADR when you change
  a documented decision.
<!-- org-sync:end conventions -->

## Git workflow

<!-- org-sync:begin git-workflow -->
- Branch from `main` (`claude/<short-topic>`), one focused change per PR.
- **Always open a PR to `main`** once the branch is pushed — every change is
  tracked through one.
- **PRs are squash-merged** (the only merge method enabled). The PR title is
  the commit on `main`, so it is a lowercase Conventional Commit
  (`feat:`/`fix:`/`docs:`/`chore:`/`ci:`…, optional scope).
- Push with `git push -u origin <branch>`; merge when CI is green.
- **`main` takes no direct push**, in any repo: its ruleset requires a PR, an
  up-to-date branch and the required checks. Bots push `bot/<name>` branches
  and open PRs; a release is the bump PR from `bot/release`, tagged after it
  merges (CONTRIBUTING "Cutting a release").
- When a PR falls behind `main`, update it
  (`gh api -X PUT "repos/<owner>/<repo>/pulls/<n>/update-branch"`, with
  `<owner>/<repo>` the PR's base repository and `<n>` its number) and merge PRs one at a time, each after its CI on the updated branch. A
  repository with a merge queue (`merge_queue = true` in its `[settings]`)
  is not updated by hand: enable auto-merge and the queue tests each PR on
  the latest `main` and merges it (CONTRIBUTING "Merge when CI is green").
  Never force-push a branch someone else pushed. A behind `bot/release` PR is the exception:
  dispatch the release `bump` again, so the version and changelog are rebuilt
  on the new `main`.
- **Settings are code.** Repository settings, rulesets, required checks and the
  Actions allowlist change only by a PR to the repo's `[settings]` in
  `.github/org-sync.toml` or to `templates/rulesets/` in `swarm-routing/.github`,
  never in the UI or by a direct API write. A `templates/rulesets/` change
  applies on merge; a repo's `[settings]` change applies when `repo-settings`
  in `swarm-routing/.github` is dispatched with mode `apply` after the merge
  (the daily run only checks). A required check runs on every PR (no `paths:`
  filter; skip work inside a gate job instead) and is named exactly as its
  check run. A new third-party action goes into `defaults.json`
  `selected_actions` (`templates/rulesets/`) before or with the workflow that
  uses it: in the same PR in `swarm-routing/.github`, otherwise merged there
  first, or `repo-settings` refuses the repo.
<!-- org-sync:end git-workflow -->

<!-- org-sync:begin skills -->
## Agent skills

The org's procedures ship as the Claude Code plugin **`swarm-routing`**, from
[`swarm-routing/skills`](https://github.com/swarm-routing/skills). This
repository's `.claude/settings.json` enables it, so Claude Code offers a skill
when the task matches its description. Other agents (Codex, Cursor, Copilot, …)
install the same skills with `npx skills add swarm-routing/skills`
([skills.sh](https://skills.sh)). A skill is the procedure; the script does the
work and runs without it (golden rule 9), so an agent without the skill starts
from the script; so does a session that does not read this repository's
settings (some hosted sessions with several repositories do not). If Claude
Code says the plugin is missing (it was called
`org-repo` before 2026-11-09, and a cached marketplace keeps the old list), run
`claude plugin marketplace update swarm-routing` and start a new session.

| Task | Script (any agent) | Skill |
|------|--------------------|-------|
| Bring this repository onto the org templates, or fix their drift | `swarm-routing/.github` `tools/org-sync/org_sync.py` | `org-repo` |
| Write or review a protocol's paper-fidelity sheet (`docs/fidelity.md`) | `swarm-routing/.github` `tools/fidelity/fidelity.py` | `fidelity-sheet` |
| Check a diff against the org golden rules before a PR or a review | `swarm-routing/.github` `tools/protocol-review/check_invariants.py` | `protocol-review` |
| Bring the README, AGENTS/CLAUDE/CONTEXT and docs/ to the org documentation standard | `swarm-routing/.github` `tools/docs-review/check_docs.py` | `docs-review` |
| Find new papers on a topic, or confirm a reference (Crossref, Semantic Scholar, OpenAlex; free sources only) | `swarm-routing/.github` `tools/lit-search/lit_search.py` | `lit-search` |

A skill only this repository uses lives in its own `.claude/skills/`; a skill
two repositories need moves to the plugin. Skills that file, cite and extract
papers into the private papers library stay in `swarm-routing/papers`; finding
new papers and confirming a reference is public (`lit-search`). A public skill
may point to the papers skills, never carry library content. This section is managed by org-sync: add
a row in `swarm-routing/.github` `templates/agents/skills.md`, not here (an edit
here is undone by the next `org_sync.py apply`).
<!-- org-sync:end skills -->

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
