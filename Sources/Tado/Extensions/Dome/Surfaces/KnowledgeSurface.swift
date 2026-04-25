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
                empty(icon: "square.grid.3x2", text: "No notes in the vault yet.")
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
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func kindBadge(_ kind: String?) -> some View {
        Text((kind ?? "knowledge").capitalized)
            .font(Typography.micro)
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

private struct KnowledgeGraphSurface: View {
    let domeScope: DomeScopeSelection

    @State private var snapshot: DomeRpcClient.GraphSnapshot?
    @State private var selectedNodeID: String?
    @State private var search = ""
    @State private var isLoading = false
    @State private var maxNodes = 400.0

    private var selectedNode: DomeRpcClient.GraphNode? {
        snapshot?.nodes.first { $0.nodeID == selectedNodeID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(title: "Knowledge Graph", subtitle: graphSubtitle, isLoading: isLoading) {
                Task { await reload(force: true) }
            }
            Divider().overlay(Palette.divider)
            toolbar
            Divider().overlay(Palette.divider)
            HStack(spacing: 0) {
                graphCanvas
                Divider().overlay(Palette.divider)
                inspector
                    .frame(width: 280)
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload(force: false) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            TextField("Search graph", text: $search)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .onSubmit { Task { await reload(force: false) } }
            Button(action: { Task { await reload(force: false) } }) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Run search")
            Divider().frame(height: 18).overlay(Palette.divider)
            Text("Nodes")
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
            Slider(value: $maxNodes, in: 100...1000, step: 50) {
                Text("Nodes")
            }
            .frame(width: 140)
            Text("\(Int(maxNodes))")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Palette.surface)
    }

    private var graphCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                Palette.background
                if let snapshot, !snapshot.nodes.isEmpty {
                    Canvas { context, size in
                        drawEdges(context: &context, size: size, snapshot: snapshot)
                    }
                    ForEach(snapshot.nodes) { node in
                        let point = graphPoint(for: node, size: proxy.size, snapshot: snapshot)
                        Button(action: { selectedNodeID = node.nodeID }) {
                            VStack(spacing: 3) {
                                Circle()
                                    .fill(color(for: node.kind))
                                    .frame(width: nodeRadius(for: node, snapshot: snapshot), height: nodeRadius(for: node, snapshot: snapshot))
                                    .overlay {
                                        Circle()
                                            .stroke(selectedNodeID == node.nodeID ? Palette.accent : Color.white.opacity(0.22), lineWidth: selectedNodeID == node.nodeID ? 2 : 1)
                                    }
                                Text(node.label)
                                    .font(Typography.micro)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1)
                                    .frame(width: 110)
                            }
                        }
                        .buttonStyle(.plain)
                        .position(point)
                        .help("\(node.kind): \(node.label)")
                    }
                } else {
                    empty(icon: "point.3.connected.trianglepath.dotted", text: "No graph nodes yet.")
                }
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let node = selectedNode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.kind.uppercased())
                        .font(Typography.overline)
                        .foregroundStyle(Palette.textTertiary)
                    Text(node.label)
                        .font(Typography.title)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let secondary = node.secondaryLabel {
                        Text(secondary)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                metadataLine("Node", node.nodeID)
                metadataLine("Reference", node.refID)
                metadataLine("Cluster", node.groupKey)
                provenanceBadge(kind: node.kind)
                Button(action: {
                    selectedNodeID = node.nodeID
                    search = node.label
                    Task { await reload(force: false) }
                }) {
                    Label("Focus", systemImage: "scope")
                        .font(Typography.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            } else {
                Text("Select a node")
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                Text("Inspector shows graph kind, source reference, cluster, and provenance.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(18)
        .background(Palette.surface)
    }

    private var graphSubtitle: String {
        guard let stats = snapshot?.stats else { return "Loading graph" }
        return "\(stats.visibleNodes) / \(stats.totalNodes) nodes · \(stats.visibleEdges) edges"
    }

    private func reload(force: Bool) async {
        isLoading = true
        defer { isLoading = false }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let max = Int(maxNodes)
        let fetched = await Task.detached { () -> DomeRpcClient.GraphSnapshot? in
            if force { _ = DomeRpcClient.refreshGraph() }
            return DomeRpcClient.graphSnapshot(search: query.isEmpty ? nil : query, maxNodes: max, domeScope: domeScope)
        }.value
        if let fetched {
            snapshot = fetched
            if selectedNodeID == nil {
                selectedNodeID = fetched.nodes.first?.nodeID
            }
        }
    }

    private func drawEdges(context: inout GraphicsContext, size: CGSize, snapshot: DomeRpcClient.GraphSnapshot) {
        for edge in snapshot.edges {
            guard let source = snapshot.nodes.first(where: { $0.nodeID == edge.sourceID }),
                  let target = snapshot.nodes.first(where: { $0.nodeID == edge.targetID }) else { continue }
            var path = Path()
            path.move(to: graphPoint(for: source, size: size, snapshot: snapshot))
            path.addLine(to: graphPoint(for: target, size: size, snapshot: snapshot))
            context.stroke(path, with: .color(edgeColor(for: edge.kind)), lineWidth: edge.kind == "context_pack_contains" ? 1.4 : 0.7)
        }
    }

    private func graphPoint(for node: DomeRpcClient.GraphNode, size: CGSize, snapshot: DomeRpcClient.GraphSnapshot) -> CGPoint {
        guard let layout = snapshot.layout?.nodes[node.nodeID], let bounds = layoutBounds(snapshot: snapshot) else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let padding: CGFloat = 70
        let w = max(size.width - padding * 2, 1)
        let h = max(size.height - padding * 2, 1)
        let x = padding + CGFloat((layout.x - bounds.minX) / max(bounds.width, 1)) * w
        let y = padding + CGFloat((layout.y - bounds.minY) / max(bounds.height, 1)) * h
        return CGPoint(x: x, y: y)
    }

    private func layoutBounds(snapshot: DomeRpcClient.GraphSnapshot) -> (minX: Double, minY: Double, width: Double, height: Double)? {
        let points = snapshot.layout?.nodes.values.map { ($0.x, $0.y) } ?? []
        guard let first = points.first else { return nil }
        var minX = first.0
        var maxX = first.0
        var minY = first.1
        var maxY = first.1
        for point in points.dropFirst() {
            minX = min(minX, point.0)
            maxX = max(maxX, point.0)
            minY = min(minY, point.1)
            maxY = max(maxY, point.1)
        }
        return (minX, minY, maxX - minX, maxY - minY)
    }

    private func nodeRadius(for node: DomeRpcClient.GraphNode, snapshot: DomeRpcClient.GraphSnapshot) -> CGFloat {
        let rank = snapshot.layout?.nodes[node.nodeID]?.rank ?? 1
        return CGFloat(10 + rank * 7)
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "doc": return Palette.accent
        case "context_pack": return Palette.warning
        case "agent": return Palette.success
        case "task": return Color(hex: 0xC76F3A)
        case "run": return Color(hex: 0x7F8EA3)
        case "topic": return Color(hex: 0x8B715A)
        default: return Palette.textTertiary
        }
    }

    private func edgeColor(for kind: String) -> Color {
        switch kind {
        case "context_pack_contains", "agent_used_context": return Palette.warning.opacity(0.65)
        case "agent_skipped_context": return Palette.danger.opacity(0.7)
        default: return Palette.textTertiary.opacity(0.35)
        }
    }

    private func provenanceBadge(kind: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.success).frame(width: 7, height: 7)
            Text(kind == "context_pack" ? "cited context" : "deterministic")
                .font(Typography.microEmphasis)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func metadataLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct KnowledgeSystemSurface: View {
    let domeScope: DomeScopeSelection

    @State private var envelope: DomeRpcClient.AgentStatusEnvelope?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(title: "Agent System", subtitle: "\(systemSubtitle) · \(domeScope.label)", isLoading: isLoading) {
                Task { await reload() }
            }
            Divider().overlay(Palette.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusSection
                    contextPackSection
                    retrievalSection
                }
                .padding(20)
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload() }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Claude Agents")
            if let statuses = envelope?.statuses, !statuses.isEmpty {
                ForEach(statuses) { status in
                    statusRow(status)
                    Divider().overlay(Palette.divider)
                }
            } else {
                Text("No status-line snapshots yet.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var contextPackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Context Packs")
            if let packs = envelope?.contextPacks, !packs.isEmpty {
                ForEach(packs) { pack in
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(Palette.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.contextID)
                                .font(Typography.monoCaption)
                                .foregroundStyle(Palette.textPrimary)
                            Text("\(pack.brand) · \(pack.status) · \(pack.tokenEstimate ?? 0) tokens · \(pack.citationCount ?? 0) citations")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
            } else {
                Text("No context packs have been compacted yet.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var retrievalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Retrieval Events")
            if let events = envelope?.contextEvents, !events.isEmpty {
                ForEach(events) { event in
                    HStack(spacing: 10) {
                        Image(systemName: event.eventKind.contains("skipped") ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(event.eventKind.contains("skipped") ? Palette.danger : Palette.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.eventKind)
                                .font(Typography.bodyEmphasis)
                                .foregroundStyle(Palette.textPrimary)
                            Text([event.agentName, event.contextID, event.reason].compactMap { $0 }.joined(separator: " · "))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
            } else {
                Text("Dome has not recorded context use or skipped-retrieval warnings yet.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var systemSubtitle: String {
        let count = envelope?.statuses.count ?? 0
        return "\(count) status snapshots"
    }

    private func statusRow(_ status: DomeRpcClient.AgentStatusSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.agentName ?? "claude")
                    .font(Typography.titleSm)
                    .foregroundStyle(Palette.textPrimary)
                Text([status.projectName, status.modelDisplayName, status.retrievalFreshness].compactMap { $0 }.joined(separator: " · "))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            metric("ctx", "\(Int(status.contextUsedPercent ?? 0))%")
            metric("tokens", "\(status.inputTokens ?? 0)")
            metric("cost", String(format: "$%.2f", status.costUSD ?? 0))
        }
        .padding(.vertical, 6)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(width: 62, alignment: .trailing)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Typography.heading)
            .foregroundStyle(Palette.textPrimary)
            .padding(.top, 2)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fetched = await Task.detached { DomeRpcClient.agentStatus(limit: 80, domeScope: domeScope) }.value
        if let fetched { envelope = fetched }
    }
}

private func surfaceHeader(title: String, subtitle: String, isLoading: Bool, refresh: @escaping () -> Void) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Typography.display)
                .foregroundStyle(Palette.textPrimary)
            Text(subtitle)
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
        }
        Spacer()
        Button(action: refresh) {
            Image(systemName: isLoading ? "hourglass" : "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .help("Refresh")
    }
    .padding(.horizontal, 20)
    .padding(.top, 20)
    .padding(.bottom, 14)
    .background(Palette.surface)
}

private func empty(icon: String, text: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon)
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(Palette.textTertiary)
        Text(text)
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
