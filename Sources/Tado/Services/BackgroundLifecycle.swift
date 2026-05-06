import Foundation
import AppKit
import CTadoCore

/// Tado's macOS background-lifecycle hub.
///
/// Tado runs a tokio bt-core daemon in-process, spawns long-lived
/// `claude` / `codex` PTY children, and watches files via DispatchSource —
/// all of which are vulnerable to silent damage when macOS sleeps the
/// laptop, throttles the app under App Nap, or kills child processes
/// under memory pressure during a long idle.
///
/// Without explicit lifecycle handling the user sees this as a "reset":
/// tiles freeze, Dome features stop responding, the sidebar appears
/// empty after a wake. This file is the single coordination point that
/// quiesces state on `willSleep` and reconciles every subsystem on
/// `didWake`.
///
/// What it does, in order:
///
/// 1. **App Nap suppression** — the moment Tado has at least one active
///    session, it holds an `NSActivity` so macOS doesn't throttle the
///    process when the window is hidden. Released when the last session
///    completes.
/// 2. **Pre-sleep checkpoint** — on `NSWorkspace.willSleepNotification`
///    we ask bt-core to flush its WAL via `tado_dome_stop`'s checkpoint
///    path, mirroring the v0.16.1 termination hook. The next mutation
///    re-arms the WAL automatically; sleep is treated like a soft quit
///    boundary so a forced shutdown after sleep never strands committed
///    pages in the WAL file.
/// 3. **Post-wake reconciliation** — on `didWakeNotification` we
///    sequentially:
///      - probe bt-core via `system_health` and emit a recovery event +
///        sound if the daemon is unresponsive (a follow-up restart
///        primitive ships when bt-core exposes one);
///      - walk every `TerminalSession` and reconcile `isRunning` against
///        the Rust `TadoCore.Session.isRunning` truth — any tile whose
///        child died during sleep transitions to `.failed` so the UI
///        shows it instead of the frozen pre-sleep grid forever.
/// 4. **Stale IPC dir cleanup** — exposed as a static helper so
///    `IPCBroker.init` can prune `/tmp/tado-ipc-<dead-pid>` directories
///    left behind by prior crashed launches before re-creating its own.
///
/// Everything is best-effort and audit-logged through `EventBus`. None
/// of these handlers retry, watchdog, or auto-restart in a loop —
/// per Rule 1 of `CLAUDE.md`. They surface state honestly and let the
/// operator decide.
@MainActor
final class BackgroundLifecycle {
    static let shared = BackgroundLifecycle()

    private weak var terminalManager: TerminalManager?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var installed = false

    private init() {}

    /// Wire every lifecycle observer. Idempotent — safe to call from
    /// `TadoApp.init` even though SwiftUI may re-evaluate `init` under
    /// scene rebuilds. `terminalManager` is held weakly so this never
    /// keeps the manager alive past app teardown.
    func install(terminalManager: TerminalManager) {
        guard !installed else { return }
        installed = true
        self.terminalManager = terminalManager

        let ws = NSWorkspace.shared.notificationCenter

        observers.append(
            ws.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWillSleep()
                }
            }
        )

        observers.append(
            ws.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDidWake()
                }
            }
        )

        // App Nap suppression — start an activity assertion as soon as
        // Tado launches and never release it while the app is alive.
        // The cost is tiny (App Nap mostly benefits idle background apps
        // that aren't doing useful work) and the upside is large: the
        // tokio runtime, the PTY parent threads, and the file watchers
        // all keep their normal scheduling priority even when the user
        // hides the window for hours. Without this, App Nap can drop
        // tile activity detection to a tick every few minutes.
        let opts: ProcessInfo.ActivityOptions = [
            .userInitiated,
            .userInitiatedAllowingIdleSystemSleep,
            .latencyCritical
        ]
        activity = ProcessInfo.processInfo.beginActivity(
            options: opts,
            reason: "Tado is running long-lived agent terminal sessions"
        )

        // Sudden + automatic termination opt-out. Without these, macOS
        // is allowed to kill the suspended Tado process at any time
        // during sleep / extended idle — no `willTerminate`, no chance
        // for bt-core to checkpoint its WAL, no chance to mark live
        // tiles as failed. The user reopens the laptop and sees a
        // freshly-launched window with their Eternal run flipped to
        // "stopped" by `reconcileActiveFlagsOnLaunch`. These calls
        // demote the process from "killable on a whim" to "send a
        // proper terminate notification first", which dramatically
        // reduces the rate of fresh-launch surprises after sleep.
        // Both are reference-counted; we never re-enable, so the
        // demotion holds for the entire app lifetime.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Tado holds live PTY children and the in-process bt-core daemon"
        )
    }

    /// Called from `NSApplication.willTerminateNotification` so the
    /// retain on the activity assertion is released cleanly. The
    /// process is going down anyway, but the formal end-call gets
    /// logged in Console for forensic clarity.
    func teardown() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        let ws = NSWorkspace.shared.notificationCenter
        for obs in observers { ws.removeObserver(obs) }
        observers.removeAll()
        installed = false
    }

    // MARK: - willSleep

    private func handleWillSleep() {
        EventBus.shared.publish(
            TadoEvent(
                type: "system.willSleep",
                severity: .info,
                source: .system,
                title: "macOS sleeping",
                body: "Tado checkpointing bt-core before sleep."
            )
        )
        // Mirror the v0.16.1 termination hook: ask bt-core to flush
        // its WAL. After sleep the next mutation re-arms it. If the
        // daemon hasn't booted yet (e.g. user slept the laptop while
        // Dome was offline) tado_dome_stop returns 0 immediately.
        DomeRpcClient.domeStop()
    }

    // MARK: - didWake

    private func handleDidWake() {
        EventBus.shared.publish(
            TadoEvent(
                type: "system.didWake",
                severity: .info,
                source: .system,
                title: "macOS resumed",
                body: "Reconciling daemon + agent tiles after wake."
            )
        )
        verifyDaemonHealth()
        reconcilePTYChildren()
    }

    private func verifyDaemonHealth() {
        // `system_health` returns nil if the daemon socket is dead, or
        // a `SystemHealth` envelope with `dbOk` plus per-step checks
        // when it answers. We treat nil + dbOk:false symmetrically as
        // "daemon is unhealthy" and surface a recovery event for the
        // operator. We deliberately do NOT auto-restart here — per
        // CLAUDE.md Rule 1 (no watchdogs / retries on the dispatch
        // chain), the operator gets the truth and decides.
        let health = DomeRpcClient.systemHealth()
        let healthy = (health?.dbOk ?? false)
        if !healthy {
            EventBus.shared.publish(
                TadoEvent(
                    type: "dome.daemonUnhealthyAfterWake",
                    severity: .error,
                    source: .system,
                    title: "Dome daemon unresponsive after wake",
                    body: "bt-core didn't answer a health check. Quit and relaunch Tado to remint the daemon socket; existing tiles + canonical JSON are unaffected."
                )
            )
        }
    }

    private func reconcilePTYChildren() {
        guard let manager = terminalManager else { return }
        var lostCount = 0
        var lostTitles: [String] = []
        for session in manager.sessions {
            // The Swift session may believe `isRunning = true`. The
            // Rust core knows whether the PTY child still has a live
            // PID. If they disagree, the child died during sleep
            // (macOS killed it under memory pressure, or the parent
            // shell exited because its claude/codex process exited).
            // Snap the Swift state to match so the UI stops showing
            // a frozen-but-"alive" tile.
            guard let core = session.coreSession else { continue }
            if session.isRunning && !core.isRunning {
                session.isRunning = false
                if session.status != .completed && session.status != .failed {
                    session.status = .failed
                }
                lostCount += 1
                lostTitles.append(session.title)
            }
        }
        if lostCount > 0 {
            let preview = lostTitles.prefix(3).joined(separator: ", ")
            let suffix = lostCount > 3 ? " (+\(lostCount - 3) more)" : ""
            EventBus.shared.publish(
                TadoEvent(
                    type: "terminal.lostDuringSleep",
                    severity: .warning,
                    source: .system,
                    title: "\(lostCount) agent tile\(lostCount == 1 ? "" : "s") died during sleep",
                    body: "macOS killed the child process while the laptop was asleep: \(preview)\(suffix). The tiles are marked failed; close them or respawn the todo to start over."
                )
            )
        }
    }

    // MARK: - Stale IPC directory cleanup

    /// Walk `/tmp` and remove any `tado-ipc-<pid>` directory whose pid
    /// is no longer alive. Called from `IPCBroker.init` before it
    /// creates the current launch's directory. Without this, the inbox
    /// accumulates one cruft directory per crashed instance.
    ///
    /// Safe to call repeatedly — the kill(0) probe is cheap and
    /// concurrent live Tado processes are honoured (their pid is
    /// still alive, so their directory is left alone).
    static func cleanupStaleIPCDirectories(currentPid: Int32) {
        let tmpRoot = URL(fileURLWithPath: "/tmp")
        let fm = FileManager.default
        let prefix = "tado-ipc-"
        guard let entries = try? fm.contentsOfDirectory(
            at: tmpRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let pidStr = String(name.dropFirst(prefix.count))
            guard let pid = Int32(pidStr) else { continue }
            if pid == currentPid { continue }
            // kill(pid, 0) returns 0 if the process exists and we have
            // permission to signal it; ESRCH (3) means no such process.
            // EPERM (1) means the pid is alive but owned by someone
            // else — which on a single-user laptop is essentially
            // impossible for a tado-ipc-<pid> directory we created,
            // but we still skip the cleanup to avoid clobbering
            // somebody else's process namespace.
            let alive = (kill(pid, 0) == 0) || (errno == EPERM)
            if !alive {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
