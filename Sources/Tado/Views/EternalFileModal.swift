import SwiftUI
import SwiftData

/// Brief editor for Eternal — 1:1 structural peer of `DispatchFileModal`.
///
/// Accept → writes the brief into `project.eternalMarkdown`, transitions
/// `eternalState = "planning"`, and spawns the Eternal Architect using the
/// user's Settings model + effort. The section on the project detail page
/// then flips to the planning card until crafted.md lands, at which point
/// it flips to ready.
///
/// Best results come from picking Opus 4.7 + Auto effort in Settings and
/// running "Bootstrap Claude auto mode" on the project first; the modal
/// surfaces that recommendation in its footer.
///
/// No TASK/EVALUATE/IMPROVE fields here anymore — the architect derives
/// those from the raw brief. Fields the user sets:
///   - Mode (Mega or Sprint)
///   - The brief itself (one multiline text editor)
///   - Completion marker (single line)
///   - Skip-permissions toggle (default on, warns when flipped off)
struct EternalFileModal: View {
    /// The run this modal is editing. Created in a `drafted` state by the
    /// "New Mega" / "New Sprint" buttons in ProjectEternalSection before
    /// the modal is presented; Cancel leaves it in drafted (so the user
    /// can reopen + refine), Accept transitions to `planning`.
    let run: EternalRun

    @Environment(\.modelContext) private var modelContext
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var mode: String = "mega"
    @State private var loopKind: String = "external"
    @State private var engine: String = "claude"
    @State private var marker: String = "ETERNAL-DONE"
    @State private var skipPermissions: Bool = true
    @State private var kind: String = "general"
    @State private var showRedoAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modeSegmented
                    kindPicker
                    enginePicker
                    briefEditor
                    markerField
                    loopKindPicker
                    // FULL AUTO toggle only applies to external-mode workers
                    // (it flips `eternalSkipPermissionsFlag`, which the
                    // eternal-loop.sh wrapper reads to add
                    // `--dangerously-skip-permissions` to each `claude -p`).
                    // Internal mode uses `--permission-mode auto` regardless,
                    // so the toggle would be misleading there. Codex
                    // workers don't use this flag — Codex's analog ships
                    // baked into the codex eternal permission flags.
                    if loopKind == "external" && engine == "claude" {
                        fullAutoToggle
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

            Divider()
            footerHint
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Palette.background)
        .onAppear {
            draft = run.userBrief
            mode = run.mode.isEmpty ? "mega" : run.mode
            let storedMarker = run.completionMarker.trimmingCharacters(in: .whitespacesAndNewlines)
            marker = storedMarker.isEmpty ? "ETERNAL-DONE" : storedMarker
            skipPermissions = run.skipPermissions
            let storedKind = run.loopKind.trimmingCharacters(in: .whitespacesAndNewlines)
            loopKind = (storedKind == "internal") ? "internal" : "external"
            // Engine: existing runs default to whatever was stamped at
            // creation; brand-new runs (drafted state, never opened
            // before) inherit the user's global engine pick so the
            // sheet matches what they'd see for a regular tile.
            let storedEngine = run.engine.trimmingCharacters(in: .whitespacesAndNewlines)
            if storedEngine == "codex" {
                engine = "codex"
            } else if storedEngine == "claude" {
                engine = "claude"
            } else {
                engine = fetchSettingsEngine().rawValue
            }
            // Kind: pre-existing runs default to general; perf-flagged
            // runs preserve their flag across re-opens of the sheet.
            let storedRunKind = run.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            kind = (storedRunKind == "perf") ? "perf" : "general"
        }
        .alert("Delete architect's draft and re-plan?", isPresented: $showRedoAlert) {
            Button("Delete & Re-plan", role: .destructive) { commitAndSpawnArchitect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove .tado/eternal/crafted.md and spawn a fresh Eternal Architect on the canvas.")
        }
    }

    // MARK: - Top bar / footer

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                    Text("Cancel")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.danger.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Text("Eternal — \(run.project?.name ?? "unknown") · \(run.label)")
                .font(Typography.heading)
                .foregroundStyle(Palette.textPrimary)

            Spacer()

            Button(action: acceptTapped) {
                HStack(spacing: 4) {
                    Text("Accept")
                    Image(systemName: "checkmark")
                        .font(.system(size: 11))
                }
                .font(Typography.label)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? Palette.textSecondary
                                 : Palette.success)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.surfaceElevated)
    }

    private var footerHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Recommendation banner — explains the canonical "good" config
            // up front so the user doesn't discover the wrong combination
            // by stalling out hours into a Continuous run.
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accent)
                Text("For Continuous Claude, use Opus 4.7 + Auto effort and bootstrap auto mode first.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Accept starts the architect. Review its plan, then launch the worker.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                Spacer()
                Text("⌘↩ to Accept · Esc to Cancel")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.surfaceElevated)
    }

    // MARK: - Mode

    private var modeSegmented: some View {
        HStack(spacing: 8) {
            modeButton(label: "Mega", value: "mega")
            modeButton(label: "Sprint", value: "sprint")
            InfoTip(text: "Mega runs one long task. Sprint repeats improvement cycles until stopped or done.")
            Spacer()
        }
    }

    private func modeButton(label: String, value: String) -> some View {
        Button(action: { mode = value }) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(mode == value ? Palette.foreground : Palette.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(mode == value ? Palette.accent : Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Engine

    /// Picks the CLI the architect, worker, and interventor all run on.
    /// Defaults to the user's global engine setting on first open of a
    /// freshly drafted run; persists onto `run.engine` on Accept so a
    /// later edit reopens with the same choice. Continuous mode is
    /// Claude-only today, so the picker disables Codex when
    /// `loopKind == "internal"` (an explicit constraint surfaced as a
    /// hint subtitle below).
    /// Kind picker — `general` (default behavior) vs `perf` (the
    /// Performance step). Orthogonal to mode and loopKind. When set to
    /// `perf`, the architect prompt's `## PERFORMANCE` section is
    /// generated, the worker env carries `TADO_PERF_MODE=1`, and
    /// `stop.sh` enforces the `[PERF-OK]`-before-marker contract.
    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("KIND")
                    .font(Typography.microBold)
                    .tracking(0.8)
                    .foregroundStyle(Palette.textTertiary)
                InfoTip(text: "Performance runs must pass the perf gate before an iteration can close.")
            }
            HStack(spacing: 8) {
                kindButton(label: "General", value: "general")
                kindButton(label: "Performance", value: "perf")
                kindButton(label: "Sprint", value: "sprint")
                Spacer()
            }
            Text(kindSubtitle)
                .font(Typography.bodySm)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var kindSubtitle: String {
        switch kind {
        case "perf":
            return "Performance gate active. Each iteration must emit [PERF-OK] before finishing."
        case "sprint":
            return "Sprint gate active. Each iteration must emit [SCORE-OK] before finishing."
        default:
            return "Default Eternal behavior. No gate active."
        }
    }

    private func kindButton(label: String, value: String) -> some View {
        Button(action: { kind = value }) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(kind == value ? Palette.foreground : Palette.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(kind == value ? Palette.accent : Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .buttonStyle(.plain)
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("ENGINE")
                    .font(Typography.microBold)
                    .tracking(0.8)
                    .foregroundStyle(Palette.textTertiary)
                InfoTip(text: "Choose the CLI for the architect and worker.")
            }
            HStack(spacing: 8) {
                engineButton(label: "Claude Code", value: "claude")
                engineButton(label: "Codex", value: "codex")
                Spacer()
            }
            Text(engineSubtitle)
                .font(Typography.bodySm)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var engineSubtitle: String {
        if engine == "codex" && loopKind == "internal" {
            return "Continuous Codex keeps one session alive and resumes it when idle."
        } else if engine == "codex" {
            return "Codex uses your Codex model and effort settings."
        } else if loopKind == "internal" {
            return "Continuous Claude keeps one auto-mode session alive."
        } else {
            return "Claude uses your Claude model and effort settings."
        }
    }

    private func engineButton(label: String, value: String) -> some View {
        Button(action: { engine = value }) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(engine == value ? Palette.foreground : Palette.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(engine == value ? Palette.accent : Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .buttonStyle(.plain)
    }

    private func fetchSettingsEngine() -> TerminalEngine {
        var descriptor = FetchDescriptor<AppSettings>()
        descriptor.fetchLimit = 1
        let settings = (try? modelContext.fetch(descriptor))?.first
        return settings?.engine ?? .claude
    }

    // MARK: - Brief editor

    private var briefEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BRIEF")
                .font(Typography.microBold)
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
            Text("Describe the goal in plain language.")
                .font(Typography.bodySm)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(mode == "sprint"
                         ? "Example: Optimize the dispatch architect prompt. Every sprint, run evals against a fixed project, score composite, tune one knob."
                         : "Example: Ship a full CLI scaffold generator in Bun — 10 subcommands, tests, README, npm publish script.")
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) || press.modifiers.contains(.control) else {
                            return .ignored
                        }
                        acceptTapped()
                        return .handled
                    }
            }
            .frame(minHeight: 200)
            .background(Palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
    }

    // MARK: - Marker

    private var markerField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COMPLETION MARKER")
                .font(Typography.microBold)
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
            Text("The worker prints this exact line when done.")
                .font(Typography.bodySm)
                .foregroundStyle(Palette.textSecondary)
            TextField("ETERNAL-DONE", text: $marker)
                .textFieldStyle(.plain)
                .font(Typography.monoCallout)
                .foregroundStyle(Palette.textPrimary)
                .padding(10)
                .background(Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
    }

    // MARK: - Loop kind

    private var loopKindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("SESSION STYLE")
                    .font(Typography.microBold)
                    .tracking(0.8)
                    .foregroundStyle(Palette.textTertiary)
                InfoTip(text: "Normal starts fresh each turn. Continuous keeps one session alive.")
            }
            HStack(spacing: 8) {
                loopKindButton(label: "Normal (per-turn)", value: "external")
                loopKindButton(label: "Continuous", value: "internal")
                Spacer()
            }
            // Subtitle that swaps with the selection. Surfaces the
            // auto-mode + Opus-4.7 + Bootstrap-prerequisite constraints
            // for Continuous so a user on the wrong plan or pre-Bootstrap
            // finds out before starting, not three hours into a stalled
            // session.
            Text(loopKindSubtitle)
                .font(Typography.bodySm)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loopKindSubtitle: String {
        if loopKind == "internal" && engine == "codex" {
            return "One Codex session stays alive and resumes when it needs input."
        } else if loopKind == "internal" {
            return "Requires Claude auto mode. Bootstrap the project first."
        } else if engine == "codex" {
            return "Starts a fresh Codex turn each iteration."
        } else {
            return "Starts a fresh Claude turn each iteration."
        }
    }

    private func loopKindButton(label: String, value: String) -> some View {
        Button(action: { loopKind = value }) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(loopKind == value ? Palette.foreground : Palette.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(loopKind == value ? Palette.accent : Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Full Auto

    private var fullAutoToggle: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: $skipPermissions) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)

            HStack(spacing: 6) {
                Text("SKIP PROMPTS (EXTERNAL)")
                    .font(Typography.microBold)
                    .tracking(0.8)
                    .foregroundStyle(skipPermissions ? Palette.success : Palette.warning)
                InfoTip(text: "Skips Claude permission prompts in Normal mode. Continuous mode uses auto mode.")
            }

            Spacer()
        }
        .padding(12)
        .background(skipPermissions ? Palette.surfaceElevated : Palette.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    // MARK: - Actions

    private func acceptTapped() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // If the run already has a crafted.md (section was `ready` when the
        // user opened Edit), Accept means "throw away the architect's draft
        // and re-plan". Confirm — destructive.
        if EternalService.craftedExistsOnDisk(run)
            || run.state == "running"
            || run.state == "planning" {
            showRedoAlert = true
        } else {
            commitAndSpawnArchitect()
        }
    }

    private func commitAndSpawnArchitect() {
        let trimmedMarker = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        run.userBrief = draft
        run.mode = mode
        run.completionMarker = trimmedMarker.isEmpty ? "ETERNAL-DONE" : trimmedMarker
        run.skipPermissions = skipPermissions
        run.loopKind = (loopKind == "internal") ? "internal" : "external"
        run.engine = (engine == "codex") ? "codex" : "claude"
        run.kind = ["perf", "sprint"].contains(kind) ? kind : "general"
        // Refresh the default label when the mode flips (user may have
        // opened the modal via "New Mega" then switched to Sprint).
        run.label = EternalRun.defaultLabel(mode: mode, createdAt: run.createdAt)
        try? modelContext.save()

        EternalService.spawnArchitect(
            run: run,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        dismiss()
    }
}
