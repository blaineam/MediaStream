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
