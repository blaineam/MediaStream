import Testing
import Foundation
@testable import MediaStream

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Thread-safe test helper

final class CallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _wasCalled = false

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _wasCalled
    }

    func markCalled() {
        lock.lock()
        defer { lock.unlock() }
        _wasCalled = true
    }
}

// MARK: - MediaType Tests

@Suite("MediaType Tests")
struct MediaTypeTests {
    @Test("MediaType enum has correct cases")
    func mediaTypeCases() {
        let image = MediaType.image
        let video = MediaType.video
        let animated = MediaType.animatedImage

        #expect(image == .image)
        #expect(video == .video)
        #expect(animated == .animatedImage)
    }
}

// MARK: - ImageMediaItem Tests

@Suite("ImageMediaItem Tests")
struct ImageMediaItemTests {
    @Test("ImageMediaItem initializes with default UUID")
    func initWithDefaultUUID() {
        let item = ImageMediaItem { nil }
        #expect(item.id != UUID())
        #expect(item.type == .image)
    }

    @Test("ImageMediaItem initializes with custom UUID")
    func initWithCustomUUID() {
        let customID = UUID()
        let item = ImageMediaItem(id: customID) { nil }
        #expect(item.id == customID)
    }

    @Test("ImageMediaItem type is always image")
    func typeIsImage() {
        let item = ImageMediaItem { nil }
        #expect(item.type == .image)
    }

    @Test("ImageMediaItem loadVideoURL returns nil")
    func loadVideoURLReturnsNil() async {
        let item = ImageMediaItem { nil }
        let url = await item.loadVideoURL()
        #expect(url == nil)
    }

    @Test("ImageMediaItem getAnimatedImageDuration returns nil")
    func getAnimatedDurationReturnsNil() async {
        let item = ImageMediaItem { nil }
        let duration = await item.getAnimatedImageDuration()
        #expect(duration == nil)
    }

    @Test("ImageMediaItem getVideoDuration returns nil")
    func getVideoDurationReturnsNil() async {
        let item = ImageMediaItem { nil }
        let duration = await item.getVideoDuration()
        #expect(duration == nil)
    }

    @Test("ImageMediaItem getCaption returns nil by default")
    func getCaptionReturnsNil() async {
        let item = ImageMediaItem { nil }
        let caption = await item.getCaption()
        #expect(caption == nil)
    }

    @Test("ImageMediaItem hasAudioTrack returns false")
    func hasAudioTrackReturnsFalse() async {
        let item = ImageMediaItem { nil }
        let hasAudio = await item.hasAudioTrack()
        #expect(hasAudio == false)
    }

    @Test("ImageMediaItem calls image loader")
    func callsImageLoader() async {
        let tracker = CallTracker()
        let item = ImageMediaItem {
            tracker.markCalled()
            return nil
        }
        _ = await item.loadImage()
        #expect(tracker.wasCalled == true)
    }
}

// MARK: - AnimatedImageMediaItem Tests

@Suite("AnimatedImageMediaItem Tests")
struct AnimatedImageMediaItemTests {
    @Test("AnimatedImageMediaItem initializes correctly")
    func initializesCorrectly() {
        let customID = UUID()
        let item = AnimatedImageMediaItem(
            id: customID,
            imageLoader: { nil },
            durationLoader: { 2.5 }
        )
        #expect(item.id == customID)
        #expect(item.type == .animatedImage)
    }

    @Test("AnimatedImageMediaItem type is animatedImage")
    func typeIsAnimatedImage() {
        let item = AnimatedImageMediaItem(
            imageLoader: { nil },
            durationLoader: { nil }
        )
        #expect(item.type == .animatedImage)
    }

    @Test("AnimatedImageMediaItem calls duration loader")
    func callsDurationLoader() async {
        let expectedDuration: TimeInterval = 3.5
        let item = AnimatedImageMediaItem(
            imageLoader: { nil },
            durationLoader: { expectedDuration }
        )
        let duration = await item.getAnimatedImageDuration()
        #expect(duration == expectedDuration)
    }

    @Test("AnimatedImageMediaItem loadVideoURL returns nil")
    func loadVideoURLReturnsNil() async {
        let item = AnimatedImageMediaItem(
            imageLoader: { nil },
            durationLoader: { nil }
        )
        let url = await item.loadVideoURL()
        #expect(url == nil)
    }

    @Test("AnimatedImageMediaItem getVideoDuration returns nil")
    func getVideoDurationReturnsNil() async {
        let item = AnimatedImageMediaItem(
            imageLoader: { nil },
            durationLoader: { nil }
        )
        let duration = await item.getVideoDuration()
        #expect(duration == nil)
    }

    @Test("AnimatedImageMediaItem hasAudioTrack returns false")
    func hasAudioTrackReturnsFalse() async {
        let item = AnimatedImageMediaItem(
            imageLoader: { nil },
            durationLoader: { nil }
        )
        let hasAudio = await item.hasAudioTrack()
        #expect(hasAudio == false)
    }
}

// MARK: - VideoMediaItem Tests

@Suite("VideoMediaItem Tests")
struct VideoMediaItemTests {
    @Test("VideoMediaItem initializes correctly")
    func initializesCorrectly() {
        let customID = UUID()
        let item = VideoMediaItem(id: customID) { nil }
        #expect(item.id == customID)
        #expect(item.type == .video)
    }

    @Test("VideoMediaItem type is video")
    func typeIsVideo() {
        let item = VideoMediaItem { nil }
        #expect(item.type == .video)
    }

    @Test("VideoMediaItem calls video URL loader")
    func callsVideoURLLoader() async {
        let expectedURL = URL(string: "file:///test/video.mp4")!
        let item = VideoMediaItem { expectedURL }
        let url = await item.loadVideoURL()
        #expect(url == expectedURL)
    }

    @Test("VideoMediaItem calls thumbnail loader")
    func callsThumbnailLoader() async {
        let tracker = CallTracker()
        let item = VideoMediaItem(
            videoURLLoader: { nil },
            thumbnailLoader: {
                tracker.markCalled()
                return nil
            }
        )
        _ = await item.loadImage()
        #expect(tracker.wasCalled == true)
    }

    @Test("VideoMediaItem loadImage returns nil without thumbnail loader")
    func loadImageReturnsNilWithoutThumbnailLoader() async {
        let item = VideoMediaItem { nil }
        let image = await item.loadImage()
        #expect(image == nil)
    }

    @Test("VideoMediaItem getAnimatedImageDuration returns nil")
    func getAnimatedDurationReturnsNil() async {
        let item = VideoMediaItem { nil }
        let duration = await item.getAnimatedImageDuration()
        #expect(duration == nil)
    }

    @Test("VideoMediaItem custom duration loader is called")
    func customDurationLoaderIsCalled() async {
        let expectedDuration: TimeInterval = 120.5
        let item = VideoMediaItem(
            videoURLLoader: { nil },
            durationLoader: { expectedDuration }
        )
        let duration = await item.getVideoDuration()
        #expect(duration == expectedDuration)
    }

    @Test("VideoMediaItem getShareableItem returns video URL")
    func getShareableItemReturnsVideoURL() async {
        let expectedURL = URL(string: "file:///test/video.mp4")!
        let item = VideoMediaItem { expectedURL }
        let shareableItem = await item.getShareableItem()
        #expect(shareableItem as? URL == expectedURL)
    }
}

// MARK: - AnimatedImageHelper Tests

@Suite("AnimatedImageHelper Tests")
struct AnimatedImageHelperTests {
    @Test("calculateSlideshowDuration with zero animation returns minimum")
    func calculateWithZeroAnimation() {
        let result = AnimatedImageHelper.calculateSlideshowDuration(
            animationDuration: 0,
            minimumDuration: 5.0
        )
        #expect(result == 5.0)
    }

    @Test("calculateSlideshowDuration with negative animation returns minimum")
    func calculateWithNegativeAnimation() {
        let result = AnimatedImageHelper.calculateSlideshowDuration(
            animationDuration: -1.0,
            minimumDuration: 5.0
        )
        #expect(result == 5.0)
    }

    @Test("calculateSlideshowDuration single loop when animation exceeds minimum")
    func calculateSingleLoop() {
        let result = AnimatedImageHelper.calculateSlideshowDuration(
            animationDuration: 10.0,
            minimumDuration: 5.0
        )
        #expect(result == 10.0)
    }

    @Test("calculateSlideshowDuration multiple loops when animation is shorter")
    func calculateMultipleLoops() {
        let result = AnimatedImageHelper.calculateSlideshowDuration(
            animationDuration: 2.0,
            minimumDuration: 5.0
        )
        // ceil(5.0 / 2.0) = 3, so 2.0 * 3 = 6.0
        #expect(result == 6.0)
    }

    @Test("calculateSlideshowDuration exact multiple")
    func calculateExactMultiple() {
        let result = AnimatedImageHelper.calculateSlideshowDuration(
            animationDuration: 2.5,
            minimumDuration: 5.0
        )
        // ceil(5.0 / 2.5) = 2, so 2.5 * 2 = 5.0
        #expect(result == 5.0)
    }

    @Test("calculateSlideshowDuration with small animation")
    func calculateWithSmallAnimation() {
        let result = AnimatedImageHelper.calculateSlideshowDuration(
            animationDuration: 0.5,
            minimumDuration: 5.0
        )
        // ceil(5.0 / 0.5) = 10, so 0.5 * 10 = 5.0
        #expect(result == 5.0)
    }

    @Test("isAnimatedImage returns false for invalid data")
    func isAnimatedImageInvalidData() {
        let invalidData = Data([0x00, 0x01, 0x02])
        let result = AnimatedImageHelper.isAnimatedImage(invalidData)
        #expect(result == false)
    }

    @Test("isAnimatedImage returns false for empty data")
    func isAnimatedImageEmptyData() {
        let emptyData = Data()
        let result = AnimatedImageHelper.isAnimatedImage(emptyData)
        #expect(result == false)
    }

    @Test("isAnimatedImageFile returns false for non-animated extensions")
    func isAnimatedImageFileNonAnimatedExtension() {
        let jpegURL = URL(fileURLWithPath: "/test/image.jpg")
        let result = AnimatedImageHelper.isAnimatedImageFile(jpegURL)
        #expect(result == false)
    }

    @Test("isAnimatedImageFile returns false for non-existent gif")
    func isAnimatedImageFileNonExistentGif() {
        let gifURL = URL(fileURLWithPath: "/nonexistent/image.gif")
        let result = AnimatedImageHelper.isAnimatedImageFile(gifURL)
        #expect(result == false)
    }
}

// MARK: - MediaFilter Tests

@Suite("MediaFilter Tests")
struct MediaFilterTests {
    @Test("MediaFilter.all matches all types")
    func allMatchesAllTypes() {
        #expect(MediaFilter.all.matches(.image) == true)
        #expect(MediaFilter.all.matches(.video) == true)
        #expect(MediaFilter.all.matches(.animatedImage) == true)
    }

    @Test("MediaFilter.images matches only images")
    func imagesMatchesOnlyImages() {
        #expect(MediaFilter.images.matches(.image) == true)
        #expect(MediaFilter.images.matches(.video) == false)
        #expect(MediaFilter.images.matches(.animatedImage) == false)
    }

    @Test("MediaFilter.videos matches only videos")
    func videosMatchesOnlyVideos() {
        #expect(MediaFilter.videos.matches(.image) == false)
        #expect(MediaFilter.videos.matches(.video) == true)
        #expect(MediaFilter.videos.matches(.animatedImage) == false)
    }

    @Test("MediaFilter.animated matches only animated images")
    func animatedMatchesOnlyAnimated() {
        #expect(MediaFilter.animated.matches(.image) == false)
        #expect(MediaFilter.animated.matches(.video) == false)
        #expect(MediaFilter.animated.matches(.animatedImage) == true)
    }

    @Test("MediaFilter.audio matches only audio")
    func audioMatchesOnlyAudio() {
        #expect(MediaFilter.audio.matches(.image) == false)
        #expect(MediaFilter.audio.matches(.video) == false)
        #expect(MediaFilter.audio.matches(.animatedImage) == false)
        #expect(MediaFilter.audio.matches(.audio) == true)
    }

    @Test("MediaFilter raw values are correct")
    func rawValuesAreCorrect() {
        #expect(MediaFilter.all.rawValue == "All")
        #expect(MediaFilter.images.rawValue == "Images")
        #expect(MediaFilter.videos.rawValue == "Videos")
        #expect(MediaFilter.audio.rawValue == "Audio")
        #expect(MediaFilter.animated.rawValue == "Animated")
    }

    @Test("MediaFilter allCases contains all filters")
    func allCasesContainsAll() {
        #expect(MediaFilter.allCases.count == 5)
        #expect(MediaFilter.allCases.contains(.all))
        #expect(MediaFilter.allCases.contains(.images))
        #expect(MediaFilter.allCases.contains(.videos))
        #expect(MediaFilter.allCases.contains(.audio))
        #expect(MediaFilter.allCases.contains(.animated))
    }
}

// MARK: - MediaGalleryConfiguration Tests

@Suite("MediaGalleryConfiguration Tests")
struct MediaGalleryConfigurationTests {
    @Test("Configuration has correct default values")
    func defaultValues() {
        let config = MediaGalleryConfiguration()
        #expect(config.slideshowDuration == 5.0)
        #expect(config.showControls == true)
        #expect(config.customActions.isEmpty)
    }

    @Test("Configuration accepts custom slideshow duration")
    func customSlideshowDuration() {
        let config = MediaGalleryConfiguration(slideshowDuration: 10.0)
        #expect(config.slideshowDuration == 10.0)
    }

    @Test("Configuration accepts custom showControls")
    func customShowControls() {
        let config = MediaGalleryConfiguration(showControls: false)
        #expect(config.showControls == false)
    }

    @Test("Configuration accepts custom actions")
    func customActions() {
        let action = MediaGalleryAction(icon: "heart") { _ in }
        let config = MediaGalleryConfiguration(customActions: [action])
        #expect(config.customActions.count == 1)
        #expect(config.customActions.first?.icon == "heart")
    }
}

// MARK: - MediaGalleryAction Tests

@Suite("MediaGalleryAction Tests")
struct MediaGalleryActionTests {
    @Test("Action initializes with icon and action")
    func initializesCorrectly() {
        let action = MediaGalleryAction(icon: "star.fill") { _ in }
        #expect(action.icon == "star.fill")
        #expect(action.id != UUID())
    }

    @Test("Action calls closure with correct index")
    func callsClosureWithIndex() {
        var receivedIndex: Int?
        let action = MediaGalleryAction(icon: "heart") { index in
            receivedIndex = index
        }
        action.action(42)
        #expect(receivedIndex == 42)
    }

    @Test("Multiple actions have unique IDs")
    func multipleActionsHaveUniqueIDs() {
        let action1 = MediaGalleryAction(icon: "heart") { _ in }
        let action2 = MediaGalleryAction(icon: "star") { _ in }
        #expect(action1.id != action2.id)
    }
}

// MARK: - MediaGalleryFilterConfig Tests

@Suite("MediaGalleryFilterConfig Tests")
struct MediaGalleryFilterConfigTests {
    @Test("FilterConfig initializes with nil values by default")
    func defaultValues() {
        let config = MediaGalleryFilterConfig()
        #expect(config.customFilter == nil)
        #expect(config.customSort == nil)
    }

    @Test("FilterConfig accepts custom filter closure")
    func customFilterClosure() {
        let config = MediaGalleryFilterConfig(customFilter: { item in
            item.type == .image
        })
        #expect(config.customFilter != nil)
    }

    @Test("FilterConfig accepts custom sort closure")
    func customSortClosure() {
        let config = MediaGalleryFilterConfig(customSort: { _, _ in
            true
        })
        #expect(config.customSort != nil)
    }

    @Test("Custom filter executes correctly")
    func customFilterExecutes() {
        let config = MediaGalleryFilterConfig(customFilter: { item in
            item.type == .video
        })

        let imageItem = ImageMediaItem { nil }
        let videoItem = VideoMediaItem { nil }

        #expect(config.customFilter?(imageItem) == false)
        #expect(config.customFilter?(videoItem) == true)
    }
}

// MARK: - MediaGalleryMultiSelectAction Tests

@Suite("MediaGalleryMultiSelectAction Tests")
struct MediaGalleryMultiSelectActionTests {
    @Test("MultiSelectAction initializes correctly")
    func initializesCorrectly() {
        let action = MediaGalleryMultiSelectAction(
            title: "Delete",
            icon: "trash"
        ) { _ in }

        #expect(action.title == "Delete")
        #expect(action.icon == "trash")
        #expect(action.id != UUID())
    }

    @Test("MultiSelectAction calls closure with items")
    func callsClosureWithItems() {
        var receivedItems: [any MediaItem]?
        let action = MediaGalleryMultiSelectAction(
            title: "Process",
            icon: "gear"
        ) { items in
            receivedItems = items
        }

        let items: [any MediaItem] = [
            ImageMediaItem { nil },
            VideoMediaItem { nil }
        ]

        action.action(items)
        #expect(receivedItems?.count == 2)
    }

    @Test("Multiple MultiSelectActions have unique IDs")
    func multipleActionsHaveUniqueIDs() {
        let action1 = MediaGalleryMultiSelectAction(title: "A", icon: "a") { _ in }
        let action2 = MediaGalleryMultiSelectAction(title: "B", icon: "b") { _ in }
        #expect(action1.id != action2.id)
    }
}

// MARK: - Index Change Notification Tests

/// `onIndexChange` is a CONTRACT: the host is told exactly once, for every
/// index change, whatever caused it. A host drives per-item UI off it (a
/// favorite button reflecting the current slide), so a missed notification
/// shows stale state and a doubled one causes redundant work.
///
/// The contract holds structurally: `currentIndex` is @State, every mutation
/// triggers `.onChange(of: currentIndex)` -> `handleIndexChanged`, and that is
/// the ONE place that notifies. It broke because the call was instead scattered
/// across the movement functions — which covered deliberate navigation but
/// missed the count-clamp and the playback-service sync, both of which also
/// assign `currentIndex`.
///
/// That is a property of where the call SITS, not of any value, so these scan
/// the source. Ugly, but it pins the invariant that actually regressed; a pure
/// value test cannot see a missing call site. If MediaGalleryView is ever made
/// testable without SwiftUI, replace these with a real host-callback spy.
@Suite("Index Change Notification Tests")
struct IndexChangeNotificationTests {
    /// Locate Sources/MediaStream/MediaGalleryView.swift relative to this file.
    private static func galleryViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()  // MediaStreamTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let src = root
            .appendingPathComponent("Sources/MediaStream/MediaGalleryView.swift")
        return try String(contentsOf: src, encoding: .utf8)
    }

    @Test("onIndexChange is invoked from exactly one place")
    func singleNotificationSite() throws {
        let source = try Self.galleryViewSource()
        let calls = source
            .split(separator: "\n")
            .filter { $0.contains("onIndexChange?(") }

        #expect(calls.count == 1, """
            onIndexChange must be called from exactly ONE site \
            (handleIndexChanged), found \(calls.count). Scattering the call \
            across movement functions is what left the count-clamp and \
            playback-service-sync paths silent, and risks double-notifying for \
            a single change.
            """)
    }

    @Test("The notification site is handleIndexChanged, the index choke point")
    func notifiesFromChokePoint() throws {
        let source = try Self.galleryViewSource()
        guard let fnRange = source.range(of: "private func handleIndexChanged(") else {
            Issue.record("handleIndexChanged not found — did it get renamed?")
            return
        }
        // The notify call must live inside handleIndexChanged's body: take the
        // slice from the function to the next func declaration.
        let after = source[fnRange.lowerBound...]
        let nextFn = after.range(of: "\n    private func ", range: after.index(after.startIndex, offsetBy: 1)..<after.endIndex)
        let body = nextFn.map { String(after[..<$0.lowerBound]) } ?? String(after)

        #expect(body.contains("onIndexChange?("), """
            onIndexChange must fire from handleIndexChanged — the single \
            function every currentIndex mutation reaches via \
            .onChange(of: currentIndex). Firing anywhere else cannot be \
            exhaustive.
            """)
    }

    @Test("handleIndexChanged is wired to currentIndex changes")
    func chokePointIsWiredToState() throws {
        let source = try Self.galleryViewSource()
        // Without this wiring the notification never fires at all.
        #expect(source.contains(".onChange(of: currentIndex)"), """
            .onChange(of: currentIndex) is the mechanism that makes \
            handleIndexChanged exhaustive. Removing it silently breaks every \
            host's index tracking.
            """)
    }
}

// MARK: - Caption Visibility Tests

/// The media caption is DECOUPLED from the auto-hiding transport controls: once
/// the user toggles it on it stays until they toggle it off, regardless of the
/// idle controls timer. `MediaGalleryView.shouldShowCaption(...)` is the single
/// pure gate the view renders from — these tests pin its truth table, including
/// the content-safety decision (suppressed while the gallery is bulk blocked).
@Suite("Caption Visibility Tests")
struct CaptionVisibilityTests {
    @Test("Shows when toggled on, a caption is present, and not bulk blocked")
    func showsWhenOnPresentAndUnblocked() {
        #expect(MediaGalleryView.shouldShowCaption(
            showCaption: true, caption: "A description", shouldBulkBlock: false) == true)
    }

    @Test("Hidden when the user has NOT toggled it on")
    func hiddenWhenToggledOff() {
        #expect(MediaGalleryView.shouldShowCaption(
            showCaption: false, caption: "A description", shouldBulkBlock: false) == false)
    }

    @Test("Hidden when the current slide has NO caption")
    func hiddenWhenNoCaption() {
        #expect(MediaGalleryView.shouldShowCaption(
            showCaption: true, caption: nil, shouldBulkBlock: false) == false)
        // Toggled on but caption-less: nothing renders (this is exactly the
        // persist-across-slides case — the choice stays true, the text is gone).
    }

    @Test("Suppressed while the gallery is BULK BLOCKED, even when toggled on")
    func suppressedWhenBulkBlocked() {
        // Content-safety decision: during a whole-gallery bulk block the transport
        // chrome is suppressed and a single block owns the screen, so the caption
        // is suppressed too. An INDIVIDUALLY shielded item is intentionally not a
        // parameter here — the caption is text (not media bytes) and the controls
        // still show for that case, so behavior there is unchanged.
        #expect(MediaGalleryView.shouldShowCaption(
            showCaption: true, caption: "A description", shouldBulkBlock: true) == false)
    }

    @Test("An empty-string caption still counts as present")
    func emptyStringCaptionIsPresent() {
        // The gate keys on presence (non-nil), matching the caption toggle button,
        // which appears whenever `currentCaption != nil` regardless of contents.
        #expect(MediaGalleryView.shouldShowCaption(
            showCaption: true, caption: "", shouldBulkBlock: false) == true)
    }

    /// Persistence across SLIDES is a property of `loadCaption()`: it clears the
    /// caption TEXT on a slide change but must NOT reset the user's `showCaption`
    /// choice, so a captioned slide reached later re-shows automatically. That
    /// behavior lives in a SwiftUI-bound method that can't run headless, so — as
    /// the IndexChangeNotificationTests do for their invariant — this scans the
    /// source for the regression: `loadCaption` must never assign showCaption.
    @Test("Slide change preserves showCaption (loadCaption never resets it)")
    func slideChangePreservesShowCaption() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = root.appendingPathComponent("Sources/MediaStream/MediaGalleryView.swift")
        let source = try String(contentsOf: src, encoding: .utf8)

        guard let fnRange = source.range(of: "private func loadCaption(") else {
            Issue.record("loadCaption not found — did it get renamed?")
            return
        }
        let after = source[fnRange.lowerBound...]
        let nextFn = after.range(
            of: "\n    private func ",
            range: after.index(after.startIndex, offsetBy: 1)..<after.endIndex)
        let body = nextFn.map { String(after[..<$0.lowerBound]) } ?? String(after)

        #expect(!body.contains("showCaption = false"), """
            loadCaption must NOT reset showCaption on a slide change — doing so \
            dismisses the caption every time the user swipes, the annoyance this \
            fix removes. It may clear currentCaption (the TEXT); the user's \
            showCaption CHOICE persists across slides.
            """)
    }
}

// MARK: - Index Bounds Tests

@Suite("Index Bounds Tests")
struct IndexBoundsTests {
    @Test("Initial index is clamped to valid range")
    func initialIndexClamping() {
        let count = 3

        #expect(MediaGalleryView.clampedIndex(-5, count: count) == 0)
        #expect(MediaGalleryView.clampedIndex(100, count: count) == 2)
        #expect(MediaGalleryView.clampedIndex(1, count: count) == 1)
        #expect(MediaGalleryView.clampedIndex(0, count: count) == 0)
        #expect(MediaGalleryView.clampedIndex(2, count: count) == 2)
    }

    @Test("Clamped index is never negative for an empty collection")
    func clampedIndexEmptyCollection() {
        // Regression: min(max(0, index), count - 1) returned -1 for an empty
        // array, which crashed mediaItems[currentIndex] subscripts in body
        // (EXC_BREAKPOINT at MediaGalleryView slideshow controls).
        #expect(MediaGalleryView.clampedIndex(0, count: 0) == 0)
        #expect(MediaGalleryView.clampedIndex(-1, count: 0) == 0)
        #expect(MediaGalleryView.clampedIndex(5, count: 0) == 0)
    }

    @Test("Clamped index handles a shrunken collection")
    func clampedIndexShrunkenCollection() {
        // A caller can pass a shorter array on a later update (item deleted)
        // while @State still holds the old larger index.
        #expect(MediaGalleryView.clampedIndex(5, count: 3) == 2)
        #expect(MediaGalleryView.clampedIndex(3, count: 3) == 2)
        #expect(MediaGalleryView.clampedIndex(2, count: 1) == 0)
    }

    @Test("MediaGalleryView initializes safely with an empty items array")
    @MainActor
    func galleryViewInitWithEmptyItems() {
        // Must not trap; the view renders an empty state instead of controls.
        _ = MediaGalleryView(
            mediaItems: [],
            initialIndex: 0,
            onDismiss: {}
        )
        _ = MediaGalleryView(
            mediaItems: [],
            initialIndex: 7,
            onDismiss: {}
        )
    }
}

// MARK: - ThumbnailCache Tests

@Suite("ThumbnailCache Tests")
struct ThumbnailCacheTests {
    @Test("ThumbnailCache singleton exists")
    func singletonExists() {
        let cache = ThumbnailCache.shared
        #expect(cache != nil)
    }

    @Test("ThumbnailCache stores and retrieves images")
    func storeAndRetrieve() {
        let cache = ThumbnailCache(maxMemoryMB: 10)
        let testId = UUID()

        // Create a simple test image
        #if canImport(UIKit)
        let image = UIImage()
        #elseif canImport(AppKit)
        let image = NSImage(size: NSSize(width: 100, height: 100))
        #endif

        cache.set(testId, image: image)
        let retrieved = cache.get(testId)

        #expect(retrieved != nil)
        cache.clear()
    }

    @Test("ThumbnailCache returns nil for non-existent key")
    func returnsNilForNonExistent() {
        let cache = ThumbnailCache(maxMemoryMB: 10)
        let testId = UUID()

        let retrieved = cache.get(testId)
        #expect(retrieved == nil)
    }

    @Test("ThumbnailCache contains check works")
    func containsCheck() {
        let cache = ThumbnailCache(maxMemoryMB: 10)
        let testId = UUID()

        #expect(cache.contains(testId) == false)

        #if canImport(UIKit)
        let image = UIImage()
        #elseif canImport(AppKit)
        let image = NSImage(size: NSSize(width: 100, height: 100))
        #endif

        cache.set(testId, image: image)
        #expect(cache.contains(testId) == true)

        cache.clear()
    }

    @Test("ThumbnailCache clear removes all entries")
    func clearRemovesAll() {
        let cache = ThumbnailCache(maxMemoryMB: 10)

        #if canImport(UIKit)
        let image = UIImage()
        #elseif canImport(AppKit)
        let image = NSImage(size: NSSize(width: 100, height: 100))
        #endif

        // Add multiple items
        for _ in 0..<5 {
            cache.set(UUID(), image: image)
        }

        let statsBefore = cache.stats
        #expect(statsBefore.count == 5)

        cache.clear()

        let statsAfter = cache.stats
        let afterCount = statsAfter.count
        #expect(afterCount == 0)
        #expect(statsAfter.memoryMB == 0)
    }

    @Test("ThumbnailCache stats reports count and memory")
    func statsReportsValues() {
        let cache = ThumbnailCache(maxMemoryMB: 10)

        let stats = cache.stats
        let itemCount = stats.count
        #expect(itemCount >= 0)
        #expect(stats.memoryMB >= 0)

        cache.clear()
    }

    @Test("ThumbnailCache handleMemoryPressure evicts entries")
    func memoryPressureEvicts() {
        let cache = ThumbnailCache(maxMemoryMB: 10)

        #if canImport(UIKit)
        let image = UIImage()
        #elseif canImport(AppKit)
        let image = NSImage(size: NSSize(width: 100, height: 100))
        #endif

        // Add items
        for _ in 0..<10 {
            cache.set(UUID(), image: image)
        }

        let countBefore = cache.stats.count
        cache.handleMemoryPressure()

        // Memory pressure should reduce cache size
        // (exact behavior depends on image sizes)
        let countAfter = cache.stats.count
        #expect(countAfter <= countBefore)

        cache.clear()
    }

    @Test("ThumbnailCache thumbnailSize has reasonable value")
    func thumbnailSizeReasonable() {
        let size = ThumbnailCache.thumbnailSize
        #expect(size > 50)
        #expect(size < 500)
    }

    @Test("ThumbnailCache createThumbnail from image returns smaller image")
    func createThumbnailFromImage() {
        #if canImport(UIKit)
        // Create a large test image
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1000))
        let largeImage = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 1000, height: 1000)))
        }

        let thumbnail = ThumbnailCache.createThumbnail(from: largeImage, targetSize: 100)

        #expect(thumbnail.size.width <= 100)
        #expect(thumbnail.size.height <= 100)
        #elseif canImport(AppKit)
        let largeImage = NSImage(size: NSSize(width: 1000, height: 1000))
        largeImage.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: NSSize(width: 1000, height: 1000)).fill()
        largeImage.unlockFocus()

        let thumbnail = ThumbnailCache.createThumbnail(from: largeImage, targetSize: 100)

        #expect(thumbnail.size.width <= 100)
        #expect(thumbnail.size.height <= 100)
        #endif
    }

    @Test("ThumbnailCache createThumbnail from data returns nil for invalid data")
    func createThumbnailFromInvalidData() {
        let invalidData = Data([0x00, 0x01, 0x02])
        let thumbnail = ThumbnailCache.createThumbnail(from: invalidData, targetSize: 100)
        #expect(thumbnail == nil)
    }

    @Test("ThumbnailCache createThumbnail from URL returns nil for non-existent file")
    func createThumbnailFromNonExistentURL() {
        let url = URL(fileURLWithPath: "/nonexistent/file.jpg")
        let thumbnail = ThumbnailCache.createThumbnail(from: url, targetSize: 100)
        #expect(thumbnail == nil)
    }

    @Test("ThumbnailCache is thread-safe")
    func threadSafety() async {
        let cache = ThumbnailCache(maxMemoryMB: 10)

        #if canImport(UIKit)
        let image = UIImage()
        #elseif canImport(AppKit)
        let image = NSImage(size: NSSize(width: 100, height: 100))
        #endif

        // Concurrent access from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let id = UUID()
                    cache.set(id, image: image)
                    _ = cache.get(id)
                    _ = cache.contains(id)
                    _ = cache.stats
                }
            }
        }

        // If we get here without crashing, thread safety is working
        cache.clear()
    }
}

// MARK: - Default loadThumbnail Tests

@Suite("Default loadThumbnail Tests")
struct DefaultLoadThumbnailTests {
    @Test("ImageMediaItem default loadThumbnail returns nil when loadImage returns nil")
    func imageItemDefaultThumbnailNil() async {
        let item = ImageMediaItem { nil }
        let thumbnail = await item.loadThumbnail(targetSize: 100)
        #expect(thumbnail == nil)
    }

    @Test("VideoMediaItem default loadThumbnail returns nil when no thumbnail loader")
    func videoItemDefaultThumbnailNil() async {
        let item = VideoMediaItem { nil }
        let thumbnail = await item.loadThumbnail(targetSize: 100)
        #expect(thumbnail == nil)
    }

    @Test("AnimatedImageMediaItem default loadThumbnail returns nil when loadImage returns nil")
    func animatedItemDefaultThumbnailNil() async {
        let item = AnimatedImageMediaItem(
            imageLoader: { nil },
            durationLoader: { nil }
        )
        let thumbnail = await item.loadThumbnail(targetSize: 100)
        #expect(thumbnail == nil)
    }
}

// MARK: - Concurrency Safety Tests

@Suite("Concurrency Safety Tests")
struct ConcurrencySafetyTests {
    @Test("MediaItem implementations are Sendable")
    func mediaItemsAreSendable() async {
        let imageItem: any MediaItem & Sendable = ImageMediaItem { nil }
        let animatedItem: any MediaItem & Sendable = AnimatedImageMediaItem(
            imageLoader: { nil },
            durationLoader: { nil }
        )
        let videoItem: any MediaItem & Sendable = VideoMediaItem { nil }

        // If this compiles, the types are Sendable
        await Task.detached {
            _ = imageItem.id
            _ = animatedItem.id
            _ = videoItem.id
        }.value
    }

    @Test("Async loaders can be called from different contexts")
    func asyncLoadersWorkAcrossContexts() async {
        let item = ImageMediaItem {
            // Simulate async work
            try? await Task.sleep(nanoseconds: 1_000_000)
            return nil
        }

        // Call from multiple tasks concurrently
        async let result1 = item.loadImage()
        async let result2 = item.loadImage()
        async let result3 = item.loadImage()

        _ = await (result1, result2, result3)
        // If this completes without issues, concurrency is handled correctly
    }
}

// MARK: - Slideshow Configuration Tests

@Suite("Slideshow Configuration Tests")
struct SlideshowConfigurationTests {
    @Test("Existing consumers compile and keep their behavior")
    func sourceCompatibility() {
        // Pinned shape: a config built from ONLY the pre-existing parameters
        // must still compile, and the new knobs must default to today's
        // behavior (loop all, unshuffled, no autostart, no callbacks).
        let config = MediaGalleryConfiguration(
            slideshowDuration: 12.0,
            customActions: [MediaGalleryAction(icon: "heart") { _ in }],
            onVRProjectionChange: { _, _ in }
        )

        #expect(config.slideshowDuration == 12.0)
        #expect(config.slideshowInitialLoopMode == .all)
        #expect(config.slideshowShuffled == false)
        #expect(config.slideshowAutoStart == false)
        #expect(config.onLoopModeChange == nil)
        #expect(config.onShuffleChange == nil)
        // v2.9.0: autoplay must default OFF, so an untouched consumer keeps
        // "video only plays while the slideshow runs".
        #expect(config.autoPlayVideoOnOpen == false)
    }

    @Test("Autoplay-on-open is independent of slideshow autostart")
    func autoPlayVideoOnOpenIsOrthogonal() {
        // The point of the knob: play the current slide's video WITHOUT
        // starting the slideshow, so the album never auto-advances.
        let autoplayOnly = MediaGalleryConfiguration(autoPlayVideoOnOpen: true)
        #expect(autoplayOnly.autoPlayVideoOnOpen == true)
        #expect(autoplayOnly.slideshowAutoStart == false)

        // ...and the reverse: autostarting the slideshow must not silently
        // imply the new flag.
        let slideshowOnly = MediaGalleryConfiguration(slideshowAutoStart: true)
        #expect(slideshowOnly.slideshowAutoStart == true)
        #expect(slideshowOnly.autoPlayVideoOnOpen == false)

        // Both together stay legal and independent.
        let both = MediaGalleryConfiguration(slideshowAutoStart: true, autoPlayVideoOnOpen: true)
        #expect(both.slideshowAutoStart == true)
        #expect(both.autoPlayVideoOnOpen == true)
    }

    @Test("Slideshow seeds round-trip through the configuration")
    func slideshowSeeds() {
        let config = MediaGalleryConfiguration(
            slideshowInitialLoopMode: .one,
            slideshowShuffled: true,
            slideshowAutoStart: true
        )

        #expect(config.slideshowInitialLoopMode == .one)
        #expect(config.slideshowShuffled == true)
        #expect(config.slideshowAutoStart == true)
    }

    @Test("Shuffled order covers every index with the current one pinned first")
    func shuffledOrderIsCoherent() {
        // A gallery seeded shuffled must get the same bookkeeping toggleShuffle()
        // builds: a full permutation that starts on the item already on screen.
        let order = MediaGalleryView.shuffledOrder(count: 10, startingAt: 4)

        #expect(order.count == 10)
        #expect(order.first == 4)
        #expect(Set(order) == Set(0..<10))
    }

    @Test("Shuffled order is empty for an empty collection")
    func shuffledOrderEmptyCollection() {
        #expect(MediaGalleryView.shuffledOrder(count: 0, startingAt: 0).isEmpty)
    }
}

// MARK: - Video Player Routing Tests

@Suite("Video Player Routing Tests")
struct VideoPlayerRoutingTests {
    @Test("Query-based URLs route on diskCacheKey, not the empty path extension")
    func queryBasedURLRoutesOnCacheKey() {
        // The regression: a host serving media from a query-based URL has an
        // EMPTY pathExtension, so the old `url.pathExtension == "webm"` test
        // never matched and every video — WebM included — went to AVFoundation,
        // which cannot decode VP8/VP9 and hung forever.
        let queryURL = URL(string: "https://host.example/media?id=abc123")!

        #expect(queryURL.pathExtension.isEmpty)  // pins WHY the old test failed
        #expect(VideoPlayerRouter.requiresWebViewPlayer(
            diskCacheKey: "clip.webm",
            urls: [queryURL]
        ) == true)
    }

    @Test("diskCacheKey wins over a misleading URL extension")
    func cacheKeyTakesPrecedence() {
        let mp4URL = URL(string: "https://host.example/stream.mp4")!
        #expect(VideoPlayerRouter.requiresWebViewPlayer(
            diskCacheKey: "actually_a.webm",
            urls: [mp4URL]
        ) == true)
    }

    @Test("Extensioned URLs still route correctly when no cache key exists")
    func urlExtensionFallback() {
        #expect(VideoPlayerRouter.requiresWebViewPlayer(
            diskCacheKey: nil,
            urls: [URL(string: "https://host.example/clip.webm")!]
        ) == true)

        #expect(VideoPlayerRouter.requiresWebViewPlayer(
            diskCacheKey: nil,
            urls: [URL(string: "https://host.example/clip.mp4")!]
        ) == false)
    }

    @Test("A filename in a query value is the last resort")
    func queryValueCarriesTheFilename() {
        // A query-based host commonly passes the real path as a parameter.
        #expect(VideoPlayerRouter.requiresWebViewPlayer(
            diskCacheKey: nil,
            urls: [URL(string: "https://host.example/api/?path=Album/clip.webm")!]
        ) == true)

        #expect(VideoPlayerRouter.requiresWebViewPlayer(
            diskCacheKey: nil,
            urls: [URL(string: "https://host.example/api/?path=Album/clip.mp4")!]
        ) == false)
    }

    @Test("Routing is case-insensitive")
    func routingIsCaseInsensitive() {
        #expect(VideoPlayerRouter.requiresWebViewPlayer(diskCacheKey: "CLIP.WebM", urls: []) == true)
    }

    @Test("Nothing carrying a type leaves AVFoundation to try")
    func noTypeInformationDefaultsToAVFoundation() {
        // An opaque cache key and an extensionless URL: AVFoundation is the
        // better player when it works, and the readiness timeout in
        // ZoomableMediaView catches it when it doesn't.
        #expect(VideoPlayerRouter.requiresWebViewPlayer(
            diskCacheKey: "9f8a7b6c5d4e",
            urls: [URL(string: "https://host.example/media?id=abc")!]
        ) == false)

        #expect(VideoPlayerRouter.containerExtension(diskCacheKey: nil, urls: [nil]) == nil)
    }

    @Test("MKV and AVI stay on the AVFoundation path")
    func unsupportedContainersAreNotSentToWebKit() {
        // WebKit can't play these either — routing them to the WebView player
        // would trade one broken player for another.
        #expect(VideoPlayerRouter.requiresWebViewPlayer(diskCacheKey: "clip.mkv", urls: []) == false)
        #expect(VideoPlayerRouter.requiresWebViewPlayer(diskCacheKey: "clip.avi", urls: []) == false)
    }

    @Test("containerExtension normalizes to a bare lowercase extension")
    func containerExtensionShape() {
        #expect(VideoPlayerRouter.containerExtension(diskCacheKey: "a/b/Clip.MP4", urls: []) == "mp4")
    }
}

// MARK: - Swipe Navigation Tests

@Suite("Swipe Navigation Tests")
struct SwipeNavigationTests {
    @Test("A quick flick registers even though it barely travels")
    func fastFlickRegisters() {
        // The regression: minimumDistance 100 + a 100pt end-translation test
        // meant a flick — which lifts after ~30pt and carries on momentum —
        // never changed slides.
        let direction = MediaGalleryView.swipeDirection(
            translation: CGSize(width: -30, height: 4),
            predictedEndTranslation: CGSize(width: -260, height: 20)
        )
        #expect(direction == -1)  // next item
    }

    @Test("A deliberate slow drag registers with no momentum")
    func slowDragRegisters() {
        let direction = MediaGalleryView.swipeDirection(
            translation: CGSize(width: 70, height: 10),
            predictedEndTranslation: CGSize(width: 70, height: 10)
        )
        #expect(direction == 1)  // previous item
    }

    @Test("A vertical scroll never changes slides")
    func verticalScrollRejected() {
        #expect(MediaGalleryView.swipeDirection(
            translation: CGSize(width: 20, height: 200),
            predictedEndTranslation: CGSize(width: 40, height: 600)
        ) == nil)
    }

    @Test("A diagonal drag is rejected unless clearly horizontal")
    func diagonalDragRejected() {
        // 60pt horizontal clears the commit distance on its own, but 50pt of
        // vertical makes it ambiguous — this is the guard that keeps a
        // zoom-pan or a drifting scroll from flipping slides.
        #expect(MediaGalleryView.swipeDirection(
            translation: CGSize(width: 60, height: 50),
            predictedEndTranslation: CGSize(width: 60, height: 50)
        ) == nil)
    }

    @Test("A small nudge with no momentum is not a swipe")
    func tinyNudgeRejected() {
        #expect(MediaGalleryView.swipeDirection(
            translation: CGSize(width: 22, height: 2),
            predictedEndTranslation: CGSize(width: 25, height: 2)
        ) == nil)
    }

    @Test("A still finger is not a swipe")
    func zeroTranslationRejected() {
        #expect(MediaGalleryView.swipeDirection(
            translation: .zero,
            predictedEndTranslation: .zero
        ) == nil)
    }

    @Test("Thresholds are loose enough for a flick, strict enough to stay directional")
    func thresholdsArePinned() {
        // Pins the balance so a later tweak has to be deliberate.
        #expect(MediaGalleryView.swipeMinimumDistance < 100)   // was 100 — flicks never started
        #expect(MediaGalleryView.swipeCommitDistance < 100)    // was 100 — flicks never committed
        #expect(MediaGalleryView.swipeHorizontalDominance >= 1.5)  // still clearly horizontal
    }
}
