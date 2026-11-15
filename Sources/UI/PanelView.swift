import SwiftUI

struct PanelView: View {
    @ObservedObject var store: QuikStore
    var onSample: (Culprit) -> Void
    var onQuit: (Culprit) -> Void
    var onActivityMonitor: () -> Void
    var onToggleHUD: () -> Void
    var onToggleAdvanced: () -> Void
    var showingAgentInstall: Bool = PanelView.agentPreviewState != nil
    var onShowAgentInstall: () -> Void = {}
    var onCloseAgentInstall: () -> Void = {}

    private static var agentPreviewState: SkillState? {
        switch ProcessInfo.processInfo.environment["QUIK_PREVIEW_AGENT"] {
        case "1": return .absent
        case "installed": return .installed
        default: return nil
        }
    }

    private var assessment: StallAssessment { store.assessment }

    var body: some View {
        if showingAgentInstall {
            AgentInstallView(
                onBack: onCloseAgentInstall,
                previewState: PanelView.agentPreviewState
            )
        } else {
            mainPanel
        }
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if store.advanced {
                if assessment.causes.isEmpty {
                    calmState
                } else {
                    causes
                }
            }
            culprits
            if !store.advanced, assessment.level != .fluid {
                Text(Copy.saveFirstHint())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: 400, alignment: .top)
        .frame(minHeight: 390, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var accent: Color {
        switch assessment.level {
        case .fluid: return .green
        case .sluggish: return .orange
        case .stalled: return .red
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if store.advanced {
                    Text("\(assessment.score)")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
                Text(Copy.level(assessment.level))
                    .font(store.advanced ? .title3.weight(.semibold) : .system(size: 30, weight: .bold))
                    .foregroundStyle(store.advanced ? Color.primary : accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        Copy.summary(assessment)
    }

    private var calmState: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(Copy.normalForLast(store.history.count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var causes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(assessment.level == .fluid ? Copy.currentState() : Copy.whatWentWrong())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(assessment.causes.prefix(3)) { cause in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(for: cause.kind))
                        .frame(width: 16)
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Copy.causeHeadline(cause)).font(.callout.weight(.medium))
                        Text(Copy.causeDetail(cause))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func icon(for kind: CauseKind) -> String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .scheduling: return "clock.badge.exclamationmark"
        case .thermal: return "thermometer.high"
        }
    }

    private var culprits: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !assessment.culprits.isEmpty {
                Text(assessment.level == .fluid ? Copy.usingTheMost() : Copy.fixThisFirst())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 5)
                ForEach(assessment.culprits.prefix(3)) { culprit in
                    CulpritRow(
                        culprit: culprit,
                        advanced: store.advanced,
                        onSample: { onSample(culprit) },
                        onQuit: { onQuit(culprit) }
                    )
                }
            } else if assessment.level != .fluid {
                Text(Copy.systemResourcesHidden())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if store.advanced {
                if assessment.level != .fluid && assessment.measuredCPUShare < 0.85 {
                    Text(Copy.hiddenCPUShare(Int(((1 - assessment.measuredCPUShare) * 100).rounded())))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Sparkline(values: store.history, accent: accent)
                    .frame(height: 30)
            }
            Text(store.advanced ? Copy.lastSeconds(store.history.count) : " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // Wraps instead of shrinking: German and French labels are longer
            // than the Chinese ones this row was sized for.
            FlowLayout(spacing: 10) {
                if store.advanced {
                    Button(Copy.activityMonitor(), action: onActivityMonitor)
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Button(store.hudVisible ? Copy.hideHUD() : Copy.showHUD(), action: onToggleHUD)
                    .buttonStyle(.link)
                    .font(.caption)
                Button(Copy.installForAssistant(), action: onShowAgentInstall)
                    .buttonStyle(.link)
                    .font(.caption)
                Button(store.advanced ? Copy.normalMode() : Copy.advancedMode(), action: onToggleAdvanced)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

private struct CulpritRow: View {
    let culprit: Culprit
    var advanced: Bool
    var onSample: () -> Void
    var onQuit: () -> Void

    @State private var hovering = false

    private var icon: NSImage? {
        guard let path = culprit.app?.bundlePath else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: advanced ? 18 : 26, height: advanced ? 18 : 26)
                } else {
                    Image(systemName: culprit.app?.bundlePath == nil ? "terminal" : "gearshape")
                        .frame(width: advanced ? 18 : 26, height: advanced ? 18 : 26)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(culprit.displayName)
                    .font(advanced ? .callout : .title3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let role = culprit.app?.role {
                    Text(Copy.processRole(role))
                        .font(advanced ? .caption2 : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if advanced, culprit.reason != .none {
                Text(Copy.culpritReason(culprit.reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if culprit.app?.isSystem != true {
                Button(advanced ? Copy.quit() : Copy.quitCulprit(culprit.displayName), action: onQuit)
                    .buttonStyle(QuitButtonStyle(compact: advanced))
                    .opacity(advanced && !hovering ? 0.8 : 1)
            }
            if advanced {
                Menu {
                    Button(Copy.sample(), action: onSample)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                .opacity(hovering ? 1 : 0.45)
            }
        }
        .padding(.vertical, advanced ? 4 : 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct QuitButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
            .foregroundStyle(.red)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 3 : 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.red.opacity(configuration.isPressed ? 0.25 : 0.12))
            )
            .contentShape(Rectangle())
    }
}

private struct Sparkline: View {
    let values: [Int]
    let accent: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let maxValue = max(values.max() ?? 1, 1)
            let stepX = size.width / CGFloat(max(values.count - 1, 1))
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let y = size.height - CGFloat(value) / CGFloat(maxValue) * size.height
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(accent.opacity(0.8)), lineWidth: 1.5)
        }
    }
}
