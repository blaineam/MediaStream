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
//  Why not a straight `URLSession.dataTask` callback? AVPlayer issues
//  *many* concurrent range requests during seeking/scrubbing and each
//  range can be megabytes. We stream bytes with the URLSession data
//  delegate (`didReceive data:` per chunk) and forward them straight
//  into the asset's `dataRequest.respond`, so memory stays bounded and
//  the asset starts decoding before the range completes.
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

    /// One per (resourceLoader request, URLSession task) pair.
    final class PendingRequest {
        let loadingRequest: AVAssetResourceLoadingRequest
        var task: URLSessionDataTask?
        /// Whether we've already populated the `contentInformationRequest`.
        /// AV may reuse the same loadingRequest for cancellation routing; we
        /// only fill content info on the first response we see.
        var contentInfoFilled = false

        init(loadingRequest: AVAssetResourceLoadingRequest) {
            self.loadingRequest = loadingRequest
        }
    }

    private var pendingByTaskID: [Int: PendingRequest] = [:]
    private var pendingByLoadingRequest: [ObjectIdentifier: PendingRequest] = [:]
    private let lock = NSLock()

    /// `URLSession` that uses the host-supplied trust evaluator. Built once
    /// per loader; recreated when the loader observes a cert rotation so
    /// in-flight TLS sessions to the previous cert don't get reused.
    private lazy var session: URLSession = makeSession()

    /// Internal trust delegate. Forwards server-trust challenges to
    /// `MediaStreamConfiguration.serverTrustEvaluator`; everything else
    /// falls through to default handling.
    private final class TrustDelegate: NSObject, URLSessionDataDelegate {
        weak var owner: RCStreamingResourceLoader?

        init(owner: RCStreamingResourceLoader) {
            self.owner = owner
        }

        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let host = challenge.protectionSpace.host
            if MediaStreamConfiguration.evaluateServerTrust(serverTrust, host: host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let owner = owner else {
                completionHandler(.cancel)
                return
            }
            owner.handleResponse(taskIdentifier: dataTask.taskIdentifier, response: response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            owner?.handleData(taskIdentifier: dataTask.taskIdentifier, data: data)
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            owner?.handleCompletion(taskIdentifier: task.taskIdentifier, error: error)
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 0
        let delegate = TrustDelegate(owner: self)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Response routing

    fileprivate func handleResponse(taskIdentifier: Int, response: URLResponse) {
        lock.lock()
        let pending = pendingByTaskID[taskIdentifier]
        lock.unlock()
        guard let pending = pending else { return }
        if !pending.contentInfoFilled, let info = pending.loadingRequest.contentInformationRequest,
           let http = response as? HTTPURLResponse {
            info.contentType = http.value(forHTTPHeaderField: "Content-Type")
            // Force-true: the rclone HTTP server always supports byte-range
            // requests, but a 200 OK response (when the server returns the
            // whole body for a 0-1 range probe) won't include
            // `Accept-Ranges: bytes`. Reporting false here makes AVPlayer
            // fall back to fetching the entire file before playback —
            // which is exactly the slow path the user just hit.
            info.isByteRangeAccessSupported = true
            // For 206 partial content, Content-Range carries the total length.
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let total = contentRange.split(separator: "/").last,
               let length = Int64(total) {
                info.contentLength = length
            } else if let lengthStr = http.value(forHTTPHeaderField: "Content-Length"),
                      let length = Int64(lengthStr) {
                info.contentLength = length
            }
            pending.contentInfoFilled = true
        }
    }

    fileprivate func handleData(taskIdentifier: Int, data: Data) {
        lock.lock()
        let pending = pendingByTaskID[taskIdentifier]
        lock.unlock()
        pending?.loadingRequest.dataRequest?.respond(with: data)
    }

    fileprivate func handleCompletion(taskIdentifier: Int, error: Error?) {
        lock.lock()
        let pending = pendingByTaskID.removeValue(forKey: taskIdentifier)
        if let pending = pending {
            pendingByLoadingRequest.removeValue(forKey: ObjectIdentifier(pending.loadingRequest))
        }
        lock.unlock()
        guard let pending = pending else { return }
        if let error = error, (error as NSError).code != NSURLErrorCancelled {
            pending.loadingRequest.finishLoading(with: error)
        } else {
            pending.loadingRequest.finishLoading()
        }
    }
}

extension RCStreamingResourceLoader: AVAssetResourceLoaderDelegate {
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // Capture all needed values from the loading request synchronously here
        // (the request has thread-affinity to the AV worker queue and can't be
        // dereferenced freely from a Task) and then dispatch the actual fetch
        // off-queue so we can read MediaStreamConfiguration.headersAsync from
        // the main actor.
        guard let sentinelURL = loadingRequest.request.url,
              let httpsURL = Self.realURL(for: sentinelURL) else {
            loadingRequest.finishLoading(
                with: NSError(domain: "RCStreamingResourceLoader", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not translate sentinel URL"])
            )
            return true
        }

        // Build the Range header on the AV-owned queue while the request is
        // still safe to inspect. AVPlayer issues many concurrent range
        // requests for streaming; each one needs its `Range` to match the
        // dataRequest exactly, with a left-open form for "to end of file"
        // so the server can keep streaming without our needing to know
        // total length.
        var rangeHeader: String? = nil
        if let dataReq = loadingRequest.dataRequest {
            let lower = dataReq.requestedOffset
            if dataReq.requestsAllDataToEndOfResource {
                rangeHeader = "bytes=\(lower)-"
            } else {
                let length = dataReq.requestedLength
                if length > 0 {
                    let upper = lower + Int64(length) - 1
                    rangeHeader = "bytes=\(lower)-\(upper)"
                } else if lower > 0 {
                    rangeHeader = "bytes=\(lower)-"
                }
            }
        } else if loadingRequest.contentInformationRequest != nil {
            rangeHeader = "bytes=0-1"
        }

        Task { [weak self] in
            await self?.kickOffFetch(loadingRequest: loadingRequest,
                                     httpsURL: httpsURL,
                                     rangeHeader: rangeHeader)
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        cancelLoading(loadingRequest: loadingRequest)
    }

    /// Async tail of `shouldWaitForLoadingOfRequestedResource`. Reads auth
    /// headers from the main actor (where `MediaStreamConfiguration` lives),
    /// builds the `URLRequest`, and starts the data task. Splitting it like
    /// this avoids `MainActor.assumeIsolated` from a non-main queue, which
    /// would trap.
    private func kickOffFetch(loadingRequest: AVAssetResourceLoadingRequest,
                              httpsURL: URL,
                              rangeHeader: String?) async {
        var request = URLRequest(url: httpsURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let rangeHeader = rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        if let headers = await MediaStreamConfiguration.headersAsync(for: httpsURL) {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let pending = PendingRequest(loadingRequest: loadingRequest)
        let task = session.dataTask(with: request)
        pending.task = task

        lock.lock()
        pendingByTaskID[task.taskIdentifier] = pending
        pendingByLoadingRequest[ObjectIdentifier(loadingRequest)] = pending
        lock.unlock()

        task.resume()
    }

    private func cancelLoading(loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        let pending = pendingByLoadingRequest.removeValue(forKey: ObjectIdentifier(loadingRequest))
        if let pending = pending, let task = pending.task {
            pendingByTaskID.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            task.cancel()
        } else {
            lock.unlock()
        }
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
