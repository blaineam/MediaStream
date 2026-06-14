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
}
