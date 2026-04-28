import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allSettings: [AppSettings]

    private var settings: AppSettings {
        if let existing = allSettings.first {
            return existing
        }
        let new = AppSettings()
        modelContext.insert(new)
        try? modelContext.save()
        return new
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Button("Done") { dismiss() }
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                    .keyboardShortcut(.escape)
            }
            .padding(20)

            Divider()

            // Settings form
            Form {
                Section("Engine") {
                    Picker(selection: Binding(
                        get: { settings.engine },
                        set: { settings.engine = $0; try? modelContext.save() }
                    )) {
                        ForEach(TerminalEngine.allCases, id: \.self) { engine in
                            HStack {
                                Text(engine.displayName)
                                Text("(\(engine.rawValue) \"your todo\")")
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .tag(engine)
                        }
                    } label: {
                        labelWithTip(
                            "When you press Enter, run:",
                            "Which CLI spawns when you press Enter on a new todo. Claude and Codex share the same tile plumbing but have different flags, models, and agent formats."
                        )
                    }
                    .pickerStyle(.radioGroup)
                }

                Section("Mode") {
                    if settings.engine == .claude {
                        Picker(selection: Binding(
                            get: { settings.claudeMode },
                            set: { settings.claudeMode = $0; try? modelContext.save() }
                        )) {
                            ForEach(ClaudeMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        } label: {
                            labelWithTip(
                                "Permission mode:",
                                "How Claude handles tool-permission prompts. Ask pauses the tile for each tool; Delegate lets the agent auto-approve within its sandbox; Skip disables prompts entirely (use only with Full Auto enabled upstream)."
                            )
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker(selection: Binding(
                            get: { settings.codexMode },
                            set: { settings.codexMode = $0; try? modelContext.save() }
                        )) {
                            ForEach(CodexMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        } label: {
                            labelWithTip(
                                "Approval mode:",
                                "How Codex prompts before running a command. Matches Codex's own --approval flag."
                            )
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Model") {
                    if settings.engine == .claude {
                        Picker(selection: Binding(
                            get: { settings.claudeModel },
                            set: { settings.claudeModel = $0; try? modelContext.save() }
                        )) {
                            ForEach(ClaudeModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        } label: {
                            labelWithTip(
                                "Claude model:",
                                "Default Claude model for new tiles. Per-session overrides from dispatch or eternal frontmatter still win."
                            )
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker(selection: Binding(
                            get: { settings.codexModel },
                            set: { settings.codexModel = $0; try? modelContext.save() }
                        )) {
                            ForEach(CodexModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        } label: {
                            labelWithTip(
                                "Codex model:",
                                "Default Codex model for new tiles."
                            )
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Effort") {
                    if settings.engine == .claude {
                        Picker(selection: Binding(
                            get: { settings.claudeEffort },
                            set: { settings.claudeEffort = $0; try? modelContext.save() }
                        )) {
                            ForEach(ClaudeEffort.allCases, id: \.self) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        } label: {
                            labelWithTip(
                                "Thinking effort:",
                                "Reasoning depth Claude applies before each response. Higher = slower and more thorough."
                            )
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker(selection: Binding(
                            get: { settings.codexEffort },
                            set: { settings.codexEffort = $0; try? modelContext.save() }
                        )) {
                            ForEach(CodexEffort.allCases, id: \.self) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        } label: {
                            labelWithTip(
                                "Reasoning effort:",
                                "Reasoning depth Codex applies. Higher = slower and more thorough."
                            )
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section {
                    if settings.engine == .claude {
                        Toggle(isOn: Binding(
                            get: { settings.claudeNoFlicker },
                            set: { settings.claudeNoFlicker = $0; try? modelContext.save() }
                        )) {
                            labelWithTip(
                                "Fullscreen Claude UI",
                                "Switches Claude Code into its fullscreen (alt-screen) UI. Tile-level scrollback is replaced by Claude's own scrollable message history — use the wheel with Mouse enabled to scroll through it. Restart the session to apply."
                            )
                        }
                        Toggle(isOn: Binding(
                            get: { settings.claudeMouseEnabled },
                            set: { settings.claudeMouseEnabled = $0; try? modelContext.save() }
                        )) {
                            labelWithTip(
                                "Mouse + clickable UI",
                                "Forwards mouse events to Claude Code so its fullscreen UI receives clicks and wheel scrolls. Required for the CLI's own scrollback to respond to the wheel."
                            )
                        }
                        .disabled(!settings.claudeNoFlicker)
                        Stepper(
                            value: Binding(
                                get: { settings.claudeScrollSpeed },
                                set: { settings.claudeScrollSpeed = $0; try? modelContext.save() }
                            ),
                            in: 1...20
                        ) {
                            labelWithTip(
                                "Scroll speed: \(settings.claudeScrollSpeed)x",
                                "Lines scrolled per wheel notch inside Claude's fullscreen UI."
                            )
                        }
                        .disabled(!settings.claudeNoFlicker)
                    } else {
                        Toggle(isOn: Binding(
                            get: { settings.codexAlternateScreen },
                            set: { settings.codexAlternateScreen = $0; try? modelContext.save() }
                        )) {
                            labelWithTip(
                                "Allow alternate-screen buffer",
                                "Codex's alt-screen toggle. Off keeps --no-alt-screen on, which is required for Codex to render correctly in embedded tiles today. Turn on only when testing a Codex build that handles alt-screen."
                            )
                        }
                    }
                } header: {
                    Text("Harness Display")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { settings.randomTileColor },
                        set: { settings.randomTileColor = $0; try? modelContext.save() }
                    )) {
                        labelWithTip(
                            "Random tile color per session",
                            "New tiles pick a random theme from a curated palette. Existing tiles keep their current color."
                        )
                    }

                    Picker(selection: Binding(
                        get: { settings.defaultThemeId },
                        set: { settings.defaultThemeId = $0; try? modelContext.save() }
                    )) {
                        ForEach(TerminalTheme.all) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    } label: {
                        labelWithTip(
                            "Default theme:",
                            "Theme used for new tiles when random colors is off. Applies background, foreground, and (when the theme supplies one) the ANSI palette."
                        )
                    }
                    .pickerStyle(.menu)
                    .disabled(settings.randomTileColor)
                } header: {
                    Text("Tile Appearance")
                }

                Section {
                    Picker(selection: Binding(
                        get: { settings.terminalFontFamily },
                        set: { settings.terminalFontFamily = $0; try? modelContext.save() }
                    )) {
                        Text("System Monospaced (SF Mono)").tag("")
                        Divider()
                        ForEach(FontMetrics.monospaceFamilyNames(), id: \.self) { family in
                            Text(family).tag(family)
                        }
                    } label: {
                        labelWithTip(
                            "Terminal font:",
                            "Only fixed-pitch fonts are listed — proportional faces break cell alignment. Picking a missing font falls back to SF Mono silently."
                        )
                    }
                    .pickerStyle(.menu)

                    Stepper(
                        value: Binding(
                            get: { settings.terminalFontSize },
                            set: { settings.terminalFontSize = $0; try? modelContext.save() }
                        ),
                        in: 9...24
                    ) {
                        labelWithTip(
                            "Terminal font size: \(settings.terminalFontSize) pt",
                            "Monospace point size. Applies to tiles spawned after the change; existing tiles keep their current size."
                        )
                    }

                    Toggle(isOn: Binding(
                        get: { settings.cursorBlink },
                        set: { settings.cursorBlink = $0; try? modelContext.save() }
                    )) {
                        labelWithTip(
                            "Blink cursor",
                            "Hides the cursor every ~530 ms while idle. Matches Terminal.app. Off keeps it solid for clean screen recordings."
                        )
                    }

                    Picker(selection: Binding(
                        get: { settings.bellMode },
                        set: { settings.bellMode = $0; try? modelContext.save() }
                    )) {
                        ForEach(BellMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        labelWithTip(
                            "Bell",
                            "How a terminal bell (0x07) is surfaced. Visual flashes the tile; Audio plays the system beep."
                        )
                    }
                } header: {
                    Text("Rendering")
                }

                Section("Canvas") {
                    Stepper(
                        value: Binding(
                            get: { settings.gridColumns },
                            set: { settings.gridColumns = $0; try? modelContext.save() }
                        ),
                        in: 2...6
                    ) {
                        labelWithTip(
                            "Grid columns: \(settings.gridColumns)",
                            "How many tiles fit per canvas row before wrapping. Tile size is fixed (820×540) — this only moves the wrap point. Existing tiles keep their positions; the new column count applies to tiles spawned from now on."
                        )
                    }
                }

                NotificationsSection()

                StorageSection()

                CodeIndexingSection()

                AgentTokensSection()

                ToolsInspectorSection()

                Section("Shortcuts") {
                    LabeledContent("Cycle pages", value: "Ctrl + Tab")
                    LabeledContent("Projects", value: "Cmd + P")
                    LabeledContent("Teams", value: "Cmd + E")
                    LabeledContent("Settings", value: "Cmd + M")
                    LabeledContent("Sidebar", value: "Cmd + B")
                    LabeledContent("Done list", value: "Cmd + D")
                    LabeledContent("Trash", value: "Cmd + T")
                    LabeledContent("Submit todo", value: "Enter")
                }
            }
            .formStyle(.grouped)
            // Hide Form's built-in Material backdrop so the VStack's
            // `Palette.background` shows through. Without this the Form
            // paints macOS' default grouped-sidebar tint and the
            // settings sheet reads as light grey on top of our neutral
            // chrome.
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
        }
        .frame(width: 480, height: 720)
        .background(Palette.background)
    }

    /// Inline label used by Pickers / Toggles / Steppers in this view so the
    /// control keeps its native layout while carrying an `InfoTip` next to
    /// the label text.
    @ViewBuilder
    private func labelWithTip(_ label: String, _ tip: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
            InfoTip(text: tip)
        }
    }
}

// MARK: - Notifications

/// Settings section for the notification substrate. Reads + writes
/// `global.json` via `ScopedConfig` (not SwiftData) — the `AppSettings`
/// row does not carry notification state. Changes round-trip through
/// the central `ScopedConfig.setGlobal` so the file on disk is the
/// canonical answer regardless of whether the user edits here, in
/// a text editor, or via `tado-config`.
private struct NotificationsSection: View {
    @State private var settingsSnapshot: GlobalSettings = GlobalSettings()

    var body: some View {
        Section {
            Toggle("In-app banners", isOn: bind(\.notifications.channels.inApp))
            Toggle("macOS system notifications", isOn: bind(\.notifications.channels.system))
            Toggle("Sounds", isOn: bind(\.notifications.channels.sound))
            Toggle("Dock badge", isOn: bind(\.notifications.channels.dockBadge))

            Toggle("Quiet hours", isOn: bind(\.notifications.quietHours.enabled))
            if settingsSnapshot.notifications.quietHours.enabled {
                HStack {
                    Text("From")
                    TextField("22:00", text: bind(\.notifications.quietHours.from))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("to")
                    TextField("08:00", text: bind(\.notifications.quietHours.to))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Spacer()
                }
                .font(Typography.monoCaption)
            }

            LabeledContent("Events routed") {
                Text("\(settingsSnapshot.notifications.eventRouting.count) types")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        } header: {
            Text("Notifications")
        }
        .onAppear { settingsSnapshot = ScopedConfig.shared.get() }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            // Cheap poll so the toggles reflect external edits (CLI,
            // text editor) without requiring a dedicated @Observable
            // wrapper around GlobalSettings.
            let fresh = ScopedConfig.shared.get()
            if fresh != settingsSnapshot { settingsSnapshot = fresh }
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<GlobalSettings, T>) -> Binding<T> {
        Binding(
            get: { settingsSnapshot[keyPath: keyPath] },
            set: { newValue in
                ScopedConfig.shared.setGlobal { $0[keyPath: keyPath] = newValue }
                settingsSnapshot = ScopedConfig.shared.get()
            }
        )
    }
}

// MARK: - Storage

/// Surfaces the canonical on-disk layout so users can jump straight to
/// the files Tado is reading / writing, plus quick export + import.
private struct StorageSection: View {
    @State private var lastExport: String?
    @State private var importError: String?
    @State private var storageError: String?
    @State private var pendingRoot: URL?
    @State private var lastMoveError: String?

    var body: some View {
        Section {
            LabeledContent("Root") {
                Text(StorePaths.root.path)
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let pendingRoot {
                Text("Move pending: \(pendingRoot.path). Restart Tado to finish.")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.warning)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let lastMoveError {
                Text("Last move failed: \(lastMoveError)")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.danger)
                    .lineLimit(3)
            }
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([StorePaths.root])
                }
                Button("Open event log") {
                    NSWorkspace.shared.open(StorePaths.eventsCurrent)
                }
                .disabled(!FileManager.default.fileExists(atPath: StorePaths.eventsCurrent.path))
            }

            HStack {
                Button("Change Location…") { chooseStorageLocation() }
                Button("Reset to Default") { resetStorageLocation() }
                    .disabled(StorageLocationManager.isUsingDefaultRoot && pendingRoot == nil)
            }
            if let storageError {
                Text(storageError)
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.danger)
                    .lineLimit(3)
            }

            HStack {
                Button("Export backup…") { exportBackup() }
                Button("Import backup…") { importBackup() }
            }
            if let lastExport {
                Text("Exported: \(lastExport)")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
            }
            if let importError {
                Text("Import failed: \(importError)")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.danger)
            }
        } header: {
            Text("Storage")
        }
        .onAppear { refreshStorageState() }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            refreshStorageState()
        }
    }

    private func refreshStorageState() {
        pendingRoot = StorageLocationManager.pendingRoot
        lastMoveError = StorageLocationManager.lastMoveError
    }

    private func chooseStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = StorePaths.root.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scheduleStorageMove(to: url)
    }

    private func resetStorageLocation() {
        scheduleStorageMove(to: StorageLocationManager.defaultRoot)
    }

    private func scheduleStorageMove(to url: URL) {
        do {
            try StorageLocationManager.scheduleMove(to: url)
            storageError = nil
            refreshStorageState()
        } catch {
            storageError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tado-backup.tar.gz"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let archive = BackupManager.createBackup(reason: "manual-export") {
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            try? fm.moveItem(at: archive, to: url)
            lastExport = url.lastPathComponent
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if BackupManager.restore(from: url) {
            importError = nil
        } else {
            importError = "tar -xzf failed — see Console.app for details"
        }
    }
}

/// Phase 4: per-user kill switch + per-project re-index controls.
/// The toggle is *live* — flipping it OFF stops every active watcher
/// and ON kicks `code.watch.resume_all`. Per-project re-index buttons
/// fire `code.index_project` on a detached task; the existing
/// `CodeIndexBadge` on the project card surfaces progress.
private struct CodeIndexingSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [AppSettings]
    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var rebuildBusy: Set<String> = []
    @State private var lastResume: [String] = []

    private var settings: AppSettings? { settingsList.first }

    var body: some View {
        Section {
            if let settings {
                Toggle(isOn: Binding(
                    get: { settings.codeIndexingEnabled },
                    set: { newValue in
                        settings.codeIndexingEnabled = newValue
                        try? modelContext.save()
                        applyKillSwitch(enabled: newValue)
                    }
                )) {
                    labelWithTip(
                        "Code indexing & file watching",
                        "Master switch. OFF stops every active file watcher and prevents new ones from starting; existing chunks stay queryable. ON reattaches watchers for every previously-enabled project."
                    )
                }
                if !lastResume.isEmpty {
                    Text("Resumed: \(lastResume.joined(separator: ", "))")
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                }
            }

            if !projects.isEmpty {
                Divider()
                Text("Projects")
                    .font(Typography.calloutBold)
                    .foregroundStyle(Palette.textSecondary)
                ForEach(projects) { project in
                    let pid = project.id.uuidString.lowercased()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(Typography.bodyEmphasis)
                                .foregroundStyle(Palette.textPrimary)
                            Text(project.rootPath)
                                .font(Typography.monoMicro)
                                .foregroundStyle(Palette.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(rebuildBusy.contains(pid) ? "Re-indexing…" : "Re-index") {
                            rebuild(projectID: pid)
                        }
                        .disabled(
                            rebuildBusy.contains(pid)
                            || (settings?.codeIndexingEnabled == false)
                        )
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Code indexing")
        }
    }

    private func applyKillSwitch(enabled: Bool) {
        if enabled {
            Task.detached {
                let started = DomeRpcClient.codeWatchResumeAll()
                await MainActor.run { lastResume = started }
            }
        } else {
            Task.detached {
                _ = DomeRpcClient.codeWatchStopAll()
                await MainActor.run { lastResume = [] }
            }
        }
    }

    private func rebuild(projectID: String) {
        rebuildBusy.insert(projectID)
        Task.detached {
            _ = DomeRpcClient.codeIndexProject(projectID: projectID, fullRebuild: true)
            await MainActor.run { _ = rebuildBusy.remove(projectID) }
        }
    }

    private func labelWithTip(_ title: String, _ tip: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(tip)
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(3)
        }
    }
}

/// v0.13 — issue + revoke + rotate Dome agent tokens.
///
/// Tokens authenticate non-Tado MCP clients (e.g. Claude Desktop)
/// against the local Dome daemon. The raw secret is shown ONCE
/// when the token is created or rotated — config stores only the
/// hash. Revoking flips a flag, keeping the row for the audit
/// trail; future authentication attempts fail with `Forbidden`.
private struct AgentTokensSection: View {
    @State private var tokens: [DomeRpcClient.AgentToken] = []
    @State private var showCreate = false
    @State private var newAgentName = ""
    @State private var newCaps: Set<String> = ["search", "read"]
    @State private var lastSecret: DomeRpcClient.TokenSecret?
    @State private var working = false

    private static let knownCaps: [String] = [
        "search", "read", "note", "schedule",
        "graph", "context", "supersede", "verify", "decay", "recipe",
    ]

    var body: some View {
        Section("Agent tokens") {
            HStack {
                Text("Tokens authenticate non-Tado MCP clients (Claude Desktop, etc.) against the local Dome daemon.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                Button(showCreate ? "Hide form" : "Issue token") {
                    showCreate.toggle()
                    if !showCreate { lastSecret = nil }
                }
                .buttonStyle(.borderless)
            }

            if showCreate {
                createForm
            }
            if let secret = lastSecret {
                secretBanner(secret)
            }

            if tokens.isEmpty {
                Text("No tokens issued yet.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            } else {
                ForEach(tokens) { token in
                    tokenRow(token)
                }
            }
        }
        .task { await reload() }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Agent label", text: $newAgentName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Button(working ? "Issuing…" : "Issue") {
                    runCreate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || newAgentName.isEmpty || newCaps.isEmpty)
            }
            HStack(spacing: 6) {
                ForEach(Self.knownCaps, id: \.self) { cap in
                    Button {
                        if newCaps.contains(cap) { newCaps.remove(cap) }
                        else { newCaps.insert(cap) }
                    } label: {
                        Text(cap)
                            .font(Typography.monoCaption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(newCaps.contains(cap) ? Palette.surfaceAccentSoft : Palette.surface)
                            .foregroundStyle(newCaps.contains(cap) ? Palette.accent : Palette.textSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func secretBanner(_ secret: DomeRpcClient.TokenSecret) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Copy this secret now — it's only shown once.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.warning)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(secret.token, forType: .string)
                }
                .buttonStyle(.borderless)
                Button("Dismiss") { lastSecret = nil }
                    .buttonStyle(.borderless)
            }
            Text(secret.token)
                .font(Typography.monoCaption)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(8)
        .background(Palette.surfaceAccentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tokenRow(_ token: DomeRpcClient.AgentToken) -> some View {
        HStack(spacing: 10) {
            Image(systemName: token.revoked ? "xmark.circle" : "key.fill")
                .foregroundStyle(token.revoked ? Palette.textTertiary : Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(token.agentName)
                    .font(Typography.body)
                    .foregroundStyle(token.revoked ? Palette.textTertiary : Palette.textPrimary)
                HStack(spacing: 4) {
                    Text(token.tokenId)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textTertiary)
                    Text(token.caps.joined(separator: ", "))
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer()
            if !token.revoked {
                Button("Rotate") { runRotate(token: token) }
                    .buttonStyle(.borderless)
                    .disabled(working)
                Button("Revoke") { confirmRevoke(token: token) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Palette.danger)
                    .disabled(working)
            } else {
                Text("Revoked")
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() async {
        let fetched = await Task.detached { DomeRpcClient.tokenList() }.value
        await MainActor.run { tokens = fetched }
    }

    private func runCreate() {
        let name = newAgentName
        let caps = Array(newCaps).sorted()
        working = true
        Task.detached {
            let secret = DomeRpcClient.tokenCreate(agentName: name, caps: caps)
            await MainActor.run {
                working = false
                if let secret {
                    lastSecret = secret
                    newAgentName = ""
                }
            }
            await reload()
        }
    }

    private func runRotate(token: DomeRpcClient.AgentToken) {
        let alert = NSAlert()
        alert.messageText = "Rotate token for \"\(token.agentName)\"?"
        alert.informativeText = "The old secret stops working immediately. Make sure no agent is still relying on it before confirming."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Rotate")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let id = token.tokenId
        working = true
        Task.detached {
            let secret = DomeRpcClient.tokenRotate(tokenID: id)
            await MainActor.run {
                working = false
                if let secret { lastSecret = secret }
            }
            await reload()
        }
    }

    private func confirmRevoke(token: DomeRpcClient.AgentToken) {
        let alert = NSAlert()
        alert.messageText = "Revoke token for \"\(token.agentName)\"?"
        alert.informativeText = "Authentication with this token will fail afterward. The row stays in the config for the audit trail."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Revoke")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let id = token.tokenId
        working = true
        Task.detached {
            _ = DomeRpcClient.tokenRevoke(tokenID: id)
            await MainActor.run { working = false }
            await reload()
        }
    }
}

/// v0.16.1 — read-only inspector for every MCP tool exposed by
/// `dome-mcp` and `tado-mcp`. Static list (mirrors the source-of-truth
/// `tool_definitions()` in each Rust [[bin]]) — kept in Swift so it
/// renders even when the daemon is offline. When you ship a new MCP
/// tool, update this list AND the matching tool_definitions().
private struct ToolsInspectorSection: View {
    private struct McpTool: Identifiable {
        let bridge: String
        let name: String
        let description: String
        var id: String { "\(bridge):\(name)" }
    }

    @State private var query: String = ""
    @State private var expandedBridge: String? = "dome-mcp"

    private static let tools: [McpTool] = [
        // dome-mcp (canonical inventory at
        // `tado-core/crates/dome-mcp/src/main.rs::tool_definitions`).
        .init(bridge: "dome-mcp", name: "dome_search",            description: "Search Dome notes + knowledge. Returns ranked hits with snippets."),
        .init(bridge: "dome-mcp", name: "dome_read",              description: "Fetch the full body + metadata of a Dome note by id."),
        .init(bridge: "dome-mcp", name: "dome_note",              description: "Append an agent note. Scope is always agent — propose user-note changes via suggestion.create."),
        .init(bridge: "dome-mcp", name: "dome_schedule",          description: "Create a calendar automation (once / cron / interval / manual / heartbeat)."),
        .init(bridge: "dome-mcp", name: "dome_graph_query",       description: "Query the Dome graph projection by node ids / kinds."),
        .init(bridge: "dome-mcp", name: "dome_context_resolve",   description: "Resolve a context pack to its citations + summary."),
        .init(bridge: "dome-mcp", name: "dome_context_compact",   description: "Compact / refresh a context pack."),
        .init(bridge: "dome-mcp", name: "dome_agent_status",      description: "Tail the agent status-line snapshots."),
        .init(bridge: "dome-mcp", name: "dome_code_search",       description: "Hybrid search across registered project codebases."),
        .init(bridge: "dome-mcp", name: "dome_code_status",       description: "Indexing status for one project."),
        .init(bridge: "dome-mcp", name: "dome_code_watch",        description: "Start the codebase watcher for a project."),
        .init(bridge: "dome-mcp", name: "dome_code_unwatch",      description: "Stop the codebase watcher for a project."),
        .init(bridge: "dome-mcp", name: "dome_code_watch_list",   description: "List active codebase watchers."),
        .init(bridge: "dome-mcp", name: "dome_supersede",         description: "Chain an old fact to its replacement (Phase 3 lifecycle)."),
        .init(bridge: "dome-mcp", name: "dome_verify",            description: "Confirm or dispute a typed entity (Phase 3 lifecycle)."),
        .init(bridge: "dome-mcp", name: "dome_decay",             description: "Soft-archive a typed entity (Phase 3 lifecycle)."),
        .init(bridge: "dome-mcp", name: "dome_recipe_list",       description: "List every retrieval recipe in the active scope."),
        .init(bridge: "dome-mcp", name: "dome_recipe_apply",      description: "Apply a recipe → return its GovernedAnswer with citations."),

        // tado-mcp (canonical inventory at
        // `tado-core/crates/tado-mcp/src/main.rs::tool_definitions`).
        .init(bridge: "tado-mcp", name: "tado_list",              description: "List every active Tado terminal session."),
        .init(bridge: "tado-mcp", name: "tado_send",              description: "Send a message to another Tado terminal session."),
        .init(bridge: "tado-mcp", name: "tado_notify",            description: "Publish a user-broadcast event to Tado's global event log."),
        .init(bridge: "tado-mcp", name: "tado_events_query",      description: "Tail Tado's event log with filters."),
        .init(bridge: "tado-mcp", name: "tado_read",              description: "Read a Tado session's terminal output log."),
        .init(bridge: "tado-mcp", name: "tado_broadcast",         description: "Send the same message to every session in a project and/or team."),
        .init(bridge: "tado-mcp", name: "tado_config_get",        description: "Read a config value from the scoped settings hierarchy."),
        .init(bridge: "tado-mcp", name: "tado_config_set",        description: "Write a config value at a chosen scope."),
        .init(bridge: "tado-mcp", name: "tado_config_list",       description: "List every config key visible at the current scope."),
        .init(bridge: "tado-mcp", name: "tado_memory_read",       description: "Read user / project memory markdown."),
        .init(bridge: "tado-mcp", name: "tado_memory_append",     description: "Append to user / project memory markdown."),
        .init(bridge: "tado-mcp", name: "tado_memory_search",     description: "Search user / project memory markdown."),
    ]

    private var filtered: [McpTool] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Self.tools }
        return Self.tools.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private var groups: [(String, [McpTool])] {
        Dictionary(grouping: filtered, by: \.bridge)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
    }

    var body: some View {
        Section("MCP tools (developer)") {
            HStack {
                Text("Every MCP tool exposed by Tado's two stdio bridges. Reference only — invocation happens through the agent client (Claude Desktop, claude-code, etc.).")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            }
            TextField("Filter by name or description", text: $query)
                .textFieldStyle(.roundedBorder)
            ForEach(groups, id: \.0) { bridge, list in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedBridge == bridge || !query.isEmpty },
                        set: { _ in expandedBridge = expandedBridge == bridge ? nil : bridge }
                    )
                ) {
                    ForEach(list) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(Typography.monoCaption)
                                .foregroundStyle(Palette.textPrimary)
                                .textSelection(.enabled)
                            Text(tool.description)
                                .font(Typography.micro)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    HStack {
                        Text(bridge).font(Typography.title)
                        Text("\(list.count) tools").font(Typography.micro).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
    }
}
