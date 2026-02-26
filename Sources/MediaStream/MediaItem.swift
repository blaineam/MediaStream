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
    case audio
}

/// VR projection type for 360/stereoscopic video
public enum VRProjection: String, CaseIterable, Codable, Sendable {
    case equirectangular360   // Full 360 equirectangular
    case equirectangular180   // 180 (front hemisphere)
    case stereoscopicSBS      // Side-by-side 3D on full 360 sphere (left-right halves)
    case stereoscopicTB       // Top-bottom 3D on full 360 sphere (over-under)
    case sbs180               // Side-by-side 3D on 180 hemisphere (e.g. LR_180, SBS_180)
    case tb180                // Top-bottom 3D on 180 hemisphere (e.g. TB_180, OU_180)
    case sbs                  // Left eye of SBS content shown as flat 2D (crops left half)
    case tb                   // Top eye of TB content shown as flat 2D (crops top half)
    case hsbs                 // Half SBS: half-width left eye stretched to full width, flat 2D
    case htb                  // Half TB: half-height top eye stretched to full height, flat 2D
    case fisheye180           // Mono fisheye (180° FOV, equidistant radial mapping)
    case fisheyeSBS           // SBS fisheye (left eye, 180° each)
    case fisheyeTB            // TB fisheye (top eye, 180° each)
    case flat                 // Flat video on virtual curved screen

    /// Whether this projection requires a 3D sphere renderer (SceneKit).
    /// Flat crop modes (SBS, TB, HSBS, HTB) use the regular AVPlayer with layer cropping.
    public var requiresSphere: Bool {
        switch self {
        case .sbs, .tb, .hsbs, .htb, .flat:
            return false
        default:
            return true
        }
    }

    /// Whether this projection uses fisheye (equidistant radial) mapping
    public var isFisheye: Bool {
        switch self {
        case .fisheye180, .fisheyeSBS, .fisheyeTB: return true
        default: return false
        }
    }

    /// Whether this is a side-by-side stereo format
    public var isSBS: Bool {
        switch self {
        case .stereoscopicSBS, .sbs180, .sbs, .hsbs, .fisheyeSBS: return true
        default: return false
        }
    }

    /// Whether this is a top-bottom stereo format
    public var isTB: Bool {
        switch self {
        case .stereoscopicTB, .tb180, .tb, .htb, .fisheyeTB: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .equirectangular360: return "360\u{00B0}"
        case .equirectangular180: return "180\u{00B0}"
        case .stereoscopicSBS: return "3D SBS 360\u{00B0}"
        case .stereoscopicTB: return "3D TB 360\u{00B0}"
        case .sbs180: return "3D SBS 180\u{00B0}"
        case .tb180: return "3D TB 180\u{00B0}"
        case .sbs: return "SBS"
        case .tb: return "TB"
        case .hsbs: return "Half SBS"
        case .htb: return "Half TB"
        case .fisheye180: return "Fisheye 180\u{00B0}"
        case .fisheyeSBS: return "3D SBS Fisheye"
        case .fisheyeTB: return "3D TB Fisheye"
        case .flat: return "2D"
        }
    }

    /// Compact label for inline display (e.g. control bar button)
    public var shortLabel: String {
        switch self {
        case .equirectangular360: return "360"
        case .equirectangular180: return "180"
        case .stereoscopicSBS: return "SBS"
        case .stereoscopicTB: return "TB"
        case .sbs180: return "SBS 180"
        case .tb180: return "TB 180"
        case .sbs: return "SBS"
        case .tb: return "TB"
        case .hsbs: return "HSBS"
        case .htb: return "HTB"
        case .fisheye180: return "FE 180"
        case .fisheyeSBS: return "FE SBS"
        case .fisheyeTB: return "FE TB"
        case .flat: return "2D"
        }
    }
}

// MARK: - Encryption Provider Protocol

/// Protocol for providing encryption/decryption of cached data
/// Apps can implement this to encrypt thumbnails and metadata at rest
public protocol MediaStreamEncryptionProvider: Sendable {
    /// Encrypt data for storage
    func encrypt(_ data: Data) throws -> Data

    /// Decrypt data from storage
    func decrypt(_ data: Data) throws -> Data

    /// Called when the encryption key is about to change
    /// Provider should re-encrypt all cached data with the new key
    /// - Parameters:
    ///   - oldProvider: The provider with the old key (for decryption)
    ///   - directories: The cache directories that need re-encryption
    func reencryptCaches(from oldProvider: MediaStreamEncryptionProvider, directories: [URL]) async throws
}

/// Default implementation for reencryptCaches - can be overridden
extension MediaStreamEncryptionProvider {
    public func reencryptCaches(from oldProvider: MediaStreamEncryptionProvider, directories: [URL]) async throws {
        // Default: no-op, subclasses can override
    }
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

    /// The encryption provider for encrypting cached thumbnails and metadata at rest
    /// Set this to enable encryption of disk cache
    /// Example:
    /// ```
    /// MediaStreamConfiguration.encryptionProvider = MyEncryptionProvider()
    /// ```
    public static var encryptionProvider: MediaStreamEncryptionProvider?

    /// Closure type for loading a saved playback position for a media item.
    /// Returns the saved position in seconds, or nil if no saved position exists.
    public typealias PositionProvider = @Sendable (any MediaItem) async -> Double?

    /// Closure type for saving the playback position for a media item.
    /// Called periodically during playback (~every 10 seconds) and on playback stop.
    /// Pass position <= 0 to indicate playback completed (clear saved position).
    public typealias PositionSaver = @Sendable (any MediaItem, Double) async -> Void

    /// The position provider closure — set this in your app to load saved playback positions
    @MainActor
    public static var positionProvider: PositionProvider?

    /// The position saver closure — set this in your app to persist playback positions
    @MainActor
    public static var positionSaver: PositionSaver?

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

    /// Load saved playback position for a media item
    public static func loadSavedPosition(for item: any MediaItem) async -> Double? {
        let provider = await MainActor.run { positionProvider }
        return await provider?(item)
    }

    /// Save playback position for a media item
    public static func savePosition(for item: any MediaItem, position: Double) async {
        let saver = await MainActor.run { positionSaver }
        await saver?(item, position)
    }
}

/// Protocol that media items must conform to
public protocol MediaItem: Identifiable, Sendable {
    var id: UUID { get }
    var type: MediaType { get }

    /// A stable key for disk caching (e.g., hash of URL or file path + modification date)
    /// Return nil if caching is not desired for this item
    var diskCacheKey: String? { get }

    /// The source URL for this media item (if available)
    /// For animated images, this is used directly by WebView for memory-efficient display
    /// Implement this to avoid downloading/decoding large GIFs - just pass the URL to WebView
    var sourceURL: URL? { get }

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

    /// Load the audio URL (for audio type only)
    func loadAudioURL() async -> URL?

    /// Get the duration for audio files (in seconds)
    func getAudioDuration() async -> TimeInterval?

    /// Get audio metadata (title, artist, album)
    func getAudioMetadata() async -> AudioMetadata?

    /// VR projection type (nil = not VR content)
    var vrProjection: VRProjection? { get }
}

/// Metadata for audio files
public struct AudioMetadata: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let trackNumber: Int?
    public let year: Int?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, trackNumber: Int? = nil, year: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.year = year
    }
}

// MARK: - Default loadAnimatedImageURL Implementation

extension MediaItem {
    /// Default: no streaming URL (will use loadImage instead)
    public func loadAnimatedImageURL() async -> URL? { nil }

    /// Default: no raw data available
    public func loadAnimatedImageData() async -> Data? { nil }
}

// MARK: - Default Audio Implementation

extension MediaItem {
    /// Default: no audio URL
    public func loadAudioURL() async -> URL? { nil }

    /// Default: no audio duration
    public func getAudioDuration() async -> TimeInterval? { nil }

    /// Default: no audio metadata
    public func getAudioMetadata() async -> AudioMetadata? { nil }
}

// MARK: - Default diskCacheKey Implementation

extension MediaItem {
    /// Default: no disk caching (items must opt in)
    public var diskCacheKey: String? { nil }
}

// MARK: - Default sourceURL Implementation

extension MediaItem {
    /// Default: no source URL (will use loadImage instead)
    public var sourceURL: URL? { nil }
}

// MARK: - Default VR Projection Implementation

extension MediaItem {
    /// Default: not VR content
    public var vrProjection: VRProjection? { nil }
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

        // Use ThumbnailCache which handles both AVFoundation and WebView fallback
        return await ThumbnailCache.createVideoThumbnail(from: url)
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

/// Default implementation for audio-based media items
public struct AudioMediaItem: MediaItem {
    public let id: UUID
    public let type: MediaType = .audio
    public let diskCacheKey: String?

    private let audioURLLoader: @Sendable () async -> URL?
    private let artworkLoader: (@Sendable () async -> PlatformImage?)?
    private let durationLoader: (@Sendable () async -> TimeInterval?)?
    private let metadataLoader: (@Sendable () async -> AudioMetadata?)?

    public init(id: UUID = UUID(),
                audioURLLoader: @escaping @Sendable () async -> URL?,
                artworkLoader: (@Sendable () async -> PlatformImage?)? = nil,
                durationLoader: (@Sendable () async -> TimeInterval?)? = nil,
                metadataLoader: (@Sendable () async -> AudioMetadata?)? = nil,
                cacheKey: String? = nil) {
        self.id = id
        self.audioURLLoader = audioURLLoader
        self.artworkLoader = artworkLoader
        self.durationLoader = durationLoader
        self.metadataLoader = metadataLoader
        self.diskCacheKey = cacheKey
    }

    public func loadImage() async -> PlatformImage? {
        // For audio, loadImage returns the album artwork
        if let artworkLoader = artworkLoader {
            if let artwork = await artworkLoader() {
                return artwork
            }
        }
        // Return audio placeholder if no artwork available
        return ThumbnailCache.createAudioPlaceholder(targetSize: ThumbnailCache.thumbnailSize)
    }

    public func loadVideoURL() async -> URL? {
        nil
    }

    public func loadAudioURL() async -> URL? {
        await audioURLLoader()
    }

    public func getAnimatedImageDuration() async -> TimeInterval? {
        nil
    }

    public func getVideoDuration() async -> TimeInterval? {
        nil
    }

    public func getAudioDuration() async -> TimeInterval? {
        if let durationLoader = durationLoader {
            return await durationLoader()
        }

        guard let url = await loadAudioURL() else { return nil }

        // Use AVFoundation to get audio duration
        let headers = await MediaStreamConfiguration.headersAsync(for: url)
        let asset: AVURLAsset
        if let headers = headers, !headers.isEmpty {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: url)
        }

        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return nil
        }
    }

    public func getAudioMetadata() async -> AudioMetadata? {
        if let metadataLoader = metadataLoader {
            return await metadataLoader()
        }
        return nil
    }

    public func getShareableItem() async -> Any? {
        await loadAudioURL()
    }

    public func getCaption() async -> String? {
        if let metadata = await getAudioMetadata() {
            var parts: [String] = []
            if let title = metadata.title { parts.append(title) }
            if let artist = metadata.artist { parts.append(artist) }
            if let album = metadata.album { parts.append(album) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    public func hasAudioTrack() async -> Bool {
        true // Audio files always have audio
    }
}
