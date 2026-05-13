import XCTest
@testable import Tado

final class TodoCommandDetectorTests: XCTestCase {
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

    func testPetSlashCommandsArePlainPrompts() {
        XCTAssertEqual(TodoCommand.detect("/pet"), .standardPrompt("/pet"))
        XCTAssertEqual(TodoCommand.detect("  /PET  "), .standardPrompt("/PET"))
        XCTAssertEqual(TodoCommand.detect("/hatch"), .standardPrompt("/hatch"))
        XCTAssertEqual(
            TodoCommand.detect("  /hatch  pixel sprite "),
            .standardPrompt("/hatch  pixel sprite")
        )
    }
}
