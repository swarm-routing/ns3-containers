# Security Policy

`swarm-routing/ns3-containers` is the org's ns-3 development images (`ghcr.io/swarm-routing/ns3-dev`), used by every repository's CI. This document records its
security posture honestly; it promises nothing the code does not do. The
org-wide policy is [swarm-routing/.github SECURITY.md](https://github.com/swarm-routing/.github/blob/main/SECURITY.md).

## Trust boundary

<!-- Which input is untrusted, the only code that parses it, and what that
code guarantees. A protocol: its wire-format decoder (org invariant 3). A
tool: the parsers of files it reads. If nothing parses untrusted input, say
so in one line. -->
The build inputs: base images pinned by digest, actions pinned by commit SHA,
and the ns-3 source fetched from upstream's release tag. Images are published
only from `main`; a pull request's candidate goes to `ns3-dev-ci` and is
deleted after its run.

## Known, by-design limitations (out of scope)

- The images run as root: they are development and CI images (Trivy DS-0002 is
  accepted in `.trivyignore`).
- ns-3 is research software and is not hardened.
- Older ns-3 releases, built on demand, get no OS security refresh.
- The Alpine base is experimental.
- Known findings: the README's "Known issues and findings", #35 and #49.

<!-- org-sync:begin reporting -->
## Reporting a vulnerability

Report privately through GitHub's private vulnerability reporting: the
repository's **Security** tab, then **Report a vulnerability**. If that is
not available, open an issue that only asks for a private contact, and put
no vulnerability details in it. This is a research project maintained on a
best-effort basis: expect an acknowledgement within a few days, not an SLA.
<!-- org-sync:end reporting -->

## Verifying what it ships

```bash
cosign verify \
  --certificate-identity https://github.com/swarm-routing/ns3-containers/.github/workflows/publish-images.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/swarm-routing/ns3-dev:<tag>
gh attestation verify oci://ghcr.io/swarm-routing/ns3-dev:<tag> --owner swarm-routing
```

The attestation is the build provenance (an SBOM follows with #38). For a
published number, pin an immutable `-<sha7>` tag or a digest, never a
rolling tag.
