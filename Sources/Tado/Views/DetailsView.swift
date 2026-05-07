import SwiftUI
import SwiftData
import AppKit

/// Top-level "go home" page reached by clicking the Tado wordmark in
/// the nav bar. A live status dashboard for every running agent across
/// every project — Tado's interpretation of OpenAI Symphony's TUI
/// status board (`elixir/lib/symphony_elixir/status_dashboard.ex`).
///
/// Two stacked panels:
///
/// 1. **Running** — one row per active `TerminalSession`, with columns
///    ID / STAGE / PID / AGE·TURN / TOKENS / SESSION / EVENT. Mono
///    typography across the table makes columns line up like a real
///    TUI; the only chromatic accent is the burnt sienna status dot.
/// 2. **Pending Prompts** — sessions whose `promptQueue` is non-empty.
///    Tado's honest replacement for Symphony's "Backoff queue" panel —
///    Rule 1 (no retry / watchdog semantics on the dispatch chain)
///    means we can't ship a backoff queue, and the prompt queue is
///    structurally what the panel actually represents (rows waiting
///    to fire).
///
/// Refresh model is event-driven for rows + stats:
///
/// - `TerminalManager.sessions` is `@Observable`; rows re-render when
///   sessions appear / disappear / change status.
/// - `EventBus.shared.recent` is `@Observable`; the EVENT column and
///   "Last event Xs ago" KPI tick on every published event.
/// - `AgentStatusEnvelope` (token / cost / model from the Claude
///   statusLine writer at `<vault>/.bt/status/claude/latest/<sid>.json`)
///   is fetched on appear and re-fetched every 2 s. The polling
///   interval matches the writer's ~5 s cadence so we pick up changes
///   inside one cycle. No watchdog — the loop cancels with the view.
/// - `TimelineView(.periodic)` re-evaluates the AGE column and the
///   "Last event Xs ago" string on a 1 s tick without re-fetching.
///
/// CLAUDE.md compliance:
///   Rule 1 — no watchdogs / retries / timeouts. ✓ (only a 2 s view
///     poll for stats; no session-level supervision.)
///   Rule 4 — FFI ↔ UI parity. ✓ (PID column consumes the new
///     `tado_session_pid` shim shipping in this same release.)
///   Rule 9 — Rust-first for non-UI logic. ✓ (PID capture in Rust,
///     UI math is pure Swift.)
///   Rule 10 — full-system thinking. ✓ (touches Rust pty + FFI +
///     Swift model + view + nav.)
struct DetailsView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query private var todos: [TodoItem]
    @Query private var settingsList: [AppSettings]

    /// Latest Claude statusLine roll-up. Nil before the first poll
    /// completes or when the daemon is offline; rows fall back to
    /// "—" tokens / cost in that state.
    @State private var statusEnvelope: DomeRpcClient.AgentStatusEnvelope?
    @State private var isLoading: Bool = false
    @State private var filter: Filter = .all
    /// `"global"` or a project UUID string. Mirrors the Dome scope
    /// picker so the page reads as a "cockpit" by default.
    @State private var scopeID: String = "global"

    enum Filter: String, CaseIterable, Identifiable, Hashable {
        case all       = "All"
        case claude    = "Claude"
        case codex     = "Codex"
        case cowork    = "Cowork"
        case eternal   = "Eternal"
        case stuck     = "Stuck"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            surfaceHeader(
                title: "Details",
                subtitle: subtitleText,
                isLoading: isLoading,
                refresh: { Task { await reload() } }
            )
            kpiStrip
            filterRow
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    runningSection
                    pendingPromptsSection
                }
                .padding(.horizontal, DK.pageGutter)
                .padding(.top, 18)
                .padding(.bottom, 64)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bgPage)
        .task { await reload() }
        .task {
            // Keep the AgentStatusEnvelope warm. 2 s falls comfortably
            // inside the ~5 s cadence of `tado-statusline.py` so we
            // pick up the latest statusLine snapshot within one cycle.
            // The Task auto-cancels when the view disappears; no
            // explicit teardown.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await reload(silent: true)
            }
        }
    }

    // MARK: - Header subtitle

    private var subtitleText: String {
        let total = filteredSessions.count
        let label = total == 1 ? "1 agent" : "\(total) agents"
        switch scopeSelection {
        case .global:
            return "\(label) · all projects"
        case let .project(_, name):
            return "\(label) · \(name)"
        }
    }

    // MARK: - Scope helpers

    private enum ScopeSelection {
        case global
        case project(UUID, String)
    }

    private var scopeSelection: ScopeSelection {
        guard scopeID != "global",
              let id = UUID(uuidString: scopeID),
              let p = projects.first(where: { $0.id == id }) else {
            return .global
        }
        return .project(p.id, p.name)
    }

    // MARK: - Session selection + filtering

    /// Sessions currently meaningful for the dashboard — anything
    /// still owned by the manager. The status filter is applied
    /// downstream so completed-but-still-mounted tiles stay visible
    /// for ~one screen of scrollback before they age out.
    private var liveSessions: [TerminalSession] {
        terminalManager.sessions
    }

    private var scopedSessions: [TerminalSession] {
        switch scopeSelection {
        case .global:
            return liveSessions
        case let .project(id, _):
            return liveSessions.filter { $0.projectID == id }
        }
    }

    private var filteredSessions: [TerminalSession] {
        scopedSessions.filter { passesFilter($0) }
    }

    private func passesFilter(_ s: TerminalSession) -> Bool {
        switch filter {
        case .all:     return true
        case .claude:  return s.engine == .claude
        case .codex:   return s.engine == .codex
        case .cowork:  return s.engine == .cowork
        case .eternal: return s.isEternalWorker
        case .stuck:   return s.status == .awaitingResponse
        }
    }

    // MARK: - KPI strip

    private var kpiStrip: some View {
        HStack(alignment: .center, spacing: 24) {
            kpi("AGENTS", value: "\(filteredSessions.count)")
            divider
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .center, spacing: 24) {
                    kpi("RUNTIME", value: runtimeString(at: context.date))
                    divider
                    kpi("LAST EVENT", value: lastEventString(at: context.date))
                }
            }
            divider
            kpi("TOKENS IN", value: formatTokens(totalInputTokens))
            divider
            kpi("TOKENS OUT", value: formatTokens(totalOutputTokens))
            divider
            kpi("COST", value: costString)
            Spacer(minLength: 16)
            if case .project = scopeSelection,
               let path = projectRootPath {
                OutlineButton("Open in Finder", icon: "arrow.up.forward.app", size: .small) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path, isDirectory: true)]
                    )
                }
                .help("Reveal the active project in Finder.")
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 14)
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.rule).frame(width: DK.ruleW, height: 22)
    }

    private func kpi(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            OverlineLabel(label, tint: Palette.ink4)
            Text(value)
                .font(Typography.monoLabel)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: - Filter row

    private var filterRow: some View {
        HStack(spacing: 16) {
            TabsStrip(
                tabs: Filter.allCases.map { f in
                    .init(id: f, label: f.rawValue, count: countString(for: f))
                },
                selection: $filter
            )
            .fixedSize()
            .frame(maxHeight: DK.tabsH)

            Spacer(minLength: 12)

            scopePicker
                .fixedSize()
                .padding(.trailing, DK.pageGutter)
        }
        .frame(height: DK.tabsH)
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scopeID) {
            Text("Global").tag("global")
            ForEach(projects) { project in
                Text(project.name).tag(project.id.uuidString)
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 120, idealWidth: 200, maxWidth: 220)
        .tint(Palette.ink2)
        .help("Filter rows to a specific project, or show every running agent.")
    }

    private func countString(for f: Filter) -> String {
        let n = scopedSessions.filter { s in
            switch f {
            case .all:     return true
            case .claude:  return s.engine == .claude
            case .codex:   return s.engine == .codex
            case .cowork:  return s.engine == .cowork
            case .eternal: return s.isEternalWorker
            case .stuck:   return s.status == .awaitingResponse
            }
        }.count
        return "\(n)"
    }

    // MARK: - Running section

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(label: "RUNNING", count: filteredSessions.count)
            if filteredSessions.isEmpty {
                runningEmpty
            } else {
                runningTable
            }
        }
    }

    private var runningEmpty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No agents running.")
                .font(Typography.body)
                .foregroundStyle(Palette.ink2)
            Text("Spawn a todo from the Todos page to mount a tile here.")
                .font(Typography.bodySm)
                .foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runningTable: some View {
        VStack(spacing: 0) {
            runningHeaderRow
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 0) {
                    ForEach(filteredSessions) { session in
                        runRow(session, at: context.date)
                        Rectangle()
                            .fill(Palette.rule)
                            .frame(height: DK.ruleW)
                    }
                }
            }
        }
        .background(Palette.bgElev)
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
    }

    private var runningHeaderRow: some View {
        HStack(spacing: 0) {
            // Status dot column header is intentionally blank —
            // each row's dot occupies the slot.
            Spacer().frame(width: dotColumnWidth)
            headerCell("ID",       width: idColumnWidth)
            headerCell("STAGE",    width: stageColumnWidth)
            headerCell("PID",      width: pidColumnWidth)
            headerCell("AGE / TURN", width: ageColumnWidth)
            headerCell("TOKENS",   width: tokensColumnWidth)
            headerCell("SESSION",  width: sessionColumnWidth)
            headerCell("EVENT",    width: nil)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Palette.bgRowHi)
    }

    private func headerCell(_ text: String, width: CGFloat?) -> some View {
        Group {
            if let width {
                OverlineLabel(text, tint: Palette.ink4)
                    .frame(width: width, alignment: .leading)
            } else {
                OverlineLabel(text, tint: Palette.ink4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Row rendering

    private func runRow(_ session: TerminalSession, at now: Date) -> some View {
        Button(action: { openOnCanvas(session) }) {
            HStack(spacing: 0) {
                statusDot(for: session)
                    .frame(width: dotColumnWidth, alignment: .leading)
                cellText(idLabel(for: session), width: idColumnWidth, tint: Palette.ink2)
                cellText(stageLabel(for: session.status),
                         width: stageColumnWidth,
                         tint: stageTint(for: session.status))
                cellText(pidLabel(for: session), width: pidColumnWidth, tint: Palette.ink3)
                cellText(ageTurnLabel(for: session, at: now),
                         width: ageColumnWidth, tint: Palette.ink2)
                cellText(tokensLabel(for: session),
                         width: tokensColumnWidth, tint: tokensTint(for: session))
                cellText(sessionLabel(for: session),
                         width: sessionColumnWidth, tint: Palette.ink3)
                cellText(eventLabel(for: session) ?? "—",
                         width: nil, tint: Palette.ink2)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverButtonStyle())
        .help("Open this tile on the canvas.")
    }

    private func statusDot(for session: TerminalSession) -> some View {
        let color = dotTint(for: session.status)
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .padding(.leading, 2)
    }

    private func cellText(_ text: String, width: CGFloat?, tint: Color) -> some View {
        Group {
            if let width {
                Text(text)
                    .font(Typography.monoRow)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width, alignment: .leading)
            } else {
                Text(text)
                    .font(Typography.monoRow)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Pending prompts section

    private var pendingPromptsSection: some View {
        let queued = filteredSessions.filter { !$0.promptQueue.isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(label: "PENDING PROMPTS", count: queued.count)
            if queued.isEmpty {
                pendingEmpty
            } else {
                pendingList(queued)
            }
        }
    }

    private var pendingEmpty: some View {
        Text("No queued prompts.")
            .font(Typography.body)
            .foregroundStyle(Palette.ink3)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pendingList(_ sessions: [TerminalSession]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                pendingRow(session)
                if idx < sessions.count - 1 {
                    Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
                }
            }
        }
        .background(Palette.bgElev)
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
    }

    private func pendingRow(_ session: TerminalSession) -> some View {
        let next = session.promptQueue.first ?? ""
        let depth = session.promptQueue.count
        return Button(action: { openOnCanvas(session) }) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink4)
                Text(idLabel(for: session))
                    .font(Typography.monoRow)
                    .foregroundStyle(Palette.ink2)
                    .frame(width: idColumnWidth, alignment: .leading)
                Text(formatPromptPreview(next))
                    .font(Typography.monoRow)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if depth > 1 {
                    Text("+\(depth - 1) more")
                        .font(Typography.monoBadge)
                        .foregroundStyle(Palette.ink4)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.bgRowHi)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowHoverButtonStyle())
        .help("Open this tile on the canvas. \(depth) prompt(s) queued.")
    }

    // MARK: - Section header

    private func sectionHeader(label: String, count: Int) -> some View {
        HStack(spacing: 10) {
            OverlineLabel(label, tint: Palette.ink4)
            Text("\(count)")
                .font(Typography.monoBadge)
                .foregroundStyle(Palette.ink3)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Palette.bgRowHi)
                .clipShape(Capsule())
            Spacer()
        }
    }

    // MARK: - Column widths

    private let dotColumnWidth:    CGFloat = 18
    private let idColumnWidth:     CGFloat = 70
    private let stageColumnWidth:  CGFloat = 110
    private let pidColumnWidth:    CGFloat = 80
    private let ageColumnWidth:    CGFloat = 120
    private let tokensColumnWidth: CGFloat = 90
    private let sessionColumnWidth: CGFloat = 130

    // MARK: - Cell formatting helpers

    private var gridColumns: Int {
        settingsList.first?.gridColumns ?? 3
    }

    private func idLabel(for session: TerminalSession) -> String {
        let columns = max(1, gridColumns)
        let col = session.gridIndex % columns + 1
        let row = session.gridIndex / columns + 1
        return "\(col),\(row)"
    }

    private func stageLabel(for status: SessionStatus) -> String {
        switch status {
        case .pending:          return "Pending"
        case .running:          return "Running"
        case .needsInput:       return "Needs input"
        case .awaitingResponse: return "Awaiting"
        case .completed:        return "Completed"
        case .failed:           return "Failed"
        }
    }

    private func stageTint(for status: SessionStatus) -> Color {
        switch status {
        case .running:          return Palette.ink
        case .needsInput:       return Palette.ink2
        case .awaitingResponse: return Palette.accent
        case .completed:        return Palette.ink3
        case .failed:           return Palette.danger
        case .pending:          return Palette.ink4
        }
    }

    private func dotTint(for status: SessionStatus) -> Color {
        switch status {
        case .running:          return Palette.accent
        case .needsInput:       return Palette.ink3
        case .awaitingResponse: return Palette.accent
        case .completed:        return Palette.ink4
        case .failed:           return Palette.danger
        case .pending:          return Palette.ink4
        }
    }

    private func pidLabel(for session: TerminalSession) -> String {
        guard let pid = session.processID, pid > 0 else { return "—" }
        return String(pid)
    }

    private func ageTurnLabel(for session: TerminalSession, at now: Date) -> String {
        let age = formatDuration(now.timeIntervalSince(session.startedAt))
        if session.turnCount > 0 {
            return "\(age) · \(session.turnCount)"
        }
        return age
    }

    private func tokensLabel(for session: TerminalSession) -> String {
        guard let snap = snapshot(for: session) else { return "—" }
        let total = (snap.inputTokens ?? 0) + (snap.outputTokens ?? 0)
        return total == 0 ? "—" : formatTokens(total)
    }

    private func tokensTint(for session: TerminalSession) -> Color {
        snapshot(for: session) == nil ? Palette.ink4 : Palette.ink2
    }

    private func sessionLabel(for session: TerminalSession) -> String {
        // First 8 hex chars + ellipsis + last 4 — just enough to be a
        // visually distinct fingerprint without dominating the row.
        let raw = session.id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        guard raw.count >= 12 else { return raw }
        let head = raw.prefix(8)
        let tail = raw.suffix(4)
        return "\(head)…\(tail)"
    }

    private func eventLabel(for session: TerminalSession) -> String? {
        for event in EventBus.shared.recent.reversed() {
            if event.source.sessionID == session.id {
                return event.title
            }
        }
        return nil
    }

    private func formatPromptPreview(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\"\(cleaned)\""
    }

    // MARK: - KPI math

    private var totalInputTokens: Int {
        guard let env = statusEnvelope else { return 0 }
        let allowedSessionIDs = Set(filteredSessions.map { $0.id.uuidString.lowercased() })
        return env.statuses
            .filter { snap in
                guard let sid = snap.tadoSessionID?.lowercased() else { return false }
                return allowedSessionIDs.contains(sid)
            }
            .reduce(0) { $0 + ($1.inputTokens ?? 0) }
    }

    private var totalOutputTokens: Int {
        guard let env = statusEnvelope else { return 0 }
        let allowedSessionIDs = Set(filteredSessions.map { $0.id.uuidString.lowercased() })
        return env.statuses
            .filter { snap in
                guard let sid = snap.tadoSessionID?.lowercased() else { return false }
                return allowedSessionIDs.contains(sid)
            }
            .reduce(0) { $0 + ($1.outputTokens ?? 0) }
    }

    private var totalCostUSD: Double {
        guard let env = statusEnvelope else { return 0 }
        let allowedSessionIDs = Set(filteredSessions.map { $0.id.uuidString.lowercased() })
        return env.statuses
            .filter { snap in
                guard let sid = snap.tadoSessionID?.lowercased() else { return false }
                return allowedSessionIDs.contains(sid)
            }
            .reduce(0.0) { $0 + ($1.costUSD ?? 0.0) }
    }

    private var costString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: totalCostUSD)) ?? "$0.00"
    }

    private func runtimeString(at now: Date) -> String {
        let oldest = filteredSessions.compactMap { $0.startedAt }.min()
        guard let oldest else { return "—" }
        return formatDuration(now.timeIntervalSince(oldest))
    }

    private func lastEventString(at now: Date) -> String {
        let scopedSessionIDs = Set(filteredSessions.map { $0.id })
        let latest = EventBus.shared.recent
            .reversed()
            .first(where: { e in
                guard let sid = e.source.sessionID else { return false }
                return scopedSessionIDs.contains(sid)
            })
        guard let latest else { return "—" }
        let delta = now.timeIntervalSince(latest.ts)
        return "\(formatShortDuration(delta)) ago"
    }

    private var projectRootPath: String? {
        guard case let .project(id, _) = scopeSelection,
              let p = projects.first(where: { $0.id == id }) else { return nil }
        return p.rootPath
    }

    // MARK: - Snapshot lookup

    /// Find the AgentStatusSnapshot keyed by `tadoSessionID` for the
    /// given live session. The Claude statusLine writer indexes
    /// snapshots by `<tado-session-id>.json`, which carries the raw
    /// UUID string; we match case-insensitively against the canonical
    /// uppercased form.
    private func snapshot(for session: TerminalSession) -> DomeRpcClient.AgentStatusSnapshot? {
        guard let env = statusEnvelope else { return nil }
        let target = session.id.uuidString.lowercased()
        return env.statuses.first {
            ($0.tadoSessionID?.lowercased()) == target
        }
    }

    // MARK: - Formatting helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0 { return "—" }
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    private func formatShortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0 { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    private func formatTokens(_ value: Int) -> String {
        if value <= 0 { return "—" }
        let absVal = Double(value)
        if absVal >= 1_000_000 {
            return String(format: "%.1fM", absVal / 1_000_000)
        }
        if absVal >= 1_000 {
            return String(format: "%.1fK", absVal / 1_000)
        }
        return String(value)
    }

    // MARK: - Click-through: open the tile on the canvas

    private func openOnCanvas(_ session: TerminalSession) {
        guard let todo = todos.first(where: { $0.id == session.todoID }) else { return }
        appState.pendingNavigationID = todo.id
        appState.currentView = .canvas
    }

    // MARK: - Reload

    @MainActor
    private func reload(silent: Bool = false) async {
        if !silent { isLoading = true }
        let env = await Task.detached { DomeRpcClient.agentStatus(limit: 100, domeScope: nil) }.value
        await MainActor.run {
            self.statusEnvelope = env
            self.isLoading = false
        }
    }
}

// MARK: - Row hover style

/// Plain SwiftUI buttons highlight via `.hover`, but we want a
/// subtle row-hover feel that matches the rest of the app
/// (Cross-Run Browser, Calendar). This style swaps `clear` ↔
/// `bgRowHi` while hovered or pressed, leaving rest-state
/// transparent so the container's `bgElev` shows through.
///
/// Note: `ButtonStyle` is a value type and gets re-instantiated on
/// every render, so `@State` doesn't persist there. We delegate the
/// per-row hover state to a wrapper `View` that does have stable
/// identity for the lifetime of the row.
private struct RowHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowHoverContent(configuration: configuration)
    }
}

private struct RowHoverContent: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered: Bool = false

    var body: some View {
        configuration.label
            .background(
                hovered || configuration.isPressed
                    ? Palette.bgRowHi
                    : Color.clear
            )
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.08), value: hovered)
    }
}
