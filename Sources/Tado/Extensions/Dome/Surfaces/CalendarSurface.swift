import SwiftUI

/// Agent Activity Ledger — Tado's chronological feed of every typed
/// event the deliverer chain publishes to `EventBus.shared.recent`,
/// scope-filtered through the active Dome scope and grouped by day.
///
/// View modes:
///   - **Ledger** (default) — newest-first list grouped by day, with
///     a click-to-jump deep-link per row.
///   - **Month** (secondary) — the legacy month grid kept for users
///     who want a calendar at-a-glance; events are summarised as a
///     count badge per day.
///
/// `domeScope` ties the surface to the active Dome scope picker so the
/// ledger automatically narrows when a project is selected.
struct CalendarSurface: View {
    let domeScope: DomeScopeSelection

    @Environment(DomeAppState.self) private var domeState
    @State private var mode: Mode = .ledger
    /// Currently-expanded event row. Click toggles expansion; the
    /// expanded panel shows full body + metadata + the deep-link as
    /// selectable text. The in-app URL router is a follow-up; for now
    /// we deliberately avoid `NSWorkspace.shared.open` since `tado://`
    /// has no registered handler (the OS pops a "no app" dialog or
    /// re-foregrounds Tado).
    @State private var expandedID: UUID? = nil

    enum Mode: String, CaseIterable, Identifiable {
        case ledger
        case month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ledger: return "Ledger"
            case .month: return "Month"
            }
        }
    }

    private var eventBus: EventBus { EventBus.shared }

    private var groups: [EventLedger.DayGroup] {
        EventLedger.build(
            events: Array(eventBus.recent),
            scope: domeScope,
            filter: EventLedger.Filter(
                kinds: domeState.globalFilters.kinds,
                since: domeState.globalFilters.since
            )
        )
    }

    /// Stable union of kind prefixes seen in `EventBus.recent`. Used
    /// to render the chip row so the user only sees filters they can
    /// actually toggle. Delegates to `EventLedger.kindPrefixes` so the
    /// helper can be exercised by `EventLedgerTests` without booting a
    /// view.
    private var availableKindPrefixes: [String] {
        EventLedger.kindPrefixes(in: Array(eventBus.recent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !availableKindPrefixes.isEmpty {
                Divider().overlay(Palette.divider)
                kindChips
            }
            Divider().overlay(Palette.divider)
            content
        }
        .background(Palette.background)
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Kind")
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.trailing, 2)
                    .accessibilityHidden(true)
                kindChip(label: "All", isAll: true)
                ForEach(availableKindPrefixes, id: \.self) { prefix in
                    kindChip(label: prefix, isAll: false)
                }
                Divider().frame(height: 16).overlay(Palette.divider)
                Text("Since")
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.trailing, 2)
                    .accessibilityHidden(true)
                sinceChip(label: "All time", window: nil)
                ForEach(EventLedger.SinceWindow.allCases) { window in
                    sinceChip(label: window.label, window: window)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Palette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity filter row")
    }

    private func sinceChip(label: String, window: EventLedger.SinceWindow?) -> some View {
        let active = matchesActiveSinceWindow(window)
        return Button(action: { applySinceWindow(window) }) {
            Text(label)
                .font(Typography.micro)
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Palette.surfaceAccent : Palette.surfaceElevated)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) since-range chip")
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    private func matchesActiveSinceWindow(_ window: EventLedger.SinceWindow?) -> Bool {
        guard let window else { return domeState.globalFilters.since == nil }
        return window.matches(domeState.globalFilters.since)
    }

    private func applySinceWindow(_ window: EventLedger.SinceWindow?) {
        domeState.globalFilters.since = window?.cutoff()
    }

    private func kindChip(label: String, isAll: Bool) -> some View {
        let active = isAll ? domeState.globalFilters.kinds.isEmpty : domeState.globalFilters.kinds.contains(label)
        return Button(action: { toggleKind(label, isAll: isAll) }) {
            Text(label)
                .font(Typography.micro)
                .foregroundStyle(active ? Palette.textPrimary : Palette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Palette.surfaceAccent : Palette.surfaceElevated)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) filter chip")
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    private func toggleKind(_ label: String, isAll: Bool) {
        if isAll {
            domeState.globalFilters.kinds.removeAll()
            return
        }
        var current = domeState.globalFilters.kinds
        if current.contains(label) {
            current.remove(label)
        } else {
            current.insert(label)
        }
        domeState.globalFilters.kinds = current
    }

    private var header: some View {
        HStack {
            Text("Activity")
                .font(Typography.display)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 220)
            .accessibilityLabel("Activity view mode")
            .accessibilityHint("Switch between the chronological ledger and the month-grid summary.")
            Text("\(visibleEventCount) events")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityLabel("\(visibleEventCount) events visible")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var visibleEventCount: Int {
        groups.reduce(0) { $0 + $1.events.count }
    }

    @ViewBuilder
    private var content: some View {
        if eventBus.recent.isEmpty {
            empty
        } else {
            switch mode {
            case .ledger: ledger
            case .month: month
            }
        }
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

    // MARK: - Ledger view

    private var ledger: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.day) { group in
                    dayGroup(group)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func dayGroup(_ group: EventLedger.DayGroup) -> some View {
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
        let deepLink = EventLedger.deepLink(for: event)
        let isExpanded = expandedID == event.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedID = isExpanded ? nil : event.id
                }
            } label: {
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
                        if !event.body.isEmpty && !isExpanded {
                            Text(event.body)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(3)
                        }
                        HStack(spacing: 6) {
                            Text(event.type)
                                .font(Typography.micro)
                                .foregroundStyle(Palette.textTertiary)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(eventRowAccessibilityLabel(event))
            .accessibilityValue(Self.timeFmt.string(from: event.ts))
            .accessibilityHint(isExpanded ? "Collapses details." : "Expands details.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !event.body.isEmpty {
                        Text(event.body)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().overlay(Palette.divider)
                    metadataRow("Type", event.type)
                    metadataRow("Severity", event.severity.rawValue)
                    if let link = deepLink {
                        metadataRow("Jump target", link)
                    }
                }
                .padding(.vertical, 8)
                .padding(.leading, 20)
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func eventRowAccessibilityLabel(_ event: TadoEvent) -> String {
        var pieces = [event.severity.rawValue, event.title]
        if !event.body.isEmpty {
            pieces.append(event.body)
        }
        pieces.append(event.type)
        return pieces.joined(separator: ", ")
    }

    private func tint(for severity: TadoEvent.Severity) -> Color {
        switch severity {
        case .info: return Palette.textTertiary
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error: return Palette.danger
        }
    }

    // MARK: - Month grid (secondary)

    private var month: some View {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let monthStart = cal.date(from: comps) ?? now
        let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<2
        let countByDay: [Date: Int] = Dictionary(uniqueKeysWithValues: groups.map { ($0.day, $0.events.count) })
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(range, id: \.self) { day in
                    let date = cal.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                    let count = countByDay[cal.startOfDay(for: date)] ?? 0
                    monthCell(day: day, count: count, isToday: cal.isDateInToday(date))
                }
            }
            .padding(20)
        }
    }

    private func monthCell(day: Int, count: Int, isToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(day)")
                .font(Typography.caption)
                .foregroundStyle(isToday ? Palette.accent : Palette.textSecondary)
            if count > 0 {
                Text("\(count)")
                    .font(Typography.micro)
                    .foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(height: 64, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isToday ? Palette.surfaceAccent : Palette.surfaceElevated)
        )
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
