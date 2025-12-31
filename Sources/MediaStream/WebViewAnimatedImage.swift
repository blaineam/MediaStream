//
//  WebViewAnimatedImage.swift
//  MediaStream
//
//  WKWebView-based animated image display for memory-efficient GIF/APNG playback
//  Browser handles frame decoding and caching internally
//

import Foundation
import SwiftUI
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - WebView Animated Image Controller

/// Controller for displaying animated images via WKWebView
/// Much more memory-efficient than loading all frames into UIImage
@MainActor
public class WebViewAnimatedImageController: NSObject, ObservableObject {
    @Published public var isReady: Bool = false

    private(set) var webView: WKWebView?
    private var currentURL: URL?

    public override init() {
        super.init()
    }

    /// Create the WKWebView for image display
    public func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        #endif
        config.suppressesIncrementalRendering = false

        // Add console logging
        let consoleScript = WKUserScript(
            source: """
            window.console.log = (function(origLog) {
                return function(...args) {
                    window.webkit.messageHandlers.consoleLog.postMessage(args.map(String).join(' '));
                    origLog.apply(console, args);
                };
            })(window.console.log);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )

        let contentController = WKUserContentController()
        contentController.addUserScript(consoleScript)
        contentController.add(Coordinator(self), name: "consoleLog")
        contentController.add(Coordinator(self), name: "imageReady")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)

        #if canImport(UIKit)
        webView.isOpaque = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif

        self.webView = webView
        return webView
    }

    /// Load an animated image from URL
    public func load(url: URL, headers: [String: String]? = nil) {
        guard let webView = webView else {
            print("WebViewAnimatedImage: No webView available")
            return
        }

        currentURL = url
        isReady = false

        let html = buildImageHTML(imageURL: url)

        // Load with same-origin as image to avoid CORS issues
        let baseURL = url.deletingLastPathComponent()
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// Build HTML for animated image display
    private func buildImageHTML(imageURL: URL) -> String {
        let imageURLString = imageURL.absoluteString

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body {
                    width: 100%;
                    height: 100%;
                    background: transparent;
                    overflow: hidden;
                    -webkit-user-select: none;
                    user-select: none;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                img {
                    max-width: 100%;
                    max-height: 100%;
                    object-fit: contain;
                }
            </style>
        </head>
        <body>
            <img id="animatedImage" src="\(imageURLString)" />
            <script>
                const img = document.getElementById('animatedImage');

                img.onload = function() {
                    console.log('Animated image loaded: ' + img.naturalWidth + 'x' + img.naturalHeight);
                    window.webkit.messageHandlers.imageReady.postMessage({
                        width: img.naturalWidth,
                        height: img.naturalHeight
                    });
                };

                img.onerror = function(e) {
                    console.log('Image load error');
                };
            </script>
        </body>
        </html>
        """
    }

    /// Clean up resources
    public func destroy() {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        currentURL = nil
        isReady = false
    }

    // MARK: - Coordinator for message handling

    private class Coordinator: NSObject, WKScriptMessageHandler {
        weak var controller: WebViewAnimatedImageController?

        init(_ controller: WebViewAnimatedImageController) {
            self.controller = controller
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor in
                switch message.name {
                case "imageReady":
                    controller?.isReady = true
                    print("WebViewAnimatedImage: Image ready")
                case "consoleLog":
                    if let msg = message.body as? String {
                        print("WebViewAnimatedImage JS: \(msg)")
                    }
                default:
                    break
                }
            }
        }
    }
}

// MARK: - SwiftUI Representable

#if canImport(UIKit)
/// UIKit representable for WebView animated image
public struct WebViewAnimatedImageRepresentable: UIViewRepresentable {
    @ObservedObject var controller: WebViewAnimatedImageController

    public init(controller: WebViewAnimatedImageController) {
        self.controller = controller
    }

    public func makeUIView(context: Context) -> WKWebView {
        if let existing = controller.webView {
            return existing
        }
        return controller.createWebView()
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        // Updates handled by controller
    }
}
#else
/// AppKit representable for WebView animated image
public struct WebViewAnimatedImageRepresentable: NSViewRepresentable {
    @ObservedObject var controller: WebViewAnimatedImageController

    public init(controller: WebViewAnimatedImageController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> WKWebView {
        if let existing = controller.webView {
            return existing
        }
        return controller.createWebView()
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        // Updates handled by controller
    }
}
#endif

// MARK: - Simple SwiftUI View

/// A simple SwiftUI view for displaying animated images via WKWebView
public struct WebViewAnimatedImageView: View {
    let url: URL
    let headers: [String: String]?

    @StateObject private var controller = WebViewAnimatedImageController()

    public init(url: URL, headers: [String: String]? = nil) {
        self.url = url
        self.headers = headers
    }

    public var body: some View {
        ZStack {
            WebViewAnimatedImageRepresentable(controller: controller)

            if !controller.isReady {
                ProgressView()
                    .scaleEffect(1.5)
                    #if canImport(UIKit)
                    .tint(.white)
                    #endif
            }
        }
        .onAppear {
            if controller.webView == nil {
                _ = controller.createWebView()
            }
            controller.load(url: url, headers: headers)
        }
        .onDisappear {
            controller.destroy()
        }
    }
}
