## v1.0.0 (2026-11-13)

### Feat

- **release**: release through the org workflow; the first release is v1.0.0 (#160)
- **image**: ship the full group's unit test libraries pre-built on debug and sanitized (#105)
- **image**: unzip, curl and gnupg on the debug image for the sonar step (#90)
- **image**: gcovr 8.6 on the debug and sanitized images, pinned with hashes (#84)
- **images**: refresh mode for the supported release (#76)
- **images**: upgrade the base's os packages at build, with a refresh arg to rerun the layer (#74)
- **contrib**: ns3-build-contrib --strict-warnings and --coverage, on the named modules only (#58)
- build only the ns-3 release upstream supports; older releases on demand (#33)
- generated ns3-dev matrix — top 10 ns-3 releases, default profile, Debian/slim/Alpine bases, GHCR cache (#10)
- ns3-dev images (3.43 optimized/debug/sanitized) with ns3-build-contrib (#1)

### Fix

- audit follow-ups (the --missing-only filter, the canary's marker download, cosign before the tags, old cache tags deleted daily, stale docs) (#151)
- **unit**: no grep -q on the test runner's suite list under pipefail (#100)
- **promote**: read the pass marker when one artifact matches the pattern (#102)
- **issue-forms**: point the issue chooser at swarm-routing/AntHocNet (#98)
- **images**: fail fast and retry apt-get update on a mirror outage (#79)
