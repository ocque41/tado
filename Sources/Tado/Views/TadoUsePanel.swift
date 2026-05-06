import SwiftUI
import SwiftData

/// The Tado Use drawer. Slides in from the left edge of the main
/// window when `appState.showTadoUse` is true (toggled by
/// Cmd+Shift+U or the close button in this header). Hosts a chat
/// surface where a headless `claude -p` / `codex exec` agent calls
/// 30 existing MCP tools (tado-mcp + dome-mcp) plus 6 in-process
/// bridge tools to drive Tado's SwiftUI surface.
///
/// Engine + model + effort + permission mode are inherited from
/// the user's live `AppSettings` row (the same row the canvas
/// tile spawn uses). The drawer header has an engine picker so
/// the user can flip between Claude and Codex per-conversation;
/// model / effort / permission live in Settings to keep the
/// drawer's chrome simple.
struct TadoUsePanel: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(TadoUseState.self) private var useState
    @Environment(TadoUseEngineHolder.self) private var engineHolder
    @Environment(\.modelContext) private var modelContext
    @Query private var allSettings: [AppSettings]

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    private var settings: AppSettings? { allSettings.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Palette.divider)
            conversationScroll
            Divider().background(Palette.divider)
            inputArea
            footer
        }
        .background(Palette.bgPage)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            // Right-edge hairline to visually separate the drawer
            // from the canvas behind it without a heavy divider.
            Rectangle()
                .fill(Palette.rule)
                .frame(width: 1)
        }
        .onAppear {
            engineHolder.engine.bind(
                useState: useState,
                appState: appState,
                settings: settings,
                modelContext: modelContext
            )
            // Defer focus so the drawer's slide-in animation
            // finishes before we steal the responder.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                inputFocused = true
            }
        }
        .onChange(of: settings?.id) { _, _ in
            engineHolder.engine.updateSettings(settings)
        }
        .onChange(of: useState.engine) { _, _ in
            // Switching engines mid-conversation invalidates the
            // resume — start a fresh conversation so the new
            // engine doesn't try to pick up the other one's thread.
            useState.clearConversation()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
            Text("Tado Use")
                .font(Typography.heading)
                .foregroundStyle(Palette.ink)

            Spacer(minLength: 8)

            engineSegment

            Button(action: { useState.clearConversation() }) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink2)
            .help("New conversation")

            Button(action: { appState.showTadoUse = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink2)
            .help("Close (⌘⇧U)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
    }

    private var engineSegment: some View {
        @Bindable var s = useState
        return Picker("Engine", selection: $s.engine) {
            ForEach(TerminalEngine.allCases, id: \.self) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 160)
        .controlSize(.small)
        .disabled(useState.isStreaming)
    }

    // MARK: - Conversation scroll

    private var conversationScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if useState.turns.isEmpty {
                        emptyState
                    } else {
                        ForEach(useState.turns) { turn in
                            TadoUseTurnRow(
                                turn: turn,
                                isStreaming: isLastTurn(turn) && useState.isStreaming
                            )
                            .id(turn.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: useState.turns.last?.id) { _, newID in
                guard let id = newID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: useState.turns.last?.text) { _, _ in
                guard let id = useState.turns.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drive Tado from here.")
                .font(Typography.titleSm)
                .foregroundStyle(Palette.ink)
            Text("Ask the agent to list your tiles, search Dome, switch the active view, focus a session, or anything else it can do with tado_*, dome_*, and tado_use_* tools.")
                .font(Typography.body)
                .foregroundStyle(Palette.ink2)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text("Engine: \(useState.engine.displayName) · Model + permission mode follow your Settings.")
                .font(Typography.captionSm)
                .foregroundStyle(Palette.ink3)
                .padding(.top, 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 24)
    }

    private func isLastTurn(_ turn: TadoUseState.Turn) -> Bool {
        useState.turns.last?.id == turn.id
    }

    // MARK: - Input

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(useState.isStreaming ? "Streaming…" : "Ask Tado Use anything (Enter sends, Shift+Enter newline)")
                        .font(Typography.body)
                        .foregroundStyle(Palette.ink3)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .focused($inputFocused)
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 120)
                    .disabled(useState.isStreaming)
                    .onSubmit { submit() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Palette.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Palette.rule, lineWidth: 1)
                    )
            )

            HStack {
                if let err = useState.lastError {
                    Text(err)
                        .font(Typography.captionSm)
                        .foregroundStyle(Palette.danger)
                        .lineLimit(2)
                } else {
                    Spacer()
                }
                Spacer()
                if useState.isStreaming {
                    Button(action: stop) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill").font(.system(size: 10))
                            Text("Stop").font(Typography.label)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.danger)
                } else {
                    Button(action: submit) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 14))
                            Text("Send").font(Typography.label)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSubmit ? Palette.accent : Palette.ink3)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.bgPage)
    }

    private var canSubmit: Bool {
        !useState.isStreaming &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 9))
            Text(permissionLabel)
                .font(Typography.captionSm)
            Spacer()
            if useState.inputTokens + useState.outputTokens > 0 {
                Text("\(useState.inputTokens) in · \(useState.outputTokens) out")
                    .font(Typography.captionSm)
            }
        }
        .foregroundStyle(Palette.ink3)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Palette.bgElev)
    }

    private var permissionLabel: String {
        switch useState.engine {
        case .claude:
            return "Claude · \(settings?.claudeMode.displayName ?? "Ask permissions")"
        case .codex:
            return "Codex · \(settings?.codexMode.displayName ?? "Default permissions")"
        }
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !useState.isStreaming else { return }
        engineHolder.engine.send(trimmed)
        draft = ""
    }

    private func stop() {
        engineHolder.engine.stop()
    }
}

/// SwiftUI environment-injectable holder for the engine reference.
/// We can't put the engine on `TadoUseState` directly without
/// dragging Foundation/SwiftData lifecycles into the @Observable
/// model, and `@State` types must be passed through `.environment`
/// as observable boxes. This wrapper keeps the engine reachable
/// from every drawer subview without rebuilding it on each render.
@Observable
@MainActor
final class TadoUseEngineHolder {
    let engine: TadoUseEngine = TadoUseEngine()
}
