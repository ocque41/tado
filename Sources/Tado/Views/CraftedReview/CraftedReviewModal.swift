import SwiftUI
import SwiftData

/// Branded review modal for the architect-authored `crafted.md` plan.
/// Used by both Dispatch and Eternal — the kind passed in disambiguates
/// which run model to fetch, where to read the file from, and which
/// service method to call on Accept / Re-plan. Layout: 220px section
/// index on the left, scrollable rendered markdown body on the right,
/// shared top-bar (Cancel / title / Accept) and footer (Re-plan / hint
/// / shortcuts) chrome that mirrors `DispatchFileModal` and
/// `EternalFileModal` byte-for-byte.
struct CraftedReviewModal: View {
    let runID: UUID
    let kind: CraftedReviewKind

    @Environment(\.modelContext) private var modelContext
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var blocks: [MarkdownBlock] = []
    @State private var sections: [(text: String, slug: String)] = []
    @State private var selectedSlug: String? = nil
    @State private var loadError: String? = nil
    @State private var titleSubject: String = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
            Divider()
            footerBar
        }
        .frame(minWidth: 980, minHeight: 720)
        .background(Palette.background)
        .onAppear(perform: loadDocument)
    }

    // MARK: - Chrome

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

            VStack(spacing: 2) {
                Text(titleSubject)
                    .font(Typography.heading)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text("Plan review · crafted.md")
                    .font(Typography.microBold)
                    .tracking(0.6)
                    .foregroundStyle(Palette.textTertiary)
            }

            Spacer()

            Button(action: acceptTapped) {
                HStack(spacing: 4) {
                    Text(kind == .dispatch ? "Accept & Dispatch" : "Accept & Run")
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

    @ViewBuilder
    private var content: some View {
        if let loadError {
            errorBanner(loadError)
        } else {
            HStack(spacing: 0) {
                CraftedReviewIndex(
                    sections: sections,
                    selectedSlug: $selectedSlug,
                    onSelect: { slug in selectedSlug = slug }
                )
                Divider()
                ScrollViewReader { proxy in
                    CraftedReviewBody(
                        blocks: blocks,
                        scrollProxy: proxy,
                        selectedSlug: $selectedSlug
                    )
                    .onChange(of: selectedSlug) { _, slug in
                        guard let slug else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(slug, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Button(action: replanTapped) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                    Text("Re-plan…")
                }
                .font(Typography.label)
                .foregroundStyle(Palette.warning)
            }
            .buttonStyle(.plain)
            .help("Re-open the brief modal so you can revise the request and re-spawn the architect.")

            Spacer()

            Text(kind == .dispatch
                 ? "Accept dispatches phase 1. Re-plan returns to the brief editor."
                 : "Accept launches the worker. Re-plan returns to the brief editor.")
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

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(Palette.warning)
            Text("Couldn't load crafted.md")
                .font(Typography.heading)
                .foregroundStyle(Palette.textPrimary)
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - State

    private var canAccept: Bool { loadError == nil && !blocks.isEmpty }

    private func loadDocument() {
        switch kind {
        case .dispatch:
            guard let run = fetchDispatchRun(runID),
                  let project = run.project else {
                loadError = "Run is missing or has been deleted."
                return
            }
            titleSubject = "Dispatch — \(project.name) · \(run.label)"
            let url = DispatchPlanService.craftedFileURL(run)
            loadFromDisk(url: url)
        case .eternal:
            guard let run = fetchEternalRun(runID),
                  let project = run.project else {
                loadError = "Run is missing or has been deleted."
                return
            }
            titleSubject = "Eternal — \(project.name) · \(run.label)"
            let url = EternalService.craftedFileURL(run)
            loadFromDisk(url: url)
        }
    }

    private func loadFromDisk(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "Architect has not finished — crafted.md is not on disk yet."
            return
        }
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "Could not read \(url.path)."
            return
        }
        let parsed = MarkdownBlocks.parse(body)
        blocks = parsed
        sections = MarkdownBlocks.sectionIndex(parsed)
        selectedSlug = sections.first?.slug
    }

    // MARK: - Fetches

    private func fetchDispatchRun(_ id: UUID) -> DispatchRun? {
        var descriptor = FetchDescriptor<DispatchRun>(
            predicate: #Predicate<DispatchRun> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func fetchEternalRun(_ id: UUID) -> EternalRun? {
        var descriptor = FetchDescriptor<EternalRun>(
            predicate: #Predicate<EternalRun> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Actions

    private func acceptTapped() {
        guard canAccept else { return }
        switch kind {
        case .dispatch:
            guard let run = fetchDispatchRun(runID) else { return }
            DispatchPlanService.acceptReview(
                run: run,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )
        case .eternal:
            guard let run = fetchEternalRun(runID) else { return }
            EternalService.acceptReview(
                run: run,
                modelContext: modelContext,
                terminalManager: terminalManager,
                appState: appState
            )
        }
        dismiss()
    }

    private func replanTapped() {
        switch kind {
        case .dispatch:
            appState.dispatchModalRunID = runID
        case .eternal:
            appState.eternalModalRunID = runID
        }
        dismiss()
    }
}
