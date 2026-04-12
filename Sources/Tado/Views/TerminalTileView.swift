import SwiftUI

struct TerminalTileView: View {
    let session: TerminalSession
    let engine: TerminalEngine
    let ipcRoot: URL?
    let scale: CGFloat
    var onPositionChanged: ((CGPoint) -> Void)? = nil
    @Environment(TerminalManager.self) private var terminalManager
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            // Title bar — drag handle
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isRunning ? .green : .orange)
                    .frame(width: 8, height: 8)

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
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        session.canvasPosition = CGPoint(
                            x: session.canvasPosition.x + value.translation.width,
                            y: session.canvasPosition.y + value.translation.height
                        )
                        dragOffset = .zero
                        onPositionChanged?(session.canvasPosition)
                    }
            )

            // Terminal
            TerminalNSViewRepresentable(session: session, engine: engine, ipcRoot: ipcRoot)
                .frame(width: CanvasLayout.contentWidth, height: CanvasLayout.contentHeight - 28)
        }
        .frame(width: CanvasLayout.contentWidth, height: CanvasLayout.contentHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .offset(x: dragOffset.width, y: dragOffset.height)
    }
}
