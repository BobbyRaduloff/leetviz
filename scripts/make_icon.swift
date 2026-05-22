// Generates icon-1024.png — a 1024×1024 macOS app icon showing spectrum bars
// in the same green as AccentColor.green from the app.
//
// Run: swift scripts/make_icon.swift  (writes icon-1024.png next to it)

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cornerRadius: CGFloat = 224 // macOS-style squircle corner radius

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Couldn't create bitmap context")
}

// Background: dark, slightly cooler than pure black so the green pops.
let bg = CGColor(srgbRed: 0.08, green: 0.10, blue: 0.13, alpha: 1)
ctx.setFillColor(bg)
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(bgPath)
ctx.fillPath()

// Spectrum bars — matches the in-app AccentColor.green (0.30, 0.95, 0.55).
let barColor = CGColor(srgbRed: 0.30, green: 0.95, blue: 0.55, alpha: 1)
ctx.setFillColor(barColor)

let barCount = 16
let marginX: CGFloat = 110
// 20% padding top + 20% bottom → bars occupy the middle 60% vertically.
let marginY: CGFloat = CGFloat(size) * 0.20
let vizWidth = CGFloat(size) - 2 * marginX
let vizHeight = CGFloat(size) - 2 * marginY

let barPad: CGFloat = 14
let barW = (vizWidth - barPad * CGFloat(barCount - 1)) / CGFloat(barCount)

// Hand-picked heights — feels like a real frequency response with a mid bump.
let heights: [CGFloat] = [
    0.22, 0.40, 0.62, 0.86, 1.00, 0.78, 0.92, 0.70,
    0.55, 0.66, 0.48, 0.40, 0.55, 0.32, 0.26, 0.20,
]

// Match the in-app "Pulsing blocks" visualizer: center-aligned rectangles.
for i in 0..<barCount {
    let h = heights[i] * vizHeight
    let x = marginX + CGFloat(i) * (barW + barPad)
    let y = marginY + (vizHeight - h) / 2
    ctx.fill(CGRect(x: x, y: y, width: barW, height: h))
}

guard let image = ctx.makeImage() else { fatalError("Couldn't make CGImage") }

let url = URL(fileURLWithPath: "icon-1024.png", isDirectory: false,
               relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
let typeIdentifier = UTType.png.identifier as CFString
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier, 1, nil) else {
    fatalError("Couldn't create image destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write PNG") }
print("Wrote \(url.path)")
