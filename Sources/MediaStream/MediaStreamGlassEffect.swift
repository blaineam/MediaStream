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

/// Helper extension for glass background styling
extension View {
    @ViewBuilder
    func mediaStreamGlassBackground() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect()
        } else {
            self.background(
                Circle()
                    .fill(.ultraThinMaterial)
            )
        }
    }

    @ViewBuilder
    func mediaStreamGlassBackgroundRounded() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect()
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Card-style glass background with smaller corner radius
    @ViewBuilder
    func mediaStreamGlassCard(cornerRadius: CGFloat = 8) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    func mediaStreamGlassCapsule() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect()
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// General bar/panel background - uses glassEffect on iOS 26+ or ultraThinMaterial on older versions
    @ViewBuilder
    func mediaStreamGlassBar() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect()
        } else {
            self.background(.ultraThinMaterial)
        }
    }
}
