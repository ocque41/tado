import SwiftUI
import SwiftData

enum AgentWorkKind: String, CaseIterable, Equatable {
    case liveTile
    case todo
    case eternal
    case dispatch

    var label: String {
        switch self {
        case .liveTile: return "Tile"
        case .todo: return "Todo"
        case .eternal: return "Eternal"
        case .dispatch: return "Dispatch"
        }
    }
}

struct AgentWorkRow: Identifiable, Equatable {
    let id: String
    let kind: AgentWorkKind
    let title: String
    let subtitle: String
    let status: String
    let projectName: String?
    let createdAt: Date
    let todoID: UUID?
    let sessionID: UUID?
    let runID: UUID?
    let promptable: Bool

    static func idForTile(_ todoID: UUID) -> String { "tile:\(todoID.uuidString)" }
    static func idForTodo(_ todoID: UUID) -> String { "todo:\(todoID.uuidString)" }
    static func idForEternal(_ runID: UUID) -> String { "eternal:\(runID.uuidString)" }
    static func idForDispatch(_ runID: UUID) -> String { "dispatch:\(runID.uuidString)" }
}

enum AgentWorkSorter {
    static func sorted(_ rows: [AgentWorkRow]) -> [AgentWorkRow] {
        rows.sorted { lhs, rhs in
            let l = priority(lhs)
            let r = priority(rhs)
            if l != r { return l < r }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func priority(_ row: AgentWorkRow) -> Int {
        let raw = row.status
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        if raw == "needsinput" || raw == "awaitingresponse" || raw == "awaitingreview" {
            return 0
        }
        if raw == "running" || raw == "dispatching" {
            return 1
        }
        if raw == "planning" || raw == "queued" || raw == "pending" || raw == "drafted" || raw == "ready" {
            return 2
        }
        return 3
    }
}

struct RelaySessionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.relayTheme) private var theme

    @Query private var todos: [TodoItem]
    @Query private var projects: [Project]
    @Query private var teams: [Team]
    @Query private var eternalRuns: [EternalRun]
    @Query private var dispatchRuns: [DispatchRun]
    @Query private var settingsRows: [AppSettings]

    @State private var selectedRowID: String?
    @State private var draft: String = ""
    @State private var notice: String?
    @State private var errorText: String?
    @FocusState private var promptFocused: Bool

    private var rows: [AgentWorkRow] {
        AgentWorkSorter.sorted(makeRows())
    }

    private var selectedRow: AgentWorkRow? {
        rows.first { $0.id == selectedRowID } ?? rows.first
    }

    private var liveTodoIDs: Set<UUID> {
        Set(terminalManager.sessions.map(\.todoID))
    }

    private var projectByID: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    private var activeTodos: [TodoItem] {
        todos.filter { $0.listState == .active }
    }

    private var needsAttentionCount: Int {
        rows.filter { AgentWorkSorter.priority($0) == 0 }.count
    }

    private var runningCount: Int {
        rows.filter { AgentWorkSorter.priority($0) == 1 }.count
    }

    var body: some View {
        RelayPageContainer {
            RelayPageHead(
                kicker: "STRUCTURE - AGENT VIEW",
                title: "Agent View",
                lead: "All active tiles, todos, Eternal runs, and Dispatch runs in one keyboard-first work queue.",
                h1Size: 52
            )

            statStrip

            VStack(alignment: .leading, spacing: 16) {
                workSurface
                promptBar
            }
            .onAppear {
                ensureSelection()
                promptFocused = true
            }
            .onChange(of: rows.map(\.id)) { _, _ in
                ensureSelection()
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.escape) {
                if draft.isEmpty {
                    promptFocused = false
                } else {
                    draft = ""
                }
                return .handled
            }
            .onKeyPress(phases: .down) { press in
                if press.key == KeyEquivalent("o"),
                   press.modifiers.contains(.command) {
                    openSelected()
                    return .handled
                }
                return .ignored
            }
        }
    }

    private var statStrip: some View {
        RelayStatStrip(stats: [
            RelayStat("WORK", "\(rows.count)"),
            RelayStat("NEEDS INPUT", "\(needsAttentionCount)", meta: needsAttentionCount > 0 ? "● Review" : nil, metaTint: RelayPalette.terracotta),
            RelayStat("RUNNING", "\(runningCount)"),
            RelayStat("RUNS", "\(eternalRuns.filter { $0.archivedAt == nil }.count + dispatchRuns.filter { $0.archivedAt == nil }.count)"),
        ])
    }

    private var workSurface: some View {
        HStack(alignment: .top, spacing: 16) {
            workList
                .frame(minWidth: 460, maxWidth: .infinity, minHeight: 460, alignment: .top)
            inspector
                .frame(width: 340, alignment: .top)
                .frame(minHeight: 460, alignment: .top)
        }
    }

    private var workList: some View {
        RelayCard(noPadding: true) {
            VStack(spacing: 0) {
                HStack {
                    RelayKicker(text: "ACTIVE WORK")
                    Spacer()
                    Text("Up/Down select - Enter send - Cmd+O open")
                        .font(Typography.sans(size: 11, weight: .medium))
                        .foregroundStyle(RelayPalette.foreground3(for: theme))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Rectangle()
                    .fill(RelayPalette.hair(for: theme))
                    .frame(height: 1)

                if rows.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                agentRow(row)
                            }
                        }
                    }
                    .frame(minHeight: 390)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No active work.")
                .font(RelayType.h2(size: 22))
                .foregroundStyle(RelayPalette.foreground(for: theme))
            Text("Create a todo or start an Eternal or Dispatch run to populate this queue.")
                .font(Typography.sans(size: 13, weight: .regular))
                .foregroundStyle(RelayPalette.foreground2(for: theme))
            RelayButton(label: "Open Todos", variant: .standard) {
                appState.currentView = .todos
            }
        }
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .topLeading)
        .padding(22)
    }

    private func agentRow(_ row: AgentWorkRow) -> some View {
        let selected = row.id == selectedRow?.id
        return Button {
            selectedRowID = row.id
            promptFocused = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RelayStatusDot(kind: dotKind(for: row), size: 7)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.title)
                            .font(Typography.sans(size: 14, weight: .semibold))
                            .foregroundStyle(RelayPalette.foreground(for: theme))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        RelayPill(label: row.kind.label, variant: .soft)
                    }
                    Text(row.subtitle)
                        .font(Typography.sans(size: 12, weight: .regular))
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        RelayPill(label: statusLabel(row.status), variant: pillVariant(for: row))
                        Text(row.projectName ?? "No project")
                            .font(Typography.sans(size: 11, weight: .medium))
                            .foregroundStyle(RelayPalette.foreground3(for: theme))
                            .lineLimit(1)
                        Spacer()
                        Text(elapsedString(row.createdAt))
                            .font(Typography.sans(size: 11, weight: .medium))
                            .foregroundStyle(RelayPalette.foreground3(for: theme))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RelayPalette.wash(for: theme) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(RelayPalette.hairSoft(for: theme))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var inspector: some View {
        RelayCard {
            if let row = selectedRow {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            RelayKicker(text: "INSPECTOR")
                            Text(row.title)
                                .font(RelayType.h2(size: 24))
                                .foregroundStyle(RelayPalette.foreground(for: theme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        RelayStatusDot(kind: dotKind(for: row), size: 8)
                    }

                    detailLines(row)

                    Rectangle()
                        .fill(RelayPalette.hair(for: theme))
                        .frame(height: 1)

                    Text(actionCopy(for: row))
                        .font(Typography.sans(size: 13, weight: .regular))
                        .lineSpacing(4)
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                        .fixedSize(horizontal: false, vertical: true)

                    actionButtons(row)

                    if let notice {
                        feedbackText(notice, color: RelayPalette.foreground2(for: theme))
                    }
                    if let errorText {
                        feedbackText(errorText, color: RelayPalette.terracotta)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    RelayKicker(text: "INSPECTOR")
                    Text("Select work to inspect.")
                        .font(Typography.sans(size: 14, weight: .regular))
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                }
            }
        }
    }

    private func detailLines(_ row: AgentWorkRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailLine("Type", row.kind.label)
            detailLine("Status", statusLabel(row.status))
            detailLine("Project", row.projectName ?? "No project")
            if let todoID = row.todoID {
                detailLine("Todo", String(todoID.uuidString.prefix(8)).lowercased())
            }
            if let runID = row.runID {
                detailLine("Run", String(runID.uuidString.prefix(8)).lowercased())
            }
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(Typography.sans(size: 10, weight: .semibold))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(Typography.sans(size: 13, weight: .regular))
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func actionButtons(_ row: AgentWorkRow) -> some View {
        HStack(spacing: 8) {
            RelayButton(label: row.kind == .todo ? "Spawn" : "Open", variant: .standard) {
                if row.kind == .todo {
                    spawnTodo(row)
                } else {
                    openSelected()
                }
            }
        }
    }

    private var promptBar: some View {
        RelayCard(noPadding: true) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                TextField(promptPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typography.sans(size: 15, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                    .focused($promptFocused)
                    .onSubmit { sendPrompt() }
                RelayButton(label: "Send", variant: .primary) {
                    sendPrompt()
                }
                .disabled(selectedRow?.promptable != true || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var promptPlaceholder: String {
        guard let row = selectedRow else { return "Prompt selected work" }
        if row.promptable { return "Prompt \(row.kind.label.lowercased()): \(row.title)" }
        return "Select a live tile or run to send a follow-up"
    }

    private func makeRows() -> [AgentWorkRow] {
        let liveRows = terminalManager.sessions.map { session in
            let todo = todos.first { $0.id == session.todoID }
            let project = session.projectID.flatMap { projectByID[$0] } ?? todo?.projectID.flatMap { projectByID[$0] }
            return AgentWorkRow(
                id: AgentWorkRow.idForTile(session.todoID),
                kind: .liveTile,
                title: session.todoText,
                subtitle: session.agentName.map { "Agent \($0)" } ?? "Live terminal tile",
                status: session.status.rawValue,
                projectName: session.projectName ?? project?.name,
                createdAt: todo?.createdAt ?? Date.distantPast,
                todoID: session.todoID,
                sessionID: session.id,
                runID: session.eternalRunID ?? session.dispatchRunID,
                promptable: true
            )
        }

        let todoRows = activeTodos
            .filter { !liveTodoIDs.contains($0.id) }
            .map { todo in
                AgentWorkRow(
                    id: AgentWorkRow.idForTodo(todo.id),
                    kind: .todo,
                    title: todo.text,
                    subtitle: todo.agentName.map { "Queued for \($0)" } ?? "Active todo without a live tile",
                    status: todo.status.rawValue,
                    projectName: todo.projectID.flatMap { projectByID[$0]?.name },
                    createdAt: todo.createdAt,
                    todoID: todo.id,
                    sessionID: nil,
                    runID: nil,
                    promptable: false
                )
            }

        let eternalRows = eternalRuns
            .filter { $0.archivedAt == nil }
            .map { run in
                AgentWorkRow(
                    id: AgentWorkRow.idForEternal(run.id),
                    kind: .eternal,
                    title: run.label,
                    subtitle: "\(run.mode.capitalized) · \(run.engine)",
                    status: run.state,
                    projectName: run.project?.name,
                    createdAt: run.createdAt,
                    todoID: run.workerTodoID ?? run.architectTodoID,
                    sessionID: nil,
                    runID: run.id,
                    promptable: true
                )
            }

        let dispatchRows = dispatchRuns
            .filter { $0.archivedAt == nil }
            .map { run in
                AgentWorkRow(
                    id: AgentWorkRow.idForDispatch(run.id),
                    kind: .dispatch,
                    title: run.label,
                    subtitle: "Dispatch \(run.shortID)",
                    status: run.state,
                    projectName: run.project?.name,
                    createdAt: run.createdAt,
                    todoID: run.currentPhaseTodoID ?? run.architectTodoID,
                    sessionID: nil,
                    runID: run.id,
                    promptable: true
                )
            }

        return liveRows + todoRows + eternalRows + dispatchRows
    }

    private func sendPrompt() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let row = selectedRow else { return }
        notice = nil
        errorText = nil

        do {
            switch row.kind {
            case .liveTile:
                guard let todoID = row.todoID else { return }
                terminalManager.forwardInput(toTodoID: todoID, text: message)
                notice = "Sent to tile."
                draft = ""
            case .eternal:
                guard let runID = row.runID,
                      let run = eternalRuns.first(where: { $0.id == runID }) else { return }
                _ = try RunInterventionWriter.writeEternal(run: run, directive: message)
                notice = "Dropped into Eternal inbox."
                draft = ""
            case .dispatch:
                guard let runID = row.runID,
                      let run = dispatchRuns.first(where: { $0.id == runID }) else { return }
                _ = try RunInterventionWriter.sendDispatch(run: run, directive: message, terminalManager: terminalManager)
                notice = "Queued into Dispatch tile."
                draft = ""
            case .todo:
                errorText = "This todo has no live session. Spawn it first."
            }
        } catch RunInterventionWriter.InterventionError.noDispatchTarget {
            errorText = "Dispatch has no active phase or architect tile."
        } catch RunInterventionWriter.InterventionError.noLiveSession {
            errorText = "Dispatch target tile is not live."
        } catch {
            errorText = error.localizedDescription
        }
        promptFocused = true
    }

    private func spawnTodo(_ row: AgentWorkRow) {
        guard let todoID = row.todoID,
              let todo = todos.first(where: { $0.id == todoID }) else { return }
        let project = todo.projectID.flatMap { projectByID[$0] }
        let team = todo.teamID.flatMap { teamID in teams.first { $0.id == teamID } }
        let settingsEngine = settingsRows.first?.engine ?? .claude
        let engine: TerminalEngine = {
            if let agentName = todo.agentName, let root = project?.rootPath,
               let resolved = AgentDiscoveryService.resolveEngine(agentName: agentName, projectRoot: root) {
                return resolved
            }
            return settingsEngine
        }()

        terminalManager.spawnAndWire(
            todo: todo,
            engine: engine,
            cwd: project?.rootPath,
            agentName: todo.agentName,
            projectName: project?.name,
            teamName: team?.name,
            teamID: team?.id,
            teamAgents: team?.agentNames
        )
        try? modelContext.save()
        selectedRowID = AgentWorkRow.idForTile(todo.id)
        notice = "Spawned tile."
        errorText = nil
        promptFocused = true
    }

    private func openSelected() {
        guard let row = selectedRow else { return }
        switch row.kind {
        case .liveTile:
            if let todoID = row.todoID {
                appState.focusedTileModalTodoID = todoID
            }
        case .todo:
            appState.currentView = .todos
        case .eternal:
            appState.eternalModalRunID = row.runID
        case .dispatch:
            appState.dispatchModalRunID = row.runID
        }
    }

    private func ensureSelection() {
        guard !rows.isEmpty else {
            selectedRowID = nil
            return
        }
        if selectedRowID == nil || !rows.contains(where: { $0.id == selectedRowID }) {
            selectedRowID = rows.first?.id
        }
    }

    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedRowID } ?? 0
        let next = min(max(current + delta, 0), rows.count - 1)
        selectedRowID = rows[next].id
        promptFocused = true
    }

    private func dotKind(for row: AgentWorkRow) -> RelayStatusKind {
        switch AgentWorkSorter.priority(row) {
        case 0: return .needsInput
        case 1: return .running
        default: return .idle
        }
    }

    private func pillVariant(for row: AgentWorkRow) -> RelayPillVariant {
        let status = row.status.lowercased()
        if status == "completed" || status == "stopped" || status == "failed" { return .strike }
        if AgentWorkSorter.priority(row) == 2 { return .soft }
        return .outline
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "needsInput": return "needs input"
        case "awaitingResponse": return "awaiting response"
        case "awaitingReview": return "awaiting review"
        default: return status
        }
    }

    private func actionCopy(for row: AgentWorkRow) -> String {
        switch row.kind {
        case .liveTile:
            return "Messages send directly to the live tile through TerminalManager."
        case .eternal:
            return "Messages are written to the Eternal inbox and picked up on the next worker pass."
        case .dispatch:
            return "Messages route to the current Dispatch phase tile when it is live."
        case .todo:
            return "This todo has no live session, so it is not a follow-up target yet."
        }
    }

    private func feedbackText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.sans(size: 12, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func elapsedString(_ start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
