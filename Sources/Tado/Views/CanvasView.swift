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
    @State private var keyMonitor: Any?
    @State private var viewportSize: CGSize = .zero
    @State private var hasInitialized: Bool = false

    /// Width of the gap between project zones on the universal canvas
    private let zoneGap: CGFloat = 120

    /// Group sessions by project name for zone layout
    private var projectZones: [(name: String, sessions: [TerminalSession])] {
        var groups: [String: [TerminalSession]] = [:]
        for session in terminalManager.sessions {
            let key = session.projectName ?? "General"
            groups[key, default: []].append(session)
        }
        // "General" first, then alphabetical
        return groups.sorted { a, b in
            if a.key == "General" { return true }
            if b.key == "General" { return false }
            return a.key < b.key
        }.map { (name: $0.key, sessions: $0.value) }
    }

    /// Compute the X offset for each project zone
    private func zoneOffset(for zoneIndex: Int) -> CGFloat {
        let settings = fetchSettings()
        let cols = CGFloat(settings.gridColumns)
        let zoneWidth = cols * CanvasLayout.tileWidth + zoneGap
        return CGFloat(zoneIndex) * zoneWidth
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CanvasGridBackground()

                // Project zone labels
                ForEach(Array(projectZones.enumerated()), id: \.element.name) { index, zone in
                    let xOff = zoneOffset(for: index)
                    Text(zone.name)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .position(
                            x: xOff + CanvasLayout.tileWidth * CGFloat(fetchSettings().gridColumns) / 2,
                            y: 20
                        )
                }

                // Session tiles with zone offsets
                ForEach(terminalManager.sessions) { session in
                    let zoneIndex = projectZones.firstIndex(where: { $0.name == (session.projectName ?? "General") }) ?? 0
                    let xOff = zoneOffset(for: zoneIndex)
                    let sessionEngine = session.engine ?? currentEngine

                    TerminalTileView(
                        session: session,
                        engine: sessionEngine,
                        ipcRoot: terminalManager.ipcBroker?.ipcRoot,
                        modeFlags: modeFlags(for: sessionEngine),
                        effortFlags: effortFlags(for: sessionEngine),
                        modelFlags: modelFlags(for: sessionEngine),
                        claudeDisplay: claudeDisplayEnv(),
                        scale: scale
                    ) { newPosition in
                        persistPosition(session: session, position: newPosition)
                    }
                    .position(
                        x: session.canvasPosition.x + xOff,
                        y: session.canvasPosition.y
                    )
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
                let zoneIndex = projectZones.firstIndex(where: { $0.name == (session.projectName ?? "General") }) ?? 0
                let xOff = zoneOffset(for: zoneIndex)
                let target = CGPoint(x: session.canvasPosition.x + xOff, y: session.canvasPosition.y)
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
            let zoneIndex = projectZones.firstIndex(where: { $0.name == (first.projectName ?? "General") }) ?? 0
            let xOff = zoneOffset(for: zoneIndex)
            offset = CGSize(
                width: -(first.canvasPosition.x + xOff) * scale + viewportSize.width / 2,
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
        // If the cursor is over a terminal, regular scroll goes to it
        // (terminal scrollback) — regardless of focus state.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            guard self.appState.currentView == .canvas else { return event }

            // Shift + scroll = zoom always, even over a terminal
            if event.modifierFlags.contains(.shift) {
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    ? event.scrollingDeltaX
                    : event.scrollingDeltaY
                self.zoomAnchored(by: delta * 0.01)
                return nil
            }

            // If the cursor is over a terminal tile, route the scroll into
            // its scrollback. Previously this was gated on first-responder
            // status, so a freshly deployed tile (never clicked) silently
            // swallowed all scrollback gestures into a canvas pan.
            //
            // Two paths because SwiftTerm's `scrollWheel` only honors
            // `event.deltaY` (classic mouse wheel). Trackpads / Magic Mouse
            // always have `deltaY == 0` and report via `scrollingDeltaY`,
            // so we synthesize line scrolls for them and consume the event.
            if let terminal = self.terminalUnderCursor(for: event) {
                if event.deltaY != 0 {
                    return event
                }
                let pixels = event.scrollingDeltaY
                if pixels == 0 { return nil }
                let lines = max(1, min(20, Int(abs(pixels) / 12)))
                if pixels > 0 {
                    terminal.scrollUpLines(lines)
                } else {
                    terminal.scrollDownLines(lines)
                }
                return nil
            }

            // Otherwise pan the canvas
            self.offset = CGSize(
                width: self.offset.width + event.scrollingDeltaX,
                height: self.offset.height + event.scrollingDeltaY
            )
            return nil
        }

        // Cmd+/- = zoom in/out, Cmd+0 = reset zoom
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard self.appState.currentView == .canvas else { return event }
            guard event.modifierFlags.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers {
            case "=", "+":
                withAnimation(.easeOut(duration: 0.15)) {
                    self.zoomAnchored(by: 0.15)
                }
                return nil
            case "-":
                withAnimation(.easeOut(duration: 0.15)) {
                    self.zoomAnchored(by: -0.15)
                }
                return nil
            case "0":
                self.resetZoom()
                return nil
            default:
                return event
            }
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
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Hit-test the scroll event location and return the LoggingTerminalView
    /// under the cursor, if any. Used to route scroll events to terminals
    /// regardless of first-responder state.
    private func terminalUnderCursor(for event: NSEvent) -> LoggingTerminalView? {
        guard let window = event.window, let contentView = window.contentView else { return nil }
        guard let hit = contentView.hitTest(event.locationInWindow) else { return nil }
        var view: NSView? = hit
        while let v = view {
            if let term = v as? LoggingTerminalView { return term }
            view = v.superview
        }
        return nil
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

    private func fetchSettings() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        return AppSettings()
    }

    private var currentEngine: TerminalEngine {
        let descriptor = FetchDescriptor<AppSettings>()
        return (try? modelContext.fetch(descriptor).first?.engine) ?? .claude
    }

    private var currentModeFlags: [String] { modeFlags(for: currentEngine) }
    private var currentEffortFlags: [String] { effortFlags(for: currentEngine) }
    private var currentModelFlags: [String] { modelFlags(for: currentEngine) }

    private func modeFlags(for engine: TerminalEngine) -> [String] {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? modelContext.fetch(descriptor).first else { return [] }
        if engine == .claude { return settings.claudeMode.cliFlags }
        // Codex needs the Tado embed shim regardless of mode (env inheritance for
        // tado-send, plus optional --no-alt-screen so SwiftTerm doesn't break).
        return ProcessSpawner.codexEmbedShim(allowAlternateScreen: settings.codexAlternateScreen)
            + settings.codexMode.cliFlags
    }

    private func effortFlags(for engine: TerminalEngine) -> [String] {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? modelContext.fetch(descriptor).first else { return [] }
        return engine == .claude ? settings.claudeEffort.cliFlags : settings.codexEffort.cliFlags
    }

    private func modelFlags(for engine: TerminalEngine) -> [String] {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? modelContext.fetch(descriptor).first else { return [] }
        return engine == .claude ? settings.claudeModel.cliFlags : settings.codexModel.cliFlags
    }

    private func claudeDisplayEnv() -> ProcessSpawner.ClaudeDisplayEnv {
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? modelContext.fetch(descriptor).first else { return .defaults }
        return ProcessSpawner.ClaudeDisplayEnv(
            noFlicker: settings.claudeNoFlicker,
            mouseEnabled: settings.claudeMouseEnabled,
            scrollSpeed: settings.claudeScrollSpeed
        )
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
