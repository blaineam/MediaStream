// MediaGallery - A SwiftUI package for displaying media with zoom, pan, and slideshow features
//
// Features:
// - Display images and videos in a gallery
// - Swipe navigation between media items
// - Double-tap to zoom in/out
// - Pan gesture when zoomed
// - Slideshow with configurable duration
// - Automatic video playback in slideshow
// - Pause slideshow when zoomed
// - Cross-platform support (iOS & macOS)
// - Memory-optimized thumbnail caching with LRU eviction
// - Visibility-based lazy loading for large galleries
// - Memory pressure handling for iOS

import Foundation

public struct MediaGallery {
    /// MediaStream release version (matches the git tag / CHANGELOG).
    public static let version = "2.7.0"
}
