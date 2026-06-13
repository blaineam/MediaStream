# Changelog

All notable changes to MediaStream are documented here. This project adheres to [Semantic Versioning](https://semver.org/).

## [2.6.0] - 2026-06-13

### Added
- **Blur-OVERLAY sensitive gallery (not a baked bitmap)**: `MediaGalleryConfiguration.sensitiveOverlay` lets a host inject a `SensitiveOverlayController`; the grid cell and slideshow then render the REAL image and lay a SwiftUI `.blur` overlay over flagged items. A verified adult's reveal removes the overlay and the sharp image (already on screen) shows instantly — no cache rebuild.
- `SensitiveOverlayVerdict`, `SensitiveOverlayController`, `SensitiveOverlayItem`, and the `.sensitiveBlurOverlay(_:)` modifier.
- **No-disk-persistence of sensitive thumbnails**: the gallery forces `diskCacheKey = nil` for any item the controller marks non-persistable (sensitive / unanalyzed / failed), so a flagged thumbnail never reaches the disk thumbnail cache regardless of the host's `MediaItem.diskCacheKey`.
- **Host-configurable, generic block copy**: `SensitiveBlockCopy` (defaults are generic — "Sensitive Content" / "This content contains sensitive media…", no "conversation" wording). `sensitiveSurfaceBlock(...)` takes an optional `copy:`; conversation hosts may override.

### Changed
- The full-screen `sensitiveSurfaceBlock` no longer hard-codes "conversation" in its body text — generic by default.

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
