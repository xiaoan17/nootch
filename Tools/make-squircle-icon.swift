#!/usr/bin/env swift
//
// Regenerate NootchIcon.png with a proper macOS squircle mask baked in.
//
// The source image is a full-bleed 1024×1024 square with no alpha channel, so
// the app icon looks like a rectangle instead of the Big Sur+ squircle every
// other macOS app has. We:
//   1) Scale the source into the Apple-recommended safe area (824×824 within
//      a 1024×1024 canvas, ~100px inset)
//   2) Clip to a superellipse (n=5, matching macOS 11+ icon geometry)
//   3) Emit a fresh NootchIcon.png with alpha
//
// Usage: swift Tools/make-squircle-icon.swift <source.png> <output.png> [canvas]
//
// Note: the wrapper build script (Tools/rebuild-icons.sh) also rebuilds all the
// .icns entries at every required size from this output PNG.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: make-squircle-icon.swift <source.png> <output.png> [canvas=1024]\n".data(using: .utf8)!)
    exit(2)
}
let sourcePath = args[1]
let outPath = args[2]
let canvas = args.count > 3 ? (Int(args[3]) ?? 1024) : 1024

// Apple's macOS Big Sur+ icons place a squircle inside the 1024 canvas with
// ~100/1024 padding on every side — the squircle itself is ~824×824. Content
// fills up to the squircle boundary, and the corner curvature trims off the
// bulge. Scale proportionally for other canvas sizes.
let squircleInset = Int(Double(canvas) * (100.0 / 1024.0))
let squircleSize = canvas - 2 * squircleInset

guard let src = CGDataProvider(filename: sourcePath).flatMap({ CGImage(pngDataProviderSource: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent) }) else {
    FileHandle.standardError.write("failed to read source: \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: canvas, height: canvas,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("failed to make context\n".data(using: .utf8)!)
    exit(1)
}

// Superellipse (squircle) path: |x/rx|^n + |y/ry|^n = 1, n=5 approximates the
// macOS icon shape closely enough that eyes can't tell it from AppKit's own
// rendering at Dock size. The squircle is centered in the canvas and sized to
// the padded bounding box, matching Apple's icon template.
let n: Double = 5
let cx = Double(canvas) / 2
let cy = Double(canvas) / 2
let rx = Double(squircleSize) / 2
let ry = Double(squircleSize) / 2

let steps = 720
let path = CGMutablePath()
for i in 0...steps {
    let theta = Double(i) / Double(steps) * 2 * .pi
    // Parametric superellipse: x = a * sign(cos t) * |cos t|^(2/n)
    let cosT = cos(theta)
    let sinT = sin(theta)
    let x = cx + rx * (cosT >= 0 ? 1 : -1) * pow(abs(cosT), 2.0 / n)
    let y = cy + ry * (sinT >= 0 ? 1 : -1) * pow(abs(sinT), 2.0 / n)
    if i == 0 {
        path.move(to: CGPoint(x: x, y: y))
    } else {
        path.addLine(to: CGPoint(x: x, y: y))
    }
}
path.closeSubpath()

ctx.saveGState()
ctx.addPath(path)
ctx.clip()

// Draw source scaled to fill the squircle's bounding box, centered — the
// squircle clip trims the corner rectangles automatically.
let drawRect = CGRect(x: squircleInset, y: squircleInset, width: squircleSize, height: squircleSize)
ctx.draw(src, in: drawRect)
ctx.restoreGState()

guard let output = ctx.makeImage() else {
    FileHandle.standardError.write("failed to snapshot\n".data(using: .utf8)!)
    exit(1)
}
let outURL = URL(fileURLWithPath: outPath)
guard let dst = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("failed to open destination\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dst, output, nil)
guard CGImageDestinationFinalize(dst) else {
    FileHandle.standardError.write("failed to write png\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outPath) (\(canvas)×\(canvas), squircle \(squircleSize)×\(squircleSize))")
