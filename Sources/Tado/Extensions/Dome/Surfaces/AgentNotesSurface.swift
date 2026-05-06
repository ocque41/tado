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
                .frame(minWidth: 200, idealWidth: 300, maxWidth: 420)
            detail
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.bgPage)
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
            VStack(alignment: .leading, spacing: 8) {
                OverlineLabel("Agent notes")
                HStack(spacing: 6) {
                    topicMenu
                    Spacer(minLength: 4)
                    OutlineButton(
                        icon: "plus",
                        size: .small,
                        variant: .accent,
                        action: startTopicSelection
                    )
                    .help("Choose or create a topic")
                    OutlineButton(
                        icon: isLoading ? "hourglass" : "arrow.clockwise",
                        size: .small,
                        variant: .standard,
                        action: { Task { await reload() } }
                    )
                    .help("Refresh")
                    .disabled(isLoading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)

            if isChoosingTopic {
                topicInputRow
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }

            if let lastError {
                Text(lastError)
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
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
                            Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .background(Palette.bgElev)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No agent writes yet")
                .font(Typography.caption)
                .foregroundStyle(Palette.ink2)
            Text("Current topic: `\(currentTopic)`")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
            Text("Ask an agent to call `dome_note`.")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
        }
        .padding(14)
    }

    private func row(for note: DomeRpcClient.NoteSummary) -> some View {
        let active = note.id == selectedID
        return Button(action: { select(id: note.id) }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Palette.ink : Palette.ink2)
                        .lineLimit(1)
                    Spacer()
                    if note.agentActive == true {
                        Circle()
                            .fill(Palette.green)
                            .frame(width: 6, height: 6)
                            .help("Agent wrote here recently")
                    }
                    scopeBadge(note.ownerScope)
                }
                Text(subtitle(for: note))
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(active ? Palette.bgRowHi : Color.clear)
            .overlay(alignment: .leading) {
                if active {
                    Rectangle().fill(Palette.accent).frame(width: 2)
                }
            }
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
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .menuStyle(.borderlessButton)
        .help("Current topic")
    }

    private var topicInputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink4)
            TextField("Topic", text: $topicDraft)
                .textFieldStyle(.plain)
                .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .onSubmit { confirmTopicSelection() }
            OutlineButton(icon: "xmark", size: .small, variant: .ghost, action: cancelTopicSelection)
            OutlineButton(icon: "arrow.right.circle", size: .small, variant: .accent, action: confirmTopicSelection)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.bgPage)
    }

    private func scopeBadge(_ scope: String?) -> some View {
        StatusPill(
            scope == "project" ? "project" : "global",
            variant: scope == "project" ? .review : .draft
        )
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
            detailBody
        }
    }

    private var lensModeBar: some View {
        HStack(spacing: 6) {
            ForEach(NoteLensMode.allCases) { mode in
                OutlineButton(
                    mode == .edit ? "Read" : mode.label,
                    size: .small,
                    variant: lensMode == mode ? .accent : .standard,
                    action: { lensMode = mode }
                )
            }
            Spacer()
            Text(lensMode == .edit ? "Read-only agent log" : lensMode.subtitle)
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .accessibilityLabel(lensMode == .edit ? "Read-only agent log" : lensMode.subtitle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
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
                            .font(.system(size: 22, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        if isDeleting {
                            ProgressView().controlSize(.small)
                                .tint(Palette.accent)
                        }
                        OutlineButton(
                            icon: "trash",
                            size: .small,
                            variant: .danger,
                            action: { showDeleteConfirmation = true }
                        )
                        .help("Delete note")
                        .disabled(isDeleting || !canDeleteSelected)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "number")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.ink4)
                        Text(d.topic)
                            .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.ink3)
                    }
                    Text(d.agentContent ?? "")
                        .font(Font.system(size: 12.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, DK.pageGutter)
                .padding(.vertical, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.bgPage)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Palette.ink4)
                    Text("Pick a note to read what an agent wrote")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                Text("Agent writes land via the dome-mcp `dome_note` tool. The write barrier blocks UI edits to `agent.md`, so this surface is read-only by design.")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: 540, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("AGENT NOTES  ·  read-only  ·  diff lens shows changes since you opened this note")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Palette.rule).frame(height: 1).padding(.horizontal, -2)
                    }
            }
            .padding(.horizontal, DK.pageGutter)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.bgPage)
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
        .background(Palette.bgElev)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Text("\(result.added) added · \(result.removed) removed")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                    .accessibilityLabel("\(result.added) lines added, \(result.removed) lines removed")
                if dirty {
                    OutlineButton(
                        "Mark as read",
                        size: .small,
                        variant: .ghost,
                        action: { snapshotAgentBody = current }
                    )
                    .help("Reset the diff baseline to the current agent body — useful as a 'I've read what the agent wrote' bookmark.")
                    .accessibilityLabel("Mark current agent body as read")
                }
            }
            .padding(10)
        }
    }

    private func diffRow(_ line: DiffEngine.DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(diffMarker(for: line.origin))
                .font(Typography.monoMicro)
                .foregroundStyle(diffMarkerColor(for: line.origin))
                .frame(width: 18, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink)
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
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Palette.ink3)
                        .padding(20)
                } else {
                    ForEach(merged) { note in
                        togetherRow(note)
                        Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                    }
                }
            }
        }
        .background(Palette.bgPage)
    }

    private func togetherRow(_ note: DomeRpcClient.NoteSummary) -> some View {
        Button(action: {
            lensMode = .edit
            select(id: note.id)
        }) {
            HStack(alignment: .top, spacing: 10) {
                scopeBadge(note.ownerScope)
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title.isEmpty ? "Untitled" : note.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(note.topic)
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
                Spacer()
                if let ts = note.updatedAt ?? note.createdAt {
                    Text(Self.rel.localizedString(for: ts, relativeTo: Date()))
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
            }
            .padding(.horizontal, DK.pageGutter)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgElev)
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
