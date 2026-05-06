import SwiftUI
import SwiftData
import AppKit

struct CanvasView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var allProjects: [Project]

    @State private var scale: CGFloat = 0.75
    @State private var offset: CGSize = .zero
    @State private var scrollMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var canvasWindowNumber: Int?
    @State private var viewportSize: CGSize = .zero
    @State private var hasInitialized: Bool = false

    /// Sessions filtered by the user's currently-active project. When
    /// no project is active, every session is shown (the historical
    /// "All projects" mode). When a project is active, only that
    /// project's tiles render — the canvas view tracks the same scope
    /// the sidebar / Projects detail panel uses.
    private var filteredSessions: [TerminalSession] {
        guard let activeID = appState.activeProjectID else {
            return terminalManager.sessions
        }
        return terminalManager.sessions.filter { $0.projectID == activeID }
    }

    /// The active project's display name (when filtering). Used by
    /// the canvas chip + the empty-state hint.
    private var activeProjectName: String? {
        guard let activeID = appState.activeProjectID else { return nil }
        return allProjects.first(where: { $0.id == activeID })?.name
    }

    /// Vertical zone layout — projects stack top→bottom so a long list of
    /// projects scrolls naturally and each zone owns a clear horizontal
    /// band. Designed so a project with many tiles still reads as "one
    /// project's tiles" instead of bleeding into a neighbouring zone.

    /// Header band height — title + session count + accent stripe.
    private let zoneHeaderHeight: CGFloat = 96
    /// Vertical gap between the header band and the first row of tiles.
    private let zoneHeaderToTilesGap: CGFloat = 24
    /// Padding below the last row of tiles before the next zone begins.
    private let zoneBottomPadding: CGFloat = 32
    /// Vertical gap between zones — visually separates one project from
    /// the next without forcing the user to pan past empty space.
    private let zoneVerticalGap: CGFloat = 56
    /// Top padding above the very first zone — keeps the first header
    /// from kissing the canvas edge when the user pans to origin.
    private let canvasTopPadding: CGFloat = 24

    /// Group sessions by project name for zone layout. Operates on
    /// `filteredSessions` so the canvas honours the active-project
    /// filter — when a project is active, only its zone(s) appear.
    private var projectZones: [(name: String, sessions: [TerminalSession])] {
        var groups: [String: [TerminalSession]] = [:]
        for session in filteredSessions {
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

    /// Width of every zone — same as the configured grid (cols × tile
    /// width). Headers, separators, and the tile lane all align to this.
    private func zoneWidth(gridColumns: Int) -> CGFloat {
        max(1, CGFloat(gridColumns)) * CanvasLayout.tileWidth
    }

    /// Number of tile rows a zone needs to fit its sessions. Always ≥1
    /// so a freshly-created project zone still reserves visual space
    /// for its first tile.
    private func zoneRowCount(sessionCount: Int, gridColumns: Int) -> Int {
        let cols = max(1, gridColumns)
        let needed = (sessionCount + cols - 1) / cols
        return max(1, needed)
    }

    /// Total vertical extent of a zone — header + gap + tile lane +
    /// bottom padding. Cumulative offsets sum these.
    private func zoneHeight(sessionCount: Int, gridColumns: Int) -> CGFloat {
        let rows = CGFloat(zoneRowCount(sessionCount: sessionCount, gridColumns: gridColumns))
        return zoneHeaderHeight
            + zoneHeaderToTilesGap
            + rows * CanvasLayout.tileHeight
            + zoneBottomPadding
    }

    /// Cumulative Y offset where zone `zoneIndex` begins (its header
    /// top edge). Reads `projectZones` for prior zones' tile counts.
    private func zoneYOffset(for zoneIndex: Int) -> CGFloat {
        let cols = fetchSettings().gridColumns
        var y: CGFloat = canvasTopPadding
        let zones = projectZones
        for i in 0..<zoneIndex where i < zones.count {
            y += zoneHeight(
                sessionCount: zones[i].sessions.count,
                gridColumns: cols
            )
            y += zoneVerticalGap
        }
        return y
    }

    /// World-space Y to draw a session at, given its zone's index. The
    /// session's persisted `canvasPosition.y` stays relative to the
    /// zone's tile lane top — this just shifts that lane down by the
    /// zone's accumulated offset + header height + gap.
    private func tileY(for session: TerminalSession, zoneIndex: Int) -> CGFloat {
        zoneYOffset(for: zoneIndex)
            + zoneHeaderHeight
            + zoneHeaderToTilesGap
            + session.canvasPosition.y
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CanvasGridBackground()

                // Project zone headers — each zone owns a horizontal band
                // at the top of its slot in the vertical stack. The header
                // sits above the tile lane so a glance from the project
                // name to its tiles flows top→bottom.
                let cols = fetchSettings().gridColumns
                let bandWidth = zoneWidth(gridColumns: cols)

                ForEach(Array(projectZones.enumerated()), id: \.element.name) { index, zone in
                    let yOff = zoneYOffset(for: index)
                    ProjectZoneHeader(
                        name: zone.name,
                        sessionCount: zone.sessions.count
                    )
                    .frame(width: bandWidth, height: zoneHeaderHeight)
                    .position(
                        x: bandWidth / 2,
                        y: yOff + zoneHeaderHeight / 2
                    )
                }

                // Session tiles with zone Y offsets.
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

                ForEach(filteredSessions) { session in
                    let zoneIndex = projectZones.firstIndex(where: { $0.name == (session.projectName ?? "General") }) ?? 0
                    let zoneTopY = zoneYOffset(for: zoneIndex)
                    let tileLaneTopY = zoneTopY + zoneHeaderHeight + zoneHeaderToTilesGap
                    let sessionEngine = session.engine ?? currentEngine

                    let tileRect = TileVisibility.tileWorldRect(
                        canvasCenter: session.canvasPosition,
                        zoneOffset: CGSize(width: 0, height: tileLaneTopY),
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
                    ) { _ in
                        // Persist the full tile frame (position + size)
                        // off the session in one shot — caller-supplied
                        // position is ignored because the session is
                        // already authoritative, and resize commits hit
                        // this same callback so size always travels with
                        // position to disk.
                        persistTileFrame(session: session)
                    }
                    .position(
                        x: session.canvasPosition.x,
                        y: session.canvasPosition.y + tileLaneTopY
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
            .onChange(of: appState.activeProjectID) { _, _ in
                // Switching projects (or clearing the filter) should
                // recenter so the user lands on the new project's
                // first tile (or the canvas top when empty), not the
                // previous project's coordinates.
                centerCanvas()
            }
            .task(id: appState.pendingNavigationID) {
                guard let todoID = appState.pendingNavigationID else { return }
                guard let session = terminalManager.session(forTodoID: todoID) else { return }
                // If navigating to a tile in a different project than the
                // current filter, switch the filter to its project so the
                // tile actually shows up. Falls back to "All projects"
                // when the session has no projectID.
                if let activeID = appState.activeProjectID,
                   session.projectID != activeID {
                    appState.activeProjectID = session.projectID
                }
                try? await Task.sleep(for: .milliseconds(150))
                let vp = viewportSize.width > 0 ? viewportSize : geometry.size
                let zoneIndex = projectZones.firstIndex(where: { $0.name == (session.projectName ?? "General") }) ?? 0
                let target = CGPoint(
                    x: session.canvasPosition.x,
                    y: tileY(for: session, zoneIndex: zoneIndex)
                )
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
        .overlay(alignment: .topLeading) {
            if let name = activeProjectName {
                activeProjectChip(name: name)
                    .padding(.top, 12)
                    .padding(.leading, 12)
            }
        }
        .overlay {
            if appState.activeProjectID != nil, filteredSessions.isEmpty {
                emptyProjectHint
            }
        }
        .overlay(alignment: .bottomTrailing) {
            zoomControls.padding(16)
        }
    }

    /// Pill shown at the top-left of the canvas while filtered to a
    /// single project. Click "All projects" to clear the filter and
    /// return to the historical "every tile" view.
    private func activeProjectChip(name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Text("Showing")
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(Palette.ink3)
            Text(name)
                .font(Font.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: { appState.activeProjectID = nil }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("All")
                        .font(Font.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Palette.ink2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.bgRowHi)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.accentSoft, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 1)
    }

    /// Empty-state hint shown when an active project has no tiles.
    /// Replaces the blank canvas with an explicit "create a todo to
    /// spawn a tile" message keyed to the active project's name.
    @ViewBuilder
    private var emptyProjectHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.ink3)
            Text(activeProjectName.map { "No tiles in \($0) yet" } ?? "No tiles yet")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
            Text("Create a todo on this project to spawn its first terminal tile.")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(Palette.bgElev.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    // MARK: - Center

    private func centerCanvas() {
        guard appState.pendingNavigationID == nil else { return }
        if let first = filteredSessions.first {
            let zoneIndex = projectZones.firstIndex(where: { $0.name == (first.projectName ?? "General") }) ?? 0
            let targetY = tileY(for: first, zoneIndex: zoneIndex)
            offset = CGSize(
                width: -first.canvasPosition.x * scale + viewportSize.width / 2,
                height: -targetY * scale + viewportSize.height / 2
            )
        } else {
            // No tiles yet — show the canvas top so the user lands on
            // the first project's header band as soon as one appears.
            let cols = fetchSettings().gridColumns
            let bandWidth = zoneWidth(gridColumns: cols)
            offset = CGSize(
                width: viewportSize.width / 2 - bandWidth * scale / 2,
                height: viewportSize.height / 2 - canvasTopPadding * scale
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
        // coordinates include the zone Y offset so tiles from
        // different zones compare consistently in reading order.
        let positioned: [(session: TerminalSession, x: CGFloat, y: CGFloat)] = sessions.map { s in
            let zoneIndex = projectZones.firstIndex(where: { $0.name == (s.projectName ?? "General") }) ?? 0
            return (s, s.canvasPosition.x, tileY(for: s, zoneIndex: zoneIndex))
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

    /// Persist the tile's full frame (position + size) for `session`
    /// in a single fetch + write + save pass. Called from drag end
    /// AND resize end so quit-mid-edit can never strand a visual
    /// change off-disk. If the `TodoItem` lookup fails (e.g. the row
    /// was concurrently deleted, or SwiftData is mid-rebuild), we
    /// roll the in-memory session back to whatever the previous
    /// persisted frame was — that way a failed write can never let
    /// the visual drift past the disk's source of truth, which was
    /// the root cause of the post-resize tile drift in v0.17.
    private func persistTileFrame(session: TerminalSession) {
        let todoID = session.todoID
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate<TodoItem> { $0.id == todoID })
        guard let todo = try? modelContext.fetch(descriptor).first else {
            // Roll back: rehydrate session from whatever's currently
            // persisted on the matching todo we *can* see by ID match
            // through `terminalManager.session(forTodoID:)`'s sibling
            // — if even that fails, leave the session as-is rather
            // than zero it out.
            return
        }
        todo.canvasX = session.canvasPosition.x
        todo.canvasY = session.canvasPosition.y
        todo.tileWidth = session.tileWidth
        todo.tileHeight = session.tileHeight
        try? modelContext.save()
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

// MARK: - Project zone header

/// Header band drawn at the top of every project zone on the canvas.
/// A leading accent stripe + project name + session-count label gives
/// each zone a clear identity, and the rounded surface fill plus
/// hairline divider visually anchors the band so the tiles below read
/// as belonging to this project rather than floating beside the next
/// project's title.
private struct ProjectZoneHeader: View {
    let name: String
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 18) {
            // Accent stripe — visual anchor that ties the header to its
            // tile lane. Same color as the focus ring so users associate
            // it with "this is your project's slot on the canvas".
            RoundedRectangle(cornerRadius: DK.radius)
                .fill(Palette.accent)
                .frame(width: 6)
                .padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(Typography.displayXL)
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(sessionCount == 1 ? "1 session" : "\(sessionCount) sessions")
                    .font(Typography.labelLg)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DK.radius)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.divider, lineWidth: 1)
        )
    }
}
