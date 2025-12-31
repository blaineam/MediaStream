import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Streaming Animated Image View (Memory-Efficient)

#if canImport(UIKit)
/// A memory-efficient animated image view that decodes frames on-demand
/// instead of loading all frames into memory at once.
/// Use this for large GIFs with many frames to prevent OOM.
public class StreamingAnimatedImageView: UIView {
    /// Maximum number of frames to cache in memory (decode ahead + behind)
    private static let frameCacheSize = 4

    /// Threshold: GIFs with more frames than this use streaming
    public static let streamingThreshold = 50

    private var imageSource: CGImageSource?
    private var frameCount: Int = 0
    private var frameDurations: [TimeInterval] = []
    private var totalDuration: TimeInterval = 0
    private var currentFrameIndex: Int = 0
    private var accumulatedTime: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var frameCache: [Int: CGImage] = [:]
    private var isAnimating = false

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        return iv
    }()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    deinit {
        stopAnimating()
        clearCache()
    }

    /// Load an animated image from data
    public func loadImage(from data: Data) {
        stopAnimating()
        clearCache()

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return
        }

        imageSource = source
        frameCount = CGImageSourceGetCount(source)

        guard frameCount > 0 else { return }

        // Pre-calculate frame durations
        frameDurations = []
        totalDuration = 0

        for i in 0..<frameCount {
            let duration = getFrameDuration(at: i)
            frameDurations.append(duration)
            totalDuration += duration
        }

        // Show first frame immediately
        if let firstFrame = decodeFrame(at: 0) {
            imageView.image = UIImage(cgImage: firstFrame)
        }

        // Only start animation if there are multiple frames
        if frameCount > 1 {
            startAnimating()
        }
    }

    /// Load an animated image from URL
    public func loadImage(from url: URL) {
        stopAnimating()
        clearCache()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return
        }

        imageSource = source
        frameCount = CGImageSourceGetCount(source)

        guard frameCount > 0 else { return }

        // Pre-calculate frame durations
        frameDurations = []
        totalDuration = 0

        for i in 0..<frameCount {
            let duration = getFrameDuration(at: i)
            frameDurations.append(duration)
            totalDuration += duration
        }

        // Show first frame immediately
        if let firstFrame = decodeFrame(at: 0) {
            imageView.image = UIImage(cgImage: firstFrame)
        }

        // Only start animation if there are multiple frames
        if frameCount > 1 {
            startAnimating()
        }
    }

    private func getFrameDuration(at index: Int) -> TimeInterval {
        guard let source = imageSource,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else {
            return 0.1
        }

        var duration: TimeInterval = 0.1

        if let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
            if let delay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval, delay > 0 {
                duration = delay
            } else if let delay = gifProperties[kCGImagePropertyGIFDelayTime as String] as? TimeInterval, delay > 0 {
                duration = delay
            }
        } else if let pngProperties = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            if let delay = pngProperties[kCGImagePropertyAPNGDelayTime as String] as? TimeInterval, delay > 0 {
                duration = delay
            }
        }

        return max(duration, 0.01) // Minimum 10ms
    }

    private func decodeFrame(at index: Int) -> CGImage? {
        // Check cache first
        if let cached = frameCache[index] {
            return cached
        }

        guard let source = imageSource else { return nil }

        // Decode the frame
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true
        ]

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else {
            return nil
        }

        // Cache it (with LRU eviction)
        frameCache[index] = cgImage

        // Evict old frames if cache is too large
        if frameCache.count > Self.frameCacheSize {
            evictDistantFrames(from: index)
        }

        return cgImage
    }

    private func evictDistantFrames(from currentIndex: Int) {
        let keepRange = max(0, currentIndex - 1)...min(frameCount - 1, currentIndex + Self.frameCacheSize - 2)

        for key in frameCache.keys {
            if !keepRange.contains(key) {
                frameCache.removeValue(forKey: key)
            }
        }
    }

    private func clearCache() {
        frameCache.removeAll()
        imageSource = nil
        frameDurations = []
        frameCount = 0
        totalDuration = 0
        currentFrameIndex = 0
        accumulatedTime = 0
    }

    public func startAnimating() {
        guard !isAnimating, frameCount > 1 else { return }
        isAnimating = true

        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.add(to: .main, forMode: .common)
    }

    public func stopAnimating() {
        isAnimating = false
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updateFrame(_ link: CADisplayLink) {
        guard frameCount > 1 else { return }

        accumulatedTime += link.duration

        // Find the current frame based on accumulated time
        let frameDuration = frameDurations[currentFrameIndex]

        if accumulatedTime >= frameDuration {
            accumulatedTime -= frameDuration
            currentFrameIndex = (currentFrameIndex + 1) % frameCount

            if let frame = decodeFrame(at: currentFrameIndex) {
                imageView.image = UIImage(cgImage: frame)
            }

            // Pre-decode next frame
            let nextIndex = (currentFrameIndex + 1) % frameCount
            _ = decodeFrame(at: nextIndex)
        }
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopAnimating()
            clearCache()
        }
    }
}
#endif

/// Helper class for working with animated images
public struct AnimatedImageHelper {

    #if canImport(UIKit)
    /// Creates an animated UIImage from GIF/APNG data with proper frame extraction
    /// This is required because UIImage(data:) only loads the first frame
    public static func createAnimatedImage(from data: Data) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(imageSource)
        guard count > 1 else {
            // Not animated, just return regular image
            return UIImage(data: data)
        }

        var images: [UIImage] = []
        var totalDuration: TimeInterval = 0

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, i, nil) else {
                continue
            }

            let frame = UIImage(cgImage: cgImage)
            images.append(frame)

            // Get frame duration
            var frameDuration: TimeInterval = 0.1
            if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil) as? [String: Any] {
                if let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                    if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval, delayTime > 0 {
                        frameDuration = delayTime
                    } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime as String] as? TimeInterval, delayTime > 0 {
                        frameDuration = delayTime
                    }
                } else if let pngProperties = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
                    if let delayTime = pngProperties[kCGImagePropertyAPNGDelayTime as String] as? TimeInterval, delayTime > 0 {
                        frameDuration = delayTime
                    }
                }
            }
            totalDuration += max(frameDuration, 0.01) // Minimum 10ms per frame
        }

        guard !images.isEmpty else { return nil }

        return UIImage.animatedImage(with: images, duration: totalDuration)
    }

    /// Creates an animated UIImage from a URL
    public static func createAnimatedImage(from url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return createAnimatedImage(from: data)
    }
    #endif

    #if canImport(AppKit)
    /// Creates an NSImage from animated image data
    /// NSImage handles animation natively through NSImageView.animates
    public static func createAnimatedImage(from data: Data) -> NSImage? {
        return NSImage(data: data)
    }

    /// Creates an NSImage from a URL
    public static func createAnimatedImage(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return NSImage(data: data)
    }
    #endif

    /// Detects if a file is an animated image and returns its total duration
    public static func getAnimatedImageDuration(from url: URL) async -> TimeInterval? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(imageSource)
        guard count > 1 else {
            return nil
        }

        var totalDuration: TimeInterval = 0

        for i in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil) as? [String: Any],
                  let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
                continue
            }

            var frameDuration: TimeInterval = 0.1

            if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval, delayTime > 0 {
                frameDuration = delayTime
            } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime as String] as? TimeInterval {
                frameDuration = delayTime
            }

            totalDuration += frameDuration
        }

        return totalDuration > 0 ? totalDuration : nil
    }

    /// Detects if data represents an animated image and returns its total duration
    public static func getAnimatedImageDuration(from data: Data) async -> TimeInterval? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(imageSource)
        guard count > 1 else {
            return nil
        }

        var totalDuration: TimeInterval = 0

        for i in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil) as? [String: Any] else {
                continue
            }

            var frameDuration: TimeInterval = 0.1

            if let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval, delayTime > 0 {
                    frameDuration = delayTime
                } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime as String] as? TimeInterval {
                    frameDuration = delayTime
                }
            } else if let pngProperties = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any],
                      let delayTime = pngProperties[kCGImagePropertyAPNGDelayTime as String] as? TimeInterval {
                frameDuration = delayTime
            } else if let heicProperties = properties["{HEICS}" as String] as? [String: Any],
                      let delayTime = heicProperties["DelayTime" as String] as? TimeInterval {
                frameDuration = delayTime
            }

            totalDuration += max(frameDuration, 0.1)
        }

        return totalDuration > 0 ? totalDuration : nil
    }

    /// Checks if a file is an animated image by actually reading the image data
    public static func isAnimatedImageFile(_ url: URL) -> Bool {
        // First check if the extension could potentially be animated
        let pathExtension = url.pathExtension.lowercased()
        guard ["gif", "heif", "heic", "png", "apng", "webp"].contains(pathExtension) else {
            return false
        }

        // Then check if it actually has multiple frames
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetCount(imageSource) > 1
    }

    /// Checks if data represents an animated image
    public static func isAnimatedImage(_ data: Data) -> Bool {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(imageSource) > 1
    }

    /// Get the frame count for an animated image from URL
    public static func getFrameCount(from url: URL) -> Int {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return 0
        }
        return CGImageSourceGetCount(imageSource)
    }

    /// Get the frame count for an animated image from data
    public static func getFrameCount(from data: Data) -> Int {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return 0
        }
        return CGImageSourceGetCount(imageSource)
    }

    #if canImport(UIKit)
    /// Check if an animated image requires streaming (too many frames for memory)
    public static func requiresStreaming(frameCount: Int) -> Bool {
        return frameCount > StreamingAnimatedImageView.streamingThreshold
    }

    /// Check if a URL's image requires streaming
    public static func requiresStreaming(url: URL) -> Bool {
        return requiresStreaming(frameCount: getFrameCount(from: url))
    }

    /// Creates a temporary GIF file from UIImage frames for streaming playback
    /// This is used when we have a loaded animated UIImage but need to use streaming
    /// to avoid keeping all frames in memory
    /// Returns the temp file URL, or nil if creation failed
    public static func createTempGIFForStreaming(from image: UIImage) -> URL? {
        guard let frames = image.images, frames.count > 1 else { return nil }

        let frameCount = frames.count
        let frameDuration = image.duration / Double(frameCount)

        // Create temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_\(UUID().uuidString).gif")

        // Create GIF destination
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else { return nil }

        // Set GIF properties
        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0  // Loop forever
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        // Add each frame
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDuration
            ]
        ]

        for frame in frames {
            guard let cgImage = frame.cgImage else { continue }
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
        }

        // Finalize
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }

        print("AnimatedImageHelper: Created temp GIF for streaming (\(frameCount) frames) at \(tempURL.lastPathComponent)")
        return tempURL
    }
    #endif

    /// Calculates the adjusted slideshow duration for an animated image
    /// This ensures the animation plays enough times to meet or exceed the minimum duration
    public static func calculateSlideshowDuration(
        animationDuration: TimeInterval,
        minimumDuration: TimeInterval
    ) -> TimeInterval {
        guard animationDuration > 0 else {
            return minimumDuration
        }

        let repeatCount = ceil(minimumDuration / animationDuration)
        return animationDuration * repeatCount
    }
}
