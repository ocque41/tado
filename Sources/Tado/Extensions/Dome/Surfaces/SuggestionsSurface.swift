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
            Divider().overlay(Palette.divider)
            HStack(spacing: 6) {
                ForEach(Self.statusOptions, id: \.self) { option in
                    Button {
                        statusFilter = option
                    } label: {
                        Text(option.capitalized)
                            .font(Typography.monoCaption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusFilter == option ? Palette.surfaceAccentSoft : Palette.surface)
                            .foregroundStyle(statusFilter == option ? Palette.accent : Palette.textSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().overlay(Palette.divider)
            if filtered.isEmpty {
                surfaceEmpty(
                    icon: "pencil.and.list.clipboard",
                    text: suggestions.isEmpty
                        ? "No suggestions yet — agents call `dome_suggestion_create` via MCP to surface edits here."
                        : "No \(statusFilter) suggestions."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filtered) { s in
                            suggestionCard(s)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload() }
    }

    private var filtered: [DomeRpcClient.Suggestion] {
        if statusFilter == "all" { return suggestions }
        return suggestions.filter { $0.status == statusFilter }
    }

    private func suggestionCard(_ s: DomeRpcClient.Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                statusBadge(s.status)
                Text(s.summary.isEmpty ? "(no summary)" : s.summary)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(s.format)
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
            HStack(spacing: 8) {
                Text(s.docId)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                if !s.createdBy.isEmpty {
                    Text("by \(s.createdBy)")
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
                if let ts = s.createdAt {
                    Text(Self.relative.localizedString(for: ts, relativeTo: Date()))
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                if s.status == "pending" {
                    Button(working ? "Applying…" : "Accept") {
                        runApply(s)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                }
            }
        }
        .padding(12)
        .background(s.status == "rejected" ? Palette.surface.opacity(0.6) : Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusBadge(_ status: String) -> some View {
        let color: Color
        switch status {
        case "pending": color = Palette.warning
        case "applied": color = Palette.success
        case "rejected": color = Palette.danger
        default: color = Palette.textTertiary
        }
        return Text(status.capitalized)
            .font(Typography.micro)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.surfaceAccentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
