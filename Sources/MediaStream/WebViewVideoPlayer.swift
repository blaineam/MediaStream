//
//  WebViewVideoPlayer.swift
//  MediaStream
//
//  HTML5 video player using WKWebView - cleaner alternative to VLCKit
//  Supports WebM, MP4, and other HTML5-compatible formats
//

import Foundation
import SwiftUI
import WebKit
import Combine

#if canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#endif

// MARK: - Shared Interaction State

/// Tracks when controls are being interacted with to block navigation gestures
public class MediaControlsInteractionState: ObservableObject {
    public static let shared = MediaControlsInteractionState()
    @Published public var isInteracting: Bool = false
}

// MARK: - Gesture Blocking Helper

#if canImport(UIKit)
/// A view modifier that blocks parent gesture recognizers from receiving touches
struct GestureBlockingModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(GestureBlocker())
    }
}

/// Invisible UIView that blocks gesture propagation to parent views
private struct GestureBlocker: UIViewRepresentable {
    func makeUIView(context: Context) -> GestureBlockerView {
        let view = GestureBlockerView()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: GestureBlockerView, context: Context) {}
}

private class GestureBlockerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGesture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGesture()
    }

    private func setupGesture() {
        let pan = UIPanGestureRecognizer(target: nil, action: nil)
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        addGestureRecognizer(pan)
    }
}

extension GestureBlockerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

extension View {
    func blockParentGestures() -> some View {
        modifier(GestureBlockingModifier())
    }
}
#else
extension View {
    func blockParentGestures() -> some View {
        self
    }
}
#endif

// MARK: - WebView Thumbnail Generation Queue

/// Limits concurrent WKWebView thumbnail generations to prevent resource starvation
/// WKWebViews are heavy - each creates a WebContent process, so we limit to 1 at a time
actor WebViewThumbnailQueue {
    static let shared = WebViewThumbnailQueue()

    private var activeCount = 0
    private let maxConcurrent = 1  // Only 1 WKWebView generating thumbnails at a time to prevent resource starvation
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var operationId = 0

    func acquire() async {
        operationId += 1
        let myId = operationId

        if activeCount < maxConcurrent {
            activeCount += 1
            print("WebViewThumbnailQueue: Acquired slot #\(myId) (active: \(activeCount)/\(maxConcurrent))")
            return
        }

        print("WebViewThumbnailQueue: Waiting in queue #\(myId) (active: \(activeCount)/\(maxConcurrent), waiters: \(waiters.count))")
        // Wait in queue
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        print("WebViewThumbnailQueue: Acquired after waiting #\(myId)")
    }

    func release() {
        activeCount -= 1
        print("WebViewThumbnailQueue: Released slot (active: \(activeCount)/\(maxConcurrent), waiters: \(waiters.count))")

        // Wake up next waiter if any
        if !waiters.isEmpty && activeCount < maxConcurrent {
            activeCount += 1
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }

    /// Execute a closure with queue limiting - properly awaits release
    func withLimit<T>(_ operation: () async -> T) async -> T {
        await acquire()
        let result = await operation()
        await release()
        return result
    }
}

// MARK: - Custom URL Scheme Handler for Video Player

/// Handles custom scheme requests to serve video player HTML
/// This gives us a proper web origin context for cross-origin video playback
class VideoPlayerSchemeHandler: NSObject, WKURLSchemeHandler {
    var videoHTML: String = ""

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "VideoPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        if url.path == "/player.html" || url.path.isEmpty || url.path == "/" {
            guard let data = videoHTML.data(using: .utf8) else {
                urlSchemeTask.didFailWithError(NSError(domain: "VideoPlayer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode HTML"]))
                return
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "*"
                ]
            )!

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } else {
            urlSchemeTask.didFailWithError(NSError(domain: "VideoPlayer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unknown path: \(url.path)"]))
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to clean up
    }
}

// MARK: - WebView Video Controller

/// Observable controller for HTML5 video playback via WKWebView
/// Mirrors VLCPlayerController interface for drop-in replacement
@MainActor
public class WebViewVideoController: NSObject, ObservableObject {
    @Published public var isPlaying: Bool = false
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var isReady: Bool = false
    @Published public var hasAudio: Bool = true
    @Published public var didReachEnd: Bool = false
    @Published public var isBuffering: Bool = false

    /// Callback when video playback ends
    public var onVideoEnd: (() -> Void)?

    /// The WKWebView instance
    private(set) var webView: WKWebView?

    /// Timer for polling playback state
    private var stateTimer: Timer?

    /// Current video URL
    private var currentURL: URL?

    /// HTTP headers for authenticated requests
    private var httpHeaders: [String: String]?

    /// Volume level (0.0 - 1.0)
    private var volumeLevel: Float = 1.0

    /// Muted state
    private var isMutedState: Bool = false

    /// Flag for showing first frame mode
    private var isShowingFirstFrame = false

    /// Custom URL scheme handler for remote videos
    private var schemeHandler: VideoPlayerSchemeHandler?

    /// Flag indicating user needs to tap video to enable audio (iOS autoplay restriction)
    @Published public var needsUserGestureForAudio: Bool = false

    /// Background color for the player (matches parent view)
    public var backgroundColor: PlatformColor = .black {
        didSet {
            updateBackgroundColor()
        }
    }

    public override init() {
        super.init()
    }

    /// Update the webview background color
    private func updateBackgroundColor() {
        #if canImport(UIKit)
        webView?.backgroundColor = backgroundColor
        webView?.scrollView.backgroundColor = backgroundColor
        #endif

        // Also update the HTML body background via JS
        let hexColor = backgroundColor.hexString
        webView?.evaluateJavaScript("document.body.style.background = '\(hexColor)'; document.querySelector('video').style.background = '\(hexColor)';")
    }

    deinit {
        stateTimer?.invalidate()
    }

    /// Creates and configures the WKWebView
    func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()

        // Register custom scheme handler for remote videos
        // This gives us a proper web origin that can play cross-origin videos
        let handler = VideoPlayerSchemeHandler()
        self.schemeHandler = handler
        config.setURLSchemeHandler(handler, forURLScheme: "video-player")

        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        #endif

        config.mediaTypesRequiringUserActionForPlayback = []

        let contentController = WKUserContentController()

        // Add message handlers for JS -> Swift communication
        contentController.add(self, name: "videoState")
        contentController.add(self, name: "videoEnded")
        contentController.add(self, name: "videoReady")
        contentController.add(self, name: "videoError")
        contentController.add(self, name: "consoleLog")

        // Inject console.log capture (capture all arguments, not just first)
        let consoleScript = WKUserScript(
            source: "window.console.log = function(...args) { window.webkit.messageHandlers.consoleLog.postMessage(args.map(a => String(a)).join(' ')); };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(consoleScript)

        config.userContentController = contentController

        // Try to allow cross-origin access for video loading
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)

        // Try to disable CORS restrictions (may not work on all iOS versions)
        if webView.responds(to: Selector(("_allowUniversalAccessFromFileURLs"))) {
            webView.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }

        #if canImport(UIKit)
        // Match system appearance
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #elseif canImport(AppKit)
        webView.setValue(false, forKey: "drawsBackground")
        // macOS-specific CORS bypass attempt
        if let prefs = webView.configuration.preferences.value(forKey: "developerExtrasEnabled") {
            // Enable dev tools for debugging if needed
        }
        #endif

        webView.navigationDelegate = self

        // Enable Web Inspector for debugging (Safari > Develop menu)
        #if DEBUG
        if #available(iOS 16.4, macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        self.webView = webView
        return webView
    }

    /// Load video from URL with optional HTTP headers
    public func load(url: URL, headers: [String: String]? = nil) {
        currentURL = url
        httpHeaders = headers
        didReachEnd = false
        isReady = false

        guard let webView = webView else {
            print("WebViewVideoPlayer: No webView available")
            return
        }

        if url.isFileURL {
            // For local files, we need to create an HTML file and load it with file access
            loadLocalVideo(url: url, webView: webView)
        } else {
            // For remote URLs, use custom URL scheme handler
            // This provides a proper web origin context that can play cross-origin videos
            // Using loadHTMLString with baseURL doesn't give proper origin for media playback
            loadRemoteVideo(url: url, headers: headers, webView: webView)
        }

        startStatePolling()
    }

    /// Load a local video file with proper file access permissions
    private func loadLocalVideo(url: URL, webView: WKWebView) {
        // Create temp HTML file in the SAME directory as the video so we can grant access to one directory
        let videoDirectory = url.deletingLastPathComponent()
        let htmlFile = videoDirectory.appendingPathComponent(".video_player_\(UUID().uuidString).html")

        // Use relative path since HTML is in same directory as video
        let html = buildVideoHTML(videoURL: url, headers: nil, useRelativePath: true)

        do {
            try html.write(to: htmlFile, atomically: true, encoding: .utf8)

            // Load the HTML file with access to the video's directory (which now contains both)
            webView.loadFileURL(htmlFile, allowingReadAccessTo: videoDirectory)

            print("WebViewVideoPlayer: Loading local video from \(url.lastPathComponent) (relative path)")

            // Clean up temp file after a delay
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds to ensure video loads
                try? FileManager.default.removeItem(at: htmlFile)
            }
        } catch {
            print("WebViewVideoPlayer: Failed to write HTML to video directory, trying temp: \(error)")
            // Fallback: try temp directory with broader access
            loadLocalVideoFallback(url: url, webView: webView)
        }
    }

    /// Fallback for when we can't write to the video's directory
    private func loadLocalVideoFallback(url: URL, webView: WKWebView) {
        let tempDir = FileManager.default.temporaryDirectory
        let htmlFile = tempDir.appendingPathComponent("video_player_\(UUID().uuidString).html")

        // For the fallback, use absolute file:// URL since HTML is in different directory
        let html = buildVideoHTML(videoURL: url, headers: nil, useRelativePath: false)

        do {
            try html.write(to: htmlFile, atomically: true, encoding: .utf8)

            // Grant access to root to allow reading both the HTML and video
            let rootAccess = URL(fileURLWithPath: "/")
            webView.loadFileURL(htmlFile, allowingReadAccessTo: rootAccess)

            print("WebViewVideoPlayer: Loading local video (fallback) from \(url.lastPathComponent)")

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                try? FileManager.default.removeItem(at: htmlFile)
            }
        } catch {
            print("WebViewVideoPlayer: Failed to create temp HTML: \(error)")
        }
    }

    /// Load a remote video - uses direct URL in HTML5 video element
    private func loadRemoteVideo(url: URL, headers: [String: String]?, webView: WKWebView) {
        // Build HTML with direct video URL
        let html = buildVideoHTML(videoURL: url, headers: headers, useRelativePath: false)

        // Load HTML with the video's base URL so they share the same origin
        // This avoids CORS issues that would taint the canvas and prevent thumbnail capture
        let baseURL = url.deletingLastPathComponent()
        print("WebViewVideoPlayer: Loading remote video \(url.lastPathComponent) with baseURL \(baseURL)")
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// Build minimal HTML for video playback
    private func buildVideoHTML(videoURL: URL, headers: [String: String]?, useRelativePath: Bool = false) -> String {
        // For local files loaded via loadFileURL, use relative path (just filename)
        // For remote URLs, use the full URL
        let videoURLString: String

        if useRelativePath {
            // URL encode the filename for safety
            videoURLString = videoURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoURL.lastPathComponent
        } else {
            videoURLString = videoURL.absoluteString
        }

        // Determine MIME type based on extension
        let ext = videoURL.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "webm": mimeType = "video/webm"
        case "mp4", "m4v": mimeType = "video/mp4"
        case "mov": mimeType = "video/quicktime"
        case "mkv": mimeType = "video/x-matroska"
        default: mimeType = "video/mp4"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body {
                    width: 100%;
                    height: 100%;
                    background: #000;
                    overflow: hidden;
                    -webkit-user-select: none;
                    user-select: none;
                }
                video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: #000;
                }
                video::-webkit-media-controls { display: none !important; }
                video::-webkit-media-controls-enclosure { display: none !important; }
                video::-webkit-media-controls-panel { display: none !important; }
            </style>
        </head>
        <body>
            <video id="player" playsinline preload="auto" muted src="\(videoURLString)" type="\(mimeType)"></video>
            <script>
                const video = document.getElementById('player');
                let hasNotifiedReady = false;

                console.log('Video player init, src:', video.src);

                // Check codec support
                const canPlayWebmVP9 = video.canPlayType('video/webm; codecs="vp9"');
                const canPlayWebmVP8 = video.canPlayType('video/webm; codecs="vp8"');
                const canPlayMP4 = video.canPlayType('video/mp4; codecs="avc1.42E01E"');
                console.log('Codec support - VP9:', canPlayWebmVP9, 'VP8:', canPlayWebmVP8, 'H264:', canPlayMP4);

                function notifyReady() {
                    if (hasNotifiedReady) return;
                    if (video.duration > 0) {
                        hasNotifiedReady = true;
                        console.log('Video ready - dimensions: ' + video.videoWidth + 'x' + video.videoHeight + ', duration: ' + video.duration);
                        window.webkit.messageHandlers.videoReady.postMessage({
                            duration: video.duration,
                            hasAudio: true
                        });
                    }
                }

                video.addEventListener('loadedmetadata', notifyReady);
                video.addEventListener('canplay', notifyReady);
                video.addEventListener('loadeddata', () => {
                    notifyReady();
                    // Seek to show first frame as preview (iOS needs this for proper thumbnail display)
                    if (video.currentTime === 0 && video.paused) {
                        video.currentTime = 0.1;
                        console.log('Seeking to 0.1s for first frame preview');
                    }
                });

                video.addEventListener('ended', () => {
                    window.webkit.messageHandlers.videoEnded.postMessage({});
                });

                video.addEventListener('error', (e) => {
                    const msg = video.error ? (video.error.message || 'Code: ' + video.error.code) : 'Unknown';
                    console.log('Video error:', msg);
                    window.webkit.messageHandlers.videoError.postMessage({ error: msg });
                });

                // Debug events for playback issues
                video.addEventListener('stalled', () => console.log('Video STALLED - network issues'));
                video.addEventListener('waiting', () => console.log('Video WAITING - buffering'));
                video.addEventListener('suspend', () => console.log('Video SUSPEND - download suspended'));
                video.addEventListener('playing', () => console.log('Video PLAYING event fired, currentTime: ' + video.currentTime));
                video.addEventListener('timeupdate', () => {
                    if (video.currentTime > 0 && video.currentTime < 0.5) {
                        console.log('Video timeupdate: ' + video.currentTime);
                    }
                });

                // Track if user has interacted with audio (required for iOS unmute)
                var hasUserAudioGesture = false;
                var pendingUnmute = false;
                var pendingVolume = 1.0;

                // Click on video enables audio (establishes user gesture context)
                video.addEventListener('click', (e) => {
                    console.log('Video CLICKED - enabling audio context');
                    const wasWaitingForGesture = !hasUserAudioGesture;
                    hasUserAudioGesture = true;
                    // Apply any pending unmute
                    if (pendingUnmute) {
                        video.muted = false;
                        video.volume = pendingVolume;
                        console.log('Applied pending unmute, volume:', pendingVolume, 'muted now:', video.muted);
                        pendingUnmute = false;
                        // Notify Swift that audio is now enabled
                        window.webkit.messageHandlers.videoState.postMessage({ audioEnabled: true });
                    }
                    // Toggle play/pause on click (only if we weren't just enabling audio)
                    if (!wasWaitingForGesture || !pendingUnmute) {
                        if (video.paused) {
                            video.play();
                        } else {
                            video.pause();
                        }
                    }
                });

                // Also enable on touchstart for iOS
                video.addEventListener('touchstart', (e) => {
                    if (!hasUserAudioGesture) {
                        console.log('Video TOUCHED - enabling audio context');
                        hasUserAudioGesture = true;
                        if (pendingUnmute) {
                            video.muted = false;
                            video.volume = pendingVolume;
                            console.log('Applied pending unmute on touch, volume:', pendingVolume, 'muted now:', video.muted);
                            pendingUnmute = false;
                            // Notify Swift that audio is now enabled
                            window.webkit.messageHandlers.videoState.postMessage({ audioEnabled: true });
                        }
                    }
                }, { passive: true });

                // Exposed functions for Swift to call
                window.videoPlay = () => {
                    console.log('videoPlay called, paused: ' + video.paused + ', readyState: ' + video.readyState + ', muted: ' + video.muted);

                    // Don't touch muted state - let SwiftUI controls handle it
                    // iOS kills playback if we unmute programmatically without user gesture
                    video.play().then(() => {
                        console.log('Play started successfully, currentTime: ' + video.currentTime);
                        window.webkit.messageHandlers.videoState.postMessage({ playing: true, currentTime: video.currentTime });
                    }).catch(e => {
                        console.log('Play failed: ' + e.name + ' - ' + e.message);
                        window.webkit.messageHandlers.videoError.postMessage({ error: 'Play failed: ' + e.message });
                    });
                };
                window.videoPause = () => {
                    console.log('videoPause called, paused:', video.paused);
                    video.pause();
                    console.log('Video now paused:', video.paused);
                };
                window.videoSeek = (time) => { video.currentTime = time; };
                window.videoSetVolume = (vol) => {
                    console.log('Setting volume to:', vol, 'hasUserGesture:', hasUserAudioGesture);
                    pendingVolume = Math.max(0, Math.min(1, vol));
                    video.volume = pendingVolume;
                    console.log('Volume after set:', video.volume, 'muted:', video.muted);
                };
                window.videoSetMuted = (muted) => {
                    console.log('Setting muted to:', muted, 'was:', video.muted, 'hasUserGesture:', hasUserAudioGesture);
                    if (!muted && !hasUserAudioGesture) {
                        // Queue the unmute for when user taps the video
                        console.log('Queuing unmute - waiting for user gesture (tap video to enable audio)');
                        pendingUnmute = true;
                        window.webkit.messageHandlers.videoState.postMessage({ needsUserGesture: true });
                    } else {
                        video.muted = muted;
                        console.log('Muted after set:', video.muted);
                        // If iOS silently ignored unmute, report it
                        if (!muted && video.muted) {
                            console.log('WARNING: iOS rejected unmute request');
                            pendingUnmute = true;
                            window.webkit.messageHandlers.videoState.postMessage({ needsUserGesture: true });
                        }
                    }
                };
                window.videoGetState = () => ({
                    currentTime: video.currentTime,
                    duration: video.duration || 0,
                    paused: video.paused,
                    ended: video.ended,
                    buffered: video.buffered.length > 0 ? video.buffered.end(video.buffered.length - 1) : 0
                });

                // Snapshot for thumbnail
                window.videoSnapshot = (width, height) => {
                    const canvas = document.createElement('canvas');
                    canvas.width = width || video.videoWidth || 320;
                    canvas.height = height || video.videoHeight || 240;
                    const ctx = canvas.getContext('2d');
                    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
                    return canvas.toDataURL('image/jpeg', 0.8);
                };
            </script>
        </body>
        </html>
        """
    }

    /// Start polling for playback state
    private func startStatePolling() {
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPlaybackState()
            }
        }
    }

    /// Poll the video element for current state
    private func pollPlaybackState() {
        guard let webView = webView, isReady else { return }

        webView.evaluateJavaScript("window.videoGetState()") { [weak self] result, error in
            guard let self = self, let dict = result as? [String: Any] else { return }

            Task { @MainActor in
                if let currentTime = dict["currentTime"] as? Double {
                    self.currentTime = currentTime
                }
                if let duration = dict["duration"] as? Double, duration > 0 {
                    self.duration = duration
                }
                if let paused = dict["paused"] as? Bool {
                    self.isPlaying = !paused
                }
                if let ended = dict["ended"] as? Bool {
                    self.didReachEnd = ended
                }
            }
        }
    }

    // MARK: - Playback Control (mirrors VLCPlayerController interface)

    public func play() {
        guard let webView = webView else {
            print("WebViewVideoPlayer: No webView for play()")
            return
        }
        webView.evaluateJavaScript("window.videoPlay()") { result, error in
            if let error = error {
                print("WebViewVideoPlayer: play() error - \(error.localizedDescription)")
            } else {
                print("WebViewVideoPlayer: play() called")
            }
        }
        isPlaying = true
        didReachEnd = false
    }

    public func pause() {
        guard let webView = webView else {
            print("WebViewVideoPlayer: No webView for pause()")
            return
        }
        webView.evaluateJavaScript("window.videoPause()") { result, error in
            if let error = error {
                print("WebViewVideoPlayer: pause() error - \(error.localizedDescription)")
            } else {
                print("WebViewVideoPlayer: pause() called")
            }
        }
        isPlaying = false
    }

    public func stop() {
        pause()
        seek(to: 0)
    }

    public func reset() {
        stateTimer?.invalidate()
        stateTimer = nil
        webView?.stopLoading()
        isPlaying = false
        currentTime = 0
        duration = 0
        isReady = false
        didReachEnd = false
        currentURL = nil
    }

    /// Fully destroys the webView to release memory (use for thumbnail generation cleanup)
    public func destroy() {
        reset()
        // Remove message handlers to break retain cycles
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.navigationDelegate = nil
        // Load blank page to release video resources
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
        schemeHandler = nil
        print("WebViewVideoPlayer: Destroyed controller and released memory")
    }

    public func seek(to time: Double) {
        webView?.evaluateJavaScript("window.videoSeek(\(time))")
        currentTime = time
        didReachEnd = false
    }

    public func seekToBeginning() {
        seek(to: 0)
    }

    public func setVolume(_ volume: Float) {
        volumeLevel = volume
        webView?.evaluateJavaScript("window.videoSetVolume(\(volume))")
    }

    public func setMuted(_ muted: Bool) {
        isMutedState = muted
        webView?.evaluateJavaScript("window.videoSetMuted(\(muted ? "true" : "false"))")
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            if didReachEnd {
                seekToBeginning()
                didReachEnd = false
            }
            play()
        }
    }

    /// Show first frame without playing (for preview)
    public func showFirstFrame() {
        guard isReady else { return }
        isShowingFirstFrame = true

        // Mute, play briefly, then pause to render first frame
        webView?.evaluateJavaScript("""
            const v = document.getElementById('player');
            v.muted = true;
            v.play().then(() => {
                setTimeout(() => {
                    v.pause();
                    v.currentTime = 0;
                    v.muted = \(isMutedState ? "true" : "false");
                }, 100);
            });
        """)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isShowingFirstFrame = false
            self?.isPlaying = false
        }
    }

    /// Cancel first frame mode
    public func cancelFirstFrameMode() {
        isShowingFirstFrame = false
    }

    // MARK: - Thumbnail Generation

    /// Generate a thumbnail from the current video frame using JavaScript canvas
    /// This captures the frame directly in the WebView without needing view hierarchy tricks
    public func generateThumbnail(size: CGSize) async -> PlatformImage? {
        guard let webView = webView, isReady else {
            print("WebViewVideoPlayer: generateThumbnail failed - webView=\(webView != nil), isReady=\(isReady)")
            return nil
        }

        print("WebViewVideoPlayer: Generating thumbnail via JS canvas, target size: \(size)")

        // Use JavaScript to capture the video frame to a canvas and return as base64
        let captureJS = """
            (function() {
                const v = document.getElementById('player');
                if (!v) {
                    console.log('Thumbnail capture: No video element');
                    return { error: 'no_element' };
                }
                if (v.readyState < 2) {
                    console.log('Thumbnail capture: Video not ready, readyState=' + v.readyState);
                    return { error: 'not_ready', readyState: v.readyState };
                }

                // Check if VP9 is supported (it often isn't in WKWebView)
                const vp9Support = v.canPlayType('video/webm; codecs="vp9"');
                const vp8Support = v.canPlayType('video/webm; codecs="vp8"');
                console.log('Thumbnail capture: VP9=' + vp9Support + ', VP8=' + vp8Support + ', dims=' + v.videoWidth + 'x' + v.videoHeight);

                const canvas = document.createElement('canvas');
                const targetWidth = \(Int(size.width));
                const aspectRatio = v.videoWidth / v.videoHeight;

                canvas.width = targetWidth;
                canvas.height = Math.round(targetWidth / aspectRatio);

                const ctx = canvas.getContext('2d');
                ctx.drawImage(v, 0, 0, canvas.width, canvas.height);

                // Check if the canvas has any non-transparent pixels (VP9 might draw black)
                try {
                    const imageData = ctx.getImageData(0, 0, Math.min(10, canvas.width), Math.min(10, canvas.height));
                    let hasContent = false;
                    for (let i = 0; i < imageData.data.length; i += 4) {
                        if (imageData.data[i] > 0 || imageData.data[i+1] > 0 || imageData.data[i+2] > 0) {
                            hasContent = true;
                            break;
                        }
                    }
                    console.log('Thumbnail capture: Canvas has content=' + hasContent);
                } catch(e) {
                    console.log('Thumbnail capture: getImageData failed (CORS?):', e.message);
                }

                try {
                    // Return as JPEG base64 (smaller than PNG)
                    const dataURL = canvas.toDataURL('image/jpeg', 0.85);
                    console.log('Thumbnail capture: dataURL length=' + dataURL.length);
                    return dataURL;
                } catch(e) {
                    console.log('Canvas toDataURL failed:', e.message);
                    return { error: 'toDataURL_failed', message: e.message };
                }
            })()
        """

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(captureJS) { result, error in
                if let error = error {
                    print("WebViewVideoPlayer: JS thumbnail error - \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                // Check for error object
                if let errorDict = result as? [String: Any], let errorType = errorDict["error"] as? String {
                    print("WebViewVideoPlayer: JS thumbnail error: \(errorType) - \(errorDict)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let dataURL = result as? String,
                      dataURL.hasPrefix("data:image/jpeg;base64,") else {
                    let resultType = type(of: result as Any)
                    let preview = (result as? String)?.prefix(100) ?? "nil"
                    print("WebViewVideoPlayer: JS thumbnail returned invalid data - type: \(resultType), preview: \(preview)")
                    continuation.resume(returning: nil)
                    return
                }

                // Extract base64 data and decode to image
                let base64String = String(dataURL.dropFirst("data:image/jpeg;base64,".count))
                guard let imageData = Data(base64Encoded: base64String) else {
                    print("WebViewVideoPlayer: Failed to decode base64 image data")
                    continuation.resume(returning: nil)
                    return
                }

                #if canImport(UIKit)
                if let image = UIImage(data: imageData) {
                    print("WebViewVideoPlayer: JS thumbnail ✓ - \(image.size)")
                    continuation.resume(returning: image)
                } else {
                    print("WebViewVideoPlayer: Failed to create UIImage from data")
                    continuation.resume(returning: nil)
                }
                #elseif canImport(AppKit)
                if let image = NSImage(data: imageData) {
                    print("WebViewVideoPlayer: JS thumbnail ✓ - \(image.size)")
                    continuation.resume(returning: image)
                } else {
                    print("WebViewVideoPlayer: Failed to create NSImage from data")
                    continuation.resume(returning: nil)
                }
                #endif
            }
        }
    }

    // MARK: - Static Metadata Methods

    /// Get video duration from URL (static method for use without player instance)
    public static func getVideoDuration(from url: URL, headers: [String: String]? = nil) async -> TimeInterval? {
        print("WebViewVideoPlayer: Getting duration for \(url.lastPathComponent)")
        let controller = await MainActor.run { WebViewVideoController() }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let webView = controller.createWebView()

                #if canImport(UIKit)
                // Need to add to view hierarchy temporarily
                let window = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
                webView.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
                window?.addSubview(webView)
                #endif

                controller.load(url: url, headers: headers)

                // Wait for video to be ready
                var attempts = 0
                while !controller.isReady && attempts < 50 { // 5 seconds max
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    attempts += 1
                }

                #if canImport(UIKit)
                webView.removeFromSuperview()
                #endif

                let duration = controller.duration > 0 ? controller.duration : nil
                print("WebViewVideoPlayer: Duration for \(url.lastPathComponent): \(duration ?? -1)s (ready: \(controller.isReady), attempts: \(attempts))")
                continuation.resume(returning: duration)
            }
        }
    }

    /// Check if video has audio track (static method)
    public static func hasAudioTrack(url: URL, headers: [String: String]? = nil) async -> Bool {
        let controller = await MainActor.run { WebViewVideoController() }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let webView = controller.createWebView()

                #if canImport(UIKit)
                let window = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
                webView.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
                window?.addSubview(webView)
                #endif

                controller.load(url: url, headers: headers)

                // Wait for video to be ready
                var attempts = 0
                while !controller.isReady && attempts < 30 { // 3 seconds max
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    attempts += 1
                }

                #if canImport(UIKit)
                webView.removeFromSuperview()
                #endif

                // Use JavaScript to check for audio tracks
                let hasAudio = await withCheckedContinuation { (audioCont: CheckedContinuation<Bool, Never>) in
                    webView.evaluateJavaScript("""
                        (function() {
                            const v = document.getElementById('player');
                            // Check various ways to detect audio
                            if (v.mozHasAudio !== undefined) return v.mozHasAudio;
                            if (v.webkitAudioDecodedByteCount !== undefined) return v.webkitAudioDecodedByteCount > 0;
                            if (v.audioTracks !== undefined) return v.audioTracks.length > 0;
                            // Fallback: assume it has audio if we can't detect
                            return true;
                        })()
                    """) { result, _ in
                        audioCont.resume(returning: (result as? Bool) ?? true)
                    }
                }

                continuation.resume(returning: hasAudio)
            }
        }
    }

    /// Static thumbnail generation from URL
    /// Uses WebViewThumbnailQueue to limit concurrent WKWebView instances (max 2)
    public static func generateThumbnail(from url: URL, targetSize: CGFloat, headers: [String: String]? = nil) async -> PlatformImage? {
        // Use queue to limit concurrent WebView thumbnail generations
        // WKWebViews are very resource intensive - too many in parallel causes starvation
        return await WebViewThumbnailQueue.shared.withLimit {
            await generateThumbnailInternal(from: url, targetSize: targetSize, headers: headers)
        }
    }

    /// Internal thumbnail generation (called with queue limiting)
    /// Uses JS canvas capture with Swift-side polling (avoids JS async/await Promise issues)
    private static func generateThumbnailInternal(from url: URL, targetSize: CGFloat, headers: [String: String]?) async -> PlatformImage? {
        // Create a temporary controller to generate thumbnail
        let controller = await MainActor.run { WebViewVideoController() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<PlatformImage?, Never>) in
            Task { @MainActor in
                let webView = controller.createWebView()

                print("WebViewVideoPlayer: Starting thumbnail generation for \(url.lastPathComponent)")

                // WKWebView needs to be in view hierarchy for proper loading on iOS
                #if canImport(UIKit)
                // Create minimal offscreen window - needed for WKWebView to process loads
                let windowScene = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first

                let thumbnailWindow: UIWindow
                if let scene = windowScene {
                    thumbnailWindow = UIWindow(windowScene: scene)
                } else {
                    thumbnailWindow = UIWindow(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
                }
                thumbnailWindow.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
                thumbnailWindow.isHidden = false
                thumbnailWindow.rootViewController = UIViewController()
                thumbnailWindow.rootViewController?.view.addSubview(webView)
                webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                #endif

                controller.load(url: url, headers: headers)

                // Wait for video to be ready using controller's isReady flag
                // (set by videoReady message handler when loadeddata event fires)
                var attempts = 0
                let maxAttempts = 100  // 10 seconds at 100ms intervals

                while !controller.isReady && attempts < maxAttempts {
                    attempts += 1
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                }

                guard controller.isReady else {
                    print("WebViewVideoPlayer: Video not ready after \(attempts) attempts for \(url.lastPathComponent)")
                    #if canImport(UIKit)
                    webView.removeFromSuperview()
                    thumbnailWindow.isHidden = true
                    thumbnailWindow.rootViewController = nil
                    #endif
                    controller.destroy()
                    continuation.resume(returning: nil)
                    return
                }

                print("WebViewVideoPlayer: Video ready after \(attempts) attempts for \(url.lastPathComponent)")

                // Atomic check-and-capture: poll until we get a valid thumbnail
                // This avoids the race where readyState drops between check and capture
                let atomicCaptureJS = """
                    (function() {
                        const v = document.getElementById('player');
                        if (!v) return { error: 'no_element' };
                        if (v.readyState < 2) return { error: 'not_ready', readyState: v.readyState };

                        const targetWidth = \(Int(targetSize));
                        const canvas = document.createElement('canvas');
                        const aspectRatio = v.videoWidth / v.videoHeight;
                        canvas.width = targetWidth;
                        canvas.height = Math.round(targetWidth / aspectRatio);

                        const ctx = canvas.getContext('2d');
                        ctx.drawImage(v, 0, 0, canvas.width, canvas.height);

                        // Check if canvas has actual content (not all black)
                        try {
                            const sample = ctx.getImageData(canvas.width/2, canvas.height/2, 1, 1);
                            const hasContent = sample.data[0] > 0 || sample.data[1] > 0 || sample.data[2] > 0;
                            if (!hasContent) {
                                // Try a different spot
                                const sample2 = ctx.getImageData(10, 10, 1, 1);
                                const hasContent2 = sample2.data[0] > 0 || sample2.data[1] > 0 || sample2.data[2] > 0;
                                if (!hasContent2) {
                                    return { error: 'black_frame', readyState: v.readyState };
                                }
                            }
                        } catch(e) { /* ignore getImageData errors */ }

                        try {
                            const dataURL = canvas.toDataURL('image/jpeg', 0.85);
                            return { success: true, dataURL: dataURL, width: canvas.width, height: canvas.height };
                        } catch(e) {
                            return { error: 'toDataURL_failed', message: e.message };
                        }
                    })()
                """

                // Force video to buffer and render frames
                // For network videos, seek to 0 first (should be already buffered)
                // Then play() to trigger frame decode
                let playJS = """
                    (function() {
                        const v = document.getElementById('player');
                        if (!v) return { status: 'no_element' };
                        v.muted = true;
                        // Seek to 0.1s (first frames should already be buffered)
                        if (v.currentTime === 0 || v.currentTime > 1) {
                            v.currentTime = 0.1;
                        }
                        v.play().then(() => {
                            console.log('Play started for thumbnail, readyState=' + v.readyState);
                        }).catch(e => {
                            console.log('Play failed for thumbnail: ' + e.message);
                        });
                        return { status: 'ok', readyState: v.readyState, currentTime: v.currentTime };
                    })()
                """

                var thumbnail: PlatformImage? = nil
                var captureAttempts = 0
                let maxCaptureAttempts = 50  // 5 seconds at 100ms intervals

                while thumbnail == nil && captureAttempts < maxCaptureAttempts {
                    captureAttempts += 1

                    // Try to play every 10 attempts to force frame buffering
                    if captureAttempts == 1 || captureAttempts % 10 == 0 {
                        let playResult = await withCheckedContinuation { (playCont: CheckedContinuation<[String: Any]?, Never>) in
                            webView.evaluateJavaScript(playJS) { result, error in
                                playCont.resume(returning: result as? [String: Any])
                            }
                        }
                        if let playResult = playResult, captureAttempts == 1 {
                            print("WebViewVideoPlayer: Play attempt for \(url.lastPathComponent): \(playResult)")
                        }
                        try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms after play to let frames decode
                    }

                    let result = await withCheckedContinuation { (captureCont: CheckedContinuation<[String: Any]?, Never>) in
                        webView.evaluateJavaScript(atomicCaptureJS) { result, error in
                            captureCont.resume(returning: result as? [String: Any])
                        }
                    }

                    if let result = result {
                        if let success = result["success"] as? Bool, success,
                           let dataURL = result["dataURL"] as? String,
                           dataURL.hasPrefix("data:image/jpeg;base64,") {
                            // Successfully captured!
                            let base64String = String(dataURL.dropFirst("data:image/jpeg;base64,".count))
                            if let imageData = Data(base64Encoded: base64String) {
                                #if canImport(UIKit)
                                thumbnail = UIImage(data: imageData)
                                #elseif canImport(AppKit)
                                thumbnail = NSImage(data: imageData)
                                #endif
                                if thumbnail != nil {
                                    print("WebViewVideoPlayer: Thumbnail captured on attempt \(captureAttempts) for \(url.lastPathComponent)")
                                }
                            }
                        } else if let error = result["error"] as? String {
                            // Log every 10 attempts
                            if captureAttempts % 10 == 0 {
                                let readyState = result["readyState"] ?? "?"
                                print("WebViewVideoPlayer: Capture attempt \(captureAttempts): \(error), readyState=\(readyState)")
                            }
                        }
                    }

                    if thumbnail == nil {
                        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                    }
                }

                guard let thumb = thumbnail else {
                    print("WebViewVideoPlayer: Failed to capture after \(captureAttempts) attempts for \(url.lastPathComponent)")
                    #if canImport(UIKit)
                    webView.removeFromSuperview()
                    thumbnailWindow.isHidden = true
                    thumbnailWindow.rootViewController = nil
                    #endif
                    controller.destroy()
                    continuation.resume(returning: nil)
                    return
                }

                print("WebViewVideoPlayer: Thumbnail ✓ for \(url.lastPathComponent) - size: \(thumb.size)")

                // Cleanup
                #if canImport(UIKit)
                webView.removeFromSuperview()
                thumbnailWindow.isHidden = true
                thumbnailWindow.rootViewController = nil
                #endif
                controller.destroy()

                continuation.resume(returning: thumb)
            }
        }
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewVideoController: WKScriptMessageHandler {
    nonisolated public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            switch message.name {
            case "videoReady":
                if let body = message.body as? [String: Any] {
                    if let dur = body["duration"] as? Double, dur > 0 {
                        self.duration = dur
                    }
                    if let audio = body["hasAudio"] as? Bool {
                        self.hasAudio = audio
                    }
                }
                self.isReady = true
                print("WebViewVideoPlayer: Video ready! Duration: \(self.duration)s")

            case "videoEnded":
                self.didReachEnd = true
                self.isPlaying = false
                self.onVideoEnd?()
                print("WebViewVideoPlayer: Video ended")

            case "videoError":
                if let body = message.body as? [String: Any],
                   let error = body["error"] as? String {
                    print("WebViewVideoPlayer: Video error - \(error)")
                } else {
                    print("WebViewVideoPlayer: Unknown video error")
                }
                self.isReady = false

            case "consoleLog":
                if let msg = message.body as? String {
                    print("WebViewVideoPlayer JS: \(msg)")
                }

            case "videoState":
                if let body = message.body as? [String: Any] {
                    if let playing = body["playing"] as? Bool {
                        self.isPlaying = playing
                    }
                    if let needsGesture = body["needsUserGesture"] as? Bool, needsGesture {
                        self.needsUserGestureForAudio = true
                        print("WebViewVideoPlayer: Audio requires user gesture - tap video to enable")
                    }
                    if let audioEnabled = body["audioEnabled"] as? Bool, audioEnabled {
                        self.needsUserGestureForAudio = false
                        print("WebViewVideoPlayer: Audio enabled after user gesture")
                    }
                }

            default:
                break
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebViewVideoController: WKNavigationDelegate {
    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("WebViewVideoPlayer: HTML loaded successfully")
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WebViewVideoPlayer: Navigation failed - \(error.localizedDescription)")
    }

    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("WebViewVideoPlayer: Provisional navigation failed - \(error.localizedDescription)")
    }

    /// Handle HTTP Basic Auth challenges for video requests
    nonisolated public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only handle HTTP Basic Auth
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Get credentials from MediaStreamConfiguration
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        // Build URL to check with credential provider
        var components = URLComponents()
        components.scheme = challenge.protectionSpace.protocol
        components.host = host
        components.port = port

        if let url = components.url {
            // Check for credentials - need to dispatch to main actor
            Task { @MainActor in
                if let creds = MediaStreamConfiguration.credentials(for: url) {
                    print("WebViewVideoPlayer: Providing credentials for \(host)")
                    let credential = URLCredential(user: creds.username, password: creds.password, persistence: .forSession)
                    completionHandler(.useCredential, credential)
                } else {
                    print("WebViewVideoPlayer: No credentials configured for \(host)")
                    completionHandler(.performDefaultHandling, nil)
                }
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - WebView Video Representable (iOS)

#if canImport(UIKit)
public struct WebViewVideoRepresentable: UIViewRepresentable {
    @ObservedObject var controller: WebViewVideoController

    public init(controller: WebViewVideoController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> WKWebView {
        let webView = controller.webView ?? controller.createWebView()
        webView.isUserInteractionEnabled = false // Pass touches to SwiftUI
        return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
        // WebView updates handled by controller
    }
}
#elseif canImport(AppKit)
public struct WebViewVideoRepresentable: NSViewRepresentable {
    @ObservedObject var controller: WebViewVideoController

    public init(controller: WebViewVideoController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> WKWebView {
        let webView = controller.webView ?? controller.createWebView()
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        // WebView updates handled by controller
    }
}
#endif

// MARK: - Custom WebView Video Player View with Controls

/// Video player view with SwiftUI controls using WKWebView for rendering
public struct CustomWebViewVideoPlayerView: View {
    @ObservedObject var controller: WebViewVideoController
    let shouldAutoplay: Bool
    var showControls: Bool = true
    var hasAudio: Bool = true
    var onVideoEnd: (() -> Void)? = nil
    @Binding var isInteractingWithControls: Bool

    @State private var isDragging = false
    @State private var showVolumeSlider = false
    @State private var scrubPosition: Double = 0
    @State private var volumeCollapseTimer: Timer?
    @State private var scrubPreviewTask: Task<Void, Never>?

    @AppStorage("MediaStream_WebViewVideoVolume") private var volume: Double = 1.0
    @AppStorage("MediaStream_WebViewVideoMuted") private var isMuted: Bool = false

    /// Track if user has interacted with audio controls (required for iOS unmuting)
    @State private var hasUserAudioInteraction = false

    public init(
        controller: WebViewVideoController,
        shouldAutoplay: Bool,
        showControls: Bool = true,
        hasAudio: Bool = true,
        onVideoEnd: (() -> Void)? = nil,
        isInteractingWithControls: Binding<Bool> = .constant(false)
    ) {
        self.controller = controller
        self.shouldAutoplay = shouldAutoplay
        self.showControls = showControls
        self.hasAudio = hasAudio
        self.onVideoEnd = onVideoEnd
        self._isInteractingWithControls = isInteractingWithControls
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

    public var body: some View {
        ZStack {
            // Video layer - allow hit testing when we need user gesture for audio
            WebViewVideoRepresentable(controller: controller)
                .allowsHitTesting(controller.needsUserGestureForAudio)

            // Audio gesture overlay - shown when user needs to tap to enable audio
            if controller.needsUserGestureForAudio {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundColor(.white)
                        Text("Tap video to enable audio")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 60) // Above controls
                }
                .allowsHitTesting(false) // Let taps pass through to video
            }

            // Controls overlay
            if showControls {
                VStack(spacing: 0) {
                    Spacer()

                    HStack(spacing: 12) {
                        // Play/Pause
                        Button(action: { controller.togglePlayPause() }) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 36, height: 36)

                                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)

                        Text(formatTime(isDragging ? scrubPosition : controller.currentTime))
                            .font(.caption)
                            .foregroundColor(.white)
                            .monospacedDigit()

                        // Scrub bar with debounced preview
                        Slider(
                            value: Binding(
                                get: { isDragging ? scrubPosition : controller.currentTime },
                                set: { newValue in
                                    scrubPosition = newValue
                                    // Debounced seek preview while dragging
                                    if isDragging {
                                        scrubPreviewTask?.cancel()
                                        scrubPreviewTask = Task {
                                            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
                                            guard !Task.isCancelled else { return }
                                            await MainActor.run {
                                                controller.seek(to: scrubPosition)
                                            }
                                        }
                                    }
                                }
                            ),
                            in: 0...max(controller.duration, 1.0),
                            onEditingChanged: { editing in
                                if editing {
                                    scrubPosition = controller.currentTime
                                    MediaControlsInteractionState.shared.isInteracting = true
                                } else {
                                    // Cancel any pending preview and do final seek
                                    scrubPreviewTask?.cancel()
                                    controller.seek(to: scrubPosition)
                                    MediaControlsInteractionState.shared.isInteracting = false
                                }
                                isDragging = editing
                                isInteractingWithControls = editing
                            }
                        )
                        .frame(maxWidth: .infinity)
                        .tint(.white)

                        Text(formatTime(controller.duration))
                            .font(.caption)
                            .foregroundColor(.white)
                            .monospacedDigit()

                        // Volume controls
                        HStack(spacing: 8) {
                            // Volume slider (expandable)
                            if showVolumeSlider {
                                Slider(value: $volume, in: 0...1) { editing in
                                    hasUserAudioInteraction = true
                                    // Always unmute when interacting with volume slider
                                    if !editing {
                                        // On release, set final volume
                                        controller.setVolume(Float(volume))
                                        if volume > 0 {
                                            isMuted = false
                                            controller.setMuted(false)
                                        }
                                    }
                                    resetVolumeCollapseTimer()
                                }
                                .frame(width: 80)
                                .tint(.white)
                                .onChange(of: volume) { _, newValue in
                                    hasUserAudioInteraction = true
                                    // Unmute and set volume on every change
                                    controller.setMuted(false)
                                    controller.setVolume(Float(newValue))
                                    if newValue > 0 {
                                        isMuted = false
                                    }
                                    resetVolumeCollapseTimer()
                                }
                            }

                            // Volume/mute button
                            Button(action: {
                                hasUserAudioInteraction = true
                                if showVolumeSlider {
                                    toggleMute()
                                } else {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showVolumeSlider = true
                                    }
                                    // Always sync volume and muted state when slider is shown
                                    // Video starts muted in HTML, so we must explicitly unmute
                                    controller.setVolume(Float(volume))
                                    controller.setMuted(isMuted)
                                    // If not muted in our state, unmute the video too
                                    if !isMuted {
                                        controller.setMuted(false)
                                    }
                                }
                                resetVolumeCollapseTimer()
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
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .blockParentGestures()
                }
                .transition(.opacity)
                .allowsHitTesting(true)
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            controller.onVideoEnd = onVideoEnd
        }
        .onChange(of: controller.isReady) { _, isReady in
            // Only apply stored audio settings if user has explicitly interacted with audio controls
            // iOS kills playback if we programmatically unmute without user gesture
            // So we wait for the user to tap the volume button before applying their saved preferences
            if isReady && hasUserAudioInteraction {
                controller.setVolume(Float(volume))
                controller.setMuted(isMuted)
            }
        }
        .task {
            if shouldAutoplay {
                controller.cancelFirstFrameMode()
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    controller.play()
                }
            }
        }
        .onChange(of: shouldAutoplay) { _, newValue in
            if newValue {
                controller.cancelFirstFrameMode()
                if controller.didReachEnd {
                    controller.seekToBeginning()
                    controller.didReachEnd = false
                }
                controller.play()
            } else {
                controller.pause()
            }
        }
        .onDisappear {
            controller.pause()
            volumeCollapseTimer?.invalidate()
            scrubPreviewTask?.cancel()
        }
    }

    private func formatTime(_ time: Double) -> String {
        guard time.isFinite else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func toggleMute() {
        isMuted.toggle()
        controller.setMuted(isMuted)
        if !isMuted && volume == 0 {
            volume = 0.5
            controller.setVolume(0.5)
        }
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
}

// MARK: - Color Helpers

extension PlatformColor {
    /// Convert color to hex string for CSS
    var hexString: String {
        #if canImport(UIKit)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        return String(format: "#%02X%02X%02X",
                      Int(red * 255),
                      Int(green * 255),
                      Int(blue * 255))
        #elseif canImport(AppKit)
        guard let rgbColor = usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        return String(format: "#%02X%02X%02X",
                      Int(rgbColor.redComponent * 255),
                      Int(rgbColor.greenComponent * 255),
                      Int(rgbColor.blueComponent * 255))
        #endif
    }
}
