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
                .frame(minWidth: 200, idealWidth: 300, maxWidth: 420)
            detail
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.bgPage)
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

    /// Sidebar — section-rail-style: overline + topic dropdown +
    /// "New" outline button as a header row, then flat-tabular note
    /// rows below with a leading 2 px accent stripe on the active
    /// row.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                OverlineLabel(domeScope == .global ? "User notes" : "Project notes")
                HStack(spacing: 6) {
                    topicMenu
                    Spacer(minLength: 4)
                    OutlineButton(
                        "New",
                        icon: "plus",
                        size: .small,
                        variant: .accent,
                        action: startNewNote
                    )
                    .help("New note in a topic")
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

            if notes.isEmpty && !isCreating {
                emptySidebar
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isCreating {
                            sidebarRow(id: nil, title: editingTitle.isEmpty ? "New note" : editingTitle, subtitle: "drafting…")
                            Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                        }
                        ForEach(notes) { note in
                            sidebarRow(id: note.id, title: note.title, subtitle: sidebarSubtitle(for: note))
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

    private var emptySidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No notes yet")
                .font(Typography.caption)
                .foregroundStyle(Palette.ink2)
            Text("Tap + to pick a topic and start one.")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
        }
        .padding(14)
    }

    private func sidebarRow(id: String?, title: String, subtitle: String) -> some View {
        let active = id == selectedID || (id == nil && isCreating && selectedID == nil)
        return Button(action: { select(id: id) }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Palette.ink : Palette.ink2)
                        .lineLimit(1)
                    Spacer()
                    if let id, let note = notes.first(where: { $0.id == id }) {
                        scopeBadge(note.ownerScope)
                    }
                }
                Text(subtitle)
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
                .onSubmit { confirmTopicSelectionForNewNote() }
            OutlineButton(icon: "xmark", size: .small, variant: .ghost, action: cancelTopicSelection)
            OutlineButton(icon: "arrow.right.circle", size: .small, variant: .accent, action: confirmTopicSelectionForNewNote)
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
                togetherLens
            }
        } else if selectedID == nil && !isCreating {
            placeholder
        } else {
            VStack(alignment: .leading, spacing: 0) {
                lensModeBar
                titleBar
                if lensMode == .diff {
                    diffLens
                } else {
                    TextEditor(text: $editingBody)
                        .font(Font.system(size: 12.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .scrollContentBackground(.hidden)
                        .background(Palette.bgElev)
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

    /// Composer-style lens-mode bar — segmented OutlineButton trio
    /// (Edit / Diff / Together) + mono caption subtitle.
    private var lensModeBar: some View {
        HStack(spacing: 6) {
            ForEach(NoteLensMode.allCases) { mode in
                OutlineButton(
                    mode.label,
                    size: .small,
                    variant: lensMode == mode ? .accent : .standard,
                    action: { lensMode = mode }
                )
            }
            Spacer()
            Text(lensMode.subtitle)
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .accessibilityLabel(lensMode.subtitle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
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
        .background(Palette.bgElev)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Text("\(result.added) added · \(result.removed) removed")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                    .accessibilityLabel("\(result.added) lines added, \(result.removed) lines removed")
                if dirty {
                    OutlineButton(
                        "Use current as baseline",
                        size: .small,
                        variant: .ghost,
                        action: { snapshotBody = editingBody }
                    )
                    .help("Reset the diff baseline to the current editor contents.")
                    .accessibilityLabel("Reset diff baseline to current editor contents")
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
                    Text(Self.relativeFormatter.localizedString(for: ts, relativeTo: Date()))
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
        .accessibilityHint("Switches to the Edit lens and loads this note.")
    }


    /// PageHeader-style title bar — large title TextField + topic
    /// chip + delete IconButton, hairline rule below.
    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Title", text: $editingTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Palette.ink)
                if isSaving || isDeleting {
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
                .disabled(isCreating || selectedID == nil || isSaving || isDeleting || !canDeleteSelected)
            }
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.ink4)
                Text(currentTopic)
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 11))
                .foregroundStyle(Palette.danger)
            Text(text)
                .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink2)
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.danger.opacity(0.08))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.danger.opacity(0.4)).frame(height: DK.ruleW)
        }
    }

    private var saveBar: some View {
        HStack(spacing: 8) {
            Text("⌘⏎ to save")
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
            Spacer()
            OutlineButton("Discard", size: .small, variant: .ghost) {
                discardChanges()
            }
            .disabled(isSaving || isDeleting || (!isCreating && selectedID == nil))
            OutlineButton(
                "Save",
                icon: "checkmark.circle",
                size: .small,
                variant: .accent,
                action: { Task { await save() } }
            )
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isSaving || isDeleting || !canEditSelected || editingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.ink4)
                Text("Pick a note or start a new one")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text("The left rail lists every note in the active topic, sorted by last update. The + button starts a new note in any topic you type.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("USER NOTES  ·  topic-scoped writes  ·  bt-core refreshes FTS in the same transaction")
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
