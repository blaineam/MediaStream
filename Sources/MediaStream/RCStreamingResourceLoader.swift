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

        /// Equivalent locations for this resource (see `RCStreamRouting`),
        /// in preference order, and which one the current task is using.
        var candidates: [URL] = []
        var candidateIndex = 0
        /// The byte range AV asked for. `rangeUpper == nil` means "to end".
        /// nil `rangeLower` means no Range header at all.
        var rangeLower: Int64?
        var rangeUpper: Int64?
        /// Bytes already handed to AV for this request — a failover resumes
        /// after them so nothing is delivered twice.
        var bytesDelivered: Int64 = 0
        /// Set when the current candidate answered with an HTTP error status:
        /// its body must not be fed to AV, and completion fails over.
        var rejectedResponse = false
        /// Host-supplied headers, resolved once and reused on failover.
        var headers: [String: String] = [:]
        var startedAt = Date()

        init(loadingRequest: AVAssetResourceLoadingRequest) {
            self.loadingRequest = loadingRequest
        }

        var currentURL: URL? {
            candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
        }

        var hasFallback: Bool { candidateIndex + 1 < candidates.count }

        /// Range header for the CURRENT attempt, accounting for bytes already
        /// delivered by an earlier candidate.
        var rangeHeader: String? {
            guard let lower = rangeLower else { return nil }
            let start = lower + bytesDelivered
            if let upper = rangeUpper {
                return "bytes=\(start)-\(upper)"
            }
            return "bytes=\(start)-"
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
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            // An error page is not media. Never let its Content-Length become
            // the asset's length or its body reach the decoder; completion
            // fails over (or fails) instead.
            pending.rejectedResponse = true
            pending.task?.cancel()
            return
        }
        if let url = pending.currentURL {
            RCStreamRouting.reportSuccess?(url, Date().timeIntervalSince(pending.startedAt))
        }
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
        guard let pending, !pending.rejectedResponse else { return }
        pending.bytesDelivered += Int64(data.count)
        pending.loadingRequest.dataRequest?.respond(with: data)
    }

    fileprivate func handleCompletion(taskIdentifier: Int, error: Error?) {
        lock.lock()
        let pending = pendingByTaskID.removeValue(forKey: taskIdentifier)
        // Still registered under its loading request ⇒ AV hasn't cancelled it.
        // A task WE cancelled for an HTTP error status still counts as failed.
        let stillWanted = pending.map {
            pendingByLoadingRequest[ObjectIdentifier($0.loadingRequest)] === $0
        } ?? false
        lock.unlock()
        guard let pending = pending else { return }

        let cancelled = (error as NSError?)?.code == NSURLErrorCancelled
        let failed = pending.rejectedResponse || (error != nil && !cancelled)

        if failed && stillWanted {
            if let url = pending.currentURL { RCStreamRouting.reportFailure?(url) }
            // Mid-stream failover: same loading request, remaining bytes, next
            // mirror. AV keeps waiting on the request and never sees the drop.
            if pending.hasFallback {
                pending.candidateIndex += 1
                pending.rejectedResponse = false
                startTask(for: pending)
                return
            }
        }

        lock.lock()
        pendingByLoadingRequest.removeValue(forKey: ObjectIdentifier(pending.loadingRequest))
        lock.unlock()

        if pending.rejectedResponse {
            pending.loadingRequest.finishLoading(
                with: NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable,
                              userInfo: [NSLocalizedDescriptionKey: "The media server returned an error"]))
        } else if let error = error, !cancelled {
            pending.loadingRequest.finishLoading(with: error)
        } else if !cancelled || stillWanted {
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

        // Capture the requested byte range on the AV-owned queue while the
        // request is still safe to inspect. AVPlayer issues many concurrent
        // range requests for streaming; each one needs its `Range` to match
        // the dataRequest exactly, with a left-open form for "to end of file"
        // so the server can keep streaming without our needing to know total
        // length. Kept as numbers (not a header string) so a mid-range
        // failover can resume after the bytes already delivered.
        var rangeLower: Int64? = nil
        var rangeUpper: Int64? = nil
        if let dataReq = loadingRequest.dataRequest {
            let lower = dataReq.requestedOffset
            if dataReq.requestsAllDataToEndOfResource {
                rangeLower = lower
            } else if dataReq.requestedLength > 0 {
                rangeLower = lower
                rangeUpper = lower + Int64(dataReq.requestedLength) - 1
            } else if lower > 0 {
                rangeLower = lower
            }
        } else if loadingRequest.contentInformationRequest != nil {
            rangeLower = 0
            rangeUpper = 1
        }

        Task { [weak self] in
            await self?.kickOffFetch(loadingRequest: loadingRequest,
                                     httpsURL: httpsURL,
                                     rangeLower: rangeLower,
                                     rangeUpper: rangeUpper)
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
                              rangeLower: Int64?,
                              rangeUpper: Int64?) async {
        let pending = PendingRequest(loadingRequest: loadingRequest)
        pending.candidates = RCStreamRouting.resolve(httpsURL)
        pending.rangeLower = rangeLower
        pending.rangeUpper = rangeUpper
        // Headers are host-wide (Basic auth for the loopback listener), so
        // the original URL's headers serve every candidate.
        pending.headers = await MediaStreamConfiguration.headersAsync(for: httpsURL) ?? [:]
        startTask(for: pending)
    }

    /// Start (or restart, on failover) the data task for `pending`'s current
    /// candidate.
    private func startTask(for pending: PendingRequest) {
        guard let url = pending.currentURL else {
            pending.loadingRequest.finishLoading(with: URLError(.badURL))
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if pending.hasFallback {
            request.timeoutInterval = RCStreamRouting.failoverRequestTimeout
        }
        if let rangeHeader = pending.rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        for (key, value) in pending.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.dataTask(with: request)
        pending.startedAt = Date()

        lock.lock()
        if let old = pending.task { pendingByTaskID.removeValue(forKey: old.taskIdentifier) }
        pending.task = task
        pendingByTaskID[task.taskIdentifier] = pending
        pendingByLoadingRequest[ObjectIdentifier(pending.loadingRequest)] = pending
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
