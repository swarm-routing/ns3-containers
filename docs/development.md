# Developer guide

This repository builds and publishes `ghcr.io/swarm-routing/ns3-dev`: ns-3
configured and prebuilt at `/opt/ns-3`, in several profiles (`default`,
`debug`, `sanitized`, `optimized`) and on several base images, plus the
`ns3-build-contrib` script that compiles a contrib module against that warm
tree. Every other org repository builds and tests in these images. This page
shows how to set up, build an image, test it, lint, and what CI checks; the
README ("Which image", "Building the images") describes the images
themselves and [layout.md](layout.md) every file. The rules a change must
keep are in [AGENTS.md](../AGENTS.md) ("Golden rules"); how issues and pull
requests work is in the org's
[CONTRIBUTING.md](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md).

## Prerequisites

| Tool | Version | Needed for |
| --- | --- | --- |
| Linux, or macOS with Docker Desktop, `git`, `make` | any recent | everything |
| Docker with Buildx | any recent; 4 CPU cores and about 15 GB free to build one image | building and testing an image |
| Python | 3.11 or newer | `tools/` and their tests |
| shellcheck | any recent (CI: the runner's) | `make lint` |
| actionlint | 1.7.12 (`pip install actionlint-py==1.7.12.25`) | `make lint` |
| hadolint | 2.x (CI: hadolint-action v3.5.0) | linting the Dockerfile |

An image build compiles ns-3 from source: 8 to 15 minutes on 4 cores. The
images are `linux/amd64`; on Apple silicon the build runs under emulation
and is much slower.

## Get the code

```bash
git clone https://github.com/swarm-routing/ns3-containers.git
cd ns3-containers
```

There are no submodules. `test/downstream.sh --check` reads a script from
swarm-routing/.github: clone that next to this repository, or set
`ORG_TOOLS_DIR` to a checkout of it.

## Dependencies

What goes into an image is pinned in the repository: the base images by
digest and the ns-3 release list in `tools/ns3_matrix.py` (generated from
ns-3's upstream tags, never typed), the stock ns-3 modules in
`NS3_MODULES` of `docker/Dockerfile`, and gcovr by hash in
`docker/gcovr-requirements.txt`. Automatic pipelines build only the release
ns-3 supports (its latest); older releases are built on demand. The org's
release locks and the vcpkg plan (swarm-routing/.github#489) are about the
protocol repositories, not this one.

## Build

One image, locally:

```bash
make build PLATFORM=linux/amd64    # docker buildx build --load --platform linux/amd64 -f docker/Dockerfile -t local/ns3-containers:dev .
docker build --platform linux/amd64 -f docker/Dockerfile --build-arg NS3_VERSION=3.48 \
    --build-arg BUILD_PROFILE=debug -t ns3-dev:3.48-debug .      # a given release and profile
```

The published images are `linux/amd64`; without `--platform` Docker
builds for its own platform (`linux/arm64` on Apple silicon). `BASE_IMAGE`
selects the base (Ubuntu 24.04 by default, Debian 13, Debian 13
slim, Alpine); the README's "Building the images" lists the arguments.
`make dist` builds the release's source tarball.

## Test

| What | Command | CI |
| --- | --- | --- |
| the tools' unit tests | `python3 -m unittest discover -s tools` | `resolve the ns-3 release(s)` (`publish-images.yml`) |
| every test stage on one image (labels, security, structure, profile, smoke, integration, unit) | `EXPECT_VERSION=3.48 EXPECT_PROFILE=debug EXPECT_OS=ubuntu test/run.sh ns3-dev:3.48-debug` | `test <image>` jobs, then `images gate` |
| one or more stages | `test/run.sh --stages structure,smoke <image>` | same |
| the tools' tests, a build and every stage | `make test` | |
| the downstream list parses | `ORG_TOOLS_DIR=../.github test/downstream.sh --check` | `downstream canary` |
| every org module builds and passes on an image | `ORG_TOOLS_DIR=../.github test/downstream.sh ns3-dev:3.48-debug` | `downstream canary` (gates the `latest-*` tags) |

`test/run.sh` is meant for an image built from the same commit: CI tests
each candidate by digest before tagging it. Pointed at an older published
image, a stage whose test moved on since that image was built can fail. The
`security` stage runs Trivy on the host (it pulls Trivy's image). The smoke
must report a small Ninja step count (gate 40): a larger number means the
image's warm build cache was missed.

## Run

Use an image the way every downstream repository does: mount a contrib
module and build it against the warm tree.

```bash
docker run --rm -v "$PWD/test/fixtures/swarm-hello:/src/swarm-hello:ro" \
    ghcr.io/swarm-routing/ns3-dev:latest-debug ns3-build-contrib --test swarm-hello=/src/swarm-hello
docker run --rm ghcr.io/swarm-routing/ns3-dev:latest-debug ns3-build-contrib --help
```

The README's "Building a contrib module" covers `--strict-warnings`,
`--coverage`, `--quality-modules` and `--run`.

## Docker and dev containers

This repository is the org's Docker setup: `docker/Dockerfile` is the one
image definition and `docker/scripts/build-contrib.sh` becomes
`/usr/local/bin/ns3-build-contrib`. `make shell` opens a shell in the
published `ns3-dev:latest-debug` image with this checkout at `/src`. There
is no `.devcontainer/`.

## Lint and format

```bash
make lint                                   # shellcheck on every .sh, then actionlint
docker run --rm -i -v "$PWD/.hadolint.yaml:/.hadolint.yaml:ro" hadolint/hadolint < docker/Dockerfile   # the hadolint job, with its config
make headers                                # licence headers (fetches the org tools)
make org-sync-check
make check                                  # lint, test (builds an image), headers, org-sync
```

`container-security.yml` also runs a Trivy configuration scan; its findings
and hadolint's go to the repository's code scanning alerts.

## CI map

| Workflow | Job (check name) | What it checks | Required |
| --- | --- | --- | --- |
| `publish-images.yml` | `images gate` | builds each affected image once, tests it by digest in every stage, and on `main` promotes the same digest to its tags | yes |
| `publish-images.yml` | `downstream canary` | the org's modules build and pass on the Ubuntu debug candidate | no on a PR; gates `latest-*` on `main` |
| `container-security.yml` | `hadolint`, `trivy-config` | the Dockerfile's lint and configuration scan | no (`hadolint` fails on a warning) |
| `licence.yml` | `headers / licence` | licence headers | yes |
| `candidates-cleanup.yml` | | daily: deletes stale candidate images and caches | no (scheduled) |
| `org-sync.yml` | `check / org-sync` | the org-managed files match the templates | yes |
| `pr-title.yml` | `title / title` | the PR title is a lowercase Conventional Commit | yes |
| `review-gate.yml` | `review / coderabbit` | CodeRabbit has reviewed the PR | yes |
| `release.yml`, `dco.yml`, `scorecard.yml`, `sync-labels.yml` | | the release (dispatched); sign-off on outside contributions; OpenSSF Scorecard; labels | no |

On a pull request, `publish-images.yml` tests only the images the change
affects (`tools/pr_tests.py`; AGENTS.md golden rule 17 has the rules), so a
docs-only PR builds nothing. The required checks are the ones the `main`
ruleset lists: `gh api repos/swarm-routing/ns3-containers/rules/branches/main`.
`main` merges through a merge queue, so a pull request is merged by enabling
auto-merge.

## Release

Releases follow the org procedure: [CONTRIBUTING "Cutting a release"](https://github.com/swarm-routing/.github/blob/main/CONTRIBUTING.md#cutting-a-release).
A release here versions the pipeline and its contract (the source tarball
`make dist` builds), never an image tag: images are published continuously
by `publish-images.yml`, each under a rolling tag and an immutable
`<ver>-<profile>-<sha7>` tag.

## Troubleshooting

- **The smoke reports a large Ninja step count.** The configure line in
  `docker/Dockerfile` and `docker/scripts/build-contrib.sh` drifted apart
  (golden rule 10); every downstream job would rebuild ns-3.
- **A suite fails on one exact ns-3 version because of an upstream bug.**
  Add it to `test/known-failures.txt` with its tracking issue; never skip or
  loosen the check.
- **The build fails behind a TLS-intercepting proxy.** Build from a scratch
  copy of the Dockerfile with the proxy's CA added; never commit that layer.
- **The build is very slow or fails with an exec format error on Apple
  silicon.** The images are `linux/amd64`; Docker emulates it.
- **`test/downstream.sh` says a script is not found.** Clone
  swarm-routing/.github next to this repository or set `ORG_TOOLS_DIR`.
- **You need another distribution, compiler or ns-3 version.** Open an
  *Image request* issue (README "Need another distribution, version or
  compiler?").
