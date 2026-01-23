//
//  MediaStreamGlassEffect.swift
//  MediaStream
//
//  Glass effect helpers for iOS 26+ with fallback to material on older versions
//

import SwiftUI

/// MediaStream button style that uses glassEffect on iOS 26+ and falls back to material on older versions
struct MediaStreamGlassButton<Label: View>: View {
    let action: () -> Void
    let label: Label
    let size: CGFloat

    init(action: @escaping () -> Void, size: CGFloat = 36, @ViewBuilder label: () -> Label) {
        self.action = action
        self.size = size
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .mediaStreamGlassBackground()
    }
}

// MARK: - iOS 26+ Glass Effect Helpers
// These are in a separate @available extension to ensure compile-time safety
// when building with older SDKs that don't have the glassEffect API

#if swift(>=6.2)
@available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 3.0, *)
private extension View {
    func applyGlassEffect() -> some View {
        self.glassEffect()
    }

    func applyGlassEffectWithCornerRadius(_ cornerRadius: CGFloat) -> some View {
        self.glassEffect(in: .rect(cornerRadius: cornerRadius))
    }
}
#endif

/// Helper extension for glass background styling
extension View {
    @ViewBuilder
    func mediaStreamGlassBackground() -> some View {
        #if swift(>=6.2)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 3.0, *) {
            self.applyGlassEffect()
        } else {
            self.background(
                Circle()
                    .fill(.ultraThinMaterial)
            )
        }
        #else
        self.background(
            Circle()
                .fill(.ultraThinMaterial)
        )
        #endif
    }

    @ViewBuilder
    func mediaStreamGlassBackgroundRounded() -> some View {
        #if swift(>=6.2)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 3.0, *) {
            self.applyGlassEffect()
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        #else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        #endif
    }

    /// Card-style glass background with smaller corner radius
    @ViewBuilder
    func mediaStreamGlassCard(cornerRadius: CGFloat = 8) -> some View {
        #if swift(>=6.2)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 3.0, *) {
            self.applyGlassEffectWithCornerRadius(cornerRadius)
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }

    @ViewBuilder
    func mediaStreamGlassCapsule() -> some View {
        #if swift(>=6.2)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 3.0, *) {
            self.applyGlassEffect()
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self.background(.ultraThinMaterial, in: Capsule())
        #endif
    }

    /// General bar/panel background - uses glassEffect on iOS 26+ or ultraThinMaterial on older versions
    @ViewBuilder
    func mediaStreamGlassBar() -> some View {
        #if swift(>=6.2)
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 3.0, *) {
            self.applyGlassEffect()
        } else {
            self.background(.ultraThinMaterial)
        }
        #else
        self.background(.ultraThinMaterial)
        #endif
    }
}
