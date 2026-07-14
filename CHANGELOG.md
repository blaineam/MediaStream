# Changelog

All notable changes to MediaStream are documented here. This project adheres to [Semantic Versioning](https://semver.org/).

## [2.8.0] - 2026-07-14

### Added (host-settable slideshow configuration)
- **A host app could not seed or persist the slideshow's transport state**: `slideshowDuration` was the ONLY host-settable slideshow knob — loop mode, shuffle, and play/pause were private `@State` on `MediaGalleryView` with no configuration field and no way in. A host offering its own slideshow preferences could set the interval but not the loop mode or shuffle, and could not persist what the user picked with the in-gallery buttons. `MediaGalleryConfiguration` gains five **additive, defaulted** members that preserve today's behavior exactly:
  - `slideshowInitialLoopMode: LoopMode = .all` — seeds `loopMode`.
  - `slideshowShuffled: Bool = false` — seeds `isShuffled` **and** its index bookkeeping (`shuffledIndices` / `shuffledPosition`), so a gallery that starts shuffled walks a full permutation pinned to the item already on screen instead of an empty order. The shuffled-order construction is now shared between the seed and `toggleShuffle()` (`MediaGalleryView.shuffledOrder(count:startingAt:)`).
  - `slideshowAutoStart: Bool = false` — starts the slideshow when the gallery appears, once per gallery (returning from the fullscreen cover re-runs `.onAppear` and must not restart it).
  - `onLoopModeChange: ((LoopMode) -> Void)?` and `onShuffleChange: ((Bool) -> Void)?` — fire from `cycleLoopMode()` / `toggleShuffle()` so the host can persist the user's choice, following the existing `onIndexChange` / `onVRProjectionChange` convention.
- **Seeds are INITIAL values, not overrides.** The short-clip rule (`onVRDurationKnown` / `playbackService.duration` forcing `.one` for media under 120s, guarded by `autoLoopApplied`) is untouched and still wins over a seeded loop mode on first play, exactly as it did over the old `.all` default. The seeded loop/shuffle state is pushed onto the shared `MediaPlaybackService` in `.onAppear` via `syncLoopModeToService()` and a new `syncShuffleToService()` — the latter drives the service's *toggle*-only shuffle API to the value held rather than flipping it blind.

### Changed
- **A host-side slideshow interval is no longer permanently shadowed by the in-gallery menu**: the play button's duration context menu sets a view-local `customSlideshowDuration` that overrode `configuration.slideshowDuration` for the rest of the gallery's life, with no way for the host to read or reset it — so once the user touched the menu, a host's own interval picker did nothing. Changing `configuration.slideshowDuration` now clears the override. The menu keeps its intent: the override still wins until the host changes the value again.

### Tests
- Added `SlideshowConfigurationTests`: source compatibility (a config built from ONLY the pre-existing parameters compiles, and the new knobs default to today's behavior), seed round-tripping, and `shuffledOrder(count:startingAt:)` coherence (full permutation, current index first, empty collection safe). All existing tests stay green.

## [2.7.4] - 2026-07-07

### Fixed (animated images black in the viewer)
- **Every remote animated image (GIF/APNG/animated WebP) rendered as a black screen in the full-screen viewer while grid thumbnails worked**: the native animated renderer introduced in v2.7.0 (`WebViewAnimatedImageController`, replacing the WKWebView path) downloaded the image with plain `URLSession.shared`, which rejects the self-signed certificates host apps (Enter Space) use for their local HTTPS media servers. The TLS handshake failed before a single byte arrived, the completion handler bailed silently, `currentFrame` stayed nil, and the viewer showed black. Thumbnails kept working because the host app fetches those bytes itself. The controller now uses a shared **trust-evaluating session** (`MediaStreamConfiguration.trustEvaluatingSession`, new) whose delegate consults the host's `serverTrustEvaluator` — the same pattern the video streaming paths (`RCStreamingResourceLoader`, `WebViewVideoPlayer`) already used. Hosts without an evaluator get default certificate handling, so nothing changes for normal HTTPS.
- **Silent failures in the animated download/decode path now log**: download errors, HTTP ≥400 responses, and `CGImageSourceCreateWithData` failures each print a `[MediaStream]` diagnostic instead of leaving a black view with no trace.
- `MediaGalleryView.loadAnimatedGIF(from:)` switched to the trust-evaluating session for the same reason.

## [2.7.3] - 2026-06-14

### Fixed (sensitive-content gallery — two slideshow navigation defects)
- **No reachable dismiss when the CURRENT item is individually shielded (per-item, not just bulk)**: in `MediaGalleryView`, the control bar carrying the Close/Back button is shown only `if … && !shouldBulkBlock` and it **auto-hides** — and the per-item shield (`currentOverlayVerdict.isShielded && !shouldBulkBlock`) is layered over it. So a single shielded slideshow item covered the auto-hiding bar with **no persistent way out** — the user was STUCK (v2.7.2 only added a persistent Done for the bulk case). The slideshow now shows a **persistent, never-auto-hidden top nav bar layered ABOVE the shield whenever the current item is shielded OR the gallery is bulk blocked**: a **Back-to-grid** arrow (id `sca.slideshow.persistentBack`) when a grid exists (`onBackToGrid != nil`), plus a **Dismiss** `xmark` (id `sca.slideshow.persistentDismiss`) calling `onDismiss`. The dismiss is an `xmark` (NOT labelled "Done"), so the bulk state still exposes exactly ONE element labelled "Done" (`sca.bulk.done`); the persistent dismiss is suppressed in the bulk case to avoid shadowing that Done. Share/Download remain gated off while shielded (v2.7.2's leak gate is unchanged). The adult-gated Reveal All stays on the per-item reveal control / bulk overlay.
- **Back-to-grid regressed to a plain dismiss for direct slideshow entry**: `MediaGalleryFullView` had `onBackToGrid: enteredSlideshowDirectly ? nil : { … }`, which stripped the Back-to-grid arrow for hosts that open straight into the slideshow (Ari / Enter Space). `MediaGalleryFullView` **always** owns a grid (kept alive behind the slideshow), so `onBackToGrid` is now **always** wired — the slideshow always offers Back-to-grid (returning to the thumbnails) and a dismiss to leave entirely, even when shielded. The narrow anti-bounce behavior the flag protected — a fully-shielded gallery's blocked Done must NOT drop onto a still-blocked grid and force a second Done — is preserved differently: `onDismiss` still fully EXITS when `enteredSlideshowDirectly` (the bulk overlay's Reveal-gated Done and the persistent dismiss `xmark` both call it), while the Back-to-grid arrow simply un-covers the grid (which, if bulk-blocked, renders its OWN block + Done from v2.7.1/v2.7.2).

### Tests
- Added `testPerItemShieldedSlideshowHasReachableDismiss` (per-item shielded slideshow — `-scaStart slideshow -scaFlag some -scaAge undetermined` on a shielded item — exposes a reachable persistent Dismiss that leaves the gallery), `testGridEntrySlideshowShowsBackToGridAndReturns` (entering through the grid then into the slideshow shows the Back-to-grid arrow and returns to the grid), and `testBulkBlockSlideshowStillHasReachableDone` (the bulk-block slideshow still has a reachable `sca.bulk.done`) to `MediaStreamSCAUITests`. All existing tests stay green.

## [2.7.2] - 2026-06-13

### Fixed (sensitive-content gallery — CRITICAL slideshow gap)
- **A fully-sensitive SLIDESHOW had no dismiss and leaked**: the always-reachable bulk block existed only in the GRID (`MediaGalleryGridView.bulkBlockOverlay`). The slideshow (`MediaGalleryView`) had no bulk block — only a top control bar with a Share button and an **auto-hiding** Close. When the whole gallery was sensitive, the shield covered the content and the auto-hiding Close sat UNDER it, so a user who opened straight into the slideshow (Ari / Enter Space) was **stuck with no Done** (critical for minors, who can never reveal). The slideshow now presents the SAME persistent bulk block: an always-on-top `Done` (id `sca.bulk.done`, never auto-hidden) plus an adult-gated `Reveal All` (id `sca.bulk.revealAll`) — exactly ONE Done in that state, and it dismisses without revealing.
- **Unrevealed sensitive media could be exfiltrated from the slideshow**: the slideshow's `Share` and per-item `Download` controls are now **hidden whenever the current item is sensitive and not revealed**. Non-sensitive items, or items a verified adult has revealed, share/download normally.
- **Extracted a SHARED bulk-block gate**: `SensitiveOverlayController.shouldBulkBlock(forKeys:totalCount:)` is now the single source of truth both the grid and the slideshow call, so they can never disagree about whether the gallery is fully blocked. The denominator is the TOTAL item count (gated + safe) — passing only the gated-key count would make a minority of flagged items look "100% sensitive" and wrongly bulk-block.
- **Duplicate bulk overlay under the slideshow**: `MediaGalleryFullView` kept the grid alive (via `.opacity`) behind the slideshow; when fully sensitive, the grid drew its OWN bulk block underneath, producing two `sca.bulk.done` buttons (the slideshow's read as not-hittable). The grid now takes a `suppressBulkOverlay` flag and stops drawing its block while the slideshow is on top. A direct slideshow entry's `Done` fully exits the gallery (no bounce to a second identical block).

### Tests
- Added `testSlideshowBulkBlockHasSingleDoneAndNoShareUndetermined` (exactly one Done, dismisses without revealing, Share + Download absent), `testSlideshowBulkBlockRevealAllRestoresShareVerifiedAdult` (Reveal All clears the block and Share returns), and `testSlideshowBulkBlockMinorNoRevealButCanDismiss` to `MediaStreamSCAUITests`. Added unit tests for the shared `shouldBulkBlock(forKeys:totalCount:)` gate (minority does NOT block, majority blocks, inactive guard never blocks, clears after Reveal-All).

## [2.7.1] - 2026-06-13

### Fixed (sensitive-content gallery)
- **Duplicate "Done" when the gallery is fully blocked**: when the bulk block covers the whole gallery, the navigation-toolbar trailing group (the chrome `Done`, the `MediaDownloadButton`, and the multi-select controls) is now **suppressed** — gated on `shouldBulkBlock`, the same condition that presents `bulkBlockOverlay`. The block overlay's own always-reachable `Done` (id `sca.bulk.done`) is the ONLY visible Done, eliminating the two overlapping Done buttons at the top-right. A fully-shielded gallery also no longer offers download/select of sensitive content.
- **Reveal survived backgrounding the app**: both `MediaGalleryGridView` and the slideshow `MediaGalleryView` now observe `@Environment(\.scenePhase)` and call `SensitiveOverlayController.resetReveals()` when the phase becomes `.background`, so a per-item reveal or Reveal-All is dropped when the app is backgrounded while the gallery stays open — returning to the foreground shows sensitive content blurred again. The re-guard is gated strictly on `.background` (not the transient `.inactive` from a Control Center pull-down / app-switcher peek) to avoid over-aggressive re-blurring.

### Tests
- Added `testBulkBlockShowsExactlyOneDone` (asserts exactly one `Done` and no `Download` while fully blocked, and that the single Done dismisses), `testGridRevealReGuardsAfterBackgrounding`, and `testSlideshowRevealReGuardsAfterBackgrounding` (reveal → `XCUIDevice.shared.press(.home)` → `app.activate()` → assert re-shielded) to `MediaStreamSCAUITests`. Hardened the pre-existing slideshow/reset tests against the simulator's intermittent sign-in sheet stealing focus mid-tap.

## [2.7.0] - 2026-06-13

### Added
- **Demo app + automated XCUITest harness** (`Example/`): a `MediaStreamDemo` iOS app (generated by XcodeGen from `Example/project.yml`) hosts the MediaStream gallery against a STUBBED `SensitiveOverlayController`. Age status (`verified-adult` / `undetermined` / `minor`) and flag mode (`all` / `some` / `none`) are settable via launch arguments, and a `some` mode flags only a MINORITY of items so the per-item shield is reachable below the bulk threshold. A comprehensive XCUITest suite runs **headless on the iOS Simulator** and taps the real controls to verify: per-item shield single-tap reveal, bulk block + Reveal-All + reachable Done, age gating, slideshow reveal with no control collision, and reveal-resets-on-dismiss. Wired into CI as the `demo-uitests` job.
- `SensitiveOverlayController.resetReveals()` and `isKeyRevealedInScope(_:)`, plus an optional `canRevealAll:` gate on the initializer.

### Fixed (sensitive-content gallery)
- **Reveal-All was global + permanent**: reveal / reveal-all state is now scoped to the gallery view instance (tracked inside `SensitiveOverlayController`) and RESET when the gallery is dismissed (`resetReveals()` on `onDisappear`), so reopening shows content blurred again instead of staying revealed until force-quit.
- **"Show Anyway" appeared on already-revealed content**: the per-item reveal control is suppressed the moment a key is revealed (and whenever the item is no longer shielded).
- **Reveal button collided with slideshow transport controls**: the full-screen viewer's reveal/verify control is now pinned to the vertical center, never overlapping the bottom transport row; both stay independently hittable.
- **Gallery couldn't be dismissed while the bulk block / Reveal-All was shown**: the grid bulk block now layers an always-on-top, never-captured Done control above the block's touch-absorber, so the user (including a minor who can never reveal) can always leave.

### Changed
- `SensitiveOverlayController`'s `overlayVerdict` / `diskPersistable` / `canRevealKey` / `canVerifyKey` / `revealKey` / `revealAllAction` are now methods that layer the controller's view-scoped reveal state over the host's base closures (call sites unchanged).

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
