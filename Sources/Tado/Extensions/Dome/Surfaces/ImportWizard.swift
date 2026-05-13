import AppKit
import Foundation
import SwiftUI

/// v0.13 — Bulk import wizard. v0.18 — restyled on the structural-grid
/// design language: PageHeader-style title bar with phase StatusPill,
/// hairline-bordered phase bodies, OutlineButton actions, flat-tabular
/// item rows.
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
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)

            VStack(alignment: .leading, spacing: 14) {
                switch phase {
                case .pickRoot: pickRootView
                case .review: reviewView
                case .done: doneView
                }
            }
            .padding(.horizontal, DK.pageGutter)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Palette.bgPage)
    }

    // MARK: - Header

    /// PageHeader-style title bar with a phase StatusPill on the
    /// right. Mono caption "Bulk import" overline + 28 pt bold
    /// title + StatusPill phase tracker.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                OverlineLabel("Wizard · 3 steps")
                Text("Bulk import")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink)
                Text(domeScope.label)
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 16)
            phasePill
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var phasePill: some View {
        switch phase {
        case .pickRoot: StatusPill("step 1 · pick", variant: .draft)
        case .review:   StatusPill("step 2 · review", variant: .planning)
        case .done:     StatusPill("step 3 · done", variant: .running)
        }
    }

    // MARK: - Phase 1 — pick root

    private var pickRootView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a folder inside the Dome vault, then choose what to import.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 580, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                OutlineButton(
                    picking ? "Picking…" : "Choose folder…",
                    icon: "folder",
                    size: .regular,
                    variant: .accent,
                    action: pickRoot
                )
                .disabled(picking)

                OutlineButton(
                    "Scan vault root (everything)",
                    icon: "tray.full",
                    size: .regular,
                    variant: .standard,
                    action: { runPreview(rootPath: nil) }
                )
                .help("Skip the picker and scan the entire vault root for importable files.")
            }

            if let err = error { errorBanner(err) }

            Text("VAULT IMPORT  ·  paths must stay inside the vault")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.rule).frame(height: 1).padding(.horizontal, -2)
                }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Phase 2 — review

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = preview {
                HStack(spacing: 10) {
                    Text(p.rootPath)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(selectedSourcePaths.count) of \(p.items.count) selected · \(p.skipped.count) skipped")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }

                HStack(spacing: 6) {
                    OutlineButton("Select all", size: .small, variant: .standard) {
                        selectedSourcePaths = Set(p.items.map(\.sourcePath))
                    }
                    OutlineButton("Clear", size: .small, variant: .ghost) {
                        selectedSourcePaths.removeAll()
                    }
                    OutlineButton("Notes only", size: .small, variant: .standard) {
                        selectedSourcePaths = Set(p.items.filter { $0.mode == "note_text" }.map(\.sourcePath))
                    }
                    OutlineButton("Attachments only", size: .small, variant: .standard) {
                        selectedSourcePaths = Set(p.items.filter { $0.mode == "attachment" }.map(\.sourcePath))
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(p.items) { item in
                            itemRow(item)
                            Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                        }
                        if !p.skipped.isEmpty {
                            HStack {
                                OverlineLabel("Skipped · \(p.skipped.count)", tint: Palette.ink4)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Palette.bgPage)
                            ForEach(p.skipped, id: \.path) { skipped in
                                HStack(spacing: 8) {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(Palette.ink4)
                                        .font(.system(size: 10))
                                    Text(skipped.path)
                                        .font(Typography.monoCaption)
                                        .foregroundStyle(Palette.ink3)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(skipped.reason)
                                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                                        .foregroundStyle(Palette.ink4)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.bgElev)
                .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
            } else {
                ProgressView("Scanning…")
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
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
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Palette.accent : Palette.ink4)
                    .font(.system(size: 12))
                Text(item.relativePath)
                    .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(item.topic)
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
                StatusPill(
                    item.mode == "note_text" ? "note" : "attachment",
                    variant: item.mode == "note_text" ? .running : .review
                )
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Phase 3 — done

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = executeResult {
                HStack(spacing: 12) {
                    StatusPill("imported", variant: .running)
                    Text("\(result.imported.count) of \(result.count) files")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    if !result.failures.isEmpty {
                        StatusPill("\(result.failures.count) failed", variant: .danger)
                    }
                }

                if !result.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(result.failures, id: \.relativePath) { failure in
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(Palette.danger)
                                    .font(.system(size: 11))
                                Text(failure.relativePath ?? "?")
                                    .font(Typography.monoCaption)
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(failure.reason)
                                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Palette.ink3)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Palette.bgElev)
                            Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                        }
                    }
                    .frame(maxHeight: 220)
                    .overlay(Rectangle().stroke(Palette.rule, lineWidth: DK.ruleW))
                }
                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if phase == .review {
                OutlineButton("Back", icon: "chevron.left", size: .small, variant: .ghost) {
                    phase = .pickRoot
                }
                .disabled(executing)
                OutlineButton(
                    executing ? "Importing…" : "Import \(selectedSourcePaths.count) files",
                    icon: "arrow.down.to.line",
                    size: .small,
                    variant: .accent,
                    action: runExecute
                )
                .keyboardShortcut(.defaultAction)
                .disabled(executing || selectedSourcePaths.isEmpty)
            }
            if phase == .done {
                OutlineButton("Close", icon: "xmark", size: .small, variant: .accent, action: onClose)
                    .keyboardShortcut(.defaultAction)
            } else {
                OutlineButton("Cancel", size: .small, variant: .ghost, action: onClose)
                    .disabled(executing)
            }
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 12)
        .background(Palette.bgPage)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon")
                .foregroundStyle(Palette.danger)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            OutlineButton("Dismiss", size: .small, variant: .ghost) {
                error = nil
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.danger.opacity(0.08))
        .overlay(Rectangle().stroke(Palette.danger.opacity(0.4), lineWidth: DK.ruleW))
    }

    // MARK: - Actions (unchanged)

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
