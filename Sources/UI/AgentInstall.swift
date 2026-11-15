import SwiftUI

/// 复制安装提示词的面板入口。提示词内嵌技能全文，只引用 `quik` 与
/// `~/.local/bin/quik` 两个固定位置，绝不引用应用所在路径：开发构建从
/// build 目录运行时，应用路径本身就带着机器的用户名。
enum AgentInstall {
    static var skillMarkdown: String? {
        guard let url = Bundle.main.url(forResource: "quik-skill", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }

    static func prompt() -> String? {
        guard let skill = skillMarkdown else { return nil }
        return """
        帮我安装 Quik 的系统监控技能。装好后，你就能直接回答"电脑现在卡不卡、什么在拖慢系统"，数据来自 Quik 的实时监控。

        步骤：

        1. 把下面的技能文件原样保存为 ~/.claude/skills/quik/SKILL.md。如果你的技能目录不同（比如 Cursor 用 ~/.cursor/skills/quik/SKILL.md），放到对应位置。
        2. 验证：运行 `~/.local/bin/quik --json`。命令行工具由 Quik 在运行时自动放到那里，不需要安装。如果命令不存在，说明 Quik 没在运行，让我先打开 Quik 再试。
        3. 完成后告诉我装好了。

        技能文件内容如下，原样保存，不要改动最上面的 frontmatter：

        ````markdown
        \(skill)
        ````
        """
    }

    @discardableResult
    static func copyPrompt() -> Bool {
        guard let prompt = prompt() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        return true
    }

    /// 应用启动时把随包的命令行工具复制到 ~/.local/bin/quik。这是提示词和
    /// 技能文件里唯一提到的命令位置，路径里不含用户名；每次启动覆盖，应用
    /// 更新后命令跟着更新。
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
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让 AI 助手帮你盯着电脑")
                .font(.system(size: 26, weight: .bold))
            Text("点下面的按钮复制一段提示词，粘贴给你的 AI 助手（Claude Code、Cursor 都可以）。装好后，你直接问它「现在电脑卡不卡」，它就会用 Quik 的数据回答。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                copied = AgentInstall.copyPrompt()
            } label: {
                Label(
                    copied ? "已复制，去粘贴给 AI 助手" : "复制安装提示词",
                    systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .task { copied = AgentInstall.copyPrompt() }
            Text("提示词里带着要安装的文件内容，AI 助手会自己完成剩下的步骤。命令行工具不用管，Quik 运行时自动放到 ~/.local/bin。装一次就行，之后随 Quik 常驻。")
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
    }
}
