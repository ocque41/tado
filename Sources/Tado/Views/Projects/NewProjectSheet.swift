import SwiftUI
import SwiftData

/// Sheet used to create a new project. Replaces the previous inline
/// "New Project" form that pushed the list down when expanded.
/// Matches the `DispatchFileModal` chrome convention: Cancel / title
/// / Create top bar, labeled fields below. Esc cancels; Return
/// creates when the form is valid.
struct NewProjectSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var appSettingsList: [AppSettings]

    @State private var name: String = ""
    @State private var path: String = ""
    @FocusState private var nameFocused: Bool

    private var appSettings: AppSettings? { appSettingsList.first }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !path.isEmpty
    }

    @Environment(\.relayTheme) private var relayTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Page-anatomy head: kicker + h1 + lead
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RelayKicker(text: "PROJECTS — NEW")
                    Spacer()
                    Button(action: { dismiss() }) {
                        Text("✕")
                            .font(Typography.sans(size: 14, weight: .regular))
                            .foregroundStyle(RelayPalette.foreground3(for: relayTheme))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel")
                }
                Text("Add a project.")
                    .font(RelayType.h2(size: 32))
                    .foregroundStyle(RelayPalette.foreground(for: relayTheme))
                Text("A project links a directory to Tado.")
                    .font(Typography.sans(size: 13, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground2(for: relayTheme))
                    .frame(maxWidth: 480, alignment: .leading)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)

            Rectangle()
                .fill(RelayPalette.hair(for: relayTheme))
                .frame(height: 1)

            // Body — name + location as Relay settings rows
            VStack(alignment: .leading, spacing: 0) {
                RelaySettingsRow(
                    label: "Name",
                    help: "How this project shows up in the sidebar and across tile metadata.",
                    control: {
                        TextField(
                            "",
                            text: $name,
                            prompt: Text("noblestack")
                                .foregroundStyle(RelayPalette.foreground3(for: relayTheme))
                        )
                        .textFieldStyle(.plain)
                        .font(Typography.sans(size: 13, weight: .regular))
                        .foregroundStyle(RelayPalette.foreground(for: relayTheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(width: 240)
                        .overlay(
                            RoundedRectangle(cornerRadius: RelayRadius.standard)
                                .stroke(RelayPalette.hair(for: relayTheme), lineWidth: 1)
                        )
                        .focused($nameFocused)
                    }
                )
                RelaySettingsRow(
                    label: "Location",
                    help: "Working directory the agents will run in. Click Browse to pick a folder.",
                    control: {
                        HStack(spacing: 8) {
                            Text(path.isEmpty ? "No folder selected" : path)
                                .font(Typography.sans(size: 11, weight: .regular))
                                .tracking(RelayTracking.meta(11))
                                .foregroundStyle(path.isEmpty
                                    ? RelayPalette.foreground3(for: relayTheme)
                                    : RelayPalette.foreground(for: relayTheme))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 220, alignment: .leading)
                            RelayButton(label: "Browse", variant: .standard, action: pickDirectory)
                        }
                    }
                )
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)

            // Footer actions
            Rectangle()
                .fill(RelayPalette.hair(for: relayTheme))
                .frame(height: 1)
            HStack {
                Spacer()
                RelayButton(label: "Cancel", variant: .ghost) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                RelayButton(label: "Create", variant: .primary) {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.4)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(RelayPalette.background(for: relayTheme))
        .onAppear { nameFocused = true }
    }

    // MARK: - Actions

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select project root directory"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = url.lastPathComponent
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !path.isEmpty else { return }
        let project = Project(name: trimmed, rootPath: path)
        modelContext.insert(project)
        try? modelContext.save()

        // C2: Seed the project's Dome topic with an overview note so
        // every agent spawned into the project wakes with at least
        // one discoverable fact about it. Best-effort — if Dome
        // isn't online yet (race between first-launch hook fan-out
        // and a project-creation click), the seed is skipped and
        // the project still works; the first agent note or user
        // note will create the topic lazily.
        DomeProjectMemory.seedOverview(for: project)

        // C3 (Phase 3): Register the project for code indexing and
        // kick off a full rebuild on a detached task. Runs for many
        // minutes on a multi-thousand-file project — the user can
        // start using the app immediately while indexing proceeds in
        // the background. Status is poll-able via
        // `DomeRpcClient.codeIndexStatus`.
        let projectID = project.id.uuidString.lowercased()
        let projectName = project.name
        let projectRoot = project.rootPath
        // Honor the per-user kill switch — if code indexing is OFF,
        // we still register the project (so flipping the switch on
        // later picks it up via `code.watch.resume_all`), but skip
        // the immediate full index + watcher start.
        let codeIndexingOn = appSettings?.codeIndexingEnabled ?? true
        Task.detached(priority: .background) {
            DomeRpcClient.codeRegisterProject(
                projectID: projectID,
                name: projectName,
                rootPath: projectRoot,
                enabled: codeIndexingOn
            )
            guard codeIndexingOn else { return }
            _ = DomeRpcClient.codeIndexProject(projectID: projectID, fullRebuild: true)
            // Phase 4: keep the index live by file-watching the
            // project root. The watcher debounces 500 ms and only
            // re-embeds files whose SHA actually changed, so it's
            // cheap even for large projects.
            DomeRpcClient.codeWatchStart(projectID: projectID)
        }

        dismiss()
    }
}
