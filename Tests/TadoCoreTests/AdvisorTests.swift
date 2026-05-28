import XCTest
@testable import Tado

final class AdvisorTests: XCTestCase {
    func testAdvisorDefaultsAreOffAndInitializeFromCurrentProfile() {
        let settings = AppSettings()
        XCTAssertFalse(settings.advisorEnabled)

        settings.engine = .codex
        settings.codexMode = .fullAccess
        settings.codexModel = .gpt54Mini
        settings.codexEffort = .xhigh

        settings.initializeAdvisorDefaultsIfNeeded()

        XCTAssertTrue(settings.advisorDefaultsInitialized)
        XCTAssertEqual(settings.advisorExecutionerEngine, .codex)
        XCTAssertEqual(settings.advisorExecutionerCodexMode, .fullAccess)
        XCTAssertEqual(settings.advisorExecutionerCodexModel, .gpt54Mini)
        XCTAssertEqual(settings.advisorExecutionerCodexEffort, .xhigh)
        XCTAssertEqual(settings.advisorAdvisorEngine, .claude)
        XCTAssertEqual(settings.advisorAdvisorClaudeModel, .opus47)
        XCTAssertEqual(settings.advisorAdvisorClaudeEffort, .high)
    }

    func testAdvisorGlobalSettingsCodableShape() throws {
        var settings = GlobalSettings()
        settings.engine.advisor.enabled = true
        settings.engine.advisor.executioner.engine = "codex"
        settings.engine.advisor.executioner.codex.model = "gpt-5.4-mini"
        settings.engine.advisor.advisor.claude.model = "claude-opus-4-7"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        XCTAssertTrue(decoded.engine.advisor.enabled)
        XCTAssertEqual(decoded.engine.advisor.executioner.engine, "codex")
        XCTAssertEqual(decoded.engine.advisor.executioner.codex.model, "gpt-5.4-mini")
        XCTAssertEqual(decoded.engine.advisor.advisor.claude.model, "claude-opus-4-7")
    }

    func testAdvisorGlobalSettingsDecodeOlderJsonWithoutAdvisorBlock() throws {
        let json = """
        {
          "schemaVersion": 1,
          "writer": "test",
          "updatedAt": "2026-05-21T00:00:00Z",
          "engine": {
            "default": "codex",
            "codex": { "mode": "fullAccess", "model": "gpt-5.4-mini" }
          }
        }
        """.data(using: .utf8)!

        let decoded = try AtomicStore.jsonDecoder.decode(GlobalSettings.self, from: json)

        XCTAssertEqual(decoded.engine.default, "codex")
        XCTAssertEqual(decoded.engine.codex.mode, "fullAccess")
        XCTAssertEqual(decoded.engine.codex.model, "gpt-5.4-mini")
        XCTAssertFalse(decoded.engine.advisor.enabled)
        XCTAssertEqual(decoded.engine.advisor.executioner.engine, "claude")
        XCTAssertEqual(decoded.engine.advisor.advisor.claude.model, "claude-opus-4-7")
    }

    func testAdvisorRoleFlagGeneration() {
        let settings = AppSettings()
        settings.advisorExecutionerEngine = .codex
        settings.advisorExecutionerCodexMode = .fullAccess
        settings.advisorExecutionerCodexModel = .gpt55
        settings.advisorExecutionerCodexEffort = .high
        settings.advisorAdvisorEngine = .claude
        settings.advisorAdvisorClaudeModel = .opus47
        settings.advisorAdvisorClaudeEffort = .high

        XCTAssertEqual(
            settings.advisorModelFlags(for: .executioner),
            ["-c", "model=\"gpt-5.5\""]
        )
        XCTAssertEqual(
            settings.advisorEffortFlags(for: .executioner),
            ["-c", "model_reasoning_effort=\"high\""]
        )
        XCTAssertTrue(settings.advisorModeFlags(for: .executioner).contains("--no-alt-screen"))
        XCTAssertEqual(
            settings.advisorModelFlags(for: .advisor),
            ["--model", "claude-opus-4-7"]
        )
        XCTAssertEqual(
            settings.advisorEffortFlags(for: .advisor),
            ["--effort", "high"]
        )
    }

    func testAdvisorPromptsContainWorkflowRules() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let executioner = AdvisorPrompts.executionerPrompt(task: "Ship auth")
        let advisor = AdvisorPrompts.advisorPrompt(
            task: "Ship auth",
            executionerSessionID: id,
            executionerGridLabel: "[1, 2]"
        )

        XCTAssertTrue(executioner.contains("Do not plan the whole task."))
        XCTAssertTrue(executioner.contains("Reply with: READY"))
        XCTAssertTrue(advisor.contains(id.uuidString.lowercased()))
        XCTAssertTrue(advisor.contains("[1, 2]"))
        XCTAssertTrue(advisor.contains("Prefer messages under 240 characters."))
        XCTAssertTrue(advisor.contains("Do not edit files"))
    }

    func testAdvisorRelayCompactionCapsTail() {
        let text = (0..<120)
            .map { "line-\($0)" }
            .joined(separator: "\n")

        let compact = AdvisorRelay.compactTail(text, maxChars: 120, maxLines: 5)

        XCTAssertTrue(compact.contains("[clipped earlier lines]"))
        XCTAssertTrue(compact.contains("line-119"))
        XCTAssertFalse(compact.contains("line-0\n"))

        let clipped = AdvisorRelay.compactTail(String(repeating: "x", count: 200), maxChars: 20, maxLines: 80)
        XCTAssertTrue(clipped.hasPrefix("[clipped earlier output]\n"))
        XCTAssertLessThanOrEqual(clipped.count, "[clipped earlier output]\n".count + 20)
    }
}
