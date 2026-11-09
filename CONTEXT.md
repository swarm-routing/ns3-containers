# CONTEXT.md — orientation and history

Background an agent or a new contributor needs that does not belong in
`AGENTS.md`: domain notes, current state, glossary, open questions. Read the
section a task needs, not the whole file.

## Current state

**Live.** `ghcr.io/swarm-routing/ns3-dev` is published for the ns-3 release
upstream supports (its latest), in the `default`, `debug`, `sanitized` and
`optimized` profiles on Ubuntu, Debian and Alpine bases; every image is built
once, tested by digest, signed and attested before its tag moves. Known
exceptions: ns-3.49's stock AODV livelocks (#35), and the 3.49 Debian/slim
legs failed their tests (#64). The work queue is handoff #62.

## Glossary

## Open questions
