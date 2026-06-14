//
//  DemoRootView.swift
//  MediaStreamDemo
//
//  Root harness: in-app controls for age/flag state plus Open/Close so XCUITest
//  can drive the gallery, dismiss it, and REOPEN it (to prove reveal state
//  resets on dismiss). The gallery is shown INLINE (not a fullScreenCover) so
//  its accessibility tree is reliably visible to XCUITest from the first frame.
//  A fresh `SensitiveOverlayController` is built each time the gallery opens —
//  mirroring a real host that builds one controller per presentation.
//

import SwiftUI
import MediaStream

struct DemoRootView: View {
    @StateObject private var store = DemoSensitiveStore()
    @State private var isGalleryShown = false
    /// Rebuilt whenever the gallery opens so its view-scoped reveal state is
    /// fresh (the controller also resets itself on dismiss as a safety net).
    @State private var controller = SensitiveOverlayController.inactive
    /// nil → open to grid; non-nil → open straight into the slideshow at index.
    @State private var slideshowIndex: Int?
    @State private var didApplyLaunchArguments = false

    var body: some View {
        Group {
            if isGalleryShown {
                galleryView
            } else {
                harnessView
            }
        }
        .onAppear {
            guard !didApplyLaunchArguments else { return }
            didApplyLaunchArguments = true
            applyLaunchArguments()
        }
    }

    private var harnessView: some View {
        NavigationStack {
            Form {
                Section("Age Status") {
                    Picker("Age", selection: $store.ageStatus) {
                        Text("Verified Adult").tag(DemoAgeStatus.verifiedAdult)
                        Text("Undetermined").tag(DemoAgeStatus.undetermined)
                        Text("Minor").tag(DemoAgeStatus.minor)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("demo.agePicker")
                }
                Section("Flag Mode") {
                    Picker("Flag", selection: $store.flagMode) {
                        Text("All").tag(DemoFlagMode.all)
                        Text("Some").tag(DemoFlagMode.some)
                        Text("None").tag(DemoFlagMode.none)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("demo.flagPicker")
                }
                Section {
                    Button("Open Grid") { openGallery(slideshow: nil) }
                        .accessibilityIdentifier("demo.openGrid")
                    Button("Open Slideshow") { openGallery(slideshow: store.firstSensitiveIndex) }
                        .accessibilityIdentifier("demo.openSlideshow")
                }
            }
            .navigationTitle("MediaStream Demo")
        }
    }

    @ViewBuilder
    private var galleryView: some View {
        NavigationStack {
            MediaGalleryFullView(
                mediaItems: store.items(),
                configuration: MediaGalleryConfiguration(
                    slideshowDuration: 5.0,
                    showControls: true,
                    backgroundColor: .black,
                    sensitiveOverlay: controller
                ),
                initialSlideshowIndex: slideshowIndex,
                onDismiss: { isGalleryShown = false }
            )
        }
    }

    private func openGallery(slideshow: Int?) {
        controller = store.makeController()
        slideshowIndex = slideshow
        isGalleryShown = true
    }

    /// Honor launch-argument deep links so a UI test can jump straight to the
    /// state it needs without tapping through the harness.
    private func applyLaunchArguments() {
        switch store.startScreen {
        case .grid:
            openGallery(slideshow: nil)
        case .slideshow:
            openGallery(slideshow: store.startIndex ?? store.firstSensitiveIndex)
        }
    }
}
