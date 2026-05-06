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
                Text("Best results: pick Opus 4.7 + Auto effort in Settings and run \"Bootstrap Claude auto mode\" on the project. Architect and worker both follow your Settings picks — Tado no longer pins Opus 4.7 / max effort behind your back.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Accept spawns the Eternal Architect on the canvas using your Settings model + effort. It crafts the worker brief; you then review the plan and click Accept to launch the worker.")
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
            InfoTip(text: "Mega: one long plan executed end-to-end, single crafted.md, stops when the plan is complete. Sprint: repeating improvement cycles (implement → evaluate → improve) that run forever until you stop them or the done marker fires.")
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
                InfoTip(text: "General runs work as before. Performance runs measure the project's eight curated perf dimensions every iteration and refuse to close the iteration until [PERF-OK] is in the transcript. The worker auto-detects the project's stack (Rust, Swift, Node, Python, Go, polyglot) and uses the universal IMPROVE ladder + EVAL stencils from bench/PERF_KNOBS.md.")
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
            return "Performance step active. Each iteration runs perf-suite (algorithmic complexity, alloc count, critical-path ops, IO syscalls, DB query cost, cross-process roundtrips, cold-start ops, steady-state RSS ratio) and scores against the project's all-time-best baseline at .tado/perf-baselines/<project>.json. The worker MUST clear the perf gate ([PERF-OK]) before printing [SPRINT-DONE] or ETERNAL-DONE. Same-turn pay-back required on regression."
        case "sprint":
            return "Sprint rules optimization active. Each iteration proposes ONE change to sprint_rules.txt (the methodology under optimization), records a measured row in sprint-data.json, and runs sprint-gate.sh. The gate computes SprintSuccessScore = (points_completed/total_points_planned*100) + (code_review_passes*2) - (bugs_found_after_sprint*10) + (developer_satisfaction_score*5) and ratchets the all-time-best baseline at .tado/sprint-baselines/<project>.json. Per-component guards: bugs cannot rise; reviews cannot drop. The worker MUST clear the sprint gate ([SCORE-OK]) before printing [SPRINT-DONE] or ETERNAL-DONE."
        default:
            return "Default Eternal behavior — the architect designs the brief, the worker iterates per the chosen mode, no gate active."
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
                InfoTip(text: "Which CLI runs the architect + worker. Claude Code uses --permission-mode auto / bypassPermissions for non-stop runs. Codex uses --ask-for-approval never --sandbox danger-full-access. Both engines work for Normal (per-turn) AND Continuous (one-session) loops.")
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
            return "Continuous Codex: one interactive `codex` session stays alive for the run. Tado's idle-injection re-fires the continue prompt every time the session goes idle. Codex's `--ask-for-approval never --sandbox danger-full-access` keeps the worker non-stop. There's no `/loop` secondary driver — Codex doesn't have one — so the idle injection is the only driver."
        } else if engine == "codex" {
            return "Codex runs through the Tado embed shim plus `--ask-for-approval never --sandbox danger-full-access` so the worker never stalls on an approval prompt. Architect, worker, and interventor all use your Codex model + effort settings."
        } else if loopKind == "internal" {
            return "Continuous Claude: one interactive `claude --permission-mode auto` session, with Tado's idle injection AND `/loop 30s …` as parallel drivers. Requires Opus 4.7 + Bootstrap Claude auto mode on the project."
        } else {
            return "Claude Code runs with `--permission-mode auto` / `bypassPermissions` per-iteration. Architect, worker, and interventor all use your Claude model + effort settings."
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
            Text("Say in plain language what you want. A few sentences is fine — the Eternal Architect (Opus 4.7 max) structures it for you.")
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
            Text("Claude outputs this exact string on its own line when the task is fully done. The Stop hook watches for it.")
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
                InfoTip(text: "Normal: fresh `claude -p` spawns every turn via the eternal-loop wrapper. Cheap tokens, no mid-turn memory (each iteration re-reads crafted.md + progress.md). Default and reliable. Continuous: one interactive `claude` session stays alive for the whole run. Context grows and auto-compacts; Tado injects a \"continue\" prompt on idle and installs `/loop` as backup. Requires auto mode — Bootstrap the project first.")
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
            return "Continuous Codex: one interactive `codex` session stays alive for the run; Tado's idle-injection re-fires the continue prompt on every `.needsInput`. Codex doesn't have an equivalent of Claude's `/loop` secondary driver, so the idle injection is the only driver. Works without any Bootstrap step — `--ask-for-approval never --sandbox danger-full-access` is wired in automatically."
        } else if loopKind == "internal" {
            return "Uses `--permission-mode auto` — Claude Code's classifier-gated autonomy mode, available for Opus 4.7 on Max/Teams/Enterprise plans. A classifier judges each tool call so the worker runs without babysitting. Run \"Bootstrap Claude auto mode\" from the project ⋯ menu first to install the required settings. Architect and worker both follow your Settings model + effort picks — works best with Opus 4.7 + Auto effort selected; smaller models or non-auto effort can stall on the auto-mode classifier."
        } else if engine == "codex" {
            return "Fresh `codex \"<prompt>\"` per turn via the eternal-loop.sh wrapper. Architect and worker both follow your Codex model + effort settings; `--ask-for-approval never --sandbox danger-full-access` is wired in automatically."
        } else {
            return "Fresh `claude -p` per turn via the eternal-loop.sh wrapper. Architect and worker both follow your Settings model + effort picks; the bypass toggle below controls per-turn `--dangerously-skip-permissions`."
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
                InfoTip(text: "Passes --dangerously-skip-permissions to the external-mode `claude -p` wrapper on every turn. On (default): agent runs non-stop without permission prompts. Off: agent pauses on any tool Claude considers dangerous, which will stall an eternal run — you almost certainly don't want this. Has no effect on Continuous mode (that uses --permission-mode auto regardless).")
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
