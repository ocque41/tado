import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(TerminalManager.self) private var terminalManager
    @Query private var allSettings: [AppSettings]

    @State private var filter: String = ""

    private var settings: AppSettings? { allSettings.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()

            if terminalManager.sessions.isEmpty {
                Spacer()
                Text("No active sessions")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedSessions, id: \.key) { group in
                            ProjectGroupSection(
                                title: group.key,
                                sessions: group.value,
                                settings: settings
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
            if !terminalManager.sessions.isEmpty {
                Button(action: terminateAll) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Terminate All")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Palette.danger)
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
        .background(Palette.surface)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Sessions")
                .font(Typography.heading)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            NotificationsBell()
            Text("\(visibleSessions.count)\(filter.isEmpty ? "" : "/\(terminalManager.sessions.count)")")
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Palette.surfaceElevated)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.surfaceElevated)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
            TextField("Filter by text, project, model, agent…", text: $filter)
                .textFieldStyle(.plain)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textPrimary)
            if !filter.isEmpty {
                Button(action: { filter = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Grouping + filtering

    /// Sessions that match the current filter. Matches against todo text,
    /// title, project, team, agent, and run role.
    private var visibleSessions: [TerminalSession] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return terminalManager.sessions }
        return terminalManager.sessions.filter { session in
            let haystack = [
                session.todoText,
                session.title,
                session.projectName ?? "",
                session.teamName ?? "",
                session.agentName ?? "",
                session.runRole ?? "",
                modelShortName(for: session),
                session.engine?.rawValue ?? ""
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    /// Sessions grouped by project name; `nil` becomes `Unassigned`. Project
    /// groups are sorted alphabetically, `Unassigned` always last. Within a
    /// group, newest sessions first.
    private var groupedSessions: [(key: String, value: [TerminalSession])] {
        let unassignedKey = "Unassigned"
        var buckets: [String: [TerminalSession]] = [:]
        for session in visibleSessions {
            let key = session.projectName?.isEmpty == false ? session.projectName! : unassignedKey
            buckets[key, default: []].append(session)
        }
        for key in buckets.keys {
            buckets[key]?.sort { $0.startedAt > $1.startedAt }
        }
        let projectKeys = buckets.keys.filter { $0 != unassignedKey }.sorted()
        var ordered: [(key: String, value: [TerminalSession])] = projectKeys.map { ($0, buckets[$0]!) }
        if let unassigned = buckets[unassignedKey] {
            ordered.append((unassignedKey, unassigned))
        }
        return ordered
    }

    private func modelShortName(for session: TerminalSession) -> String {
        if let override = session.modelFlagsOverride, override.count >= 2 {
            return prettifyModel(override[1])
        }
        switch session.engine {
        case .codex: return prettifyModel(settings?.codexModel.rawValue ?? "")
        case .claude, .none: return prettifyModel(settings?.claudeModel.rawValue ?? "")
        }
    }

    private func terminateAll() {
        let ids = terminalManager.sessions.map(\.id)
        for id in ids {
            terminalManager.terminateSession(id)
        }
    }
}

// MARK: - Project group

private struct ProjectGroupSection: View {
    let title: String
    let sessions: [TerminalSession]
    let settings: AppSettings?

    @State private var expanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(sessions) { session in
                    SessionRow(session: session, settings: settings)
                    Divider().padding(.leading, 28)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(sessions.count)")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Palette.surfaceElevated)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let session: TerminalSession
    let settings: AppSettings?

    @Environment(AppState.self) private var appState

    var body: some View {
        Button(action: jumpToCanvas) {
            VStack(alignment: .leading, spacing: 4) {
                topLine
                chipLine
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detailTooltip)
    }

    // MARK: Lines

    private var topLine: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(displayTitle)
                .font(Typography.monoRow)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(formatUptime(since: session.startedAt, now: context.date))
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    private var chipLine: some View {
        FlowLayout(spacing: 4) {
            if let engine = session.engine {
                chip(text: engine.rawValue, systemImage: "terminal")
            }
            if let model = modelChipText {
                chip(text: model)
            }
            if let effort = effortChipText {
                chip(text: effort)
            }
            if let agent = session.agentName {
                chip(text: agent, systemImage: "person.crop.circle")
            }
            if let run = runChipText {
                chip(text: run, systemImage: runChipIcon)
            }
            if let role = session.runRole {
                chip(text: role)
            }
            chip(text: CanvasLayout.gridLabel(forIndex: session.gridIndex))
        }
        .padding(.leading, 16)
    }

    // MARK: Chip construction

    private func chip(text: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(Typography.monoMicro)
        }
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: Derived fields

    private var displayTitle: String {
        let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != session.todoText { return trimmed }
        return session.todoText
    }

    private var statusColor: Color {
        switch session.status {
        case .pending:    return Palette.textTertiary
        case .running:    return Palette.accent
        case .needsInput: return Palette.warning
        case .completed:  return Palette.success
        case .failed:     return Palette.danger
        }
    }

    private var modelChipText: String? {
        if let override = session.modelFlagsOverride, override.count >= 2 {
            return prettifyModel(override[1]).nilIfEmpty
        }
        let raw: String?
        switch session.engine {
        case .codex: raw = settings?.codexModel.rawValue
        case .claude, .none: raw = settings?.claudeModel.rawValue
        }
        guard let raw else { return nil }
        return prettifyModel(raw).nilIfEmpty
    }

    private var effortChipText: String? {
        if let override = session.effortFlagsOverride, override.count >= 2 {
            return override[1]
        }
        return nil
    }

    private var runChipText: String? {
        if session.eternalRunID != nil {
            if let mode = session.eternalMode, !mode.isEmpty { return "eternal·\(mode)" }
            return "eternal"
        }
        if session.dispatchRunID != nil { return "dispatch" }
        return nil
    }

    private var runChipIcon: String? {
        if session.eternalRunID != nil { return "infinity" }
        if session.dispatchRunID != nil { return "square.stack.3d.up" }
        return nil
    }

    private var detailTooltip: String {
        var lines: [String] = []
        lines.append(session.todoText)
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != session.todoText {
            lines.append("Title: \(trimmedTitle)")
        }
        if let engine = session.engine { lines.append("Engine: \(engine.rawValue)") }
        if let model = modelChipText { lines.append("Model: \(model)") }
        if let effort = effortChipText { lines.append("Effort: \(effort)") }
        if let project = session.projectName { lines.append("Project: \(project)") }
        if let root = session.projectRoot { lines.append("Root: \(root)") }
        if let team = session.teamName { lines.append("Team: \(team)") }
        if let peers = session.teamAgents, !peers.isEmpty {
            lines.append("Team agents: \(peers.joined(separator: ", "))")
        }
        if let agent = session.agentName { lines.append("Agent: \(agent)") }
        if let runID = session.eternalRunID {
            var s = "Eternal run: \(runID.uuidString.prefix(8))"
            if let mode = session.eternalMode { s += " (\(mode)" }
            if let kind = session.eternalLoopKind { s += session.eternalMode != nil ? ", \(kind))" : " (\(kind))" }
            else if session.eternalMode != nil { s += ")" }
            lines.append(s)
        }
        if let runID = session.dispatchRunID {
            lines.append("Dispatch run: \(runID.uuidString.prefix(8))")
        }
        if let role = session.runRole { lines.append("Role: \(role)") }
        lines.append("Grid: \(CanvasLayout.gridLabel(forIndex: session.gridIndex))")
        lines.append("Started: \(detailDateFormatter.string(from: session.startedAt))")
        lines.append("Status: \(session.status.rawValue)")
        return lines.joined(separator: "\n")
    }

    private func jumpToCanvas() {
        appState.pendingNavigationID = session.todoID
        appState.currentView = .canvas
    }
}

// MARK: - Helpers

private let detailDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .medium
    return f
}()

/// Strip common vendor prefixes so chips stay narrow. `claude-opus-4-7` →
/// `opus-4-7`, `gpt-5.4` → `5.4`. Whitespace-only input returns empty.
private func prettifyModel(_ id: String) -> String {
    var s = id.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
    if s.hasPrefix("gpt-")    { s = String(s.dropFirst("gpt-".count)) }
    return s
}

/// Compact uptime like `3s`, `42m`, `1h 12m`, `2d 4h`. Drops precision as
/// the duration grows so the chip doesn't wobble width.
private func formatUptime(since start: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d \((s % 86400) / 3600)h"
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Notifications bell

/// Bell icon with unread badge. Opens `NotificationsView` as a sheet.
/// Lives in the sidebar header so it's always one click away
/// regardless of current view.
private struct NotificationsBell: View {
    @Environment(AppState.self) private var appState
    // Reading this observed property in the body re-renders the bell
    // whenever a new event arrives — we don't need to cache the count.
    private var unread: Int { EventBus.shared.unreadCount }

    var body: some View {
        Button {
            appState.showNotifications = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: unread > 0 ? "bell.fill" : "bell")
                    .font(.system(size: 13))
                    .foregroundStyle(unread > 0 ? Palette.accent : Palette.textSecondary)
                    .frame(width: 22, height: 22)
                if unread > 0 {
                    Text(unread > 99 ? "99+" : String(unread))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.danger))
                        .offset(x: 6, y: -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(unread > 0 ? "Notifications (\(unread) unread)" : "Notifications")
    }
}
