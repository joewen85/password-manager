#!/usr/bin/env swift
import AppKit
import Foundation

let filenames: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate_app_icon.swift <output.iconset>\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

func scaled(_ value: CGFloat, for pixels: Int) -> CGFloat {
    value * CGFloat(pixels) / 1024.0
}

func pathFrom(_ points: [CGPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() {
        path.line(to: point)
    }
    path.close()
    return path
}

func drawIcon(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap"])
    }

    rep.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "AppIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create graphics context"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    context.cgContext.setAllowsAntialiasing(true)

    let canvas = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.setFill()
    canvas.fill()

    let radius = scaled(216, for: pixels)
    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: scaled(48, for: pixels), dy: scaled(48, for: pixels)), xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.055, green: 0.180, blue: 0.205, alpha: 1),
        NSColor(red: 0.080, green: 0.380, blue: 0.365, alpha: 1),
    ])!
    gradient.draw(in: background, angle: 42)

    let accent = pathFrom([
        CGPoint(x: scaled(137, for: pixels), y: scaled(215, for: pixels)),
        CGPoint(x: scaled(391, for: pixels), y: scaled(106, for: pixels)),
        CGPoint(x: scaled(887, for: pixels), y: scaled(623, for: pixels)),
        CGPoint(x: scaled(763, for: pixels), y: scaled(748, for: pixels)),
    ])
    NSColor(red: 0.925, green: 0.625, blue: 0.255, alpha: 0.92).setFill()
    accent.fill()

    let plateRect = NSRect(
        x: scaled(246, for: pixels),
        y: scaled(260, for: pixels),
        width: scaled(532, for: pixels),
        height: scaled(492, for: pixels)
    )
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: scaled(76, for: pixels), yRadius: scaled(76, for: pixels))
    NSColor(red: 0.940, green: 0.965, blue: 0.940, alpha: 0.96).setFill()
    plate.fill()

    let shadow = NSBezierPath(roundedRect: plateRect.insetBy(dx: scaled(52, for: pixels), dy: scaled(70, for: pixels)), xRadius: scaled(52, for: pixels), yRadius: scaled(52, for: pixels))
    NSColor(red: 0.035, green: 0.095, blue: 0.110, alpha: 0.10).setFill()
    shadow.fill()

    let shackle = NSBezierPath()
    shackle.lineWidth = scaled(56, for: pixels)
    shackle.lineCapStyle = .round
    shackle.move(to: CGPoint(x: scaled(382, for: pixels), y: scaled(518, for: pixels)))
    shackle.curve(
        to: CGPoint(x: scaled(642, for: pixels), y: scaled(518, for: pixels)),
        controlPoint1: CGPoint(x: scaled(382, for: pixels), y: scaled(716, for: pixels)),
        controlPoint2: CGPoint(x: scaled(642, for: pixels), y: scaled(716, for: pixels))
    )
    NSColor(red: 0.060, green: 0.205, blue: 0.230, alpha: 1).setStroke()
    shackle.stroke()

    let bodyRect = NSRect(
        x: scaled(332, for: pixels),
        y: scaled(316, for: pixels),
        width: scaled(360, for: pixels),
        height: scaled(252, for: pixels)
    )
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: scaled(54, for: pixels), yRadius: scaled(54, for: pixels))
    NSColor(red: 0.045, green: 0.160, blue: 0.180, alpha: 1).setFill()
    body.fill()

    let dial = NSBezierPath(ovalIn: NSRect(
        x: scaled(460, for: pixels),
        y: scaled(398, for: pixels),
        width: scaled(104, for: pixels),
        height: scaled(104, for: pixels)
    ))
    NSColor(red: 0.965, green: 0.710, blue: 0.300, alpha: 1).setFill()
    dial.fill()

    let stem = NSBezierPath(roundedRect: NSRect(
        x: scaled(493, for: pixels),
        y: scaled(348, for: pixels),
        width: scaled(38, for: pixels),
        height: scaled(86, for: pixels)
    ), xRadius: scaled(19, for: pixels), yRadius: scaled(19, for: pixels))
    NSColor(red: 0.965, green: 0.710, blue: 0.300, alpha: 1).setFill()
    stem.fill()

    let highlight = NSBezierPath(roundedRect: NSRect(
        x: scaled(302, for: pixels),
        y: scaled(650, for: pixels),
        width: scaled(410, for: pixels),
        height: scaled(44, for: pixels)
    ), xRadius: scaled(22, for: pixels), yRadius: scaled(22, for: pixels))
    NSColor.white.withAlphaComponent(0.18).setFill()
    highlight.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    return data
}

for (name, pixels) in filenames {
    let data = try drawIcon(pixels: pixels)
    try data.write(to: outputURL.appendingPathComponent(name), options: .atomic)
}
