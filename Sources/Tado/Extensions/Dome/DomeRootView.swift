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
    @State private var activeSurface: DomeSurfaceTab = .userNotes
    @State private var activeKnowledgePage: DomeKnowledgePage = .list
    @State private var knowledgeExpanded = false
    @State private var activeScopeID = "global"
    @State private var includeGlobalData = true

    /// Direct singleton access matches the pattern already used by
    /// `NotificationsWindowView`. `@Observable` on EventBus means the
    /// view auto-tracks the `recent` ring without an explicit
    /// `@Environment` injection.
    private var eventBus: EventBus { EventBus.shared }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider().overlay(Palette.divider)
            VStack(spacing: 0) {
                domeNavbar
                Divider().overlay(Palette.divider)
                surfaceContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .onAppear {
            syncIncludeGlobalData(for: activeScopeID)
        }
    }

    private var selectedProject: Project? {
        guard activeScopeID != "global",
              let id = UUID(uuidString: activeScopeID) else {
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
            includeGlobal: includeGlobalData
        )
    }

    private var scopePickerSelection: Binding<String> {
        Binding(
            get: {
                if activeScopeID == "global" { return "global" }
                guard let id = UUID(uuidString: activeScopeID),
                      projects.contains(where: { $0.id == id }) else {
                    return "global"
                }
                return activeScopeID
            },
            set: {
                activeScopeID = $0
                syncIncludeGlobalData(for: $0)
            }
        )
    }

    private var domeNavbar: some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: scopePickerSelection) {
                Text("Global").tag("global")
                ForEach(projects) { project in
                    Text(project.name).tag(project.id.uuidString)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220, alignment: .leading)
            .help("Choose Global common knowledge or a project overlay.")

            if selectedProject != nil {
                Toggle(isOn: $includeGlobalData) {
                    Label("Global", systemImage: "globe")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: includeGlobalData) { _, newValue in
                    persistIncludeGlobalData(newValue)
                }
                .help("Include inherited global knowledge in this project view.")

                Divider()
                    .frame(height: 18)
                    .overlay(Palette.divider)
            }

            Text(scopeSubtitle)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.surface)
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
            includeGlobalData = ScopedConfig.shared.get().dome.includeGlobalInProject
            return
        }
        includeGlobalData = resolvedIncludeGlobal(for: project)
    }

    private func persistIncludeGlobalData(_ value: Bool) {
        guard let project = selectedProject else { return }
        guard value != resolvedIncludeGlobal(for: project) else { return }
        let rootURL = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        ScopedConfig.shared.setProjectLocal(at: rootURL) {
            $0.dome.includeGlobal = value
        }
    }

    private func resolvedIncludeGlobal(for project: Project) -> Bool {
        let rootURL = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let globalDefault = ScopedConfig.shared.get().dome.includeGlobalInProject
        let projectDefaults = ProjectSettings()
        let shared = ScopedConfig.shared.getProjectShared(at: rootURL)
        let local = ScopedConfig.shared.getProjectLocal(at: rootURL)

        var includeGlobal = globalDefault
        if shared.dome.includeGlobal != projectDefaults.dome.includeGlobal {
            includeGlobal = shared.dome.includeGlobal
        }
        if local.dome.includeGlobal != projectDefaults.dome.includeGlobal {
            includeGlobal = local.dome.includeGlobal
        }
        return includeGlobal
    }

    private func project(for scopeID: String) -> Project? {
        guard scopeID != "global", let id = UUID(uuidString: scopeID) else {
            return nil
        }
        return projects.first(where: { $0.id == id })
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.divider)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(DomeSurfaceTab.allCases) { tab in
                    if tab == .knowledge {
                        knowledgeButton
                    } else {
                        tabButton(tab)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            Spacer()
            statusFooter
        }
        .background(Palette.surfaceElevated)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dome")
                .font(Typography.displayXL)
                .foregroundStyle(Palette.textPrimary)
            Text("second brain")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabButton(_ tab: DomeSurfaceTab) -> some View {
        let active = tab == activeSurface
        return Button(action: { activeSurface = tab }) {
            HStack(spacing: 10) {
                Image(systemName: tab.iconSystemName)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(tab.label)
                    .font(Typography.label)
                Spacer()
            }
            .foregroundStyle(active ? Palette.accent : Palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Palette.surfaceAccent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var knowledgeButton: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                activeSurface = .knowledge
                knowledgeExpanded.toggle()
            }) {
                HStack(spacing: 10) {
                    Image(systemName: DomeSurfaceTab.knowledge.iconSystemName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16)
                    Text(DomeSurfaceTab.knowledge.label)
                        .font(Typography.label)
                    Spacer()
                    Image(systemName: knowledgeExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
                .foregroundStyle(activeSurface == .knowledge ? Palette.accent : Palette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(activeSurface == .knowledge ? Palette.surfaceAccent : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if knowledgeExpanded || activeSurface == .knowledge {
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
        let active = activeSurface == .knowledge && activeKnowledgePage == page
        return Button(action: {
            activeSurface = .knowledge
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
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(Typography.micro)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.surface)
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
        switch activeSurface {
        case .userNotes: UserNotesSurface(domeScope: selectedScope)
        case .agentNotes: AgentNotesSurface(domeScope: selectedScope)
        case .calendar: CalendarSurface()
        case .knowledge: KnowledgeSurface(page: activeKnowledgePage, domeScope: selectedScope)
        }
    }
}
