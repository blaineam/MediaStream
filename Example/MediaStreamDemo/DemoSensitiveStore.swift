//
//  DemoSensitiveStore.swift
//  MediaStreamDemo
//
//  A STUB sensitive-content policy whose age status and per-item verdicts are
//  settable via launch arguments (or in-app controls) so every SCA + gallery
//  path is drivable headlessly by XCUITest in the simulator — no live device,
//  no real SensitiveContentAnalysis, no real Declared Age Range sheet.
//
//  Launch arguments understood (all optional):
//    -scaAge       verifiedAdult | undetermined | minor   (default verifiedAdult)
//    -scaFlag      all | some | none                       (default some)
//    -scaItems     <Int>                                   (default 12)
//    -scaStart     grid | slideshow                        (default grid)
//    -scaStartIndex <Int>  (slideshow start index; default first sensitive tile)
//
//  `some` flags only a MINORITY of items (below the bulk threshold) so the
//  PER-ITEM shield is reachable; `all` flags every item so the bulk block fires.
//

import Foundation
import Combine
import MediaStream

enum DemoAgeStatus: String {
    case verifiedAdult
    case undetermined
    case minor
}

enum DemoFlagMode: String {
    case all
    case some
    case none
}

enum DemoStartScreen: String {
    case grid
    case slideshow
}

/// Holds the demo's "host policy" state and vends a `SensitiveOverlayController`
/// the gallery consumes. Mutating age / flag-mode rebuilds nothing — the
/// controller reads these live through closures.
@MainActor
final class DemoSensitiveStore: ObservableObject {
    @Published var ageStatus: DemoAgeStatus
    @Published var flagMode: DemoFlagMode
    let itemCount: Int
    let startScreen: DemoStartScreen
    let startIndex: Int?

    /// Host-level "this key was revealed" set (defense-in-depth mirror; the
    /// view-scoped reveal lives in the controller). Kept so the host closures
    /// behave like a real app's guard.
    private var hostRevealed: Set<String> = []

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        self.ageStatus = value("-scaAge").flatMap(DemoAgeStatus.init) ?? .verifiedAdult
        self.flagMode = value("-scaFlag").flatMap(DemoFlagMode.init) ?? .some
        self.itemCount = value("-scaItems").flatMap(Int.init) ?? 12
        self.startScreen = value("-scaStart").flatMap(DemoStartScreen.init) ?? .grid
        self.startIndex = value("-scaStartIndex").flatMap(Int.init)
    }

    // MARK: Derived capabilities

    /// The guard is always "on" in the demo (the OS SCA policy is assumed on).
    var isGuardActive: Bool { true }
    /// Only a verified adult may reveal.
    var canReveal: Bool { ageStatus == .verifiedAdult }
    /// An undetermined viewer may run the (stubbed) age request.
    var canVerify: Bool { ageStatus == .undetermined }

    /// Which tile indices are sensitive for the current flag mode. `some` keeps
    /// the count BELOW the bulk threshold so per-item shields are reachable.
    func isSensitiveIndex(_ index: Int) -> Bool {
        switch flagMode {
        case .none: return false
        case .all: return true
        case .some:
            // Flag exactly 2 tiles (indices 1 and 3) — a minority that stays
            // under SensitiveBulkPolicy so the bulk block does NOT fire.
            return index == 1 || index == 3
        }
    }

    func items() -> [DemoMediaItem] {
        (0..<itemCount).map { DemoMediaItem(index: $0, isSensitiveContent: isSensitiveIndex($0)) }
    }

    // MARK: Host closures → SensitiveOverlayController

    private func baseVerdict(_ key: String) -> SensitiveOverlayVerdict {
        // The host verdict stays "sensitive" for a flagged key — un-blurring is
        // owned by the controller's VIEW-SCOPED reveal (which resets on dismiss).
        // We deliberately do NOT consult `hostRevealed` here: a real host's
        // analyzer verdict doesn't change just because the user tapped reveal in
        // a now-dismissed gallery, and letting it un-blur would defeat Bug-1's
        // "reset on dismiss" guarantee.
        guard isGuardActive, key.hasPrefix("tile-") else { return .none }
        return .shielded(isError: false)
    }

    /// The first sensitive tile index (for a slideshow deep-link default).
    var firstSensitiveIndex: Int {
        (0..<itemCount).first(where: { isSensitiveIndex($0) }) ?? 0
    }

    func makeController() -> SensitiveOverlayController {
        SensitiveOverlayController(
            overlayVerdict: { [weak self] key in self?.baseVerdict(key) ?? .none },
            diskPersistable: { [weak self] key in
                guard let self else { return true }
                if !key.hasPrefix("tile-") { return true }
                return self.hostRevealed.contains(key) && self.canReveal
            },
            canRevealKey: { [weak self] _ in self?.canReveal ?? false },
            canVerifyKey: { [weak self] _ in self?.canVerify ?? false },
            revealKey: { [weak self] key in
                guard let self, self.canReveal else { return }
                self.hostRevealed.insert(key)
            },
            revealAllAction: { [weak self] in
                guard let self, self.canReveal else { return }
                for i in 0..<self.itemCount where self.isSensitiveIndex(i) {
                    self.hostRevealed.insert("tile-\(i)")
                }
            },
            requestVerification: { [weak self] in
                // Stubbed Declared Age Range: an "undetermined" viewer becomes a
                // verified adult; anyone else returns their current adult flag.
                guard let self else { return false }
                if self.ageStatus == .undetermined { self.ageStatus = .verifiedAdult }
                return self.ageStatus == .verifiedAdult
            },
            isActive: { [weak self] in self?.isGuardActive ?? false },
            canRevealAll: { [weak self] in self?.canReveal ?? false }
        )
    }
}
