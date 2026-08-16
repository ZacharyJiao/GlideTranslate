# Contributing

Glide Translate targets macOS 14+ and is developed with full Xcode. The current
validation baseline is Xcode 26.6 with Swift 6.3.3 on arm64 macOS.

## Safety rules

- Never add real credentials, tokens, selected text, prompts, responses,
  endpoints, model names, application content, local paths, diagnostics, or
  private reports to fixtures, commits, issues, or pull requests.
- Use synthetic content and the reserved `example.invalid` domain for public
  network-shaped examples.
- Do not broaden the public candidate allowlist to include plans, handoffs,
  local reports, IDE state, databases, archives, or agent state.
- Do not change repository settings, Actions permissions, signing,
  notarization, distribution, or release state as part of an ordinary code
  contribution.

## Local checks

Use per-command full-Xcode selection; do not change the machine-wide
`xcode-select` setting.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/test_all.sh
```

The aggregate creates an explicit-path candidate snapshot and runs the public
tree/Gitleaks policy, workflow pinning, localization, Actionlint, SwiftPM tests,
App/UI tests, and warning-as-error Debug/Release Xcode gates. Gitleaks 8.30.1
and Actionlint 1.7.12 are the pinned audit-tool versions.

Useful focused checks include:

```bash
./script/test_public_tree.sh
./script/test_workflow_pins.sh
./script/check_localizations.sh
./script/test_architecture_boundaries.sh
./script/test_candidate_snapshot.sh
```

## Git hooks

Hook installation is applicable only after this source tree has been placed in
an initialized Git repository. From that repository root:

```bash
./script/install_hooks.sh . .
./script/verify_hooks.sh . .
```

Do not routinely use `--no-verify`. If an emergency bypass is genuinely
required, record the reason and run the equivalent checks before review.

## Pull-request evidence

A pull request should describe the behavior and privacy boundary changed, list
the exact checks run with PASS/FAIL/BLOCKED categories, disclose manual or GUI
preconditions that were not verified, and avoid raw logs or private machine
details. A passing automated gate does not convert a blocked manual row into a
PASS or authorize a release.
