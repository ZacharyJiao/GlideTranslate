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
4. synthetic release-archive, DMG packaging, and signed-payload inspection
   fixtures;
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

On 2026-08-16, the controller also ran the panel accessibility/motion and
keyboard-navigation UI suites under both Light and Dark system appearances.
The five focused tests passed in each appearance. A separate controller-only
characterization enabled the real macOS Reduce Motion setting, launched the
panel without a motion override, observed the reduced-motion branch, and
passed before the setting was restored.

## Local provider preflight evidence

On 2026-08-15, a read-only preflight found Ollama 0.32.9 available with the
model category `locally installed`. The bounded synthetic harness separately
verified timeout, response-limit, HTTP-status, invalid-response, unavailable,
cleanup, and signal categories without publishing a model name, service
address, response body, or raw diagnostic.

A controller observation on 2026-08-16 reported a successful synthetic
shortcut-to-Accessibility-capture, native-stream, passive-panel, explicit-Copy,
and history-off path with a locally installed model. No independently
inspectable record of that run is retained in the public tree, so it is treated
as historical context rather than current release evidence. A release claim
requires fresh categorical evidence without publishing the model, endpoint,
selected text, prompt, result, or clipboard content.

## Manual compatibility evidence

The [Compatibility](compatibility.md) matrix records the sanitized local manual
evidence currently available. The complete A–J and bounds protocol was
reported as passing for the seven non-Chrome required applications, and the
later batched tester result marked Chrome's remaining local rows as passing.
The same result covered VoiceOver traversal/language/streaming, physical
second-display default/non-default scaling and boundary placement, and the
required real local Ollama shortcut-to-stream/panel/Copy/history-off path. The
current display-labelled ChatGPT/Codex surface remains documented outside the
eight-row table as shortcut-clipboard only: automatic AX selection is
unsupported, while explicit shortcut capture succeeds when the user-enabled
clipboard fallback is active.

The downloaded GitHub artifact/Finder quarantine path remains unverified and is
not a release-pass claim. No local compatibility row remains blocked; synthetic
tests are still not substituted for the categorical tester result.

## Remote and release evidence

Remote and Release evidence is valid only when GitHub identifies the exact
commit, checks, tag, asset size, and asset hash. Local checks do not substitute
for that evidence. The downloadable MVP uses an ad hoc signature and is
expected to fail Apple trust assessment because Developer ID and notarization
are intentionally absent; exact downloaded-artifact launch remains a separate
Finder/tester row. See [Distribution](distribution.md).

The external-surface fixtures verify local scanning, bounded binary writes, and
archive rejection/extraction behavior. Real repository history, pull requests,
comments, Actions logs/artifacts, releases, and assets require a separate live
enumeration; a fixture PASS is never reported as a live-surface PASS.

Reports publish only sanitized categories, versions, architecture/OS major,
gate names, status, and duration. Raw logs, local paths, device/user names,
endpoints, models, credentials, and application content are not public
verification evidence.
