# Repository layout, file by file

What each file does, in the detail `AGENTS.md` leaves out: its flags, the
stages and jobs it runs, and the issues behind them. `AGENTS.md` keeps a
one-line map and points here; update both when a file is added, moved or
changes what it does.

```
docker/Dockerfile                 BASE_IMAGE x NS3_VERSION x BUILD_PROFILE image
tools/pass_markers.py             promote's check: every test job of an image passed, all on one digest (+ test_pass_markers.py)
tools/ns3_matrix.py               supported release vs on-demand releases (`--tier latest`: the supported release only), base digests and tags, the PR representatives; `--missing-only` (the weekly run): only a release with a required image's own versioned tag not yet published, the missing ones named in `--summary` (#149) (+ test_ns3_matrix.py)
tools/pr_tests.py                 the PR test selection: which images and stages a pull request tests (`select` job; + test_pr_tests.py)
tools/cache_tags.py               the cache tags candidates-cleanup.yml deletes: `<ver>-<base>-<profile>` scopes of releases older than the supported one (read from upstream as ns3_matrix.py reads it); prints the version ids, deletes nothing itself (+ test_cache_tags.py)
tools/release/dist.sh             dist.sh VERSION OUT-DIR (`make dist`, the release workflow's build): ns3-containers-VERSION.tar.gz, the tracked docker/, test/, tools/, .github/workflows/, the build context's ignore and lint files, README, licences, CITATION.cff and INSTALL.txt; deterministic (sorted, fixed owner, the commit's time, gzip -n); then checks the unpacked tree (bash -n, the tools' tests, downstream.sh --check; DIST_CHECK=0 skips)
.cz.toml                          Commitizen: the release version (the pipeline's and its contract's, never an image tag), `major_version_zero = false` (the first release is v1.0.0, maintainer decision 2026-11-13), version_files CITATION.cff
CITATION.cff                      seeded by org-sync (`citation = true`); `version:` kept by Commitizen, `doi:` written by org-bot once Zenodo archives the first release
docker/gcovr-requirements.in      gcovr's pin for the debug/sanitized images; docker/gcovr-requirements.txt: its hashed lock (uv pip compile, command in the .in)
docker/scripts/build-contrib.sh   -> /usr/local/bin/ns3-build-contrib (--strict-warnings / --coverage [--quality-modules] through swarm-quality.cmake, the contrib targets only; ns-3.43+ and 3.36-3.42 target names)
docker/scripts/swarm-quality.cmake   the quality hook build-contrib.sh passes to CMake: strict warnings and coverage flags on the contrib modules' targets only (golden rule 10)
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
.github/workflows/publish-images.yml   resolve -> build once (candidate in ns3-dev-ci) -> select the tests (PRs: only what the PR affects) -> test by digest -> promote = retag the same digest (main) -> sign -> attest -> CVE report to code scanning (non-blocking); downstream canary on the ubuntu debug candidate (advisory on PRs, opens/updates an issue on main) -> latest-* -> discard this run's candidates (PRs too); weekly new release; `versions` = on demand; `refresh` = OS security refresh of the supported release (REFRESH=<run id>, --tier latest); runs on every PR (other paths: empty matrix), `images gate` is the check to require
.github/workflows/container-security.yml   every push/PR: hadolint (gate) and a Trivy config scan, both as SARIF to code scanning (the image CVE report is in publish-images' promote job)
.github/workflows/release.yml          the org release pipeline (swarm-routing/.github reusable-release.yml): dispatch `dry-run` or `bump` (with `increment`: auto, passed as '', or PATCH, MINOR, MAJOR; MAJOR for the first release, v1.0.0), merging the bump PR releases `make dist`'s tarball with checksums, SBOM and signed provenance; no image job: the images keep publish-images.yml and their ns-3 tags
.github/workflows/pr-title.yml         the PR title is a lowercase Conventional Commit (reusable-pr-title.yml)
.github/workflows/candidates-cleanup.yml   daily and as publish-images.yml's `sweep` job on every main pipeline: ns3-dev-ci candidates left by failed runs (> 2 days), untagged ns3-dev-cache versions (> 1 day), and the ns3-dev-cache tags of every release but the supported one (`tools/cache_tags.py`; an on-demand build's scope goes at the next run, no grace period; a tag that is not `<ver>-<base>-<profile>` is kept and reported; nothing deleted when the supported release is unknown or has no scope in the package; the step summary lists what was kept and deleted; #146); never ns3-dev
.github/workflows/licence.yml     licence headers (tooling MIT OR GPL-2.0-only, rest GPL-2.0-only); its `dual-roots` are org-sync.toml's `dual` and the `make headers` roots: change the three together
.github/workflows/sync-labels.yml      the org label taxonomy (swarm-routing/.github labels.json) applied here: creates and updates, never deletes; monthly, on demand, and on a PR that changes the file
.github/workflows/org-sync.yml         org-managed (template: swarm-routing/.github templates/workflows/org-sync.yml): the org-managed files match the org templates; the required check `check / org-sync`
.github/workflows/review-gate.yml      org-managed (templates/workflows/review-gate.yml): the bounded wait for CodeRabbit's review; the required check `review / coderabbit`
.github/workflows/dco.yml              org-managed (templates/workflows/dco.yml): every outside commit is signed off; pull requests only, not a required check
.github/workflows/scorecard.yml        org-managed (templates/workflows/scorecard.yml): OpenSSF Scorecard, weekly and on push to main; a report, never a gate
.github/org-sync.toml             this repo's org-sync configuration (kind, the dual-licensed roots that LICENSING.md, licence.yml and `make headers` share, SECURITY.md texts) and its `[settings]`: GitHub settings as code (ruleset, required checks, merge queue)
Makefile                          the org's standard targets (build, test, lint, format, check, clean, shell, ci) with this repo's commands; `headers` and `org-sync-check` fetch the org tooling; `org_sync.py reseed Makefile` re-renders it from org-sync.toml
docs/references.bib               the works this repository relies on (org-sync renders CITATION.cff `references:` and the README's citing section from it)
.github/ISSUE_TEMPLATE/           the org's forms (org-sync items, `forms = true`: a repo folder replaces the org defaults) + image-request.yml
```
