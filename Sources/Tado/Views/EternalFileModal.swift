import SwiftUI
import SwiftData

/// Brief editor for Eternal — 1:1 structural peer of `DispatchFileModal`.
///
/// Accept → writes the brief into `project.eternalMarkdown`, transitions
/// `eternalState = "planning"`, and spawns the Eternal Architect (Opus 4.7
/// max effort). The section on the project detail page then flips to the
/// planning card until crafted.md lands, at which point it flips to ready.
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
    @State private var marker: String = "ETERNAL-DONE"
    @State private var skipPermissions: Bool = true
    @State private var showRedoAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modeSegmented
                    briefEditor
                    markerField
                    loopKindPicker
                    // FULL AUTO toggle only applies to external-mode workers
                    // (it flips `eternalSkipPermissionsFlag`, which the
                    // eternal-loop.sh wrapper reads to add
                    // `--dangerously-skip-permissions` to each `claude -p`).
                    // Internal mode uses `--permission-mode auto` regardless,
                    // so the toggle would be misleading there.
                    if loopKind == "external" {
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
        HStack {
            Text("Accept spawns the Eternal Architect (Opus 4.7 max) on the canvas. It will craft the worker brief; you then click Start on the Eternal section.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
            Spacer()
            Text("⌘↩ to Accept · Esc to Cancel")
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize()
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
                .foregroundStyle(mode == value ? .white : Palette.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(mode == value ? Palette.accent : Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
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
            }
            .frame(minHeight: 200)
            .background(Palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
        if loopKind == "internal" {
            return "Uses `--permission-mode auto` — Claude Code's classifier-gated autonomy mode, available for Opus 4.7 on Max/Teams/Enterprise plans. A classifier judges each tool call so the worker runs without babysitting. Run \"Bootstrap Claude auto mode\" from the project ⋯ menu first to install the required settings. Tado pins Opus 4.7 for Continuous runs automatically."
        } else {
            return "Fresh `claude -p` per turn via the eternal-loop.sh wrapper. Model follows Settings; the bypass toggle below controls per-turn `--dangerously-skip-permissions`."
        }
    }

    private func loopKindButton(label: String, value: String) -> some View {
        Button(action: { loopKind = value }) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(loopKind == value ? .white : Palette.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(loopKind == value ? Palette.accent : Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
