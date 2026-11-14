import XCTest
@testable import Quik

final class StatusSnapshotTests: XCTestCase {
    private func fixtureAssessment(at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> StallAssessment {
        StallAssessment(
            at: date,
            score: 55,
            level: .sluggish,
            stableCause: .cpu,
            causes: [
                CauseEvidence(kind: .cpu, contribution: 52, headline: "CPU 忙", detail: "12 核用掉 9 核"),
                CauseEvidence(kind: .disk, contribution: 18, headline: "磁盘忙", detail: "写入 120 MB/s")
            ],
            culprits: [
                Culprit(
                    pid: 4321, name: "Chrome Helper (Renderer)", attribution: .measured,
                    cpuOneCore: 1.234, diskBytesPerSecond: 3_145_728,
                    footprintBytes: 512 * 1_048_576, score: 64, reason: "CPU 1.2 核",
                    app: AppIdentity(name: "Chrome", bundlePath: "/Applications/Chrome.app", role: "页面渲染")
                )
            ],
            cpuBusy: 0.9, cpuCores: 12, memoryPressure: 2,
            compressorBytes: 0, swapUsedBytes: 0,
            diskReadBytesPerSecond: 10_485_760, diskWriteBytesPerSecond: 3_145_728,
            schedulerJankMs: 3.46, thermal: .fair, measuredCPUShare: 0.8
        )
    }

    func testSnapshotCarriesTheAgentContract() throws {
        let snapshot = StatusSnapshot(assessment: fixtureAssessment(), appVersion: "9.9.9")
        let data = try XCTUnwrap(snapshot.encode())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\"schema\" : 1"))
        XCTAssertTrue(text.contains("\"level\" : \"sluggish\""))
        XCTAssertTrue(text.contains("\"memoryPressure\" : \"warning\""))
        XCTAssertTrue(text.contains("\"thermal\" : \"fair\""))
        XCTAssertTrue(text.contains("\"role\" : \"页面渲染\""))

        let decoded = try XCTUnwrap(StatusSnapshot.decode(data))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.culprits.first?.name, "Chrome")
        XCTAssertEqual(decoded.culprits.first?.cpuCores, 1.23)
        XCTAssertEqual(decoded.culprits.first?.diskMBps, 3.0)
        XCTAssertEqual(decoded.culprits.first?.memoryMB, 512)
        XCTAssertEqual(decoded.diskReadMBps, 10.0)
        XCTAssertEqual(decoded.diskWriteMBps, 3.0)
        XCTAssertEqual(decoded.schedulerJankMs, 3.5)
        XCTAssertEqual(decoded.cpuBusyPercent, 90)
    }

    func testStaleness() {
        let snapshot = StatusSnapshot(assessment: fixtureAssessment(), appVersion: "0")
        let at = fixtureAssessment().at
        XCTAssertFalse(snapshot.isStale(now: at + 4))
        XCTAssertTrue(snapshot.isStale(now: at + 6))
    }

    func testFluidSummaryComesFromOnePlace() {
        let snapshot = StatusSnapshot(assessment: .idle(), appVersion: "0")
        XCTAssertEqual(snapshot.summary, "现在用起来是流畅的，不需要做什么。")
        XCTAssertEqual(snapshot.level, "fluid")
        XCTAssertEqual(snapshot.levelLabel, "流畅")
    }

    func testStatusFileRoundTrip() throws {
        let url = StatusFile.url
        try? FileManager.default.removeItem(at: url)
        XCTAssertNil(StatusFile.read())

        let snapshot = StatusSnapshot(assessment: fixtureAssessment(), appVersion: "1.2.3")
        StatusFile.write(snapshot)
        XCTAssertEqual(StatusFile.read(), snapshot)
        try? FileManager.default.removeItem(at: url)
    }

    func testAgentPromptCarriesSkillAndPaths() throws {
        let prompt = try XCTUnwrap(AgentInstall.prompt())
        XCTAssertTrue(prompt.contains("name: quik"), "frontmatter 原样保留")
        XCTAssertTrue(prompt.contains("~/.claude/skills/quik/SKILL.md"))
        XCTAssertTrue(prompt.contains(AgentInstall.cliPath))
        XCTAssertTrue(prompt.contains("退出码即状态"), "技能正文完整带进提示词")
        XCTAssertFalse(prompt.contains("{{QUIK_CLI}}"), "占位符已替换")
    }
}
