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
        let owners: [pid_t: AppIdentity] = [
            42: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .pageRendering)
        ]
        var assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, owners: owners, at: Date())
        for _ in 0..<3 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, owners: owners, at: Date())
        }
        XCTAssertEqual(assessment.culprits.first?.displayName, "Slack")
        XCTAssertEqual(assessment.culprits.first?.app?.role, .pageRendering)
        XCTAssertTrue(Copy.menuTitle(assessment, advanced: true, .base).hasPrefix("Slack"))
    }

    func testHelpersOfOneAppBecomeOneRow() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 100, name: "Slack Helper (Renderer)", attribution: .measured, cpuOneCore: 2.0, diskBytesPerSecond: 0, footprintBytes: 0),
            ProcessDelta(pid: 101, name: "Slack Helper (GPU)", attribution: .measured, cpuOneCore: 1.0, diskBytesPerSecond: 0, footprintBytes: 0)
        ]
        let owners: [pid_t: AppIdentity] = [
            100: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .pageRendering),
            101: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .graphics)
        ]
        var assessment = StallAssessment.idle()
        for _ in 0..<2 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.95), processes: processes, owners: owners, at: Date())
        }
        XCTAssertEqual(assessment.culprits.count, 1)
        XCTAssertEqual(assessment.culprits.first?.displayName, "Slack")
        XCTAssertEqual(assessment.culprits.first?.cpuOneCore ?? 0, 3.0, accuracy: 0.001)
        XCTAssertEqual(Set(assessment.culprits.first?.memberPids ?? []), [100, 101])
    }

    func testReasonMemberBecomesRepresentative() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 210, name: "Slack Helper (Renderer)", attribution: .measured, cpuOneCore: 0.1, diskBytesPerSecond: 0, footprintBytes: 0),
            ProcessDelta(pid: 211, name: "Slack Helper (GPU)", attribution: .measured, cpuOneCore: 0.3, diskBytesPerSecond: 300 * 1_048_576, footprintBytes: 0)
        ]
        let owners: [pid_t: AppIdentity] = [
            210: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .pageRendering),
            211: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .graphics)
        ]
        let assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, owners: owners, at: Date())
        XCTAssertEqual(assessment.culprits.count, 1)
        XCTAssertEqual(assessment.culprits.first?.pid, 211)
    }

    func testRepresentativeHoldsUntilChallengerLeadsClearly() {
        var evaluator = StallEvaluator()
        func sweep(_ a: Double, _ b: Double) -> StallAssessment {
            let processes = [
                ProcessDelta(pid: 220, name: "Slack Helper (Renderer)", attribution: .measured, cpuOneCore: a, diskBytesPerSecond: 0, footprintBytes: 0),
                ProcessDelta(pid: 221, name: "Slack Helper (GPU)", attribution: .measured, cpuOneCore: b, diskBytesPerSecond: 0, footprintBytes: 0)
            ]
            let owners: [pid_t: AppIdentity] = [
                220: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .pageRendering),
                221: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .graphics)
            ]
            return evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, owners: owners, at: Date())
        }
        XCTAssertEqual(sweep(2.0, 1.0).culprits.first?.pid, 220)
        XCTAssertEqual(sweep(1.9, 2.0).culprits.first?.pid, 220, "挑战者只高一点不该换代表")
        XCTAssertEqual(sweep(1.9, 4.5).culprits.first?.pid, 221)
    }

    func testMemoryUsesLargestMemberNotSum() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 230, name: "Slack Helper (Renderer)", attribution: .measured, cpuOneCore: 0.1, diskBytesPerSecond: 0, footprintBytes: 1_500 * 1_048_576),
            ProcessDelta(pid: 231, name: "Slack Helper (GPU)", attribution: .measured, cpuOneCore: 0.1, diskBytesPerSecond: 0, footprintBytes: 500 * 1_048_576)
        ]
        let owners: [pid_t: AppIdentity] = [
            230: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .pageRendering),
            231: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .graphics)
        ]
        let assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.2), processes: processes, owners: owners, at: Date())
        XCTAssertEqual(assessment.culprits.count, 1)
        XCTAssertEqual(assessment.culprits.first?.footprintBytes, 1_500 * 1_048_576)
    }

    func testUnrelatedSameNameProcessesDoNotMerge() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 240, name: "node", attribution: .measured, cpuOneCore: 2.0, diskBytesPerSecond: 0, footprintBytes: 0),
            ProcessDelta(pid: 241, name: "node", attribution: .measured, cpuOneCore: 2.0, diskBytesPerSecond: 0, footprintBytes: 0)
        ]
        let owners: [pid_t: AppIdentity] = [
            240: AppIdentity(name: "node", bundlePath: nil, role: nil),
            241: AppIdentity(name: "node", bundlePath: nil, role: nil)
        ]
        let assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, owners: owners, at: Date())
        XCTAssertEqual(assessment.culprits.count, 2)
    }

    func testSystemDaemonsShareOneRow() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 250, name: "mdworker_shared", attribution: .measured, cpuOneCore: 2.0, diskBytesPerSecond: 0, footprintBytes: 0),
            ProcessDelta(pid: 251, name: "mdworker_shared", attribution: .measured, cpuOneCore: 2.0, diskBytesPerSecond: 0, footprintBytes: 0)
        ]
        let owners: [pid_t: AppIdentity] = [
            250: AppIdentity(name: "Spotlight", bundlePath: nil, role: nil, isSystem: true),
            251: AppIdentity(name: "Spotlight", bundlePath: nil, role: nil, isSystem: true)
        ]
        let assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, owners: owners, at: Date())
        XCTAssertEqual(assessment.culprits.count, 1)
        XCTAssertEqual(Set(assessment.culprits.first?.memberPids ?? []), [250, 251])
    }

    func testSummedHelpersClearTheEntryFloor() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 200, name: "Slack Helper (Renderer)", attribution: .measured, cpuOneCore: 0.55, diskBytesPerSecond: 0, footprintBytes: 0),
            ProcessDelta(pid: 201, name: "Slack Helper (GPU)", attribution: .measured, cpuOneCore: 0.55, diskBytesPerSecond: 0, footprintBytes: 0)
        ]
        let owners: [pid_t: AppIdentity] = [
            200: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .pageRendering),
            201: AppIdentity(name: "Slack", bundlePath: "/Applications/Slack.app", role: .graphics)
        ]
        var assessment = StallAssessment.idle()
        for _ in 0..<2 {
            assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, owners: owners, at: Date())
        }
        XCTAssertEqual(assessment.culprits.count, 1)
        XCTAssertEqual(assessment.culprits.first?.displayName, "Slack")
    }

    func testDifferentAppsStaySeparate() {
        var evaluator = StallEvaluator()
        let processes = [
            ProcessDelta(pid: 300, name: "A Helper", attribution: .measured, cpuOneCore: 2.0, diskBytesPerSecond: 0, footprintBytes: 0),
            ProcessDelta(pid: 301, name: "B Helper", attribution: .measured, cpuOneCore: 2.0, diskBytesPerSecond: 0, footprintBytes: 0)
        ]
        let owners: [pid_t: AppIdentity] = [
            300: AppIdentity(name: "A", bundlePath: "/Applications/A.app", role: .graphics),
            301: AppIdentity(name: "B", bundlePath: "/Applications/B.app", role: .graphics)
        ]
        let assessment = evaluator.evaluate(delta: delta(cpuBusy: 0.9), processes: processes, owners: owners, at: Date())
        XCTAssertEqual(assessment.culprits.count, 2)
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
