import SwiftUI
import SwiftData
import AppKit

/// Unified view over every `EternalRun` + `DispatchRun` the app knows
/// about. See `CrossRunBrowserExtension` for the contract.
///
/// SwiftData `@Query` gives us live-updating arrays — adding a run in
/// the project detail surface flips the row in here without any
/// explicit refresh.
///
/// v0.18 — Mail.app-style list+detail layout. Two-line rows in a
/// fixed-width left list, rich detail pane on the right. Top filter
/// strip replaces the underused sidebar. Project grouping reduces the
/// repetitive per-row Project column. Replaces the v0.17 five-column
/// hand-rolled table that broke at narrow widths (every variable text
/// in the row now has `.lineLimit(1)` + `.fixedSize` + `layoutPriority`
/// so SwiftUI's compression order is deterministic and character-wrap
/// is structurally impossible).
struct CrossRunBrowserView: View {
    @Query(sort: \EternalRun.createdAt, order: .reverse) private var eternalRuns: [EternalRun]
    @Query(sort: \DispatchRun.createdAt, order: .reverse) private var dispatchRuns: [DispatchRun]

    @State private var scope: Scope = .all
    @State private var activeOnly: Bool = false
    @State private var query: String = ""
    @State private var selectedRowID: UUID?
    @State private var collapsedGroups: Set<String> = []

    @AppStorage("crossRunBrowser.listWidth") private var listWidth: Double = 340

    enum Scope: String, CaseIterable, Identifiable, Hashable {
        case all = "All"
        case eternal = "Eternal"
        case dispatch = "Dispatch"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            surfaceHeader(
                title: "Cross-Run Browser",
                subtitle: headerSubtitle,
                isLoading: false,
                refresh: {}
            )
            filterStrip
            HStack(spacing: 0) {
                listPane
                    .frame(width: max(280, min(460, CGFloat(listWidth))))
                Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Palette.bgPage)
        .navigationTitle("Cross-Run Browser")
        .onChange(of: filtered.map(\.id)) { _, ids in
            // Clear selection if the selected row is no longer visible.
            if let sid = selectedRowID, !ids.contains(sid) {
                selectedRowID = nil
            }
        }
    }

    // MARK: - Header subtitle

    private var headerSubtitle: String {
        let total = filtered.count
        let active = filtered.filter(\.isActive).count
        let projectCount = Set(filtered.compactMap(\.projectName)).count
        if total == 0 {
            return "No runs match the current filter"
        }
        let projectsCopy = projectCount == 1 ? "1 project" : "\(projectCount) projects"
        return "\(total) run\(total == 1 ? "" : "s") · \(active) active · across \(projectsCopy)"
    }

    // MARK: - Filter strip (replaces sidebar)

    private var filterStrip: some View {
        HStack(spacing: 16) {
            TabsStrip(
                tabs: [
                    .init(id: Scope.all,      label: "All",      count: "\(eternalRuns.count + dispatchRuns.count)"),
                    .init(id: Scope.eternal,  label: "Eternal",  count: "\(eternalRuns.count)"),
                    .init(id: Scope.dispatch, label: "Dispatch", count: "\(dispatchRuns.count)")
                ],
                selection: $scope
            )
            .fixedSize()

            Spacer(minLength: 12)

            Toggle(isOn: $activeOnly) {
                Text("Active only")
                    .font(Typography.labelSm)
                    .foregroundStyle(Palette.ink2)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()

            Rectangle().fill(Palette.rule).frame(width: DK.ruleW, height: 16)

            searchField
                .frame(width: 240)
        }
        .padding(.horizontal, DK.pageGutter)
        .frame(height: DK.tabsH)
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink4)
            TextField("Search label or project", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.ink)
            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    // MARK: - List pane

    private var listPane: some View {
        Group {
            if filtered.isEmpty {
                emptyListState
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                groupedList
            } else {
                flatList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bgPage)
    }

    private var emptyListState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Palette.ink4)
                Text("No runs match")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            Text("Adjust the filter or unselect \"Active only\" to widen the result set.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var flatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { row in
                    rowButton(row)
                    Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                }
            }
        }
    }

    private var groupedList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(groupedRows, id: \.0) { (key, rows) in
                    let displayName = key.isEmpty ? "No project" : key
                    let isCollapsed = collapsedGroups.contains(key)
                    ProjectGroupHeader(
                        name: displayName,
                        runCount: rows.count,
                        activeCount: rows.filter(\.isActive).count,
                        isCollapsed: isCollapsed,
                        onToggle: {
                            if isCollapsed { collapsedGroups.remove(key) }
                            else           { collapsedGroups.insert(key) }
                        }
                    )
                    if !isCollapsed {
                        ForEach(rows) { row in
                            rowButton(row)
                            Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                        }
                    }
                }
            }
        }
    }

    private func rowButton(_ row: BrowserRow) -> some View {
        Button(action: { selectedRowID = row.id }) {
            RunListRow(row: row, isSelected: row.id == selectedRowID)
        }
        .buttonStyle(.plain)
    }

    /// Group filtered rows by project name, then sort groups by run
    /// count desc (most active project first). Within each group rows
    /// stay in createdAt-desc order (the input is already sorted).
    private var groupedRows: [(String, [BrowserRow])] {
        let groups = Dictionary(grouping: filtered) { $0.projectName ?? "" }
        return groups
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count {
                    return lhs.value.count > rhs.value.count
                }
                return lhs.key < rhs.key
            }
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        Group {
            if let row = selectedRow {
                RunDetailPane(row: row, eternalState: eternalStateFor(row))
            } else {
                detailEmpty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bgPage)
    }

    private var detailEmpty: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "infinity.circle")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(Palette.ink4)
            Text("Pick a run on the left to inspect")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.ink2)
            Text("Status, project root, sprint counters, and reveal-in-Finder live here.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DK.pageGutter)
    }

    private var selectedRow: BrowserRow? {
        guard let sid = selectedRowID else { return nil }
        return filtered.first(where: { $0.id == sid })
    }

    /// Lazy state-load for the selected eternal row only. Avoids
    /// re-reading state.json for every visible row when we only need
    /// the rich detail for the one the user clicked.
    private func eternalStateFor(_ row: BrowserRow) -> EternalState? {
        guard row.kind == .eternal else { return nil }
        guard let run = eternalRuns.first(where: { $0.id == row.id }) else { return nil }
        return EternalService.readState(run)
    }

    // MARK: - Filtering / merging

    private var filtered: [BrowserRow] {
        var rows: [BrowserRow] = []
        if scope != .dispatch {
            rows.append(contentsOf: eternalRuns.map(BrowserRow.eternal))
        }
        if scope != .eternal {
            rows.append(contentsOf: dispatchRuns.map(BrowserRow.dispatch))
        }
        rows.sort { $0.createdAt > $1.createdAt }
        if activeOnly {
            rows = rows.filter(\.isActive)
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            rows = rows.filter {
                $0.label.lowercased().contains(q)
                    || ($0.projectName?.lowercased().contains(q) ?? false)
            }
        }
        return rows
    }
}

// MARK: - Row model

struct BrowserRow: Identifiable {
    enum Kind { case eternal, dispatch }

    let id: UUID
    let kind: Kind
    let label: String
    let state: String
    let projectName: String?
    let projectRoot: String?
    let createdAt: Date
    /// Sprint count for eternal runs (read lazily from state.json at
    /// row construction). `nil` means unavailable.
    let sprints: Int?
    /// Last metric display string for eternal runs.
    let lastMetric: String?
    /// Mode for eternal runs: "mega" or "sprint" — drives KindGlyph.
    let mode: String?
    /// Eternal Performance step state. `nil` for non-eternal runs and
    /// for eternal runs with `kind != "perf"`. Drives the inline
    /// "PERF" column + the regression triangle.
    let perfCycles: Int?
    let lastPerfScore: Double?
    let perfRegression: Bool
    /// Brief preview for dispatch runs (first ~280 chars).
    let brief: String?
    /// True when the run was proposed by a natural-language
    /// coordinator todo (the user typed `tado <brief>` on the
    /// general todo page). Drives the small "C" badge in the
    /// row so the user can tell which runs were spawned
    /// remotely vs. via the project UI.
    let coordinatorSpawned: Bool

    var isActive: Bool {
        state != "completed" && state != "stopped"
    }

    /// Display label that survives empty user-set labels. Untitled runs
    /// fall back to `Untitled <mode>` so the row never renders blank.
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .eternal:  return "Untitled \(mode ?? "run")"
        case .dispatch: return "Untitled dispatch"
        }
    }

    var glyphKind: KindGlyph.Kind {
        switch kind {
        case .eternal:  return mode == "sprint" ? .sprint : .mega
        case .dispatch: return .generic
        }
    }

    var modeBadge: String {
        switch kind {
        case .eternal:  return mode ?? "mega"
        case .dispatch: return "dispatch"
        }
    }

    static func eternal(_ run: EternalRun) -> BrowserRow {
        let state = EternalService.readState(run)
        let isPerf = run.kind == "perf"
        return BrowserRow(
            id: run.id,
            kind: .eternal,
            label: run.label,
            state: run.state,
            projectName: run.project?.name,
            projectRoot: run.project?.rootPath,
            createdAt: run.createdAt,
            sprints: state?.sprints,
            lastMetric: state?.lastMetric?.display,
            mode: run.mode,
            perfCycles: isPerf ? state?.perfCycles : nil,
            lastPerfScore: isPerf ? state?.lastPerfScore : nil,
            perfRegression: isPerf && (state?.perfRegressionDelta != nil),
            brief: nil,
            coordinatorSpawned: run.spawnedByCoordinatorTodoID != nil
        )
    }

    static func dispatch(_ run: DispatchRun) -> BrowserRow {
        BrowserRow(
            id: run.id,
            kind: .dispatch,
            label: run.label,
            state: run.state,
            projectName: run.project?.name,
            projectRoot: run.project?.rootPath,
            createdAt: run.createdAt,
            sprints: nil,
            lastMetric: nil,
            mode: nil,
            perfCycles: nil,
            lastPerfScore: nil,
            perfRegression: false,
            brief: run.brief,
            coordinatorSpawned: run.spawnedByCoordinatorTodoID != nil
        )
    }

    /// Resolves the on-disk run directory if it still exists.
    func runDirectoryURL() -> URL? {
        guard let projectRoot else { return nil }
        let subpath = kind == .eternal ? "eternal/runs" : "dispatch/runs"
        let url = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".tado")
            .appendingPathComponent(subpath)
            .appendingPathComponent(id.uuidString)
        return url
    }

    /// Falls back to `<root>/.tado/` when the per-run directory was
    /// pruned. Matches the behaviour of the v0.17 row's Reveal action.
    func revealableURL() -> URL? {
        guard let projectRoot else { return nil }
        if let url = runDirectoryURL(), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let tado = URL(fileURLWithPath: projectRoot).appendingPathComponent(".tado")
        return FileManager.default.fileExists(atPath: tado.path) ? tado : URL(fileURLWithPath: projectRoot)
    }
}

// MARK: - List row (two-line, Mail.app style)

private struct RunListRow: View {
    let row: BrowserRow
    let isSelected: Bool

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KindGlyph(kind: row.glyphKind)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                primaryLine
                secondaryLine
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.bgRowHi : Palette.bgElev)
        .overlay(alignment: .leading) {
            if row.isActive {
                Rectangle()
                    .fill(row.kind == .eternal ? Palette.accent : Palette.warning)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
    }

    private var primaryLine: some View {
        HStack(spacing: 8) {
            Text(row.displayLabel)
                .font(Typography.label)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            StatusPill.runState(row.state)
            Text(Self.relFormatter.localizedString(for: row.createdAt, relativeTo: Date()))
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.ink4)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var secondaryLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(Palette.ink4)
            Text(row.projectName ?? "—")
                .font(Typography.monoCallout)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let n = row.sprints, n > 0 {
                metaSeparator
                Text("\(n) sprint\(n == 1 ? "" : "s")")
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.ink4)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let metric = row.lastMetric, !metric.isEmpty, metric != "—" {
                metaSeparator
                Text(metric)
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.ink4)
                    .lineLimit(1)
                    .fixedSize()
            }
            // Perf step indicators — only on perf-mode eternal runs
            // (everything else has perfCycles=nil). Regression flips
            // the colour to .danger and shows a triangle.
            if let cycles = row.perfCycles {
                metaSeparator
                HStack(spacing: 3) {
                    if row.perfRegression {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Palette.danger)
                    }
                    Text("perf \(cycles)")
                        .font(Typography.monoMicro)
                        .foregroundStyle(row.perfRegression ? Palette.danger : Palette.ink4)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let composite = row.lastPerfScore {
                    Text(String(format: "%.2f", composite))
                        .font(Typography.monoMicro)
                        .foregroundStyle(row.perfRegression ? Palette.danger : Palette.ink4)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var metaSeparator: some View {
        Text("·")
            .font(Typography.monoMicro)
            .foregroundStyle(Palette.ink4)
            .fixedSize()
    }
}

// MARK: - Project group header

private struct ProjectGroupHeader: View {
    let name: String
    let runCount: Int
    let activeCount: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.ink4)
                    .frame(width: 12)
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.ink3)
                Text(name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                Text(meta)
                    .font(Typography.monoMicro)
                    .foregroundStyle(Palette.ink4)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgPage)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var meta: String {
        if activeCount == 0 {
            return "\(runCount)"
        }
        return "\(runCount) · \(activeCount) active"
    }
}

// MARK: - Detail pane

private struct RunDetailPane: View {
    let row: BrowserRow
    let eternalState: EternalState?

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                metaStrip
                if row.kind == .eternal {
                    eternalDetail
                } else {
                    dispatchDetail
                }
                actions
            }
            .padding(DK.pageGutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                KindGlyph(kind: row.glyphKind, size: 14)
                Text(row.modeBadge.uppercased())
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink4)
                StatusPill.runState(row.state)
                if row.coordinatorSpawned {
                    Text("COORDINATOR")
                        .font(Font.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Rectangle().stroke(Palette.accent, lineWidth: DK.ruleW))
                }
                Spacer(minLength: 0)
            }
            Text(row.displayLabel)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Meta strip

    private var metaStrip: some View {
        MetaStrip {
            MetaCell(key: "Project", value: row.projectName ?? "—")
            MetaCell(key: "Created", value: createdValue)
            MetaCell(key: "Mode", value: row.modeBadge)
            if let n = row.sprints {
                MetaCell(key: "Sprints", value: "\(n)")
            }
            MetaCell(key: "Run ID", value: shortID, trailingDivider: false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var createdValue: String {
        let abs = Self.absoluteFormatter.string(from: row.createdAt)
        let rel = Self.relFormatter.localizedString(for: row.createdAt, relativeTo: Date())
        return "\(abs) · \(rel)"
    }

    private var shortID: String {
        let s = row.id.uuidString
        return String(s.prefix(8))
    }

    // MARK: Eternal-specific block

    private var eternalDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverlineLabel("Eternal state")
            if let st = eternalState {
                eternalStatusGrid(st)
                if let note = st.lastProgressNote, !note.isEmpty {
                    progressNoteBlock(note)
                }
            } else {
                emptyDetailHint(
                    "No state.json on disk yet — the run hasn't started or has been archived."
                )
            }
        }
    }

    private func eternalStatusGrid(_ st: EternalState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow("Phase",        value: st.phase)
            statusRow("Iterations",   value: "\(st.iterations)")
            statusRow("Sprints",      value: "\(st.sprints)")
            statusRow("Compactions",  value: "\(st.compactions)")
            if let metric = st.lastMetric?.display, !metric.isEmpty, metric != "—" {
                statusRow("Last metric", value: metric)
            }
            if st.perfCycles > 0 {
                statusRow("Perf cycles", value: "\(st.perfCycles)")
            }
            if let composite = st.lastPerfScore {
                statusRow("Perf composite", value: String(format: "%.3f", composite))
            }
            if let delta = st.perfRegressionDelta {
                statusRow("Perf regression Δ", value: String(format: "%.3f", delta))
            }
            if let path = st.lastPerfReportPath, !path.isEmpty {
                statusRow("Perf report", value: path)
            }
            if st.startedAt > 0 {
                statusRow("Started",   value: Self.absoluteFormatter.string(from: Date(timeIntervalSince1970: st.startedAt)))
            }
            if st.lastActivityAt > 0 {
                statusRow("Last activity", value: Self.relFormatter.localizedString(for: Date(timeIntervalSince1970: st.lastActivityAt), relativeTo: Date()))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func statusRow(_ key: String, value: String) -> some View {
        HStack(spacing: 0) {
            Text(key.uppercased())
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Palette.ink4)
                .frame(width: 110, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
            Text(value)
                .font(Typography.monoCallout)
                .foregroundStyle(Palette.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private func progressNoteBlock(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OverlineLabel("Last progress note", tint: Palette.ink4)
            Text(note)
                .font(Typography.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    // MARK: Dispatch-specific block

    private var dispatchDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            OverlineLabel("Dispatch brief")
            if let brief = row.brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
                let preview = String(brief.prefix(280))
                let truncated = brief.count > 280
                VStack(alignment: .leading, spacing: 6) {
                    Text(preview + (truncated ? "…" : ""))
                        .font(Typography.body)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if truncated {
                        Text("Showing first 280 of \(brief.count) characters.")
                            .font(Typography.monoMicro)
                            .foregroundStyle(Palette.ink4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            } else {
                emptyDetailHint("No brief recorded for this dispatch run.")
            }
        }
    }

    private func emptyDetailHint(_ text: String) -> some View {
        Text(text)
            .font(Typography.captionItalic)
            .foregroundStyle(Palette.ink4)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverlineLabel("Actions")
            HStack(spacing: 8) {
                OutlineButton(
                    "Reveal in Finder",
                    icon: "folder.badge.gearshape",
                    size: .small,
                    variant: .standard,
                    action: revealRun
                )
                .help("Open the on-disk run directory in Finder")
                if row.projectRoot != nil {
                    OutlineButton(
                        "Project root",
                        icon: "folder",
                        size: .small,
                        variant: .ghost,
                        action: revealProjectRoot
                    )
                    .help("Open the project working directory in Finder")
                }
                OutlineButton(
                    "Copy ID",
                    icon: "doc.on.doc",
                    size: .small,
                    variant: .ghost,
                    action: copyRunID
                )
                .help("Copy the full run UUID to the clipboard")
                Spacer(minLength: 0)
            }
        }
    }

    private func revealRun() {
        guard let url = row.revealableURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func revealProjectRoot() {
        guard let root = row.projectRoot else { return }
        let url = URL(fileURLWithPath: root)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyRunID() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(row.id.uuidString, forType: .string)
    }
}
