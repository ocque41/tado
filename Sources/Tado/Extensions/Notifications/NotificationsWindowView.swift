import SwiftUI

/// Window-style notifications surface for the migrated extension.
/// Reads the in-memory ring (`EventBus.shared.recent`) plus supports
/// severity filter + free-text search. Older events live in
/// `~/Library/Application Support/Tado/events/archive/*.ndjson` and
/// will be paged in by a follow-up packet.
struct NotificationsWindowView: View {
    @State private var severityFilter: TadoEvent.Severity? = nil
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 520)
        .background(Palette.surface)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Notifications")
                .font(Typography.heading)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.surfaceElevated)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            severityChip(nil, label: "All")
            severityChip(.info, label: "Info")
            severityChip(.success, label: "Success")
            severityChip(.warning, label: "Warning")
            severityChip(.error, label: "Error")
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                TextField("Search title or body", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 200)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Palette.surfaceElevated)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func severityChip(_ severity: TadoEvent.Severity?, label: String) -> some View {
        let selected = severityFilter == severity
        return Button {
            severityFilter = severity
        } label: {
            Text(label)
                .font(Typography.monoCaption)
                .foregroundStyle(selected ? Palette.accent : Palette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(selected ? Palette.surfaceAccent : Palette.surfaceElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredEvents.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 28))
                            .foregroundStyle(Palette.textTertiary)
                        Text("No notifications to show.")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    ForEach(filteredEvents) { event in
                        NotificationRow(event: event)
                            .onTapGesture { EventBus.shared.markRead(event.id) }
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private var filteredEvents: [TadoEvent] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let items = EventBus.shared.recent.reversed().filter { event in
            if let sev = severityFilter, event.severity != sev { return false }
            if !trimmed.isEmpty {
                let hay = (event.title + " " + event.body).lowercased()
                if !hay.contains(trimmed) { return false }
            }
            return true
        }
        return Array(items)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(EventBus.shared.recent.count) event(s) in ring")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textTertiary)
            Spacer()
            Button("Mark all read") {
                EventBus.shared.markAllRead()
                DockBadgeUpdater.shared.refresh()
            }
            .buttonStyle(.plain)
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.surfaceElevated)
    }
}

// MARK: - Row

private struct NotificationRow: View {
    let event: TadoEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(severityColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(Typography.label)
                        .foregroundStyle(event.read ? Palette.textSecondary : Palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(timeString(event.ts))
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.textTertiary)
                        .monospacedDigit()
                }
                if !event.body.isEmpty {
                    Text(event.body)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(3)
                }
                HStack(spacing: 6) {
                    chip(event.type)
                    if let project = event.source.projectName, !project.isEmpty {
                        chip(project, icon: "folder")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(event.title, forType: .string)
            }
            Button("Copy event JSON") {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted]
                if let data = try? encoder.encode(event),
                   let str = String(data: data, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(str, forType: .string)
                }
            }
        }
    }

    private func chip(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8)) }
            Text(text).font(Typography.monoMicro)
        }
        .foregroundStyle(Palette.textTertiary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var severityColor: Color {
        switch event.severity {
        case .info:    return Palette.accent
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error:   return Palette.danger
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}
