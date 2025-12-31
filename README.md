# MediaStream

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017.0%2B%20%7C%20macOS%2014.0%2B-blue" alt="Platform">
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
- **Static Images**: JPEG, PNG, HEIC, etc.
- **Animated Images**: GIF, APNG, HEIF sequences, WebP
- **Videos**: MP4, MOV, M4V with playback controls
- **Duration Display**: Shows video length and animated image duration

### 🎨 Grid View Features
- **Multi-Select Mode**: Tap to select multiple items with visual indicators
- **Filtering**: Built-in filter UI (All, Images, Videos, Animated)
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
- **WebView Animated Images**: Large GIFs display via WKWebView without loading all frames into memory
- **sourceURL Property**: Direct URL loading for animated images without intermediate decoding
- **Improved Gesture Support**: Full zoom/pan support for WebView-based animated images
- **Simplified Audio Controls**: Mute/unmute toggle with persistent state between videos

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
    .package(url: "https://github.com/blaineam/MediaStream.git", from: "1.2.0")
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

### 3. Configuring the Gallery

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

### 4. Custom Filtering and Sorting

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

### 5. Multi-Select Actions

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
│   └── loadThumbnail for efficient thumbnail loading (v1.1.0)
├── MediaGalleryView
│   ├── Main slideshow view
│   ├── Zoom & pan support
│   ├── Slideshow controls
│   └── Lazy rendering (only current + adjacent items)
├── MediaGalleryGridView
│   ├── Grid browsing interface
│   ├── Multi-select mode
│   ├── Filtering UI
│   └── LazyThumbnailView for visibility-based loading (v1.1.0)
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

    func loadImage() async -> PlatformImage?
    func loadThumbnail(targetSize: CGFloat) async -> PlatformImage?  // v1.1.0
    func loadVideoURL() async -> URL?
    func getAnimatedImageDuration() async -> TimeInterval?
    func getVideoDuration() async -> TimeInterval?
    func getShareableItem() async -> Any?
    func getCaption() async -> String?
    func hasAudioTrack() async -> Bool
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

### MediaType Enum

```swift
public enum MediaType {
    case image
    case video
    case animatedImage
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
