<p align="center">
  <img src="./assets/readme/hero-en.svg" width="100%" alt="Glide Translate — a local-first macOS translation companion for selected text and manual input">
</p>

<p align="center">
  <a href="./README.md">English</a> · <a href="./README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/ZacharyJiao/GlideTranslate/releases/tag/v0.2.0"><img src="https://img.shields.io/badge/release-v0.2.0-00a850" alt="Release v0.2.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-12201b" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-verified-12201b" alt="Verified on Apple silicon">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-d9a441" alt="MIT License"></a>
</p>

Glide Translate (轻译) is a menu-bar translation app for macOS 14 and later. It translates selected text or text entered manually, using a local Ollama model by default or an OpenAI-compatible service that you configure.

This README documents **v0.2.0**.

The app is local-first, but not “offline by definition”: text is sent to the provider selected for that request. Glide Translate shows whether a destination is on this Mac, on the local network, in the cloud, or unresolved, and asks for confirmation before using an off-device destination.

> [!IMPORTANT]
> The downloadable `v0.2.0` build is an Apple-silicon prerelease. It is ad hoc signed for bundle-integrity checks, but it is not Developer ID signed or notarized. Read [Install the prerelease](#install-the-prerelease) before opening it.

## The v0.2.0 experience

The source tree now presents the same privacy model through a calmer, more capable macOS interface:

- **Adaptive reading panel.** The result surface chooses a compact, standard, or reading width, caps growth to the selected display, and keeps long output in a selectable scrolling region. Scrolling away reveals **Back to Latest** without taking control from the reader.
- **Menu-bar command center.** The menu shows runtime status, destination locality, the active preset, pause/resume, manual translation, Settings, and the explicit translate action in one predictable surface.
- **Unified native windows.** Manual translation, onboarding, Settings, prompt editing, history, and safe recovery actions share the same spacing, typography, motion, keyboard, and accessibility rules.
- **One Offset Focus identity.** AppIcon, Light and Dark appearances, Dock, Finder, and the menu-bar template reuse the same graphite, emerald, mint, and slate geometry.

## Highlights

- **Selected-text translation.** Select text in another app, press `⌥⇧D`, and read the streamed result in an adaptive panel near the selection.
- **Manual input without Accessibility access.** If there is no usable selection, the explicit shortcut opens the manual translation window. Manual input does not read the clipboard.
- **Local and self-chosen providers.** Use Ollama's native API or an OpenAI-compatible endpoint. Requests stay with the selected provider; the app does not silently fall back to another service.
- **Opt-in automatic capture.** Mouse and keyboard selection capture are disabled by default and can be enabled only for applications you add to the allowlist.
- **Useful presets.** Built-in presets cover accurate translation, natural translation, word explanation, sentence explanation, and polishing. You can duplicate them or create encrypted custom presets.
- **Private history controls.** History is disabled by default. When enabled, completed source and result text is encrypted at rest, searchable locally, and kept within configurable age and count limits.
- **English and Simplified Chinese UI.** The interface language can be changed in Settings without changing the system language.

## How a request moves through the app

```text
Selected text or manual input
        ↓
Trigger, source-app and destination checks
        ↓
The selected Ollama or OpenAI-compatible provider
        ↓
Streaming result panel → copy, retry, change preset or pin
```

Automatic capture has a narrower path than the explicit shortcut: it requires global opt-in, an allowed source app, an enabled mouse or keyboard trigger, and—when the provider is off-device—authorization for that app and provider combination.

## Install the prerelease

The [v0.2.0 prerelease](https://github.com/ZacharyJiao/GlideTranslate/releases/tag/v0.2.0) provides an Apple-silicon build for macOS 14 or later.

1. Download both `GlideTranslate-0.2.0-macos-arm64.zip` and `GlideTranslate-0.2.0-macos-arm64.zip.sha256` from the release page.
2. Put both files in the same directory and verify the ZIP:

   ```bash
   /usr/bin/shasum -a 256 -c GlideTranslate-0.2.0-macos-arm64.zip.sha256
   ```

3. Continue only when the command reports `OK`, then extract the ZIP in Finder.
4. Move `GlideTranslate.app` to Applications if you want to keep it there.
5. For the first launch, Control-click the app, choose **Open**, review the macOS warning, and choose **Open** again.

Do not disable Gatekeeper or remove quarantine attributes. If Finder does not offer the Open action, use the [source-build path](#build-from-source). The release is not claimed to support Intel Macs or Universal 2.

For the full trust model and optional bundle checks, see [Distribution](docs/distribution.md).

## First run

The onboarding window walks through four decisions:

1. **Privacy model.** Review when selected text may be read and where it may be sent.
2. **Local Ollama.** Detect an existing Ollama service and choose one of its installed models, or enter an installed model name manually.
3. **Global shortcut.** The default is `⌥⇧D`. If it is already in use, the app offers `⌥⇧F`, `⌥⇧G`, or `⌥⇧T`.
4. **Accessibility.** Grant access only if you want selected-text capture. You can skip it and use manual input.

Glide Translate does not install Ollama or download a model for you. A basic local setup is:

```bash
brew install ollama
ollama serve
ollama pull <model>
```

Keep `ollama serve` running, then return to onboarding or **Settings → Models**, detect the service, and select the installed model.

## Use Glide Translate

### Translate selected text

1. Select text in a supported application.
2. Press `⌥⇧D`, or choose **Translate Selected Text** from the menu-bar menu.
3. The result panel streams the response and shows the language direction and destination class.
4. Use the panel to copy, retry, change the preset, pin the result, or close it.

Selection capture depends on the source application's Accessibility tree. If the explicit shortcut cannot obtain a valid selection, Glide Translate opens manual input or shows a safe next action instead of sending unrelated content.

### Translate manual input

Press the shortcut with no usable selection to open **Manual Translation**. Enter text, choose source and target languages, a preset, and a provider, then press `⌘Return` or click **Translate**. This path does not require Accessibility permission.

### Turn on automatic capture

Automatic capture is off by default. To enable it:

1. Grant Accessibility access in **Settings → Selection**.
2. Add each source application under **Applications**.
3. Enable mouse selection and/or keyboard selection.
4. Turn on **Automatic capture** in **Settings → General**.
5. For a Local Network or Cloud provider, open **Settings → Models**, load the automatic-application list for that provider, and authorize the required applications.

You can pause or resume automatic capture from the menu-bar menu without changing the rest of the configuration.

## Configuration

### General

| Setting | What it controls | Default |
| --- | --- | --- |
| UI language | English or Simplified Chinese | English |
| Target language | Automatic, English, or Simplified Chinese | Automatic |
| Shortcut | Global selected-text action | `⌥⇧D` |
| Launch at login | Start Glide Translate after login | Off |
| Default preset | Preset used by shortcut and automatic capture | Accurate Translation |
| Default provider | Provider used unless manual input selects another | None until onboarding/configuration |
| Automatic capture | Global automatic-capture switch | Off |

### Selection

| Setting | Range or behavior | Default |
| --- | --- | --- |
| Applications | Per-app allowlist for automatic capture | Empty |
| Mouse selection | Observe mouse selection events in allowed apps | Off |
| Keyboard selection | Observe keyboard selection events in allowed apps | Off |
| Debounce | `100–2,000 ms`, in `50 ms` steps | `350 ms` |
| Character limit | `1–20,000` characters | `2,000` |
| Shortcut clipboard fallback | Explicit-shortcut fallback only; may replace clipboard contents | Off |

The clipboard fallback is never used by automatic capture. When enabled, it may synthesize `Command-C` and read the resulting plain text. The app does not claim to restore the previous clipboard contents.

### Models

Each provider stores a protocol, endpoint, model name, and optional credential. Credentials are kept in macOS Keychain.

- **Ollama native:** the built-in default points to Ollama on this Mac, using port `11434`.
- **OpenAI-compatible:** configure the endpoint and model required by your service.
- **Model discovery and connection test:** available from the selected provider's settings.
- **Timeouts:** connection `1–60 s` (default `5 s`), first token `5–600 s` (default `120 s`), and stream idle `5–120 s` (default `30 s`).
- **Destination confirmation:** required for Local Network and Cloud providers. A changed or unresolved destination must be confirmed again before use.
- **Automatic applications:** off-device automatic capture requires a second, provider-specific application authorization.

### Prompts

The built-in presets are read-only, but they can be duplicated and edited as custom presets. A custom template:

- must contain `{text}` exactly once;
- may contain `{source_language}` and `{target_language}`;
- rejects unknown placeholders; and
- uses `{{` and `}}` when a literal brace is needed.

Custom preset names are limited to 80 characters. Explanations and templates are each limited to 8,000 characters. Custom presets are encrypted at rest.

### Privacy and history

History is off by default. Enabling it affects future completed translations; disabling it does not delete existing records.

| Setting | Range or behavior | Default |
| --- | --- | --- |
| Retention | `1–365` days | `30 days` |
| Maximum records | `1–10,000` | `1,000` |
| Excluded applications | Skip history for selected allowed apps | None |
| Search | Decrypt and search source/result text locally | — |
| Diagnostics | Preview a category-only JSON report before saving | — |
| Reset | Remove app data, credentials, keys and runtime configuration in stages | — |

See [Privacy](PRIVACY.md) for the complete data flow, storage rules, logging exclusions, diagnostic fields, and reset limitations.

## Compatibility and current limits

- The app requires macOS 14 or later.
- The downloadable build is verified for Apple silicon only.
- Selected-text capture varies with the source application, selected control, Accessibility support, and Secure Input state. Universal compatibility is not claimed.
- The current Codex desktop surface does not expose automatic Accessibility selection. Its explicit shortcut can work through the user-enabled shortcut-only clipboard fallback.
- The prerelease has no Developer ID signature, notarization ticket, App Store receipt, automatic updater, Intel validation, or Universal 2 claim.

See the tested application matrix and trigger-specific notes in [Compatibility](docs/compatibility.md).

## Build from source

Requirements:

- macOS 14 or later;
- full Xcode at `/Applications/Xcode.app`; and
- the repository's current validation baseline of Xcode 26.6 and Swift 6.3.3 on arm64 macOS.

Run the Swift package tests and build the unsigned Debug app:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project GlideTranslate.xcodeproj -scheme GlideTranslate \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Build and launch a local Debug app:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh run
```

More detail is available in [Building](docs/building.md) and [Verification](docs/verification.md).

## Contributing and project documents

Before opening a pull request, read [Contributing](CONTRIBUTING.md). Use synthetic test content and do not include credentials, selected text, prompts, responses, private endpoints, local paths, diagnostics, or machine details in public artifacts.

- [Privacy](PRIVACY.md)
- [Compatibility](docs/compatibility.md)
- [Distribution](docs/distribution.md)
- [Building](docs/building.md)
- [Verification](docs/verification.md)
- [Security policy](SECURITY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [MIT License](LICENSE)
