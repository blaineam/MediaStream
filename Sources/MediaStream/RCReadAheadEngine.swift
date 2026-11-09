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
//  So the engine fetches on its own schedule, decoupled from AV's requests:
//
//  * Per resource (URL) it keeps up to a few **windows**: contiguous runs of
//    bytes. A window starts with one open-ended fetch (`bytes=N-`), so the
//    first bytes flow after a single time-to-first-byte. Bounded fetches
//    (chunks) then run alongside it further ahead, a few at a time, and the
//    open-ended one is capped where the first chunk begins. A server whose
//    single connection is slower than the video's bitrate still keeps up,
//    and each chunk's time-to-first-byte overlaps the others' transfers.
//    Chunks are joined in order as they arrive.
//  * An AV request that starts inside a window (or inside what it is
//    fetching, or just past that) is served from memory and then fed as the
//    chunks land. No request of its own, no time-to-first-byte of its own.
//  * A window keeps fetching AHEAD after AV cancels, up to a limit that
//    starts small (a thumbnail costs little) and doubles as the window is
//    consumed (sequential playback), capped at `maxAhead`. Chunks grow with
//    the limit.
//  * Bytes far behind the read position are dropped.
//  * A failed or stalled chunk (transport error, HTTP error status, idle
//    past `RCStreamRouting.failoverRequestTimeout` when there is an
//    alternative) resumes where it stopped on the next candidate from
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
        /// Chunks fetched at once per window.
        var parallelFetches = 4
        /// Chunk size bounds; between them a chunk is a quarter of the
        /// window's current read-ahead limit.
        var minChunk: Int64 = 1 << 20
        var maxChunk: Int64 = 8 << 20
        /// How far ahead of an open-ended fetch the first chunk starts, in
        /// bounds. It is already flowing, so it carries playback while the
        /// chunks pay their time-to-first-byte: the lead is what it moves in
        /// 1.5 of those, measured. Too long a lead and a slow connection
        /// carries playback alone; too short and nothing covers the wait.
        var minOpenEndedLead: Int64 = 2 << 20
        var maxOpenEndedLead: Int64 = 16 << 20
        /// How long an open-ended fetch runs before its speed is trusted.
        var measureFor: TimeInterval = 0.5
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
        /// Measured time-to-first-byte (smoothed), seconds.
        var ttfb: TimeInterval?
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
        /// Chunks in flight or waiting to be joined, in byte order.
        var fetches: [Fetch] = []
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
        init(resource: Resource, candidates: [URL], start: Int64, aheadLimit: Int64) {
            self.resource = resource
            self.candidates = candidates
            self.start = start
            self.anchor = start
            self.aheadLimit = aheadLimit
        }
        var ahead: Int64 { end - anchor }
        /// End of what is buffered or being fetched. An open-ended fetch
        /// counts up to where it has got.
        var plannedEnd: Int64 {
            fetches.map { $0.openEnded ? $0.next : $0.stop }.max().map { max($0, end) } ?? end
        }
        var hasFallback: Bool { candidates.count > 1 }
        var currentURL: URL? {
            candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
        }
    }

    /// One bounded range fetch `[offset, stop)` of a window.
    private final class Fetch {
        unowned let window: Window
        /// First byte not yet joined to the window (start of `pending`).
        var offset: Int64
        /// Exclusive end; lowered to the file's length once that is known.
        var stop: Int64
        /// Requested as `bytes=N-` and not yet capped: it reserves only
        /// `next + chunk` for planning, and is capped (`stop` set, connection
        /// closed on reaching it) when a chunk is planned after it.
        var openEnded = false
        /// Received but not yet contiguous with the window.
        var pending = Data()
        var task: URLSessionDataTask?
        var rejected = false
        var receivedBytes = false
        var startedAt = Date()
        var firstByteAt: Date?
        var bytesSinceFirst: Int64 = 0
        /// Measured transfer rate, bytes/s, once it has run long enough.
        func rate(after warmup: TimeInterval) -> Double? {
            guard let firstByteAt else { return nil }
            let elapsed = Date().timeIntervalSince(firstByteAt)
            return elapsed >= warmup ? Double(bytesSinceFirst) / elapsed : nil
        }
        init(window: Window, offset: Int64, stop: Int64) {
            self.window = window
            self.offset = offset
            self.stop = stop
        }
        /// Where a restart resumes.
        var next: Int64 { offset + Int64(pending.count) }
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
    private var taskFetches: [Int: Fetch] = [:]
    private var engineCancelled: Set<Int> = []
    /// Requests AV cancelled before they reached `load` (headers in flight).
    private var cancelledEarly: Set<ObjectIdentifier> = []
    private var sweepScheduled = false

    /// MEDIASTREAM_RC_DEBUG=1 logs every request, window and connection.
    private static let debug = ProcessInfo.processInfo.environment["MEDIASTREAM_RC_DEBUG"] != nil
    private func log(_ message: @autoclosure () -> String) {
        if Self.debug { print(String(format: "[RCReadAhead %.2f] ", Date().timeIntervalSince(Self.debugEpoch)) + message()) }
    }
    private static let debugEpoch = Date()
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
            // Room for every window's parallel fetches (iOS defaults to 4).
            c.httpMaximumConnectionsPerHost = 8
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
        log("load \(waiter.offset)-\(upper.map(String.init) ?? "") → window \(Self.mb(window.start))..\(Self.mb(window.end)) fetching=\(window.fetches.count) windows=\(resource.windows.count)")
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
            $0.start <= offset && offset <= $0.plannedEnd + tuning.joinGap && !($0.eof && offset > $0.end)
        }
        if let best = joinable.max(by: { $0.plannedEnd < $1.plannedEnd }) { return best }

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
        stopFetches(window)
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
        // A request can start past the buffered end (it joined bytes still
        // being fetched), so never trim past the buffer itself.
        let excess = min(keepFrom - window.start, Int64(window.buffer.count))
        guard excess > max(tuning.keepBehind, 4 << 20) else { return }
        window.buffer = window.buffer.subdata(in: Int(excess)..<window.buffer.count)
        window.start += excess
    }

    // MARK: - Upstream

    private func chunkSize(_ window: Window) -> Int64 {
        min(max(window.aheadLimit / 4, tuning.minChunk), tuning.maxChunk)
    }

    /// Start chunks the window needs, or stop fetching for an idle window.
    private func pump(_ window: Window) {
        guard !invalidated, window.resource.windows.contains(where: { $0 === window }) else { return }
        let resource = window.resource
        if let length = resource.contentLength, window.end >= length { window.eof = true }
        let recent = Date().timeIntervalSince(window.lastUsed) < tuning.idleStopAfter
        if window.waiters.isEmpty && !recent {
            stopFetches(window)
            return
        }
        guard !window.eof else { return }

        // Someone is waiting for bytes past what's buffered. AV keeps an
        // open request taking whatever arrives until its own buffer is
        // full, so while it does, read on past the usual limit (bounded).
        let hungry = window.waiters.contains { $0.sink.hasDataRequest && !$0.infoPending && $0.offset >= window.end }
            || (window.waiters.contains { $0.infoPending } && !resource.infoKnown)
        let limit = hungry ? tuning.maxAhead * 2 : window.aheadLimit

        // An open-ended fetch that nobody is waiting on stops at the limit.
        if !hungry, let open = window.fetches.first(where: { $0.openEnded }),
           open.next - window.anchor >= window.aheadLimit {
            cap(open, at: open.next)
        }

        while window.fetches.filter({ $0.task != nil }).count < tuning.parallelFetches {
            // Playback (someone waiting) gets big chunks straight away.
            let chunk = hungry ? tuning.maxChunk : chunkSize(window)
            if window.fetches.isEmpty {
                // Nothing in flight: one open-ended fetch from the end.
                let from = window.end
                if let length = resource.contentLength, from >= length { return }
                guard hungry || from - window.anchor < window.aheadLimit else { return }
                let fetch = Fetch(window: window, offset: from, stop: resource.contentLength ?? .max)
                fetch.openEnded = true
                window.fetches.append(fetch)
                start(fetch)
                // Not started (no usable URL: the window was failed and dropped).
                if fetch.task == nil { return }
                continue
            }
            // Until the first answer gives the length, one fetch at a time.
            guard resource.infoKnown else { return }
            // Chunks go after what's planned; an open-ended fetch keeps a
            // lead of its own before them, since it is already flowing.
            let open = window.fetches.first { $0.openEnded }
            var lead: Int64 = 0
            if let open {
                // Wait until its speed is known (data keeps calling pump).
                guard let rate = open.rate(after: tuning.measureFor) else { return }
                let wait = resource.ttfb ?? 1
                lead = min(max(Int64(rate * wait * 1.5), tuning.minOpenEndedLead), tuning.maxOpenEndedLead)
            }
            let from = max(window.plannedEnd, open.map { $0.next + lead } ?? 0)
            if let length = resource.contentLength, from >= length { return }
            guard from - window.anchor < limit else { return }
            if let open { cap(open, at: from) }
            var stop = from + chunk
            if let length = resource.contentLength { stop = min(stop, length) }
            let fetch = Fetch(window: window, offset: from, stop: stop)
            window.fetches.append(fetch)
            start(fetch)
            if fetch.task == nil { return }
        }
    }

    /// Bound an open-ended fetch at `offset`; its connection closes when it
    /// gets there (at once if it already has).
    private func cap(_ fetch: Fetch, at offset: Int64) {
        fetch.openEnded = false
        fetch.stop = min(fetch.stop, max(offset, fetch.next))
        if fetch.next >= fetch.stop { finishEarly(fetch) }
    }

    /// Close a fetch's connection because it has everything it should.
    private func finishEarly(_ fetch: Fetch) {
        guard let task = fetch.task else { return }
        engineCancelled.insert(task.taskIdentifier)
        taskFetches.removeValue(forKey: task.taskIdentifier)
        fetch.task = nil
        task.cancel()
        drain(fetch.window)
    }

    private func start(_ fetch: Fetch) {
        // A task on an invalidated session raises an exception.
        guard !invalidated else { return }
        let window = fetch.window
        guard let url = window.currentURL else {
            fail(window, error: URLError(.badURL))
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if window.hasFallback {
            request.timeoutInterval = RCStreamRouting.failoverRequestTimeout
        }
        let range = fetch.openEnded ? "bytes=\(fetch.next)-" : "bytes=\(fetch.next)-\(fetch.stop - 1)"
        request.setValue(range, forHTTPHeaderField: "Range")
        for (key, value) in window.resource.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.dataTask(with: request)
        log("fetch \(range) waiters=\(window.waiters.count) ahead=\(Self.mb(window.ahead)) limit=\(Self.mb(window.aheadLimit))")
        fetch.task = task
        fetch.rejected = false
        fetch.receivedBytes = false
        fetch.startedAt = Date()
        fetch.firstByteAt = nil
        fetch.bytesSinceFirst = 0
        taskFetches[task.taskIdentifier] = fetch
        task.resume()
    }

    private func stopFetches(_ window: Window) {
        for fetch in window.fetches {
            guard let task = fetch.task else { continue }
            engineCancelled.insert(task.taskIdentifier)
            taskFetches.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
        if !window.fetches.isEmpty { log("stop fetching at \(Self.mb(window.end))") }
        window.fetches.removeAll()
    }

    /// Join arrived chunks to the window in byte order.
    private func drain(_ window: Window) {
        window.fetches.sort { $0.offset < $1.offset }
        while let head = window.fetches.first, head.offset == window.end {
            if !head.pending.isEmpty {
                window.buffer.append(head.pending)
                head.offset += Int64(head.pending.count)
                head.pending = Data()
            }
            guard head.offset >= head.stop, head.task == nil else { break }
            window.fetches.removeFirst()
        }
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
        guard let fetch = taskFetches[task.taskIdentifier], fetch.task === task else { return false }
        let window = fetch.window
        let resource = window.resource
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        if status == 416 {
            // Asked past the end (the length wasn't known yet).
            fetch.stop = fetch.next
            return false
        }
        // An error page isn't media, and a 200 to a mid-file range would put
        // the file's start where AV expects later bytes.
        if status >= 400 || (status == 200 && fetch.next > 0) {
            fetch.rejected = true
            return false
        }
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
        if let length = resource.contentLength {
            // Chunks planned before the length was known may lie past it.
            for other in window.fetches where other !== fetch && other.offset >= length {
                if let task = other.task {
                    engineCancelled.insert(task.taskIdentifier)
                    taskFetches.removeValue(forKey: task.taskIdentifier)
                    task.cancel()
                }
            }
            window.fetches.removeAll { $0 !== fetch && $0.offset >= length }
            for other in window.fetches { other.stop = min(other.stop, length) }
        }
        resource.infoKnown = true
        let wait = Date().timeIntervalSince(fetch.startedAt)
        resource.ttfb = resource.ttfb.map { $0 * 0.7 + wait * 0.3 } ?? wait
        if let url = window.currentURL {
            RCStreamRouting.reportSuccess?(url, 0)
        }
        serve(window)
        // The length is known now: the other chunks can start.
        pump(window)
        return true
    }

    private func handleData(_ task: URLSessionDataTask, data: Data) {
        guard !invalidated, let fetch = taskFetches[task.taskIdentifier], fetch.task === task else { return }
        let window = fetch.window
        let room = fetch.stop - fetch.next
        fetch.pending.append(Int64(data.count) > room ? data.prefix(Int(max(0, room))) : data)
        fetch.receivedBytes = true
        if fetch.firstByteAt == nil { fetch.firstByteAt = Date() } else { fetch.bytesSinceFirst += Int64(data.count) }
        if fetch.next >= fetch.stop { finishEarly(fetch) }
        window.failuresWithoutProgress = 0
        drain(window)
        serve(window)
        pump(window)
    }

    private func handleCompletion(_ task: URLSessionTask, error: Error?) {
        let id = task.taskIdentifier
        if engineCancelled.remove(id) != nil || invalidated { return }
        guard let fetch = taskFetches.removeValue(forKey: id), fetch.task === task else { return }
        let window = fetch.window
        fetch.task = nil
        guard window.resource.windows.contains(where: { $0 === window }) else { return }

        // A cancellation the engine didn't ask for (the session going away)
        // says nothing about the server. A rejected response is cancelled by
        // the engine too, but is a real failure.
        let cancelled = (error as? URLError)?.code == .cancelled
        if cancelled && !fetch.rejected && fetch.stop > fetch.next { return }
        let complete = fetch.next >= fetch.stop
        if !fetch.rejected && (error == nil || complete) {
            if !complete {
                // The server ended early: that is the end of the file.
                fetch.stop = fetch.next
                window.resource.contentLength = fetch.next
            }
            drain(window)
            serve(window)
            pump(window)
            return
        }

        if let url = window.currentURL { RCStreamRouting.reportFailure?(url) }
        if !fetch.receivedBytes { window.failuresWithoutProgress += 1 }
        if window.failuresWithoutProgress >= window.candidates.count {
            // Each candidate has failed in turn without delivering a byte.
            // Only bother AV when it's waiting; otherwise just stop reading.
            if window.waiters.isEmpty {
                drop(window)
            } else {
                let status = fetch.rejected
                    ? NSError(domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable,
                              userInfo: [NSLocalizedDescriptionKey: "The media server returned an error"])
                    : (error ?? URLError(.cannotConnectToHost))
                fail(window, error: status)
            }
            return
        }
        // Resume this chunk where it stopped on the next copy (or, with a
        // single copy that was making progress, on the same one).
        window.candidateIndex = (window.candidateIndex + 1) % window.candidates.count
        start(fetch)
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
