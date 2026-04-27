import SwiftUI
import SwiftData
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
    @State private var canvasWindowNumber: Int?
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
                        .font(Typography.title)
                        .foregroundStyle(Palette.foreground.opacity(0.35))
                        .position(
                            x: xOff + CanvasLayout.tileWidth * CGFloat(fetchSettings().gridColumns) / 2,
                            y: 20
                        )
                }

                // Session tiles with zone offsets.
                //
                // Virtualization: compute the visible world-space rect
                // once per body eval; skip mounting heavy renderers for
                // tiles fully outside it. Every tile uses the Metal
                // renderer, so virtualization applies uniformly.
                let visibleRect = TileVisibility.visibleWorldRect(
                    viewportSize: viewportSize,
                    scale: scale,
                    offset: offset
                )

                ForEach(terminalManager.sessions) { session in
                    let zoneIndex = projectZones.firstIndex(where: { $0.name == (session.projectName ?? "General") }) ?? 0
                    let xOff = zoneOffset(for: zoneIndex)
                    let sessionEngine = session.engine ?? currentEngine

                    let tileRect = TileVisibility.tileWorldRect(
                        canvasCenter: session.canvasPosition,
                        zoneX: xOff,
                        tileWidth: session.tileWidth,
                        tileHeight: session.tileHeight
                    )
                    let visible = TileVisibility.isVisible(
                        tileRect: tileRect,
                        visibleRect: visibleRect
                    )

                    TerminalTileView(
                        session: session,
                        engine: sessionEngine,
                        ipcRoot: terminalManager.ipcBroker?.ipcRoot,
                        modeFlags: session.modeFlagsOverride ?? modeFlags(for: sessionEngine),
                        effortFlags: session.effortFlagsOverride ?? effortFlags(for: sessionEngine),
                        modelFlags: session.modelFlagsOverride ?? modelFlags(for: sessionEngine),
                        claudeDisplay: claudeDisplayEnv(),
                        fontSize: CGFloat(fetchSettings().terminalFontSize),
                        fontFamily: fetchSettings().terminalFontFamily,
                        cursorBlink: fetchSettings().cursorBlink,
                        bellMode: fetchSettings().bellMode,
                        isVisible: visible,
                        scale: scale,
                        isFocused: appState.focusedTileTodoID == session.todoID
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
            // Do NOT wrap with .frame + .clipped here. It was used to
            // prevent a tile near the canvas origin from bleeding into
            // the TopNavBar's hit region, but clipping also blocks
            // AppKit mouse-event delivery to every child MTKView that
            // extends past the clip rect — which kills scrollback,
            // tile drag, and resize gestures. The TopNavBar is
            // protected instead by `.zIndex(1)` in ContentView, which
            // wins hit-testing without clipping canvas children.
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
        .background(Palette.canvas)
        .background(
            CanvasWindowProbe { window in
                canvasWindowNumber = window?.windowNumber
            }
        )
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
        // Hover alone never routes scroll to a terminal — the tile must
        // also be the focused one (accent border visible). Any other
        // cursor position pans the canvas.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            guard self.appState.currentView == .canvas else { return event }
            guard event.window?.windowNumber == self.canvasWindowNumber else { return event }

            // Shift + scroll = zoom always, even over a terminal
            if event.modifierFlags.contains(.shift) {
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    ? event.scrollingDeltaX
                    : event.scrollingDeltaY
                self.zoomAnchored(by: delta * 0.01)
                return nil
            }

            // Only pass scroll through to the terminal when the cursor
            // is over the *focused* tile. Returning the event (not nil)
            // lets AppKit deliver it to `TerminalMTKView.scrollWheel`
            // for scrollback / mouse-reporting. Unfocused hover falls
            // through to canvas pan below.
            if let mtk = self.metalTileUnderCursor(for: event),
               let session = self.sessionForMTKView(mtk),
               self.appState.focusedTileTodoID == session.todoID {
                return event
            }

            // Otherwise pan the canvas
            self.offset = CGSize(
                width: self.offset.width + event.scrollingDeltaX,
                height: self.offset.height + event.scrollingDeltaY
            )
            return nil
        }

        // Keyboard: arrow-key tile selection, Escape for edit-mode exit,
        // Cmd+/-/0 for zoom.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard self.appState.currentView == .canvas else { return event }
            guard event.window?.windowNumber == self.canvasWindowNumber else { return event }

            // A sheet is open (Settings, Dispatch modal, Eternal modal,
            // Done list, Trash list) — let its TextFields / pickers use
            // arrows + Escape natively. We still handle Cmd+zoom below
            // because the main canvas is what's being zoomed; even with
            // a sheet over it, that's fine.
            let anySheetOpen = self.appState.showSettings
                || self.appState.showDoneList
                || self.appState.showTrashList
                || self.appState.dispatchModalRunID != nil
                || self.appState.eternalModalRunID != nil
                || self.appState.eternalInterveneRunID != nil

            let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let hasModifier = !event.modifierFlags.intersection(modifierMask).isEmpty

            // Arrow keys (no modifier) — tile selection navigation.
            if !hasModifier, !anySheetOpen, let direction = ArrowDirection(keyCode: event.keyCode) {
                // Edit mode: a terminal already owns firstResponder, arrows
                // go to the PTY (bash readline, vim, etc.).
                if self.isFirstResponderATerminal(event.window) {
                    return event
                }
                self.moveSelection(direction)
                return nil
            }

            // Escape — exit terminal edit mode OR clear selection.
            if !hasModifier, event.keyCode == 53 {
                if self.isFirstResponderATerminal(event.window),
                   let window = event.window,
                   let contentView = window.contentView {
                    window.makeFirstResponder(contentView)
                    return nil
                }
                if self.appState.focusedTileTodoID != nil {
                    self.appState.focusedTileTodoID = nil
                    return nil
                }
                return event
            }

            // Cmd+/- = zoom in/out, Cmd+0 = reset zoom.
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

        // Click outside a terminal = unfocus it so scroll goes back to canvas
        // pan. Click ON a terminal = make that tile the keyboard selection.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [self] event in
            guard self.appState.currentView == .canvas else { return event }
            guard event.window?.windowNumber == self.canvasWindowNumber else { return event }
            guard let window = event.window, let contentView = window.contentView else { return event }

            let location = event.locationInWindow
            if let hitView = contentView.hitTest(location) {
                if !isViewInsideTerminal(hitView) {
                    window.makeFirstResponder(contentView)
                    self.appState.focusedTileTodoID = nil
                } else if let mtk = self.metalTileUnderCursor(for: event),
                          let session = self.sessionForMTKView(mtk) {
                    self.appState.focusedTileTodoID = session.todoID
                    // Sync firstResponder explicitly. The MTKView's own
                    // mouseDown also calls makeFirstResponder(self), but a
                    // SwiftUI overlay above the cell area (resize handles,
                    // focus border, future tile chrome) can swallow the
                    // click before AppKit dispatches mouseDown to the
                    // MTKView — leaving the accent ring lit while
                    // firstResponder stays on contentView, which routes
                    // arrows to tile-nav instead of the picker the user
                    // sees.
                    if window.firstResponder !== mtk {
                        window.makeFirstResponder(mtk)
                    }
                }
            }
            return event // always pass clicks through
        }
    }

    /// Map an MTKView back to its owning `TerminalSession` via the shared
    /// `TadoCore.Session` reference. Returns nil if the tile hasn't
    /// finished spawning (coreSession still nil on the session side).
    private func sessionForMTKView(_ mtk: TerminalMTKView) -> TerminalSession? {
        for session in terminalManager.sessions {
            if let core = session.coreSession, core === mtk.session {
                return session
            }
        }
        return nil
    }

    /// True when the current first responder chain begins with a terminal
    /// tile (the user is actively typing into a PTY). Gates the arrow-key
    /// tile navigation so arrows inside bash / vim / etc. still work.
    private func isFirstResponderATerminal(_ window: NSWindow?) -> Bool {
        guard let first = window?.firstResponder as? NSView else { return false }
        var current: NSView? = first
        while let v = current {
            if v is TerminalMTKView { return true }
            current = v.superview
        }
        return false
    }

    /// Direction picked from the four arrow keys. Maps macOS virtual
    /// keyCodes (stable across locales) to a logical axis+sign.
    private enum ArrowDirection {
        case up, down, left, right
        init?(keyCode: UInt16) {
            switch keyCode {
            case 123: self = .left
            case 124: self = .right
            case 125: self = .down
            case 126: self = .up
            default:  return nil
            }
        }
    }

    /// Move the tile-selection ring in the given direction. Picks the
    /// nearest tile along the primary axis, breaking ties with distance on
    /// the secondary axis. When no tile is currently selected, picks the
    /// first tile in reading order (top-left-most). After moving, pans the
    /// canvas so the newly-selected tile is centred.
    private func moveSelection(_ direction: ArrowDirection) {
        let sessions = terminalManager.sessions
        guard !sessions.isEmpty else { return }

        // Resolve (session, worldX, worldY) for every tile — world
        // coordinates include the project zone offset so tiles from
        // different zones compare consistently.
        let positioned: [(session: TerminalSession, x: CGFloat, y: CGFloat)] = sessions.map { s in
            let zoneIndex = projectZones.firstIndex(where: { $0.name == (s.projectName ?? "General") }) ?? 0
            let xOff = zoneOffset(for: zoneIndex)
            return (s, s.canvasPosition.x + xOff, s.canvasPosition.y)
        }

        let currentID = appState.focusedTileTodoID
        let currentEntry = positioned.first(where: { $0.session.todoID == currentID })

        let chosen: (session: TerminalSession, x: CGFloat, y: CGFloat)?
        if let cur = currentEntry {
            chosen = pickNeighbor(from: cur, among: positioned, direction: direction)
        } else {
            // No selection yet — pick the first tile in reading order.
            chosen = positioned.sorted { a, b in
                if a.y != b.y { return a.y < b.y }
                return a.x < b.x
            }.first
        }

        guard let target = chosen else { return }
        appState.focusedTileTodoID = target.session.todoID

        // Pan the canvas to centre the selected tile. Matches the
        // existing pendingNavigationID animation cadence.
        let vp = viewportSize
        guard vp.width > 0, vp.height > 0 else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            offset = CGSize(
                width: -target.x * scale + vp.width / 2,
                height: -target.y * scale + vp.height / 2
            )
        }
    }

    /// Filter + score candidates on the axis dominated by `direction`.
    /// Returns the best match or nil if no tile lies in that direction.
    private func pickNeighbor(
        from current: (session: TerminalSession, x: CGFloat, y: CGFloat),
        among all: [(session: TerminalSession, x: CGFloat, y: CGFloat)],
        direction: ArrowDirection
    ) -> (session: TerminalSession, x: CGFloat, y: CGFloat)? {
        let candidates = all.filter { $0.session.id != current.session.id }
        let inDirection = candidates.filter { c in
            switch direction {
            case .up:    return c.y < current.y
            case .down:  return c.y > current.y
            case .left:  return c.x < current.x
            case .right: return c.x > current.x
            }
        }
        // If no tile strictly in-direction, wrap within the axis (e.g.
        // "down" from the bottom-most tile wraps to the top-most in
        // the same column region). Matches Finder / iOS springboard feel.
        let pool = inDirection.isEmpty ? candidates : inDirection
        return pool.min { a, b in
            neighborScore(current: current, candidate: a, direction: direction)
                < neighborScore(current: current, candidate: b, direction: direction)
        }
    }

    /// Lower score = better match. Primary axis weighted more heavily so a
    /// tile directly below is preferred over one far to the side.
    private func neighborScore(
        current: (session: TerminalSession, x: CGFloat, y: CGFloat),
        candidate: (session: TerminalSession, x: CGFloat, y: CGFloat),
        direction: ArrowDirection
    ) -> CGFloat {
        let dx = candidate.x - current.x
        let dy = candidate.y - current.y
        switch direction {
        case .up, .down:
            return abs(dy) + abs(dx) * 2
        case .left, .right:
            return abs(dx) + abs(dy) * 2
        }
    }

    private func removeMonitors() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Hit-test for a Metal-rendered terminal tile under the cursor.
    /// The Metal path handles scrollback inside its own `scrollWheel`
    /// override, so the scroll monitor just needs to know "is this one
    /// of those?" to pass the event through.
    private func metalTileUnderCursor(for event: NSEvent) -> TerminalMTKView? {
        guard let window = event.window, let contentView = window.contentView else { return nil }
        guard let hit = contentView.hitTest(event.locationInWindow) else { return nil }
        var view: NSView? = hit
        while let v = view {
            if let mtk = v as? TerminalMTKView { return mtk }
            view = v.superview
        }
        return nil
    }

    /// Check if a view is inside a Metal terminal tile. Used by the
    /// click monitor to decide whether an outside-click should resign
    /// the tile's first-responder status.
    private func isViewInsideTerminal(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is TerminalMTKView { return true }
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
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textSecondary)
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

private struct CanvasWindowProbe: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindowChange = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.onWindowChange = onResolve
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }

    private final class ProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
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
                    context.fill(Path(ellipseIn: rect), with: .color(Palette.foreground.opacity(0.06)))
                    y += gridSpacing
                }
                x += gridSpacing
            }
        }
        .frame(width: 5000, height: 5000)
        .offset(x: -2500, y: -2500)
    }
}
