import XCTest
@testable import Tado

/// Verifies the v0.19.0 Performance step's data-model additions are
/// backward-compatible with pre-v0.19 EternalRun records and that
/// EternalState's tolerant decoder accepts both old and new state.json
/// shapes.
final class EternalPerfModelTests: XCTestCase {

    // MARK: - EternalState backward compatibility

    func testStateJsonWithoutPerfFieldsDecodesWithDefaults() throws {
        // Pre-v0.19 state.json — no perf fields. Must decode and
        // surface zero/nil for the new perf fields so the dashboard
        // doesn't blow up on existing on-disk runs.
        let pre019 = #"""
        {
          "mode": "sprint",
          "startedAt": 1714600000,
          "lastActivityAt": 1714600100,
          "iterations": 5,
          "sprints": 1,
          "compactions": 0,
          "phase": "working",
          "lastProgressNote": "did some work",
          "lastMetric": 0.42,
          "completionMarker": "ETERNAL-DONE",
          "sprintMarker": "[SPRINT-DONE]"
        }
        """#
        let state = try JSONDecoder().decode(EternalState.self, from: pre019.data(using: .utf8)!)
        XCTAssertEqual(state.mode, "sprint")
        XCTAssertEqual(state.iterations, 5)
        XCTAssertEqual(state.sprints, 1)
        XCTAssertEqual(state.perfCycles, 0, "perfCycles must default to 0 for pre-v0.19 state.json")
        XCTAssertNil(state.lastPerfScore, "lastPerfScore must default to nil")
        XCTAssertNil(state.perfRegressionDelta, "perfRegressionDelta must default to nil")
        XCTAssertNil(state.lastPerfReportPath, "lastPerfReportPath must default to nil")
    }

    func testStateJsonWithPerfFieldsDecodesAllValues() throws {
        let v019 = #"""
        {
          "mode": "sprint",
          "startedAt": 1714600000,
          "lastActivityAt": 1714600100,
          "iterations": 5,
          "sprints": 1,
          "compactions": 0,
          "phase": "perfRegressed",
          "lastProgressNote": "regressed alloc",
          "lastMetric": 0.42,
          "completionMarker": "ETERNAL-DONE",
          "sprintMarker": "[SPRINT-DONE]",
          "perfCycles": 3,
          "lastPerfScore": 0.728,
          "perfRegressionDelta": 0.272,
          "lastPerfReportPath": "/tmp/perf-report.json"
        }
        """#
        let state = try JSONDecoder().decode(EternalState.self, from: v019.data(using: .utf8)!)
        XCTAssertEqual(state.perfCycles, 3)
        XCTAssertEqual(state.lastPerfScore ?? 0, 0.728, accuracy: 0.0001)
        XCTAssertEqual(state.perfRegressionDelta ?? 0, 0.272, accuracy: 0.0001)
        XCTAssertEqual(state.lastPerfReportPath, "/tmp/perf-report.json")
        XCTAssertEqual(state.phase, "perfRegressed")
    }

    func testPhaseKindIncludesPerfStates() {
        // The dashboard pill colour-shifts based on these enum cases.
        XCTAssertEqual(EternalState.PhaseKind(rawValue: "perfPending"), .perfPending)
        XCTAssertEqual(EternalState.PhaseKind(rawValue: "perfRegressed"), .perfRegressed)
        XCTAssertEqual(EternalState.PhaseKind(rawValue: "working"), .working)
        XCTAssertEqual(EternalState.PhaseKind(rawValue: "completed"), .completed)
    }

    func testEternalRunDefaultsKindToGeneral() {
        let run = EternalRun(
            project: nil,
            label: "Test",
            mode: "sprint"
        )
        XCTAssertEqual(run.kind, "general", "EternalRun.kind must default to 'general' for backward-compat")
    }

    func testEternalRunPersistsPerfKind() {
        let run = EternalRun(
            project: nil,
            label: "Perf test",
            mode: "sprint",
            kind: "perf"
        )
        XCTAssertEqual(run.kind, "perf")
    }

    // MARK: - Metric sample components decoder accepts perf shape

    func testMetricSampleAcceptsPerfComposite() throws {
        // Sprint-mode metrics.jsonl line as the perf-mode worker
        // would emit it: composite as `metric`, per-component scores
        // under `components`.
        let line = #"""
        {"sprint": 1, "timestamp": "2026-05-03T10:00:00Z", "metric": 1.05,
         "components": {"algo_complexity": 1.0, "alloc_per_op": 0.95,
                        "critical_path_ops": 1.1}}
        """#
        let sample = try JSONDecoder().decode(EternalMetricSample.self, from: line.data(using: .utf8)!)
        XCTAssertEqual(sample.sprint, 1)
        XCTAssertEqual(sample.metric.numberValue ?? 0, 1.05, accuracy: 0.0001)
        XCTAssertEqual(sample.components?.count ?? 0, 3)
        XCTAssertEqual(sample.components?["alloc_per_op"] ?? 0, 0.95, accuracy: 0.0001)
    }

    func testMetricSampleAcceptsLegacyShapeWithoutComponents() throws {
        let legacy = #"{"sprint": 1, "timestamp": "2026-05-03T10:00:00Z", "metric": 0.42, "note": "ok"}"#
        let sample = try JSONDecoder().decode(EternalMetricSample.self, from: legacy.data(using: .utf8)!)
        XCTAssertEqual(sample.sprint, 1)
        XCTAssertNil(sample.components, "Legacy shape (no components) must still decode")
    }
}
