import Foundation

/// Per-process EWMA over consecutive sweeps. A single 3 second window is too
/// short to rank processes; one burst of rendering puts a helper on top for one
/// row refresh and drops it the next. Alpha 0.4 gives a time constant of about
/// two sweeps (6 seconds), long enough to hold a real trend and short enough to
/// still react within one row refresh.
struct ProcessSmoother {
    private struct Entry {
        var cpu: Double
        var disk: Double
        var lastSeen: Date
    }

    private var entries: [pid_t: Entry] = [:]
    private let alpha = 0.4
    private let forgetAfter: TimeInterval = 60

    mutating func smooth(_ deltas: [ProcessDelta], at: Date) -> [ProcessDelta] {
        var out: [ProcessDelta] = []
        out.reserveCapacity(deltas.count)
        for delta in deltas {
            let previous = entries[delta.pid]
            let cpu = previous.map { $0.cpu + alpha * (delta.cpuOneCore - $0.cpu) } ?? delta.cpuOneCore
            let disk = previous.map { $0.disk + alpha * (delta.diskBytesPerSecond - $0.disk) } ?? delta.diskBytesPerSecond
            entries[delta.pid] = Entry(cpu: cpu, disk: disk, lastSeen: at)
            out.append(ProcessDelta(
                pid: delta.pid, name: delta.name, attribution: delta.attribution,
                cpuOneCore: cpu, diskBytesPerSecond: disk, footprintBytes: delta.footprintBytes
            ))
        }
        if entries.count > 512 {
            entries = entries.filter { at.timeIntervalSince($0.value.lastSeen) < forgetAfter }
        }
        return out
    }
}
