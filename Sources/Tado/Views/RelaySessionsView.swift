// Relay Sessions surface — full-page list of every running tile
// per brief section 6.4.
//
// Same data flow as the existing SidebarView (which remains for
// the Cmd+B drawer): reads `TodoItem` filtered to `active` state
// and groups by status. Only the chrome is redesigned.

import SwiftUI
import SwiftData

struct RelaySessionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]

    private var actives: [TodoItem] {
        todos.filter { $0.listState == .active }
    }

    private var running: [TodoItem]    { actives.filter { $0.status == .running } }
    private var idle: [TodoItem]       { actives.filter { $0.status == .pending || $0.status == .completed || $0.status == .failed } }
    private var needs: [TodoItem]      { actives.filter { $0.status == .needsInput || $0.status == .awaitingResponse } }

    private var engineCount: Int {
        // Distinct engines used across active sessions.
        let set = Set(actives.compactMap { _ in TerminalEngine.claude })
        return set.count
    }

    var body: some View {
        RelayPageContainer {
            RelayPageHead(
                kicker: "STRUCTURE — SESSIONS",
                title: "\(actives.count) live \(actives.count == 1 ? "session" : "sessions").",
                lead: "Every running terminal tile, by status. Live status indicator shows whether the agent is running, idle, or waiting on input. Click a row to focus the tile.",
                h1Size: 52
            )

            statStrip
            tableSection
        }
    }

    private var statStrip: some View {
        RelayStatStrip(stats: [
            RelayStat("RUNNING",     "\(running.count)", meta: running.count > 0 ? "● Live" : nil, metaTint: running.count > 0 ? RelayPalette.terracotta : nil),
            RelayStat("IDLE",        "\(idle.count)"),
            RelayStat("NEEDS INPUT", "\(needs.count)",   meta: needs.count > 0 ? "● Awaiting" : nil, metaTint: needs.count > 0 ? RelayPalette.terracotta : nil),
            RelayStat("ENGINES",     "\(engineCount > 0 ? engineCount : 1)"),
        ])
    }

    private var tableSection: some View {
        RelaySection(
            kicker: "ALL SESSIONS",
            title: "Sorted by status, newest first.",
            content: {
                if actives.isEmpty {
                    emptyState
                } else {
                    sessionTable
                }
            }
        )
    }

    private var emptyState: some View {
        RelayCard {
            VStack(alignment: .leading, spacing: 12) {
                RelayKicker(text: "NO LIVE SESSIONS")
                Text("Spawn a todo to begin.")
                    .font(RelayType.h2(size: 22))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                RelayInlineLink(label: "Open Todos", arrow: .forward) {
                    appState.currentView = .todos
                }
            }
        }
    }

    private var sessionTable: some View {
        VStack(spacing: 0) {
            RelayTableHeader(columns: [
                RelayTableColumn("GRID",    width: .fixed(72)),
                RelayTableColumn("NAME"),
                RelayTableColumn("STATUS",  width: .fixed(180)),
                RelayTableColumn("ELAPSED", alignment: .trailing, width: .fixed(96)),
                RelayTableColumn("",        alignment: .trailing, width: .fixed(80)),
            ])
            ForEach(sortedTodos) { todo in
                sessionRow(todo: todo)
            }
        }
    }

    private var sortedTodos: [TodoItem] {
        let order: (SessionStatus) -> Int = { s in
            switch s {
            case .needsInput, .awaitingResponse: return 0
            case .running:                       return 1
            case .pending:                       return 2
            case .completed:                     return 3
            case .failed:                        return 4
            }
        }
        return actives.sorted { a, b in
            if order(a.status) != order(b.status) {
                return order(a.status) < order(b.status)
            }
            return a.createdAt > b.createdAt
        }
    }

    private func sessionRow(todo: TodoItem) -> some View {
        let dotKind: RelayStatusKind = {
            switch todo.status {
            case .running:                       return .running
            case .needsInput, .awaitingResponse: return .needsInput
            default:                             return .idle
            }
        }()
        return RelayTableRow {
            RelayTableCell(text: "[\(todo.gridIndex)]", style: .meta, width: 72)
            RelayTableCell(text: todo.text, style: .body)
            HStack(spacing: 8) {
                RelayStatusDot(kind: dotKind, size: 7)
                RelayPill(label: pillLabel(for: todo.status), variant: pillVariant(for: todo.status))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(width: 180, alignment: .leading)
            RelayTableCell(text: elapsedString(todo.createdAt), style: .meta, alignment: .trailing, width: 96)
            HStack {
                Spacer()
                RelayInlineLink(label: "Focus", arrow: .forward) {
                    appState.focusedTileModalTodoID = todo.id
                }
            }
            .padding(.trailing, 12)
            .frame(width: 80)
        }
    }

    private func pillLabel(for s: SessionStatus) -> String {
        switch s {
        case .running:           return "running"
        case .needsInput:        return "needs input"
        case .awaitingResponse:  return "awaiting"
        case .pending:           return "pending"
        case .completed:         return "done"
        case .failed:            return "failed"
        }
    }

    private func pillVariant(for s: SessionStatus) -> RelayPillVariant {
        switch s {
        case .completed, .failed: return .strike
        case .pending:            return .soft
        default:                  return .outline
        }
    }

    private func elapsedString(_ start: Date) -> String {
        let secs = Int(Date().timeIntervalSince(start))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }
}
