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
