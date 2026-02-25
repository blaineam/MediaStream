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
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: url)
        }

        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)

            // Check for valid duration
            if !seconds.isNaN && !seconds.isInfinite && seconds > 0 {
                print("VideoMetadata: AVFoundation duration for \(url.lastPathComponent): \(seconds)s")
                return seconds
            }
        } catch {
            print("VideoMetadata: AVFoundation failed for \(url.lastPathComponent): \(error.localizedDescription)")
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
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVURLAsset(url: url)
        }

        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if !audioTracks.isEmpty {
                print("VideoMetadata: AVFoundation found audio tracks for \(url.lastPathComponent)")
                return true
            }
            // AVFoundation found no audio - but for some formats it may not detect correctly
        } catch {
            print("VideoMetadata: AVFoundation audio check failed for \(url.lastPathComponent): \(error.localizedDescription)")
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
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers!])

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
