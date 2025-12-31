import Foundation
import SwiftUI
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Represents the type of media content
public enum MediaType: Sendable {
    case image
    case video
    case animatedImage
}

// MARK: - HTTP Header Provider

/// Global configuration for HTTP headers and authentication in MediaStream
/// Apps can set providers to inject authentication into HTTP requests
public enum MediaStreamConfiguration {
    /// Closure type for providing HTTP headers for a given URL
    public typealias HeaderProvider = @Sendable (URL) -> [String: String]?

    /// Closure type for providing Basic Auth credentials for a given URL
    public typealias CredentialProvider = @Sendable (URL) -> (username: String, password: String)?

    /// The header provider closure - set this in your app to provide authentication headers
    /// Used by AVFoundation for video thumbnail generation
    /// Example:
    /// ```
    /// MediaStreamConfiguration.headerProvider = { url in
    ///     if url.host == "127.0.0.1" {
    ///         return ["Authorization": "Basic \(base64Credentials)"]
    ///     }
    ///     return nil
    /// }
    /// ```
    @MainActor
    public static var headerProvider: HeaderProvider?

    /// The credential provider closure for Basic Auth challenges in WKWebView
    /// Set this to handle HTTP Basic Auth for video playback
    /// Example:
    /// ```
    /// MediaStreamConfiguration.credentialProvider = { url in
    ///     if url.host == "127.0.0.1" {
    ///         return (username: "user", password: "pass")
    ///     }
    ///     return nil
    /// }
    /// ```
    @MainActor
    public static var credentialProvider: CredentialProvider?

    /// Get headers for a URL using the configured provider
    public static func headers(for url: URL) -> [String: String]? {
        return MainActor.assumeIsolated {
            headerProvider?(url)
        }
    }

    /// Async version for contexts where we're not on main actor
    public static func headersAsync(for url: URL) async -> [String: String]? {
        return await MainActor.run {
            headerProvider?(url)
        }
    }

    /// Get credentials for a URL using the configured provider
    public static func credentials(for url: URL) -> (username: String, password: String)? {
        return MainActor.assumeIsolated {
            credentialProvider?(url)
        }
    }

    /// Async version for credentials
    public static func credentialsAsync(for url: URL) async -> (username: String, password: String)? {
        return await MainActor.run {
            credentialProvider?(url)
        }
    }
}

/// Protocol that media items must conform to
public protocol MediaItem: Identifiable, Sendable {
    var id: UUID { get }
    var type: MediaType { get }

    /// A stable key for disk caching (e.g., hash of URL or file path + modification date)
    /// Return nil if caching is not desired for this item
    var diskCacheKey: String? { get }

    /// Load the image content asynchronously
    func loadImage() async -> PlatformImage?

    /// Load a downsampled thumbnail efficiently (memory-optimized)
    /// Default implementation calls loadImage() and downsamples
    func loadThumbnail(targetSize: CGFloat) async -> PlatformImage?

    /// Load the video URL (for video type only)
    func loadVideoURL() async -> URL?

    /// Get the URL for an animated image (for streaming large GIFs)
    /// Return nil to use loadImage() instead (which loads all frames into memory)
    func loadAnimatedImageURL() async -> URL?

    /// Get the raw data for an animated image (alternative to URL for streaming)
    /// Return nil if not available
    func loadAnimatedImageData() async -> Data?

    /// Get the duration for animated images (in seconds)
    func getAnimatedImageDuration() async -> TimeInterval?

    /// Get the duration for videos (in seconds)
    func getVideoDuration() async -> TimeInterval?

    /// Get a shareable item (URL or Data) for share sheet
    func getShareableItem() async -> Any?

    /// Get the caption for this media item (optional)
    func getCaption() async -> String?

    /// Check if video has audio track (for video type only)
    func hasAudioTrack() async -> Bool
}

// MARK: - Default loadAnimatedImageURL Implementation

extension MediaItem {
    /// Default: no streaming URL (will use loadImage instead)
    public func loadAnimatedImageURL() async -> URL? { nil }

    /// Default: no raw data available
    public func loadAnimatedImageData() async -> Data? { nil }
}

// MARK: - Default diskCacheKey Implementation

extension MediaItem {
    /// Default: no disk caching (items must opt in)
    public var diskCacheKey: String? { nil }
}

// MARK: - Default Implementation for loadThumbnail

extension MediaItem {
    /// Default implementation: loads full image and downsamples
    /// Subclasses can override for more efficient file-based loading
    public func loadThumbnail(targetSize: CGFloat = ThumbnailCache.thumbnailSize) async -> PlatformImage? {
        guard let fullImage = await loadImage() else { return nil }
        return ThumbnailCache.createThumbnail(from: fullImage, targetSize: targetSize)
    }
}

/// Platform-agnostic image type
#if canImport(UIKit)
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
public typealias PlatformImage = NSImage
#endif

/// Default implementation for image-based media items
public struct ImageMediaItem: MediaItem {
    public let id: UUID
    public let type: MediaType = .image
    public let diskCacheKey: String?

    private let imageLoader: @Sendable () async -> PlatformImage?

    public init(id: UUID = UUID(), imageLoader: @escaping @Sendable () async -> PlatformImage?, cacheKey: String? = nil) {
        self.id = id
        self.imageLoader = imageLoader
        self.diskCacheKey = cacheKey
    }

    public func loadImage() async -> PlatformImage? {
        await imageLoader()
    }

    public func loadVideoURL() async -> URL? {
        nil
    }

    public func getAnimatedImageDuration() async -> TimeInterval? {
        nil
    }

    public func getVideoDuration() async -> TimeInterval? {
        nil
    }

    public func getShareableItem() async -> Any? {
        await loadImage()
    }

    public func getCaption() async -> String? {
        nil
    }

    public func hasAudioTrack() async -> Bool {
        false
    }
}

/// Default implementation for animated image media items
public struct AnimatedImageMediaItem: MediaItem {
    public let id: UUID
    public let type: MediaType = .animatedImage
    public let diskCacheKey: String?

    private let imageLoader: @Sendable () async -> PlatformImage?
    private let durationLoader: @Sendable () async -> TimeInterval?

    public init(id: UUID = UUID(),
                imageLoader: @escaping @Sendable () async -> PlatformImage?,
                durationLoader: @escaping @Sendable () async -> TimeInterval?,
                cacheKey: String? = nil) {
        self.id = id
        self.imageLoader = imageLoader
        self.durationLoader = durationLoader
        self.diskCacheKey = cacheKey
    }

    public func loadImage() async -> PlatformImage? {
        await imageLoader()
    }

    public func loadVideoURL() async -> URL? {
        nil
    }

    public func getAnimatedImageDuration() async -> TimeInterval? {
        await durationLoader()
    }

    public func getVideoDuration() async -> TimeInterval? {
        nil
    }

    public func getShareableItem() async -> Any? {
        await loadImage()
    }

    public func getCaption() async -> String? {
        nil
    }

    public func hasAudioTrack() async -> Bool {
        false
    }
}

/// Default implementation for video-based media items
public struct VideoMediaItem: MediaItem {
    public let id: UUID
    public let type: MediaType = .video
    public let diskCacheKey: String?

    private let videoURLLoader: @Sendable () async -> URL?
    private let thumbnailLoader: (@Sendable () async -> PlatformImage?)?
    private let durationLoader: (@Sendable () async -> TimeInterval?)?

    public init(id: UUID = UUID(),
                videoURLLoader: @escaping @Sendable () async -> URL?,
                thumbnailLoader: (@Sendable () async -> PlatformImage?)? = nil,
                durationLoader: (@Sendable () async -> TimeInterval?)? = nil,
                cacheKey: String? = nil) {
        self.id = id
        self.videoURLLoader = videoURLLoader
        self.thumbnailLoader = thumbnailLoader
        self.durationLoader = durationLoader
        self.diskCacheKey = cacheKey
    }

    public func loadImage() async -> PlatformImage? {
        // If a custom thumbnailLoader was provided, use it
        if let thumbnailLoader = thumbnailLoader {
            return await thumbnailLoader()
        }

        // Otherwise, try to generate thumbnail from video URL
        guard let url = await loadVideoURL() else { return nil }

        // Get headers from MediaStreamConfiguration for authenticated requests
        let headers = await MediaStreamConfiguration.headersAsync(for: url)

        // Use WebViewVideoController for all video thumbnails (supports WebM, MP4, etc.)
        // This uses WKWebView's HTML5 video which has broad format support
        return await WebViewVideoController.generateThumbnail(
            from: url,
            targetSize: ThumbnailCache.thumbnailSize,
            headers: headers
        )
    }

    public func loadVideoURL() async -> URL? {
        await videoURLLoader()
    }

    public func getAnimatedImageDuration() async -> TimeInterval? {
        nil
    }

    public func getVideoDuration() async -> TimeInterval? {
        if let durationLoader = durationLoader {
            return await durationLoader()
        }

        guard let url = await loadVideoURL() else { return nil }

        // Get headers from MediaStreamConfiguration for HTTP URLs
        let headers = await MediaStreamConfiguration.headersAsync(for: url)

        // Use VideoMetadata which properly falls back to HTML5 video for WebM and other formats
        // AVFoundation doesn't support WebM
        return await VideoMetadata.getVideoDuration(from: url, headers: headers)
    }

    public func getShareableItem() async -> Any? {
        await loadVideoURL()
    }

    public func getCaption() async -> String? {
        nil
    }

    public func hasAudioTrack() async -> Bool {
        guard let url = await loadVideoURL() else { return false }

        // Get headers from MediaStreamConfiguration for HTTP URLs
        let headers = await MediaStreamConfiguration.headersAsync(for: url)

        // Use VideoMetadata which properly falls back to HTML5 video for WebM and other formats
        // AVFoundation doesn't support WebM
        return await VideoMetadata.hasAudioTrack(url: url, headers: headers)
    }
}
