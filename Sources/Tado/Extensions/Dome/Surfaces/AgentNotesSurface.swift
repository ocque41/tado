import SwiftUI

/// Read-only view of every note in the vault that has agent content.
/// Agents write via the `dome-mcp` stdio bridge (`dome_note` tool);
/// this surface shows what they've written.
///
/// We deliberately don't expose an edit path here: bt-core's write
/// barrier classifies any UI edit as "user authored" and will refuse
/// writes to `agent.md`. Anything a human wants to say goes in User
/// Notes; agent output comes from agents.
///
/// Listing approach: the FFI `tado_dome_notes_list(topic=nil)` returns
/// every note. We filter to those whose `agent_content` isn't the
/// starter boilerplate. "Non-trivial content" = strictly more than
/// the 16-byte starter. Cheap heuristic, good enough until C1's
/// embeddings make a real "has agent written anything meaningful"
/// signal available.
struct AgentNotesSurface: View {
    let domeScope: DomeScopeSelection

    @State private var allNotes: [DomeRpcClient.NoteSummary] = []
    @State private var selectedID: String? = nil
    @State private var selectedDetail: DomeRpcClient.NoteDetail? = nil
    @State private var selectedTopic: String = ""
    @State private var topicDraft: String = ""
    @State private var isChoosingTopic = false
    @State private var isLoading = false
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var lastError: String? = nil
    /// P5 — view mode for the detail pane: read (edit-locked because
    /// agent.md is write-barriered), diff (snapshot at last open vs
    /// re-fetched current agent body), or together (merged listing
    /// across the active scope, identical lens to User Notes).
    /// Per-surface state — stays local per the P0 contract.
    @State private var lensMode: NoteLensMode = .edit
    /// Snapshot of the agent body at the moment the user clicked into
    /// the note. Acts as the left side of the diff lens against the
    /// current value; matches User Notes' `snapshotBody` slot.
    @State private var snapshotAgentBody: String = ""

    private var notes: [DomeRpcClient.NoteSummary] {
        guard !currentTopic.isEmpty else { return allNotes }
        return allNotes
            .filter { $0.topic == currentTopic }
            .sorted { $0.sortTimestamp > $1.sortTimestamp }
    }

    private var availableTopics: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for topic in [currentTopic] + allNotes.map(\.topic) {
            guard !topic.isEmpty, seen.insert(topic).inserted else { continue }
            ordered.append(topic)
        }
        return ordered
    }

    private var currentTopic: String {
        let trimmed = selectedTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? domeScope.defaultTopic : trimmed
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 140, idealWidth: 280, maxWidth: 420)
            detail
                .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload() }
        .alert("Delete note?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedNote() }
            }
        } message: {
            Text("This permanently removes the note and its stored knowledge.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Agent Notes")
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                topicMenu
                Button(action: startTopicSelection) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Choose or create a topic")
                Button(action: { Task { await reload() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .disabled(isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().overlay(Palette.divider)

            if isChoosingTopic {
                topicInputRow
                Divider().overlay(Palette.divider)
            }

            if let lastError {
                Text(lastError)
                    .font(Typography.micro)
                    .foregroundStyle(Palette.danger)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            if notes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notes) { note in
                            row(for: note)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .background(Palette.surfaceElevated)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No agent writes yet")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            Text("Current topic: `\(currentTopic)`")
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
            Text("Ask an agent to call `dome_note`.")
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(14)
    }

    private func row(for note: DomeRpcClient.NoteSummary) -> some View {
        let active = note.id == selectedID
        return Button(action: { select(id: note.id) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(Typography.label)
                        .foregroundStyle(active ? Palette.accent : Palette.textPrimary)
                        .lineLimit(1)
                    scopeBadge(note.ownerScope)
                    Spacer()
                    if note.agentActive == true {
                        Circle()
                            .fill(Palette.success)
                            .frame(width: 6, height: 6)
                            .help("Agent wrote here recently")
                    }
                }
                Text(subtitle(for: note))
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(active ? Palette.surfaceAccentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for note: DomeRpcClient.NoteSummary) -> String {
        guard let ts = note.updatedAt ?? note.createdAt else { return note.topic }
        return Self.rel.localizedString(for: ts, relativeTo: Date())
    }

    private var topicMenu: some View {
        Menu {
            ForEach(availableTopics, id: \.self) { topic in
                Button(topic == currentTopic ? "\(topic) ✓" : topic) {
                    activateTopic(topic)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.system(size: 10, weight: .semibold))
                Text(currentTopic)
                    .font(Typography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Palette.surfaceAccentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .help("Current topic")
    }

    private var topicInputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            TextField("Topic", text: $topicDraft)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .onSubmit { confirmTopicSelection() }
            Button(action: cancelTopicSelection) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            Button(action: confirmTopicSelection) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.surface)
    }

    private func scopeBadge(_ scope: String?) -> some View {
        Text(scope == "project" ? "Project" : "Global")
            .font(Typography.micro)
            .foregroundStyle(scope == "project" ? Palette.warning : Palette.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Palette.surfaceAccentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            lensModeBar
            Divider().overlay(Palette.divider)
            detailBody
        }
    }

    private var lensModeBar: some View {
        HStack(spacing: 10) {
            Picker("Lens", selection: $lensMode) {
                ForEach(NoteLensMode.allCases) { mode in
                    Text(mode == .edit ? "Read" : mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 160, idealWidth: 280, maxWidth: 320)
            .accessibilityLabel("Agent Notes lens mode")
            .accessibilityHint("Switch between the read-only log, the diff against the snapshot at open time, and the merged scope view.")
            Spacer()
            Text(lensMode == .edit ? "Read-only agent log" : lensMode.subtitle)
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityLabel(lensMode == .edit ? "Read-only agent log" : lensMode.subtitle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.surface)
    }

    @ViewBuilder
    private var detailBody: some View {
        switch lensMode {
        case .together:
            togetherLens
        case .diff:
            diffLens
        case .edit:
            readLens
        }
    }

    @ViewBuilder
    private var readLens: some View {
        if let d = selectedDetail {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text(d.title.isEmpty ? "Untitled" : d.title)
                            .font(Typography.display)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        if isDeleting {
                            ProgressView().controlSize(.small)
                        }
                        Button(action: { showDeleteConfirmation = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Delete note")
                        .disabled(isDeleting || !canDeleteSelected)
                    }
                    Text("topic: \(d.topic)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                    Text(d.agentContent ?? "")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Palette.textTertiary)
                Text("Pick a note to read what an agent wrote.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
        }
    }

    private var diffLens: some View {
        let current = selectedDetail?.agentContent ?? ""
        let result = DiffEngine.diff(left: snapshotAgentBody, right: current)
        let dirty = result.added + result.removed > 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                    diffRow(line)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Palette.surfaceElevated)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Text("\(result.added) added · \(result.removed) removed")
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityLabel("\(result.added) lines added, \(result.removed) lines removed")
                if dirty {
                    Button("Mark as read") {
                        snapshotAgentBody = current
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reset the diff baseline to the current agent body — useful as a 'I've read what the agent wrote' bookmark.")
                    .accessibilityLabel("Mark current agent body as read")
                }
            }
            .padding(8)
        }
    }

    private func diffRow(_ line: DiffEngine.DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(diffMarker(for: line.origin))
                .font(Typography.monoMicro)
                .foregroundStyle(diffMarkerColor(for: line.origin))
                .frame(width: 18, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(diffRowBackground(for: line.origin))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(diffRowAccessibilityLabel(for: line))
    }

    private func diffRowAccessibilityLabel(for line: DiffEngine.DiffLine) -> String {
        "\(line.origin.accessibilityPrefix) \(line.text.isEmpty ? "(empty line)" : line.text)"
    }

    private func diffMarker(for origin: DiffEngine.Origin) -> String {
        origin.markerGlyph
    }

    private func diffMarkerColor(for origin: DiffEngine.Origin) -> Color { origin.markerColor }
    private func diffRowBackground(for origin: DiffEngine.Origin) -> Color { origin.rowBackground }

    private var togetherLens: some View {
        let merged = TogetherLens.merge(notes: allNotes, scope: domeScope)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if merged.isEmpty {
                    Text("Nothing to merge in this scope.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(20)
                } else {
                    ForEach(merged) { note in
                        togetherRow(note)
                        Divider().overlay(Palette.divider)
                    }
                }
            }
        }
        .background(Palette.background)
    }

    private func togetherRow(_ note: DomeRpcClient.NoteSummary) -> some View {
        Button(action: {
            // Mirror the User Notes lens parity from sprint 21: a tap
            // on a Together row jumps back into the Read lens with the
            // note loaded so the lens isn't a read-only dead-end.
            lensMode = .edit
            select(id: note.id)
        }) {
            HStack(alignment: .top, spacing: 8) {
                scopeBadge(note.ownerScope)
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(Typography.label)
                        .foregroundStyle(Palette.textPrimary)
                    Text(note.topic)
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                if let ts = note.updatedAt ?? note.createdAt {
                    Text(Self.rel.localizedString(for: ts, relativeTo: Date()))
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(note.title.isEmpty ? "untitled note" : note.title)")
        .accessibilityHint("Switches to the Read lens and loads this note.")
    }

    private func select(id: String) {
        selectedID = id
        selectedDetail = DomeRpcClient.getNote(id: id)
        snapshotAgentBody = selectedDetail?.agentContent ?? ""
    }

    private var canDeleteSelected: Bool {
        guard let selectedID else { return false }
        guard case .project = domeScope else { return true }
        return notes.first(where: { $0.id == selectedID })?.ownerScope == "project"
    }

    private func startTopicSelection() {
        topicDraft = currentTopic
        isChoosingTopic = true
    }

    private func cancelTopicSelection() {
        topicDraft = ""
        isChoosingTopic = false
    }

    private func confirmTopicSelection() {
        guard let topic = resolvedTopicSelection(from: topicDraft) else { return }
        activateTopic(topic)
        topicDraft = ""
        isChoosingTopic = false
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fetched = await Task.detached { () -> [DomeRpcClient.NoteSummary]? in
            DomeRpcClient.listNotes(topic: nil, limit: 500, domeScope: domeScope)
        }.value
        if let fetched {
            // Simple heuristic for "agent has written something": use
            // agent_active flag when available, fallback to showing
            // every doc (users can browse). Deeper filter (inspect
            // agent_content length) would require a second FFI call
            // per doc — not worth it; the Diff lens already gives
            // users a way to see what the agent wrote since they
            // opened the note.
            allNotes = fetched.sorted { $0.sortTimestamp > $1.sortTimestamp }
            selectedTopic = preferredTopic(from: fetched)
            if let selectedID, !notes.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                self.selectedDetail = nil
            } else if let selectedID {
                // Re-fetch the selected note's content so the Diff
                // lens can pick up new agent writes without forcing
                // the user to re-select. The snapshot stays put —
                // it's the diff baseline.
                let refreshed = await Task.detached { DomeRpcClient.getNote(id: selectedID) }.value
                if let refreshed {
                    self.selectedDetail = refreshed
                }
            }
        }
    }

    private func deleteSelectedNote() async {
        guard let selectedID, canDeleteSelected else { return }
        isDeleting = true
        lastError = nil
        defer { isDeleting = false }

        let deleted = await Task.detached { DomeRpcClient.deleteNote(id: selectedID) }.value
        if deleted {
            self.selectedID = nil
            self.selectedDetail = nil
            await reload()
        } else {
            lastError = "Delete failed. Dome rejected the request."
        }
    }

    private func activateTopic(_ topic: String) {
        selectedTopic = topic
        if let selectedID, !notes.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
            self.selectedDetail = nil
        }
    }

    private func canonicalTopic(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return availableTopics.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) ?? trimmed
    }

    private func resolvedTopicSelection(from raw: String) -> String? {
        guard let topic = canonicalTopic(from: raw) else { return nil }
        if availableTopics.contains(where: { $0.caseInsensitiveCompare(topic) == .orderedSame }) {
            return topic
        }
        return DomeRpcClient.createTopic(topic)
    }

    private func preferredTopic(from notes: [DomeRpcClient.NoteSummary]) -> String {
        if let match = notes.map(\.topic).first(where: { $0.caseInsensitiveCompare(currentTopic) == .orderedSame }) {
            return match
        }
        if let match = notes.map(\.topic).first(where: { $0.caseInsensitiveCompare(domeScope.defaultTopic) == .orderedSame }) {
            return match
        }
        return notes.first?.topic ?? domeScope.defaultTopic
    }
}
