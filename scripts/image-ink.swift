#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

// A window that failed to draw is one flat color. This counts the pixels that
// differ from the image's dominant color, so a blank capture fails the check
// without reading any text.
// usage: image-ink.swift <png> [minPercent] [maxPercent]

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: image-ink.swift <png> [min] [max]\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: args[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(url.path)\n".utf8))
    exit(2)
}

let width = image.width
let height = image.height
let bytesPerRow = width * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
guard let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("cannot allocate bitmap\n".utf8))
    exit(2)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

// Quantize to 5 bits per channel so antialiasing and gradients land in the
// same bucket as the flat areas around them.
func bucket(_ offset: Int) -> Int {
    let r = Int(pixels[offset]) >> 3
    let g = Int(pixels[offset + 1]) >> 3
    let b = Int(pixels[offset + 2]) >> 3
    return (r << 10) | (g << 5) | b
}

var histogram = [Int: Int](minimumCapacity: 1024)
for y in 0..<height {
    let row = y * bytesPerRow
    for x in 0..<width where pixels[row + x * 4 + 3] > 16 {
        histogram[bucket(row + x * 4), default: 0] += 1
    }
}
guard let dominant = histogram.max(by: { $0.value < $1.value })?.key else {
    print("ink 0.00%")
    exit(1)
}

func distance(_ a: Int, _ b: Int) -> Int {
    let dr = abs(((a >> 10) & 31) - ((b >> 10) & 31))
    let dg = abs(((a >> 5) & 31) - ((b >> 5) & 31))
    let db = abs((a & 31) - (b & 31))
    return max(dr, max(dg, db))
}

var ink = 0
var total = 0
for y in 0..<height {
    let row = y * bytesPerRow
    for x in 0..<width where pixels[row + x * 4 + 3] > 16 {
        total += 1
        if distance(bucket(row + x * 4), dominant) > 6 { ink += 1 }
    }
}
guard total > 0 else {
    print("ink 0.00%")
    exit(1)
}

let percent = Double(ink) / Double(total) * 100
print(String(format: "ink %.2f%% (%dx%d)", percent, width, height))

guard args.count >= 4 else { exit(0) }
let minimum = Double(args[2]) ?? 0
let maximum = Double(args[3]) ?? 100
if percent < minimum || percent > maximum {
    FileHandle.standardError.write(
        Data(String(format: "ink %.2f%% outside %.2f..%.2f\n", percent, minimum, maximum).utf8)
    )
    exit(1)
}
