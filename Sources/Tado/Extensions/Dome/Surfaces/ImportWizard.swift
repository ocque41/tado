import AppKit
import Foundation
import SwiftUI

/// v0.13 — Bulk import wizard.
///
/// Drives `tado_dome_import_preview` → `tado_dome_import_execute`.
/// Steps:
///   1. Pick a folder (must already live inside the Dome vault root —
///      bt-core enforces that on the daemon side).
///   2. Tree of every file the daemon found. Tick the rows you want
///      to import. `Select all` / `Clear` / per-extension filter chips
///      help with bulk selection.
///   3. Confirm → import_execute returns counts + per-file outcomes.
///
/// All state mutations go through `swift_ui_actor()` so every action
/// shows up in the audit log under `actor=user_ui`.
struct ImportWizard: View {
    let domeScope: DomeScopeSelection
    let onClose: () -> Void

    @State private var phase: Phase = .pickRoot
    @State private var preview: DomeRpcClient.ImportPreviewResult?
    @State private var selectedSourcePaths: Set<String> = []
    @State private var executing = false
    @State private var executeResult: DomeRpcClient.ImportExecuteResult?
    @State private var error: String?
    @State private var picking = false

    enum Phase {
        case pickRoot
        case review
        case done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(Palette.divider)
            switch phase {
            case .pickRoot: pickRootView
            case .review: reviewView
            case .done: doneView
            }
            Divider().overlay(Palette.divider)
            footer
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 540)
        .background(Palette.background)
    }

    // MARK: - Phase views

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Bulk import")
                .font(Typography.display)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Text(phaseLabel)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .pickRoot: return "Step 1 of 3 — pick a folder"
        case .review: return "Step 2 of 3 — review files"
        case .done: return "Step 3 of 3 — done"
        }
    }

    private var pickRootView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a folder inside your Dome vault. The daemon walks it, lists every importable file, and you confirm which ones become notes (markdown / txt) or attachments.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(picking ? "Picking…" : "Choose folder…") { pickRoot() }
                    .buttonStyle(.borderedProminent)
                    .disabled(picking)

                Button("Scan vault root (everything)") { runPreview(rootPath: nil) }
                    .buttonStyle(.borderless)
                    .help("Skip the picker and scan the entire vault root for importable files.")
            }

            if let err = error { errorBanner(err) }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = preview {
                HStack {
                    Text(p.rootPath)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(selectedSourcePaths.count) of \(p.items.count) selected · \(p.skipped.count) skipped")
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textTertiary)
                }

                HStack(spacing: 8) {
                    Button("Select all") {
                        selectedSourcePaths = Set(p.items.map(\.sourcePath))
                    }
                    .buttonStyle(.borderless)
                    Button("Clear") { selectedSourcePaths.removeAll() }
                        .buttonStyle(.borderless)
                    Button("Notes only (.md / .txt)") {
                        selectedSourcePaths = Set(p.items.filter { $0.mode == "note_text" }.map(\.sourcePath))
                    }
                    .buttonStyle(.borderless)
                    Button("Attachments only") {
                        selectedSourcePaths = Set(p.items.filter { $0.mode == "attachment" }.map(\.sourcePath))
                    }
                    .buttonStyle(.borderless)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(p.items) { item in
                            itemRow(item)
                        }
                        if !p.skipped.isEmpty {
                            Divider().overlay(Palette.divider).padding(.vertical, 8)
                            Text("Skipped (\(p.skipped.count))")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textTertiary)
                            ForEach(p.skipped, id: \.path) { skipped in
                                HStack(spacing: 6) {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(Palette.textTertiary)
                                        .font(.system(size: 11))
                                    Text(skipped.path)
                                        .font(Typography.monoCaption)
                                        .foregroundStyle(Palette.textTertiary)
                                    Text(skipped.reason)
                                        .font(Typography.micro)
                                        .foregroundStyle(Palette.textTertiary)
                                    Spacer()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView("Scanning…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let err = error { errorBanner(err) }
        }
    }

    private func itemRow(_ item: DomeRpcClient.ImportItem) -> some View {
        let isSelected = selectedSourcePaths.contains(item.sourcePath)
        return Button(action: {
            if isSelected {
                selectedSourcePaths.remove(item.sourcePath)
            } else {
                selectedSourcePaths.insert(item.sourcePath)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textTertiary)
                    .font(.system(size: 12))
                Text(item.relativePath)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(item.topic)
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
                Text(item.mode == "note_text" ? "note" : "attachment")
                    .font(Typography.micro)
                    .foregroundStyle(item.mode == "note_text" ? Palette.success : Palette.warning)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Palette.surfaceAccentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = executeResult {
                Text("Imported \(result.imported.count) of \(result.count) files")
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                if !result.failures.isEmpty {
                    Text("\(result.failures.count) failure(s)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(result.failures, id: \.relativePath) { failure in
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(Palette.danger)
                                        .font(.system(size: 11))
                                    Text(failure.relativePath ?? "?")
                                        .font(Typography.monoCaption)
                                        .foregroundStyle(Palette.textPrimary)
                                    Text(failure.reason)
                                        .font(Typography.micro)
                                        .foregroundStyle(Palette.textSecondary)
                                    Spacer()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 200)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if phase == .review {
                Button("Back") { phase = .pickRoot }
                    .buttonStyle(.borderless)
                    .disabled(executing)
                Button(executing ? "Importing…" : "Import \(selectedSourcePaths.count) files") {
                    runExecute()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(executing || selectedSourcePaths.isEmpty)
            }
            if phase == .done {
                Button("Close") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") { onClose() }
                    .buttonStyle(.borderless)
                    .disabled(executing)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon")
                .foregroundStyle(Palette.danger)
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { error = nil }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func pickRoot() {
        picking = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let response = panel.runModal()
        picking = false
        if response == .OK, let url = panel.url {
            runPreview(rootPath: url.path)
        }
    }

    private func runPreview(rootPath: String?) {
        error = nil
        Task.detached {
            let result = DomeRpcClient.importPreview(rootPath: rootPath)
            await MainActor.run {
                if let result {
                    preview = result
                    selectedSourcePaths = Set(result.items.map(\.sourcePath))
                    phase = .review
                } else {
                    error = "Couldn't scan that folder. The daemon expects a path inside the Dome vault root — paths outside the vault are rejected. Drop the files into <vault>/inbox/ first if you want to import from elsewhere."
                }
            }
        }
    }

    private func runExecute() {
        guard let preview else { return }
        let chosen = preview.items.filter { selectedSourcePaths.contains($0.sourcePath) }
        executing = true
        Task.detached {
            let result = DomeRpcClient.importExecute(items: chosen)
            await MainActor.run {
                executing = false
                if let result {
                    executeResult = result
                    phase = .done
                } else {
                    error = "Import failed. Check the audit log for the rejected row."
                }
            }
        }
    }
}
