//
//  MediaDownloadManager.swift
//  MediaStream
//
//  Manages downloading and caching media files locally.
//  When MediaStreamConfiguration.encryptDownloads is true, files are stored encrypted
//  using the configured encryptionProvider, and background playback is not supported.
//  When encryption is off, files are stored unencrypted for AVPlayer background access.
//

import Foundation
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Progress information for download operations
public struct DownloadProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentItemName: String?
    public let bytesDownloaded: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    public var currentItemProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }
}

/// State of the download manager
public enum DownloadState: Equatable, Sendable {
    case idle
    case downloading(completed: Int, total: Int)
    case completed
    case cancelled
    case failed(String)

    public static func == (lhs: DownloadState, rhs: DownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.completed, .completed), (.cancelled, .cancelled):
            return true
        case (.downloading(let lhsC, let lhsT), .downloading(let rhsC, let rhsT)):
            return lhsC == rhsC && lhsT == rhsT
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

/// Singleton manager for downloading and caching media files locally.
/// When encryptDownloads is false (default): files stored unencrypted for AVPlayer background access.
/// When encryptDownloads is true: files stored encrypted with .enc extension; no background playback.
@MainActor
public final class MediaDownloadManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = MediaDownloadManager()

    // MARK: - Published Properties

    @Published public private(set) var downloadState: DownloadState = .idle
    @Published public private(set) var progress: DownloadProgress?

    // MARK: - Storage

    private let fileManager = FileManager.default

    /// The directory where downloaded media files are stored.
    /// Files are named `{cacheKey}.{ext}` or `{cacheKey}.{ext}.enc` when encrypted.
    public let downloadDirectory: URL

    /// Suffix appended to encrypted download files
    private static let encryptedSuffix = "enc"

    /// Active download task (cancellable)
    private var downloadTask: Task<Void, Never>?

    /// Temp files created for decrypted playback - cleaned up on next access or clearAllDownloads
    private var tempPlaybackFiles: [URL] = []

    /// URLSession for downloads
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600 // 10 minutes for large files
        return URLSession(configuration: config)
    }()

    // MARK: - Initialization

    private init() {
        // Use Caches directory for downloaded media
        // ~/Library/Caches/MediaStream/DownloadedMedia/
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        downloadDirectory = cachesDir
            .appendingPathComponent("MediaStream", isDirectory: true)
            .appendingPathComponent("DownloadedMedia", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Check if a media item is cached locally
    public func isCached(mediaItem: any MediaItem) -> Bool {
        guard let localURL = localURL(for: mediaItem) else { return false }
        return fileManager.fileExists(atPath: localURL.path)
    }

    /// Check if all items in a collection are cached
    public func allCached(_ items: [any MediaItem]) -> Bool {
        let cacheableItems = items.filter { canCache($0) }
        guard !cacheableItems.isEmpty else { return false }
        return cacheableItems.allSatisfy { isCached(mediaItem: $0) }
    }

    /// Check if any items in a collection are cached
    public func anyCached(_ items: [any MediaItem]) -> Bool {
        return items.contains { isCached(mediaItem: $0) }
    }

    /// Get count of cached items
    public func cachedCount(of items: [any MediaItem]) -> Int {
        return items.filter { isCached(mediaItem: $0) }.count
    }

    /// Get the local file URL for a cached media item.
    /// Returns a URL with `.enc` extension when encryptDownloads is true.
    /// Use `playbackURL(for:)` to get a URL usable by AVPlayer.
    public func localURL(for mediaItem: any MediaItem) -> URL? {
        guard let cacheKey = mediaItem.diskCacheKey else { return nil }

        let ext = fileExtension(for: mediaItem)
        if MediaStreamConfiguration.encryptDownloads {
            let filename = "\(cacheKey).\(ext).\(MediaDownloadManager.encryptedSuffix)"
            return downloadDirectory.appendingPathComponent(filename)
        } else {
            let filename = "\(cacheKey).\(ext)"
            return downloadDirectory.appendingPathComponent(filename)
        }
    }

    /// Get a URL suitable for AVPlayer playback.
    /// When encryptDownloads is true, decrypts the file to a temporary location.
    /// When encryptDownloads is false, returns the local URL directly.
    /// Returns nil if the file is not cached or decryption fails.
    public func playbackURL(for mediaItem: any MediaItem) async -> URL? {
        guard let fileURL = localURL(for: mediaItem) else { return nil }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        // Not encrypted — return directly
        guard MediaStreamConfiguration.encryptDownloads,
              let provider = MediaStreamConfiguration.encryptionProvider else {
            return fileURL
        }

        // Decrypt to a temp file for playback.
        // Run I/O and crypto on a background thread — both Data(contentsOf:) and
        // AES-GCM decryption are synchronous and can block for seconds on large
        // video files, which would freeze the UI if run on the main actor.
        let originalExt = fileURL.deletingPathExtension().pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms_play_\(UUID().uuidString)")
            .appendingPathExtension(originalExt)

        do {
            try await Task.detached(priority: .userInitiated) {
                let encryptedData = try Data(contentsOf: fileURL)
                let decryptedData = try provider.decrypt(encryptedData)
                try decryptedData.write(to: tempURL)
            }.value

            // Track temp file for cleanup (back on main actor)
            tempPlaybackFiles.append(tempURL)
            pruneOldTempFiles()

            print("[MediaDownloadManager] Decrypted to temp for playback: \(tempURL.lastPathComponent)")
            return tempURL
        } catch {
            print("[MediaDownloadManager] Failed to decrypt for playback: \(error)")
            return nil
        }
    }

    /// Check if a media item can be cached (has diskCacheKey and is video/audio)
    /// Note: sourceURL may be loaded asynchronously, so we only check diskCacheKey here
    public func canCache(_ mediaItem: any MediaItem) -> Bool {
        guard mediaItem.diskCacheKey != nil else { return false }
        // Only cache video and audio for local playback
        return mediaItem.type == .video || mediaItem.type == .audio
    }

    /// Download all media items that support caching
    public func downloadAll(
        _ items: [any MediaItem],
        headerProvider: @escaping @Sendable (URL) async -> [String: String]?
    ) async {
        // Don't start a new download if one is already in progress
        if case .downloading = downloadState {
            print("[MediaDownloadManager] Download already in progress, ignoring request")
            return
        }

        // Filter to only cacheable items that aren't already cached
        let itemsToDownload = items.filter { canCache($0) && !isCached(mediaItem: $0) }

        guard !itemsToDownload.isEmpty else {
            downloadState = .completed
            return
        }

        downloadState = .downloading(completed: 0, total: itemsToDownload.count)
        progress = DownloadProgress(
            completed: 0,
            total: itemsToDownload.count,
            currentItemName: nil,
            bytesDownloaded: 0,
            totalBytes: 0
        )

        // Create cancellable task
        downloadTask = Task {
            var completedCount = 0

            for item in itemsToDownload {
                // Check for cancellation
                if Task.isCancelled {
                    downloadState = .cancelled
                    progress = nil
                    return
                }

                // Get source URL - try sourceURL first, then load asynchronously
                let sourceURL: URL?
                if let directURL = item.sourceURL {
                    sourceURL = directURL
                } else if item.type == .video {
                    sourceURL = await item.loadVideoURL()
                } else if item.type == .audio {
                    sourceURL = await item.loadAudioURL()
                } else {
                    sourceURL = nil
                }

                guard let sourceURL = sourceURL else {
                    print("[MediaDownloadManager] No URL available for item: \(item.id)")
                    completedCount += 1
                    continue
                }

                // Update progress
                let itemName = sourceURL.lastPathComponent
                progress = DownloadProgress(
                    completed: completedCount,
                    total: itemsToDownload.count,
                    currentItemName: itemName,
                    bytesDownloaded: 0,
                    totalBytes: 0
                )

                // Download the file
                do {
                    try await downloadFile(
                        item: item,
                        sourceURL: sourceURL,
                        headerProvider: headerProvider,
                        progressUpdate: { [weak self] bytesDownloaded, totalBytes in
                            Task { @MainActor in
                                self?.progress = DownloadProgress(
                                    completed: completedCount,
                                    total: itemsToDownload.count,
                                    currentItemName: itemName,
                                    bytesDownloaded: bytesDownloaded,
                                    totalBytes: totalBytes
                                )
                            }
                        }
                    )
                    completedCount += 1
                    downloadState = .downloading(completed: completedCount, total: itemsToDownload.count)
                } catch {
                    if Task.isCancelled {
                        downloadState = .cancelled
                        progress = nil
                        return
                    }
                    print("[MediaDownloadManager] Failed to download \(itemName): \(error)")
                    completedCount += 1  // Continue with next item
                    downloadState = .downloading(completed: completedCount, total: itemsToDownload.count)
                }
            }

            // All done
            if !Task.isCancelled {
                downloadState = .completed
                progress = nil
            }
        }

        // Await the task
        await downloadTask?.value
    }

    /// Cancel any active download
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadState = .cancelled
        progress = nil
    }

    /// Clear all downloaded media files
    public func clearAllDownloads() {
        cancelDownload()
        cleanupTempPlaybackFiles()

        do {
            try fileManager.removeItem(at: downloadDirectory)
            try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            downloadState = .idle
            print("[MediaDownloadManager] Cleared all downloads")
        } catch {
            print("[MediaDownloadManager] Failed to clear downloads: \(error)")
        }
    }

    /// Clear downloads for specific items
    public func clearDownloads(for items: [any MediaItem]) {
        for item in items {
            if let localURL = localURL(for: item) {
                try? fileManager.removeItem(at: localURL)
            }
        }

        // If no downloads remain, reset state
        if let contents = try? fileManager.contentsOfDirectory(at: downloadDirectory, includingPropertiesForKeys: nil),
           contents.isEmpty {
            downloadState = .idle
        }
    }

    /// Migrate existing downloaded files when the encryptDownloads setting changes.
    /// When enabling encryption: encrypts all plain files and renames with .enc extension.
    /// When disabling encryption: decrypts all .enc files and removes the extension.
    /// - Parameter encrypt: true to encrypt existing plain files, false to decrypt .enc files
    public func migrateEncryption(encrypt: Bool) async {
        guard let provider = MediaStreamConfiguration.encryptionProvider else {
            print("[MediaDownloadManager] Cannot migrate: no encryptionProvider configured")
            return
        }

        print("[MediaDownloadManager] Starting download migration — encrypt: \(encrypt)")
        var migratedCount = 0
        var failedCount = 0

        guard let enumerator = fileManager.enumerator(
            at: downloadDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        // Collect URLs first to avoid mutating directory while enumerating
        var fileURLs: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            fileURLs.append(fileURL)
        }

        for fileURL in fileURLs {
            let isEncrypted = fileURL.pathExtension.lowercased() == MediaDownloadManager.encryptedSuffix

            if encrypt && !isEncrypted {
                // Encrypt plain file: read → encrypt → write .enc → remove original
                do {
                    let rawData = try Data(contentsOf: fileURL)
                    let encryptedData = try provider.encrypt(rawData)
                    let destURL = fileURL.appendingPathExtension(MediaDownloadManager.encryptedSuffix)
                    try encryptedData.write(to: destURL, options: .atomic)
                    try fileManager.removeItem(at: fileURL)
                    migratedCount += 1
                } catch {
                    print("[MediaDownloadManager] Failed to encrypt \(fileURL.lastPathComponent): \(error)")
                    failedCount += 1
                }
            } else if !encrypt && isEncrypted {
                // Decrypt .enc file: read → decrypt → write without .enc → remove original
                do {
                    let encryptedData = try Data(contentsOf: fileURL)
                    let decryptedData = try provider.decrypt(encryptedData)
                    let destURL = fileURL.deletingPathExtension() // removes .enc
                    try decryptedData.write(to: destURL, options: .atomic)
                    try fileManager.removeItem(at: fileURL)
                    migratedCount += 1
                } catch {
                    print("[MediaDownloadManager] Failed to decrypt \(fileURL.lastPathComponent): \(error)")
                    failedCount += 1
                }
            }
        }

        print("[MediaDownloadManager] Migration complete: \(migratedCount) files migrated, \(failedCount) failed")
    }

    /// Remove temp decryption files created for playback
    public func cleanupTempPlaybackFiles() {
        for url in tempPlaybackFiles {
            try? fileManager.removeItem(at: url)
        }
        tempPlaybackFiles.removeAll()
    }

    /// Delete all encrypted download files (.enc). Used when the passphrase is
    /// removed or changed — the files can no longer be decrypted, so they are
    /// discarded. Downloads will be re-fetched on demand.
    public func clearEncryptedDownloads() {
        guard let enumerator = fileManager.enumerator(
            at: downloadDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.pathExtension == MediaDownloadManager.encryptedSuffix {
                try? fileManager.removeItem(at: fileURL)
                count += 1
            }
        }
        print("[MediaDownloadManager] Cleared \(count) encrypted download files")
    }

    /// Get current cache statistics
    public var stats: (fileCount: Int, diskMB: Double) {
        var totalSize: Int64 = 0
        var fileCount = 0

        if let enumerator = fileManager.enumerator(
            at: downloadDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            while let fileURL = enumerator.nextObject() as? URL {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                    fileCount += 1
                }
            }
        }

        return (fileCount, Double(totalSize) / 1024.0 / 1024.0)
    }

    // MARK: - Private Helpers

    /// Download a single file, encrypting it if encryptDownloads is true
    private func downloadFile(
        item: any MediaItem,
        sourceURL: URL,
        headerProvider: @escaping @Sendable (URL) async -> [String: String]?,
        progressUpdate: @escaping (Int64, Int64) -> Void
    ) async throws {
        guard let destinationURL = localURL(for: item) else {
            throw DownloadError.invalidDestination
        }

        // Skip if already exists
        if fileManager.fileExists(atPath: destinationURL.path) {
            return
        }

        // Local file:// URLs — read directly instead of going through URLSession.
        // This covers AI-generated videos that already live on disk, including private
        // videos that were decrypted to a temp location by loadVideoURL().
        if sourceURL.isFileURL {
            if MediaStreamConfiguration.encryptDownloads,
               let provider = MediaStreamConfiguration.encryptionProvider {
                let encryptedData = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                    let rawData = try Data(contentsOf: sourceURL)
                    return try provider.encrypt(rawData)
                }.value
                try encryptedData.write(to: destinationURL, options: .atomic)
                print("[MediaDownloadManager] Copied and encrypted local file: \(destinationURL.lastPathComponent)")
            } else {
                try await Task.detached(priority: .userInitiated) {
                    let rawData = try Data(contentsOf: sourceURL)
                    try rawData.write(to: destinationURL, options: .atomic)
                }.value
                print("[MediaDownloadManager] Copied local file: \(destinationURL.lastPathComponent)")
            }
            return
        }

        // Get headers for authenticated requests
        let headers = await headerProvider(sourceURL)

        var request = URLRequest(url: sourceURL)
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Download with progress tracking
        let (tempURL, response) = try await urlSession.download(for: request)

        // Check response
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw DownloadError.httpError(httpResponse.statusCode)
            }
        }

        // Encrypt if needed, then move to final destination
        try? fileManager.removeItem(at: destinationURL)

        if MediaStreamConfiguration.encryptDownloads,
           let provider = MediaStreamConfiguration.encryptionProvider {
            // Read downloaded data, encrypt it, write encrypted file — off main thread
            let encryptedData = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                let rawData = try Data(contentsOf: tempURL)
                return try provider.encrypt(rawData)
            }.value
            try? fileManager.removeItem(at: tempURL)
            try encryptedData.write(to: destinationURL, options: .atomic)
            print("[MediaDownloadManager] Downloaded and encrypted: \(destinationURL.lastPathComponent)")
        } else {
            // Store unencrypted
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            print("[MediaDownloadManager] Downloaded: \(destinationURL.lastPathComponent)")
        }
    }

    /// Get file extension for a media item
    private func fileExtension(for mediaItem: any MediaItem) -> String {
        // Try to get extension from sourceURL
        if let sourceURL = mediaItem.sourceURL {
            let ext = sourceURL.pathExtension.lowercased()
            if !ext.isEmpty {
                return ext
            }
        }

        // Fallback based on media type
        switch mediaItem.type {
        case .video:
            return "mp4"
        case .audio:
            return "mp3"
        case .image:
            return "jpg"
        case .animatedImage:
            return "gif"
        }
    }

    /// Keep only the most recent N temp playback files to avoid unbounded growth
    private func pruneOldTempFiles(keepLast: Int = 3) {
        guard tempPlaybackFiles.count > keepLast else { return }
        let toRemove = tempPlaybackFiles.dropLast(keepLast)
        for url in toRemove {
            try? fileManager.removeItem(at: url)
        }
        tempPlaybackFiles = Array(tempPlaybackFiles.suffix(keepLast))
    }
}

// MARK: - Errors

enum DownloadError: Error, LocalizedError {
    case invalidDestination
    case httpError(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "Invalid download destination"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .cancelled:
            return "Download cancelled"
        }
    }
}
