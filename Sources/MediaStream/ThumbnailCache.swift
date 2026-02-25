import Foundation
import SwiftUI
import AVFoundation
import CryptoKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Disk Cache for Thumbnails and Metadata

/// Metadata that can be cached to disk for media items
public struct CachedMediaMetadata: Codable {
    public var videoDuration: TimeInterval?
    public var animatedImageDuration: TimeInterval?
    public var hasAudio: Bool?
    public var mediaType: String?
    public var width: Int?
    public var height: Int?
    public var lastAccessed: Date

    public init(
        videoDuration: TimeInterval? = nil,
        animatedImageDuration: TimeInterval? = nil,
        hasAudio: Bool? = nil,
        mediaType: String? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.videoDuration = videoDuration
        self.animatedImageDuration = animatedImageDuration
        self.hasAudio = hasAudio
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.lastAccessed = Date()
    }
}

/// Public helper to clear all MediaStream caches (memory + disk)
public enum MediaStreamCache {
    /// Clear all cached thumbnails, metadata, and downloaded media (memory + disk)
    @MainActor
    public static func clearAll() {
        ThumbnailCache.shared.clear()
        DiskThumbnailCache.shared.clearAll()
        MediaDownloadManager.shared.clearAllDownloads()
    }

    /// Get cache statistics
    public static var stats: (memoryMB: Double, diskMB: Double, thumbnailCount: Int) {
        let memoryStats = ThumbnailCache.shared.stats
        let diskStats = DiskThumbnailCache.shared.stats
        return (memoryStats.memoryMB, diskStats.diskMB, memoryStats.count + diskStats.thumbnailCount)
    }
}

/// Disk-based thumbnail and metadata cache
public final class DiskThumbnailCache: @unchecked Sendable {
    public static let shared = DiskThumbnailCache()

    private let fileManager = FileManager.default
    private let thumbnailDirectory: URL
    private let metadataDirectory: URL
    private let lock = NSLock()

    /// Maximum disk cache size in bytes (default: 500MB)
    private let maxDiskBytes: Int

    /// JPEG compression quality for thumbnails (0.0 - 1.0)
    private let compressionQuality: CGFloat = 0.8

    public init(maxDiskMB: Int = 500) {
        self.maxDiskBytes = maxDiskMB * 1024 * 1024

        // Use Caches directory for thumbnails (can be purged by system)
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let mediaStreamCacheDir = cachesDir.appendingPathComponent("MediaStream", isDirectory: true)

        self.thumbnailDirectory = mediaStreamCacheDir.appendingPathComponent("Thumbnails", isDirectory: true)
        self.metadataDirectory = mediaStreamCacheDir.appendingPathComponent("Metadata", isDirectory: true)

        // Create directories if they don't exist
        try? fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Cache Key Generation

    /// Generate a stable cache key from a URL (for remote files)
    public func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Generate a stable cache key from a file path and modification date
    public func cacheKey(for path: String, modificationDate: Date?) -> String {
        var input = path
        if let date = modificationDate {
            input += "_\(date.timeIntervalSince1970)"
        }
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache Directories (for re-encryption)

    /// Get the cache directories for re-encryption purposes
    public var cacheDirectories: [URL] {
        [thumbnailDirectory, metadataDirectory]
    }

    // MARK: - Thumbnail Operations

    /// Get thumbnail file path for a cache key (uses .enc extension when encryption is enabled)
    private func thumbnailPath(for key: String, encrypted: Bool? = nil) -> URL {
        let useEncryption = encrypted ?? (MediaStreamConfiguration.encryptionProvider != nil)
        let ext = useEncryption ? "jpg.enc" : "jpg"
        return thumbnailDirectory.appendingPathComponent("\(key).\(ext)")
    }

    /// Get metadata file path for a cache key (uses .enc extension when encryption is enabled)
    private func metadataPath(for key: String, encrypted: Bool? = nil) -> URL {
        let useEncryption = encrypted ?? (MediaStreamConfiguration.encryptionProvider != nil)
        let ext = useEncryption ? "json.enc" : "json"
        return metadataDirectory.appendingPathComponent("\(key).\(ext)")
    }

    /// Check if a thumbnail exists on disk (checks both encrypted and unencrypted)
    public func hasThumbnail(for key: String) -> Bool {
        fileManager.fileExists(atPath: thumbnailPath(for: key, encrypted: true).path) ||
        fileManager.fileExists(atPath: thumbnailPath(for: key, encrypted: false).path)
    }

    /// Load a thumbnail from disk (handles both encrypted and unencrypted)
    public func loadThumbnail(for key: String) -> PlatformImage? {
        // Try encrypted first if provider is available
        let encryptedPath = thumbnailPath(for: key, encrypted: true)
        let unencryptedPath = thumbnailPath(for: key, encrypted: false)

        var data: Data?
        var usedPath: URL?

        if let provider = MediaStreamConfiguration.encryptionProvider,
           fileManager.fileExists(atPath: encryptedPath.path),
           let encryptedData = try? Data(contentsOf: encryptedPath) {
            // Decrypt the data
            data = try? provider.decrypt(encryptedData)
            usedPath = encryptedPath
        } else if fileManager.fileExists(atPath: unencryptedPath.path),
                  let rawData = try? Data(contentsOf: unencryptedPath) {
            // Use unencrypted data
            data = rawData
            usedPath = unencryptedPath
        }

        guard let imageData = data, let path = usedPath else {
            return nil
        }

        // Update access time for LRU
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)

        #if canImport(UIKit)
        return UIImage(data: imageData)
        #elseif canImport(AppKit)
        return NSImage(data: imageData)
        #endif
    }

    /// Save a thumbnail to disk (encrypts if provider is configured, skips animated images)
    public func saveThumbnail(_ image: PlatformImage, for key: String, isAnimated: Bool = false) {
        // Don't cache animated images - they would lose animation data
        guard !isAnimated else { return }

        #if canImport(UIKit)
        // Skip if this is an animated UIImage
        if image.images != nil { return }
        guard var data = image.jpegData(compressionQuality: compressionQuality) else { return }
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard var data = rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) else {
            return
        }
        #endif

        // Encrypt if provider is available
        let useEncryption = MediaStreamConfiguration.encryptionProvider != nil
        if let provider = MediaStreamConfiguration.encryptionProvider {
            do {
                data = try provider.encrypt(data)
            } catch {
                return // Don't save unencrypted if encryption is expected
            }
        }

        let path = thumbnailPath(for: key, encrypted: useEncryption)

        do {
            try data.write(to: path, options: .atomic)

            // Remove old unencrypted version if we just wrote encrypted
            if useEncryption {
                let oldPath = thumbnailPath(for: key, encrypted: false)
                try? fileManager.removeItem(at: oldPath)
            }
        } catch {
        }
    }

    // MARK: - Metadata Operations

    /// Check if metadata exists on disk (checks both encrypted and unencrypted)
    public func hasMetadata(for key: String) -> Bool {
        fileManager.fileExists(atPath: metadataPath(for: key, encrypted: true).path) ||
        fileManager.fileExists(atPath: metadataPath(for: key, encrypted: false).path)
    }

    /// Load metadata from disk (handles both encrypted and unencrypted)
    public func loadMetadata(for key: String) -> CachedMediaMetadata? {
        let encryptedPath = metadataPath(for: key, encrypted: true)
        let unencryptedPath = metadataPath(for: key, encrypted: false)

        var data: Data?
        var usedPath: URL?

        if let provider = MediaStreamConfiguration.encryptionProvider,
           fileManager.fileExists(atPath: encryptedPath.path),
           let encryptedData = try? Data(contentsOf: encryptedPath) {
            // Decrypt the data
            data = try? provider.decrypt(encryptedData)
            usedPath = encryptedPath
        } else if fileManager.fileExists(atPath: unencryptedPath.path),
                  let rawData = try? Data(contentsOf: unencryptedPath) {
            // Use unencrypted data
            data = rawData
            usedPath = unencryptedPath
        }

        guard let jsonData = data, let path = usedPath else {
            return nil
        }

        // Update access time for LRU
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)

        return try? JSONDecoder().decode(CachedMediaMetadata.self, from: jsonData)
    }

    /// Save metadata to disk (encrypts if provider is configured)
    public func saveMetadata(_ metadata: CachedMediaMetadata, for key: String) {
        guard var data = try? JSONEncoder().encode(metadata) else { return }

        // Encrypt if provider is available
        let useEncryption = MediaStreamConfiguration.encryptionProvider != nil
        if let provider = MediaStreamConfiguration.encryptionProvider {
            do {
                data = try provider.encrypt(data)
            } catch {
                return // Don't save unencrypted if encryption is expected
            }
        }

        let path = metadataPath(for: key, encrypted: useEncryption)

        do {
            try data.write(to: path, options: .atomic)

            // Remove old unencrypted version if we just wrote encrypted
            if useEncryption {
                let oldPath = metadataPath(for: key, encrypted: false)
                try? fileManager.removeItem(at: oldPath)
            }
        } catch {
        }
    }

    // MARK: - Cache Management

    /// Get total disk cache size in bytes
    public func currentDiskUsage() -> Int {
        var totalSize = 0

        let enumerator = fileManager.enumerator(
            at: thumbnailDirectory.deletingLastPathComponent(),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += size
            }
        }

        return totalSize
    }

    /// Evict oldest files until under the max disk size
    public func evictIfNeeded() {
        let currentSize = currentDiskUsage()
        guard currentSize > maxDiskBytes else { return }

        lock.lock()
        defer { lock.unlock() }

        let targetSize = maxDiskBytes / 2  // Evict to 50% capacity

        // Collect all cache files with their modification dates
        var files: [(url: URL, date: Date, size: Int)] = []

        for directory in [thumbnailDirectory, metadataDirectory] {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let fileURL = enumerator.nextObject() as? URL {
                guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = values.contentModificationDate,
                      let size = values.fileSize else { continue }
                files.append((fileURL, date, size))
            }
        }

        // Sort by date (oldest first)
        files.sort { $0.date < $1.date }

        // Delete oldest files until we're under target
        var totalSize = currentSize
        for file in files {
            guard totalSize > targetSize else { break }
            try? fileManager.removeItem(at: file.url)
            totalSize -= file.size
        }

    }

    /// Clear all cached data
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        try? fileManager.removeItem(at: thumbnailDirectory)
        try? fileManager.removeItem(at: metadataDirectory)

        // Recreate directories
        try? fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)

    }

    /// Get cache statistics
    public var stats: (thumbnailCount: Int, metadataCount: Int, diskMB: Double) {
        let thumbnailCount = (try? fileManager.contentsOfDirectory(at: thumbnailDirectory, includingPropertiesForKeys: nil).count) ?? 0
        let metadataCount = (try? fileManager.contentsOfDirectory(at: metadataDirectory, includingPropertiesForKeys: nil).count) ?? 0
        let diskBytes = currentDiskUsage()
        return (thumbnailCount, metadataCount, Double(diskBytes) / 1024.0 / 1024.0)
    }
}

/// Actor to limit concurrent thumbnail loading operations
public actor ThumbnailLoadingQueue {
    public static let shared = ThumbnailLoadingQueue(maxConcurrent: 4)

    private let maxConcurrent: Int
    private var currentCount: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    /// Acquire a slot for thumbnail loading (waits if at max capacity)
    public func acquire() async {
        if currentCount < maxConcurrent {
            currentCount += 1
            return
        }

        // Wait in queue - count will be incremented when resumed
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Release a slot when thumbnail loading is done
    public func release() {
        currentCount -= 1

        // Wake up next waiter if any
        if !waiters.isEmpty && currentCount < maxConcurrent {
            currentCount += 1  // Pre-increment for the waiter we're about to resume
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    /// Execute a thumbnail loading operation with concurrency limiting
    public func withLimit<T>(_ operation: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await operation()
        await release()
        return result
    }
}

/// Thread-safe LRU cache for thumbnails with memory limit and pressure handling
public final class ThumbnailCache: @unchecked Sendable {
    #if os(iOS) || os(tvOS)
    // Lower memory limit on iOS/tvOS to prevent OOM
    public static let shared = ThumbnailCache(maxMemoryMB: 50)
    #else
    public static let shared = ThumbnailCache(maxMemoryMB: 100)
    #endif

    /// Maximum memory limit in bytes
    private let maxMemoryBytes: Int

    /// Thumbnail size for grid display
    public static let thumbnailSize: CGFloat = 200

    /// Current estimated memory usage
    private var currentMemoryBytes: Int = 0

    /// Cache storage with access time tracking
    private var cache: [UUID: CacheEntry] = [:]

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Memory pressure observer
    #if canImport(UIKit)
    private var memoryWarningObserver: NSObjectProtocol?
    #endif

    private struct CacheEntry {
        let image: PlatformImage
        let sizeBytes: Int
        var lastAccess: Date
    }

    public init(maxMemoryMB: Int = 100) {
        self.maxMemoryBytes = maxMemoryMB * 1024 * 1024
        setupMemoryPressureHandling()
    }

    deinit {
        #if canImport(UIKit)
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    private func setupMemoryPressureHandling() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryPressure()
        }
        #endif
    }

    /// Handle memory pressure by evicting half the cache
    public func handleMemoryPressure() {
        lock.lock()
        defer { lock.unlock() }

        let targetBytes = maxMemoryBytes / 2
        evictToSize(targetBytes)
    }

    /// Get a cached thumbnail, or nil if not cached
    public func get(_ id: UUID) -> PlatformImage? {
        lock.lock()
        defer { lock.unlock() }

        guard var entry = cache[id] else { return nil }
        entry.lastAccess = Date()
        cache[id] = entry
        return entry.image
    }

    /// Store a thumbnail in the cache
    public func set(_ id: UUID, image: PlatformImage) {
        let sizeBytes = estimateImageSize(image)

        lock.lock()
        defer { lock.unlock() }

        // Remove existing entry if present
        if let existing = cache[id] {
            currentMemoryBytes -= existing.sizeBytes
        }

        // Evict if necessary to make room
        let targetSize = maxMemoryBytes - sizeBytes
        if currentMemoryBytes > targetSize {
            evictToSize(targetSize)
        }

        // Store the new entry
        cache[id] = CacheEntry(
            image: image,
            sizeBytes: sizeBytes,
            lastAccess: Date()
        )
        currentMemoryBytes += sizeBytes
    }

    /// Check if an item is cached
    public func contains(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[id] != nil
    }

    /// Clear the entire cache
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        currentMemoryBytes = 0
    }

    // MARK: - Disk Cache Integration

    /// Get a cached thumbnail, checking disk cache if not in memory
    /// - Parameters:
    ///   - id: The media item UUID
    ///   - diskCacheKey: Optional disk cache key for persistent storage
    /// - Returns: The cached thumbnail image or nil
    public func get(_ id: UUID, diskCacheKey: String?) -> PlatformImage? {
        // First check memory cache
        if let image = get(id) {
            return image
        }

        // If not in memory, check disk cache
        guard let key = diskCacheKey,
              let diskImage = DiskThumbnailCache.shared.loadThumbnail(for: key) else {
            return nil
        }

        // Promote to memory cache
        set(id, image: diskImage)
        return diskImage
    }

    /// Store a thumbnail in both memory and disk caches
    /// - Parameters:
    ///   - id: The media item UUID
    ///   - image: The thumbnail image to cache
    ///   - diskCacheKey: Optional disk cache key for persistent storage
    public func set(_ id: UUID, image: PlatformImage, diskCacheKey: String?) {
        // Store in memory cache
        set(id, image: image)

        // Also store to disk cache if key provided
        if let key = diskCacheKey {
            Task.detached(priority: .utility) {
                DiskThumbnailCache.shared.saveThumbnail(image, for: key)
            }
        }
    }

    /// Check if a thumbnail is cached (memory or disk)
    public func contains(_ id: UUID, diskCacheKey: String?) -> Bool {
        if contains(id) {
            return true
        }
        guard let key = diskCacheKey else { return false }
        return DiskThumbnailCache.shared.hasThumbnail(for: key)
    }

    /// Get current cache statistics
    public var stats: (count: Int, memoryMB: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (cache.count, Double(currentMemoryBytes) / 1024.0 / 1024.0)
    }

    /// Evict least recently used entries until we're under the target size
    private func evictToSize(_ targetBytes: Int) {
        // Sort by last access time (oldest first)
        let sortedEntries = cache.sorted { $0.value.lastAccess < $1.value.lastAccess }

        for (id, entry) in sortedEntries {
            if currentMemoryBytes <= targetBytes { break }
            cache.removeValue(forKey: id)
            currentMemoryBytes -= entry.sizeBytes
        }
    }

    /// Estimate image memory size in bytes
    private func estimateImageSize(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else {
            return Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
        }
        return cgImage.bytesPerRow * cgImage.height
        #elseif canImport(AppKit)
        let size = image.size
        return Int(size.width * size.height * 4)
        #endif
    }
}

// MARK: - Thumbnail Generation

extension ThumbnailCache {
    /// Generate a downsampled thumbnail from an image
    public static func createThumbnail(from image: PlatformImage, targetSize: CGFloat = thumbnailSize) -> PlatformImage {
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        let pixelSize = targetSize * scale

        // Calculate aspect-fit size
        let imageSize = image.size
        let aspectRatio = imageSize.width / imageSize.height

        let thumbnailSize: CGSize
        if aspectRatio > 1 {
            // Landscape
            thumbnailSize = CGSize(width: pixelSize, height: pixelSize / aspectRatio)
        } else {
            // Portrait or square
            thumbnailSize = CGSize(width: pixelSize * aspectRatio, height: pixelSize)
        }

        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        }
        #elseif canImport(AppKit)
        let imageSize = image.size
        let aspectRatio = imageSize.width / imageSize.height

        let thumbnailSize: NSSize
        if aspectRatio > 1 {
            thumbnailSize = NSSize(width: targetSize, height: targetSize / aspectRatio)
        } else {
            thumbnailSize = NSSize(width: targetSize * aspectRatio, height: targetSize)
        }

        let newImage = NSImage(size: thumbnailSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                   from: NSRect(origin: .zero, size: imageSize),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
        #endif
    }

    /// Load and downsample an image from data for use as a thumbnail
    public static func createThumbnail(from data: Data, targetSize: CGFloat = thumbnailSize) -> PlatformImage? {
        // Use ImageIO for efficient downsampling without loading full image into memory
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        return createThumbnail(from: imageSource, targetSize: targetSize)
    }

    /// Load and downsample an image from URL for use as a thumbnail
    public static func createThumbnail(from url: URL, targetSize: CGFloat = thumbnailSize) -> PlatformImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        return createThumbnail(from: imageSource, targetSize: targetSize)
    }

    /// Create a thumbnail from CGImageSource using ImageIO (memory efficient)
    private static func createThumbnail(from imageSource: CGImageSource, targetSize: CGFloat) -> PlatformImage? {
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        let pixelSize = targetSize * scale
        #else
        let pixelSize = targetSize * 2.0 // Assume 2x for macOS
        #endif

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        #if canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// Generate a thumbnail from a video URL (supports both local file:// and remote http:// URLs)
    /// Uses WebView HTML5 video for thumbnail generation (WebM support), falls back to AVFoundation
    /// - Parameters:
    ///   - videoURL: The URL of the video (local or remote)
    ///   - targetSize: The target size for the thumbnail
    ///   - time: The time in the video to capture (default: beginning)
    /// - Returns: A thumbnail image or nil if generation fails
    public static func createVideoThumbnail(
        from videoURL: URL,
        targetSize: CGFloat = thumbnailSize,
        at time: CMTime = .zero
    ) async -> PlatformImage? {
        // Get headers from MediaStreamConfiguration if available
        let headers = await MediaStreamConfiguration.headersAsync(for: videoURL)

        // Try AVFoundation first for MP4 and other common formats
        if let avThumbnail = await createVideoThumbnailWithAVFoundation(from: videoURL, targetSize: targetSize, at: time, headers: headers) {
            return avThumbnail
        }

        // Fall back to WebView HTML5 video for WebM and other formats
        if let webViewThumbnail = await createVideoThumbnailWithWebView(from: videoURL, targetSize: targetSize, headers: headers) {
            return webViewThumbnail
        }

        // Return a placeholder if both fail
        return createVideoPlaceholder(targetSize: targetSize)
    }

    /// Generate a thumbnail using AVFoundation (fallback)
    private static func createVideoThumbnailWithAVFoundation(
        from videoURL: URL,
        targetSize: CGFloat,
        at time: CMTime,
        headers: [String: String]?
    ) async -> PlatformImage? {
        let asset: AVURLAsset
        if let headers = headers, !headers.isEmpty {
            asset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: videoURL)
        }

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        let pixelSize = targetSize * scale
        #else
        let pixelSize = targetSize * 2.0
        #endif

        imageGenerator.maximumSize = CGSize(width: pixelSize, height: pixelSize)

        do {
            let cgImage = try await imageGenerator.image(at: time).image

            #if canImport(UIKit)
            let fullImage = UIImage(cgImage: cgImage)
            #elseif canImport(AppKit)
            let fullImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            #endif

            return createThumbnail(from: fullImage, targetSize: targetSize)
        } catch {
            return nil
        }
    }

    /// Generate a thumbnail from a video URL using WKWebView HTML5 video (for WebM and other formats)
    /// Uses canvas snapshot for thumbnail extraction
    public static func createVideoThumbnailWithWebView(
        from videoURL: URL,
        targetSize: CGFloat = thumbnailSize,
        headers: [String: String]? = nil
    ) async -> PlatformImage? {
        #if canImport(WebKit)
        return await WebViewVideoController.generateThumbnail(from: videoURL, targetSize: targetSize, headers: headers)
        #else
        return nil
        #endif
    }

    /// Creates a placeholder thumbnail for audio files without cover artwork
    public static func createAudioPlaceholder(targetSize: CGFloat) -> PlatformImage? {
        #if canImport(UIKit)
        let size = CGSize(width: targetSize, height: targetSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            // Neutral gray background
            UIColor.gray.withAlphaComponent(0.3).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Draw music note icon in gray
            let iconSize: CGFloat = targetSize * 0.4
            let iconRect = CGRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )

            if let musicIcon = UIImage(systemName: "music.note") {
                musicIcon.withTintColor(.gray, renderingMode: .alwaysOriginal)
                    .draw(in: iconRect)
            }
        }
        #elseif canImport(AppKit)
        let size = NSSize(width: targetSize, height: targetSize)
        let image = NSImage(size: size)
        image.lockFocus()

        // Neutral gray background
        NSColor.gray.withAlphaComponent(0.3).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw music note icon in gray
        if let musicIcon = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Audio") {
            let iconSize: CGFloat = targetSize * 0.4
            let iconRect = NSRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            NSColor.gray.set()
            musicIcon.draw(in: iconRect)
        }

        image.unlockFocus()
        return image
        #endif
    }

    /// Creates a placeholder thumbnail for videos that can't generate thumbnails (e.g., WebM)
    public static func createVideoPlaceholder(targetSize: CGFloat) -> PlatformImage? {
        #if canImport(UIKit)
        let size = CGSize(width: targetSize, height: targetSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            // Dark background
            #if os(tvOS)
            UIColor.darkGray.setFill()
            #else
            UIColor.systemGray5.setFill()
            #endif
            context.fill(CGRect(origin: .zero, size: size))

            // Draw play icon
            let iconSize: CGFloat = targetSize * 0.4
            let iconRect = CGRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )

            if let playIcon = UIImage(systemName: "play.circle.fill") {
                UIColor.systemGray.setFill()
                playIcon.withTintColor(.systemGray, renderingMode: .alwaysOriginal)
                    .draw(in: iconRect)
            }
        }
        #elseif canImport(AppKit)
        let size = NSSize(width: targetSize, height: targetSize)
        let image = NSImage(size: size)
        image.lockFocus()

        // Dark background
        NSColor.systemGray.withAlphaComponent(0.3).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw play icon
        if let playIcon = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil) {
            let iconSize: CGFloat = targetSize * 0.4
            let iconRect = NSRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            playIcon.draw(in: iconRect)
        }

        image.unlockFocus()
        return image
        #endif
    }

    /// Generate a thumbnail from a video URL synchronously (for use in non-async contexts)
    /// Note: This is a blocking call - prefer the async version when possible
    /// - Parameters:
    ///   - videoURL: The URL of the video (local or remote)
    ///   - targetSize: The target size for the thumbnail
    ///   - time: The time in the video to capture (default: beginning)
    /// - Returns: A thumbnail image or nil if generation fails
    @MainActor
    public static func createVideoThumbnailSync(from videoURL: URL, targetSize: CGFloat = thumbnailSize, at time: CMTime = .zero) -> PlatformImage? {
        // Use AVFoundation for synchronous thumbnail generation
        let headers = MediaStreamConfiguration.headers(for: videoURL)
        let asset: AVURLAsset
        if let headers = headers, !headers.isEmpty {
            asset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: videoURL)
        }

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        let pixelSize = targetSize * scale
        #else
        let pixelSize = targetSize * 2.0
        #endif

        imageGenerator.maximumSize = CGSize(width: pixelSize, height: pixelSize)

        do {
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)

            #if canImport(UIKit)
            let fullImage = UIImage(cgImage: cgImage)
            #elseif canImport(AppKit)
            let fullImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            #endif

            return createThumbnail(from: fullImage, targetSize: targetSize)
        } catch {
            return createVideoPlaceholder(targetSize: targetSize)
        }
    }
}
