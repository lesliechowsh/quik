import XCTest
@testable import Quik

final class DeltaTests: XCTestCase {
    private func snapshot(
        at seconds: TimeInterval,
        read: UInt64,
        write: UInt64,
        busyNs: UInt64 = 0
    ) -> RawSystemSnapshot {
        RawSystemSnapshot(
            at: Date(timeIntervalSince1970: seconds),
            cpuTicks: [
                CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
                CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
            ],
            memory: RawMemory(
                pageSize: 16_384, freePages: 0, activePages: 0, inactivePages: 0,
                wiredPages: 0, compressorPages: 0, swapTotal: 0, swapUsed: 0,
                pressureLevel: 0
            ),
            disk: RawDisk(readBytes: read, writeBytes: write, busyNs: busyNs, deviceCount: 1),
            thermal: .nominal
        )
    }

    func testDiskCounterDropReportsNoTraffic() {
        let previous = snapshot(at: 100, read: 1_000_000_000_000, write: 500_000_000_000)
        let current = snapshot(at: 100.9, read: 0, write: 0)
        let delta = DeltaCalculator.system(previous: previous, current: current, jankMs: 0, jankBaselineMs: 5)

        XCTAssertEqual(delta.diskReadBytesPerSecond, 0)
        XCTAssertEqual(delta.diskWriteBytesPerSecond, 0)
        XCTAssertEqual(delta.diskBusy, 0)

        var evaluator = StallEvaluator()
        let assessment = evaluator.evaluate(delta: delta, processes: [], at: current.at)
        XCTAssertEqual(assessment.diskReadBytesPerSecond, 0)
    }

    func testDiskCounterGrowthReportsRate() {
        let previous = snapshot(at: 100, read: 1_000_000_000, write: 0)
        let current = snapshot(at: 101, read: 1_200_000_000, write: 100_000_000)
        let delta = DeltaCalculator.system(previous: previous, current: current, jankMs: 0, jankBaselineMs: 5)

        XCTAssertEqual(delta.diskReadBytesPerSecond, 200_000_000, accuracy: 1)
        XCTAssertEqual(delta.diskWriteBytesPerSecond, 100_000_000, accuracy: 1)
    }

    func testProcessDiskDeltaSurvivesCounterDrop() {
        let previous = [
            pid_t(42): RawProcess(
                pid: 42, name: "p42", cpuNs: 1_000_000_000,
                diskReadBytes: 1_000_000_000_000, diskWriteBytes: 500_000_000_000,
                footprintBytes: 0
            )
        ]
        let current = [
            RawProcess(
                pid: 42, name: "p42", cpuNs: 1_500_000_000,
                diskReadBytes: 0, diskWriteBytes: 0, footprintBytes: 0
            )
        ]
        let deltas = DeltaCalculator.processes(previous: previous, current: current, wall: 0.9, excluding: 0)

        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas.first?.diskBytesPerSecond, 0)

        var evaluator = StallEvaluator()
        _ = evaluator.evaluate(
            delta: DeltaCalculator.system(
                previous: snapshot(at: 100, read: 0, write: 0),
                current: snapshot(at: 101, read: 0, write: 0),
                jankMs: 0, jankBaselineMs: 5
            ),
            processes: deltas,
            at: Date(timeIntervalSince1970: 101)
        )
    }

    func testImpossibleRateDoesNotTrap() {
        var evaluator = StallEvaluator()
        let delta = SystemDelta(
            wall: 1, cpuBusy: 0.2, cpuCores: 12,
            memoryPressure: 0, compressorBytes: 0, swapUsedBytes: 0,
            swapDeltaBytesPerSecond: 0,
            diskReadBytesPerSecond: .infinity,
            diskWriteBytesPerSecond: 1e20,
            diskBusy: 0, schedulerJankMs: 0, jankBaselineMs: 5, thermal: .nominal
        )
        let process = ProcessDelta(
            pid: 7, name: "p7", attribution: .measured,
            cpuOneCore: 0.5, diskBytesPerSecond: 1e20, footprintBytes: 0
        )
        let assessment = evaluator.evaluate(delta: delta, processes: [process], at: Date())

        XCTAssertEqual(assessment.diskReadBytesPerSecond, 0, "非有限读数按未知处理")
        XCTAssertEqual(assessment.diskWriteBytesPerSecond, UInt64.max)
        XCTAssertEqual(assessment.culprits.first?.diskBytesPerSecond, UInt64.max)
    }
}
