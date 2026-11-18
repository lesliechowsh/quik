import Foundation

enum StallLevel: Int, Comparable, Sendable {
    case fluid = 0
    case sluggish = 1
    case stalled = 2

    static func < (lhs: StallLevel, rhs: StallLevel) -> Bool { lhs.rawValue < rhs.rawValue }

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

}

/// What a cause measured, kept as numbers rather than a sentence so the panel,
/// the floating window, and the agent snapshot can each render it in their own
/// language.
enum CauseMetrics: Sendable, Equatable {
    case cpu(busyPercent: Int, busyCores: Int, cores: Int)
    case memory(pressure: Int32, compressedGB: Double, swapUsedMB: Double, paging: Bool)
    case disk(busyPercent: Int, readBytesPerSecond: Double, writeBytesPerSecond: Double)
    case scheduling(jankMs: Int, baselineMs: Int)
    case thermal(ProcessInfo.ThermalState)
}

struct CauseEvidence: Sendable, Identifiable {
    var id: CauseKind { kind }
    let kind: CauseKind
    let contribution: Int
    let metrics: CauseMetrics
}

enum CulpritReason: Sendable, Equatable {
    case none
    case cpuShare(percent: Int)
    case cpuCores(Double)
    case disk(bytesPerSecond: Double)
    case memory(bytes: Double)
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

enum ProcessRole: Sendable, Equatable {
    case pageRendering
    case graphics
    case plugin
    case background
    case webContent
    case workingDirectory(String)
}

struct AppIdentity: Sendable, Equatable {
    let name: String
    let bundlePath: String?
    let role: ProcessRole?
    var ownerPid: pid_t? = nil
    var isSystem = false

    /// Two processes share a row when this matches. The role is left out on
    /// purpose, so an app's helpers collapse into the app the user acts on.
    var groupKey: String? {
        if let bundlePath { return "app:" + bundlePath }
        if let role, case .workingDirectory(let folder) = role {
            return "proc:" + name + ":" + folder
        }
        if isSystem { return "proc:" + name }
        // Two unrelated processes sharing only a name must not share a row.
        return nil
    }
}

struct Culprit: Sendable, Identifiable {
    let pid: pid_t
    let name: String
    let attribution: Attribution
    let cpuOneCore: Double
    let diskBytesPerSecond: UInt64
    let footprintBytes: UInt64
    let score: Int
    let reason: CulpritReason
    var groupKey: String = ""
    var memberPids: [pid_t] = []
    var app: AppIdentity? = nil

    var id: String { groupKey.isEmpty ? "pid:\(pid)" : groupKey }

    var displayName: String { app?.name ?? name }
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

    static func idle(at date: Date = Date()) -> StallAssessment {
        StallAssessment(
            at: date, score: 0, level: .fluid, stableCause: nil, causes: [], culprits: [],
            cpuBusy: 0, cpuCores: 0, memoryPressure: 0, compressorBytes: 0,
            swapUsedBytes: 0, diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0,
            schedulerJankMs: 0, thermal: .nominal, measuredCPUShare: 1
        )
    }
}
