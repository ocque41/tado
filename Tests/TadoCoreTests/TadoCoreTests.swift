import XCTest
@testable import Tado

/// Exercises the Rust `tado-core` bindings through the `TadoCore.Session`
/// wrapper. These tests spawn a real `/bin/echo` under a PTY and verify the
/// FFI round-trips correctly: spawn → snapshot → write → grid diff.
///
/// Rust-level logic (VT parser, grid math, scroll) is covered by
/// `tado-core/cargo test`. These tests cover only the FFI + Swift bridge.
final class TadoCoreSessionTests: XCTestCase {

    func testSpawnEchoAndSnapshot() throws {
        guard let session = TadoCore.Session(
            command: "/bin/echo",
            args: ["hello world"],
            cwd: nil,
            environment: [:],
            cols: 80,
            rows: 24
        ) else {
            XCTFail("spawn returned nil")
            return
        }

        // Wait up to 2s for the PTY reader to consume `/bin/echo`'s output.
        let deadline = Date().addingTimeInterval(2.0)
        var saw = false
        while Date() < deadline {
            if let snap = session.snapshotFull() {
                let text = String(snap.cells.prefix(80).compactMap {
                    Unicode.Scalar($0.ch).map { Character($0) }
                })
                if text.contains("hello world") {
                    saw = true
                    break
                }
            }
            usleep(50_000)
        }
        XCTAssertTrue(saw, "expected 'hello world' in grid snapshot")
    }

    func testSnapshotDirtyIsIncremental() throws {
        guard let session = TadoCore.Session(
            command: "/bin/sh",
            args: ["-c", "printf 'a\\n'; sleep 0.2; printf 'b\\n'; sleep 0.5"],
            cwd: nil,
            environment: ["PATH": "/usr/bin:/bin"],
            cols: 20,
            rows: 5
        ) else {
            XCTFail("spawn returned nil")
            return
        }

        // Give the first printf a moment, then snapshot.
        usleep(300_000)
        guard let first = session.snapshotDirty() else {
            XCTFail("first snapshot failed")
            return
        }
        XCTAssertGreaterThan(first.dirtyRows.count, 0)

        // Calling again immediately should return few or zero dirty rows
        // because nothing new has been written yet.
        let second = session.snapshotDirty()
        XCTAssertNotNil(second)
        // Not a hard count; just ensures snapshotting is working without
        // returning duplicate dirty rows.
        XCTAssertLessThanOrEqual(second!.dirtyRows.count, first.dirtyRows.count)
    }

    func testScrollbackAccumulatesOnOverflow() throws {
        // Tiny 3-row terminal so a single `seq 10` output overflows and
        // pushes rows into scrollback. Expect total_available >= 5 when
        // settled (exact count depends on shell prompt echo).
        guard let session = TadoCore.Session(
            command: "/bin/sh",
            args: ["-c", "for i in 1 2 3 4 5 6 7 8 9 10; do echo line$i; done"],
            cwd: nil,
            environment: ["PATH": "/usr/bin:/bin"],
            cols: 20,
            rows: 3
        ) else {
            XCTFail("spawn failed")
            return
        }

        // Wait for output + scrollback fill.
        let deadline = Date().addingTimeInterval(2.0)
        var snap: TadoCore.Scrollback?
        while Date() < deadline {
            if let s = session.scrollbackSnapshot(offset: 0, rows: 20),
               s.totalAvailable >= 5 {
                snap = s
                break
            }
            usleep(50_000)
        }
        guard let snap else {
            XCTFail("scrollback never accumulated; got \(session.scrollbackSnapshot(offset: 0, rows: 1)?.totalAvailable ?? 0) lines")
            return
        }
        XCTAssertGreaterThanOrEqual(snap.totalAvailable, 5)
        XCTAssertGreaterThan(snap.cells.count, 0)
        XCTAssertEqual(snap.cells.count, Int(snap.cols) * Int(snap.rows))
    }

    func testSetDefaultColorsAppliesToBlankCells() throws {
        // Spawn a shell that does nothing but sleeps. Immediately push
        // a themed palette via setDefaultColors, then wait for the grid
        // to scroll once (which blanks a row with the new default_bg).
        // Finally snapshot and check that blank cells carry the themed bg.
        guard let session = TadoCore.Session(
            command: "/bin/sh",
            args: ["-c", "sleep 0.6"],
            cwd: nil,
            environment: ["PATH": "/usr/bin:/bin"],
            cols: 10,
            rows: 2
        ) else {
            XCTFail("spawn failed")
            return
        }

        // Theme the tile before it prints anything. New default_bg =
        // 0x11223344. Any blank cell that emerges must carry this value.
        session.setDefaultColors(fg: 0xAABBCCFF, bg: 0x11223344)

        // Poll for the first snapshot and sniff a cell we expect to be
        // unwritten (e.g., the last cell of the last row). The shell
        // doesn't touch it, so it stays at default.
        let deadline = Date().addingTimeInterval(1.0)
        var sawThemedBlank = false
        var lastSeenBg: UInt32 = 0
        var lastSeenCh: UInt32 = 0
        while Date() < deadline {
            if let snap = session.snapshotFull() {
                let lastIdx = Int(snap.cols) * Int(snap.rows) - 1
                if lastIdx < snap.cells.count {
                    lastSeenBg = snap.cells[lastIdx].bg
                    lastSeenCh = snap.cells[lastIdx].ch
                    if snap.cells[lastIdx].bg == 0x11223344 {
                        sawThemedBlank = true
                        break
                    }
                }
            }
            usleep(50_000)
        }
        XCTAssertTrue(sawThemedBlank,
                      "blank cells should carry the themed default_bg 0x11223344 — saw bg=\(String(format: "0x%08X", lastSeenBg)) ch=\(lastSeenCh)")
    }

    func testBracketedPasteAndTitleFFI() throws {
        // Spawn a shell that emits OSC 2 (title) and DECSET 2004
        // (bracketed paste on). Confirm the Swift FFI wrappers reflect
        // each on arrival. Runs in a real PTY to prove the full stack
        // — Rust parser, session events queue, FFI drain, Swift wrapper.
        let script = #"""
            printf '\033]2;my tado test\a'
            printf '\033[?2004h'
            echo ready
            sleep 0.5
        """#
        guard let session = TadoCore.Session(
            command: "/bin/sh",
            args: ["-c", script],
            cwd: nil,
            environment: ["PATH": "/usr/bin:/bin"],
            cols: 40,
            rows: 5
        ) else {
            XCTFail("spawn failed")
            return
        }

        // Wait for `ready` then check flags. The title arrives before
        // the echo, so by the time we see `ready` both should be set.
        let deadline = Date().addingTimeInterval(2.0)
        var sawReady = false
        var capturedTitle: String?
        while Date() < deadline {
            if !sawReady, let snap = session.snapshotFull() {
                let text = String(snap.cells.compactMap {
                    Unicode.Scalar($0.ch).map { Character($0) }
                })
                if text.contains("ready") { sawReady = true }
            }
            if capturedTitle == nil, let title = session.takeTitle() {
                capturedTitle = title
            }
            if sawReady && capturedTitle != nil { break }
            usleep(50_000)
        }

        XCTAssertTrue(sawReady, "shell never printed 'ready'")
        XCTAssertEqual(capturedTitle, "my tado test")
        XCTAssertTrue(session.bracketedPasteEnabled,
                      "DECSET 2004 should leave bracketedPasteEnabled=true")
    }

    func testWriteRoundTrip() throws {
        // `cat` echoes stdin back to stdout. We write a string and expect
        // it to appear in the grid.
        guard let session = TadoCore.Session(
            command: "/bin/cat",
            args: [],
            cwd: nil,
            environment: [:],
            cols: 40,
            rows: 5
        ) else {
            XCTFail("spawn returned nil")
            return
        }

        session.write(text: "ping\r\n")

        let deadline = Date().addingTimeInterval(2.0)
        var saw = false
        while Date() < deadline {
            if let snap = session.snapshotFull() {
                let text = String(snap.cells.compactMap {
                    Unicode.Scalar($0.ch).map { Character($0) }
                })
                if text.contains("ping") {
                    saw = true
                    break
                }
            }
            usleep(50_000)
        }

        session.kill()
        XCTAssertTrue(saw, "expected 'ping' to round-trip through /bin/cat PTY")
    }

    // MARK: - Spawn error surfacing (Packet 0)

    /// Spawning a nonexistent binary must return nil AND populate the
    /// thread-local error so the UI can show a concrete cause. Before
    /// Packet 0 the failure was silent — this test gates regressions of
    /// that contract.
    func testSpawnFailurePopulatesLastError() throws {
        TadoCore.lastSpawnError = nil

        let session = TadoCore.Session(
            command: "/no/such/binary/tado-regression-zzz",
            args: [],
            cwd: nil,
            environment: [:],
            cols: 80,
            rows: 24
        )
        XCTAssertNil(session, "spawn should fail for nonexistent binary")

        let captured = TadoCore.lastSpawnError
        XCTAssertNotNil(captured, "init? must stash the Rust error in TadoCore.lastSpawnError")
        if let captured {
            XCTAssertTrue(
                captured.contains("No such file")
                    || captured.contains("not found")
                    || captured.contains("Session::spawn failed"),
                "expected captured error to describe the spawn failure, got: \(captured)"
            )
        }
    }

    /// Mimic the exact argv/env/cwd shape the Metal tile uses for a
    /// plain todo (no project). If this passes but real-app spawn still
    /// fails, the bug is specific to the `cwd: Some(projectRoot)` path;
    /// if it fails, the error text will be in the XCTest log.
    func testSpawnViaLoginShellZshMirrorsAppPath() throws {
        TadoCore.lastSpawnError = nil

        var envDict = ProcessInfo.processInfo.environment
        // ProcessSpawner.environment prepends the IPC bin dir to PATH
        // when ipcRoot is provided. Mirror with a plausible synthetic
        // prefix so we exercise the exact code path.
        let ipcBin = NSTemporaryDirectory() + "tado-ipc-test-bin"
        envDict["PATH"] = ipcBin + ":" + (envDict["PATH"] ?? "/usr/bin:/bin")

        guard let session = TadoCore.Session(
            command: "/bin/zsh",
            args: ["-l", "-c", "echo hello-metal"],
            cwd: nil,
            environment: envDict,
            cols: 80,
            rows: 24
        ) else {
            let err = TadoCore.lastSpawnError ?? "(no error)"
            XCTFail("Metal-tile-shape spawn returned nil. Last error: \(err)")
            return
        }
        defer { session.kill() }

        let deadline = Date().addingTimeInterval(3.0)
        var saw = false
        while Date() < deadline {
            if let snap = session.snapshotFull() {
                let text = String(snap.cells.compactMap {
                    Unicode.Scalar($0.ch).map { Character($0) }
                })
                if text.contains("hello-metal") {
                    saw = true
                    break
                }
            }
            usleep(50_000)
        }
        XCTAssertTrue(saw, "expected 'hello-metal' to round-trip through /bin/zsh -l -c")
    }

    /// Uses the actual `ProcessSpawner.command` + `ProcessSpawner.environment`
    /// helpers the app calls at spawn time, so any shape drift between the
    /// stubbed mirror test and the real code path is caught.
    func testSpawnUsingRealProcessSpawnerHelpers() throws {
        TadoCore.lastSpawnError = nil

        let tmpIPC = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tado-ipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpIPC, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmpIPC.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmpIPC) }

        let (executable, args) = ProcessSpawner.command(
            for: "echo hello-from-spawner",
            engine: .claude
        )
        // Override: we don't actually want to invoke `claude`, so replace
        // the command string inside args[2] with a harmless echo.
        let patchedArgs = ["-l", "-c", "echo hello-from-spawner"]
        XCTAssertEqual(executable, "/bin/zsh", "ProcessSpawner.command should use zsh -l -c")
        XCTAssertEqual(args.count, 3, "ProcessSpawner.command should produce 3 args")

        let envArray = ProcessSpawner.environment(
            sessionID: UUID(),
            sessionName: "echo hello-from-spawner",
            engine: .claude,
            ipcRoot: tmpIPC,
            projectName: nil,
            projectRoot: nil,
            teamName: nil,
            teamID: nil,
            agentName: nil,
            teamAgents: nil,
            claudeDisplay: .defaults
        )
        var envDict: [String: String] = [:]
        for entry in envArray {
            if let eq = entry.firstIndex(of: "=") {
                let key = String(entry[entry.startIndex..<eq])
                let value = String(entry[entry.index(after: eq)...])
                envDict[key] = value
            }
        }

        guard let session = TadoCore.Session(
            command: executable,
            args: patchedArgs,
            cwd: nil,
            environment: envDict,
            cols: 80,
            rows: 24
        ) else {
            let err = TadoCore.lastSpawnError ?? "(no error)"
            XCTFail("Real-spawner-shape spawn returned nil. Last error: \(err)")
            return
        }
        defer { session.kill() }

        let deadline = Date().addingTimeInterval(3.0)
        var saw = false
        while Date() < deadline {
            if let snap = session.snapshotFull() {
                let text = String(snap.cells.compactMap {
                    Unicode.Scalar($0.ch).map { Character($0) }
                })
                if text.contains("hello-from-spawner") {
                    saw = true
                    break
                }
            }
            usleep(50_000)
        }
        XCTAssertTrue(saw, "expected 'hello-from-spawner' to land in the grid")
    }

    /// A successful spawn must clear any prior error so a stale message
    /// doesn't leak into the UI on the next tile.
    func testSuccessfulSpawnClearsLastError() throws {
        TadoCore.lastSpawnError = "stale from a prior test"

        guard let session = TadoCore.Session(
            command: "/bin/echo",
            args: ["ok"],
            cwd: nil,
            environment: [:],
            cols: 40,
            rows: 4
        ) else {
            XCTFail("spawn returned nil for /bin/echo")
            return
        }
        defer { session.kill() }

        XCTAssertNil(
            TadoCore.lastSpawnError,
            "successful Session.init? must clear TadoCore.lastSpawnError"
        )
    }
}
