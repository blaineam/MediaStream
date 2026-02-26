//
//  VRVideoPlayerView.swift
//  MediaStream
//
//  SwiftUI wrapper managing VR video playback lifecycle and controls overlay.
//

import SwiftUI
import AVFoundation

// MARK: - VR Video Player View

/// Full-screen VR video player with playback controls and projection picker.
public struct VRVideoPlayerView: View {
    let url: URL
    let initialProjection: VRProjection
    let authHeaders: [String: String]

    /// Called when video playback completes
    var onVideoComplete: (() -> Void)?

    /// Called when the user changes the projection via the in-player picker
    var onProjectionChange: ((VRProjection) -> Void)?

    /// External controls visibility (synced with gallery slideshow controls)
    var externalShowControls: Bool?

    /// Called when the user taps the VR view (used by gallery to toggle its own controls)
    var onTapToggleControls: (() -> Void)?

    /// Called to go to next/previous media item (slideshow integration)
    var onNextItem: (() -> Void)?
    var onPreviousItem: (() -> Void)?

    /// Media item for position saving (recently played tracking)
    var mediaItem: (any MediaItem)?

    /// Called when user manually triggers play (for slideshow sync)
    var onManualPlayTriggered: (() -> Void)?

    /// Reports (currentTime, duration) periodically for external scrub bar
    var onTimeUpdate: ((Double, Double) -> Void)?

    /// External seek request — set to a time value to seek, VR player resets to nil after seeking
    @Binding var externalSeekRequest: Double?

    @State private var player: AVPlayer?
    @State private var currentProjection: VRProjection
    @State private var isPlaying = false
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var isScrubbing = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0

    #if os(tvOS)
    @State private var scrubMode = false
    @State private var scrubPreviewTime: Double = 0
    #endif
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    // Camera state
    @State private var manualYaw: Float = 0
    @State private var manualPitch: Float = 0
    @State private var gyroYaw: Float = 0
    @State private var gyroPitch: Float = 0
    @State private var gyroEnabled = false
    @State private var fieldOfView: Double = 70

    @State private var showProjectionPicker = false
    @State private var lastPositionSaveTime = Date.distantPast

    #if os(iOS)
    @State private var motionController: VRMotionController?
    #endif

    /// Direct reference to the scene coordinator for bypassing @State on 60Hz updates (gyro)
    @State private var sceneCoordinator: VRSceneCoordinator?

    #if os(tvOS)
    @State private var remoteMotionController: VRRemoteMotionController?
    #endif

    public init(url: URL, initialProjection: VRProjection, authHeaders: [String: String] = [:],
                onVideoComplete: (() -> Void)? = nil, onProjectionChange: ((VRProjection) -> Void)? = nil,
                externalShowControls: Bool? = nil,
                onTapToggleControls: (() -> Void)? = nil,
                onNextItem: (() -> Void)? = nil, onPreviousItem: (() -> Void)? = nil,
                mediaItem: (any MediaItem)? = nil,
                onManualPlayTriggered: (() -> Void)? = nil,
                onTimeUpdate: ((Double, Double) -> Void)? = nil,
                externalSeekRequest: Binding<Double?> = .constant(nil)) {
        self.url = url
        self.initialProjection = initialProjection
        self.authHeaders = authHeaders
        self.onVideoComplete = onVideoComplete
        self.onProjectionChange = onProjectionChange
        self.externalShowControls = externalShowControls
        self.onTapToggleControls = onTapToggleControls
        self.onNextItem = onNextItem
        self.onPreviousItem = onPreviousItem
        self.mediaItem = mediaItem
        self.onManualPlayTriggered = onManualPlayTriggered
        self.onTimeUpdate = onTimeUpdate
        self._externalSeekRequest = externalSeekRequest
        self._currentProjection = State(initialValue: initialProjection)
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                VRVideoView(
                    player: player,
                    projection: currentProjection,
                    manualYaw: $manualYaw,
                    manualPitch: $manualPitch,
                    gyroYaw: $gyroYaw,
                    gyroPitch: $gyroPitch,
                    gyroEnabled: $gyroEnabled,
                    fieldOfView: $fieldOfView,
                    onTap: {
                        if let onTapToggleControls = onTapToggleControls {
                            // Gallery mode: forward tap to gallery so it toggles its own controls
                            // (gallery syncs back via externalShowControls)
                            onTapToggleControls()
                        } else {
                            // Standalone mode: toggle our own controls
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showControls.toggle()
                            }
                            if showControls {
                                resetControlsTimer()
                            }
                        }
                    },
                    onPlayPause: {
                        togglePlayPause()
                    },
                    controlsVisible: showControls || showProjectionPicker,
                    onCoordinatorReady: { coordinator in
                        DispatchQueue.main.async {
                            sceneCoordinator = coordinator
                        }
                    }
                )
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .scaleEffect(1.5)
            }

            #if os(tvOS)
            // tvOS focus-based press handling. TVSCNView is never focusable — it only
            // handles pan gestures for look-around. All press events go through SwiftUI.

            if externalShowControls != nil {
                // External controls mode (gallery slideshow manages controls):
                // Don't show our own controls overlay — the gallery's slideshow overlay
                // handles prev/next/play/loop/etc. Just remove focus capture when the
                // gallery's controls are visible so focus reaches the gallery's buttons.
                if !showControls {
                    TVFocusCaptureView {
                        // Select press does nothing here — the gallery handles control toggling
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // When showControls is true (synced from gallery), no focus capture view
                // is present, so focus naturally moves to the gallery's slideshow overlay.
            } else {
                // Standalone mode (VR player manages its own controls):
                // When controls are hidden: invisible UIKit view captures Select press.
                if !showControls && !showProjectionPicker {
                    TVFocusCaptureView {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showControls = true
                        }
                        resetControlsTimer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // When controls are visible: show overlay with focusable buttons.
                if showControls {
                    controlsOverlay
                        .transition(.opacity)
                        .focusSection()
                        .onExitCommand {
                            if scrubMode {
                                scrubMode = false
                            } else {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showControls = false
                                }
                            }
                        }
                }

                if showProjectionPicker {
                    projectionPickerOverlay
                        .transition(.opacity)
                        .focusSection()
                        .onExitCommand {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showProjectionPicker = false
                            }
                        }
                }
            }
            #else
            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }

            if showProjectionPicker {
                projectionPickerOverlay
                    .transition(.opacity)
            }
            #endif

        }
        .onAppear {
            setupPlayer()
            // Sync initial external state, or start auto-hide timer
            if let ext = externalShowControls {
                showControls = ext
            } else {
                resetControlsTimer()
            }
        }
        .onDisappear {
            cleanup()
        }
        .onChange(of: externalShowControls) { _, newValue in
            if let visible = newValue {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = visible
                }
            }
        }
        .onChange(of: externalSeekRequest) { _, newValue in
            if let seekTime = newValue {
                currentTime = seekTime
                player?.seek(to: CMTime(seconds: seekTime, preferredTimescale: 600))
                externalSeekRequest = nil
            }
        }
        #if os(tvOS)
        // Play/pause works at any time — no UIKit view intercepts it now
        .onPlayPauseCommand {
            togglePlayPause()
        }
        #endif
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack {
            Spacer()

            VStack(spacing: 12) {
                // Seek bar
                HStack(spacing: 8) {
                    Text(formatTime(currentTime))
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()

                    #if os(tvOS)
                    // tvOS: interactive scrub bar
                    VRScrubBar(
                        currentTime: currentTime,
                        duration: duration,
                        scrubMode: $scrubMode,
                        scrubPreviewTime: $scrubPreviewTime,
                        onSeek: { time in
                            currentTime = time
                            player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
                        }
                    )
                    #else
                    Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                        isScrubbing = editing
                        if !editing {
                            player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                        }
                    }
                    .tint(.white)
                    #endif

                    Text(formatTime(duration))
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)

                // Button bar
                HStack(spacing: 20) {
                    // Play/Pause
                    vrControlButton(icon: isPlaying ? "pause.fill" : "play.fill") {
                        togglePlayPause()
                    }

                    // Reset view
                    vrControlButton(icon: "location.north.fill") {
                        manualYaw = 0
                        manualPitch = 0
                        fieldOfView = 70
                    }

                    #if os(iOS)
                    // Gyro toggle — tap to switch between swipe and sensor control
                    vrControlButton(icon: gyroEnabled ? "gyroscope" : "hand.draw",
                                    tint: gyroEnabled ? .cyan : nil) {
                        if gyroEnabled {
                            gyroEnabled = false
                            stopMotion()
                        } else {
                            gyroEnabled = true
                            startMotion()
                        }
                    }
                    #endif

                    // Projection picker — label shows current projection name
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showProjectionPicker = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "view.3d")
                                .font(.title3)
                            Text(currentProjection.shortLabel)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 44)
                    }
                    #if os(tvOS)
                    .buttonStyle(VRControlBtnStyle())
                    #elseif os(macOS)
                    .buttonStyle(.plain)
                    #endif

                    #if os(tvOS)
                    // Prev/Next media item (slideshow navigation)
                    if onPreviousItem != nil || onNextItem != nil {
                        if let onPrev = onPreviousItem {
                            vrControlButton(icon: "backward.end.fill") { onPrev() }
                        }
                        if let onNext = onNextItem {
                            vrControlButton(icon: "forward.end.fill") { onNext() }
                        }
                    }
                    #endif

                    Spacer()
                }
                .padding(.horizontal, 40)
            }
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
        }
    }

    /// Inline projection picker overlay (no sheet — avoids SceneKit rendering conflicts)
    private var projectionPickerOverlay: some View {
        ZStack {
            // Dimming background — tap to dismiss
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showProjectionPicker = false
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
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentProjection = proj
                                    showProjectionPicker = false
                                }
                                onProjectionChange?(proj)
                            } label: {
                                HStack {
                                    Text(proj.displayName)
                                        .foregroundColor(.white)
                                    Spacer()
                                    if proj == currentProjection {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.cyan)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(proj == currentProjection ? Color.white.opacity(0.15) : Color.clear)
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

    // MARK: - Player Setup

    private func setupPlayer() {
        let asset: AVURLAsset
        if !authHeaders.isEmpty {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": authHeaders])
        } else {
            asset = AVURLAsset(url: url)
        }

        let playerItem = AVPlayerItem(asset: asset)
        // Buffer more aggressively for large remote files (30s forward buffer)
        playerItem.preferredForwardBufferDuration = 30
        let avPlayer = AVPlayer(playerItem: playerItem)
        // Don't wait to buffer — start rendering frames immediately.
        // Remote files may stall briefly but this avoids blank/white screen on startup.
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        self.player = avPlayer

        // Time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds
            if let item = avPlayer.currentItem {
                let dur = item.duration
                if dur.isNumeric {
                    duration = dur.seconds
                }
            }
            // Report time to external scrub bar
            onTimeUpdate?(currentTime, duration)
            // Save position periodically (every 10s) for recently played tracking
            savePositionThrottled()
        }

        // End observer
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: nil  // Use posting queue to avoid main-thread contention during rapid loops
        ) { [weak avPlayer] _ in
            Task { @MainActor in
                // Loop short videos (< 2 minutes) instead of completing
                if duration > 0 && duration < 120, let player = avPlayer {
                    player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                        guard finished else { return }
                        Task { @MainActor in
                            player.play()
                        }
                    }
                    isPlaying = true
                    return
                }
                isPlaying = false
                // Video completed — clear saved position so it doesn't resume mid-video
                if let item = mediaItem {
                    Task { await MediaStreamConfiguration.savePosition(for: item, position: 0) }
                }
                onVideoComplete?()
            }
        }

        avPlayer.play()
        isPlaying = true

        #if os(tvOS) || os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    private func cleanup() {
        // Save final position before tearing down
        savePositionNow()

        controlsTimer?.invalidate()
        controlsTimer = nil

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }

        player?.pause()
        player = nil

        #if os(iOS)
        stopMotion()
        #endif
        #if os(tvOS)
        stopRemoteMotion()
        #endif

        #if os(tvOS) || os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
            onManualPlayTriggered?()
        }
        isPlaying.toggle()
    }

    private func resetControlsTimer() {
        // Don't use local timer if externally controlled
        guard externalShowControls == nil else { return }
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            #if os(tvOS)
            guard !isScrubbing && !showProjectionPicker && !scrubMode else { return }
            #else
            guard !isScrubbing && !showProjectionPicker else { return }
            #endif
            withAnimation(.easeInOut(duration: 0.25)) {
                showControls = false
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    // MARK: - Position Saving

    /// Save position throttled (every 10s) — called from periodic time observer
    private func savePositionThrottled() {
        guard let item = mediaItem, currentTime > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPositionSaveTime) >= 10 else { return }
        lastPositionSaveTime = now
        let pos = currentTime
        Task { await MediaStreamConfiguration.savePosition(for: item, position: pos) }
    }

    /// Save position immediately — called on cleanup/disappear
    private func savePositionNow() {
        guard let item = mediaItem, currentTime > 0 else { return }
        let pos = currentTime
        Task { await MediaStreamConfiguration.savePosition(for: item, position: pos) }
    }

    // MARK: - Motion (iOS)

    #if os(iOS)
    private func startMotion() {
        let coord = sceneCoordinator
        let controller = VRMotionController { yaw, pitch in
            coord?.gyroYaw = yaw
            coord?.gyroPitch = pitch
        }
        controller.start()
        motionController = controller
    }

    private func stopMotion() {
        motionController?.stop()
        motionController = nil
        // Fold gyro offsets into manual so the view stays at the current orientation
        let gy = sceneCoordinator?.gyroYaw ?? gyroYaw
        let gp = sceneCoordinator?.gyroPitch ?? gyroPitch
        manualYaw += gy
        manualPitch += gp
        sceneCoordinator?.manualYaw = manualYaw
        sceneCoordinator?.manualPitch = manualPitch
        sceneCoordinator?.gyroYaw = 0
        sceneCoordinator?.gyroPitch = 0
        gyroYaw = 0
        gyroPitch = 0
    }
    #endif

    // MARK: - Motion (tvOS)

    #if os(tvOS)
    private func startRemoteMotion() {
        // Write gyro values directly to the scene coordinator (read by its render delegate).
        // This bypasses @State → SwiftUI body re-evaluation → updateUIView, which at 60Hz
        // floods SwiftUI and freezes the app.
        let coord = sceneCoordinator
        let controller = VRRemoteMotionController { yaw, pitch in
            coord?.gyroYaw = yaw
            coord?.gyroPitch = pitch
        }
        controller.start()
        remoteMotionController = controller
    }

    private func stopRemoteMotion() {
        remoteMotionController?.stop()
        remoteMotionController = nil
        sceneCoordinator?.gyroYaw = 0
        sceneCoordinator?.gyroPitch = 0
        gyroYaw = 0
        gyroPitch = 0
    }
    #endif

    // MARK: - Control Button Helper

    /// Builds a control button matching tvOS slideshow style (subtle scale, no background chrome)
    @ViewBuilder
    private func vrControlButton(icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VRControlBtnLabel(icon: icon, tint: tint)
        }
        #if os(tvOS)
        .buttonStyle(VRControlBtnStyle())
        #elseif os(macOS)
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - VR Control Button Style (matches TVSlideBtnStyle)

#if os(tvOS)
private struct VRControlBtnStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.15 : (configuration.isPressed ? 0.9 : 1.0))
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Button style for the scrub bar — no scale effect (would overflow screen), just opacity change.
private struct VRScrubBarBtnStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isFocused ? 1.0 : 0.7)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
#endif

private struct VRControlBtnLabel: View {
    let icon: String
    var tint: Color?

    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    var body: some View {
        Image(systemName: icon)
            .font(.title3)
            #if os(tvOS)
            .foregroundColor(isFocused ? (tint ?? .white) : (tint?.opacity(0.7) ?? Color.white.opacity(0.5)))
            #else
            .foregroundColor(tint ?? .white)
            #endif
            .frame(width: 50, height: 44)
    }
}

// MARK: - tvOS Scrub Bar

#if os(tvOS)
/// Interactive progress bar for tvOS VR video player.
/// Click to enter scrub mode, left/right to adjust, click to confirm, Menu to cancel.
/// IMPORTANT: .onMoveCommand and .onExitCommand are only added when in scrub mode,
/// because these modifiers ALWAYS consume their respective presses — even if the handler
/// does nothing. When not in scrub mode, presses must pass through so focus navigation
/// and menu dismiss work normally.
struct VRScrubBar: View {
    let currentTime: Double
    let duration: Double
    @Binding var scrubMode: Bool
    @Binding var scrubPreviewTime: Double
    let onSeek: (Double) -> Void

    @Environment(\.isFocused) private var isFocused

    private var displayTime: Double {
        scrubMode ? scrubPreviewTime : currentTime
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return displayTime / duration
    }

    var body: some View {
        Button {
            if scrubMode {
                onSeek(scrubPreviewTime)
                scrubMode = false
            } else {
                scrubPreviewTime = currentTime
                scrubMode = true
            }
        } label: {
            VStack(spacing: 4) {
                if scrubMode {
                    Text(formatTime(scrubPreviewTime))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.cyan)
                        .monospacedDigit()
                        .transition(.opacity)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3))
                            .frame(height: scrubMode ? 10 : 6)
                        Capsule().fill(scrubMode ? Color.cyan : Color.white)
                            .frame(width: max(0, geo.size.width * progress), height: scrubMode ? 10 : 6)
                    }
                }
                .frame(height: scrubMode ? 10 : 6)
            }
            .animation(.easeInOut(duration: 0.2), value: scrubMode)
        }
        // No scale effect on scrub bar — VRControlBtnStyle scales the whole view which
        // makes the bar overflow beyond screen edges. Use a subtle highlight instead.
        .buttonStyle(VRScrubBarBtnStyle())
        // Always apply onMoveCommand but only act when scrubMode is active.
        // Using .if() to conditionally add these modifiers changes the view identity,
        // causing SwiftUI to recreate the button and lose focus — so scrub mode would
        // immediately break. Instead we always have them but guard the handlers.
        .onMoveCommand { direction in
            guard scrubMode else { return }
            switch direction {
            case .left:
                scrubPreviewTime = max(0, scrubPreviewTime - 5)
            case .right:
                scrubPreviewTime = min(duration, scrubPreviewTime + 5)
            default:
                break
            }
        }
        // NOTE: .onExitCommand is NOT placed here — it would always consume Menu presses
        // and prevent the parent controlsOverlay from dismissing. Instead, the parent
        // .onExitCommand checks scrubMode and cancels scrub or dismisses controls.
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}

// MARK: - tvOS Focus Capture View

/// UIViewRepresentable that captures Select press without any visual focus effect.
/// Unlike SwiftUI Button, UIView subclasses don't get the tvOS system focus highlight
/// (white haze). Menu/PlayPause pass through via UIView's responder chain to SwiftUI modifiers.
struct TVFocusCaptureView: UIViewRepresentable {
    let onSelect: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = FocusCaptureUIView()
        view.onSelect = onSelect
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? FocusCaptureUIView)?.onSelect = onSelect
    }

    private class FocusCaptureUIView: UIView {
        var onSelect: (() -> Void)?

        override var canBecomeFocused: Bool { true }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            // No visual change on focus — plain UIView with clear background
            // doesn't get the system focus highlight (that's only on UIButton/UIImageView)
        }

        // Pass ALL touch events through to views below (SCNView's pan gesture).
        // This view only needs to handle press events (Select/Menu/PlayPause)
        // via the responder chain — touches for pan/swipe must reach the SCNView.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Return nil for touch events so they pass through to the SCNView underneath.
            // Press events don't go through hitTest — they use the focus system.
            return nil
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var unhandled = [UIPress]()
            for press in presses {
                if press.type == .select {
                    onSelect?()
                } else {
                    // Menu, PlayPause, arrows → pass to next responder → SwiftUI
                    unhandled.append(press)
                }
            }
            if !unhandled.isEmpty {
                super.pressesBegan(Set(unhandled), with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            // Pass all pressesEnded through except select
            let passThrough = presses.filter { $0.type != .select }
            if !passThrough.isEmpty {
                super.pressesEnded(Set(passThrough), with: event)
            }
        }
    }
}
#endif
