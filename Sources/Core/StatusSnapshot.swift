import Foundation

/// The machine-readable view of one assessment. This is the contract between
/// the running app and every agent that reads the status file, so it changes
/// only by bumping `schema`.
struct SnapshotCause: Codable, Equatable, Sendable {
    let kind: String
    let label: String
    let contribution: Int
}

struct SnapshotCulprit: Codable, Equatable, Sendable {
    let pid: Int32
    let name: String
    let role: String?
    let cpuCores: Double
    let diskMBps: Double
    let memoryMB: Int
    let score: Int
    let reason: String
}

struct StatusSnapshot: Codable, Equatable, Sendable {
    let schema: Int
    let appVersion: String
    let at: Date
    let level: String
    let levelLabel: String
    let score: Int
    let summary: String
    let causes: [SnapshotCause]
    let culprits: [SnapshotCulprit]
    let cpuBusyPercent: Int
    let cpuCores: Int
    let diskReadMBps: Double
    let diskWriteMBps: Double
    let schedulerJankMs: Double
    let memoryPressure: String
    let thermal: String

    init(assessment: StallAssessment, appVersion: String) {
        self.schema = 1
        self.appVersion = appVersion
        self.at = assessment.at
        self.level = assessment.level.caseName
        self.levelLabel = assessment.level.label
        self.score = assessment.score
        self.summary = assessment.plainSummary
        self.causes = assessment.causes.map {
            SnapshotCause(kind: $0.kind.rawValue, label: $0.kind.label, contribution: $0.contribution)
        }
        self.culprits = assessment.culprits.map { culprit in
            SnapshotCulprit(
                pid: culprit.pid,
                name: culprit.displayName,
                role: culprit.app?.role,
                cpuCores: (culprit.cpuOneCore * 100).rounded() / 100,
                diskMBps: (Double(culprit.diskBytesPerSecond) / 1_048_576 * 10).rounded() / 10,
                memoryMB: Int(culprit.footprintBytes / 1_048_576),
                score: culprit.score,
                reason: culprit.reason
            )
        }
        self.cpuBusyPercent = Int((assessment.cpuBusy * 100).rounded())
        self.cpuCores = assessment.cpuCores
        self.diskReadMBps = (Double(assessment.diskReadBytesPerSecond) / 1_048_576 * 10).rounded() / 10
        self.diskWriteMBps = (Double(assessment.diskWriteBytesPerSecond) / 1_048_576 * 10).rounded() / 10
        self.schedulerJankMs = (assessment.schedulerJankMs * 10).rounded() / 10
        self.memoryPressure = StatusSnapshot.memoryPressureName(assessment.memoryPressure)
        self.thermal = assessment.thermal.caseName
    }

    private static func memoryPressureName(_ level: Int32) -> String {
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 3: return "critical"
        default: return "unknown"
        }
    }

    func isStale(now: Date, after seconds: TimeInterval = 5) -> Bool {
        now.timeIntervalSince(at) > seconds
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    func encode() -> Data? {
        try? StatusSnapshot.makeEncoder().encode(self)
    }

    static func decode(_ data: Data) -> StatusSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StatusSnapshot.self, from: data)
    }
}

/// One writer, one reader, one path. The app rewrites the file every tick and
/// deletes it on quit, so a missing or old file means Quik is not running.
enum StatusFile {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Quik/status.json")
    }

    static func write(_ snapshot: StatusSnapshot) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = snapshot.encode() else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return StatusSnapshot.decode(data)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
