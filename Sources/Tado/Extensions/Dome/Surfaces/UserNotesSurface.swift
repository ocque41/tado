import SwiftUI

/// The User Notes surface — primary write tab of the Dome window.
///
/// Left column: chronological list of every note in topic `"user"`
/// sorted by `updated_at` desc. Right column: a `TextEditor` bound
/// to the selected note's user-content.
///
/// Write path: first save on a never-saved note creates a new scoped
/// doc; later saves update `user.md` in place and rename the note when
/// the title changes. Body writes still use replace mode so editing
/// behaves like a normal text editor, and bt-core refreshes FTS in the
/// same transaction that writes the file.
///
/// No live-sync with agent edits: if a Claude session happens to be
/// writing to the same doc's `agent.md` via dome-mcp, the two sides
/// don't conflict (separate files) and we don't refresh the Swift
/// view until the user navigates away and back. Good enough for v0.11.
struct UserNotesSurface: View {
    let domeScope: DomeScopeSelection

    @State private var allNotes: [DomeRpcClient.NoteSummary] = []
    @State private var selectedID: String? = nil
    @State private var selectedTopic: String = ""
    @State private var topicDraft: String = ""
    @State private var editingTitle: String = ""
    @State private var loadedTitle: String = ""
    @State private var editingBody: String = ""
    @State private var isCreating: Bool = false
    @State private var isSaving: Bool = false
    @State private var isDeleting: Bool = false
    @State private var isChoosingTopic: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var lastError: String? = nil
    /// P4 — view mode for the detail pane: edit, diff (saved vs
    /// in-progress), or together (read-only merged across scopes).
    /// Per-surface state — stays local, doesn't lift to `DomeAppState`
    /// per the P0 contract.
    @State private var lensMode: NoteLensMode = .edit
    /// Snapshot of the body at last load/save. Acts as the left side
    /// of the diff lens against the live `editingBody`.
    @State private var snapshotBody: String = ""

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
        .task(id: domeScope.id) {
            await reload()
        }
        .alert("Delete note?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedNote() }
            }
        } message: {
            Text("This permanently removes the note and its stored knowledge.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(domeScope == .global ? "User Notes" : "Project Notes")
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                topicMenu
                Button(action: startNewNote) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("New note in a topic")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().overlay(Palette.divider)

            if isChoosingTopic {
                topicInputRow
                Divider().overlay(Palette.divider)
            }

            if notes.isEmpty && !isCreating {
                emptySidebar
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isCreating {
                            sidebarRow(id: nil, title: editingTitle.isEmpty ? "New note" : editingTitle, subtitle: "drafting…")
                        }
                        ForEach(notes) { note in
                            sidebarRow(id: note.id, title: note.title, subtitle: sidebarSubtitle(for: note))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .background(Palette.surfaceElevated)
    }

    private var emptySidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No notes yet")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            Text("Tap + to pick a topic and start one.")
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(14)
    }

    private func sidebarRow(id: String?, title: String, subtitle: String) -> some View {
        let active = id == selectedID || (id == nil && isCreating && selectedID == nil)
        return Button(action: { select(id: id) }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(Typography.label)
                        .foregroundStyle(active ? Palette.accent : Palette.textPrimary)
                        .lineLimit(1)
                    if let id, let note = notes.first(where: { $0.id == id }) {
                        scopeBadge(note.ownerScope)
                    }
                }
                Text(subtitle)
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

    private func sidebarSubtitle(for note: DomeRpcClient.NoteSummary) -> String {
        guard let ts = note.updatedAt ?? note.createdAt else { return note.topic }
        return Self.relativeFormatter.localizedString(for: ts, relativeTo: Date())
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
                .onSubmit { confirmTopicSelectionForNewNote() }
            Button(action: cancelTopicSelection) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            Button(action: confirmTopicSelectionForNewNote) {
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if lensMode == .together {
            VStack(alignment: .leading, spacing: 0) {
                lensModeBar
                Divider().overlay(Palette.divider)
                togetherLens
            }
        } else if selectedID == nil && !isCreating {
            placeholder
        } else {
            VStack(alignment: .leading, spacing: 0) {
                lensModeBar
                Divider().overlay(Palette.divider)
                titleBar
                Divider().overlay(Palette.divider)
                if lensMode == .diff {
                    diffLens
                } else {
                    TextEditor(text: $editingBody)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Palette.background)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .disabled(!canEditSelected)
                    if let err = lastError {
                        errorBanner(err)
                    }
                    saveBar
                }
            }
        }
    }

    private var lensModeBar: some View {
        HStack(spacing: 10) {
            Picker("Lens", selection: $lensMode) {
                ForEach(NoteLensMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 160, idealWidth: 280, maxWidth: 320)
            .accessibilityLabel("User Notes lens mode")
            .accessibilityHint("Switch between the editor, the diff against the saved snapshot, and the merged scope view.")
            Spacer()
            Text(lensMode.subtitle)
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityLabel(lensMode.subtitle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.surface)
    }

    private var diffLens: some View {
        let result = DiffEngine.diff(left: snapshotBody, right: editingBody)
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
                    Button("Use current as baseline") {
                        snapshotBody = editingBody
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reset the diff baseline to the current editor contents.")
                    .accessibilityLabel("Reset diff baseline to current editor contents")
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

    /// Together lens — read-only merged view across the active scope.
    /// Scope filtering is delegated to `TogetherLens.merge` so the
    /// `includeGlobalData` rule is enforced by the same code the
    /// acceptance harness exercises.
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
            // Jump back into Edit mode with this row's note loaded.
            // Without this, Together is a read-only dead-end — the
            // user can see notes but can't act on them.
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
                    Text(Self.relativeFormatter.localizedString(for: ts, relativeTo: Date()))
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
        .accessibilityHint("Switches to the Edit lens and loads this note.")
    }


    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Title", text: $editingTitle)
                    .textFieldStyle(.plain)
                    .font(Typography.displaySm)
                    .foregroundStyle(Palette.textPrimary)
                if isSaving || isDeleting {
                    ProgressView().controlSize(.small)
                }
                Button(action: { showDeleteConfirmation = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Delete note")
                .disabled(isCreating || selectedID == nil || isSaving || isDeleting || !canDeleteSelected)
            }
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                Text(currentTopic)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceAccentSoft)
    }

    private var saveBar: some View {
        HStack {
            Spacer()
            Button("Discard") {
                discardChanges()
            }
            .disabled(isSaving || isDeleting || (!isCreating && selectedID == nil))
            Button("Save") {
                Task { await save() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isSaving || isDeleting || !canEditSelected || editingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Palette.surfaceElevated)
    }

    private var canEditSelected: Bool {
        guard !isCreating, let selectedID else { return true }
        guard case .project = domeScope else { return true }
        return notes.first(where: { $0.id == selectedID })?.ownerScope == "project"
    }

    private var canDeleteSelected: Bool {
        guard let selectedID, !isCreating else { return false }
        guard case .project = domeScope else { return true }
        return notes.first(where: { $0.id == selectedID })?.ownerScope == "project"
    }

    private var placeholder: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("Pick a note or start a new one.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }

    // MARK: - Actions

    private func select(id: String?) {
        lastError = nil
        guard let id else {
            selectedID = nil
            isCreating = true
            return
        }
        isCreating = false
        isChoosingTopic = false
        selectedID = id
        // Fetch full content.
        if let detail = DomeRpcClient.getNote(id: id) {
            editingTitle = detail.title
            loadedTitle = detail.title
            editingBody = detail.userContent ?? ""
            snapshotBody = editingBody
            selectedTopic = detail.topic
        } else {
            lastError = "Couldn't load the note."
            editingTitle = ""
            loadedTitle = ""
            editingBody = ""
            snapshotBody = ""
        }
    }

    private func startNewNote() {
        topicDraft = currentTopic
        isChoosingTopic = true
        lastError = nil
        showDeleteConfirmation = false
        loadedTitle = ""
    }

    private func cancelTopicSelection() {
        isChoosingTopic = false
        topicDraft = ""
    }

    private func confirmTopicSelectionForNewNote() {
        guard let topic = resolvedTopicSelection(from: topicDraft) else {
            lastError = "Topic can't be empty."
            return
        }
        activateTopic(topic)
        selectedID = nil
        isCreating = true
        editingTitle = ""
        editingBody = ""
        lastError = nil
        isChoosingTopic = false
        topicDraft = ""
    }

    private func discardChanges() {
        if isCreating {
            isCreating = false
            editingTitle = ""
            loadedTitle = ""
            editingBody = ""
        } else if let id = selectedID {
            select(id: id)
        }
    }

    private func save() async {
        let trimmedTitle = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        isSaving = true
        lastError = nil
        defer { isSaving = false }

        let body = editingBody
        if isCreating || selectedID == nil {
            let targetTopic = currentTopic
            let targetScope = domeScope
            let savedID = await Task.detached { () -> String? in
                DomeRpcClient.writeNote(
                    scope: .user,
                    topic: targetTopic,
                    title: trimmedTitle,
                    body: body,
                    domeScope: targetScope,
                    knowledgeKind: "knowledge"
                )
            }.value

            if let savedID {
                isCreating = false
                selectedID = savedID
                loadedTitle = trimmedTitle
                // Post-save the on-disk body equals the editor body;
                // refresh the diff baseline so the Diff lens shows
                // "no changes" instead of diffs against the old load.
                snapshotBody = body
                await reload()
            } else {
                lastError = "Save failed. Dome rejected the request."
            }
            return
        }

        guard let selectedID else {
            lastError = "Save failed. Missing note id."
            return
        }

        let contentUpdated = await Task.detached {
            DomeRpcClient.updateUserNote(id: selectedID, body: body)
        }.value
        guard contentUpdated else {
            lastError = "Save failed. Dome rejected the request."
            return
        }
        // Body just saved — make it the new diff baseline.
        snapshotBody = body

        if trimmedTitle != loadedTitle {
            let renamed = await Task.detached {
                DomeRpcClient.renameNoteTitle(id: selectedID, title: trimmedTitle)
            }.value
            guard renamed else {
                await reload()
                select(id: selectedID)
                lastError = "Body saved, but title update failed."
                return
            }
            loadedTitle = trimmedTitle
        }

        await reload()
    }

    private func deleteSelectedNote() async {
        guard let selectedID, canDeleteSelected else { return }
        isDeleting = true
        lastError = nil
        defer { isDeleting = false }

        let deleted = await Task.detached { DomeRpcClient.deleteNote(id: selectedID) }.value
        if deleted {
            self.selectedID = nil
            self.editingTitle = ""
            self.loadedTitle = ""
            self.editingBody = ""
            self.isCreating = false
            await reload()
        } else {
            lastError = "Delete failed. Dome rejected the request."
        }
    }

    private func reload() async {
        let scope = domeScope
        let fetched = await Task.detached { () -> [DomeRpcClient.NoteSummary]? in
            DomeRpcClient.listNotes(topic: nil, limit: 500, domeScope: scope)
        }.value
        if let fetched {
            allNotes = fetched.sorted { $0.sortTimestamp > $1.sortTimestamp }
            selectedTopic = preferredTopic(from: fetched)
            if let selectedID, !notes.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                if !isCreating {
                    editingTitle = ""
                    editingBody = ""
                }
            }
        }
    }

    private func activateTopic(_ topic: String) {
        selectedTopic = topic
        isChoosingTopic = false
        if !notes.contains(where: { $0.id == selectedID }) {
            selectedID = nil
            if !isCreating {
                editingTitle = ""
                editingBody = ""
            }
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
