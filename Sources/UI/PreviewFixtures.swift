import Foundation

enum PreviewFixtures {
    static func make(_ state: String) -> StallAssessment {
        let now = Date()
        switch state {
        case "stalled":
            return StallAssessment(
                at: now, score: 72, level: .stalled, stableCause: .memory,
                causes: [
                    CauseEvidence(kind: .memory, contribution: 100, metrics: .memory(pressure: 2, compressedGB: 12.4, swapUsedMB: 1_843, paging: true)),
                    CauseEvidence(kind: .cpu, contribution: 54, metrics: .cpu(busyPercent: 92, busyCores: 11, cores: 12)),
                    CauseEvidence(kind: .scheduling, contribution: 41, metrics: .scheduling(jankMs: 84, baselineMs: 4))
                ],
                culprits: [
                    Culprit(pid: 101, name: "Slack Helper (Renderer)", attribution: .measured, cpuOneCore: 3.2, diskBytesPerSecond: 18_000_000, footprintBytes: 2_400_000_000, score: 92, reason: .cpuShare(percent: 31),
                        app: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .pageRendering)),
                    Culprit(pid: 102, name: "Notion Helper (Renderer)", attribution: .measured, cpuOneCore: 1.8, diskBytesPerSecond: 2_000_000, footprintBytes: 1_500_000_000, score: 71, reason: .cpuCores(1.8),
                        app: AppIdentity(name: "Notion", bundlePath: "/Applications/Notion.app", role: .background)),
                    Culprit(pid: 103, name: "mdworker_shared", attribution: .measured, cpuOneCore: 1.1, diskBytesPerSecond: 44_000_000, footprintBytes: 680_000_000, score: 64, reason: .disk(bytesPerSecond: 44_000_000),
                        app: AppIdentity(name: Copy.systemProcessName("mdworker")!, bundlePath: nil, role: nil, isSystem: true))
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
                    CauseEvidence(kind: .disk, contribution: 58, metrics: .disk(busyPercent: 90, readBytesPerSecond: 12_000_000, writeBytesPerSecond: 28_000_000)),
                    CauseEvidence(kind: .memory, contribution: 25, metrics: .memory(pressure: 1, compressedGB: 8.2, swapUsedMB: 620, paging: false))
                ],
                culprits: [
                    Culprit(pid: 201, name: "Slack Helper", attribution: .measured, cpuOneCore: 1.2, diskBytesPerSecond: 9_000_000, footprintBytes: 820_000_000, score: 58, reason: .cpuCores(1.2),
                        app: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .pageRendering)),
                    Culprit(pid: 202, name: "mds_stores", attribution: .measured, cpuOneCore: 0.6, diskBytesPerSecond: 21_000_000, footprintBytes: 410_000_000, score: 44, reason: .disk(bytesPerSecond: 21_000_000),
                        app: AppIdentity(name: Copy.systemProcessName("mdworker")!, bundlePath: nil, role: nil, isSystem: true))
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
