import SwiftUI
import AVKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Custom animated image view that properly displays animations
struct AnimatedImageView: View {
    let image: PlatformImage
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        GeometryReader { geometry in
            #if canImport(UIKit)
            AnimatedImageRepresentable(image: image, containerSize: geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                .allowsHitTesting(false)  // Pass gestures through to parent
            #elseif canImport(AppKit)
            AnimatedImageRepresentable(image: image, containerSize: geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                .allowsHitTesting(false)  // Pass gestures through to parent
            #endif
        }
        .contentShape(Rectangle())  // Make entire area tappable for gestures
        .scaleEffect(scale)
        .offset(offset)
    }
}

#if canImport(UIKit)
struct AnimatedImageRepresentable: UIViewRepresentable {
    let image: UIImage
    let containerSize: CGSize

    func makeUIView(context: Context) -> UIView {
        // Use a container view to ensure proper layout
        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit  // Always fit within bounds
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        imageView.isUserInteractionEnabled = false  // Allow gestures to pass through to SwiftUI
        imageView.tag = 100  // Tag to find it later
        imageView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)

        // Constrain imageView to fill container
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        imageView.image = image
        // Start animation if this is an animated image
        if image.images != nil {
            imageView.animationImages = image.images
            imageView.animationDuration = image.duration
            imageView.startAnimating()
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let imageView = uiView.viewWithTag(100) as? UIImageView else { return }

        // Update image if changed
        if imageView.image !== image {
            imageView.image = image
            imageView.animationImages = image.images
            imageView.animationDuration = image.duration
        }

        // Always ensure animation is running if this is an animated image
        // This handles the case where we swipe back to this view
        if image.images != nil && !imageView.isAnimating {
            imageView.startAnimating()
        }
    }

    /// Clean up animation memory when view is removed from hierarchy
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        if let imageView = uiView.viewWithTag(100) as? UIImageView {
            imageView.stopAnimating()
            imageView.animationImages = nil  // Release all frames from memory
            imageView.image = nil
        }
    }
}

/// UIViewRepresentable wrapper for StreamingAnimatedImageView (memory-efficient large GIFs)
struct StreamingAnimatedImageRepresentable: UIViewRepresentable {
    let url: URL
    let containerSize: CGSize

    func makeUIView(context: Context) -> StreamingAnimatedImageView {
        let view = StreamingAnimatedImageView()
        view.backgroundColor = .clear
        view.loadImage(from: url)
        return view
    }

    func updateUIView(_ uiView: StreamingAnimatedImageView, context: Context) {
        // URL changes are handled by parent view recreating this view
    }

    static func dismantleUIView(_ uiView: StreamingAnimatedImageView, coordinator: ()) {
        uiView.stopAnimating()
    }
}
#elseif canImport(AppKit)
struct AnimatedImageRepresentable: NSViewRepresentable {
    let image: NSImage
    let containerSize: CGSize

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image
        imageView.animates = true // Enable animation for animated images
        imageView.canDrawSubviewsIntoLayer = true
        // Prevent NSImageView from enforcing the image's pixel dimensions as its
        // intrinsic size. Without this, the view fights SwiftUI's layout system
        // and may render at screen/image resolution instead of the window size.
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image !== image {
            nsView.image = image
        }
        nsView.animates = true
        // Do not set nsView.frame manually — SwiftUI's .frame() modifier on this
        // representable controls the size. Setting it here can conflict with layout
        // updates during window resize.
    }
}
#endif

/// Custom video player view with controls
struct CustomVideoPlayerView: View {
    let player: AVPlayer
    let mediaItem: any MediaItem
    let shouldAutoplay: Bool
    var showControls: Bool = true
    var isCurrentSlide: Bool = false
    var videoLoopCount: Int = 0
    var onVideoComplete: (() -> Void)? = nil
    var onManualPlayTriggered: (() -> Void)? = nil
    @Binding var savedPosition: Double
    @Binding var wasAtEnd: Bool

    /// Duration threshold for long-form content (7 minutes)
    /// Content >= this duration resumes from last position (podcast/movie behavior)
    /// Content < this duration starts from beginning (music video behavior)
    private static let longFormThreshold: Double = 420.0 // 7 minutes in seconds

    // Store player layer for PiP setup
    @State private var currentPlayerLayer: AVPlayerLayer?

    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isDragging = false
    @State private var showVideoControls = true
    @State private var timeObserver: Any?
    @State private var endTimeObserver: NSObjectProtocol?
    @State private var showVolumeSlider = false
    @State private var scrubPosition: Double = 0
    @State private var volumeCollapseTimer: Timer?
    @State private var hasInitializedNowPlaying = false
    @State private var wasPlayingBeforeUpdate = false

    // Persist volume preference across media items
    @AppStorage("MediaStream_VideoVolume") private var volume: Double = 1.0
    @AppStorage("MediaStream_VideoMuted") private var isMuted: Bool = false

    var body: some View {
        ZStack {
            // Video player layer
            #if canImport(UIKit)
            VideoPlayerRepresentable(player: player) { playerLayer in
                // Defer state modification to avoid "Modifying state during view update"
                DispatchQueue.main.async {
                    // Store the player layer for PiP setup
                    currentPlayerLayer = playerLayer
                    // Setup PiP immediately if this is the current slide
                    if isCurrentSlide {
                        MediaPlaybackService.shared.setupPiP(with: playerLayer)
                    }
                }
            }
            .onChange(of: isCurrentSlide) { _, newValue in
                // Update PiP when this slide becomes current
                if newValue, let playerLayer = currentPlayerLayer {
                    MediaPlaybackService.shared.setupPiP(with: playerLayer)
                }
            }
            #elseif canImport(AppKit)
            VideoPlayerRepresentable(player: player)
            #endif

            // Video controls overlay - sync with parent's showControls
            if showControls {
                VStack(spacing: 0) {
                    Spacer()

                    // Scrub bar at very bottom with play/pause on left
                    HStack(spacing: 12) {
                        // Play/pause button on left
                        MediaStreamGlassButton(action: togglePlayPause) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                        }

                        Text(formatTime(isDragging ? scrubPosition : currentTime))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .monospacedDigit()

                        #if os(tvOS)
                        ProgressView(value: currentTime, total: max(duration, 0.1))
                            .tint(.primary)
                        #else
                        Slider(
                            value: Binding(
                                get: { isDragging ? scrubPosition : currentTime },
                                set: { newValue in
                                    scrubPosition = newValue
                                }
                            ),
                            in: 0...max(duration, 0.1),
                            onEditingChanged: { editing in
                                if editing {
                                    // Starting to drag - capture current position
                                    scrubPosition = currentTime
                                    MediaControlsInteractionState.shared.isInteracting = true
                                } else {
                                    // Finished dragging - seek to scrub position
                                    seekTo(scrubPosition)
                                    MediaControlsInteractionState.shared.isInteracting = false
                                }
                                isDragging = editing
                            }
                        )
                        .tint(.primary)
                        #endif

                        Text(formatTime(duration))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .monospacedDigit()

                        #if !os(tvOS)
                        // Volume controls
                        HStack(spacing: 8) {
                            // Volume slider (expandable)
                            if showVolumeSlider {
                                Slider(value: $volume, in: 0...1) { editing in
                                    if editing {
                                        resetVolumeCollapseTimer()
                                    } else {
                                        applyVolume()
                                        resetVolumeCollapseTimer()
                                    }
                                }
                                .frame(width: 80)
                                .tint(.primary)
                                .onChange(of: volume) { _, newValue in
                                    player.volume = Float(newValue)
                                    if newValue > 0 && isMuted {
                                        isMuted = false
                                        player.isMuted = false
                                    }
                                    resetVolumeCollapseTimer()
                                }
                            }

                            // Volume/mute button
                            MediaStreamGlassButton(action: {
                                if showVolumeSlider {
                                    toggleMute()
                                    resetVolumeCollapseTimer()
                                } else {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showVolumeSlider = true
                                    }
                                    resetVolumeCollapseTimer()
                                }
                            }) {
                                Image(systemName: volumeIcon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                            .onLongPressGesture(minimumDuration: 0.3) {
                                toggleMute()
                            }
                        }
                        #endif
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .mediaStreamGlassBackgroundRounded()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .onTapGesture {
                        // Collapse volume slider when tapping elsewhere on controls
                        if showVolumeSlider {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showVolumeSlider = false
                            }
                        }
                    }
                    .blockParentGestures()
                }
                .transition(.opacity)
                .allowsHitTesting(true)
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
        .onChange(of: shouldAutoplay) { _, newValue in
            if newValue {
                // Check if video is at end
                let currentPos = CMTimeGetSeconds(player.currentTime())
                let isAtEnd = duration > 0 && currentPos >= duration - 1.0

                // Check if this is short-form content
                let isLongForm = duration >= Self.longFormThreshold

                if isAtEnd || (!isLongForm && currentPos > 1.0) {
                    // At end OR short-form content not at beginning: reset to start
                    currentTime = 0.0
                    savedPosition = 0.0
                    wasAtEnd = false

                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        Task { @MainActor in
                            self.player.play()
                            self.isPlaying = true
                        }
                    }
                } else {
                    // Long-form content: resume from current position
                    player.play()
                    isPlaying = true
                }
            } else {
                player.pause()
                isPlaying = false
            }
        }
        .onChange(of: videoLoopCount) { oldValue, newValue in
            // When loop count increments, restart the video
            if newValue > oldValue && shouldAutoplay {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in
                        self.currentTime = 0.0
                        self.savedPosition = 0.0
                        self.wasAtEnd = false
                        self.player.play()
                        self.isPlaying = true
                    }
                }
            }
        }
        .onChange(of: isCurrentSlide) { oldValue, newValue in
            // When this slide is no longer current, pause the video
            if !newValue && oldValue {
                player.pause()
                isPlaying = false
            }
            // When this video becomes the current slide, just reset if at end
            if newValue && !oldValue {
                let currentPos = CMTimeGetSeconds(player.currentTime())
                let isAtEnd = wasAtEnd || (duration > 0 && currentPos >= duration - 1.0)

                if isAtEnd {
                    currentTime = 0.0
                    savedPosition = 0.0
                    wasAtEnd = false

                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        Task { @MainActor in
                            if self.shouldAutoplay {
                                self.player.play()
                                self.isPlaying = true
                            }
                        }
                    }
                }
            }
        }
    }

    private func setupPlayer() {
        // Clean up any existing observers first to prevent duplicates
        cleanupPlayer()

        // Configure audio session for playback (iOS only)
        #if canImport(UIKit) && !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Audio session configuration failed
        }
        #endif

        // Apply persisted volume settings
        player.isMuted = isMuted
        player.volume = Float(volume)

        // Get duration if we don't have it
        if let currentItem = player.currentItem {
            let durationSeconds = CMTimeGetSeconds(currentItem.duration)
            if durationSeconds.isFinite && durationSeconds > 0 {
                duration = durationSeconds
            }
        }

        // Setup observers
        setupObservers()

        // Determine if this is long-form content that should resume
        let isLongForm = duration >= Self.longFormThreshold

        // Check if we need to reset position
        let currentPos = CMTimeGetSeconds(player.currentTime())
        let isAtEnd = wasAtEnd || (duration > 0 && currentPos >= duration - 1.0)

        if isAtEnd {
            // Always reset if at end
            currentTime = 0.0
            savedPosition = 0.0
            wasAtEnd = false
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        } else if !isLongForm && currentPos > 0 {
            // Short-form content: start from beginning (music video behavior)
            currentTime = 0.0
            savedPosition = 0.0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // Long-form content: keep current position (movie/podcast behavior)

        // Start playing if slideshow is active
        if shouldAutoplay {
            player.play()
            isPlaying = true
        }
    }

    private func setupObservers() {
        // Clean up any existing observers first to prevent duplicates
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endTimeObserver {
            NotificationCenter.default.removeObserver(observer)
            endTimeObserver = nil
        }

        // Add periodic time observer
        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            // Update current time if not dragging
            Task { @MainActor in
                let currentTimeValue = CMTimeGetSeconds(time)

                if !self.isDragging {
                    self.currentTime = currentTimeValue
                    // Save position for restoration
                    self.savedPosition = currentTimeValue
                }

                // Update duration if needed
                if let currentItem = self.player.currentItem {
                    let durationSeconds = CMTimeGetSeconds(currentItem.duration)
                    if durationSeconds.isFinite && self.duration != durationSeconds {
                        self.duration = durationSeconds
                    }
                }

                // Update play state
                let nowPlaying = self.player.rate > 0
                let justStartedPlaying = nowPlaying && !self.wasPlayingBeforeUpdate
                self.wasPlayingBeforeUpdate = nowPlaying
                self.isPlaying = nowPlaying

                // Update external playback position for cached media (enables lock screen controls)
                if MediaDownloadManager.shared.isCached(mediaItem: self.mediaItem) {
                    // Enable external playback mode so remote commands are relayed to views
                    if !MediaPlaybackService.shared.externalPlaybackMode {
                        MediaPlaybackService.shared.externalPlaybackMode = true
                    }
                    // Register player for direct control (faster than notifications in background)
                    MediaPlaybackService.shared.registerExternalPlayer(self.player, forMediaId: self.mediaItem.id)

                    // Initialize Now Playing metadata when playback first starts
                    if justStartedPlaying && !self.hasInitializedNowPlaying {
                        self.hasInitializedNowPlaying = true
                        let item = self.mediaItem
                        let currentDuration = self.duration
                        Task {
                            // Load metadata directly from the media item
                            let metadata = await item.getAudioMetadata()
                            let artwork = await item.loadImage()

                            // Get title from metadata or filename
                            var title = metadata?.title
                            if title == nil || title?.isEmpty == true {
                                if let cacheKey = item.diskCacheKey {
                                    title = URL(fileURLWithPath: cacheKey).deletingPathExtension().lastPathComponent
                                } else if let sourceURL = item.sourceURL {
                                    title = sourceURL.deletingPathExtension().lastPathComponent
                                }
                            }

                            await MainActor.run {
                                MediaPlaybackService.shared.updateNowPlayingForExternalPlayer(
                                    mediaItem: item,
                                    title: title,
                                    artist: metadata?.artist,
                                    album: metadata?.album,
                                    artwork: artwork,
                                    duration: currentDuration,
                                    isVideo: true
                                )
                            }
                        }
                    }

                    MediaPlaybackService.shared.updateExternalPlaybackPosition(
                        currentTime: self.currentTime,
                        duration: self.duration,
                        isPlaying: self.isPlaying
                    )
                }
            }
        }
        timeObserver = observer

        // Handle video completion - only if we don't already have an observer
        guard endTimeObserver == nil else { return }
        guard let currentItem = player.currentItem else { return }

        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { notification in
            let notificationItem = notification.object as? AVPlayerItem

            Task { @MainActor in
                // Verify this is for our current player item
                guard let notificationItem = notificationItem,
                      notificationItem == self.player.currentItem else {
                    return
                }

                // Verify video actually reached the end
                let currentPos = CMTimeGetSeconds(self.player.currentTime())
                let isAtEnd = self.duration > 0 && currentPos >= (self.duration - 0.1)

                guard isAtEnd else { return }

                self.wasAtEnd = true
                self.onVideoComplete?()
            }
        }
        endTimeObserver = endObserver
    }

    private func cleanupPlayer() {
        // Remove time observer
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }

        // Remove notification observer
        if let observer = endTimeObserver {
            NotificationCenter.default.removeObserver(observer)
            endTimeObserver = nil
        }

        // Cancel volume collapse timer
        volumeCollapseTimer?.invalidate()
        volumeCollapseTimer = nil

        // Pause playback
        player.pause()
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            // If video is at or near the end, restart from beginning
            if duration > 0 && currentTime >= duration - 1.0 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0.0
                savedPosition = 0.0
            }
            player.play()
            wasAtEnd = false
            // Notify that playback was manually triggered (can start slideshow)
            onManualPlayTriggered?()
        }
        isPlaying.toggle()
    }

    private var volumeIcon: String {
        if isMuted || volume == 0 {
            return "speaker.slash.fill"
        } else if volume > 0.66 {
            return "speaker.wave.3.fill"
        } else if volume > 0.33 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.1.fill"
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
        if !isMuted && volume == 0 {
            volume = 0.5
            player.volume = 0.5
        }
    }

    private func applyVolume() {
        player.volume = Float(volume)
        player.isMuted = isMuted
    }

    private func resetVolumeCollapseTimer() {
        volumeCollapseTimer?.invalidate()
        volumeCollapseTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
    }

    private func seekTo(_ time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime)
        // Clear wasAtEnd flag when user manually seeks
        wasAtEnd = false
    }

    private func formatTime(_ time: Double) -> String {
        guard time.isFinite else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// AVFoundation-based audio player controls (no video layer, just controls)
struct AudioPlayerControlsView: View {
    let player: AVPlayer
    let mediaItem: any MediaItem
    let shouldAutoplay: Bool
    var showControls: Bool = true
    var isCurrentSlide: Bool = false
    var videoLoopCount: Int = 0
    var onAudioComplete: (() -> Void)? = nil
    var onManualPlayTriggered: (() -> Void)? = nil
    @Binding var savedPosition: Double
    @Binding var wasAtEnd: Bool

    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isDragging = false
    @State private var timeObserver: Any?
    @State private var endTimeObserver: NSObjectProtocol?
    @State private var showVolumeSlider = false
    @State private var scrubPosition: Double = 0
    @State private var volumeCollapseTimer: Timer?
    @State private var hasSetupPlayer = false
    @State private var hasInitializedNowPlaying = false
    @State private var wasPlayingBeforeUpdate = false

    @AppStorage("MediaStream_AudioVolume") private var volume: Double = 1.0
    @AppStorage("MediaStream_AudioMuted") private var isMuted: Bool = false

    var body: some View {
        // Use opacity instead of conditional to keep time observer running
        // The view must always be present for lifecycle to work correctly
        HStack(spacing: 12) {
            // Play/pause button
            MediaStreamGlassButton(action: togglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Text(formatTime(isDragging ? scrubPosition : currentTime))
                .font(.caption)
                .foregroundStyle(.primary)
                .monospacedDigit()

            #if os(tvOS)
            ProgressView(value: currentTime, total: max(duration, 0.1))
                .tint(.primary)
            #else
            Slider(
                value: Binding(
                    get: { isDragging ? scrubPosition : currentTime },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(duration, 0.1),
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = currentTime
                        MediaControlsInteractionState.shared.isInteracting = true
                    } else {
                        seekTo(scrubPosition)
                        MediaControlsInteractionState.shared.isInteracting = false
                    }
                    isDragging = editing
                }
            )
            .tint(.primary)
            #endif

            Text(formatTime(duration))
                .font(.caption)
                .foregroundStyle(.primary)
                .monospacedDigit()

            #if !os(tvOS)
            // Volume controls
            HStack(spacing: 8) {
                if showVolumeSlider {
                    Slider(value: $volume, in: 0...1) { editing in
                        if !editing {
                            applyVolume()
                        }
                        resetVolumeCollapseTimer()
                    }
                    .frame(width: 80)
                    .tint(.primary)
                    .onChange(of: volume) { _, newValue in
                        player.volume = Float(newValue)
                        if newValue > 0 && isMuted {
                            isMuted = false
                            player.isMuted = false
                        }
                        resetVolumeCollapseTimer()
                    }
                }

                MediaStreamGlassButton(action: {
                    if showVolumeSlider {
                        toggleMute()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showVolumeSlider = true
                        }
                    }
                    resetVolumeCollapseTimer()
                }) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .mediaStreamGlassBackgroundRounded()
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .blockParentGestures()
            .onAppear {
                // Always ensure player is set up when controls appear
                // (observers may have been cleaned up when controls were hidden)
                if !hasSetupPlayer || timeObserver == nil {
                    setupPlayer()
                    hasSetupPlayer = true
                }
            }
            .onDisappear {
                // Clean up observers when view is truly removed from hierarchy
                cleanupObservers()
            }
            .opacity(showControls ? 1 : 0)
            .allowsHitTesting(showControls)
            .onChange(of: shouldAutoplay) { _, newValue in
                if newValue {
                    // Check if this is short-form content that should start from beginning
                    let durationSeconds = duration > 0 ? duration : CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
                    let isLongForm = durationSeconds.isFinite && durationSeconds >= Self.longFormThreshold

                    if !isLongForm && !wasAtEnd {
                        // Short-form content: start from beginning
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            Task { @MainActor in
                                self.currentTime = 0.0
                                self.savedPosition = 0.0
                                self.player.play()
                                self.isPlaying = true
                            }
                        }
                    } else {
                        // Long-form content: resume from current position
                        player.play()
                        isPlaying = true
                    }
                } else {
                    player.pause()
                    isPlaying = false
                }
            }
            .onChange(of: videoLoopCount) { oldValue, newValue in
                // When loop count increments, restart the audio from the beginning
                if newValue > oldValue && shouldAutoplay {
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        Task { @MainActor in
                            self.currentTime = 0.0
                            self.savedPosition = 0.0
                            self.wasAtEnd = false
                            self.player.play()
                            self.isPlaying = true
                        }
                    }
                }
            }
            .onChange(of: isCurrentSlide) { oldValue, newValue in
                // When this slide is no longer current, pause the audio
                if !newValue && oldValue {
                    player.pause()
                    isPlaying = false
                }
            }
        }

    private var volumeIcon: String {
        if isMuted || volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.fill"
        } else if volume < 0.66 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }

    /// Duration threshold for long-form content (7 minutes)
    /// Content >= this duration resumes from last position (podcast behavior)
    /// Content < this duration starts from beginning (music behavior)
    private static let longFormThreshold: Double = 420.0 // 7 minutes in seconds

    private func setupPlayer() {
        // Apply saved volume settings
        player.volume = Float(volume)
        player.isMuted = isMuted

        // Check duration to determine resume behavior
        // Long-form content (>= 7 min): Resume from last position
        // Short-form content (< 7 min): Start from beginning
        var shouldResumePosition = false
        if savedPosition > 0 && !wasAtEnd {
            if let currentItem = player.currentItem {
                let durationSeconds = CMTimeGetSeconds(currentItem.duration)
                if durationSeconds.isFinite && durationSeconds >= Self.longFormThreshold {
                    shouldResumePosition = true
                }
            }
        }

        if shouldResumePosition {
            let cmTime = CMTime(seconds: savedPosition, preferredTimescale: 600)
            player.seek(to: cmTime)
        } else {
            // Short-form content or no saved position - start from beginning
            savedPosition = 0
            player.seek(to: .zero)
        }

        // Add time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                let currentTimeValue = CMTimeGetSeconds(time)

                if !self.isDragging {
                    self.currentTime = currentTimeValue
                    self.savedPosition = currentTimeValue
                }

                // Update duration if needed
                if let currentItem = self.player.currentItem {
                    let durationSeconds = CMTimeGetSeconds(currentItem.duration)
                    if durationSeconds.isFinite && self.duration != durationSeconds {
                        self.duration = durationSeconds
                    }
                }

                // Update play state
                let nowPlaying = self.player.rate > 0
                let justStartedPlaying = nowPlaying && !self.wasPlayingBeforeUpdate
                self.wasPlayingBeforeUpdate = nowPlaying
                self.isPlaying = nowPlaying

                // Update external playback position for cached media (enables lock screen controls)
                if MediaDownloadManager.shared.isCached(mediaItem: self.mediaItem) {
                    // Enable external playback mode so remote commands are relayed to views
                    if !MediaPlaybackService.shared.externalPlaybackMode {
                        MediaPlaybackService.shared.externalPlaybackMode = true
                    }
                    // Register player for direct control (faster than notifications in background)
                    MediaPlaybackService.shared.registerExternalPlayer(self.player, forMediaId: self.mediaItem.id)

                    // Initialize Now Playing metadata when playback first starts
                    if justStartedPlaying && !self.hasInitializedNowPlaying {
                        self.hasInitializedNowPlaying = true
                        let item = self.mediaItem
                        let currentDuration = self.duration
                        Task {
                            // Load metadata directly from the media item
                            let metadata = await item.getAudioMetadata()
                            let artwork = await item.loadImage()

                            // Get title from metadata or filename
                            var title = metadata?.title
                            if title == nil || title?.isEmpty == true {
                                if let cacheKey = item.diskCacheKey {
                                    title = URL(fileURLWithPath: cacheKey).deletingPathExtension().lastPathComponent
                                } else if let sourceURL = item.sourceURL {
                                    title = sourceURL.deletingPathExtension().lastPathComponent
                                }
                            }

                            await MainActor.run {
                                MediaPlaybackService.shared.updateNowPlayingForExternalPlayer(
                                    mediaItem: item,
                                    title: title,
                                    artist: metadata?.artist,
                                    album: metadata?.album,
                                    artwork: artwork,
                                    duration: currentDuration,
                                    isVideo: false
                                )
                            }
                        }
                    }

                    MediaPlaybackService.shared.updateExternalPlaybackPosition(
                        currentTime: self.currentTime,
                        duration: self.duration,
                        isPlaying: self.isPlaying
                    )
                }
            }
        }
        timeObserver = observer

        // Autoplay if requested
        if shouldAutoplay {
            player.play()
            isPlaying = true
        }

        // Get duration when ready (async loading for more accurate duration)
        if let item = player.currentItem {
            Task {
                do {
                    let dur = try await item.asset.load(.duration)
                    let seconds = CMTimeGetSeconds(dur)
                    await MainActor.run {
                        if seconds.isFinite && seconds > 0 {
                            duration = seconds
                        }
                    }
                } catch {
                    // Duration will be updated via time observer as playback progresses
                }
            }
        }

        // Add end observer
        if let currentItem = player.currentItem {
            let endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { notification in
                let notificationItem = notification.object as? AVPlayerItem
                Task { @MainActor in
                    guard let notificationItem = notificationItem,
                          notificationItem == self.player.currentItem else { return }

                    // Trust the AVPlayerItemDidPlayToEndTime notification
                    // For streaming content, duration may not be accurate, so we don't
                    // strictly verify position - the system knows when playback ended
                    self.wasAtEnd = true
                    self.isPlaying = false
                    self.onAudioComplete?()
                }
            }
            endTimeObserver = endObserver
        }
    }

    private func cleanupObservers() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endTimeObserver {
            NotificationCenter.default.removeObserver(observer)
            endTimeObserver = nil
        }
        volumeCollapseTimer?.invalidate()
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            if wasAtEnd {
                player.seek(to: .zero)
                wasAtEnd = false
            }
            player.play()
            // Notify that playback was manually triggered (can start slideshow)
            onManualPlayTriggered?()
        }
        isPlaying.toggle()
    }

    private func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    private func applyVolume() {
        player.volume = Float(volume)
        player.isMuted = isMuted
    }

    private func resetVolumeCollapseTimer() {
        volumeCollapseTimer?.invalidate()
        volumeCollapseTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
    }

    private func seekTo(_ time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime)
        wasAtEnd = false
    }

    private func formatTime(_ time: Double) -> String {
        guard time.isFinite else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#if canImport(UIKit)
struct VideoPlayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    var onPlayerLayerReady: ((AVPlayerLayer) -> Void)?

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        #if os(tvOS)
        view.backgroundColor = .black
        #else
        view.backgroundColor = .systemBackground
        #endif

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)

        context.coordinator.playerLayer = playerLayer
        view.playerLayer = playerLayer

        // Notify that the player layer is ready (for PiP setup)
        onPlayerLayerReady?(playerLayer)

        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // Update player if it changed
        if context.coordinator.playerLayer?.player !== player {
            context.coordinator.playerLayer?.player = player
            // Re-notify with updated layer
            if let layer = context.coordinator.playerLayer {
                onPlayerLayerReady?(layer)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var playerLayer: AVPlayerLayer?
    }
}

class PlayerContainerView: UIView {
    var playerLayer: AVPlayerLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        // Update player layer frame whenever the view's bounds change
        playerLayer?.frame = bounds
    }
}
#elseif canImport(AppKit)
struct VideoPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

class PlayerView: NSView {
    var player: AVPlayer? {
        didSet {
            if let layer = self.layer as? AVPlayerLayer {
                layer.player = player
                layer.setNeedsDisplay()
            }
        }
    }

    private var playerLayer: AVPlayerLayer? {
        return layer as? AVPlayerLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = currentBackgroundColor
        layer.needsDisplayOnBoundsChange = true
        if let player = player {
            layer.player = player
        }
        return layer
    }

    /// Get the correct background color for the current appearance
    private var currentBackgroundColor: CGColor {
        // Resolve windowBackgroundColor in the current appearance context
        var resolvedColor: NSColor?
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor.windowBackgroundColor
        }

        // Convert to CGColor - if conversion fails, use appearance-based fallback
        if let color = resolvedColor, let rgbColor = color.usingColorSpace(.sRGB) {
            return rgbColor.cgColor
        }

        // Fallback using system colors
        let isDark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor.controlBackgroundColor.cgColor : NSColor.windowBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        if let playerLayer = self.layer as? AVPlayerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure layer is set up when view is added to window
        if window != nil, let layer = self.layer as? AVPlayerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = bounds
            layer.backgroundColor = currentBackgroundColor
            CATransaction.commit()
            if let player = player {
                layer.player = player
                layer.setNeedsDisplay()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Update background color when appearance changes (light/dark mode)
        if let layer = self.layer as? AVPlayerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = currentBackgroundColor
            CATransaction.commit()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let playerLayer = self.layer as? AVPlayerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif

/// ViewModifier for conditionally applying double-tap zoom gesture
private struct DoubleTapZoomModifier: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.highPriorityGesture(
                TapGesture(count: 2)
                    .onEnded { _ in action() }
            )
        } else {
            content
        }
    }
}

/// Extension to conditionally apply pan gesture only when zoomed
/// This prevents blocking parent swipe gestures when not zoomed
extension View {
    @ViewBuilder
    func applyPanGesture<G: Gesture>(if condition: Bool, gesture: G) -> some View {
        if condition {
            self.simultaneousGesture(gesture)
        } else {
            self
        }
    }
}

/// A view that displays a single media item with zoom and pan support
struct ZoomableMediaView: View {
    let mediaItem: any MediaItem
    let onZoomChanged: (Bool) -> Void
    var isSlideshowPlaying: Bool = false
    var showControls: Bool = true
    var isCurrentSlide: Bool = false
    var videoLoopCount: Int = 0
    var onVideoComplete: (() -> Void)? = nil
    var onManualPlayTriggered: (() -> Void)? = nil
    /// Manual VR projection override (overrides mediaItem.vrProjection when set)
    var vrProjectionOverride: VRProjection? = nil
    /// Called when VR projection is changed via the in-player picker
    var onVRProjectionChange: ((VRProjection) -> Void)? = nil

    @State private var image: PlatformImage?
    @State private var videoURL: URL?
    @State private var animatedImageURL: URL?  // For WebView-based animated image display
    @State private var useStreaming: Bool = false  // Legacy: Whether to use streaming for this animated image
    @State private var useWebViewForAnimatedImage: Bool = false  // Whether to use WKWebView for animated image
    @State private var isLoading = false  // Start false, only true when actively loading
    @State private var isLoadingMedia = false  // Flag to prevent concurrent loading
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero  // Offset when drag started
    @State private var videoPlayer: AVPlayer?
    @State private var audioPlayer: AVPlayer?
    @State private var savedVideoPosition: Double = 0.0
    @State private var savedAudioPosition: Double = 0.0
    @State private var videoWasAtEnd: Bool = false
    @State private var audioWasAtEnd: Bool = false
    @State private var lastPersistedPosition: Double = 0.0
    @State private var lastPersistTime: Date = .distantPast
    @State private var hasLoadedMedia: Bool = false
    @State private var useWebViewForVideo: Bool = false  // True for WebM, false for AVFoundation-compatible formats
    #if canImport(WebKit)
    @StateObject private var videoController = WebViewVideoController()
    #endif
    @StateObject private var animatedImageController = WebViewAnimatedImageController()

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0

    /// Maximum display size for images to prevent OOM with large files.
    /// At 4x zoom on a typical device (430pt width * 3x scale * 4x zoom = ~5160px),
    /// we need at most ~2000px for display. Full resolution only needed for sharing.
    private static let maxDisplayPixelSize: CGFloat = 2000

    /// Audio player view with album artwork and AVFoundation-based playback controls
    @ViewBuilder
    private func audioPlayerView(geometry: GeometryProxy) -> some View {
        ZStack {
            // Album artwork background (or placeholder)
            VStack {
                Spacer()
                if let artworkImage = image {
                    #if canImport(UIKit)
                    Image(uiImage: artworkImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(geometry.size.width * 0.7, 400))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 10)
                    #elseif canImport(AppKit)
                    Image(nsImage: artworkImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(geometry.size.width * 0.7, 400))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 10)
                    #endif
                } else {
                    // No artwork - show music note placeholder
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: min(geometry.size.width * 0.7, 400), height: min(geometry.size.width * 0.7, 400))
                        Image(systemName: "music.note")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                    }
                }
                Spacer()
            }

            // AVFoundation-based audio playback controls
            if let player = audioPlayer {
                VStack {
                    Spacer()
                    AudioPlayerControlsView(
                        player: player,
                        mediaItem: mediaItem,
                        shouldAutoplay: isSlideshowPlaying && isCurrentSlide,
                        showControls: showControls,
                        isCurrentSlide: isCurrentSlide,
                        videoLoopCount: videoLoopCount,
                        onAudioComplete: onVideoComplete,
                        onManualPlayTriggered: onManualPlayTriggered,
                        savedPosition: $savedAudioPosition,
                        wasAtEnd: $audioWasAtEnd
                    )
                }
            } else if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .padding(.bottom, 80)
                }
            }
        }
    }

    /// Effective VR projection: override takes priority over auto-detected
    private var effectiveVRProjection: VRProjection? {
        vrProjectionOverride ?? mediaItem.vrProjection
    }

    /// VR video content, extracted to reduce type-checker complexity in body.
    @ViewBuilder
    private var vrVideoContent: some View {
        if let vrProj = effectiveVRProjection, let url = videoURL {
            let headers = MediaStreamConfiguration.headers(for: url) ?? [:]
            VRVideoPlayerView(
                url: url,
                initialProjection: vrProj,
                authHeaders: headers,
                onVideoComplete: onVideoComplete,
                onProjectionChange: onVRProjectionChange,
                externalShowControls: showControls
            )
        } else {
            ZStack {
                Color(PlatformColor.adaptiveBackground)
                if isLoading || videoURL != nil {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
        }
    }

    /// Regular (non-VR) video content, extracted to reduce type-checker complexity.
    @ViewBuilder
    private var regularVideoContent: some View {
        #if canImport(WebKit)
        if useWebViewForVideo {
            ZStack {
                CustomWebViewVideoPlayerView(
                    controller: videoController,
                    shouldAutoplay: isSlideshowPlaying && isCurrentSlide,
                    showControls: showControls && videoController.isReady,
                    hasAudio: true,
                    showVolumeSlider: false,
                    onVideoEnd: onVideoComplete
                )

                if !videoController.isReady {
                    Color(PlatformColor.adaptiveBackground)
                    if isLoading || videoURL != nil {
                        ProgressView()
                            .scaleEffect(1.5)
                    }
                }
            }
        } else if let player = videoPlayer {
            CustomVideoPlayerView(
                player: player,
                mediaItem: mediaItem,
                shouldAutoplay: isSlideshowPlaying && isCurrentSlide,
                showControls: showControls,
                isCurrentSlide: isCurrentSlide,
                videoLoopCount: videoLoopCount,
                onVideoComplete: onVideoComplete,
                onManualPlayTriggered: onManualPlayTriggered,
                savedPosition: $savedVideoPosition,
                wasAtEnd: $videoWasAtEnd
            )
        } else {
            ZStack {
                Color(PlatformColor.adaptiveBackground)
                if isLoading || videoURL != nil {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
        }
        #else
        if let player = videoPlayer {
            CustomVideoPlayerView(
                player: player,
                mediaItem: mediaItem,
                shouldAutoplay: isSlideshowPlaying && isCurrentSlide,
                showControls: showControls,
                isCurrentSlide: isCurrentSlide,
                videoLoopCount: videoLoopCount,
                onVideoComplete: onVideoComplete,
                onManualPlayTriggered: onManualPlayTriggered,
                savedPosition: $savedVideoPosition,
                wasAtEnd: $videoWasAtEnd
            )
        } else {
            ZStack {
                Color(PlatformColor.adaptiveBackground)
                if isLoading || videoURL != nil {
                    ProgressView()
                        .scaleEffect(1.5)
                }
            }
        }
        #endif
    }

    /// Animated image content, extracted to reduce type-checker complexity.
    @ViewBuilder
    private func animatedImageContent(geometry: GeometryProxy) -> some View {
        #if canImport(UIKit)
        if useWebViewForAnimatedImage, let url = animatedImageURL {
            // Native CGImageSource animated image display
            WebViewAnimatedImageRepresentable(controller: animatedImageController)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                .scaleEffect(scale)
                .offset(offset)
                #if !os(tvOS)
                .gesture(createMagnificationGesture(in: geometry))
                .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
                #endif
        } else if useStreaming, let url = animatedImageURL {
            // Legacy: streaming view for large GIFs
            StreamingAnimatedImageRepresentable(url: url, containerSize: geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                .scaleEffect(scale)
                .offset(offset)
                #if !os(tvOS)
                .gesture(createMagnificationGesture(in: geometry))
                .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
                #endif
        } else if let image = image {
            // Use regular animated image view for small GIFs (already in memory)
            AnimatedImageView(image: image, scale: scale, offset: offset)
                #if !os(tvOS)
                .gesture(createMagnificationGesture(in: geometry))
                .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
                #endif
        }
        #else  // macOS — native CGImageSource rendering (no WKWebView)
        if useWebViewForAnimatedImage {
            WebViewAnimatedImageRepresentable(controller: animatedImageController)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(createMagnificationGesture(in: geometry))
                .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
        } else if let image = image {
            AnimatedImageView(image: image, scale: scale, offset: offset)
                .gesture(createMagnificationGesture(in: geometry))
                .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
        }
        #endif
    }

    /// Static image content, extracted to reduce type-checker complexity.
    @ViewBuilder
    private func imageContent(image: PlatformImage, geometry: GeometryProxy) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            #if !os(tvOS)
            .gesture(createMagnificationGesture(in: geometry))
            .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
            #endif
        #elseif canImport(AppKit)
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(createMagnificationGesture(in: geometry))
            .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(PlatformColor.adaptiveBackground)

                if isLoading && image == nil && videoURL == nil && animatedImageURL == nil {
                    ProgressView()
                        .scaleEffect(1.5)
                } else {
                    Group {
                        if mediaItem.type == .animatedImage {
                            animatedImageContent(geometry: geometry)
                        } else if mediaItem.type == .image, let image = image {
                            imageContent(image: image, geometry: geometry)
                        } else if mediaItem.type == .video, effectiveVRProjection != nil {
                            vrVideoContent
                        } else if mediaItem.type == .video {
                            regularVideoContent
                        } else if mediaItem.type == .audio {
                            audioPlayerView(geometry: geometry)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            #if !os(tvOS)
            // Only allow double-tap zoom for images, not videos or audio
            .modifier(DoubleTapZoomModifier(
                isEnabled: mediaItem.type != .video && mediaItem.type != .audio,
                action: { handleDoubleTap(in: geometry) }
            ))
            #endif
        }
        .task(id: mediaItem.id) {
            // Reset state when switching to a different media item
            image = nil
            videoURL = nil
            animatedImageURL = nil
            useStreaming = false
            hasLoadedMedia = false
            #if canImport(WebKit)
            videoController.stop()
            #endif

            // Clean up video player (AVFoundation)
            videoPlayer?.pause()
            videoPlayer = nil
            useWebViewForVideo = false
            savedVideoPosition = 0
            videoWasAtEnd = false

            // Clean up audio player
            audioPlayer?.pause()
            audioPlayer = nil
            savedAudioPosition = 0
            audioWasAtEnd = false

            // Reset persist tracking
            lastPersistedPosition = 0
            lastPersistTime = .distantPast

            // Load saved playback position from persistent storage
            // Skip resume during slideshow — just start from the beginning
            if !isSlideshowPlaying, let savedPos = await MediaStreamConfiguration.loadSavedPosition(for: mediaItem), savedPos > 5 {
                if mediaItem.type == .video {
                    savedVideoPosition = savedPos
                } else if mediaItem.type == .audio {
                    savedAudioPosition = savedPos
                }
            }

            // Reset zoom state and notify parent
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            onZoomChanged(false)

            await loadMedia()
        }
        .onChange(of: vrProjectionOverride) { _, newValue in
            guard mediaItem.type == .video else { return }
            if newValue != nil {
                // Switching TO VR mode: stop the regular AVPlayer so it doesn't
                // compete with VRVideoPlayerView's own player
                if let player = videoPlayer {
                    MediaPlaybackService.shared.unregisterExternalPlayer(player, forMediaId: mediaItem.id)
                }
                videoPlayer?.pause()
                videoPlayer = nil
                #if canImport(WebKit)
                if useWebViewForVideo {
                    videoController.stop()
                    useWebViewForVideo = false
                }
                #endif
            } else {
                // Switching FROM VR mode back to regular: reload media
                hasLoadedMedia = false
                videoURL = nil
                Task { await loadMedia() }
            }
        }
        .onChange(of: isCurrentSlide) { oldValue, newValue in
            if mediaItem.type == .video {
                if newValue && !oldValue {
                    // When this slide becomes current (and wasn't before), show first frame for videos
                    // Only if not in slideshow mode (slideshow will autoplay)
                    #if canImport(WebKit)
                    if useWebViewForVideo {
                        if !isSlideshowPlaying && videoController.isReady {
                            videoController.showFirstFrame()
                        }
                    }
                    #endif
                    // AVPlayer doesn't need "show first frame" - it will autoplay when slideshow starts
                } else if !newValue && oldValue {
                    // When navigating away from this slide, pause the video
                    #if canImport(WebKit)
                    if useWebViewForVideo {
                        videoController.pause()
                    } else {
                        videoPlayer?.pause()
                    }
                    #else
                    videoPlayer?.pause()
                    #endif
                }
            } else if mediaItem.type == .audio {
                if newValue && !oldValue {
                    // When this slide becomes current, load audio if not already loaded
                    // Don't check isCurrentSlide again - if we got here, slide WAS current at some point
                    if audioPlayer == nil {
                        Task {
                            // Check if the shared audio player is already playing this item
                            let sharedPlayerAlreadyHasThisItem = await MainActor.run {
                                if let currentItem = MediaPlaybackService.shared.currentAudioMediaItem {
                                    // Compare by content, not UUID
                                    if let key1 = currentItem.diskCacheKey, let key2 = mediaItem.diskCacheKey {
                                        return key1 == key2
                                    }
                                    if let url1 = currentItem.sourceURL, let url2 = mediaItem.sourceURL {
                                        return url1.absoluteString == url2.absoluteString
                                    }
                                    return currentItem.id == mediaItem.id
                                }
                                return false
                            }

                            if sharedPlayerAlreadyHasThisItem {
                                // Already loaded - just reference the player
                                print("[ZoomableMediaView] ♻️ Shared player already has this item, reusing")
                                await MainActor.run {
                                    audioPlayer = MediaPlaybackService.shared.sharedAudioPlayer
                                }
                            } else {
                                // Load fresh into shared player - don't check isCurrentSlide again to avoid race condition
                                print("[ZoomableMediaView] 🎵 Loading audio (onChange handler)")
                                await MediaPlaybackService.shared.loadAudioInSharedPlayer(
                                    mediaItem: mediaItem,
                                    autoplay: false  // Don't autoplay when manually navigating
                                )
                                await MainActor.run {
                                    audioPlayer = MediaPlaybackService.shared.sharedAudioPlayer
                                }
                                print("[ZoomableMediaView] ✅ Loaded audio when slide became current")
                            }
                        }
                    }
                } else if !newValue && oldValue {
                    // When navigating away from this slide, pause the audio
                    audioPlayer?.pause()
                }
            } else if mediaItem.type == .animatedImage && useWebViewForAnimatedImage {
                if newValue && !oldValue {
                    // Became current slide - start animation
                    animatedImageController.startAnimating()
                } else if !newValue && oldValue {
                    // Left current slide - stop animation to save memory
                    animatedImageController.stopAnimating()
                }
            }
        }
        .onChange(of: isSlideshowPlaying) { oldValue, newValue in
            // Handle slideshow start/stop for videos on the current slide
            if mediaItem.type == .video && isCurrentSlide {
                #if canImport(WebKit)
                if useWebViewForVideo && videoController.isReady {
                    if newValue && !oldValue {
                        // Slideshow started - play the video
                        videoController.cancelFirstFrameMode()
                        if videoController.didReachEnd {
                            videoController.seekToBeginning()
                            videoController.didReachEnd = false
                        }
                        videoController.play()
                    } else if !newValue && oldValue {
                        // Slideshow stopped - pause the video
                        videoController.pause()
                    }
                } else if let player = videoPlayer {
                    // AVFoundation video player
                    if newValue && !oldValue {
                        if videoWasAtEnd {
                            player.seek(to: .zero)
                            videoWasAtEnd = false
                        }
                        player.play()
                    } else if !newValue && oldValue {
                        player.pause()
                    }
                }
                #else
                if let player = videoPlayer {
                    // AVFoundation video player
                    // Playback is handled by CustomVideoPlayerView via shouldAutoplay binding
                    if newValue && !oldValue {
                        // Slideshow started - play the video
                        if videoWasAtEnd {
                            player.seek(to: .zero)
                            videoWasAtEnd = false
                        }
                        player.play()
                    } else if !newValue && oldValue {
                        // Slideshow stopped - pause the video
                        player.pause()
                    }
                }
                #endif
            }
            // Audio playback is handled by AudioPlayerControlsView via shouldAutoplay binding
            // The AudioPlayerControlsView observes shouldAutoplay changes directly
            if mediaItem.type == .audio && isCurrentSlide {
                if let player = audioPlayer {
                    if newValue && !oldValue {
                        // Slideshow started - play audio
                        if audioWasAtEnd {
                            player.seek(to: .zero)
                            audioWasAtEnd = false
                        }
                        player.play()
                    } else if !newValue && oldValue {
                        // Slideshow stopped - pause audio
                        player.pause()
                    }
                }
            }
        }
        .onChange(of: scale) { _, newScale in
            onZoomChanged(newScale > minScale)
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: MediaPlaybackService.shouldPauseForBackgroundNotification)) { _ in
            // Only pause NON-CACHED media when app enters background
            // Cached media should continue playing in background
            let isCached = MediaDownloadManager.shared.isCached(mediaItem: mediaItem)
            let diskCacheKey = mediaItem.diskCacheKey
            let localURL = MediaDownloadManager.shared.localURL(for: mediaItem)
            print("[ZoomableMediaView] Background check - isCached: \(isCached), diskCacheKey: \(diskCacheKey ?? "nil"), localURL: \(localURL?.path ?? "nil")")

            if isCached {
                // Keep audio session active for cached media background playback
                try? AVAudioSession.sharedInstance().setActive(true)
                print("[ZoomableMediaView] ✅ Background: keeping cached media playing")
                return // Don't pause cached media - it should keep playing
            }

            // Pause non-cached media since rclone server gets killed when app is backgrounded
            print("[ZoomableMediaView] ⚠️ Background: pausing non-cached media (type: \(mediaItem.type))")
            if mediaItem.type == .video {
                if useWebViewForVideo {
                    videoController.pause()
                } else {
                    videoPlayer?.pause()
                }
            } else if mediaItem.type == .audio {
                audioPlayer?.pause()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MediaPlaybackService.externalPlayNotification)) { _ in
            // Handle remote play command for cached media
            // Note: We check isCurrentSlide but also allow if this view's player is registered OR paused
            // This handles edge cases where isCurrentSlide might be stale in background
            let isCached = MediaDownloadManager.shared.isCached(mediaItem: mediaItem)
            let isRegisteredPlayer = (mediaItem.type == .audio && audioPlayer != nil && MediaPlaybackService.shared.externalPlayer === audioPlayer) ||
                                    (mediaItem.type == .video && videoPlayer != nil && MediaPlaybackService.shared.externalPlayer === videoPlayer)
            // Also consider this player if it exists and is paused (might be the one we want to resume)
            let hasPausedPlayer = (mediaItem.type == .audio && audioPlayer != nil && audioPlayer!.rate == 0) ||
                                  (mediaItem.type == .video && videoPlayer != nil && videoPlayer!.rate == 0)
            guard isCached && (isCurrentSlide || isRegisteredPlayer || hasPausedPlayer) else { return }

            // Ensure audio session is active for background playback
            try? AVAudioSession.sharedInstance().setActive(true)

            if mediaItem.type == .video {
                if useWebViewForVideo {
                    videoController.play()
                } else {
                    videoPlayer?.play()
                }
            } else if mediaItem.type == .audio {
                audioPlayer?.play()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MediaPlaybackService.externalPauseNotification)) { _ in
            // Handle remote pause command for cached media
            // More lenient check: if our player is playing, we should pause it
            let isCached = MediaDownloadManager.shared.isCached(mediaItem: mediaItem)
            let isRegisteredPlayer = (mediaItem.type == .audio && audioPlayer != nil && MediaPlaybackService.shared.externalPlayer === audioPlayer) ||
                                    (mediaItem.type == .video && videoPlayer != nil && MediaPlaybackService.shared.externalPlayer === videoPlayer)
            // Also pause if our player is actively playing (rate > 0) - this catches orphaned players
            let hasPlayingPlayer = (mediaItem.type == .audio && audioPlayer != nil && audioPlayer!.rate > 0) ||
                                   (mediaItem.type == .video && videoPlayer != nil && videoPlayer!.rate > 0)
            guard isCached && (isCurrentSlide || isRegisteredPlayer || hasPlayingPlayer) else { return }
            if mediaItem.type == .video {
                if useWebViewForVideo {
                    videoController.pause()
                } else {
                    videoPlayer?.pause()
                }
            } else if mediaItem.type == .audio {
                audioPlayer?.pause()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MediaPlaybackService.externalSeekNotification)) { notification in
            // Handle remote seek command for cached media
            guard isCurrentSlide && MediaDownloadManager.shared.isCached(mediaItem: mediaItem) else { return }
            guard let time = notification.userInfo?["time"] as? TimeInterval else { return }
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if mediaItem.type == .video {
                if useWebViewForVideo {
                    videoController.seek(to: time)
                } else {
                    videoPlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            } else if mediaItem.type == .audio {
                audioPlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            syncStateOnForeground()
        }
        #endif
        .onChange(of: savedVideoPosition) { _, newValue in
            // Throttle persistent saves to every ~10 seconds
            let now = Date()
            guard now.timeIntervalSince(lastPersistTime) >= 10,
                  abs(newValue - lastPersistedPosition) > 1 else { return }
            lastPersistTime = now
            lastPersistedPosition = newValue
            let item = mediaItem
            Task { await MediaStreamConfiguration.savePosition(for: item, position: newValue) }
        }
        .onChange(of: savedAudioPosition) { _, newValue in
            let now = Date()
            guard now.timeIntervalSince(lastPersistTime) >= 10,
                  abs(newValue - lastPersistedPosition) > 1 else { return }
            lastPersistTime = now
            lastPersistedPosition = newValue
            let item = mediaItem
            Task { await MediaStreamConfiguration.savePosition(for: item, position: newValue) }
        }
        .onChange(of: videoWasAtEnd) { _, isAtEnd in
            if isAtEnd {
                // Video completed — clear saved position
                let item = mediaItem
                Task { await MediaStreamConfiguration.savePosition(for: item, position: 0) }
            }
        }
        .onChange(of: audioWasAtEnd) { _, isAtEnd in
            if isAtEnd {
                let item = mediaItem
                Task { await MediaStreamConfiguration.savePosition(for: item, position: 0) }
            }
        }
        .onDisappear {
            // Persist final position before cleanup
            let finalPosition: Double
            if mediaItem.type == .video {
                finalPosition = videoWasAtEnd ? 0 : savedVideoPosition
            } else if mediaItem.type == .audio {
                finalPosition = audioWasAtEnd ? 0 : savedAudioPosition
            } else {
                finalPosition = 0
            }
            if finalPosition > 5 || (mediaItem.type == .video || mediaItem.type == .audio) {
                let item = mediaItem
                let pos = finalPosition
                Task { await MediaStreamConfiguration.savePosition(for: item, position: pos) }
            }

            // Critical: Release memory when view disappears to prevent OOM
            // Delete temp animated image files if they exist
            if let tempURL = animatedImageURL,
               tempURL.path.contains("streaming_") || tempURL.path.contains("webview_animated_") {
                try? FileManager.default.removeItem(at: tempURL)
            }

            // Clear image/video/animated image state
            image = nil
            videoURL = nil
            animatedImageURL = nil
            useStreaming = false
            useWebViewForAnimatedImage = false
            hasLoadedMedia = false

            // Unregister and clean up AVFoundation video player
            if let player = videoPlayer {
                MediaPlaybackService.shared.unregisterExternalPlayer(player, forMediaId: mediaItem.id)
            }
            videoPlayer?.pause()
            videoPlayer = nil
            useWebViewForVideo = false

            // For audio: DON'T pause or clean up the shared player - it should keep running
            // Just clear our local reference. The shared player is managed by MediaPlaybackService.
            if let player = audioPlayer, player !== MediaPlaybackService.shared.sharedAudioPlayer {
                // Only unregister if it's NOT the shared player (legacy video player)
                MediaPlaybackService.shared.unregisterExternalPlayer(player, forMediaId: mediaItem.id)
                player.pause()
            }
            audioPlayer = nil

            // Fully destroy controllers to release resources
            #if canImport(WebKit)
            videoController.destroy()
            #endif
            animatedImageController.destroy()

        }
    }

    /// Sync view state with player state when returning from background
    private func syncStateOnForeground() {
        guard isCurrentSlide else { return }

        // Audio state is managed by AudioPlayerControlsView via its time observer on the shared player
        // Video state syncing handled here
        if mediaItem.type == .video, let player = videoPlayer {
            let playerTime = CMTimeGetSeconds(player.currentTime())
            let playerRate = player.rate
            print("[ZoomableMediaView] Video state on foreground: time=\(playerTime), playing=\(playerRate > 0)")
        } else if mediaItem.type == .audio {
            let state = MediaPlaybackService.shared.sharedAudioPlayerState
            print("[ZoomableMediaView] Audio state from shared player on foreground: time=\(state.currentTime), playing=\(state.isPlaying)")
        }
    }

    private func loadMedia() async {
        // Don't reload if already loaded
        if hasLoadedMedia || image != nil || videoURL != nil || animatedImageURL != nil {
            return
        }

        // Prevent concurrent loading
        if isLoadingMedia {
            return
        }

        // Only set loading flags after passing all guards
        isLoadingMedia = true
        isLoading = true
        defer {
            isLoading = false
            isLoadingMedia = false
        }

        switch mediaItem.type {
        case .image:
            // Capture the type BEFORE loading — for unresolved webp/heic, loadImage()
            // downloads the data and resolves _animationStorage as a side effect.
            let preloadType = mediaItem.type
            if let loadedImage = await mediaItem.loadImage() {
                // If an unresolved format just resolved to animated during loadImage(),
                // switch to animated WKWebView display instead of showing a static frame.
                if preloadType == .image && mediaItem.type == .animatedImage,
                   let animURL = await mediaItem.loadAnimatedImageURL() {
                    animatedImageURL = animURL
                    useWebViewForAnimatedImage = true
                    hasLoadedMedia = true
                    await MainActor.run {
                        animatedImageController.load(url: animURL)
                        if isCurrentSlide {
                            Task {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                animatedImageController.startAnimating()
                            }
                        }
                    }
                    return
                }
                // Downsample large images to prevent OOM with 40MB+ files
                // A 8000x6000 image decodes to ~192MB - with 3 visible, that's 576MB causing OOM
                // Downsample to maxDisplayPixelSize for display; full resolution only for sharing
                image = Self.downsampleForDisplay(loadedImage)
                hasLoadedMedia = true
            }
        case .animatedImage:
            #if canImport(UIKit)
            // Use WKWebView for animated images - much more memory efficient
            // Browser handles GIF frame decoding/caching internally
            // Check sourceURL first (simplest), then loadAnimatedImageURL(), then loadAnimatedImageData()
            if let url = mediaItem.sourceURL {
                // Direct URL - load natively
                animatedImageURL = url
                useWebViewForAnimatedImage = true
                hasLoadedMedia = true

                await MainActor.run {
                    animatedImageController.load(url: url)
                    if isCurrentSlide {
                        Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            animatedImageController.startAnimating()
                        }
                    }
                }
            } else if let url = await mediaItem.loadAnimatedImageURL() {
                animatedImageURL = url
                useWebViewForAnimatedImage = true
                hasLoadedMedia = true

                await MainActor.run {
                    animatedImageController.load(url: url)
                    if isCurrentSlide {
                        Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            animatedImageController.startAnimating()
                        }
                    }
                }
            } else if let data = await mediaItem.loadAnimatedImageData() {
                // Save data to temp file with correct extension for CGImageSource
                let ext = Self.detectAnimatedImageExtension(from: data)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("webview_animated_\(UUID().uuidString).\(ext)")
                try? data.write(to: tempURL)

                animatedImageURL = tempURL
                useWebViewForAnimatedImage = true
                hasLoadedMedia = true

                await MainActor.run {
                    animatedImageController.load(url: tempURL)
                    if isCurrentSlide {
                        Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            animatedImageController.startAnimating()
                        }
                    }
                }
            } else {
                // No URL or Data - fall back to loadImage()
                if let loadedImage = await mediaItem.loadImage() {
                    if let frames = loadedImage.images, frames.count > StreamingAnimatedImageView.streamingThreshold {
                        // Large GIF - save to temp file for native rendering
                        if let tempURL = AnimatedImageHelper.createTempGIFForStreaming(from: loadedImage) {
                            animatedImageURL = tempURL
                            useWebViewForAnimatedImage = true
                            hasLoadedMedia = true

                            await MainActor.run {
                                animatedImageController.load(url: tempURL)
                                if isCurrentSlide {
                                    Task {
                                        try? await Task.sleep(nanoseconds: 100_000_000)
                                        animatedImageController.startAnimating()
                                    }
                                }
                            }
                            // UIImage will be released when function exits
                        } else {
                            // Fallback: couldn't create temp file, show first frame
                            image = frames.first ?? loadedImage
                            hasLoadedMedia = true
                        }
                    } else {
                        // Small enough to keep in memory
                        image = loadedImage
                        hasLoadedMedia = true
                    }
                }
            }
            #else
            // macOS: native CGImageSource rendering for animated images.
            // Supports GIF, APNG, WebP, HEIC — no WKWebView needed.
            // Priority: sourceURL → loadAnimatedImageURL() → loadAnimatedImageData() → static fallback.
            if let url = mediaItem.sourceURL {
                animatedImageURL = url
                useWebViewForAnimatedImage = true
                hasLoadedMedia = true

                await MainActor.run {
                    animatedImageController.load(url: url)
                    if isCurrentSlide {
                        Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            animatedImageController.startAnimating()
                        }
                    }
                }
            } else if let url = await mediaItem.loadAnimatedImageURL() {
                animatedImageURL = url
                useWebViewForAnimatedImage = true
                hasLoadedMedia = true

                await MainActor.run {
                    animatedImageController.load(url: url)
                    if isCurrentSlide {
                        Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            animatedImageController.startAnimating()
                        }
                    }
                }
            } else if let data = await mediaItem.loadAnimatedImageData() {
                // Write to temp file with correct extension for CGImageSource
                let ext = Self.detectAnimatedImageExtension(from: data)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("webview_animated_\(UUID().uuidString).\(ext)")
                try? data.write(to: tempURL)

                animatedImageURL = tempURL
                useWebViewForAnimatedImage = true
                hasLoadedMedia = true

                await MainActor.run {
                    animatedImageController.load(url: tempURL)
                    if isCurrentSlide {
                        Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            animatedImageController.startAnimating()
                        }
                    }
                }
            } else if let loadedImage = await mediaItem.loadImage() {
                // Fallback: load as static image
                image = loadedImage
                hasLoadedMedia = true
            }
            #endif
        case .video:
            // VR videos: just need the URL, VRVideoPlayerView manages its own AVPlayer
            if effectiveVRProjection != nil {
                if let url = await mediaItem.loadVideoURL() {
                    videoURL = url
                    hasLoadedMedia = true
                }
                return
            }

            // Check local cache first for background playback support
            if let localURL = await MainActor.run(body: { MediaDownloadManager.shared.localURL(for: mediaItem) }),
               FileManager.default.fileExists(atPath: localURL.path) {
                // Use local cached file - AVFoundation always handles local files
                videoURL = localURL
                hasLoadedMedia = true

                let playerItem = AVPlayerItem(url: localURL)
                let player = AVPlayer(playerItem: playerItem)

                await MainActor.run {
                    useWebViewForVideo = false
                    videoPlayer = player
                }
            } else if let url = await mediaItem.loadVideoURL() {
                // Fall back to remote URL
                // For local files, verify the file exists
                if url.isFileURL {
                    guard FileManager.default.fileExists(atPath: url.path) else { return }
                }

                videoURL = url
                hasLoadedMedia = true

                // Check file extension to determine player type
                // WebM requires WKWebView (AVFoundation doesn't support WebM/VP8/VP9)
                let ext = url.pathExtension.lowercased()
                let isWebM = ext == "webm"

                var useAVFoundation = !isWebM

                #if canImport(WebKit)
                if isWebM {
                    // WebM: Must use WKWebView player (AVFoundation doesn't support WebM codec)
                    await MainActor.run {
                        useWebViewForVideo = true
                    }

                    let headers = await MediaStreamConfiguration.headersAsync(for: url)

                    await MainActor.run {
                        if videoController.webView == nil {
                            _ = videoController.createWebView()
                        }
                        videoController.load(url: url, headers: headers)
                        if !isSlideshowPlaying && isCurrentSlide {
                            Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if videoController.isReady {
                                    videoController.showFirstFrame()
                                }
                            }
                        }
                    }
                    useAVFoundation = false
                }
                #endif

                if useAVFoundation {
                    // Non-WebM (or no WebKit): Try AVFoundation (better performance/controls)
                    let playerItem = AVPlayerItem(url: url)
                    let player = AVPlayer(playerItem: playerItem)

                    // Wait a moment to check if AVPlayer can load the video
                    do {
                        // Load asset properties to verify it's playable
                        let asset = playerItem.asset
                        let isPlayable = try await asset.load(.isPlayable)

                        if isPlayable {
                            // AVFoundation can handle this video
                            await MainActor.run {
                                useWebViewForVideo = false
                                videoPlayer = player
                            }
                        } else {
                            #if canImport(WebKit)
                            // AVFoundation can't play it - fallback to WebView
                            await fallbackToWebView(url: url)
                            #endif
                        }
                    } catch {
                        #if canImport(WebKit)
                        // AVFoundation failed - fallback to WebView
                        print("AVFoundation failed to load video: \(error.localizedDescription), falling back to WebView")
                        await fallbackToWebView(url: url)
                        #endif
                    }
                }
            }
        case .audio:
            // For audio files, load the album artwork as the image
            // Check cache first to avoid re-loading on every swipe
            let diskCacheKey = mediaItem.diskCacheKey
            let artworkCacheKey = diskCacheKey.map { $0 + "_artwork" }

            // Try memory cache first
            if let cached = ThumbnailCache.shared.get(mediaItem.id) {
                image = cached
            }
            // Try disk cache
            else if let cacheKey = artworkCacheKey,
                    let diskCached = DiskThumbnailCache.shared.loadThumbnail(for: cacheKey) {
                image = diskCached
                // Also put in memory cache
                ThumbnailCache.shared.set(mediaItem.id, image: diskCached, diskCacheKey: nil)
            }
            // Load fresh
            else if let artwork = await mediaItem.loadImage() {
                image = artwork
                // Cache it (memory + disk if key available)
                ThumbnailCache.shared.set(mediaItem.id, image: artwork, diskCacheKey: artworkCacheKey)
            }

            // Mark as loaded even without artwork (placeholder will show)
            hasLoadedMedia = true

            // Use the shared audio player from MediaPlaybackService
            // This avoids creating multiple players and works reliably in background
            let isCached = MediaDownloadManager.shared.isCached(mediaItem: mediaItem)
            print("[ZoomableMediaView] Audio - cached: \(isCached), isCurrentSlide: \(isCurrentSlide)")

            // Check if the shared audio player is already playing this item
            // This prevents double-loading when the view is recreated on foreground restore
            // Use content-based comparison (diskCacheKey/sourceURL) instead of UUID
            // because gallery recreation creates new media items with new UUIDs for the same file
            let sharedPlayerAlreadyHasThisItem = await MainActor.run {
                if let currentItem = MediaPlaybackService.shared.currentAudioMediaItem {
                    // Compare by content, not UUID - diskCacheKey is most reliable
                    if let key1 = currentItem.diskCacheKey, let key2 = mediaItem.diskCacheKey {
                        return key1 == key2
                    }
                    // Fall back to sourceURL comparison
                    if let url1 = currentItem.sourceURL, let url2 = mediaItem.sourceURL {
                        return url1.absoluteString == url2.absoluteString
                    }
                    // Last resort: compare by UUID
                    return currentItem.id == mediaItem.id
                }
                return false
            }

            // Load audio player - don't check isCurrentSlide to avoid race condition
            // The onChange(of: isCurrentSlide) handler will load if this view wasn't current initially
            if sharedPlayerAlreadyHasThisItem {
                // Already loaded - just reference the player, don't reload
                print("[ZoomableMediaView] ♻️ Shared player already has this item (same content), reusing")
                await MainActor.run {
                    audioPlayer = MediaPlaybackService.shared.sharedAudioPlayer
                }
            } else if isCurrentSlide {
                // Only load fresh if this is the current slide (avoid loading all audio files at once)
                print("[ZoomableMediaView] 🎵 Loading audio (loadMedia)")
                await MediaPlaybackService.shared.loadAudioInSharedPlayer(
                    mediaItem: mediaItem,
                    autoplay: isSlideshowPlaying
                )
                // Reference the shared player for UI compatibility
                await MainActor.run {
                    audioPlayer = MediaPlaybackService.shared.sharedAudioPlayer
                }
                print("[ZoomableMediaView] ✅ Loaded audio into shared player")
            } else {
                // Not current slide initially - onChange handler will load when it becomes current
                print("[ZoomableMediaView] Audio not current slide initially, will load via onChange")
            }
        }
    }

    #if canImport(WebKit)
    /// Fallback to WebView player when AVFoundation can't play the video
    private func fallbackToWebView(url: URL) async {
        let headers = await MediaStreamConfiguration.headersAsync(for: url)

        await MainActor.run {
            useWebViewForVideo = true
            videoPlayer = nil  // Clear any partial AVPlayer

            if videoController.webView == nil {
                _ = videoController.createWebView()
            }
            videoController.load(url: url, headers: headers)

            if !isSlideshowPlaying && isCurrentSlide {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if videoController.isReady {
                        videoController.showFirstFrame()
                    }
                }
            }
        }
    }
    #endif

    #if !os(tvOS)
    private func createMagnificationGesture(in geometry: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                scale = min(max(scale * delta, minScale), maxScale)
            }
            .onEnded { _ in
                lastScale = 1.0
                if scale < minScale {
                    withAnimation(.easeOut(duration: 0.3)) {
                        scale = minScale
                        offset = .zero
                    }
                } else {
                    // Smoothly slide back to constrained bounds
                    withAnimation(.easeOut(duration: 0.3)) {
                        offset = constrainOffset(offset, in: geometry)
                    }
                }
            }
    }

    private var isZoomedIn: Bool {
        scale > minScale
    }

    private func panGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Only pan when zoomed in
                guard scale > minScale else { return }

                // On first change, capture the starting offset
                if value.translation == .zero || (dragStartOffset == .zero && offset != .zero) {
                    dragStartOffset = offset
                }

                // Update offset based on drag start + translation
                offset = CGSize(
                    width: dragStartOffset.width + value.translation.width,
                    height: dragStartOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > minScale else { return }

                // Reset drag start offset
                dragStartOffset = .zero

                // Smoothly slide back to constrained bounds when drag ends
                withAnimation(.easeOut(duration: 0.3)) {
                    offset = constrainOffset(offset, in: geometry)
                }
            }
    }

    private func constrainOffset(_ offset: CGSize, in geometry: GeometryProxy) -> CGSize {
        guard scale > minScale else { return .zero }

        // Calculate the size of the scaled image
        let imageWidth = geometry.size.width * scale
        let imageHeight = geometry.size.height * scale

        // Calculate maximum allowed offset
        // When zoomed, the image is larger than the viewport, so we can pan
        // But we want to prevent it from being dragged completely off screen
        let maxOffsetX = max(0, (imageWidth - geometry.size.width) / 2)
        let maxOffsetY = max(0, (imageHeight - geometry.size.height) / 2)

        // Constrain the offset to keep the image edges visible
        let constrainedX = min(max(offset.width, -maxOffsetX), maxOffsetX)
        let constrainedY = min(max(offset.height, -maxOffsetY), maxOffsetY)

        return CGSize(width: constrainedX, height: constrainedY)
    }

    private func handleDoubleTap(in geometry: GeometryProxy) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            // Use a threshold to detect if we're zoomed in (account for floating point precision)
            if scale > minScale + 0.01 {
                // Zoom out
                scale = minScale
                offset = .zero
            } else {
                // Zoom in
                scale = 2.0
                // Constrain offset after zooming in
                offset = constrainOffset(offset, in: geometry)
            }
        }
    }
    #endif

    /// Detect the appropriate file extension for animated image data by inspecting the
    /// image source type via ImageIO. Used to create temp files with correct extensions
    /// so WKWebView serves the right MIME type (WebP bytes in a .gif file won't display).
    private static func detectAnimatedImageExtension(from data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let utType = CGImageSourceGetType(source) as String? else {
            return "gif"
        }
        if utType.contains("webp") { return "webp" }
        if utType.contains("heic") || utType.contains("heif") { return "heic" }
        if utType.contains("png") { return "png" }
        return "gif"
    }

    /// Downsample large images to prevent OOM when viewing many large files.
    /// Images are downsampled to maxDisplayPixelSize which is sufficient for display
    /// at maximum zoom (4x) on typical devices. Full resolution is only loaded for sharing.
    private static func downsampleForDisplay(_ image: PlatformImage) -> PlatformImage {
        #if canImport(UIKit)
        let maxDimension = max(image.size.width, image.size.height) * image.scale
        #else
        let maxDimension = max(image.size.width, image.size.height)
        #endif

        // If image is already small enough, return as-is
        guard maxDimension > maxDisplayPixelSize else {
            return image
        }

        // Calculate the scale factor to fit within maxDisplayPixelSize
        let scaleFactor = maxDisplayPixelSize / maxDimension

        #if canImport(UIKit)
        let newSize = CGSize(
            width: image.size.width * scaleFactor,
            height: image.size.height * scaleFactor
        )

        // Use UIGraphicsImageRenderer for efficient resizing
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        #elseif canImport(AppKit)
        let newSize = NSSize(
            width: image.size.width * scaleFactor,
            height: image.size.height * scaleFactor
        )

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
        #endif
    }
}
