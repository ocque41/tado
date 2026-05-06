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

                ProcessHygieneSection()

                DangerZoneSection()

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
                .fixedSize(horizontal: false, vertical: true)
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
                            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
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
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .padding(8)
        .background(Palette.surfaceAccentSoft)
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
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

/// v0.17 — operator-facing nuclear-option section. Houses the
/// "Reset Tado data" button that wipes every Tado-owned artifact in
/// the active storage root (vault, settings JSON, memory, events log,
/// SwiftData cache, backups). It deliberately does NOT touch any
/// per-project `.tado/` directories — those live inside the user's
/// project trees and are the user's own data.
///
/// The flow is intentionally annoying: type `DELETE` to confirm,
/// then a final `NSAlert.critical` with `hasDestructiveAction` on the
/// confirm button. After the wipe the daemon is checkpointed cleanly
/// (`tado_dome_stop`) and the app force-quits so the next launch
/// rebuilds a fresh storage root from defaults.
private struct DangerZoneSection: View {
    @State private var typedConfirmation: String = ""
    @State private var lastError: String?
    @State private var resetting = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("This deletes every Tado-owned artifact in the storage root: the Dome vault, settings JSON, user memory, events log, SwiftData cache, and backup tarballs. Files inside your project trees (including each project's `.tado/` folder) are NOT touched.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Storage root: \(StorePaths.root.path)")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                LabeledContent {
                    TextField("DELETE", text: $typedConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .disabled(resetting)
                } label: {
                    Text("Type DELETE to enable")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        confirmReset()
                    } label: {
                        if resetting {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Label("Reset Tado data", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.danger)
                    .disabled(resetting || typedConfirmation != "DELETE")
                }

                if let lastError {
                    Text(lastError)
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.danger)
                        .lineLimit(3)
                }
            }
        } header: {
            Text("Reset Tado data")
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset all Tado data?"
        alert.informativeText = """
            This deletes the entire Tado storage root at:
            \(StorePaths.root.path)

            That includes every saved project, todo, terminal log, automation occurrence, and Dome note. \
            Project files OUTSIDE the Tado storage root (your code, .tado/ directories inside each project) are NOT touched.

            Tado will quit immediately after the reset. Relaunching gives you a fresh app state.
            This action cannot be undone.
            """
        alert.addButton(withTitle: "Cancel")
        let confirm = alert.addButton(withTitle: "Reset and Quit")
        confirm.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runReset()
    }

    private func runReset() {
        resetting = true
        lastError = nil
        let root = StorePaths.root
        Task { @MainActor in
            await Task.detached {
                // Best-effort daemon checkpoint so the SQLite WAL
                // doesn't dirty-tear during the rmdir. The shim
                // returns immediately if the daemon never booted.
                DomeRpcClient.domeStop()
            }.value

            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: root.path) {
                    let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    for entry in entries {
                        // Keep the storage-location.json locator at
                        // the *default* root so the next launch
                        // doesn't try to re-attach to a deleted
                        // pending root.
                        if entry.lastPathComponent == StorageLocationManager.locatorFileName,
                           root.path == StorageLocationManager.defaultRoot.path {
                            continue
                        }
                        try fm.removeItem(at: entry)
                    }
                }
            } catch {
                resetting = false
                lastError = "Reset failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                return
            }
            // Hard quit so SwiftData / file watchers / extensions
            // don't write anything back into the now-empty store.
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - Process Hygiene (v0.18)

/// Settings section that surfaces the v0.18 zombie-process sweeper as
/// two operator-facing buttons:
///
/// 1. **Kill Zombies** — fires `DomeRpcClient.zombieSweep()` which
///    calls into `bt_core::zombie::sweep`. The Rust side enumerates
///    every process matching the `KILL_PATTERNS` substring list,
///    excludes the live Tado app's PID and its full ancestor chain
///    (the `make dev` tree that hosts this window), then issues a
///    process-group SIGKILL for each surviving target. Returns a
///    detailed result envelope that this view renders inline.
///
/// 2. **Make Sure** — writes a `SpawnRequest` to
///    `/tmp/tado-ipc/spawn-requests/<uuid>.json`; the IPCBroker
///    watcher picks it up and creates a fresh tile running the
///    user's preferred engine with the prompt produced by
///    `ProcessSpawner.makeSurePrompt`. The agent reads the sweeper
///    source as ground truth, independently audits the live process
///    table, and kills any survivors. Engine + model come from the
///    user's existing top-of-Settings picker — "based on
///    configuration" — so a single change there steers both regular
///    tile spawns AND the verifier.
///
/// Why these two buttons aren't merged into one
/// --------------------------------------------
/// The Rust sweeper is fast (sub-100ms), deterministic, and requires
/// no API tokens. The agent verifier is slow (15-60s), reasons about
/// edge cases, but burns model tokens and depends on a working LLM
/// session. Most days the operator just wants the fast button. The
/// verifier is the safety net for the rare case where the sweep
/// missed something (process forked between scan and kill, novel
/// pattern variant, etc.).
///
/// Destructive-action confirmation
/// -------------------------------
/// Per project rule 8, both actions show an `NSAlert` with
/// `alertStyle = .critical` and Cancel as the default button before
/// proceeding. The Kill Zombies alert lists the exact patterns the
/// Rust code matches (sourced from a one-time dry-run rather than
/// hardcoded in Swift, so the alert can never drift from the code).
private struct ProcessHygieneSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [AppSettings]

    @State private var lastSweep: DomeRpcClient.ZombieSweepResult?
    @State private var sweeping = false
    @State private var deploying = false
    @State private var lastError: String?
    @State private var showAllKilled = false
    @State private var showProtected = false

    /// Resolves the currently-configured engine from AppSettings.
    /// Falls back to `.claude` if no row exists yet (first launch).
    private var preferredEngine: TerminalEngine {
        settingsList.first?.engine ?? .claude
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tado spawns agent CLIs and MCP bridges in tiles. When a tile is force-quit, when a build crashes mid-spawn, or when the macOS Claude desktop auto-resumes agent-mode sessions, those subprocesses can survive as invisible orphans — accumulating CPU time and holding API connections in the background. The buttons below clean them up safely without touching this running Tado app or your `make dev` shell.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        confirmAndSweep()
                    } label: {
                        if sweeping {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Label("Kill Zombies", systemImage: "trash.slash")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.danger)
                    .disabled(sweeping || deploying)
                    .help(killZombiesTooltip)

                    Button {
                        confirmAndDeployVerifier()
                    } label: {
                        if deploying {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Label("Make Sure", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(sweeping || deploying)
                    .help(makeSureTooltip)

                    Spacer()
                }

                if let lastError {
                    Text(lastError)
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.danger)
                        .lineLimit(3)
                }

                if let sweep = lastSweep {
                    sweepSummary(sweep)
                }
            }
        } header: {
            Text("Process hygiene")
        }
    }

    // MARK: Tooltip prose
    //
    // The tooltip strings duplicate prose that's also in Rust (the
    // KILL_PATTERNS list, the protection algorithm). The Rust unit
    // test `pattern_list_is_locked_for_v018` asserts that the pattern
    // list is exactly the eight strings below; if you legitimately
    // change Rust, the test fails until you also update this Swift
    // text — a "tripwire" so operator-visible documentation can
    // never silently drift from what the code actually does.

    private var killZombiesTooltip: String {
        """
        Sweeps every process Tado spawned (or might have spawned) that's still alive across this and prior runs.

        WHAT GETS KILLED (substring match against full command line):
          • /release/Tado — stale Tado app instances from forced-quit prior launches
          • /Applications/Tado.app/ — same, when running the bundled .app
          • tado-mcp/dist/index.js — legacy Node MCP bridge (pre-v0.9.0)
          • target/release/tado-mcp — Rust MCP bridge orphans
          • target/release/dome-mcp — Dome MCP bridge orphans
          • target/release/tado-dome — scoped-knowledge CLI orphans
          • claude --output-format stream-json — Tado-spawned + Claude.app agent-mode sessions
          • codex --output-format stream-json — Codex agent-mode sessions

        WHAT STAYS ALIVE (protection algorithm):
          • This running Tado app (its own PID)
          • The `make dev` ancestor chain (Tado → swift run → make → shell → Terminal → launchd)
          • PID 1 (launchd) defensively
          • Any process whose process-group leader is in the protected set
          • Anything not matching the patterns above

        METHOD: SIGKILL via libc::killpg, hitting the entire foreground process group so subprocess trees die in one syscall. Result count + PIDs + commands appear inline below the buttons after the sweep finishes.

        SAFETY: The protection set is built BEFORE any kill is issued, walking up `getppid()` from the live Tado app's PID. A buggy caller cannot widen or narrow this set.
        """
    }

    private var makeSureTooltip: String {
        """
        Spawns a verification agent in a fresh Tado tile (using your currently-configured engine + model from the Engine section above) that:

          1. Reads the sweeper's Rust source as ground truth for what SHOULD have died
          2. Independently enumerates Tado-related processes via `ps`
          3. Cross-references with the protected ancestor chain
          4. Kills any survivors the in-process sweeper missed
          5. Prints a detailed verification report to its tile output

        Use this when:
          • You want a second opinion after a Kill Zombies sweep
          • You suspect a process forked between the sweeper's enumerate and kill phases
          • You suspect Tado spawned something the substring patterns don't yet match

        The agent operates under hard rules: never kill the protected ancestor chain, never use broad pkill patterns, abort if a sudo prompt appears.

        Engine: \(preferredEngine == .claude ? "Claude (set in Engine section above)" : "Codex (set in Engine section above)")
        """
    }

    // MARK: Sweep flow

    private func confirmAndSweep() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Run zombie sweep?"
        alert.informativeText = """
        This will SIGKILL every process whose command line matches any of the patterns listed in the tooltip — across this and prior runs of Tado.

        Your `make dev` shell, the swift run process hosting this window, the Terminal app, launchd, and this running Tado app are all protected. Anything else matching the patterns dies.

        Tile children of this running Tado app (claude / codex agents inside tiles) will also die. Their tiles will show as exited until you remove them from the canvas.

        This action cannot be undone. Re-spawning agents requires manually re-creating the tiles or rerunning the relevant todos.
        """
        alert.addButton(withTitle: "Cancel")
        let confirm = alert.addButton(withTitle: "Kill Zombies")
        confirm.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runSweep()
    }

    private func runSweep() {
        sweeping = true
        lastError = nil
        // The sweep is fast (~50-100ms) but bouncing through a
        // detached task keeps the UI responsive in pathological
        // cases (1000+ processes on the system) and matches the
        // pattern every other DomeRpcClient call in this view uses.
        Task { @MainActor in
            let result = await Task.detached { DomeRpcClient.zombieSweep(dryRun: false) }.value
            sweeping = false
            guard let result else {
                lastError = "Zombie sweep FFI returned null. Check Console.app for `[Tado]` log lines or try again."
                return
            }
            lastSweep = result
        }
    }

    // MARK: Verifier deploy flow

    private func confirmAndDeployVerifier() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Spawn the Make Sure verifier?"
        alert.informativeText = """
        This creates a new Tado tile running \(preferredEngine == .claude ? "Claude" : "Codex") with a prompt that audits the live process table and kills any Tado-related survivors the in-process sweeper missed.

        The agent will:
          • Read the sweeper's Rust source for context
          • Enumerate processes via `ps -eo pid,pgid,ppid,command`
          • Cross-reference with the protected ancestor chain (provided in its prompt)
          • Issue process-group SIGKILLs only against confirmed zombies
          • Print a verification report to its tile

        This costs LLM tokens (the verifier reads ~200 lines of Rust + analyzes process output). Use it as a safety net, not as the primary cleanup tool.
        """
        alert.addButton(withTitle: "Cancel")
        let confirm = alert.addButton(withTitle: "Spawn Verifier")
        confirm.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        deployVerifier()
    }

    private func deployVerifier() {
        deploying = true
        lastError = nil

        // Capture protection context FROM the most recent sweep
        // result if available. If the operator hits Make Sure
        // without having clicked Kill Zombies first, fall back to
        // a fresh dry-run sweep so the verifier always has an
        // accurate protected-PID list to work with.
        let baselineWork: () -> DomeRpcClient.ZombieSweepResult? = { [lastSweep] in
            if let lastSweep { return lastSweep }
            return DomeRpcClient.zombieSweep(dryRun: true)
        }

        Task { @MainActor in
            let baseline = await Task.detached(operation: baselineWork).value
            guard let baseline else {
                deploying = false
                lastError = "Could not gather protection baseline (sweeper FFI returned null)."
                return
            }

            let summary: String = {
                if lastSweep != nil {
                    return "Killed \(baseline.killed.filter { $0.killOutcome == "killed" }.count) of \(baseline.killed.count) matched processes; \(baseline.matchedButProtected.count) protected"
                }
                return "Dry-run baseline only — no in-process sweep ran before this verifier"
            }()

            let prompt = ProcessSpawner.makeSurePrompt(
                tadoRepoPath: tadoRepoPath(),
                ourPid: baseline.ourPid,
                protectedPids: baseline.protectedPids,
                sweepSummary: summary
            )

            let request = SpawnRequest(
                id: UUID(),
                prompt: prompt,
                agentName: nil,
                teamName: nil,
                projectName: nil,
                projectRoot: tadoRepoPath(),
                engine: preferredEngine.rawValue,
                requestedBy: "settings.process_hygiene.make_sure",
                timestamp: Date(),
                status: .pending
            )

            do {
                try writeSpawnRequest(request)
                deploying = false
                // The IPCBroker watcher picks up the file within
                // ~250ms (FSEvents debounce), creates a tile, and
                // the user sees it on the canvas. No further UI
                // feedback needed here — the tile IS the feedback.
            } catch {
                deploying = false
                lastError = "Spawn request write failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    /// Best-guess Tado repo root: the cwd if it has the well-known
    /// repo markers (Package.swift + tado-core/), otherwise nil. The
    /// agent uses this to find the sweeper source — if we can't
    /// resolve it, the prompt still works, the agent just has to
    /// search for the file.
    private func tadoRepoPath() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let marker = (cwd as NSString).appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: marker) {
            return cwd
        }
        // Bundled .app: the source isn't shipped, fall back to the
        // user's home — agent will need to grep. This branch is
        // rare in practice (developers run via `make dev`).
        return NSHomeDirectory()
    }

    /// Atomic write: serialize → write to <uuid>.json.tmp → rename.
    /// Mirrors the spawn-requests dir contract that IPCBroker reads.
    private func writeSpawnRequest(_ request: SpawnRequest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(request)
        let dir = URL(fileURLWithPath: "/tmp/tado-ipc")
            .appendingPathComponent("spawn-requests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("\(request.id.uuidString).json")
        let tmp = target.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    // MARK: Result rendering

    @ViewBuilder
    private func sweepSummary(_ sweep: DomeRpcClient.ZombieSweepResult) -> some View {
        let actuallyKilled = sweep.killed.filter { $0.killOutcome == "killed" || $0.killOutcome == "killed_pid_only" }
        let alreadyDead = sweep.killed.filter { $0.killOutcome == "esrch" }
        let failures = sweep.killed.filter {
            $0.killOutcome != "killed" && $0.killOutcome != "killed_pid_only" && $0.killOutcome != "esrch"
        }

        VStack(alignment: .leading, spacing: 6) {
            Divider()

            HStack(spacing: 12) {
                Label("\(actuallyKilled.count) killed", systemImage: "checkmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(actuallyKilled.isEmpty ? Palette.textSecondary : Palette.success)

                if alreadyDead.count > 0 {
                    Label("\(alreadyDead.count) already gone", systemImage: "circle.dashed")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }

                if failures.count > 0 {
                    Label("\(failures.count) failed", systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                }

                if sweep.matchedButProtected.count > 0 {
                    Label("\(sweep.matchedButProtected.count) protected", systemImage: "shield.fill")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }

                Spacer()

                Text("\(sweep.totalScanned) scanned")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
            }

            if !sweep.killed.isEmpty {
                DisclosureGroup(isExpanded: $showAllKilled) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sweep.killed) { row in
                            killRow(row, danger: row.killOutcome != "killed" && row.killOutcome != "killed_pid_only" && row.killOutcome != "esrch")
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Show kill log")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            if !sweep.matchedButProtected.isEmpty {
                DisclosureGroup(isExpanded: $showProtected) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sweep.matchedButProtected) { row in
                            killRow(row, danger: false)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Show protected (matched but spared)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func killRow(_ row: DomeRpcClient.KilledProcess, danger: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("PID \(row.pid)")
                .font(Typography.monoMicro)
                .foregroundStyle(danger ? Palette.danger : Palette.textTertiary)
                .frame(width: 80, alignment: .leading)
            Text(row.killOutcome)
                .font(Typography.monoMicro)
                .foregroundStyle(danger ? Palette.danger : Palette.textTertiary)
                .frame(width: 100, alignment: .leading)
            Text(row.command)
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
