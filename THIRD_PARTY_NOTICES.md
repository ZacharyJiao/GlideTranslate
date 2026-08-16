# Third-Party Notices

The Swift Package Manager dependency graph contains no external package, and
the Xcode project contains no remote Swift package or binary target. The source
tree contains no bundled third-party font, image, or other third-party asset.

Glide Translate itself is provided under the [MIT License](LICENSE).

The project uses platform components supplied by macOS and Xcode rather than
redistributing them. Apple platform modules used by the source include AppKit,
ApplicationServices, Carbon.HIToolbox, Combine, CoreGraphics, CryptoKit,
Darwin, Dispatch, Foundation, NaturalLanguage, Network, Observation, OSLog,
QuartzCore, Security, ServiceManagement, and SwiftUI. Those components remain
governed by the terms accompanying Apple software.

The PrivacyStorage package also links the system `libsqlite3` through the local
`CSQLite` module map. No SQLite source or binary is vendored in this project;
the system library remains governed by its platform distribution terms.
