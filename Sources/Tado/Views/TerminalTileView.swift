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

    private let titleBarHeight: CGFloat = 28
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
                width: isResizing ? visualWidth : session.tileWidth,
                height: (isResizing ? visualHeight : session.tileHeight) - titleBarHeight
            )
        }
        .background(Palette.surface)
        .frame(
            width: isResizing ? visualWidth : session.tileWidth,
            height: isResizing ? visualHeight : session.tileHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.divider, lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .overlay {
            if isResizing {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Palette.accent.opacity(0.7), lineWidth: 2)
            } else if isFocused {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Palette.accent, lineWidth: 2)
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
        HStack(spacing: 8) {
            Circle()
                .fill(session.isRunning ? Palette.success : Palette.warning)
                .frame(width: 8, height: 8)

            if let agent = session.agentName {
                Text(agent)
                    .font(Typography.monoMicroEmph)
                    .foregroundColor(Palette.accent)
                    .lineLimit(1)
                Text("|")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
            }

            // Run-role tag — disambiguates concurrent eternal/dispatch tiles
            // in the same project zone. "worker", "architect", "interventor",
            // or "phase" — read from TerminalSession.runRole set at spawn time.
            if let role = session.runRole {
                Text(role)
                    .font(Typography.monoMicroEmph)
                    .foregroundStyle(roleColor(role))
                    .lineLimit(1)
                Text("|")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
            }

            Text(session.todoText)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)

            Spacer()

            Text(CanvasLayout.gridLabel(forIndex: session.gridIndex))
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)

            if session.unreadMessageCount > 0 {
                Text("\(session.unreadMessageCount)")
                    .font(Typography.monoBadgeSmall)
                    .foregroundStyle(Palette.foreground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.accent))
            }

            Button(action: { terminalManager.terminateSession(session.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.surfaceElevated)
        .contentShape(Rectangle())
        .gesture(tileDragGesture)
    }

    /// Small distinct color per run role. Worker = green (long-lived), architect
    /// = blue (planning), interventor = amber (one-shot directive), phase = gray.
    private func roleColor(_ role: String) -> Color {
        switch role {
        case "worker":      return Palette.success
        case "architect":   return Palette.accent
        case "interventor": return Palette.warning
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
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if isVisible {
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
                width: width,
                height: height
            )
        } else {
            OffscreenTilePlaceholder(session: session, width: width, height: height)
        }
    }
}

/// Cheap placeholder shown for Metal-rendered tiles that are currently
/// off-screen. Preserves the tile shape so pan/zoom visuals don't jitter
/// when a tile crosses the visibility threshold. The session's PTY keeps
/// running in Rust; only the GPU resources are released.
private struct OffscreenTilePlaceholder: View {
    let session: TerminalSession
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Palette.canvas)
            .frame(width: width, height: height)
            .overlay(
                Image(systemName: "pause.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.foreground.opacity(0.15))
            )
    }
}
