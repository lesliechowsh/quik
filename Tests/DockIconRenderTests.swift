import XCTest
import SwiftUI
import Vision
@testable import Quik

@MainActor
final class DockIconRenderTests: XCTestCase {
    func testExportAdvancedIcons() throws {
        let dir = "/tmp/quik-icons-advanced"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for state in ["fluid", "sluggish", "stalled"] {
            let view = DockIconView(assessment: PreviewFixtures.make(state), advanced: true)
                .frame(width: DockIconView.side, height: DockIconView.side)
                .clipped()
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir + "/" + state + "-advanced.png"))
        }
        let triple = StallAssessment(
            at: Date(), score: 100, level: .stalled, stableCause: .memory, causes: [], culprits: [],
            cpuBusy: 1, cpuCores: 12, memoryPressure: 2, compressorBytes: 0, swapUsedBytes: 0,
            diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, schedulerJankMs: 0,
            thermal: .critical, measuredCPUShare: 1
        )
        let dir2 = "/tmp/quik-icons-score100"
        try? FileManager.default.createDirectory(atPath: dir2, withIntermediateDirectories: true)
        let view = DockIconView(assessment: triple, advanced: true)
            .frame(width: DockIconView.side, height: DockIconView.side)
            .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir2 + "/stalled-advanced.png"))

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .uppercased()
            .replacingOccurrences(of: "O", with: "0")
        XCTAssertTrue(recognized.contains("100"), "three-digit score rendered as \(recognized)")
    }
}
