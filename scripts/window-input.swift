#!/usr/bin/env swift
import CoreGraphics
import Foundation

// Synthetic mouse input for the window checks. Coordinates are screen points
// with the origin at the top left, the same space window-bounds reports.
// usage: window-input.swift drag x1 y1 x2 y2 | click x y

func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func click(_ point: CGPoint) {
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        post(type, point)
        usleep(120_000)
    }
}

func drag(from: CGPoint, to: CGPoint) {
    post(.mouseMoved, from)
    usleep(150_000)
    post(.leftMouseDown, from)
    usleep(150_000)
    for step in 1...20 {
        let t = Double(step) / 20
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(20_000)
    }
    usleep(150_000)
    post(.leftMouseUp, to)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: window-input.swift drag|click ...\n".utf8))
    exit(2)
}
func number(_ index: Int) -> CGFloat {
    CGFloat(Double(arguments[index]) ?? 0)
}
switch arguments[1] {
case "drag" where arguments.count >= 6:
    drag(from: CGPoint(x: number(2), y: number(3)), to: CGPoint(x: number(4), y: number(5)))
case "click" where arguments.count >= 4:
    click(CGPoint(x: number(2), y: number(3)))
default:
    FileHandle.standardError.write(Data("usage: window-input.swift drag x1 y1 x2 y2 | click x y\n".utf8))
    exit(2)
}
