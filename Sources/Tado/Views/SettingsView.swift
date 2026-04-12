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
                    LabeledContent("Switch view", value: "Ctrl + Tab")
                    LabeledContent("Settings", value: "Cmd + M")
                    LabeledContent("Sidebar", value: "Cmd + B")
                    LabeledContent("Submit todo", value: "Enter")
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 10)
        }
        .frame(width: 450, height: 380)
    }
}
