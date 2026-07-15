//
//  VideoMetadata.swift
//  MediaStream
//
//  Video metadata extraction using HTML5 video via WKWebView
//  Falls back to AVFoundation for supported formats
//

import Foundation
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Player Routing

/// Decides which player a video needs, from whatever actually carries the
/// container type.
///
/// Routing MUST NOT be driven by `url.pathExtension` alone. A host that serves
/// media from a *query-based* URL (`https://host/media?id=abc`, `/proxy?key=…`)
/// has an EMPTY path extension, so an extension test never matches and every
/// video — including containers AVFoundation cannot decode — is handed to
/// AVFoundation. `diskCacheKey` is the reliable carrier: hosts are expected to
/// put the real filename there, and `MediaPlaybackService` already keys its
/// `.webm` behavior off it, so consulting it first is consistent with the rest
/// of the package. The URL stays as a fallback for hosts that DO serve
/// extensioned paths.
public enum VideoPlayerRouter {

    /// Containers AVFoundation cannot decode on any Apple platform, but which
    /// WKWebView's HTML5 `<video>` can (VP8/VP9 in a WebM container).
    ///
    /// Deliberately narrow. Formats like MKV/AVI are *also* unsupported by
    /// AVFoundation, but WebKit cannot play them either — routing them here
    /// would trade one broken player for another. They stay on the AVFoundation
    /// path, where the `isPlayable` check and the readiness timeout in
    /// `ZoomableMediaView` handle them without hanging forever.
    public static let webViewOnlyExtensions: Set<String> = ["webm"]

    /// Lowercased container extension for a media item, preferring the source
    /// that actually carries the type.
    ///
    /// Order: `diskCacheKey` (host-supplied filename) → each URL's path
    /// extension → each URL's query values (a query-based host commonly passes
    /// the real path as a parameter, e.g. `?path=Album/clip.webm`).
    /// - Returns: The extension without a dot, or nil when nothing carries one.
    public static func containerExtension(diskCacheKey: String?, urls: [URL?]) -> String? {
        if let ext = nonEmptyExtension(of: diskCacheKey) { return ext }

        let candidates = urls.compactMap { $0 }

        for url in candidates {
            if let ext = nonEmptyExtension(of: url.path) { return ext }
        }

        // Last resort: a query-based URL carries no path extension, but the
        // real filename is usually sitting in one of its query values.
        for url in candidates {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let queryItems = components.queryItems else { continue }
            for item in queryItems {
                if let ext = nonEmptyExtension(of: item.value) { return ext }
            }
        }

        return nil
    }

    /// Whether this item must use the WKWebView player because AVFoundation
    /// cannot decode its container.
    public static func requiresWebViewPlayer(diskCacheKey: String?, urls: [URL?]) -> Bool {
        guard let ext = containerExtension(diskCacheKey: diskCacheKey, urls: urls) else {
            // Nothing carries a type — let AVFoundation try. It is the better
            // player when it works, and the readiness timeout catches it when
            // it doesn't.
            return false
        }
        return webViewOnlyExtensions.contains(ext)
    }

    /// `pathExtension` for a path-like string, normalized to lowercase and to
    /// nil rather than "" when absent.
    private static func nonEmptyExtension(of path: String?) -> String? {
        guard let path = path else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

/// Helper for extracting video metadata
/// Uses AVFoundation first, then falls back to WebView-based HTML5 video for WebM and other formats
public enum VideoMetadata {

    // MARK: - Video Duration

    /// Get video duration using HTML5 video via WKWebView
    /// Works with WebM, MKV, and other formats AVFoundation doesn't support
    /// - Parameters:
    ///   - url: URL to the video file (local or remote URL)
    ///   - timeout: Maximum time to wait for metadata (default: 10 seconds)
    /// - Returns: Duration in seconds, or nil if unable to determine
    public static func getVideoDurationWebView(from url: URL, headers: [String: String]? = nil, timeout: TimeInterval = 10) async -> TimeInterval? {
        #if canImport(WebKit)
        return await WebViewVideoController.getVideoDuration(from: url, headers: headers)
        #else
        return nil
        #endif
    }

    /// Get video duration, trying AVFoundation first then falling back to WebView
    /// - Parameters:
    ///   - url: URL to the video file
    ///   - headers: Optional HTTP headers for authenticated requests (AVFoundation only)
    /// - Returns: Duration in seconds, or nil if unable to determine
    public static func getVideoDuration(from url: URL, headers: [String: String]?) async -> TimeInterval? {
        // Try AVFoundation first (more reliable for supported formats)
        let asset: AVURLAsset
        if let headers = headers, !headers.isEmpty {
            asset = AVURLAsset.makeForRCStream(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset.makeForRCStream(url: url)
        }

        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)

            // Check for valid duration
            if !seconds.isNaN && !seconds.isInfinite && seconds > 0 {
                #if DEBUG
                print("VideoMetadata: AVFoundation duration for \(url.lastPathComponent): \(seconds)s")
                #endif
                return seconds
            }
        } catch {
            #if DEBUG
            print("VideoMetadata: AVFoundation failed for \(url.lastPathComponent): \(error.localizedDescription)")
            #endif
        }

        // Fall back to WebView for unsupported formats (WebM, etc.)
        return await getVideoDurationWebView(from: url, headers: headers, timeout: 10)
    }

    // MARK: - Audio Track Detection

    /// Check if video has audio tracks using HTML5 video via WKWebView
    /// Works with WebM, MKV, and other formats AVFoundation doesn't support
    /// - Parameters:
    ///   - url: URL to the video file (local or remote URL)
    ///   - timeout: Maximum time to wait for metadata (default: 10 seconds)
    /// - Returns: True if video has audio, false if silent
    public static func hasAudioTrackWebView(url: URL, headers: [String: String]? = nil, timeout: TimeInterval = 10) async -> Bool {
        #if canImport(WebKit)
        return await WebViewVideoController.hasAudioTrack(url: url, headers: headers)
        #else
        return true // Assume audio on platforms without WebKit
        #endif
    }

    /// Check if video has audio tracks, trying AVFoundation first then falling back to WebView
    /// - Parameters:
    ///   - url: URL to the video file
    ///   - headers: Optional HTTP headers for authenticated requests (AVFoundation only)
    /// - Returns: True if video has audio, false if silent
    public static func hasAudioTrack(url: URL, headers: [String: String]?) async -> Bool {
        // Try AVFoundation first (more reliable for supported formats)
        let asset: AVURLAsset
        if let headers = headers, !headers.isEmpty {
            asset = AVURLAsset.makeForRCStream(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset.makeForRCStream(url: url)
        }

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if !audioTracks.isEmpty {
                #if DEBUG
                print("VideoMetadata: AVFoundation found audio tracks for \(url.lastPathComponent)")
                #endif
                return true
            }
            // AVFoundation found no audio - but for some formats it may not detect correctly
        } catch {
            #if DEBUG
            print("VideoMetadata: AVFoundation audio check failed for \(url.lastPathComponent): \(error.localizedDescription)")
            #endif
        }

        // Fall back to WebView for unsupported formats (WebM, etc.)
        return await hasAudioTrackWebView(url: url, headers: headers, timeout: 10)
    }

    // MARK: - Combined Metadata

    /// Metadata result containing duration and audio info
    public struct VideoInfo {
        public let duration: TimeInterval?
        public let hasAudio: Bool
    }

    /// Get both duration and audio info in one call (more efficient)
    /// - Parameters:
    ///   - url: URL to the video file (local or remote URL)
    ///   - headers: Optional HTTP headers for authenticated requests
    ///   - timeout: Maximum time to wait for metadata
    /// - Returns: VideoInfo with duration and audio detection results
    public static func getVideoInfo(from url: URL, headers: [String: String]? = nil, timeout: TimeInterval = 10) async -> VideoInfo {
        // For HTTP URLs with headers, try AVFoundation first
        if !url.isFileURL && headers != nil {
            let asset = AVURLAsset.makeForRCStream(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers!])

            var avDuration: TimeInterval?
            var avHasAudio: Bool?

            do {
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                if !seconds.isNaN && !seconds.isInfinite && seconds > 0 {
                    avDuration = seconds
                }
            } catch {}

            do {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                avHasAudio = !audioTracks.isEmpty
            } catch {}

            // If AVFoundation succeeded for both, return early
            if let duration = avDuration, let hasAudio = avHasAudio {
                return VideoInfo(duration: duration, hasAudio: hasAudio)
            }
        }

        // Use WebView for formats AVFoundation doesn't support (not available on tvOS)
        let duration = await getVideoDurationWebView(from: url, headers: headers, timeout: timeout)
        let hasAudio = await hasAudioTrackWebView(url: url, headers: headers, timeout: timeout)

        return VideoInfo(duration: duration, hasAudio: hasAudio)
    }
}
