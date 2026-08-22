# Compatibility

> Manual compatibility evidence is partially populated from the recovered A–J
> tester result and later current-build Chrome/Codex acceptance. Remaining
> distribution-specific gates are called out explicitly below.

Glide Translate requires macOS 14 or later. Manual input does not require
Accessibility permission. Selection capture depends on each application's
accessibility tree, selected control, Secure Input state, and the trigger used;
universal compatibility is not claimed.

The application inventory below was collected locally without opening user
content. The tester reported that the complete A–J protocol and bounds checks
passed for the seven non-Chrome required applications. A later batched tester
run reported all remaining local protocol rows as passing, including Chrome's
disabled and allowlist silence, keyboard-selection off/on, shortcut clipboard
fallback, manual input, and bounds/non-overlap checks. Only
distribution-specific evidence remains outside this matrix.

| Application | Bundle ID | Tested Version | Mouse Automatic Disabled | Mouse Allowed | Optional Keyboard | Shortcut Selection | Shortcut Clipboard | Manual Input | Bounds | Classification | Limitation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Safari | com.apple.Safari | 26.5.2 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None. |
| Chrome | com.google.Chrome | 151.0.7922.109 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None. |
| TextEdit | com.apple.TextEdit | 1.20 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None. |
| Notes | com.apple.Notes | 4.13 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None. |
| Xcode | com.apple.dt.Xcode | 26.6 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None. |
| Visual Studio Code | com.microsoft.VSCode | 1.132.1 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None. |
| Terminal | com.apple.Terminal | 2.15 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None. |
| Preview | com.apple.Preview | 11.0 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None. |

Controller-owned Light, Dark, keyboard-only, and real-system Reduce Motion
checks passed on 2026-08-16 using synthetic UI fixtures. The batched tester
result also marked the required VoiceOver traversal/language/streaming checks
and physical second-display default/non-default scaling and boundary-placement
checks as passing. The downloaded GitHub artifact/Finder quarantine path
remains outside this local matrix.

The current display-labelled ChatGPT target is the Codex desktop surface. Its
automatic AX selection remains unsupported; its explicit shortcut succeeds
only through the user-enabled shortcut-only clipboard fallback. This is a
`Shortcut-clipboard` compatibility note, not an additional table row.

The compatibility classifications are limited to `Full`, `Text-only`,
`Manual-input`, `Shortcut-clipboard`, `Rejected`, and `Blocked`. Automated
tests and application presence cannot substitute for the manual protocol;
distribution-specific gaps are not inferred from synthetic tests.
