import SwiftUI
import AVKit

#if canImport(UIKit)
import UIKit
#endif

/// Helper extension for conditional view modifiers
extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

/// Custom action button configuration
public struct MediaGalleryAction: Identifiable {
    public let id = UUID()
    public let icon: String
    public let action: (Int) -> Void

    public init(icon: String, action: @escaping (Int) -> Void) {
        self.icon = icon
        self.action = action
    }
}

/// Configuration for the media gallery
public struct MediaGalleryConfiguration {
    public var slideshowDuration: TimeInterval
    public var showControls: Bool
    public var backgroundColor: Color
    public var customActions: [MediaGalleryAction]

    public init(
        slideshowDuration: TimeInterval = 5.0,
        showControls: Bool = true,
        backgroundColor: Color = .black,
        customActions: [MediaGalleryAction] = []
    ) {
        self.slideshowDuration = slideshowDuration
        self.showControls = showControls
        self.backgroundColor = backgroundColor
        self.customActions = customActions
    }
}

/// Main media gallery view with slideshow, zoom, and navigation support
public struct MediaGalleryView: View {
    let mediaItems: [any MediaItem]
    let initialIndex: Int
    let configuration: MediaGalleryConfiguration
    let onDismiss: () -> Void
    let onBackToGrid: (() -> Void)?
    let onIndexChange: ((Int) -> Void)?

    @State private var currentIndex: Int
    @State private var isSlideshowPlaying = false
    @State private var isZoomed = false
    @State private var wasPlayingBeforeZoom = false
    @State private var slideshowTimer: Timer?
    @State private var showControls = true
    @State private var shareItem: Any?
    @State private var showShareSheet = false
    @State private var currentCaption: String?
    @State private var showCaption = false
    @State private var hideControlsTimer: Timer?
    @State private var controlsHoverTimer: Timer?
    @State private var customSlideshowDuration: TimeInterval?
    @State private var videoSlideStartTime: Date?
    @State private var videoLoopCount: Int = 0
    @State private var isFullscreen = false
    @FocusState private var isFocused: Bool

    /// Number of adjacent items to preload on each side
    private let preloadCount = 1

    /// Returns indices for current item plus adjacent items for preloading
    /// This limits memory usage by only rendering ~3 items instead of all 600+
    private var visibleIndices: [Int] {
        guard !mediaItems.isEmpty else { return [] }

        var indices: [Int] = []
        let count = mediaItems.count

        // Add previous items (with wrapping)
        for offset in (1...preloadCount).reversed() {
            let idx = (currentIndex - offset + count) % count
            if !indices.contains(idx) {
                indices.append(idx)
            }
        }

        // Add current
        indices.append(currentIndex)

        // Add next items (with wrapping)
        for offset in 1...preloadCount {
            let idx = (currentIndex + offset) % count
            if !indices.contains(idx) {
                indices.append(idx)
            }
        }

        return indices
    }

    public init(
        mediaItems: [any MediaItem],
        initialIndex: Int = 0,
        configuration: MediaGalleryConfiguration = MediaGalleryConfiguration(),
        onDismiss: @escaping () -> Void,
        onBackToGrid: (() -> Void)? = nil,
        onIndexChange: ((Int) -> Void)? = nil
    ) {
        self.mediaItems = mediaItems
        self.initialIndex = min(max(0, initialIndex), mediaItems.count - 1)
        self.configuration = configuration
        self.onDismiss = onDismiss
        self.onBackToGrid = onBackToGrid
        self.onIndexChange = onIndexChange
        _currentIndex = State(initialValue: min(max(0, initialIndex), mediaItems.count - 1))
    }

    public var body: some View {
        ZStack {
            configuration.backgroundColor
                .ignoresSafeArea()

            // Only render current and adjacent items to save memory
            // For 600+ items, rendering all would cause OOM
            ZStack {
                ForEach(visibleIndices, id: \.self) { index in
                    let item = mediaItems[index]
                    ZoomableMediaView(
                        mediaItem: item,
                        onZoomChanged: { zoomed in
                            handleZoomChanged(zoomed)
                        },
                        isSlideshowPlaying: isSlideshowPlaying,
                        showControls: showControls,
                        isCurrentSlide: currentIndex == index,
                        videoLoopCount: currentIndex == index ? videoLoopCount : 0,
                        onVideoComplete: {
                            handleVideoComplete()
                        }
                    )
                    .opacity(currentIndex == index ? 1 : 0)
                    .zIndex(currentIndex == index ? 1 : 0)
                    .allowsHitTesting(currentIndex == index)
                    .simultaneousGesture(
                        // Navigation gesture - only activates for large horizontal swipes when not zoomed
                        DragGesture(minimumDistance: 100)
                            .onEnded { value in
                                // Block if zoomed or interacting with controls
                                guard !isZoomed else { return }
                                guard !MediaControlsInteractionState.shared.isInteracting else { return }
                                let horizontalAmount = abs(value.translation.width)
                                let verticalAmount = abs(value.translation.height)
                                // Require clearly horizontal (2:1 ratio) and significant distance
                                if horizontalAmount > verticalAmount * 2 && horizontalAmount > 100 {
                                    if value.translation.width < 0 {
                                        nextItem()
                                    } else {
                                        previousItem()
                                    }
                                }
                            }
                    )
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentIndex)
            .transition(.opacity)
            .ignoresSafeArea()
            .onChange(of: currentIndex) { _, newIndex in
                handleIndexChanged(newIndex)
            }

            // Controls on top so they receive taps
            if configuration.showControls && showControls {
                VStack(spacing: 0) {
                    // Top: Slide counter and buttons
                    HStack {
                        // Slide counter on the left
                        Text("\(currentIndex + 1) / \(mediaItems.count)")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())

                        Spacer()

                        // Right side buttons
                        HStack(spacing: 12) {
                            // Custom action buttons
                            ForEach(configuration.customActions) { customAction in
                                Button(action: { customAction.action(currentIndex); resetControlsTimer() }) {
                                    ZStack {
                                        Circle()
                                            .fill(.ultraThinMaterial)
                                            .frame(width: 36, height: 36)
                                        Image(systemName: customAction.icon)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            // Share button
                            Button(action: { shareCurrentItem(); resetControlsTimer() }) {
                                ZStack {
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)

                            // Close/Back button
                            Button(action: {
                                if let onBackToGrid = onBackToGrid {
                                    onBackToGrid()
                                } else {
                                    onDismiss()
                                }
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 36, height: 36)
                                    Image(systemName: onBackToGrid != nil ? "arrow.left" : "xmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading)
                    .padding(.top)
                    .padding(.trailing)

                    Spacer()

                    // Caption above controls
                    if let caption = currentCaption, showCaption {
                        captionView(caption: caption)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }

                    // Controls at bottom with extra padding for video controls
                    controlsView
                        .padding(.bottom, mediaItems[currentIndex].type == .video ? 140 : 20)
                }
                .allowsHitTesting(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Only toggle controls if configuration allows it
            if configuration.showControls {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
                if showControls {
                    scheduleHideControls()
                } else {
                    cancelHideControls()
                }
            }
        }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if configuration.showControls && !showControls {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                }
                if configuration.showControls {
                    scheduleHideControls()
                }
            case .ended:
                break
            }
        }
        #endif
        #if os(iOS)
        .statusBar(hidden: true)
        .sheet(isPresented: Binding(
            get: { showShareSheet && shareItem != nil },
            set: { showShareSheet = $0 }
        )) {
            if let item = shareItem {
                ShareSheet(items: [item])
            }
        }
        .fullScreenCover(isPresented: $isFullscreen) {
            // Recreate the full gallery view in fullscreen mode
            MediaGalleryView(
                mediaItems: mediaItems,
                initialIndex: currentIndex,
                configuration: configuration,
                onDismiss: {
                    isFullscreen = false
                },
                onBackToGrid: nil
            )
        }
        #elseif os(macOS)
        .background(
            Group {
                if showShareSheet, let item = shareItem {
                    ShareSheetMac(items: [item], isPresented: $showShareSheet)
                }
            }
        )
        #endif
        .onAppear {
            checkAndHandleVideo()
            loadCaption()
            scheduleHideControls()
        }
        .onDisappear {
            stopSlideshow()
            cancelHideControls()

            // Ensure idle timer is re-enabled when gallery is dismissed
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(iOS)
        .onKeyPress(.space) {
            toggleSlideshow()
            resetControlsTimer()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            previousItem()
            resetControlsTimer()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            nextItem()
            resetControlsTimer()
            return .handled
        }
        .focusable()
        .focused($isFocused)
        #endif
        .onAppear {
            #if os(iOS)
            isFocused = true
            #endif
            #if os(macOS)
            setupKeyboardNotifications()
            #endif
        }
        .onDisappear {
            #if os(macOS)
            removeKeyboardNotifications()
            #endif
        }
    }

    #if os(macOS)
    private func setupKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("mediaGalleryToggleSlideshow"),
            object: nil,
            queue: .main
        ) { [self] _ in
            toggleSlideshow()
            resetControlsTimer()
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("mediaGalleryPreviousSlide"),
            object: nil,
            queue: .main
        ) { [self] _ in
            previousItem()
            resetControlsTimer()
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("mediaGalleryNextSlide"),
            object: nil,
            queue: .main
        ) { [self] _ in
            nextItem()
            resetControlsTimer()
        }
    }

    private func removeKeyboardNotifications() {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("mediaGalleryToggleSlideshow"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("mediaGalleryPreviousSlide"), object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("mediaGalleryNextSlide"), object: nil)
    }
    #endif

    private var controlsView: some View {
        // All controls in one row
        HStack(spacing: 16) {
            // Previous button
            Button(action: { previousItem(); resetControlsTimer() }) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 36, height: 36)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)

            // Slideshow Play/Pause button
            Button(action: { toggleSlideshow(); resetControlsTimer() }) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                    Image(systemName: isSlideshowPlaying ? "stop.fill" : "play.square.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Text("Slideshow Duration")
                Divider()
                Button("3 seconds") {
                    customSlideshowDuration = 3.0
                    if !isSlideshowPlaying {
                        startSlideshow()
                    }
                }
                Button("5 seconds") {
                    customSlideshowDuration = 5.0
                    if !isSlideshowPlaying {
                        startSlideshow()
                    }
                }
                Button("7 seconds") {
                    customSlideshowDuration = 7.0
                    if !isSlideshowPlaying {
                        startSlideshow()
                    }
                }
                Button("10 seconds") {
                    customSlideshowDuration = 10.0
                    if !isSlideshowPlaying {
                        startSlideshow()
                    }
                }
                Button("20 seconds") {
                    customSlideshowDuration = 20.0
                    if !isSlideshowPlaying {
                        startSlideshow()
                    }
                }
                Button("30 seconds") {
                    customSlideshowDuration = 30.0
                    if !isSlideshowPlaying {
                        startSlideshow()
                    }
                }
                Button("1 minute") {
                    customSlideshowDuration = 60.0
                    if !isSlideshowPlaying {
                        startSlideshow()
                    }
                }
                if customSlideshowDuration != nil {
                    Divider()
                    Button("Reset to Default") { customSlideshowDuration = nil }
                }
            }

            // Caption toggle button (if caption exists)
            if currentCaption != nil {
                Button(action: { withAnimation { showCaption.toggle() }; resetControlsTimer() }) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 36, height: 36)
                        Image(systemName: showCaption ? "text.bubble.fill" : "text.bubble")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
            }

            // Next button
            Button(action: { nextItem(); resetControlsTimer() }) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 36, height: 36)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func captionView(caption: String) -> some View {
        ScrollView {
            Text(caption)
                .font(.body)
                .foregroundStyle(.white)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 150) // Limit height to make it scrollable
        .background(.black.opacity(0.7))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func handleZoomChanged(_ zoomed: Bool) {
        isZoomed = zoomed

        if zoomed {
            // Zooming in - save state and stop slideshow
            if isSlideshowPlaying {
                wasPlayingBeforeZoom = true
                stopSlideshow()
            }
        } else {
            // Zooming out - resume slideshow if it was playing before
            if wasPlayingBeforeZoom {
                wasPlayingBeforeZoom = false
                startSlideshow()
            }
        }
    }

    private func handleVideoComplete() {
        print("📺 handleVideoComplete called. isSlideshowPlaying: \(isSlideshowPlaying)")

        guard isSlideshowPlaying else {
            print("📺 Not advancing - slideshow not playing")
            return
        }

        print("📺 Video completed - ALWAYS waiting for full completion before advancing")

        // Add a delay after video completes to ensure last frame is visible
        // AND to prevent the crossfade from cutting off the video
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second pause to let video fully finish

            await MainActor.run {
                guard self.isSlideshowPlaying else { return } // Check again in case stopped

                // ALWAYS advance after video completes - videos must play to completion
                print("📺 ✅ Video fully completed - advancing to next slide after pause")
                self.videoSlideStartTime = nil
                self.videoLoopCount = 0

                // Now animate the transition after the pause
                self.nextItemAfterVideoCompletion()
            }
        }
    }

    private func handleIndexChanged(_ newIndex: Int) {
        checkAndHandleVideo()
        loadCaption()
        resetControlsTimer()
    }

    private func loadCaption() {
        Task {
            let currentItem = mediaItems[currentIndex]
            print("📝 MediaGallery: Loading caption for item \(currentIndex + 1)/\(mediaItems.count)")
            if let caption = await currentItem.getCaption() {
                print("📝 MediaGallery: Caption loaded: \(caption.prefix(100))...")
                await MainActor.run {
                    currentCaption = caption
                }
            } else {
                print("📝 MediaGallery: No caption available for this item")
                await MainActor.run {
                    currentCaption = nil
                    showCaption = false
                }
            }
        }
    }

    private func checkAndHandleVideo() {
        // Video playback is handled by ZoomableMediaView
        // Just track slideshow state for videos
        let currentItem = mediaItems[currentIndex]
        if currentItem.type == .video {
            if isSlideshowPlaying {
                videoSlideStartTime = Date()
                videoLoopCount = 0
                print("📺 Video slide started during slideshow")
            }
        }
    }

    private func toggleSlideshow() {
        if isSlideshowPlaying {
            stopSlideshow()
        } else {
            startSlideshow()
        }
    }

    private func startSlideshow() {
        guard !isZoomed else { return }
        isSlideshowPlaying = true

        // Disable idle timer to prevent device from sleeping during slideshow
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif

        // Auto-hide controls when slideshow starts
        withAnimation(.easeOut(duration: 0.3)) {
            showControls = false
        }
        cancelHideControls()

        let currentItem = mediaItems[currentIndex]

        // For videos, record start time for duration tracking
        if currentItem.type == .video {
            videoSlideStartTime = Date()
            videoLoopCount = 0
            print("📺 Slideshow started on video - will loop until slide duration reached")
        } else if currentItem.type == .image || currentItem.type == .animatedImage {
            // Only schedule timer for images and animated images
            Task {
                await scheduleSlideshowTimer()
            }
        }
    }

    private func pauseSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    private func stopSlideshow() {
        isSlideshowPlaying = false
        pauseSlideshow()
        videoSlideStartTime = nil
        videoLoopCount = 0

        // Re-enable idle timer when slideshow stops
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func scheduleSlideshowTimer() async {
        slideshowTimer?.invalidate()

        let currentItem = mediaItems[currentIndex]
        let baseDuration = customSlideshowDuration ?? configuration.slideshowDuration
        var duration = baseDuration

        // Videos handle their own completion via onVideoComplete callback
        // Don't schedule a timer for videos
        if currentItem.type == .video {
            return
        }

        if currentItem.type == .animatedImage {
            if let animDuration = await currentItem.getAnimatedImageDuration() {
                duration = AnimatedImageHelper.calculateSlideshowDuration(
                    animationDuration: animDuration,
                    minimumDuration: baseDuration
                )
            }
        }

        await MainActor.run {
            slideshowTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
                Task { @MainActor [self] in
                    if self.isSlideshowPlaying && !self.isZoomed {
                        self.nextItem()
                    }
                }
            }
        }
    }

    private func nextItem() {
        // Always loop: if at last slide, go to first slide
        let newIndex = (currentIndex + 1) % mediaItems.count

        withAnimation(.easeInOut(duration: 0.3)) {
            currentIndex = newIndex
        }

        // Notify parent of index change
        onIndexChange?(currentIndex)

        if isSlideshowPlaying {
            let nextItem = mediaItems[currentIndex]
            // Schedule timer for images and animated images
            // Videos handle their own completion via onVideoComplete
            if nextItem.type == .image || nextItem.type == .animatedImage {
                Task {
                    await scheduleSlideshowTimer()
                }
            } else if nextItem.type == .video {
                // Video will play automatically via shouldAutoplay
                // No timer needed - video completion will advance
            }
        }
    }

    private func nextItemAfterVideoCompletion() {
        // Special transition for videos that doesn't start animation until called
        // This ensures video plays to completion before crossfade starts
        let newIndex = (currentIndex + 1) % mediaItems.count

        withAnimation(.easeInOut(duration: 0.3)) {
            currentIndex = newIndex
        }

        // Notify parent of index change
        onIndexChange?(currentIndex)

        if isSlideshowPlaying {
            let nextItem = mediaItems[currentIndex]
            // Schedule timer for images and animated images
            // Videos handle their own completion via onVideoComplete
            if nextItem.type == .image || nextItem.type == .animatedImage {
                Task {
                    await scheduleSlideshowTimer()
                }
            } else if nextItem.type == .video {
                // Video will play automatically via shouldAutoplay
                // No timer needed - video completion will advance
            }
        }
    }

    private func previousItem() {
        // Always loop: if at first slide, go to last slide
        let newIndex = currentIndex == 0 ? mediaItems.count - 1 : currentIndex - 1

        withAnimation(.easeInOut(duration: 0.3)) {
            currentIndex = newIndex
        }

        // Notify parent of index change
        onIndexChange?(currentIndex)

        if isSlideshowPlaying {
            let prevItem = mediaItems[currentIndex]
            // Schedule timer for images and animated images
            // Videos handle their own completion via onVideoComplete
            if prevItem.type == .image || prevItem.type == .animatedImage {
                Task {
                    await scheduleSlideshowTimer()
                }
            } else if prevItem.type == .video {
                // Video will play automatically via shouldAutoplay
                // No timer needed - video completion will advance
            }
        }
    }

    private func shareCurrentItem() {
        Task {
            let currentItem = mediaItems[currentIndex]

            // First try getShareableItem() which should return original format
            if let shareableItem = await currentItem.getShareableItem() {
                // Check if it's already a file URL (original format preserved)
                if let url = shareableItem as? URL {
                    print("📤 Slideshow share - File URL (original format): \(url.path)")
                    print("📤 File extension: \(url.pathExtension)")
                    await MainActor.run {
                        shareItem = url
                        showShareSheet = true
                    }
                    return
                }

                // If it returned an image object, we need to create a temp file
                #if os(iOS)
                if let image = shareableItem as? UIImage {
                    print("📤 Slideshow share - Got UIImage, creating temp file")
                    if let tempURL = await createTemporaryImageFile(from: image, isAnimated: currentItem.type == .animatedImage) {
                        await MainActor.run {
                            shareItem = tempURL
                            showShareSheet = true
                        }
                    }
                    return
                }
                #else
                if let image = shareableItem as? NSImage {
                    print("📤 Slideshow share - Got NSImage, creating temp file")
                    if let tempURL = await createTemporaryImageFile(from: image, isAnimated: currentItem.type == .animatedImage) {
                        await MainActor.run {
                            shareItem = tempURL
                            showShareSheet = true
                        }
                    }
                    return
                }
                #endif

                // Unknown type, share as-is
                print("📤 Slideshow share - Unknown type: \(type(of: shareableItem))")
                await MainActor.run {
                    shareItem = shareableItem
                    showShareSheet = true
                }
            } else {
                print("⚠️ getShareableItem() returned nil, cannot share")
            }
        }
    }

    private func createTemporaryImageFile(from image: PlatformImage, isAnimated: Bool) async -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "\(UUID().uuidString).png"
        let tempURL = tempDir.appendingPathComponent(filename)

        #if os(iOS)
        guard let data = image.pngData() else {
            print("⚠️ Failed to create PNG data from UIImage")
            return nil
        }
        #else
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let data = bitmapRep.representation(using: .png, properties: [:]) else {
            print("⚠️ Failed to create PNG data from NSImage")
            return nil
        }
        #endif

        do {
            try data.write(to: tempURL)
            print("✅ Created temporary PNG file: \(tempURL.path) (\(data.count) bytes)")
            return tempURL
        } catch {
            print("⚠️ Failed to write temporary image file: \(error)")
            return nil
        }
    }

    private func scheduleHideControls() {
        cancelHideControls()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor [self] in
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showControls = false
                }
            }
        }
    }

    private func cancelHideControls() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = nil
    }

    private func resetControlsTimer() {
        if !showControls {
            withAnimation(.easeIn(duration: 0.2)) {
                showControls = true
            }
        }
        scheduleHideControls()
    }

    private func toggleFullscreen() {
        #if os(iOS)
        isFullscreen.toggle()
        #elseif os(macOS)
        // Find the active window
        if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            window.toggleFullScreen(nil)
            isFullscreen.toggle()
        } else if let window = NSApplication.shared.windows.first {
            // Fallback to first window if no key window
            window.toggleFullScreen(nil)
            isFullscreen.toggle()
        }
        #endif
    }
}

// MARK: - Preview Support

#if DEBUG
import SwiftUI
import AVFoundation
import ImageIO

// MARK: - UIImage Animated GIF Extension

#if canImport(UIKit)
extension UIImage {
    /// Create an animated UIImage from GIF data
    static func animatedImageWithAnimatedGIFData(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            // Single frame, just return regular image
            return UIImage(data: data)
        }

        var images: [UIImage] = []
        var duration: TimeInterval = 0

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(UIImage(cgImage: cgImage))

            // Get frame duration
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, delayTime > 0 {
                    duration += delayTime
                } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime as String] as? Double {
                    duration += delayTime
                } else {
                    duration += 0.1 // Default frame duration
                }
            } else {
                duration += 0.1
            }
        }

        return UIImage.animatedImage(with: images, duration: duration)
    }
}
#endif

#Preview("Slideshow with Real Media") {
    MediaGalleryView(
        mediaItems: PreviewMediaItems.createComprehensiveTestMedia(),
        initialIndex: 0,
        configuration: MediaGalleryConfiguration(
            slideshowDuration: 3.0,
            showControls: true,
            backgroundColor: .black
        ),
        onDismiss: {
            print("Slideshow dismissed")
        }
    )
}

#Preview("Slideshow with Custom Actions") {
    MediaGalleryView(
        mediaItems: PreviewMediaItems.createComprehensiveTestMedia(),
        initialIndex: 2,
        configuration: MediaGalleryConfiguration(
            slideshowDuration: 5.0,
            showControls: true,
            backgroundColor: .black,
            customActions: [
                MediaGalleryAction(icon: "star.fill", action: { index in
                    print("Favorited item at index: \(index)")
                }),
                MediaGalleryAction(icon: "trash", action: { index in
                    print("Delete item at index: \(index)")
                })
            ]
        ),
        onDismiss: {
            print("Gallery dismissed")
        }
    )
}

/// Preview media item with caption support
fileprivate struct PreviewImageMediaItem: MediaItem {
    let id: UUID
    let type: MediaType
    private let imageLoader: @Sendable () async -> PlatformImage?
    private let caption: String?
    private let animatedDuration: TimeInterval?

    init(id: UUID = UUID(), imageLoader: @escaping @Sendable () async -> PlatformImage?, caption: String? = nil, type: MediaType = .image, animatedDuration: TimeInterval? = nil) {
        self.id = id
        self.type = type
        self.imageLoader = imageLoader
        self.caption = caption
        self.animatedDuration = animatedDuration
    }

    func loadImage() async -> PlatformImage? {
        await imageLoader()
    }

    func loadVideoURL() async -> URL? {
        nil
    }

    func getAnimatedImageDuration() async -> TimeInterval? {
        animatedDuration
    }

    func getVideoDuration() async -> TimeInterval? {
        nil
    }

    func getShareableItem() async -> Any? {
        await loadImage()
    }

    func getCaption() async -> String? {
        caption
    }

    func hasAudioTrack() async -> Bool {
        false
    }
}

/// Preview video media item
fileprivate struct PreviewVideoMediaItem: MediaItem {
    let id: UUID
    let type: MediaType = .video
    private let videoURL: URL
    private let thumbnailLoader: @Sendable () async -> PlatformImage?
    private let caption: String?
    private let duration: TimeInterval?

    init(id: UUID = UUID(), videoURL: URL, thumbnailLoader: @escaping @Sendable () async -> PlatformImage?, caption: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.videoURL = videoURL
        self.thumbnailLoader = thumbnailLoader
        self.caption = caption
        self.duration = duration
    }

    func loadImage() async -> PlatformImage? {
        await thumbnailLoader()
    }

    func loadVideoURL() async -> URL? {
        videoURL
    }

    func getAnimatedImageDuration() async -> TimeInterval? {
        nil
    }

    func getVideoDuration() async -> TimeInterval? {
        duration
    }

    func getShareableItem() async -> Any? {
        videoURL
    }

    func getCaption() async -> String? {
        caption
    }

    func hasAudioTrack() async -> Bool {
        true
    }
}

/// Preview helper for generating sample media
fileprivate struct PreviewMediaItems {
    static let samplePrompts: [String] = [
        "A serene mountain landscape at sunset with golden light",
        "A cozy coffee shop interior with warm lighting and books",
        "Abstract geometric patterns in vibrant colors",
        "A futuristic city skyline at night with neon lights",
        "Peaceful zen garden with carefully raked sand",
        "Underwater coral reef teeming with colorful fish",
        "Misty forest path with sunbeams filtering through trees",
        "Vintage record player with vinyl collection",
        "Modern minimalist workspace with clean lines",
        "Starry night sky over a calm lake reflection",
        "Rustic farmhouse kitchen with fresh ingredients",
        "Abstract expressionist painting with bold brushstrokes"
    ]

    static func createComprehensiveTestMedia() -> [any MediaItem] {
        var items: [any MediaItem] = []

        print("📁 [MediaGalleryView] Creating preview items with all media types")

        let colors: [(Color, String)] = [
            (.red, "Red"),
            (.blue, "Blue"),
            (.green, "Green"),
            (.orange, "Orange"),
            (.purple, "Purple"),
            (.pink, "Pink"),
            (.yellow, "Yellow"),
            (.teal, "Teal"),
            (.indigo, "Indigo"),
            (.mint, "Mint"),
            (.cyan, "Cyan"),
            (.brown, "Brown")
        ]

        let samplePrompts: [String] = PreviewMediaItems.samplePrompts

        // Sample video URLs (Big Buck Bunny - public domain)
        let sampleVideoURLs: [(URL, TimeInterval)] = [
            (URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!, 596.0),
            (URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!, 653.0),
            (URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!, 887.0),
            (URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4")!, 734.0)
        ]

        // Sample animated GIF URLs (public domain / creative commons)
        let sampleAnimatedGIFs: [(URL, TimeInterval)] = [
            (URL(string: "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExcDd2OWRyMnNhMzVkOWt0N2RjZnNhNjN3NnV3OXBwNHo2ZGtvbWhueSZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/3o7aCSPqXE5C6T8tBC/giphy.gif")!, 2.0),
            (URL(string: "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExYzRlMjM5NzY0MzdiYjhhZTgzMjJlMjBiOWE4OWRjMmM2YTk0OTYwNyZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/l0HlBO7eyXzSZkJri/giphy.gif")!, 1.5),
            (URL(string: "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExNDhiMzYxMjU0ZjJkNjM5ZDE5NWY2ZWE3NTg1MTBiMzM5MjNlNDIwMyZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/xT9IgzoKnwFNmISR8I/giphy.gif")!, 2.5),
            (URL(string: "https://media.giphy.com/media/v1.Y2lkPTc5MGI3NjExNmI1YzI2ZjY5ZDgzODdjMjE5MzE1MzY1YjhlMTBiMDNjZjQyZDE5MSZlcD12MV9pbnRlcm5hbF9naWZfYnlfaWQmY3Q9Zw/3oEjI6SIIHBdRxXI40/giphy.gif")!, 1.0)
        ]

        let targetCount = 20
        var colorIndex = 0
        var videoIndex = 0
        var gifIndex = 0

        while items.count < targetCount {
            let (color, _) = colors[colorIndex % colors.count]
            let itemNumber = items.count + 1
            let promptIndex = items.count % samplePrompts.count
            let prompt = samplePrompts[promptIndex]

            // Mix of media types: every 7th is video, every 5th is animated GIF, rest are static images
            if itemNumber % 7 == 0 && videoIndex < sampleVideoURLs.count {
                // Video item
                let (videoURL, duration) = sampleVideoURLs[videoIndex]
                let capturedColor = color
                let capturedItemNumber = itemNumber
                let item = PreviewVideoMediaItem(
                    id: UUID(),
                    videoURL: videoURL,
                    thumbnailLoader: {
                        await PreviewMediaItems.generateVideoThumbnail(color: capturedColor, text: "🎬 #\(capturedItemNumber)")
                    },
                    caption: "Sample Video #\(videoIndex + 1)\n\n\(prompt)",
                    duration: duration
                )
                items.append(item)
                videoIndex += 1
            } else if itemNumber % 5 == 0 && gifIndex < sampleAnimatedGIFs.count {
                // Real animated GIF from URL
                let (gifURL, duration) = sampleAnimatedGIFs[gifIndex]
                let capturedGifIndex = gifIndex
                let item = PreviewImageMediaItem(
                    id: UUID(),
                    imageLoader: {
                        await PreviewMediaItems.loadAnimatedGIF(from: gifURL)
                    },
                    caption: "Animated GIF #\(capturedGifIndex + 1)\n\n\(prompt)",
                    type: .animatedImage,
                    animatedDuration: duration
                )
                items.append(item)
                gifIndex += 1
            } else {
                // Static image item
                let capturedColor = color
                let capturedItemNumber = itemNumber
                let item = PreviewImageMediaItem(
                    id: UUID(),
                    imageLoader: {
                        await PreviewMediaItems.generateColorImage(color: capturedColor, text: "#\(capturedItemNumber)")
                    },
                    caption: "\(prompt)\n\nModel: DALL-E 3"
                )
                items.append(item)
            }
            colorIndex += 1
        }

        print("✅ [MediaGalleryView] Created \(items.count) preview items (images, animated, videos)")

        return items
    }

    @MainActor
    static func generateColorImage(color: Color, text: String) -> PlatformImage {
        let size = CGSize(width: 800, height: 600)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor(color).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 120, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(color).setFill()
        NSRect(origin: .zero, size: size).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 120, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = CGRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        return image
        #endif
    }

    /// Load an animated GIF from a URL
    static func loadAnimatedGIF(from url: URL) async -> PlatformImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            #if canImport(UIKit)
            return UIImage.animatedImageWithAnimatedGIFData(data)
            #elseif canImport(AppKit)
            return NSImage(data: data)
            #endif
        } catch {
            print("⚠️ Failed to load animated GIF from \(url): \(error)")
            return nil
        }
    }

    /// Generate an animated image (simulated with multi-frame UIImage/NSImage)
    @MainActor
    static func generateAnimatedImage(color: Color, text: String) -> PlatformImage {
        let size = CGSize(width: 800, height: 600)
        let frameCount = 8
        var frames: [PlatformImage] = []

        // Create frames with varying brightness/saturation for animation effect
        for i in 0..<frameCount {
            let progress = Double(i) / Double(frameCount)
            let adjustedColor = color.opacity(0.5 + 0.5 * sin(progress * .pi * 2))

            #if canImport(UIKit)
            let renderer = UIGraphicsImageRenderer(size: size)
            let frame = renderer.image { context in
                // Background with gradient effect
                UIColor(adjustedColor).setFill()
                context.fill(CGRect(origin: .zero, size: size))

                // Draw animated circle
                let circleRadius: CGFloat = 100
                let centerX = size.width / 2 + CGFloat(sin(progress * .pi * 2)) * 150
                let centerY = size.height / 2 + CGFloat(cos(progress * .pi * 2)) * 100
                UIColor.white.withAlphaComponent(0.8).setFill()
                context.cgContext.fillEllipse(in: CGRect(
                    x: centerX - circleRadius,
                    y: centerY - circleRadius,
                    width: circleRadius * 2,
                    height: circleRadius * 2
                ))

                // Draw text
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 80, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let textSize = (text as NSString).size(withAttributes: attributes)
                let textRect = CGRect(
                    x: (size.width - textSize.width) / 2,
                    y: (size.height - textSize.height) / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                (text as NSString).draw(in: textRect, withAttributes: attributes)
            }
            frames.append(frame)
            #elseif canImport(AppKit)
            let frame = NSImage(size: size)
            frame.lockFocus()

            NSColor(adjustedColor).setFill()
            NSRect(origin: .zero, size: size).fill()

            // Draw animated circle
            let circleRadius: CGFloat = 100
            let centerX = size.width / 2 + CGFloat(sin(progress * .pi * 2)) * 150
            let centerY = size.height / 2 + CGFloat(cos(progress * .pi * 2)) * 100
            NSColor.white.withAlphaComponent(0.8).setFill()
            let circlePath = NSBezierPath(ovalIn: NSRect(
                x: centerX - circleRadius,
                y: centerY - circleRadius,
                width: circleRadius * 2,
                height: circleRadius * 2
            ))
            circlePath.fill()

            // Draw text
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 80, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attributes)

            frame.unlockFocus()
            frames.append(frame)
            #endif
        }

        #if canImport(UIKit)
        // Create animated UIImage
        return UIImage.animatedImage(with: frames, duration: 2.0) ?? frames[0]
        #elseif canImport(AppKit)
        // For macOS, return single frame (NSImage doesn't have built-in animation support like UIImage)
        // The animation will be handled by the AnimatedImageView
        return frames[0]
        #endif
    }

    /// Generate a video thumbnail placeholder
    @MainActor
    static func generateVideoThumbnail(color: Color, text: String) -> PlatformImage {
        let size = CGSize(width: 800, height: 600)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            // Dark gradient background
            UIColor(color).withAlphaComponent(0.7).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Draw play button circle
            let playButtonSize: CGFloat = 120
            let playButtonRect = CGRect(
                x: (size.width - playButtonSize) / 2,
                y: (size.height - playButtonSize) / 2 - 30,
                width: playButtonSize,
                height: playButtonSize
            )
            UIColor.white.withAlphaComponent(0.9).setFill()
            context.cgContext.fillEllipse(in: playButtonRect)

            // Draw play triangle
            UIColor(color).setFill()
            let trianglePath = UIBezierPath()
            let triCenterX = playButtonRect.midX + 5
            let triCenterY = playButtonRect.midY
            let triSize: CGFloat = 35
            trianglePath.move(to: CGPoint(x: triCenterX - triSize * 0.4, y: triCenterY - triSize))
            trianglePath.addLine(to: CGPoint(x: triCenterX - triSize * 0.4, y: triCenterY + triSize))
            trianglePath.addLine(to: CGPoint(x: triCenterX + triSize * 0.8, y: triCenterY))
            trianglePath.close()
            trianglePath.fill()

            // Draw text
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 60, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: size.height - 120,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(color).withAlphaComponent(0.7).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Draw play button circle
        let playButtonSize: CGFloat = 120
        let playButtonRect = NSRect(
            x: (size.width - playButtonSize) / 2,
            y: (size.height - playButtonSize) / 2 + 30,
            width: playButtonSize,
            height: playButtonSize
        )
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: playButtonRect).fill()

        // Draw play triangle
        NSColor(color).setFill()
        let trianglePath = NSBezierPath()
        let triCenterX = playButtonRect.midX + 5
        let triCenterY = playButtonRect.midY
        let triSize: CGFloat = 35
        trianglePath.move(to: NSPoint(x: triCenterX - triSize * 0.4, y: triCenterY - triSize))
        trianglePath.line(to: NSPoint(x: triCenterX - triSize * 0.4, y: triCenterY + triSize))
        trianglePath.line(to: NSPoint(x: triCenterX + triSize * 0.8, y: triCenterY))
        trianglePath.close()
        trianglePath.fill()

        // Draw text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 60, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = CGRect(
            x: (size.width - textSize.width) / 2,
            y: 60,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        return image
        #endif
    }
}
#endif
