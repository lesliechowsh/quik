import SwiftUI

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

    /// 应用启动时把随包技能写入标准目录。每次启动覆盖，应用更新后技能跟着更新。
    @discardableResult
    static func installSkill(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        content: String? = nil
    ) -> Bool {
        guard let text = content ?? skillMarkdown else { return false }
        let manager = FileManager.default
        for location in skillLocations {
            let file = home.appendingPathComponent(location).appendingPathComponent("SKILL.md")
            do {
                try manager.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try text.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
        }
        return true
    }

    static func skillIsInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        skillLocations.allSatisfy { location in
            FileManager.default.fileExists(
                atPath: home.appendingPathComponent(location).appendingPathComponent("SKILL.md").path
            )
        }
    }

    /// 卸载：删掉 Quik 放进系统的所有东西。macOS 在应用被删除后不会执行任何
    /// 代码，所以清理只能由应用在活着时完成——状态菜单里的「卸载 Quik」调用这里。
    static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let manager = FileManager.default
        var targets = skillLocations.map { home.appendingPathComponent($0) }
        targets.append(home.appendingPathComponent(".local/bin/quik"))
        targets.append(home.appendingPathComponent("Library/Application Support/Quik"))
        for target in targets {
            try? manager.removeItem(at: target)
        }
    }

    /// 应用启动时把随包的命令行工具复制到 ~/.local/bin/quik。这是技能文件里
    /// 唯一提到的命令位置，路径里不含用户名；每次启动覆盖，应用更新后命令跟着更新。
    @discardableResult
    static func installCommandLine(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        source: URL? = nil
    ) -> Bool {
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
    @State private var installed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让 AI 助手帮你盯着电脑")
                .font(.system(size: 26, weight: .bold))
            Text("Quik 已经按 Agent Skills 开放标准，把监控技能装进了系统的标准技能目录。打开你的 AI 助手，直接问「现在电脑卡不卡」，它就会用 Quik 的实时数据回答。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                locationRow("~/.agents/skills/quik", note: "Codex、Cursor、Cline、Zed 等")
                locationRow("~/.claude/skills/quik", note: "Claude Code")
            }
            HStack(spacing: 6) {
                Image(systemName: installed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(installed ? .green : .orange)
                Text(installed ? "已安装，随 Quik 常驻" : "还没装好，点下面重试")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            Button {
                installed = AgentInstall.installSkill() && AgentInstall.installCommandLine()
            } label: {
                Label("重新安装", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("命令行工具自动放在 ~/.local/bin/quik，助手会自己找到它。不用了就在菜单栏图标的右键菜单里点「卸载 Quik」，技能、命令和数据会一次删干净。")
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
        .task { installed = AgentInstall.skillIsInstalled() }
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
