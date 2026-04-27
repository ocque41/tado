import SwiftUI

/// Dome's front door. Free-text query across the active scope, ranked
/// by `SearchEngine`. Selecting a hit deep-links into the surface that
/// owns it (User Notes / Agent Notes / Knowledge) — the deep-link
/// machinery lands in P6; for now selecting a row reveals the note's
/// metadata in a detail panel.
///
/// Cross-surface state (the query string, the active scope) lives on
/// `DomeAppState` so the search bar in P6's hotkey overlay can read
/// from the same source.
struct SearchSurface: View {
    let domeScope: DomeScopeSelection

    @Environment(DomeAppState.self) private var domeState

    @State private var hits: [SearchEngine.Scored] = []
    @State private var lastError: String? = nil
    @State private var lastLatencyMs: Double = 0
    @State private var selectedID: String? = nil
    /// 100 ms keystroke debounce — fast typers shouldn't fire one
    /// `tado_dome_notes_list` FFI call per character. The cancelled
    /// task path is fine because `runQuery()` is idempotent.
    @State private var debounceTask: Task<Void, Never>? = nil
    @FocusState private var queryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            queryBar
            Divider().overlay(Palette.divider)
            HSplitView {
                resultsColumn
                    .frame(minWidth: 160, idealWidth: 360, maxWidth: 520)
                detailPanel
                    .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .onChange(of: domeState.searchQuery) { _, _ in scheduleQuery() }
        .task(id: domeScope.id) {
            // `.task(id:)` re-fires when the scope identifier changes,
            // which a `.onChange(of: domeScope)` misses if SwiftUI
            // recreates the surface in place. Belt-and-braces with
            // `.onAppear` for first-launch behaviour.
            runQuery()
        }
        .onChange(of: domeState.searchFocusRequest) { _, _ in
            queryFieldFocused = true
        }
        .onAppear {
            // `.task(id: domeScope.id)` above already fires on the
            // first appearance, so we skip the duplicate `runQuery()`
            // call here — pulling focus is the only thing that needs
            // the appear hook. Mirrors macOS Spotlight: opening the
            // panel lands you typing-ready.
            queryFieldFocused = true
        }
    }

    @ViewBuilder
    private var queryBar: some View {
        @Bindable var state = domeState
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            TextField("Search the second brain", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(Typography.label)
                .foregroundStyle(Palette.textPrimary)
                .submitLabel(.search)
                .focused($queryFieldFocused)
                .onSubmit { runQuery() }
                .accessibilityLabel("Search query")
            if !domeState.searchQuery.isEmpty {
                Button(action: { domeState.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear query")
                .accessibilityLabel("Clear search query")
                .accessibilityHint("Empties the search field and clears results.")
            }
            if lastLatencyMs > 0 {
                Text("\(hits.count) hits · \(Int(lastLatencyMs)) ms")
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityLabel("\(hits.count) results in \(Int(lastLatencyMs)) milliseconds")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.surface)
        // The TextField, clear button, and result-summary text each
        // carry their own accessibility labels — wrapping the row in
        // a `.contain` container groups them as a single navigable
        // landmark labelled "Search Dome", instead of the previous
        // single-label override that hid the inner controls.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search Dome")
    }

    private var resultsColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if hits.isEmpty {
                    placeholderRow
                } else {
                    ForEach(hits, id: \.note.id) { hit in
                        resultRow(hit)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Palette.surfaceElevated)
    }

    private var placeholderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if domeState.searchQuery.isEmpty {
                Text("Type to search across the active scope.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
            } else if let lastError {
                Text(lastError)
                    .font(Typography.label)
                    .foregroundStyle(Palette.danger)
            } else {
                Text("No matches.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func resultRow(_ hit: SearchEngine.Scored) -> some View {
        let active = hit.note.id == selectedID
        return Button(action: { selectedID = hit.note.id }) { resultRowLabel(hit, active: active) }
            .buttonStyle(.plain)
            .accessibilityLabel("Result: \(hit.note.title.isEmpty ? "untitled" : hit.note.title)")
            .accessibilityValue("score \(String(format: "%.1f", hit.score))")
            .accessibilityHint("Shows metadata in the detail pane.")
            .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    private func resultRowLabel(_ hit: SearchEngine.Scored, active: Bool) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(hit.note.title.isEmpty ? "(untitled)" : hit.note.title)
                        .font(Typography.label)
                        .foregroundStyle(active ? Palette.accent : Palette.textPrimary)
                    Spacer()
                    Text(String(format: "%.1f", hit.score))
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
                Text(hit.note.topic)
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Palette.surfaceAccent : Color.clear)
            )
            .contentShape(Rectangle())
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = selectedID, let hit = hits.first(where: { $0.note.id == id }) {
                Text(hit.note.title.isEmpty ? "(untitled)" : hit.note.title)
                    .font(Typography.displayXL)
                    .foregroundStyle(Palette.textPrimary)
                Text("Topic · \(hit.note.topic)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                if let updated = hit.note.updatedAt {
                    Text("Updated \(updated.formatted(.dateTime.month().day().hour().minute()))")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
                Text("Score \(String(format: "%.2f", hit.score))")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            } else {
                Text("Pick a result to see metadata.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search result detail")
    }

    private func scheduleQuery() {
        debounceTask?.cancel()
        // Bypass the debounce when the field has just been emptied
        // (e.g. via the X-clear button) — clearing should feel
        // instant; debouncing here only delays the empty-state UI.
        let trimmed = domeState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            runQuery()
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            runQuery()
        }
    }

    private func runQuery() {
        let q = domeState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            selectedID = nil
            lastError = nil
            lastLatencyMs = 0
            return
        }
        // Capture the trimmed query AND scope id as the generation
        // label; if a newer keystroke or a scope change supersedes
        // this call while the FFI is in flight, we discard the stale
        // result on landing.
        let scope = domeScope
        let scopeID = scope.id
        let started = Date()
        Task { @MainActor in
            let result = await Task.detached { () -> [SearchEngine.Scored]? in
                DomeRpcClient.search(query: q, domeScope: scope, limit: 50)
            }.value
            // Bail if either the query OR the scope has moved on —
            // keeps the latency text honest and stops a slow FFI call
            // from clobbering a fresher result set.
            let queryStillCurrent = domeState.searchQuery
                .trimmingCharacters(in: .whitespacesAndNewlines) == q
            let scopeStillCurrent = domeScope.id == scopeID
            guard queryStillCurrent && scopeStillCurrent else { return }
            if let result {
                hits = result
                lastError = nil
                if let id = selectedID, !result.contains(where: { $0.note.id == id }) {
                    selectedID = nil
                }
            } else {
                hits = []
                selectedID = nil
                lastError = "Dome daemon offline."
            }
            lastLatencyMs = Date().timeIntervalSince(started) * 1000
        }
    }
}
