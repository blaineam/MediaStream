# MediaStream

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017.0%2B%20%7C%20macOS%2014.0%2B%20%7C%20tvOS%2017.0%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange" alt="Swift">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License">
</p>

A comprehensive SwiftUI package for displaying beautiful media galleries with advanced features including zoom, pan, slideshow, grid view with multi-select, video playback, and more.

## ✨ Features

### 🖼️ Gallery Views
- **Slideshow View**: Fullscreen media viewer with swipe navigation
- **Grid View**: Browsing interface with thumbnails and filtering
- **Responsive Design**: Adapts to screen size (3 wide on iPhone portrait, 4 on landscape)

### 🎯 Core Capabilities
- ✅ Double-tap to zoom (1x to 4x with smooth animations)
- ✅ Pinch-to-zoom gesture support
- ✅ Pan gesture when zoomed in
- ✅ Swipe navigation between media items
- ✅ Caption support with toggle visibility
- ✅ Share functionality (preserves original file formats)
- ✅ Built-in iCloud download support

### 🎬 Slideshow Features
- Configurable duration (default 5 seconds)
- Automatic playback through images and videos
- Smart pause when zoomed in
- Automatic resume when zoomed out
- Duration detection for animated images
- **Auto-disable idle timer** (iOS): Prevents device from sleeping during slideshow playback

### 📱 Media Type Support
- **Static Images**: JPEG, PNG, HEIC, RAW (DNG, CR2, NEF, ARW), etc.
- **Animated Images**: GIF, APNG, HEIF sequences, WebP
- **Videos**: MP4, MOV, M4V, WebM with playback controls
- **Audio**: MP3, AAC, M4A, FLAC, WAV with artwork and controls
- **Duration Display**: Shows video/audio length and animated image duration

### 🎨 Grid View Features
- **Multi-Select Mode**: Tap to select multiple items with visual indicators
- **Filtering**: Built-in filter UI (All, Images, Videos, Audio, Animated)
- **Custom Filters**: Apply your own filtering logic
- **Custom Sorting**: Define custom sort order
- **Batch Operations**: Share, delete, or perform custom actions on selected items

### 🔧 Advanced Features
- Platform-specific share sheets (iOS UIActivityViewController, macOS NSSharingServicePicker)
- Custom action buttons API
- Multi-select with custom bulk actions
- Drag & drop support (macOS)
- Cross-platform support (iOS & macOS)

### 🧠 Memory Optimization (v1.1.0)
- **LRU Thumbnail Cache**: Automatic eviction of least-recently-used thumbnails with configurable memory limit (default 100MB)
- **Visibility-based Loading**: Only loads thumbnails for items currently visible on screen
- **ImageIO Downsampling**: Uses efficient CGImageSource for thumbnails without loading full images into memory
- **Memory Pressure Handling**: Automatically evicts cache entries when iOS sends memory warnings
- **Lazy Gallery Rendering**: Only renders current and adjacent items in slideshow view (not all 600+ items)

### 🎬 Video & Animation Improvements (v1.2.0)
- **WKWebView Video Player**: Memory-efficient HTML5 video playback supporting WebM, MP4, and more
- **Native Animated Images**: CGImageSource + display link rendering with LRU frame cache
- **sourceURL Property**: Direct URL loading for animated images without intermediate decoding
- **Improved Gesture Support**: Full zoom/pan support for animated images on macOS and iOS
- **Simplified Audio Controls**: Mute/unmute toggle with persistent state between videos

### 🎵 Audio Support (v1.6.0)
- **Audio Media Type**: New `MediaType.audio` for audio file support
- **Audio Player Controls**: Full-featured playback with:
  - Play/pause button with elegant circular design
  - Scrubber slider for seeking with time display
  - Volume slider with expand/collapse animation
  - Mute/unmute toggle with persistent state
  - Progress tracking and duration display
- **Album Artwork Display**: Shows embedded artwork or custom placeholder
- **Audio Placeholder Thumbnails**: Gradient background with music note icon when no artwork exists
- **Audio Metadata**: Title, artist, album, track number, and year support
- **Slideshow Integration**: Audio files work seamlessly in slideshow with auto-advance

### 📲 Background Playback & Local Caching (v1.7.0)
- **Local Media Caching**: Download media files locally for offline/background playback
  - `MediaDownloadManager`: Singleton for managing downloads and cache
  - `MediaDownloadButton`: UI component with download/progress/cached states
  - Files stored in `~/Library/Caches/MediaStream/DownloadedMedia/` (unencrypted for AVPlayer)
- **Background Audio/Video Playback**: Continue playback when app is backgrounded (cached media only)
- **Lock Screen & Control Center Integration**:
  - Play/pause, next/previous track controls
  - Seek bar with accurate position tracking
  - Album artwork and metadata display (title, artist, album)
  - Playback position updates in real-time
- **Picture-in-Picture (PiP)**: Manual PiP toggle for cached videos
- **Smart Playback Behavior**:
  - **Short-form content (< 7 min)**: Starts from beginning (music behavior)
  - **Long-form content (≥ 7 min)**: Resumes from last position (podcast/movie behavior)
- **Cache Management**:
  - Individual item download/clear in slideshow view
  - Bulk download/clear in grid view
  - Integrates with "Clear Cache" to remove downloaded media

### 🎞️ Native Animated Image Rendering & WebP Support (v1.9.0)
- **Native CGImageSource Rendering**: Replaced WKWebView-based animated image display with native frame-by-frame rendering via `CGImageSource` + display link (`CADisplayLink` on iOS, `Timer` on macOS)
- **Animated WebP Support**: Full frame duration extraction via `kCGImagePropertyWebPDictionary` across all animated image helpers
- **LRU Frame Cache**: 4-frame sliding window cache for memory-efficient playback
- **Accurate Frame Timing**: `CACurrentMediaTime()` for smooth animation without dropped or doubled frames
- **Improved macOS Gesture Support**: Native `NSView` rendering eliminates WKWebView scroll event conflicts — zoom/pan gestures work correctly
- **Thumbnail Load Cancellation**: Grid thumbnails cancel in-flight downloads when views disappear (e.g., gallery dismiss)
- **Media Type Re-filtering**: Grid automatically re-checks filter chips when WebP/HEIC items resolve their actual animation state after download
- **Video Metadata Auth Headers**: `getVideoDurationWebView` and `hasAudioTrackWebView` now pass auth headers through to the WebView fallback

### 🌐 VR & Stereoscopic 3D Support (v2.0.0)
- **360/180 Spherical Video**: Renders equirectangular video on an interactive SceneKit sphere with gyroscope and touch/drag controls
- **Stereoscopic Formats**: Side-by-Side (SBS/HSBS) and Top-Bottom (TB/HTB) projection modes for 3D content
- **Fisheye Projection**: Metal shader-based equidistant fisheye UV remapping for fisheye-encoded content (mono, SBS, TB)
- **2D Flat Crop Mode**: View stereoscopic content as flat 2D by cropping to one eye (left for SBS, top for TB) — works in both slideshow and grid views
- **Automatic Detection**: Filename-based VR projection detection (e.g., `_180_sbs`, `_360`, `_fisheye`) via `VRFilenameDetector`
- **Manual Override**: Per-item projection picker lets users manually set or change the VR projection type
- **Smart Thumbnail Cropping**: Grid thumbnails automatically show only one eye for SBS/TB content
- **tvOS Support**: Full VR projection controls, scrub bar, and slideshow overlay on Apple TV

### 📺 tvOS Support (v2.0.0)
- **Apple TV Media Browser**: Full-screen media viewer with native tvOS navigation and focus system
- **Slideshow Controls**: Double-tap Play/Pause to access slideshow overlay with navigation, loop, shuffle, and interval controls
- **VR Projection Controls**: SceneKit sphere rendering and flat crop modes on tvOS with confirmation dialog picker
- **Recently Played**: Thumbnail cache with SBS/TB-aware cropping for recently played media
- **Native Video Controls**: AVPlayerViewController integration with subtitle and audio track selection

### 📷 RAW Image Support
- **Native RAW Support**: Leverages iOS/macOS ImageIO for RAW image formats
- **Supported Formats**: DNG, CR2, CR3, NEF, ARW, ORF, RW2, and other camera RAW formats
- **Efficient Thumbnails**: Uses CGImageSource for memory-efficient RAW thumbnail generation
- **Full Resolution Display**: RAW images display at full quality in slideshow view

## 📦 Installation

### Swift Package Manager

Add the package to your Xcode project:

1. In Xcode, go to **File > Add Package Dependencies**
2. Enter the repository URL:
   ```
   https://github.com/blaineam/MediaStream.git
   ```
3. Select your desired version or branch
4. Click **Add Package**

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/blaineam/MediaStream.git", from: "1.9.0")
]
```

## 🚀 Quick Start

### Basic Slideshow

```swift
import SwiftUI
import MediaStream

struct ContentView: View {
    let mediaItems: [any MediaItem] = [
        // Your media items
    ]

    @State private var showGallery = false

    var body: some View {
        Button("Show Gallery") {
            showGallery = true
        }
        .sheet(isPresented: $showGallery) {
            MediaGalleryView(
                mediaItems: mediaItems,
                initialIndex: 0,
                onDismiss: {
                    showGallery = false
                }
            )
        }
    }
}
```

### Grid View with Multi-Select

```swift
import SwiftUI
import MediaStream

struct GalleryBrowserView: View {
    let mediaItems: [any MediaItem]
    @State private var showGallery = false

    var body: some View {
        MediaGalleryGridView(
            mediaItems: mediaItems,
            multiSelectActions: [
                MediaGalleryMultiSelectAction(
                    title: "Delete",
                    icon: "trash"
                ) { selectedItems in
                    // Handle deletion
                    deleteItems(selectedItems)
                }
            ],
            includeBuiltInShareAction: true,
            onSelect: { index in
                // Open slideshow at selected index
                showGallery = true
            },
            onDismiss: {
                // Handle dismiss
            }
        )
    }
}
```

## 📖 Implementation Guide

### 1. Implementing the MediaItem Protocol

The `MediaItem` protocol is the foundation of the package. Here's a complete implementation:

```swift
import Foundation
import MediaStream

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

struct PhotoMediaItem: MediaItem {
    let id: UUID
    let type: MediaType
    private let imageURL: URL
    private let caption: String?

    init(id: UUID = UUID(), imageURL: URL, caption: String? = nil, isAnimated: Bool = false) {
        self.id = id
        self.imageURL = imageURL
        self.caption = caption
        self.type = isAnimated ? .animatedImage : .image
    }

    // Load the image from disk or network
    func loadImage() async -> PlatformImage? {
        do {
            let data = try Data(contentsOf: imageURL)
            #if canImport(UIKit)
            return UIImage(data: data)
            #elseif canImport(AppKit)
            return NSImage(data: data)
            #endif
        } catch {
            print("Failed to load image: \(error)")
            return nil
        }
    }

    // Not used for images
    func loadVideoURL() async -> URL? {
        return nil
    }

    // Return duration for animated images
    func getAnimatedImageDuration() async -> TimeInterval? {
        guard type == .animatedImage else { return nil }
        return await AnimatedImageHelper.getAnimatedImageDuration(from: imageURL)
    }

    // Not used for images
    func getVideoDuration() async -> TimeInterval? {
        return nil
    }

    // Return the item to share (preserves original format)
    func getShareableItem() async -> Any? {
        return imageURL
    }

    // Return optional caption text
    func getCaption() async -> String? {
        return caption
    }

    // Videos only
    func hasAudioTrack() async -> Bool {
        return false
    }
}
```

### 2. Video Implementation

```swift
struct VideoMediaItem: MediaItem {
    let id: UUID
    let type: MediaType = .video
    private let videoURL: URL
    private let thumbnailURL: URL?

    init(id: UUID = UUID(), videoURL: URL, thumbnailURL: URL? = nil) {
        self.id = id
        self.videoURL = videoURL
        self.thumbnailURL = thumbnailURL
    }

    // Load thumbnail image for grid view
    func loadImage() async -> PlatformImage? {
        guard let thumbnailURL = thumbnailURL else { return nil }
        do {
            let data = try Data(contentsOf: thumbnailURL)
            #if canImport(UIKit)
            return UIImage(data: data)
            #elseif canImport(AppKit)
            return NSImage(data: data)
            #endif
        } catch {
            return nil
        }
    }

    // Return video URL for playback
    func loadVideoURL() async -> URL? {
        return videoURL
    }

    func getAnimatedImageDuration() async -> TimeInterval? {
        return nil
    }

    // Return video duration
    func getVideoDuration() async -> TimeInterval? {
        let asset = AVAsset(url: videoURL)
        return try? await asset.load(.duration).seconds
    }

    func getShareableItem() async -> Any? {
        return videoURL
    }

    func getCaption() async -> String? {
        return nil
    }

    // Check if video has audio track
    func hasAudioTrack() async -> Bool {
        let asset = AVAsset(url: videoURL)
        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        return !(tracks?.isEmpty ?? true)
    }
}
```

### 3. Audio Implementation

```swift
struct AudioFileMediaItem: MediaItem {
    let id: UUID
    let type: MediaType = .audio
    private let audioURL: URL
    private let artworkURL: URL?
    private let metadata: AudioMetadata?

    init(id: UUID = UUID(), audioURL: URL, artworkURL: URL? = nil, metadata: AudioMetadata? = nil) {
        self.id = id
        self.audioURL = audioURL
        self.artworkURL = artworkURL
        self.metadata = metadata
    }

    // Load album artwork for grid view (returns placeholder if nil)
    func loadImage() async -> PlatformImage? {
        if let artworkURL = artworkURL {
            do {
                let data = try Data(contentsOf: artworkURL)
                #if canImport(UIKit)
                return UIImage(data: data)
                #elseif canImport(AppKit)
                return NSImage(data: data)
                #endif
            } catch {
                return nil
            }
        }
        // AudioMediaItem automatically returns audio placeholder when artwork is nil
        return nil
    }

    // Return audio URL for playback
    func loadAudioURL() async -> URL? {
        return audioURL
    }

    // Return audio duration
    func getAudioDuration() async -> TimeInterval? {
        let asset = AVAsset(url: audioURL)
        return try? await asset.load(.duration).seconds
    }

    // Return audio metadata for caption display
    func getAudioMetadata() async -> AudioMetadata? {
        return metadata
    }

    func loadVideoURL() async -> URL? { nil }
    func getAnimatedImageDuration() async -> TimeInterval? { nil }
    func getVideoDuration() async -> TimeInterval? { nil }
    func getShareableItem() async -> Any? { audioURL }
    func getCaption() async -> String? {
        guard let metadata = metadata else { return nil }
        var parts: [String] = []
        if let title = metadata.title { parts.append(title) }
        if let artist = metadata.artist { parts.append(artist) }
        if let album = metadata.album { parts.append(album) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
    func hasAudioTrack() async -> Bool { true }
}
```

### 4. Using Built-in AudioMediaItem

You can also use the built-in `AudioMediaItem` for simple audio playback:

```swift
let audioItem = AudioMediaItem(
    audioURLLoader: { return URL(fileURLWithPath: "/path/to/song.mp3") },
    artworkLoader: {
        // Load album artwork from ID3 tags or external source
        return await extractAlbumArt(from: audioURL)
    },
    durationLoader: { return 180.0 },
    metadataLoader: {
        return AudioMetadata(
            title: "Song Title",
            artist: "Artist Name",
            album: "Album Name",
            trackNumber: 1,
            year: 2024
        )
    }
)
```

### 5. Background Playback with Local Caching (v1.7.0)

```swift
import SwiftUI
import MediaStream

struct BackgroundPlaybackExample: View {
    let mediaItems: [any MediaItem]
    @ObservedObject private var downloadManager = MediaDownloadManager.shared

    var body: some View {
        VStack {
            // Download button for caching media locally
            MediaDownloadButton(
                mediaItems: mediaItems,
                headerProvider: { url in
                    // Return auth headers if needed for your media URLs
                    return ["Authorization": "Bearer \(token)"]
                }
            )

            // Check cache status
            if downloadManager.allCached(mediaItems) {
                Text("All media cached - background playback enabled!")
            }

            // Open gallery (background playback works automatically for cached items)
            MediaGalleryView(
                mediaItems: mediaItems,
                initialIndex: 0,
                onDismiss: { }
            )
        }
    }
}
```

**Important Notes:**
- Background playback only works for **cached/downloaded** media items
- Non-cached media will pause when the app enters background
- The `diskCacheKey` property on MediaItem is required for caching
- Lock screen controls (play/pause, next/prev, seek) work automatically
- Album artwork and metadata display in Control Center when available

### 6. Configuring the Gallery

```swift
let config = MediaGalleryConfiguration(
    slideshowDuration: 5.0,        // Seconds per slide
    showControls: true,             // Show play/pause, share buttons
    backgroundColor: .black,        // Background color
    customActions: [                // Custom action buttons
        MediaGalleryAction(icon: "heart.fill") { index in
            print("Favorited item at index \(index)")
        },
        MediaGalleryAction(icon: "square.and.arrow.down") { index in
            print("Downloaded item at index \(index)")
        }
    ]
)

MediaGalleryView(
    mediaItems: mediaItems,
    initialIndex: 0,
    configuration: config,
    onDismiss: { }
)
```

### 5. Custom Filtering and Sorting

```swift
let filterConfig = MediaGalleryFilterConfig(
    customFilter: { item in
        // Only show images
        return item.type == .image
    },
    customSort: { item1, item2 in
        // Sort by type (images first, then videos)
        if item1.type == .image && item2.type != .image {
            return true
        }
        return false
    }
)

MediaGalleryGridView(
    mediaItems: mediaItems,
    filterConfig: filterConfig,
    onSelect: { index in },
    onDismiss: { }
)
```

### 6. Multi-Select Actions

```swift
let multiSelectActions = [
    MediaGalleryMultiSelectAction(
        title: "Export",
        icon: "square.and.arrow.down"
    ) { selectedItems in
        Task {
            for item in selectedItems {
                if let shareableItem = await item.getShareableItem() {
                    // Export the item
                    exportToFiles(shareableItem)
                }
            }
        }
    },
    MediaGalleryMultiSelectAction(
        title: "Delete",
        icon: "trash"
    ) { selectedItems in
        // Show confirmation
        showDeleteConfirmation(for: selectedItems)
    },
    MediaGalleryMultiSelectAction(
        title: "Add to Album",
        icon: "folder.badge.plus"
    ) { selectedItems in
        // Show album picker
        showAlbumPicker(for: selectedItems)
    }
]

MediaGalleryGridView(
    mediaItems: mediaItems,
    multiSelectActions: multiSelectActions,
    includeBuiltInShareAction: true,  // Adds built-in share button
    onSelect: { index in },
    onDismiss: { }
)
```

## 🎨 UI Components

### Slideshow View
- **Navigation**: Swipe left/right to navigate between items
- **Zoom**: Double-tap to zoom in/out, pinch to zoom
- **Controls**: Play/pause slideshow, share button, caption toggle
- **Caption**: Collapsible caption overlay at bottom
- **Progress**: Page indicator showing current position

### Grid View
- **Responsive Layout**: 3 columns (portrait) or 4 columns (landscape) on iOS
- **Filter Bar**: Buttons to filter by media type
- **Multi-Select**: Tap "Select" to enter multi-select mode
- **Selection Indicator**: Blue checkmarks on selected items
- **Toolbar**: Action buttons appear when items are selected

## 🔧 Advanced Usage

### Handling Encrypted/Private Images

```swift
struct EncryptedMediaItem: MediaItem {
    let id: UUID
    let type: MediaType
    private let encryptedURL: URL
    private let decryptionKey: Data

    func loadImage() async -> PlatformImage? {
        do {
            // Load encrypted data
            let encryptedData = try Data(contentsOf: encryptedURL)

            // Decrypt (using your encryption manager)
            let decryptedData = try decrypt(encryptedData, key: decryptionKey)

            #if canImport(UIKit)
            return UIImage(data: decryptedData)
            #elseif canImport(AppKit)
            return NSImage(data: decryptedData)
            #endif
        } catch {
            print("Failed to decrypt image: \(error)")
            return nil
        }
    }

    func getShareableItem() async -> Any? {
        // Create temporary decrypted file for sharing
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")

        do {
            let encryptedData = try Data(contentsOf: encryptedURL)
            let decryptedData = try decrypt(encryptedData, key: decryptionKey)
            try decryptedData.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }

    // ... other required methods
}
```

### iCloud Download Support

The package includes built-in iCloud download support. When a file is not available locally, it will automatically attempt to download it from iCloud:

```swift
func loadImage() async -> PlatformImage? {
    let url = imageURL

    // Check if file exists, attempt iCloud download if needed
    if !FileManager.default.fileExists(atPath: url.path) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)

            // Wait for download (up to 5 seconds)
            for _ in 1...10 {
                if FileManager.default.fileExists(atPath: url.path) {
                    break
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch {
            print("iCloud download failed: \(error)")
            return nil
        }
    }

    // Load the image
    // ...
}
```

## 📐 Architecture

The package is designed with a protocol-oriented architecture:

```
MediaStream (Package)
├── MediaItem (Protocol)
│   ├── Defines interface for media items
│   ├── Async methods for loading content
│   ├── loadThumbnail for efficient thumbnail loading (v1.1.0)
│   └── vrProjection for VR/3D content detection (v2.0.0)
├── MediaGalleryView
│   ├── Main slideshow view
│   ├── Zoom & pan support
│   ├── Slideshow controls
│   ├── 3D/2D projection toggle
│   └── Lazy rendering (only current + adjacent items)
├── MediaGalleryGridView
│   ├── Grid browsing interface
│   ├── Multi-select mode
│   ├── Filtering UI
│   ├── SBS/TB thumbnail cropping
│   └── LazyThumbnailView for visibility-based loading (v1.1.0)
├── VRVideoPlayerView (v2.0.0)
│   ├── SceneKit sphere rendering for 360/180 video
│   ├── Gyroscope + drag navigation
│   ├── Metal fisheye shader
│   └── Projection picker overlay
├── ThumbnailCache (v1.1.0)
│   ├── LRU cache with memory limit
│   ├── Memory pressure handling
│   └── ImageIO-based downsampling
├── ZoomableMediaView
│   ├── Individual media display
│   ├── Gesture handling
│   └── Video playback
├── ShareSheet
│   ├── iOS: UIActivityViewController
│   └── macOS: NSSharingServicePicker
└── AnimatedImageHelper
    ├── Format detection
    └── Duration calculation
```

## 🎯 API Reference

### MediaItem Protocol

```swift
public protocol MediaItem: Identifiable, Sendable {
    var id: UUID { get }
    var type: MediaType { get }
    var diskCacheKey: String? { get }  // Optional disk caching
    var sourceURL: URL? { get }        // For animated image streaming

    func loadImage() async -> PlatformImage?
    func loadThumbnail(targetSize: CGFloat) async -> PlatformImage?
    func loadVideoURL() async -> URL?
    func loadAudioURL() async -> URL?              // v1.6.0
    func getAnimatedImageDuration() async -> TimeInterval?
    func getVideoDuration() async -> TimeInterval?
    func getAudioDuration() async -> TimeInterval? // v1.6.0
    func getAudioMetadata() async -> AudioMetadata? // v1.6.0
    func getShareableItem() async -> Any?
    func getCaption() async -> String?
    func hasAudioTrack() async -> Bool
}
```

### AudioMetadata (v1.6.0)

```swift
public struct AudioMetadata: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let trackNumber: Int?
    public let year: Int?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        year: Int? = nil
    )
}
```

### ThumbnailCache (v1.1.0)

```swift
public final class ThumbnailCache {
    public static let shared: ThumbnailCache
    public static let thumbnailSize: CGFloat = 200

    public init(maxMemoryMB: Int = 100)

    public func get(_ id: UUID) -> PlatformImage?
    public func set(_ id: UUID, image: PlatformImage)
    public func contains(_ id: UUID) -> Bool
    public func clear()
    public func handleMemoryPressure()
    public var stats: (count: Int, memoryMB: Double)

    // Efficient thumbnail generation using ImageIO
    public static func createThumbnail(from image: PlatformImage, targetSize: CGFloat) -> PlatformImage
    public static func createThumbnail(from data: Data, targetSize: CGFloat) -> PlatformImage?
    public static func createThumbnail(from url: URL, targetSize: CGFloat) -> PlatformImage?
}
```

### MediaDownloadManager (v1.7.0)

```swift
@MainActor
public final class MediaDownloadManager: ObservableObject {
    public static let shared: MediaDownloadManager

    // Published state
    @Published public private(set) var downloadState: DownloadState
    @Published public private(set) var progress: DownloadProgress?

    // Check cache status
    public func isCached(mediaItem: any MediaItem) -> Bool
    public func allCached(_ items: [any MediaItem]) -> Bool
    public func anyCached(_ items: [any MediaItem]) -> Bool
    public func cachedCount(of items: [any MediaItem]) -> Int
    public func canCache(_ mediaItem: any MediaItem) -> Bool

    // Get local file URL for cached media
    public func localURL(for mediaItem: any MediaItem) -> URL?

    // Download operations
    public func downloadAll(
        _ items: [any MediaItem],
        headerProvider: @escaping @Sendable (URL) async -> [String: String]?
    ) async
    public func cancelDownload()

    // Clear cache
    public func clearAllDownloads()
    public func clearDownloads(for items: [any MediaItem])

    // Cache statistics
    public var stats: (fileCount: Int, diskMB: Double)
}

public enum DownloadState: Equatable, Sendable {
    case idle
    case downloading(completed: Int, total: Int)
    case completed
    case cancelled
    case failed(String)
}

public struct DownloadProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentItemName: String?
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public var fractionCompleted: Double
    public var currentItemProgress: Double
}
```

### MediaDownloadButton (v1.7.0)

```swift
/// A button that manages downloading and clearing cached media files.
/// Shows three states: not cached, downloading, cached.
public struct MediaDownloadButton: View {
    public init(
        mediaItems: [any MediaItem],
        headerProvider: @escaping @Sendable (URL) async -> [String: String]?
    )
}

// States:
// - Not cached: Download icon (arrow.down.circle)
// - Partially cached: Dotted download icon (arrow.down.circle.dotted)
// - Downloading: Progress ring with stop button
// - Cached: Green checkmark (checkmark.circle.fill)
```

### MediaPlaybackService (v1.7.0)

```swift
@MainActor
public final class MediaPlaybackService: NSObject, ObservableObject {
    public static let shared: MediaPlaybackService

    // Notifications for external player integration
    public static let shouldPauseForBackgroundNotification: Notification.Name
    public static let externalPlayNotification: Notification.Name
    public static let externalPauseNotification: Notification.Name
    public static let externalSeekNotification: Notification.Name
    public static let externalTrackChangedNotification: Notification.Name

    // External playback mode (when views own the player)
    public var externalPlaybackMode: Bool

    // Playlist management
    public func setPlaylist(_ mediaItems: [any MediaItem], startIndex: Int = 0)
    public var currentIndex: Int
    public var loopMode: PlaybackLoopMode

    // Now Playing info for Control Center/Lock Screen
    public func updateNowPlayingForCurrentItem() async
    public func updateNowPlayingForExternalPlayer(
        mediaItem: any MediaItem,
        title: String?,
        artist: String?,
        album: String?,
        artwork: PlatformImage?,
        duration: TimeInterval,
        isVideo: Bool
    )
    public func updateExternalPlaybackPosition(
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    )

    // Picture-in-Picture (iOS only)
    public func setupPiP(with playerLayer: AVPlayerLayer)
    public func startPiP()
    public func stopPiP()
    public func togglePiP()
    public var isPiPActive: Bool
    public var isPiPPossible: Bool
}

public enum PlaybackLoopMode {
    case off    // Stop at end
    case all    // Loop entire playlist
    case one    // Repeat current track
}
```

### MediaType Enum

```swift
public enum MediaType {
    case image
    case video
    case animatedImage
    case audio
}
```

### MediaGalleryConfiguration

```swift
public struct MediaGalleryConfiguration {
    public var slideshowDuration: TimeInterval = 5.0
    public var showControls: Bool = true
    public var backgroundColor: Color = .black
    public var customActions: [MediaGalleryAction] = []
}
```

### MediaGalleryAction

```swift
public struct MediaGalleryAction: Identifiable {
    public let id: UUID
    public let icon: String
    public let action: (Int) -> Void

    public init(id: UUID = UUID(), icon: String, action: @escaping (Int) -> Void)
}
```

### MediaGalleryMultiSelectAction

```swift
public struct MediaGalleryMultiSelectAction: Identifiable {
    public let id: UUID
    public let title: String
    public let icon: String
    public let action: ([any MediaItem]) -> Void

    public init(
        id: UUID = UUID(),
        title: String,
        icon: String,
        action: @escaping ([any MediaItem]) -> Void
    )
}
```

### MediaGalleryFilterConfig

```swift
public struct MediaGalleryFilterConfig {
    public var customFilter: ((any MediaItem) -> Bool)?
    public var customSort: ((any MediaItem, any MediaItem) -> Bool)?

    public init(
        customFilter: ((any MediaItem) -> Bool)? = nil,
        customSort: ((any MediaItem, any MediaItem) -> Bool)? = nil
    )
}
```

## 🎬 Animated Image Support

The package automatically detects and handles animated images:

- **GIF**: Graphics Interchange Format
- **APNG**: Animated PNG
- **HEIF**: High Efficiency Image Format sequences
- **WebP**: WebP animated images

Duration detection ensures animations play completely before advancing in slideshow mode.

## 🖥️ Platform Support

- **iOS**: 17.0+
- **macOS**: 14.0+
- **tvOS**: 17.0+
- **Swift**: 5.9+

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📧 Contact

Blaine Miller - [@blaineam](https://github.com/blaineam)

Project Link: [https://github.com/blaineam/MediaStream](https://github.com/blaineam/MediaStream)

---

<p align="center">Made with ❤️ and SwiftUI</p>
