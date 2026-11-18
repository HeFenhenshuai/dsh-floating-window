// Generates window-macos/icon.icns from a drawing, so the app has a real Dock
// icon instead of the generic executable one. Run it only when the artwork
// changes: the checked-in .icns is what build.sh copies.
//
//   swift window-macos/make-icon.swift
//   cd window-macos && ./make-icon.sh     # also possible, see that file

import AppKit
import CoreGraphics
import Foundation

let canvas = 1024.0
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }

// --- background: the app's dark page colour, with a soft accent glow --------
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let rounded = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.saveGState()
context.addPath(rounded)
context.clip()
let colors = [
    NSColor(srgbRed: 27 / 255, green: 42 / 255, blue: 68 / 255, alpha: 1).cgColor,
    NSColor(srgbRed: 15 / 255, green: 17 / 255, blue: 21 / 255, alpha: 1).cgColor,
] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: tile.minX, y: tile.maxY),
                               end: CGPoint(x: tile.maxX, y: tile.minY),
                               options: [])
}
// accent glow bottom-left: a radial falloff, not a visible circle edge
let glowCenter = CGPoint(x: 300, y: 300)
let glowColors = [
    NSColor(srgbRed: 65 / 255, green: 118 / 255, blue: 230 / 255, alpha: 0.55).cgColor,
    NSColor(srgbRed: 65 / 255, green: 118 / 255, blue: 230 / 255, alpha: 0).cgColor,
] as CFArray
if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1]) {
    context.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 520, options: [])
}
context.restoreGState()

// --- the floating window glyph: a back pane, a front bubble -----------------
context.setLineWidth(26)
context.setLineCap(.round)
context.setLineJoin(.round)

// back pane (the window that stays behind)
let back = CGRect(x: 250, y: 470, width: 420, height: 300)
context.setStrokeColor(NSColor(white: 1, alpha: 0.30).cgColor)
context.addPath(CGPath(roundedRect: back, cornerWidth: 62, cornerHeight: 62, transform: nil))
context.strokePath()

// front bubble: white fill with a tail toward the bottom-left
let front = CGRect(x: 330, y: 250, width: 470, height: 330)
let bubble = CGMutablePath()
bubble.addRoundedRect(in: front, cornerWidth: 76, cornerHeight: 76)
let tail = CGMutablePath()
tail.move(to: CGPoint(x: front.minX + 90, y: front.minY + 10))
tail.addLine(to: CGPoint(x: front.minX + 90, y: front.minY - 92))
tail.addLine(to: CGPoint(x: front.minX + 214, y: front.minY + 6))
tail.closeSubpath()
context.setFillColor(NSColor(white: 1, alpha: 0.96).cgColor)
context.addPath(bubble)
context.fillPath()
context.addPath(tail)
context.fillPath()

// three text lines inside the bubble: one accent, two muted
let accent = NSColor(srgbRed: 65 / 255, green: 118 / 255, blue: 230 / 255, alpha: 1).cgColor
let muted = NSColor(srgbRed: 154 / 255, green: 164 / 255, blue: 186 / 255, alpha: 1).cgColor
let lines: [(CGRect, CGColor)] = [
    (CGRect(x: 385, y: 480, width: 300, height: 34), accent),
    (CGRect(x: 385, y: 405, width: 360, height: 26), muted),
    (CGRect(x: 385, y: 340, width: 250, height: 26), muted),
]
for (rect, color) in lines {
    context.setFillColor(color)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
    context.fillPath()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: output)
print("wrote \(output.path)")
