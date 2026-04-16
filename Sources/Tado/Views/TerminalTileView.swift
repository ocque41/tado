import SwiftUI

struct TerminalTileView: View {
    let session: TerminalSession
    let engine: TerminalEngine
    let ipcRoot: URL?
    let modeFlags: [String]
    let effortFlags: [String]
    let modelFlags: [String]
    let claudeDisplay: ProcessSpawner.ClaudeDisplayEnv
    let scale: CGFloat
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
                width: isResizing ? visualWidth : session.tileWidth,
                height: (isResizing ? visualHeight : session.tileHeight) - titleBarHeight
            )
        }
        .background(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
        .frame(
            width: isResizing ? visualWidth : session.tileWidth,
            height: isResizing ? visualHeight : session.tileHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .overlay {
            if isResizing {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isResizing {
                Text("\(Int(visualWidth)) x \(Int(visualHeight))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.6)))
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
                .fill(session.isRunning ? .green : .orange)
                .frame(width: 8, height: 8)

            if let agent = session.agentName {
                Text(agent)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                Text("|")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(session.todoText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(CanvasLayout.gridLabel(forIndex: session.gridIndex))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            if session.unreadMessageCount > 0 {
                Text("\(session.unreadMessageCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.blue))
            }

            Button(action: { terminalManager.terminateSession(session.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: NSColor(white: 0.15, alpha: 1.0)))
        .contentShape(Rectangle())
        .gesture(tileDragGesture)
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
                context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1)
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
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        TerminalNSViewRepresentable(session: session, engine: engine, ipcRoot: ipcRoot, modeFlags: modeFlags, effortFlags: effortFlags, modelFlags: modelFlags, agentName: session.agentName, claudeDisplay: claudeDisplay)
            .frame(width: width, height: height)
    }
}
