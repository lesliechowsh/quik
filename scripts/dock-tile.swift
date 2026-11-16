#!/usr/bin/env swift
import AppKit
import ApplicationServices
import CoreGraphics

// Clicks a Dock tile the way a person does, with real mouse events at the
// tile's centre. The Accessibility press action is not the same path: it
// skips the Dock's activation click, so it cannot prove the toggle.
// usage: dock-tile.swift <tile title>

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: dock-tile.swift <tile title>\n".utf8))
    exit(2)
}
guard let dock = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
    FileHandle.standardError.write(Data("Dock is not running\n".utf8))
    exit(1)
}
let app = AXUIElementCreateApplication(dock.processIdentifier)
guard let list = children(app).first else {
    FileHandle.standardError.write(Data("Dock has no item list\n".utf8))
    exit(1)
}
guard let tile = children(list).first(where: { (attribute($0, kAXTitleAttribute) as? String) == arguments[1] }) else {
    let titles = children(list).compactMap { attribute($0, kAXTitleAttribute) as? String }
    FileHandle.standardError.write(Data("no tile \(arguments[1]); have \(titles)\n".utf8))
    exit(1)
}

var positionValue: AnyObject?
var sizeValue: AnyObject?
AXUIElementCopyAttributeValue(tile, kAXPositionAttribute as CFString, &positionValue)
AXUIElementCopyAttributeValue(tile, kAXSizeAttribute as CFString, &sizeValue)
var origin = CGPoint.zero
var size = CGSize.zero
if let positionValue { AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin) }
if let sizeValue { AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) }
let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)

for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(120_000)
}
print("clicked \(arguments[1]) at \(Int(center.x)),\(Int(center.y))")
