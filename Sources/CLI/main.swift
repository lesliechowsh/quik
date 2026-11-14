import Foundation

let help = """
quik — 读取 Quik 菜单栏监控的当前系统状态

用法:
  quik            人类可读的摘要
  quik --json     机器可读的 JSON，字段说明见 Quik 技能文件
退出码: 0 流畅  1 有点卡  2 卡住了  3 没有数据（Quik 没在运行或数据过期）
"""

let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    print(help)
    exit(0)
}

let exitCodes = ["fluid": 0, "sluggish": 1, "stalled": 2]

guard let snapshot = StatusFile.read() else {
    print("没有找到 Quik 的状态文件。Quik 可能没在运行，先打开 Quik 再试。")
    exit(3)
}
if snapshot.isStale(now: Date()) {
    let age = Int(Date().timeIntervalSince(snapshot.at))
    print("Quik 的数据已经 \(age) 秒没有更新，它可能刚退出。先打开 Quik 再试。")
    exit(3)
}

if arguments.contains("--json") {
    print(String(data: snapshot.encode() ?? Data(), encoding: .utf8) ?? "{}")
} else {
    print("\(snapshot.levelLabel) \(snapshot.score)/100")
    print(snapshot.summary)
    if let top = snapshot.culprits.first {
        var parts = ["pid \(top.pid)"]
        parts.append("CPU \(String(format: "%.1f", top.cpuCores)) 核")
        if top.diskMBps > 0 {
            parts.append("磁盘 \(String(format: "%.1f", top.diskMBps)) MB/s")
        }
        if top.memoryMB > 0 {
            parts.append("内存 \(top.memoryMB) MB")
        }
        let role = top.role.map { "（\($0)）" } ?? ""
        print("主因：\(top.name)\(role) · " + parts.joined(separator: " · "))
    }
}

exit(Int32(exitCodes[snapshot.level] ?? 3))
