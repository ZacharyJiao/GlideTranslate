# Building Glide Translate

The public application name is **Glide Translate** in English and **轻译** in
Simplified Chinese. Internal package, project, target, scheme, executable, and
source-directory coordinates intentionally remain `GlideTranslate`.

## Requirements

- macOS 14 or later for the app target
- Full Xcode at `/Applications/Xcode.app` (validation baseline: Xcode 26.6)
- arm64 is the current local candidate-verification architecture
- Command-line audit tools for the aggregate gate: `rg`, `jq`, Gitleaks 8.30.1,
  and Actionlint 1.7.12

Use `DEVELOPER_DIR` per command. Do not change the global `xcode-select`
configuration.

## Test the Swift packages

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Build the macOS app without signing

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project GlideTranslate.xcodeproj -scheme GlideTranslate \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Build and launch a local Debug app

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh run
```

The helper writes DerivedData under `.build/xcode-derived-data`. It does not
create a signed distribution artifact.

## Run the deterministic aggregate

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/test_all.sh
```

The aggregate creates a fresh candidate from `script/public_paths.txt`; policy,
test, and build inputs come from that snapshot. It requires no real credential,
provider service, endpoint, model, self-hosted runner, or signing identity.

Distribution remains conditional; see [Distribution](distribution.md).
