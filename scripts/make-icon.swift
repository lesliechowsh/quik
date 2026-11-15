// Draws the static app icon: a graphite rounded tile with one white pulse line.
// The runtime Dock tile paints live scores on the same rounded shape, so the
// two read as the same app. Run with `swift scripts/make-icon.swift`.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/Resources/Quik.icns"

func render(_ size: CGFloat) -> CGImage {
    let scale = size / canvas
    let context = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)

    let tile = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 186, cornerHeight: 186, transform: nil
    )
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.26, green: 0.28, blue: 0.32, alpha: 1),
            CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: []
    )

    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 292, y: 512))
    pulse.addLine(to: CGPoint(x: 400, y: 512))
    pulse.addLine(to: CGPoint(x: 462, y: 330))
    pulse.addLine(to: CGPoint(x: 552, y: 700))
    pulse.addLine(to: CGPoint(x: 622, y: 430))
    pulse.addLine(to: CGPoint(x: 732, y: 430))
    context.addPath(pulse)
    context.setStrokeColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1))
    context.setLineWidth(80)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot create PNG writer: \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG write failed: \(url.path)"])
    }
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("Quik-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// iconutil wants these exact names. Rendering each size on its own keeps the
// 16 and 32 point rasters crisp instead of downscaled from the master.
for points in [16, 32, 128, 256, 512] {
    for scaleFactor in [1, 2] {
        let pixels = points * scaleFactor
        let name = scaleFactor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try writePNG(render(CGFloat(pixels)), to: iconset.appendingPathComponent(name))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outPath]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}
print("wrote \(outPath)")
