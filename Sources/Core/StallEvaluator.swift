import Foundation

struct StallState: Sendable {
    var level: StallLevel = .fluid
    var samplesInLevel = 0
    var aboveSluggish = 0
    var aboveStalled = 0
    var belowExit = 0
}

struct StallEvaluator: Sendable {
    private var state = StallState()
    private var recentScores: [Int] = []
    private var previousCauseOrder: [CauseKind] = []
    private var previousRank: [pid_t] = []
    private var recentCauseLoad: [CauseKind: Double] = [:]
    private var stableCauseKind: CauseKind?

    private static let sluggishEnter = 40
    private static let stalledEnter = 70
    private static let exitScore = 25
    private static let criticalScore = 72
    private static let sluggishSamples = 3
    private static let stalledSamples = 5
    private static let exitSamples = 10
    private static let sluggishDwell = 8
    private static let stalledDwell = 12
    private static let causeEntryFloor = 12
    private static let causeRetainFloor = 6
    private static let rankEntryFloor = 12
    private static let rankRetainFloor = 6
    private static let rankMargin = 1.25
    private static let causeMargin = 1.25

    mutating func evaluate(delta: SystemDelta, processes: [ProcessDelta], at: Date) -> StallAssessment {
        let rawCauses = causes(for: delta)
        let causes = stableCauses(rawCauses)
        rememberScore(compositeScore(rawCauses, delta))
        let score = smoothedScore
        advanceState(score: score)
        trackRecentCause(rawCauses)

        let measuredCores = processes
            .filter { $0.attribution == .measured }
            .reduce(0) { $0 + $1.cpuOneCore }
        let busyCores = delta.cpuBusy * Double(delta.cpuCores)
        let share = busyCores > 0 ? min(measuredCores / busyCores, 1) : 1

        return StallAssessment(
            at: at,
            score: score,
            level: state.level,
            stableCause: stableCauseKind,
            causes: causes,
            culprits: rank(processes: processes, delta: delta, busyCores: busyCores),
            cpuBusy: delta.cpuBusy,
            cpuCores: delta.cpuCores,
            memoryPressure: delta.memoryPressure,
            compressorBytes: delta.compressorBytes,
            swapUsedBytes: delta.swapUsedBytes,
            diskReadBytesPerSecond: UInt64(saturating: delta.diskReadBytesPerSecond),
            diskWriteBytesPerSecond: UInt64(saturating: delta.diskWriteBytesPerSecond),
            schedulerJankMs: delta.schedulerJankMs,
            thermal: delta.thermal,
            measuredCPUShare: share
        )
    }

    private var smoothedScore: Int {
        guard recentScores.count >= 3 else { return recentScores.last ?? 0 }
        return recentScores.sorted()[1]
    }

    private mutating func rememberScore(_ score: Int) {
        recentScores.append(score)
        if recentScores.count > 3 {
            recentScores.removeFirst(recentScores.count - 3)
        }
    }

    private mutating func advanceState(score: Int) {
        state.samplesInLevel += 1
        if score >= Self.stalledEnter {
            state.aboveStalled += 1
        } else {
            state.aboveStalled = 0
        }
        if score >= Self.sluggishEnter {
            state.aboveSluggish += 1
        } else {
            state.aboveSluggish = 0
        }
        if score < Self.exitScore {
            state.belowExit += 1
        } else {
            state.belowExit = 0
        }

        let enteringStalled = state.aboveStalled >= Self.stalledSamples
        let enteringSluggish = state.aboveSluggish >= Self.sluggishSamples
        let leaving = state.belowExit >= Self.exitSamples && state.samplesInLevel >= dwell(for: state.level)

        let previous = state.level
        switch state.level {
        case .fluid:
            if enteringStalled { state.level = .stalled }
            else if enteringSluggish { state.level = .sluggish }
        case .sluggish:
            if enteringStalled { state.level = .stalled }
            else if leaving { state.level = .fluid }
        case .stalled:
            if leaving { state.level = .fluid }
        }
        if state.level != previous {
            state.samplesInLevel = 0
        }
    }

    /// A level change is a statement about the machine, not about this second.
    /// Hold the new level before letting it fall back, so a workload that pulses
    /// on and off reads as one steady state instead of alternating labels.
    private func dwell(for level: StallLevel) -> Int {
        switch level {
        case .fluid: return 0
        case .sluggish: return Self.sluggishDwell
        case .stalled: return Self.stalledDwell
        }
    }

    /// Peak hold with a slow release, the same shape a level meter uses. A cause
    /// jumps to its new value at once and decays over the next few seconds, so a
    /// burst that stops four seconds ago still explains a held 有点卡.
    private mutating func trackRecentCause(_ raw: [CauseEvidence]) {
        let present = Dictionary(uniqueKeysWithValues: raw.map { ($0.kind, Double($0.contribution)) })
        for kind in CauseKind.allCases {
            let target = present[kind] ?? 0
            let previous = recentCauseLoad[kind] ?? 0
            recentCauseLoad[kind] = target >= previous ? target : previous * 0.8
        }
        guard let peak = recentCauseLoad.max(by: { $0.value < $1.value }), peak.value >= 20 else {
            stableCauseKind = nil
            return
        }
        if let current = stableCauseKind, let currentLoad = recentCauseLoad[current] {
            if peak.key != current && peak.value > currentLoad * 1.25 + 4 {
                stableCauseKind = peak.key
            }
        } else {
            stableCauseKind = peak.key
        }
    }

    private mutating func stableCauses(_ raw: [CauseEvidence]) -> [CauseEvidence] {
        let byKind = Dictionary(uniqueKeysWithValues: raw.map { ($0.kind, $0) })
        var order = previousCauseOrder.filter { kind in
            guard let cause = byKind[kind] else { return false }
            return cause.contribution >= Self.causeRetainFloor
        }
        for cause in raw.sorted(by: { $0.contribution > $1.contribution })
        where cause.contribution >= Self.causeEntryFloor && !order.contains(cause.kind) {
            order.append(cause.kind)
        }
        var swapped = true
        var passes = 0
        while swapped && passes < order.count {
            swapped = false
            passes += 1
            for index in 0..<max(0, order.count - 1) {
                guard let a = byKind[order[index]], let b = byKind[order[index + 1]] else { continue }
                if Double(b.contribution) > Double(a.contribution) * Self.causeMargin + 4 {
                    order.swapAt(index, index + 1)
                    swapped = true
                }
            }
        }
        previousCauseOrder = order
        return order.compactMap { byKind[$0] }
    }

    func causes(for delta: SystemDelta) -> [CauseEvidence] {
        var out: [CauseEvidence] = []
        let cpu = cpuContribution(delta)
        if cpu > 0 {
            out.append(CauseEvidence(
                kind: .cpu, contribution: cpu,
                headline: "CPU \(Int((delta.cpuBusy * 100).rounded()))%",
                detail: "\(delta.cpuCores) 个核心里有 \(Int((delta.cpuBusy * Double(delta.cpuCores)).rounded())) 个在忙"
            ))
        }
        let mem = memoryContribution(delta)
        if mem > 0 {
            out.append(CauseEvidence(
                kind: .memory, contribution: mem,
                headline: memoryHeadline(delta),
                detail: memoryDetail(delta)
            ))
        }
        let disk = diskContribution(delta)
        if disk > 0 {
            out.append(CauseEvidence(
                kind: .disk, contribution: disk,
                headline: "硬盘很忙（\(Int((delta.diskBusy * 100).rounded()))%）",
                detail: "每秒读 \(formatRate(delta.diskReadBytesPerSecond))、写 \(formatRate(delta.diskWriteBytesPerSecond))"
            ))
        }
        let sched = schedulingContribution(delta)
        if sched > 0 {
            out.append(CauseEvidence(
                kind: .scheduling, contribution: sched,
                headline: "响应延迟 \(Int(delta.schedulerJankMs.rounded())) ms",
                detail: "系统晚了 \(Int(delta.schedulerJankMs.rounded())) 毫秒才响应（平时只要 \(Int(delta.jankBaselineMs.rounded())) 毫秒）"
            ))
        }
        let heat = thermalContribution(delta.thermal)
        if heat > 0 {
            out.append(CauseEvidence(
                kind: .thermal, contribution: heat,
                headline: "温度限制",
                detail: thermalDetail(delta.thermal)
            ))
        }
        return out.sorted { $0.contribution > $1.contribution }
    }

    func compositeScore(_ causes: [CauseEvidence], _ delta: SystemDelta) -> Int {
        let experience = causes.first { $0.kind == .scheduling }?.contribution ?? 0
        let resource = causes.filter { $0.kind != .scheduling }.map(\.contribution).max() ?? 0
        var score = min(100, max(experience, Int((Double(resource) * 0.65).rounded())))
        score = max(score, criticalFloor(delta))
        return score
    }

    /// A resource can only claim 卡住了 when the kernel itself says it is out of room.
    /// Measured latency stays the normal path to that level.
    private func criticalFloor(_ delta: SystemDelta) -> Int {
        if delta.memoryPressure >= 2 { return Self.criticalScore }
        if delta.thermal == .critical { return Self.criticalScore }
        return 0
    }

    func cpuContribution(_ delta: SystemDelta) -> Int {
        norm(delta.cpuBusy, low: 0.65, high: 0.95)
    }

    func memoryContribution(_ delta: SystemDelta) -> Int {
        var score: Double
        switch delta.memoryPressure {
        case 2: score = 100
        case 1: score = 25
        default: score = 0
        }
        let compressorGB = Double(delta.compressorBytes) / 1_073_741_824
        if compressorGB > 20 { score += 35 }
        else if compressorGB > 12 { score += 20 }
        if delta.swapDeltaBytesPerSecond > 50 * 1_048_576 { score += 40 }
        else if delta.swapDeltaBytesPerSecond > 10 * 1_048_576 { score += 25 }
        return min(100, Int(score.rounded()))
    }

    func diskContribution(_ delta: SystemDelta) -> Int {
        var score = Double(norm(delta.diskBusy, low: 0.5, high: 0.95))
        if delta.diskWriteBytesPerSecond > 100 * 1_048_576 { score += 20 }
        return min(100, Int(score.rounded()))
    }

    func schedulingContribution(_ delta: SystemDelta) -> Int {
        let threshold = max(delta.jankBaselineMs * 3, 25)
        guard delta.schedulerJankMs >= threshold else { return 0 }
        return norm(delta.schedulerJankMs, low: threshold, high: threshold * 4)
    }

    func thermalContribution(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 0
        case .serious: return 70
        case .critical: return 100
        @unknown default: return 0
        }
    }

    /// Rows keep their place until a challenger is clearly ahead. Without the
    /// margin, two helpers of the same app trade places every sweep while their
    /// smoothed load is within a couple of percent.
    private mutating func rank(processes: [ProcessDelta], delta: SystemDelta, busyCores: Double) -> [Culprit] {
        let previouslyRanked = Set(previousRank)
        let scored: [Culprit] = processes
            .filter { $0.attribution == .measured }
            .filter { $0.cpuOneCore > 0.02 || $0.diskBytesPerSecond > 1_048_576 || $0.footprintBytes > 500 * 1_048_576 }
            .map { proc -> Culprit in
                let cpuShare = busyCores > 0 ? min(proc.cpuOneCore / busyCores, 1) : 0
                let cpuScore = cpuShare * 200
                let diskScore = min(proc.diskBytesPerSecond / (200 * 1_048_576), 1) * 100
                let memScore = min(Double(proc.footprintBytes) / (8 * 1_073_741_824), 1) * 60
                let score = max(cpuScore, diskScore, memScore)
                return Culprit(
                    pid: proc.pid,
                    name: proc.name,
                    attribution: proc.attribution,
                    cpuOneCore: proc.cpuOneCore,
                    diskBytesPerSecond: UInt64(saturating: proc.diskBytesPerSecond),
                    footprintBytes: proc.footprintBytes,
                    score: Int(score.rounded()),
                    reason: reason(for: proc, cpuShare: cpuShare)
                )
            }
            .filter { $0.score >= (previouslyRanked.contains($0.pid) ? Self.rankRetainFloor : Self.rankEntryFloor) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.pid < $1.pid }

        let candidates = Array(scored.prefix(20))
        let byPid = Dictionary(uniqueKeysWithValues: candidates.map { ($0.pid, $0) })
        var order = previousRank.filter { byPid[$0] != nil }
        var included = Set(order)
        for culprit in candidates where !included.contains(culprit.pid) {
            order.append(culprit.pid)
            included.insert(culprit.pid)
        }

        var swapped = true
        var passes = 0
        while swapped && passes < order.count {
            swapped = false
            passes += 1
            for index in 0..<max(0, order.count - 1) {
                guard let a = byPid[order[index]], let b = byPid[order[index + 1]] else { continue }
                if Double(b.score) > Double(a.score) * Self.rankMargin + 4 {
                    order.swapAt(index, index + 1)
                    swapped = true
                }
            }
        }

        previousRank = Array(order.prefix(8))
        return Array(order.prefix(5)).compactMap { byPid[$0] }
    }

    private func reason(for proc: ProcessDelta, cpuShare: Double) -> String {
        if cpuShare > 0.2 {
            return String(format: "%.0f%% CPU", cpuShare * 100)
        }
        if proc.cpuOneCore >= 0.5 {
            return String(format: "%.1f 核", proc.cpuOneCore)
        }
        if proc.diskBytesPerSecond > 5 * 1_048_576 {
            return "磁盘 \(formatRate(proc.diskBytesPerSecond))"
        }
        if proc.footprintBytes > 1_073_741_824 {
            return String(format: "%.1f GB 内存", Double(proc.footprintBytes) / 1_073_741_824)
        }
        return ""
    }

    private func memoryHeadline(_ delta: SystemDelta) -> String {
        switch delta.memoryPressure {
        case 2: return "内存严重不足"
        case 1: return "内存压力偏高"
        default: return "内存压缩 \(Int(Double(delta.compressorBytes) / 1_073_741_824)) GB"
        }
    }

    private func memoryDetail(_ delta: SystemDelta) -> String {
        var parts = [
            "系统压缩了 \(String(format: "%.1f", Double(delta.compressorBytes) / 1_073_741_824)) GB 内存",
            "拿 \(String(format: "%.0f", Double(delta.swapUsedBytes) / 1_048_576)) MB 硬盘当内存用"
        ]
        if delta.swapDeltaBytesPerSecond > 1_048_576 {
            parts.append("还在不停地把数据搬进搬出")
        }
        return parts.joined(separator: "，")
    }

    private func thermalDetail(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .fair: return "芯片开始降频"
        case .serious: return "明显降频，性能被压低"
        case .critical: return "严重过热，系统强制限速"
        default: return "温度正常"
        }
    }

    private func norm(_ value: Double, low: Double, high: Double) -> Int {
        guard high > low else { return 0 }
        let ratio = (value - low) / (high - low)
        return min(100, max(0, Int((ratio * 100).rounded())))
    }
}

func formatRate(_ bytesPerSecond: Double) -> String {
    let mb = bytesPerSecond / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB/s", mb / 1024) }
    if mb >= 1 { return String(format: "%.0f MB/s", mb) }
    return String(format: "%.0f KB/s", bytesPerSecond / 1024)
}
