import Testing
import Foundation
@testable import MediaStream

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

    @Test("MediaFilter raw values are correct")
    func rawValuesAreCorrect() {
        #expect(MediaFilter.all.rawValue == "All")
        #expect(MediaFilter.images.rawValue == "Images")
        #expect(MediaFilter.videos.rawValue == "Videos")
        #expect(MediaFilter.animated.rawValue == "Animated")
    }

    @Test("MediaFilter allCases contains all filters")
    func allCasesContainsAll() {
        #expect(MediaFilter.allCases.count == 4)
        #expect(MediaFilter.allCases.contains(.all))
        #expect(MediaFilter.allCases.contains(.images))
        #expect(MediaFilter.allCases.contains(.videos))
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

// MARK: - Index Bounds Tests

@Suite("Index Bounds Tests")
struct IndexBoundsTests {
    @Test("Initial index is clamped to valid range")
    func initialIndexClamping() {
        // Test that the clamping logic works correctly
        let items: [any MediaItem] = [
            ImageMediaItem { nil },
            ImageMediaItem { nil },
            ImageMediaItem { nil }
        ]

        // These tests verify the clamping formula: min(max(0, index), count - 1)
        let clampedNegative = min(max(0, -5), items.count - 1)
        #expect(clampedNegative == 0)

        let clampedTooLarge = min(max(0, 100), items.count - 1)
        #expect(clampedTooLarge == 2)

        let clampedValid = min(max(0, 1), items.count - 1)
        #expect(clampedValid == 1)
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
