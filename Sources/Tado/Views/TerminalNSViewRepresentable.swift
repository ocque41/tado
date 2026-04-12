import SwiftUI
import SwiftTerm
import SwiftData

class LoggingTerminalView: LocalProcessTerminalView {
    var onDataReceived: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onDataReceived?(slice)
    }
}

struct TerminalNSViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let engine: TerminalEngine
    let ipcRoot: URL?

    func makeNSView(context: Context) -> LoggingTerminalView {
        let terminalView = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))

        let fontSize: CGFloat = 13
        if let font = NSFont(name: "SF Mono", size: fontSize) ?? NSFont(name: "Menlo", size: fontSize) {
            terminalView.font = font
        }
        terminalView.nativeBackgroundColor = NSColor(red: 0.118, green: 0.118, blue: 0.180, alpha: 1.0)
        terminalView.nativeForegroundColor = NSColor(red: 0.804, green: 0.839, blue: 0.957, alpha: 1.0)

        terminalView.processDelegate = context.coordinator
        context.coordinator.terminalView = terminalView

        Task { @MainActor in
            session.terminalView = terminalView
        }

        let (executable, args) = ProcessSpawner.command(for: session.todoText, engine: engine)
        let env: [String]
        if let ipcRoot = ipcRoot {
            env = ProcessSpawner.environment(
                sessionID: session.id,
                sessionName: session.todoText,
                engine: engine,
                ipcRoot: ipcRoot
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
