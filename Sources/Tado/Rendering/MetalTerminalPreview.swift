import SwiftUI
import AppKit

/// Standalone preview window for the Phase 2 Metal renderer. Opens via
/// Debug → Metal Terminal Preview (Cmd+Shift+M). Spawns one login shell
/// through `TadoCore.Session` and renders it with `MetalTerminalView`,
/// bypassing SwiftTerm and the main canvas entirely.
///
/// This is the safe integration path — it lets the user try the new
/// pipeline end-to-end with zero risk to the existing production flow.
/// Phase 2.4 deletes this file and swaps MetalTerminalView into
/// `TerminalTileView` directly.
struct MetalTerminalPreviewWindow: View {
    @StateObject private var holder = SessionHolder()

    var body: some View {
        Group {
            if let session = holder.session {
                MetalTerminalView(session: session, cols: 120, rows: 32)
                    .frame(minWidth: 800, minHeight: 500)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(holder.status)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 800, minHeight: 500)
            }
        }
        .background(Color.black)
        .onAppear { holder.start() }
        .onDisappear { holder.stop() }
    }
}

/// Lightweight AppKit controller that opens exactly one preview window
/// at a time. Cleaner than a SwiftUI `Window` scene because it doesn't
/// need to be declared at the top-level `body` — the Debug menu item
/// can spin it up on demand.
enum MetalTerminalPreviewWindowController {
    private static var currentWindow: NSWindow?

    static func show() {
        if let existing = currentWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: MetalTerminalPreviewWindow())
        host.view.frame = NSRect(x: 0, y: 0, width: 960, height: 560)

        let window = NSWindow(
            contentRect: host.view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Metal Terminal Preview"
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Clear the reference when the user closes the window so re-opening
        // spawns a fresh zsh instead of surfacing a dead view.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            currentWindow = nil
        }

        currentWindow = window
    }
}

/// Owns the TadoCore.Session lifecycle for the preview window.
/// Using a reference-type holder (not @State) because `TadoCore.Session`
/// is a class and its lifetime must outlive SwiftUI re-renders.
private final class SessionHolder: ObservableObject {
    @Published var session: TadoCore.Session?
    @Published var status: String = "spawning shell…"

    func start() {
        guard session == nil else { return }
        // Inherit the user's env so `claude` / `codex` on $PATH work.
        let env = ProcessInfo.processInfo.environment
        guard let spawned = TadoCore.Session(
            command: "/bin/zsh",
            args: ["-l"],
            cwd: ProcessInfo.processInfo.environment["HOME"],
            environment: env,
            cols: 120,
            rows: 32
        ) else {
            status = "failed to spawn /bin/zsh"
            return
        }
        session = spawned
        status = "ready"
    }

    func stop() {
        session?.kill()
        session = nil
    }
}
