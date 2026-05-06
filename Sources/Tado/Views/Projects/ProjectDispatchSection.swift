import SwiftUI
import SwiftData

/// Dispatch zone on the project detail page. Shows a list of every
/// `DispatchRun` for this project with per-run state + controls, plus a
/// top-level "New Dispatch" button that always creates a fresh run.
/// Two concurrent dispatches can coexist — each writes under its own
/// `.tado/dispatch/runs/<id>/` dir and namespaces its skills/agents with
/// the run short-id, so there's no cross-talk.
struct ProjectDispatchSection: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager

    @Query private var allRuns: [DispatchRun]

    /// Per-project lookup. Sorted newest-first.
    private var projectRuns: [DispatchRun] {
        allRuns
            .filter { $0.project?.id == project.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var activeRuns: [DispatchRun] {
        projectRuns.filter {
            $0.state == "drafted" || $0.state == "planning"
            || $0.state == "awaitingReview" || $0.state == "ready"
            || $0.state == "dispatching"
        }
    }

    private var archivedRuns: [DispatchRun] {
        projectRuns.filter { $0.state == "completed" }
    }

    @State private var showPlanNotReadyRunID: UUID? = nil
    /// Run the user clicked delete on; non-nil shows the confirmation alert.
    @State private var runPendingDelete: DispatchRun? = nil

    var body: some View {
        // Section header (DISPATCH label + count + "New plan" button)
        // is now drawn by the parent `SectionRail` in
        // `ProjectDetailView`, so the body renders only the runs list
        // + the empty-state block. Keeping the outer VStack so the
        // archived disclosure can sit below the active runs without
        // bleeding into the sibling section.
        VStack(alignment: .leading, spacing: 10) {
            if activeRuns.isEmpty && archivedRuns.isEmpty {
                emptyCard
            } else {
                VStack(spacing: 8) {
                    ForEach(activeRuns, id: \.id) { run in
                        runRow(run: run)
                    }
                }

                if !archivedRuns.isEmpty {
                    DisclosureGroup {
                        VStack(spacing: 6) {
                            ForEach(archivedRuns, id: \.id) { run in
                                archivedRow(run: run)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Archived dispatches · \(archivedRuns.count)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .alert("Architect still planning", isPresented: Binding(
            get: { showPlanNotReadyRunID != nil },
            set: { if !$0 { showPlanNotReadyRunID = nil } }
        )) {
            Button("OK", role: .cancel) { showPlanNotReadyRunID = nil }
        } message: {
            Text("The Dispatch Architect has not finished writing this run's plan yet. Watch its terminal on the canvas — once plan.json is on disk, try Start again.")
        }
        .alert("Delete \(runPendingDelete?.label ?? "dispatch")?", isPresented: Binding(
            get: { runPendingDelete != nil },
            set: { if !$0 { runPendingDelete = nil } }
        ), presenting: runPendingDelete) { run in
            Button("Delete", role: .destructive) {
                DispatchPlanService.deleteRun(
                    run,
                    modelContext: modelContext,
                    terminalManager: terminalManager
                )
                runPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                runPendingDelete = nil
            }
        } message: { run in
            Text("Any live architect or phase tiles for this dispatch will be killed and the run's on-disk directory will be removed. Per-phase skill/agent files under `.claude/` stay — they're namespaced by run short-id and don't collide with new dispatches.")
        }
    }

    private var newRunButton: some View {
        Button(action: createAndEditRun) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("New Dispatch")
            }
            .font(Typography.label)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.surfaceAccent)
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .buttonStyle(.plain)
    }

    /// Empty-state block matching the design's `dispatch-empty` —
    /// ASCII-art glyph, headline, subhead, and a help line set off
    /// by a dashed top border. Replaces the previous centered
    /// description card so an empty Dispatch section reads as
    /// scannable structure, not a dialog.
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("""
            ┌──────────────┐
            │    ░░░░░     │   no plans
            │  ░░    ░░    │
            │    ░░░░░     │
            └──────────────┘
            """)
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.bottom, 16)

            Text("No dispatch plans yet")
                .font(Font.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 4)

            Text("Describe a multi-phase super-project. Tado's Dispatch Architect will design the plan and launch the phases on your canvas.")
                .font(Font.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            Text("DISPATCH ARCHITECT  ·  runs >1 mega in sequence  ·  auto-spawns sprints between phases")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Palette.rule)
                        .frame(height: 1)
                        .padding(.horizontal, -2)
                }
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Run rows

    @ViewBuilder
    private func runRow(run: DispatchRun) -> some View {
        let displayState = effectiveState(for: run)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusPill.runState(displayState)
                Text(run.label)
                    .font(Font.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                let phaseCount = DispatchPlanService.phaseFileCount(run)
                if phaseCount > 0 {
                    Text("·  \(phaseCount) phase\(phaseCount == 1 ? "" : "s")")
                        .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
                Spacer()
                actionButtons(run: run, state: displayState)
            }
            if !run.brief.isEmpty {
                Text(briefPreview(run.brief))
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgElev)
        .overlay(alignment: .leading) {
            // Per-state leading accent stripe — same affordance the
            // ProjectCard uses; a subtle "this run is the one
            // demanding attention" cue.
            Rectangle()
                .fill(borderColor(for: displayState))
                .frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.rule)
                .frame(height: DK.ruleW)
        }
    }

    @ViewBuilder
    private func archivedRow(run: DispatchRun) -> some View {
        HStack(spacing: 10) {
            statePill(state: run.state)
            Text(run.label)
                .font(Typography.bodySm)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer()
            if let todoID = run.currentPhaseTodoID ?? run.architectTodoID {
                Button("Canvas") {
                    appState.pendingNavigationID = todoID
                    appState.currentView = .canvas
                }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            }
            deleteButton(run: run)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    /// Legacy state-pill helper — superseded by the design-kit
    /// `StatusPill` which carries the same labels but with proper
    /// outlined chrome and the design's pill-{variant} colour rules.
    /// Kept as a thin alias so archived rows that haven't been
    /// migrated yet still compile through one source of truth.
    @ViewBuilder
    private func statePill(state: String) -> some View {
        StatusPill.runState(state)
    }

    private func statePillStyle(state: String) -> (String, Color) {
        switch state {
        case "drafted":         return ("DRAFT",       Palette.textSecondary)
        case "planning":        return ("PLANNING",    Palette.accent)
        case "awaitingReview":  return ("REVIEW",      Palette.warning)
        case "ready":           return ("READY",       Palette.success)
        case "dispatching":     return ("DISPATCHING", Palette.accent)
        case "completed":       return ("COMPLETED",   Palette.success)
        default:                return (state.uppercased(), Palette.textSecondary)
        }
    }

    private func borderColor(for state: String) -> Color {
        switch state {
        case "dispatching":     return Palette.accent.opacity(0.5)
        case "planning":        return Palette.accent.opacity(0.3)
        case "awaitingReview":  return Palette.warning.opacity(0.6)
        case "ready":           return Palette.success.opacity(0.5)
        default:                return Palette.divider
        }
    }

    @ViewBuilder
    private func actionButtons(run: DispatchRun, state: String) -> some View {
        HStack(spacing: 6) {
            switch state {
            case "drafted":
                smallButton("Edit", tint: Palette.textPrimary) {
                    appState.dispatchModalRunID = run.id
                }
            case "planning":
                if let todoID = run.architectTodoID ?? run.currentPhaseTodoID {
                    smallButton("Canvas", tint: Palette.textSecondary) {
                        appState.pendingNavigationID = todoID
                        appState.currentView = .canvas
                    }
                }
                smallButton("Edit", tint: Palette.textSecondary) {
                    appState.dispatchModalRunID = run.id
                }
            case "awaitingReview":
                smallButton("Review", tint: Palette.warning) {
                    appState.craftedReviewKind = .dispatch
                    appState.craftedReviewRunID = run.id
                }
            case "ready":
                smallButton("Edit", tint: Palette.textSecondary) {
                    appState.dispatchModalRunID = run.id
                }
                smallButton("Start", tint: Palette.success) {
                    let launched = DispatchPlanService.startPhaseOne(
                        run: run,
                        modelContext: modelContext,
                        terminalManager: terminalManager,
                        appState: appState
                    )
                    if !launched {
                        showPlanNotReadyRunID = run.id
                    }
                }
            case "dispatching":
                if let todoID = run.currentPhaseTodoID ?? run.architectTodoID {
                    smallButton("Canvas", tint: Palette.accent) {
                        appState.pendingNavigationID = todoID
                        appState.currentView = .canvas
                    }
                }
                smallButton("Redo", tint: Palette.warning) {
                    appState.dispatchModalRunID = run.id
                }
            default:
                EmptyView()
            }
            deleteButton(run: run)
        }
    }

    @ViewBuilder
    private func deleteButton(run: DispatchRun) -> some View {
        Button(action: { runPendingDelete = run }) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Palette.danger.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("Delete this dispatch — kills its live tiles and wipes the on-disk run dir")
    }

    @ViewBuilder
    private func smallButton(_ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .buttonStyle(.plain)
    }

    /// First ~180 chars of the brief, trimmed. Matches the old single-run card.
    private func briefPreview(_ md: String) -> String {
        let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstParagraph = trimmed.split(separator: "\n\n", maxSplits: 1).first.map(String.init) ?? trimmed
        let limit = 180
        if firstParagraph.count <= limit { return firstParagraph }
        return firstParagraph.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // MARK: - State reconciliation

    /// Promote the display state when the architect has finished. The
    /// authoritative on-disk signal is `crafted.md` AND `plan.json` both
    /// existing; missing either means the architect is mid-write or
    /// crashed. The user's Accept action in the review modal is the only
    /// thing that flips state to "dispatching" by spawning phase 1.
    ///
    /// This is display-only: `run.state` stays at "planning" until the
    /// user accepts. That means restarting Tado on an unaccepted plan
    /// re-shows the Review button, which is exactly what we want.
    private func effectiveState(for run: DispatchRun) -> String {
        if run.state == "planning"
            && DispatchPlanService.planExistsOnDisk(run)
            && DispatchPlanService.craftedExistsOnDisk(run) {
            return "awaitingReview"
        }
        return run.state
    }

    // MARK: - Actions

    private func createAndEditRun() {
        let run = DispatchRun(
            project: project,
            label: DispatchRun.defaultLabel(),
            state: "drafted",
            brief: ""
        )
        modelContext.insert(run)
        try? modelContext.save()
        appState.dispatchModalRunID = run.id
    }
}
