# CONTEXT.md — orientation and history

Background an agent or a new contributor needs that does not belong in
`AGENTS.md`: domain notes, current state, glossary, open questions. Read the
section a task needs, not the whole file.

## Current state

**Live.** `ghcr.io/swarm-routing/ns3-dev` is published for the ns-3 release
upstream supports (its latest): Ubuntu in the `default`, `debug`, `sanitized`
and `optimized` profiles, Debian and Debian slim in `default` and `debug`, and
Alpine in `debug` only (experimental). Every image is built once and tested
by digest; the versioned tags are then carbon copies of that digest, which is
signed and attested, and only then do the `latest-*` tags move. Known
exceptions: ns-3.49's stock AODV livelocks (#35), and the 3.49 Debian/slim
legs failed their tests (#64). The work queue is handoff #62.

## Glossary

## Open questions
