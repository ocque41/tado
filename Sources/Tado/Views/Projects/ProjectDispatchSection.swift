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
        projectRuns.filter { $0.state == "drafted" || $0.state == "planning"
                             || $0.state == "ready" || $0.state == "dispatching" }
    }

    private var archivedRuns: [DispatchRun] {
        projectRuns.filter { $0.state == "completed" }
    }

    @State private var showPlanNotReadyRunID: UUID? = nil
    /// Run the user clicked delete on; non-nil shows the confirmation alert.
    @State private var runPendingDelete: DispatchRun? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("DISPATCH")
                    .font(Typography.callout)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textSecondary)

                if !activeRuns.isEmpty {
                    Text("·  \(activeRuns.count) active")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }

                Spacer()

                newRunButton
            }

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
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Text("No dispatch plans yet")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Text("Describe a multi-phase super-project. Tado's Dispatch Architect will design the plan and launch the phases on your canvas.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Palette.divider, style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Run rows

    @ViewBuilder
    private func runRow(run: DispatchRun) -> some View {
        let displayState = effectiveState(for: run)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statePill(state: displayState)
                Text(run.label)
                    .font(Typography.bodyBold)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                let phaseCount = DispatchPlanService.phaseFileCount(run)
                if phaseCount > 0 {
                    Text("·  \(phaseCount) phase\(phaseCount == 1 ? "" : "s")")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                actionButtons(run: run, state: displayState)
            }
            if !run.brief.isEmpty {
                Text(briefPreview(run.brief))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(12)
        .background(Palette.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor(for: displayState), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

    @ViewBuilder
    private func statePill(state: String) -> some View {
        let (label, color) = statePillStyle(state: state)
        Text(label)
            .font(Typography.microBold)
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func statePillStyle(state: String) -> (String, Color) {
        switch state {
        case "drafted":     return ("DRAFT",       Palette.textSecondary)
        case "planning":    return ("PLANNING",    Palette.accent)
        case "ready":       return ("READY",       Palette.success)
        case "dispatching": return ("DISPATCHING", Palette.accent)
        case "completed":   return ("COMPLETED",   Palette.success)
        default:            return (state.uppercased(), Palette.textSecondary)
        }
    }

    private func borderColor(for state: String) -> Color {
        switch state {
        case "dispatching": return Palette.accent.opacity(0.5)
        case "planning":    return Palette.accent.opacity(0.3)
        case "ready":       return Palette.success.opacity(0.5)
        default:            return Palette.divider
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
                .clipShape(RoundedRectangle(cornerRadius: 5))
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

    /// If the architect has written plan.json while `run.state` is still
    /// "planning", promote the display state to "ready" without mutating
    /// SwiftData on every render. The user's Start action is the only
    /// thing that flips state to "dispatching".
    private func effectiveState(for run: DispatchRun) -> String {
        if run.state == "planning" && DispatchPlanService.planExistsOnDisk(run) {
            return "ready"
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
