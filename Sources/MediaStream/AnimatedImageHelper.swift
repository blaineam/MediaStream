import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Helper class for working with animated images
public struct AnimatedImageHelper {

    /// Detects if a file is an animated image and returns its total duration
    public static func getAnimatedImageDuration(from url: URL) async -> TimeInterval? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(imageSource)
        guard count > 1 else {
            return nil
        }

        var totalDuration: TimeInterval = 0

        for i in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil) as? [String: Any],
                  let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] else {
                continue
            }

            var frameDuration: TimeInterval = 0.1

            if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval, delayTime > 0 {
                frameDuration = delayTime
            } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime as String] as? TimeInterval {
                frameDuration = delayTime
            }

            totalDuration += frameDuration
        }

        return totalDuration > 0 ? totalDuration : nil
    }

    /// Detects if data represents an animated image and returns its total duration
    public static func getAnimatedImageDuration(from data: Data) async -> TimeInterval? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(imageSource)
        guard count > 1 else {
            return nil
        }

        var totalDuration: TimeInterval = 0

        for i in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil) as? [String: Any] else {
                continue
            }

            var frameDuration: TimeInterval = 0.1

            if let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let delayTime = gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? TimeInterval, delayTime > 0 {
                    frameDuration = delayTime
                } else if let delayTime = gifProperties[kCGImagePropertyGIFDelayTime as String] as? TimeInterval {
                    frameDuration = delayTime
                }
            } else if let pngProperties = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any],
                      let delayTime = pngProperties[kCGImagePropertyAPNGDelayTime as String] as? TimeInterval {
                frameDuration = delayTime
            } else if let heicProperties = properties["{HEICS}" as String] as? [String: Any],
                      let delayTime = heicProperties["DelayTime" as String] as? TimeInterval {
                frameDuration = delayTime
            }

            totalDuration += max(frameDuration, 0.1)
        }

        return totalDuration > 0 ? totalDuration : nil
    }

    /// Checks if a file is an animated image by actually reading the image data
    public static func isAnimatedImageFile(_ url: URL) -> Bool {
        // First check if the extension could potentially be animated
        let pathExtension = url.pathExtension.lowercased()
        guard ["gif", "heif", "heic", "png", "apng", "webp"].contains(pathExtension) else {
            return false
        }

        // Then check if it actually has multiple frames
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetCount(imageSource) > 1
    }

    /// Checks if data represents an animated image
    public static func isAnimatedImage(_ data: Data) -> Bool {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(imageSource) > 1
    }

    /// Calculates the adjusted slideshow duration for an animated image
    /// This ensures the animation plays enough times to meet or exceed the minimum duration
    public static func calculateSlideshowDuration(
        animationDuration: TimeInterval,
        minimumDuration: TimeInterval
    ) -> TimeInterval {
        guard animationDuration > 0 else {
            return minimumDuration
        }

        let repeatCount = ceil(minimumDuration / animationDuration)
        return animationDuration * repeatCount
    }
}
