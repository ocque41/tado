import XCTest
@testable import Tado

/// Unit tests for `WatchdogState` — the pure state machine inside
/// `DispatchChainWatchdog`. Covers the three outcomes (running,
/// completed, stalled) and the edge cases that drove the design:
/// lastAdvanceAt updating on progress, totalPhases growing as the
/// architect writes phase files, and the stall trigger only firing
/// at or past the timeout.
final class DispatchChainWatchdogTests: XCTestCase {

    /// Reference epoch used across tests. The actual value doesn't
    /// matter — what matters is that we construct WatchdogTicks with
    /// deterministic Dates relative to the start.
    private let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

    /// A fresh state with no progress yet must report `.running` until
    /// the clock advances past the timeout window. The first tick at
    /// t0 itself is trivially within the window.
    func testStartsRunningWithNoProgress() {
        var state = WatchdogState(startedAt: t0, timeout: 60, totalPhases: 5)
        let outcome = state.consume(tick: WatchdogTick(
            now: t0,
            highestCompletedOrder: 0,
            totalPhases: 5
        ))
        XCTAssertEqual(outcome, .running)
        XCTAssertEqual(state.lastObservedCompleted, 0)
        XCTAssertEqual(state.lastAdvanceAt, t0)
    }

    /// Observing a new completed phase must refresh `lastAdvanceAt` so
    /// a phase that took 19 minutes doesn't trip a 20-minute timeout.
    /// This is the critical invariant for the "steady-progress, just
    /// slow" case.
    func testProgressRefreshesLastAdvanceAt() {
        var state = WatchdogState(startedAt: t0, timeout: 60, totalPhases: 5)

        // 30 seconds in, phase 1 completes. Progress — last advance
        // should snap to now.
        let progressAt = t0.addingTimeInterval(30)
        let outcome = state.consume(tick: WatchdogTick(
            now: progressAt,
            highestCompletedOrder: 1,
            totalPhases: 5
        ))
        XCTAssertEqual(outcome, .running)
        XCTAssertEqual(state.lastObservedCompleted, 1)
        XCTAssertEqual(state.lastAdvanceAt, progressAt)

        // 40 more seconds — we'd trip the 60s timeout relative to t0,
        // but since progress reset the anchor to progressAt, we're
        // actually only 40s since the last advance. Still running.
        let almostExpire = progressAt.addingTimeInterval(40)
        let running = state.consume(tick: WatchdogTick(
            now: almostExpire,
            highestCompletedOrder: 1,
            totalPhases: 5
        ))
        XCTAssertEqual(running, .running)
    }

    /// Once `now - lastAdvanceAt >= timeout` and no progress, the
    /// state machine returns `.stalled(atPhase:)` where the payload
    /// is the order the watchdog believes is stuck — one past the
    /// last completed phase.
    func testStallTriggersAtTimeout() {
        var state = WatchdogState(startedAt: t0, timeout: 60, totalPhases: 5)
        _ = state.consume(tick: WatchdogTick(
            now: t0.addingTimeInterval(20),
            highestCompletedOrder: 3,
            totalPhases: 5
        ))
        // 60 seconds later — now idle, no new progress. Stall at
        // phase 4 (one past the last completed).
        let stallAt = t0.addingTimeInterval(80)
        let outcome = state.consume(tick: WatchdogTick(
            now: stallAt,
            highestCompletedOrder: 3,
            totalPhases: 5
        ))
        XCTAssertEqual(outcome, .stalled(atPhase: 4))
    }

    /// When the observed completion count reaches or exceeds
    /// totalPhases, the state machine returns `.completed` regardless
    /// of the timeout clock. Watchdog should stop cleanly at the end
    /// of a successful chain.
    func testCompletesWhenAllPhasesDone() {
        var state = WatchdogState(startedAt: t0, timeout: 60, totalPhases: 3)
        let outcome = state.consume(tick: WatchdogTick(
            now: t0.addingTimeInterval(10),
            highestCompletedOrder: 3,
            totalPhases: 3
        ))
        XCTAssertEqual(outcome, .completed)
    }

    /// If the architect is still writing phase files when the
    /// watchdog starts, totalPhases observed from the filesystem can
    /// grow. The state machine must track the max — otherwise a plan
    /// that temporarily reports `totalPhases: 1` during writing
    /// would false-trip `.completed` after phase 1 finishes.
    func testTotalPhasesGrowsButNeverShrinks() {
        var state = WatchdogState(startedAt: t0, timeout: 60, totalPhases: 2)

        // Tick sees 5 phases total (architect caught up).
        _ = state.consume(tick: WatchdogTick(
            now: t0,
            highestCompletedOrder: 0,
            totalPhases: 5
        ))
        XCTAssertEqual(state.totalPhases, 5)

        // Phase file got deleted on disk somehow (totalPhases drops
        // to 3). State should cling to the earlier max of 5 — a
        // vanishing phase isn't progress.
        _ = state.consume(tick: WatchdogTick(
            now: t0.addingTimeInterval(10),
            highestCompletedOrder: 0,
            totalPhases: 3
        ))
        XCTAssertEqual(state.totalPhases, 5)
    }

    /// The stall payload is always `lastCompleted + 1`, never the
    /// total. Ensures the UI can point the user at the exact phase
    /// to re-spawn on Resume.
    func testStallPayloadIsNextUncompleted() {
        var state = WatchdogState(startedAt: t0, timeout: 60, totalPhases: 10)
        _ = state.consume(tick: WatchdogTick(
            now: t0.addingTimeInterval(5),
            highestCompletedOrder: 7,
            totalPhases: 10
        ))
        let outcome = state.consume(tick: WatchdogTick(
            now: t0.addingTimeInterval(70),
            highestCompletedOrder: 7,
            totalPhases: 10
        ))
        XCTAssertEqual(outcome, .stalled(atPhase: 8))
    }

    /// Zero-phase plan is a degenerate case (architect wrote plan.json
    /// but no phase files yet). State must stay `.running` — the
    /// "completed" check requires totalPhases > 0, so the watchdog
    /// doesn't short-circuit before the architect finishes writing.
    func testZeroPhasesDoesNotShortCircuitToCompleted() {
        var state = WatchdogState(startedAt: t0, timeout: 60, totalPhases: 0)
        let outcome = state.consume(tick: WatchdogTick(
            now: t0,
            highestCompletedOrder: 0,
            totalPhases: 0
        ))
        XCTAssertEqual(outcome, .running)
    }
}
