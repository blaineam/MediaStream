# Changelog

All notable changes to MediaStream are documented here. This project adheres to [Semantic Versioning](https://semver.org/).

## [2.10.0] - 2026-07-15

### Fixed (the grid shared the ORIGINAL of a still-shielded item)

- **Share was a hole straight through the sensitive-content overlay in the grid**: `MediaGalleryView` (the slideshow) has hard-blocked export for an unrevealed sensitive item since v2.7.2 — `currentItemBlocksExport` (`currentOverlayVerdict.isShielded`) gates its Share and per-item Download, because handing over the real original is strictly worse than un-blurring on screen. **`MediaGalleryGridView` had no equivalent and no `blocksExport` concept at all.** Both of its share paths ignored sensitivity entirely: the per-item **context-menu "Share"** (long-press a blurred thumbnail → `shareItem(_:)` → `getShareableItem()`) and the **multi-select Share** (`executeBuiltInShareAction()` → `shareSelected()`) each resolved and handed out the untouched original bytes of an item the viewer was not allowed to see. The grid consulted `sensitiveOverlay` only to *draw* the blur and to compute `shouldBulkBlock`.
- **The bulk block was not covering this.** `shouldBulkBlock` is a whole-grid, threshold-gated decision (25% of items or 3 absolute, whichever hits first). A **minority** of shielded items in a larger gallery — 2 flagged of 12 — does not bulk-block by design, which left each of those items individually long-pressable and shareable. The leak was widest exactly where the bulk overlay intentionally stays out of the way.
- **Every export path now asks per item**, through the same live verdict the blur is drawn from, so a reveal makes an item shareable instantly and re-shielding blocks it again with no rebuild:
  - the context-menu **Share is hidden** for a shielded item;
  - **`shareSelected()` drops shielded items before any bytes are resolved**, so a mixed selection shares only what the viewer is allowed to have rather than failing the whole batch;
  - the multi-select **Share button is hidden when every selected item is shielded** (nothing could come out of it);
  - **`shareItem(_:)` and `shareSelected()` guard themselves** regardless of what offered the affordance — the affordance and the code path are gated independently, so a future caller cannot reintroduce the leak by invoking them directly.

### Added

- `SensitiveExportPolicy` — the pure decision table behind every export affordance: `allowsExport(_:)` (shielded never exports, including the fail-closed error shield), `exportable(_:verdict:)` (filter a selection to what may leave the app), and `shouldOfferShare(verdicts:)` (offer Share unless every item is shielded, or the set is empty). Free of SwiftUI and of the controller, so the matrix is directly unit-testable — the same shape as `SensitiveBulkPolicy`.
- `SensitiveOverlayController.blocksExport(_:)` — resolves one stable key to an export decision through `overlayVerdict(_:)`, the seam the grid uses per item. `SensitiveOverlayController.inactive` never blocks, so hosts that do not gate are unaffected.

### Tests

- Extended `SensitiveContentTests` with an export-gate section (8 tests, 45 XCTest / 96 Swift Testing total, all green): shielded and fail-closed-error verdicts never export, `.none` does; a mixed selection filters down to only the unshielded items; a fully-shielded selection offers no Share and yields nothing; an empty selection offers no Share; the controller blocks a shielded key; reveal-in-scope flips export on instantly; an inactive guard never blocks.
- Mutation-tested: forcing `allowsExport` to `true` fails 7 tests, removing the `exportable` filter fails 2, and forcing `blocksExport` to `false` fails 2 — each caught by the test written for it.

## [2.9.0] - 2026-07-15

### Fixed (video player routing was dead code for query-based URLs)
- **Every video was handed to AVFoundation when a host's media URLs are query-based**: `ZoomableMediaView` picked the player with `url.pathExtension.lowercased() == "webm"`. A host that serves media from a **query-based URL** (`https://host/media?id=abc`, `/proxy?key=…`) has an **empty `pathExtension`**, so that test never matched and the WebView player was unreachable — WebM/VP8/VP9, which AVFoundation cannot decode, went to AVFoundation anyway. Such a video survived only if `asset.load(.isPlayable)` happened to return false; when `isPlayable` returned **true** for a container AVFoundation could not actually decode, the item never reached `.readyToPlay`, never errored, and playback **hung forever with no fallback** — the video simply never loaded. Routing now goes through a new `VideoPlayerRouter`, which resolves the container from something that actually carries it: **`diskCacheKey` first** (hosts are expected to put the real filename there, and `MediaPlaybackService.isWebMFile` already keys its `.webm` behavior off it), then each URL's **path extension** (unchanged behavior for hosts that do serve extensioned paths), then, as a last resort, a filename sitting in a URL's **query values** (`?path=Album/clip.webm`).
- **A "playable" video that never became ready hung forever**: `isPlayable` only means the container parsed. `ZoomableMediaView` now watches an AVFoundation item that claimed to be playable and **falls back to the WebView player if it does not reach `.readyToPlay` within 15s**, instead of spinning indefinitely. The window is deliberately generous — a remote stream on a slow connection must not be demoted by mistake — and the fallback re-checks that the view still shows the same AVFoundation-backed item before switching. `.failed` keeps its existing `isPlayable` / `catch` handling.
- **Routing stays narrow on purpose**: MKV/AVI are *also* unsupported by AVFoundation, but WebKit cannot play them either, so they are **not** routed to the WebView player — that would trade one broken player for another. They stay on the AVFoundation path, where the `isPlayable` check and the new readiness timeout now handle them without hanging.

### Fixed (a stuck global disabled swipe navigation for the process lifetime)
- **One interrupted scrub-drag killed swipe navigation until the app was relaunched**: `MediaControlsInteractionState.shared.isInteracting` gates the gallery's swipe handling, is raised by a scrub Slider's `onEditingChanged(true)`, and was cleared **only** by the same Slider's `onEditingChanged(false)`. If the drag was lost mid-flight (view disappeared, gallery dismissed, gesture cancelled) the release never arrived and the flag stayed raised **for the rest of the process**, silently disabling swipe navigation in every later gallery. Added `MediaControlsInteractionState.endInteraction()` and wired it into every teardown path: `MediaGalleryView.onDisappear`, plus the `onDisappear` of all three views that own a scrub Slider (`CustomVideoPlayerView`, `AudioPlayerControlsView`, `CustomWebViewVideoPlayerView`). A stuck flag can no longer outlive the interaction that set it.
- **The singleton is still a singleton.** A process-wide mutable flag driving gesture routing is the root problem, and making it per-gallery instance state is the real fix — but that means threading a binding through `ZoomableMediaView`, `WebViewVideoPlayer` and the audio controls, which is too invasive for a point release. The type now documents that, and the teardown calls make the current design self-healing.

### Fixed (fast flicks did not change slides)
- **A quick flick legitimately failed to register**: the navigation gesture was `DragGesture(minimumDistance: 100)` plus a ~100pt *end*-translation requirement. A flick lifts the finger after ~30-60pt and covers the rest on momentum, so it often never even **started** the gesture, let alone committed it. The thresholds are now `swipeMinimumDistance: 20` (engage), and a swipe commits on **either** `swipeCommitDistance: 50` of real travel (a deliberate slow drag, where there is no momentum to predict) **or** `swipeFlickDistance: 120` of `predictedEndTranslation` (a flick). Direction comes from real travel, falling back to the predicted end when a flick measures zero.
- **Balanced against false positives by keeping the guard the distances no longer provide.** The horizontal-dominance test is what keeps a vertical scroll or a diagonal zoom-pan from flipping slides, so it **stays strict** (`swipeHorizontalDominance: 1.5`) rather than relaxing alongside the distances: a drag 60pt across and 50pt down is still rejected. The existing `isZoomed` / VR-sphere / interaction guards are unchanged (the zoom-pan gesture only applies while zoomed, which the navigation gesture already excludes).

### Added (autoplay a video without running the slideshow)
- **"Play this video" and "run the slideshow" were the same flag**: video playback was gated on `shouldAutoplay: isSlideshowPlaying && isCurrentSlide`, and `isSlideshowPlaying` is set **only** by `startSlideshow()`. A host therefore could not express "play the video when its slide opens, but don't auto-advance the album" — a very common want — without also starting the slideshow. `MediaGalleryConfiguration` gains one **additive, defaulted** member:
  - `autoPlayVideoOnOpen: Bool = false` — plays the current slide's video/audio **without** starting the slideshow.
- **The two are orthogonal.** `slideshowAutoStart` keeps its exact meaning. Autoplay and auto-advance are now separate conditions: `ZoomableMediaView` starts media on `(isSlideshowPlaying || autoPlayVideoOnOpen) && isCurrentSlide`, while **advancing still keys off `isSlideshowPlaying` alone** in `handleVideoComplete()` — so an autoplayed video plays to the end and stays put. The "pose the first frame" paths that assumed `!isSlideshowPlaying` meant "nothing will play this" now consult the same combined condition, so an autoplayed slide plays instead of freezing on its poster frame. `onManualPlayTriggered` (which starts the slideshow) fires only from `togglePlayPause()`, i.e. a real user tap, so autoplay cannot start the slideshow by a side door.

### Tests
- Added `VideoPlayerRoutingTests`: a query-based URL routes on `diskCacheKey` (and pins that its `pathExtension` really is empty — the reason the old test was dead code), `diskCacheKey` beating a misleading URL extension, the extensioned-URL fallback, the query-value last resort, case-insensitivity, MKV/AVI staying on AVFoundation, and an opaque key + extensionless URL leaving AVFoundation to try.
- Added `SwipeNavigationTests`: a fast flick registers, a slow drag registers, and vertical scrolls / ambiguous diagonals / small nudges / a still finger are all rejected — plus a test pinning the threshold balance so a later tweak has to be deliberate.
- Extended `SlideshowConfigurationTests.sourceCompatibility` to assert `autoPlayVideoOnOpen` defaults to `false`, and added `autoPlayVideoOnOpenIsOrthogonal` (neither flag implies the other; both together stay legal). All existing tests stay green (96 total).

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
