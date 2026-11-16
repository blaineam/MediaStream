//
//  DirectStreamingResourceLoader.swift
//  MediaStream
//
//  Streams a remote file to AVPlayer with NO local HTTP server.
//
//  The RC route (`RCStreamingResourceLoader`) fetches over a localhost HTTPS
//  server. That server is a listener socket inside the app process, and iOS
//  does not keep it alive once the app is suspended, so streamed audio stops
//  when the app goes to the background. This loader instead asks the host app
//  for byte ranges directly (for Enter Space: an in-process librclone ranged
//  read), so playback only depends on the app process being allowed to run —
//  which an active `.playback` audio session guarantees.
//
//  URL shape: `espace-direct:///<remote>/<path>` (see `DirectStreamingURL`).
//  The remote name may contain spaces/uppercase, so it lives in the path, not
//  the host. The extension is preserved so AVFoundation can sniff the type.
//
//  Host contract: set `MediaStreamConfiguration.directRangeReader` and
//  `directSizeProvider`; hand `DirectStreamingURL.make(remote:path:)` URLs to
//  any `MediaItem` and the existing `AVURLAsset.makeForRCStream` call sites
//  route them here.
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Sentinel scheme for assets served by `DirectStreamingResourceLoader`.
public let DirectStreamingScheme = "espace-direct"

/// Builds and parses `espace-direct:///<remote>/<path>` URLs.
public enum DirectStreamingURL {
    public static func make(remote: String, path: String) -> URL? {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var c = URLComponents()
        c.scheme = DirectStreamingScheme
        c.host = ""
        c.path = "/" + remote + "/" + clean
        return c.url
    }

    public static func parse(_ url: URL) -> (remote: String, path: String)? {
        guard url.scheme == DirectStreamingScheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let p = c.path.hasPrefix("/") ? String(c.path.dropFirst()) : c.path
        guard let slash = p.firstIndex(of: "/") else { return nil }
        let remote = String(p[..<slash])
        let path = String(p[p.index(after: slash)...])
        guard !remote.isEmpty, !path.isEmpty else { return nil }
        return (remote, path)
    }
}

/// Measured read speed, shared by every request of the loader, used to size the next chunk so a chunk
/// takes about `targetSeconds` whatever the link: a fast LAN gets 2 MB reads, a 10 Mbps upstream shared
/// with a whole office gets ~100 KB reads that finish well inside a timeout instead of being retried.
public final class StreamThroughputEstimator: @unchecked Sendable {
    public static let targetSeconds: Double = 3
    public static let minChunk: Int64 = 64 * 1024
    public static let maxChunk: Int64 = 2 * 1024 * 1024
    public static let firstChunk: Int64 = 128 * 1024

    private let lock = NSLock()
    private var bytesPerSecond: Double?

    public init() {}

    public func record(bytes: Int, seconds: Double) {
        guard bytes >= 16 * 1024, seconds > 0 else { return }
        let sample = Double(bytes) / seconds
        lock.withLock { bytesPerSecond = bytesPerSecond.map { 0.6 * $0 + 0.4 * sample } ?? sample }
    }

    /// A failure means the link is worse than it looked: halve the estimate.
    public func recordFailure() {
        lock.withLock { bytesPerSecond = bytesPerSecond.map { $0 * 0.5 } }
    }

    public var estimate: Double? { lock.withLock { bytesPerSecond } }

    public func chunkLength(remaining: Int64) -> Int64 {
        let wanted: Int64 = lock.withLock {
            guard let bps = bytesPerSecond else { return Self.firstChunk }
            return Int64(bps * Self.targetSeconds)
        }
        return min(remaining, max(Self.minChunk, min(Self.maxChunk, wanted)))
    }
}

/// Pure, AV-free helpers so the interesting logic is unit-testable.
enum DirectStreamingPlanner {
    /// Chunk sizes grow so playback starts fast (small first read) but a long
    /// sequential read amortises per-request latency on slow remotes.
    static let chunkSteps: [Int64] = [256 * 1024, 512 * 1024, 1024 * 1024, 2 * 1024 * 1024]

    /// Size of the `index`th chunk of a request, never past `remaining`.
    static func chunkLength(index: Int, remaining: Int64) -> Int64 {
        let step = chunkSteps[min(index, chunkSteps.count - 1)]
        return min(step, remaining)
    }

    /// Half-open byte window `[start, end)` an AV data request covers.
    /// Returns nil when nothing needs to be read.
    static func window(requestedOffset: Int64, requestedLength: Int,
                       toEnd: Bool, size: Int64?) -> (start: Int64, end: Int64)? {
        let start = max(0, requestedOffset)
        var end: Int64
        if toEnd {
            guard let size else { return nil }
            end = size
        } else {
            let (sum, overflow) = start.addingReportingOverflow(Int64(requestedLength))
            end = overflow ? Int64.max : sum
            if let size { end = min(end, size) }
        }
        return end > start ? (start, end) : nil
    }

    /// UTI string AVFoundation wants for `contentType`, from the extension.
    static func contentType(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        let overrides = ["mp3": "public.mp3", "m4a": "com.apple.m4a-audio",
                         "aac": "public.aac-audio", "flac": "org.xiph.flac",
                         "wav": "com.microsoft.waveform-audio", "aiff": "public.aiff-audio",
                         "mp4": "public.mpeg-4", "m4v": "com.apple.m4v-video",
                         "mov": "com.apple.quicktime-movie"]
        if let o = overrides[ext] { return o }
        return UTType(filenameExtension: ext)?.identifier
    }

    /// Reads `[start, end)` in growing chunks, handing each to `deliver`
    /// (which AV consumes) and checking `isCancelled` between chunks.
    /// A short read before `end` means EOF/shrunk file: the stream stops
    /// rather than spinning.
    static func stream(start: Int64, end: Int64,
                       estimator: StreamThroughputEstimator? = nil,
                       reader: (Int64, Int64) async throws -> Data,
                       isCancelled: () -> Bool,
                       deliver: (Data) -> Void) async throws {
        var offset = start
        var index = 0
        while offset < end {
            if isCancelled() || Task.isCancelled { return }
            let remaining = end - offset
            let want = estimator?.chunkLength(remaining: remaining) ?? chunkLength(index: index, remaining: remaining)
            let began = Date()
            let data: Data
            do {
                data = try await reader(offset, want)
            } catch {
                estimator?.recordFailure()
                throw error
            }
            estimator?.record(bytes: data.count, seconds: Date().timeIntervalSince(began))
            if isCancelled() || Task.isCancelled { return }
            if data.isEmpty { return }
            deliver(data)
            offset += Int64(data.count)
            index += 1
        }
    }
}

public final class DirectStreamingResourceLoader: NSObject, @unchecked Sendable {
    public static let shared = DirectStreamingResourceLoader()
    public let queue = DispatchQueue(label: "com.mediastream.directLoader", qos: .userInitiated)

    /// How far one OPEN-ENDED request ("from here to the end of the file") reads before it is completed.
    /// AVFoundation asks for the whole rest of the file and then plays it at its own pace; answering all of
    /// it at once pulled entire files over whatever the link was — on a 10 Mbps upstream shared with an
    /// office that starved everyone. Completing the request early is fine: AVPlayer asks again from where it
    /// stopped, when its buffer needs more, so the download follows playback instead of racing ahead of it.
    public static var maxBytesPerOpenEndedRequest: Int64 = 3 * 1024 * 1024

    private let throughput = StreamThroughputEstimator()
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var cancelled = Set<ObjectIdentifier>()
    private var sizeCache: [URL: Int64] = [:]

    private func size(for url: URL, remote: String, path: String) async throws -> Int64? {
        if let cached = lock.withLock({ sizeCache[url] }) { return cached }
        guard let provider = MediaStreamConfiguration.directSizeProvider else { return nil }
        guard let s = try await provider(remote, path) else { return nil }
        lock.withLock { sizeCache[url] = s }
        return s
    }

    private func isCancelled(_ id: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(id)
    }

    private func finish(_ id: ObjectIdentifier) {
        lock.lock(); tasks[id] = nil; cancelled.remove(id); lock.unlock()
    }

    private func fail(_ request: AVAssetResourceLoadingRequest, _ message: String) {
        request.finishLoading(with: NSError(domain: "DirectStreamingResourceLoader", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

extension DirectStreamingResourceLoader: AVAssetResourceLoaderDelegate {
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url,
              let (remote, path) = DirectStreamingURL.parse(url) else {
            fail(loadingRequest, "Not a direct streaming URL")
            return true
        }
        guard let reader = MediaStreamConfiguration.directRangeReader else {
            fail(loadingRequest, "No direct range reader configured")
            return true
        }
        let id = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(id) }
            do {
                let size = try await self.size(for: url, remote: remote, path: path)
                if let info = loadingRequest.contentInformationRequest {
                    guard let size else {
                        self.fail(loadingRequest, "File not found: \(path)")
                        return
                    }
                    info.contentType = DirectStreamingPlanner.contentType(forPath: path)
                    info.contentLength = size
                    info.isByteRangeAccessSupported = true
                }
                if let data = loadingRequest.dataRequest {
                    let start = data.currentOffset > 0 ? data.currentOffset : data.requestedOffset
                    // A to-end request reports an enormous `requestedLength`; adding it to the offset
                    // overflowed (a trap) for any request that does not start at 0 — i.e. every seek.
                    let remainingLength: Int = {
                        if data.requestsAllDataToEndOfResource { return 0 }
                        let (end, overflow) = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                        let length = overflow ? Int64(Int.max) : end - start
                        return Int(clamping: max(0, length))
                    }()
                    if let w = DirectStreamingPlanner.window(
                        requestedOffset: start, requestedLength: remainingLength,
                        toEnd: data.requestsAllDataToEndOfResource, size: size) {
                        let end = data.requestsAllDataToEndOfResource
                            ? min(w.end, w.start + Self.maxBytesPerOpenEndedRequest) : w.end
                        try await DirectStreamingPlanner.stream(
                            start: w.start, end: end,
                            estimator: self.throughput,
                            reader: { off, len in try await reader(remote, path, off, len) },
                            isCancelled: { self.isCancelled(id) },
                            deliver: { data.respond(with: $0) })
                    }
                }
                if !self.isCancelled(id) { loadingRequest.finishLoading() }
            } catch {
                if !self.isCancelled(id) { loadingRequest.finishLoading(with: error) }
            }
        }
        lock.lock(); tasks[id] = task; lock.unlock()
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(loadingRequest)
        lock.lock()
        cancelled.insert(id)
        let t = tasks[id]
        lock.unlock()
        t?.cancel()
    }
}
