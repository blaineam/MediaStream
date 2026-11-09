//
//  RCReadAheadEngine.swift
//  MediaStream
//
//  The byte pump behind `RCStreamingResourceLoader`.
//
//  AVPlayer doesn't stream a file with one request. It opens a range, takes
//  a few megabytes, cancels it once its buffer is full, and opens another a
//  moment later just before (or at) where the last one stopped. Startup costs
//  three such requests, and a seek costs one or two. With a fixed cost per
//  request that is fine on a LAN. A cloud remote behind rclone pays a whole
//  lookup plus a link request plus the download's own time-to-first-byte on
//  every one, often seconds. That made startup crawl and steady playback
//  stutter, because each re-request stalled the decoder for that long.
//
//  So the engine keeps the upstream connection itself, decoupled from AV's
//  requests:
//
//  * Per resource (URL) it keeps up to a few **windows**: contiguous runs of
//    bytes, each fed by one open-ended upstream request (`bytes=N-`).
//  * An AV request that starts inside a window (or just past its end) is
//    served from memory and then fed live from the same connection. No new
//    upstream request, no new time-to-first-byte.
//  * A window keeps reading AHEAD after AV cancels, up to a limit that
//    starts small (a thumbnail costs little) and doubles as the window is
//    actually consumed (sequential playback), capped at `maxAhead`. When it
//    is that far ahead the connection is closed, and reopened once AV has
//    used half of it, so the reopen's latency is hidden behind the buffer.
//  * Bytes far behind the read position are dropped.
//  * A failed or stalled upstream (transport error, HTTP error status,
//    idle past `RCStreamRouting.failoverRequestTimeout` when there is an
//    alternative) resumes at the window's end on the next candidate from
//    `RCStreamRouting`. AV's requests just keep waiting.
//
//  Everything runs on one serial queue: AV's resource-loader callbacks and
//  the URLSession delegate callbacks alike, so the state needs no locks.
//

import Foundation

/// One consumer of a byte range: an AV loading request in production.
protocol RCRangeSink: AnyObject {
    /// AV wants the content type and length filled before any data.
    var wantsContentInfo: Bool { get }
    /// False for a content-info-only request.
    var hasDataRequest: Bool { get }
    func fillContentInfo(contentType: String?, length: Int64?)
    func respond(with data: Data)
    func finish(error: Error?)
}

final class RCReadAheadEngine: NSObject, @unchecked Sendable {

    struct Tuning {
        /// Read-ahead allowed beyond what AV asked for, before the window
        /// shows it is being consumed.
        var initialAhead: Int64 = 2 << 20
        /// Read-ahead cap per window (memory per playing file).
        var maxAhead: Int64 = 48 << 20
        /// Bytes kept behind the read position for AV's overlapping
        /// re-requests (it often restarts a little before where it stopped).
        var keepBehind: Int64 = 8 << 20
        /// A request starting at most this far past a window's end joins it.
        var joinGap: Int64 = 1 << 20
        var maxWindowsPerResource = 3
        /// A window nobody has asked anything of for this long stops reading.
        var idleStopAfter: TimeInterval = 15
        /// How long a request may wait at a full window's end before the
        /// window reopens its connection anyway.
        var starvingGrace: TimeInterval = 1
        /// A resource with no requests for this long is forgotten.
        var forgetAfter: TimeInterval = 45
    }

    let queue: DispatchQueue
    let tuning: Tuning
    private var session: URLSession!

    private final class Resource {
        let url: URL
        let headers: [String: String]
        var contentLength: Int64?
        var contentType: String?
        var infoKnown = false
        var windows: [Window] = []
        var lastActivity = Date()
        init(url: URL, headers: [String: String]) {
            self.url = url
            self.headers = headers
        }
    }

    private final class Window {
        unowned let resource: Resource
        /// Equivalent locations (mirrors), resolved when the window opened
        /// so it follows the current ranking.
        let candidates: [URL]
        var start: Int64
        var buffer = Data()
        var end: Int64 { start + Int64(buffer.count) }
        var waiters: [Waiter] = []
        var task: URLSessionDataTask?
        var taskRejected = false
        var taskReceivedBytes = false
        var candidateIndex = 0
        var failuresWithoutProgress = 0
        var aheadLimit: Int64
        /// Where AV's latest request into this window started. AV accepts
        /// whatever an open request is handed but then often discards it and
        /// asks again from about here, so this, not what was handed out, is
        /// its real read position. AV's request starts only move forward
        /// during playback.
        var anchor: Int64
        var served: Int64 = 0
        var eof = false
        var lastUsed = Date()
        /// When a request first waited at `end` with no connection open.
        var starvingSince: Date?
        init(resource: Resource, candidates: [URL], start: Int64, aheadLimit: Int64) {
            self.resource = resource
            self.candidates = candidates
            self.start = start
            self.anchor = start
            self.aheadLimit = aheadLimit
        }
        var ahead: Int64 { end - anchor }
        var hasFallback: Bool { candidates.count > 1 }
        var currentURL: URL? {
            candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
        }
    }

    private final class Waiter {
        let sink: RCRangeSink
        var offset: Int64
        /// Inclusive; nil = to end of file.
        let last: Int64?
        var infoPending: Bool
        init(sink: RCRangeSink, offset: Int64, last: Int64?) {
            self.sink = sink
            self.offset = offset
            self.last = last
            self.infoPending = sink.wantsContentInfo
        }
    }

    private var resources: [String: Resource] = [:]
    private var waiterWindows: [ObjectIdentifier: Window] = [:]
    private var waiters: [ObjectIdentifier: Waiter] = [:]
    private var taskWindows: [Int: Window] = [:]
    private var engineCancelled: Set<Int> = []
    /// Requests AV cancelled before they reached `load` (headers in flight).
    private var cancelledEarly: Set<ObjectIdentifier> = []
    private var sweepScheduled = false

    /// MEDIASTREAM_RC_DEBUG=1 logs every request, window and connection.
    private static let debug = ProcessInfo.processInfo.environment["MEDIASTREAM_RC_DEBUG"] != nil
    private func log(_ message: @autoclosure () -> String) {
        if Self.debug { print("[RCReadAhead] \(message())") }
    }
    private static func mb(_ bytes: Int64) -> String { String(format: "%.1fMB", Double(bytes) / 1_048_576) }

    init(queue: DispatchQueue, configuration: URLSessionConfiguration? = nil, tuning: Tuning = Tuning()) {
        self.queue = queue
        self.tuning = tuning
        super.init()
        let config = configuration ?? {
            let c = URLSessionConfiguration.default
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.timeoutIntervalForRequest = 60
            c.timeoutIntervalForResource = 0
            c.urlCache = nil
            return c
        }()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    private var invalidated = false

    /// Ends the session; nothing is reported or retried afterwards (tests).
    func invalidate() {
        queue.sync { invalidated = true }
        session.invalidateAndCancel()
    }

    // MARK: - Requests (on `queue`)

    /// Whether `url` already has state (so its headers needn't be fetched).
    func knows(_ url: URL) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return resources[url.absoluteString] != nil
    }

    /// Serve bytes `lower...upper` (`upper == nil`: to end of file) of `url`
    /// to `sink`. `headers` are used when this is the first request for
    /// `url`. Must be called on `queue`.
    func load(sink: RCRangeSink, url: URL, lower: Int64, upper: Int64?, headers: [String: String]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let id = ObjectIdentifier(sink)
        if cancelledEarly.remove(id) != nil { return }

        let key = url.absoluteString
        let resource: Resource
        if let existing = resources[key] {
            resource = existing
        } else {
            resource = Resource(url: url, headers: headers)
            resources[key] = resource
        }
        resource.lastActivity = Date()
        scheduleSweep()

        let waiter = Waiter(sink: sink, offset: max(0, lower), last: upper)

        // Already-known answers need no network at all.
        if resource.infoKnown {
            if waiter.infoPending {
                sink.fillContentInfo(contentType: resource.contentType, length: resource.contentLength)
                waiter.infoPending = false
            }
            if !sink.hasDataRequest || (resource.contentLength.map { waiter.offset >= $0 } ?? false) {
                sink.finish(error: nil)
                return
            }
        }

        let window = window(for: waiter.offset, in: resource)
        log("load \(waiter.offset)-\(upper.map(String.init) ?? "") → window \(Self.mb(window.start))..\(Self.mb(window.end)) task=\(window.task != nil) windows=\(resource.windows.count)")
        window.waiters.append(waiter)
        window.anchor = max(window.anchor, waiter.offset)
        window.lastUsed = Date()
        waiters[id] = waiter
        waiterWindows[id] = window
        serve(window)
        pump(window)
    }

    /// AV no longer wants `sink`'s bytes. Must be called on `queue`.
    func cancel(sink: RCRangeSink) {
        dispatchPrecondition(condition: .onQueue(queue))
        let id = ObjectIdentifier(sink)
        guard let window = waiterWindows.removeValue(forKey: id) else {
            cancelledEarly.insert(id)
            return
        }
        waiters.removeValue(forKey: id)
        window.waiters.removeAll { $0.sink === sink }
        log("cancel; window \(Self.mb(window.start))..\(Self.mb(window.end)) ahead=\(Self.mb(window.ahead)) limit=\(Self.mb(window.aheadLimit))")
        window.lastUsed = Date()
        // The window deliberately keeps reading: AV re-requests from about
        // here a moment later.
        pump(window)
    }

    // MARK: - Windows

    private func window(for offset: Int64, in resource: Resource) -> Window {
        let joinable = resource.windows.filter {
            $0.start <= offset && offset <= $0.end + tuning.joinGap && !($0.eof && offset > $0.end)
        }
        if let best = joinable.max(by: { $0.end < $1.end }) { return best }

        // Make room: drop idle windows, least recently used first.
        if resource.windows.count >= tuning.maxWindowsPerResource {
            let idle = resource.windows.filter { $0.waiters.isEmpty }.sorted { $0.lastUsed < $1.lastUsed }
            for victim in idle.prefix(resource.windows.count - tuning.maxWindowsPerResource + 1) {
                drop(victim)
            }
        }
        let window = Window(resource: resource, candidates: RCStreamRouting.resolve(resource.url),
                            start: offset, aheadLimit: tuning.initialAhead)
        resource.windows.append(window)
        return window
    }

    private func drop(_ window: Window) {
        stopUpstream(window)
        window.resource.windows.removeAll { $0 === window }
        window.buffer = Data()
    }

    /// Hand every waiter what the window holds for it; finish the satisfied.
    private func serve(_ window: Window) {
        let resource = window.resource
        for waiter in window.waiters {
            if waiter.infoPending {
                guard resource.infoKnown else { continue }
                waiter.sink.fillContentInfo(contentType: resource.contentType, length: resource.contentLength)
                waiter.infoPending = false
            }
            guard waiter.sink.hasDataRequest else { continue }
            let limit = waiter.last.map { min(window.end, $0 + 1) } ?? window.end
            if waiter.offset >= window.start, waiter.offset < limit {
                let from = Int(waiter.offset - window.start)
                let to = Int(limit - window.start)
                waiter.sink.respond(with: window.buffer.subdata(in: from..<to))
                window.served += limit - waiter.offset
                waiter.offset = limit
            }
        }
        // Finish whoever is complete.
        let done = window.waiters.filter { waiter in
            if waiter.infoPending { return false }
            if !waiter.sink.hasDataRequest { return true }
            if let last = waiter.last, waiter.offset > last { return true }
            if let length = resource.contentLength, waiter.offset >= length { return true }
            return window.eof && waiter.offset >= window.end
        }
        for waiter in done {
            remove(waiter, from: window)
            waiter.sink.finish(error: nil)
        }

        // Being consumed: allow a deeper read-ahead.
        while window.served > window.aheadLimit / 2 && window.aheadLimit < tuning.maxAhead {
            window.aheadLimit = min(window.aheadLimit * 2, tuning.maxAhead)
        }
        trim(window)
    }

    private func remove(_ waiter: Waiter, from window: Window) {
        let id = ObjectIdentifier(waiter.sink)
        waiters.removeValue(forKey: id)
        waiterWindows.removeValue(forKey: id)
        window.waiters.removeAll { $0 === waiter }
    }

    /// Drop bytes well behind every reader. Done in steps, not per chunk,
    /// so the buffer isn't re-copied constantly.
    private func trim(_ window: Window) {
        let lowest = window.waiters.map(\.offset).min().map { min($0, window.anchor) } ?? window.anchor
        let keepFrom = lowest - tuning.keepBehind
        let excess = keepFrom - window.start
        guard excess > max(tuning.keepBehind, 4 << 20) else { return }
        window.buffer = window.buffer.subdata(in: Int(excess)..<window.buffer.count)
        window.start += excess
    }

    // MARK: - Upstream

    /// Start, keep or stop the window's upstream connection.
    private func pump(_ window: Window) {
        guard window.resource.windows.contains(where: { $0 === window }) else { return }
        if let length = window.resource.contentLength, window.end >= length { window.eof = true }
        let wanted = !window.waiters.isEmpty
        let recent = Date().timeIntervalSince(window.lastUsed) < tuning.idleStopAfter

        if window.task != nil {
            if !wanted && (window.ahead >= window.aheadLimit || !recent) {
                stopUpstream(window)
            }
            return
        }
        guard !window.eof else { return }

        // Reopen once half the read-ahead is used, so the reopen's latency
        // hides behind what's still buffered.
        if (wanted || recent) && window.ahead < window.aheadLimit / 2 {
            startUpstream(window)
            return
        }
        // Content info is only learned from a response.
        if window.waiters.contains(where: { $0.infoPending }) && !window.resource.infoKnown {
            startUpstream(window)
            return
        }
        // A request waiting at the window's end while plenty is buffered
        // behind it is usually AV over-asking: it takes what it's handed,
        // cancels, and asks again further on. Reopen only if it is still
        // waiting a moment later.
        let starving = window.waiters.contains { $0.sink.hasDataRequest && $0.offset >= window.end }
        if !starving {
            window.starvingSince = nil
        } else if let since = window.starvingSince {
            if Date().timeIntervalSince(since) >= tuning.starvingGrace {
                window.starvingSince = nil
                startUpstream(window)
            }
        } else {
            window.starvingSince = Date()
            queue.asyncAfter(deadline: .now() + tuning.starvingGrace) { [weak self, weak window] in
                guard let self, let window else { return }
                self.pump(window)
            }
        }
    }

    private func startUpstream(_ window: Window) {
        // A task on an invalidated session raises an exception.
        guard !invalidated else { return }
        guard let url = window.currentURL else {
            fail(window, error: URLError(.badURL))
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if window.hasFallback {
            request.timeoutInterval = RCStreamRouting.failoverRequestTimeout
        }
        request.setValue("bytes=\(window.end)-", forHTTPHeaderField: "Range")
        for (key, value) in window.resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.dataTask(with: request)
        log("open bytes=\(window.end)- waiters=\(window.waiters.count) ahead=\(Self.mb(window.ahead))")
        window.task = task
        window.taskRejected = false
        window.taskReceivedBytes = false
        taskWindows[task.taskIdentifier] = window
        task.resume()
    }

    private func stopUpstream(_ window: Window) {
        guard let task = window.task else { return }
        log("close at \(Self.mb(window.end)) ahead=\(Self.mb(window.ahead)) limit=\(Self.mb(window.aheadLimit))")
        engineCancelled.insert(task.taskIdentifier)
        taskWindows.removeValue(forKey: task.taskIdentifier)
        window.task = nil
        task.cancel()
    }

    /// Every candidate failed: fail the window's requests and forget it, so
    /// AV's retry starts clean.
    private func fail(_ window: Window, error: Error) {
        let pending = window.waiters
        for waiter in pending { remove(waiter, from: window) }
        drop(window)
        for waiter in pending { waiter.sink.finish(error: error) }
    }

    private func handleResponse(_ task: URLSessionDataTask, response: URLResponse) -> Bool {
        guard let window = taskWindows[task.taskIdentifier], window.task === task else { return false }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        // An error page isn't media, and a 200 to a mid-file range would put
        // the file's start where AV expects later bytes.
        if status >= 400 || (status == 200 && window.end > 0) {
            window.taskRejected = true
            return false
        }
        let resource = window.resource
        if let http {
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = range.split(separator: "/").last, let length = Int64(total) {
                resource.contentLength = length
            } else if status == 200, let text = http.value(forHTTPHeaderField: "Content-Length"),
                      let length = Int64(text) {
                resource.contentLength = length
            }
            if let type = http.value(forHTTPHeaderField: "Content-Type") {
                resource.contentType = type
            }
        }
        resource.infoKnown = true
        if let url = window.currentURL {
            RCStreamRouting.reportSuccess?(url, 0)
        }
        serve(window)
        return true
    }

    private func handleData(_ task: URLSessionDataTask, data: Data) {
        guard !invalidated, let window = taskWindows[task.taskIdentifier], window.task === task else { return }
        window.buffer.append(data)
        window.taskReceivedBytes = true
        window.failuresWithoutProgress = 0
        serve(window)
        pump(window)
    }

    private func handleCompletion(_ task: URLSessionTask, error: Error?) {
        let id = task.taskIdentifier
        if engineCancelled.remove(id) != nil || invalidated { return }
        guard let window = taskWindows.removeValue(forKey: id), window.task === task else { return }
        window.task = nil

        // A cancellation the engine didn't ask for (the session going away)
        // says nothing about the server. A rejected response is cancelled by
        // the engine too, but is a real failure.
        let cancelled = (error as? URLError)?.code == .cancelled
        if cancelled && !window.taskRejected { return }
        let failed = window.taskRejected || error != nil
        guard failed else {
            // An open-ended range that completes normally reached the end.
            window.eof = true
            serve(window)
            return
        }

        if let url = window.currentURL { RCStreamRouting.reportFailure?(url) }
        if !window.taskReceivedBytes { window.failuresWithoutProgress += 1 }
        if window.failuresWithoutProgress >= window.candidates.count {
            // Each candidate has failed in turn without delivering a byte.
            // Only bother AV when it's waiting; otherwise just stop reading.
            if window.waiters.isEmpty {
                drop(window)
            } else {
                let status = window.taskRejected
                    ? NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable,
                              userInfo: [NSLocalizedDescriptionKey: "The media server returned an error"])
                    : (error ?? URLError(.cannotConnectToHost))
                fail(window, error: status)
            }
            return
        }
        // Resume the same bytes on the next copy (or, with a single copy that
        // was making progress, on the same one).
        window.candidateIndex = (window.candidateIndex + 1) % window.candidates.count
        pump(window)
    }

    // MARK: - Housekeeping

    private func scheduleSweep() {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.sweep() }
    }

    private func sweep() {
        sweepScheduled = false
        let now = Date()
        for (key, resource) in resources {
            let busy = resource.windows.contains { !$0.waiters.isEmpty }
            if !busy && now.timeIntervalSince(resource.lastActivity) > tuning.forgetAfter {
                for window in resource.windows { drop(window) }
                resources.removeValue(forKey: key)
                continue
            }
            for window in resource.windows { pump(window) }
        }
        if !resources.isEmpty { scheduleSweep() }
    }
}

// MARK: - URLSession delegate (runs on `queue`)

extension RCReadAheadEngine: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if MediaStreamConfiguration.evaluateServerTrust(serverTrust, host: challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(handleResponse(dataTask, response: response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handleData(dataTask, data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handleCompletion(task, error: error)
    }
}
