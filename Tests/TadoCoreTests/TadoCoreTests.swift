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
}
