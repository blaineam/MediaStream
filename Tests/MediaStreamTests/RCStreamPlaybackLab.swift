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
        // A host's per-backend connection limit (2 = Enter Space on SFTP).
        if let conns = Int(ProcessInfo.processInfo.environment["STREAMLAB_CONN"] ?? "") {
            RCStreamRouting.connectionLimit = { _ in conns }
        }
        defer { RCStreamRouting.connectionLimit = nil }

        let result = try await MainActor.run { () -> Task<String, Error> in
            Task { @MainActor in try await Self.run(url: url, seconds: seconds) }
        }.value
        print("STREAMLAB \(result)")
    }

    @MainActor
    private static func run(url: URL, seconds: Double) async throws -> String {
        let asset = AVURLAsset.makeForRCStream(url: url)
        let item: AVPlayerItem
        // Only video and audio, in a composition: the player never sees the
        // subtitle track at all.
        if ProcessInfo.processInfo.environment["STREAMLAB_COMPOSE"] != nil {
            let composition = AVMutableComposition()
            let duration = try await asset.load(.duration)
            for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
                guard let target = composition.addMutableTrack(withMediaType: track.mediaType,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                target.preferredTransform = try await track.load(.preferredTransform)
            }
            item = AVPlayerItem(asset: composition)
        } else {
            item = AVPlayerItem(asset: asset)
        }
        // The host app's forward-buffer target (Enter Space's tvOS player sets 30).
        if let fwd = Double(ProcessInfo.processInfo.environment["STREAMLAB_FWD"] ?? "") {
            item.preferredForwardBufferDuration = fwd
        }
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        // Subtitles on, as a viewer with them enabled (a legible track whose
        // samples may lie far from the video's).
        if ProcessInfo.processInfo.environment["STREAMLAB_SUBS"] != nil,
           let group = try await asset.loadMediaSelectionGroup(for: .legible),
           let option = group.options.first(where: { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }) {
            item.select(option, in: group)
        }
        // Subtitle track switched off entirely (the host draws subtitles itself).
        if ProcessInfo.processInfo.environment["STREAMLAB_NOSUBTRACK"] != nil {
            try await waitUntil(timeout: 30) { item.status == .readyToPlay }
            for track in item.tracks where [.subtitle, .text, .closedCaption].contains(track.assetTrack?.mediaType) {
                track.isEnabled = false
            }
            if let group = try await asset.loadMediaSelectionGroup(for: .legible) {
                let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                print("STREAMLAB after disabling, selected subtitle option: \(selected?.displayName ?? "none")")
                if let option = group.options.first { item.select(option, in: group) }
                try await Task.sleep(nanoseconds: 500_000_000)
                let enabled = item.tracks.filter { [.subtitle, .text].contains($0.assetTrack?.mediaType) && $0.isEnabled }.count
                print("STREAMLAB after re-selecting: \(item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "none"), enabled subtitle tracks=\(enabled)")
            }
        }
        // Resume partway in, like Continue Watching.
        if let start = Double(ProcessInfo.processInfo.environment["STREAMLAB_START"] ?? "") {
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }

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
        var minBuffered = Double.infinity
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
            // Lowest buffer after the first 15 s (startup excluded).
            let now = player.currentTime().seconds
            let ahead = item.loadedTimeRanges.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds }
                .filter { $0 >= now }.max().map { $0 - now } ?? 0
            if Date().timeIntervalSince(playStart) > 15 { minBuffered = min(minBuffered, ahead) }
            if ProcessInfo.processInfo.environment["STREAMLAB_TRACE"] != nil,
               Int(Date().timeIntervalSince(playStart) * 10) % 20 == 0 {
                let net = RCStreamingResourceLoader.shared.stats(for: asset.url)
                let ranges = item.loadedTimeRanges.map { r -> String in
                    let tr = r.timeRangeValue
                    return String(format: "%.1f-%.1f", tr.start.seconds, CMTimeRangeGetEnd(tr).seconds)
                }.joined(separator: ",")
                print(String(format: "STREAMLAB t=%.0fs pos=%.1f buffered=%.1fs conns=%d ranges=%@", Date().timeIntervalSince(playStart), now, ahead,
                             net?.activeConnections ?? -1, ranges))
            }
        }
        let position = player.currentTime().seconds

        // Seek well ahead and time the resume.
        let target = CMTime(seconds: position + 30, preferredTimescale: 600)
        let s0 = Date()
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        try await waitUntil(timeout: 60) {
            player.timeControlStatus == .playing && player.currentTime().seconds > target.seconds + 0.2
        }
        let seek = Date().timeIntervalSince(s0)
        player.pause()

        return String(format: "start=%.2fs played=%.1fs/%.0fs waiting=%.1fs pauses=%d stalls=%d seekResume=%.2fs minBuffered=%.1fs",
                      start, position, seconds, waiting, transitions, stalls, seek, minBuffered)
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
