#!/usr/bin/env swift
import AppKit

/// Draws the Clawde mascot at a given size
func drawClawde(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        let s = size
        let u = s / 12.0  // grid unit

        // Background — rounded rect with white fill (like the sticker)
        let bgInset = u * 0.5
        let bgRect = CGRect(x: bgInset, y: bgInset, width: s - bgInset * 2, height: s - bgInset * 2)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: u * 1.5, cornerHeight: u * 1.5, transform: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()

        // Terracotta color
        let terracotta = NSColor(red: 0.80, green: 0.45, blue: 0.30, alpha: 1.0)
        ctx.setFillColor(terracotta.cgColor)

        // Body
        ctx.fill(CGRect(x: u*2, y: u*2.5, width: u*8, height: u*6.5))

        // Left ear
        ctx.fill(CGRect(x: u*1, y: u*1.5, width: u*2.5, height: u*2.5))

        // Right ear
        ctx.fill(CGRect(x: u*8.5, y: u*1.5, width: u*2.5, height: u*2.5))

        // Left leg
        ctx.fill(CGRect(x: u*2, y: u*9, width: u*2.5, height: u*2))

        // Right leg
        ctx.fill(CGRect(x: u*7.5, y: u*9, width: u*2.5, height: u*2))

        // Eyes
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let lineWidth = max(u * 0.5, 1.5)
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(NSColor.black.cgColor)

        let eyeY = u * 5.5
        let eyeSize = u * 1.2

        // Left eye: >
        let lx = u * 4.2
        ctx.beginPath()
        ctx.move(to: CGPoint(x: lx - eyeSize, y: eyeY - eyeSize))
        ctx.addLine(to: CGPoint(x: lx + eyeSize * 0.4, y: eyeY))
        ctx.addLine(to: CGPoint(x: lx - eyeSize, y: eyeY + eyeSize))
        ctx.strokePath()

        // Right eye: <
        let rx = u * 7.8
        ctx.beginPath()
        ctx.move(to: CGPoint(x: rx + eyeSize, y: eyeY - eyeSize))
        ctx.addLine(to: CGPoint(x: rx - eyeSize * 0.4, y: eyeY))
        ctx.addLine(to: CGPoint(x: rx + eyeSize, y: eyeY + eyeSize))
        ctx.strokePath()

        return true
    }
    return image
}

func savePNG(_ image: NSImage, to path: String, pixelSize: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// Create iconset directory
let scriptPath = CommandLine.arguments[0]
let projectDir = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().deletingLastPathComponent().path
let iconsetPath = "\(projectDir)/Clawdebar.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

// Required sizes for .icns
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for (name, pixels) in sizes {
    let image = drawClawde(size: CGFloat(pixels))
    let path = "\(iconsetPath)/\(name).png"
    savePNG(image, to: path, pixelSize: pixels)
    print("Generated \(name).png (\(pixels)x\(pixels))")
}

print("\nIconset created at \(iconsetPath)")
print("Run: iconutil -c icns \(iconsetPath)")
