# Verification

Glide Translate keeps automated, manual, remote, and release evidence separate.
A PASS in one class does not fill a row in another.

## Automated local candidate gate

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/test_all.sh
```

This command creates an explicit-path candidate snapshot and, from that
snapshot, runs:

1. public-tree policy and one structured Gitleaks scan;
2. immutable workflow-reference, localization, and compatibility-report checks;
3. a synthetic bounded local-provider preflight harness;
4. synthetic release-archive and payload-inspection fixtures;
5. synthetic bounded-download, safe-extraction, and external-surface fixtures;
6. Actionlint;
7. all SwiftPM tests;
8. Debug App and UI tests with compiler warnings treated as errors; and
9. a generic macOS Release build with warnings treated as errors.

The candidate-owner harness is verified separately:

```bash
./script/test_candidate_snapshot.sh
```

It covers path normalization, symlink refusal, deterministic modes, caller
ownership, cleanup failure, and INT/TERM/HUP behavior.

## Local provider preflight evidence

On 2026-08-15, a read-only preflight found Ollama 0.32.9 available with the
model category `locally installed`. The bounded synthetic harness separately
verified timeout, response-limit, HTTP-status, invalid-response, unavailable,
cleanup, and signal categories without publishing a model name, service
address, response body, or raw diagnostic.

This is preflight evidence only. The required shortcut-to-Accessibility-
capture, native stream, passive panel, explicit Copy, and history-off flow has
not been run because it requires current explicit tester opt-in. No real local
end-to-end or release-readiness claim is made.

## Manual compatibility evidence

Application and Accessibility behavior requires the pending manual matrix.
Until it is populated, [Compatibility](compatibility.md) remains **Release
evidence pending**. `MANUAL_BLOCKED_GUI_SESSION`, `BLOCKED_MISSING_APP`, or
another BLOCKED category is not a PASS.

## Remote and release evidence

Remote CI evidence requires a separately authorized repository and is not
claimed by local checks. A local unsigned arm64 archive and its payload were
inspected on 2026-08-15, but signing, notarization, Gatekeeper, installed-
artifact, and public-release evidence remain separate authorization gates; see
[Distribution](distribution.md).

The external-surface fixtures verify local scanning, bounded binary writes,
and archive rejection/extraction behavior. They do not inspect repository
history, pull requests, comments, Actions logs or artifacts, releases, or
assets. Those real surfaces remain unverified until an exact repository is in
scope.

Reports publish only sanitized categories, versions, architecture/OS major,
gate names, status, and duration. Raw logs, local paths, device/user names,
endpoints, models, credentials, and application content are not public
verification evidence.
