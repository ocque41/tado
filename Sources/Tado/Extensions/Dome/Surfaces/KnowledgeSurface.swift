import AppKit
import Foundation
import SwiftUI

struct KnowledgeSurface: View {
    let page: DomeKnowledgePage
    let domeScope: DomeScopeSelection

    var body: some View {
        switch page {
        case .list:
            KnowledgeListSurface(domeScope: domeScope)
        case .graph:
            KnowledgeGraphSurface(domeScope: domeScope)
        case .system:
            KnowledgeSystemSurface(domeScope: domeScope)
        case .topics:
            KnowledgeTopicsSurface(domeScope: domeScope)
        case .packs:
            KnowledgePacksSurface(domeScope: domeScope)
        case .suggestions:
            SuggestionsSurface(domeScope: domeScope)
        }
    }
}

// MARK: - v0.14 Topics + Packs

/// Authoritative topic browser. Reads `tado_dome_topic_list` (every
/// dir under `<vault>/topics/`) plus a per-topic doc count derived
/// from `listNotes`. Click a row → drills into the existing
/// `KnowledgeListSurface` filtered to that topic via a sheet.
private struct KnowledgeTopicsSurface: View {
    let domeScope: DomeScopeSelection

    @State private var topics: [String] = []
    @State private var notes: [DomeRpcClient.NoteSummary] = []
    @State private var newTopic: String = ""
    @State private var creating = false
    @State private var isLoading = false
    /// v0.17 — set during a topic-purge round so the row spinner
    /// can show progress + the row can disable its own button while
    /// the cascade runs.
    @State private var purging: Set<String> = []
    /// v0.17 — last-action banner so the operator gets confirmation
    /// the purge actually did something, even if the topic ends up
    /// gone from the list (`topic_list` walks the on-disk dirs so a
    /// purge that removes the last doc also removes the row).
    @State private var lastPurge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(title: "Topics", subtitle: "\(topics.count) topics · \(domeScope.label)", isLoading: isLoading) {
                Task { await reload() }
            }
            Divider().overlay(Palette.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("New topic name (slug)", text: $newTopic)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                        Button(creating ? "Creating…" : "Create topic") {
                            runCreate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(creating || newTopic.isEmpty)
                        Spacer()
                    }
                    if let lastPurge {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Palette.success)
                            Text(lastPurge)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
                    }
                    if topics.isEmpty {
                        surfaceEmpty(icon: "tag", text: "No topics yet — create one above to organize notes.")
                    } else {
                        ForEach(topics, id: \.self) { topic in
                            topicCard(topic)
                        }
                    }
                }
                .padding(20)
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload() }
    }

    private func topicCard(_ topic: String) -> some View {
        let count = notes.filter { $0.topic == topic }.count
        let busy = purging.contains(topic)
        return HStack(spacing: 10) {
            Image(systemName: "tag")
                .foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic)
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                Text("\(count) doc\(count == 1 ? "" : "s")")
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            Menu {
                Button("Delete topic data…", role: .destructive) {
                    confirmPurge(topic: topic, count: count)
                }
                .disabled(busy)
            } label: {
                if busy {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .help("Topic actions")
        }
        .padding(12)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let scope = domeScope
        async let topicsTask = Task.detached { DomeRpcClient.topicList() }.value
        async let notesTask = Task.detached {
            DomeRpcClient.listNotes(topic: nil, limit: 1000, domeScope: scope)
        }.value
        topics = await topicsTask
        if let fetchedNotes = await notesTask {
            notes = fetchedNotes
        }
    }

    private func runCreate() {
        let name = newTopic
        creating = true
        Task.detached {
            _ = DomeRpcClient.createTopic(name)
            await MainActor.run {
                creating = false
                newTopic = ""
            }
            await reload()
        }
    }

    /// v0.17 — show an `NSAlert.critical` confirmation before doing
    /// anything destructive. The purge cascades through note_chunks
    /// → graph_nodes → graph_edges → docs → on-disk topic dirs, so
    /// the operator sees the exact doomed-row count up-front.
    private func confirmPurge(topic: String, count: Int) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete topic “\(topic)”?"
        alert.informativeText = """
            This removes \(count) doc\(count == 1 ? "" : "s") in the active scope (\(domeScope.label)) plus their chunks, graph nodes, edges, and on-disk topic folders. \
            It will not touch any project files outside the Tado vault. This action cannot be undone.
            """
        alert.addButton(withTitle: "Cancel")
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runPurge(topic: topic)
    }

    private func runPurge(topic: String) {
        purging.insert(topic)
        let ownerScope = domeScope.ownerScope
        let projectID = domeScope.projectIDString
        Task { @MainActor in
            let result = await Task.detached {
                DomeRpcClient.purgeTopicScope(
                    topic: topic,
                    ownerScope: ownerScope,
                    projectID: projectID
                )
            }.value
            purging.remove(topic)
            if let result {
                lastPurge = "Purged \(result.purged) doc\(result.purged == 1 ? "" : "s") from “\(topic)”."
            } else {
                lastPurge = "Couldn't reach the daemon — topic “\(topic)” was not deleted."
            }
            await reload()
        }
    }
}

/// Browse every cached context pack. v0.14 — lets the user inspect
/// what's been compiled into a session pack without spelunking
/// through the daemon directly.
private struct KnowledgePacksSurface: View {
    let domeScope: DomeScopeSelection

    @State private var packs: [DomeRpcClient.ContextPackRow] = []
    @State private var selectedID: String?
    @State private var detail: DomeRpcClient.ContextPackDetail?
    @State private var isLoading = false
    /// v0.17 — set during a delete cascade (DB rows + manifest +
    /// summary on disk) so the row's button can show busy state.
    @State private var deletingID: String?
    /// v0.17 — last-action banner for delete confirmations. Mirrors
    /// the topic surface's `lastPurge` pattern.
    @State private var lastAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(title: "Context Packs", subtitle: "\(packs.count) packs · \(domeScope.label)", isLoading: isLoading) {
                Task { await reload() }
            }
            Divider().overlay(Palette.divider)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if packs.isEmpty {
                            surfaceEmpty(icon: "shippingbox", text: "No context packs cached yet — packs are minted by spawn-pack and `dome_context_compact`.")
                        } else {
                            ForEach(packs) { pack in
                                packRow(pack)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                .background(Palette.surface)
                Divider().overlay(Palette.divider)
                packDetail
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload() }
    }

    private func packRow(_ pack: DomeRpcClient.ContextPackRow) -> some View {
        let isSelected = selectedID == pack.id
        return Button(action: {
            selectedID = pack.id
            loadDetail(pack)
        }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(pack.contextId)
                        .font(Typography.monoCaption)
                        .foregroundStyle(isSelected ? Palette.accent : Palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let intent = pack.intentKey, !intent.isEmpty {
                        Text(intent)
                            .font(Typography.micro)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                HStack(spacing: 6) {
                    if let agent = pack.agentName {
                        Text(agent)
                            .font(Typography.micro)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let brand = pack.brand {
                        Text(brand)
                            .font(Typography.micro)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    if let last = pack.lastReferencedAt {
                        Text(last.prefix(19))
                            .font(Typography.micro)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.surfaceAccentSoft : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var packDetail: some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(detail.contextPack.contextId)
                            .font(Typography.display)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            confirmDelete(pack: detail.contextPack)
                        } label: {
                            if deletingID == detail.contextPack.id {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Label("Delete pack", systemImage: "trash")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(deletingID == detail.contextPack.id)
                        .help("Delete this cached context pack. Source notes stay.")
                    }
                    if let lastAction {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Palette.success)
                            Text(lastAction)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textPrimary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
                    }
                    if let summary = detail.summary, !summary.isEmpty {
                        Text("Summary")
                            .font(Typography.title)
                            .foregroundStyle(Palette.textPrimary)
                        Text(summary)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)
                            .padding(12)
                            .background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
                    }
                    if let json = detail.manifestJSON, json != "null" {
                        Text("Manifest")
                            .font(Typography.title)
                            .foregroundStyle(Palette.textPrimary)
                        ScrollView(.horizontal) {
                            Text(json)
                                .font(Typography.monoCaption)
                                .foregroundStyle(Palette.textSecondary)
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .background(Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
                    }
                    if let sources = detail.sourceReferences, !sources.isEmpty {
                        Text("Sources (\(sources.count))")
                            .font(Typography.title)
                            .foregroundStyle(Palette.textPrimary)
                        ForEach(sources, id: \.self) { src in
                            Text(src)
                                .font(Typography.monoCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                .padding(20)
            }
        } else {
            Text("Pick a pack on the left to see its summary + manifest + sources.")
                .font(Typography.body)
                .foregroundStyle(Palette.textTertiary)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fetched = await Task.detached { () -> [DomeRpcClient.ContextPackRow] in
            DomeRpcClient.contextList(limit: 200)
        }.value
        packs = fetched
        if let id = selectedID, let pack = fetched.first(where: { $0.id == id }) {
            loadDetail(pack)
        }
    }

    private func loadDetail(_ pack: DomeRpcClient.ContextPackRow) {
        let id = pack.id
        Task.detached {
            let result = DomeRpcClient.contextGet(contextID: id)
            await MainActor.run { detail = result }
        }
    }

    /// v0.17 — confirm-before-delete on the cached context pack.
    /// Deletes only the cached envelope (DB row + on-disk manifest +
    /// summary). The original source notes the pack cited stay
    /// intact, so the worst-case undo is "re-run spawn-pack or
    /// `dome_context_compact` to remint the pack". Mirrors the
    /// destructive-action pattern set by the v0.10 codebase-purge
    /// button.
    private func confirmDelete(pack: DomeRpcClient.ContextPackRow) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete context pack “\(pack.contextId)”?"
        alert.informativeText = """
            This removes the cached pack envelope (DB row + manifest + summary file). \
            The original source notes the pack cited remain in the vault. \
            Spawn-pack or `dome_context_compact` will mint a fresh pack on the next agent spawn.
            """
        alert.addButton(withTitle: "Cancel")
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runDelete(pack: pack)
    }

    private func runDelete(pack: DomeRpcClient.ContextPackRow) {
        let id = pack.id
        deletingID = id
        Task { @MainActor in
            let ok = await Task.detached { DomeRpcClient.contextDelete(contextID: id) }.value
            deletingID = nil
            if ok {
                lastAction = "Deleted context pack “\(pack.contextId)”."
                detail = nil
                if selectedID == id { selectedID = nil }
            } else {
                lastAction = "Couldn't delete context pack — daemon might be down."
            }
            await reload()
        }
    }
}

/// Topic tree over every note in the vault.
private struct KnowledgeListSurface: View {
    let domeScope: DomeScopeSelection

    @State private var notes: [DomeRpcClient.NoteSummary] = []
    @State private var expanded: Set<String> = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(title: "Knowledge List", subtitle: "\(notes.count) notes · \(domeScope.label)", isLoading: isLoading) {
                Task { await reload() }
            }
            Divider().overlay(Palette.divider)
            if grouped.isEmpty {
                surfaceEmpty(icon: "square.grid.3x2", text: "No notes in the vault yet.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sortedTopics, id: \.self) { topic in
                            topicRow(topic: topic, items: grouped[topic] ?? [])
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload() }
    }

    private func topicRow(topic: String, items: [DomeRpcClient.NoteSummary]) -> some View {
        let isExpanded = expanded.contains(topic)
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: { toggle(topic) }) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 14)
                    Text(topic)
                        .font(Typography.title)
                        .foregroundStyle(Palette.textPrimary)
                    Text("\(items.count)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { note in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textTertiary)
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                                .font(Typography.body)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                            scopeBadge(note.ownerScope)
                            kindBadge(note.knowledgeKind)
                            Spacer()
                            if let ts = note.updatedAt ?? note.createdAt {
                                Text(Self.rel.localizedString(for: ts, relativeTo: Date()))
                                    .font(Typography.micro)
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                        .padding(.leading, 22)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var grouped: [String: [DomeRpcClient.NoteSummary]] {
        Dictionary(grouping: notes, by: { $0.topic.isEmpty ? "inbox" : $0.topic })
    }

    private var sortedTopics: [String] {
        grouped.keys.sorted()
    }

    private func toggle(_ topic: String) {
        if expanded.contains(topic) {
            expanded.remove(topic)
        } else {
            expanded.insert(topic)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fetched = await Task.detached { () -> [DomeRpcClient.NoteSummary]? in
            DomeRpcClient.listNotes(topic: nil, limit: 500, domeScope: domeScope)
        }.value
        if let fetched {
            notes = fetched.sorted { $0.sortTimestamp > $1.sortTimestamp }
            if expanded.isEmpty, let first = sortedTopics.first {
                expanded.insert(first)
            }
        }
    }

    private func scopeBadge(_ scope: String?) -> some View {
        Text(scope == "project" ? "Project" : "Global")
            .font(Typography.micro)
            .foregroundStyle(scope == "project" ? Palette.warning : Palette.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Palette.surfaceAccentSoft)
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func kindBadge(_ kind: String?) -> some View {
        Text((kind ?? "knowledge").capitalized)
            .font(Typography.micro)
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// **Agent System** (v0.20) — Tado's top-level operator surface for
/// the Dome second-brain daemon. Restructured from a single 1000-line
/// scrolling VStack into four tabs on top of the same data fetches:
///
/// - **Overview** — vault status + scheduler queue + vault health
/// - **Embeddings** — embedding stats + ingest controls + context packs
/// - **Retrieval** — eval (P@5/R@10/nDCG) + retrieval log + context events
/// - **Agents** — Claude Agents table
///
/// A persistent KPI strip sits between the page header and the tabs;
/// a sticky right rail of contextual actions (different per tab)
/// hangs on the right edge. The whole layout mirrors the design's
/// `Agent System` page on Tado's existing dark + ember palette — no
/// new colour tokens, no new RPC methods, no schema changes.
///
/// Audit log (formerly the last section here) relocates to the
/// Calendar surface's new "Audit" tab so the ledger views all live
/// in one place.
private struct KnowledgeSystemSurface: View {
    let domeScope: DomeScopeSelection

    /// Active tab. Persists for the lifetime of the surface; reset
    /// to `.overview` when the user re-enters via the sidebar.
    enum Tab: Hashable {
        case overview, embeddings, retrieval, agents
    }
    @State private var activeTab: Tab = .overview

    @State private var envelope: DomeRpcClient.AgentStatusEnvelope?
    @State private var isLoading = false
    /// P3 hardening — keyed by `pack.contextID`, holds the latest
    /// `ContextPackResult` returned from the live `tado_dome_context_resolve`
    /// /  `tado_dome_context_compact` FFI calls so the row can render
    /// citation chains without a full reload of the envelope.
    @State private var packResults: [String: ContextPackResult] = [:]
    @State private var packBusy: Set<String> = []
    @State private var packError: String? = nil

    /// Live snapshot of `note_chunks` row counts grouped by embedding
    /// model. Re-fetched after Bootstrap or Ingest finishes so the
    /// "Embeddings" panel reflects the latest state without a full
    /// envelope reload.
    @State private var embeddingStats: DomeRpcClient.EmbeddingStats?
    @State private var bootstrapBusy = false
    @State private var ingestBusy = false
    @State private var lastIngest: DomeRpcClient.IngestResult?
    @State private var ingestProgress: DomeRpcClient.IngestProgress?

    /// Operator cleanup state for the "Clear globally-ingested
    /// codebases" button. `purgeGlobalCount` is refreshed on scope
    /// changes + after every ingest/purge so the button label tracks
    /// the live row count without manual reload.
    @State private var purgeBusy = false
    @State private var purgeGlobalCount: Int?

    /// Phase 2 — recent rows from `retrieval_log`. Refreshed on the
    /// same `reload` tick as the agent-status envelope.
    @State private var retrievalLog: DomeRpcClient.RetrievalLogEnvelope?

    /// Phase 3 — enrichment queue depth for the backfill chip in the
    /// system header. Polled alongside `retrievalLog`; the chip shows
    /// `queued + running` and hides when both are zero.
    @State private var queueDepth: DomeRpcClient.EnrichmentQueueDepth?

    /// v0.12 — system observability + eval. Each is fetched alongside
    /// the existing `reload()` tick so the System surface stays a
    /// single round trip (parallel awaits). Audit moved to Calendar
    /// in v0.20 — auditRows + auditFilter no longer live here.
    @State private var systemHealth: DomeRpcClient.SystemHealth?
    @State private var automationStatus: DomeRpcClient.AutomationStatus?
    @State private var lastEvalReport: DomeRpcClient.EvalReplayReport?
    @State private var evalRunning = false
    @State private var evalWindowSeconds: Int = 86_400 // last 24h default

    /// Retrieval log filter — empty string means "show all". Free-text
    /// substring match against `tool` and `query` columns.
    @State private var retrievalFilter: String = ""

    /// v0.13 — vault status snapshot + import wizard sheet state.
    @State private var vaultStatus: DomeRpcClient.VaultStatus?
    @State private var showImportWizard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(
                title: "Agent System",
                subtitle: "\(systemSubtitle) · \(domeScope.label)",
                isLoading: isLoading
            ) {
                Task { await reload() }
            }

            // KPI strip — always visible. Auto-fits 6 tiles into the
            // available width; collapses cleanly on a narrow window.
            KpiStrip(kpiTiles)
                .padding(.horizontal, DK.pageGutter)
                .padding(.top, 16)
                .padding(.bottom, 18)
                .background(Palette.bgPage)

            TabsStrip(tabs: tabsItems, selection: $activeTab)

            // Main + right rail.
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let depth = queueDepth, !depth.idle {
                            backfillChip(depth)
                        }
                        switch activeTab {
                        case .overview:   overviewTab
                        case .embeddings: embeddingsTab
                        case .retrieval:  retrievalTab
                        case .agents:     agentsTab
                        }
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, DK.pageGutter)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                RightRail(groups: railGroups)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.bgPage)
        .task(id: domeScope.id) { await reload() }
        .task { embeddingStats = DomeRpcClient.embeddingStats() }
    }

    // MARK: - KPI strip

    /// Six tiles, in scan order:
    ///   1. chunks indexed (lead, accent value)
    ///   2. docs · topics
    ///   3. p@5 · retrieval
    ///   4. avg latency
    ///   5. agents active
    ///   6. queue (ready / sched / active)
    private var kpiTiles: [KpiTile] {
        [
            KpiTile(
                label: "chunks indexed",
                value: kpiChunksValue,
                sub: kpiChunksSub,
                lead: true,
                accent: true
            ),
            KpiTile(
                label: "docs · topics",
                value: kpiDocsTopicsValue,
                sub: domeScope.label
            ),
            KpiTile(
                label: "p@5 · retrieval",
                value: kpiPrecisionValue,
                sub: lastEvalReport == nil ? "run eval to populate" : "last \(kpiEvalWindowLabel)"
            ),
            KpiTile(
                label: "avg latency",
                value: kpiLatencyValue,
                sub: kpiLatencySub
            ),
            KpiTile(
                label: "agents active",
                value: kpiAgentsValue,
                sub: kpiAgentsSub
            ),
            KpiTile(
                label: "queue",
                value: kpiQueueValue,
                sub: "ready · sched · active"
            ),
        ]
    }

    private var kpiChunksValue: String {
        guard let total = embeddingStats?.total else { return "—" }
        return total.formatted()
    }
    private var kpiChunksSub: String {
        guard let stats = embeddingStats, !stats.modelCounts.isEmpty else {
            return "no embeddings yet"
        }
        let leading = stats.modelCounts.max(by: { $0.value < $1.value })?.key ?? "qwen3-embedding"
        return "model · \(leading)"
    }
    private var kpiDocsTopicsValue: String {
        guard let s = vaultStatus else { return "— / —" }
        return "\(s.docCount) / \(s.topicsCount)"
    }
    private var kpiPrecisionValue: String {
        guard let report = lastEvalReport, report.nRows > 0 else { return "—" }
        return String(format: "%.2f", report.aggregate.precisionAt5)
    }
    private var kpiEvalWindowLabel: String {
        switch evalWindowSeconds {
        case 0: return "all-time"
        case 3_600: return "1h"
        case 86_400: return "24h"
        case 604_800: return "7 days"
        default: return "window"
        }
    }
    private var kpiLatencyValue: String {
        guard let log = retrievalLog, log.n > 0 else { return "—" }
        return String(format: "%.0fms", log.meanLatencyMs)
    }
    private var kpiLatencySub: String {
        guard let log = retrievalLog, log.n > 0 else { return "no calls logged" }
        return "last \(log.n) calls"
    }
    private var kpiAgentsValue: String {
        guard let envelope else { return "—" }
        let total = envelope.statuses.count
        return "\(total)"
    }
    private var kpiAgentsSub: String {
        guard let envelope, !envelope.statuses.isEmpty else { return "no snapshots yet" }
        let totalCost = envelope.statuses.compactMap { $0.costUSD }.reduce(0, +)
        return String(format: "$%.2f total", totalCost)
    }
    private var kpiQueueValue: String {
        guard let s = automationStatus else { return "— / — / —" }
        return "\(s.queueDepth.ready) / \(s.queueDepth.scheduled) / \(s.queueDepth.active)"
    }

    // MARK: - Tabs

    private var tabsItems: [TabsStrip<Tab>.Tab] {
        [
            TabsStrip<Tab>.Tab(id: .overview,   label: "Overview"),
            TabsStrip<Tab>.Tab(id: .embeddings, label: "Embeddings", count: embeddingStats?.total.formatted()),
            TabsStrip<Tab>.Tab(id: .retrieval,  label: "Retrieval",  count: retrievalLog.map { "\($0.n)" }),
            TabsStrip<Tab>.Tab(id: .agents,     label: "Agents",     count: envelope.map { "\($0.statuses.count)" }),
        ]
    }

    // MARK: - Tab content

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            vaultStatusSection
            schedulerSection
            healthSection
        }
    }

    private var embeddingsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            embeddingsSection
            contextPackSection
        }
    }

    private var retrievalTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            evalSection
            retrievalLogSection
            retrievalSection
        }
    }

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            statusSection
        }
    }

    // MARK: - Right rail

    private var railGroups: [RailGroup] {
        switch activeTab {
        case .overview:
            return overviewRailGroups
        case .embeddings:
            return embeddingsRailGroups
        case .retrieval:
            return retrievalRailGroups
        case .agents:
            return agentsRailGroups
        }
    }

    private var overviewRailGroups: [RailGroup] {
        [
            RailGroup("vault", actions: [
                RailAction("Open in Finder", icon: "arrow.up.right.square", action: openVaultInFinder),
                RailAction("Snapshot vault", icon: "tray.and.arrow.down", action: snapshotVault),
                RailAction("Bulk import…", icon: "square.and.arrow.down", action: { showImportWizard = true }),
            ]),
            RailGroup("system", actions: [
                RailAction("View logs", icon: "doc.text.magnifyingglass", action: openLogsInFinder),
                RailAction("Restart daemon", icon: "arrow.clockwise.circle", isDisabled: true, action: { /* not yet wired */ }),
            ]),
        ]
    }

    private var embeddingsRailGroups: [RailGroup] {
        var groups: [RailGroup] = [
            RailGroup("embeddings", actions: [
                RailAction(
                    "Bootstrap vectors",
                    icon: "wand.and.stars",
                    isDisabled: bootstrapBusy || ingestBusy || purgeBusy,
                    action: runBootstrap
                ),
                RailAction(
                    "Ingest codebase",
                    icon: "square.and.arrow.down",
                    variant: .primary,
                    isDisabled: bootstrapBusy || ingestBusy || purgeBusy,
                    action: runIngest
                ),
            ]),
            RailGroup("context packs", actions: [
                RailAction("Compact pack…", icon: "square.compress.vertical", isDisabled: true, action: { /* per-row only */ }),
                RailAction("Browse packs", icon: "shippingbox", action: { /* future: link to Knowledge → Packs */ }),
            ]),
        ]
        if let count = purgeGlobalCount, count > 0 {
            groups.append(
                RailGroup("danger zone", actions: [
                    RailAction(
                        "Clear ingested (\(count))",
                        icon: "trash",
                        variant: .danger,
                        isDisabled: bootstrapBusy || ingestBusy || purgeBusy,
                        action: { runPurgeGlobalCodebases(count: count) }
                    ),
                ])
            )
        }
        return groups
    }

    private var retrievalRailGroups: [RailGroup] {
        [
            RailGroup("eval", actions: [
                RailAction(
                    "Run eval",
                    icon: "play.fill",
                    variant: .primary,
                    kbd: "⌘R",
                    isDisabled: evalRunning,
                    action: runEval
                ),
                RailAction("Replay window…", icon: "backward.end", isDisabled: true, action: { /* picker is inline */ }),
                RailAction("Export log", icon: "square.and.arrow.up", isDisabled: true, action: { /* future */ }),
            ]),
            RailGroup("filters", actions: [
                RailAction("Show consumed only", icon: "checkmark.circle", isDisabled: true, action: { /* future */ }),
                RailAction("Slow queries (>500ms)", icon: "clock.badge.exclamationmark", isDisabled: true, action: { /* future */ }),
            ]),
        ]
    }

    private var agentsRailGroups: [RailGroup] {
        [
            RailGroup("agents", actions: [
                RailAction("Spawn agent", icon: "plus.circle", variant: .primary, kbd: "⌘N", isDisabled: true, action: { /* future */ }),
                RailAction("Pause all idle", icon: "pause.circle", isDisabled: true, action: { /* future */ }),
                RailAction("Export usage", icon: "square.and.arrow.up", isDisabled: true, action: { /* future */ }),
            ]),
            RailGroup("budget", actions: [
                RailAction("Set hourly cap", icon: "dollarsign.circle", isDisabled: true, action: { /* future */ }),
                RailAction("Cost report", icon: "chart.bar", isDisabled: true, action: { /* future */ }),
            ]),
        ]
    }

    // MARK: - Rail actions

    private func openVaultInFinder() {
        if let path = vaultStatus?.vaultPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func snapshotVault() {
        Task.detached { _ = BackupManager.createBackup(reason: "manual-from-system") }
    }

    private func openLogsInFinder() {
        let dir = StorePaths.eventsCurrent.deletingLastPathComponent().path
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    // MARK: - v0.13 Vault status

    // MARK: - Overview tab — Vault status

    /// Vault status — 4-cell card. Actions live in the right rail
    /// now (Open in Finder · Snapshot vault · Bulk import…).
    private var vaultStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(eyebrow: "vault", title: "Vault status")
            if let s = vaultStatus {
                vaultStatusCard(s)
            } else {
                emptyCard("Vault status pending — click refresh to populate.")
            }
        }
        .sheet(isPresented: $showImportWizard) {
            ImportWizard(
                domeScope: domeScope,
                onClose: {
                    showImportWizard = false
                    Task { await reload() }
                }
            )
        }
    }

    private func vaultStatusCard(_ s: DomeRpcClient.VaultStatus) -> some View {
        HStack(alignment: .top, spacing: 0) {
            metaCell(label: "docs", value: "\(s.docCount)")
            CellDivider()
            metaCell(label: "topics", value: "\(s.topicsCount)")
            CellDivider()
            metaCell(label: "vault path", value: shortenPath(s.vaultPath), monoValue: true)
            CellDivider()
            metaCell(label: "socket", value: shortenPath(s.socketPath), monoValue: true)
        }
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func metaCell(label: String, value: String, monoValue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Palette.ink4)
            if monoValue {
                Text(value)
                    .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
            } else {
                Text(value)
                    .font(Font.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Overview tab — Scheduler queue

    /// Scheduler queue — 4 large numerals card (ready / scheduled /
    /// active / stale leases). Active is accent-tinted.
    private var schedulerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(eyebrow: "health", title: "Scheduler queue") {
                Text("refreshed live")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
            }
            if let s = automationStatus {
                schedulerCard(s)
                if s.staleLeases > 0 {
                    Text("\(s.staleLeases) stale leases. Check Activity → Audit.")
                        .font(Font.system(size: 11, weight: .regular))
                        .foregroundStyle(Palette.danger)
                }
            } else {
                emptyCard("No scheduler snapshot yet.")
            }
        }
    }

    private func schedulerCard(_ s: DomeRpcClient.AutomationStatus) -> some View {
        HStack(alignment: .top, spacing: 0) {
            queueCell("Ready", value: s.queueDepth.ready, accent: false)
            CellDivider()
            queueCell("Scheduled", value: s.queueDepth.scheduled, accent: false)
            CellDivider()
            queueCell("Active", value: s.queueDepth.active, accent: s.queueDepth.active > 0)
            CellDivider()
            queueCell("Stale leases", value: s.staleLeases, accent: false, danger: s.staleLeases > 0)
        }
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func queueCell(_ label: String, value: Int, accent: Bool, danger: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Palette.ink4)
            Text("\(value)")
                .font(Font.system(size: 32, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(danger ? Palette.danger : (accent ? Palette.accent : Palette.ink))
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Overview tab — Vault health

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(eyebrow: "diagnostics", title: "Vault health")
            if let health = systemHealth, !health.checks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(health.checks.enumerated()), id: \.offset) { i, check in
                        healthRow(check)
                        if i < health.checks.count - 1 {
                            Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                        }
                    }
                }
                .background(Palette.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
                if !health.dbOk {
                    Text("SQLite open failed — check daemon log + filesystem permissions.")
                        .font(Font.system(size: 11, weight: .regular))
                        .foregroundStyle(Palette.danger)
                }
            } else {
                emptyCard("Health snapshot pending — refresh to check.")
            }
        }
    }

    private func healthRow(_ check: DomeRpcClient.SystemHealthCheck) -> some View {
        HStack(spacing: 10) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.ok ? Palette.green : Palette.danger)
                .font(.system(size: 13))
            Text(check.name)
                .font(Font.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
            Spacer()
            if let detail = check.detail {
                Text(detail)
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            StatusPill(check.ok ? "ok" : "fail", variant: check.ok ? .running : .danger)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Retrieval tab — eval

    /// Retrieval quality (eval) section. The Run-eval button has
    /// moved to the right rail (with the ⌘R shortcut); this section
    /// keeps the inline window picker so the operator can change
    /// scope without leaving the result card.
    private var evalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                eyebrow: "quality",
                title: "Retrieval quality",
                sub: "dome-eval replay against the chosen window"
            ) {
                HStack(spacing: 8) {
                    Picker("Window", selection: $evalWindowSeconds) {
                        Text("Last 1h").tag(3_600)
                        Text("Last 24h").tag(86_400)
                        Text("Last 7 days").tag(604_800)
                        Text("All time").tag(0)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .disabled(evalRunning)
                }
            }
            evalCard
        }
    }

    private var evalCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                evalCellLeading("P@5", value: evalP5, sub: "precision at 5")
                CellDivider()
                evalCellLeading("R@10", value: evalR10, sub: "recall at 10")
                CellDivider()
                evalCellLeading("nDCG", value: evalNDCG, sub: "normalized DCG")
            }
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            HStack(spacing: 16) {
                Text(evalCardCaption)
                    .font(Font.system(size: 11, weight: .regular))
                    .foregroundStyle(Palette.ink3)
                Spacer(minLength: 8)
                if let report = lastEvalReport {
                    Text("\(report.nRows) rows")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                    Text("· \(Int(report.consumptionRate * 100))% consumed")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                    Text("· \(Int(report.meanLatencyMs)) ms avg")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func evalCellLeading(_ label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Palette.ink4)
            Text(value)
                .font(Font.system(size: 32, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
            Text(sub)
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var evalP5: String {
        guard let r = lastEvalReport, r.nRows > 0 else { return "—" }
        return String(format: "%.2f", r.aggregate.precisionAt5)
    }
    private var evalR10: String {
        guard let r = lastEvalReport, r.nRows > 0 else { return "—" }
        return String(format: "%.2f", r.aggregate.recallAt10)
    }
    private var evalNDCG: String {
        guard let r = lastEvalReport, r.nRows > 0 else { return "—" }
        return String(format: "%.2f", r.aggregate.ndcgAt10)
    }
    private var evalCardCaption: String {
        if let r = lastEvalReport, r.nRows == 0 {
            return "No retrieval-log rows in this window. Run dome_search a few times (or invoke a recipe) and rerun."
        }
        if lastEvalReport == nil {
            return "Run eval (⌘R, right rail) to score retrieval quality across the chosen window. P@5 / R@10 / nDCG come from the consumed-vs-not signal stored on every retrieval_log row."
        }
        return "Aggregate metrics from the latest replay over the chosen window."
    }

    private func runEval() {
        evalRunning = true
        let seconds = evalWindowSeconds
        Task.detached {
            let report = DomeRpcClient.evalReplay(sinceSeconds: seconds)
            await MainActor.run {
                evalRunning = false
                lastEvalReport = report
            }
        }
    }

    // MARK: - Reusable empty card

    private func emptyCard(_ message: String) -> some View {
        Text(message)
            .font(Font.system(size: 12, weight: .regular))
            .foregroundStyle(Palette.ink3)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    // Audit log moved to Calendar → Audit tab in v0.20.

    // MARK: - Agents tab — Claude Agents table

    /// Compact table of every Claude Agent the daemon has seen
    /// recently — one row per `tado_session`, showing model, ctx %,
    /// usage meter, tokens, cost. Clicking a row in a future revision
    /// will open the agent's transcript; for now they're read-only.
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                eyebrow: "active",
                title: "Claude Agents",
                count: envelope.map { "\($0.statuses.count) sessions" },
                sub: agentsSummarySub
            )
            if let statuses = envelope?.statuses, !statuses.isEmpty {
                agentsTable(statuses)
            } else {
                emptyCard("No status-line snapshots yet. Spawn a Claude Code agent and the statusLine script will populate this list.")
            }
        }
    }

    private var agentsSummarySub: String? {
        guard let envelope, !envelope.statuses.isEmpty else { return nil }
        let totalTokens = envelope.statuses.compactMap { $0.inputTokens }.reduce(0, +)
        let totalCost = envelope.statuses.compactMap { $0.costUSD }.reduce(0, +)
        return "\(totalTokens.formatted()) tokens · $\(String(format: "%.2f", totalCost)) total cost"
    }

    private func agentsTable(_ statuses: [DomeRpcClient.AgentStatusSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("AGENT · PROJECT")
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("MODEL")
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink4)
                    .frame(width: 100, alignment: .leading)
                Text("CTX")
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink4)
                    .frame(width: 60, alignment: .trailing)
                Text("USAGE")
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink4)
                    .frame(width: 110, alignment: .leading)
                Text("TOKENS")
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink4)
                    .frame(width: 80, alignment: .trailing)
                Text("COST")
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink4)
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Palette.bgPage)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }

            ForEach(statuses) { status in
                agentRow(status)
                Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
            }
        }
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func agentRow(_ status: DomeRpcClient.AgentStatusSnapshot) -> some View {
        let ctx = Int(status.contextUsedPercent ?? 0)
        let isActive = ctx > 0 // proxy for "currently running"
        let usageColor: Color = ctx > 75 ? Palette.danger : (ctx > 50 ? Palette.warning : Palette.accent)
        return HStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isActive ? Palette.accent : Palette.ink4)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.agentName ?? "claude")
                        .font(Font.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text([status.projectName, status.retrievalFreshness].compactMap { $0 }.joined(separator: " · "))
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(status.modelDisplayName ?? "—")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)

            Text("\(ctx)%")
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
                .frame(width: 60, alignment: .trailing)

            // Usage meter
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.bgRowHi)
                    .frame(height: 4)
                Capsule()
                    .fill(usageColor)
                    .frame(width: max(2, CGFloat(min(ctx, 100)) / 100 * 100), height: 4)
            }
            .frame(width: 100)
            .padding(.horizontal, 5)
            .frame(width: 110, alignment: .leading)

            Text(formatTokens(status.inputTokens))
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
                .frame(width: 80, alignment: .trailing)

            Text(String(format: "$%.2f", status.costUSD ?? 0))
                .font(Font.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatTokens(_ tokens: Int?) -> String {
        guard let t = tokens else { return "—" }
        if t < 1000 { return "\(t)" }
        return String(format: "%.1fk", Double(t) / 1000.0)
    }

    // MARK: - Embeddings tab

    /// Embeddings panel — total chunks accent display + per-model
    /// breakdown + last-ingest line. Bootstrap / Ingest / cleanup
    /// actions live in the right rail now; this card is read-only
    /// status. The ingest-busy progress bar still lives here so the
    /// operator can see "47 / 290 files" while a walk is in flight.
    private var embeddingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                eyebrow: "index",
                title: "Embeddings",
                sub: embeddingsSubtitle
            )
            embeddingsCard
            // Live progress + last result, only when relevant.
            if ingestBusy, let p = ingestProgress, p.total > 0 {
                ingestProgressCard(p)
            }
            if let r = lastIngest {
                ingestResultLine(r)
            }
        }
        .task(id: ingestBusy) { await pollIngestProgress() }
        .task(id: domeScope.id) { refreshPurgeGlobalCount() }
    }

    private var embeddingsSubtitle: String {
        let leading = embeddingStats?.modelCounts.max(by: { $0.value < $1.value })?.key
            ?? "qwen3-embedding-0.6b@1"
        return "\(leading) · \(domeScope.label) scope"
    }

    private var embeddingsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TOTAL CHUNKS")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                    Text(embeddingStats?.total.formatted() ?? "—")
                        .font(Font.system(size: 32, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Palette.accent)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("CODEBASES INGESTED")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                    Text(purgeGlobalCount.map(String.init) ?? "—")
                        .font(Font.system(size: 32, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("SCOPE TARGET")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                    Text(domeScope.label.uppercased())
                        .font(Font.system(size: 18, weight: .semibold))
                        .foregroundStyle(domeScope.ownerScope == "global" ? Palette.warning : Palette.ink)
                }
                Spacer(minLength: 0)
            }

            if let stats = embeddingStats, !stats.modelCounts.isEmpty {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODEL BREAKDOWN")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                    ForEach(stats.modelCounts.sorted(by: { $0.value > $1.value }), id: \.key) { model, count in
                        HStack {
                            Text(model)
                                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Palette.ink2)
                            Spacer()
                            Text("\(count.formatted()) chunks")
                                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Palette.ink3)
                                .monospacedDigit()
                        }
                    }
                }
            }
            // Scope-target chip — visible always so the operator knows
            // where the next Ingest click will land.
            Text(scopeTargetChipText)
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(domeScope.ownerScope == "global" ? Palette.warning : Palette.ink4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func ingestProgressCard(_ p: DomeRpcClient.IngestProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ingestButtonLabel)
                    .font(Font.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer()
                OutlineButton(
                    "Cancel",
                    size: .small,
                    variant: .danger,
                    action: { DomeRpcClient.ingestCancel() }
                )
                .help("Stop the in-flight ingest at the next file boundary. Files already created are kept.")
            }
            ProgressView(value: p.fraction)
                .progressViewStyle(.linear)
                .tint(Palette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.accentSoft, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private func ingestResultLine(_ r: DomeRpcClient.IngestResult) -> some View {
        let suffix: String = r.capped
            ? " (capped at 5000 files)"
            : ((r.canceled ?? false) ? " (canceled)" : "")
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.green)
                .font(.system(size: 11))
            Text("Created \(r.created), skipped \(r.skipped)\(suffix)")
                .font(Font.system(size: 11, weight: .regular))
                .foregroundStyle(Palette.ink2)
        }
    }

    /// One-line chip beneath the Ingest button explaining where the
    /// files will land. Loud-on-Global because that's the historical
    /// foot-gun.
    private var scopeTargetChipText: String {
        switch domeScope {
        case .global:
            return "Files will land in the Global scope (visible to every project)."
        case .project(_, let name, _, _):
            return "Files will land in project: \(name)."
        }
    }

    /// "Ingesting… N / M" while a count is known, otherwise the bare
    /// label. Updates every ~1s via the polling task.
    private var ingestButtonLabel: String {
        guard let p = ingestProgress, p.running else { return "Ingesting…" }
        if p.total > 0 {
            return "Ingesting… \(p.created) / \(p.total)"
        }
        return "Ingesting… \(p.created)"
    }

    /// Poll the FFI for live ingest counters while `ingestBusy` is
    /// true. Cooperatively cancels when the View task is invalidated
    /// (which happens when `ingestBusy` flips back to false).
    private func pollIngestProgress() async {
        guard ingestBusy else {
            ingestProgress = nil
            return
        }
        while ingestBusy {
            if Task.isCancelled { return }
            ingestProgress = DomeRpcClient.ingestProgress()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func runBootstrap() {
        bootstrapBusy = true
        Task.detached {
            _ = DomeRpcClient.vaultReindex()
            let fresh = DomeRpcClient.embeddingStats()
            await MainActor.run {
                bootstrapBusy = false
                embeddingStats = fresh
            }
        }
    }

    private func runIngest() {
        // Make accidental Global ingestion explicitly opt-in. The
        // historical foot-gun is "open the System surface, click
        // Ingest, pick a folder" — which silently lands files in the
        // Global scope because that's the picker's default. Surface a
        // confirm dialog so the operator knows what they're doing.
        if domeScope.ownerScope == "global" {
            let alert = NSAlert()
            alert.messageText = "Ingest into the Global scope?"
            alert.informativeText = "Files will be visible to every project. Switch the scope picker to a specific project first if you want this codebase scoped to one project."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Ingest globally anyway")
            // Default button is the first one added → Cancel. The
            // dangerous button is opt-in.
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ingest"
        // Pre-fill the panel with the project root when scoped — saves
        // operator clicks and discourages cross-project ingestion.
        if let projectRoot = domeScope.projectRoot {
            panel.directoryURL = URL(fileURLWithPath: projectRoot)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scope = domeScope
        ingestBusy = true
        Task.detached {
            let result = DomeRpcClient.ingestPath(url.path, topic: "codebase", domeScope: scope)
            let fresh = DomeRpcClient.embeddingStats()
            await MainActor.run {
                ingestBusy = false
                lastIngest = result
                embeddingStats = fresh
                refreshPurgeGlobalCount()
            }
        }
    }

    /// Re-fetches the count of `(topic='codebase', owner_scope='global',
    /// project_id NULL)` rows so the cleanup button label stays in sync.
    /// Read-only, cheap (one COUNT(*) over an indexed column).
    private func refreshPurgeGlobalCount() {
        Task.detached {
            let value = DomeRpcClient.purgeTopicScopeCount(
                topic: "codebase", ownerScope: "global", projectID: nil
            )
            await MainActor.run {
                purgeGlobalCount = value?.count
            }
        }
    }

    /// Confirm + snapshot + purge. Three guard rails:
    /// 1. NSAlert with destructive style so the operator can't no-op
    ///    through it accidentally.
    /// 2. `BackupManager.createBackup(reason:)` before the purge so the
    ///    work is recoverable from Settings → Storage → Backups.
    /// 3. The actual call goes through the trusted-mutator daemon so
    ///    the audit log records who did what.
    private func runPurgeGlobalCodebases(count: Int) {
        let alert = NSAlert()
        alert.messageText = "Delete \(count) globally-ingested codebase files?"
        alert.informativeText = "Removes every doc with topic='codebase' at the Global scope, plus their note chunks, graph nodes, edges, and on-disk folders. A backup snapshot is taken first — restore via Settings → Storage → Backups if needed."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete \(count) docs")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        purgeBusy = true
        Task.detached {
            // Snapshot first; ignore failures so a stuck snapshot doesn't
            // block the cleanup the operator is asking for. The snapshot
            // is a nice-to-have safety net, not a hard precondition.
            _ = BackupManager.createBackup(reason: "pre-codebase-purge")

            let result = DomeRpcClient.purgeTopicScope(
                topic: "codebase", ownerScope: "global", projectID: nil
            )
            let fresh = DomeRpcClient.embeddingStats()
            await MainActor.run {
                purgeBusy = false
                embeddingStats = fresh
                if let result {
                    purgeGlobalCount = max(0, (purgeGlobalCount ?? result.purged) - result.purged)
                } else {
                    refreshPurgeGlobalCount()
                }
            }
        }
    }

    /// Context Packs — list of compacted packs the daemon has minted.
    /// Each row shows brand · status · token estimate · citation
    /// count, with Resolve / Compact actions per row.
    private var contextPackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                eyebrow: "packs",
                title: "Context Packs",
                count: envelope?.contextPacks.isEmpty == false ? "\(envelope?.contextPacks.count ?? 0) packs" : nil
            )
            if let err = packError {
                Text(err)
                    .font(Font.system(size: 11, weight: .regular))
                    .foregroundStyle(Palette.danger)
            }
            if let packs = envelope?.contextPacks, !packs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(packs) { pack in
                        contextPackRow(pack)
                        if let resolved = packResults[pack.contextID] {
                            citationsList(for: resolved)
                                .padding(.leading, 32)
                                .padding(.trailing, 16)
                                .padding(.bottom, 12)
                        }
                        Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                    }
                }
                .background(Palette.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            } else {
                emptyCard("No context packs have been compacted yet. Compaction merges hot chunks into a denser, faster pack.")
            }
        }
    }

    private func contextPackRow(_ pack: DomeRpcClient.ContextPackSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .foregroundStyle(Palette.warning)
                .font(.system(size: 13))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.contextID)
                    .font(Font.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(pack.brand) · \(pack.status) · \(pack.tokenEstimate ?? 0) tokens · \(pack.citationCount ?? 0) citations")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
            if packBusy.contains(pack.contextID) {
                ProgressView().controlSize(.small)
            } else {
                OutlineButton("Resolve", size: .small, variant: .standard) {
                    Task { await resolvePack(pack) }
                }
                .accessibilityLabel("Resolve context pack \(pack.contextID)")
                OutlineButton("Compact", size: .small, variant: .accent) {
                    Task { await compactPack(pack, force: true) }
                }
                .accessibilityLabel("Compact context pack \(pack.contextID)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func citationsList(for result: ContextPackResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sources = result.sourceReferences, !sources.isEmpty {
                ForEach(sources) { source in
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.ink4)
                        Text(source.title ?? source.sourceRef)
                            .font(Font.system(size: 11, weight: .regular))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(1)
                        if let link = ContextPackDeepLink.sourceLink(for: source) {
                            Button(action: {
                                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                            }) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Palette.ink3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Jump to \(source.title ?? source.sourceRef)")
                        }
                        Spacer()
                    }
                }
            } else if result.resolved {
                Text("Pack resolved · no citations recorded.")
                    .font(Font.system(size: 11, weight: .regular))
                    .foregroundStyle(Palette.ink4)
            } else if let next = result.recommendedNextSteps?.first {
                Text(next)
                    .font(Font.system(size: 11, weight: .regular))
                    .foregroundStyle(Palette.warning)
            }
        }
    }

    @MainActor
    private func resolvePack(_ pack: DomeRpcClient.ContextPackSummary) async {
        packBusy.insert(pack.contextID)
        defer { packBusy.remove(pack.contextID) }
        packError = nil
        let result = await Task.detached { () -> ContextPackResult? in
            DomeRpcClient.contextResolve(
                brand: pack.brand,
                sessionID: pack.sessionID,
                docID: pack.docID,
                mode: "compact"
            )
        }.value
        if let result {
            packResults[pack.contextID] = result
        } else {
            packError = "Resolve failed (daemon offline?)"
        }
    }

    @MainActor
    private func compactPack(_ pack: DomeRpcClient.ContextPackSummary, force: Bool) async {
        packBusy.insert(pack.contextID)
        defer { packBusy.remove(pack.contextID) }
        packError = nil
        let result = await Task.detached { () -> ContextPackResult? in
            DomeRpcClient.contextCompact(
                brand: pack.brand,
                sessionID: pack.sessionID,
                docID: pack.docID,
                force: force
            )
        }.value
        if let result {
            packResults[pack.contextID] = result
            // A successful compact mints a fresh manifest; reload the
            // envelope so token estimates and citation counts catch
            // up without forcing the user to hit refresh.
            await reload()
        } else {
            packError = "Compact failed — needs a session_id or doc_id."
        }
    }

    /// Retrieval Events — bottom of the Retrieval tab. Shows context
    /// use vs. skipped-retrieval warnings emitted by the daemon as
    /// agents consume packs. Distinct from the Retrieval Log above
    /// (which records the search query); these are *consumption*
    /// signals.
    private var retrievalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                eyebrow: "events",
                title: "Retrieval Events",
                count: envelope?.contextEvents.isEmpty == false ? "\(envelope?.contextEvents.count ?? 0) events" : nil,
                sub: "context_used vs context_skipped signals from agents"
            )
            if let events = envelope?.contextEvents, !events.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        retrievalEventRow(event)
                        Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                    }
                }
                .background(Palette.bgElev)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            } else {
                emptyCard("Dome has not recorded context use or skipped-retrieval warnings yet.")
            }
        }
    }

    private func retrievalEventRow(_ event: DomeRpcClient.AgentContextEvent) -> some View {
        HStack(spacing: 12) {
            let isSkipped = event.eventKind.contains("skipped")
            Image(systemName: isSkipped ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isSkipped ? Palette.danger : Palette.green)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(event.eventKind)
                    .font(Font.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text([event.agentName, event.contextID, event.reason].compactMap { $0 }.joined(separator: " · "))
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var systemSubtitle: String {
        let count = envelope?.statuses.count ?? 0
        let total = embeddingStats?.total ?? 0
        return "\(count) snapshots · \(total.formatted()) chunks"
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let scope = domeScope
        async let agentTask = Task.detached { DomeRpcClient.agentStatus(limit: 80, domeScope: scope) }.value
        async let logTask = Task.detached {
            DomeRpcClient.retrievalLogRecent(
                limit: 50,
                projectID: scope.projectIDString,
                tool: nil
            )
        }.value
        async let queueTask = Task.detached {
            DomeRpcClient.enrichmentQueueDepth()
        }.value
        // v0.12 — system observability. Audit moved to Calendar in
        // v0.20. Each fetch is independent so we kick them off in
        // parallel with the existing reads.
        async let healthTask = Task.detached {
            DomeRpcClient.systemHealth()
        }.value
        async let schedulerTask = Task.detached {
            DomeRpcClient.systemAutomationStatus()
        }.value
        async let vaultStatusTask = Task.detached {
            DomeRpcClient.vaultStatus()
        }.value
        let fetched = await agentTask
        let log = await logTask
        queueDepth = await queueTask
        systemHealth = await healthTask
        automationStatus = await schedulerTask
        vaultStatus = await vaultStatusTask
        if let fetched {
            envelope = fetched
            // After a Compact mints a new pack the old contextID is
            // gone from the envelope; drop stale cache entries so the
            // citations panel doesn't render under packs that no
            // longer exist.
            let liveIDs = Set((fetched.contextPacks).map(\.contextID))
            packResults = packResults.filter { liveIDs.contains($0.key) }
        }
        retrievalLog = log
    }

    /// Backfill chip. Visible whenever the enrichment queue has any
    /// queued or running jobs. Hides as soon as the pipeline is idle
    /// (queued+running = 0). Displays raw counts so users can see the
    /// drain progressing without polling logs.
    private func backfillChip(_ depth: DomeRpcClient.EnrichmentQueueDepth) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Enrichment running")
                    .font(Font.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                let parts = [
                    "\(depth.queued) queued",
                    "\(depth.running) running",
                    "\(depth.done) done",
                    depth.failed > 0 ? "\(depth.failed) failed" : nil,
                ].compactMap { $0 }
                Text(parts.joined(separator: " · "))
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.accentSoft, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    /// Retrieval Log — table of recent `retrieval_log` rows. Header
    /// carries the consumption rate (fraction of logged calls whose
    /// pack was actually consumed via an `agent_used_context` event)
    /// and mean latency. Rows show status dot + tool · query + kind
    /// + scope + hits + latency.
    private var retrievalLogSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                eyebrow: "log",
                title: "Retrieval Log",
                count: retrievalLog.map { "\($0.n) rows" },
                sub: retrievalLogSubtitle
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Palette.ink4)
                        .font(.system(size: 11))
                    TextField("filter by tool or query…", text: $retrievalFilter)
                        .textFieldStyle(.plain)
                        .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 200)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Palette.bgPage)
                .overlay(
                    RoundedRectangle(cornerRadius: DK.radius)
                        .stroke(Palette.rule, lineWidth: DK.ruleW)
                )
                .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            }
            retrievalLogTable
        }
    }

    private var retrievalLogSubtitle: String? {
        guard let log = retrievalLog, log.n > 0 else { return nil }
        return "\(Int(log.consumptionRate * 100))% consumed · avg \(Int(log.meanLatencyMs)) ms"
    }

    private var filteredRetrievalRows: [DomeRpcClient.RetrievalLogRow] {
        guard let log = retrievalLog else { return [] }
        let q = retrievalFilter.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Array(log.rows.prefix(40)) }
        return log.rows.filter { row in
            row.tool.lowercased().contains(q) || (row.query?.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder
    private var retrievalLogTable: some View {
        if retrievalLog == nil || (retrievalLog?.rows.isEmpty ?? true) {
            emptyCard("No retrieval calls logged yet — every `dome_search` writes one row here once the daemon serves a query with an actor.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Column header
                HStack(spacing: 0) {
                    Color.clear.frame(width: 22)
                    Text("QUERY")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("KIND")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                        .frame(width: 68, alignment: .leading)
                    Text("SCOPE")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                        .frame(width: 76, alignment: .leading)
                    Text("HITS")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                        .frame(width: 56, alignment: .trailing)
                    Text("LATENCY")
                        .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Palette.ink4)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.bgPage)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
                }

                ForEach(filteredRetrievalRows) { row in
                    retrievalLogRow(row)
                    Rectangle().fill(Palette.rule.opacity(0.6)).frame(height: DK.ruleW)
                }

                if let log = retrievalLog, log.rows.count > filteredRetrievalRows.count {
                    Text("+ \(log.rows.count - filteredRetrievalRows.count) more · run `dome-eval replay --vault <db>` for full window")
                        .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .background(Palette.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        }
    }

    private func retrievalLogRow(_ row: DomeRpcClient.RetrievalLogRow) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(row.wasConsumed ? Palette.accent : Palette.ink4)
                .frame(width: 6, height: 6)
                .frame(width: 22, alignment: .leading)
                .opacity(row.wasConsumed ? 1.0 : 0.5)

            HStack(spacing: 6) {
                Text(row.tool)
                    .font(Font.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                if let q = row.query, !q.isEmpty {
                    Text(q)
                        .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.actorKind)
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink3)
                .frame(width: 68, alignment: .leading)

            Text(row.knowledgeScope)
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink3)
                .frame(width: 76, alignment: .leading)

            Text("\(row.resultIDs.count)")
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
                .frame(width: 56, alignment: .trailing)

            Text("\(row.latencyMs) ms")
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(row.latencyMs > 500 ? Palette.warning : Palette.ink2)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// surfaceHeader + empty helpers moved to SurfaceHelpers.swift in
// v0.11 so AutomationSurface + RecipesSurface (and future
// surfaces) can share them without copy-paste. The local `empty(…)`
// callers were renamed to `surfaceEmpty(…)` at the same time.
// The Knowledge → Graph surface itself moved out to
// KnowledgeGraphSurface.swift in v0.18.0 and is now a tri-modal
// editorial surface (Index cover · Orbital · Ledger).
