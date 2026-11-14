import Foundation

enum PreviewFixtures {
    static func make(_ state: String) -> StallAssessment {
        let now = Date()
        switch state {
        case "stalled":
            return StallAssessment(
                at: now, score: 72, level: .stalled, stableCause: .memory,
                causes: [
                    CauseEvidence(kind: .memory, contribution: 100, headline: "内存严重不足", detail: "系统压缩了 12.4 GB 内存，拿 1.8 GB 硬盘当内存用"),
                    CauseEvidence(kind: .cpu, contribution: 54, headline: "CPU 92%", detail: "12 个核心里有 11 个在忙"),
                    CauseEvidence(kind: .scheduling, contribution: 41, headline: "响应延迟 84 ms", detail: "系统晚了 84 毫秒才响应（平时只要 4 毫秒）")
                ],
                culprits: [
                    Culprit(pid: 101, name: "Slack Helper (Renderer)", attribution: .measured, cpuOneCore: 3.2, diskBytesPerSecond: 18_000_000, footprintBytes: 2_400_000_000, score: 92, reason: "31% CPU",
                        app: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: "页面渲染")),
                    Culprit(pid: 102, name: "Notion Helper (Renderer)", attribution: .measured, cpuOneCore: 1.8, diskBytesPerSecond: 2_000_000, footprintBytes: 1_500_000_000, score: 71, reason: "1.8 核",
                        app: AppIdentity(name: "Notion", bundlePath: "/Applications/Notion.app", role: "后台进程")),
                    Culprit(pid: 103, name: "mdworker_shared", attribution: .measured, cpuOneCore: 1.1, diskBytesPerSecond: 44_000_000, footprintBytes: 680_000_000, score: 64, reason: "磁盘 44 MB/s",
                        app: AppIdentity(name: "聚焦搜索", bundlePath: nil, role: nil, isSystem: true))
                ],
                cpuBusy: 0.92, cpuCores: 12, memoryPressure: 2, compressorBytes: 13_314_129_920,
                swapUsedBytes: 1_932_735_283, diskReadBytesPerSecond: 42_000_000,
                diskWriteBytesPerSecond: 51_000_000, schedulerJankMs: 84, thermal: .serious,
                measuredCPUShare: 0.68
            )
        case "sluggish":
            return StallAssessment(
                at: now, score: 58, level: .sluggish, stableCause: .disk,
                causes: [
                    CauseEvidence(kind: .disk, contribution: 58, headline: "硬盘很忙（90%）", detail: "每秒读 12 MB/s、写 28 MB/s"),
                    CauseEvidence(kind: .memory, contribution: 25, headline: "内存压力偏高", detail: "系统压缩了 8.2 GB 内存，拿 620 MB 硬盘当内存用")
                ],
                culprits: [
                    Culprit(pid: 201, name: "Slack Helper", attribution: .measured, cpuOneCore: 1.2, diskBytesPerSecond: 9_000_000, footprintBytes: 820_000_000, score: 58, reason: "占用 1.2 个核",
                        app: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: "页面渲染")),
                    Culprit(pid: 202, name: "mds_stores", attribution: .measured, cpuOneCore: 0.6, diskBytesPerSecond: 21_000_000, footprintBytes: 410_000_000, score: 44, reason: "磁盘 21 MB/s",
                        app: AppIdentity(name: "聚焦搜索", bundlePath: nil, role: nil, isSystem: true))
                ],
                cpuBusy: 0.64, cpuCores: 12, memoryPressure: 1, compressorBytes: 8_804_682_138,
                swapUsedBytes: 650_117_120, diskReadBytesPerSecond: 12_000_000,
                diskWriteBytesPerSecond: 28_000_000, schedulerJankMs: 22, thermal: .fair,
                measuredCPUShare: 0.81
            )
        default:
            return StallAssessment(
                at: now, score: 8, level: .fluid, stableCause: nil,
                causes: [],
                culprits: [],
                cpuBusy: 0.18, cpuCores: 12, memoryPressure: 0, compressorBytes: 1_073_741_824,
                swapUsedBytes: 0, diskReadBytesPerSecond: 1_000_000,
                diskWriteBytesPerSecond: 2_000_000, schedulerJankMs: 3, thermal: .nominal,
                measuredCPUShare: 1
            )
        }
    }

    static let history: [Int] = [8, 10, 9, 12, 14, 11, 13, 18, 22, 19, 24, 31, 28, 34, 41, 38, 45, 52, 49, 58]
}
