import SwiftUI

struct TerminalTileView: View {
    let session: TerminalSession
    let engine: TerminalEngine
    let ipcRoot: URL?
    let modeFlags: [String]
    let effortFlags: [String]
    let modelFlags: [String]
    let claudeDisplay: ProcessSpawner.ClaudeDisplayEnv
    /// Monospace point size for the Metal renderer.
    let fontSize: CGFloat
    /// Family name for the Metal renderer font. Empty = system mono.
    let fontFamily: String
    /// Blink the cursor. Honored live.
    let cursorBlink: Bool
    /// How BEL (0x07) is surfaced. Honored live.
    let bellMode: BellMode
    /// Virtualization signal from CanvasView. When false, this tile
    /// unmounts its renderer and shows a lightweight placeholder — the
    /// underlying `TadoCore.Session` keeps running in Rust.
    let isVisible: Bool
    let scale: CGFloat
    /// Paint the keyboard-selection accent ring around this tile. Set by
    /// `CanvasView` when `AppState.focusedTileTodoID == session.todoID`.
    var isFocused: Bool = false
    var onPositionChanged: ((CGPoint) -> Void)? = nil
    @Environment(TerminalManager.self) private var terminalManager
    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero
    @State private var isResizing: Bool = false

    /// Phase 6: head 28px + foot 22px = 50px chrome.
    private let titleBarHeight: CGFloat = 28
    private let tileFootHeight: CGFloat = 22
    private let handleSize: CGFloat = 6
    private let gripSize: CGFloat = 14
    private let minTileWidth: CGFloat = 300
    private let minTileHeight: CGFloat = 200

    /// Visual width during resize — used for outer frame and overlay, NOT for the terminal.
    private var visualWidth: CGFloat {
        max(minTileWidth, session.tileWidth + resizeDelta.width)
    }

    /// Visual height during resize — used for outer frame and overlay, NOT for the terminal.
    private var visualHeight: CGFloat {
        max(minTileHeight, session.tileHeight + resizeDelta.height)
    }

    /// Offset to keep the top-left corner fixed while resizing from right/bottom
    private var resizeOffset: CGSize {
        CGSize(
            width: (visualWidth - session.tileWidth) / 2,
            height: (visualHeight - session.tileHeight) / 2
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            // Terminal resizes in real time during drag gestures.
            StableTerminalContent(
                session: session,
                engine: engine,
                ipcRoot: ipcRoot,
                modeFlags: modeFlags,
                effortFlags: effortFlags,
                modelFlags: modelFlags,
                claudeDisplay: claudeDisplay,
                fontSize: fontSize,
                fontFamily: fontFamily,
                cursorBlink: cursorBlink,
                bellMode: bellMode,
                isVisible: isVisible,
                isFocused: isFocused,
                width: isResizing ? visualWidth : session.tileWidth,
                height: (isResizing ? visualHeight : session.tileHeight) - titleBarHeight - tileFootHeight
            )
            tileFoot
        }
        .background(Palette.surface)
        .frame(
            width: isResizing ? visualWidth : session.tileWidth,
            height: isResizing ? visualHeight : session.tileHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(Palette.divider, lineWidth: 1)
        )
        .compositingGroup()
        .overlay {
            // Phase 6 — terracotta focus + resize ring per brief.
            // Drop shadow removed per "no shadows on tiles" rule;
            // hairline border + focus ring is the affordance.
            if isResizing {
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(RelayPalette.terracotta.opacity(0.7), lineWidth: 2)
            } else if isFocused {
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(RelayPalette.terracotta, lineWidth: 2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isResizing {
                Text("\(Int(visualWidth)) x \(Int(visualHeight))")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.foreground.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.background.opacity(0.7)))
                    .padding(8)
            }
        }
        .overlay { resizeHandles }
        .offset(
            x: dragOffset.width + (isResizing ? resizeOffset.width : 0),
            y: dragOffset.height + (isResizing ? resizeOffset.height : 0)
        )
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            // Phase 6 — Relay live status dot. Three variants per
            // brief: pulsing terracotta for running, solid terracotta
            // for needs-input, ink-4 for idle.
            relayStatusDot

            if let agent = session.agentName {
                Text(agent.uppercased())
                    .font(Typography.sans(size: 9, weight: .semibold))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.terracotta)
                    .lineLimit(1)
                Rectangle()
                    .fill(Palette.divider)
                    .frame(width: 1, height: 10)
            }

            // Run-role tag — disambiguates concurrent eternal/dispatch tiles
            // in the same project zone. "worker", "architect", "interventor",
            // or "phase" — read from TerminalSession.runRole set at spawn time.
            if let role = session.runRole {
                Text(role.uppercased())
                    .font(Typography.sans(size: 9, weight: .semibold))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(roleColor(role))
                    .lineLimit(1)
                Rectangle()
                    .fill(Palette.divider)
                    .frame(width: 1, height: 10)
            }

            Text(session.todoText)
                .font(Typography.sans(size: 11, weight: .regular))
                .tracking(RelayTracking.meta(11))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text("[\(CanvasLayout.gridLabel(forIndex: session.gridIndex))]")
                .font(Typography.sans(size: 9, weight: .regular))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(Palette.textTertiary)

            if session.unreadMessageCount > 0 {
                Text("\(session.unreadMessageCount)")
                    .font(Typography.sans(size: 9, weight: .semibold))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(Palette.background)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: RelayRadius.standard)
                            .fill(RelayPalette.terracotta)
                    )
            }

            Button(action: { terminalManager.terminateSession(session.id) }) {
                Text("✕")
                    .font(Typography.sans(size: 11, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Close tile")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(height: titleBarHeight)
        .background(Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.divider)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .gesture(tileDragGesture)
    }

    /// Relay live status dot — translates SessionStatus into the
    /// three Relay variants per brief section 5.8.
    private var relayStatusDot: some View {
        let kind: RelayStatusKind = {
            if session.isRunning {
                return session.status == .needsInput || session.status == .awaitingResponse
                    ? .needsInput
                    : .running
            }
            return .idle
        }()
        return RelayStatusDot(kind: kind, size: 7)
    }

    // MARK: - Tile foot
    //
    // Phase 6 — engine name on the left, elapsed time / "NEEDS INPUT"
    // on the right. Mono-substitute caps. Hairline above.

    private var tileFoot: some View {
        HStack(spacing: 8) {
            Text(engine.rawValue.uppercased())
                .font(Typography.sans(size: 9, weight: .medium))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            footStatusText
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 22)
        .background(Palette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.divider)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var footStatusText: some View {
        let isUrgent = session.status == .needsInput || session.status == .awaitingResponse
        Text(footStatusLabel.uppercased())
            .font(Typography.sans(size: 9, weight: .medium))
            .tracking(RelayTracking.caps(9))
            .foregroundStyle(isUrgent
                ? RelayPalette.terracotta
                : Palette.textTertiary)
    }

    private var footStatusLabel: String {
        if session.coreSession == nil, let phase = session.spawnPhase {
            return phase
        }
        switch session.status {
        case .needsInput, .awaitingResponse:
            return "⚡ Needs Input"
        case .running:
            let secs = Int(Date().timeIntervalSince(session.startedAt))
            if secs < 60 { return "\(secs)s" }
            if secs < 3600 { return "\(secs / 60)m" }
            return "\(secs / 3600)h"
        case .pending:
            return "Pending"
        case .completed:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    /// Per-role color. Per the master brand (terracotta-only), the
    /// worker / architect / interventor variants all flatten to ink
    /// tiers + terracotta for the live ones; the role text itself is
    /// what carries the meaning, not the hue.
    private func roleColor(_ role: String) -> Color {
        switch role {
        case "worker":      return RelayPalette.terracotta
        case "architect":   return RelayPalette.terracotta.opacity(0.7)
        case "interventor": return Palette.textPrimary
        case "phase":       return Palette.textSecondary
        default:            return Palette.textTertiary
        }
    }

    // MARK: - Tile Drag (scale-compensated)

    private var tileDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                withTransaction(Transaction(animation: nil)) {
                    dragOffset = CGSize(
                        width: value.translation.width / scale,
                        height: value.translation.height / scale
                    )
                }
            }
            .onEnded { value in
                let adjusted = CGSize(
                    width: value.translation.width / scale,
                    height: value.translation.height / scale
                )
                withTransaction(Transaction(animation: nil)) {
                    dragOffset = .zero
                    session.canvasPosition = CGPoint(
                        x: session.canvasPosition.x + adjusted.width,
                        y: session.canvasPosition.y + adjusted.height
                    )
                }
                onPositionChanged?(session.canvasPosition)
            }
    }

    // MARK: - Resize Handles

    private var resizeHandles: some View {
        ZStack {
            // Right edge
            HStack(spacing: 0) {
                Spacer()
                Color.clear
                    .frame(width: handleSize)
                    .padding(.top, titleBarHeight)
                    .padding(.bottom, gripSize)
                    .contentShape(Rectangle())
                    .gesture(rightEdgeGesture)
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
                    }
            }

            // Bottom edge
            VStack(spacing: 0) {
                Spacer()
                Color.clear
                    .frame(height: handleSize)
                    .padding(.trailing, gripSize)
                    .contentShape(Rectangle())
                    .gesture(bottomEdgeGesture)
                    .onHover { hovering in
                        if hovering { NSCursor.resizeUpDown.push() }
                        else { NSCursor.pop() }
                    }
            }

            // Bottom-right corner grip
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    Spacer()
                    resizeGripIcon
                        .frame(width: gripSize, height: gripSize)
                        .contentShape(Rectangle())
                        .gesture(cornerGesture)
                        .onHover { hovering in
                            if hovering { NSCursor.crosshair.push() }
                            else { NSCursor.pop() }
                        }
                }
            }
        }
    }

    private var resizeGripIcon: some View {
        Canvas { context, size in
            for i in [3, 7, 11] as [CGFloat] {
                var path = Path()
                path.move(to: CGPoint(x: i, y: size.height - 1))
                path.addLine(to: CGPoint(x: size.width - 1, y: i))
                context.stroke(path, with: .color(Palette.foreground.opacity(0.3)), lineWidth: 1)
            }
        }
    }

    // MARK: - Resize Gestures

    private var rightEdgeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                withTransaction(Transaction(animation: nil)) {
                    isResizing = true
                    resizeDelta = CGSize(
                        width: value.translation.width / scale,
                        height: resizeDelta.height
                    )
                }
            }
            .onEnded { _ in commitResize() }
    }

    private var bottomEdgeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                withTransaction(Transaction(animation: nil)) {
                    isResizing = true
                    resizeDelta = CGSize(
                        width: resizeDelta.width,
                        height: value.translation.height / scale
                    )
                }
            }
            .onEnded { _ in commitResize() }
    }

    private var cornerGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                withTransaction(Transaction(animation: nil)) {
                    isResizing = true
                    resizeDelta = CGSize(
                        width: value.translation.width / scale,
                        height: value.translation.height / scale
                    )
                }
            }
            .onEnded { _ in commitResize() }
    }

    private func commitResize() {
        let newWidth = visualWidth
        let newHeight = visualHeight
        let widthChange = newWidth - session.tileWidth
        let heightChange = newHeight - session.tileHeight
        withTransaction(Transaction(animation: nil)) {
            resizeDelta = .zero
            isResizing = false
            session.tileWidth = newWidth
            session.tileHeight = newHeight
            session.canvasPosition = CGPoint(
                x: session.canvasPosition.x + widthChange / 2,
                y: session.canvasPosition.y + heightChange / 2
            )
        }
        onPositionChanged?(session.canvasPosition)
    }
}

// MARK: - Stable Terminal Content

/// Wraps the terminal NSView with a fixed frame based on committed dimensions.
/// SwiftUI skips this view's body when inputs are unchanged — which they are
/// during drag/resize gestures (width/height use committed session values).
/// The terminal only re-layouts when committed dimensions change (on gesture end).
private struct StableTerminalContent: View {
    let session: TerminalSession
    let engine: TerminalEngine
    let ipcRoot: URL?
    let modeFlags: [String]
    let effortFlags: [String]
    let modelFlags: [String]
    let claudeDisplay: ProcessSpawner.ClaudeDisplayEnv
    let fontSize: CGFloat
    let fontFamily: String
    let cursorBlink: Bool
    let bellMode: BellMode
    let isVisible: Bool
    let isFocused: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        // Always mount `MetalTerminalTileView` — its `.onAppear`
        // triggers `spawnIfNeeded`, which must fire even when the
        // tile lands outside the canvas viewport at first render.
        // Pre-fix, virtualization branched here on `isVisible` and
        // unmounted the spawning view entirely, so a freshly-spawned
        // session whose tile happened to land off-screen never ran
        // its PTY. The tile renders its own offscreen placeholder
        // internally based on the `isVisible` prop.
        MetalTerminalTileView(
            session: session,
            engine: engine,
            ipcRoot: ipcRoot,
            modeFlags: modeFlags,
            effortFlags: effortFlags,
            modelFlags: modelFlags,
            agentName: session.agentName,
            claudeDisplay: claudeDisplay,
            fontSize: fontSize,
            fontFamily: fontFamily,
            cursorBlink: cursorBlink,
            bellMode: bellMode,
            isFocused: isFocused,
            isVisible: isVisible,
            width: width,
            height: height
        )
    }
}
