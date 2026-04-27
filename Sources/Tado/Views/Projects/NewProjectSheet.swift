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

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button(action: { dismiss() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                        Text("Cancel")
                    }
                    .font(Typography.label)
                    .foregroundStyle(Palette.danger.opacity(0.85))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("New Project")
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                Button(action: create) {
                    HStack(spacing: 4) {
                        Text("Create")
                        Image(systemName: "checkmark")
                            .font(.system(size: 11))
                    }
                    .font(Typography.label)
                    .foregroundStyle(canCreate ? Palette.success : Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.surfaceElevated)

            Divider()

            // Body — name + location
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(Typography.label)
                        .foregroundStyle(Palette.textSecondary)
                    TextField("", text: $name, prompt: Text("noblestack").foregroundStyle(Palette.textTertiary))
                        .textFieldStyle(.plain)
                        .font(Typography.monoBody)
                        .foregroundStyle(Palette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Palette.divider, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .focused($nameFocused)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Location")
                        .font(Typography.label)
                        .foregroundStyle(Palette.textSecondary)
                    HStack(spacing: 8) {
                        Text(path.isEmpty ? "Select a folder…" : path)
                            .font(Typography.monoCaption)
                            .foregroundStyle(path.isEmpty ? Palette.textTertiary : Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Palette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Palette.divider, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button(action: pickDirectory) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                Text("Browse…")
                            }
                            .font(Typography.label)
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Palette.surfaceAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 280)
        .background(Palette.background)
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
