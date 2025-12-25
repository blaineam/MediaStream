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

/// Protocol that media items must conform to
public protocol MediaItem: Identifiable, Sendable {
    var id: UUID { get }
    var type: MediaType { get }

    /// Load the image content asynchronously
    func loadImage() async -> PlatformImage?

    /// Load the video URL (for video type only)
    func loadVideoURL() async -> URL?

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

    private let imageLoader: @Sendable () async -> PlatformImage?

    public init(id: UUID = UUID(), imageLoader: @escaping @Sendable () async -> PlatformImage?) {
        self.id = id
        self.imageLoader = imageLoader
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

    private let imageLoader: @Sendable () async -> PlatformImage?
    private let durationLoader: @Sendable () async -> TimeInterval?

    public init(id: UUID = UUID(),
                imageLoader: @escaping @Sendable () async -> PlatformImage?,
                durationLoader: @escaping @Sendable () async -> TimeInterval?) {
        self.id = id
        self.imageLoader = imageLoader
        self.durationLoader = durationLoader
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

    private let videoURLLoader: @Sendable () async -> URL?
    private let thumbnailLoader: (@Sendable () async -> PlatformImage?)?
    private let durationLoader: (@Sendable () async -> TimeInterval?)?

    public init(id: UUID = UUID(),
                videoURLLoader: @escaping @Sendable () async -> URL?,
                thumbnailLoader: (@Sendable () async -> PlatformImage?)? = nil,
                durationLoader: (@Sendable () async -> TimeInterval?)? = nil) {
        self.id = id
        self.videoURLLoader = videoURLLoader
        self.thumbnailLoader = thumbnailLoader
        self.durationLoader = durationLoader
    }

    public func loadImage() async -> PlatformImage? {
        await thumbnailLoader?()
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

        return await withCheckedContinuation { continuation in
            Task {
                let asset = AVAsset(url: url)
                do {
                    let duration = try await asset.load(.duration)
                    continuation.resume(returning: CMTimeGetSeconds(duration))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    public func getShareableItem() async -> Any? {
        await loadVideoURL()
    }

    public func getCaption() async -> String? {
        nil
    }

    public func hasAudioTrack() async -> Bool {
        guard let url = await loadVideoURL() else { return false }

        return await withCheckedContinuation { continuation in
            Task {
                let asset = AVAsset(url: url)
                do {
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    continuation.resume(returning: !tracks.isEmpty)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
