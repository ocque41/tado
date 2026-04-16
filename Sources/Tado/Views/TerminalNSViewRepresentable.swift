import SwiftUI
import SwiftTerm
import SwiftData

class LoggingTerminalView: LocalProcessTerminalView {
    var onDataReceived: ((ArraySlice<UInt8>) -> Void)?
    private var dropHighlightView: NSView?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onDataReceived?(slice)
    }

    // SwiftTerm's `scrollWheel(with:)` is `public` (not `open`), so it can't
    // be overridden from outside the module. To support trackpad scrollback
    // (where `event.deltaY == 0` and only `scrollingDeltaY` is set), the
    // CanvasView scroll monitor translates pixel deltas into line scrolls
    // and calls these helpers directly.
    func scrollUpLines(_ count: Int) { scrollUp(lines: count) }
    func scrollDownLines(_ count: Int) { scrollDown(lines: count) }

    // MARK: - File drag-and-drop

    func setupDragAndDrop() {
        registerForDraggedTypes([.fileURL])

        let overlay = NSView(frame: bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        overlay.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        overlay.layer?.borderWidth = 2
        overlay.layer?.cornerRadius = 4
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        addSubview(overlay)
        dropHighlightView = overlay
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return super.draggingEntered(sender)
        }
        dropHighlightView?.isHidden = false
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return super.draggingUpdated(sender)
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlightView?.isHidden = true
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlightView?.isHidden = true

        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }

        let text = urls.map(\.path).joined(separator: " ")
        send(txt: text)
        return true
    }
}

struct TerminalNSViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let engine: TerminalEngine
    let ipcRoot: URL?
    let modeFlags: [String]
    let effortFlags: [String]
    let modelFlags: [String]
    let agentName: String?
    let claudeDisplay: ProcessSpawner.ClaudeDisplayEnv

    func makeNSView(context: Context) -> LoggingTerminalView {
        let terminalView = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))

        let fontSize: CGFloat = 13
        if let font = NSFont(name: "SF Mono", size: fontSize) ?? NSFont(name: "Menlo", size: fontSize) {
            terminalView.font = font
        }
        // Apply the session's randomized (or fixed) theme. Themes are picked at
        // spawn time in TerminalManager based on AppSettings.randomTileColor.
        terminalView.nativeBackgroundColor = session.theme.background
        terminalView.nativeForegroundColor = session.theme.foreground

        terminalView.setupDragAndDrop()
        terminalView.processDelegate = context.coordinator
        context.coordinator.terminalView = terminalView

        Task { @MainActor in
            session.terminalView = terminalView
        }

        let (executable, args) = ProcessSpawner.command(for: session.todoText, engine: engine, modeFlags: modeFlags, effortFlags: effortFlags, modelFlags: modelFlags, agentName: agentName)
        let env: [String]
        if let ipcRoot = ipcRoot {
            env = ProcessSpawner.environment(
                sessionID: session.id,
                sessionName: session.todoText,
                engine: engine,
                ipcRoot: ipcRoot,
                projectName: session.projectName,
                projectRoot: session.projectRoot,
                teamName: session.teamName,
                teamID: session.teamID,
                agentName: session.agentName,
                teamAgents: session.teamAgents,
                claudeDisplay: claudeDisplay
            )
        } else {
            env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        }

        terminalView.startProcess(
            executable: executable,
            args: args,
            environment: env,
            execName: "zsh",
            currentDirectory: session.lastKnownCwd
        )

        terminalView.onDataReceived = { [weak session] slice in
            let data = Data(slice)
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    session?.appendLog(text)
                }
            }
        }

        context.coordinator.startActivityMonitor()
        context.coordinator.startLogFlushTimer()

        return terminalView
    }

    func updateNSView(_ nsView: LoggingTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LoggingTerminalView, coordinator: Coordinator) {
        coordinator.stopActivityMonitor()
        coordinator.stopLogFlushTimer()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, ipcRoot: ipcRoot)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let session: TerminalSession
        let ipcRoot: URL?
        weak var terminalView: LoggingTerminalView?
        var activityTimer: Timer?
        var logFlushTimer: Timer?
        var lastCursorX: Int = -1
        var lastCursorY: Int = -1

        init(session: TerminalSession, ipcRoot: URL?) {
            self.session = session
            self.ipcRoot = ipcRoot
        }

        deinit {
            activityTimer?.invalidate()
            logFlushTimer?.invalidate()
        }

        func startActivityMonitor() {
            activityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self = self, let view = self.terminalView else { return }
                let terminal = view.getTerminal()
                let x = terminal.buffer.x
                let y = terminal.buffer.y

                Task { @MainActor in
                    if x != self.lastCursorX || y != self.lastCursorY {
                        self.lastCursorX = x
                        self.lastCursorY = y
                        self.session.markActivity()
                    } else {
                        // Cursor hasn't moved — check if idle long enough for needsInput
                        self.session.checkIdle()
                    }
                }
            }
        }

        func stopActivityMonitor() {
            activityTimer?.invalidate()
            activityTimer = nil
        }

        func startLogFlushTimer() {
            logFlushTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.flushLog()
            }
        }

        func stopLogFlushTimer() {
            logFlushTimer?.invalidate()
            logFlushTimer = nil
        }

        private func flushLog() {
            Task { @MainActor in
                guard !session.logBuffer.isEmpty else { return }
                let chunk = session.logBuffer
                session.logBuffer = ""
                session.onLogFlush?(chunk)
                self.appendToIPCLog(chunk)
            }
        }

        private func appendToIPCLog(_ chunk: String) {
            guard let ipcRoot = ipcRoot else { return }
            let logFile = ipcRoot
                .appendingPathComponent("sessions")
                .appendingPathComponent(session.id.uuidString.lowercased())
                .appendingPathComponent("log")
            guard let data = chunk.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: logFile)
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor in
                session.title = title
                session.markActivity()
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory else { return }
            Task { @MainActor in
                session.lastKnownCwd = directory
                session.onCwdChange?(directory)
            }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            flushLog()
            Task { @MainActor in
                session.markTerminated(exitCode: exitCode)
            }
            stopActivityMonitor()
            stopLogFlushTimer()
        }
    }
}
