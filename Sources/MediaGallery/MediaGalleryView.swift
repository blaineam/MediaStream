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

    public init(
        mediaItems: [any MediaItem],
        initialIndex: Int = 0,
        configuration: MediaGalleryConfiguration = MediaGalleryConfiguration(),
        onDismiss: @escaping () -> Void,
        onBackToGrid: (() -> Void)? = nil
    ) {
        self.mediaItems = mediaItems
        self.initialIndex = min(max(0, initialIndex), mediaItems.count - 1)
        self.configuration = configuration
        self.onDismiss = onDismiss
        self.onBackToGrid = onBackToGrid
        _currentIndex = State(initialValue: min(max(0, initialIndex), mediaItems.count - 1))
    }

    public var body: some View {
        ZStack {
            configuration.backgroundColor
                .ignoresSafeArea()

            ZStack {
                ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, item in
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
                    .highPriorityGesture(
                        // High priority swipe gesture for navigation when not zoomed
                        // Only responds when not zoomed - doesn't recreate view when zoom state changes
                        DragGesture(minimumDistance: 50)
                            .onEnded { value in
                                // Only navigate if not zoomed
                                guard !isZoomed else { return }
                                if abs(value.translation.width) > abs(value.translation.height) {
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
        .sheet(isPresented: $showShareSheet) {
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

    init(id: UUID = UUID(), imageLoader: @escaping @Sendable () async -> PlatformImage?, caption: String? = nil, type: MediaType = .image) {
        self.id = id
        self.type = type
        self.imageLoader = imageLoader
        self.caption = caption
    }

    func loadImage() async -> PlatformImage? {
        await imageLoader()
    }

    func loadVideoURL() async -> URL? {
        nil
    }

    func getAnimatedImageDuration() async -> TimeInterval? {
        nil
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

        print("📁 [MediaGalleryView] Creating preview items with captions")

        // Fill to 20 items with generated colored images with captions
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

        let targetCount = 20
        var colorIndex = 0
        while items.count < targetCount {
            let (color, colorName) = colors[colorIndex % colors.count]
            let itemNumber = items.count + 1
            let promptIndex = items.count % samplePrompts.count
            let prompt = samplePrompts[promptIndex]

            let item = PreviewImageMediaItem(
                id: UUID(),
                imageLoader: {
                    await PreviewMediaItems.generateColorImage(color: color, text: "#\(itemNumber)")
                },
                caption: "\(prompt)\n\nModel: DALL-E 3"
            )
            items.append(item)
            colorIndex += 1
        }

        print("✅ [MediaGalleryView] Created \(items.count) preview items with captions")

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
}
#endif
