import SwiftUI

/// Window-style notifications surface for the migrated extension.
/// Reads the in-memory ring (`EventBus.shared.recent`) plus supports
/// severity filter + free-text search. Older events live in
/// `~/Library/Application Support/Tado/events/archive/*.ndjson` and
/// will be paged in by a follow-up packet.
///
/// v0.18 — restyled on the structural-grid design language:
/// PageHeader-style title bar with `MetaStrip` (Total / Unread / Window),
/// a horizontal filter strip of severity OutlineButtons + composer-style
/// search input, flat-tabular notification rows with leading severity
/// dot + StatusPill metadata.
struct NotificationsWindowView: View {
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
        .background(Palette.bgPage)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink)
                Text("Live event ring + recent history")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 16)
            MetaStrip {
                MetaCell(
                    key: "Status",
                    value: unreadCount > 0 ? "● Unread" : "○ Read",
                    tint: unreadCount > 0 ? Palette.accent : Palette.ink3
                )
                MetaCell(key: "Total", value: "\(totalCount)")
                MetaCell(key: "Unread", value: "\(unreadCount)", trailingDivider: false)
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
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
                    .foregroundStyle(Palette.ink4)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 60, idealWidth: 220)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Palette.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            .layoutPriority(0)
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 10)
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private func severityChip(_ severity: TadoEvent.Severity?, label: String) -> some View {
        let selected = severityFilter == severity
        return OutlineButton(
            label,
            size: .small,
            variant: selected ? .accent : .standard,
            action: { severityFilter = severity }
        )
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
                        Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
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
                    .foregroundStyle(Palette.ink4)
                Text("No notifications to show")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text("Events fan in from `EventBus.shared` — terminal completions, eternal phase transitions, dome daemon updates, and user broadcasts all land here.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("EVENT RING  ·  in-memory  ·  archived nightly to <storage-root>/events/archive/")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.rule).frame(height: 1).padding(.horizontal, -2)
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
                .foregroundStyle(Palette.ink4)
            Spacer()
            OutlineButton(
                "Mark all read",
                icon: "checkmark.circle",
                size: .small,
                variant: .standard,
                action: {
                    EventBus.shared.markAllRead()
                    DockBadgeUpdater.shared.refresh()
                }
            )
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }
}

// MARK: - Row

private struct NotificationRow: View {
    let event: TadoEvent

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
                        .foregroundStyle(event.read ? Palette.ink2 : Palette.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(timeString(event.ts))
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                        .monospacedDigit()
                }
                if !event.body.isEmpty {
                    Text(event.body)
                        .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
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
        .background(Palette.bgElev)
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
        .foregroundStyle(Palette.ink4)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Palette.bgPage)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private var severityColor: Color {
        switch event.severity {
        case .info:    return Palette.accent
        case .success: return Palette.green
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
