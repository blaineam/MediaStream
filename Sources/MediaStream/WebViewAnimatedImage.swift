//
//  WebViewAnimatedImage.swift
//  MediaStream
//
//  Native CGImageSource + display link animated image rendering.
//  Replaces WKWebView-based approach to eliminate event-handling issues on macOS.
//  Uses the same frame-by-frame decoding pattern as StreamingAnimatedImageView.
//

import Foundation
import SwiftUI
import ImageIO
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Native Animated Image Controller

/// Controller for displaying animated images via native CGImageSource + display link.
/// Decodes frames on-demand with LRU caching for memory efficiency.
@MainActor
public class WebViewAnimatedImageController: NSObject, ObservableObject {
    @Published public var isReady: Bool = false

    private var imageSource: CGImageSource?
    private var frameCount: Int = 0
    private var frameDurations: [TimeInterval] = []
    private var totalDuration: TimeInterval = 0
    private var currentFrameIndex: Int = 0
    private var accumulatedTime: TimeInterval = 0
    private var isAnimating = false

    /// When startAnimating() is called before the source is loaded (remote URL still
    /// downloading), this flag defers the start until setupSource() completes.
    private var pendingStart = false

    /// LRU frame cache — keep a small window around current frame
    private static let frameCacheSize = 4
    private var frameCache: [Int: CGImage] = [:]

    /// The current frame to display
    @Published public var currentFrame: CGImage?

    /// Accurate elapsed-time tracking (used by both CADisplayLink and Timer)
    private var lastFrameTimestamp: CFTimeInterval = 0

    /// Display link / timer for animation
    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #else
    private var displayTimer: Timer?
    #endif

    /// Active download task (for cancellation)
    private var downloadTask: URLSessionDataTask?

    override public init() {
        super.init()
    }

    // MARK: - Loading

    /// Load an animated image from a URL, with optional auth headers.
    public func load(url: URL, headers: [String: String]? = nil) {
        // Cancel any in-progress download
        downloadTask?.cancel()
        reset()

        // Try local file first
        if url.isFileURL {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                setupSource(source)
            }
            return
        }

        // Remote URL — download with auth headers
        var request = URLRequest(url: url)

        // Resolve auth header
        if let h = headers?["Authorization"] {
            request.setValue(h, forHTTPHeaderField: "Authorization")
        } else if let h = MediaStreamConfiguration.headers(for: url)?["Authorization"] {
            request.setValue(h, forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data, error == nil else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Don't call reset() here — it would clear pendingStart.
                // loadAnimatedData already handles source setup.
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
                self.setupSource(source)
            }
        }
        downloadTask = task
        task.resume()
    }

    /// Load an animated image from raw data.
    public func loadAnimatedData(_ data: Data, mimeType: String) {
        reset()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
        setupSource(source)
    }

    private func setupSource(_ source: CGImageSource) {
        imageSource = source
        frameCount = CGImageSourceGetCount(source)

        guard frameCount > 0 else { return }

        // Pre-calculate frame durations
        frameDurations = []
        totalDuration = 0

        for i in 0..<frameCount {
            let duration = getFrameDuration(at: i)
            frameDurations.append(duration)
            totalDuration += duration
        }

        // Show first frame immediately
        if let first = decodeFrame(at: 0) {
            currentFrame = first
        }

        isReady = true

        // If startAnimating() was called before the source was loaded, start now.
        if pendingStart {
            pendingStart = false
            startAnimating()
        }
    }

    // MARK: - Frame Duration

    private func getFrameDuration(at index: Int) -> TimeInterval {
        guard let source = imageSource,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else {
            return 0.1
        }

        var duration: TimeInterval = 0.1

        if let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
            if let delay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval, delay > 0 {
                duration = delay
            } else if let delay = gifProperties[kCGImagePropertyGIFDelayTime as String] as? TimeInterval, delay > 0 {
                duration = delay
            }
        } else if let pngProperties = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            if let delay = pngProperties[kCGImagePropertyAPNGDelayTime as String] as? TimeInterval, delay > 0 {
                duration = delay
            }
        } else if let webpProperties = properties[kCGImagePropertyWebPDictionary as String] as? [String: Any] {
            if let delay = webpProperties[kCGImagePropertyWebPUnclampedDelayTime as String] as? TimeInterval, delay > 0 {
                duration = delay
            } else if let delay = webpProperties[kCGImagePropertyWebPDelayTime as String] as? TimeInterval, delay > 0 {
                duration = delay
            }
        } else if let heicProperties = properties["{HEICS}" as String] as? [String: Any] {
            if let delay = heicProperties["DelayTime" as String] as? TimeInterval, delay > 0 {
                duration = delay
            }
        }

        return max(duration, 0.01)
    }

    // MARK: - Frame Decoding

    private func decodeFrame(at index: Int) -> CGImage? {
        if let cached = frameCache[index] {
            return cached
        }

        guard let source = imageSource else { return nil }

        let options: [CFString: Any] = [kCGImageSourceShouldCache: true]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else {
            return nil
        }

        frameCache[index] = cgImage

        if frameCache.count > Self.frameCacheSize {
            evictDistantFrames(from: index)
        }

        return cgImage
    }

    private func evictDistantFrames(from currentIndex: Int) {
        let keepRange = max(0, currentIndex - 1)...min(frameCount - 1, currentIndex + Self.frameCacheSize - 2)
        for key in frameCache.keys where !keepRange.contains(key) {
            frameCache.removeValue(forKey: key)
        }
    }

    // MARK: - Animation Control

    public func startAnimating() {
        // Source not loaded yet (remote download in progress) — defer start
        if frameCount == 0 {
            pendingStart = true
            return
        }
        guard !isAnimating, frameCount > 1 else { return }
        isAnimating = true
        lastFrameTimestamp = CACurrentMediaTime()

        #if canImport(UIKit)
        let link = CADisplayLink(target: self, selector: #selector(updateFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #else
        // macOS: Timer at ~60fps with accurate elapsed-time tracking
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let now = CACurrentMediaTime()
                let elapsed = now - self.lastFrameTimestamp
                self.lastFrameTimestamp = now
                self.advanceFrame(elapsed: elapsed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
        #endif
    }

    public func stopAnimating() {
        isAnimating = false
        pendingStart = false

        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        #else
        displayTimer?.invalidate()
        displayTimer = nil
        #endif
    }

    #if canImport(UIKit)
    @objc private func updateFrame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrameTimestamp
        lastFrameTimestamp = now
        advanceFrame(elapsed: elapsed)
    }
    #endif

    private func advanceFrame(elapsed: TimeInterval) {
        guard frameCount > 1 else { return }

        accumulatedTime += elapsed

        let frameDuration = frameDurations[currentFrameIndex]

        if accumulatedTime >= frameDuration {
            accumulatedTime -= frameDuration
            currentFrameIndex = (currentFrameIndex + 1) % frameCount

            if let frame = decodeFrame(at: currentFrameIndex) {
                currentFrame = frame
            }

            // Pre-decode next frame
            let nextIndex = (currentFrameIndex + 1) % frameCount
            _ = decodeFrame(at: nextIndex)
        }
    }

    // MARK: - Cleanup

    private func reset() {
        stopAnimating()
        frameCache.removeAll()
        imageSource = nil
        frameDurations = []
        frameCount = 0
        totalDuration = 0
        currentFrameIndex = 0
        accumulatedTime = 0
        lastFrameTimestamp = 0
        currentFrame = nil
        isReady = false
    }

    public func destroy() {
        downloadTask?.cancel()
        downloadTask = nil
        reset()
    }
}

// MARK: - Native Rendering Views

#if canImport(UIKit)

/// UIKit view that displays CGImage frames via UIImageView
private class NativeAnimatedImageUIView: UIView {
    let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        return iv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateFrame(_ cgImage: CGImage?) {
        if let cgImage = cgImage {
            imageView.image = UIImage(cgImage: cgImage)
        }
    }
}

/// UIViewRepresentable for native animated image
public struct WebViewAnimatedImageRepresentable: UIViewRepresentable {
    @ObservedObject var controller: WebViewAnimatedImageController

    public init(controller: WebViewAnimatedImageController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> UIView {
        let view = NativeAnimatedImageUIView()
        view.updateFrame(controller.currentFrame)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        if let view = uiView as? NativeAnimatedImageUIView {
            view.updateFrame(controller.currentFrame)
        }
    }
}

#else

/// AppKit view that displays CGImage frames via layer.contents
private class NativeAnimatedImageNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateFrame(_ cgImage: CGImage?) {
        layer?.contents = cgImage
    }
}

/// NSViewRepresentable for native animated image
public struct WebViewAnimatedImageRepresentable: NSViewRepresentable {
    @ObservedObject var controller: WebViewAnimatedImageController

    public init(controller: WebViewAnimatedImageController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NativeAnimatedImageNSView()
        view.updateFrame(controller.currentFrame)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? NativeAnimatedImageNSView {
            view.updateFrame(controller.currentFrame)
        }
    }
}

#endif

// MARK: - Simple SwiftUI View

/// A simple SwiftUI view for displaying animated images natively
public struct WebViewAnimatedImageView: View {
    let url: URL
    let headers: [String: String]?

    @StateObject private var controller = WebViewAnimatedImageController()

    public init(url: URL, headers: [String: String]? = nil) {
        self.url = url
        self.headers = headers
    }

    public var body: some View {
        ZStack {
            WebViewAnimatedImageRepresentable(controller: controller)

            if !controller.isReady {
                ProgressView()
                    .scaleEffect(1.5)
                    #if canImport(UIKit)
                    .tint(.white)
                    #endif
            }
        }
        .onAppear {
            controller.load(url: url, headers: headers)
            controller.startAnimating()
        }
        .onDisappear {
            controller.destroy()
        }
    }
}
