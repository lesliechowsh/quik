import Foundation

struct SystemDelta: Sendable {
    let wall: TimeInterval
    let cpuBusy: Double
    let cpuCores: Int
    let memoryPressure: Int32
    let compressorBytes: UInt64
    let swapUsedBytes: UInt64
    let swapDeltaBytesPerSecond: Double
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let diskBusy: Double
    let schedulerJankMs: Double
    let jankBaselineMs: Double
    let thermal: ProcessInfo.ThermalState

    var isValid: Bool { wall > 0.05 && wall < 5 && cpuCores > 0 }
}

struct ProcessDelta: Sendable {
    let pid: pid_t
    let name: String
    let attribution: Attribution
    let cpuOneCore: Double
    let diskBytesPerSecond: Double
    let footprintBytes: UInt64
}

enum DeltaCalculator {
    static func system(previous: RawSystemSnapshot, current: RawSystemSnapshot, jankMs: Double, jankBaselineMs: Double) -> SystemDelta {
        let wall = max(current.at.timeIntervalSince(previous.at), 0.001)

        var busyTicks: Double = 0
        var totalTicks: Double = 0
        var cores = current.cpuTicks.count
        if previous.cpuTicks.count == current.cpuTicks.count {
            // CPU ticks are 32-bit counters that really do wrap; disk totals never do.
            for (a, b) in zip(previous.cpuTicks, current.cpuTicks) {
                let du = Double(b.user &- a.user)
                let ds = Double(b.system &- a.system)
                let di = Double(b.idle &- a.idle)
                let dn = Double(b.nice &- a.nice)
                busyTicks += du + ds + dn
                totalTicks += du + ds + di + dn
            }
        } else {
            cores = 0
        }

        let swapDelta = Double(current.memory.swapUsed) - Double(previous.memory.swapUsed)
        let diskRead = Double(counterDelta(current.disk.readBytes, previous.disk.readBytes)) / wall
        let diskWrite = Double(counterDelta(current.disk.writeBytes, previous.disk.writeBytes)) / wall
        let busyNs = Double(counterDelta(current.disk.busyNs, previous.disk.busyNs))
        let deviceCount = max(Double(current.disk.deviceCount), 1)

        return SystemDelta(
            wall: wall,
            cpuBusy: totalTicks > 0 ? busyTicks / totalTicks : 0,
            cpuCores: cores,
            memoryPressure: current.memory.pressureLevel,
            compressorBytes: current.memory.compressorPages * current.memory.pageSize,
            swapUsedBytes: current.memory.swapUsed,
            swapDeltaBytesPerSecond: swapDelta / wall,
            diskReadBytesPerSecond: max(diskRead, 0),
            diskWriteBytesPerSecond: max(diskWrite, 0),
            diskBusy: min(busyNs / (wall * 1_000_000_000 * deviceCount), 1),
            schedulerJankMs: jankMs,
            jankBaselineMs: jankBaselineMs,
            thermal: current.thermal
        )
    }

    static func processes(
        previous: [pid_t: RawProcess],
        current: [RawProcess],
        wall: TimeInterval,
        excluding excludedPid: pid_t
    ) -> [ProcessDelta] {
        let denominator = max(wall, 0.001) * 1_000_000_000
        return current.compactMap { proc in
            guard proc.pid != excludedPid else { return nil }
            let cpu = proc.cpuNs
            let diskRead = proc.diskReadBytes
            let diskWrite = proc.diskWriteBytes
            let footprint = proc.footprintBytes
            let previousCpu = previous[proc.pid]?.cpuNs ?? cpu
            let previousRead = previous[proc.pid]?.diskReadBytes ?? diskRead
            let previousWrite = previous[proc.pid]?.diskWriteBytes ?? diskWrite
            let cpuDelta = cpu >= previousCpu ? Double(cpu - previousCpu) : 0
            let readDelta = diskRead >= previousRead ? diskRead - previousRead : 0
            let writeDelta = diskWrite >= previousWrite ? diskWrite - previousWrite : 0
            return ProcessDelta(
                pid: proc.pid, name: proc.name, attribution: .measured,
                cpuOneCore: cpuDelta / denominator,
                diskBytesPerSecond: (Double(readDelta) + Double(writeDelta)) / max(wall, 0.001),
                footprintBytes: footprint
            )
        }
    }

    /// Device totals drop when the set of attached devices changes, and a probe
    /// can read zero before it is warm. Treating that as a value close to
    /// UInt64.max turns one unmounted disk into an exabyte per second, which then
    /// cannot be converted to UInt64 at all.
    private static func counterDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

extension UInt64 {
    /// The last boundary before an absurd probe reading reaches the UI.
    /// Both infinities and NaN mean "not a measurement"; a finite value above
    /// UInt64.max saturates, because `UInt64(_:)` traps on it.
    init(saturating rate: Double) {
        if !rate.isFinite || rate <= 0 {
            self = 0
        } else if rate >= Double(UInt64.max) {
            self = .max
        } else {
            self = UInt64(rate)
        }
    }
}
