import XCTest
@testable import Tado

final class StorageAndModelTests: XCTestCase {
    func testCodexModelDefaultsAndNormalization() {
        let settings = AppSettings()
        XCTAssertEqual(settings.codexModel, .gpt55)
        XCTAssertEqual(settings.codexModel.cliFlags, ["-c", "model=\"gpt-5.5\""])
        XCTAssertEqual(CodexModel.normalizedRawValue("gpt-5.1-codex-max"), "gpt-5.5")
        XCTAssertEqual(CodexModel.normalizedRawValue("gpt52Codex"), "gpt-5.5")
        XCTAssertEqual(CodexModel.normalizedRawValue("gpt54"), "gpt-5.4")
    }

    func testClaudeModelNormalizationUsesRealIDs() {
        XCTAssertEqual(ClaudeModel.normalizedRawValue("opus47"), "claude-opus-4-7")
        XCTAssertEqual(ClaudeModel.normalizedRawValue("sonnet46"), "claude-sonnet-4-6")
        XCTAssertEqual(ClaudeModel.normalizedRawValue("opus[1m]"), "opus[1m]")
    }

    func testStorePathsUseLocatorActiveRoot() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tado-storage-test-\(UUID().uuidString)", isDirectory: true)
        let defaultRoot = temp.appendingPathComponent("DefaultTado", isDirectory: true)
        let customRoot = temp.appendingPathComponent("CustomTado", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        defer {
            unsetenv("TADO_STORAGE_DEFAULT_ROOT")
            try? FileManager.default.removeItem(at: temp)
        }
        setenv("TADO_STORAGE_DEFAULT_ROOT", defaultRoot.path, 1)

        let record = StorageLocationRecord(
            activeRoot: customRoot.path,
            pendingRoot: nil,
            lastMoveError: nil
        )
        try AtomicStore.encode(record, to: StorageLocationManager.locatorFile)

        XCTAssertEqual(StorePaths.root.path, customRoot.path)
        XCTAssertEqual(StorePaths.globalSettingsFile.path, customRoot.appendingPathComponent("settings/global.json").path)
    }

    func testScheduleMoveWritesPendingRoot() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tado-storage-test-\(UUID().uuidString)", isDirectory: true)
        let defaultRoot = temp.appendingPathComponent("DefaultTado", isDirectory: true)
        let targetRoot = temp.appendingPathComponent("TargetTado", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        defer {
            unsetenv("TADO_STORAGE_DEFAULT_ROOT")
            try? FileManager.default.removeItem(at: temp)
        }
        setenv("TADO_STORAGE_DEFAULT_ROOT", defaultRoot.path, 1)

        try StorageLocationManager.scheduleMove(to: targetRoot)
        let record = StorageLocationManager.readRecord()
        XCTAssertEqual(record.pendingRoot, targetRoot.path)
        XCTAssertNil(record.lastMoveError)
    }
}
