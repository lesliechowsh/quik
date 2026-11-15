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

    func testSkillMarkdownDocumentsStandardLocationsAndUninstall() throws {
        let skill = try XCTUnwrap(AgentInstall.skillMarkdown)
        XCTAssertTrue(skill.contains("name: quik"), "frontmatter 原样保留")
        XCTAssertTrue(skill.contains("退出码即状态"))
        XCTAssertTrue(skill.contains("~/.local/bin/quik"), "命令只出现在无用户名的固定位置")
        for location in AgentInstall.skillLocations {
            XCTAssertTrue(skill.contains(location), "技能要写明自己被装在哪：\(location)")
        }
        XCTAssertTrue(skill.contains("卸载"), "技能自描述卸载方式，助手能替用户清理")
        XCTAssertFalse(skill.contains("{{"), "技能是静态内容，不需要占位符")
        XCTAssertFalse(skill.contains("/Users/"), "技能不得携带机器绝对路径")
        XCTAssertFalse(skill.contains(".app"), "技能不得引用应用包内路径")
    }

    func testSkillInstallsIntoStandardDirectories() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("quik-skill-\(UUID().uuidString)")
        XCTAssertTrue(AgentInstall.installSkill(home: home))
        let bundled = try XCTUnwrap(AgentInstall.skillMarkdown)
        for location in AgentInstall.skillLocations {
            let file = home.appendingPathComponent(location).appendingPathComponent("SKILL.md")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), bundled)
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("/Users/"))
        }
        XCTAssertTrue(AgentInstall.skillIsInstalled(home: home))
        XCTAssertTrue(AgentInstall.installSkill(home: home), "重复安装幂等")
        try? FileManager.default.removeItem(at: home)
    }

    func testUninstallRemovesEverythingQuikPlaced() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("quik-uninstall-\(UUID().uuidString)")
        XCTAssertTrue(AgentInstall.installSkill(home: home))
        let cli = home.appendingPathComponent(".local/bin/quik")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        let support = home.appendingPathComponent("Library/Application Support/Quik")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: support.appendingPathComponent("status.json"))

        AgentInstall.uninstall(home: home)
        for location in AgentInstall.skillLocations {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: home.appendingPathComponent(location).path),
                "技能目录要删干净：\(location)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cli.path), "命令行工具要删掉")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path), "状态数据目录要删掉")
        AgentInstall.uninstall(home: home) // 重复卸载幂等，不崩
        try? FileManager.default.removeItem(at: home)
    }

    func testInstallCommandLineCopiesToolIntoHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("quik-install-\(UUID().uuidString)")
        let source = home.appendingPathComponent("fixture-quik")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho quik-fixture\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)

        XCTAssertTrue(AgentInstall.installCommandLine(home: home, source: source))
        let destination = home.appendingPathComponent(".local/bin/quik")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o755)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))

        XCTAssertTrue(AgentInstall.installCommandLine(home: home, source: source), "重复安装幂等")

        XCTAssertFalse(
            AgentInstall.installCommandLine(home: home, source: home.appendingPathComponent("missing")),
            "来源缺失时报失败而不是崩溃"
        )
        try? FileManager.default.removeItem(at: home)
    }
}
