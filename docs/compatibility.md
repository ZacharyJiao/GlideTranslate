# Compatibility

> Manual release evidence is pending execution in an interactive macOS tester session.

Glide Translate requires macOS 14 or later. Manual input does not require
Accessibility permission. Selection capture depends on each application's
accessibility tree, selected control, Secure Input state, and the trigger used;
universal compatibility is not claimed.

The application inventory below was collected locally on 2026-08-15 without
opening user content. All eight required applications were present. The
synthetic manual protocol has not been completed because its global-shortcut
and menu-bar interactions require an interactive tester session. These rows
therefore remain honestly classified `Blocked`; they are not release-pass
evidence.

| Application | Bundle ID | Tested Version | Mouse Automatic Disabled | Mouse Allowed | Optional Keyboard | Shortcut Selection | Shortcut Clipboard | Manual Input | Bounds | Classification | Limitation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Safari | com.apple.Safari | 26.5.2 | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | Blocked | Synthetic application protocol requires an interactive tester session. |
| Chrome | com.google.Chrome | 151.0.7922.109 | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | Blocked | Synthetic application protocol requires an interactive tester session. |
| TextEdit | com.apple.TextEdit | 1.20 | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | Blocked | Synthetic application protocol requires an interactive tester session. |
| Notes | com.apple.Notes | 4.13 | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | Blocked | Synthetic local-note protocol requires an interactive tester session. |
| Xcode | com.apple.dt.Xcode | 26.6 | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | Blocked | Synthetic project-fixture protocol requires an interactive tester session. |
| Visual Studio Code | com.microsoft.VSCode | 1.132.1 | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | Blocked | Synthetic application protocol requires an interactive tester session. |
| Terminal | com.apple.Terminal | 2.15 | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | Blocked | Fresh-window synthetic protocol requires an interactive tester session. |
| Preview | com.apple.Preview | 11.0 | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | BLOCKED_TESTER_EXECUTION_REQUIRED | Blocked | Disposable PDF protocol requires an interactive tester session. |

The second-display, non-default-scaling, Light, Dark, keyboard-only,
VoiceOver, and Reduce Motion rows are also blocked pending interactive tester
execution. No multi-display or accessibility compatibility claim is made.

The compatibility classifications are limited to `Full`, `Text-only`,
`Manual-input`, `Shortcut-clipboard`, `Rejected`, and `Blocked`. Automated
tests and application presence cannot substitute for the manual protocol.
