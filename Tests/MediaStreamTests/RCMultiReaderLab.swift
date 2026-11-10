//
//  RCMultiReaderLab.swift
//  MediaStreamTests
//
//  Manual benchmark of `RCReadAheadEngine`'s scheduling when one file is
//  read at several far-apart places at once, the way AVPlayer reads a movie
//  whose tracks are stored apart (video, audio and subtitles each advancing
//  through their own region). Skipped unless STREAMLAB_URL is set; point it
//  at `slowserver.py` serving a large file.
//
//  Reports how long requests waited for their bytes, and how many bytes the
//  engine fetched against how many the readers used.
//

import XCTest
@testable import MediaStream

final class RCMultiReaderLab: XCTestCase {

    private final class Sink: RCRangeSink, @unchecked Sendable {
        let wantsContentInfo = false
        let hasDataRequest = true
        var received = 0
        /// Open-ended mode: once this much has arrived, the reader has what
        /// it wanted (AV then cancels the request).
        var enough = Int.max
        var done: (() -> Void)?
        func fillContentInfo(contentType: String?, length: Int64?) {}
        func respond(with data: Data) {
            received += data.count
            if received >= enough, let done { self.done = nil; done() }
        }
        func finish(error: Error?) { if let done { self.done = nil; done() } }
    }

    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.withLock { _value } }
        func update(_ n: Int) { lock.withLock { _value = max(_value, n) } }
    }

    private struct Reader {
        let name: String
        let start: Int64
        /// Bytes per second the "decoder" uses.
        let rate: Double
        /// Bytes per request.
        let request: Int64
    }

    func testFarApartTracks() async throws {
        guard let raw = ProcessInfo.processInfo.environment["STREAMLAB_URL"], let url = URL(string: raw) else {
            throw XCTSkip("STREAMLAB_URL not set")
        }
        let seconds = Double(ProcessInfo.processInfo.environment["STREAMLAB_SECONDS"] ?? "40") ?? 40
        // AV's way: open-ended requests that take what arrives, cancelled
        // once it has enough, then a new one from there.
        let openEnded = ProcessInfo.processInfo.environment["MULTILAB_OPEN"] != nil
        MediaStreamConfiguration.serverTrustEvaluator = { _, _ in true }
        let queue = DispatchQueue(label: "lab")
        let engine = RCReadAheadEngine(queue: queue)
        defer { engine.invalidate() }

        // 5.5 Mbps video, 0.6 Mbps audio, a trickle of subtitles, far apart.
        let readers = [
            Reader(name: "video", start: 1 << 20, rate: 5_500_000 / 8, request: 1 << 20),
            Reader(name: "audio", start: 300 << 20, rate: 600_000 / 8, request: 256 << 10),
            Reader(name: "subs", start: 500 << 20, rate: 2_000, request: 64 << 10),
        ]

        // Sample the connection count while the readers run.
        let peak = Peak()
        let sampler = Task {
            while !Task.isCancelled {
                let n = engine.stats(for: url)?.activeConnections ?? 0
                peak.update(n)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { sampler.cancel() }
        let results = await withTaskGroup(of: (String, [Double], Int).self) { group in
            for reader in readers {
                group.addTask {
                    var waits: [Double] = []
                    var used = 0
                    var position = reader.start
                    // Each reader keeps ~10 s of its own data buffered, like AV.
                    var buffered: Double = 0
                    let begin = Date()
                    var lastTick = begin
                    while Date().timeIntervalSince(begin) < seconds {
                        let now = Date()
                        buffered = max(0, buffered - now.timeIntervalSince(lastTick))
                        lastTick = now
                        if buffered > 10 {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            continue
                        }
                        let sink = Sink()
                        let t0 = Date()
                        if openEnded { sink.enough = Int(reader.request) }
                        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                            sink.done = { done.resume() }
                            queue.async {
                                engine.load(sink: sink, url: url, lower: position,
                                            upper: openEnded ? nil : position + reader.request - 1, headers: [:])
                            }
                        }
                        if openEnded { queue.sync { engine.cancel(sink: sink) } }
                        let wait = Date().timeIntervalSince(t0)
                        waits.append(wait)
                        used += min(sink.received, Int(reader.request))
                        position += reader.request
                        buffered += Double(reader.request) / reader.rate
                        lastTick = Date()
                    }
                    return (reader.name, waits, used)
                }
            }
            var all: [(String, [Double], Int)] = []
            for await r in group { all.append(r) }
            return all
        }
        let stats = engine.stats(for: url)
        print("MULTILAB peak connections=\(peak.value)")
        for (name, waits, used) in results.sorted(by: { $0.0 < $1.0 }) {
            let sorted = waits.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
            print(String(format: "MULTILAB %@: requests=%d used=%.1fMB maxWait=%.2fs p95=%.2fs over1s=%d",
                         name, waits.count, Double(used) / 1_048_576, sorted.last ?? 0, p95,
                         waits.filter { $0 > 1 }.count))
        }
        print("MULTILAB connections at end=\(stats?.activeConnections ?? -1)")
    }
}
