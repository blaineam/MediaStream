//
//  RCStreamPlaybackLab.swift
//  MediaStreamTests
//
//  Manual playback benchmark for `RCStreamingResourceLoader` against a
//  slow, high-latency HTTPS server (e.g. one that mimics rclone serving a
//  cloud remote). Skipped unless STREAMLAB_URL is set:
//
//    STREAMLAB_URL=https://127.0.0.1:8443/fast.mp4 swift test --filter RCStreamPlaybackLab
//
//  Reports time to first frame, stalls during STREAMLAB_SECONDS of play,
//  and time to resume after a seek.
//

import XCTest
import AVFoundation
@testable import MediaStream

final class RCStreamPlaybackLab: XCTestCase {

    func testPlaybackThroughLoader() async throws {
        guard let raw = ProcessInfo.processInfo.environment["STREAMLAB_URL"],
              let url = URL(string: raw) else {
            throw XCTSkip("STREAMLAB_URL not set")
        }
        let seconds = Double(ProcessInfo.processInfo.environment["STREAMLAB_SECONDS"] ?? "30") ?? 30
        MediaStreamConfiguration.serverTrustEvaluator = { _, _ in true }

        let result = try await MainActor.run { () -> Task<String, Error> in
            Task { @MainActor in try await Self.run(url: url, seconds: seconds) }
        }.value
        print("STREAMLAB \(result)")
    }

    @MainActor
    private static func run(url: URL, seconds: Double) async throws -> String {
        let asset = AVURLAsset.makeForRCStream(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        var stalls = 0
        let stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
            MainActor.assumeIsolated { stalls += 1 }
        }
        defer { NotificationCenter.default.removeObserver(stallObserver) }

        let t0 = Date()
        player.play()
        try await waitUntil(timeout: 60) { player.timeControlStatus == .playing && player.currentTime().seconds > 0 }
        let start = Date().timeIntervalSince(t0)

        // Play, counting time spent waiting (rebuffering).
        var waiting: TimeInterval = 0
        var transitions = 0
        var wasPlaying = true
        let playStart = Date()
        while Date().timeIntervalSince(playStart) < seconds {
            try await Task.sleep(nanoseconds: 100_000_000)
            let playing = player.timeControlStatus == .playing
            if !playing { waiting += 0.1 }
            if wasPlaying && !playing {
                transitions += 1
                print(String(format: "STREAMLAB pause at %.1fs, buffered to %.1fs", player.currentTime().seconds,
                             item.loadedTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds } ?? 0))
            }
            wasPlaying = playing
        }
        let position = player.currentTime().seconds

        // Seek well ahead and time the resume.
        let target = CMTime(seconds: min(position + 30, 80), preferredTimescale: 600)
        let s0 = Date()
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        try await waitUntil(timeout: 60) {
            player.timeControlStatus == .playing && player.currentTime().seconds > target.seconds + 0.2
        }
        let seek = Date().timeIntervalSince(s0)
        player.pause()

        return String(format: "start=%.2fs played=%.1fs/%.0fs waiting=%.1fs pauses=%d stalls=%d seekResume=%.2fs",
                      start, position, seconds, waiting, transitions, stalls, seek)
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
