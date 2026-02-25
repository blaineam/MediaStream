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

    #if os(iOS)
    @State private var motionController: VRMotionController?
    #endif

    #if os(tvOS)
    @State private var remoteMotionController: VRRemoteMotionController?
    #endif

    public init(url: URL, initialProjection: VRProjection, authHeaders: [String: String] = [:],
                onVideoComplete: (() -> Void)? = nil, onProjectionChange: ((VRProjection) -> Void)? = nil,
                externalShowControls: Bool? = nil) {
        self.url = url
        self.initialProjection = initialProjection
        self.authHeaders = authHeaders
        self.onVideoComplete = onVideoComplete
        self.onProjectionChange = onProjectionChange
        self.externalShowControls = externalShowControls
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
                    onTap: externalShowControls != nil ? nil : {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showControls.toggle()
                        }
                        if showControls {
                            resetControlsTimer()
                        }
                    },
                    onPlayPause: {
                        togglePlayPause()
                    },
                    controlsVisible: showControls || showProjectionPicker
                )
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .scaleEffect(1.5)
            }

            // Controls overlay — always in the view tree on tvOS so focus
            // engine can discover the buttons; hidden via opacity when not visible.
            #if os(tvOS)
            controlsOverlay
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
                .focusSection()

            if showProjectionPicker {
                projectionPickerOverlay
                    .transition(.opacity)
                    .focusSection()
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
        #if os(tvOS)
        .onPlayPauseCommand {
            togglePlayPause()
        }
        .onExitCommand {
            if showControls {
                withAnimation { showControls = false }
            } else if showProjectionPicker {
                withAnimation { showProjectionPicker = false }
            }
        }
        .onMoveCommand { direction in
            guard externalShowControls == nil else { return }
            // If controls are hidden, any direction press shows them
            if !showControls {
                withAnimation { showControls = true }
                resetControlsTimer()
            }
            // When controls are visible, let SwiftUI handle focus navigation
            // between buttons — don't intercept with seeking
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

                    Spacer().frame(width: 12)

                    // Reset view
                    vrControlButton(icon: "location.north.fill") {
                        manualYaw = 0
                        manualPitch = 0
                        fieldOfView = 70
                    }

                    #if os(iOS)
                    // Gyro — hold to tilt
                    Image(systemName: gyroEnabled ? "gyroscope" : "hand.draw")
                        .font(.title3)
                        .foregroundColor(gyroEnabled ? .cyan : .white)
                        .frame(width: 50, height: 44)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if !gyroEnabled {
                                        gyroEnabled = true
                                        startMotion()
                                    }
                                }
                                .onEnded { _ in
                                    gyroEnabled = false
                                    stopMotion()
                                }
                        )
                    #endif

                    #if os(tvOS)
                    // Remote tilt toggle
                    vrControlButton(icon: gyroEnabled ? "gyroscope" : "hand.draw", tint: gyroEnabled ? .cyan : nil) {
                        gyroEnabled.toggle()
                        if gyroEnabled {
                            startRemoteMotion()
                        } else {
                            stopRemoteMotion()
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
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .frame(maxWidth: 260)
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
        }

        // End observer
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            isPlaying = false
            onVideoComplete?()
        }

        avPlayer.play()
        isPlaying = true

        #if os(tvOS) || os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    private func cleanup() {
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

    // MARK: - Motion (iOS)

    #if os(iOS)
    private func startMotion() {
        let controller = VRMotionController { yaw, pitch in
            gyroYaw = yaw
            gyroPitch = pitch
        }
        controller.start()
        motionController = controller
    }

    private func stopMotion() {
        motionController?.stop()
        motionController = nil
        gyroYaw = 0
        gyroPitch = 0
    }
    #endif

    // MARK: - Motion (tvOS)

    #if os(tvOS)
    private func startRemoteMotion() {
        let controller = VRRemoteMotionController { yaw, pitch in
            gyroYaw = yaw
            gyroPitch = pitch
        }
        controller.start()
        remoteMotionController = controller
    }

    private func stopRemoteMotion() {
        remoteMotionController?.stop()
        remoteMotionController = nil
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
                // Confirm seek
                onSeek(scrubPreviewTime)
                scrubMode = false
            } else {
                // Enter scrub mode
                scrubPreviewTime = currentTime
                scrubMode = true
            }
        } label: {
            VStack(spacing: 4) {
                // Time preview label during scrubbing
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
        .buttonStyle(.plain)
        .focusable()
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
        .onExitCommand {
            if scrubMode {
                scrubMode = false
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
#endif
