import Foundation

final class MonitorEngine {
    private let queue = DispatchQueue(label: "dev.quik.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastSystem: RawSystemSnapshot?
    private var lastProcesses: [pid_t: RawProcess] = [:]
    private var lastProcessDeltas: [ProcessDelta] = []
    private var lastProcessSweepAt: Date?
    private let processSweepInterval: TimeInterval = 3
    private var evaluator = StallEvaluator()
    private var smoother = ProcessSmoother()
    private var history: [Int] = []
    private var lastDeadline: UInt64?
    private let historyLimit = 60
    private let interval: TimeInterval
    private let experience = ExperienceProbe()

    var onUpdate: ((StallAssessment, [Int]) -> Void)?

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    func start() {
        experience.start()
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now(),
                repeating: .milliseconds(Int(self.interval * 1000)),
                leeway: .milliseconds(10)
            )
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func tick() {
        let now = DispatchTime.now()
        var jankMs: Double = 0
        if let last = lastDeadline {
            let elapsed = Double(now.uptimeNanoseconds - last) / 1_000_000
            jankMs = max(0, elapsed - interval * 1000)
        }
        lastDeadline = now.uptimeNanoseconds

        let snapshot = SystemProbe.read()
        defer { lastSystem = snapshot }
        guard let previous = lastSystem else { return }

        let report = experience.snapshot()
        let delta = DeltaCalculator.system(
            previous: previous,
            current: snapshot,
            jankMs: jankMs > 0 ? jankMs : report.p95,
            jankBaselineMs: report.baselineP95
        )
        guard delta.isValid else { return }
        var processDeltas = lastProcessDeltas
        if lastProcessSweepAt == nil || snapshot.at.timeIntervalSince(lastProcessSweepAt!) >= processSweepInterval - 0.2 {
            let processes = ProcessProbe.readAll()
            let sweepWall = snapshot.at.timeIntervalSince(lastProcessSweepAt ?? previous.at)
            processDeltas = smoother.smooth(
                DeltaCalculator.processes(
                    previous: lastProcesses,
                    current: processes,
                    wall: sweepWall,
                    excluding: getpid()
                ),
                at: snapshot.at
            )
            lastProcesses = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
            lastProcessDeltas = processDeltas
            lastProcessSweepAt = snapshot.at
        }
        var assessment = evaluator.evaluate(delta: delta, processes: processDeltas, at: snapshot.at)
        assessment = assessment.attaching(AppOwnerResolver.resolve(assessment.culprits.map(\.pid)))

        if ProcessInfo.processInfo.environment["QUIK_DEBUG"] == "1" {
            debugLog(delta: delta, processes: processDeltas, assessment: assessment)
        }

        history.append(assessment.score)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }

        let levels = history
        let output = assessment
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(output, levels)
        }
    }

    private func debugLog(delta: SystemDelta, processes: [ProcessDelta], assessment: StallAssessment) {
        let top = assessment.culprits.map {
            String(format: "%@ pid=%d core=%.2f share=%.2f", $0.name, $0.pid, $0.cpuOneCore, Double($0.score) / 100)
        }.joined(separator: " | ")
        let measured = processes.filter { $0.attribution == .measured }.reduce(0) { $0 + $1.cpuOneCore }
        let causes = assessment.causes.map { "\($0.kind.rawValue):\($0.contribution)" }.joined(separator: ",")
        let line = String(
            format: "level=%d score=%d busy=%.0f%% jank95=%.1f baseline=%.1f measured=%.2f share=%.2f stable=%@ causes=[%@] top=[%@]\n",
            assessment.level.rawValue, assessment.score, delta.cpuBusy * 100,
            delta.schedulerJankMs, delta.jankBaselineMs,
            measured, assessment.measuredCPUShare, assessment.stableCause?.rawValue ?? "-", causes, top
        )
        let path = "/tmp/quik-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
        }
    }
}
