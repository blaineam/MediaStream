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
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image !== image {
            nsView.image = image
        }
        nsView.animates = true
        nsView.frame = CGRect(origin: .zero, size: containerSize)
    }
}
#endif

/// Custom video player view with controls
struct CustomVideoPlayerView: View {
    let player: AVPlayer
    let shouldAutoplay: Bool
    var showControls: Bool = true
    var isCurrentSlide: Bool = false
    var videoLoopCount: Int = 0
    var onVideoComplete: (() -> Void)? = nil
    @Binding var savedPosition: Double
    @Binding var wasAtEnd: Bool

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

    // Persist volume preference across media items
    @AppStorage("MediaStream_VideoVolume") private var volume: Double = 1.0
    @AppStorage("MediaStream_VideoMuted") private var isMuted: Bool = false

    var body: some View {
        ZStack {
            // Video player layer
            #if canImport(UIKit)
            VideoPlayerRepresentable(player: player)
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
                        Button(action: togglePlayPause) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 36, height: 36)

                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)

                        Text(formatTime(isDragging ? scrubPosition : currentTime))
                            .font(.caption)
                            .foregroundColor(.white)
                            .monospacedDigit()

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
                        .tint(.white)

                        Text(formatTime(duration))
                            .font(.caption)
                            .foregroundColor(.white)
                            .monospacedDigit()

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
                                .tint(.white)
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
                            Button(action: {
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
                                ZStack {
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 36, height: 36)

                                    Image(systemName: volumeIcon)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            .onLongPressGesture(minimumDuration: 0.3) {
                                toggleMute()
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

                if isAtEnd {
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

        // Check if we need to reset from end position
        let currentPos = CMTimeGetSeconds(player.currentTime())
        if wasAtEnd || (duration > 0 && currentPos >= duration - 1.0) {
            currentTime = 0.0
            savedPosition = 0.0
            wasAtEnd = false
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

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
        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
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
                self.isPlaying = self.player.rate > 0
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

#if canImport(UIKit)
struct VideoPlayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)

        context.coordinator.playerLayer = playerLayer
        view.playerLayer = playerLayer

        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // Update player if it changed
        if context.coordinator.playerLayer?.player !== player {
            context.coordinator.playerLayer?.player = player
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
        layer.backgroundColor = NSColor.black.cgColor
        layer.needsDisplayOnBoundsChange = true
        if let player = player {
            layer.player = player
        }
        return layer
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
            CATransaction.commit()
            if let player = player {
                layer.player = player
                layer.setNeedsDisplay()
            }
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

    @State private var image: PlatformImage?
    @State private var videoURL: URL?
    @State private var animatedImageURL: URL?  // For streaming large GIFs
    @State private var useStreaming: Bool = false  // Whether to use streaming for this animated image
    @State private var isLoading = false  // Start false, only true when actively loading
    @State private var isLoadingMedia = false  // Flag to prevent concurrent loading
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero  // Offset when drag started
    @State private var videoPlayer: AVPlayer?
    @State private var savedVideoPosition: Double = 0.0
    @State private var videoWasAtEnd: Bool = false
    @State private var hasLoadedMedia: Bool = false
    @StateObject private var videoController = WebViewVideoController()

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if isLoading && image == nil && videoURL == nil && animatedImageURL == nil {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                } else {
                    Group {
                        if mediaItem.type == .animatedImage {
                            #if canImport(UIKit)
                            if useStreaming, let url = animatedImageURL {
                                // Use streaming view for large GIFs (memory-efficient)
                                StreamingAnimatedImageRepresentable(url: url, containerSize: geometry.size)
                                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                                    .scaleEffect(scale)
                                    .offset(offset)
                                    .gesture(createMagnificationGesture(in: geometry))
                                    .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
                            } else if let image = image {
                                // Use regular animated image view for small GIFs
                                AnimatedImageView(image: image, scale: scale, offset: offset)
                                    .gesture(createMagnificationGesture(in: geometry))
                                    .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
                            }
                            #else
                            if let image = image {
                                AnimatedImageView(image: image, scale: scale, offset: offset)
                                    .gesture(createMagnificationGesture(in: geometry))
                                    .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
                            }
                            #endif
                        } else if mediaItem.type == .image, let image = image {
                            #if canImport(UIKit)
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(scale)
                                .offset(offset)
                                .gesture(createMagnificationGesture(in: geometry))
                                .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
                            #elseif canImport(AppKit)
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(scale)
                                .offset(offset)
                                .gesture(createMagnificationGesture(in: geometry))
                                .applyPanGesture(if: scale > minScale, gesture: panGesture(in: geometry))
                            #endif
                        } else if mediaItem.type == .video {
                            // Use WebView player for all videos (WebM/MP4 support via HTML5)
                            // Always show the player (webview needs to be in hierarchy to load)
                            ZStack {
                                CustomWebViewVideoPlayerView(
                                    controller: videoController,
                                    shouldAutoplay: isSlideshowPlaying && isCurrentSlide,
                                    showControls: showControls && videoController.isReady,
                                    hasAudio: true,
                                    onVideoEnd: onVideoComplete
                                )

                                // Show loading overlay while video loads
                                if !videoController.isReady {
                                    Color.black
                                    if isLoading || videoURL != nil {
                                        ProgressView()
                                            .scaleEffect(1.5)
                                            .tint(.white)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Only allow double-tap zoom for images, not videos
            .modifier(DoubleTapZoomModifier(
                isEnabled: mediaItem.type != .video,
                action: { handleDoubleTap(in: geometry) }
            ))
        }
        .task(id: mediaItem.id) {
            // Reset state when switching to a different media item
            image = nil
            videoURL = nil
            animatedImageURL = nil
            useStreaming = false
            hasLoadedMedia = false
            videoController.stop()

            // Reset zoom state and notify parent
            scale = 1.0
            lastScale = 1.0
            offset = .zero
            onZoomChanged(false)

            await loadMedia()
        }
        .onChange(of: isCurrentSlide) { oldValue, newValue in
            if mediaItem.type == .video {
                if newValue && !oldValue {
                    // When this slide becomes current (and wasn't before), show first frame for videos
                    // Only if not in slideshow mode (slideshow will autoplay)
                    if !isSlideshowPlaying && videoController.isReady {
                        videoController.showFirstFrame()
                    }
                } else if !newValue && oldValue {
                    // When navigating away from this slide, pause the video
                    videoController.pause()
                }
            }
        }
        .onChange(of: isSlideshowPlaying) { oldValue, newValue in
            // Handle slideshow start/stop for videos on the current slide
            if mediaItem.type == .video && isCurrentSlide && videoController.isReady {
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
            }
        }
        .onChange(of: scale) { _, newScale in
            onZoomChanged(newScale > minScale)
        }
        .onDisappear {
            // Critical: Release memory when view disappears to prevent OOM
            // Clear image/video/animated image state
            image = nil
            videoURL = nil
            animatedImageURL = nil
            useStreaming = false
            hasLoadedMedia = false

            // Fully destroy video controller to release WKWebView memory
            videoController.destroy()

            print("ZoomableMediaView: Cleaned up resources for \(mediaItem.id)")
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
            if let loadedImage = await mediaItem.loadImage() {
                image = loadedImage
                hasLoadedMedia = true
            }
        case .animatedImage:
            #if canImport(UIKit)
            // Check if we can use streaming (memory-efficient for large GIFs)
            // First try URL, then try Data
            if let url = await mediaItem.loadAnimatedImageURL() {
                let frameCount = AnimatedImageHelper.getFrameCount(from: url)
                print("ZoomableMediaView: Animated image (URL) has \(frameCount) frames")

                if AnimatedImageHelper.requiresStreaming(frameCount: frameCount) {
                    print("ZoomableMediaView: Using streaming for large GIF (\(frameCount) frames)")
                    animatedImageURL = url
                    useStreaming = true
                    hasLoadedMedia = true
                } else {
                    if let loadedImage = await mediaItem.loadImage() {
                        image = loadedImage
                        hasLoadedMedia = true
                    }
                }
            } else if let data = await mediaItem.loadAnimatedImageData() {
                // Have raw data - check frame count before creating full animated image
                let frameCount = AnimatedImageHelper.getFrameCount(from: data)
                print("ZoomableMediaView: Animated image (Data) has \(frameCount) frames")

                if AnimatedImageHelper.requiresStreaming(frameCount: frameCount) {
                    // Too many frames - create streaming view from data
                    print("ZoomableMediaView: Using streaming for large GIF (\(frameCount) frames)")
                    // Save data to temp file for streaming view
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("streaming_\(UUID().uuidString).gif")
                    try? data.write(to: tempURL)
                    animatedImageURL = tempURL
                    useStreaming = true
                    hasLoadedMedia = true
                } else {
                    // Small enough - create animated image
                    if let animatedImage = AnimatedImageHelper.createAnimatedImage(from: data) {
                        image = animatedImage
                        hasLoadedMedia = true
                    }
                }
            } else {
                // No URL or Data available - fall back to loadImage()
                // This may OOM for large GIFs, but it's the app's responsibility to provide URL/Data
                if let loadedImage = await mediaItem.loadImage() {
                    // Check if it's too large and show warning
                    if let frames = loadedImage.images, frames.count > StreamingAnimatedImageView.streamingThreshold {
                        print("ZoomableMediaView: ⚠️ Large GIF (\(frames.count) frames) - implement loadAnimatedImageURL() or loadAnimatedImageData() to avoid OOM")
                        // Show first frame only to reduce ongoing memory pressure
                        image = frames.first ?? loadedImage
                    } else {
                        image = loadedImage
                    }
                    hasLoadedMedia = true
                }
            }
            #else
            // macOS doesn't need streaming (handles animated images differently)
            if let loadedImage = await mediaItem.loadImage() {
                image = loadedImage
                hasLoadedMedia = true
            }
            #endif
        case .video:
            if let url = await mediaItem.loadVideoURL() {
                // For local files, verify the file exists
                if url.isFileURL {
                    guard FileManager.default.fileExists(atPath: url.path) else { return }
                }

                videoURL = url
                hasLoadedMedia = true

                // Load video with WebView player (HTML5 video)
                // Get headers from MediaStreamConfiguration for authenticated requests
                let headers = await MediaStreamConfiguration.headersAsync(for: url)

                await MainActor.run {
                    // Create the webview first if needed
                    if videoController.webView == nil {
                        _ = videoController.createWebView()
                    }
                    videoController.load(url: url, headers: headers)
                    // Show first frame immediately
                    // Only do this if:
                    // 1. Not autoplaying (slideshow will handle playback)
                    // 2. This is the current slide (don't trigger for pre-rendered adjacent slides)
                    if !isSlideshowPlaying && isCurrentSlide {
                        // Wait a bit for video to be ready before showing first frame
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                            if videoController.isReady {
                                videoController.showFirstFrame()
                            }
                        }
                    }
                }
            }
        }
    }

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
            .onEnded { value in
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
}
