import SwiftUI
import SwiftData
import SwiftTerm
import AppKit

struct CanvasView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext

    @State private var scale: CGFloat = 0.75
    @State private var offset: CGSize = .zero
    @State private var scrollMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var viewportSize: CGSize = .zero
    @State private var hasInitialized: Bool = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CanvasGridBackground()

                ForEach(terminalManager.sessions) { session in
                    TerminalTileView(
                        session: session,
                        engine: currentEngine,
                        ipcRoot: terminalManager.ipcBroker?.ipcRoot,
                        scale: scale
                    ) { newPosition in
                        persistPosition(session: session, position: newPosition)
                    }
                    .position(x: session.canvasPosition.x, y: session.canvasPosition.y)
                    .id(session.id)
                }
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(offset)
            .onAppear {
                viewportSize = geometry.size
                installMonitors()
                if !hasInitialized {
                    centerCanvas()
                    hasInitialized = true
                }
            }
            .onDisappear {
                removeMonitors()
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
            }
            .task(id: appState.pendingNavigationID) {
                guard let todoID = appState.pendingNavigationID else { return }
                guard let session = terminalManager.session(forTodoID: todoID) else { return }
                try? await Task.sleep(for: .milliseconds(150))
                let vp = viewportSize.width > 0 ? viewportSize : geometry.size
                let target = session.canvasPosition
                withAnimation(.easeInOut(duration: 0.4)) {
                    offset = CGSize(
                        width: -target.x * scale + vp.width / 2,
                        height: -target.y * scale + vp.height / 2
                    )
                }
                try? await Task.sleep(for: .milliseconds(500))
                appState.pendingNavigationID = nil
            }
        }
        .background(Color(nsColor: NSColor(white: 0.08, alpha: 1.0)))
        .overlay(alignment: .bottomTrailing) {
            zoomControls.padding(16)
        }
    }

    // MARK: - Center

    private func centerCanvas() {
        guard appState.pendingNavigationID == nil else { return }
        if let first = terminalManager.sessions.first {
            offset = CGSize(
                width: -first.canvasPosition.x * scale + viewportSize.width / 2,
                height: -first.canvasPosition.y * scale + viewportSize.height / 2
            )
        } else {
            offset = CGSize(
                width: viewportSize.width / 2 - CanvasLayout.tileWidth * scale / 2,
                height: viewportSize.height / 2 - CanvasLayout.tileHeight * scale / 2
            )
        }
    }

    // MARK: - Event monitors

    private func installMonitors() {
        // Scroll: 2-finger pan or shift+2-finger zoom
        // If a terminal is focused, regular scroll goes to it (scrollback)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            guard self.appState.currentView == .canvas else { return event }

            // Shift + scroll = zoom always, even over a focused terminal
            if event.modifierFlags.contains(.shift) {
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    ? event.scrollingDeltaX
                    : event.scrollingDeltaY
                self.zoomAnchored(by: delta * 0.01)
                return nil
            }

            // If a terminal has focus, let it handle scroll (terminal scrollback)
            if self.isTerminalFocused() {
                return event
            }

            // Otherwise pan the canvas
            self.offset = CGSize(
                width: self.offset.width + event.scrollingDeltaX,
                height: self.offset.height + event.scrollingDeltaY
            )
            return nil
        }

        // Click outside a terminal = unfocus it so scroll goes back to canvas pan
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [self] event in
            guard self.appState.currentView == .canvas else { return event }
            guard let window = event.window, let contentView = window.contentView else { return event }

            let location = event.locationInWindow
            if let hitView = contentView.hitTest(location) {
                if !isViewInsideTerminal(hitView) {
                    // Clicked on canvas background — resign terminal focus
                    window.makeFirstResponder(contentView)
                }
            }
            return event // always pass clicks through
        }
    }

    private func removeMonitors() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    /// Check if any TerminalView in the responder chain is first responder
    private func isTerminalFocused() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        var view: NSView? = firstResponder
        while let v = view {
            if v is TerminalView { return true }
            view = v.superview
        }
        return false
    }

    /// Check if a view is inside a TerminalView hierarchy
    private func isViewInsideTerminal(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is TerminalView { return true }
            current = v.superview
        }
        return false
    }

    // MARK: - Zoom

    private func zoomAnchored(by delta: CGFloat) {
        let oldScale = scale
        let newScale = max(0.2, min(2.0, oldScale + delta))
        guard newScale != oldScale else { return }

        let vpCenterX = viewportSize.width / 2
        let vpCenterY = viewportSize.height / 2
        let canvasX = (vpCenterX - offset.width) / oldScale
        let canvasY = (vpCenterY - offset.height) / oldScale

        offset = CGSize(
            width: vpCenterX - canvasX * newScale,
            height: vpCenterY - canvasY * newScale
        )
        scale = newScale
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button(action: { zoomAnchored(by: -0.15) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)

            Text("\(Int(scale * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44)

            Button(action: { zoomAnchored(by: 0.15) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)

            Button(action: { resetZoom() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    private func resetZoom() {
        let oldScale = scale
        let newScale: CGFloat = 0.75
        let vpCenterX = viewportSize.width / 2
        let vpCenterY = viewportSize.height / 2
        let canvasX = (vpCenterX - offset.width) / oldScale
        let canvasY = (vpCenterY - offset.height) / oldScale
        withAnimation(.easeInOut(duration: 0.3)) {
            offset = CGSize(
                width: vpCenterX - canvasX * newScale,
                height: vpCenterY - canvasY * newScale
            )
            scale = newScale
        }
    }

    private var currentEngine: TerminalEngine {
        let descriptor = FetchDescriptor<AppSettings>()
        return (try? modelContext.fetch(descriptor).first?.engine) ?? .claude
    }

    private func persistPosition(session: TerminalSession, position: CGPoint) {
        let todoID = session.todoID
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.id == todoID })
        if let todo = try? modelContext.fetch(descriptor).first {
            todo.canvasX = position.x
            todo.canvasY = position.y
        }
    }
}

// MARK: - Grid background

struct CanvasGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let gridSpacing: CGFloat = 40
            let dotSize: CGFloat = 1.5
            var x: CGFloat = 0
            while x < size.width * 3 {
                var y: CGFloat = 0
                while y < size.height * 3 {
                    let rect = CGRect(
                        x: x - size.width, y: y - size.height,
                        width: dotSize, height: dotSize
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.06)))
                    y += gridSpacing
                }
                x += gridSpacing
            }
        }
        .frame(width: 5000, height: 5000)
        .offset(x: -2500, y: -2500)
    }
}
