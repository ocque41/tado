import SwiftUI

/// **Activity** (v0.20) — Tado's chronological feed of every typed
/// event the deliverer chain publishes to `EventBus.shared.recent`,
/// scope-filtered through the active Dome scope and grouped by day.
///
/// Restructured to match the design's "Activity" page on Tado's
/// existing chrome: a persistent KPI strip, four tabs with counts, a
/// filter bar (kind / since chips), and a sticky right rail of
/// contextual actions. Same data sources as v0.17 — only the structure
/// landed.
///
/// Tabs:
///   - **Recent** — in-process EventBus ledger (last few hundred
///     typed events), expandable rows with status dots and topic
///     micro-labels.
///   - **Month** — 7-col calendar grid, today highlighted, per-day
///     count + density meter.
///   - **All activity** — bt-core daemon timeline (automations +
///     agent runs + ratings + evals), with a range-bucket strip
///     (5 min / hour / 24h / 7 days / 30 days) and a 24×7 hour-of-day
///     heatmap.
///   - **Audit** — audit-log table relocated from Knowledge → System.
///     Filter by action prefix; row expand for full details JSON.
///
/// `domeScope` ties the surface to the active Dome scope picker so the
/// ledger automatically narrows when a project is selected.
struct CalendarSurface: View {
    let domeScope: DomeScopeSelection

    @Environment(DomeAppState.self) private var domeState

    enum Tab: Hashable {
        case recent, month, allActivity, audit
        var label: String {
            switch self {
            case .recent: return "Recent"
            case .month: return "Month"
            case .allActivity: return "All activity"
            case .audit: return "Audit"
            }
        }
        var description: String {
            switch self {
            case .recent: return "In-app event ledger from this session."
            case .month: return "Month grid summary of the in-app ledger."
            case .allActivity: return "Daemon timeline — automations, agent runs, ratings, evals."
            case .audit: return "Audit log — every mutator call against the daemon."
            }
        }
    }

    enum AllActivityRange: Int, CaseIterable, Identifiable {
        case fiveMin, hour, day, week, month
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .fiveMin: return "Last 5 min"
            case .hour: return "Last hour"
            case .day: return "Last 24 h"
            case .week: return "Last 7 days"
            case .month: return "Last 30 days"
            }
        }
        var seconds: TimeInterval {
            switch self {
            case .fiveMin: return 300
            case .hour: return 3_600
            case .day: return 86_400
            case .week: return 86_400 * 7
            case .month: return 86_400 * 30
            }
        }
        var days: Int {
            switch self {
            case .fiveMin, .hour, .day: return 1
            case .week: return 7
            case .month: return 30
            }
        }
    }

    @State private var activeTab: Tab = .recent
    /// Currently-expanded event row. Click toggles expansion.
    @State private var expandedID: UUID? = nil

    /// v0.14 — daemon-backed calendar feed. Lazily fetched when the
    /// user picks the All-activity tab for the first time, then refreshed
    /// when they hit the Reload button.
    @State private var daemonEntries: [DomeRpcClient.CalendarEntry] = []
    @State private var allActivityRange: AllActivityRange = .week
    @State private var daemonLoading: Bool = false

    /// v0.20 — audit log lifted from Knowledge → System.
    @State private var auditRows: [DomeRpcClient.AuditRow] = []
    @State private var auditFilter: String = ""
    @State private var expandedAuditRow: String? = nil

    /// v0.20 — retrieval log envelope reused for the Activity KPI tile
    /// "retrieval (30-day window)".
    @State private var retrievalLog: DomeRpcClient.RetrievalLogEnvelope?

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
    /// actually toggle.
    private var availableKindPrefixes: [String] {
        EventLedger.kindPrefixes(in: Array(eventBus.recent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // PageHeader (existing surfaceHeader chrome)
            surfaceHeader(
                title: "Activity",
                subtitle: headerSubtitle,
                isLoading: daemonLoading
            ) {
                Task { await reloadAll() }
            }

            // KPI strip — always visible.
            KpiStrip(kpiTiles)
                .padding(.horizontal, DK.pageGutter)
                .padding(.top, 16)
                .padding(.bottom, 18)
                .background(Palette.bgPage)

            // Tabs.
            TabsStrip(tabs: tabsItems, selection: $activeTab)

            // Filter bar — kind + since chips. Hidden on Audit tab
            // (which has its own action-prefix filter inline).
            if activeTab != .audit {
                filterBar
            }

            // Main + right rail.
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch activeTab {
                        case .recent:      recentTab
                        case .month:       monthTab
                        case .allActivity: allActivityTab
                        case .audit:       auditTab
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                RightRail(groups: railGroups)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.bgPage)
        .task(id: domeScope.id) { await reloadAll() }
    }

    private var headerSubtitle: String {
        "live event ledger + daemon timeline"
    }

    // MARK: - KPI strip

    /// Five tiles, in scan order:
    ///   1. events today (lead, accent value)
    ///   2. last 7 days
    ///   3. avg / hour
    ///   4. retrieval (30-day window)
    ///   5. awaiting (eternal plans needing attention)
    private var kpiTiles: [KpiTile] {
        [
            KpiTile(
                label: "events today",
                value: "\(eventsToday)",
                sub: lastEventSub,
                lead: true,
                accent: true
            ),
            KpiTile(
                label: "last 7 days",
                value: "\(eventsLast7Days)",
                sub: domeScope.label
            ),
            KpiTile(
                label: "avg / hour",
                value: avgPerHourLabel,
                sub: "rolling 24h"
            ),
            KpiTile(
                label: "retrieval",
                value: retrievalLog.map { "\($0.n)" } ?? "—",
                sub: "30-day window"
            ),
            KpiTile(
                label: "awaiting",
                value: "\(awaitingAttention)",
                sub: awaitingAttention > 0 ? "needs attention" : "clear"
            ),
        ]
    }

    private var eventsToday: Int {
        let cal = Calendar.current
        return eventBus.recent.filter { cal.isDateInToday($0.ts) }.count
    }
    private var lastEventSub: String {
        guard let last = eventBus.recent.max(by: { $0.ts < $1.ts }) else { return "no events yet" }
        return "last at \(Self.timeFmt.string(from: last.ts))"
    }
    private var eventsLast7Days: Int {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        return eventBus.recent.filter { $0.ts >= cutoff }.count
    }
    private var avgPerHourLabel: String {
        let cutoff = Date().addingTimeInterval(-86_400)
        let count = eventBus.recent.filter { $0.ts >= cutoff }.count
        let avg = Double(count) / 24.0
        return String(format: "%.1f", avg)
    }
    private var awaitingAttention: Int {
        eventBus.recent.filter { $0.type.contains("awaitingReview") || $0.severity == .warning || $0.severity == .error }.count
    }

    // MARK: - Tabs

    private var tabsItems: [TabsStrip<Tab>.Tab] {
        [
            TabsStrip<Tab>.Tab(id: .recent, label: "Recent", count: "\(visibleEventCount)"),
            TabsStrip<Tab>.Tab(id: .month, label: "Month", count: "\(eventBus.recent.count)"),
            TabsStrip<Tab>.Tab(id: .allActivity, label: "All activity", count: daemonEntries.isEmpty ? nil : "\(daemonEntries.count)"),
            TabsStrip<Tab>.Tab(id: .audit, label: "Audit", count: auditRows.isEmpty ? nil : "\(auditRows.count)"),
        ]
    }

    private var visibleEventCount: Int {
        groups.reduce(0) { $0 + $1.events.count }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        FilterBar(
            groups: filterBarGroups,
            trailing: {
                Text(visibleCountLabel)
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
            }
        )
    }

    private var filterBarGroups: [FilterBar<Text>.Group] {
        var kindChips = [FilterBar<Text>.Chip(
            label: "All",
            active: domeState.globalFilters.kinds.isEmpty,
            action: { domeState.globalFilters.kinds.removeAll() }
        )]
        for prefix in availableKindPrefixes {
            kindChips.append(FilterBar<Text>.Chip(
                label: prefix,
                active: domeState.globalFilters.kinds.contains(prefix),
                action: { toggleKind(prefix) }
            ))
        }
        var sinceChips = [FilterBar<Text>.Chip(
            label: "All time",
            active: domeState.globalFilters.since == nil,
            action: { domeState.globalFilters.since = nil }
        )]
        for window in EventLedger.SinceWindow.allCases {
            sinceChips.append(FilterBar<Text>.Chip(
                label: window.label,
                active: window.matches(domeState.globalFilters.since),
                action: { domeState.globalFilters.since = window.cutoff() }
            ))
        }
        return [
            FilterBar<Text>.Group(label: "kind", chips: kindChips),
            FilterBar<Text>.Group(label: "since", chips: sinceChips),
        ]
    }

    private func toggleKind(_ prefix: String) {
        var kinds = domeState.globalFilters.kinds
        if kinds.contains(prefix) {
            kinds.remove(prefix)
        } else {
            kinds.insert(prefix)
        }
        domeState.globalFilters.kinds = kinds
    }

    /// Tab-aware "X items" string.
    private var visibleCountLabel: String {
        switch activeTab {
        case .recent: return "\(visibleEventCount) events"
        case .month:  return "month of " + Self.monthFmt.string(from: Date())
        case .allActivity: return "\(daemonEntries.count) entries"
        case .audit:  return "\(auditRows.count) rows"
        }
    }

    // MARK: - Right rail

    private var railGroups: [RailGroup] {
        switch activeTab {
        case .recent:
            return [
                RailGroup("view", actions: [
                    RailAction("Pause stream", icon: "pause.circle", isDisabled: true, action: { /* future */ }),
                    RailAction("Tail in Terminal", icon: "terminal", action: tailInTerminal),
                    RailAction("Export NDJSON", icon: "square.and.arrow.up", action: openEventsLog),
                ]),
                RailGroup("filters", actions: [
                    RailAction("Only attention", icon: "exclamationmark.circle", isDisabled: true, action: { /* future */ }),
                    RailAction("Hide idle", icon: "moon.zzz", isDisabled: true, action: { /* future */ }),
                ]),
            ]
        case .month:
            return [
                RailGroup("navigate", actions: [
                    RailAction("◀ Previous month", icon: nil, isDisabled: true, action: { /* future */ }),
                    RailAction("Today", icon: "circle.dashed", variant: .primary, action: { /* future */ }),
                    RailAction("Next month ▶", icon: nil, isDisabled: true, action: { /* future */ }),
                ]),
                RailGroup("export", actions: [
                    RailAction("Export CSV", icon: "tablecells", isDisabled: true, action: { /* future */ }),
                ]),
            ]
        case .allActivity:
            return [
                RailGroup("window", actions: AllActivityRange.allCases.map { range in
                    RailAction(
                        range.label,
                        icon: "clock",
                        variant: range == allActivityRange ? .primary : .standard,
                        action: { allActivityRange = range; Task { await reloadDaemon() } }
                    )
                }),
                RailGroup("analyze", actions: [
                    RailAction("Run eval", icon: "play.fill", variant: .primary, kbd: "⌘R", isDisabled: true, action: { /* future */ }),
                    RailAction("Open in Agent System", icon: "arrow.up.right.square", isDisabled: true, action: { /* future */ }),
                ]),
            ]
        case .audit:
            return [
                RailGroup("filter", actions: [
                    RailAction("Clear filter", icon: "xmark.circle", action: { auditFilter = "" }),
                ]),
                RailGroup("export", actions: [
                    RailAction("Export NDJSON", icon: "square.and.arrow.up", action: openEventsLog),
                    RailAction("Open log file", icon: "doc.text.magnifyingglass", action: openEventsLog),
                ]),
            ]
        }
    }

    private func tailInTerminal() {
        let path = StorePaths.eventsCurrent.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("tail -f \"\(path)\"", forType: .string)
    }

    private func openEventsLog() {
        let dir = StorePaths.eventsCurrent.deletingLastPathComponent().path
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    // MARK: - Recent tab

    @ViewBuilder
    private var recentTab: some View {
        if eventBus.recent.isEmpty {
            recentEmpty
        } else if groups.isEmpty {
            recentNoMatch
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.day) { group in
                    dayGroup(group)
                }
            }
            .padding(.horizontal, DK.pageGutter)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    private var recentEmpty: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.ink4)
                Text("No events yet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text("Terminal and automation events appear here by day.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var recentNoMatch: some View {
        Text("No events match the current filters.")
            .font(Font.system(size: 12, weight: .regular))
            .foregroundStyle(Palette.ink3)
            .padding(.horizontal, DK.pageGutter)
            .padding(.vertical, 24)
    }

    private func dayGroup(_ group: EventLedger.DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OverlineLabel(dayLabel(group.day))
                Spacer()
                Text("\(group.events.count) event\(group.events.count == 1 ? "" : "s")")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
            }
            .padding(.top, 16)
            .padding(.bottom, 10)
            ForEach(group.events) { event in
                eventRow(event)
                Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
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
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(event.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text(Self.timeFmt.string(from: event.ts))
                                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(Palette.ink4)
                                .frame(alignment: .trailing)
                        }
                        if !event.body.isEmpty && !isExpanded {
                            Text(event.body)
                                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Palette.ink3)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        HStack(spacing: 6) {
                            Text(event.type)
                                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(Palette.ink4)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.ink4)
                        }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(eventRowAccessibilityLabel(event))
            .accessibilityValue(Self.timeFmt.string(from: event.ts))
            .accessibilityHint(isExpanded ? "Collapses details." : "Expands details.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !event.body.isEmpty {
                        Text(event.body)
                            .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
                    metadataRow("Type", event.type)
                    metadataRow("Severity", event.severity.rawValue)
                    if let link = deepLink {
                        metadataRow("Jump target", link)
                    }
                }
                .padding(.vertical, 12)
                .padding(.leading, 22)
                .padding(.trailing, 0)
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Palette.ink4)
            Text(value)
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink2)
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
        case .info: return Palette.ink3
        case .success: return Palette.green
        case .warning: return Palette.warning
        case .error: return Palette.danger
        }
    }

    // MARK: - Month tab

    private var monthTab: some View {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let monthStart = cal.date(from: comps) ?? now
        let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<2
        let countByDay: [Date: Int] = Dictionary(uniqueKeysWithValues: groups.map { ($0.day, $0.events.count) })
        let maxCount = countByDay.values.max() ?? 1
        // Compute leading weekday offset so day 1 sits in the right column.
        let firstWeekday = cal.component(.weekday, from: monthStart) - 1 // 0 = Sun
        let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)
        return VStack(alignment: .leading, spacing: 12) {
            // Weekday header row
            HStack(spacing: 1) {
                ForEach(["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"], id: \.self) { d in
                    Text(d)
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.bgElev)
                }
            }

            LazyVGrid(columns: columns, spacing: 1) {
                // Leading blanks
                ForEach(0..<firstWeekday, id: \.self) { _ in
                    Rectangle().fill(Palette.bgPage).frame(height: 96)
                }
                ForEach(range, id: \.self) { day in
                    let date = cal.date(byAdding: .day, value: day - 1, to: monthStart) ?? monthStart
                    let count = countByDay[cal.startOfDay(for: date)] ?? 0
                    monthCell(day: day, count: count, isToday: cal.isDateInToday(date), maxCount: maxCount)
                }
            }
            .background(Palette.rule)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))

            // Density legend
            HStack(spacing: 6) {
                OverlineLabel("Density", tint: Palette.ink4)
                ForEach([0.15, 0.35, 0.55, 0.8, 1.0], id: \.self) { intensity in
                    RoundedRectangle(cornerRadius: DK.radius)
                        .fill(Palette.accent.opacity(intensity))
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: DK.radius)
                                .stroke(Palette.rule, lineWidth: 0.5)
                        )
                }
                Text("low → high · today highlighted")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    private func monthCell(day: Int, count: Int, isToday: Bool, maxCount: Int) -> some View {
        let intensity = maxCount > 0 ? Double(count) / Double(maxCount) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(day)")
                    .font(Font.system(size: 12, weight: isToday ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(isToday ? Palette.accent : (count > 0 ? Palette.ink : Palette.ink3))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(Font.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isToday ? Palette.accent : Palette.ink2)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            if count > 0 {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.bgRow).frame(height: 3)
                    Capsule()
                        .fill(isToday ? Palette.accent : Palette.ink3)
                        .opacity(0.3 + intensity * 0.7)
                        .frame(width: max(2, CGFloat(intensity) * 100), height: 3)
                }
            }
        }
        .padding(10)
        .frame(height: 96, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(Palette.bgPage)
        .overlay(
            isToday
            ? Rectangle().stroke(Palette.accentSoft, lineWidth: 1.4)
            : Rectangle().stroke(Color.clear, lineWidth: 0)
        )
    }

    // MARK: - All activity tab

    private var allActivityTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Range pill bar — drives the data window. Mirrors the
            // right-rail "window" group; either can change the range.
            HStack(spacing: 10) {
                OverlineLabel("Range", tint: Palette.ink4)
                ForEach(AllActivityRange.allCases) { range in
                    OutlineButton(
                        range.label,
                        size: .small,
                        variant: range == allActivityRange ? .accent : .standard,
                        action: { allActivityRange = range; Task { await reloadDaemon() } }
                    )
                }
                Spacer()
                Text("\(daemonEntries.count) entries · automations + agent runs + ratings + evaluations")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Activity by window — bucket card matrix. Helps the
            // operator see the *shape* of activity across grain.
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    eyebrow: "retrieval logs",
                    title: "Activity by window",
                    sub: "zoom across time grains"
                )
                activityByWindowCard
            }

            // Hour-of-day heatmap — the "per minute, hour, day, week,
            // month" zoom the user asked for.
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(
                    eyebrow: "hourly",
                    title: "Hour-of-day heatmap",
                    sub: "last 7 days · darker = denser activity"
                )
                Heatmap24x7(
                    cells: heatmapCells,
                    todayWeekday: currentWeekdayMonStart,
                    currentHour: Calendar.current.component(.hour, from: Date())
                )
                .padding(16)
                .background(Palette.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            }

            // Daemon-entries ledger — fold the existing daemon mode
            // back in so the tab still shows individual rows.
            if !daemonEntries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(
                        eyebrow: "ledger",
                        title: "Daemon entries",
                        count: "\(daemonEntries.count) entries"
                    )
                    daemonEntriesList
                }
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .task(id: domeScope.id) { await reloadDaemon() }
    }

    private var activityByWindowCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AllActivityRange.allCases) { range in
                let count = bucketCount(for: range)
                let avgMs = bucketAvgLatency(for: range)
                HStack(spacing: 0) {
                    Text(range.label.lowercased())
                        .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink2)
                        .frame(width: 140, alignment: .leading)
                    Text("\(count)")
                        .font(Font.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .frame(width: 80, alignment: .leading)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.bgRow).frame(height: 4)
                        Capsule()
                            .fill(Palette.accent)
                            .frame(width: bucketBarWidth(count: count), height: 4)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    Text(avgMs)
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                        .frame(width: 100, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                if range != .month {
                    Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                }
            }
        }
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func bucketCount(for range: AllActivityRange) -> Int {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return eventBus.recent.filter { $0.ts >= cutoff }.count
    }

    private func bucketAvgLatency(for range: AllActivityRange) -> String {
        // The retrieval log is a pre-aggregated window — for now
        // surface its meanLatencyMs only on the 30-day bucket and
        // leave others as a daemon-entry density caption.
        if range == .month, let log = retrievalLog, log.n > 0 {
            return "avg \(Int(log.meanLatencyMs)) ms"
        }
        let count = bucketCount(for: range)
        return count > 0 ? "in-app events" : "—"
    }

    private func bucketBarWidth(count: Int) -> CGFloat {
        let max = bucketCount(for: .month)
        guard max > 0 else { return 2 }
        let frac = min(1.0, Double(count) / Double(max))
        // The capsule lives inside a flexible-width container; we
        // size it as a fraction of the container's full width by
        // returning a CGFloat the caller multiplies into. Here we
        // cap at 200pt so it stays inside reasonable bounds.
        return max == 0 ? 2 : CGFloat(frac) * 240
    }

    /// Cells for `Heatmap24x7`. Aggregates `eventBus.recent` over the
    /// last 7 days into 168 buckets. Intensity normalised by the
    /// densest bucket.
    private var heatmapCells: [Heatmap24x7.Cell] {
        let cal = Calendar.current
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var counts: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for event in eventBus.recent where event.ts >= cutoff {
            let weekday = cal.component(.weekday, from: event.ts) // 1=Sun…7=Sat
            let hour = cal.component(.hour, from: event.ts)
            // Re-map to MON=0…SUN=6 to match the design.
            let mapped = (weekday + 5) % 7
            counts[mapped][hour] += 1
        }
        // Add daemon entries (use plannedAt or startedAt).
        for entry in daemonEntries {
            guard let iso = entry.startedAt ?? entry.plannedAt,
                  let date = ISO8601DateFormatter().date(from: iso),
                  date >= cutoff else { continue }
            let weekday = cal.component(.weekday, from: date)
            let hour = cal.component(.hour, from: date)
            let mapped = (weekday + 5) % 7
            counts[mapped][hour] += 1
        }
        let maxCount = counts.flatMap { $0 }.max() ?? 1
        var cells: [Heatmap24x7.Cell] = []
        for w in 0..<7 {
            for h in 0..<24 {
                let intensity = maxCount > 0 ? Double(counts[w][h]) / Double(maxCount) : 0
                if intensity > 0 {
                    cells.append(.init(weekday: w, hour: h, intensity: intensity))
                }
            }
        }
        return cells
    }

    /// Today's index in the heatmap (MON=0…SUN=6).
    private var currentWeekdayMonStart: Int {
        let weekday = Calendar.current.component(.weekday, from: Date())
        return (weekday + 5) % 7
    }

    private var daemonEntriesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(daemonEntries) { entry in
                daemonRow(entry)
                Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
            }
        }
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func daemonRow(_ entry: DomeRpcClient.CalendarEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: iconForKind(entry.kind))
                    .foregroundStyle(colorForStatus(entry.displayStatus))
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
                StatusPill(entry.displayStatus, variant: pillVariantForStatus(entry.displayStatus))
                if let badge = entry.qualityBadge, !badge.isEmpty, badge != entry.displayStatus {
                    StatusPill(badge, variant: pillVariantForBadge(badge))
                }
            }
            HStack(spacing: 8) {
                Text(entry.entryType.replacingOccurrences(of: "_", with: " "))
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                if let agent = entry.agent, !agent.isEmpty {
                    Text("· \(agent)")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                }
                if let n = entry.interventionCount, n > 0 {
                    Text("· \(n) intervention\(n == 1 ? "" : "s")")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.warning)
                }
                Spacer()
                if let ts = entry.startedAt ?? entry.plannedAt {
                    Text(ts.prefix(19).replacingOccurrences(of: "T", with: " "))
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
            }
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(Font.system(size: 11, weight: .regular))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pillVariantForStatus(_ status: String) -> StatusPill.Variant {
        switch status {
        case "succeeded", "done", "ok":               return .running
        case "failed", "canceled", "cancelled",
             "aborted", "heartbeat_missed", "error":  return .danger
        case "running", "leased", "active":           return .planning
        case "ready", "scheduled", "queued",
             "retry_ready":                            return .review
        default:                                       return .neutral
        }
    }

    private func pillVariantForBadge(_ badge: String) -> StatusPill.Variant {
        switch badge {
        case "excellent", "good":          return .running
        case "needs_review":               return .review
        case "failed", "heartbeat_missed": return .danger
        case "active", "running":          return .planning
        default:                            return .draft
        }
    }

    private func iconForKind(_ kind: DomeRpcClient.CalendarEntry.Kind) -> String {
        switch kind {
        case .automation: return "clock.arrow.circlepath"
        case .agentRun: return "play.rectangle"
        case .unknown: return "circle"
        }
    }

    private func colorForStatus(_ status: String) -> Color {
        switch status {
        case "succeeded", "done", "ok": return Palette.green
        case "failed", "canceled", "cancelled", "aborted", "heartbeat_missed", "error":
            return Palette.danger
        case "running", "leased", "active": return Palette.accent
        case "ready", "scheduled", "queued", "retry_ready": return Palette.warning
        default: return Palette.ink3
        }
    }

    // MARK: - Audit tab

    @ViewBuilder
    private var auditTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                eyebrow: "log",
                title: "Audit log",
                count: auditRows.isEmpty ? nil : "\(filteredAudit.count) of \(auditRows.count)",
                sub: "every mutator call against the daemon, latest first"
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.ink4)
                        .font(.system(size: 11))
                    TextField("filter by action prefix…", text: $auditFilter)
                        .textFieldStyle(.plain)
                        .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 220)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Palette.bgPage)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            }
            if filteredAudit.isEmpty {
                Text(auditRows.isEmpty
                     ? "Audit log empty (or daemon hasn't loaded yet). Refresh to populate."
                     : "No rows match the current filter.")
                    .font(Font.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.ink3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: DK.radius)
                            .stroke(Palette.rule, lineWidth: DK.ruleW)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredAudit) { row in
                        auditRow(row)
                        Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                    }
                }
                .background(Palette.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    private var filteredAudit: [DomeRpcClient.AuditRow] {
        let prefix = auditFilter.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return auditRows }
        return auditRows.filter { $0.action.lowercased().hasPrefix(prefix) }
    }

    private func auditRow(_ row: DomeRpcClient.AuditRow) -> some View {
        let isExpanded = expandedAuditRow == row.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    expandedAuditRow = isExpanded ? nil : row.id
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(row.result == "ok" ? Palette.green : Palette.danger)
                        .frame(width: 6, height: 6)
                    Text(row.action)
                        .font(Font.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    StatusPill(
                        row.result,
                        variant: row.result == "ok" ? .running : .danger
                    )
                    Text("\(row.actorType):\(row.actorId)")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                    Spacer()
                    Text(row.ts.prefix(19).replacingOccurrences(of: "T", with: " "))
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.ink4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded, !row.detailsJSON.isEmpty, row.detailsJSON != "{}" {
                Text(row.detailsJSON)
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Reload

    private func reloadAll() async {
        async let recent = reloadRetrievalLog()
        async let audit = reloadAudit()
        async let daemon = reloadDaemon()
        _ = await (recent, audit, daemon)
    }

    private func reloadRetrievalLog() async {
        let scope = domeScope
        let log = await Task.detached {
            DomeRpcClient.retrievalLogRecent(
                limit: 50,
                projectID: scope.projectIDString,
                tool: nil
            )
        }.value
        retrievalLog = log
    }

    private func reloadAudit() async {
        auditRows = await Task.detached {
            DomeRpcClient.auditTail(since: nil, limit: 200)
        }.value
    }

    private func reloadDaemon() async {
        daemonLoading = true
        defer { daemonLoading = false }
        let now = Date()
        let from = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(allActivityRange.days * 86_400)))
        let to = ISO8601DateFormatter().string(from: now)
        let result = await Task.detached {
            DomeRpcClient.calendarRange(from: from, to: to, timezone: TimeZone.current.identifier)
        }.value
        daemonEntries = result?.entries ?? []
    }

    // MARK: - Formatters

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
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f
    }()
}
