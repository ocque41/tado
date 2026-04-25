import SwiftUI
import SwiftData
import AppKit

/// Unified view over every `EternalRun` + `DispatchRun` the app knows
/// about. See `CrossRunBrowserExtension` for the contract.
///
/// SwiftData `@Query` gives us live-updating arrays — adding a run in
/// the project detail surface flips the row in here without any
/// explicit refresh.
struct CrossRunBrowserView: View {
    @Query(sort: \EternalRun.createdAt, order: .reverse) private var eternalRuns: [EternalRun]
    @Query(sort: \DispatchRun.createdAt, order: .reverse) private var dispatchRuns: [DispatchRun]

    @State private var scope: Scope = .all
    @State private var activeOnly: Bool = false
    @State private var query: String = ""

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case eternal = "Eternal"
        case dispatch = "Dispatch"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            content
                .frame(minWidth: 520)
        }
        .background(Palette.canvas)
        .navigationTitle("Cross-Run Browser")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filters")
                .font(Typography.callout.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 16)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Scope.allCases) { s in
                    Button {
                        scope = s
                    } label: {
                        HStack {
                            Image(systemName: icon(for: s))
                                .frame(width: 18)
                            Text(s.rawValue)
                            Spacer()
                            Text("\(count(for: s))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 16)
                        .background(
                            s == scope
                                ? Palette.accent.opacity(0.18)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(s == scope ? Palette.accent : Palette.textPrimary)
                }
            }

            Toggle("Active only", isOn: $activeOnly)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Spacer()

            Text("\(filtered.count) run\(filtered.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .background(Palette.surfaceElevated)
    }

    private func icon(for scope: Scope) -> String {
        switch scope {
        case .all: return "tray.2"
        case .eternal: return "infinity"
        case .dispatch: return "rectangle.3.group"
        }
    }

    private func count(for scope: Scope) -> Int {
        switch scope {
        case .all: return eternalRuns.count + dispatchRuns.count
        case .eternal: return eternalRuns.count
        case .dispatch: return dispatchRuns.count
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().background(Palette.divider)
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { row in
                            RunRowView(row: row)
                            Divider().background(Palette.divider)
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textSecondary)
            TextField("Search label or project", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.body)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(Palette.textSecondary)
            Text("No runs match")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct BrowserRow: Identifiable {
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

    var isActive: Bool {
        state != "completed" && state != "stopped"
    }

    static func eternal(_ run: EternalRun) -> BrowserRow {
        let state = EternalService.readState(run)
        return BrowserRow(
            id: run.id,
            kind: .eternal,
            label: run.label,
            state: run.state,
            projectName: run.project?.name,
            projectRoot: run.project?.rootPath,
            createdAt: run.createdAt,
            sprints: state?.sprints,
            lastMetric: state?.lastMetric?.display
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
            lastMetric: nil
        )
    }
}

// MARK: - Row view

private struct RunRowView: View {
    let row: BrowserRow

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    stateChip
                    Spacer()
                    Text(Self.relFormatter.localizedString(for: row.createdAt, relativeTo: Date()))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                }
                HStack(spacing: 10) {
                    if let proj = row.projectName {
                        Label(proj, systemImage: "folder")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let sprints = row.sprints {
                        Label("\(sprints) sprint\(sprints == 1 ? "" : "s")", systemImage: "repeat")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let metric = row.lastMetric, !metric.isEmpty, metric != "—" {
                        Label(metric, systemImage: "chart.xyaxis.line")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            Button {
                revealInFinder()
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .help("Reveal run directory in Finder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var icon: some View {
        Image(systemName: row.kind == .eternal ? "infinity" : "rectangle.3.group")
            .font(.system(size: 20))
            .foregroundStyle(row.kind == .eternal ? Palette.accent : Palette.warning)
            .frame(width: 28, height: 28)
            .padding(.top, 2)
    }

    private var stateChip: some View {
        Text(row.state.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(chipColor.opacity(0.2))
            .foregroundStyle(chipColor)
            .clipShape(Capsule())
    }

    private var chipColor: Color {
        switch row.state {
        case "completed": return Palette.success
        case "stopped": return Palette.danger
        case "running", "ready": return Palette.accent
        case "planning", "drafted": return Palette.textSecondary
        default: return Palette.textSecondary
        }
    }

    /// Opens the on-disk run directory. Eternal runs live at
    /// `<project-root>/.tado/eternal/runs/<id>/`; dispatch at
    /// `<project-root>/.tado/dispatch/runs/<id>/`.
    private func revealInFinder() {
        guard let projectRoot = row.projectRoot else { return }
        let subpath = row.kind == .eternal ? "eternal/runs" : "dispatch/runs"
        let url = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".tado")
            .appendingPathComponent(subpath)
            .appendingPathComponent(row.id.uuidString)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Fall back to `.tado/` so the user at least sees the
            // parent if the per-run dir was pruned.
            let tado = URL(fileURLWithPath: projectRoot).appendingPathComponent(".tado")
            NSWorkspace.shared.activateFileViewerSelecting([tado])
        }
    }
}
