//
//  MediaStreamSCAUITests.swift
//  MediaStreamDemoUITests
//
//  Automated XCUITest coverage for MediaStream's sensitive-content gallery,
//  running fully headless on the iOS Simulator against the stubbed
//  DemoSensitiveStore. Every test launches the demo app with launch arguments
//  that put the SCA policy into a known state, taps the REAL gallery controls,
//  and asserts the visible result — so the SCA behavior is verifiable without a
//  physical device.
//

import XCTest

final class MediaStreamSCAUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // The simulator can pop a SpringBoard "Sign in to Apple Account" sheet
        // that steals focus. Auto-dismiss it whenever it interrupts.
        addUIInterruptionMonitor(withDescription: "System dialog") { alert in
            for label in ["Cancel", "Not Now", "Don’t Allow", "Dismiss"] {
                let btn = alert.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }
    }

    /// Dismiss any SpringBoard-level alert (e.g. the Apple Account sign-in sheet)
    /// that may be covering the app, so element queries hit our UI. Runs a few
    /// passes because the sheet can appear a beat after launch.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            var dismissedAny = false
            for label in ["Cancel", "Not Now", "Don’t Allow", "Dismiss"] {
                let btn = springboard.buttons[label]
                if btn.exists { btn.tap(); dismissedAny = true }
            }
            if !dismissedAny { break }
        }
    }

    /// Launch the demo with SCA launch arguments.
    private func launch(age: String, flag: String, start: String = "grid",
                        items: Int = 12, startIndex: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-scaAge", age, "-scaFlag", flag, "-scaStart", start, "-scaItems", "\(items)"]
        if let startIndex { args += ["-scaStartIndex", "\(startIndex)"] }
        app.launchArguments = args
        app.launch()
        dismissSystemAlerts()
        // The sign-in sheet can land a beat after launch; give it a moment and
        // sweep again so it never covers the gallery during the test.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        _ = springboard.buttons["Cancel"].waitForExistence(timeout: 2)
        dismissSystemAlerts()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Prefer the typed `buttons` query (most reliable for SwiftUI buttons),
    /// falling back to the generic descendant query.
    private func button(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let typed = app.buttons[id]
        return typed.exists ? typed : element(app, id)
    }

    private func waitFor(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 10) -> Bool {
        element(app, id).waitForExistence(timeout: timeout)
    }

    // MARK: 1. Per-item shield (minority sensitive + verified adult)

    func testPerItemShieldRevealsSingleCellOnTap() {
        // flag=some flags a MINORITY (tiles 1 & 3) so the bulk block does NOT
        // fire and the per-item shield is reachable.
        let app = launch(age: "verifiedAdult", flag: "some")

        // The reveal control on the sensitive cell is the reliable signal that
        // the cell started shielded (a shielded adult-revealable cell always
        // offers it). Wait for it, clearing any system alert first.
        let revealBtn = button(app, "sca.cell.reveal.tile-1")
        XCTAssertTrue(revealBtn.waitForExistence(timeout: 12),
                      "A verified adult should see a Show Anyway control on the shielded cell")
        XCTAssertTrue(element(app, "sca.cell.tile-1.shielded").exists,
                      "Sensitive tile should start shielded")

        // A SINGLE tap reveals THAT cell.
        revealBtn.tap()
        XCTAssertTrue(waitFor(app, "sca.cell.tile-1.revealed"),
                      "A single tap must reveal that cell's real image")

        // The reveal button must NOT show again on the revealed cell (Bug 2).
        XCTAssertFalse(button(app, "sca.cell.reveal.tile-1").exists,
                       "Revealed content must not show the reveal control again")

        // The OTHER sensitive cell (tile 3) stays shielded — reveal is per-item.
        XCTAssertTrue(element(app, "sca.cell.tile-3.shielded").exists,
                      "Revealing one cell must not reveal the others")
    }

    // MARK: 2. Bulk block (majority sensitive) + dismissable

    func testBulkBlockRevealAllAndDismissable() {
        let app = launch(age: "verifiedAdult", flag: "all")

        // The bulk block + Reveal-All appear, and a Done control is reachable.
        XCTAssertTrue(waitFor(app, "sca.bulk.revealAll"),
                      "A majority-sensitive gallery should bulk-block with Reveal All")
        let done = element(app, "sca.bulk.done")
        XCTAssertTrue(done.exists, "A Done control must remain reachable while the block shows (Bug 4)")
        XCTAssertTrue(done.isHittable, "The Done control must be hittable on top of the block")

        // A SINGLE Reveal-All un-blurs everything.
        element(app, "sca.bulk.revealAll").tap()
        XCTAssertTrue(waitFor(app, "sca.cell.tile-0.revealed"),
                      "Reveal All must un-blur every sensitive cell")
        XCTAssertTrue(element(app, "sca.cell.tile-1.revealed").exists)
    }

    func testBulkBlockDoneDismissesWithoutRevealing() {
        let app = launch(age: "verifiedAdult", flag: "all")
        XCTAssertTrue(waitFor(app, "sca.bulk.done"))
        // Done must work even without revealing.
        element(app, "sca.bulk.done").tap()
        XCTAssertTrue(waitFor(app, "demo.openGrid"),
                      "Tapping Done must dismiss the gallery back to the harness")
    }

    // MARK: 3. Age gating

    func testVerifiedAdultSeesReveal() {
        let app = launch(age: "verifiedAdult", flag: "some")
        XCTAssertTrue(element(app, "sca.cell.reveal.tile-1").waitForExistence(timeout: 10),
                      "A verified adult must see a reveal control")
        XCTAssertFalse(element(app, "sca.cell.verify.tile-1").exists)
    }

    func testUndeterminedSeesVerifyAge() {
        let app = launch(age: "undetermined", flag: "some")
        XCTAssertTrue(element(app, "sca.cell.verify.tile-1").waitForExistence(timeout: 10),
                      "An undetermined viewer must see a Verify Age control")
        XCTAssertFalse(element(app, "sca.cell.reveal.tile-1").exists,
                       "An undetermined viewer must NOT see a direct reveal")
    }

    func testMinorSeesNoRevealButCanDismiss() {
        let app = launch(age: "minor", flag: "some")
        // Minor: tile stays shielded, NO reveal and NO verify control.
        XCTAssertTrue(waitFor(app, "sca.cell.tile-1.shielded"))
        XCTAssertFalse(element(app, "sca.cell.reveal.tile-1").exists,
                       "A minor must never see a reveal control")
        XCTAssertFalse(element(app, "sca.cell.verify.tile-1").exists,
                       "A minor must never see a verify control")
        // A minor must still be able to leave the gallery (Done in toolbar).
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
    }

    func testMinorBulkBlockHasNoRevealAllButHasDone() {
        let app = launch(age: "minor", flag: "all")
        // Minor + majority sensitive: block shows, Done present, NO Reveal All.
        XCTAssertTrue(waitFor(app, "sca.bulk.done"))
        XCTAssertFalse(element(app, "sca.bulk.revealAll").exists,
                       "A minor must not get a Reveal All button")
        XCTAssertTrue(element(app, "sca.bulk.done").isHittable,
                      "A minor must still be able to dismiss the blocked gallery")
    }

    // MARK: 4. Slideshow reveal + no collision with transport controls

    func testSlideshowRevealNoCollisionWithControls() {
        // Open straight into the slideshow on a sensitive tile.
        let app = launch(age: "verifiedAdult", flag: "some", start: "slideshow", startIndex: 1)

        // The grid → slideshow transition + a possible system alert can land
        // after launch; wait for the slideshow to settle and clear any alert.
        _ = element(app, "sca.slideshow.tile-1.shielded").waitForExistence(timeout: 10)
        dismissSystemAlerts()

        let revealBtn = button(app, "sca.slideshow.reveal")
        XCTAssertTrue(revealBtn.waitForExistence(timeout: 10),
                      "The full-screen viewer must offer a reveal control for a shielded item")

        // Bug 3: the reveal button must not overlap the bottom transport row.
        // Find a transport control (the slideshow play/next chevrons render as
        // images); assert the reveal button sits above the bottom controls band.
        let revealFrame = revealBtn.frame
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThan(revealFrame.maxY, screen.maxY - 80,
                          "Reveal button must sit above the bottom transport controls band")

        // A single tap reveals the full-screen item. Tapping the full-screen
        // viewer can also toggle the transport-control chrome, which may
        // intercept the first hit; clear any alert and retry once so the test is
        // not flaky in a full-suite run.
        dismissSystemAlerts()
        revealBtn.tap()
        let revealed = element(app, "sca.slideshow.tile-1.revealed")
        if !revealed.waitForExistence(timeout: 6) {
            let retryBtn = button(app, "sca.slideshow.reveal")
            if retryBtn.exists { retryBtn.tap() }
        }
        XCTAssertTrue(revealed.waitForExistence(timeout: 8),
                      "A single tap must reveal the full-screen item")
        XCTAssertFalse(element(app, "sca.slideshow.reveal").exists,
                       "Revealed full-screen content must not show the reveal control again")
    }

    // MARK: 5. Reveal scoping: reset on dismiss (Bug 1)

    func testRevealAllResetsWhenGalleryDismissedAndReopened() {
        let app = launch(age: "verifiedAdult", flag: "all")

        // Reveal everything in this gallery instance.
        XCTAssertTrue(waitFor(app, "sca.bulk.revealAll"))
        element(app, "sca.bulk.revealAll").tap()
        XCTAssertTrue(waitFor(app, "sca.cell.tile-0.revealed"))

        // Dismiss back to the harness. A SpringBoard sign-in sheet can steal
        // focus mid-test, so clear it and retry the Done tap once before
        // asserting the harness returned.
        dismissSystemAlerts()
        let toolbarDone = app.buttons["Done"].firstMatch
        XCTAssertTrue(toolbarDone.waitForExistence(timeout: 5))
        toolbarDone.tap()
        if !waitFor(app, "demo.openGrid", timeout: 5) {
            dismissSystemAlerts()
            if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        }
        XCTAssertTrue(waitFor(app, "demo.openGrid"))

        // Reopen — content must be BLURRED AGAIN (reveal did not persist).
        element(app, "demo.openGrid").tap()
        XCTAssertTrue(waitFor(app, "sca.bulk.revealAll"),
                      "Reopening the gallery must show the bulk block again — reveal must NOT persist (Bug 1)")
        XCTAssertFalse(element(app, "sca.cell.tile-0.revealed").exists,
                       "Reopened gallery must show content blurred again, not still-revealed")
    }

    func testPerItemRevealResetsOnReopen() {
        let app = launch(age: "verifiedAdult", flag: "some")
        let reveal = element(app, "sca.cell.reveal.tile-1")
        XCTAssertTrue(reveal.waitForExistence(timeout: 10))
        reveal.tap()
        XCTAssertTrue(waitFor(app, "sca.cell.tile-1.revealed"))

        // Dismiss + reopen. Guard against a SpringBoard sheet stealing the tap.
        dismissSystemAlerts()
        app.buttons["Done"].firstMatch.tap()
        if !waitFor(app, "demo.openGrid", timeout: 5) {
            dismissSystemAlerts()
            if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        }
        XCTAssertTrue(waitFor(app, "demo.openGrid"))
        element(app, "demo.openGrid").tap()

        // The previously-revealed cell is shielded again.
        XCTAssertTrue(waitFor(app, "sca.cell.tile-1.shielded"),
                      "A per-item reveal must not persist across gallery dismissal (Bug 1)")
    }

    // MARK: 6. Single Done when fully blocked (v2.7.1 — toolbar suppression)

    /// When the WHOLE gallery is bulk blocked, the navigation-toolbar trailing
    /// group (chrome Done + Download + Select) is suppressed so the ONLY visible
    /// Done is the block overlay's own "sca.bulk.done". There must be EXACTLY
    /// ONE element labelled "Done" — the prior bug rendered two overlapping Dones
    /// at the top-right ("multiple done buttons when it is all sensitive").
    func testBulkBlockShowsExactlyOneDone() {
        let app = launch(age: "verifiedAdult", flag: "all")

        // The bulk block (and its own Done) must be present.
        let bulkDone = element(app, "sca.bulk.done")
        XCTAssertTrue(bulkDone.waitForExistence(timeout: 12),
                      "A fully-sensitive gallery must show the bulk block's Done")
        XCTAssertTrue(bulkDone.isHittable, "The block's Done must be hittable")

        // EXACTLY ONE button labelled "Done" may exist — the toolbar Done,
        // Download and Select buttons are suppressed while bulk blocked.
        let doneButtons = app.buttons.matching(
            NSPredicate(format: "label == %@", "Done"))
        XCTAssertEqual(doneButtons.count, 1,
                       "Exactly one Done must be visible when fully blocked (toolbar Done suppressed)")

        // The download button must also be gone while fully blocked (no
        // downloading of sensitive content).
        XCTAssertFalse(app.buttons["Download"].exists,
                       "Download must be suppressed while the gallery is fully blocked")

        // The single Done dismisses the gallery back to the harness.
        bulkDone.tap()
        XCTAssertTrue(waitFor(app, "demo.openGrid"),
                      "Tapping the single Done must dismiss the blocked gallery")
    }

    // MARK: 7. Re-guard on background → foreground (v2.7.1 — scenePhase)

    /// Reveal-All in the grid, BACKGROUND the app, then reactivate it. The
    /// reveal is view-scoped and must be dropped on `.background`, so on return
    /// the bulk block (blurred shield) is back. Prior bug: reveal survived
    /// backgrounding and the content stayed visible after foregrounding.
    func testGridRevealReGuardsAfterBackgrounding() {
        let app = launch(age: "verifiedAdult", flag: "all")

        // Reveal everything.
        XCTAssertTrue(waitFor(app, "sca.bulk.revealAll"))
        element(app, "sca.bulk.revealAll").tap()
        XCTAssertTrue(waitFor(app, "sca.cell.tile-0.revealed"),
                      "Reveal All must un-blur the content first")

        // Background the app, then bring it back to the foreground.
        XCUIDevice.shared.press(.home)
        app.activate()
        dismissSystemAlerts()

        // Content must be BLURRED AGAIN — the bulk block returns and the cell is
        // shielded once more (the scenePhase .background re-guard fired).
        XCTAssertTrue(waitFor(app, "sca.bulk.revealAll", timeout: 12),
                      "Foregrounding must restore the bulk block — reveal must NOT survive backgrounding")
        XCTAssertTrue(element(app, "sca.cell.tile-0.shielded").exists,
                      "The cell must be re-shielded after returning from background")
        XCTAssertFalse(element(app, "sca.cell.tile-0.revealed").exists,
                       "Content must not remain revealed after backgrounding the app")
    }

    // MARK: 8. Slideshow bulk block — persistent Done + share leak gated (v2.7.2)

    /// CRITICAL gap (v2.7.2): when the WHOLE gallery is sensitive and the app
    /// opens straight into the SLIDESHOW (Ari / Enter Space), the slideshow must
    /// present the SAME bulk block the grid does — a persistent, always-on-top
    /// Done (never auto-hidden) plus an adult-gated Reveal All. Previously the
    /// slideshow had NO bulk block, so the shield covered the content and the
    /// auto-hiding Close sat UNDER it: the user was STUCK with no Done. This test
    /// (undetermined viewer — no direct reveal) asserts EXACTLY ONE Done exists,
    /// it DISMISSES the gallery without revealing, and the Share control is ABSENT
    /// while blocked.
    func testSlideshowBulkBlockHasSingleDoneAndNoShareUndetermined() {
        let app = launch(age: "undetermined", flag: "all", start: "slideshow", startIndex: 0)

        // The slideshow's persistent bulk Done must appear and be hittable above
        // the shield.
        let bulkDone = element(app, "sca.bulk.done")
        XCTAssertTrue(bulkDone.waitForExistence(timeout: 12),
                      "A fully-sensitive slideshow must show the bulk block's persistent Done")
        XCTAssertTrue(bulkDone.isHittable,
                      "The slideshow bulk Done must be hittable on top of the shield")

        // EXACTLY ONE Done may exist in this state.
        let doneButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
        XCTAssertEqual(doneButtons.count, 1,
                       "Exactly one Done must be visible while the slideshow is fully blocked")

        // The Share control must be ABSENT while the sensitive item is unrevealed —
        // no exfiltration of unrevealed sensitive media.
        XCTAssertFalse(element(app, "sca.slideshow.share").exists,
                       "Share must be absent while the slideshow item is sensitive and unrevealed")
        XCTAssertFalse(app.buttons["Download"].exists,
                       "Download must be absent while the slideshow item is sensitive and unrevealed")

        // The single Done DISMISSES the gallery without revealing — straight back
        // to the harness (a direct slideshow entry fully exits, not back to grid).
        bulkDone.tap()
        XCTAssertTrue(waitFor(app, "demo.openGrid"),
                      "The single slideshow Done must dismiss the gallery without revealing")
    }

    /// Verified-adult counterpart: the slideshow bulk block offers Reveal All;
    /// after revealing, the block clears and the Share control RETURNS (the now-
    /// revealed item is exportable). Confirms the share-gate is keyed on the
    /// shielded state, not a blanket disable.
    func testSlideshowBulkBlockRevealAllRestoresShareVerifiedAdult() {
        let app = launch(age: "verifiedAdult", flag: "all", start: "slideshow", startIndex: 0)

        // Bulk block with Reveal All, and Share gated off while blocked.
        XCTAssertTrue(waitFor(app, "sca.bulk.revealAll"),
                      "A verified adult must see Reveal All on the fully-blocked slideshow")
        XCTAssertFalse(element(app, "sca.slideshow.share").exists,
                       "Share must be hidden while the slideshow is bulk blocked")

        // Reveal everything — the block clears.
        element(app, "sca.bulk.revealAll").tap()
        XCTAssertTrue(waitFor(app, "sca.slideshow.tile-0.revealed"),
                      "Reveal All must un-blur the current slideshow item")

        // The transport chrome may auto-hide; tap the viewer to toggle controls
        // back so the (now-allowed) Share button is on screen. Retry the toggle
        // once since a single tap could hide controls that were already showing.
        XCTAssertTrue(waitFor(app, "sca.slideshow.tile-0.revealed", timeout: 6))
        let share = button(app, "sca.slideshow.share")
        if !share.waitForExistence(timeout: 3) {
            app.tap()
            if !share.waitForExistence(timeout: 3) { app.tap() }
        }
        XCTAssertTrue(share.waitForExistence(timeout: 8),
                      "Share must RETURN once the slideshow item is revealed")

        // And the bulk block is gone (no more Reveal All / bulk Done).
        XCTAssertFalse(element(app, "sca.bulk.revealAll").exists,
                       "Reveal All must disappear once everything is revealed")
        XCTAssertFalse(element(app, "sca.bulk.done").exists,
                       "The bulk Done must disappear once the gallery is no longer blocked")
    }

    /// A MINOR opening straight into a fully-sensitive slideshow must get NO
    /// Reveal All but MUST still be able to leave via the persistent Done.
    func testSlideshowBulkBlockMinorNoRevealButCanDismiss() {
        let app = launch(age: "minor", flag: "all", start: "slideshow", startIndex: 0)

        let bulkDone = element(app, "sca.bulk.done")
        XCTAssertTrue(bulkDone.waitForExistence(timeout: 12),
                      "A minor in a fully-blocked slideshow must still get a persistent Done")
        XCTAssertFalse(element(app, "sca.bulk.revealAll").exists,
                       "A minor must never see Reveal All in the slideshow")
        XCTAssertFalse(element(app, "sca.slideshow.share").exists,
                       "A minor must never be able to share unrevealed sensitive media")
        XCTAssertTrue(bulkDone.isHittable,
                      "A minor must always be able to dismiss the blocked slideshow")
        bulkDone.tap()
        XCTAssertTrue(waitFor(app, "demo.openGrid"),
                      "The minor's Done must dismiss the blocked slideshow")
    }

    // MARK: 9. Re-guard on background → foreground (v2.7.1 — scenePhase)

    /// Same re-guard, exercised in the full-screen slideshow: reveal a shielded
    /// item, background, reactivate, and assert it is shielded again.
    func testSlideshowRevealReGuardsAfterBackgrounding() {
        let app = launch(age: "verifiedAdult", flag: "some",
                         start: "slideshow", startIndex: 1)

        _ = element(app, "sca.slideshow.tile-1.shielded").waitForExistence(timeout: 10)
        dismissSystemAlerts()

        let revealBtn = button(app, "sca.slideshow.reveal")
        XCTAssertTrue(revealBtn.waitForExistence(timeout: 10),
                      "The slideshow must offer a reveal control for the shielded item")
        revealBtn.tap()
        XCTAssertTrue(waitFor(app, "sca.slideshow.tile-1.revealed"),
                      "The item must reveal first")

        // Background → foreground.
        XCUIDevice.shared.press(.home)
        app.activate()
        dismissSystemAlerts()

        // The slideshow item must be shielded again on return.
        XCTAssertTrue(waitFor(app, "sca.slideshow.tile-1.shielded", timeout: 12),
                      "Foregrounding must re-blur the slideshow item — reveal must NOT survive backgrounding")
        XCTAssertFalse(element(app, "sca.slideshow.tile-1.revealed").exists,
                       "The slideshow item must not remain revealed after backgrounding")
    }

    // MARK: 10. Persistent shielded nav (v2.7.3) — per-item dismiss + back-to-grid

    /// DEFECT 1 (v2.7.3): when the CURRENT slideshow item is INDIVIDUALLY shielded
    /// (minority sensitive → NOT bulk blocked) the auto-hiding transport Close sat
    /// UNDER the shield, leaving the user STUCK with no way out. The slideshow now
    /// layers a PERSISTENT, never-auto-hidden nav bar ABOVE the shield carrying a
    /// Dismiss control. This test opens straight into the slideshow on a shielded
    /// tile as an UNDETERMINED viewer (no direct reveal), asserts the persistent
    /// Dismiss is present + reachable, and that tapping it LEAVES the gallery.
    func testPerItemShieldedSlideshowHasReachableDismiss() {
        // flag=some flags only a MINORITY (tiles 1 & 3) so the bulk block does
        // NOT fire — the per-item shield path is exercised. startIndex defaults
        // to the first sensitive tile (1), which opens shielded.
        let app = launch(age: "undetermined", flag: "some", start: "slideshow", startIndex: 1)

        // Wait for the shielded slideshow item to settle; clear any system sheet.
        _ = element(app, "sca.slideshow.tile-1.shielded").waitForExistence(timeout: 12)
        dismissSystemAlerts()
        XCTAssertTrue(element(app, "sca.slideshow.tile-1.shielded").exists,
                      "The slideshow must open on an individually shielded item")

        // The persistent Dismiss must be present and HITTABLE above the shield —
        // this is the fix for being stuck under a per-item shield.
        let dismiss = button(app, "sca.slideshow.persistentDismiss")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10),
                      "A persistent Dismiss must be reachable whenever the current item is shielded")
        XCTAssertTrue(dismiss.isHittable,
                      "The persistent Dismiss must be hittable on top of the per-item shield")

        // Tapping it must LEAVE the gallery (direct entry fully exits to harness).
        dismiss.tap()
        if !waitFor(app, "demo.openGrid", timeout: 6) {
            dismissSystemAlerts()
            if button(app, "sca.slideshow.persistentDismiss").exists {
                button(app, "sca.slideshow.persistentDismiss").tap()
            }
        }
        XCTAssertTrue(waitFor(app, "demo.openGrid"),
                      "The persistent Dismiss must leave the shielded slideshow back to the harness")
    }

    /// DEFECT 2 (v2.7.3): the slideshow in `MediaGalleryFullView` must ALWAYS
    /// offer a Back-to-grid arrow that RETURNS to the thumbnails (not a plain
    /// dismiss) — the prior `enteredSlideshowDirectly ? nil : …` stripped it for
    /// hosts that open straight into the slideshow. Open into the slideshow on a
    /// NON-sensitive item (so the normal transport bar with the Back-to-grid arrow
    /// is reachable, no shield), tap the arrow, and assert the grid is shown again
    /// (the slideshow is gone and the grid toolbar Done — proof the grid is live —
    /// is reachable).
    func testGridEntrySlideshowShowsBackToGridAndReturns() {
        // flag=some flags only tiles 1 & 3, so startIndex 0 opens the slideshow on
        // a NON-sensitive item: no shield, normal transport chrome, and (because
        // MediaGalleryFullView always owns a grid) a Back-to-grid arrow.
        let app = launch(age: "verifiedAdult", flag: "some", start: "slideshow", startIndex: 0)

        // Settle, then surface the (auto-hiding) transport chrome.
        _ = element(app, "sca.slideshow.tile-0.revealed").waitForExistence(timeout: 12)
        dismissSystemAlerts()
        let backToGrid = button(app, "sca.slideshow.backToGrid")
        if !backToGrid.waitForExistence(timeout: 6) {
            app.tap()  // toggle the transport chrome back on
        }
        XCTAssertTrue(backToGrid.waitForExistence(timeout: 8),
                      "The slideshow must ALWAYS offer a Back-to-grid arrow (a grid exists)")

        // Tapping it must RETURN to the grid — the slideshow chrome disappears and
        // the grid toolbar's Done becomes reachable again (proves it went to the
        // grid, NOT a plain dismiss out of the gallery).
        backToGrid.tap()
        let toolbarDone = app.buttons["Done"].firstMatch
        XCTAssertTrue(toolbarDone.waitForExistence(timeout: 8),
                      "Back-to-grid must return to the thumbnail grid (toolbar Done present)")
        XCTAssertFalse(button(app, "sca.slideshow.backToGrid").exists,
                       "After Back-to-grid the slideshow (and its arrow) must be gone")
        // It must NOT have dismissed the whole gallery — the harness's openGrid is
        // only visible when the gallery has fully closed.
        XCTAssertFalse(element(app, "demo.openGrid").exists,
                       "Back-to-grid must NOT fully dismiss the gallery to the harness")
    }

    /// DEFECT-reconcile (v2.7.3): the bulk-block slideshow must STILL expose a
    /// single reachable Done — the persistent per-item Dismiss is suppressed in
    /// the bulk case so the block's own `sca.bulk.done` stays the one exit.
    func testBulkBlockSlideshowStillHasReachableDone() {
        let app = launch(age: "verifiedAdult", flag: "all", start: "slideshow", startIndex: 0)

        let bulkDone = element(app, "sca.bulk.done")
        XCTAssertTrue(bulkDone.waitForExistence(timeout: 12),
                      "A fully-blocked slideshow must still show the bulk block's Done")
        XCTAssertTrue(bulkDone.isHittable,
                      "The bulk Done must be hittable on top of the shield")

        // Exactly one labelled Done — the persistent Dismiss is an xmark (not
        // "Done") AND is suppressed in the bulk case, so nothing duplicates it.
        let doneButtons = app.buttons.matching(NSPredicate(format: "label == %@", "Done"))
        XCTAssertEqual(doneButtons.count, 1,
                       "Exactly one Done must remain while the slideshow is bulk blocked")

        // And it dismisses the gallery.
        bulkDone.tap()
        XCTAssertTrue(waitFor(app, "demo.openGrid"),
                      "The bulk slideshow Done must dismiss the gallery")
    }
}
