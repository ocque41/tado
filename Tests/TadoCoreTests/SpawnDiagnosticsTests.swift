import XCTest
@testable import Tado

final class SpawnDiagnosticsTests: XCTestCase {
    func testSpawnTracePersistsSummaryAndRedactsShellCommand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tado-spawn-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("spawn-traces.ndjson")
        let store = SpawnDiagnosticsStore(logURL: logURL)

        let traceID = UUID()
        let sessionID = UUID()
        let todoID = UUID()
        let summary = SpawnDiagnosticsStore.commandSummary(
            executable: "/bin/zsh",
            args: ["-l", "-c", "claude --model opus 'very secret prompt text'"]
        )

        store.startTrace(
            traceID: traceID,
            sessionID: sessionID,
            todoID: todoID,
            engine: "claude",
            title: "test spawn",
            projectName: "Tado",
            projectRoot: "/tmp/tado"
        )
        store.beginPhase(traceID: traceID, phase: "command.build")
        store.endPhase(
            traceID: traceID,
            phase: "command.build",
            commandSummary: summary
        )
        store.finishTrace(
            traceID: traceID,
            outcome: .failure,
            message: "boom",
            commandSummary: summary
        )
        store.drainForTests()

        let recent = store.recentSummariesSnapshotForTests()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].traceID, traceID)
        XCTAssertEqual(recent[0].outcome, .failure)
        XCTAssertEqual(recent[0].error, "boom")
        XCTAssertEqual(recent[0].commandSummary, "zsh -l -c <claude command redacted>")

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("traceFinished"))
        XCTAssertFalse(log.contains("very secret prompt text"))
    }

    func testEngineAwareSanitizerKeepsFlagsWhenCapabilityCacheIsCold() {
        let caps = CLICapabilities.shared
        caps.invalidate()
        defer {
            caps.invalidate()
            caps.resetHelpRunnerForTesting()
        }

        let flags = ["--effort", "xhigh", "--model", "opus"]
        let sanitized = ProcessSpawner.sanitizeFlags(
            flags,
            engine: .claude,
            startProbeIfMissing: false
        )
        XCTAssertEqual(sanitized, flags)
    }

    func testEngineAwareSanitizerDropsOnlyCachedInvalidValues() {
        let caps = CLICapabilities.shared
        caps.invalidate()
        defer {
            caps.invalidate()
            caps.resetHelpRunnerForTesting()
        }
        caps.setValidValuesForTesting(
            engine: .claude,
            flag: "--effort",
            values: ["low", "medium", "high"]
        )

        let sanitized = ProcessSpawner.sanitizeFlags(
            ["--effort", "xhigh", "--model", "opus"],
            engine: .claude,
            startProbeIfMissing: false
        )
        XCTAssertEqual(sanitized, ["--model", "opus"])
    }

    func testCapabilityProbeDoesNotBlockSanitizer() {
        let caps = CLICapabilities.shared
        caps.invalidate()
        let runnerEntered = expectation(description: "background help runner entered")
        let releaseRunner = DispatchSemaphore(value: 0)
        caps.setHelpRunnerForTesting { _ in
            runnerEntered.fulfill()
            releaseRunner.wait()
            return ""
        }
        defer {
            releaseRunner.signal()
            caps.invalidate()
            caps.resetHelpRunnerForTesting()
        }

        let started = Date()
        let sanitized = ProcessSpawner.sanitizeFlags(
            ["--effort", "high"],
            engine: .claude
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(sanitized, ["--effort", "high"])
        XCTAssertLessThan(elapsed, 0.25)
        wait(for: [runnerEntered], timeout: 1.0)
    }
}
