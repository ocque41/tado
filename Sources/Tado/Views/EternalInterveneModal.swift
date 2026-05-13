import SwiftUI
import SwiftData

/// Ad-hoc message sender for a running Eternal worker.
///
/// The user types a plain-language note — priority change, correction,
/// question, extra context. Accept spawns a short-lived Haiku 4.5
/// "Interventor" tile that grounds the message in the worker's current
/// state (crafted.md + progress.md tail), writes a distilled directive
/// to `.tado/eternal/inbox/intervene-<ts>.md`, and prints a one-paragraph
/// confirmation so the user sees when the worker will pick it up.
///
/// The worker's loop wrapper drains the inbox at the top of every
/// iteration and injects each note under a "USER INTERVENTIONS" section
/// in its next prompt — authoritative, processed before resuming the
/// current sprint phase.
struct EternalInterveneModal: View {
    /// The run whose worker the interventor will send a note to. Modal
    /// title includes the run label so the user can see at a glance which
    /// of the project's concurrent runs they're addressing.
    let run: EternalRun

    @Environment(\.modelContext) private var modelContext
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var message: String = ""

    private var canAccept: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    flowBlurb
                    messageEditor
                    examplesBlurb
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

            Divider()
            footerHint
        }
        .frame(minWidth: 600, minHeight: 460)
        .background(Palette.background)
    }

    // MARK: - Top bar / footer

    private var topBar: some View {
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

            Text("Intervene — \(run.project?.name ?? "?") · \(run.label)")
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
                .foregroundStyle(canAccept ? Palette.success : Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(!canAccept)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.surfaceElevated)
    }

    private var footerHint: some View {
        HStack {
            Text("Accept sends this note to the worker's inbox.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
            Spacer()
            Text("⌘↩ to Accept · Esc to Cancel")
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.surfaceElevated)
    }

    // MARK: - Blurbs + editor

    private var flowBlurb: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOUR MESSAGE")
                .font(Typography.microBold)
                .tracking(0.8)
                .foregroundStyle(Palette.textTertiary)
            Text("Write what the worker should know. It reads the note next iteration.")
                .font(Typography.bodySm)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var messageEditor: some View {
        ZStack(alignment: .topLeading) {
            if message.isEmpty {
                Text("Examples:\n  pivot to M3 dialogue\n  polish M2 lighting\n  what's blocking sprint 1?")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $message)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(10)
        }
        .frame(minHeight: 180)
        .background(Palette.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private var examplesBlurb: some View {
        HStack(alignment: .top, spacing: 8) {
            InfoTip(text: "The worker reads this at the start of the next iteration. Use Stop to end the run.")
            Text("This does not interrupt the current iteration. Use Stop to end the run.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    // MARK: - Actions

    private func acceptTapped() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        EternalService.spawnInterventor(
            run: run,
            userMessage: trimmed,
            modelContext: modelContext,
            terminalManager: terminalManager,
            appState: appState
        )

        dismiss()
    }
}
