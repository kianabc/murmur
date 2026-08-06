#!/usr/bin/env swift
// Renders Murmur.icns from code — no design tool, no binary asset in git.
//
//   swift scripts/make-icon.swift
//
// The mark is the same five-bar level meter the HUD uses while listening, so the
// icon and the running app read as the same object.

import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

/// Bar heights as a fraction of the tallest, mirrored around the centre.
let bars: [CGFloat] = [0.34, 0.62, 1.0, 0.74, 0.44]

func render(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons sit inside the canvas rather than filling it; roughly 10%
    // padding with a ~22% corner radius matches the system look.
    let inset = s * 0.094
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237

    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow, scaled so small sizes don't turn to mud.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -s * 0.012),
        blur: s * 0.03,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    context.addPath(squircle)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Indigo → violet, top-left to bottom-right.
    context.saveGState()
    context.addPath(squircle)
    context.clip()

    let colors = [
        NSColor(srgbRed: 0.42, green: 0.40, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.66, green: 0.31, blue: 0.93, alpha: 1).cgColor,
        NSColor(srgbRed: 0.83, green: 0.29, blue: 0.76, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 0.55, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Soft highlight across the top edge, so it reads as glass rather than flat.
    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY),
            options: []
        )
    }

    // The level meter.
    let barWidth = rect.width * 0.082
    let spacing = rect.width * 0.062
    let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
    let maxHeight = rect.height * 0.46
    var x = rect.midX - totalWidth / 2

    for fraction in bars {
        let height = max(barWidth, maxHeight * fraction)
        let bar = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        let path = CGPath(
            roundedRect: bar,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        context.fillPath()
        x += barWidth + spacing
    }

    context.restoreGState()
    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Build the iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Murmur.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil expects this exact naming.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

var cache: [Int: CGImage] = [:]
for size in sizes { cache[size] = render(size: size) }

for variant in variants {
    guard let image = cache[variant.pixels] else { continue }
    write(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}

print("wrote \(iconset.path)")
