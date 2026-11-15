import XCTest
import SwiftUI
@testable import Quik

@MainActor
final class DockIconRenderTests: XCTestCase {
    private func render(score: Int) throws -> CGImage {
        let assessment = StallAssessment(
            at: Date(), score: score, level: .stalled, stableCause: .memory, causes: [], culprits: [],
            cpuBusy: 1, cpuCores: 12, memoryPressure: 2, compressorBytes: 0, swapUsedBytes: 0,
            diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, schedulerJankMs: 0,
            thermal: .critical, measuredCPUShare: 1
        )
        let view = DockIconView(assessment: assessment, advanced: true)
            .frame(width: DockIconView.side, height: DockIconView.side)
            .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    /// Horizontal extent of the white glyph pixels in the top half, where the
    /// score sits. icon-check.swift uses the same bright and near-neutral rule
    /// to separate text from the colored tile. The label below is excluded
    /// because its bbox would dominate the measurement.
    private func scoreInkWidth(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var left = rep.pixelsWide
        var right = -1
        for y in 0..<(rep.pixelsHigh / 2) {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
                let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
                guard c.alphaComponent > 0.5, hi > 0.8, hi - lo < 0.15 else { continue }
                left = min(left, x)
                right = max(right, x)
            }
        }
        return right >= left ? right - left + 1 : 0
    }

    func testThreeDigitScoreRendersWhole() throws {
        let image = try render(score: 100)
        let width = scoreInkWidth(image)
        let fraction = Double(width) / Double(image.width)

        // Three digits at 52 points span about 67% of the 128 point tile. A
        // truncated "1…" lands near 32%, and an overflowing score would push
        // past 92%.
        XCTAssertGreaterThan(fraction, 0.55, "100 只画出 \(width)px，像是被截断了")
        XCTAssertLessThan(fraction, 0.92, "100 画出 \(width)px，超出了图标的可用宽度")
    }
}
