import SwiftUI

/// Builds the install prompt the user pastes into their agent, and the panel
/// section that hands it over with one click.
enum AgentInstall {
    static var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/quik").path
    }

    static var skillMarkdown: String? {
        guard let url = Bundle.main.url(forResource: "quik-skill", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "{{QUIK_CLI}}", with: cliPath)
    }

    static func prompt() -> String? {
        guard let skill = skillMarkdown else { return nil }
        let cli = cliPath
        return """
        帮我安装 Quik 的系统监控技能。装好后，我就能直接问你"电脑现在卡不卡、什么在拖慢系统"，你会用 Quik 的实时监控数据回答。

        步骤：

        1. 把下面的技能文件原样保存为 ~/.claude/skills/quik/SKILL.md。如果你的技能目录不同（比如 Cursor 用 ~/.cursor/skills/quik/SKILL.md），放到对应位置。
        2. 可选：把命令行工具加进 PATH，方便我手动查询：
           ln -sf "\(cli)" /usr/local/bin/quik
        3. 验证：运行 "\(cli) --json"，能输出 JSON 就说明装好了。

        技能文件内容如下，原样保存，不要改动最上面的 frontmatter：

        ````markdown
        \(skill)
        ````

        完成后告诉我装好了。
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
            Text("提示词里带着要安装的文件内容，AI 助手会自己完成剩下的步骤。之后随 Quik 常驻，不用再装第二次。")
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
