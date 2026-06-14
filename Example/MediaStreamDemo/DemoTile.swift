//
//  DemoTile.swift
//  MediaStreamDemo
//
//  Generates simple, deterministic numbered color tiles so the blur/reveal of
//  the MediaStream gallery is visually unambiguous in the demo and in XCUITest.
//  No network, no bundled assets — every tile is drawn on the fly.
//

import UIKit

enum DemoTile {
    /// A flat color with a big white index number centered on it. Distinct hue
    /// per index so a revealed tile is obviously different from a blurred one.
    static func image(index: Int, size: CGSize = CGSize(width: 600, height: 600)) -> UIImage {
        let hue = CGFloat((index * 47) % 360) / 360.0
        let color = UIColor(hue: hue, saturation: 0.75, brightness: 0.85, alpha: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "\(index)" as NSString
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.height * 0.5, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let textSize = text.size(withAttributes: attrs)
            let origin = CGPoint(x: 0, y: (size.height - textSize.height) / 2)
            text.draw(in: CGRect(origin: origin, size: CGSize(width: size.width, height: textSize.height)),
                      withAttributes: attrs)
        }
    }
}
