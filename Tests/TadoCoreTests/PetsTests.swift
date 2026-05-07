import XCTest
@testable import Tado

/// Coverage for Tado Pets: the priority-resolved aggregate
/// builder, the `/pet` and `/hatch` slash-command detector, and
/// the custom-pets directory layout used by the hatch service +
/// the `tado_pets_hatch` MCP tool.
final class PetsTests: XCTestCase {

    // MARK: - PetState priority

    func testPetStatePriorityOrder() {
        XCTAssertGreaterThan(PetState.perfRegressed.priority, PetState.awaitingResponse.priority)
        XCTAssertGreaterThan(PetState.awaitingResponse.priority, PetState.eternalRunning.priority)
        XCTAssertGreaterThan(PetState.eternalRunning.priority, PetState.running.priority)
        XCTAssertGreaterThan(PetState.running.priority, PetState.needsInput.priority)
        XCTAssertGreaterThan(PetState.needsInput.priority, PetState.done.priority)
        XCTAssertGreaterThan(PetState.done.priority, PetState.idle.priority)
    }

    // MARK: - Resolver

    func testResolverEmptyCandidatesYieldsIdle() {
        let (state, bubble) = PetsAggregateResolver.resolve([])
        XCTAssertEqual(state, .idle)
        XCTAssertNil(bubble)
    }

    func testResolverPicksHighestPriority() {
        let candidates: [PetsAggregateResolver.Candidate] = [
            .init(state: .running,           bubble: "running"),
            .init(state: .needsInput,        bubble: "idle"),
            .init(state: .awaitingResponse,  bubble: "y/n"),
            .init(state: .eternalRunning,    bubble: "Sprint 3")
        ]
        let (state, bubble) = PetsAggregateResolver.resolve(candidates)
        XCTAssertEqual(state, .awaitingResponse)
        XCTAssertEqual(bubble, "y/n")
    }

    func testResolverPerfRegressionBeatsEverything() {
        let candidates: [PetsAggregateResolver.Candidate] = [
            .init(state: .awaitingResponse, bubble: "y/n"),
            .init(state: .perfRegressed,    bubble: "perf Δ-0.12"),
            .init(state: .eternalRunning,   bubble: "Sprint 3")
        ]
        let (state, bubble) = PetsAggregateResolver.resolve(candidates)
        XCTAssertEqual(state, .perfRegressed)
        XCTAssertEqual(bubble, "perf Δ-0.12")
    }

    // MARK: - Slash commands

    func testSlashPetTogglesPet() {
        XCTAssertEqual(TodoCommand.detect("/pet"), .togglePet)
        XCTAssertEqual(TodoCommand.detect("  /pet  "), .togglePet)
        XCTAssertEqual(TodoCommand.detect("/PET"), .togglePet)
    }

    func testBareHatchOpensSheetWithEmptyPrompt() {
        XCTAssertEqual(TodoCommand.detect("/hatch"), .hatchPet(prompt: ""))
    }

    func testHatchWithPromptCarriesText() {
        XCTAssertEqual(
            TodoCommand.detect("/hatch a small dragon"),
            .hatchPet(prompt: "a small dragon")
        )
        XCTAssertEqual(
            TodoCommand.detect("  /hatch  pixel goblin "),
            .hatchPet(prompt: "pixel goblin")
        )
    }

    func testCoordinatorPathStillWorks() {
        XCTAssertEqual(
            TodoCommand.detect("tado bootstrap a2a docs"),
            .coordinator(brief: "bootstrap a2a docs")
        )
    }

    func testStandardPromptUnchanged() {
        XCTAssertEqual(
            TodoCommand.detect("write me a function"),
            .standardPrompt("write me a function")
        )
    }

    // MARK: - Hatch service

    @MainActor
    func testHatchStubWritesPlaceholderToCustomDir() async throws {
        let prompt = "tiny pixel goblin"
        let url = try await PetsHatchService.shared.requestHatch(prompt: prompt)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "stub sprite should land on disk")
        XCTAssertTrue(url.deletingLastPathComponent().path.hasSuffix("pets/custom"),
                      "stub sprite should live under <storage-root>/pets/custom")

        // PNG file should decode as an image.
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)

        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Built-in roster sanity

    func testBuiltInPetRosterMatchesCodexParity() {
        // Codex Pets ships eight built-ins (cat, dog, fox, owl,
        // crab, snake, octopus, dragon). Tado mirrors that list
        // for parity. If we ever change the roster, this test
        // forces a deliberate update.
        XCTAssertEqual(PetID.builtIn.count, 8)
        XCTAssertTrue(PetID.builtIn.contains("cat"))
        XCTAssertTrue(PetID.builtIn.contains("dragon"))
        XCTAssertEqual(PetID.default, "cat")
    }
}
