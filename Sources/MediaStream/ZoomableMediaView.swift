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
        #if canImport(UIKit)
        AnimatedImageRepresentable(image: image)
            .scaleEffect(scale)
            .offset(offset)
        #elseif canImport(AppKit)
        AnimatedImageRepresentable(image: image)
            .scaleEffect(scale)
            .offset(offset)
        #endif
    }
}

#if canImport(UIKit)
struct AnimatedImageRepresentable: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = image
    }
}
#elseif canImport(AppKit)
struct AnimatedImageRepresentable: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = image
        imageView.animates = true // Enable animation for animated images
        imageView.canDrawSubviewsIntoLayer = true
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = image
        nsView.animates = true
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

                        Text(formatTime(currentTime))
                            .font(.caption)
                            .foregroundColor(.white)
                            .monospacedDigit()

                        Slider(value: $currentTime, in: 0...max(duration, 0.1)) { editing in
                            isDragging = editing
                            if !editing {
                                seekTo(currentTime)
                            }
                        }
                        .tint(.white)

                        Text(formatTime(duration))
                            .font(.caption)
                            .foregroundColor(.white)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .transition(.opacity)
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

                print("🎬 Slideshow autoplay: position \(currentPos)s of \(duration)s")

                if isAtEnd {
                    print("🎬 Video at end - resetting before playing")
                    currentTime = 0.0
                    savedPosition = 0.0
                    wasAtEnd = false

                    // Simple seek to beginning
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                        Task { @MainActor in
                            self.player.play()
                            self.isPlaying = true
                            print("🎬 Reset complete, now playing")
                        }
                    }
                } else {
                    // Just play from current position
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
                print("📹 Loop count increased to \(newValue) - restarting video")
                // Reset and play from beginning
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    Task { @MainActor in
                        self.currentTime = 0.0
                        self.savedPosition = 0.0
                        self.wasAtEnd = false
                        self.player.play()
                        self.isPlaying = true
                        print("📹 Video restarted for loop #\(newValue)")
                    }
                }
            }
        }
        .onChange(of: isCurrentSlide) { oldValue, newValue in
            // When this video becomes the current slide, just reset if at end
            if newValue && !oldValue {
                print("📹 Video became current slide")

                // Check if video is at end
                let currentPos = CMTimeGetSeconds(player.currentTime())
                let isAtEnd = wasAtEnd || (duration > 0 && currentPos >= duration - 1.0)

                if isAtEnd {
                    print("📹 Video at end - resetting to beginning")
                    currentTime = 0.0
                    savedPosition = 0.0
                    wasAtEnd = false

                    // Simple seek to beginning
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
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

        // Get duration if we don't have it
        if let currentItem = player.currentItem {
            let durationSeconds = CMTimeGetSeconds(currentItem.duration)
            if durationSeconds.isFinite && durationSeconds > 0 {
                duration = durationSeconds
            }
        }

        // Setup observers - simple and clean
        setupObservers()

        // Check if we need to reset from end position
        let currentPos = CMTimeGetSeconds(player.currentTime())
        if wasAtEnd || (duration > 0 && currentPos >= duration - 1.0) {
            print("📹 Video at end in setupPlayer - resetting")
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
        // CRITICAL: Clean up any existing observers first to prevent duplicates
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endTimeObserver {
            NotificationCenter.default.removeObserver(observer)
            endTimeObserver = nil
        }

        print("📹 Creating new observers")

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
        guard endTimeObserver == nil else {
            print("📹 End observer already exists - not creating duplicate")
            return
        }

        guard let currentItem = player.currentItem else {
            print("⚠️ Cannot create end observer - no current item")
            return
        }

        print("📹 Creating ONE end observer for item: \(ObjectIdentifier(currentItem))")

        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { notification in
            // Extract the notification object before entering Task
            let notificationItem = notification.object as? AVPlayerItem

            Task { @MainActor in
                print("🎬 Video completed playback notification received")

                // Verify this is for our current player item
                guard let notificationItem = notificationItem,
                      notificationItem == self.player.currentItem else {
                    print("🎬 Ignoring - notification for different item")
                    return
                }

                // Verify video actually reached the end
                let currentPos = CMTimeGetSeconds(self.player.currentTime())

                // Be VERY strict - must be within 0.1 seconds of the end
                let isAtEnd = self.duration > 0 && currentPos >= (self.duration - 0.1)

                if !isAtEnd {
                    print("🎬 REJECTING spurious completion - at \(currentPos)s but duration is \(self.duration)s")
                    return
                }

                print("🎬 VALID completion at \(currentPos)s of \(self.duration)s")
                self.wasAtEnd = true

                // Call completion callback ONCE
                if let callback = self.onVideoComplete {
                    print("🎬 Calling onVideoComplete callback")
                    callback()
                } else {
                    print("🎬 No callback registered")
                }
            }
        }
        endTimeObserver = endObserver
        print("📹 End observer created successfully")
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

        // Pause playback
        player.pause()
    }

    private func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            // If video is at or near the end (within 1 second), restart from beginning
            if duration > 0 && currentTime >= duration - 1.0 {
                print("▶️ Video at end, restarting from beginning")
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0.0
                savedPosition = 0.0
            }
            player.play()
            // Clear wasAtEnd flag when user manually plays
            wasAtEnd = false
        }
        isPlaying.toggle()
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
    @State private var isLoading = false  // Start false, only true when actively loading
    @State private var isLoadingMedia = false  // Flag to prevent concurrent loading
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var videoPlayer: AVPlayer?
    @State private var savedVideoPosition: Double = 0.0
    @State private var videoWasAtEnd: Bool = false
    @State private var hasLoadedMedia: Bool = false  // Track if media has been loaded

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if isLoading && image == nil && videoURL == nil {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                } else {
                    Group {
                        if mediaItem.type == .animatedImage, let image = image {
                            AnimatedImageView(image: image, scale: scale, offset: offset)
                                .gesture(createGestures(in: geometry))
                        } else if mediaItem.type == .image, let image = image {
                            #if canImport(UIKit)
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(scale)
                                .offset(offset)
                                .gesture(createGestures(in: geometry))
                            #elseif canImport(AppKit)
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(scale)
                                .offset(offset)
                                .gesture(createGestures(in: geometry))
                            #endif
                        } else if mediaItem.type == .video, let player = videoPlayer {
                            CustomVideoPlayerView(
                                player: player,
                                shouldAutoplay: isSlideshowPlaying,
                                showControls: showControls,
                                isCurrentSlide: isCurrentSlide,
                                videoLoopCount: videoLoopCount,
                                onVideoComplete: onVideoComplete,
                                savedPosition: $savedVideoPosition,
                                wasAtEnd: $videoWasAtEnd
                            )
                        } else if mediaItem.type == .video {
                            // Video type but no player - show error
                            VStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.largeTitle)
                                    .foregroundColor(.white)
                                Text("Video failed to load")
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture(count: 2)
                    .onEnded { _ in
                        handleDoubleTap(in: geometry)
                    }
            )
        }
        .task(id: mediaItem.id) {
            await loadMedia()
        }
        .onChange(of: scale) { _, newScale in
            onZoomChanged(newScale > minScale)
        }
    }

    private func loadMedia() async {
        // Don't reload if already loaded
        if hasLoadedMedia || image != nil || videoURL != nil {
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

        do {
            switch mediaItem.type {
            case .image, .animatedImage:
                if let loadedImage = await mediaItem.loadImage() {
                    image = loadedImage
                    hasLoadedMedia = true
                } else {
                    print("⚠️ Failed to load image for media item: \(mediaItem.id)")
                }
            case .video:
                if let url = await mediaItem.loadVideoURL() {
                    // Verify the file exists
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        print("⚠️ Video file does not exist: \(url.path)")
                        return
                    }

                    videoURL = url
                    hasLoadedMedia = true
                    await MainActor.run {
                        videoPlayer = AVPlayer(url: url)
                        print("✅ Created AVPlayer for video: \(url.lastPathComponent)")

                        // IMMEDIATELY seek to zero to prevent loading at end position
                        // This prevents AVPlayer from remembering last playback position
                        videoPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                        print("🔄 Force seeking to zero immediately after player creation")
                    }
                } else {
                    print("⚠️ Failed to load video URL for media item: \(mediaItem.id)")
                }
            }
        } catch {
            print("⚠️ Error loading media: \(error.localizedDescription)")
        }
    }

    private func createGestures(in geometry: GeometryProxy) -> some Gesture {
        let magnification = MagnificationGesture()
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
                        lastOffset = .zero
                    }
                } else {
                    // Smoothly slide back to constrained bounds
                    withAnimation(.easeOut(duration: 0.3)) {
                        offset = constrainOffset(offset, in: geometry)
                        lastOffset = offset
                    }
                }
            }

        // Pan gesture with a small minimum distance to avoid conflicting with parent swipe
        // Only actively pans when zoomed in
        let drag = DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Only pan if zoomed in
                // When not zoomed, this does nothing, allowing parent swipe gesture to work
                if scale > minScale {
                    // Allow dragging freely without constraints
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                if scale > minScale {
                    // Smoothly slide back to constrained bounds when drag ends
                    withAnimation(.easeOut(duration: 0.3)) {
                        offset = constrainOffset(offset, in: geometry)
                        lastOffset = offset
                    }
                }
            }

        return magnification.simultaneously(with: drag)
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
        print("👆 Double tap - current scale: \(scale), minScale: \(minScale)")

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            // Use a threshold to detect if we're zoomed in (account for floating point precision)
            if scale > minScale + 0.01 {
                // Zoom out
                print("🔍 Zooming out to minScale")
                scale = minScale
                offset = .zero
                lastOffset = .zero
            } else {
                // Zoom in
                print("🔍 Zooming in to 2.0")
                scale = 2.0
                // Constrain offset after zooming in
                offset = constrainOffset(offset, in: geometry)
                lastOffset = offset
            }
        }
    }
}
