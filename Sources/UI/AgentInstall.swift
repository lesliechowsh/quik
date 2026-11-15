import SwiftUI

/// 助手能不能用 Quik，只有一个判断依据：磁盘上的技能与命令是否齐备。
enum SkillState {
    case absent
    case partial
    case installed
}

/// Quik 交给 AI 助手的一切遵循 Agent Skills 开放标准（agentskills.io）：
/// 一个技能就是「文件夹 + SKILL.md」，兼容的助手启动时自动从磁盘发现。
/// 技能写入两个有官方文档背书的标准目录：`~/.agents/skills`（Codex、
/// Cursor、Cline、Zed、Warp 等的全局技能目录）与 `~/.claude/skills`
/// （Claude Code 的技能目录，Cursor 也会兼容读取）。
/// 所有会离开机器的位置只写 `~` 相对路径：开发构建的应用绝对路径带着
/// 机器用户名，绝不能出现在提示词、技能或界面上。
enum AgentInstall {
    /// 标准技能目录（home 相对路径），写盘、界面展示与卸载共用同一份清单。
    static let skillLocations = [".agents/skills/quik", ".claude/skills/quik"]

    static var skillMarkdown: String? {
        guard let url = Bundle.main.url(forResource: "quik-skill", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }

    /// 技能和命令缺一样，助手都会失败：技能在但命令没了，助手读到的是
    /// command not found。所以三样齐全才算装好，缺任意一样都算装了一半。
    static func skillState(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SkillState {
        let manager = FileManager.default
        let skills = skillLocations.filter { location in
            manager.fileExists(
                atPath: home.appendingPathComponent(location).appendingPathComponent("SKILL.md").path
            )
        }.count
        let hasCommand = manager.fileExists(atPath: home.appendingPathComponent(".local/bin/quik").path)
        if skills == 0 && !hasCommand { return .absent }
        if skills == skillLocations.count && hasCommand { return .installed }
        return .partial
    }

    /// 安装是用户主动点的动作。每次覆盖写，重复执行收敛到同一结果，上次只装了
    /// 一半也能补全。
    @discardableResult
    static func install(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        source: URL? = nil
    ) -> Bool {
        guard let text = skillMarkdown else { return false }
        let manager = FileManager.default
        for location in skillLocations {
            let file = home.appendingPathComponent(location).appendingPathComponent("SKILL.md")
            do {
                try manager.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // 原子写入，崩溃也不会留下半截 SKILL.md。
                try text.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
        }
        return installCommandLine(home: home, source: source)
    }

    /// 移除只清理 Quik 装进系统的技能与命令。应用自己的数据目录留给 uninstall，
    /// 移除后 Quik 还要继续运行。
    static func remove(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let manager = FileManager.default
        var targets = skillLocations.map { home.appendingPathComponent($0) }
        targets.append(home.appendingPathComponent(".local/bin/quik"))
        for target in targets {
            try? manager.removeItem(at: target)
        }
    }

    /// 卸载：删掉 Quik 放进系统的所有东西。macOS 在应用被删除后不会执行任何
    /// 代码，所以清理只能由应用在活着时完成，状态菜单里的「卸载 Quik」调用这里。
    static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        remove(home: home)
        try? FileManager.default.removeItem(
            at: home.appendingPathComponent("Library/Application Support/Quik")
        )
    }

    /// 把随包的命令行工具复制到 ~/.local/bin/quik。这是技能文件里唯一提到的
    /// 命令位置，路径里不含用户名；每次覆盖，应用更新后命令跟着更新。
    private static func installCommandLine(home: URL, source: URL?) -> Bool {
        let cli = source ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Library/quik")
        let destination = home.appendingPathComponent(".local/bin/quik")
        let manager = FileManager.default
        guard manager.fileExists(atPath: cli.path) else { return false }
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: cli, to: destination)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            return true
        } catch {
            return false
        }
    }
}

struct AgentInstallView: View {
    var onBack: () -> Void
    private let previewState: SkillState?
    @State private var state: SkillState

    init(onBack: @escaping () -> Void, previewState: SkillState? = nil) {
        self.onBack = onBack
        self.previewState = previewState
        _state = State(initialValue: previewState ?? .absent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让 AI 助手帮你盯着电脑")
                .font(.system(size: 26, weight: .bold))
            Text("装好之后，你的 AI 助手能读到 Quik 的实时数据。直接问它「现在电脑卡不卡」，它会替你回答。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                locationRow("~/.agents/skills/quik", note: "Codex、Cursor、Cline、Zed 等")
                locationRow("~/.claude/skills/quik", note: "Claude Code")
            }
            HStack(spacing: 6) {
                Image(systemName: state == .installed ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(state == .installed ? Color.green : Color.secondary)
                Text(statusText)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(state == .installed ? "重新安装" : "安装") {
                    AgentInstall.install()
                    refresh()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if state != .absent {
                    Button("移除") {
                        AgentInstall.remove()
                        refresh()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                Spacer(minLength: 0)
            }
            Text("命令行工具会一起放到 ~/.local/bin/quik，别的地方不写文件。移除会把技能和命令一起删掉。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("返回", action: onBack)
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 400, height: 390, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            guard previewState == nil else { return }
            refresh()
        }
    }

    private var statusText: String {
        switch state {
        case .absent: return "还没安装"
        case .partial: return "只装了一半，点安装补全"
        case .installed: return "已安装，随 Quik 常驻"
        }
    }

    private func refresh() {
        state = AgentInstall.skillState()
    }

    private func locationRow(_ path: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
