import SwiftUI
import SwiftData

/// Per-project knowledge section embedded in `ProjectDetailView`.
///
/// Solves the v1.0 "vault soup" problem: every project's knowledge
/// piles into one global Dome vault, the **Ingest codebase** /
/// **Bootstrap vectors** / **Clear ingested** buttons silently
/// target *global scope only*, and there is no per-project reset.
///
/// This view exposes four blocks the operator can act on without
/// leaving the project page:
///
/// 1. **Status** — codebase chunks + project notes for *this* project
///    only, plus a single toggle that flips
///    `Project.scopeIsolation` (controls whether spawned agents
///    default to `knowledge_scope: "project"` vs `"merged"`).
/// 2. **Ingest** — register + index this project's source tree, then
///    bootstrap vectors, all scoped via `DomeScopeSelection.project`.
/// 3. **Recipes** — apply the `architecture-review` recipe scoped to
///    this project; render the GovernedAnswer inline.
/// 4. **Danger zone** — three destructive resets (codebase only,
///    notes only, everything for this project) gated by
///    `NSAlert.critical`.
///
/// Every destructive primitive (`purgeTopicScope`, codeUnregister)
/// already takes `ownerScope: "project"` + `projectID` — this view
/// just stops hardcoding `"global"`.
struct ProjectKnowledgeView: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext

    @State private var codeProjects: [DomeRpcClient.CodeProjectSummary] = []
    @State private var projectNoteCount: Int = 0
    @State private var codebaseCount: Int = 0
    @State private var noteTopicCount: Int = 0
    @State private var lastIndexResult: DomeRpcClient.CodeIndexResult?
    @State private var lastAnswer: DomeRpcClient.GovernedAnswer?
    @State private var lastAnswerError: String?
    @State private var indexBusy: Bool = false
    @State private var bootstrapBusy: Bool = false
    @State private var purgeBusy: Bool = false
    @State private var recipeBusy: Bool = false
    @State private var statsLoaded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusBlock
            ingestBlock
            recipesBlock
            dangerBlock
        }
        .task {
            await reload()
        }
    }

    // MARK: - Status

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverlineLabel("Status")
            MetaStrip {
                MetaCell(key: "Codebase chunks", value: "\(codebaseCount)")
                MetaCell(key: "Project notes", value: "\(projectNoteCount)")
                MetaCell(key: "Topics", value: "\(noteTopicCount)")
                MetaCell(
                    key: "Last index",
                    value: lastIndexLabel(),
                    trailingDivider: false
                )
            }
            isolationToggle
        }
    }

    private var isolationToggle: some View {
        let isolated = project.scopeIsolation
        return HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(
                get: { project.scopeIsolation },
                set: { newValue in
                    project.scopeIsolation = newValue
                    try? modelContext.save()
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text("Isolate this project from global knowledge")
                    .font(Typography.body)
                    .foregroundStyle(Palette.ink)
                Text(isolated
                     ? "Spawned agents default to knowledge_scope: \"project\". Pass include_global: true only when explicitly asking for cross-project facts."
                     : "Spawned agents default to knowledge_scope: \"merged\" — global notes and other projects' codebase chunks are visible.")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
        .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
    }

    // MARK: - Ingest

    private var ingestBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverlineLabel("Ingest")
            HStack(alignment: .top, spacing: 10) {
                OutlineButton(
                    indexBusy ? "Indexing…" : "Index this project",
                    icon: "doc.text.magnifyingglass",
                    size: .small,
                    variant: .accent,
                    action: { runIndex(fullRebuild: false) }
                )
                .disabled(indexBusy)

                OutlineButton(
                    "Re-index from scratch",
                    icon: "arrow.triangle.2.circlepath",
                    size: .small,
                    action: { confirmFullRebuild() }
                )
                .disabled(indexBusy)

                OutlineButton(
                    bootstrapBusy ? "Bootstrapping…" : "Bootstrap vectors",
                    icon: "vector.subscript",
                    size: .small,
                    action: { runBootstrap() }
                )
                .disabled(bootstrapBusy)

                Spacer()
            }
            if let result = lastIndexResult {
                Text("indexed \(result.chunksTotal) chunks across \(result.filesIndexed) files (\(byteString(result.bytesTotal)))")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.bgElev)
        .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
    }

    // MARK: - Recipes

    private var recipesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverlineLabel("Recipes")
            HStack(spacing: 10) {
                OutlineButton(
                    recipeBusy ? "Running…" : "Run architecture-review",
                    icon: "doc.text.below.ecg",
                    size: .small,
                    variant: .accent,
                    action: { runRecipe(intentKey: "architecture-review") }
                )
                .disabled(recipeBusy)

                OutlineButton(
                    "Run completion-claim",
                    icon: "checkmark.seal",
                    size: .small,
                    action: { runRecipe(intentKey: "completion-claim") }
                )
                .disabled(recipeBusy)

                OutlineButton(
                    "Open project recipes",
                    icon: "folder",
                    size: .small,
                    variant: .ghost,
                    action: openProjectRecipesFolder
                )
                Spacer()
            }
            if let err = lastAnswerError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon")
                        .foregroundStyle(Palette.danger)
                    Text(err)
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.ink2)
                    Spacer()
                    OutlineButton("Dismiss", size: .small, variant: .ghost) {
                        lastAnswerError = nil
                    }
                }
                .padding(8)
                .background(Palette.danger.opacity(0.08))
                .overlay(Rectangle().stroke(Palette.danger.opacity(0.4), lineWidth: DK.ruleW))
            }
            if let answer = lastAnswer {
                governedAnswerCard(answer)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.bgElev)
        .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
    }

    private func governedAnswerCard(_ answer: DomeRpcClient.GovernedAnswer) -> some View {
        // Trimmed-down sibling of `RecipesSurface.answerCard` — kept
        // local so this view doesn't depend on the Dome window. Same
        // semantic shape (answer markdown + citations + missing
        // authority callout), simpler chrome.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OverlineLabel("Governed answer · \(answer.intentKey)")
                Spacer()
                OutlineButton(
                    "Copy",
                    icon: "doc.on.doc",
                    size: .small,
                    variant: .ghost,
                    action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer.answer, forType: .string)
                    }
                )
                OutlineButton(
                    "Dismiss",
                    icon: "xmark",
                    size: .small,
                    variant: .ghost,
                    action: { lastAnswer = nil }
                )
            }
            Text(answer.answer)
                .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Palette.bgPage)
                .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
            if !answer.citations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    OverlineLabel("Citations · \(answer.citations.count)")
                    ForEach(answer.citations) { citation in
                        Text("· \(citation.title) — `\(citation.topic)` (conf \(String(format: "%.2f", citation.confidence)))")
                            .font(Typography.monoMicro)
                            .foregroundStyle(Palette.ink3)
                    }
                }
            }
            if !answer.missingAuthority.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    OverlineLabel("Missing authority", tint: Palette.warning)
                    ForEach(answer.missingAuthority, id: \.self) { gap in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Palette.warning)
                                .font(.system(size: 10))
                            Text(gap)
                                .font(Typography.monoMicro)
                                .foregroundStyle(Palette.ink2)
                        }
                    }
                }
                .padding(8)
                .background(Palette.warning.opacity(0.06))
                .overlay(Rectangle().stroke(Palette.warning.opacity(0.3), lineWidth: DK.ruleW))
            }
        }
    }

    // MARK: - Danger zone

    private var dangerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverlineLabel("Danger zone", tint: Palette.danger)
            VStack(alignment: .leading, spacing: 6) {
                OutlineButton(
                    purgeBusy ? "Working…" : "Reset this project's codebase (\(codebaseCount))",
                    icon: "trash",
                    size: .small,
                    variant: .danger,
                    action: { confirmResetCodebase() }
                )
                .disabled(purgeBusy || codebaseCount == 0)

                OutlineButton(
                    purgeBusy ? "Working…" : "Reset this project's notes (\(projectNoteCount))",
                    icon: "trash",
                    size: .small,
                    variant: .danger,
                    action: { confirmResetNotes() }
                )
                .disabled(purgeBusy || projectNoteCount == 0)

                OutlineButton(
                    purgeBusy ? "Working…" : "Reset all knowledge for this project",
                    icon: "trash.slash",
                    size: .small,
                    variant: .danger,
                    action: { confirmResetEverything() }
                )
                .disabled(purgeBusy || (codebaseCount == 0 && projectNoteCount == 0))
            }
            Text("Each reset takes a backup snapshot first (Settings → Storage → Backups can restore). Project files on disk are untouched.")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.ink4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.danger.opacity(0.05))
        .overlay(Rectangle().stroke(Palette.danger.opacity(0.35), lineWidth: DK.ruleW))
    }

    // MARK: - Loaders

    private func reload() async {
        let projectID = project.id.uuidString
        let topic = "project-" + project.id.uuidString.prefix(8).lowercased()
        let scope = DomeScopeSelection.project(
            id: project.id,
            name: project.name,
            rootPath: project.rootPath,
            includeGlobal: false
        )
        let result = await Task.detached { () -> (
            [DomeRpcClient.CodeProjectSummary],
            DomeRpcClient.PurgeTopicCount?,
            DomeRpcClient.PurgeTopicCount?,
            [DomeRpcClient.NoteSummary]
        ) in
            let codeProjects = DomeRpcClient.codeListProjects()
            let codebase = DomeRpcClient.purgeTopicScopeCount(
                topic: "codebase", ownerScope: "project", projectID: projectID
            )
            let notes = DomeRpcClient.purgeTopicScopeCount(
                topic: topic, ownerScope: "project", projectID: projectID
            )
            let recent = DomeRpcClient.listNotes(topic: topic, limit: 1, domeScope: scope) ?? []
            return (codeProjects, codebase, notes, recent)
        }.value
        await MainActor.run {
            self.codeProjects = result.0
            self.codebaseCount = Int(result.1?.count ?? 0)
            self.projectNoteCount = Int(result.2?.count ?? 0)
            self.noteTopicCount = result.3.isEmpty ? 0 : 1
            self.statsLoaded = true
        }
    }

    private func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func lastIndexLabel() -> String {
        guard let entry = codeProjects.first(where: { $0.projectID == project.id.uuidString }) else {
            return "—"
        }
        guard let iso = entry.lastFullIndexAt,
              let date = ISO8601DateFormatter().date(from: iso) else {
            return "never"
        }
        return DomeRelativeTime.formatAgo(date)
    }

    // MARK: - Ingest actions

    private func runIndex(fullRebuild: Bool) {
        let projectID = project.id.uuidString
        let name = project.name
        let root = project.rootPath
        indexBusy = true
        Task.detached {
            _ = DomeRpcClient.codeRegisterProject(
                projectID: projectID,
                name: name,
                rootPath: root,
                enabled: true
            )
            let result = DomeRpcClient.codeIndexProject(
                projectID: projectID,
                fullRebuild: fullRebuild
            )
            _ = DomeRpcClient.codeWatchStart(projectID: projectID)
            await MainActor.run {
                indexBusy = false
                lastIndexResult = result
            }
            await reload()
        }
    }

    private func runBootstrap() {
        bootstrapBusy = true
        Task.detached {
            _ = DomeRpcClient.vaultReindex()
            await MainActor.run {
                bootstrapBusy = false
            }
            await reload()
        }
    }

    private func confirmFullRebuild() {
        let alert = NSAlert()
        alert.messageText = "Re-index \(project.name) from scratch?"
        alert.informativeText = "Drops every code chunk for this project and re-walks the source tree. Slow on multi-thousand-file repos."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Re-index")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runIndex(fullRebuild: true)
    }

    // MARK: - Recipe actions

    private func runRecipe(intentKey: String) {
        let projectID = project.id.uuidString
        recipeBusy = true
        lastAnswerError = nil
        Task.detached {
            let result = DomeRpcClient.recipeApply(
                intentKey: intentKey,
                projectID: projectID
            )
            await MainActor.run {
                recipeBusy = false
                if let result {
                    lastAnswer = result
                } else {
                    lastAnswerError = "Recipe didn't return an answer. The vault may be empty for this intent — write some notes first, or check Dome → Knowledge → System → Audit log for the failure detail."
                }
            }
        }
    }

    private func openProjectRecipesFolder() {
        // Per-project recipe overrides land under
        // <project>/.tado/verified-prompts/<intent>.md per Phase 5
        // (see `RecipesSurface.swift:11`). Open in Finder; create
        // the folder lazily if missing so the operator has a
        // landing zone the first time they click.
        let url = URL(fileURLWithPath: project.rootPath)
            .appendingPathComponent(".tado", isDirectory: true)
            .appendingPathComponent("verified-prompts", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Danger actions

    private func confirmResetCodebase() {
        let count = codebaseCount
        let alert = NSAlert()
        alert.messageText = "Reset codebase knowledge for \(project.name)?"
        alert.informativeText = "Removes \(count) code chunks for this project (topic='codebase', owner_scope='project'). A backup snapshot is taken first. Files on disk are untouched."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset codebase")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runPurgeCodebase()
    }

    private func runPurgeCodebase() {
        let projectID = project.id.uuidString
        purgeBusy = true
        Task.detached {
            _ = BackupManager.createBackup(reason: "pre-project-codebase-purge")
            // Two-step cleanup: drop every doc with topic='codebase'
            // at this project's scope, then unregister + cascade
            // through code_files / code_chunks via the existing
            // code.unregister path with purge=true.
            _ = DomeRpcClient.purgeTopicScope(
                topic: "codebase", ownerScope: "project", projectID: projectID
            )
            _ = DomeRpcClient.codeUnregisterProject(
                projectID: projectID, purge: true
            )
            await MainActor.run {
                purgeBusy = false
            }
            await reload()
        }
    }

    private func confirmResetNotes() {
        let count = projectNoteCount
        let topic = "project-" + project.id.uuidString.prefix(8).lowercased()
        let alert = NSAlert()
        alert.messageText = "Reset notes for \(project.name)?"
        alert.informativeText = "Removes \(count) docs in topic '\(topic)' at owner_scope='project'. A backup snapshot is taken first."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset notes")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runPurgeNotes()
    }

    private func runPurgeNotes() {
        let projectID = project.id.uuidString
        let topic = "project-" + project.id.uuidString.prefix(8).lowercased()
        purgeBusy = true
        Task.detached {
            _ = BackupManager.createBackup(reason: "pre-project-notes-purge")
            _ = DomeRpcClient.purgeTopicScope(
                topic: topic, ownerScope: "project", projectID: projectID
            )
            await MainActor.run {
                purgeBusy = false
            }
            await reload()
        }
    }

    private func confirmResetEverything() {
        let total = codebaseCount + projectNoteCount
        let alert = NSAlert()
        alert.messageText = "Reset ALL knowledge for \(project.name)?"
        alert.informativeText = "Removes \(total) docs across this project's codebase and notes topics, unregisters the code project, and drops cascaded chunks/edges. A backup snapshot is taken first. Files on disk are untouched."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset everything")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runPurgeEverything()
    }

    private func runPurgeEverything() {
        let projectID = project.id.uuidString
        let topic = "project-" + project.id.uuidString.prefix(8).lowercased()
        purgeBusy = true
        Task.detached {
            _ = BackupManager.createBackup(reason: "pre-project-full-purge")
            _ = DomeRpcClient.purgeTopicScope(
                topic: "codebase", ownerScope: "project", projectID: projectID
            )
            _ = DomeRpcClient.purgeTopicScope(
                topic: topic, ownerScope: "project", projectID: projectID
            )
            _ = DomeRpcClient.codeUnregisterProject(
                projectID: projectID, purge: true
            )
            await MainActor.run {
                purgeBusy = false
            }
            await reload()
        }
    }
}
