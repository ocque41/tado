import SwiftUI
import SwiftData

/// Dome extension window root. A sidebar picker chooses which of the
/// four surfaces is active (User Notes, Agent Notes, Calendar,
/// Knowledge); the selected surface fills the detail pane.
///
/// A small status bar pinned at the bottom of the sidebar shows
/// whether the daemon is online (by observing `EventBus.shared.recent`
/// for the most recent `dome.daemonStarted` / `.daemonFailed` event).
/// Offline state doesn't disable the tabs — each surface handles
/// nil-returning FFI calls gracefully and shows its own placeholder.
struct DomeRootView: View {
    @Query(sort: \Project.createdAt) private var projects: [Project]
    /// Cross-surface state lives on `DomeAppState`. Per-surface state
    /// (`activeKnowledgePage`, `knowledgeExpanded`) stays local — see the
    /// P0 contract in the Eternal brief at
    /// `.tado/eternal/runs/.../crafted.md`.
    @State private var domeState = DomeAppState()
    /// P3 — `.graph` is the default Knowledge page; the list/system
    /// pages remain reachable via the sidebar disclosure.
    @State private var activeKnowledgePage: DomeKnowledgePage = .graph
    @State private var knowledgeExpanded = false
    /// Live status of the Qwen3 embedding model. Polled by the
    /// onboarding overlay; we keep it here so the overlay can be
    /// dismissed in-place once `ready == true`.
    @State private var modelStatus: DomeRpcClient.ModelStatus?

    /// Direct singleton access matches the pattern already used by
    /// `NotificationsWindowView`. `@Observable` on EventBus means the
    /// view auto-tracks the `recent` ring without an explicit
    /// `@Environment` injection.
    private var eventBus: EventBus { EventBus.shared }

    var body: some View {
        GeometryReader { proxy in
            // `compact` collapses the sidebar to icon-only at narrow
            // widths so the detail pane keeps a usable share of the
            // window. 420pt is the threshold where a 220pt sidebar
            // starts crushing the content; below it we drop to a
            // 52pt icon strip.
            let compact = proxy.size.width < 420
            HStack(spacing: 0) {
                sidebar(compact: compact)
                    .frame(width: compact ? 52 : 220)
                Divider().overlay(Palette.divider)
                VStack(spacing: 0) {
                    domeNavbar(compact: compact)
                    Divider().overlay(Palette.divider)
                    surfaceContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .environment(domeState)
        .overlay(alignment: .topLeading) {
            DomeHotkeyRegistrar()
                .environment(domeState)
        }
        .overlay {
            if let modelStatus, !modelStatus.ready {
                DomeOnboardingView()
                    .transition(.opacity)
            }
        }
        .onAppear {
            syncIncludeGlobalData(for: domeState.activeScopeID)
            modelStatus = DomeRpcClient.modelStatus()
        }
        .task {
            // Re-poll every 2 seconds while the overlay is visible.
            // Once the runtime loads, `ready` flips and the overlay
            // disappears; the loop exits cleanly when the view does.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                modelStatus = DomeRpcClient.modelStatus()
                if modelStatus?.ready == true { break }
            }
        }
    }

    private var breadcrumbs: [DomeBreadcrumbs.Crumb] {
        DomeBreadcrumbs.trail(
            for: domeState.activeSurface,
            knowledgePage: domeState.activeSurface == .knowledge ? activeKnowledgePage : nil,
            scope: selectedScope
        )
    }

    private var selectedProject: Project? {
        guard domeState.activeScopeID != "global",
              let id = UUID(uuidString: domeState.activeScopeID) else {
            return nil
        }
        return projects.first(where: { $0.id == id })
    }

    private var selectedScope: DomeScopeSelection {
        guard let project = selectedProject else { return .global }
        return .project(
            id: project.id,
            name: project.name,
            rootPath: project.rootPath,
            includeGlobal: domeState.includeGlobalData
        )
    }

    private var scopePickerSelection: Binding<String> {
        Binding(
            get: {
                if domeState.activeScopeID == "global" { return "global" }
                guard let id = UUID(uuidString: domeState.activeScopeID),
                      projects.contains(where: { $0.id == id }) else {
                    return "global"
                }
                return domeState.activeScopeID
            },
            set: {
                domeState.activeScopeID = $0
                syncIncludeGlobalData(for: $0)
            }
        )
    }

    private var includeGlobalDataBinding: Binding<Bool> {
        Binding(
            get: { domeState.includeGlobalData },
            set: { domeState.includeGlobalData = $0 }
        )
    }

    private func domeNavbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 12) {
            Picker("Scope", selection: scopePickerSelection) {
                Text("Global").tag("global")
                ForEach(projects) { project in
                    Text(project.name).tag(project.id.uuidString)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 100, idealWidth: 220, maxWidth: 220, alignment: .leading)
            .layoutPriority(1)
            .help("Choose Global common knowledge or a project overlay.")

            if selectedProject != nil {
                Toggle(isOn: includeGlobalDataBinding) {
                    if compact {
                        Label("Global", systemImage: "globe")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .labelStyle(.iconOnly)
                    } else {
                        Label("Global", systemImage: "globe")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: domeState.includeGlobalData) { _, newValue in
                    persistIncludeGlobalData(newValue)
                }
                .help("Include inherited global knowledge in this project view.")

                if !compact {
                    Divider()
                        .frame(height: 18)
                        .overlay(Palette.divider)
                }
            }

            if !compact {
                Text(scopeSubtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
            }
            Spacer(minLength: 4)
            if !compact {
                DomeBreadcrumbsView(crumbs: breadcrumbs)
                    .lineLimit(1)
                    .layoutPriority(0)
            }
        }
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, 10)
        .background(Palette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dome navigation")
    }

    private var scopeSubtitle: String {
        switch selectedScope {
        case .global:
            return "Common knowledge and reusable workflows"
        case .project(_, let name, _, let includeGlobal):
            if includeGlobal {
                return "\(name): global knowledge plus project-specific workflows"
            }
            return "\(name): project-specific knowledge and workflows only"
        }
    }

    private func syncIncludeGlobalData(for scopeID: String) {
        guard let project = project(for: scopeID) else {
            domeState.includeGlobalData = ScopedConfig.shared.get().dome.includeGlobalInProject
            return
        }
        domeState.includeGlobalData = resolvedIncludeGlobal(for: project)
    }

    private func persistIncludeGlobalData(_ value: Bool) {
        guard let project = selectedProject else { return }
        let rootURL = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        // Skip the write when nothing would actually change. Two cases:
        //   1. local already has the same explicit value → exact match.
        //   2. local is nil AND resolution already returns `value`
        //      (i.e. shared/global default already says so) → writing
        //      would be a redundant promotion of "inherit" to "explicit".
        // This keeps the file-watcher quiet on every project-pick where
        // `syncIncludeGlobalData` round-trips through `.onChange`.
        let local = ScopedConfig.shared.getProjectLocal(at: rootURL)
        if local.dome.includeGlobal == value { return }
        if local.dome.includeGlobal == nil && value == resolvedIncludeGlobal(for: project) {
            return
        }
        ScopedConfig.shared.setProjectLocal(at: rootURL) {
            $0.dome.includeGlobal = value
        }
    }

    private func resolvedIncludeGlobal(for project: Project) -> Bool {
        let rootURL = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let globalDefault = ScopedConfig.shared.get().dome.includeGlobalInProject
        let shared = ScopedConfig.shared.getProjectShared(at: rootURL)
        let local = ScopedConfig.shared.getProjectLocal(at: rootURL)
        return local.dome.includeGlobal
            ?? shared.dome.includeGlobal
            ?? globalDefault
    }

    private func project(for scopeID: String) -> Project? {
        guard scopeID != "global", let id = UUID(uuidString: scopeID) else {
            return nil
        }
        return projects.first(where: { $0.id == id })
    }

    // MARK: - Sidebar

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(compact: compact)
            Divider().overlay(Palette.divider)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(DomeSurfaceTab.allCases) { tab in
                    if tab == .knowledge {
                        knowledgeButton(compact: compact)
                    } else {
                        tabButton(tab, compact: compact)
                    }
                }
            }
            .padding(.horizontal, compact ? 4 : 10)
            .padding(.top, 12)
            Spacer()
            statusFooter(compact: compact)
        }
        .background(Palette.surfaceElevated)
    }

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(compact ? "D" : "Dome")
                .font(Typography.displayXL)
                .foregroundStyle(Palette.textPrimary)
                .help("Dome — second brain")
            if !compact {
                Text("second brain")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
    }

    private func tabButton(_ tab: DomeSurfaceTab, compact: Bool) -> some View {
        let active = tab == domeState.activeSurface
        return Button(action: { domeState.activeSurface = tab }) { tabButtonLabel(tab, active: active, compact: compact) }
            .buttonStyle(.plain)
            .help(tab.label)
            .accessibilityLabel("\(tab.label) surface")
            .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
            .accessibilityHint("Switches the Dome window to the \(tab.label) surface.")
    }

    private func tabButtonLabel(_ tab: DomeSurfaceTab, active: Bool, compact: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tab.iconSystemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16)
            if !compact {
                Text(tab.label)
                    .font(Typography.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(active ? Palette.accent : Palette.textSecondary)
        .padding(.horizontal, compact ? 0 : 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? Palette.surfaceAccent : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func knowledgeButton(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                domeState.activeSurface = .knowledge
                knowledgeExpanded.toggle()
            }) {
                HStack(spacing: 10) {
                    Image(systemName: DomeSurfaceTab.knowledge.iconSystemName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16)
                    if !compact {
                        Text(DomeSurfaceTab.knowledge.label)
                            .font(Typography.label)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: knowledgeExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .foregroundStyle(domeState.activeSurface == .knowledge ? Palette.accent : Palette.textSecondary)
                .padding(.horizontal, compact ? 0 : 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(domeState.activeSurface == .knowledge ? Palette.surfaceAccent : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(DomeSurfaceTab.knowledge.label)

            if !compact, knowledgeExpanded || domeState.activeSurface == .knowledge {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(DomeKnowledgePage.allCases) { page in
                        knowledgePageButton(page)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    private func knowledgePageButton(_ page: DomeKnowledgePage) -> some View {
        let active = domeState.activeSurface == .knowledge && activeKnowledgePage == page
        return Button(action: {
            domeState.activeSurface = .knowledge
            activeKnowledgePage = page
            knowledgeExpanded = true
        }) {
            HStack(spacing: 8) {
                Image(systemName: page.iconSystemName)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14)
                Text(page.label)
                    .font(Typography.labelSm)
                Spacer()
            }
            .foregroundStyle(active ? Palette.accent : Palette.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Knowledge \(page.label) sub-page")
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Opens the Knowledge surface on the \(page.label) page.")
    }

    private func statusFooter(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
            if !compact {
                Text(statusLabel)
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .background(Palette.surface)
        .help(compact ? statusLabel : "")
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.divider)
                .frame(height: 1)
        }
    }

    private var latestDomeEvent: TadoEvent? {
        for e in eventBus.recent.reversed() {
            if e.type.hasPrefix("dome.") { return e }
        }
        return nil
    }

    private var statusTint: Color {
        switch latestDomeEvent?.type {
        case "dome.daemonStarted": return Palette.success
        case "dome.daemonFailed": return Palette.danger
        case "dome.modelDownloading": return Palette.warning
        default: return Palette.textTertiary
        }
    }

    private var statusLabel: String {
        switch latestDomeEvent?.type {
        case "dome.daemonStarted": return "Online"
        case "dome.daemonFailed": return "Offline"
        case "dome.modelDownloading": return "Downloading model"
        default: return "Starting…"
        }
    }

    // MARK: - Surface content

    @ViewBuilder
    private var surfaceContent: some View {
        switch domeState.activeSurface {
        case .search: SearchSurface(domeScope: selectedScope)
        case .userNotes: UserNotesSurface(domeScope: selectedScope)
        case .agentNotes: AgentNotesSurface(domeScope: selectedScope)
        case .calendar: CalendarSurface(domeScope: selectedScope)
        case .knowledge: KnowledgeSurface(page: activeKnowledgePage, domeScope: selectedScope)
        case .recipes: RecipesSurface(domeScope: selectedScope)
        case .automation: AutomationSurface(domeScope: selectedScope)
        }
    }
}
