import Testing
import Foundation
@testable import MediaStream

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

@Suite("Direct streaming download", .serialized)
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
