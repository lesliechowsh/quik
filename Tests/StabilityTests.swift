import XCTest
@testable import Quik

final class StabilityTests: XCTestCase {
    private func delta(cpuBusy: Double = 0.2, diskBusy: Double = 0) -> SystemDelta {
        SystemDelta(
            wall: 1, cpuBusy: cpuBusy, cpuCores: 12,
            memoryPressure: 0, compressorBytes: 0, swapUsedBytes: 0,
            swapDeltaBytesPerSecond: 0, diskReadBytesPerSecond: 0,
            diskWriteBytesPerSecond: 0, diskBusy: diskBusy,
            schedulerJankMs: 0, jankBaselineMs: 5, thermal: .nominal
        )
    }

    private func process(_ pid: pid_t, _ cpu: Double) -> ProcessDelta {
        ProcessDelta(pid: pid, name: "p\(pid)", attribution: .measured,
                     cpuOneCore: cpu, diskBytesPerSecond: 0, footprintBytes: 0)
    }

    func testPulsingLoadDoesNotFlipLevel() {
        var evaluator = StallEvaluator()
        var levels: [StallLevel] = []
        for _ in 0..<5 {
            for _ in 0..<6 {
                levels.append(evaluator.evaluate(delta: delta(cpuBusy: 0.98), processes: [], at: Date()).level)
            }
            for _ in 0..<6 {
                levels.append(evaluator.evaluate(delta: delta(cpuBusy: 0.08), processes: [], at: Date()).level)
            }
        }
        let flips = zip(levels, levels.dropFirst()).filter { $0 != $1 }.count
        XCTAssertEqual(levels.first, .fluid)
        XCTAssertEqual(levels.last, .sluggish)
        XCTAssertLessThanOrEqual(flips, 1, "6 秒满负载、6 秒空闲重复 5 次，标签只该切换一次")
    }

    func testSustainedCalmRecovers() {
        var evaluator = StallEvaluator()
        for _ in 0..<4 {
            _ = evaluator.evaluate(delta: delta(cpuBusy: 0.98), processes: [], at: Date())
        }
        var assessment = StallAssessment.idle()
        for _ in 0..<25 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.08), processes: [], at: Date())
        }
        XCTAssertEqual(assessment.level, .fluid)
    }

    func testRankingHoldsUntilChallengerLeadsClearly() {
        var evaluator = StallEvaluator()
        let busy = delta(cpuBusy: 0.9)
        _ = evaluator.evaluate(delta: busy, processes: [process(1, 3.0), process(2, 2.5)], at: Date())
        let close = evaluator.evaluate(delta: busy, processes: [process(1, 3.0), process(2, 2.7)], at: Date())
        XCTAssertEqual(close.culprits.first?.pid, 1, "只高出一点不该顶掉原来的第一")

        let clear = evaluator.evaluate(delta: busy, processes: [process(1, 3.0), process(2, 4.5)], at: Date())
        XCTAssertEqual(clear.culprits.first?.pid, 2)
    }

    func testRowStaysWhenLoadDipsBelowEntryFloor() {
        var evaluator = StallEvaluator()
        let busy = delta(cpuBusy: 0.9)
        _ = evaluator.evaluate(delta: busy, processes: [process(9, 1.0)], at: Date())
        let dip = evaluator.evaluate(delta: busy, processes: [process(9, 0.3)], at: Date())
        XCTAssertTrue(dip.culprits.contains { $0.pid == 9 })

        let gone = evaluator.evaluate(delta: busy, processes: [process(9, 0.1)], at: Date())
        XCTAssertFalse(gone.culprits.contains { $0.pid == 9 })
    }

    func testSmootherDampsAlternatingLoad() {
        var smoother = ProcessSmoother()
        var values: [Double] = []
        for index in 0..<8 {
            let cpu = index % 2 == 0 ? 1.0 : 0.0
            values.append(smoother.smooth([process(7, cpu)], at: Date()).first?.cpuOneCore ?? 0)
        }
        let tail = Array(values.suffix(4))
        XCTAssertGreaterThan(tail.min() ?? 0, 0.2, "低点不该掉到零")
        XCTAssertLessThan(tail.max() ?? 0, 0.8, "高点不该冲到满")
    }

    func testRecentCauseSurvivesShortGap() {
        var evaluator = StallEvaluator()
        for _ in 0..<5 {
            _ = evaluator.evaluate(delta: delta(cpuBusy: 0.98), processes: [], at: Date())
        }
        var assessment = StallAssessment.idle()
        for _ in 0..<5 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.08), processes: [], at: Date())
        }
        XCTAssertEqual(assessment.level, .sluggish, "负载停了不到退出时长，标签还在")
        XCTAssertEqual(assessment.stableCause, .cpu, "说明用的原因跟着标签一起停住")
    }

    func testTopCauseHoldsAgainstSmallLead() {
        var evaluator = StallEvaluator()
        let cpuOnly = evaluator.evaluate(delta: delta(cpuBusy: 0.85), processes: [], at: Date())
        XCTAssertEqual(cpuOnly.causes.first?.kind, .cpu)

        let diskClose = evaluator.evaluate(delta: delta(cpuBusy: 0.85, diskBusy: 0.7), processes: [], at: Date())
        XCTAssertEqual(diskClose.causes.first?.kind, .cpu, "接近的贡献不该换首句原因")

        let diskClear = evaluator.evaluate(delta: delta(cpuBusy: 0.85, diskBusy: 0.95), processes: [], at: Date())
        XCTAssertEqual(diskClear.causes.first?.kind, .disk)
    }
}
