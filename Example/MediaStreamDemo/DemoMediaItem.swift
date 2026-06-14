//
//  DemoMediaItem.swift
//  MediaStreamDemo
//
//  A MediaItem backed by a generated numbered color tile, that also conforms to
//  MediaStream's `SensitiveOverlayItem` so the gallery can shield it. The stable
//  `sensitiveOverlayKey` is just "tile-<index>" so XCUITest can address each cell.
//

import UIKit
import MediaStream

struct DemoMediaItem: MediaItem, SensitiveOverlayItem {
    let id: UUID
    let index: Int
    /// When false this tile is never gated (a "safe" item in flag-SOME mode).
    let isSensitiveContent: Bool

    var type: MediaType { .image }
    var diskCacheKey: String? { "demo-tile-\(index)" }
    var vrProjection: VRProjection? { nil }

    /// Stable per-item shield key. Only sensitive tiles return a key; safe tiles
    /// return nil so the gallery never shields them.
    var sensitiveOverlayKey: String? { isSensitiveContent ? "tile-\(index)" : nil }

    init(index: Int, isSensitiveContent: Bool) {
        self.id = DemoMediaItem.stableUUID(for: index)
        self.index = index
        self.isSensitiveContent = isSensitiveContent
    }

    func loadImage() async -> PlatformImage? { DemoTile.image(index: index) }
    func loadVideoURL() async -> URL? { nil }
    func getAnimatedImageDuration() async -> TimeInterval? { nil }
    func getVideoDuration() async -> TimeInterval? { nil }
    func getShareableItem() async -> Any? { DemoTile.image(index: index) }
    func getCaption() async -> String? { nil }
    func hasAudioTrack() async -> Bool { false }

    /// Deterministic UUID per index so gallery item identity is stable across
    /// state changes (the gallery keys cells by id).
    private static func stableUUID(for index: Int) -> UUID {
        let hex = String(format: "%012x", index)
        return UUID(uuidString: "00000000-0000-0000-0000-\(hex)") ?? UUID()
    }
}
