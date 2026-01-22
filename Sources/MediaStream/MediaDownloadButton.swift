//
//  MediaDownloadButton.swift
//  MediaStream
//
//  A button that shows download state for media items:
//  - Download icon: No items cached, tap to start download
//  - Progress ring + stop: Downloading in progress, tap to cancel
//  - Clear/X icon: All cached, tap to clear with confirmation
//

import SwiftUI

/// A button that manages downloading and clearing cached media files.
/// Shows three states: not cached, downloading, cached.
public struct MediaDownloadButton: View {
    let mediaItems: [any MediaItem]
    let headerProvider: @Sendable (URL) async -> [String: String]?

    @ObservedObject private var downloadManager = MediaDownloadManager.shared
    @State private var showClearConfirmation = false

    /// Initialize with media items and a header provider for authentication
    public init(
        mediaItems: [any MediaItem],
        headerProvider: @escaping @Sendable (URL) async -> [String: String]?
    ) {
        self.mediaItems = mediaItems
        self.headerProvider = headerProvider
    }

    /// Current cache state derived from download manager
    private var cacheState: CacheState {
        switch downloadManager.downloadState {
        case .downloading:
            return .downloading
        default:
            // Check actual cache status
            if downloadManager.allCached(mediaItems) {
                return .cached
            } else if downloadManager.anyCached(mediaItems) {
                return .partiallyCached
            } else {
                return .notCached
            }
        }
    }

    private enum CacheState {
        case notCached
        case partiallyCached
        case downloading
        case cached
    }

    public var body: some View {
        Button(action: handleTap) {
            Group {
                switch cacheState {
                case .notCached:
                    // Download icon
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                case .partiallyCached:
                    // Partial download icon (shows some are cached)
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)

                case .downloading:
                    // Progress ring with stop button
                    ZStack {
                        // Background ring
                        Circle()
                            .stroke(Color.primary.opacity(0.3), lineWidth: 2)
                            .frame(width: 24, height: 24)

                        // Progress ring
                        Circle()
                            .trim(from: 0, to: progressFraction)
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 24, height: 24)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.1), value: progressFraction)

                        // Stop icon
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.primary)
                    }

                case .cached:
                    // Checkmark shows cached, tap to clear
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.green)
                }
            }
            .frame(width: 36, height: 36)
            .mediaStreamGlassBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .confirmationDialog(
            mediaItems.count == 1 ? "Clear Downloaded File" : "Clear Downloaded Media",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(mediaItems.count == 1 ? "Clear Download" : "Clear All Downloads", role: .destructive) {
                downloadManager.clearDownloads(for: mediaItems)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if mediaItems.count == 1 {
                Text("This will remove the cached file for this item")
            } else {
                let stats = downloadManager.stats
                Text("This will remove \(stats.fileCount) cached files (\(String(format: "%.1f", stats.diskMB)) MB)")
            }
        }
    }

    /// Progress fraction for the ring (0.0 to 1.0)
    private var progressFraction: CGFloat {
        guard let progress = downloadManager.progress else { return 0 }
        // Combine item progress with current file progress
        let itemProgress = progress.fractionCompleted
        let currentProgress = progress.currentItemProgress
        // Weight: 90% from completed items, 10% from current item
        return CGFloat(itemProgress * 0.9 + currentProgress * 0.1)
    }

    /// Handle button tap based on current state
    private func handleTap() {
        switch cacheState {
        case .notCached, .partiallyCached:
            // Start downloading
            Task {
                await downloadManager.downloadAll(mediaItems, headerProvider: headerProvider)
            }

        case .downloading:
            // Cancel download
            downloadManager.cancelDownload()

        case .cached:
            // Show confirmation before clearing
            showClearConfirmation = true
        }
    }

    /// Accessibility label for VoiceOver
    private var accessibilityLabel: String {
        switch cacheState {
        case .notCached:
            let count = mediaItems.filter { downloadManager.canCache($0) }.count
            return "Download \(count) media files for offline playback"
        case .partiallyCached:
            let cached = downloadManager.cachedCount(of: mediaItems)
            let total = mediaItems.filter { downloadManager.canCache($0) }.count
            return "\(cached) of \(total) files cached. Tap to download remaining"
        case .downloading:
            if let progress = downloadManager.progress {
                return "Downloading \(progress.completed) of \(progress.total). Tap to cancel"
            }
            return "Downloading. Tap to cancel"
        case .cached:
            return "All media cached. Tap to clear downloads"
        }
    }
}

/// Compact version of the download button for toolbars
public struct MediaDownloadButtonCompact: View {
    let mediaItems: [any MediaItem]
    let headerProvider: @Sendable (URL) async -> [String: String]?

    @ObservedObject private var downloadManager = MediaDownloadManager.shared

    public init(
        mediaItems: [any MediaItem],
        headerProvider: @escaping @Sendable (URL) async -> [String: String]?
    ) {
        self.mediaItems = mediaItems
        self.headerProvider = headerProvider
    }

    public var body: some View {
        MediaDownloadButton(
            mediaItems: mediaItems,
            headerProvider: headerProvider
        )
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Download Button - Not Cached") {
    ZStack {
        Color.black
        MediaDownloadButton(
            mediaItems: [],
            headerProvider: { _ in nil }
        )
    }
}
#endif
