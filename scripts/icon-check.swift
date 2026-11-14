import AppKit

guard CommandLine.arguments.count > 1 else {
    print("usage: icon-check.swift <dir>")
    exit(2)
}
let dir = CommandLine.arguments[1]
let advanced = CommandLine.arguments.contains("--advanced")
let requested = CommandLine.arguments.dropFirst(2).filter { !$0.hasPrefix("--") }
let states = requested.isEmpty ? ["fluid", "sluggish", "stalled"] : requested
var failures = 0

let edgeInset = Int(Double(512) * 0.04)

for state in states {
    let suffix = advanced ? "-advanced" : ""
    let path = dir + "/" + state + suffix + ".png"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let rep = NSBitmapImageRep(data: data) else {
        print("FAIL \(state): cannot read \(path)")
        failures += 1
        continue
    }
    guard rep.pixelsWide == rep.pixelsHigh else {
        print("FAIL \(state): not square \(rep.pixelsWide)x\(rep.pixelsHigh)")
        failures += 1
        continue
    }

    var textMinX = rep.pixelsWide, textMaxX = 0, textMinY = rep.pixelsHigh, textMaxY = 0
    var textPixels = 0
    var rowText = [Int](repeating: 0, count: rep.pixelsHigh)
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
            let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
            if c.alphaComponent > 0.5, hi > 0.8, hi - lo < 0.15 {
                textPixels += 1
                rowText[y] += 1
                textMinX = min(textMinX, x); textMaxX = max(textMaxX, x)
                textMinY = min(textMinY, y); textMaxY = max(textMaxY, y)
            }
        }
    }
    var bands: [(Int, Int)] = []
    var bandStart: Int? = nil
    for y in 0..<rep.pixelsHigh {
        if rowText[y] > 0 {
            if bandStart == nil { bandStart = y }
        } else if let start = bandStart {
            bands.append((start, y - 1))
            bandStart = nil
        }
    }
    if let start = bandStart { bands.append((start, rep.pixelsHigh - 1)) }
    let bandText = bands.map { "\($0.0)-\($0.1)" }.joined(separator: ",")
    let gapText = zip(bands, bands.dropFirst()).map { $1.0 - $0.1 - 1 }.map(String.init).joined(separator: ",")

    var onEdge = 0
    let probe = 3
    if textPixels > 0 {
        for y in textMinY...textMaxY {
            for x in textMinX...textMaxX {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
                let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
                guard c.alphaComponent > 0.5, hi > 0.8, hi - lo < 0.15 else { continue }
                for (dx, dy) in [(-probe, 0), (probe, 0), (0, -probe), (0, probe)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < rep.pixelsWide, ny < rep.pixelsHigh,
                          let n = rep.colorAt(x: nx, y: ny), n.alphaComponent < 0.5 else { continue }
                    onEdge += 1
                }
            }
        }
    }

    let margin = min(textMinX, textMinY, rep.pixelsWide - 1 - textMaxX, rep.pixelsHigh - 1 - textMaxY)
    let glyphHeight = textMaxY - textMinY + 1
    let note = "glyphHeight=\(glyphHeight) size=\(rep.pixelsWide) text=\(textPixels)px bbox=(\(textMinX),\(textMinY))-(\(textMaxX),\(textMaxY)) margin=\(margin)px bands=[\(bandText)] gaps=[\(gapText)]"
    if advanced, bands.count == 2 {
        let gap = bands[1].0 - bands[0].1 - 1
        let bottom = rep.pixelsHigh - 1 - bands[1].1
        if gap > Int(Double(rep.pixelsHigh) * 0.12) {
            print("FAIL \(state): gap between number and label is \(gap)px, \(note)")
            failures += 1
            continue
        }
        if bottom < edgeInset {
            print("FAIL \(state): label sits \(bottom)px from the bottom, \(note)")
            failures += 1
            continue
        }
    }
    if onEdge > 0 {
        print("FAIL \(state): text touches the icon edge, \(note) edgePixels=\(onEdge)")
        failures += 1
    } else if textPixels < 1000 {
        print("FAIL \(state): almost no text rendered, \(note)")
        failures += 1
    } else if glyphHeight < Int(Double(rep.pixelsHigh) * 0.28) {
        print("FAIL \(state): text too small for a Dock tile, \(note)")
        failures += 1
    } else if margin < edgeInset {
        print("FAIL \(state): text runs into the icon edge, \(note)")
        failures += 1
    } else {
        print("PASS \(state): \(note)")
    }
}

exit(failures > 0 ? 1 : 0)
