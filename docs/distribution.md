# Distribution

When `v0.2.2` is published on GitHub Releases, its downloadable package is one
Apple-silicon DMG for macOS 14 or later. The app inside the DMG has an ad hoc
signature that provides bundle-integrity verification only. The DMG itself is
not claimed to be signed. The application has no Apple-trusted
Developer ID signature, notarization ticket, App Store receipt, automatic
update feed, Intel validation, or Universal 2 claim. Gatekeeper is therefore
expected to reject an ordinary double-click on first launch.

## Download

If that release is present, download
`GlideTranslate-0.2.2-macos-arm64.dmg` from
[GitHub Releases](https://github.com/ZacharyJiao/GlideTranslate/releases).

## Install and open

1. Open the DMG in Finder.
2. Drag `GlideTranslate.app` to **Applications**.
3. Eject the DMG.
4. Try to open the installed app once. Because this prerelease is unidentified
   and unnotarized, macOS may block it.
5. If macOS blocks it, open **System Settings → Privacy & Security**, find the
   Glide Translate message in the Security section, click **Open Anyway**, and
   confirm **Open**.
6. If Finder offers Control-click → **Open**, that is an alternate first-launch
   path; otherwise use **Open Anyway** above.
7. If selection translation is needed, follow the app's link to System Settings
   and grant Accessibility permission to this exact app copy. Manual input does
   not require Accessibility permission.

Do not disable Gatekeeper, use `xattr` to remove quarantine, or weaken system
security. If Finder does not offer the alternate Control-click path, use the
**Open Anyway** path in System Settings instead of weakening system security.

## Optional bundle checks

These optional checks confirm architecture and ad hoc integrity; they do not
create Apple trust:

```bash
/usr/bin/lipo -archs \
  /Applications/GlideTranslate.app/Contents/MacOS/GlideTranslate
/usr/bin/codesign --verify --deep --strict \
  /Applications/GlideTranslate.app
```

The architecture output must be `arm64`, and `codesign` must exit successfully.
An expected Gatekeeper rejection is consistent with the deliberately absent
Developer ID and notarization; it does not indicate that the app-tree signature
check failed.
