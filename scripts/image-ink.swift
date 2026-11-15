#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

// A window that failed to draw is one flat color. This counts the pixels that
// differ from the image's dominant color, so a blank capture fails the check
// without reading any text.
// usage: image-ink.swift <png> [minPercent] [maxPercent] [--inset PIXELS] [--region X,Y,W,H]
// --inset ignores the outer band of the image. A window capture carries the
// popover's 13 point shadow border and its arrow; both differ from the panel
// background and would otherwise read as text at the edge.
// --region limits the count to one part of the window, in pixels from the top
// left, and still reports the bounding box in image coordinates.

var positional: [String] = []
var inset = 0
var probes: [(x: Int, y: Int)] = []
var region: (x: Int, y: Int, width: Int, height: Int)?
var index = 1
while index < CommandLine.arguments.count {
    let argument = CommandLine.arguments[index]
    if argument == "--inset", index + 1 < CommandLine.arguments.count {
        inset = max(Int(CommandLine.arguments[index + 1]) ?? 0, 0)
        index += 2
    } else if argument == "--probe", index + 1 < CommandLine.arguments.count {
        let parts = CommandLine.arguments[index + 1].split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else {
            FileHandle.standardError.write(Data("--probe wants x,y in pixels\n".utf8))
            exit(2)
        }
        probes.append((parts[0], parts[1]))
        index += 2
    } else if argument == "--region", index + 1 < CommandLine.arguments.count {
        let parts = CommandLine.arguments[index + 1].split(separator: ",").compactMap { Int($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else {
            FileHandle.standardError.write(Data("--region wants x,y,w,h in pixels\n".utf8))
            exit(2)
        }
        region = (parts[0], parts[1], parts[2], parts[3])
        index += 2
    } else {
        positional.append(argument)
        index += 1
    }
}
guard let first = positional.first else {
    FileHandle.standardError.write(
        Data("usage: image-ink.swift <png> [min] [max] [--inset PIXELS] [--region X,Y,W,H]\n".utf8)
    )
    exit(2)
}

let url = URL(fileURLWithPath: first)
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

var top = min(inset, height / 2)
var left = min(inset, width / 2)
var bottom = height - top
var right = width - left
if let region {
    left = max(left, region.x)
    top = max(top, region.y)
    right = min(right, region.x + region.width)
    bottom = min(bottom, region.y + region.height)
}
guard left < right, top < bottom else {
    FileHandle.standardError.write(Data("region is outside the image\n".utf8))
    exit(2)
}

var histogram = [Int: Int](minimumCapacity: 1024)
for y in top..<bottom {
    let row = y * bytesPerRow
    for x in left..<right where pixels[row + x * 4 + 3] > 16 {
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
var minX = width, maxX = -1, minY = height, maxY = -1
for y in top..<bottom {
    let row = y * bytesPerRow
    for x in left..<right where pixels[row + x * 4 + 3] > 16 {
        total += 1
        if distance(bucket(row + x * 4), dominant) > 6 {
            ink += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard total > 0 else {
    print("ink 0.00%")
    exit(1)
}

let percent = Double(ink) / Double(total) * 100
if ink > 0 {
    print(String(format: "ink %.2f%% (%dx%d) bbox=(%d,%d %dx%d)",
                 percent, width, height, minX, minY, maxX - minX + 1, maxY - minY + 1))
} else {
    print(String(format: "ink %.2f%% (%dx%d)", percent, width, height))
}

// A filled control is only a few steps away from the panel background, below
// the ink threshold. A probe reports the luminance at one pixel so a caller can
// tell a tinted capsule from an empty corner.
for probe in probes {
    guard probe.x >= 0, probe.x < width, probe.y >= 0, probe.y < height else {
        print("probe \(probe.x),\(probe.y)=na")
        continue
    }
    let offset = probe.y * bytesPerRow + probe.x * 4
    let luminance = (Double(pixels[offset]) + Double(pixels[offset + 1]) + Double(pixels[offset + 2])) / 765
    print(String(format: "probe %d,%d=%.3f", probe.x, probe.y, luminance))
}

guard positional.count >= 3 else { exit(0) }
let minimum = Double(positional[1]) ?? 0
let maximum = Double(positional[2]) ?? 100
if percent < minimum || percent > maximum {
    FileHandle.standardError.write(
        Data(String(format: "ink %.2f%% outside %.2f..%.2f\n", percent, minimum, maximum).utf8)
    )
    exit(1)
}
