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

    /// Per-spawn category — used for tile-mount + PTY-spawn
    /// intervals. Boot signpost names route through `bootLog` via
    /// `log(for:)` so Console.app's `category:boot` filter can
    /// isolate startup timing from per-spawn timing without losing
    /// the shared subsystem grouping.
    static let log = OSLog(subsystem: subsystem, category: "spawn")

    /// Boot-phase category. Names starting with `boot.` route here
    /// automatically. Filter `subsystem:com.tado.spawn category:boot`
    /// in Console.app to see only the startup pipeline; the
    /// `category:spawn` filter shows only per-tile work.
    static let bootLog = OSLog(subsystem: subsystem, category: "boot")

    /// Pick the right `OSLog` for a given signpost name. `boot.*`
    /// names go to `bootLog`; everything else stays on the
    /// per-spawn category. `@inline(__always)` so signposts named
    /// at compile-time (every call site is a `StaticString`) inline
    /// to a single load on Apple Silicon.
    @inline(__always)
    private static func selectLog(for name: StaticString) -> OSLog {
        // `StaticString` doesn't expose a `hasPrefix` of its own;
        // round-trip through `String` for the lookup. Cheap when the
        // signpost itself is firing (the trace cost dominates), and
        // a no-op when no trace is attached because `os_signpost`
        // short-circuits on the first arg.
        return "\(name)".hasPrefix("boot.") ? bootLog : log
    }

    /// Time a synchronous closure under one signpost interval.
    /// Returns the closure's value; rethrows on failure. The end
    /// signpost fires regardless so the trace shows the bounded
    /// span even on throws.
    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let osLog = selectLog(for: name)
        let id = OSSignpostID(log: osLog)
        os_signpost(.begin, log: osLog, name: name, signpostID: id)
        defer { os_signpost(.end, log: osLog, name: name, signpostID: id) }
        return try body()
    }

    /// Async variant. Same shape — the end signpost fires on every
    /// exit path, including suspension cancellation and throws.
    @discardableResult
    static func intervalAsync<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let osLog = selectLog(for: name)
        let id = OSSignpostID(log: osLog)
        os_signpost(.begin, log: osLog, name: name, signpostID: id)
        defer { os_signpost(.end, log: osLog, name: name, signpostID: id) }
        return try await body()
    }

    /// One-shot signpost event (no duration). Useful for marking
    /// transitions like "session.coreSession set" where the
    /// duration is implicit (from the previous interval's end to
    /// this event). Allocation-free at the call site — `os_signpost`'s
    /// no-format-string variant skips the per-event message
    /// serialization the previous helper unconditionally paid.
    static func event(_ name: StaticString) {
        os_signpost(.event, log: selectLog(for: name), name: name)
    }

    /// Variant with an attached `StaticString` message. Use sparingly:
    /// every firing serializes the message into the trace buffer
    /// even when no trace is attached, which is exactly the cost
    /// the parameter-less `event(_:)` exists to avoid. Restricted
    /// to `StaticString` so the message can't be a per-call format.
    static func event(_ name: StaticString, message: StaticString) {
        os_signpost(.event, log: selectLog(for: name), name: name, "%{public}s", "\(message)")
    }
}
