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

    // MARK: - Shared Audio Player (Single Player Architecture)

    /// The single shared audio player for all audio playback
    /// This avoids creating multiple players and works reliably in background
    public private(set) var sharedAudioPlayer: AVPlayer?
    private var sharedAudioTimeObserver: Any?
    private var sharedAudioItemObserver: NSKeyValueObservation?
    private var sharedAudioEndObserver: NSObjectProtocol?

    /// The currently loaded media item in the shared audio player
    @Published public private(set) var currentAudioMediaItem: (any MediaItem)?

    /// Whether we're using the shared audio player (vs external/video players)
    @Published public private(set) var isUsingSharedAudioPlayer: Bool = false

    /// External player reference for direct control (avoids notification delays in background)
    /// Note: This is a STRONG reference to ensure we can control the player even after view recreation.
    /// Views MUST call unregisterExternalPlayer() in onDisappear to prevent memory leaks.
    /// DEPRECATED: Use sharedAudioPlayer for audio. This is kept for video players only.
    public var externalPlayer: AVPlayer?

    /// Players registered by media item ID - allows looking up player for specific tracks
    /// Used for next/previous track control in background
    /// DEPRECATED: Now only used for video players
    private var playersByMediaId: [UUID: AVPlayer] = [:]

    /// Backup reference to all registered players for emergency pause
    /// Used when externalPlayer becomes stale but audio is still playing
    /// DEPRECATED: Now only used for video players
    private var registeredPlayers: [ObjectIdentifier: AVPlayer] = [:]

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

    // MARK: - External Player Management

    /// Register an external player for control. Call this when a view starts playing media.
    /// The player is stored strongly to ensure we can control it even after view recreation.
    /// - Parameters:
    ///   - player: The AVPlayer to register
    ///   - mediaId: Optional media item ID for lookup during track changes
    public func registerExternalPlayer(_ player: AVPlayer, forMediaId mediaId: UUID? = nil) {
        let id = ObjectIdentifier(player)
        registeredPlayers[id] = player
        externalPlayer = player

        // Also store by media ID for track change lookup
        if let mediaId = mediaId {
            playersByMediaId[mediaId] = player
            print("[MediaPlaybackService] Registered external player \(id) for media \(mediaId)")
        } else {
            print("[MediaPlaybackService] Registered external player \(id)")
        }
    }

    /// Unregister an external player. Call this in onDisappear to prevent memory leaks.
    public func unregisterExternalPlayer(_ player: AVPlayer, forMediaId mediaId: UUID? = nil) {
        let id = ObjectIdentifier(player)
        player.pause() // Ensure paused before removal
        registeredPlayers.removeValue(forKey: id)

        // Also remove from media ID lookup
        if let mediaId = mediaId {
            playersByMediaId.removeValue(forKey: mediaId)
        }

        if externalPlayer === player {
            // Find another registered player or clear
            externalPlayer = registeredPlayers.values.first
        }
        print("[MediaPlaybackService] Unregistered external player \(id), remaining: \(registeredPlayers.count)")
    }

    /// Get the player for a specific media item ID (if registered)
    public func getPlayer(forMediaId mediaId: UUID) -> AVPlayer? {
        return playersByMediaId[mediaId]
    }

    /// Pause all registered players. Emergency method when normal pause doesn't work.
    public func pauseAllPlayers() {
        for (id, player) in registeredPlayers {
            player.pause()
            print("[MediaPlaybackService] Emergency pause player \(id)")
        }
        externalPlayer?.pause()
        isPlaying = false
        playbackState = .paused
        updateNowPlayingInfo()
    }

    /// Clear all registered players and reset external playback mode
    public func clearAllExternalPlayers() {
        for (_, player) in registeredPlayers {
            player.pause()
        }
        registeredPlayers.removeAll()
        playersByMediaId.removeAll()
        externalPlayer = nil
        externalPlaybackMode = false
        print("[MediaPlaybackService] Cleared all external players")
    }

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
            print("[MediaPlaybackService] 🎮 Remote PLAY command received")
            Task { @MainActor in
                self?.play()
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            print("[MediaPlaybackService] 🎮 Remote PAUSE command received")
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            print("[MediaPlaybackService] 🎮 Remote TOGGLE play/pause command received")
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }

        // Next track
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            print("[MediaPlaybackService] 🎮 Remote NEXT TRACK command received")
            Task { @MainActor in
                self?.nextTrack()
            }
            return .success
        }

        // Previous track
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            print("[MediaPlaybackService] 🎮 Remote PREVIOUS TRACK command received")
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
            print("[MediaPlaybackService] 🎮 Remote SEEK command received: \(positionEvent.positionTime)")
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

                // In external playback mode, DON'T pause here - let the views handle it
                // The views know which player is actually playing and whether it's cached
                // Pausing here would incorrectly pause cached media via externalPlayer
                if !externalPlaybackMode {
                    // Pause non-cached media since rclone server will be killed
                    let isCached = MediaDownloadManager.shared.isCached(mediaItem: currentMedia)
                    if !isCached && isPlaying {
                        print("[MediaPlaybackService] Pausing non-cached media for background")
                        pause()
                    }
                }
            }

            // Post notification for views to handle their own pause logic
            // Views will check cache status and pause non-cached media accordingly
            print("[MediaPlaybackService] Posting pause notification for background (externalPlayback: \(externalPlaybackMode))")
            NotificationCenter.default.post(
                name: MediaPlaybackService.shouldPauseForBackgroundNotification,
                object: nil
            )

            print("[MediaPlaybackService] App entered background, externalPlayback: \(externalPlaybackMode), media type: \(backgroundMediaType.map { String(describing: $0) } ?? "none")")
        }
    }

    @objc private func handleAppWillEnterForeground(_ notification: Notification) {
        Task { @MainActor in
            let wasInBackground = isInBackground
            isInBackground = false
            backgroundMediaType = nil

            // Reactivate audio session when entering foreground
            // iOS may have deactivated it during background
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                print("[MediaPlaybackService] Reactivated audio session for foreground")
            } catch {
                print("[MediaPlaybackService] Failed to reactivate audio session: \(error)")
            }

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
        // For audio, use the shared audio player
        if mediaItem.type == .audio {
            await loadAudioInSharedPlayer(mediaItem: mediaItem, autoplay: true)
            return
        }

        // For video, use the legacy player
        guard let url = await mediaItem.loadVideoURL() else {
            playbackState = .failed("Could not load media URL")
            return
        }

        // Build NowPlayingInfo from media item if not provided
        var playingInfo = info
        if playingInfo == nil {
            let metadata = await mediaItem.getAudioMetadata()
            let artwork = await mediaItem.loadImage()
            let videoDuration = await mediaItem.getVideoDuration()

            playingInfo = NowPlayingInfo(
                title: metadata?.title,
                artist: metadata?.artist,
                album: metadata?.album,
                artwork: artwork,
                duration: videoDuration,
                isVideo: true
            )
        }

        loadAndPlay(url: url, info: playingInfo)
    }

    /// Play the current media
    public func play() {
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // In external playback mode, control players directly for faster response
        if externalPlaybackMode {
            var playedAny = false

            // Priority 1: Use shared audio player if we're using it
            if isUsingSharedAudioPlayer, let audioPlayer = sharedAudioPlayer {
                audioPlayer.play()
                print("[MediaPlaybackService] Play (shared audio player)")
                playedAny = true
            }

            // Priority 2: Try external player (for video)
            if !playedAny, let extPlayer = externalPlayer, extPlayer !== sharedAudioPlayer {
                extPlayer.play()
                print("[MediaPlaybackService] Play (external video player)")
                playedAny = true
            }

            // Priority 3: Try registered players as backup (legacy)
            if !playedAny {
                for (id, player) in registeredPlayers {
                    if player.rate == 0 && player.currentItem != nil {
                        player.play()
                        print("[MediaPlaybackService] Play (registered player \(id))")
                        playedAny = true
                        break
                    }
                }
            }

            // Fall back to notification if still nothing played
            if !playedAny {
                NotificationCenter.default.post(name: MediaPlaybackService.externalPlayNotification, object: nil)
                print("[MediaPlaybackService] Play (notification fallback)")
            }

            isPlaying = true
            playbackState = .playing
            updateNowPlayingInfo()
            onExternalPlay?()
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
        // In external playback mode, control players directly for faster response
        if externalPlaybackMode {
            var pausedAny = false

            // Priority 1: Pause shared audio player if active
            if isUsingSharedAudioPlayer, let audioPlayer = sharedAudioPlayer, audioPlayer.rate > 0 {
                audioPlayer.pause()
                print("[MediaPlaybackService] Pause (shared audio player)")
                pausedAny = true
            }

            // Priority 2: Pause external player (for video)
            if let extPlayer = externalPlayer, extPlayer !== sharedAudioPlayer, extPlayer.rate > 0 {
                extPlayer.pause()
                print("[MediaPlaybackService] Pause (external video player)")
                pausedAny = true
            }

            // Priority 3: Pause ALL registered players as backup (legacy)
            for (id, player) in registeredPlayers where player.rate > 0 {
                player.pause()
                print("[MediaPlaybackService] Pause (registered player \(id))")
                pausedAny = true
            }

            // If still no players paused, post notification as last resort
            if !pausedAny {
                NotificationCenter.default.post(name: MediaPlaybackService.externalPauseNotification, object: nil)
                print("[MediaPlaybackService] Pause (notification fallback)")
            }

            isPlaying = false
            playbackState = .paused
            updateNowPlayingInfo()
            onExternalPause?()
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
        // In external playback mode, control players directly
        if externalPlaybackMode {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            var seekedAny = false

            // Priority 1: Seek on shared audio player if active
            if isUsingSharedAudioPlayer, let audioPlayer = sharedAudioPlayer {
                audioPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                print("[MediaPlaybackService] Seek to \(time) (shared audio player)")
                seekedAny = true
            }

            // Priority 2: Seek on external player (for video)
            if let extPlayer = externalPlayer, extPlayer !== sharedAudioPlayer {
                extPlayer.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                print("[MediaPlaybackService] Seek to \(time) (external video player)")
                seekedAny = true
            }

            // Priority 3: Seek on registered players as backup (legacy)
            if !seekedAny {
                for (id, player) in registeredPlayers where player.currentItem != nil {
                    player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    print("[MediaPlaybackService] Seek to \(time) (registered player \(id))")
                    seekedAny = true
                }
            }

            // Fall back to notification if nothing seeked directly
            if !seekedAny {
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalSeekNotification,
                    object: nil,
                    userInfo: ["time": time]
                )
                print("[MediaPlaybackService] Seek to \(time) (notification fallback)")
            }

            currentTime = time
            updateNowPlayingInfo()
            onExternalSeek?(time)
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
        guard !playlist.isEmpty else {
            print("[MediaPlaybackService] nextTrack: playlist is empty")
            return
        }

        // Loop one mode: just replay current
        if loopMode == .one {
            if externalPlaybackMode {
                // Seek all registered players to beginning
                let cmTime = CMTime.zero
                for (_, player) in registeredPlayers {
                    player.seek(to: cmTime)
                }
                externalPlayer?.seek(to: cmTime)
                currentTime = 0
                updateNowPlayingInfo()

                onTrackChanged?(currentIndex)
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": currentIndex]
                )
                print("[MediaPlaybackService] Loop one: restart current track")
            } else {
                seek(to: 0)
                play()
            }
            return
        }

        // Find next playable item (respecting background mode filtering)
        if let nextIndex = findNextPlayableIndex(after: currentIndex, forward: true) {
            // Get the next media item
            let nextItem = playlist[nextIndex]
            let nextMediaItem = nextItem.mediaItem
            let isAudio = nextMediaItem.type == .audio

            currentIndex = nextIndex
            if isShuffled, let pos = shuffledIndices.firstIndex(of: nextIndex) {
                shuffledPosition = pos
            }
            onTrackChanged?(nextIndex)

            // In external mode, use shared audio player for audio, video players for video
            if externalPlaybackMode {
                // Pause current playback
                sharedAudioPlayer?.pause()
                externalPlayer?.pause()

                // Post notification for view updates (gallery will switch to this index)
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": nextIndex]
                )
                print("[MediaPlaybackService] Next track -> index \(nextIndex) (audio: \(isAudio))")

                if isAudio {
                    // Use the shared audio player - handles loading, playing, and metadata
                    Task {
                        await loadAudioInSharedPlayer(mediaItem: nextMediaItem, autoplay: true)
                    }
                } else {
                    // Video: let the gallery view handle it (needs view for display)
                    // Just notify and the view will create its player when it appears
                    print("[MediaPlaybackService] Next track is video - gallery will handle playback")
                }
            } else {
                Task {
                    await playCurrentItem()
                }
            }
        } else {
            // No more playable items
            print("[MediaPlaybackService] nextTrack: no more playable items")
            if externalPlaybackMode {
                // Just pause current
                pauseAllPlayers()
            } else {
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
        guard !playlist.isEmpty else {
            print("[MediaPlaybackService] previousTrack: playlist is empty")
            return
        }

        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
            if externalPlaybackMode {
                // Seek all registered players to beginning
                let cmTime = CMTime.zero
                for (_, player) in registeredPlayers {
                    player.seek(to: cmTime)
                }
                externalPlayer?.seek(to: cmTime)
                currentTime = 0
                updateNowPlayingInfo()

                onTrackChanged?(currentIndex)
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": currentIndex, "restart": true]
                )
                print("[MediaPlaybackService] Restart current track (>3s in)")
            } else {
                seek(to: 0)
            }
            return
        }

        // Find previous playable item (respecting background mode filtering)
        if let prevIndex = findNextPlayableIndex(after: currentIndex, forward: false) {
            // Get the prev media item
            let prevItem = playlist[prevIndex]
            let prevMediaItem = prevItem.mediaItem
            let isAudio = prevMediaItem.type == .audio

            currentIndex = prevIndex
            if isShuffled, let pos = shuffledIndices.firstIndex(of: prevIndex) {
                shuffledPosition = pos
            }
            onTrackChanged?(prevIndex)

            // In external mode, use shared audio player for audio, video players for video
            if externalPlaybackMode {
                // Pause current playback
                sharedAudioPlayer?.pause()
                externalPlayer?.pause()

                // Post notification for view updates (gallery will switch to this index)
                NotificationCenter.default.post(
                    name: MediaPlaybackService.externalTrackChangedNotification,
                    object: nil,
                    userInfo: ["index": prevIndex]
                )
                print("[MediaPlaybackService] Previous track -> index \(prevIndex) (audio: \(isAudio))")

                if isAudio {
                    // Use the shared audio player - handles loading, playing, and metadata
                    Task {
                        await loadAudioInSharedPlayer(mediaItem: prevMediaItem, autoplay: true)
                    }
                } else {
                    // Video: let the gallery view handle it (needs view for display)
                    print("[MediaPlaybackService] Previous track is video - gallery will handle playback")
                }
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

        // iOS 16+: Also set playback state for better Now Playing integration
        #if canImport(UIKit)
        if #available(iOS 16.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
        #endif
    }

    // MARK: - Shared Audio Player Management

    /// Helper to check if two media items represent the same content
    /// Uses diskCacheKey (most reliable) or sourceURL to compare, ignoring UUID
    private func isSameMediaContent(_ item1: any MediaItem, _ item2: any MediaItem) -> Bool {
        // First try diskCacheKey (most reliable - includes path and modification date)
        if let key1 = item1.diskCacheKey, let key2 = item2.diskCacheKey {
            return key1 == key2
        }
        // Fall back to sourceURL comparison
        if let url1 = item1.sourceURL, let url2 = item2.sourceURL {
            return url1.absoluteString == url2.absoluteString
        }
        // Last resort: compare by UUID (least reliable after view recreation)
        return item1.id == item2.id
    }

    /// Load and play an audio item using the shared audio player
    /// This is the primary method for audio playback - uses a single reusable player
    /// - Parameters:
    ///   - mediaItem: The media item to play
    ///   - autoplay: Whether to start playing immediately
    ///   - seekToPosition: If provided, seeks to this position after loading (for restoration)
    public func loadAudioInSharedPlayer(mediaItem: any MediaItem, autoplay: Bool = true, seekToPosition: TimeInterval? = nil) async {
        // Check if this item is already loaded in the shared player
        // Use content-based comparison (diskCacheKey/sourceURL) instead of UUID
        // because gallery recreation creates new media items with new UUIDs for the same file
        if let currentItem = currentAudioMediaItem, isSameMediaContent(currentItem, mediaItem) {
            print("[MediaPlaybackService] ♻️ Audio already in shared player (same content), skipping reload")

            // Ensure external playback mode is enabled for remote commands
            externalPlaybackMode = true

            // Handle seek position restoration if requested
            if let position = seekToPosition, position > 0 {
                let cmTime = CMTime(seconds: position, preferredTimescale: 600)
                await sharedAudioPlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = position
                print("[MediaPlaybackService] 🔄 Restored playback position to \(position)")
            }

            // Just handle autoplay state
            if autoplay && sharedAudioPlayer?.rate == 0 {
                sharedAudioPlayer?.play()
                isPlaying = true
                playbackState = .playing
            }
            updateNowPlayingInfo()
            return
        }

        // Get URL - prefer cached, fall back to source
        var audioURL: URL?

        if MediaDownloadManager.shared.isCached(mediaItem: mediaItem) {
            audioURL = MediaDownloadManager.shared.localURL(for: mediaItem)
            print("[MediaPlaybackService] Loading cached audio: \(audioURL?.lastPathComponent ?? "unknown")")
        } else if let sourceURL = mediaItem.sourceURL {
            audioURL = sourceURL
            print("[MediaPlaybackService] Loading remote audio: \(sourceURL.lastPathComponent)")
        } else if let videoURL = await mediaItem.loadVideoURL() {
            // Some audio items return URL via loadVideoURL
            audioURL = videoURL
            print("[MediaPlaybackService] Loading audio via loadVideoURL: \(videoURL.lastPathComponent)")
        }

        guard let url = audioURL else {
            print("[MediaPlaybackService] Cannot load audio - no URL available")
            return
        }

        await MainActor.run {
            #if canImport(UIKit)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif

            // Create shared player if needed
            if sharedAudioPlayer == nil {
                sharedAudioPlayer = AVPlayer()
                setupSharedAudioPlayerObservers()
                print("[MediaPlaybackService] Created shared audio player")
            }

            // Replace the current item
            let newItem = AVPlayerItem(url: url)
            sharedAudioPlayer?.replaceCurrentItem(with: newItem)
            currentAudioMediaItem = mediaItem
            isUsingSharedAudioPlayer = true
            externalPlayer = sharedAudioPlayer  // Keep compatibility
            externalPlaybackMode = true  // Enable external playback mode for remote commands

            // Setup end-of-track observer for this specific item
            setupItemEndObserver(for: newItem)

            if autoplay {
                sharedAudioPlayer?.play()
                isPlaying = true
                playbackState = .playing
            }

            print("[MediaPlaybackService] Loaded audio in shared player: \(url.lastPathComponent)")
        }

        // Seek to position if requested (for restoration) - must be outside MainActor.run for async seek
        if let position = seekToPosition, position > 0 {
            let cmTime = CMTime(seconds: position, preferredTimescale: 600)
            await sharedAudioPlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = position
            print("[MediaPlaybackService] 🔄 Set initial playback position to \(position)")
        }

        // Load and update metadata
        let metadata = await mediaItem.getAudioMetadata()
        let artwork = await mediaItem.loadImage()

        var title = metadata?.title
        if title == nil || title?.isEmpty == true {
            if let sourceURL = mediaItem.sourceURL {
                title = sourceURL.deletingPathExtension().lastPathComponent
            }
        }

        // Wait briefly for duration to be available
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        await MainActor.run {
            var mediaDuration: TimeInterval = 0
            if let item = sharedAudioPlayer?.currentItem {
                let dur = CMTimeGetSeconds(item.duration)
                if dur.isFinite && dur > 0 {
                    mediaDuration = dur
                    duration = mediaDuration
                }
            }

            updateNowPlayingForExternalPlayer(
                mediaItem: mediaItem,
                title: title,
                artist: metadata?.artist,
                album: metadata?.album,
                artwork: artwork,
                duration: mediaDuration,
                isVideo: false
            )
        }
    }

    /// Setup observers for the shared audio player (called once when player is created)
    private func setupSharedAudioPlayerObservers() {
        guard let player = sharedAudioPlayer else { return }

        // Remove existing time observer
        if let observer = sharedAudioTimeObserver {
            player.removeTimeObserver(observer)
            sharedAudioTimeObserver = nil
        }

        // Add periodic time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        sharedAudioTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self, self.isUsingSharedAudioPlayer else { return }

                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    self.currentTime = seconds
                }

                // Update duration if available
                if let item = player.currentItem {
                    let dur = CMTimeGetSeconds(item.duration)
                    if dur.isFinite && dur > 0 && self.duration != dur {
                        self.duration = dur
                    }
                }

                // Update playing state
                self.isPlaying = player.rate > 0
                self.updateNowPlayingTimeOnly()
            }
        }

        // Observe item status changes
        sharedAudioItemObserver = player.observe(\.currentItem?.status) { [weak self] observedPlayer, _ in
            guard self != nil else { return }
            if observedPlayer.currentItem?.status == .readyToPlay {
                print("[MediaPlaybackService] Shared audio player ready to play")
            }
        }
    }

    /// Setup end-of-track observer for the current player item
    /// Called each time a new item is loaded to ensure we catch completion
    private func setupItemEndObserver(for playerItem: AVPlayerItem) {
        // Remove existing end observer
        if let observer = sharedAudioEndObserver {
            NotificationCenter.default.removeObserver(observer)
            sharedAudioEndObserver = nil
        }

        // Register for this specific item's end notification
        sharedAudioEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,  // Only listen for THIS item
            queue: nil  // Use posting queue for immediate delivery (important for background)
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isUsingSharedAudioPlayer else { return }
                print("[MediaPlaybackService] 🎵 Shared audio player finished track - advancing to next")
                self.handleTrackCompletion()
            }
        }
        print("[MediaPlaybackService] Registered end observer for player item")
    }

    /// Handle when the current track finishes playing
    private func handleTrackCompletion() {
        // Check loop mode
        if loopMode == .one {
            // Loop the current track
            sharedAudioPlayer?.seek(to: .zero)
            sharedAudioPlayer?.play()
            return
        }

        // Move to next track
        nextTrack()
    }

    /// Get the shared audio player's current state
    public var sharedAudioPlayerState: (isPlaying: Bool, currentTime: TimeInterval, duration: TimeInterval) {
        guard let player = sharedAudioPlayer else {
            return (false, 0, 0)
        }
        let time = CMTimeGetSeconds(player.currentTime())
        let dur = player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? 0
        return (player.rate > 0, time.isFinite ? time : 0, dur.isFinite ? dur : 0)
    }

    // MARK: - External Player Integration (Legacy - for video players)

    /// Create and play a player on demand for background playback
    /// DEPRECATED: Use loadAudioInSharedPlayer instead
    private func createAndPlayOnDemand(mediaItem: any MediaItem) async {
        // Now just delegates to the shared player
        await loadAudioInSharedPlayer(mediaItem: mediaItem, autoplay: true)
    }

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

        // iOS 16+: Also set playback state
        #if canImport(UIKit)
        if #available(iOS 16.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
        #endif
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

        // Get title: try metadata first, then extract from URLs/cache key
        var title = metadata?.title

        if title == nil || title?.isEmpty == true {
            // Try diskCacheKey first (most reliable for remote files - contains the filename)
            if let cacheKey = item.diskCacheKey {
                // diskCacheKey is usually the filename
                let filename = URL(fileURLWithPath: cacheKey).deletingPathExtension().lastPathComponent
                if !filename.isEmpty {
                    title = filename
                }
            }

            // Try sourceURL
            if title == nil || title?.isEmpty == true, let sourceURL = item.sourceURL {
                title = sourceURL.deletingPathExtension().lastPathComponent
            }

            // Try audio URL (don't await if we already have a title)
            if title == nil || title?.isEmpty == true {
                if let audioURL = await item.loadAudioURL() {
                    title = audioURL.deletingPathExtension().lastPathComponent
                }
            }

            // Try video URL
            if title == nil || title?.isEmpty == true {
                if let videoURL = await item.loadVideoURL() {
                    title = videoURL.deletingPathExtension().lastPathComponent
                }
            }

            // Final fallback
            if title == nil || title?.isEmpty == true {
                title = "Track \(currentIndex + 1)"
            }
        }

        print("[MediaPlaybackService] Updating Now Playing: title=\(title ?? "nil"), artist=\(metadata?.artist ?? "nil"), hasArtwork=\(artwork != nil)")

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
