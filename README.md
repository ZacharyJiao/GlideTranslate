# Glide Translate

Glide Translate (轻译) is a macOS 14+ translation companion for selected text
and manual input. It defaults to a local, on-device Ollama provider and also
supports explicitly configured OpenAI-compatible providers.

## Privacy-first defaults

- Manual input works without Accessibility permission.
- Automatic capture is off by default. Mouse and optional keyboard capture
  must be enabled globally and allowed for each source application.
- The global shortcut first uses explicit selection capture. Its optional
  clipboard fallback is off by default and is used only for that shortcut.
- Every provider is labeled Local (this Mac), Local Network, Cloud, or
  unresolved. Off-device destinations require confirmation. Automatic capture
  to an off-device provider additionally requires per-application
  authorization.
- A request stays bound to the selected provider; Glide Translate does not
  silently retry through another provider.
- History is off by default. When enabled, completed source and result text is
  encrypted at rest and maintained under retention and count limits.

See [Privacy](PRIVACY.md) for the complete data-flow description and
[Compatibility](docs/compatibility.md) for application-specific limitations.

## Build from source

The verified public path is currently a source build with full Xcode. No
signed or notarized binary is claimed available.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project GlideTranslate.xcodeproj -scheme GlideTranslate \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

To build and launch the local Debug app:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh run
```

Detailed prerequisites and verification commands are in
[Building](docs/building.md) and [Verification](docs/verification.md).

## Project documents

- [Security policy](SECURITY.md)
- [Privacy](PRIVACY.md)
- [Contributing](CONTRIBUTING.md)
- [Compatibility](docs/compatibility.md)
- [Building](docs/building.md)
- [Verification](docs/verification.md)
- [Distribution](docs/distribution.md)
- [MIT License](LICENSE)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
