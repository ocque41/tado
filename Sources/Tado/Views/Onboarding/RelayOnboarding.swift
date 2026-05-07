// Relay first-run onboarding per brief section 12.
//
// Four full-page steps, rendered inside the main window (no
// modal). Gated by `@AppStorage("relay.onboarded")` so it only
// surfaces once. Includes a `Skip →` link in every step and a
// 1-of-4 progress indicator in the bottom-right.
//
// 1. Welcome — kicker `00 — WELCOME`, h1 "Tado runs your agents
//    in parallel.", BEGIN button.
// 2. Pick engines — toggleable list of detected engines.
// 3. Bootstrap a project — file picker + checkbox.
// 4. Done — kicker `04 — READY`, h1 "Type a task. Press ⌘↩.",
//    auto-redirects to Todos in 3s.

import SwiftUI
import SwiftData

struct RelayOnboarding: View {
    @Environment(\.relayTheme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @AppStorage("relay.onboarded") private var onboarded: Bool = false

    @State private var step: Int = 0

    var body: some View {
        ZStack {
            RelayPalette.background(for: theme)
                .ignoresSafeArea()
            stepContent
                .padding(48)
            VStack {
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .buttonStyle(.plain)
                        .font(Typography.sans(size: 11, weight: .medium))
                        .tracking(RelayTracking.caps(11))
                        .foregroundStyle(RelayPalette.foreground3(for: theme))
                }
                Spacer()
                HStack {
                    Spacer()
                    progress
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: welcomeStep
        case 1: enginesStep
        case 2: bootstrapStep
        default: doneStep
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            RelayKicker(text: "00 — WELCOME")
            Text("Tado runs your agents in parallel.")
                .font(RelayType.h1(size: 60))
                .tracking(RelayTracking.h1(60))
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 800, alignment: .leading)
            Text("Type a todo, press ⌘↩, and an agent gets to work in its own terminal tile. Forty agents at once is the unit of work.")
                .font(RelayType.lead())
                .foregroundStyle(RelayPalette.foreground2(for: theme))
                .frame(maxWidth: 720, alignment: .leading)
                .lineSpacing(4)
            RelayButton(label: "Begin →", variant: .primary) {
                advance()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var enginesStep: some View {
        VStack(alignment: .leading, spacing: 32) {
            RelayKicker(text: "01 — PICK YOUR ENGINES")
            Text("Pick how todos should spawn.")
                .font(RelayType.h1(size: 52))
                .tracking(RelayTracking.h1(52))
                .foregroundStyle(RelayPalette.foreground(for: theme))
            Text("Tado spawns a CLI per todo. Pick the engine you want today; you can switch any time in Settings.")
                .font(RelayType.lead())
                .foregroundStyle(RelayPalette.foreground2(for: theme))
                .frame(maxWidth: 600, alignment: .leading)
                .lineSpacing(4)

            VStack(spacing: 0) {
                engineCard(name: "Claude Code", desc: "Long-context Anthropic CLI. Default for most projects.")
                engineCard(name: "Codex",       desc: "OpenAI's CLI. Useful when you need GPT-style completion.")
                engineCard(name: "Claude Cowork", desc: "Desktop-first knowledge-work coworker. URL-scheme launched.")
            }

            HStack {
                RelayButton(label: "Continue →", variant: .primary) {
                    advance()
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func engineCard(name: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(name)
                .font(Typography.sans(size: 18, weight: .light))
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .frame(width: 200, alignment: .leading)
            Text(desc)
                .font(Typography.sans(size: 13, weight: .regular))
                .foregroundStyle(RelayPalette.foreground2(for: theme))
                .frame(maxWidth: 520, alignment: .leading)
                .lineSpacing(2)
            Spacer()
        }
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hairSoft(for: theme))
                .frame(height: 1)
        }
    }

    private var bootstrapStep: some View {
        VStack(alignment: .leading, spacing: 32) {
            RelayKicker(text: "02 — BOOTSTRAP A PROJECT")
            Text("Add your first project.")
                .font(RelayType.h1(size: 52))
                .tracking(RelayTracking.h1(52))
                .foregroundStyle(RelayPalette.foreground(for: theme))
            Text("A project links a directory on disk to Tado. You can do this any time from the Projects tab — but starting with one makes the canvas more useful immediately.")
                .font(RelayType.lead())
                .foregroundStyle(RelayPalette.foreground2(for: theme))
                .frame(maxWidth: 720, alignment: .leading)
                .lineSpacing(4)
            HStack {
                RelayButton(label: "Add a project", variant: .primary) {
                    appState.showNewProjectSheet = true
                }
                RelayButton(label: "Skip for now", variant: .ghost) {
                    advance()
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 32) {
            RelayKicker(text: "04 — READY")
            Text("Type a task. Press ⌘↩.")
                .font(RelayType.h1(size: 60))
                .tracking(RelayTracking.h1(60))
                .foregroundStyle(RelayPalette.foreground(for: theme))
            Text("That's the whole flow.")
                .font(RelayType.lead())
                .foregroundStyle(RelayPalette.foreground2(for: theme))
            RelayButton(label: "Open Todos", variant: .primary) {
                finish()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            finish()
        }
    }

    // MARK: - Progress

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i <= step ? RelayPalette.terracotta : RelayPalette.foreground4(for: theme))
                    .frame(width: 6, height: 6)
            }
            Text("\(step + 1) / 4")
                .font(Typography.sans(size: 10, weight: .medium))
                .tracking(RelayTracking.caps(10))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
        }
    }

    private func advance() {
        if step < 3 {
            step += 1
        } else {
            finish()
        }
    }

    private func finish() {
        onboarded = true
        appState.currentView = .todos
    }
}
