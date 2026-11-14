import Foundation
import Darwin

/// Measures how late a high-priority thread wakes from an exact deadline.
/// That lateness is the direct cost a user feels: the system did not run my work when I asked.
final class ExperienceProbe {
    struct Report {
        let p50: Double
        let p95: Double
        let max: Double
        let over25ms: Int
        let samples: Int
        let baselineP95: Double
        let isCalibrating: Bool
    }

    private let lock = NSLock()
    private var latencies: [Double] = []
    private var baseline: [Double] = []
    private var running = false
    private var cachedBaselineP95: Double = 0
    private var baselineComputedAt = Date.distantPast
    private var thread: Thread?
    private let intervalMs: Double = 100
    private let windowSize = 30
    private let baselineWindow = 600
    private let calibrationSeconds: Double = 60

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.loop()
        }
        thread.name = "dev.quik.experience"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func snapshot() -> Report {
        lock.lock()
        defer { lock.unlock() }
        let recent = Array(latencies.suffix(windowSize))
        let now = Date()
        if now.timeIntervalSince(baselineComputedAt) > 5 {
            cachedBaselineP95 = percentile(baseline, 0.95)
            baselineComputedAt = now
        }
        let baselineP95 = cachedBaselineP95
        return Report(
            p50: percentile(recent, 0.50),
            p95: percentile(recent, 0.95),
            max: recent.max() ?? 0,
            over25ms: recent.filter { $0 > 25 }.count,
            samples: recent.count,
            baselineP95: baselineP95,
            isCalibrating: Double(baseline.count) * intervalMs / 1000 < calibrationSeconds
        )
    }

    private func loop() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        let periodNs = UInt64(intervalMs * 1_000_000)
        let periodAbs = periodNs * denom / numer
        var next = mach_absolute_time()

        while isRunning {
            next &+= periodAbs
            mach_wait_until(next)
            let now = mach_absolute_time()
            let lateAbs = now > next ? now - next : 0
            let lateMs = Double(lateAbs * numer / denom) / 1_000_000

            // A sleep/wake or a debugger pause is not a stall the user felt.
            if lateMs < 5_000 {
                record(lateMs)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func record(_ lateMs: Double) {
        lock.lock()
        latencies.append(lateMs)
        if latencies.count > 1_200 {
            latencies.removeFirst(latencies.count - 1_200)
        }
        baseline.append(lateMs)
        if baseline.count > baselineWindow {
            baseline.removeFirst(baseline.count - baselineWindow)
        }
        lock.unlock()
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
