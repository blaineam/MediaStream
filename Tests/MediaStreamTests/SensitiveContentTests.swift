//
//  SensitiveContentTests.swift
//  MediaStreamTests
//
//  Unit tests for the UNIFIED sensitive-content decision logic shared by
//  Enter Space and Ari: per-item reveal policy, the verify-age seam, the
//  fail-closed error matrix, and the gallery / conversation bulk-block
//  threshold. These exercise the pure decision tables only (no SwiftUI, no
//  system SCA / Declared Age Range).
//

import XCTest
@testable import MediaStream

final class SensitiveContentTests: XCTestCase {

    // MARK: decide(...) — per-item reveal matrix

    func testInactiveGuardNeverShields() {
        for verdict: SensitiveContentVerdict in [.safe, .sensitive, .analysisFailed] {
            let p = SensitiveShieldPresentation.decide(
                verdict: verdict, guardActive: false, revealed: false,
                canReveal: true, canRequestVerification: true)
            XCTAssertEqual(p, .none, "Guard inactive must never shield (\(verdict))")
            XCTAssertFalse(p.isShielded)
        }
    }

    func testSafeNeverShields() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .safe, guardActive: true, revealed: false, canReveal: false)
        XCTAssertEqual(p, .none)
    }

    func testPendingVerdictNeverShields() {
        let p = SensitiveShieldPresentation.decide(
            verdict: nil, guardActive: true, revealed: false, canReveal: true)
        XCTAssertEqual(p, .none)
    }

    func testMinorGetsBlurNoReveal() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .sensitive, guardActive: true, revealed: false,
            canReveal: false, canRequestVerification: false)
        XCTAssertEqual(p, .sensitiveNoReveal)
        XCTAssertFalse(p.showsRevealButton)
        XCTAssertFalse(p.showsVerifyAgeButton)
        XCTAssertTrue(p.isShielded)
    }

    func testMinorRevealStateCannotPunchThrough() {
        // Even if a stray reveal flag is set, a non-adult must stay shielded.
        let p = SensitiveShieldPresentation.decide(
            verdict: .sensitive, guardActive: true, revealed: true,
            canReveal: false, canRequestVerification: false)
        XCTAssertEqual(p, .sensitiveNoReveal)
    }

    func testVerifiedAdultGetsShowAnyway() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .sensitive, guardActive: true, revealed: false, canReveal: true)
        XCTAssertEqual(p, .sensitiveWithReveal)
        XCTAssertTrue(p.showsRevealButton)
    }

    func testVerifiedAdultRevealedShowsContent() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .sensitive, guardActive: true, revealed: true, canReveal: true)
        XCTAssertEqual(p, .none)
    }

    func testUndeterminedGetsVerifyAge() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .sensitive, guardActive: true, revealed: false,
            canReveal: false, canRequestVerification: true)
        XCTAssertEqual(p, .sensitiveVerifyAge)
        XCTAssertTrue(p.showsVerifyAgeButton)
        XCTAssertFalse(p.showsRevealButton)
    }

    // MARK: Fail-closed error matrix

    func testAnalysisFailedMinorFailsClosed() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .analysisFailed, guardActive: true, revealed: false,
            canReveal: false, canRequestVerification: false)
        XCTAssertEqual(p, .errorNoReveal)
        XCTAssertTrue(p.isErrorState)
        XCTAssertTrue(p.isShielded)
    }

    func testAnalysisFailedAdultGetsManualReveal() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .analysisFailed, guardActive: true, revealed: false, canReveal: true)
        XCTAssertEqual(p, .errorWithReveal)
        XCTAssertTrue(p.showsRevealButton)
        XCTAssertTrue(p.isErrorState)
    }

    func testAnalysisFailedUndeterminedGetsVerifyAge() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .analysisFailed, guardActive: true, revealed: false,
            canReveal: false, canRequestVerification: true)
        XCTAssertEqual(p, .errorVerifyAge)
        XCTAssertTrue(p.showsVerifyAgeButton)
        XCTAssertTrue(p.isErrorState)
    }

    func testAnalysisFailedAdultRevealedShowsContent() {
        let p = SensitiveShieldPresentation.decide(
            verdict: .analysisFailed, guardActive: true, revealed: true, canReveal: true)
        XCTAssertEqual(p, .none)
    }

    // MARK: Bulk-block threshold

    func testBulkBlockEmptyOrNoneSensitive() {
        XCTAssertFalse(SensitiveBulkPolicy.shouldBulkBlock(sensitiveCount: 0, totalCount: 0))
        XCTAssertFalse(SensitiveBulkPolicy.shouldBulkBlock(sensitiveCount: 0, totalCount: 20))
    }

    func testBulkBlockHitsAbsoluteCount() {
        // 3 sensitive items trips the count threshold regardless of fraction.
        XCTAssertTrue(SensitiveBulkPolicy.shouldBulkBlock(sensitiveCount: 3, totalCount: 100))
    }

    func testBulkBlockHitsFraction() {
        // 1 of 4 = 25% trips the fraction threshold.
        XCTAssertTrue(SensitiveBulkPolicy.shouldBulkBlock(sensitiveCount: 1, totalCount: 4))
        // 2 of 9 ≈ 22% does NOT (and is below the count threshold).
        XCTAssertFalse(SensitiveBulkPolicy.shouldBulkBlock(sensitiveCount: 2, totalCount: 9))
    }

    func testBulkBlockSingleSensitiveLargeGalleryDoesNotBulk() {
        // 1 sensitive of 50 should remain per-item, not bulk-block.
        XCTAssertFalse(SensitiveBulkPolicy.shouldBulkBlock(sensitiveCount: 1, totalCount: 50))
    }

    // MARK: Bulk reveal cascade (verified adult unblocks → every key reveals)

    @MainActor
    func testBulkRevealRevealsEveryKeyForVerifiedAdult() {
        let policy = StubPolicy(canReveal: true)
        XCTAssertFalse(policy.isRevealed("a"))
        XCTAssertFalse(policy.isRevealed("b"))
        policy.revealAll()
        // A single bulk reveal must un-blur EVERY per-item key (the reported
        // "did not unblur all" bug), not just the block key.
        XCTAssertTrue(policy.isRevealed("a"))
        XCTAssertTrue(policy.isRevealed("b"))
        XCTAssertTrue(policy.isRevealed("conversation:42"))
    }

    @MainActor
    func testBulkRevealIsNoOpForNonAdult() {
        let policy = StubPolicy(canReveal: false)
        policy.revealAll()
        // A minor / undetermined user can never bulk-reveal.
        XCTAssertFalse(policy.isRevealed("a"))
        XCTAssertFalse(policy.isRevealed("b"))
    }

    // MARK: Policy wiring → decide() (the build-861/565 root cause)
    //
    // The reported bug was an UNVERIFIED-but-VERIFIABLE adult getting
    // `.sensitiveNoReveal` (a dead-end blur) instead of `.sensitiveVerifyAge`.
    // The decision table is correct; the failure was that a host policy did NOT
    // forward `canRequestVerificationFromShield` into decide(...). These assert
    // the contract a host MUST honor: when the policy advertises the verify-age
    // capability, a sensitive item produces the verify-age presentation; when it
    // does not, it produces the no-reveal dead-end. (ES previously hard-wired
    // the capability to false — this is what would have caught that.)

    @MainActor
    func testPolicyAdvertisingVerificationDrivesVerifyAgePresentation() {
        // Undetermined-but-verifiable adult policy.
        let policy = StubPolicy(canReveal: false, canRequestVerificationFromShield: true)
        let p = SensitiveShieldPresentation.decide(
            verdict: .sensitive,
            guardActive: policy.isGuardActive,
            revealed: policy.isRevealed("k"),
            canReveal: policy.canReveal,
            canRequestVerification: policy.canRequestVerificationFromShield)
        XCTAssertEqual(p, .sensitiveVerifyAge,
                       "A policy that advertises verify-age must yield the verify-age button, never a dead-end")
        XCTAssertTrue(p.showsVerifyAgeButton)
        XCTAssertFalse(p.showsRevealButton)
    }

    @MainActor
    func testPolicyWithoutVerificationDeadEndsAtNoReveal() {
        // Minor / declined policy (no reveal, no verify) — the ONLY case that
        // should ever reach the buttonless dead-end.
        let policy = StubPolicy(canReveal: false, canRequestVerificationFromShield: false)
        let p = SensitiveShieldPresentation.decide(
            verdict: .sensitive,
            guardActive: policy.isGuardActive,
            revealed: policy.isRevealed("k"),
            canReveal: policy.canReveal,
            canRequestVerification: policy.canRequestVerificationFromShield)
        XCTAssertEqual(p, .sensitiveNoReveal)
        XCTAssertFalse(p.showsVerifyAgeButton)
        XCTAssertFalse(p.showsRevealButton)
    }

    @MainActor
    func testPolicyVerificationAlsoDrivesFailClosedVerifyAge() {
        // The verify-age affordance must also appear on the fail-closed
        // (analysisFailed) path for an undetermined-but-verifiable adult, not
        // just the clean .sensitive path.
        let policy = StubPolicy(canReveal: false, canRequestVerificationFromShield: true)
        let p = SensitiveShieldPresentation.decide(
            verdict: .analysisFailed,
            guardActive: policy.isGuardActive,
            revealed: policy.isRevealed("k"),
            canReveal: policy.canReveal,
            canRequestVerification: policy.canRequestVerificationFromShield)
        XCTAssertEqual(p, .errorVerifyAge)
        XCTAssertTrue(p.showsVerifyAgeButton)
    }

    // MARK: Generic block copy (no "conversation")

    func testGenericBlockCopyHasNoConversationWording() {
        let copy = SensitiveBlockCopy.generic
        XCTAssertEqual(copy.title, "Sensitive Content")
        for text in [copy.title, copy.revealMessage, copy.verifyMessage, copy.lockedMessage] {
            XCTAssertFalse(text.lowercased().contains("conversation"),
                           "Generic copy must not say 'conversation': \(text)")
        }
    }

    func testHostMayOverrideBlockCopy() {
        let copy = SensitiveBlockCopy(title: "Hidden Chat",
                                      revealMessage: "This conversation is sensitive.")
        XCTAssertEqual(copy.title, "Hidden Chat")
        XCTAssertTrue(copy.revealMessage.contains("conversation"))
    }

    // MARK: Overlay verdict + controller (no baked bitmap, no disk persistence)

    func testOverlayVerdictShieldedFlag() {
        XCTAssertFalse(SensitiveOverlayVerdict.none.isShielded)
        XCTAssertTrue(SensitiveOverlayVerdict.shielded(isError: false).isShielded)
        XCTAssertTrue(SensitiveOverlayVerdict.shielded(isError: true).isShielded)
    }

    @MainActor
    func testInactiveOverlayControllerNeverShieldsAndAlwaysPersists() {
        let c = SensitiveOverlayController.inactive
        XCTAssertEqual(c.overlayVerdict("k"), .none)
        // Guard inactive → the gallery shows raw pixels and caching is fine.
        XCTAssertTrue(c.diskPersistable("k"))
        XCTAssertFalse(c.isActive())
    }

    @MainActor
    func testSensitiveItemIsNotDiskPersistableUntilRevealed() {
        // Mirrors the host contract: a sensitive key is NOT disk-persistable
        // (so a blurred/flagged thumbnail never reaches disk) until revealed.
        var revealed: Set<String> = []
        let c = SensitiveOverlayController(
            overlayVerdict: { revealed.contains($0) ? .none : .shielded(isError: false) },
            diskPersistable: { revealed.contains($0) },   // sensitive ⇒ false
            canRevealKey: { _ in true },
            canVerifyKey: { _ in false },
            revealKey: { revealed.insert($0) },
            revealAllAction: {},
            requestVerification: { false },
            isActive: { true }
        )
        XCTAssertEqual(c.overlayVerdict("img"), .shielded(isError: false))
        XCTAssertFalse(c.diskPersistable("img"), "Sensitive thumbnail must NOT be disk-persistable")
        c.revealKey("img")
        XCTAssertEqual(c.overlayVerdict("img"), .none, "Reveal removes the overlay (instant, no rebuild)")
        XCTAssertTrue(c.diskPersistable("img"), "Once revealed the real thumbnail may persist")
    }

    // MARK: View-scoped reveal + reset-on-dismiss (Bug 1) and revealed-button (Bug 2)

    /// Build a controller whose BASE state always shields adult-revealable keys,
    /// so the controller's OWN view-scoped reveal is what un-blurs (mirrors the
    /// gallery wiring: the host verdict stays sensitive; the view scope reveals).
    @MainActor
    private func adultShieldingController() -> SensitiveOverlayController {
        SensitiveOverlayController(
            overlayVerdict: { _ in .shielded(isError: false) },
            diskPersistable: { _ in false },
            canRevealKey: { _ in true },
            canVerifyKey: { _ in false },
            revealKey: { _ in },
            revealAllAction: {},
            requestVerification: { false },
            isActive: { true },
            canRevealAll: { true }
        )
    }

    @MainActor
    func testRevealAllIsScopedToControllerAndResetsOnDismiss() {
        let c = adultShieldingController()
        XCTAssertEqual(c.overlayVerdict("a"), .shielded(isError: false))
        XCTAssertEqual(c.overlayVerdict("b"), .shielded(isError: false))
        c.revealAllAction()
        // Reveal-All un-blurs EVERY key in THIS scope…
        XCTAssertEqual(c.overlayVerdict("a"), .none)
        XCTAssertEqual(c.overlayVerdict("b"), .none)
        // …but it is VIEW-SCOPED: dismissing (resetReveals) re-blurs everything,
        // instead of staying revealed everywhere until force-quit (Bug 1).
        c.resetReveals()
        XCTAssertEqual(c.overlayVerdict("a"), .shielded(isError: false))
        XCTAssertEqual(c.overlayVerdict("b"), .shielded(isError: false))
    }

    @MainActor
    func testPerItemRevealIsScopedAndResets() {
        let c = adultShieldingController()
        c.revealKey("a")
        XCTAssertEqual(c.overlayVerdict("a"), .none, "Revealed key un-blurs")
        XCTAssertEqual(c.overlayVerdict("b"), .shielded(isError: false), "Other keys stay blurred")
        c.resetReveals()
        XCTAssertEqual(c.overlayVerdict("a"), .shielded(isError: false), "Reset re-blurs the revealed key")
    }

    @MainActor
    func testRevealButtonSuppressedOnAlreadyRevealedContent() {
        let c = adultShieldingController()
        XCTAssertTrue(c.canRevealKey("a"), "Shielded adult-revealable key offers the button")
        c.revealKey("a")
        // Bug 2: once revealed, the per-item reveal control must NOT show again.
        XCTAssertFalse(c.canRevealKey("a"), "Revealed key must not offer Show Anyway again")
        XCTAssertFalse(c.canVerifyKey("a"))
    }

    @MainActor
    func testRevealAllSuppressesEveryPerItemButton() {
        let c = adultShieldingController()
        c.revealAllAction()
        XCTAssertFalse(c.canRevealKey("a"))
        XCTAssertFalse(c.canRevealKey("b"))
    }

    @MainActor
    func testMinorCannotPunchThroughRevealAll() {
        // A minor: base shields, but canRevealAll is FALSE. revealAllAction must
        // be a structural no-op so the view scope never un-blurs.
        let c = SensitiveOverlayController(
            overlayVerdict: { _ in .shielded(isError: false) },
            diskPersistable: { _ in false },
            canRevealKey: { _ in false },
            canVerifyKey: { _ in false },
            revealKey: { _ in },
            revealAllAction: {},
            requestVerification: { false },
            isActive: { true },
            canRevealAll: { false }
        )
        c.revealAllAction()
        XCTAssertEqual(c.overlayVerdict("a"), .shielded(isError: false),
                       "A minor must never punch through reveal-all")
        XCTAssertFalse(c.canRevealKey("a"))
    }

    @MainActor
    func testCanRevealKeySuppressedWhenNotShielded() {
        // A safe (base .none) key never offers a reveal button even if the host
        // would otherwise allow reveals.
        let c = SensitiveOverlayController(
            overlayVerdict: { _ in .none },
            diskPersistable: { _ in true },
            canRevealKey: { _ in true },
            canVerifyKey: { _ in false },
            revealKey: { _ in },
            revealAllAction: {},
            requestVerification: { false },
            isActive: { true }
        )
        XCTAssertFalse(c.canRevealKey("safe"), "A non-shielded key must not offer a reveal control")
    }

    // MARK: Shared bulk-block gate (grid ⇄ slideshow agreement, v2.7.2)

    /// Helper: a controller whose every passed key is base-shielded.
    @MainActor
    private func shieldingController(active: Bool = true) -> SensitiveOverlayController {
        SensitiveOverlayController(
            overlayVerdict: { _ in .shielded(isError: false) },
            diskPersistable: { _ in false },
            canRevealKey: { _ in true },
            canVerifyKey: { _ in false },
            revealKey: { _ in },
            revealAllAction: {},
            requestVerification: { true },
            isActive: { active },
            canRevealAll: { true }
        )
    }

    /// THE denominator-bug guard: the slideshow's keys are GATED keys only (safe
    /// items have no key). A MINORITY of flagged items in a larger gallery must
    /// NOT bulk-block — the total count, not the gated-key count, is the
    /// denominator. (2 flagged of 12 → 16% < 25% threshold and < count-3.)
    @MainActor
    func testSharedGateMinorityDoesNotBulkBlock() {
        let c = shieldingController()
        XCTAssertFalse(
            c.shouldBulkBlock(forKeys: ["tile-1", "tile-3"], totalCount: 12),
            "A minority of flagged items must not bulk-block the whole gallery")
    }

    /// A fully-sensitive gallery (every item gated + shielded) bulk-blocks.
    @MainActor
    func testSharedGateMajorityBulkBlocks() {
        let c = shieldingController()
        let keys = (0..<12).map { "tile-\($0)" }
        XCTAssertTrue(
            c.shouldBulkBlock(forKeys: keys, totalCount: 12),
            "A fully-sensitive gallery must bulk-block")
    }

    /// The gate is false when the guard is inactive, regardless of keys.
    @MainActor
    func testSharedGateInactiveGuardNeverBlocks() {
        let c = shieldingController(active: false)
        let keys = (0..<12).map { "tile-\($0)" }
        XCTAssertFalse(
            c.shouldBulkBlock(forKeys: keys, totalCount: 12),
            "An inactive guard must never bulk-block")
    }

    /// The gate reads reveal state live: once a verified adult reveals all, the
    /// shielded count drops to zero and the block clears (grid + slideshow agree).
    @MainActor
    func testSharedGateClearsAfterRevealAll() {
        let c = shieldingController()
        let keys = (0..<12).map { "tile-\($0)" }
        XCTAssertTrue(c.shouldBulkBlock(forKeys: keys, totalCount: 12))
        c.revealAllAction()
        XCTAssertFalse(
            c.shouldBulkBlock(forKeys: keys, totalCount: 12),
            "After Reveal-All the gate must drop so the block disappears")
    }

    // MARK: Export gate (Share must never hand out a shielded item's original)

    /// A shielded item never exports — the whole point of the gate. Sharing
    /// hands over the real original, which is strictly worse than un-blurring.
    func testShieldedNeverExports() {
        XCTAssertFalse(SensitiveExportPolicy.allowsExport(.shielded(isError: false)))
        XCTAssertFalse(SensitiveExportPolicy.allowsExport(.shielded(isError: true)),
                       "The fail-closed error shield must block export too")
    }

    /// `.none` — safe, revealed in scope, or guard inactive — exports normally.
    func testUnshieldedExports() {
        XCTAssertTrue(SensitiveExportPolicy.allowsExport(.none))
    }

    /// A mixed multi-select shares ONLY the allowed items rather than blocking
    /// the whole batch — and the shielded ones must not survive the filter.
    func testExportableDropsShieldedFromMixedSelection() {
        let items: [(String, SensitiveOverlayVerdict)] = [
            ("safe-1", .none),
            ("nsfw-1", .shielded(isError: false)),
            ("safe-2", .none),
            ("err-1", .shielded(isError: true))
        ]
        let out = SensitiveExportPolicy.exportable(items) { $0.1 }
        XCTAssertEqual(out.map(\.0), ["safe-1", "safe-2"],
                       "Only unshielded items may leave the app")
    }

    /// Every-item-shielded selection: no Share affordance (dead end), and the
    /// filter yields nothing even if the button were somehow reached.
    func testFullyShieldedSelectionOffersNoShare() {
        let verdicts: [SensitiveOverlayVerdict] = [
            .shielded(isError: false), .shielded(isError: true)
        ]
        XCTAssertFalse(SensitiveExportPolicy.shouldOfferShare(verdicts: verdicts))
        XCTAssertTrue(SensitiveExportPolicy.exportable(verdicts, verdict: { $0 }).isEmpty)
    }

    /// A mixed selection still offers Share (the safe items are shareable).
    func testMixedSelectionOffersShare() {
        XCTAssertTrue(SensitiveExportPolicy.shouldOfferShare(
            verdicts: [.shielded(isError: false), .none]))
    }

    /// An empty selection has nothing to share.
    func testEmptySelectionOffersNoShare() {
        XCTAssertFalse(SensitiveExportPolicy.shouldOfferShare(verdicts: []))
    }

    /// The controller seam the GRID resolves per item: a shielded key blocks
    /// export, and it reads the same live verdict the blur is drawn from.
    @MainActor
    func testControllerBlocksExportForShieldedKey() {
        let c = shieldingController()
        XCTAssertTrue(c.blocksExport("tile-1"),
                      "A shielded key must block export in the grid's share paths")
    }

    /// Reveal-in-scope flips export ON instantly — a verified adult who revealed
    /// the item may share it, exactly as the slideshow already allowed.
    @MainActor
    func testRevealInScopeUnblocksExport() {
        let c = shieldingController()
        XCTAssertTrue(c.blocksExport("tile-1"))
        c.revealKey("tile-1")
        XCTAssertFalse(c.blocksExport("tile-1"),
                       "A revealed item must become exportable without a rebuild")
    }

    /// An inactive guard never blocks export (hosts that don't gate at all).
    @MainActor
    func testInactiveGuardNeverBlocksExport() {
        XCTAssertFalse(SensitiveOverlayController.inactive.blocksExport("tile-1"))
    }
}

/// Minimal in-memory policy exercising the bulk-reveal contract shared by
/// Enter Space and Ari (revealAll → every key reveals, adult-gated).
@MainActor
private final class StubPolicy: SensitiveContentPolicy {
    let canReveal: Bool
    var isGuardActive = true
    var canRequestVerificationFromShield = false
    var verificationFeedbackMessage: String?

    private var revealedKeys: Set<String> = []
    private var revealedAll = false

    init(canReveal: Bool, canRequestVerificationFromShield: Bool = false) {
        self.canReveal = canReveal
        self.canRequestVerificationFromShield = canRequestVerificationFromShield
    }

    func isRevealed(_ key: String) -> Bool { revealedAll || revealedKeys.contains(key) }
    func reveal(_ key: String) { guard canReveal else { return }; revealedKeys.insert(key) }
    func revealAll() { guard canReveal else { return }; revealedAll = true }
    #if compiler(>=6.3)
    func verdict(forKey key: String,
                 dataProvider: @escaping @concurrent @Sendable () async -> Data?) async -> SensitiveContentVerdict { .safe }
    #else
    func verdict(forKey key: String,
                 dataProvider: @escaping @Sendable () async -> Data?) async -> SensitiveContentVerdict { .safe }
    #endif
    func requestAdultVerification() async -> Bool { canReveal }
    func clearVerificationOutcome() {}
    func anySensitive(in keys: [String]) -> Bool { false }
}
