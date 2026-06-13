//
//  SensitiveContent.swift
//  MediaStream
//
//  UNIFIED sensitive-content guard for every app that consumes MediaStream
//  (Enter Space, Ari, …). Both apps previously reimplemented this guard and
//  DIVERGED — Ari's gallery "blur" was an extreme 12-pixel decode (looked
//  pixelated, not blurred) and its reveal often failed to appear, while
//  Enter Space used a smooth gaussian blur with a working reveal. This file
//  collapses both into ONE implementation so the two apps behave IDENTICALLY.
//
//  WHAT LIVES HERE (shared, app-agnostic):
//    • SensitiveContentVerdict — the per-item analysis outcome.
//    • SensitiveShieldPresentation + decide(...) — THE single decision table
//      (minor / undetermined / verified-adult / bypass / fail-closed). This
//      is the only place the reveal-policy matrix is expressed.
//    • SensitiveContentPolicy — the protocol the APP injects. Age
//      verification is app-specific (Declared Age Range gating differs per
//      bundle / entitlement), so each app adapts its own guard
//      (ES SensitiveMediaGuard, Ari SensitiveContentGuard) to this protocol.
//    • SensitiveBlurRenderer — the SMOOTH gaussian-blur bitmap renderer for
//      gallery surfaces that can only display pixels obtained from a
//      MediaItem (the MediaStream gallery). Replaces Ari's 12px pixelate.
//    • SensitiveContentShield / ConversationSensitiveBlock — the shared
//      SwiftUI presentation: a single smooth-blur interstitial over the real
//      thumbnail, the age-gated reveal affordance, gallery BULK-block, and
//      the FULL-SCREEN conversation block (covers nav + input, no
//      auto-dismiss). The decision logic lives ONCE in decide(...).
//    • SensitiveGalleryPolicy — bulk-block threshold + gallery wrap seam.
//
//  WHAT STAYS IN EACH APP (injected via SensitiveContentPolicy):
//    • The age-verification guard (Declared Age Range request, persisted age
//      status, the SCA analyzer instance, the adult-bypass toggle). Each app
//      keeps its own object and conforms it to SensitiveContentPolicy.
//

import SwiftUI
import Foundation
import ImageIO
import CoreGraphics
import CoreText

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Verdict

/// Outcome of analyzing one media item.
public enum SensitiveContentVerdict: Equatable, Sendable {
    /// Analysis ran and the item is fine (or the guard is inactive).
    case safe
    /// Analysis ran and flagged the item.
    case sensitive
    /// Analysis could NOT run (unreadable data, decrypt failure, SCA error).
    /// FAIL CLOSED: treated as flagged. Apps must NOT cache this, so a later
    /// attempt re-runs the analysis.
    case analysisFailed
}

// MARK: - Presentation decision (pure, unit-tested)

/// What the shield overlay should render for a given verdict + policy state.
/// Pure decision table so the minor / undetermined / verified-adult matrix is
/// unit-testable without SwiftUI. This is THE single place the reveal policy
/// is expressed for both apps.
public enum SensitiveShieldPresentation: Equatable, Sendable {
    /// Item shown normally (safe, revealed, or guard inactive/pending).
    case none
    /// Blur, "Sensitive Content", NO reveal affordance (verified minor, or
    /// undetermined where verification can't run — e.g. macOS).
    case sensitiveNoReveal
    /// Blur, "Sensitive Content", "Show Anyway" (verified 18+ only).
    case sensitiveWithReveal
    /// Blur, "Sensitive Content", "Verify Age to Reveal" (age UNDETERMINED
    /// and the Declared Age Range request can run).
    case sensitiveVerifyAge
    /// Analysis failed; fail closed with NO reveal (minor / can't verify).
    case errorNoReveal
    /// Analysis failed; error-state card with manual reveal (verified 18+).
    case errorWithReveal
    /// Analysis failed; fail closed, but the undetermined user may verify.
    case errorVerifyAge

    public var showsRevealButton: Bool {
        self == .sensitiveWithReveal || self == .errorWithReveal
    }

    /// "Verify Age to Reveal" affordance — never an actual reveal; it only
    /// launches the system Declared Age Range sheet. Verified 18+ unlocks the
    /// normal Show Anyway path; minor/declined/error stays locked.
    public var showsVerifyAgeButton: Bool {
        self == .sensitiveVerifyAge || self == .errorVerifyAge
    }

    public var isShielded: Bool { self != .none }

    public var isErrorState: Bool {
        self == .errorWithReveal || self == .errorNoReveal || self == .errorVerifyAge
    }

    /// THE reveal-policy gate: only a verified-18+ user ever gets a reveal
    /// affordance. A verified minor gets blur with no way through. An
    /// UNDETERMINED user gets no reveal either, but — when the platform can
    /// run the Declared Age Range request — a "Verify Age to Reveal"
    /// affordance that invokes the system sheet. Errors fail closed.
    public static func decide(
        verdict: SensitiveContentVerdict?,
        guardActive: Bool,
        revealed: Bool,
        canReveal: Bool,
        canRequestVerification: Bool = false
    ) -> SensitiveShieldPresentation {
        guard guardActive, let verdict else { return .none }
        switch verdict {
        case .safe:
            return .none
        case .sensitive:
            if revealed && canReveal { return .none }
            if canReveal { return .sensitiveWithReveal }
            return canRequestVerification ? .sensitiveVerifyAge : .sensitiveNoReveal
        case .analysisFailed:
            if revealed && canReveal { return .none }
            if canReveal { return .errorWithReveal }
            return canRequestVerification ? .errorVerifyAge : .errorNoReveal
        }
    }
}

// MARK: - Injected policy

/// The seam each app injects. Age verification is app-specific (each bundle
/// gates Declared Age Range differently), so the host app adapts its own
/// guard object to this protocol and the shared SwiftUI views observe it.
///
/// Conformers are `ObservableObject` so the shared views re-render when reveal
/// state / age status / the bypass toggle change. All members are
/// MainActor-isolated because the SwiftUI surfaces read them on the main actor.
@MainActor
public protocol SensitiveContentPolicy: ObservableObject {
    /// True when interstitials should appear at all: the OS SCA policy is on
    /// AND no verified-adult bypass is in effect.
    var isGuardActive: Bool { get }
    /// Reveal affordances exist only for verified adults.
    var canReveal: Bool { get }
    /// "Verify Age to Reveal" is offered while the age is UNDETERMINED and the
    /// platform can run the Declared Age Range request.
    var canRequestVerificationFromShield: Bool { get }

    /// Per-item reveal ("Show Anyway"), session-only, verified-adult ONLY.
    func isRevealed(_ key: String) -> Bool
    /// No-op unless the user is a verified adult (defense in depth).
    func reveal(_ key: String)
    /// BULK reveal — a verified adult's single unblock on a gallery/conversation
    /// block reveals EVERY sensitive item in the session (so the whole surface
    /// un-blurs at once, not item-by-item). Session-only and a structural no-op
    /// for anyone who isn't a verified adult. `isRevealed(_:)` must return true
    /// for all keys once this has fired.
    func revealAll()

    /// Analyze the bytes behind `key` (or return the cached session verdict).
    /// Returns `.safe` when the guard is inactive; `.analysisFailed` (fail
    /// closed, NOT cached) when analysis can't run.
    ///
    /// The data provider closure is explicitly `@concurrent` so this protocol
    /// requirement has the SAME type in every consuming target regardless of
    /// whether that target builds with `NonisolatedNonsendingByDefault`
    /// (Enter Space's app target has it on, its file-provider targets do not —
    /// without the explicit annotation the inferred isolation diverges and the
    /// shared conformance fails to type-check).
    #if compiler(>=6.3)
    // Swift 6.3+ (Xcode 26): `@concurrent` and `@Sendable` are DISTINCT
    // attributes. The explicit `@concurrent` keeps the closure's isolation
    // identical across consuming targets regardless of
    // `NonisolatedNonsendingByDefault` (see note above).
    func verdict(forKey key: String,
                 dataProvider: @escaping @concurrent @Sendable () async -> Data?) async -> SensitiveContentVerdict
    #else
    // Swift < 6.3 (e.g. Xcode 16 CI runner): `@concurrent` was the old spelling
    // of `@Sendable`, so writing both is a "duplicate attribute" error. On these
    // toolchains `@Sendable` alone has the same effect.
    func verdict(forKey key: String,
                 dataProvider: @escaping @Sendable () async -> Data?) async -> SensitiveContentVerdict
    #endif

    /// Launch the system age-range request (from the "Verify Age to Reveal"
    /// affordance). Returns the new verified-adult flag.
    @discardableResult
    func requestAdultVerification() async -> Bool

    /// User-facing message for the most recent verification attempt, or nil.
    var verificationFeedbackMessage: String? { get }
    func clearVerificationOutcome()

    /// Cache read only (never triggers analysis): true when ANY of `keys` has
    /// already analyzed `.sensitive`. Powers the conversation / gallery
    /// bulk-block without re-analyzing anything.
    func anySensitive(in keys: [String]) -> Bool
}

// MARK: - Bulk-block policy

/// Decides when a whole gallery / conversation should be blocked by ONE
/// interstitial rather than per-item shields. A verified adult's single
/// "Show Anyway" then bulk-reveals every item; minors never get bulk reveal.
public enum SensitiveBulkPolicy {
    /// Block the whole surface when at least this fraction of items are
    /// sensitive…
    public static let fractionThreshold: Double = 0.25
    /// …or at least this many absolute items are sensitive (whichever hits
    /// first). Keeps small galleries (2–3 flagged of 4) bulk-blocking too.
    public static let countThreshold: Int = 3

    /// True when `sensitiveCount` of `totalCount` warrants a bulk block.
    public static func shouldBulkBlock(sensitiveCount: Int, totalCount: Int) -> Bool {
        guard totalCount > 0, sensitiveCount > 0 else { return false }
        if sensitiveCount >= countThreshold { return true }
        return Double(sensitiveCount) / Double(totalCount) >= fractionThreshold
    }
}

// MARK: - Smooth-blur bitmap renderer (gallery seam)

/// Renders the SMOOTH gaussian-blur "Sensitive Content" interstitial as an
/// IMAGE, for surfaces (the MediaStream gallery) that can only display pixels
/// obtained from a MediaItem and cannot host the SwiftUI shield overlay.
///
/// This REPLACES Ari's old 12-pixel decode (which read as a coarse pixelate,
/// not a blur). The original thumbnail is decoded at a bounded size, run
/// through a real CIGaussianBlur, darkened with a thin scrim, and stamped with
/// an eye.slash glyph + "Sensitive" label — visually identical to Enter
/// Space's overlay. When no bytes are available a neutral dark card is drawn.
public enum SensitiveBlurRenderer {

    /// Bounded decode for the blur base (the blurred shield is shown small;
    /// the full bitmap is never needed and a 48 MP decode would jetsam).
    public static let blurMaxPixelSize = 1_024

    /// A heavily-but-SMOOTHLY blurred copy of `image` with an eye.slash badge
    /// + "Sensitive" label baked in. `isError` swaps the glyph/label to the
    /// fail-closed "Couldn't Check" state.
    public static func blurredImage(from image: PlatformImage, isError: Bool = false) -> PlatformImage {
        let fallbackSize = boundedSize(for: image)
        guard let cg = boundedCGImage(from: image, maxPixelSize: blurMaxPixelSize) else {
            return card(size: fallbackSize, isError: isError)
        }
        let input = CIImage(cgImage: cg)
        let clamped = input.clampedToExtent()
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else {
            return card(size: fallbackSize, isError: isError)
        }
        blurFilter.setValue(clamped, forKey: kCIInputImageKey)
        // Radius scales with the image so small thumbs and large previews are
        // equally unreadable.
        let radius = max(8, min(input.extent.width, input.extent.height) * 0.08)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let blurred = blurFilter.outputImage,
              let blurredCG = ciContext.createCGImage(blurred, from: input.extent) else {
            return card(size: fallbackSize, isError: isError)
        }
        let renderSize = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        return renderer.image { ctx in
            UIImage(cgImage: blurredCG).draw(in: CGRect(origin: .zero, size: renderSize))
            ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: renderSize))
            drawBadge(in: ctx.cgContext, size: renderSize, isError: isError, flipped: false)
        }
        #elseif canImport(AppKit)
        return NSImage(size: renderSize, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.draw(blurredCG, in: rect)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.fill(rect)
            drawBadge(in: ctx, size: rect.size, isError: isError, flipped: true)
            return true
        }
        #endif
    }

    /// Neutral dark "Sensitive Content" card — last resort when the real image
    /// can't be decoded/blurred at all. Never derived from flagged pixels.
    public static func card(size: CGSize, isError: Bool = false) -> PlatformImage {
        let size = CGSize(width: max(size.width, 64), height: max(size.height, 64))
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(CGColor(gray: 0.18, alpha: 1))
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))
            drawBadge(in: ctx.cgContext, size: size, isError: isError, flipped: false)
        }
        #elseif canImport(AppKit)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(CGColor(gray: 0.18, alpha: 1))
            ctx.fill(rect)
            drawBadge(in: ctx, size: rect.size, isError: isError, flipped: true)
            return true
        }
        #endif
    }

    // MARK: Badge

    private static func drawBadge(in ctx: CGContext, size: CGSize, isError: Bool, flipped: Bool) {
        let side = min(size.width, size.height)
        let drawLabel = side >= 120
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + (drawLabel ? side * 0.06 : 0))
        let r = side * 0.13
        ctx.setStrokeColor(CGColor(gray: 0.95, alpha: 0.95))
        ctx.setLineWidth(max(2, side * 0.018))
        ctx.setLineCap(.round)
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.move(to: CGPoint(x: center.x - r * 1.4, y: center.y - r * 1.4))
        ctx.addLine(to: CGPoint(x: center.x + r * 1.4, y: center.y + r * 1.4))
        ctx.strokePath()

        guard drawLabel else { return }
        let text = (isError ? "Couldn't Check" : "Sensitive") as NSString
        let fontSize = side * 0.075
        #if canImport(UIKit)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        #elseif canImport(AppKit)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        #endif
        let textSize = text.size(withAttributes: attrs)
        let textOrigin = CGPoint(
            x: (size.width - textSize.width) / 2,
            y: center.y - r * 2.6 - textSize.height / 2
        )
        // Both UIGraphicsImageRenderer and the flipped NSImage block draw text
        // upright with NSString.draw, so no manual flip is needed here.
        _ = flipped
        text.draw(at: textOrigin, withAttributes: attrs)
    }

    // MARK: Decode helpers

    private static func boundedSize(for image: PlatformImage) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return CGSize(width: 512, height: 512) }
        let maxSide = max(size.width, size.height)
        let scale = maxSide > 1024 ? 1024 / maxSide : 1
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    public static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        if let cg = image.cgImage { return cg }
        // CIImage-backed UIImages have no cgImage — render real pixels.
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale > 0 ? image.scale : 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    /// Memory-bounded CGImage for the analysis / blur paths.
    public static func boundedCGImage(from image: PlatformImage, maxPixelSize: Int = 2_048) -> CGImage? {
        guard let full = cgImage(from: image) else { return nil }
        let maxSide = max(full.width, full.height)
        guard maxSide > maxPixelSize else { return full }
        #if canImport(UIKit)
        guard let data = UIImage(cgImage: full).jpegData(compressionQuality: 0.9)
                ?? UIImage(cgImage: full).pngData() else { return full }
        #elseif canImport(AppKit)
        let rep = NSBitmapImageRep(cgImage: full)
        guard let data = rep.representation(using: .jpeg, properties: [:]) else { return full }
        #endif
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return full }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) ?? full
    }
}

// MARK: - Per-item shield (SwiftUI)

extension View {
    /// Guards this media view with a sensitive-content interstitial. `key`
    /// must be stable per item; `dataProvider` supplies the PLAINTEXT image
    /// bytes and only runs when the guard is active. `compact` drops the
    /// text/button for tiny row thumbnails.
    public func sensitiveContentShield<P: SensitiveContentPolicy>(
        key: String,
        policy: P,
        cornerRadius: CGFloat = 12,
        compact: Bool = false,
        dataProvider: @escaping @Sendable () async -> Data?
    ) -> some View {
        modifier(SensitiveContentShieldModifier(key: key,
                                                policy: policy,
                                                cornerRadius: cornerRadius,
                                                compact: compact,
                                                dataProvider: dataProvider))
    }
}

public struct SensitiveContentShieldModifier<P: SensitiveContentPolicy>: ViewModifier {
    let key: String
    @ObservedObject var policy: P
    let cornerRadius: CGFloat
    let compact: Bool
    let dataProvider: @Sendable () async -> Data?

    @State private var verdict: SensitiveContentVerdict?
    @State private var isRequestingVerification = false
    @State private var showVerificationFeedback = false

    private var presentation: SensitiveShieldPresentation {
        SensitiveShieldPresentation.decide(
            verdict: verdict,
            guardActive: policy.isGuardActive,
            revealed: policy.isRevealed(key),
            canReveal: policy.canReveal,
            canRequestVerification: policy.canRequestVerificationFromShield
        )
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                let presentation = self.presentation
                if presentation.isShielded {
                    shield(for: presentation)
                }
            }
            .task(id: TaskKey(key: key, guardActive: policy.isGuardActive)) {
                guard policy.isGuardActive else {
                    verdict = nil
                    return
                }
                verdict = await policy.verdict(forKey: key, dataProvider: dataProvider)
            }
    }

    private func shield(for presentation: SensitiveShieldPresentation) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.ultraThinMaterial)
            if compact {
                Image(systemName: presentation.isErrorState ? "exclamationmark.triangle.fill" : "eye.slash.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: presentation.isErrorState ? "exclamationmark.triangle.fill" : "eye.slash.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(presentation.isErrorState ? "Couldn't Check Media" : "Sensitive Content")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if presentation.showsRevealButton {
                        Button("Show Anyway") { policy.reveal(key) }
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if presentation.showsVerifyAgeButton {
                        Text("Age not verified — verify to enable reveal")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            requestVerification()
                        } label: {
                            if isRequestingVerification {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Verify Age to Reveal")
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRequestingVerification)
                    }
                }
                .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onTapGesture {}
        .alert("Age Verification", isPresented: $showVerificationFeedback) {
            Button("OK") { policy.clearVerificationOutcome() }
        } message: {
            Text(policy.verificationFeedbackMessage ?? "")
        }
    }

    private func requestVerification() {
        guard !isRequestingVerification else { return }
        isRequestingVerification = true
        Task {
            let verified = await policy.requestAdultVerification()
            isRequestingVerification = false
            if !verified {
                showVerificationFeedback = policy.verificationFeedbackMessage != nil
            } else {
                policy.clearVerificationOutcome()
                // A successful Declared Age Range verification flips the whole
                // session's reveal capability on (the same effect Settings
                // "Verify Age" has), so the just-verified adult sees the
                // content WITHOUT a second "Reveal All"/"Show Anyway" tap. The
                // verify-age affordance is only ever offered to an undetermined
                // adult, and revealAll() is a structural no-op for anyone who
                // isn't a verified adult — so this can't punch through policy.
                policy.revealAll()
            }
        }
    }

    private struct TaskKey: Equatable, Hashable {
        let key: String
        let guardActive: Bool
    }
}

// MARK: - Full-screen conversation / surface block (SwiftUI)

extension View {
    /// Blocks an entire OPEN surface (an Ari conversation transcript, etc.)
    /// with ONE full-screen smooth-blur interstitial when it is flagged
    /// sensitive and the viewer can't reveal — instead of force-closing it.
    ///
    /// The block COVERS THE FULL SCREEN (it `.ignoresSafeArea()`, so it
    /// extends beneath the input field AND the top nav/menu bar as one
    /// cohesive surface) and STAYS until the user navigates away — there is no
    /// auto-dismiss. A verified adult unblocks once → BULK-reveals all media
    /// in the surface (the single `blockKey` reveal). Minors get blur + an
    /// explanation, no unblock.
    public func sensitiveSurfaceBlock<P: SensitiveContentPolicy>(
        blockKey: String,
        policy: P,
        flaggedSensitive: Bool
    ) -> some View {
        modifier(SensitiveSurfaceBlockModifier(blockKey: blockKey,
                                               policy: policy,
                                               flaggedSensitive: flaggedSensitive,
                                               topInteractivePassthrough: 0))
    }

    /// Same FULL-BLEED block, but the top `topInteractivePassthrough` points
    /// (the custom nav/header bar region, INCLUDING the top safe-area inset the
    /// host folds in) DRAW under the cover yet do NOT capture touches — so the
    /// host's custom header buttons (drawer / new-conversation / menu) that sit
    /// BENEATH this overlay in the same container stay tappable and the user can
    /// navigate away themselves. The visual blur still extends full-screen under
    /// the translucent bar; only the hit-test region is inset from the top.
    ///
    /// Use this overload when the host's top bar is a CUSTOM in-content HStack
    /// (Ari's `headerView`) rather than a system NavigationStack toolbar — a
    /// system toolbar renders above an in-content overlay automatically, a
    /// custom header does not. Pass the header bar height plus the top safe-area
    /// inset as `topInteractivePassthrough`. ari.guards.convo-blur-cohesion.
    public func sensitiveSurfaceBlock<P: SensitiveContentPolicy>(
        blockKey: String,
        policy: P,
        flaggedSensitive: Bool,
        topInteractivePassthrough: CGFloat
    ) -> some View {
        modifier(SensitiveSurfaceBlockModifier(blockKey: blockKey,
                                               policy: policy,
                                               flaggedSensitive: flaggedSensitive,
                                               topInteractivePassthrough: topInteractivePassthrough))
    }
}

public struct SensitiveSurfaceBlockModifier<P: SensitiveContentPolicy>: ViewModifier {
    let blockKey: String
    @ObservedObject var policy: P
    let flaggedSensitive: Bool
    /// When > 0, the top this-many points of the cover draw the blur but pass
    /// touches THROUGH to the host's custom header buttons beneath this overlay.
    var topInteractivePassthrough: CGFloat = 0

    @State private var isRequestingVerification = false
    @State private var showVerificationFeedback = false

    private var presentation: SensitiveShieldPresentation {
        guard policy.isGuardActive, flaggedSensitive else { return .none }
        return SensitiveShieldPresentation.decide(
            verdict: .sensitive,
            guardActive: policy.isGuardActive,
            revealed: policy.isRevealed(blockKey),
            canReveal: policy.canReveal,
            canRequestVerification: policy.canRequestVerificationFromShield
        )
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                let presentation = self.presentation
                if presentation.isShielded {
                    block(for: presentation)
                        .transition(.opacity)
                }
            }
            // No auto-dismiss: the block stays until the surface is navigated
            // away or a verified adult reveals it.
            .animation(.easeInOut(duration: 0.2), value: presentation)
    }

    private func block(for presentation: SensitiveShieldPresentation) -> some View {
        ZStack {
            // ONE cohesive full-screen surface — extends under the nav bar, the
            // input field, AND the keyboard via ignoresSafeArea(.all). The host
            // must install this block on its OUTERMOST container (not an inner
            // message-scroll area inset by the chrome) for the cover to actually
            // reach the top/bottom bars. An opaque scrim sits over the material
            // so no chrome reads through the translucency at the screen edges.
            //
            // VISUAL layer: full-bleed blur + scrim, hit-testing DISABLED so it
            // never swallows touches. When topInteractivePassthrough > 0 the
            // touch-capturing layer below is inset from the top, letting the
            // host's custom header buttons (which sit BENEATH this overlay)
            // receive their taps while the blur still paints under them.
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(.all)
                .allowsHitTesting(false)
            Rectangle().fill(Color.primary.opacity(0.04)).ignoresSafeArea(.all)
                .allowsHitTesting(false)
            // Touch-absorbing layer: captures stray taps on the blurred body so
            // the (now hidden) transcript beneath can't be interacted with, but
            // leaves the top `topInteractivePassthrough` points free so the
            // header bar stays tappable. With passthrough == 0 it fills the
            // whole cover (gallery / non-custom-header hosts), preserving the
            // original "absorb everything" behavior.
            VStack(spacing: 0) {
                if topInteractivePassthrough > 0 {
                    Color.clear
                        .frame(height: topInteractivePassthrough)
                        .allowsHitTesting(false)
                }
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
            .ignoresSafeArea(.all)
            VStack(spacing: 12) {
                Image(systemName: "eye.slash.fill")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Sensitive Content")
                    .font(.headline)
                Text(explanation(for: presentation))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if presentation.showsRevealButton {
                    Button {
                        // BULK reveal: unblock EVERY sensitive item in the
                        // surface at once (reported: a single reveal "did not
                        // unblur all"). revealAll() reveals the whole session so
                        // the per-item shields underneath all un-blur together.
                        policy.revealAll()
                    } label: {
                        Label("Reveal All", systemImage: "eye.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                if presentation.showsVerifyAgeButton {
                    Button {
                        requestVerification()
                    } label: {
                        if isRequestingVerification {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Verify Your Age in Settings", systemImage: "person.badge.shield.checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isRequestingVerification)
                }
            }
            .padding(20)
        }
        // Touch handling lives on the inset absorbing layer above (so the top
        // header region can pass through). No outer contentShape/onTapGesture
        // here — that would re-capture the whole frame and re-block the header.
        .alert("Age Verification", isPresented: $showVerificationFeedback) {
            Button("OK") { policy.clearVerificationOutcome() }
        } message: {
            Text(policy.verificationFeedbackMessage ?? "")
        }
    }

    private func explanation(for presentation: SensitiveShieldPresentation) -> String {
        if presentation.showsRevealButton {
            return "This conversation contains sensitive content. Tap Reveal to view it."
        }
        if presentation.showsVerifyAgeButton {
            return "Blurred: sensitive content. Verify your age in Settings to reveal it."
        }
        return "This conversation contains sensitive content and can't be revealed on this account."
    }

    private func requestVerification() {
        guard !isRequestingVerification else { return }
        isRequestingVerification = true
        Task {
            let verified = await policy.requestAdultVerification()
            isRequestingVerification = false
            if !verified {
                showVerificationFeedback = policy.verificationFeedbackMessage != nil
            } else {
                policy.clearVerificationOutcome()
                // A successful Declared Age Range verification flips the whole
                // session's reveal capability on (the same effect Settings
                // "Verify Age" has), so the just-verified adult sees the
                // content WITHOUT a second "Reveal All"/"Show Anyway" tap. The
                // verify-age affordance is only ever offered to an undetermined
                // adult, and revealAll() is a structural no-op for anyone who
                // isn't a verified adult — so this can't punch through policy.
                policy.revealAll()
            }
        }
    }
}
