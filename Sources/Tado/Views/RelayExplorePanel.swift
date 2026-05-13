// Relay Explore left panel — 380px overlay per brief section 7.
//
// Slides in from the leading edge (240ms cubic-bezier(0.2, 0.7,
// 0.3, 1)). Stays after animation completes (SwiftUI transitions
// preserve end state automatically when bound to view existence).
// Closes on Escape, scrim click, or close button.
//
// Anatomy (top to bottom):
//
//   - Head — brand mark + EXPLORE + workspace subtitle, close ✕.
//   - Status filter strip (4-column grid) — NEEDS INPUT / RUNNING /
//     IDLE / ALL with big numerals.
//   - Filter input — `›` glyph + 13pt mono input.
//   - Results list — pinned group + sessions + recent dispatches +
//     jump-to shortcuts.
//   - Foot — keyboard hints.
//
// Triggered by ⌘E or by clicking the workspace pill / brand-mark
// dot. The conversational TadoUse turns will be folded in as a
// section in a later iteration; for now Explore is the operational
// dashboard.

import SwiftUI
import SwiftData

enum ExploreFilter: String, CaseIterable, Equatable {
    case needsInput
    case running
    case idle
    case all

    var label: String {
        switch self {
        case .needsInput: return "NEEDS INPUT"
        case .running:    return "RUNNING"
        case .idle:       return "IDLE"
        case .all:        return "ALL"
        }
    }
}

struct RelayExplorePanel: View {
    @Binding var isPresented: Bool

    @Environment(AppState.self) private var appState
    @Environment(\.relayTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Query(sort: \TodoItem.createdAt) private var todos: [TodoItem]
    @Query(sort: \DispatchRun.createdAt, order: .reverse) private var dispatches: [DispatchRun]

    @State private var filter: ExploreFilter = .all
    @State private var query: String = ""
    @State private var pinned: Set<UUID> = []

    var body: some View {
        ZStack(alignment: .leading) {
            // Panel itself
            HStack(spacing: 0) {
                panel
                    .frame(width: 380)
                    .frame(maxHeight: .infinity)
                    .background(RelayPalette.background(for: theme))
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(RelayPalette.hair(for: theme))
                            .frame(width: 1)
                    }
                Spacer(minLength: 0)
            }
            .transition(.move(edge: .leading))
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 0) {
            head
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            statusStrip
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            filterInput
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            resultsList
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            foot
        }
    }

    // MARK: - Head

    private var head: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    RelayBrandDot()
                    Text("EXPLORE")
                        .font(Typography.sans(size: 11, weight: .semibold))
                        .tracking(RelayTracking.brand(11))
                        .foregroundStyle(RelayPalette.foreground(for: theme))
                }
                Text("WORKSPACE · TADO · CORE")
                    .font(Typography.sans(size: 9, weight: .regular))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
            }
            Spacer()
            Button(action: dismiss) {
                Text("CLOSE  ✕")
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.foreground2(for: theme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayRadius.standard)
                            .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // MARK: - Status strip

    private var statusStrip: some View {
        HStack(spacing: 0) {
            ForEach(ExploreFilter.allCases, id: \.self) { f in
                statusCell(for: f)
                    .frame(maxWidth: .infinity)
                if f != .all {
                    Rectangle()
                        .fill(RelayPalette.hair(for: theme))
                        .frame(width: 1, height: 60)
                }
            }
        }
    }

    private func statusCell(for f: ExploreFilter) -> some View {
        let active = filter == f
        let count = self.count(for: f)
        return Button(action: {
            withAnimation(RelayAnim.standard(reduce: reduce)) {
                filter = f
            }
        }) {
            VStack(spacing: 6) {
                Text("\(count)")
                    .font(Typography.sans(size: 28, weight: .light))
                    .tracking(RelayTracking.tight(28))
                    .foregroundStyle(active
                        ? RelayPalette.foreground(for: theme)
                        : RelayPalette.foreground2(for: theme))
                    .monospacedDigit()
                Text(f.label)
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(active
                        ? RelayPalette.foreground(for: theme)
                        : RelayPalette.foreground3(for: theme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background(active ? RelayPalette.wash(for: theme) : Color.clear)
            .overlay(alignment: .bottom) {
                if active {
                    Rectangle()
                        .fill(RelayPalette.terracotta)
                        .frame(width: 18, height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func count(for f: ExploreFilter) -> Int {
        let actives = todos.filter { $0.listState == .active }
        switch f {
        case .needsInput:
            return actives.filter { $0.status == .needsInput || $0.status == .awaitingResponse }.count
        case .running:
            return actives.filter { $0.status == .running }.count
        case .idle:
            return actives.filter { $0.status == .pending }.count
        case .all:
            return actives.count
        }
    }

    // MARK: - Filter input

    private var filterInput: some View {
        HStack(spacing: 12) {
            Text("›")
                .font(Typography.sans(size: 16, weight: .regular))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            TextField("Filter sessions…", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.sans(size: 13, weight: .regular))
                .foregroundStyle(RelayPalette.foreground(for: theme))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Results list

    private var filteredSessions: [TodoItem] {
        let actives = todos.filter { $0.listState == .active }
        let scoped: [TodoItem]
        switch filter {
        case .needsInput:
            scoped = actives.filter { $0.status == .needsInput || $0.status == .awaitingResponse }
        case .running:
            scoped = actives.filter { $0.status == .running }
        case .idle:
            scoped = actives.filter { $0.status == .pending }
        case .all:
            scoped = actives
        }
        let sorted = scoped.sorted { (a, b) in
            // Needs-input first, then running, then everything else.
            order(a.status) < order(b.status)
        }
        guard !query.isEmpty else { return sorted }
        let q = query.lowercased()
        return sorted.filter {
            $0.text.lowercased().contains(q)
                || ("\($0.gridIndex)".contains(q))
        }
    }

    private func order(_ s: SessionStatus) -> Int {
        switch s {
        case .needsInput, .awaitingResponse: return 0
        case .running:                       return 1
        case .pending:                       return 2
        case .completed:                     return 3
        case .failed:                        return 4
        }
    }

    private var pinnedSessions: [TodoItem] {
        guard filter == .all && query.isEmpty else { return [] }
        return filteredSessions.filter { pinned.contains($0.id) }
    }

    private var unpinnedSessions: [TodoItem] {
        if filter == .all && query.isEmpty {
            return filteredSessions.filter { !pinned.contains($0.id) }
        }
        return filteredSessions
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !pinnedSessions.isEmpty {
                    groupHeader(label: "PINNED", count: pinnedSessions.count)
                    ForEach(pinnedSessions) { todo in
                        sessionRow(todo: todo)
                    }
                    softDivider
                }
                groupHeader(label: "SESSIONS", count: unpinnedSessions.count)
                if unpinnedSessions.isEmpty {
                    emptySessions
                } else {
                    ForEach(unpinnedSessions) { todo in
                        sessionRow(todo: todo)
                    }
                }
                softDivider
                if !dispatches.isEmpty {
                    groupHeader(label: "RECENT DISPATCH", count: min(3, dispatches.count))
                    ForEach(Array(dispatches.prefix(3))) { run in
                        dispatchRow(run: run)
                    }
                    softDivider
                }
                groupHeader(label: "JUMP TO", count: 5)
                tadoUseRow
                notificationsRow
                jumpRow(label: "Todos",     mode: .todos)
                jumpRow(label: "Knowledge", mode: .knowledge)
                jumpRow(label: "Eternal",   mode: .eternal)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var softDivider: some View {
        Rectangle()
            .fill(RelayPalette.hairSoft(for: theme))
            .frame(height: 1)
    }

    private func groupHeader(label: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typography.sans(size: 9, weight: .semibold))
                .tracking(RelayTracking.brand(9))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Spacer()
            Text("\(count)")
                .font(Typography.sans(size: 9, weight: .regular))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.foreground4(for: theme))
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptySessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No active sessions match.")
                .font(Typography.sans(size: 13, weight: .regular))
                .foregroundStyle(RelayPalette.foreground2(for: theme))
            Text("Spawn a todo to begin.")
                .font(Typography.sans(size: 11, weight: .regular))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func sessionRow(todo: TodoItem) -> some View {
        let dotKind: RelayStatusKind = {
            switch todo.status {
            case .running:                       return .running
            case .needsInput, .awaitingResponse: return .needsInput
            default:                             return .idle
            }
        }()
        let isUrgent = todo.status == .needsInput || todo.status == .awaitingResponse
        let isPinned = pinned.contains(todo.id)
        return Button(action: {
            appState.focusedTileModalTodoID = todo.id
            dismiss()
        }) {
            HStack(spacing: 10) {
                RelayStatusDot(kind: dotKind, size: 7)
                Text("[\(todo.gridIndex)]")
                    .font(Typography.sans(size: 10, weight: .regular))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                Text(todo.text)
                    .font(Typography.sans(size: 13, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(elapsedString(todo.createdAt))
                    .font(Typography.sans(size: 10, weight: .regular))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                Button(action: { togglePin(todo.id) }) {
                    Text(isPinned ? "◆" : "◇")
                        .font(Typography.sans(size: 11, weight: .regular))
                        .foregroundStyle(isPinned
                            ? RelayPalette.terracotta
                            : RelayPalette.foreground4(for: theme))
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin" : "Pin")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isUrgent ? RelayPalette.terracotta : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dispatchRow(run: DispatchRun) -> some View {
        Button(action: {
            appState.dispatchModalRunID = run.id
            dismiss()
        }) {
            HStack(spacing: 10) {
                Text(run.shortID.uppercased())
                    .font(Typography.sans(size: 10, weight: .medium))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(RelayPalette.terracotta)
                    .frame(width: 36, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.label)
                        .font(Typography.sans(size: 13, weight: .regular))
                        .foregroundStyle(RelayPalette.foreground(for: theme))
                        .lineLimit(1)
                    Text("\(run.state.uppercased()) · \(run.dispatchMode.uppercased())")
                        .font(Typography.sans(size: 9, weight: .regular))
                        .tracking(RelayTracking.caps(9))
                        .foregroundStyle(RelayPalette.foreground3(for: theme))
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tado Use jump-row — opens the legacy chat panel via the
    /// existing `appState.showTadoUse` toggle. The conversational
    /// engine + turn-row plumbing stays in TadoUsePanel; Explore
    /// is the one operational lane that points back at it.
    private var tadoUseRow: some View {
        Button(action: {
            appState.showTadoUse = true
            dismiss()
        }) {
            HStack(spacing: 10) {
                Text("◐")
                    .font(Typography.sans(size: 12, weight: .regular))
                    .foregroundStyle(RelayPalette.terracotta)
                    .frame(width: 36, alignment: .leading)
                Text("Tado Use")
                    .font(Typography.sans(size: 13, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Text("· conversational")
                    .font(Typography.sans(size: 11, weight: .regular))
                    .tracking(RelayTracking.meta(11))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                Spacer()
                Text("⌘⇧U")
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.kbd(9))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Notifications jump-row — opens the dedicated event-ledger
    /// window (the only window-routed surface that didn't have a
    /// nav cell in the post-redesign topbar).
    private var notificationsRow: some View {
        Button(action: {
            openWindow(id: ExtensionWindowID.string(for: NotificationsExtension.manifest.id))
            dismiss()
        }) {
            HStack(spacing: 10) {
                Text("◉")
                    .font(Typography.sans(size: 11, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground2(for: theme))
                    .frame(width: 36, alignment: .leading)
                Text("Notifications")
                    .font(Typography.sans(size: 13, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Text("· event log")
                    .font(Typography.sans(size: 11, weight: .regular))
                    .tracking(RelayTracking.meta(11))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                Spacer()
                Text("OPEN")
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func jumpRow(label: String, mode: ViewMode) -> some View {
        Button(action: {
            switch mode {
            case .knowledge:
                openWindow(id: ExtensionWindowID.string(for: DomeExtension.manifest.id))
            default:
                appState.currentView = mode
            }
            dismiss()
        }) {
            HStack(spacing: 10) {
                Text("↵")
                    .font(Typography.sans(size: 11, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                    .frame(width: 36, alignment: .leading)
                Text(label)
                    .font(Typography.sans(size: 13, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Spacer()
                Text("OPEN")
                    .font(Typography.sans(size: 9, weight: .medium))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Foot

    private var foot: some View {
        HStack(spacing: 14) {
            kbdGroup(["↵"], label: "focus tile")
            kbdGroup(["P"], label: "pin")
            kbdGroup(["⌘", "E"], label: "toggle")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(RelayPalette.wash(for: theme))
    }

    private func kbdGroup(_ keys: [String], label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { k in RelayKbdPill(text: k) }
            Text(label.uppercased())
                .font(Typography.sans(size: 9, weight: .regular))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
        }
    }

    // MARK: - Helpers

    private func dismiss() {
        withAnimation(RelayAnim.overlay(reduce: reduce, dur: RelayMotionTokens.durExplore)) {
            isPresented = false
        }
    }

    private func togglePin(_ id: UUID) {
        if pinned.contains(id) {
            pinned.remove(id)
        } else {
            pinned.insert(id)
        }
    }

    private func elapsedString(_ start: Date) -> String {
        let secs = Int(Date().timeIntervalSince(start))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }
}
