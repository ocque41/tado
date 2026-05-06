import SwiftUI
import SwiftData
import os

/// Branded review modal for the architect-authored `crafted.md` plan.
/// Used by both Dispatch and Eternal — the kind passed in disambiguates
/// which run model to fetch, where to read the file from, and which
/// service method to call on Accept / Re-plan. Layout: 220px section
/// index on the left, scrollable rendered markdown body on the right,
/// shared top-bar (Cancel / title / Accept) and footer (Re-plan / hint
/// / shortcuts) chrome that mirrors `DispatchFileModal` and
/// `EternalFileModal` byte-for-byte.
///
/// v0.18 — file IO + markdown parsing moved off the main thread via
/// `.task` + `Task.detached`, gated by a `LoadState` enum so the
/// initial layout renders a skeleton with the same geometry as the
/// final state. Eliminates the visible "empty two-pane → real
/// content" reflow that operators reported. Process-lifetime cache
/// keyed by file URL + mtime makes re-opening the same plan free.
struct CraftedReviewModal: View {
    let runID: UUID
    let kind: CraftedReviewKind

    @Environment(\.modelContext) private var modelContext
    @Environment(TerminalManager.self) private var terminalManager
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var loadState: LoadState = .loading
    @State private var selectedSlug: String? = nil
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
        .task(id: runID) {
            await loadDocumentAsync()
        }
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
                Text(titleSubject.isEmpty ? "Loading…" : titleSubject)
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
        switch loadState {
        case .loading:
            loadingPane
        case .ready(let blocks, let sections):
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
        case .error(let message):
            errorBanner(message)
        }
    }

    /// Skeleton placeholder rendered while the architect plan is
    /// loading. Mirrors the geometry of the final two-pane content
    /// (220px index column + flexible body) so the inner layout
    /// settles once on first present, no reflow when real content
    /// arrives.
    private var loadingPane: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.surfaceElevated)
                        .frame(height: 14)
                        .padding(.horizontal, 14)
                }
                Spacer()
            }
            .frame(width: 220)
            .padding(.top, 18)
            .background(Palette.background)
            Divider()
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Loading plan…")
                    .font(Typography.monoCaption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
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

    private var canAccept: Bool {
        switch loadState {
        case .ready(let blocks, _): return !blocks.isEmpty
        default: return false
        }
    }

    /// Async load entry point. Resolves the run, picks the right
    /// crafted.md URL, then hands off to `parseOffMain` so the
    /// expensive parse never touches the main actor. The signpost
    /// + logger lines are debug-only — release builds stay quiet.
    private func loadDocumentAsync() async {
        let signposter = OSSignposter(subsystem: "tado", category: "CraftedReview")
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("loadDocument", id: signpostID)
        defer { signposter.endInterval("loadDocument", interval) }

        let resolved: (title: String, url: URL)?
        switch kind {
        case .dispatch:
            if let run = fetchDispatchRun(runID), let project = run.project {
                resolved = (
                    title: "Dispatch — \(project.name) · \(run.label)",
                    url: DispatchPlanService.craftedFileURL(run)
                )
            } else {
                resolved = nil
            }
        case .eternal:
            if let run = fetchEternalRun(runID), let project = run.project {
                resolved = (
                    title: "Eternal — \(project.name) · \(run.label)",
                    url: EternalService.craftedFileURL(run)
                )
            } else {
                resolved = nil
            }
        }

        guard let resolved else {
            loadState = .error("Run is missing or has been deleted.")
            return
        }

        titleSubject = resolved.title
        debugLog("opened url=\(resolved.url.path) kind=\(kind == .dispatch ? "dispatch" : "eternal")")

        let url = resolved.url
        let result: ParseResult = await Task.detached(priority: .userInitiated) {
            CraftedReviewModal.parseOffMain(url: url)
        }.value

        if Task.isCancelled { return }

        switch result {
        case .success(let blocks, let sections, let cacheHit, let durationMs):
            signposter.emitEvent("parsed", id: signpostID)
            debugLog("parsed cache=\(cacheHit ? "hit" : "miss") blocks=\(blocks.count) duration=\(durationMs)ms")
            loadState = .ready(blocks: blocks, sections: sections)
            selectedSlug = sections.first?.slug
        case .missing:
            loadState = .error("Architect has not finished — crafted.md is not on disk yet.")
        case .ioFailure(let message):
            loadState = .error(message)
        }
    }

    /// File IO + parse runs here. Always invoked from a detached
    /// task — never on the main actor. Hits the cache first, falls
    /// through to a fresh parse + cache write otherwise.
    nonisolated private static func parseOffMain(url: URL) -> ParseResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        let mtime: Date
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        } catch {
            return .ioFailure("Could not stat \(url.path).")
        }

        if let cached = MarkdownParseCache.shared.lookup(url: url, mtime: mtime) {
            return .success(blocks: cached.blocks, sections: cached.sections, cacheHit: true, durationMs: 0)
        }

        let body: String
        do {
            body = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return .ioFailure("Could not read \(url.path).")
        }

        let parseStart = DispatchTime.now()
        let parsed = MarkdownBlocks.parse(body)
        let sections = MarkdownBlocks.sectionIndex(parsed)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - parseStart.uptimeNanoseconds) / 1_000_000.0

        MarkdownParseCache.shared.store(url: url, mtime: mtime, blocks: parsed, sections: sections)

        return .success(blocks: parsed, sections: sections, cacheHit: false, durationMs: durationMs)
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        Logger(subsystem: "tado", category: "CraftedReview").debug("\(message, privacy: .public)")
        if ProcessInfo.processInfo.environment["TADO_DEBUG_REVIEW_MODAL"] != nil {
            FileHandle.standardError.write(Data("[CraftedReview] \(message)\n".utf8))
        }
        #endif
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

    // MARK: - Types

    /// Three-state loader: `.loading` while the file is being read +
    /// parsed off the main actor, `.ready` with the parsed blocks +
    /// section index, `.error` with a message for the operator.
    enum LoadState {
        case loading
        case ready(blocks: [MarkdownBlock], sections: [(text: String, slug: String)])
        case error(String)
    }

    /// Result from `parseOffMain` — what was learned during the
    /// detached task. The view-side `LoadState` is derived from
    /// this; keeping the two separate stops the view from having
    /// to know about cache instrumentation.
    enum ParseResult {
        case success(blocks: [MarkdownBlock], sections: [(text: String, slug: String)], cacheHit: Bool, durationMs: Double)
        case missing
        case ioFailure(String)
    }
}

/// Process-lifetime cache for parsed crafted.md plans, keyed by
/// file URL + mtime. Hits return immediately; misses parse +
/// store. Never persists to disk — re-launching the app re-parses
/// once per file. A misorder against mtime simply forces a fresh
/// parse, never returns stale.
private final class MarkdownParseCache: @unchecked Sendable {
    static let shared = MarkdownParseCache()

    private struct Entry {
        let mtime: Date
        let blocks: [MarkdownBlock]
        let sections: [(text: String, slug: String)]
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    func lookup(url: URL, mtime: Date) -> (blocks: [MarkdownBlock], sections: [(text: String, slug: String)])? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[url], entry.mtime == mtime else { return nil }
        return (entry.blocks, entry.sections)
    }

    func store(
        url: URL,
        mtime: Date,
        blocks: [MarkdownBlock],
        sections: [(text: String, slug: String)]
    ) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = Entry(mtime: mtime, blocks: blocks, sections: sections)
    }
}
