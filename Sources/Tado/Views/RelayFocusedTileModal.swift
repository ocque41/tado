// Focused-tile modal — full-canvas overlay per brief section 6.3.
//
// Triggered by clicking a tile on the canvas (or selecting a session
// row in Sessions / Explore). Renders a centered editorial card
// 80vw × 80vh containing a scrolling read-only mirror of the tile's
// terminal log + a hairline-separated input field at the bottom.
//
// This is a chrome layer over the existing tile data; it does NOT
// replace the underlying Metal-rendered terminal — that stays on
// the canvas behind. The modal shows a markdown-style mirror of the
// tile's text content for "what is this agent doing right now"
// reading + a quick-send input.

import SwiftUI
import SwiftData

struct RelayFocusedTileModal: View {
    @Binding var todoID: UUID?

    @Environment(\.relayTheme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]

    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    private var focused: TodoItem? {
        guard let id = todoID else { return nil }
        return todos.first(where: { $0.id == id })
    }

    var body: some View {
        ZStack {
            // Scrim
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
                .onTapGesture { dismiss() }

            // Modal card
            if let todo = focused {
                modalCard(todo: todo)
                    .frame(maxWidth: 1280)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 80)
                    .padding(.vertical, 60)
            }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func modalCard(todo: TodoItem) -> some View {
        VStack(spacing: 0) {
            head(todo: todo)
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            body(todo: todo)
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            inputBar(todo: todo)
        }
        .background(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .fill(RelayPalette.background(for: theme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
        )
        .shadow(
            color: RelayShadow.modalColor,
            radius: RelayShadow.modalRadius,
            x: RelayShadow.modalX,
            y: RelayShadow.modalY
        )
    }

    private func head(todo: TodoItem) -> some View {
        let dotKind: RelayStatusKind = {
            switch todo.status {
            case .running:                       return .running
            case .needsInput, .awaitingResponse: return .needsInput
            default:                             return .idle
            }
        }()
        return HStack(spacing: 14) {
            RelayStatusDot(kind: dotKind, size: 8)
            Text(todo.displayName)
                .font(Typography.sans(size: 13, weight: .medium))
                .tracking(RelayTracking.meta(13))
                .foregroundStyle(RelayPalette.foreground(for: theme))
            Text("[\(todo.gridIndex)] · \(todo.agentName?.uppercased() ?? "AGENT")")
                .font(Typography.sans(size: 10, weight: .regular))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Spacer()
            Text(elapsedString(todo.createdAt).uppercased())
                .font(Typography.sans(size: 10, weight: .medium))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(todo.status == .needsInput
                    ? RelayPalette.terracotta
                    : RelayPalette.foreground3(for: theme))
            RelayButton(label: "Close ✕", variant: .tiny) {
                dismiss()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func body(todo: TodoItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(todo.terminalLog.isEmpty
                    ? "Waiting for output…"
                    : todo.terminalLog)
                    .font(Typography.sans(size: 13, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .textSelection(.enabled)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func inputBar(todo: TodoItem) -> some View {
        HStack(spacing: 12) {
            Text("›")
                .font(Typography.sans(size: 14, weight: .regular))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            TextField("Send to this agent… (⌘↩)", text: $inputText)
                .textFieldStyle(.plain)
                .font(Typography.sans(size: 13, weight: .regular))
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .focused($inputFocused)
                .onKeyPress(phases: .down) { keyPress in
                    if keyPress.key == .return && keyPress.modifiers.contains(.command) {
                        send(todo: todo)
                        return .handled
                    }
                    return .ignored
                }
            RelayButton(label: "Forward", variant: .tiny) {
                appState.forwardTargetTodoID = todo.id
                dismiss()
            }
            RelayButton(label: "Send", variant: .primary) {
                send(todo: todo)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    // MARK: - Helpers

    private func dismiss() {
        todoID = nil
    }

    private func send(todo: TodoItem) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        terminalManager.forwardInput(toTodoID: todo.id, text: text)
        inputText = ""
    }

    private func elapsedString(_ start: Date) -> String {
        let secs = Int(Date().timeIntervalSince(start))
        if secs < 60 { return "\(secs)s elapsed" }
        if secs < 3600 { return "\(secs / 60)m elapsed" }
        return "\(secs / 3600)h elapsed"
    }
}
