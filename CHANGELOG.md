# Changelog

All notable changes to Glide Translate are documented here.

## [0.2.2] - 2026-09-01

- Rebuilt provider setup around adding a service, loading its available models,
  and explicitly activating the model to use.
- Fixed manual and selected-text translation so the activated provider and its
  stored credential are used consistently.
- Fixed long streaming results forcing the scrollbar back to the bottom after
  the user scrolls up or drags the scrollbar.
- Improved temporary-panel dismissal when navigation, editing, or deletion
  clears the source selection, while preserving pinned panels.
- Redesigned Settings, Manual Translation, History, and prompt editing for
  compact macOS layouts, clearer provider state, and complete prompt previews.
- Added branded Settings navigation and fixed layout displacement when switching
  between English and Simplified Chinese.

## [0.2.1] - 2026-08-31

- Fixed long-result scrolling while keeping result actions available.
- Dismissed temporary result panels reliably after arrow/delete selection-clear
  events while keeping pinned panels visible.
- Added a drag-to-Applications DMG installer for Apple-silicon macOS builds.
- Added repository discoverability metadata and refreshed release documentation.

## [0.2.0] - 2026-08-30

- Upgraded the translation experience with adaptive result panels, shared app
  window behavior, menu-bar actions, and the unified app icon.
- Published the Apple-silicon prerelease with the documented ad hoc trust
  boundary.
