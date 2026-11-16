import Testing
import Foundation
@testable import MediaStream
import AVFoundation

@Suite("Direct streaming")
struct DirectStreamingTests {
    @Test("URL round-trips remotes with spaces and awkward paths")
    func urlRoundTrip() throws {
        let cases = [("PCloud Syncs", "Music/Album 1/01 Track #1 (live)?.mp3"),
                     ("B2", "a.mp3"), ("Università", "è/ñ.m4a")]
        for (remote, path) in cases {
            let url = try #require(DirectStreamingURL.make(remote: remote, path: path))
            #expect(url.scheme == DirectStreamingScheme)
            let parsed = try #require(DirectStreamingURL.parse(url))
            #expect(parsed.remote == remote)
            #expect(parsed.path == path)
        }
        #expect(DirectStreamingURL.parse(URL(string: "https://x/y/z")!) == nil)
        #expect(DirectStreamingURL.make(remote: "R", path: "/lead.mp3").flatMap(DirectStreamingURL.parse)?.path == "lead.mp3")
    }

    @Test("window clamps to size and handles to-end")
    func window() {
        let w = DirectStreamingPlanner.window(requestedOffset: 100, requestedLength: 50, toEnd: false, size: 1000)
        #expect(w?.start == 100 && w?.end == 150)
        #expect(DirectStreamingPlanner.window(requestedOffset: 990, requestedLength: 50, toEnd: false, size: 1000)?.end == 1000)
        #expect(DirectStreamingPlanner.window(requestedOffset: 10, requestedLength: 0, toEnd: true, size: 1000)?.end == 1000)
        #expect(DirectStreamingPlanner.window(requestedOffset: 1000, requestedLength: 5, toEnd: false, size: 1000) == nil)
        #expect(DirectStreamingPlanner.window(requestedOffset: 0, requestedLength: 0, toEnd: true, size: nil) == nil)
        // A request with an enormous length at an offset must not overflow (seeking in a to-end request).
        let huge = DirectStreamingPlanner.window(requestedOffset: 5_000, requestedLength: Int.max, toEnd: false, size: 1_000_000)
        #expect(huge?.start == 5_000 && huge?.end == 1_000_000)
    }

    @Test("chunks grow and cap")
    func chunks() {
        #expect(DirectStreamingPlanner.chunkLength(index: 0, remaining: 10_000_000) == 256 * 1024)
        #expect(DirectStreamingPlanner.chunkLength(index: 50, remaining: 10_000_000) == 2 * 1024 * 1024)
        #expect(DirectStreamingPlanner.chunkLength(index: 3, remaining: 10) == 10)
    }

    @Test("content types for audio")
    func contentTypes() {
        #expect(DirectStreamingPlanner.contentType(forPath: "a/b.MP3") == "public.mp3")
        #expect(DirectStreamingPlanner.contentType(forPath: "x.m4a") == "com.apple.m4a-audio")
        #expect(DirectStreamingPlanner.contentType(forPath: "noext") == nil)
    }

    final class Box: @unchecked Sendable {
        let lock = NSLock(); var out = Data(); var calls: [(Int64, Int64)] = []
        func record(_ o: Int64, _ l: Int64) { lock.withLock { calls.append((o, l)) } }
    }

    @Test("stream delivers exact bytes in order across chunks")
    func streamBytes() async throws {
        let file = Data((0..<3_000_000).map { UInt8($0 % 241) })
        let box = Box()
        try await DirectStreamingPlanner.stream(
            start: 1234, end: 2_900_000,
            reader: { off, len in
                box.record(off, len)
                return file.subdata(in: Int(off)..<Int(min(off + len, Int64(file.count))))
            },
            isCancelled: { false }, deliver: { box.out.append($0) })
        #expect(box.out == file.subdata(in: 1234..<2_900_000))
        #expect(box.calls.first.map { $0.1 } == Int64(256 * 1024), "calls=\(box.calls.prefix(3))")
        #expect(box.calls.allSatisfy { $0.1 <= 2 * 1024 * 1024 })
    }


    @Test("estimator sizes chunks to the link: fast gets big reads, a slow shared uplink gets small ones")
    func estimatorSizesChunks() {
        let e = StreamThroughputEstimator()
        #expect(e.chunkLength(remaining: 10_000_000) == StreamThroughputEstimator.firstChunk)
        for _ in 0..<10 { e.record(bytes: 2_000_000, seconds: 0.5) }          // ~4 MB/s
        #expect(e.chunkLength(remaining: 10_000_000) == StreamThroughputEstimator.maxChunk)
        let slow = StreamThroughputEstimator()
        for _ in 0..<10 { slow.record(bytes: 100_000, seconds: 1) }           // ~100 KB/s
        let chunk = slow.chunkLength(remaining: 10_000_000)
        #expect(chunk >= StreamThroughputEstimator.minChunk && chunk <= 400_000)
        slow.recordFailure()
        #expect(slow.chunkLength(remaining: 10_000_000) < chunk)
        #expect(slow.chunkLength(remaining: 1_000) == 1_000)                   // never past what remains
    }

    @Test("stream with an estimator still delivers every byte in order")
    func estimatedStreamDelivers() async throws {
        let file = Data((0..<1_500_000).map { UInt8($0 % 241) })
        let box = Box(); let e = StreamThroughputEstimator()
        try await DirectStreamingPlanner.stream(
            start: 100, end: 1_400_000, estimator: e,
            reader: { off, len in file.subdata(in: Int(off)..<Int(min(off + len, Int64(file.count)))) },
            isCancelled: { false }, deliver: { box.out.append($0) })
        #expect(box.out == file.subdata(in: 100..<1_400_000))
    }

    @Test("stream stops on cancel and on EOF short read")
    func streamStops() async throws {
        let box = Box()
        try await DirectStreamingPlanner.stream(
            start: 0, end: 10_000_000,
            reader: { _, len in Data(count: Int(len)) },
            isCancelled: { box.lock.withLock { box.out.count >= 256 * 1024 } },
            deliver: { box.out.append($0) })
        #expect(box.out.count == 256 * 1024)

        let eof = Box()
        try await DirectStreamingPlanner.stream(
            start: 0, end: 10_000_000,
            reader: { _, _ in Data() }, isCancelled: { false }, deliver: { eof.out.append($0) })
        #expect(eof.out.isEmpty)
    }

    @Test("reader errors propagate")
    func streamError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await DirectStreamingPlanner.stream(start: 0, end: 10, reader: { _, _ in throw Boom() },
                                                    isCancelled: { false }, deliver: { _ in })
        }
    }
}

// Both suites mutate the global range-reader hooks, so they run serialized under one parent.
@Suite("Direct streaming hooks", .serialized)
struct DirectStreamingHookTests {
    @Suite("Download")
    struct DirectStreamingDownloadTests {
        @Test("downloadDirect pulls the whole file through the reader")
        func downloadWholeFile() async throws {
            let file = Data((0..<5_000_000).map { UInt8($0 % 239) })
            MediaStreamConfiguration.directSizeProvider = { _, _ in Int64(file.count) }
            MediaStreamConfiguration.directRangeReader = { _, _, off, len in
                file.subdata(in: Int(off)..<Int(min(off + len, Int64(file.count))))
            }
            defer { MediaStreamConfiguration.directRangeReader = nil; MediaStreamConfiguration.directSizeProvider = nil }
            let url = try #require(DirectStreamingURL.make(remote: "R", path: "m/a.mp3"))
            let temp = try await MediaDownloadManager.downloadDirect(url) { _, _ in }
            defer { try? FileManager.default.removeItem(at: temp) }
            #expect(try Data(contentsOf: temp) == file)
        }
    }

    @Suite("AVFoundation")
    struct DirectStreamingAVTests {
        static func wav(seconds: Int, rate: Int = 8000) -> Data {
            let samples = seconds * rate
            var d = Data()
            func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
            func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
            d.append("RIFF".data(using: .ascii)!); u32(36 + samples * 2)
            d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
            d.append("data".data(using: .ascii)!); u32(samples * 2)
            for i in 0..<samples { u16(Int(Double(i % 80) / 80 * 20000)) }
            return d
        }

        @Test("AVURLAsset loads duration and tracks through the direct loader")
        func assetLoads() async throws {
            let file = Self.wav(seconds: 3)
            let log = Box2()
            MediaStreamConfiguration.directSizeProvider = { r, p in log.add("size \(r):\(p)"); return Int64(file.count) }
            MediaStreamConfiguration.directRangeReader = { r, p, off, len in
                log.add("read \(off)+\(len)")
                return file.subdata(in: Int(off)..<Int(min(off + len, Int64(file.count))))
            }
            defer { MediaStreamConfiguration.directRangeReader = nil; MediaStreamConfiguration.directSizeProvider = nil }
            let url = try #require(DirectStreamingURL.make(remote: "My Remote", path: "Music/tone.wav"))
            let asset = AVURLAsset.makeForRCStream(url: url)
            let duration = try await asset.load(.duration)
            #expect(abs(CMTimeGetSeconds(duration) - 3.0) < 0.1)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(tracks.count == 1)
            #expect(log.items.contains { $0.hasPrefix("size My Remote:Music/tone.wav") })
            #expect(log.items.contains { $0.hasPrefix("read ") })
        }

        @Test("AVFoundation keeps asking when open-ended requests are completed early (download follows playback)")
        func windowedOpenEndedRequestsStillPlayThrough() async throws {
            let file = Self.wav(seconds: 4)            // 64,000 bytes of PCM
            let reads = Box2()
            MediaStreamConfiguration.directSizeProvider = { _, _ in Int64(file.count) }
            MediaStreamConfiguration.directRangeReader = { _, _, off, len in
                reads.add("\(off)+\(len)")
                return file.subdata(in: Int(off)..<Int(min(off + len, Int64(file.count))))
            }
            let previous = DirectStreamingResourceLoader.maxBytesPerOpenEndedRequest
            DirectStreamingResourceLoader.maxBytesPerOpenEndedRequest = 16 * 1024   // far smaller than the file
            defer {
                DirectStreamingResourceLoader.maxBytesPerOpenEndedRequest = previous
                MediaStreamConfiguration.directRangeReader = nil; MediaStreamConfiguration.directSizeProvider = nil
            }
            let url = try #require(DirectStreamingURL.make(remote: "R", path: "tone.wav"))
            let asset = AVURLAsset.makeForRCStream(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            #expect(reader.startReading())
            var bytes = 0
            while let sample = output.copyNextSampleBuffer() { bytes += CMSampleBufferGetTotalSampleSize(sample) }
            #expect(bytes >= 60_000, "decoded \(bytes) of ~64000 PCM bytes; reads: \(reads.items.count)")
            #expect(reader.status == .completed)
        }

        @Test("missing file fails the asset instead of hanging")
        func missingFails() async throws {
            MediaStreamConfiguration.directSizeProvider = { _, _ in nil }
            MediaStreamConfiguration.directRangeReader = { _, _, _, _ in Data() }
            defer { MediaStreamConfiguration.directRangeReader = nil; MediaStreamConfiguration.directSizeProvider = nil }
            let url = try #require(DirectStreamingURL.make(remote: "R", path: "nope.mp3"))
            let asset = AVURLAsset.makeForRCStream(url: url)
            await #expect(throws: (any Error).self) { _ = try await asset.load(.duration) }
        }

        final class Box2: @unchecked Sendable {
            let l = NSLock(); private var a: [String] = []
            func add(_ s: String) { l.withLock { a.append(s) } }
            var items: [String] { l.withLock { a } }
        }
    }

}

@Suite("Background playable", .serialized)
struct BackgroundPlayableTests {
    struct Audio: MediaItem {
        let id = UUID(); let type: MediaType; var sourceURL: URL? { URL(string: "https://example.com/never-cached-\(id).mp3") }
        init(_ t: MediaType) { type = t }
        func loadImage() async -> PlatformImage? { nil }
        func loadThumbnail(targetSize: CGFloat) async -> PlatformImage? { nil }
        func loadVideoURL() async -> URL? { nil }
        func loadAudioURL() async -> URL? { nil }
        func getAnimatedImageDuration() async -> TimeInterval? { nil }
        func getVideoDuration() async -> TimeInterval? { nil }
        func getAudioDuration() async -> TimeInterval? { nil }
        func getAudioMetadata() async -> AudioMetadata? { nil }
        func getShareableItem() async -> Any? { nil }
        func getCaption() async -> String? { nil }
        func hasAudioTrack() async -> Bool { true }
    }

    @MainActor @Test("direct audio may play in the background; direct flag does not widen video")
    func playable() {
        let m = MediaDownloadManager.shared
        MediaStreamConfiguration.directAudioStreaming = false
        #expect(!m.isBackgroundPlayable(mediaItem: Audio(.audio)))
        MediaStreamConfiguration.directAudioStreaming = true
        defer { MediaStreamConfiguration.directAudioStreaming = false }
        #expect(m.isBackgroundPlayable(mediaItem: Audio(.audio)))
        #expect(!m.isBackgroundPlayable(mediaItem: Audio(.video)))
    }

    @MainActor @Test("encrypt-downloads no longer turns background audio off; streamed audio still plays in the background")
    func encryptDownloadsDoesNotBlockStreamedAudio() {
        let wasEncrypt = MediaStreamConfiguration.encryptDownloads
        let wasBackground = MediaStreamConfiguration.backgroundAudioEnabled
        defer {
            MediaStreamConfiguration.encryptDownloads = wasEncrypt
            MediaStreamConfiguration.backgroundAudioEnabled = wasBackground
            MediaStreamConfiguration.directAudioStreaming = false
        }
        MediaStreamConfiguration.encryptDownloads = true
        MediaStreamConfiguration.backgroundAudioEnabled = true
        MediaStreamConfiguration.directAudioStreaming = true
        #expect(MediaStreamConfiguration.backgroundAudioEnabled)
        #expect(MediaDownloadManager.shared.isBackgroundPlayable(mediaItem: Audio(.audio)))
        #expect(!MediaDownloadManager.shared.isBackgroundPlayable(mediaItem: Audio(.video)))
    }
}
