# Changelog

All notable changes to MediaStream are documented here. This project adheres to [Semantic Versioning](https://semver.org/).

## [2.5.0] - 2026-06-13

### Added
- **SensitiveContent component**: unified `SensitiveContentPolicy` + `sensitiveSurfaceBlock(...)` surface shared by Enter Space and Ari, including `sensitiveSurfaceBlock(topInteractivePassthrough:)` for hosts with custom navigation bars.
- Verify-age success now reveals the protected session, with policy-wiring tests covering the flow.
- Self-signed loopback HTTPS streaming via `RCStreamingResourceLoader` and a cross-platform `serverTrustEvaluator`.

### Fixed
- Out-of-bounds crash when `MediaGalleryView` receives an empty items array.
- macOS gallery arrow/space keyboard navigation.
- Video buffering jitter and swipe navigation being blocked by controls.

### Changed
- macOS thumbnail/zoom downsampling switched from `NSImage.lockFocus` to `CGContext`.
- CI compiles cleanly on the Xcode 16 runner with Swift 6 `Sendable` warnings cleared.

[2.5.0]: https://github.com/blaineam/MediaStream/releases/tag/v2.5.0
