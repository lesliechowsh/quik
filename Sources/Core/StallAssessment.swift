import Foundation

enum StallLevel: Int, Comparable, Sendable {
    case fluid = 0
    case sluggish = 1
    case stalled = 2

    static func < (lhs: StallLevel, rhs: StallLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .fluid: return "流畅"
        case .sluggish: return "有点卡"
        case .stalled: return "卡住了"
        }
    }

    /// The snake_case name agents read from the status file and the skill.
    var caseName: String {
        switch self {
        case .fluid: return "fluid"
        case .sluggish: return "sluggish"
        case .stalled: return "stalled"
        }
    }
}

enum CauseKind: String, CaseIterable, Sendable {
    case cpu
    case memory
    case disk
    case scheduling
    case thermal

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .scheduling: return "调度"
        case .thermal: return "温度"
        }
    }

    /// The one plain sentence this cause turns into for a non-technical user.
    /// Panel, floating window, and the agent status file all read from here.
    var plainSentence: String {
        switch self {
        case .cpu: return "CPU 被占满了，系统来不及处理你的操作。"
        case .memory: return "内存不够用了，系统一直在腾地方。"
        case .disk: return "硬盘太忙了，读写都要排队。"
        case .scheduling: return "系统响应变慢了，点下去要等一会儿才有反应。"
        case .thermal: return "机器太热了，性能被压下来了。"
        }
    }
}

struct CauseEvidence: Sendable, Identifiable {
    var id: CauseKind { kind }
    let kind: CauseKind
    let contribution: Int
    let headline: String
    let detail: String
}

enum Attribution: Sendable, Equatable {
    case measured
    case unreadable(String)
}

extension ProcessInfo.ThermalState {
    /// The name agents read from the status file.
    var caseName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

struct AppIdentity: Sendable, Equatable {
    let name: String
    let bundlePath: String?
    let role: String?
    var ownerPid: pid_t? = nil
    var isSystem = false
}

struct Culprit: Sendable, Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let attribution: Attribution
    let cpuOneCore: Double
    let diskBytesPerSecond: UInt64
    let footprintBytes: UInt64
    let score: Int
    let reason: String
    var app: AppIdentity? = nil

    var displayName: String { app?.name ?? name }
}

extension StallAssessment {
    func attaching(_ owners: [pid_t: AppIdentity]) -> StallAssessment {
        guard !owners.isEmpty else { return self }
        return StallAssessment(
            at: at, score: score, level: level, stableCause: stableCause, causes: causes,
            culprits: culprits.map { culprit in
                var copy = culprit
                copy.app = owners[culprit.pid]
                return copy
            },
            cpuBusy: cpuBusy, cpuCores: cpuCores, memoryPressure: memoryPressure,
            compressorBytes: compressorBytes, swapUsedBytes: swapUsedBytes,
            diskReadBytesPerSecond: diskReadBytesPerSecond,
            diskWriteBytesPerSecond: diskWriteBytesPerSecond,
            schedulerJankMs: schedulerJankMs, thermal: thermal,
            measuredCPUShare: measuredCPUShare
        )
    }
}

struct StallAssessment: Sendable {
    let at: Date
    let score: Int
    let level: StallLevel
    /// The cause that has dominated the last few seconds. Normal mode speaks from
    /// this so the sentence does not change on every one second sample.
    let stableCause: CauseKind?
    let causes: [CauseEvidence]
    let culprits: [Culprit]
    let cpuBusy: Double
    let cpuCores: Int
    let memoryPressure: Int32
    let compressorBytes: UInt64
    let swapUsedBytes: UInt64
    let diskReadBytesPerSecond: UInt64
    let diskWriteBytesPerSecond: UInt64
    let schedulerJankMs: Double
    let thermal: ProcessInfo.ThermalState
    let measuredCPUShare: Double

    var topCause: CauseEvidence? { causes.first }
    var headlineCulprit: Culprit? { culprits.first }

    /// The sentence a non-technical user reads, in panel and in the agent feed.
    var plainSummary: String {
        if level == .fluid {
            return "现在用起来是流畅的，不需要做什么。"
        }
        var parts: [String] = []
        if let cause = stableCause {
            parts.append(cause.plainSentence)
        } else {
            parts.append("刚才的资源争用让系统还没缓过来。")
        }
        if let culprit = headlineCulprit {
            parts.append("占用资源最多的是「\(culprit.displayName)」。")
        }
        return parts.joined()
    }

    func menuTitle(advanced: Bool) -> String {
        switch level {
        case .fluid:
            return advanced ? "\(score)" : "流畅"
        case .sluggish, .stalled:
            if let culprit = headlineCulprit {
                let name = attributionShort(culprit.displayName)
                guard advanced else { return name }
                let pct = Int((culprit.cpuOneCore * 100).rounded())
                return name + " \(pct)%"
            }
            return advanced ? "\(score)" : level.label
        }
    }

    private func attributionShort(_ name: String) -> String {
        let stripped = name.replacingOccurrences(of: ".app", with: "")
        return String(stripped.prefix(9))
    }

    static func idle(at date: Date = Date()) -> StallAssessment {
        StallAssessment(
            at: date, score: 0, level: .fluid, stableCause: nil, causes: [], culprits: [],
            cpuBusy: 0, cpuCores: 0, memoryPressure: 0, compressorBytes: 0,
            swapUsedBytes: 0, diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0,
            schedulerJankMs: 0, thermal: .nominal, measuredCPUShare: 1
        )
    }
}
