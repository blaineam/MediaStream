//
//  RCSubtitleCursorLab.swift
//  MediaStreamTests
//
//  Manual check that a streamed asset's subtitle samples can be located by
//  byte range (AVSampleCursor) without AVPlayer reading the subtitle track.
//  Skipped unless STREAMLAB_URL is set.
//

import XCTest
import AVFoundation
@testable import MediaStream

final class RCSubtitleCursorLab: XCTestCase {
    func testSubtitleSampleRanges() async throws {
        guard let raw = ProcessInfo.processInfo.environment["STREAMLAB_URL"], let url = URL(string: raw) else {
            throw XCTSkip("STREAMLAB_URL not set")
        }
        MediaStreamConfiguration.serverTrustEvaluator = { _, _ in true }
        let asset = AVURLAsset.makeForRCStream(url: url)
        let t0 = Date()
        let tracks = try await asset.loadTracks(withMediaType: .text) + asset.loadTracks(withMediaType: .subtitle)
        guard let track = tracks.first else { XCTFail("no subtitle track"); return }
        let formats = try await track.load(.formatDescriptions)
        let subtype = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        print("CURSORLAB track \(track.trackID) type=\(track.mediaType.rawValue) subtype=\(String(format: "%08x", subtype)) loadedIn=\(Date().timeIntervalSince(t0))")
        if let group = try await asset.loadMediaSelectionGroup(for: .legible) {
            for option in group.options {
                print("CURSORLAB option \(option.displayName) plist=\(option.propertyList()) tag=\(option.extendedLanguageTag ?? "-")")
            }
        }
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { XCTFail("no cursor"); return }
        var count = 0
        let t1 = Date()
        repeat {
            let range = cursor.currentSampleStorageRange
            if count < 3 || count % 500 == 0 {
                print(String(format: "CURSORLAB #%d pts=%.2f dur=%.2f offset=%lld len=%lld", count,
                             cursor.presentationTimeStamp.seconds, cursor.currentSampleDuration.seconds,
                             range.offset, range.length))
            }
            count += 1
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        print("CURSORLAB samples=\(count) walkedIn=\(Date().timeIntervalSince(t1))")
    }
}
