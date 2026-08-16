# Distribution

When `v0.1.0` is published on GitHub Releases, its downloadable MVP is an
Apple-silicon application for macOS 14 or later. Its ad hoc signature provides
bundle-integrity verification only. The application has no Apple-trusted
Developer ID signature, notarization ticket, App Store receipt, automatic
update feed, Intel validation, or Universal 2 claim. Gatekeeper is therefore
expected to reject an ordinary double-click on first launch.

## Download and verify

If that release is present, download both files for the same version from
[GitHub Releases](https://github.com/ZacharyJiao/GlideTranslate/releases):

- `GlideTranslate-0.1.0-macos-arm64.zip`
- `GlideTranslate-0.1.0-macos-arm64.zip.sha256`

Place them in the same directory, then verify the downloaded bytes:

```bash
cd /path/to/download-directory
/usr/bin/shasum -a 256 -c GlideTranslate-0.1.0-macos-arm64.zip.sha256
```

The command must report `OK`. Do not open the application when the checksum
fails.

## Install and open

1. Extract the ZIP in Finder.
2. Move `GlideTranslate.app` to Applications if desired.
3. For the first launch, hold Control while clicking the app, choose **Open**,
   review the macOS warning, and choose **Open** again.
4. If selection translation is needed, follow the app's link to System Settings
   and grant Accessibility permission to this exact app copy. Manual input does
   not require Accessibility permission.

Do not disable Gatekeeper, use `xattr` to remove quarantine, or weaken system
security. If macOS does not offer the Finder Open action, use the source-build
path in [Building](building.md) instead.

## Verify the extracted bundle

These optional checks confirm architecture and ad hoc integrity; they do not
create Apple trust:

```bash
/usr/bin/lipo -archs \
  /Applications/GlideTranslate.app/Contents/MacOS/GlideTranslate
/usr/bin/codesign --verify --deep --strict \
  /Applications/GlideTranslate.app
```

The architecture output must be `arm64`, and `codesign` must exit successfully.
An expected Gatekeeper rejection is not evidence of corruption when the ZIP
checksum and ad hoc signature both pass; it reflects the deliberately absent
Developer ID and notarization.
