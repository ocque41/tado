import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allSettings: [AppSettings]

    private var settings: AppSettings {
        if let existing = allSettings.first {
            return existing
        }
        let new = AppSettings()
        modelContext.insert(new)
        try? modelContext.save()
        return new
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(20)

            Divider()

            // Settings form
            Form {
                Section("Engine") {
                    Picker("When you press Enter, run:", selection: Binding(
                        get: { settings.engine },
                        set: { settings.engine = $0; try? modelContext.save() }
                    )) {
                        ForEach(TerminalEngine.allCases, id: \.self) { engine in
                            HStack {
                                Text(engine.displayName)
                                Text("(\(engine.rawValue) \"your todo\")")
                                    .foregroundStyle(.secondary)
                            }
                            .tag(engine)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }

                Section("Mode") {
                    if settings.engine == .claude {
                        Picker("Permission mode:", selection: Binding(
                            get: { settings.claudeMode },
                            set: { settings.claudeMode = $0; try? modelContext.save() }
                        )) {
                            ForEach(ClaudeMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("Approval mode:", selection: Binding(
                            get: { settings.codexMode },
                            set: { settings.codexMode = $0; try? modelContext.save() }
                        )) {
                            ForEach(CodexMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Model") {
                    if settings.engine == .claude {
                        Picker("Claude model:", selection: Binding(
                            get: { settings.claudeModel },
                            set: { settings.claudeModel = $0; try? modelContext.save() }
                        )) {
                            ForEach(ClaudeModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("Codex model:", selection: Binding(
                            get: { settings.codexModel },
                            set: { settings.codexModel = $0; try? modelContext.save() }
                        )) {
                            ForEach(CodexModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Effort") {
                    if settings.engine == .claude {
                        Picker("Thinking effort:", selection: Binding(
                            get: { settings.claudeEffort },
                            set: { settings.claudeEffort = $0; try? modelContext.save() }
                        )) {
                            ForEach(ClaudeEffort.allCases, id: \.self) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("Reasoning effort:", selection: Binding(
                            get: { settings.codexEffort },
                            set: { settings.codexEffort = $0; try? modelContext.save() }
                        )) {
                            ForEach(CodexEffort.allCases, id: \.self) { effort in
                                Text(effort.displayName).tag(effort)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section {
                    if settings.engine == .claude {
                        Toggle("No-flicker fullscreen renderer", isOn: Binding(
                            get: { settings.claudeNoFlicker },
                            set: { settings.claudeNoFlicker = $0; try? modelContext.save() }
                        ))
                        Toggle("Mouse + clickable UI", isOn: Binding(
                            get: { settings.claudeMouseEnabled },
                            set: { settings.claudeMouseEnabled = $0; try? modelContext.save() }
                        ))
                        .disabled(!settings.claudeNoFlicker)
                        Stepper(
                            "Scroll speed: \(settings.claudeScrollSpeed)x",
                            value: Binding(
                                get: { settings.claudeScrollSpeed },
                                set: { settings.claudeScrollSpeed = $0; try? modelContext.save() }
                            ),
                            in: 1...20
                        )
                        .disabled(!settings.claudeNoFlicker)
                        Text("Sets CLAUDE_CODE_NO_FLICKER, CLAUDE_CODE_DISABLE_MOUSE, and CLAUDE_CODE_SCROLL_SPEED on every spawned Claude Code session. Restart the session to apply.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Allow alternate-screen buffer", isOn: Binding(
                            get: { settings.codexAlternateScreen },
                            set: { settings.codexAlternateScreen = $0; try? modelContext.save() }
                        ))
                        Text("Codex's equivalent of NO_FLICKER. Off keeps `--no-alt-screen` on, which is required for Codex to render correctly inside Tado tiles. Turn on only if you're testing a Codex build that handles alt-screen in embedded terminals.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Harness Display")
                }

                Section {
                    Toggle("Random tile color per session", isOn: Binding(
                        get: { settings.randomTileColor },
                        set: { settings.randomTileColor = $0; try? modelContext.save() }
                    ))
                    Text("Each new terminal tile picks a random theme from a curated palette of Claude colors and macOS Terminal classics. Existing tiles keep their current color.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Tile Appearance")
                }

                Section {
                    Toggle("Use Rust + Metal renderer (experimental)", isOn: Binding(
                        get: { settings.useMetalRenderer },
                        set: { settings.useMetalRenderer = $0; try? modelContext.save() }
                    ))
                    Text("Phase 2 pipeline: tado-core (Rust PTY + VT parser) with a GPU-accelerated glyph grid instead of SwiftTerm. Only affects tiles spawned after the toggle flips; existing tiles keep their current renderer until closed. Try Cmd+Shift+M to preview on a standalone shell window without enabling this globally.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Stepper(
                        "Terminal font size: \(settings.terminalFontSize) pt",
                        value: Binding(
                            get: { settings.terminalFontSize },
                            set: { settings.terminalFontSize = $0; try? modelContext.save() }
                        ),
                        in: 9...24
                    )
                    Text("Monospace point size used by the Metal renderer. Changes apply to tiles spawned after the setting moves; existing tiles keep their current size so scrollback geometry stays stable.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Toggle("Blink cursor", isOn: Binding(
                        get: { settings.cursorBlink },
                        set: { settings.cursorBlink = $0; try? modelContext.save() }
                    ))
                    Text("When on, the Metal renderer hides the cursor every ~530 ms (Terminal.app cadence). Off keeps the cursor solid, useful for screen recordings.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Picker("Bell", selection: Binding(
                        get: { settings.bellMode },
                        set: { settings.bellMode = $0; try? modelContext.save() }
                    )) {
                        ForEach(BellMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Text("How a terminal bell (0x07) is surfaced — agents ring this for notifications. Visual flashes the tile background; useful when audio is muted. Metal path only; SwiftTerm tiles defer to the library's built-in audible bell.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Rendering")
                }

                Section("Canvas") {
                    Stepper(
                        "Grid columns: \(settings.gridColumns)",
                        value: Binding(
                            get: { settings.gridColumns },
                            set: { settings.gridColumns = $0; try? modelContext.save() }
                        ),
                        in: 2...6
                    )
                }

                Section("Shortcuts") {
                    LabeledContent("Cycle pages", value: "Ctrl + Tab")
                    LabeledContent("Projects", value: "Cmd + P")
                    LabeledContent("Teams", value: "Cmd + E")
                    LabeledContent("Settings", value: "Cmd + M")
                    LabeledContent("Sidebar", value: "Cmd + B")
                    LabeledContent("Done list", value: "Cmd + D")
                    LabeledContent("Trash", value: "Cmd + T")
                    LabeledContent("Submit todo", value: "Enter")
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 10)
        }
        .frame(width: 480, height: 720)
    }
}
