import SwiftUI

/// Timeline of agent activity across Tado, backed by `EventBus`.
/// Every event the deliverer chain publishes to `EventBus.shared.recent`
/// appears here in reverse-chronological order, grouped by day, with
/// severity-tinted iconography.
///
/// v0.11 scope: bus-only source. Later phases merge Dome note events
/// and Eternal retro entries once those emit to the bus (C5 rest + C2).
struct CalendarSurface: View {
    private var eventBus: EventBus { EventBus.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.divider)
            if eventBus.recent.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(Palette.background)
    }

    private var header: some View {
        HStack {
            Text("Calendar")
                .font(Typography.display)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Text("\(eventBus.recent.count) events")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("No events yet. Spawn a terminal or run an automation.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedEvents, id: \.day) { group in
                    dayGroup(group)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func dayGroup(_ group: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dayLabel(group.day))
                .font(Typography.headingSm)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 16)
            ForEach(group.events) { event in
                eventRow(event)
            }
        }
    }

    private func eventRow(_ event: TadoEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(tint(for: event.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(Typography.label)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.timeFmt.string(from: event.ts))
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }
                if !event.body.isEmpty {
                    Text(event.body)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                }
                Text(event.type)
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tint(for severity: TadoEvent.Severity) -> Color {
        switch severity {
        case .info: return Palette.textTertiary
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error: return Palette.danger
        }
    }

    // MARK: - Grouping

    private struct DayGroup {
        let day: Date
        let events: [TadoEvent]
    }

    private var groupedEvents: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: eventBus.recent.reversed()) { (event: TadoEvent) in
            cal.startOfDay(for: event.ts)
        }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                events: grouped[day]!.sorted { $0.ts > $1.ts }
            )
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return Self.dayFmt.string(from: day)
    }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
