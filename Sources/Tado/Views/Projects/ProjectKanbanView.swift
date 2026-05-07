import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Per-project Kanban board. Sibling of `ProjectDetailView`; routed by
/// `ProjectsView` when `appState.projectPageMode == .kanban`.
///
/// The board is a **single picture of everything happening on a
/// project** — todos, dispatch runs, and eternal runs all surface as
/// cards. A tab strip at the top swaps between grouping axes (custom
/// columns, status FSM, agent, team, kind), and an inline composer
/// lets the user fire any of those off (plain todo, Dispatch
/// [Grid|Kanban], Eternal Mega [Normal|Continuous|Perf], Eternal
/// Sprint [Normal|Continuous|Perf]) without leaving the board.
///
/// Drag-and-drop only applies in `.column` mode (user-managed lanes).
/// Other groupings are read-only — the lane membership is derived from
/// the card's own state.
struct ProjectKanbanView: View {
    let project: Project

    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \KanbanColumn.orderIndex) private var allColumns: [KanbanColumn]
    @Query(sort: \TodoItem.kanbanOrderIndex) private var allTodos: [TodoItem]
    @Query(sort: \Team.createdAt) private var allTeams: [Team]
    @Query(sort: \DispatchRun.createdAt) private var allDispatchRuns: [DispatchRun]
    @Query(sort: \EternalRun.createdAt) private var allEternalRuns: [EternalRun]

    @State private var newColumnTitle: String = ""
    @State private var showNewColumnField: Bool = false
    @State private var renamingColumnID: UUID? = nil
    @State private var renameDraft: String = ""
    @State private var pathCopiedAt: Date? = nil
    @State private var composeText: String = ""
    @State private var composeKind: ComposeKind = .todo

    // MARK: - Derived collections

    private var userColumns: [KanbanColumn] {
        allColumns.filter { $0.kind == "project" && $0.project?.id == project.id }
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    private var projectTodos: [TodoItem] {
        allTodos.filter { $0.projectID == project.id && $0.listState == .active }
    }

    private var projectDispatchRuns: [DispatchRun] {
        allDispatchRuns
            .filter { $0.project?.id == project.id && $0.archivedAt == nil }
    }

    private var projectEternalRuns: [EternalRun] {
        allEternalRuns
            .filter { $0.project?.id == project.id && $0.archivedAt == nil }
    }

    private var projectTeams: [Team] {
        allTeams.filter { $0.projectID == project.id }
    }

    /// Heterogeneous card list. Built once per body eval so every lane
    /// reads from the same materialized snapshot.
    private var allCards: [BoardCard] {
        var cards: [BoardCard] = []
        cards.append(contentsOf: projectTodos.map { BoardCard(todo: $0) })
        cards.append(contentsOf: projectDispatchRuns.map { BoardCard(dispatch: $0) })
        cards.append(contentsOf: projectEternalRuns.map { BoardCard(eternal: $0) })
        return cards
    }

    var body: some View {
        @Bindable var appStateBindable = appState

        return PageContainer {
            PageHeader(
                title: project.name,
                path: project.rootPath,
                pathOnCopy: { pathCopiedAt = .now }
            ) {
                metaStrip()
            }

            // Detail | Kanban view-mode toggle.
            pageModePicker
                .padding(.bottom, 12)

            // Inline composer — prompt anything from the board.
            composer
                .padding(.bottom, 12)

            // Grouping tab strip — picks how lanes are partitioned.
            groupingTabs
                .padding(.bottom, 12)

            SectionRail(
                label: "Board",
                count: boardCountText(),
                actions: {
                    if appState.kanbanGrouping == .column {
                        OutlineButton("New column", icon: "plus", size: .small, variant: .accent) {
                            beginNewColumn()
                        }
                    }
                },
                content: {
                    boardScroller
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                }
            )
        }
        .onAppear {
            // First-visit seed. Idempotent; only runs the seed when no
            // user columns exist yet.
            ProjectActionsService.seedKanbanColumns(
                project: project,
                modelContext: modelContext
            )
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.accent)
                Text("PROMPT")
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink3)
                Text("create todo / dispatch / eternal from the board")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if composeText.isEmpty {
                        Text(composePlaceholder)
                            .font(Typography.monoBody)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $composeText)
                        .font(Typography.monoBody)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 56, maxHeight: 140)
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) || press.modifiers.contains(.control) else {
                                return .ignored
                            }
                            submitCompose()
                            return .handled
                        }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .fill(Palette.bgElev)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(
                            composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Palette.divider
                                : Palette.accentSoft,
                            lineWidth: DK.ruleW
                        )
                )

                VStack(alignment: .trailing, spacing: 8) {
                    composeKindMenu
                    OutlineButton(
                        composeKind.submitLabel,
                        icon: composeKind.submitIcon,
                        size: .small,
                        variant: .accent,
                        action: { submitCompose() }
                    )
                    .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    Text("⌘↩ to submit")
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textTertiary)
                }
                .frame(width: 200, alignment: .trailing)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DK.radius)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.divider, lineWidth: DK.ruleW)
        )
    }

    private var composeKindMenu: some View {
        Menu {
            Section("Todo") {
                Button(action: { composeKind = .todo }) {
                    Label("Plain todo", systemImage: "checklist")
                }
            }
            Section("Dispatch") {
                Button(action: { composeKind = .dispatchGrid }) {
                    Label("Dispatch · Grid", systemImage: "square.grid.3x3")
                }
                Button(action: { composeKind = .dispatchKanban }) {
                    Label("Dispatch · Kanban", systemImage: "rectangle.split.3x1")
                }
            }
            Section("Eternal Mega") {
                Button(action: { composeKind = .eternalMegaNormal }) {
                    Label("Mega · Normal", systemImage: "infinity")
                }
                Button(action: { composeKind = .eternalMegaContinuous }) {
                    Label("Mega · Continuous", systemImage: "infinity.circle")
                }
                Button(action: { composeKind = .eternalMegaPerf }) {
                    Label("Mega · Performance", systemImage: "speedometer")
                }
            }
            Section("Eternal Sprint") {
                Button(action: { composeKind = .eternalSprintNormal }) {
                    Label("Sprint · Normal", systemImage: "repeat")
                }
                Button(action: { composeKind = .eternalSprintContinuous }) {
                    Label("Sprint · Continuous", systemImage: "repeat.circle")
                }
                Button(action: { composeKind = .eternalSprintPerf }) {
                    Label("Sprint · Performance", systemImage: "gauge.with.needle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: composeKind.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(composeKind.label)
                    .font(Font.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DK.radius - 1, style: .continuous)
                    .fill(Palette.bgElev)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius - 1, style: .continuous)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .frame(width: 200, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var composePlaceholder: String {
        switch composeKind {
        case .todo: return "What's the next thing? One-line todo, or paste a richer prompt."
        case .dispatchGrid, .dispatchKanban:
            return "Describe WHAT you want built and WHY. The Dispatch Architect plans phases from this brief."
        case .eternalMegaNormal, .eternalMegaContinuous, .eternalMegaPerf:
            return "Describe the long-running goal for this Eternal Mega. The architect derives plan / eval / improve from your brief."
        case .eternalSprintNormal, .eternalSprintContinuous, .eternalSprintPerf:
            return "Describe what each sprint should accomplish. The architect breaks the brief into iterations."
        }
    }

    // MARK: - Grouping tabs

    private var groupingTabs: some View {
        @Bindable var appStateBindable = appState
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(KanbanGroupingMode.allCases, id: \.self) { mode in
                    let count = laneCount(for: mode)
                    groupingTabButton(mode: mode, count: count)
                }
                Spacer(minLength: 0)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DK.radius)
                .fill(Palette.bgPage)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
    }

    private func groupingTabButton(mode: KanbanGroupingMode, count: Int) -> some View {
        let active = appState.kanbanGrouping == mode
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                appState.kanbanGrouping = mode
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                Text(mode.label)
                    .font(Font.system(size: 12, weight: active ? .semibold : .medium))
                Text("\(count)")
                    .font(Font.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(active ? Palette.accent : Palette.ink4)
            }
            .foregroundStyle(active ? Palette.ink : Palette.ink3)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? Palette.accent : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Board

    private var boardScroller: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(currentLanes(), id: \.id) { lane in
                    laneView(lane)
                }
                if appState.kanbanGrouping == .column, showNewColumnField {
                    newColumnField
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Resolved lane list for the active grouping mode. Every lane has
    /// a stable `id`, a label, an ordering index, an optional column
    /// key (only set for `.column` mode so we know what to write to
    /// `TodoItem.kanbanColumnKey` on a drop), and a card list.
    private func currentLanes() -> [Lane] {
        switch appState.kanbanGrouping {
        case .column: return columnLanes()
        case .status: return statusLanes()
        case .agent:  return agentLanes()
        case .team:   return teamLanes()
        case .kind:   return kindLanes()
        }
    }

    private func columnLanes() -> [Lane] {
        let cols = userColumns
        let everyCard = allCards
        let firstKey = cols.first?.columnKey
        return cols.enumerated().map { index, col in
            // Only todo cards participate in user-column grouping
            // (dispatch + eternal cards have their own columns in the
            // .kind / .status views — putting them in user lanes would
            // be more confusing than useful).
            let assignedTodos = everyCard.filter {
                guard case let .todo(todo) = $0.payload else { return false }
                return todo.kanbanColumnKey == col.columnKey
            }
            let extras: [BoardCard] = (col.columnKey == firstKey)
                ? everyCard.filter {
                    guard case let .todo(todo) = $0.payload else { return false }
                    return todo.kanbanColumnKey == nil
                }
                : []
            let cards = (assignedTodos + extras).sorted { a, b in
                a.sortKey < b.sortKey
            }
            return Lane(
                id: "col-\(col.columnKey)",
                label: col.title,
                orderIndex: index,
                columnKey: col.columnKey,
                userColumn: col,
                cards: cards
            )
        }
    }

    private func statusLanes() -> [Lane] {
        // Lanes by FSM state. Order matches the natural flow.
        let order: [(SessionStatus, String)] = [
            (.pending, "Pending"),
            (.running, "Running"),
            (.needsInput, "Needs input"),
            (.awaitingResponse, "Awaiting response"),
            (.completed, "Completed"),
            (.failed, "Failed"),
        ]
        let cards = allCards
        return order.enumerated().map { index, pair in
            let (status, label) = pair
            let bucket = cards.filter { $0.matchesStatus(status) }
                .sorted { $0.sortKey < $1.sortKey }
            return Lane(
                id: "status-\(status.rawValue)",
                label: label,
                orderIndex: index,
                columnKey: nil,
                userColumn: nil,
                cards: bucket
            )
        }
    }

    private func agentLanes() -> [Lane] {
        // Group cards by agentName (todos) or runRole (dispatch
        // architect/phase, eternal worker). Falls back to "Unassigned".
        var groups: [String: [BoardCard]] = [:]
        for card in allCards {
            let key = card.agentLabel ?? "Unassigned"
            groups[key, default: []].append(card)
        }
        let names = groups.keys.sorted { a, b in
            // Pin "Unassigned" last
            if a == "Unassigned" { return false }
            if b == "Unassigned" { return true }
            return a.lowercased() < b.lowercased()
        }
        return names.enumerated().map { index, name in
            Lane(
                id: "agent-\(name)",
                label: name,
                orderIndex: index,
                columnKey: nil,
                userColumn: nil,
                cards: (groups[name] ?? []).sorted { $0.sortKey < $1.sortKey }
            )
        }
    }

    private func teamLanes() -> [Lane] {
        // One lane per team in the project + a "No team" lane for
        // todos without a teamID. Dispatch + Eternal cards always
        // route to "No team" since teams attach to todos, not runs.
        let teams = projectTeams
        let teamByID: [UUID: Team] = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0) })
        var byTeam: [String: [BoardCard]] = ["No team": []]
        for team in teams { byTeam[team.id.uuidString] = [] }
        for card in allCards {
            if case let .todo(todo) = card.payload, let tid = todo.teamID, teamByID[tid] != nil {
                byTeam[tid.uuidString, default: []].append(card)
            } else {
                byTeam["No team", default: []].append(card)
            }
        }
        var lanes: [Lane] = []
        for (index, team) in teams.enumerated() {
            lanes.append(Lane(
                id: "team-\(team.id.uuidString)",
                label: team.name,
                orderIndex: index,
                columnKey: nil,
                userColumn: nil,
                cards: (byTeam[team.id.uuidString] ?? []).sorted { $0.sortKey < $1.sortKey }
            ))
        }
        lanes.append(Lane(
            id: "team-none",
            label: "No team",
            orderIndex: lanes.count,
            columnKey: nil,
            userColumn: nil,
            cards: (byTeam["No team"] ?? []).sorted { $0.sortKey < $1.sortKey }
        ))
        return lanes
    }

    private func kindLanes() -> [Lane] {
        // Three lanes — Todos, Dispatch, Eternal. Useful for spotting
        // long-running infrastructure runs alongside one-off todos.
        let cards = allCards
        let todos = cards.filter { if case .todo = $0.payload { return true }; return false }
        let dispatches = cards.filter { if case .dispatch = $0.payload { return true }; return false }
        let eternals = cards.filter { if case .eternal = $0.payload { return true }; return false }
        return [
            Lane(id: "kind-todo", label: "Todos", orderIndex: 0, columnKey: nil, userColumn: nil,
                 cards: todos.sorted { $0.sortKey < $1.sortKey }),
            Lane(id: "kind-dispatch", label: "Dispatch", orderIndex: 1, columnKey: nil, userColumn: nil,
                 cards: dispatches.sorted { $0.sortKey < $1.sortKey }),
            Lane(id: "kind-eternal", label: "Eternal", orderIndex: 2, columnKey: nil, userColumn: nil,
                 cards: eternals.sorted { $0.sortKey < $1.sortKey }),
        ]
    }

    private func laneCount(for mode: KanbanGroupingMode) -> Int {
        switch mode {
        case .column: return userColumns.count
        case .status: return 6
        case .agent:
            let names = Set(allCards.compactMap { $0.agentLabel })
            return names.count + (allCards.contains(where: { $0.agentLabel == nil }) ? 1 : 0)
        case .team:   return projectTeams.count + 1
        case .kind:   return 3
        }
    }

    // MARK: - Lane rendering

    private func laneView(_ lane: Lane) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            laneHeader(lane)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(lane.cards, id: \.id) { card in
                        cardView(card: card)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 600)
            .background(
                RoundedRectangle(cornerRadius: DK.radius)
                    .fill(Palette.bgElev.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.divider, lineWidth: DK.ruleW)
            )
            .modifier(ColumnDropModifier(
                enabled: lane.columnKey != nil,
                columnKey: lane.columnKey ?? "",
                onDrop: { todoID in
                    moveTodo(todoID: todoID, toColumnKey: lane.columnKey ?? "")
                }
            ))
        }
        .frame(width: 320)
    }

    private func laneHeader(_ lane: Lane) -> some View {
        HStack(spacing: 8) {
            if let column = lane.userColumn, renamingColumnID == column.id {
                TextField("Column name", text: $renameDraft, onCommit: { commitRename(column) })
                    .textFieldStyle(.plain)
                    .font(Typography.heading)
                    .onExitCommand { renamingColumnID = nil }
            } else {
                Text(lane.label)
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        if let column = lane.userColumn {
                            renameDraft = column.title
                            renamingColumnID = column.id
                        }
                    }
            }
            Text("\(lane.cards.count)")
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.ink2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Palette.bgRowHi))
            Spacer(minLength: 4)
            if let column = lane.userColumn {
                Menu {
                    Button("Rename") {
                        renameDraft = column.title
                        renamingColumnID = column.id
                    }
                    Button("Delete column", role: .destructive) {
                        deleteColumn(column)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DK.radius)
                .fill(Palette.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.divider, lineWidth: DK.ruleW)
        )
    }

    // MARK: - Card rendering

    @ViewBuilder
    private func cardView(card: BoardCard) -> some View {
        switch card.payload {
        case .todo(let todo):    todoCard(todo)
        case .dispatch(let run): dispatchCard(run)
        case .eternal(let run):  eternalCard(run)
        }
    }

    private func todoCard(_ todo: TodoItem) -> some View {
        let session = terminalManager.session(forTodoID: todo.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusDot(for: todo.status)
                Text(todo.displayName)
                    .font(Typography.monoDefault)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 6) {
                kindChip(label: "TODO", tint: Palette.ink3)
                if let agent = todo.agentName {
                    pill(text: agent, tint: Palette.bgRowHi, foreground: Palette.ink2)
                }
                if let session, !session.promptQueue.isEmpty {
                    pill(text: "\(session.promptQueue.count) queued",
                         tint: Palette.accent,
                         foreground: Palette.foreground)
                }
                Spacer(minLength: 0)
                Text(relativeAgo(todo.createdAt))
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DK.radius)
                .fill(Palette.bgRowHi)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.divider, lineWidth: DK.ruleW)
        )
        .onTapGesture {
            appState.pendingNavigationID = todo.id
            appState.currentView = .canvas
        }
        .onDrag {
            NSItemProvider(object: todo.id.uuidString as NSString)
        }
    }

    private func dispatchCard(_ run: DispatchRun) -> some View {
        let phaseCount = DispatchPlanService.phaseFileCount(run)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(run.label)
                    .font(Typography.monoDefault)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if !run.brief.isEmpty {
                Text(run.brief)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                kindChip(label: "DISPATCH", tint: Palette.accent.opacity(0.85))
                pill(text: dispatchStateLabel(run.state),
                     tint: dispatchStateTint(run.state),
                     foreground: dispatchStateInk(run.state))
                pill(text: run.dispatchMode == "kanban" ? "kanban" : "grid",
                     tint: Palette.bgRowHi, foreground: Palette.ink2)
                if phaseCount > 0 {
                    pill(text: "\(phaseCount) phase\(phaseCount == 1 ? "" : "s")",
                         tint: Palette.bgRowHi, foreground: Palette.ink2)
                }
                Spacer(minLength: 0)
                Text(relativeAgo(run.createdAt))
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DK.radius)
                .fill(Palette.bgRowHi)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.accentSoft.opacity(0.6), lineWidth: DK.ruleW)
        )
        .onTapGesture {
            // Open the brief editor for the run.
            appState.dispatchModalRunID = run.id
        }
    }

    private func eternalCard(_ run: EternalRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: run.mode == "sprint" ? "repeat.circle.fill" : "infinity.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(run.label)
                    .font(Typography.monoDefault)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if !run.userBrief.isEmpty {
                Text(run.userBrief)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                kindChip(label: "ETERNAL", tint: Palette.accent.opacity(0.85))
                pill(text: run.mode.uppercased(),
                     tint: Palette.bgRowHi, foreground: Palette.ink2)
                pill(text: run.loopKind == "internal" ? "continuous" : "normal",
                     tint: Palette.bgRowHi, foreground: Palette.ink2)
                if run.kind == "perf" {
                    pill(text: "perf", tint: Palette.accentSoft, foreground: Palette.foreground)
                }
                pill(text: eternalStateLabel(run.state),
                     tint: eternalStateTint(run.state),
                     foreground: eternalStateInk(run.state))
                Spacer(minLength: 0)
                Text(relativeAgo(run.createdAt))
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DK.radius)
                .fill(Palette.bgRowHi)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.accentSoft.opacity(0.6), lineWidth: DK.ruleW)
        )
        .onTapGesture {
            appState.eternalModalRunID = run.id
        }
    }

    // MARK: - Card chrome helpers

    private func statusDot(for status: SessionStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .pending: return Palette.ink3
        case .running: return Palette.green
        case .needsInput, .awaitingResponse: return Palette.accent
        case .completed: return Palette.ink2
        case .failed: return Palette.danger
        }
    }

    private func kindChip(label: String, tint: Color) -> some View {
        Text(label)
            .font(Font.system(size: 8.5, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(Palette.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint))
    }

    private func pill(text: String, tint: Color, foreground: Color) -> some View {
        Text(text)
            .font(Typography.monoCaption)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint))
    }

    private func dispatchStateLabel(_ state: String) -> String {
        switch state {
        case "drafted": return "draft"
        case "planning": return "planning"
        case "awaitingReview": return "review"
        case "ready": return "ready"
        case "dispatching": return "dispatching"
        case "completed": return "complete"
        default: return state
        }
    }

    private func dispatchStateTint(_ state: String) -> Color {
        switch state {
        case "drafted": return Palette.bgRowHi
        case "planning", "dispatching": return Palette.green.opacity(0.65)
        case "awaitingReview": return Palette.accent
        case "ready": return Palette.accentSoft
        case "completed": return Palette.ink4
        default: return Palette.bgRowHi
        }
    }

    private func dispatchStateInk(_ state: String) -> Color {
        switch state {
        case "drafted", "completed": return Palette.ink2
        case "awaitingReview", "ready", "planning", "dispatching": return Palette.foreground
        default: return Palette.ink2
        }
    }

    private func eternalStateLabel(_ state: String) -> String {
        switch state {
        case "drafted": return "draft"
        case "planning": return "planning"
        case "awaitingReview": return "review"
        case "ready": return "ready"
        case "running": return "running"
        case "completed": return "complete"
        case "stopped": return "stopped"
        default: return state
        }
    }

    private func eternalStateTint(_ state: String) -> Color {
        switch state {
        case "drafted": return Palette.bgRowHi
        case "running": return Palette.green.opacity(0.7)
        case "awaitingReview": return Palette.accent
        case "ready", "planning": return Palette.accentSoft
        case "completed": return Palette.ink4
        case "stopped": return Palette.danger.opacity(0.65)
        default: return Palette.bgRowHi
        }
    }

    private func eternalStateInk(_ state: String) -> Color {
        switch state {
        case "drafted", "completed": return Palette.ink2
        default: return Palette.foreground
        }
    }

    // MARK: - New column field

    private var newColumnField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Column title", text: $newColumnTitle, onCommit: commitNewColumn)
                .textFieldStyle(.plain)
                .font(Typography.heading)
                .foregroundStyle(Palette.textPrimary)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .fill(Palette.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.accentSoft, lineWidth: DK.ruleW)
                )
                .onExitCommand {
                    showNewColumnField = false
                    newColumnTitle = ""
                }
            HStack(spacing: 6) {
                OutlineButton("Add", icon: "checkmark", size: .small, variant: .accent) {
                    commitNewColumn()
                }
                OutlineButton("Cancel", icon: "xmark", size: .small) {
                    showNewColumnField = false
                    newColumnTitle = ""
                }
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    // MARK: - Page-mode picker (Detail | Kanban)

    private var pageModePicker: some View {
        @Bindable var appStateBindable = appState
        return HStack(spacing: 10) {
            ModeTab(
                eyebrow: "VIEW",
                options: [
                    .init(id: ProjectPageMode.detail, label: "Detail", icon: "list.bullet.rectangle"),
                    .init(id: ProjectPageMode.kanban, label: "Kanban", icon: "rectangle.split.3x1"),
                ],
                selection: $appStateBindable.projectPageMode
            )
            Spacer()
        }
    }

    // MARK: - Compose submission

    private func submitCompose() {
        let trimmed = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch composeKind {
        case .todo:
            createPlainTodo(brief: trimmed)
        case .dispatchGrid:
            createDispatch(brief: trimmed, mode: "grid")
        case .dispatchKanban:
            createDispatch(brief: trimmed, mode: "kanban")
        case .eternalMegaNormal:
            createEternal(brief: trimmed, mode: "mega", loopKind: "external", kind: "general")
        case .eternalMegaContinuous:
            createEternal(brief: trimmed, mode: "mega", loopKind: "internal", kind: "general")
        case .eternalMegaPerf:
            createEternal(brief: trimmed, mode: "mega", loopKind: "external", kind: "perf")
        case .eternalSprintNormal:
            createEternal(brief: trimmed, mode: "sprint", loopKind: "external", kind: "general")
        case .eternalSprintContinuous:
            createEternal(brief: trimmed, mode: "sprint", loopKind: "internal", kind: "general")
        case .eternalSprintPerf:
            createEternal(brief: trimmed, mode: "sprint", loopKind: "external", kind: "perf")
        }
        composeText = ""
    }

    private func createPlainTodo(brief: String) {
        let settings = fetchOrCreateSettings()
        let index = nextAvailableGridIndex()
        let position = CanvasLayout.position(forIndex: index, gridColumns: settings.gridColumns)
        let todo = TodoItem(text: brief, gridIndex: index, canvasPosition: position)
        todo.projectID = project.id
        // Drop the new card into the leftmost column of the user's
        // board so it appears right where the composer lives.
        if let firstCol = userColumns.first {
            todo.kanbanColumnKey = firstCol.columnKey
        }
        modelContext.insert(todo)
        terminalManager.spawnAndWire(
            todo: todo,
            engine: settings.engine,
            cwd: project.rootPath,
            projectName: project.name
        )
        try? modelContext.save()
    }

    private func createDispatch(brief: String, mode: String) {
        let run = DispatchRun(
            project: project,
            label: DispatchRun.defaultLabel(),
            state: "drafted",
            brief: brief,
            dispatchMode: mode
        )
        modelContext.insert(run)
        try? modelContext.save()
        // Open the brief editor pre-filled so the user can refine
        // before Accept (matches today's Project page flow).
        appState.dispatchModalRunID = run.id
    }

    private func createEternal(brief: String, mode: String, loopKind: String, kind: String) {
        let run = EternalRun(
            project: project,
            label: EternalRun.defaultLabel(mode: mode),
            state: "drafted",
            mode: mode,
            loopKind: loopKind,
            kind: kind,
            userBrief: brief
        )
        modelContext.insert(run)
        try? modelContext.save()
        appState.eternalModalRunID = run.id
    }

    // MARK: - Mutations

    private func moveTodo(todoID: UUID, toColumnKey columnKey: String) {
        guard let todo = projectTodos.first(where: { $0.id == todoID }) else { return }
        guard todo.kanbanColumnKey != columnKey else { return }
        let dest = projectTodos.filter { $0.kanbanColumnKey == columnKey }
        let nextIndex = (dest.map(\.kanbanOrderIndex).max() ?? -1) + 1
        todo.kanbanColumnKey = columnKey
        todo.kanbanOrderIndex = nextIndex
        try? modelContext.save()
    }

    private func beginNewColumn() {
        newColumnTitle = ""
        showNewColumnField = true
    }

    private func commitNewColumn() {
        let trimmed = newColumnTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (userColumns.map(\.orderIndex).max() ?? -1) + 1
        let key = "col-\(UUID().uuidString.prefix(8).lowercased())"
        let col = KanbanColumn(
            project: project,
            kind: "project",
            columnKey: String(key),
            title: trimmed,
            orderIndex: nextOrder
        )
        modelContext.insert(col)
        try? modelContext.save()
        newColumnTitle = ""
        showNewColumnField = false
    }

    private func commitRename(_ column: KanbanColumn) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != column.title {
            column.title = trimmed
            try? modelContext.save()
        }
        renamingColumnID = nil
        renameDraft = ""
    }

    private func deleteColumn(_ column: KanbanColumn) {
        for todo in projectTodos where todo.kanbanColumnKey == column.columnKey {
            todo.kanbanColumnKey = nil
        }
        modelContext.delete(column)
        try? modelContext.save()
    }

    // MARK: - Header / counts

    private func metaStrip() -> some View {
        let inFlight = projectTodos.filter {
            $0.status == .running || $0.status == .needsInput || $0.status == .awaitingResponse
        }.count
        return MetaStrip {
            MetaCell(key: "Todos", value: "\(projectTodos.count)")
            MetaCell(key: "Dispatch", value: "\(projectDispatchRuns.count)")
            MetaCell(key: "Eternal", value: "\(projectEternalRuns.count)")
            MetaCell(
                key: "In-flight",
                value: "\(inFlight)",
                tint: inFlight > 0 ? Palette.green : Palette.ink3
            )
            MetaCell(key: "Mode", value: appState.kanbanGrouping.label, trailingDivider: false)
        }
    }

    private func boardCountText() -> String {
        switch appState.kanbanGrouping {
        case .column:
            return "\(userColumns.count) columns · \(projectTodos.count) todos"
        case .status:
            return "6 status lanes · \(allCards.count) cards"
        case .agent:
            return "\(laneCount(for: .agent)) agents · \(allCards.count) cards"
        case .team:
            return "\(projectTeams.count + 1) team lanes · \(allCards.count) cards"
        case .kind:
            return "\(projectTodos.count) todos · \(projectDispatchRuns.count) dispatch · \(projectEternalRuns.count) eternal"
        }
    }

    private func relativeAgo(_ date: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        switch secs {
        case 0..<60:        return "just now"
        case 60..<3600:     return "\(secs / 60)m ago"
        case 3600..<86_400: return "\(secs / 3600)h ago"
        default:            return "\(secs / 86_400)d ago"
        }
    }

    // MARK: - Helpers shared with the main composer

    private func fetchOrCreateSettings() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? modelContext.fetch(descriptor).first { return existing }
        let s = AppSettings()
        modelContext.insert(s)
        try? modelContext.save()
        return s
    }

    private func nextAvailableGridIndex() -> Int {
        let descriptor = FetchDescriptor<TodoItem>()
        let used = Set(((try? modelContext.fetch(descriptor)) ?? [])
            .filter { $0.listState == .active }
            .map(\.gridIndex))
        var idx = 0
        while used.contains(idx) { idx += 1 }
        return idx
    }
}

// MARK: - Lane / BoardCard model

/// One column on the board. `userColumn` is non-nil only for `.column`
/// grouping; other groupings synthesize lanes on the fly.
private struct Lane: Identifiable {
    let id: String
    let label: String
    let orderIndex: Int
    let columnKey: String?
    let userColumn: KanbanColumn?
    let cards: [BoardCard]
}

/// A single card on the board. Heterogeneous wrapper around the three
/// per-project entity types so lane rendering stays uniform.
private struct BoardCard: Identifiable {
    enum Payload {
        case todo(TodoItem)
        case dispatch(DispatchRun)
        case eternal(EternalRun)
    }

    let id: String
    let payload: Payload
    let sortKey: Int

    init(todo: TodoItem) {
        self.id = "todo-\(todo.id.uuidString)"
        self.payload = .todo(todo)
        self.sortKey = todo.kanbanOrderIndex
    }

    init(dispatch: DispatchRun) {
        self.id = "dispatch-\(dispatch.id.uuidString)"
        self.payload = .dispatch(dispatch)
        // Newest first (negative timestamp ⇒ smaller sort key)
        self.sortKey = -Int(dispatch.createdAt.timeIntervalSinceReferenceDate)
    }

    init(eternal: EternalRun) {
        self.id = "eternal-\(eternal.id.uuidString)"
        self.payload = .eternal(eternal)
        self.sortKey = -Int(eternal.createdAt.timeIntervalSinceReferenceDate)
    }

    /// Map to a SessionStatus bucket for `.status` grouping.
    func matchesStatus(_ status: SessionStatus) -> Bool {
        switch payload {
        case .todo(let todo):
            return todo.status == status
        case .dispatch(let run):
            switch (run.state, status) {
            case ("drafted", .pending),
                 ("planning", .running),
                 ("dispatching", .running),
                 ("awaitingReview", .awaitingResponse),
                 ("ready", .needsInput),
                 ("completed", .completed):
                return true
            default: return false
            }
        case .eternal(let run):
            switch (run.state, status) {
            case ("drafted", .pending),
                 ("planning", .running),
                 ("running", .running),
                 ("awaitingReview", .awaitingResponse),
                 ("ready", .needsInput),
                 ("completed", .completed),
                 ("stopped", .failed):
                return true
            default: return false
            }
        }
    }

    /// Best-effort agent label for `.agent` grouping. Returns nil for
    /// cards without a logical assignee (so they fall into the
    /// "Unassigned" bucket).
    var agentLabel: String? {
        switch payload {
        case .todo(let todo): return todo.agentName
        case .dispatch:       return "Dispatch architect"
        case .eternal:        return "Eternal worker"
        }
    }
}

// MARK: - Compose kinds

/// Every "+" affordance the inline composer supports. Lives here
/// because each kind is just a label / icon / submit-button mapping —
/// no behavior beyond what the submitCompose switch dispatches.
private enum ComposeKind: String, CaseIterable, Equatable {
    case todo
    case dispatchGrid
    case dispatchKanban
    case eternalMegaNormal
    case eternalMegaContinuous
    case eternalMegaPerf
    case eternalSprintNormal
    case eternalSprintContinuous
    case eternalSprintPerf

    var label: String {
        switch self {
        case .todo: "Todo"
        case .dispatchGrid: "Dispatch · Grid"
        case .dispatchKanban: "Dispatch · Kanban"
        case .eternalMegaNormal: "Mega · Normal"
        case .eternalMegaContinuous: "Mega · Continuous"
        case .eternalMegaPerf: "Mega · Performance"
        case .eternalSprintNormal: "Sprint · Normal"
        case .eternalSprintContinuous: "Sprint · Continuous"
        case .eternalSprintPerf: "Sprint · Performance"
        }
    }

    var icon: String {
        switch self {
        case .todo: "checklist"
        case .dispatchGrid: "square.grid.3x3"
        case .dispatchKanban: "rectangle.split.3x1"
        case .eternalMegaNormal: "infinity"
        case .eternalMegaContinuous: "infinity.circle"
        case .eternalMegaPerf: "speedometer"
        case .eternalSprintNormal: "repeat"
        case .eternalSprintContinuous: "repeat.circle"
        case .eternalSprintPerf: "gauge.with.needle"
        }
    }

    var submitLabel: String {
        switch self {
        case .todo: "Spawn"
        default:    "Draft & open"
        }
    }

    var submitIcon: String {
        switch self {
        case .todo: "play.fill"
        default:    "arrow.up.right.square"
        }
    }
}

// MARK: - Drop modifier

/// Conditionally attaches a drop target to a lane. Only `.column`
/// grouping accepts drops (the other groupings are derived from card
/// state, so dragging would have no obvious destination).
private struct ColumnDropModifier: ViewModifier {
    let enabled: Bool
    let columnKey: String
    let onDrop: (UUID) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(
                of: [.utf8PlainText],
                delegate: ColumnDropDelegate(targetKey: columnKey, onDrop: onDrop)
            )
        } else {
            content
        }
    }
}

private struct ColumnDropDelegate: DropDelegate {
    let targetKey: String
    let onDrop: (UUID) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let str = item as? String, let id = UUID(uuidString: str) else { return }
            DispatchQueue.main.async {
                onDrop(id)
            }
        }
        return true
    }
}
