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
        let diskRead = Double(current.disk.readBytes &- previous.disk.readBytes) / wall
        let diskWrite = Double(current.disk.writeBytes &- previous.disk.writeBytes) / wall
        let busyNs = Double(current.disk.busyNs &- previous.disk.busyNs)
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
                diskBytesPerSecond: Double(readDelta + writeDelta) / max(wall, 0.001),
                footprintBytes: footprint
            )
        }
    }
}
