import AppKit
import CoreGraphics

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Quik"
let assertMode = CommandLine.arguments.contains("--assert")
let noOverlap = CommandLine.arguments.contains("--no-overlap")
let tolerance: CGFloat = 2

let screens = NSScreen.screens
let primaryHeight = screens.first?.frame.height ?? 0
let screenRects = screens.map { s -> CGRect in
    CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height)
}

func describe(_ r: CGRect) -> String {
    "(x:\(Int(r.minX)) y:\(Int(r.minY)) w:\(Int(r.width)) h:\(Int(r.height)))"
}

if let idx = CommandLine.arguments.firstIndex(of: "--rect"),
   CommandLine.arguments.count > idx + 1 {
    let parts = CommandLine.arguments[idx + 1].split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else {
        print("usage: --rect x,y,w,h")
        exit(2)
    }
    let rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    let inside = screenRects.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(rect) }
    print("\(inside ? "PASS" : "FAIL") rect \(describe(rect)) inside=\(inside)")
    exit(inside ? 0 : 1)
}

if !assertMode {
    print("== screens ==")
    for (screen, rect) in zip(screens, screenRects) {
        print("frame=\(screen.frame) visible=\(screen.visibleFrame) safeTop=\(screen.safeAreaInsets.top) cg=\(describe(rect)) name=\(screen.localizedName)")
    }
    print("== windows ==")
}

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var failures = 0
var rects: [(Int, CGRect)] = []
for info in list {
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == target else { continue }
    let number = info[kCGWindowNumber as String] as? Int ?? 0
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    let b = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    let inside = screenRects.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(rect) }
    rects.append((number, rect))
    if assertMode {
        if inside {
            print("ok window=\(number) \(describe(rect))")
        } else {
            failures += 1
            print("off-screen window=\(number) layer=\(layer) \(describe(rect))")
        }
    } else {
        print("window=\(number) layer=\(layer) cg=\(describe(rect)) inside=\(inside)")
    }
}

if noOverlap {
    for i in 0..<rects.count {
        for j in (i + 1)..<rects.count {
            let overlap = rects[i].1.insetBy(dx: tolerance, dy: tolerance).intersection(rects[j].1)
            if !overlap.isNull && overlap.width > 0 && overlap.height > 0 {
                failures += 1
                print("overlap window=\(rects[i].0) and window=\(rects[j].0) \(describe(overlap))")
            }
        }
    }
}

if assertMode || noOverlap {
    if failures > 0 {
        print("FAIL \(failures) window check(s) failed")
        exit(1)
    }
    print(noOverlap ? "PASS no Quik windows overlap" : "PASS all windows inside a screen")
}
