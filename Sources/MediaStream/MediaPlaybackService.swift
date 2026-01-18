//
//  MediaPlaybackService.swift
//  MediaStream
//
//  Singleton service for managing media playback with background audio support,
//  Now Playing info, remote command handling, and Picture-in-Picture.
//

import Foundation
import AVFoundation
import AVKit
import MediaPlayer
import Combine

#if canImport(UIKit)
import UIKit
#endif

/// Playback state for the media player
public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case failed(String)

    public static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.playing, .playing),
             (.paused, .paused), (.stopped, .stopped):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError == rhsError
        default:
            return false
        }
    }
}

/// Loop mode for playlist playback (matches MediaGalleryView.LoopMode)
public enum PlaybackLoopMode: Int, CaseIterable, Sendable {
    case off      // No looping
    case all      // Loop entire playlist
    case one      // Loop current item

    public var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    public var description: String {
        switch self {
        case .off: return "Loop Off"
        case .all: return "Loop All"
        case .one: return "Loop One"
        }
    }

    public func next() -> PlaybackLoopMode {
        let allCases = PlaybackLoopMode.allCases
        let currentIndex = allCases.firstIndex(of: self) ?? 0
        let nextIndex = (currentIndex + 1) % allCases.count
        return allCases[nextIndex]
    }
}

/// Information about the currently playing media
public struct NowPlayingInfo: Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artwork: PlatformImage?
    public let duration: TimeInterval?
    public let isVideo: Bool

    public init(title: String? = nil, artist: String? = nil, album: String? = nil,
                artwork: PlatformImage? = nil, duration: TimeInterval? = nil, isVideo: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.duration = duration
        self.isVideo = isVideo
    }
}

/// Playlist item wrapper
public struct PlaylistItem: Identifiable, Sendable {
    public let id: UUID
    public let mediaItem: any MediaItem
    public let info: NowPlayingInfo?

    public init(mediaItem: any MediaItem, info: NowPlayingInfo? = nil) {
        self.id = mediaItem.id
        self.mediaItem = mediaItem
        self.info = info
    }
}

/// Singleton service for managing media playback with background support
@MainActor
public final class MediaPlaybackService: NSObject, ObservableObject {

    // MARK: - Notifications

    /// Posted when app enters background and non-cached media should pause
    public static let shouldPauseForBackgroundNotification = Notification.Name("MediaPlaybackService.shouldPauseForBackground")

    /// Posted when remote play command is received for external players
    public static let externalPlayNotification = Notification.Name("MediaPlaybackService.externalPlay")

    /// Posted when remote pause command is received for external players
    public static let externalPauseNotification = Notification.Name("MediaPlaybackService.externalPause")

    /// Posted when remote seek command is received for external players (userInfo contains "time" key)
    public static let externalSeekNotification = Notification.Name("MediaPlaybackService.externalSeek")

    /// Posted when track changes via remote commands (userInfo contains "index" key with the new index in cached items)
    public static let externalTrackChangedNotification = Notification.Name("MediaPlaybackService.externalTrackChanged")

    // MARK: - Singleton

    public static let shared = MediaPlaybackService()

    // MARK: - Published Properties

    @Published public private(set) var playbackState: PlaybackState = .idle
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var nowPlayingInfo: NowPlayingInfo?
    @Published public var currentIndex: Int = 0

    // Playback modes
    @Published public var loopMode: PlaybackLoopMode = .all
    @Published public var isShuffled: Bool = false

    // PiP state
    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var isPiPSupported: Bool = false

    // Background mode
    @Published public private(set) var isInBackground: Bool = false

    /// The media type that was playing when backgrounded (used to filter playlist)
    private var backgroundMediaType: MediaType?

    // MARK: - Player

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var playerItemObserver: NSKeyValueObservation?
    private var playerStatusObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - PiP

    #if canImport(UIKit)
    private var pipController: AVPictureInPictureController?
    private var playerLayer: AVPlayerLayer?
    #endif

    // MARK: - Playlist

    private var playlist: [PlaylistItem] = []
    private var shuffledIndices: [Int] = []
    private var shuffledPosition: Int = 0

    // MARK: - Current Media

    private var currentMediaURL: URL?

    // MARK: - Callbacks

    /// Called when playback naturally completes (not stopped by user)
    public var onPlaybackComplete: (() -> Void)?

    /// Called when transitioning to next track
    public var onTrackChanged: ((Int) -> Void)?

    /// Called when app returns from background with PiP active - UI should restore main view
    public var onRestoreFromPiP: (() -> Void)?

    /// Called when remote play command is received (for external players)
    public var onExternalPlay: (() -> Void)?

    /// Called when remote pause command is received (for external players)
    public var onExternalPause: (() -> Void)?

    /// Called when remote seek command is received (for external players)
    public var onExternalSeek: ((TimeInterval) -> Void)?

    /// When true, remote commands only change the index and call onTrackChanged,
    /// letting the view handle actual playback. When false, the service plays media itself.
    public var externalPlaybackMode: Bool = false

    // MARK: - Initialization

    override private init() {
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupNotifications()
        checkPiPSupport()
    }

    // MARK: - Audio Session Setup

    private func setupAudioSession() {
        #if canImport(UIKit)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            print("[MediaPlaybackService] Audio session configured for background playback")
        } catch {
            print("[MediaPlaybackService] Failed to configure audio session: \(error)")
        }
        #endif
    }

    // MARK: - PiP Support

    private func checkPiPSupport() {
        #if canImport(UIKit)
        isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
        print("[MediaPlaybackService] PiP supported: \(isPiPSupported)")
        #else
        isPiPSupported = false
        #endif
    }

    #if canImport(UIKit)
    /// Setup PiP controller for video playback
    public func setupPiP(with playerLayer: AVPlayerLayer) {
        guard isPiPSupported else { return }

        // If this is the same player layer, don't recreate
        if self.playerLayer === playerLayer && pipController != nil {
            print("[MediaPlaybackService] PiP controller already configured for this layer")
            return
        }

        // Stop existing PiP if active before switching to new layer
        if isPiPActive {
            pipController?.stopPictureInPicture()
            isPiPActive = false
        }

        // Clean up old controller
        pipController?.delegate = nil
        pipController = nil

        // Store new layer and create controller
        self.playerLayer = playerLayer
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.delegate = self

        print("[MediaPlaybackService] PiP controller configured for new layer")
    }

    /// Start Picture-in-Picture mode
    public func startPiP() {
        guard let pipController = pipController else {
            print("[MediaPlaybackService] PiP controller not available")
            return
        }

        // Wait a moment for the controller to be ready
        if !pipController.isPictureInPicturePossible {
            print("[MediaPlaybackService] PiP not yet possible, waiting...")
            // Retry after a short delay
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                await MainActor.run {
                    if pipController.isPictureInPicturePossible {
                        pipController.startPictureInPicture()
                        print("[MediaPlaybackService] PiP started after delay")
                    } else {
                        print("[MediaPlaybackService] PiP still not possible after delay")
                    }
                }
            }
            return
        }
        pipController.startPictureInPicture()
    }

    /// Stop Picture-in-Picture mode
    public func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    /// Toggle PiP mode
    public func togglePiP() {
        if isPiPActive {
            stopPiP()
        } else {
            startPiP()
        }
    }

    /// Check if PiP is currently possible
    public var isPiPPossible: Bool {
        pipController?.isPictureInPicturePossible ?? false
    }
    #endif

    // MARK: - Remote Command Setup

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.play()
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }

        // Next track
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.nextTrack()
            }
            return .success
        }

        // Previous track
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.previousTrack()
            }
            return .success
        }

        // Seek command
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.seek(to: positionEvent.positionTime)
            }
            return .success
        }

        // Disable skip forward/backward to prioritize next/previous track buttons
        // When both are enabled, iOS may show skip buttons instead of track buttons
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false

        // Keep seek bar functionality via changePlaybackPositionCommand (already enabled above)
        // Users can still seek by dragging the progress bar on lock screen

        /*
        // Skip forward/backward (disabled - use next/prev track instead)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                let newTime = (self?.currentTime ?? 0) + skipEvent.interval
                self?.seek(to: min(newTime, self?.duration ?? 0))
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                let newTime = (self?.currentTime ?? 0) - skipEvent.interval
                self?.seek(to: max(newTime, 0))
            }
            return .success
        }
        */

        print("[MediaPlaybackService] Remote commands configured")
    }

    // MARK: - Notifications

    private func setupNotifications() {
        #if canImport(UIKit)
        // Handle audio interruptions (phone calls, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // Handle route changes (headphones unplugged, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // Handle app about to resign active (start PiP here, before background)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )

        // Handle app entering background (track background state)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Handle app entering foreground
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
    }

    #if canImport(UIKit)
    @objc private func handleAppWillResignActive(_ notification: Notification) {
        // Auto-PiP disabled - users should manually trigger PiP using the toggle button.
        // PiP only works reliably when media is cached locally (see MediaDownloadManager).
        // Keeping this handler for potential future use but not auto-starting PiP.
    }

    @objc private func handleAppDidEnterBackground(_ notification: Notification) {
        Task { @MainActor in
            isInBackground = true

            // Remember what type of media we were playing (if playlist is set up)
            if !playlist.isEmpty && currentIndex < playlist.count {
                let currentMedia = playlist[currentIndex].mediaItem
                backgroundMediaType = currentMedia.type

                // Pause non-cached media since rclone server will be killed
                let isCached = MediaDownloadManager.shared.isCached(mediaItem: currentMedia)
                if !isCached && isPlaying {
                    print("[MediaPlaybackService] Pausing non-cached media for background")
                    pause()
                }
            }

            // Always post notification when entering background if NOT in external playback mode
            // This handles cases where non-cached media is playing but playlist wasn't set up
            // The notification handlers in views will check cache status and pause if needed
            if !externalPlaybackMode {
                print("[MediaPlaybackService] Posting pause notification for non-external playback")
                NotificationCenter.default.post(
                    name: MediaPlaybackService.shouldPauseForBackgroundNotification,
                    object: nil
                )
            }

            print("[MediaPlaybackService] App entered background, externalPlayback: \(externalPlaybackMode), media type: \(backgroundMediaType.map { String(describing: $0) } ?? "none")")
        }
    }

    @objc private func handleAppWillEnterForeground(_ notification: Notification) {
        Task { @MainActor in
            let wasInBackground = isInBackground
            isInBackground = false
            backgroundMediaType = nil

            // Auto-stop PiP when returning to foreground
            if wasInBackground && isPiPActive {
                pipController?.stopPictureInPicture()
                print("[MediaPlaybackService] Auto-stopping PiP for foreground return")
                // Notify that we should restore the main view
                onRestoreFromPiP?()
            }
            print("[MediaPlaybackService] App entering foreground")
        }
    }
    #endif

    #if canImport(UIKit)
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        Task { @MainActor in
            switch type {
            case .began:
                print("[MediaPlaybackService] Audio interruption began")
                pause()
            case .ended:
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        print("[MediaPlaybackService] Audio interruption ended, resuming")
                        play()
                    }
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        Task { @MainActor in
            switch reason {
            case .oldDeviceUnavailable:
                print("[MediaPlaybackService] Audio route changed (device unavailable), pausing")
                pause()
            default:
                break
            }
        }
    }
    #endif

    // MARK: - Playlist Management

    /// Set the playlist from media items
    public func setPlaylist(_ mediaItems: [any MediaItem], startIndex: Int = 0) {
        playlist = mediaItems.map { PlaylistItem(mediaItem: $0) }
        currentIndex = min(startIndex, max(0, playlist.count - 1))

        if isShuffled {
            generateShuffledIndices()
        }

        print("[MediaPlaybackService] Playlist set with \(playlist.count) items, starting at \(currentIndex)")
    }

    /// Add item to playlist
    public func addToPlaylist(_ mediaItem: any MediaItem) {
        playlist.append(PlaylistItem(mediaItem: mediaItem))
        if isShuffled {
            shuffledIndices.append(playlist.count - 1)
        }
    }

    /// Clear the playlist
    public func clearPlaylist() {
        stop()
        playlist = []
        shuffledIndices = []
        shuffledPosition = 0
        currentIndex = 0
    }

    /// Toggle shuffle mode
    public func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            generateShuffledIndices()
        } else {
            shuffledIndices = []
            shuffledPosition = 0
        }
        print("[MediaPlaybackService] Shuffle: \(isShuffled)")
    }

    /// Cycle through loop modes
    public func cycleLoopMode() {
        loopMode = loopMode.next()
        print("[MediaPlaybackService] Loop mode: \(loopMode.description)")
    }

    private func generateShuffledIndices() {
        shuffledIndices = Array(0..<playlist.count).shuffled()
        // Move current index to front
        if let pos = shuffledIndices.firstIndex(of: currentIndex) {
            shuffledIndices.remove(at: pos)
            shuffledIndices.insert(currentIndex, at: 0)
        }
        shuffledPosition = 0
    }

    private func reshuffleIndices() {
        shuffledIndices = Array(0..<playlist.count).shuffled()
        shuffledPosition = 0
    }

    // MARK: - Playback Control

    /// Play the current item in the playlist
    public func playCurrentItem() async {
        guard !playlist.isEmpty, currentIndex < playlist.count else { return }

        let item = playlist[currentIndex]
        await loadAndPlay(mediaItem: item.mediaItem, info: item.info)
    }

    /// Load and play media from a URL
    public func loadAndPlay(url: URL, info: NowPlayingInfo? = nil) {
        cleanupPlayer()

        playbackState = .loading
        currentMediaURL = url
        nowPlayingInfo = info

        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)

        setupPlayerObservers()

        // Start playback
        player?.play()
        isPlaying = true
        playbackState = .playing

        updateNowPlayingInfo()

        print("[MediaPlaybackService] Started playback: \(url.lastPathComponent)")
    }

    /// Load and play from a MediaItem
    public func loadAndPlay(mediaItem: any MediaItem, info: NowPlayingInfo? = nil) async {
        var url: URL?
        if mediaItem.type == .audio {
            url = await mediaItem.loadAudioURL()
        } else if mediaItem.type == .video {
            url = await mediaItem.loadVideoURL()
        }

        guard let url = url else {
            playbackState = .failed("Could not load media URL")
            return
        }

        // Build NowPlayingInfo from media item if not provided
        var playingInfo = info
        if playingInfo == nil {
            let metadata = await mediaItem.getAudioMetadata()
            let artwork = await mediaItem.loadImage()
            let audioDuration = await mediaItem.getAudioDuration()
            let videoDuration = await mediaItem.getVideoDuration()
            let mediaDuration = audioDuration ?? videoDuration

            playingInfo = NowPlayingInfo(
                title: metadata?.title,
                artist: metadata?.artist,
                album: metadata?.album,
                artwork: artwork,
                duration: mediaDuration,
                isVideo: mediaItem.type == .video
            )
        }

        loadAndPlay(url: url, info: playingInfo)
    }

    /// Play the current media
    public func play() {
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // In external playback mode, notify the external player via notification
        if externalPlaybackMode {
            isPlaying = true
            playbackState = .playing
            updateNowPlayingInfo()
            onExternalPlay?()
            NotificationCenter.default.post(name: MediaPlaybackService.externalPlayNotification, object: nil)
            print("[MediaPlaybackService] Play (external)")
            return
        }

        guard let player = player else { return }

        player.play()
        isPlaying = true
        playbackState = .playing
        updateNowPlayingInfo()

        print("[MediaPlaybackService] Play")
    }

    /// Pause the current media
    public func pause() {
        // In external playback mode, notify the external player via notification
        if externalPlaybackMode {
            isPlaying = false
            playbackState = .paused
            updateNowPlayingInfo()
            onExternalPause?()
            NotificationCenter.default.post(name: MediaPlaybackService.externalPauseNotification, object: nil)
            print("[MediaPlaybackService] Pause (external)")
            return
        }

        guard let player = player else { return }

        player.pause()
        isPlaying = false
        playbackState = .paused
        updateNowPlayingInfo()

        print("[MediaPlaybackService] Pause")
    }

    /// Toggle between play and pause
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Stop playback and cleanup
    public func stop() {
        cleanupPlayer()
        playbackState = .stopped
        isPlaying = false
        currentTime = 0
        duration = 0
        nowPlayingInfo = nil
        currentMediaURL = nil

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        print("[MediaPlaybackService] Stopped")
    }

    /// Seek to a specific time
    public func seek(to time: TimeInterval) {
        // In external playback mode, notify the external player via notification
        if externalPlaybackMode {
            currentTime = time
            updateNowPlayingInfo()
            onExternalSeek?(time)
            NotificationCenter.default.post(
                name: MediaPlaybackService.externalSeekNotification,
                object: nil,
                userInfo: ["time": time]
            )
            print("[MediaPlaybackService] Seek to \(time) (external)")
            return
        }

        guard let player = player else { return }

        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateNowPlayingInfo()
    }

    /// Go to next track
    public func nextTrack() {
        guard !playlist.isEmpty else { return }

        // Loop one mode: just replay current
        if loopMode == .one {
            if externalPlaybackMode {
                // In external mode, notify that we should restart current track
                onTrackChanged?(currentIndex)
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": currentIndex]
                )
            } else {
                seek(to: 0)
                play()
            }
            return
        }

        // Find next playable item (respecting background mode filtering)
        if let nextIndex = findNextPlayableIndex(after: currentIndex, forward: true) {
            currentIndex = nextIndex
            if isShuffled, let pos = shuffledIndices.firstIndex(of: nextIndex) {
                shuffledPosition = pos
            }
            onTrackChanged?(nextIndex)

            // In external playback mode, notify via notification
            if externalPlaybackMode {
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": nextIndex]
                )
                print("[MediaPlaybackService] Next track -> index \(nextIndex)")
            } else {
                Task {
                    await playCurrentItem()
                }
            }
        } else {
            // No more playable items
            if !externalPlaybackMode {
                stop()
            }
        }
    }

    /// Find the next playable index in the playlist
    /// - Parameters:
    ///   - startIndex: Starting index to search from
    ///   - forward: Search forward (true) or backward (false)
    /// - Returns: The next playable index, or nil if none found
    private func findNextPlayableIndex(after startIndex: Int, forward: Bool) -> Int? {
        let count = playlist.count
        guard count > 0 else { return nil }

        var searchOrder: [Int]

        if isShuffled {
            // Use shuffled order
            let currentPos = shuffledIndices.firstIndex(of: startIndex) ?? 0
            if forward {
                // Items after current position, then wrap if looping
                let afterCurrent = shuffledIndices.suffix(from: currentPos + 1)
                let beforeCurrent = loopMode == .all ? shuffledIndices.prefix(upTo: currentPos + 1) : []
                searchOrder = Array(afterCurrent) + Array(beforeCurrent)
            } else {
                // Items before current position, then wrap if looping
                let beforeCurrent = shuffledIndices.prefix(upTo: currentPos).reversed()
                let afterCurrent = loopMode == .all ? shuffledIndices.suffix(from: currentPos).reversed() : []
                searchOrder = Array(beforeCurrent) + Array(afterCurrent)
            }
        } else {
            if forward {
                // Sequential: after current, then wrap if looping
                let afterCurrent = Array((startIndex + 1)..<count)
                let beforeCurrent = loopMode == .all ? Array(0...startIndex) : []
                searchOrder = afterCurrent + beforeCurrent
            } else {
                // Sequential backwards
                let beforeCurrent = Array((0..<startIndex).reversed())
                let afterCurrent = loopMode == .all ? Array((startIndex..<count).reversed()) : []
                searchOrder = beforeCurrent + afterCurrent
            }
        }

        // Find first playable item
        return searchOrder.first { isPlayableInCurrentMode(playlist[$0].mediaItem) }
    }

    /// Check if a media item is playable in the current mode (foreground/background)
    private func isPlayableInCurrentMode(_ mediaItem: any MediaItem) -> Bool {
        // In foreground, everything is playable
        guard isInBackground else { return true }

        let type = mediaItem.type

        // Images are never playable in background
        if type == .image || type == .animatedImage {
            return false
        }

        // WebM files use WebView playback and don't support background/PiP
        if isWebMFile(mediaItem) {
            return false
        }

        // If we have a background media type preference, match it
        if let bgType = backgroundMediaType {
            // Audio can always play in background
            if type == .audio {
                return true
            }
            // Video only plays if we started with video (PiP mode)
            if type == .video {
                return bgType == .video
            }
        }

        // Default: audio and video are playable
        return type == .audio || type == .video
    }

    /// Check if a media item is a WebM file (requires WebView playback, no background support)
    private func isWebMFile(_ mediaItem: any MediaItem) -> Bool {
        // Check diskCacheKey for .webm extension
        if let cacheKey = mediaItem.diskCacheKey?.lowercased() {
            return cacheKey.hasSuffix(".webm")
        }
        return false
    }

    /// Go to previous track
    public func previousTrack() {
        guard !playlist.isEmpty else { return }

        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
            if externalPlaybackMode {
                // In external mode, notify to restart current track
                onTrackChanged?(currentIndex)
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": currentIndex, "restart": true]
                )
            } else {
                seek(to: 0)
            }
            return
        }

        // Find previous playable item (respecting background mode filtering)
        if let prevIndex = findNextPlayableIndex(after: currentIndex, forward: false) {
            currentIndex = prevIndex
            if isShuffled, let pos = shuffledIndices.firstIndex(of: prevIndex) {
                shuffledPosition = pos
            }
            onTrackChanged?(prevIndex)

            // In external playback mode, notify via notification
            if externalPlaybackMode {
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": prevIndex]
                )
                print("[MediaPlaybackService] Previous track -> index \(prevIndex)")
            } else {
                Task {
                    await playCurrentItem()
                }
            }
        } else {
            // No previous playable items, restart current
            if externalPlaybackMode {
                onTrackChanged?(currentIndex)
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": currentIndex, "restart": true]
                )
            } else {
                seek(to: 0)
            }
        }
    }

    /// Jump to specific index in playlist
    public func jumpToIndex(_ index: Int) async {
        guard index >= 0 && index < playlist.count else { return }

        currentIndex = index
        if isShuffled {
            if let pos = shuffledIndices.firstIndex(of: index) {
                shuffledPosition = pos
            }
        }
        onTrackChanged?(index)
        await playCurrentItem()
    }

    /// Get the current AVPlayer (for video layer binding)
    public func getPlayer() -> AVPlayer? {
        return player
    }

    /// Check if a media item is currently playing
    public func isCurrentlyPlaying(mediaItem: any MediaItem) -> Bool {
        guard !playlist.isEmpty, currentIndex < playlist.count else { return false }
        return playlist[currentIndex].id == mediaItem.id && isPlaying
    }

    /// Check if a media item is currently loaded
    public func isCurrentlyLoaded(mediaItem: any MediaItem) -> Bool {
        guard !playlist.isEmpty, currentIndex < playlist.count else { return false }
        return playlist[currentIndex].id == mediaItem.id
    }

    // MARK: - Player Observers

    private func setupPlayerObservers() {
        guard let player = player, let playerItem = playerItem else { return }

        // Observe player item status
        playerItemObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    self?.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self?.updateNowPlayingInfo()
                case .failed:
                    self?.playbackState = .failed(item.error?.localizedDescription ?? "Unknown error")
                default:
                    break
                }
            }
        }

        // Periodic time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
                self?.updateNowPlayingInfo()
            }
        }

        // Observe playback end
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnded()
            }
        }
    }

    private func handlePlaybackEnded() {
        print("[MediaPlaybackService] Playback ended")

        // Handle based on loop mode
        switch loopMode {
        case .one:
            // Loop current item
            seek(to: 0)
            play()
        case .all, .off:
            // Try to go to next, respecting loop mode
            isPlaying = false
            playbackState = .stopped
            onPlaybackComplete?()
            nextTrack()
        }
    }

    private func cleanupPlayer() {
        if let timeObserver = timeObserver, let player = player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        playerItemObserver?.invalidate()
        playerItemObserver = nil
        playerStatusObserver?.invalidate()
        playerStatusObserver = nil

        player?.pause()
        player = nil
        playerItem = nil
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        var info = [String: Any]()

        if let nowPlayingInfo = nowPlayingInfo {
            if let title = nowPlayingInfo.title {
                info[MPMediaItemPropertyTitle] = title
            } else if let url = currentMediaURL {
                info[MPMediaItemPropertyTitle] = url.deletingPathExtension().lastPathComponent
            }

            if let artist = nowPlayingInfo.artist {
                info[MPMediaItemPropertyArtist] = artist
            }

            if let album = nowPlayingInfo.album {
                info[MPMediaItemPropertyAlbumTitle] = album
            }

            if let artwork = nowPlayingInfo.artwork {
                #if canImport(UIKit)
                let mpArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
                info[MPMediaItemPropertyArtwork] = mpArtwork
                #elseif canImport(AppKit)
                let mpArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
                info[MPMediaItemPropertyArtwork] = mpArtwork
                #endif
            }
        } else if let url = currentMediaURL {
            info[MPMediaItemPropertyTitle] = url.deletingPathExtension().lastPathComponent
        }

        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - External Player Integration

    /// Update Now Playing info for media being played by an external player (e.g., the gallery view).
    /// Call this when the view starts playing a new media item.
    public func updateNowPlayingForExternalPlayer(
        mediaItem: any MediaItem,
        title: String?,
        artist: String?,
        album: String?,
        artwork: PlatformImage?,
        duration: TimeInterval,
        isVideo: Bool
    ) {
        nowPlayingInfo = NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            duration: duration,
            isVideo: isVideo
        )
        self.duration = duration
        self.isPlaying = true
        playbackState = .playing
        updateNowPlayingInfo()
    }

    /// Update playback position from an external player.
    /// Call this periodically (e.g., every 0.5-1 second) while media is playing.
    public func updateExternalPlaybackPosition(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        self.currentTime = currentTime
        if duration > 0 && duration.isFinite {
            self.duration = duration
        }
        self.isPlaying = isPlaying
        playbackState = isPlaying ? .playing : .paused

        // Only update time-related info, preserving existing metadata
        // This prevents race condition where metadata hasn't loaded yet
        updateNowPlayingTimeOnly()
    }

    /// Update only time-related Now Playing info (preserves metadata)
    private func updateNowPlayingTimeOnly() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()

        // Only update time-related properties
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Notify that external playback has stopped.
    public func notifyExternalPlaybackStopped() {
        isPlaying = false
        playbackState = .stopped
        currentTime = 0
        updateNowPlayingInfo()
    }

    /// Update Now Playing for the current playlist item (async, loads metadata from media item).
    /// Useful when changing tracks via remote commands.
    public func updateNowPlayingForCurrentItem() async {
        guard !playlist.isEmpty && currentIndex < playlist.count else { return }

        let item = playlist[currentIndex].mediaItem
        let metadata = await item.getAudioMetadata()
        let artwork = await item.loadImage()

        // Get title: try metadata first, then extract from URLs
        var title = metadata?.title

        if title == nil || title?.isEmpty == true {
            // Try sourceURL first (most reliable for filename)
            if let sourceURL = item.sourceURL {
                title = sourceURL.deletingPathExtension().lastPathComponent
            }
            // Try audio URL
            else if let audioURL = await item.loadAudioURL() {
                title = audioURL.deletingPathExtension().lastPathComponent
            }
            // Try video URL
            else if let videoURL = await item.loadVideoURL() {
                title = videoURL.deletingPathExtension().lastPathComponent
            }
            // Final fallback
            else {
                title = "Track \(currentIndex + 1)"
            }
        }

        // Don't set duration from metadata - let the view's player report the actual duration
        // via updateExternalPlaybackPosition. This avoids showing wrong duration.
        // We'll use 0 here and the actual duration will be set when the player reports it.
        updateNowPlayingForExternalPlayer(
            mediaItem: item,
            title: title,
            artist: metadata?.artist,
            album: metadata?.album,
            artwork: artwork,
            duration: self.duration, // Use current duration (will be updated by player)
            isVideo: item.type == .video
        )
    }
}

// MARK: - AVPictureInPictureControllerDelegate

#if canImport(UIKit)
extension MediaPlaybackService: AVPictureInPictureControllerDelegate {
    nonisolated public func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isPiPActive = true
            print("[MediaPlaybackService] PiP will start")
        }
    }

    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isPiPActive = true
            print("[MediaPlaybackService] PiP started")
        }
    }

    nonisolated public func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            print("[MediaPlaybackService] PiP will stop")
        }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isPiPActive = false
            print("[MediaPlaybackService] PiP stopped")
        }
    }

    // swiftlint:disable:next line_length
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            isPiPActive = false
            print("[MediaPlaybackService] PiP failed to start: \(error)")
        }
    }
}
#endif
