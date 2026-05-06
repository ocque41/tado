import SwiftUI

/// A single conversation turn rendered in the Tado Use drawer.
/// User turns are right-aligned terracotta-tinted bubbles;
/// assistant turns are left-aligned with a model-/engine- chip,
/// streaming caret while the turn is mid-flight, and collapsible
/// tool-call disclosure rows nested beneath the text.
struct TadoUseTurnRow: View {
    let turn: TadoUseState.Turn
    let isStreaming: Bool

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

    // MARK: - User bubble

    private var userBubble: some View {
        Text(turn.text)
            .font(Typography.body)
            .foregroundStyle(Palette.textPrimary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Palette.surfaceAccent)
            )
    }

    // MARK: - Assistant bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            engineChip

            if !turn.text.isEmpty || isStreaming {
                Text(turn.text + (isStreaming ? "▍" : ""))
                    .font(Typography.body)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.surfaceElevated)
        )
    }

    private var engineChip: some View {
        HStack(spacing: 4) {
            Image(systemName: turn.engine == .codex ? "circle.hexagongrid" : "sparkles")
                .font(.system(size: 9))
            Text(turn.engine.rawValue)
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
    let call: TadoUseState.ToolCall
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
            RoundedRectangle(cornerRadius: 4)
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
