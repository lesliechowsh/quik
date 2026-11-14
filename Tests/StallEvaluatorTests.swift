import XCTest
@testable import Quik

final class StallEvaluatorTests: XCTestCase {
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

    func testCPUSaturationAloneDoesNotStall() {
        var evaluator = StallEvaluator()
        var assessment = StallAssessment.idle()
        for _ in 0..<5 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.96), processes: [], at: Date())
        }
        XCTAssertEqual(assessment.level, .sluggish)
        XCTAssertEqual(assessment.causes.first?.kind, .cpu)
        XCTAssertLessThan(assessment.score, 70)
    }

    func testSingleSpikeDoesNotRaiseLevel() {
        var evaluator = StallEvaluator()
        var assessment = StallAssessment.idle()
        for _ in 0..<2 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.96), processes: [], at: Date())
        }
        XCTAssertEqual(assessment.level, .fluid)
    }

    func testExperienceLatencyDrivesStalledLevel() {
        var evaluator = StallEvaluator()
        var assessment = StallAssessment.idle()
        for _ in 0..<5 {
            assessment = evaluator.evaluate(delta: delta(jankMs: 160, jankBaseline: 5), processes: [], at: Date())
        }
        XCTAssertEqual(assessment.level, .stalled)
        XCTAssertEqual(assessment.causes.first?.kind, .scheduling)
    }

    func testHighCPUWithoutLatencyIsNotStalled() {
        var evaluator = StallEvaluator()
        var assessment = StallAssessment.idle()
        for _ in 0..<6 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.98, jankMs: 2, jankBaseline: 5), processes: [], at: Date())
        }
        XCTAssertEqual(assessment.level, .sluggish)
        XCTAssertLessThan(assessment.score, 70)
    }

    func testLatencyBaselineAdapts() {
        var evaluator = StallEvaluator()
        var assessment = StallAssessment.idle()
        for _ in 0..<6 {
            assessment = evaluator.evaluate(delta: delta(jankMs: 40, jankBaseline: 30), processes: [], at: Date())
        }
        XCTAssertEqual(assessment.level, .fluid)
    }

    func testSustainedSluggishNeedsThreeSamples() {
        var evaluator = StallEvaluator()
        for _ in 0..<2 {
            _ = evaluator.evaluate(delta: delta(cpuBusy: 0.93), processes: [], at: Date())
        }
        let third = evaluator.evaluate(delta: delta(cpuBusy: 0.93), processes: [], at: Date())
        XCTAssertEqual(third.level, .sluggish)
    }

    func testMemoryPressureIsTopCause() {
        var evaluator = StallEvaluator()
        let assessment = evaluator.evaluate(
            delta: delta(pressure: 2, compressorGB: 18, swapDeltaMBps: 60),
            processes: [],
            at: Date()
        )
        XCTAssertEqual(assessment.causes.first?.kind, .memory)
        XCTAssertEqual(assessment.causes.first?.contribution, 100)
    }

    func testHysteresisHoldsStalledBeforeExit() {
        var evaluator = StallEvaluator()
        for _ in 0..<5 {
            _ = evaluator.evaluate(delta: delta(jankMs: 160, jankBaseline: 5), processes: [], at: Date())
        }
        for _ in 0..<10 {
            _ = evaluator.evaluate(delta: delta(cpuBusy: 0.10), processes: [], at: Date())
        }
        let stillStalled = evaluator.evaluate(delta: delta(cpuBusy: 0.10), processes: [], at: Date())
        XCTAssertEqual(stillStalled.level, .stalled)

        let recovered = evaluator.evaluate(delta: delta(cpuBusy: 0.10), processes: [], at: Date())
        XCTAssertEqual(recovered.level, .fluid)
    }

    func testHighCPUProcessRanksFirst() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 1, name: "idle", attribution: .measured, cpuOneCore: 0.01, diskBytesPerSecond: 0, footprintBytes: 0),
            ProcessDelta(pid: 2, name: "hot", attribution: .measured, cpuOneCore: 4.0, diskBytesPerSecond: 0, footprintBytes: 0),
            ProcessDelta(pid: 3, name: "rootd", attribution: .unreadable("系统进程"), cpuOneCore: 9, diskBytesPerSecond: 0, footprintBytes: 0)
        ]
        let assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.95), processes: processes, at: Date())
        XCTAssertEqual(assessment.culprits.first?.pid, 2)
        XCTAssertFalse(assessment.culprits.contains { $0.pid == 3 })
    }

    func testOwnerAttributionNamesTheApp() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 42, name: "Slack Helper (Renderer)", attribution: .measured, cpuOneCore: 3.0, diskBytesPerSecond: 0, footprintBytes: 0)
        ]
        var assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, at: Date())
        for _ in 0..<3 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, at: Date())
        }
        XCTAssertEqual(assessment.culprits.first?.displayName, "Slack Helper (Renderer)")

        let named = assessment.attaching([
            42: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: "页面渲染")
        ])
        XCTAssertEqual(named.culprits.first?.displayName, "Slack")
        XCTAssertEqual(named.culprits.first?.app?.role, "页面渲染")
        XCTAssertTrue(named.menuTitle(advanced: true).hasPrefix("Slack"))
    }

    func testDiskWriteSurfacesAsCause() {
        var evaluator = StallEvaluator()
        let assessment = evaluator.evaluate(
            delta: delta(diskBusy: 0.9, writeMBps: 150),
            processes: [],
            at: Date()
        )
        XCTAssertEqual(assessment.causes.first?.kind, .disk)
    }
}
