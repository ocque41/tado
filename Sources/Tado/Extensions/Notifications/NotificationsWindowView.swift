import SwiftUI
import AppKit

/// Window-style notifications surface for the migrated extension.
/// Reads the in-memory ring (`EventBus.shared.recent`) plus supports
/// severity filter + free-text search. Older events live in
/// `~/Library/Application Support/Tado/events/archive/*.ndjson` and
/// will be paged in by a follow-up packet.
///
/// v0.18 — restyled on the structural-grid design language:
/// Relay title bar, compact status strip, severity filters, search,
/// and flat notification rows with leading severity dots.
struct NotificationsWindowView: View {
    @Environment(\.relayTheme) private var theme
    @State private var severityFilter: TadoEvent.Severity? = nil
    @State private var query: String = ""

    private var totalCount: Int { EventBus.shared.recent.count }
    private var unreadCount: Int { EventBus.shared.recent.filter { !$0.read }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            list
            footer
        }
        .background(RelayPalette.background(for: theme))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications")
                    .font(RelayType.h2(size: 32))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Text("Live event ring + recent history")
                    .font(Typography.sans(size: 11, weight: .regular))
                    .tracking(RelayTracking.meta(11))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
            }
            Spacer(minLength: 16)
            NotificationsMetaStrip {
                NotificationsMetaCell(
                    key: "Status",
                    value: unreadCount > 0 ? "● Unread" : "○ Read",
                    tint: unreadCount > 0 ? RelayPalette.terracotta : RelayPalette.foreground3(for: theme)
                )
                NotificationsMetaCell(key: "Total", value: "\(totalCount)")
                NotificationsMetaCell(key: "Unread", value: "\(unreadCount)", trailingDivider: false)
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RelayPalette.hair(for: theme)).frame(height: 1)
        }
    }

    // MARK: - Filter strip

    private var filterBar: some View {
        HStack(spacing: 6) {
            severityChip(nil, label: "All")
            severityChip(.info, label: "Info")
            severityChip(.success, label: "Success")
            severityChip(.warning, label: "Warning")
            severityChip(.error, label: "Error")
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(RelayPalette.foreground4(for: theme))
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typography.sans(size: 11.5, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                    .frame(minWidth: 60, idealWidth: 220)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RelayPalette.wash(for: theme))
            .overlay(
                RoundedRectangle(cornerRadius: RelayRadius.standard)
                    .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
            .layoutPriority(0)
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 10)
        .background(RelayPalette.background(for: theme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(RelayPalette.hair(for: theme)).frame(height: 1)
        }
    }

    private func severityChip(_ severity: TadoEvent.Severity?, label: String) -> some View {
        let selected = severityFilter == severity
        return Button {
            severityFilter = severity
        } label: {
            Text(label.uppercased())
                .font(Typography.sans(size: 10, weight: .semibold))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(selected ? RelayPalette.terracotta : RelayPalette.foreground2(for: theme))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? RelayPalette.terracotta.opacity(0.10) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: RelayRadius.standard)
                        .stroke(selected ? RelayPalette.terracotta : RelayPalette.hair(for: theme), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredEvents.isEmpty {
                    emptyBlock
                } else {
                    ForEach(filteredEvents) { event in
                        NotificationRow(event: event)
                            .onTapGesture { EventBus.shared.markRead(event.id) }
                        Rectangle().fill(RelayPalette.hairSoft(for: theme)).frame(height: 1)
                    }
                }
            }
        }
    }

    private var emptyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(RelayPalette.foreground4(for: theme))
                Text("No notifications to show")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
            }
            Text("Terminal, run, Dome, and broadcast events appear here.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("EVENT RING  ·  in-memory  ·  archived nightly to <storage-root>/events/archive/")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(RelayPalette.foreground4(for: theme))
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(RelayPalette.hair(for: theme)).frame(height: 1).padding(.horizontal, -2)
                }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        HStack(spacing: 8) {
            Text("\(EventBus.shared.recent.count) event(s) in ring")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(RelayPalette.foreground4(for: theme))
            Spacer()
            RelayButton(label: "Mark all read", variant: .standard, icon: "checkmark.circle") {
                EventBus.shared.markAllRead()
                DockBadgeUpdater.shared.refresh()
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 10)
        .background(RelayPalette.wash(for: theme))
        .overlay(alignment: .top) {
            Rectangle().fill(RelayPalette.hair(for: theme)).frame(height: 1)
        }
    }
}

private struct NotificationsMetaStrip<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .background(RelayPalette.background(for: theme))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
    }
}

private struct NotificationsMetaCell: View {
    let key: String
    let value: String
    var tint: Color? = nil
    var trailingDivider: Bool = true

    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.uppercased())
                    .font(Typography.sans(size: 9, weight: .semibold))
                    .tracking(RelayTracking.caps(9))
                    .foregroundStyle(RelayPalette.foreground4(for: theme))
                Text(value)
                    .font(Typography.sans(size: 12, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? RelayPalette.foreground(for: theme))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if trailingDivider {
                Rectangle()
                    .fill(RelayPalette.hair(for: theme))
                    .frame(width: 1)
            }
        }
        .frame(minHeight: 40)
    }
}

// MARK: - Row

private struct NotificationRow: View {
    let event: TadoEvent
    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(severityColor)
                .frame(width: 6, height: 6)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(.system(size: 12.5, weight: event.read ? .regular : .semibold))
                        .foregroundStyle(event.read ? RelayPalette.foreground2(for: theme) : RelayPalette.foreground(for: theme))
                        .lineLimit(1)
                    Spacer()
                    Text(timeString(event.ts))
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(RelayPalette.foreground4(for: theme))
                        .monospacedDigit()
                }
                if !event.body.isEmpty {
                    Text(event.body)
                        .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(RelayPalette.foreground3(for: theme))
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
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayPalette.wash(for: theme))
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
            Text(text).font(Font.system(size: 10, weight: .regular, design: .monospaced))
        }
        .foregroundStyle(RelayPalette.foreground4(for: theme))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RelayPalette.background(for: theme))
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: RelayRadius.standard))
    }

    private var severityColor: Color {
        switch event.severity {
        case .info:    return RelayPalette.terracotta
        case .success: return RelayPalette.foreground2(for: theme)
        case .warning: return RelayPalette.terracotta.opacity(0.75)
        case .error:   return RelayPalette.terracotta
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}
