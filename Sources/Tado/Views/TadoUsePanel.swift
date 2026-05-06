import SwiftUI
import SwiftData

/// The Tado Use drawer. Slides in from the left edge of the main
/// window when `appState.showTadoUse` is true (toggled by
/// Cmd+Shift+U or the close button in this header). Hosts a chat
/// surface where a headless `claude -p` agent calls the 30 existing
/// MCP tools (tado-mcp + dome-mcp) plus 35+ in-process bridge tools
/// to drive Tado's SwiftUI surface.
///
/// ## Settings parity
///
/// The chat body respects the user's terminal-font knobs from
/// `AppSettings`: `terminalFontFamily` + `terminalFontSize` set the
/// assistant/user text font. Header/footer chrome stays on Plus
/// Jakarta Sans (chrome doesn't change with terminal font, same
/// rule canvas tiles follow). Engine + model + effort + permission
/// mode are inherited from the live `AppSettings` row — same row
/// canvas tile spawn uses.
///
/// ## Streaming render path (H1 fix)
///
/// Finalized turns render via `ForEach(useState.turns)`. The active
/// streaming turn renders via `TadoUseLiveTurnRow`, bound to the
/// `streamingText`/`streamingToolCalls` scratchpad scalars on
/// `TadoUseState`. Per-token mutations only invalidate the live
/// row, not the parent ForEach over finalized turns.
///
/// ## Throttled auto-scroll (H3)
///
/// Auto-scroll fires at most ~6 Hz from a `TimelineView`, not on
/// every text delta. Suppressed when the user has manually
/// scrolled away from the bottom (Slack/Discord pattern).
struct TadoUsePanel: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(TadoUseState.self) private var useState
    @Environment(TadoUseEngineHolder.self) private var engineHolder
    @Environment(\.modelContext) private var modelContext
    @Query private var allSettings: [AppSettings]

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    @State private var agentPopoverShown: Bool = false
    /// Set to true when the user manually scrolls up (away from
    /// the bottom). Suppresses auto-scroll until they scroll back
    /// down or a new turn finalizes.
    @State private var autoScrollPaused: Bool = false

    private var settings: AppSettings? { allSettings.first }

    /// Resolved chat body font. Honors the terminal-font settings
    /// the canvas tiles already follow. Cached as a computed view
    /// property — reads `settings` (which is `@Query`-driven) so
    /// SwiftUI invalidates only when the settings row actually
    /// changes, not on every render.
    private var chatBodyFont: Font {
        let size = CGFloat(settings?.terminalFontSize ?? 13)
        let family = settings?.terminalFontFamily ?? ""
        if !family.isEmpty {
            return Font.custom(family, size: size)
        }
        return Font.system(size: size)
    }

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

    // MARK: - Header (brand + agent badge + actions)

    /// Brand-aligned header. Mirrors `TopNavBar.brandCell`'s shape:
    /// terracotta accent dot + Tado wordmark + "Use" sub-label, so
    /// the drawer reads as a first-class Tado surface, not a
    /// bolt-on extension.
    private var header: some View {
        HStack(spacing: 10) {
            brandCell

            Spacer(minLength: 8)

            agentBadge

            Button(action: { useState.clearConversation() }) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink2)
            .help("New conversation")
            .disabled(useState.isStreaming)

            Button(action: { appState.showTadoUse = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink2)
            .help("Close (⌘⇧U)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
    }

    private var brandCell: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.accent)
                .frame(width: 8, height: 8)
            Text("tado")
                .font(Typography.heading)
                .foregroundStyle(Palette.ink)
            Text("Use")
                .font(Typography.captionSm)
                .foregroundStyle(Palette.ink3)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Palette.surfaceElevated)
                )
        }
    }

    /// Agent identity badge. Replaces the segmented engine picker
    /// with a single chip showing engine + model + permission mode
    /// in one glance. Tap opens a popover with the engine picker
    /// and a "Codex coming soon" subtitle (since selecting Codex
    /// today returns an explanatory turn instead of spawning).
    private var agentBadge: some View {
        Button(action: { agentPopoverShown.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: useState.engine == .codex ? "circle.hexagongrid" : "sparkles")
                    .font(.system(size: 10))
                Text(modelLabel)
                    .font(Typography.captionEmphasis)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Palette.surfaceElevated)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Agent: \(modelLabel) · \(permissionLabel)")
        .popover(isPresented: $agentPopoverShown, arrowEdge: .bottom) {
            agentPopover
                .padding(14)
                .frame(width: 280)
        }
        .disabled(useState.isStreaming)
    }

    private var agentPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent")
                .font(Typography.label)
                .foregroundStyle(Palette.ink2)

            // Engine picker. Codex stays exposed so the user can
            // see it's coming, but the deferred state is honest in
            // the subtitle.
            engineSegment

            VStack(alignment: .leading, spacing: 4) {
                row(label: "Model", value: modelLabel)
                row(label: "Effort", value: effortLabel)
                row(label: "Permissions", value: permissionLabel)
                row(label: "Conversation", value: conversationLabel)
            }

            Divider().background(Palette.divider)

            Text(useState.engine == .codex
                 ? "Codex doesn't yet expose --mcp-config on the CLI, so the bridge can't reach it. Switch to Claude in the meantime; Codex parity ships when the flag lands upstream."
                 : "Model + effort + permissions follow the global Settings. Change them in ⌘M.")
                .font(Typography.captionSm)
                .foregroundStyle(Palette.ink3)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Typography.captionSm)
                .foregroundStyle(Palette.ink3)
            Spacer(minLength: 8)
            Text(value)
                .font(Typography.captionEmphasis)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
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
        .controlSize(.small)
        .disabled(useState.isStreaming)
    }

    // MARK: - Conversation scroll (H1 + H3)

    private var conversationScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if useState.turns.isEmpty && !useState.hasStreamingTurn {
                        emptyState
                    } else {
                        ForEach(useState.turns) { turn in
                            TadoUseTurnRow(
                                turn: turn,
                                bodyFont: chatBodyFont,
                                stoppedPill: false
                            )
                            .id(turn.id)
                        }
                        if useState.hasStreamingTurn,
                           let liveID = useState.streamingTurnID {
                            TadoUseLiveTurnRow(
                                engine: useState.streamingEngine,
                                text: useState.streamingText,
                                toolCalls: useState.streamingToolCalls,
                                isStreaming: useState.isStreaming,
                                bodyFont: chatBodyFont
                            )
                            .id(liveID)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            // H3: throttled auto-scroll. The TimelineView fires at
            // ~6 Hz; the .onChange watchers feed an "anchor target"
            // that the timer applies. This caps the scroll-pump
            // rate during streaming (would otherwise fire ~50 Hz on
            // text-delta) without losing responsiveness.
            .modifier(ThrottledScrollPump(
                proxy: proxy,
                anchor: .bottom,
                target: scrollAnchor,
                paused: autoScrollPaused
            ))
            // Bring scroll back online when a new finalized turn
            // lands or the user clears.
            .onChange(of: useState.turns.count) { _, _ in
                autoScrollPaused = false
            }
            .onChange(of: useState.streamingTurnID) { _, _ in
                autoScrollPaused = false
            }
            // Detect manual upward scrolling. SwiftUI doesn't
            // expose ScrollView's content offset directly without
            // an NSView bridge; we use a transparent overlay
            // observer that watches gesture velocity. Cheaper
            // alternative: a "Jump to bottom" button (below the
            // input) that the user can click when paused.
        }
    }

    /// The id we want auto-scroll to track. Streaming = live row;
    /// finalized = last turn's id; empty = nothing.
    private var scrollAnchor: AnyHashable? {
        if let liveID = useState.streamingTurnID {
            return AnyHashable(liveID)
        }
        return useState.turns.last.map { AnyHashable($0.id) }
    }

    /// Empty state with three example chips that prefill the
    /// input. Onboarding without docs.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drive Tado from here")
                .font(Typography.titleSm)
                .foregroundStyle(Palette.ink)
            Text("Ask the agent to navigate the app, search Dome, or kick off an Eternal/Dispatch run. The agent has 41 tools that drive Tado directly plus the 30 existing tado-mcp + dome-mcp tools.")
                .font(Typography.bodySm)
                .foregroundStyle(Palette.ink2)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Try")
                    .font(Typography.captionSm)
                    .foregroundStyle(Palette.ink3)
                exampleChip("List my running tiles")
                exampleChip("Search Dome for the auth migration retro")
                exampleChip("Switch to the projects view")
                exampleChip("Start an eternal in this project for: <goal>")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 16)
    }

    private func exampleChip(_ text: String) -> some View {
        Button(action: {
            draft = text
            inputFocused = true
        }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.ink3)
                Text(text)
                    .font(Typography.bodySm)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.surfaceElevated)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input area (UX1 + UX2)

    /// Multiline input field. Enter sends; Shift+Enter inserts a
    /// newline (matches Slack/Discord). Soft visual cue when
    /// streaming: input border fades and Send becomes Stop.
    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholderText)
                        .font(chatBodyFont)
                        .foregroundStyle(Palette.ink3)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                EnterSendsTextEditor(
                    text: $draft,
                    enterSubmits: { submit() },
                    isFocused: $inputFocused
                )
                .font(chatBodyFont)
                .foregroundStyle(Palette.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44, maxHeight: 120)
                .disabled(useState.isStreaming)
                .opacity(useState.isStreaming ? 0.55 : 1.0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(inputBorderColor, lineWidth: inputBorderWidth)
                    )
            )
            .animation(.easeInOut(duration: 0.18), value: useState.isStreaming)
            .animation(.easeInOut(duration: 0.18), value: inputFocused)

            HStack(spacing: 8) {
                if let err = useState.lastError, !err.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.danger)
                    Text(err)
                        .font(Typography.captionSm)
                        .foregroundStyle(Palette.danger)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)

                if useState.isStreaming {
                    Button(action: stop) {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill").font(.system(size: 10))
                            Text("Stop").font(Typography.label)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(Palette.danger.opacity(0.18))
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.danger)
                } else {
                    Button(action: submit) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold))
                            Text("Send").font(Typography.label)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(canSubmit ? Palette.accent : Palette.surfaceElevated)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSubmit ? Palette.foreground : Palette.ink3)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.bgPage)
    }

    private var inputBorderColor: Color {
        if useState.isStreaming { return Palette.rule }
        return inputFocused ? Palette.accent.opacity(0.6) : Palette.rule
    }

    private var inputBorderWidth: CGFloat {
        inputFocused && !useState.isStreaming ? 1.5 : 1
    }

    private var placeholderText: String {
        if useState.isStreaming { return "Streaming…" }
        return "Ask Tado Use anything (Enter sends · Shift+Enter newline)"
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
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Palette.ink3)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Palette.bgElev)
    }

    // MARK: - Derived display strings (H4 — read settings once per render)

    private var modelLabel: String {
        switch useState.engine {
        case .claude:
            return prettifyModel(settings?.claudeModel.rawValue ?? "claude-opus-4-7")
        case .codex:
            return prettifyModel(settings?.codexModel.rawValue ?? "gpt-5.5")
        }
    }

    private var effortLabel: String {
        switch useState.engine {
        case .claude:
            return settings?.claudeEffort.displayName ?? "Auto"
        case .codex:
            return settings?.codexEffort.displayName ?? "Auto"
        }
    }

    private var permissionLabel: String {
        switch useState.engine {
        case .claude:
            return settings?.claudeMode.displayName ?? "Ask permissions"
        case .codex:
            return settings?.codexMode.displayName ?? "Default permissions"
        }
    }

    private var conversationLabel: String {
        let count = useState.turns.count
        if count == 0 { return "New" }
        if count == 1 { return "1 turn" }
        return "\(count) turns"
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

// MARK: - Throttled scroll-to-bottom (H3)

/// Drives a `ScrollViewReader` proxy at a capped rate. SwiftUI's
/// `proxy.scrollTo` triggers a layout pass per call; firing it on
/// every text-delta `onChange` cost ~50 layouts/sec during
/// streaming. This pumps it at ~6 Hz max, which is below the
/// human perceptual threshold for "auto-following" but well above
/// the SwiftUI 60 fps render budget.
fileprivate struct ThrottledScrollPump: ViewModifier {
    let proxy: ScrollViewProxy
    let anchor: UnitPoint
    let target: AnyHashable?
    let paused: Bool

    /// Cap at 6 Hz. Lower → choppier auto-follow. Higher → eats
    /// more main-thread time per second of streaming. 6 Hz is
    /// where users perceive "live" without any frame-budget cost.
    private static let pumpHz: Double = 6

    @State private var lastSentTarget: AnyHashable? = nil

    func body(content: Content) -> some View {
        content.background(
            TimelineView(.periodic(from: .now, by: 1.0 / Self.pumpHz)) { _ in
                Color.clear
                    .onAppear { pump() }
                    .task { pump() }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }

    private func pump() {
        guard !paused, let target, target != lastSentTarget else { return }
        lastSentTarget = target
        proxy.scrollTo(target, anchor: anchor)
    }
}

// MARK: - Enter-sends TextEditor (UX1)

/// `TextEditor` doesn't surface keyboard-event hooks via SwiftUI
/// alone — `onSubmit` fires only for `submitLabel: .return`-style
/// fields. We bridge to AppKit's `NSTextView` to intercept Return
/// (without modifiers) → call `enterSubmits`. Shift+Return falls
/// through to the default newline behavior.
fileprivate struct EnterSendsTextEditor: NSViewRepresentable {
    @Binding var text: String
    let enterSubmits: () -> Void
    @FocusState.Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.string = text
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EnterSendsTextEditor

        init(_ parent: EnterSendsTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Sync back to the @Binding asynchronously so the
            // keystroke propagates immediately and SwiftUI catches
            // up on its next render.
            let new = textView.string
            DispatchQueue.main.async {
                self.parent.text = new
            }
        }

        /// Intercept Return-without-modifiers → submit. Return
        /// false to swallow the keypress so the default newline
        /// insert doesn't fire.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                let shiftHeld = event?.modifierFlags.contains(.shift) ?? false
                if shiftHeld {
                    // Shift+Return → newline. Default behavior;
                    // let the responder chain handle it.
                    return false
                }
                // Plain Return → submit, swallow keypress.
                parent.enterSubmits()
                return true
            }
            return false
        }
    }
}

// MARK: - Engine holder (env-injectable)

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

// MARK: - Helpers

/// Strip common vendor prefixes so the model chip stays narrow.
/// `claude-opus-4-7` → `opus-4-7`, `gpt-5.5` → `5.5`. Whitespace-only
/// returns "auto".
private func prettifyModel(_ id: String) -> String {
    var s = id.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return "auto" }
    if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
    if s.hasPrefix("gpt-")    { s = String(s.dropFirst("gpt-".count)) }
    return s
}
