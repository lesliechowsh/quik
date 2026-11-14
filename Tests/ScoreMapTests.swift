import XCTest
@testable import Quik

final class ScoreMapTests: XCTestCase {
    private func delta(
        cpuBusy: Double = 0.2,
        pressure: Int32 = 0,
        compressorGB: Double = 0,
        diskBusy: Double = 0,
        writeMBps: Double = 0,
        jankMs: Double = 0,
        jankBaseline: Double = 5,
        swapDeltaMBps: Double = 0,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> SystemDelta {
        SystemDelta(
            wall: 1,
            cpuBusy: cpuBusy,
            cpuCores: 12,
            memoryPressure: pressure,
            compressorBytes: UInt64(compressorGB * 1_073_741_824),
            swapUsedBytes: 0,
            swapDeltaBytesPerSecond: swapDeltaMBps * 1_048_576,
            diskReadBytesPerSecond: 0,
            diskWriteBytesPerSecond: writeMBps * 1_048_576,
            diskBusy: diskBusy,
            schedulerJankMs: jankMs,
            jankBaselineMs: jankBaseline,
            thermal: thermal
        )
    }

    private func settle(_ d: SystemDelta) -> (Int, StallLevel) {
        var evaluator = StallEvaluator()
        var assessment = StallAssessment.idle()
        for _ in 0..<6 {
            assessment = evaluator.evaluate(delta: d, processes: [], at: Date())
        }
        return (assessment.score, assessment.level)
    }

    func testPrintScoreMap() {
        var lines: [String] = []
        func row(_ name: String, _ d: SystemDelta) {
            let (score, level) = settle(d)
            lines.append(String(format: "%-42@ %3d  %@", name as NSString, score, level.label))
        }

        for busy in [0.5, 0.65, 0.75, 0.85, 0.95, 1.0] {
            row(String(format: "CPU %.0f%%", busy * 100), delta(cpuBusy: busy))
        }
        for p: Int32 in [0, 1, 2] {
            row("内存压力级别 \(p)", delta(pressure: p))
        }
        for gb in [8.0, 12.0, 16.0, 20.0, 24.0] {
            row(String(format: "压缩内存 %.0f GB", gb), delta(compressorGB: gb))
        }
        for mbps in [10, 30, 60] {
            row(String(format: "交换增长 %d MB/s", mbps), delta(swapDeltaMBps: Double(mbps)))
        }
        row("压力级别 1 + 压缩 16 GB", delta(pressure: 1, compressorGB: 16))
        row("压力级别 1 + 压缩 16 GB + 交换 30 MB/s", delta(pressure: 1, compressorGB: 16, swapDeltaMBps: 30))
        row("压力级别 2 + 压缩 16 GB", delta(pressure: 2, compressorGB: 16))
        for busy in [0.5, 0.7, 0.9] {
            row(String(format: "磁盘忙 %.0f%%", busy * 100), delta(diskBusy: busy))
        }
        row("磁盘忙 90% + 写 120 MB/s", delta(diskBusy: 0.9, writeMBps: 120))
        for jank in [10.0, 25.0, 40.0, 60.0, 75.0, 100.0, 150.0, 250.0] {
            row(String(format: "响应延迟 %.0f ms（基线 5）", jank), delta(jankMs: jank))
        }
        row("CPU 95% + 延迟 45 ms", delta(cpuBusy: 0.95, jankMs: 45))
        row("CPU 85% + 延迟 60 ms", delta(cpuBusy: 0.85, jankMs: 60))
        row("压力级别 1 + 压缩 16 GB + 延迟 60 ms", delta(pressure: 1, compressorGB: 16, jankMs: 60))
        row("温度 serious", delta(thermal: .serious))
        row("温度 critical", delta(thermal: .critical))

        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: "/tmp/quik-score-map.txt", atomically: true, encoding: .utf8)

        XCTAssertEqual(settle(delta(cpuBusy: 1.0)).1, .sluggish, "CPU 饱和只能到有点卡")
        XCTAssertLessThan(settle(delta(cpuBusy: 1.0)).0, 70)
        XCTAssertEqual(settle(delta(pressure: 2)).1, .stalled, "内存 critical 直接算卡住了")
        XCTAssertEqual(settle(delta(thermal: .critical)).1, .stalled)
        XCTAssertEqual(settle(delta(jankMs: 100)).1, .stalled)
        XCTAssertEqual(settle(delta(jankMs: 60)).1, .sluggish)
        XCTAssertEqual(settle(delta(jankMs: 40)).1, .fluid)
        XCTAssertEqual(settle(delta(pressure: 1, compressorGB: 10)).1, .fluid, "日常告警压力不该报卡")
    }
}
