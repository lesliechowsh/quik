import AppKit
import SwiftUI

final class DockIconController {
    private var lastSignature = ""
    private var lastRenderedAt = Date.distantPast

    func update(_ assessment: StallAssessment) {
        MainActor.assumeIsolated {
            updateOnMain(assessment)
        }
    }

    @MainActor
    private func updateOnMain(_ assessment: StallAssessment) {
        let advanced = QuikStore.advancedMode
        let bucket = advanced ? assessment.score / 15 : 0
        let culprit = advanced ? "" : (assessment.headlineCulprit?.displayName ?? "")
        let signature = "\(bucket)-\(assessment.level.rawValue)-\(culprit)-\(advanced)"
        guard signature != lastSignature else { return }
        guard Date().timeIntervalSince(lastRenderedAt) >= 3 else { return }
        lastSignature = signature
        lastRenderedAt = Date()

        NSApp.applicationIconImage = render(assessment, advanced: advanced)
        NSApp.dockTile.display()
    }

    @MainActor
    private func render(_ assessment: StallAssessment, advanced: Bool) -> NSImage {
        let view = DockIconView(assessment: assessment, advanced: advanced)
            .frame(width: DockIconView.side, height: DockIconView.side)
            .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            return NSApp.applicationIconImage ?? NSImage(size: NSSize(width: DockIconView.side, height: DockIconView.side))
        }
        return NSImage(cgImage: image, size: NSSize(width: DockIconView.side, height: DockIconView.side))
    }

    @MainActor
    func export(to path: String, _ assessment: StallAssessment, advanced: Bool? = nil) {
        let image = render(assessment, advanced: advanced ?? QuikStore.advancedMode)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        let size = rep.pixelsWide
        try? "\(size)x\(rep.pixelsHigh)".write(toFile: path + ".size", atomically: true, encoding: .utf8)
    }
}

struct DockIconView: View {
    static let side: CGFloat = 128

    let assessment: StallAssessment
    var advanced = true

    private var scoreText: String { "\(assessment.score)" }

    // The rounded bold digits are 0.65em wide, so a fixed 88pt "100" is wider than
    // the tile and SwiftUI's minimumScaleFactor bottoms out at the floor and
    // truncates to "1…". Sizing by digit count keeps the number whole; the offset
    // keeps the gap to the label at 28px in both cases (scripts/icon-check.swift).
    private var scoreFontSize: CGFloat { scoreText.count >= 3 ? 52 : 70 }
    private var scoreOffset: CGFloat { scoreText.count >= 3 ? -11 : -18 }

    private var colors: [Color] {
        switch assessment.level {
        case .fluid: return [Color(red: 0.18, green: 0.58, blue: 0.36), Color(red: 0.10, green: 0.38, blue: 0.24)]
        case .sluggish: return [Color(red: 0.92, green: 0.58, blue: 0.16), Color(red: 0.70, green: 0.36, blue: 0.06)]
        case .stalled: return [Color(red: 0.88, green: 0.24, blue: 0.22), Color(red: 0.62, green: 0.10, blue: 0.10)]
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            if advanced {
                Text(scoreText)
                    .font(.system(size: scoreFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .offset(y: scoreOffset)
                Text(assessment.level.label)
                    .font(.system(size: 34, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 88)
                    .foregroundStyle(.white.opacity(0.94))
                    .offset(y: 35)
            } else {
                VStack(spacing: 2) {
                    Text(assessment.level.label)
                        .font(.system(size: 58, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: DockIconView.side - 44)
                        .foregroundStyle(.white)
                    if let culprit = assessment.headlineCulprit, assessment.level != .fluid {
                        Text(culprit.displayName)
                            .font(.system(size: 24, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .truncationMode(.middle)
                            .frame(width: DockIconView.side - 56)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(.vertical, 10)

            }
        }
    }
}
