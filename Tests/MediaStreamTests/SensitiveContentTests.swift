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
