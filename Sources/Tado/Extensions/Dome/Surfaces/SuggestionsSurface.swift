import AppKit
import Foundation
import SwiftUI

/// v0.15 — Suggestions surface.
///
/// Lists every suggestion in the vault grouped by status
/// (`pending`, `applied`, `rejected`). Pending rows show `Accept`
/// and a `Show patch` disclosure with the raw patch JSON. Accepted
/// rows show their applied timestamp; rejected rows are greyed out.
///
/// Reject is intentionally absent until bt-core grows a
/// `suggestion_reject` method — for now the only mutator is
/// `suggestion_apply`. The surface still lists rejected rows so
/// agents that flip status via direct write are visible.
struct SuggestionsSurface: View {
    let domeScope: DomeScopeSelection

    @State private var suggestions: [DomeRpcClient.Suggestion] = []
    @State private var isLoading = false
    @State private var statusFilter: String = "pending"
    @State private var working = false

    private static let statusOptions: [String] = ["pending", "applied", "rejected", "all"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(
                title: "Suggestions",
                subtitle: "\(filtered.count) of \(suggestions.count) · \(domeScope.label)",
                isLoading: isLoading
            ) {
                Task { await reload() }
            }

            // Filter strip — segmented OutlineButton.small chips
            HStack(spacing: 6) {
                ForEach(Self.statusOptions, id: \.self) { option in
                    OutlineButton(
                        option.capitalized,
                        size: .small,
                        variant: statusFilter == option ? .accent : .standard,
                        action: { statusFilter = option }
                    )
                }
                Spacer()
            }
            .padding(.horizontal, DK.pageGutter)
            .padding(.vertical, 10)
            .background(Palette.bgPage)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }

            if filtered.isEmpty {
                surfaceEmpty(
                    icon: "pencil.and.list.clipboard",
                    text: suggestions.isEmpty
                        ? "No suggestions yet — agents call `dome_suggestion_create` via MCP to surface edits here."
                        : "No \(statusFilter) suggestions."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { s in
                            suggestionRow(s)
                            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
                        }
                    }
                }
            }
        }
        .background(Palette.bgPage)
        .task(id: domeScope.id) { await reload() }
    }

    private var filtered: [DomeRpcClient.Suggestion] {
        if statusFilter == "all" { return suggestions }
        return suggestions.filter { $0.status == statusFilter }
    }

    /// Flat-tabular suggestion row. Replaces the previous rounded
    /// card with a hairline-bordered structural row that reads as
    /// part of a table — leading 2 px accent stripe on pending,
    /// StatusPill, mono docId, mono caption metadata, trailing
    /// `Accept` OutlineButton.accent on pending rows.
    private func suggestionRow(_ s: DomeRpcClient.Suggestion) -> some View {
        let isPending = s.status == "pending"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusPill(s.status, variant: pillVariant(for: s.status))
                Text(s.summary.isEmpty ? "(no summary)" : s.summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(s.status == "rejected" ? Palette.ink3 : Palette.ink)
                    .lineLimit(2)
                Spacer()
                Text(s.format.uppercased())
                    .font(Font.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Palette.ink4)
            }
            HStack(spacing: 10) {
                Text(s.docId)
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                if !s.createdBy.isEmpty {
                    Text("·  by \(s.createdBy)")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
                if let ts = s.createdAt {
                    Text("·  \(Self.relative.localizedString(for: ts, relativeTo: Date()))")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
                Spacer()
                if isPending {
                    OutlineButton(
                        working ? "Applying…" : "Accept",
                        icon: "checkmark.circle",
                        size: .small,
                        variant: .accent,
                        action: { runApply(s) }
                    )
                    .disabled(working)
                }
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(s.status == "rejected" ? Palette.bgPage : Palette.bgElev)
        .overlay(alignment: .leading) {
            if isPending {
                Rectangle().fill(Palette.accent).frame(width: 2)
            }
        }
    }

    /// Map suggestion status onto the StatusPill variant scale.
    private func pillVariant(for status: String) -> StatusPill.Variant {
        switch status {
        case "pending":  return .planning
        case "applied":  return .running
        case "rejected": return .danger
        default:         return .neutral
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fetched = await Task.detached { () -> [DomeRpcClient.Suggestion] in
            DomeRpcClient.suggestionList(docID: nil, status: nil)
        }.value
        suggestions = fetched
    }

    private func runApply(_ s: DomeRpcClient.Suggestion) {
        let alert = NSAlert()
        alert.messageText = "Apply suggestion to \(s.docId)?"
        alert.informativeText = s.summary.isEmpty ? "This applies the patch and flips status to applied." : s.summary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Apply")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let id = s.id
        working = true
        Task.detached {
            _ = DomeRpcClient.suggestionApply(id: id)
            await MainActor.run { working = false }
            await reload()
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
