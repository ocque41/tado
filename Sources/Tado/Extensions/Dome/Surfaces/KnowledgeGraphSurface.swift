import SwiftUI

/// Knowledge graph map.
///
/// The old graph surface had three modes: index, orbital, and ledger.
/// The ledger mode was large, fragile, and crash-prone. This surface is
/// intentionally one map plus one inspector. It keeps the existing
/// Dome graph snapshot contract and renders the full visible graph in a
/// single SwiftUI Canvas pass.
struct KnowledgeGraphSurface: View {
    let domeScope: DomeScopeSelection

    @Environment(\.relayTheme) private var theme
    @State private var snapshot: DomeRpcClient.GraphSnapshot?
    @State private var isLoading = false
    @State private var search = ""
    @State private var focusedID: String?
    @State private var enabledKinds: Set<KnowledgeGraphKind> = Set(KnowledgeGraphKind.allCases.map { $0 })
    @State private var maxNodes = 500

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
            content
        }
        .background(RelayPalette.background(for: theme))
        .task(id: domeScope.id) { await reload(force: false) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                RelayKicker(text: "KNOWLEDGE MAP")
                Text("Graph")
                    .font(RelayType.h2(size: 28))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
            }

            searchField
                .frame(width: 280)

            kindFilters

            Spacer(minLength: 12)

            if let snapshot {
                Text("\(visibleNodes(in: snapshot).count) nodes / \(visibleEdges(in: snapshot).count) ties")
                    .font(Typography.sans(size: 10, weight: .medium))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
            }

            RelayButton(label: isLoading ? "Loading" : "Refresh", variant: .standard, icon: "arrow.clockwise") {
                Task { await reload(force: true) }
            }
            .disabled(isLoading)
        }
        .padding(.horizontal, RelaySpacing.s32)
        .padding(.vertical, RelaySpacing.s16)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            TextField("Search graph", text: $search)
                .textFieldStyle(.plain)
                .font(Typography.sans(size: 12, weight: .regular))
                .foregroundStyle(RelayPalette.foreground(for: theme))
                .onSubmit {
                    Task { await reload(force: false) }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(
            RoundedRectangle(cornerRadius: RelayRadius.standard)
                .stroke(RelayPalette.hair(for: theme), lineWidth: 1)
        )
    }

    private var kindFilters: some View {
        HStack(spacing: 6) {
            ForEach(KnowledgeGraphKind.allCases) { kind in
                let active = enabledKinds.contains(kind)
                Button {
                    toggleKind(kind)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(kind.tint(theme: theme))
                            .frame(width: 6, height: 6)
                        Text(kind.label.uppercased())
                            .font(Typography.sans(size: 9, weight: .medium))
                            .tracking(RelayTracking.caps(9))
                    }
                    .foregroundStyle(active ? RelayPalette.foreground(for: theme) : RelayPalette.foreground4(for: theme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(active ? RelayPalette.wash(for: theme) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: RelayRadius.standard)
                            .stroke(active ? RelayPalette.hair(for: theme) : RelayPalette.hairSoft(for: theme), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot, !snapshot.nodes.isEmpty {
            HStack(spacing: 0) {
                graphCanvas(snapshot)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                Rectangle()
                    .fill(RelayPalette.hair(for: theme))
                    .frame(width: 1)
                inspector(snapshot)
                    .frame(width: 320)
            }
        } else if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading graph")
                    .font(Typography.sans(size: 13, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground2(for: theme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RelayCard {
                VStack(alignment: .leading, spacing: 12) {
                    RelayKicker(text: "EMPTY GRAPH")
                    Text("No knowledge entries yet.")
                        .font(RelayType.h2(size: 24))
                        .foregroundStyle(RelayPalette.foreground(for: theme))
                    Text("Ingest a project or create notes to seed the map.")
                        .font(Typography.sans(size: 13, weight: .regular))
                        .foregroundStyle(RelayPalette.foreground2(for: theme))
                }
            }
            .padding(RelaySpacing.s32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func graphCanvas(_ snapshot: DomeRpcClient.GraphSnapshot) -> some View {
        GeometryReader { proxy in
            let render = renderState(snapshot: snapshot, size: proxy.size)
            KnowledgeGraphCanvas(
                render: render,
                focusedID: focusedID,
                theme: theme,
                onFocus: { focusedID = $0 }
            )
        }
    }

    private func inspector(_ snapshot: DomeRpcClient.GraphSnapshot) -> some View {
        let focus = focusedNode(in: snapshot)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RelayStatStrip(stats: [
                    RelayStat("NODES", "\(visibleNodes(in: snapshot).count)"),
                    RelayStat("TIES", "\(visibleEdges(in: snapshot).count)"),
                ])

                if let focus {
                    VStack(alignment: .leading, spacing: 12) {
                        RelayKicker(text: KnowledgeGraphKind.from(focus.kind).label)
                        Text(focus.label)
                            .font(RelayType.h2(size: 24))
                            .foregroundStyle(RelayPalette.foreground(for: theme))
                            .fixedSize(horizontal: false, vertical: true)
                        if let secondary = focus.secondaryLabel, !secondary.isEmpty {
                            Text(secondary)
                                .font(Typography.sans(size: 12, weight: .regular))
                                .foregroundStyle(RelayPalette.foreground2(for: theme))
                        }
                        metaRow("Group", focus.groupKey)
                        if let date = focus.sortTime {
                            metaRow("Updated", Self.relative.localizedString(for: date, relativeTo: Date()))
                        }
                    }

                    neighborList(snapshot: snapshot, nodeID: focus.nodeID)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        RelayKicker(text: "INSPECTOR")
                        Text("Click a node to inspect it.")
                            .font(Typography.sans(size: 13, weight: .regular))
                            .foregroundStyle(RelayPalette.foreground2(for: theme))
                    }
                }
            }
            .padding(RelaySpacing.s24)
        }
        .background(RelayPalette.background(for: theme))
    }

    private func neighborList(snapshot: DomeRpcClient.GraphSnapshot, nodeID: String) -> some View {
        let ids = Array(KnowledgeGraphMath.neighborMap(snapshot.edges)[nodeID, default: []].prefix(24))
        let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.nodeID, $0) })
        return VStack(alignment: .leading, spacing: 10) {
            RelayKicker(text: "NEIGHBORS")
            if ids.isEmpty {
                Text("No direct links.")
                    .font(Typography.sans(size: 12, weight: .regular))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
            } else {
                ForEach(ids, id: \.self) { id in
                    if let node = nodesByID[id] {
                        Button {
                            focusedID = node.nodeID
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(KnowledgeGraphKind.from(node.kind).tint(theme: theme))
                                    .frame(width: 6, height: 6)
                                Text(node.label)
                                    .font(Typography.sans(size: 12, weight: .regular))
                                    .foregroundStyle(RelayPalette.foreground(for: theme))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(RelayPalette.hairSoft(for: theme))
                                    .frame(height: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label.uppercased())
                .font(Typography.sans(size: 9, weight: .medium))
                .tracking(RelayTracking.caps(9))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
            Spacer()
            Text(value)
                .font(Typography.sans(size: 11, weight: .regular))
                .foregroundStyle(RelayPalette.foreground2(for: theme))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func toggleKind(_ kind: KnowledgeGraphKind) {
        if enabledKinds.contains(kind), enabledKinds.count > 1 {
            enabledKinds.remove(kind)
        } else {
            enabledKinds.insert(kind)
        }
    }

    private func focusedNode(in snapshot: DomeRpcClient.GraphSnapshot) -> DomeRpcClient.GraphNode? {
        let nodes = visibleNodes(in: snapshot)
        if let focusedID, let node = nodes.first(where: { $0.nodeID == focusedID }) {
            return node
        }
        return nodes.first
    }

    private func visibleNodes(in snapshot: DomeRpcClient.GraphSnapshot) -> [DomeRpcClient.GraphNode] {
        snapshot.nodes.filter { enabledKinds.contains(KnowledgeGraphKind.from($0.kind)) }
    }

    private func visibleEdges(in snapshot: DomeRpcClient.GraphSnapshot) -> [DomeRpcClient.GraphEdge] {
        let ids = Set(visibleNodes(in: snapshot).map(\.nodeID))
        return snapshot.edges.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) }
    }

    private func reload(force: Bool) async {
        isLoading = true
        defer { isLoading = false }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = domeScope
        let limit = maxNodes
        let fetched = await Task.detached { () -> DomeRpcClient.GraphSnapshot? in
            if force { _ = DomeRpcClient.refreshGraph() }
            return DomeRpcClient.graphSnapshot(
                search: query.isEmpty ? nil : query,
                focusNodeID: nil,
                maxNodes: limit,
                includeTypes: nil,
                domeScope: scope
            )
        }.value
        guard let fetched else { return }
        snapshot = fetched
        if let focusedID, !fetched.nodes.contains(where: { $0.nodeID == focusedID }) {
            self.focusedID = fetched.nodes.first?.nodeID
        } else if focusedID == nil {
            focusedID = fetched.nodes.first?.nodeID
        }
    }

    private func renderState(snapshot: DomeRpcClient.GraphSnapshot, size: CGSize) -> KnowledgeGraphRenderState {
        let nodes = visibleNodes(in: snapshot)
        let edges = visibleEdges(in: snapshot)
        let degrees = KnowledgeGraphMath.degreeMap(edges)
        let raw = rawPositions(for: snapshot, nodes: nodes)
        let points = fit(rawPositions: raw, into: size)
        let renderNodes = nodes.compactMap { node -> KnowledgeGraphRenderNode? in
            guard let point = points[node.nodeID] else { return nil }
            return KnowledgeGraphRenderNode(
                node: node,
                kind: KnowledgeGraphKind.from(node.kind),
                point: point,
                degree: degrees[node.nodeID] ?? 0
            )
        }
        let byID = Dictionary(uniqueKeysWithValues: renderNodes.map { ($0.node.nodeID, $0) })
        let focus = focusedID
        let renderEdges = edges.compactMap { edge -> KnowledgeGraphRenderEdge? in
            guard let source = byID[edge.sourceID]?.point,
                  let target = byID[edge.targetID]?.point else { return nil }
            return KnowledgeGraphRenderEdge(
                source: source,
                target: target,
                highlighted: focus == edge.sourceID || focus == edge.targetID
            )
        }
        let neighbors = KnowledgeGraphMath.neighborMap(edges)
        let labelIDs = Set(labelNodeIDs(nodes: renderNodes, focusID: focusedID, neighbors: neighbors))
        return KnowledgeGraphRenderState(
            nodes: renderNodes,
            nodeByID: byID,
            edges: renderEdges,
            neighbors: neighbors,
            labelNodes: renderNodes.filter { labelIDs.contains($0.node.nodeID) }
        )
    }

    private func rawPositions(
        for snapshot: DomeRpcClient.GraphSnapshot,
        nodes: [DomeRpcClient.GraphNode]
    ) -> [String: CGPoint] {
        var positions = clusterPositions(nodes: nodes)
        for (id, point) in snapshot.layout?.nodes ?? [:] {
            positions[id] = CGPoint(x: point.x, y: point.y)
        }
        return positions
    }

    private func clusterPositions(nodes: [DomeRpcClient.GraphNode]) -> [String: CGPoint] {
        let groups = Dictionary(grouping: nodes, by: \.groupKey)
        let keys = groups.keys.sorted()
        let groupRadius = max(240.0, Double(keys.count) * 42.0)
        var positions: [String: CGPoint] = [:]
        for (groupIndex, key) in keys.enumerated() {
            let angle = Double(groupIndex) / Double(max(keys.count, 1)) * .pi * 2 - .pi / 2
            let center = CGPoint(
                x: CGFloat(cos(angle) * groupRadius),
                y: CGFloat(sin(angle) * groupRadius)
            )
            let groupNodes = (groups[key] ?? []).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            let localRadius = max(28.0, Double(groupNodes.count) * 4.8)
            for (nodeIndex, node) in groupNodes.enumerated() {
                let nodeAngle = Double(nodeIndex) / Double(max(groupNodes.count, 1)) * .pi * 2
                positions[node.nodeID] = CGPoint(
                    x: center.x + CGFloat(cos(nodeAngle) * localRadius),
                    y: center.y + CGFloat(sin(nodeAngle) * localRadius)
                )
            }
        }
        return positions
    }

    private func fit(rawPositions: [String: CGPoint], into size: CGSize) -> [String: CGPoint] {
        guard !rawPositions.isEmpty else { return [:] }
        let values = Array(rawPositions.values)
        let minX = values.map(\.x).min() ?? 0
        let maxX = values.map(\.x).max() ?? 1
        let minY = values.map(\.y).min() ?? 0
        let maxY = values.map(\.y).max() ?? 1
        let sourceW = max(maxX - minX, 1)
        let sourceH = max(maxY - minY, 1)
        let pad: CGFloat = 56
        let targetW = max(size.width - pad * 2, 1)
        let targetH = max(size.height - pad * 2, 1)
        let scale = min(targetW / sourceW, targetH / sourceH)
        let drawW = sourceW * scale
        let drawH = sourceH * scale
        let offsetX = (size.width - drawW) / 2
        let offsetY = (size.height - drawH) / 2
        return rawPositions.mapValues { point in
            CGPoint(
                x: offsetX + (point.x - minX) * scale,
                y: offsetY + (point.y - minY) * scale
            )
        }
    }

    private func labelNodeIDs(
        nodes: [KnowledgeGraphRenderNode],
        focusID: String?,
        neighbors: [String: [String]]
    ) -> [String] {
        var ids: [String] = []
        if let focusID {
            ids.append(focusID)
            ids.append(contentsOf: neighbors[focusID, default: []].prefix(8))
        }
        ids.append(contentsOf: nodes.sorted { $0.degree > $1.degree }.prefix(10).map { $0.node.nodeID })
        return Array(Set(ids))
    }

    private func nearestNode(to location: CGPoint, in render: KnowledgeGraphRenderState) -> KnowledgeGraphRenderNode? {
        var bestNode: KnowledgeGraphRenderNode?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for node in render.nodes {
            let distance = hypot(node.point.x - location.x, node.point.y - location.y)
            let hitRadius = max(CGFloat(18), nodeRadius(node) + 8)
            if distance <= hitRadius, distance < bestDistance {
                bestNode = node
                bestDistance = distance
            }
        }
        return bestNode
    }

    private func nodeRadius(_ node: KnowledgeGraphRenderNode) -> CGFloat {
        min(15, 5 + CGFloat(node.degree).squareRoot() * 2.2)
    }

    private func shortLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 28 { return trimmed }
        return String(trimmed.prefix(25)) + "..."
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct KnowledgeGraphCanvas: View {
    let render: KnowledgeGraphRenderState
    let focusedID: String?
    let theme: RelayTheme
    let onFocus: (String) -> Void

    var body: some View {
        Canvas { context, _ in
            drawEdges(context: &context)
            drawNodes(context: &context)
            drawLabels(context: &context)
        }
        .background(RelayPalette.background(for: theme))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    guard let hit = nearestNode(to: value.location) else { return }
                    onFocus(hit.node.nodeID)
                }
        )
    }

    private func drawEdges(context: inout GraphicsContext) {
        for edge in render.edges {
            var path = Path()
            path.move(to: edge.source)
            path.addLine(to: edge.target)
            let color = edge.highlighted
                ? RelayPalette.terracotta.opacity(0.72)
                : RelayPalette.hairSoft(for: theme)
            context.stroke(path, with: .color(color), lineWidth: edge.highlighted ? 1.4 : 0.8)
        }
    }

    private func drawNodes(context: inout GraphicsContext) {
        for node in render.nodes {
            let radius = nodeRadius(node)
            let rect = CGRect(
                x: node.point.x - radius,
                y: node.point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let isFocused = node.node.nodeID == focusedID
            let isNeighbor = focusedID.map { render.neighbors[$0, default: []].contains(node.node.nodeID) } ?? false
            let alpha = isNeighbor || focusedID == nil ? 0.92 : 0.35
            let fill = isFocused ? RelayPalette.terracotta : node.kind.tint(theme: theme).opacity(alpha)
            let stroke = isFocused ? RelayPalette.foreground(for: theme) : RelayPalette.hair(for: theme)
            context.fill(Path(ellipseIn: rect), with: .color(fill))
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(stroke), lineWidth: isFocused ? 1.5 : 0.7)
        }
    }

    private func drawLabels(context: inout GraphicsContext) {
        for node in render.labelNodes {
            let fontSize: CGFloat = node.node.nodeID == focusedID ? 12 : 10
            let text = Text(shortLabel(node.node.label))
                .font(Typography.sans(size: fontSize, weight: .medium))
                .foregroundStyle(RelayPalette.foreground(for: theme))
            let point = CGPoint(x: node.point.x, y: node.point.y - nodeRadius(node) - 12)
            context.draw(text, at: point)
        }
    }

    private func nearestNode(to location: CGPoint) -> KnowledgeGraphRenderNode? {
        var bestNode: KnowledgeGraphRenderNode?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for node in render.nodes {
            let distance = hypot(node.point.x - location.x, node.point.y - location.y)
            let hitRadius = max(CGFloat(18), nodeRadius(node) + 8)
            if distance <= hitRadius, distance < bestDistance {
                bestNode = node
                bestDistance = distance
            }
        }
        return bestNode
    }

    private func nodeRadius(_ node: KnowledgeGraphRenderNode) -> CGFloat {
        min(15, 5 + CGFloat(node.degree).squareRoot() * 2.2)
    }

    private func shortLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 28 { return trimmed }
        return String(trimmed.prefix(25)) + "..."
    }
}

private struct KnowledgeGraphRenderNode {
    let node: DomeRpcClient.GraphNode
    let kind: KnowledgeGraphKind
    let point: CGPoint
    let degree: Int
}

private struct KnowledgeGraphRenderEdge {
    let source: CGPoint
    let target: CGPoint
    let highlighted: Bool
}

private struct KnowledgeGraphRenderState {
    let nodes: [KnowledgeGraphRenderNode]
    let nodeByID: [String: KnowledgeGraphRenderNode]
    let edges: [KnowledgeGraphRenderEdge]
    let neighbors: [String: [String]]
    let labelNodes: [KnowledgeGraphRenderNode]
}

private enum KnowledgeGraphKind: String, CaseIterable, Identifiable {
    case doc
    case topic
    case agent
    case project
    case code
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .doc: return "Docs"
        case .topic: return "Topics"
        case .agent: return "Agents"
        case .project: return "Projects"
        case .code: return "Code"
        case .other: return "Other"
        }
    }

    static func from(_ raw: String) -> KnowledgeGraphKind {
        let value = raw.lowercased()
        if value.contains("topic") || value.contains("tag") { return .topic }
        if value.contains("agent") || value.contains("person") { return .agent }
        if value.contains("project") || value.contains("company") || value.contains("brand") { return .project }
        if value.contains("code") || value.contains("symbol") || value.contains("file") { return .code }
        if value.contains("doc") || value.contains("note") || value.contains("context") { return .doc }
        return .other
    }

    func tint(theme: RelayTheme) -> Color {
        switch self {
        case .doc: return RelayPalette.foreground2(for: theme)
        case .topic: return RelayPalette.terracotta
        case .agent: return RelayPalette.foreground(for: theme)
        case .project: return RelayPalette.terracotta.opacity(0.78)
        case .code: return RelayPalette.foreground3(for: theme)
        case .other: return RelayPalette.foreground4(for: theme)
        }
    }
}

private enum KnowledgeGraphMath {
    static func neighborMap(_ edges: [DomeRpcClient.GraphEdge]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for edge in edges {
            map[edge.sourceID, default: []].append(edge.targetID)
            map[edge.targetID, default: []].append(edge.sourceID)
        }
        return map
    }

    static func degreeMap(_ edges: [DomeRpcClient.GraphEdge]) -> [String: Int] {
        var degrees: [String: Int] = [:]
        for edge in edges {
            degrees[edge.sourceID, default: 0] += 1
            degrees[edge.targetID, default: 0] += 1
        }
        return degrees
    }
}
