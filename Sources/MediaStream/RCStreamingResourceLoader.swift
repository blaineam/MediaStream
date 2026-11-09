//
//  RCStreamingResourceLoader.swift
//  MediaStream
//
//  Bridges AVPlayer / AVURLAsset to a `URLSession` that the host app
//  controls. AVURLAsset has no public hook for server-trust evaluation,
//  which means it cannot speak HTTPS to a self-signed-cert host on its
//  own. By rewriting such URLs to a custom scheme and attaching this
//  delegate to the asset's resource loader, we route every byte through
//  `MediaStreamConfiguration.serverTrustEvaluator`-aware `URLSession`
//  fetches — same TLS, same auth headers, same trust pin.
//
//  The fetching itself is `RCReadAheadEngine`: AV's many short-lived range
//  requests are served from a few long-lived upstream connections with a
//  bounded read-ahead, so a slow-to-answer cloud remote pays its latency
//  once per window instead of once per AV request. Bytes are forwarded to
//  `dataRequest.respond` as they arrive, so decoding starts before a range
//  completes.
//
//  Limitations / not handled:
//  - HLS multivariant playlists. Apple's HLS engine partially bypasses
//    the resource loader for sub-fetches; HLS over self-signed cert is
//    out of scope here. Single-file MP4/MOV/etc. (the rclone-served
//    case) is the supported configuration.
//  - Authentication challenges other than server-trust on the
//    URLSession side. The host app's host-wide Basic-Auth header
//    injection (via `MediaStreamConfiguration.headerProvider`) covers
//    the rclone RC case.
//

import Foundation
import AVFoundation

/// Custom URL scheme that tags an AVURLAsset URL as "I want this routed
/// through `RCStreamingResourceLoader`." The actual fetch is performed
/// over `https://` — the scheme is just a sentinel.
public let RCStreamingScheme = "espace-rc-https"

public final class RCStreamingResourceLoader: NSObject, @unchecked Sendable {
    public static let shared = RCStreamingResourceLoader()

    /// Serial queue handed to AVAssetResourceLoader. AV runs callbacks here.
    public let queue = DispatchQueue(label: "com.mediastream.rcLoader", qos: .userInitiated)

    /// Returns true if a URL is one we should intercept (self-signed loopback host).
    public static func shouldIntercept(url: URL) -> Bool {
        guard let host = url.host else { return false }
        let isLocalhost = host == "127.0.0.1" || host == "localhost" || host == "::1"
        return isLocalhost && url.scheme == "https"
    }

    /// Rewrite a real `https://` URL to a sentinel `espace-rc-https://` URL.
    public static func sentinelURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = RCStreamingScheme
        return components.url
    }

    /// Translate the sentinel scheme back to `https://` for the actual fetch.
    fileprivate static func realURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// The byte pump: upstream connections, read-ahead and mirror failover.
    /// Shares `queue` with AV's callbacks.
    private lazy var engine = RCReadAheadEngine(queue: queue)

    /// AV loading request as an engine sink. Only touched on `queue`, hence
    /// the unchecked Sendable.
    private final class LoadingSink: RCRangeSink, @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        /// Called once the request is finished, to drop it from `sinks`.
        var onFinish: (() -> Void)?
        init(_ request: AVAssetResourceLoadingRequest) { self.request = request }

        var wantsContentInfo: Bool { request.contentInformationRequest != nil }
        var hasDataRequest: Bool { request.dataRequest != nil }

        func fillContentInfo(contentType: String?, length: Int64?) {
            guard let info = request.contentInformationRequest else { return }
            info.contentType = contentType
            // rclone always serves byte ranges. Reporting false makes AVPlayer
            // download the whole file before playing.
            info.isByteRangeAccessSupported = true
            if let length { info.contentLength = length }
        }

        func respond(with data: Data) {
            request.dataRequest?.respond(with: data)
        }

        func finish(error: Error?) {
            onFinish?()
            onFinish = nil
            guard !request.isFinished, !request.isCancelled else { return }
            if let error {
                request.finishLoading(with: error)
            } else {
                request.finishLoading()
            }
        }
    }

    private var sinks: [ObjectIdentifier: LoadingSink] = [:]
}

extension RCStreamingResourceLoader: AVAssetResourceLoaderDelegate {
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let sentinelURL = loadingRequest.request.url,
              let httpsURL = Self.realURL(for: sentinelURL) else {
            loadingRequest.finishLoading(
                with: NSError(domain: "RCStreamingResourceLoader", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not translate sentinel URL"])
            )
            return true
        }

        // The requested range, read while on AV's queue. A content-info-only
        // request is answered from the first response, so it asks for byte 0
        // onward like the data request that always follows it.
        var lower: Int64 = 0
        var upper: Int64? = nil
        if let dataReq = loadingRequest.dataRequest {
            lower = dataReq.requestedOffset
            if !dataReq.requestsAllDataToEndOfResource, dataReq.requestedLength > 0 {
                upper = lower + Int64(dataReq.requestedLength) - 1
            }
        }

        let sink = LoadingSink(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        sinks[key] = sink
        sink.onFinish = { [unowned self] in self.sinks.removeValue(forKey: key) }
        if engine.knows(httpsURL) {
            engine.load(sink: sink, url: httpsURL, lower: lower, upper: upper, headers: [:])
        } else {
            // First request for this file: fetch the host's auth headers from
            // the main actor, then continue on AV's queue.
            Task { [weak self] in
                let headers = await MediaStreamConfiguration.headersAsync(for: httpsURL) ?? [:]
                self?.queue.async {
                    guard let self else { return }
                    self.engine.load(sink: sink, url: httpsURL, lower: lower, upper: upper, headers: headers)
                }
            }
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let sink = sinks.removeValue(forKey: ObjectIdentifier(loadingRequest)) else { return }
        engine.cancel(sink: sink)
    }
}

// MARK: - AVURLAsset helper

public extension AVURLAsset {
    /// Build an AVURLAsset that knows how to talk to the app's self-signed
    /// loopback RC. If the URL is one we should intercept, the scheme is
    /// rewritten to the sentinel and the resource loader delegate is
    /// attached. Otherwise we return a plain `AVURLAsset(url:options:)`.
    static func makeForRCStream(url: URL, options: [String: Any]? = nil) -> AVURLAsset {
        if RCStreamingResourceLoader.shouldIntercept(url: url),
           let sentinel = RCStreamingResourceLoader.sentinelURL(for: url) {
            let asset = AVURLAsset(url: sentinel, options: options)
            asset.resourceLoader.setDelegate(RCStreamingResourceLoader.shared,
                                             queue: RCStreamingResourceLoader.shared.queue)
            return asset
        }
        return AVURLAsset(url: url, options: options)
    }
}
