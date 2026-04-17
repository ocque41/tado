import SwiftUI
import SwiftData

struct DispatchFileModal: View {
    let project: Project
    @Environment(\.modelContext) private var modelContext
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var showReplanAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: Cancel (left), title (center), Accept (right)
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

                Text("Dispatch File — \(project.name)")
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                Button(action: acceptTapped) {
                    HStack(spacing: 4) {
                        Text("Accept")
                        Image(systemName: "checkmark")
                            .font(.system(size: 11))
                    }
                    .font(Typography.label)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Palette.textSecondary : Palette.success)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.surface)

            Divider()

            // Markdown editor body
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Describe WHAT you want built and WHY — the goal, constraints, and any known context. You don't need to plan the phases or pick tools.\n\nWhen you hit Accept, a Dispatch Architect agent spawns on the canvas. It will: research the project, break the work into phases, create a dedicated skill per phase via /skill-creator, assign agents, and write the full execution plan to .tado/dispatch/. Then you click Start to launch phase 1.\n\nThe more context you give here (users, stack, priorities, done criteria), the better the plan it builds.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $draft)
                    .font(Typography.monoBody)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            Divider()

            // Footer hint
            HStack {
                Text(project.dispatchState == "idle"
                    ? "Accept spawns the Dispatch Architect on the canvas."
                    : "Accept replaces the existing plan and re-dispatches the architect.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("⌘↩ to Accept · Esc to Cancel")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.surface)
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Palette.background)
        .onAppear {
            draft = project.dispatchMarkdown
        }
        .alert("Delete existing plan and re-plan?", isPresented: $showReplanAlert) {
            Button("Delete & Re-plan", role: .destructive) {
                commitAndSpawnArchitect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove .tado/dispatch/plan.json and all phase files, then spawn a new architect terminal on the canvas.")
        }
    }

    private func acceptTapped() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if project.dispatchState != "idle" && DispatchPlanService.planExistsOnDisk(project) {
            showReplanAlert = true
        } else {
            commitAndSpawnArchitect()
        }
    }

    private func commitAndSpawnArchitect() {
        project.dispatchMarkdown = draft
        project.dispatchState = "drafted"
        try? modelContext.save()

        DispatchPlanService.spawnArchitect(
            project: project,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        dismiss()
    }
}
