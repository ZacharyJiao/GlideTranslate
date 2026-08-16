# Distribution

The currently verified distribution path is build from source. On 2026-08-15,
an unsigned arm64 Release archive was built with warnings treated as errors and
its bundle identity, macOS 14.0 minimum, accessory-app behavior, architecture,
system-only linkage, file types, paths, and payload categories were inspected.
This is local implementation evidence, not a distributable binary.

No downloadable binary, signed archive, notarized package, installer, update
feed, or release URL is claimed available. The inspected unsigned archive is
not proposed for distribution.

Use [Building](building.md) for unsigned local Debug builds. Those commands do
not require or select a signing identity and do not produce a release artifact.

A future binary can be described as available only after all of the following
are separately authorized and verified against one immutable candidate:

- repository and remote CI state;
- Release archive contents and architecture;
- signing identity, entitlements, and hardened-runtime result;
- notarization and stapling result;
- installation and launch of the exact packaged artifact; and
- publication of the exact verified artifact and checksums.

Source-build success, a local Release build, or a passing automated test suite
does not by itself satisfy those distribution gates.
