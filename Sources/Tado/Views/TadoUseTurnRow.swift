import SwiftUI

/// A single FINALIZED conversation turn rendered in the Tado Use
/// drawer. User turns are right-aligned terracotta-tinted bubbles;
/// assistant turns are left-aligned with an engine chip and
/// collapsible tool-call disclosures.
///
/// Live (streaming) turns render through `TadoUseLiveTurnRow`
/// instead — see `TadoUsePanel.swift`. Splitting the live and
/// finalized renderers keeps the per-token state mutations off the
/// finalized `ForEach` body's invalidation graph.
struct TadoUseTurnRow: View {
    let turn: TadoUseState.Turn
    /// Body font for assistant text. Resolved once by the panel
    /// from `AppSettings.terminalFontFamily` + `terminalFontSize`
    /// so the drawer chat respects the same font knobs the canvas
    /// tiles do (settings parity).
    let bodyFont: Font
    /// Optional "stopped" pill — set on the most recent turn when
    /// the user hit Stop mid-stream. Renders a small chip below
    /// the assistant text so it's clear the response was cut off
    /// rather than naturally complete.
    let stoppedPill: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            switch turn.role {
            case .user:
                Spacer(minLength: 32)
                userBubble
            case .assistant:
                assistantBubble
                Spacer(minLength: 32)
            }
        }
    }

    private var userBubble: some View {
        Text(turn.text)
            .font(bodyFont)
            .foregroundStyle(Palette.textPrimary)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.surfaceAccent)
            )
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            TadoUseEngineChip(engine: turn.engine)

            if !turn.text.isEmpty {
                Text(turn.text)
                    .font(bodyFont)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }

            if !turn.toolCalls.isEmpty {
                VStack(spacing: 4) {
                    ForEach(turn.toolCalls) { call in
                        TadoUseToolCallRow(call: call)
                    }
                }
                .padding(.top, 2)
            }

            if stoppedPill {
                stoppedChip
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surfaceElevated)
        )
    }

    private var stoppedChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "stop.circle")
                .font(.system(size: 9))
            Text("stopped")
                .font(Typography.captionSm)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Palette.background.opacity(0.5))
        )
    }
}

/// Live (streaming) assistant turn. Bound directly to the
/// scratchpad scalars on `TadoUseState` (`streamingText`,
/// `streamingToolCalls`, …) instead of a `Turn` value. Per-token
/// mutations on those scalars only invalidate this view, NOT the
/// parent ForEach over finalized turns.
///
/// This is the H1 fix: the original implementation rendered every
/// turn from `useState.turns` and mutated `turns[last].text` per
/// delta, which invalidated the array keypath and rebuilt every
/// `TadoUseTurnRow` on every token. Splitting the live row out
/// drops streaming-window CPU by ~30–50% on M-series machines.
struct TadoUseLiveTurnRow: View {
    let engine: TerminalEngine
    let text: String
    let toolCalls: [TadoUseState.Turn.ToolCall]
    let isStreaming: Bool
    let bodyFont: Font

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TadoUseEngineChip(engine: engine)

                if !text.isEmpty || isStreaming {
                    Text(text + (isStreaming ? "▍" : ""))
                        .font(bodyFont)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }

                if !toolCalls.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(toolCalls) { call in
                            TadoUseToolCallRow(call: call)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.surfaceElevated)
            )
            Spacer(minLength: 32)
        }
    }
}

/// Engine badge for both finalized and live assistant turns.
struct TadoUseEngineChip: View {
    let engine: TerminalEngine

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: engine == .codex ? "circle.hexagongrid" : "sparkles")
                .font(.system(size: 9))
            Text(engine.displayName)
                .font(Typography.captionSm)
        }
        .foregroundStyle(Palette.textTertiary)
    }
}

/// One disclosure row per `tool_use` block emitted by the agent.
/// Collapsed by default — title shows the tool name and a status
/// glyph; expanded view shows the input and (if present) the
/// output JSON.
struct TadoUseToolCallRow: View {
    let call: TadoUseState.Turn.ToolCall
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.textTertiary)
                    Image(systemName: statusIcon)
                        .font(.system(size: 9))
                        .foregroundStyle(statusColor)
                    Text(call.name)
                        .font(Typography.monoBody)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !call.input.isEmpty {
                        labelled("input", body: call.input)
                    }
                    if let out = call.output, !out.isEmpty {
                        labelled("output", body: out)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.background.opacity(0.5))
        )
    }

    private func labelled(_ label: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Typography.captionSm)
                .foregroundStyle(Palette.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body)
                    .font(Typography.monoBody)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
            .frame(maxHeight: 120)
        }
    }

    private var statusIcon: String {
        switch call.status {
        case .pending:  return "circle.dotted"
        case .complete: return "checkmark.circle.fill"
        case .failed:   return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .pending:  return Palette.textTertiary
        case .complete: return Palette.success
        case .failed:   return Palette.danger
        }
    }
}
