import Foundation

/// Watches `<projectRoot>/.tado/cowork/<runID>.md` for the Cowork
/// task's result markdown, then surfaces the file contents back
/// into the originating tile's PTY stream and transitions the
/// session to `.completed`.
///
/// Cowork has no headless output capture — the URL-scheme launcher
/// (`tado-cowork`) opens the Claude Desktop app, fills in the prompt,
/// attaches the project folder, and exits. The bundled
/// `tado-cowork-plugin` ships a `cowork-tado-tools` skill that
/// instructs Cowork: "when you've finished a Tado-launched task,
/// write your result markdown to `<projectRoot>/.tado/cowork/
/// <runID>.md`." That file convention IS the round-trip channel.
///
/// One-shot by construction (CLAUDE.md rule 1 — no watchdogs):
///   • Fires its callback exactly once when the result file appears,
///     then ends.
///   • If 30 minutes pass with no file, the poller cancels and the
///     session transitions to `.completed` with a "no result"
///     status line. That timeout is a hard floor for tile-state
///     cleanliness, not a retry loop — there's no retry path,
///     just a deadline beyond which the tile shouldn't sit
///     `running` indefinitely.
///   • Cancel-on-tile-stop is honored via `cancel()`.
///
/// Implementation: a DispatchSource file watcher on the result
/// path (debounced 500 ms — a single mid-write fsync shouldn't
/// trigger a partial read), backed by a 30-min deadline timer.
@MainActor
final class CoworkOutputPoller {
    let runID: UUID
    let resultFileURL: URL
    let onResult: (_ content: String) -> Void
    let onTimeout: () -> Void
    let onCancel: () -> Void

    private var watcher: FileWatcher?
    private var deadline: DispatchWorkItem?
    private var isFinished = false

    /// Build and immediately start the poller.
    init(
        projectRoot: String,
        runID: UUID,
        timeout: TimeInterval = 30 * 60,
        onResult: @escaping (_ content: String) -> Void,
        onTimeout: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) {
        self.runID = runID
        let runIDString = runID.uuidString.lowercased()
        self.resultFileURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".tado/cowork/\(runIDString).md")
        self.onResult = onResult
        self.onTimeout = onTimeout
        self.onCancel = onCancel
        ensureWatchDirExists()
        start(timeout: timeout)
    }

    /// Stop watching. Idempotent. Calls onCancel exactly once.
    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        watcher?.cancel()
        watcher = nil
        deadline?.cancel()
        deadline = nil
        onCancel()
    }

    private func ensureWatchDirExists() {
        let parent = resultFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    }

    private func start(timeout: TimeInterval) {
        // If the file already exists when the poller starts (e.g.
        // user re-opened a tile for a Cowork run that completed
        // before the previous Tado launch), fire immediately.
        if let content = readResultFile() {
            isFinished = true
            onResult(content)
            return
        }

        // Watch the directory rather than the file directly: the
        // file doesn't exist yet, so attaching DispatchSource to a
        // non-existent path would either no-op (file mode) or
        // create an empty file via FileWatcher's auto-create
        // behavior — neither is what we want. Watching the parent
        // directory catches the create event.
        let parent = resultFileURL.deletingLastPathComponent()
        watcher = FileWatcher(url: parent, debounce: 0.5, queue: .main) { [weak self] in
            self?.checkForResult()
        }

        // Hard 30-min deadline. Cancels the watcher and surfaces
        // the timeout to the tile. Per CLAUDE.md rule 1, this is
        // a deadline, not a retry — there is no further attempt
        // after this fires.
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.fireTimeout()
            }
        }
        deadline = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout,
            execute: work
        )
    }

    private func checkForResult() {
        guard !isFinished else { return }
        guard let content = readResultFile() else { return }
        isFinished = true
        watcher?.cancel()
        watcher = nil
        deadline?.cancel()
        deadline = nil
        onResult(content)
    }

    private func fireTimeout() {
        guard !isFinished else { return }
        isFinished = true
        watcher?.cancel()
        watcher = nil
        deadline = nil
        onTimeout()
    }

    private func readResultFile() -> String? {
        guard FileManager.default.fileExists(atPath: resultFileURL.path) else {
            return nil
        }
        // Skip empty files — Cowork could have created the file but
        // not finished writing yet. The next debounced tick will
        // re-check.
        let attrs = try? FileManager.default.attributesOfItem(atPath: resultFileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size == 0 { return nil }
        return try? String(contentsOf: resultFileURL, encoding: .utf8)
    }
}
