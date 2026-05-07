import Foundation
import os.log
import os.signpost

/// Process-wide signpost log for spawn-path timing.
///
/// **Purpose.** The "first terminal freezes the whole app" symptom
/// has been chased through four code-path theories so far (sync
/// preamble fetch, sync hook install, per-tick FS reads in
/// TimelineView ticks, sync Metal shader compile + device init) —
/// each landed a real fix but the user still reports the freeze.
/// Without on-device timing data we're guessing at architecture
/// without ground truth.
///
/// This helper exposes a small, zero-friction `signpost`-based
/// timer that the user can read in **Console.app** (filter
/// `subsystem:com.tado.spawn`) or in **Instruments → System
/// Trace → Points of Interest** to see exactly which step blocks
/// @MainActor and for how long. Every interval we instrument
/// surfaces as a span in Instruments with a name and a duration —
/// the next freeze report should make the actual hot path
/// visible at a glance.
///
/// **Usage.**
/// ```swift
/// SpawnSignposts.interval("metal.compile") {
///     try MetalPipelineCache.shared.pipeline(device: …)
/// }
/// ```
/// The closure runs synchronously; the helper records start +
/// end signposts around it. Async variants take a `() async ->
/// T` body. Failure rethrows; the end signpost still fires (so a
/// throwing body still bounds its time on the trace).
///
/// **Why os_signpost vs NSLog?** Signposts are O(ns) when no
/// trace is attached — production users pay almost nothing.
/// NSLog goes through the unified logging system but stringifies
/// every call and writes to disk. For per-frame work we want
/// signposts; for one-shot diagnostic prints (where, not how
/// long) the existing NSLog calls are fine.
///
/// **No watchdogs / no auto-retry.** Per CLAUDE.md rule 1, the
/// helper does not time out, does not retry, does not raise an
/// exception on slow paths. It reports.
enum SpawnSignposts {
    /// Subsystem label for filtering in Console.app. Convention:
    /// reverse-DNS so the macOS log subsystem picker groups Tado's
    /// signposts together.
    static let subsystem = "com.tado.spawn"

    /// Shared `OSLog` handle. Initialized lazily so a unit-test
    /// build that never fires a signpost pays nothing.
    static let log = OSLog(subsystem: subsystem, category: "spawn")

    /// Time a synchronous closure under one signpost interval.
    /// Returns the closure's value; rethrows on failure. The end
    /// signpost fires regardless so the trace shows the bounded
    /// span even on throws.
    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try body()
    }

    /// Async variant. Same shape — the end signpost fires on every
    /// exit path, including suspension cancellation and throws.
    @discardableResult
    static func intervalAsync<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try await body()
    }

    /// One-shot signpost event (no duration). Useful for marking
    /// transitions like "session.coreSession set" where the
    /// duration is implicit (from the previous interval's end to
    /// this event).
    static func event(_ name: StaticString, _ message: StaticString = "") {
        os_signpost(.event, log: log, name: name, "%{public}s", String(describing: message))
    }
}
