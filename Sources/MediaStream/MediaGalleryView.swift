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

/// Loop mode for slideshow playback
public enum LoopMode: Int, CaseIterable {
    case off      // Stop at end of slideshow
    case all      // Loop entire slideshow
    case one      // Repeat current media item

    var icon: String {
        switch self {
        case .off: return "repeat.circle"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Loop Off"
        case .all: return "Loop All"
        case .one: return "Loop One"
        }
    }

    /// Cycle to next mode
    func next() -> LoopMode {
        let allCases = LoopMode.allCases
        let currentIndex = allCases.firstIndex(of: self) ?? 0
        let nextIndex = (currentIndex + 1) % allCases.count
        return allCases[nextIndex]
    }
}

/// Configuration for the media gallery
public struct MediaGalleryConfiguration {
    public var slideshowDuration: TimeInterval
    public var showControls: Bool
    public var backgroundColor: Color
    public var customActions: [MediaGalleryAction]
    /// Called when the user changes the VR projection override for a media item.
    /// Parameters: (mediaItem, newProjection) — newProjection is nil when clearing the override.
    public var onVRProjectionChange: ((any MediaItem, VRProjection?) -> Void)?
    /// Initial VR projection overrides keyed by media item index, loaded from persistent storage.
    public var initialVRProjectionOverrides: [Int: VRProjection]

    public init(
        slideshowDuration: TimeInterval = 5.0,
        showControls: Bool = true,
        backgroundColor: Color = .black,
        customActions: [MediaGalleryAction] = [],
        onVRProjectionChange: ((any MediaItem, VRProjection?) -> Void)? = nil,
        initialVRProjectionOverrides: [Int: VRProjection] = [:]
    ) {
        self.slideshowDuration = slideshowDuration
        self.showControls = showControls
        self.backgroundColor = backgroundColor
        self.customActions = customActions
        self.onVRProjectionChange = onVRProjectionChange
        self.initialVRProjectionOverrides = initialVRProjectionOverrides
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

    /// Background playback service for audio/video
    @ObservedObject private var playbackService = MediaPlaybackService.shared
    /// Download manager for observing download state
    @ObservedObject private var downloadManager = MediaDownloadManager.shared

    @State private var currentIndex: Int
    @State private var isSlideshowPlaying = false
    @State private var isZoomed = false

    /// Whether the current item is using a VR sphere projection (disables swipe navigation so drag controls the VR camera).
    /// Flat crop projections (SBS/TB/HSBS/HTB) are NOT sphere-based — swipe navigation stays enabled.
    private var isCurrentItemVRSphere: Bool {
        guard currentIndex >= 0 && currentIndex < mediaItems.count else { return false }
        let proj = effectiveVRProjection(for: currentIndex)
        return proj?.requiresSphere == true
    }

    /// Whether ANY VR projection is active (sphere or flat crop). Used for 3D/2D button state.
    private var isCurrentItemVRActive: Bool {
        guard currentIndex >= 0 && currentIndex < mediaItems.count else { return false }
        let proj = effectiveVRProjection(for: currentIndex)
        return proj != nil
    }

    /// Whether the current item is in 2D flat crop mode (non-sphere, non-nil, non-.flat).
    /// .flat means "off" for auto-detected VR items, flat crop means showing single eye.
    private var isCurrentItem2DMode: Bool {
        guard currentIndex >= 0 && currentIndex < mediaItems.count else { return false }
        guard let proj = effectiveVRProjection(for: currentIndex) else { return false }
        return !proj.requiresSphere && proj != .flat
    }

    /// The effective VR projection for the current item (auto-detected or manual override)
    private func effectiveVRProjection(for index: Int) -> VRProjection? {
        vrProjectionOverrides[index] ?? mediaItems[index].vrProjection
    }
    @State private var wasPlayingBeforeZoom = false
    @State private var slideshowTimer: Timer?
    @State private var showControls = true
    @State private var shareItem: Any?
    @State private var showShareSheet = false
    @State private var showFlatProjectionPicker = false
    @State private var currentCaption: String?
    @State private var showCaption = false
    @State private var hideControlsTimer: Timer?
    @State private var controlsHoverTimer: Timer?
    @State private var customSlideshowDuration: TimeInterval?
    @State private var videoSlideStartTime: Date?
    @State private var videoLoopCount: Int = 0
    @State private var isFullscreen = false
    @State private var loopMode: LoopMode = .all
    @State private var autoLoopApplied = false
    @State private var isShuffled = false
    @State private var shuffledIndices: [Int] = []
    @State private var shuffledPosition: Int = 0  // Current position in shuffled order
    /// Manual VR projection override — keyed by item index. Allows treating any video as VR.
    @State private var vrProjectionOverrides: [Int: VRProjection]
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
        _vrProjectionOverrides = State(initialValue: configuration.initialVRProjectionOverrides)
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
                        },
                        onManualPlayTriggered: {
                            // Start slideshow when user manually plays media
                            if !isSlideshowPlaying {
                                startSlideshow()
                            }
                        },
                        vrProjectionOverride: vrProjectionOverrides[index],
                        onVRProjectionChange: { newProjection in
                            vrProjectionOverrides[index] = newProjection
                            configuration.onVRProjectionChange?(mediaItems[index], newProjection)
                        },
                        onVRTapToggleControls: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls.toggle()
                            }
                            if showControls {
                                scheduleHideControls()
                            } else {
                                cancelHideControls()
                            }
                        },
                        onNextItem: { nextItem(); resetControlsTimer() },
                        onPreviousItem: { previousItem(); resetControlsTimer() },
                        onVRDurationKnown: { dur in
                            guard !autoLoopApplied, dur > 0, dur < 120 else { return }
                            autoLoopApplied = true
                            if loopMode != .one {
                                loopMode = .one
                                syncLoopModeToService()
                            }
                        }
                    )
                    .opacity(currentIndex == index ? 1 : 0)
                    .zIndex(currentIndex == index ? 1 : 0)
                    .allowsHitTesting(currentIndex == index)
                    #if !os(tvOS)
                    .simultaneousGesture(
                        // Navigation gesture - only activates for large horizontal swipes when not zoomed
                        // Disabled for VR items so drag controls the VR camera instead
                        DragGesture(minimumDistance: 100)
                            .onEnded { value in
                                guard !isZoomed else { return }
                                guard !isCurrentItemVRSphere else { return }
                                guard !MediaControlsInteractionState.shared.isInteracting else { return }
                                let horizontalAmount = abs(value.translation.width)
                                let verticalAmount = abs(value.translation.height)
                                if horizontalAmount > verticalAmount * 2 && horizontalAmount > 100 {
                                    if value.translation.width < 0 {
                                        nextItem()
                                    } else {
                                        previousItem()
                                    }
                                }
                            }
                    )
                    #endif
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentIndex)
            .transition(.opacity)
            .ignoresSafeArea()
            .onChange(of: currentIndex) { _, newIndex in
                handleIndexChanged(newIndex)
            }
            .onChange(of: playbackService.currentIndex) { _, newServiceIndex in
                // Sync local index when playback service changes (e.g., from lock screen controls)
                guard playbackService.externalPlaybackMode else { return }
                // Map the service index (within cached items) to the full media items index
                let cachedItems = mediaItems.filter { item in
                    (item.type == .video || item.type == .audio) &&
                    MediaDownloadManager.shared.isCached(mediaItem: item)
                }
                guard newServiceIndex < cachedItems.count else { return }
                let cachedItem = cachedItems[newServiceIndex]
                if let fullIndex = mediaItems.firstIndex(where: { $0.id == cachedItem.id }), fullIndex != currentIndex {
                    currentIndex = fullIndex
                }
            }
            .onChange(of: playbackService.duration) { _, newDuration in
                guard !autoLoopApplied, newDuration > 0, newDuration < 120 else { return }
                autoLoopApplied = true
                if loopMode != .one {
                    loopMode = .one
                    syncLoopModeToService()
                }
            }
            .onChange(of: downloadManager.downloadState) { _, newState in
                // Show controls when download starts so user can see progress
                if case .downloading = newState {
                    if !showControls {
                        withAnimation(.easeIn(duration: 0.2)) {
                            showControls = true
                        }
                    }
                    cancelHideControls()
                }
            }

            // Controls on top so they receive taps
            if configuration.showControls && showControls {
                VStack(spacing: 0) {
                    // Top: Slide counter and buttons
                    HStack {
                        // Slide counter on the left
                        Text("\(currentIndex + 1) / \(mediaItems.count)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .mediaStreamGlassCapsule()

                        Spacer()

                        // Right side buttons
                        HStack(spacing: 12) {
                            // Download button for current item only (slideshow mode)
                            MediaDownloadButton(
                                mediaItems: [mediaItems[currentIndex]],
                                headerProvider: { url in await MediaStreamConfiguration.headersAsync(for: url) }
                            )

                            // Custom action buttons
                            ForEach(configuration.customActions) { customAction in
                                MediaStreamGlassButton(action: { customAction.action(currentIndex); resetControlsTimer() }) {
                                    Image(systemName: customAction.icon)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.primary)
                                }
                            }

                            // VR mode toggle for video items
                            // Three states: 3D (sphere VR, lit) → 2D (flat crop, lit) → Off (gray)
                            if mediaItems[currentIndex].type == .video {
                                MediaStreamGlassButton(action: {
                                    if isCurrentItemVRSphere {
                                        // 3D sphere → 2D flat crop (SBS by default)
                                        let flatProj: VRProjection = {
                                            // If file was auto-detected as SBS/TB, use that flat equivalent
                                            if let autoProj = mediaItems[currentIndex].vrProjection {
                                                if autoProj.isSBS { return .sbs }
                                                if autoProj.isTB { return .tb }
                                            }
                                            return .sbs
                                        }()
                                        vrProjectionOverrides[currentIndex] = flatProj
                                        configuration.onVRProjectionChange?(mediaItems[currentIndex], flatProj)
                                    } else if isCurrentItem2DMode {
                                        // 2D flat crop → Off
                                        if mediaItems[currentIndex].vrProjection != nil {
                                            // Auto-detected as VR — force off with .flat override
                                            vrProjectionOverrides[currentIndex] = .flat
                                            configuration.onVRProjectionChange?(mediaItems[currentIndex], .flat)
                                        } else {
                                            // Manually enabled — just clear the override
                                            vrProjectionOverrides.removeValue(forKey: currentIndex)
                                            configuration.onVRProjectionChange?(mediaItems[currentIndex], nil)
                                        }
                                    } else {
                                        // Off → 3D sphere (enable with default 360 projection)
                                        vrProjectionOverrides[currentIndex] = .equirectangular360
                                        configuration.onVRProjectionChange?(mediaItems[currentIndex], .equirectangular360)
                                    }
                                    resetControlsTimer()
                                }) {
                                    if isCurrentItem2DMode {
                                        // 2D mode: show "2D" label, lit
                                        Text("2D")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        // 3D or Off: show 3D icon
                                        Image(systemName: "view.3d")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(isCurrentItemVRSphere ? Color.accentColor : .primary)
                                    }
                                }

                                // Long-press / secondary: projection picker for fine-grained control
                                if isCurrentItemVRActive, let proj = effectiveVRProjection(for: currentIndex), !proj.requiresSphere, proj != .flat {
                                    Button {
                                        showFlatProjectionPicker = true
                                        resetControlsTimer()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.system(size: 10, weight: .semibold))
                                            Text(proj.shortLabel)
                                                .font(.system(size: 12, weight: .medium))
                                        }
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                    .mediaStreamGlassCapsule()
                                }
                            }

                            // Share button
                            MediaStreamGlassButton(action: { shareCurrentItem(); resetControlsTimer() }) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }

                            // Close/Back button
                            MediaStreamGlassButton(action: {
                                if let onBackToGrid = onBackToGrid {
                                    onBackToGrid()
                                } else {
                                    onDismiss()
                                }
                            }) {
                                Image(systemName: onBackToGrid != nil ? "arrow.left" : "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
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

                    // Controls at bottom with extra padding for video/audio controls
                    controlsView
                        .padding(.bottom, (mediaItems[currentIndex].type == .video || mediaItems[currentIndex].type == .audio) ? 140 : 20)
                }
                .allowsHitTesting(true)
            }

            // Flat crop projection picker overlay
            if showFlatProjectionPicker {
                flatProjectionPickerOverlay
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
            setupPlaybackService()
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: MediaPlaybackService.shouldPauseForBackgroundNotification)) { _ in
            // Only stop slideshow for NON-CACHED media when entering background
            // Cached media should continue playing in background
            let currentItem = mediaItems[currentIndex]
            guard !MediaDownloadManager.shared.isCached(mediaItem: currentItem) else {
                return // Don't stop slideshow for cached media
            }

            if isSlideshowPlaying {
                stopSlideshow()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MediaPlaybackService.externalTrackChangedNotification)) { notification in
            // Handle track changes from lock screen/Control Center controls
            guard playbackService.externalPlaybackMode else { return }
            guard let userInfo = notification.userInfo,
                  let cachedIndex = userInfo["index"] as? Int else { return }

            // Map the cached items index to the full media items index
            let cachedItems = mediaItems.filter { item in
                (item.type == .video || item.type == .audio) &&
                MediaDownloadManager.shared.isCached(mediaItem: item)
            }
            guard cachedIndex < cachedItems.count else { return }
            let cachedItem = cachedItems[cachedIndex]

            if let fullIndex = mediaItems.firstIndex(where: { $0.id == cachedItem.id }), fullIndex != currentIndex {
                // Check if this is a restart request
                let isRestart = userInfo["restart"] as? Bool ?? false
                if isRestart && fullIndex == currentIndex {
                    // Just need to restart current video/audio - increment loop count
                    videoLoopCount += 1
                } else {
                    // Ensure slideshow is "playing" so the new track auto-plays
                    if !isSlideshowPlaying {
                        isSlideshowPlaying = true
                    }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentIndex = fullIndex
                    }
                    onIndexChange?(fullIndex)
                }
            } else if userInfo["restart"] as? Bool == true {
                // Restart current item
                videoLoopCount += 1
            }
        }
        #endif
        .onDisappear {
            stopSlideshow()
            cancelHideControls()
            cleanupPlaybackService()

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

    /// Projection picker overlay for flat crop VR modes (SBS/TB/HSBS/HTB).
    /// Mirrors VRVideoPlayerView's projectionPickerOverlay but works outside the sphere renderer.
    private var flatProjectionPickerOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFlatProjectionPicker = false
                    }
                }

            VStack(spacing: 2) {
                Text("Projection")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(VRProjection.allCases, id: \.self) { proj in
                            let currentProj = effectiveVRProjection(for: currentIndex) ?? .equirectangular360
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showFlatProjectionPicker = false
                                }
                                vrProjectionOverrides[currentIndex] = proj
                                configuration.onVRProjectionChange?(mediaItems[currentIndex], proj)
                            } label: {
                                HStack {
                                    Text(proj.displayName)
                                        .foregroundColor(.white)
                                    Spacer()
                                    if proj == currentProj {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.cyan)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(proj == currentProj ? Color.white.opacity(0.15) : Color.clear)
                                )
                            }
                            #if os(macOS)
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .frame(maxWidth: 260, maxHeight: 420)
        }
    }

    private var controlsView: some View {
        // All controls in one row
        HStack(spacing: 16) {
            // Previous button
            MediaStreamGlassButton(action: { previousItem(); resetControlsTimer() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            // Shuffle toggle button
            MediaStreamGlassButton(action: { toggleShuffle(); resetControlsTimer() }) {
                Image(systemName: isShuffled ? "shuffle" : "shuffle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isShuffled ? Color.accentColor : .primary)
            }

            // Loop mode toggle button
            MediaStreamGlassButton(action: { cycleLoopMode(); resetControlsTimer() }) {
                Image(systemName: loopMode.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(loopMode == .off ? .primary : Color.accentColor)
            }

            // Slideshow Play/Pause button with duration context menu
            MediaStreamGlassButton(action: { toggleSlideshow(); resetControlsTimer() }, size: 44) {
                Image(systemName: isSlideshowPlaying ? "stop.fill" : "play.square.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
            }
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

            // PiP toggle button - only show for video when cached
            #if canImport(UIKit) && !os(macOS)
            if mediaItems[currentIndex].type == .video && MediaDownloadManager.shared.isCached(mediaItem: mediaItems[currentIndex]) {
                MediaStreamGlassButton(action: { playbackService.togglePiP(); resetControlsTimer() }) {
                    Image(systemName: playbackService.isPiPActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            #endif

            // Caption toggle button (if caption exists)
            if currentCaption != nil {
                MediaStreamGlassButton(action: { withAnimation { showCaption.toggle() }; resetControlsTimer() }) {
                    Image(systemName: showCaption ? "text.bubble.fill" : "text.bubble")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }

            // Next button
            MediaStreamGlassButton(action: { nextItem(); resetControlsTimer() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
    }

    private func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            // Create shuffled indices starting from current position
            shuffledIndices = Array(0..<mediaItems.count).shuffled()
            // Find current index in shuffled array and move to front
            if let pos = shuffledIndices.firstIndex(of: currentIndex) {
                shuffledIndices.remove(at: pos)
                shuffledIndices.insert(currentIndex, at: 0)
            }
            shuffledPosition = 0
        } else {
            shuffledIndices = []
            shuffledPosition = 0
        }
        // Sync with playback service
        playbackService.toggleShuffle()
    }

    private func cycleLoopMode() {
        loopMode = loopMode.next()
        // Sync with playback service
        syncLoopModeToService()
    }

    /// Re-shuffle indices for next loop iteration (doesn't start with current)
    private func reshuffleIndices() {
        shuffledIndices = Array(0..<mediaItems.count).shuffled()
    }

    // MARK: - Background Playback Service Integration
    // Background playback is only enabled for locally cached media.
    // iOS kills the rclone rc server when backgrounded, so remote URLs don't work.
    // See MediaDownloadManager for local caching support.

    /// Setup the playback service for background audio/video playback
    /// Only includes cached items in the playlist
    private func setupPlaybackService() {
        let currentItem = mediaItems[currentIndex]

        // Only enable background playback for cached items
        guard MediaDownloadManager.shared.isCached(mediaItem: currentItem) else {
            playbackService.externalPlaybackMode = false
            return
        }

        // Filter to only cached video/audio items
        let cachedItems = mediaItems.filter { item in
            (item.type == .video || item.type == .audio) &&
            MediaDownloadManager.shared.isCached(mediaItem: item)
        }

        guard !cachedItems.isEmpty else {
            playbackService.externalPlaybackMode = false
            return
        }

        // Find the start index within cached items
        let startIndex = cachedItems.firstIndex(where: { $0.id == currentItem.id }) ?? 0

        // Set up the playlist with cached items
        playbackService.setPlaylist(cachedItems, startIndex: startIndex)
        playbackService.externalPlaybackMode = true

        // Track changes from external controls will be observed via playbackService.currentIndex
        // The onChange handler for playbackService.currentIndex syncs our local state
        playbackService.onTrackChanged = nil

        // Update Now Playing info with artwork for lock screen/Control Center
        Task {
            await playbackService.updateNowPlayingForCurrentItem()
        }
    }

    /// Cleanup playback service when gallery is dismissed
    private func cleanupPlaybackService() {
        playbackService.externalPlaybackMode = false
        playbackService.onTrackChanged = nil
    }

    /// Sync local loop mode to the playback service
    private func syncLoopModeToService() {
        let serviceMode: PlaybackLoopMode
        switch loopMode {
        case .off: serviceMode = .off
        case .all: serviceMode = .all
        case .one: serviceMode = .one
        }
        playbackService.loopMode = serviceMode
    }

    private func captionView(caption: String) -> some View {
        ScrollView {
            Text(caption)
                .font(.body)
                .foregroundStyle(.primary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
        }
        .frame(maxHeight: 150) // Limit height to make it scrollable
        .mediaStreamGlassCard(cornerRadius: 8)
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
                // Don't reset videoLoopCount here - nextItemAfterVideoCompletion will increment it
                // Resetting then incrementing synchronously (1→0→1) causes SwiftUI onChange to miss the change

                // Now animate the transition after the pause
                self.nextItemAfterVideoCompletion()
            }
        }
    }

    private func handleIndexChanged(_ newIndex: Int) {
        autoLoopApplied = false
        checkAndHandleVideo()
        loadCaption()
        resetControlsTimer()

        // Sync current index to the playback service (for background controls)
        if playbackService.externalPlaybackMode {
            // Find the index within the cached items playlist
            let cachedItems = mediaItems.filter { item in
                (item.type == .video || item.type == .audio) &&
                MediaDownloadManager.shared.isCached(mediaItem: item)
            }
            let currentItem = mediaItems[newIndex]
            if let cachedIndex = cachedItems.firstIndex(where: { $0.id == currentItem.id }) {
                // Update the service's current index to match our gallery position
                playbackService.currentIndex = cachedIndex
            }
        }

        // Update Now Playing info for the new media item
        Task {
            await playbackService.updateNowPlayingForCurrentItem()
        }
    }

    private func loadCaption() {
        // Capture values to avoid referencing self in detached task
        let index = currentIndex
        let item = mediaItems[index]
        let itemId = item.id

        // Use detached task to ensure caption loading doesn't block UI
        Task.detached(priority: .userInitiated) {
            let caption = await item.getCaption()

            await MainActor.run {
                // Only update if we're still on the same item (user may have swiped)
                guard self.currentIndex == index && self.mediaItems[self.currentIndex].id == itemId else {
                    return
                }

                if let caption = caption {
                    self.currentCaption = caption
                } else {
                    self.currentCaption = nil
                    self.showCaption = false
                }
            }
        }
    }

    private func checkAndHandleVideo() {
        // Video/audio playback is handled by ZoomableMediaView
        // Just track slideshow state for videos and audio
        let currentItem = mediaItems[currentIndex]
        if currentItem.type == .video || currentItem.type == .audio {
            if isSlideshowPlaying {
                videoSlideStartTime = Date()
                videoLoopCount = 0
                print("📺 Video/audio slide started during slideshow")
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

        // For videos and audio, record start time for duration tracking
        if currentItem.type == .video || currentItem.type == .audio {
            videoSlideStartTime = Date()
            videoLoopCount = 0
            print("📺 Slideshow started on video/audio - will play to completion")
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

        // Videos and audio handle their own completion via onVideoComplete callback
        // Don't schedule a timer for videos or audio
        if currentItem.type == .video || currentItem.type == .audio {
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
        let newIndex: Int

        if isShuffled {
            // In shuffle mode, advance through shuffled order
            let nextPosition = shuffledPosition + 1

            if nextPosition >= shuffledIndices.count {
                // Reached end of shuffled list
                switch loopMode {
                case .off:
                    stopSlideshow()
                    return
                case .all:
                    // Re-shuffle for next loop iteration
                    reshuffleIndices()
                    shuffledPosition = 0
                    newIndex = shuffledIndices[0]
                case .one:
                    // Stay on current item (will be handled by video completion separately)
                    return
                }
            } else {
                shuffledPosition = nextPosition
                newIndex = shuffledIndices[nextPosition]
            }
        } else {
            // Normal sequential order
            let nextIndex = currentIndex + 1

            if nextIndex >= mediaItems.count {
                // Reached end of list
                switch loopMode {
                case .off:
                    stopSlideshow()
                    return
                case .all:
                    newIndex = 0
                case .one:
                    // Stay on current item
                    return
                }
            } else {
                newIndex = nextIndex
            }
        }

        // If the new index is the same as current (single item with loop all),
        // for images/animated images: just reschedule the timer to show again
        // for videos/audio: increment videoLoopCount to trigger replay
        if newIndex == currentIndex {
            let item = mediaItems[currentIndex]
            if item.type == .video || item.type == .audio {
                videoLoopCount += 1
            }
            // For images, reschedule timer to continue the slideshow on same item
            if isSlideshowPlaying {
                scheduleNextItemTimer()
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            currentIndex = newIndex
        }

        // Notify parent of index change
        onIndexChange?(currentIndex)

        if isSlideshowPlaying {
            scheduleNextItemTimer()
        }
    }

    private func nextItemAfterVideoCompletion() {
        // Loop one mode: replay the same video/audio
        if loopMode == .one {
            videoLoopCount += 1
            return
        }

        // Special transition for videos that doesn't start animation until called
        // This ensures video plays to completion before crossfade starts
        let newIndex: Int

        if isShuffled {
            let nextPosition = shuffledPosition + 1

            if nextPosition >= shuffledIndices.count {
                switch loopMode {
                case .off:
                    stopSlideshow()
                    return
                case .all:
                    // Re-shuffle for next loop iteration
                    reshuffleIndices()
                    shuffledPosition = 0
                    newIndex = shuffledIndices[0]
                case .one:
                    return
                }
            } else {
                shuffledPosition = nextPosition
                newIndex = shuffledIndices[nextPosition]
            }
        } else {
            let nextIndex = currentIndex + 1

            if nextIndex >= mediaItems.count {
                switch loopMode {
                case .off:
                    stopSlideshow()
                    return
                case .all:
                    newIndex = 0
                case .one:
                    return
                }
            } else {
                newIndex = nextIndex
            }
        }

        // If the new index is the same as current (single item with loop all),
        // increment videoLoopCount to trigger replay instead of setting same index
        if newIndex == currentIndex {
            videoLoopCount += 1
            return
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            currentIndex = newIndex
        }

        // Notify parent of index change
        onIndexChange?(currentIndex)

        if isSlideshowPlaying {
            scheduleNextItemTimer()
        }
    }

    private func previousItem() {
        let newIndex: Int

        if isShuffled {
            let prevPosition = shuffledPosition - 1

            if prevPosition < 0 {
                switch loopMode {
                case .off:
                    // Can't go back further
                    return
                case .all:
                    shuffledPosition = shuffledIndices.count - 1
                    newIndex = shuffledIndices[shuffledPosition]
                case .one:
                    return
                }
            } else {
                shuffledPosition = prevPosition
                newIndex = shuffledIndices[prevPosition]
            }
        } else {
            let prevIndex = currentIndex - 1

            if prevIndex < 0 {
                switch loopMode {
                case .off:
                    return
                case .all:
                    newIndex = mediaItems.count - 1
                case .one:
                    return
                }
            } else {
                newIndex = prevIndex
            }
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            currentIndex = newIndex
        }

        // Notify parent of index change
        onIndexChange?(currentIndex)

        if isSlideshowPlaying {
            scheduleNextItemTimer()
        }
    }

    /// Helper to schedule timer based on current item type
    private func scheduleNextItemTimer() {
        let item = mediaItems[currentIndex]
        // Schedule timer for images and animated images
        // Videos/audio handle their own completion via onVideoComplete
        if item.type == .image || item.type == .animatedImage {
            Task {
                await scheduleSlideshowTimer()
            }
        }
        // Videos and audio will play automatically via shouldAutoplay
        // No timer needed - completion callback will advance
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
                #if os(iOS) || os(tvOS)
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
                #elseif os(macOS)
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

        #if os(iOS) || os(tvOS)
        guard let data = image.pngData() else {
            print("⚠️ Failed to create PNG data from UIImage")
            return nil
        }
        #elseif os(macOS)
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
        // Don't start auto-dismiss timer while projection picker is open
        guard !showFlatProjectionPicker else { return }
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { _ in
            Task { @MainActor [self] in
                // Don't hide controls while downloading or while projection picker is open
                if case .downloading = MediaDownloadManager.shared.downloadState {
                    return
                }
                guard !self.showFlatProjectionPicker else { return }
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

    init(
        id: UUID = UUID(),
        imageLoader: @escaping @Sendable () async -> PlatformImage?,
        caption: String? = nil,
        type: MediaType = .image,
        animatedDuration: TimeInterval? = nil
    ) {
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

    init(
        id: UUID = UUID(),
        videoURL: URL,
        thumbnailLoader: @escaping @Sendable () async -> PlatformImage?,
        caption: String? = nil,
        duration: TimeInterval? = nil
    ) {
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
