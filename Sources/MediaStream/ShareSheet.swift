import SwiftUI

#if os(iOS)
import UIKit

public struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    public init(items: [Any]) {
        self.items = items
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#elseif canImport(AppKit)
import AppKit

public struct ShareSheetMac: NSViewRepresentable {
    let items: [Any]
    @Binding var isPresented: Bool

    public init(items: [Any], isPresented: Binding<Bool>) {
        self.items = items
        self._isPresented = isPresented
    }

    public func makeNSView(context: Context) -> NSView {
        let view = ShareHostView()
        view.items = items
        view.onDismiss = {
            isPresented = false
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    class ShareHostView: NSView {
        var items: [Any] = []
        var onDismiss: (() -> Void)?
        private var hasShownPicker = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            guard !hasShownPicker, window != nil else { return }
            hasShownPicker = true

            // Wait for next run loop to ensure view hierarchy is fully set up
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Filter out any nil items
                let validItems = self.items.compactMap { $0 as Any? }

                guard !validItems.isEmpty else {
                    print("⚠️ No valid items to share")
                    self.onDismiss?()
                    return
                }

                print("📤 Sharing \(validItems.count) item(s) from ShareSheetMac")

                // Convert items to proper shareable format
                var shareableItems: [Any] = []
                for (index, item) in validItems.enumerated() {
                    if let url = item as? URL {
                        print("  [\(index)]: URL - \(url.path)")
                        print("  File exists: \(FileManager.default.fileExists(atPath: url.path))")
                        if FileManager.default.fileExists(atPath: url.path) {
                            print("  File size: \((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? "unknown")")

                            // Ensure it's a file URL (not a web URL)
                            if url.isFileURL {
                                // For macOS sharing, use the file URL directly
                                // This allows proper copy/paste to Finder
                                shareableItems.append(url)
                            } else {
                                print("  ⚠️ URL is not a file URL: \(url)")
                                shareableItems.append(item)
                            }
                        } else {
                            print("  ⚠️ File does not exist at path")
                        }
                    } else if let image = item as? NSImage {
                        print("  [\(index)]: NSImage (\(image.size.width)x\(image.size.height))")
                        shareableItems.append(image)
                    } else {
                        print("  [\(index)]: \(type(of: item))")
                        shareableItems.append(item)
                    }
                }

                guard !shareableItems.isEmpty else {
                    print("⚠️ No shareable items after processing")
                    self.onDismiss?()
                    return
                }

                let picker = NSSharingServicePicker(items: shareableItems)
                picker.delegate = self

                if let window = self.window {
                    picker.show(relativeTo: self.bounds, of: self, preferredEdge: .minY)
                } else {
                    print("⚠️ Window is nil when trying to show share picker")
                    self.onDismiss?()
                }
            }
        }
    }
}

@MainActor
extension ShareSheetMac.ShareHostView: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil {
            print("📤 Share cancelled by user")
        } else {
            print("📤 Share service chosen: \(service?.title ?? "unknown")")
        }
        // Dismiss after user makes a choice
        Task { @MainActor [weak self] in
            self?.onDismiss?()
        }
    }
}
#endif
