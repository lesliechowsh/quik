import SwiftUI

struct PanelView: View {
    @ObservedObject var store: QuikStore
    var onSample: (Culprit) -> Void
    var onQuit: (Culprit) -> Void
    var onActivityMonitor: () -> Void
    var onToggleHUD: () -> Void
    var onToggleAdvanced: () -> Void

    private var assessment: StallAssessment { store.assessment }

    var body: some View {
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
                Text("结束前先保存好正在编辑的内容。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: 400, height: store.advanced ? 500 : 390, alignment: .top)
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
                Text(assessment.level.label)
                    .font(store.advanced ? .title3.weight(.semibold) : .system(size: 30, weight: .bold))
                    .foregroundStyle(store.advanced ? Color.primary : accent)
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        if assessment.level == .fluid {
            return "现在用起来是流畅的，不需要做什么。"
        }
        var parts: [String] = []
        if let cause = assessment.stableCause {
            parts.append(plainCause(cause))
        } else {
            parts.append("刚才的资源争用让系统还没缓过来。")
        }
        if let culprit = assessment.headlineCulprit {
            parts.append("占用资源最多的是「\(culprit.displayName)」。")
        }
        return parts.joined()
    }

    private func plainCause(_ kind: CauseKind) -> String {
        switch kind {
        case .cpu: return "CPU 被占满了，系统来不及处理你的操作。"
        case .memory: return "内存不够用了，系统一直在腾地方。"
        case .disk: return "硬盘太忙了，读写都要排队。"
        case .scheduling: return "系统响应变慢了，点下去要等一会儿才有反应。"
        case .thermal: return "机器太热了，性能被压下来了。"
        }
    }

    private var calmState: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("最近 \(store.history.count) 秒都正常")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var causes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(assessment.level == .fluid ? "现在的状态" : "哪里出了问题")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(assessment.causes.prefix(3)) { cause in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(for: cause.kind))
                        .frame(width: 16)
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cause.headline).font(.callout.weight(.medium))
                        Text(cause.detail).font(.caption).foregroundStyle(.secondary)
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
                Text(assessment.level == .fluid ? "占用最多的" : "先处理这个")
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
                Text("这些资源是系统自己在用，普通权限看不到是哪个程序。可以打开活动监视器查看。")
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
                    Text("还有约 \(Int((1 - assessment.measuredCPUShare) * 100))% 的 CPU 被系统进程占用，普通权限看不到明细")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Sparkline(values: store.history, accent: accent)
                    .frame(height: 30)
            }
            HStack {
                Text(store.advanced ? "最近 \(store.history.count) 秒" : "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if store.advanced {
                    Button("活动监视器", action: onActivityMonitor)
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Button(store.hudVisible ? "隐藏悬浮窗" : "显示悬浮窗", action: onToggleHUD)
                    .buttonStyle(.link)
                    .font(.caption)
                Button(store.advanced ? "普通模式" : "高级模式", action: onToggleAdvanced)
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
                    Text(role)
                        .font(advanced ? .caption2 : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if advanced, !culprit.reason.isEmpty {
                Text(culprit.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if culprit.app?.isSystem != true {
                Button(advanced ? "结束" : "结束\(culprit.displayName)", action: onQuit)
                    .buttonStyle(QuitButtonStyle(compact: advanced))
                    .opacity(advanced && !hovering ? 0.8 : 1)
            }
            if advanced {
                Menu {
                    Button("查看它在忙什么（3 秒）", action: onSample)
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
