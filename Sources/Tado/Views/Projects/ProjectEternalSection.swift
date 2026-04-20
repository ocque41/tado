import SwiftUI
import SwiftData

/// Eternal zone on the project detail page. Shows a list of every
/// `EternalRun` for this project with per-run state + controls, plus
/// top-level "New Mega" / "New Sprint" buttons that always work —
/// the user can stack N concurrent runs on one project.
///
/// Per-run visual states:
/// - **drafted** — user created the run via "New …" but hasn't opened
///   the modal yet. Rare in practice (the button opens the modal
///   immediately); presented as an editable placeholder.
/// - **planning** — architect running, no crafted.md yet.
/// - **ready** — crafted.md on disk, worker not started.
/// - **running** — worker live; shows runtime + last progress + controls.
/// - **completed / stopped** — terminal. Shown in a collapsed
///   "Archived runs" accordion to keep the page readable.
///
/// Each row's state is computed fresh on every 2 s TimelineView tick by
/// reading the run's `.tado/eternal/runs/<id>/state.json`. That's
/// consistent with the single-run version this replaces — state.json is
/// still the source of truth; `run.state` is a cache.
struct ProjectEternalSection: View {
    let project: Project

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager

    @Query private var allRuns: [EternalRun]

    /// The run the user just clicked delete on — non-nil while the
    /// confirmation alert is open, nil otherwise. Using an `EternalRun?`
    /// rather than a bool lets the alert body show the run's label and
    /// state without extra plumbing.
    @State private var runPendingDelete: EternalRun? = nil

    /// Runs owned by this project, newest first. Filtering in Swift rather
    /// than via a `@Query` predicate because SwiftData's `#Predicate` macro
    /// chokes on the `project.id` comparison for UUID relationships in
    /// macOS 14.
    private var projectRuns: [EternalRun] {
        allRuns
            .filter { $0.project?.id == project.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var activeRuns: [EternalRun] {
        projectRuns.filter { run in
            let s = run.state
            return s == "drafted" || s == "planning" || s == "ready" || s == "running"
        }
    }

    private var archivedRuns: [EternalRun] {
        projectRuns.filter { run in
            let s = run.state
            return s == "completed" || s == "stopped"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ETERNAL")
                    .font(Typography.callout)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textSecondary)

                if !activeRuns.isEmpty {
                    Text("·  \(activeRuns.count) active")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }

                Spacer()

                newRunButtons
            }

            if activeRuns.isEmpty && archivedRuns.isEmpty {
                emptyCard
            } else {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    VStack(spacing: 8) {
                        ForEach(activeRuns, id: \.id) { run in
                            runRow(run: run)
                        }
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
                        Text("Archived runs · \(archivedRuns.count)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .alert("Delete \(runPendingDelete?.label ?? "run")?", isPresented: Binding(
            get: { runPendingDelete != nil },
            set: { if !$0 { runPendingDelete = nil } }
        ), presenting: runPendingDelete) { run in
            Button("Delete", role: .destructive) {
                EternalService.deleteRun(
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
            Text(deleteAlertMessage(for: run))
        }
    }

    /// Phrasing tuned to the run's current state so the user knows exactly
    /// what's about to disappear. A `running` delete is the most dangerous
    /// case — it kills the live worker, not just the SwiftData row.
    private func deleteAlertMessage(for run: EternalRun) -> String {
        switch run.state {
        case "running":
            return "The worker tile will be killed and the run's on-disk directory (`\(EternalService.eternalRoot(run).path)`) will be removed. progress.md, metrics.jsonl, and crafted.md go with it."
        case "planning":
            return "The architect tile will be killed. If crafted.md was partially written, it's lost."
        case "drafted":
            return "The run's on-disk directory will be removed. Nothing is running yet."
        default:
            return "The run's on-disk directory will be removed along with its SwiftData row. Can't be undone."
        }
    }

    // MARK: - New run buttons (always enabled)

    private var newRunButtons: some View {
        HStack(spacing: 8) {
            Button(action: { createAndEditRun(mode: "mega") }) {
                HStack(spacing: 4) {
                    Image(systemName: "infinity")
                    Text("New Mega")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button(action: { createAndEditRun(mode: "sprint") }) {
                HStack(spacing: 4) {
                    Image(systemName: "repeat")
                    Text("New Sprint")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Text("No eternal runs yet")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Text("A single agent that runs non-stop for hours or days. Pick a mode above — the Architect crafts the brief, then the worker runs the loop.")
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
    private func runRow(run: EternalRun) -> some View {
        let displayState = effectiveState(for: run)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statePill(state: displayState)
                Text(run.label)
                    .font(Typography.bodyBold)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text("·  \(run.mode == "sprint" ? "Sprint" : "Mega")")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                actionButtons(run: run, state: displayState)
            }
            if displayState == "running", let state = EternalService.readState(run) {
                runningMetaRow(run: run, state: state)
            }
        }
        .padding(12)
        .background(Palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor(for: displayState), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func archivedRow(run: EternalRun) -> some View {
        HStack(spacing: 10) {
            statePill(state: run.state)
            Text(run.label)
                .font(Typography.bodySm)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Text("·  \(run.mode == "sprint" ? "Sprint" : "Mega")")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            if let todoID = run.workerTodoID {
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
        case "drafted":   return ("DRAFT",     Palette.textSecondary)
        case "planning":  return ("PLANNING",  Palette.accent)
        case "ready":     return ("READY",     Palette.accent)
        case "running":   return ("RUNNING",   Palette.success)
        case "completed": return ("COMPLETED", Palette.success)
        case "stopped":   return ("STOPPED",   Palette.textSecondary)
        default:          return (state.uppercased(), Palette.textSecondary)
        }
    }

    private func borderColor(for state: String) -> Color {
        switch state {
        case "running":   return Palette.success.opacity(0.5)
        case "planning":  return Palette.accent.opacity(0.4)
        case "ready":     return Palette.accent.opacity(0.6)
        default:          return Palette.divider
        }
    }

    @ViewBuilder
    private func actionButtons(run: EternalRun, state: String) -> some View {
        HStack(spacing: 6) {
            switch state {
            case "drafted":
                smallButton("Edit", tint: Palette.textPrimary) {
                    appState.eternalModalRunID = run.id
                }
            case "planning":
                if let todoID = run.architectTodoID ?? run.workerTodoID {
                    smallButton("Canvas", tint: Palette.textSecondary) {
                        appState.pendingNavigationID = todoID
                        appState.currentView = .canvas
                    }
                }
                smallButton("Redo", tint: Palette.warning) {
                    appState.eternalModalRunID = run.id
                }
            case "ready":
                smallButton("Redo", tint: Palette.warning) {
                    appState.eternalModalRunID = run.id
                }
                smallButton("Start", tint: Palette.success) {
                    EternalService.spawnWorker(
                        run: run,
                        modelContext: modelContext,
                        terminalManager: terminalManager,
                        appState: appState
                    )
                }
            case "running":
                smallButton("Intervene", tint: Palette.accent) {
                    appState.eternalInterveneRunID = run.id
                }
                if let todoID = run.workerTodoID {
                    smallButton("Canvas", tint: Palette.textSecondary) {
                        appState.pendingNavigationID = todoID
                        appState.currentView = .canvas
                    }
                }
                smallButton("Stop", tint: Palette.danger) {
                    stop(run: run)
                }
            default:
                EmptyView()
            }
            // Trash affordance sits after the state-specific buttons. For
            // a running run this kills the worker AND wipes the run dir —
            // more destructive than Stop, which lets the wrapper exit
            // cleanly and keeps the progress log. Confirmation dialog
            // guards against misclicks.
            deleteButton(run: run)
        }
    }

    /// Small trash icon that arms the confirmation alert.
    @ViewBuilder
    private func deleteButton(run: EternalRun) -> some View {
        Button(action: { runPendingDelete = run }) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Palette.danger.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("Delete this run — kills its worker and wipes the on-disk run dir")
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

    @ViewBuilder
    private func runningMetaRow(run: EternalRun, state: EternalState) -> some View {
        let runtime = runtimeString(startedAt: state.startedAt)
        let metrics = EternalService.readMetrics(run)
        let effectiveSprint = effectiveSprintCount(state: state, metrics: metrics)
        HStack(spacing: 12) {
            metaPair(label: "RUNTIME", value: runtime)
            metaPair(label: "ITER", value: "\(state.iterations)")
            if run.mode == "sprint" {
                metaPair(label: "SPRINT", value: "\(effectiveSprint)")
                if let last = metrics.last?.metric {
                    metaPair(label: "METRIC", value: last.display)
                }
            }
            Spacer()
            if let last = state.lastProgressNote, !last.isEmpty {
                Text(last)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func metaPair(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Typography.microBold)
                .tracking(0.5)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(Typography.monoCallout)
                .foregroundStyle(Palette.textPrimary)
        }
    }

    private func runtimeString(startedAt: TimeInterval) -> String {
        let now = Date().timeIntervalSince1970
        let seconds = Int(max(0, now - startedAt))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%dh%02dm", h, m) }
        if m > 0 { return String(format: "%dm%02ds", m, s) }
        return "\(s)s"
    }

    private func effectiveSprintCount(state: EternalState, metrics: [EternalMetricSample]) -> Int {
        let maxMetricSprint = metrics.map(\.sprint).max() ?? 0
        return max(state.sprints, maxMetricSprint)
    }

    // MARK: - State reconciliation

    /// Prefer on-disk ground truth (state.json + crafted.md + active flag)
    /// over the cached `run.state` — the architect, worker, and stop hook
    /// all write to disk without touching SwiftData, so the Swift field
    /// lags behind the actual lifecycle. Three reconciliation rules:
    ///
    /// 1. **Hook fresh** (active flag + recent lastActivityAt) → `"running"`.
    /// 2. **planning + crafted.md on disk** → `"ready"`. Architect exited.
    /// 3. **running + state.json.phase in {"completed","stopped"}** → match
    ///    that phase. Worker stopped cleanly (ETERNAL-DONE or user Stop).
    ///
    /// Each branch self-heals `run.state` on a background task so the
    /// project-list card and other observers converge on the same value.
    private func effectiveState(for run: EternalRun) -> String {
        if EternalService.isHookFresh(run) {
            healIfNeeded(run: run, target: "running")
            return "running"
        }

        // Architect finished: crafted.md landed, no active flag yet.
        if run.state == "planning" && EternalService.craftedExistsOnDisk(run) {
            healIfNeeded(run: run, target: "ready")
            return "ready"
        }

        // Worker exited cleanly: state.json carries the terminal phase.
        if run.state == "running", let snapshot = EternalService.readState(run) {
            if snapshot.phase == "completed" {
                healIfNeeded(run: run, target: "completed")
                return "completed"
            }
            if snapshot.phase == "stopped" {
                healIfNeeded(run: run, target: "stopped")
                return "stopped"
            }
        }

        return run.state
    }

    private func healIfNeeded(run: EternalRun, target: String) {
        guard run.state != target else { return }
        Task { @MainActor in
            guard run.state != target else { return }
            NSLog(
                "ProjectEternalSection: self-heal run \(run.id) \(run.state) → \(target) (state.json fresh)"
            )
            run.state = target
            try? modelContext.save()
        }
    }

    // MARK: - Actions

    private func createAndEditRun(mode: String) {
        let run = EternalRun(
            project: project,
            label: EternalRun.defaultLabel(mode: mode),
            state: "drafted",
            mode: mode,
            userBrief: ""
        )
        modelContext.insert(run)
        try? modelContext.save()
        appState.eternalModalRunID = run.id
    }

    private func stop(run: EternalRun) {
        NSLog("ProjectEternalSection: user clicked Stop for run \(run.label)")
        EternalService.requestStop(run)
        run.state = "stopped"
        run.workerTodoID = nil
        try? modelContext.save()
    }
}
