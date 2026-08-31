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

## Build the ad hoc-signed DMG

The release helper produces one Apple-silicon DMG with an ad hoc-signed app.
That signature detects bundle changes but does not establish Apple trust and
cannot replace Developer ID signing or notarization.

```bash
release_root="$(mktemp -d)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_release_archive.sh "$release_root/archive"
./script/package_dmg_release.sh \
  "$release_root/archive/GlideTranslate-arm64.xcarchive" \
  "$release_root/package"
```

The package directory must not already exist. A successful run creates exactly
one file:

- `GlideTranslate-0.2.1-macos-arm64.dmg`

The packager verifies the version, build number, arm64 architecture, hardened-
runtime flag, empty approved entitlements, ad hoc identity, absence of a
Developer ID authority/team, expected Gatekeeper rejection, payload policy,
DMG creation, a read-only/nobrowse mount, the exact drag-to-Applications root
layout, app-tree integrity across the mount round trip, signature integrity,
and final payload inspection. The DMG itself is not claimed to be signed.

## Run the deterministic aggregate

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/test_all.sh
```

The aggregate creates a fresh candidate from `script/public_paths.txt`; policy,
test, and build inputs come from that snapshot. It requires no real credential,
provider service, endpoint, model, self-hosted runner, or signing identity.

Download and first-launch limitations are documented in
[Distribution](distribution.md).
