import SwiftUI
import AppKit

/// Composer-tab enum shared by the global Todos composer and the
/// project-scoped `ProjectTodoInput`. The view's body switches on
/// this rather than driving three separate sibling views — keeps
/// the chrome (header strip, picker row if any, footer hints)
/// stable while only the central editing surface swaps.
enum ComposerTab: Hashable, CaseIterable {
    case compose
    case templates
    case snippets

    var headerLabel: String {
        switch self {
        case .compose: return "Compose"
        case .templates: return "Templates"
        case .snippets: return "Snippets"
        }
    }
}

/// One library kind shared by Templates (full prompts) and
/// Snippets (inline fragments). The kind only flips a few labels
/// + the apply semantics — list rendering and CRUD are identical.
enum LibraryKind: Hashable {
    case templates
    case snippets

    var nounSingular: String {
        switch self {
        case .templates: return "template"
        case .snippets: return "snippet"
        }
    }

    var nounPlural: String {
        switch self {
        case .templates: return "templates"
        case .snippets: return "snippets"
        }
    }

    /// Verb for the apply button. Templates fully replace the
    /// editor buffer; snippets append at the caret (or to the
    /// end of the buffer when no focus is held).
    var applyVerb: String {
        switch self {
        case .templates: return "Use"
        case .snippets: return "Insert"
        }
    }
}

/// Where a library entry lives on disk. Drives the row badge and
/// dispatches reads/writes to the correct `ScopedConfig` path.
enum LibraryScope: Hashable {
    case global
    case project(URL)

    var badge: String {
        switch self {
        case .global: return "GLOBAL"
        case .project: return "PROJECT"
        }
    }
}

/// Resolved view-model row paired with its owning scope so
/// CRUD operations route to the right file.
struct LibraryEntryRow: Identifiable, Equatable {
    let entry: GlobalSettings.LibraryEntry
    let scope: LibraryScope
    var id: UUID { entry.id }

    static func == (lhs: LibraryEntryRow, rhs: LibraryEntryRow) -> Bool {
        lhs.entry == rhs.entry && lhs.scope == rhs.scope
    }
}

/// List+detail pane shown in place of the composer's editor when
/// the user clicks `TEMPLATES` or `SNIPPETS`. Master list on the
/// left, selected-entry preview on the right, footer with
/// `Use`/`Insert`, `Edit`, `Delete`. `+ New` toggles an inline
/// edit form whose scope picker (`Global` / `This project`)
/// appears only when `projectRoot` is non-nil.
///
/// `onUse` receives the body text to apply. The caller decides
/// whether to replace (templates) or append (snippets) — this
/// keeps the pane oblivious to the editor's caret state.
struct ComposerLibraryPane: View {
    let kind: LibraryKind
    let projectRoot: URL?
    let projectName: String?
    let onUse: (String) -> Void
    let onClose: () -> Void

    @State private var rows: [LibraryEntryRow] = []
    @State private var selectedID: UUID? = nil
    @State private var editingID: UUID? = nil
    @State private var draftName: String = ""
    @State private var draftBody: String = ""
    @State private var draftScope: LibraryScope = .global
    @State private var showingNew: Bool = false

    private var selectedRow: LibraryEntryRow? {
        rows.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Palette.rule)
            if showingNew || editingID != nil {
                editForm
            } else {
                content
            }
        }
        .background(Palette.bgElev)
        .onAppear(perform: reload)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            OutlineButton(
                "New \(kind.nounSingular)",
                icon: "plus",
                size: .small,
                variant: .accent,
                action: beginNew
            )
            Spacer()
            Text("\(rows.count) \(rows.count == 1 ? kind.nounSingular : kind.nounPlural)")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)
            OutlineButton("Back", icon: "arrow.uturn.left", size: .small, variant: .ghost) {
                onClose()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                listColumn
                Divider().background(Palette.rule)
                detailColumn
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No \(kind.nounPlural) yet")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.textSecondary)
            Text("Save a \(kind.nounSingular) to reuse common prompts.")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listColumn: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    listRow(row)
                    Divider().background(Palette.rule.opacity(0.4))
                }
            }
        }
        .frame(width: 240)
        .background(Palette.bgPage)
    }

    private func listRow(_ row: LibraryEntryRow) -> some View {
        let isSelected = row.id == selectedID
        return Button(action: { selectedID = row.id }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.entry.name.isEmpty ? "Untitled" : row.entry.name)
                        .font(Typography.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    scopeChip(row.scope)
                }
                Text(previewLine(row.entry.body))
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.bgRowHi : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func scopeChip(_ scope: LibraryScope) -> some View {
        Text(scope.badge)
            .font(Font.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(scope == .global ? Palette.ink3 : Palette.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                scope == .global
                    ? Palette.bgElev
                    : Palette.accent.opacity(0.12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(scope == .global ? Palette.rule : Palette.accent.opacity(0.5), lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let row = selectedRow {
                ScrollView(.vertical) {
                    Text(row.entry.body.isEmpty ? "(empty body)" : row.entry.body)
                        .font(Font.system(size: 12.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                Divider().background(Palette.rule)
                detailFooter(row)
            } else {
                Spacer()
                Text("Select a \(kind.nounSingular) to preview.")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailFooter(_ row: LibraryEntryRow) -> some View {
        HStack(spacing: 6) {
            OutlineButton(kind.applyVerb, icon: "arrow.right", size: .small, variant: .accent) {
                onUse(row.entry.body)
            }
            Spacer()
            OutlineButton("Edit", icon: "pencil", size: .small, variant: .ghost) {
                beginEdit(row)
            }
            OutlineButton("Delete", icon: "trash", size: .small, variant: .danger) {
                confirmDelete(row)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.bgPage)
    }

    // MARK: - Edit form

    private var editForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editingID == nil ? "New \(kind.nounSingular)" : "Edit \(kind.nounSingular)")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)

            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .font(Typography.body)

            ZStack(alignment: .topLeading) {
                if draftBody.isEmpty {
                    Text(kind == .templates
                        ? "Full prompt body. Replaces the editor when used."
                        : "Fragment body. Inserted at the caret when used.")
                        .font(Font.system(size: 12.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                        .padding(.leading, 6)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draftBody)
                    .font(Font.system(size: 12.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .scrollContentBackground(.hidden)
            }
            .frame(minHeight: 120)
            .background(Palette.bgPage)
            .overlay(
                Rectangle()
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )

            if projectRoot != nil {
                HStack(spacing: 8) {
                    Text("Save to:")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textSecondary)
                    Picker("", selection: $draftScope) {
                        Text("Global").tag(LibraryScope.global)
                        if let root = projectRoot {
                            Text(projectName.map { "Project (\($0))" } ?? "This project")
                                .tag(LibraryScope.project(root))
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Spacer()
                }
            }

            HStack {
                Spacer()
                OutlineButton("Cancel", size: .small, variant: .ghost, action: cancelEdit)
                OutlineButton("Save", icon: "checkmark", size: .small, variant: .accent, action: saveEdit)
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Actions

    private func beginNew() {
        editingID = nil
        draftName = ""
        draftBody = ""
        draftScope = projectRoot.map { .project($0) } ?? .global
        showingNew = true
    }

    private func beginEdit(_ row: LibraryEntryRow) {
        editingID = row.id
        draftName = row.entry.name
        draftBody = row.entry.body
        draftScope = row.scope
        showingNew = false
    }

    private func cancelEdit() {
        editingID = nil
        showingNew = false
        draftName = ""
        draftBody = ""
    }

    private func saveEdit() {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = draftBody
        guard !trimmedName.isEmpty, !trimmedBody.isEmpty else { return }

        let now = Date()
        let entry: GlobalSettings.LibraryEntry
        if let id = editingID, let existing = rows.first(where: { $0.id == id })?.entry {
            entry = GlobalSettings.LibraryEntry(
                id: existing.id,
                name: trimmedName,
                body: trimmedBody,
                createdAt: existing.createdAt,
                updatedAt: now
            )
            // If the user changed scope, remove from old scope first.
            if let oldScope = rows.first(where: { $0.id == id })?.scope, oldScope != draftScope {
                removeEntry(id: existing.id, from: oldScope)
            }
        } else {
            entry = GlobalSettings.LibraryEntry(
                id: UUID(),
                name: trimmedName,
                body: trimmedBody,
                createdAt: now,
                updatedAt: now
            )
        }

        upsertEntry(entry, to: draftScope)
        editingID = nil
        showingNew = false
        draftName = ""
        draftBody = ""
        reload()
        selectedID = entry.id
    }

    private func confirmDelete(_ row: LibraryEntryRow) {
        let alert = NSAlert()
        alert.messageText = "Delete \(kind.nounSingular)?"
        alert.informativeText = "“\(row.entry.name.isEmpty ? "Untitled" : row.entry.name)” will be removed from \(row.scope == .global ? "your global library" : "this project's library"). This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if let cancel = alert.buttons.last { cancel.keyEquivalent = "\u{1b}" }
        if alert.runModal() == .alertFirstButtonReturn {
            removeEntry(id: row.id, from: row.scope)
            reload()
            if selectedID == row.id { selectedID = rows.first?.id }
        }
    }

    // MARK: - Persistence

    private func reload() {
        var combined: [LibraryEntryRow] = []
        if let root = projectRoot {
            let projectSettings = ScopedConfig.shared.getProjectShared(at: root)
            let projectList = (kind == .templates) ? projectSettings.templates : projectSettings.snippets
            combined.append(contentsOf: projectList.map {
                LibraryEntryRow(entry: $0, scope: .project(root))
            })
        }
        let global = ScopedConfig.shared.get()
        let globalList = (kind == .templates) ? global.templates : global.snippets
        combined.append(contentsOf: globalList.map {
            LibraryEntryRow(entry: $0, scope: .global)
        })
        rows = combined
        if selectedID == nil { selectedID = rows.first?.id }
    }

    private func upsertEntry(_ entry: GlobalSettings.LibraryEntry, to scope: LibraryScope) {
        switch scope {
        case .global:
            ScopedConfig.shared.setGlobal { settings in
                var list = (kind == .templates) ? settings.templates : settings.snippets
                if let idx = list.firstIndex(where: { $0.id == entry.id }) {
                    list[idx] = entry
                } else {
                    list.append(entry)
                }
                if kind == .templates {
                    settings.templates = list
                } else {
                    settings.snippets = list
                }
            }
        case .project(let root):
            ScopedConfig.shared.setProjectShared(at: root) { settings in
                var list = (kind == .templates) ? settings.templates : settings.snippets
                if let idx = list.firstIndex(where: { $0.id == entry.id }) {
                    list[idx] = entry
                } else {
                    list.append(entry)
                }
                if kind == .templates {
                    settings.templates = list
                } else {
                    settings.snippets = list
                }
            }
        }
    }

    private func removeEntry(id: UUID, from scope: LibraryScope) {
        switch scope {
        case .global:
            ScopedConfig.shared.setGlobal { settings in
                if kind == .templates {
                    settings.templates.removeAll { $0.id == id }
                } else {
                    settings.snippets.removeAll { $0.id == id }
                }
            }
        case .project(let root):
            ScopedConfig.shared.setProjectShared(at: root) { settings in
                if kind == .templates {
                    settings.templates.removeAll { $0.id == id }
                } else {
                    settings.snippets.removeAll { $0.id == id }
                }
            }
        }
    }

    // MARK: - Helpers

    private func previewLine(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first {
            return String(firstLine)
        }
        return trimmed
    }
}
