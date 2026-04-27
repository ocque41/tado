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
    @State private var hoveredNodeID: String?
    @State private var search = ""
    @State private var isLoading = false
    @State private var maxNodes = 400.0
    /// Fallback positions computed by `ForceLayout` when the snapshot
    /// arrives without a precomputed `layout`. Keyed by `nodeID`.
    /// Recomputed on every snapshot change so a stale layout from a
    /// previous query never leaks across reloads.
    @State private var fallbackPositions: [String: CGPoint] = [:]
    /// Non-empty when the user has manually toggled chips. Empty means
    /// "use bt-core's `default_include_types`" — the sentinel keeps the
    /// chip strip in sync with whatever the daemon considers the
    /// default view (so a future daemon change is reflected here for
    /// free).
    @State private var enabledKinds: Set<String> = []
    /// When true, the next reload re-fetches with `focusNodeID` set to
    /// the current selection — bt-core then trims the snapshot to the
    /// 1-hop neighborhood. Cheaper than client-side hiding for very
    /// dense graphs because the daemon prunes edges before we marshal.
    @State private var focusNeighborhood = false

    // Pan / zoom state. `zoom` and `dragOffset` accumulate the
    // committed transform; `magnifyDelta` and `dragDelta` track the
    // in-flight gesture and reset on release.
    @State private var zoom: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero
    @GestureState private var magnifyDelta: CGFloat = 1.0
    @State private var hoveringCanvas = false
    /// Local `NSEvent` monitor for trackpad scroll-wheel pan + zoom.
    /// Installed only while this surface is on-screen so the Dome
    /// Knowledge tab doesn't keep eating scroll events from other
    /// surfaces.
    @State private var scrollMonitor: Any?

    private var selectedNode: DomeRpcClient.GraphNode? {
        snapshot?.nodes.first { $0.nodeID == selectedNodeID }
    }

    /// Cached node lookup so the per-frame edge draw doesn't redo an
    /// O(N) scan per edge. Built lazily on first use of the snapshot.
    private var nodeIndex: [String: DomeRpcClient.GraphNode] {
        var dict: [String: DomeRpcClient.GraphNode] = [:]
        if let snapshot {
            dict.reserveCapacity(snapshot.nodes.count)
            for node in snapshot.nodes { dict[node.nodeID] = node }
        }
        return dict
    }

    /// IDs of the selected node + its 1-hop neighbors. Empty when no
    /// selection is active — callers treat that as "show everything at
    /// full opacity".
    private var neighborIDs: Set<String> {
        guard let snapshot, let selectedNodeID else { return [] }
        var ids: Set<String> = [selectedNodeID]
        for edge in snapshot.edges {
            if edge.sourceID == selectedNodeID { ids.insert(edge.targetID) }
            if edge.targetID == selectedNodeID { ids.insert(edge.sourceID) }
        }
        return ids
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(title: "Knowledge Graph", subtitle: graphSubtitle, isLoading: isLoading) {
                Task { await reload(force: true) }
            }
            Divider().overlay(Palette.divider)
            toolbar
            Divider().overlay(Palette.divider)
            kindLegend
            Divider().overlay(Palette.divider)
            HSplitView {
                graphCanvas
                    .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                inspector
                    .frame(minWidth: 160, idealWidth: 280, maxWidth: 360)
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload(force: false) }
        .onAppear { installScrollMonitor() }
        .onDisappear { removeScrollMonitor() }
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

            zoomControls

            Divider().frame(height: 18).overlay(Palette.divider)

            Toggle(isOn: $focusNeighborhood) {
                Text("Neighbors only")
                    .font(Typography.micro)
                    .foregroundStyle(Palette.textSecondary)
            }
            .toggleStyle(.checkbox)
            .help("Re-fetch with focus on the selected node's 1-hop neighborhood")
            .onChange(of: focusNeighborhood) { _, _ in Task { await reload(force: false) } }

            Spacer(minLength: 12)

            Text("Cap")
                .font(Typography.micro)
                .foregroundStyle(Palette.textTertiary)
            Slider(value: $maxNodes, in: 100...1000, step: 50) {
                Text("Cap")
            }
            .frame(width: 120)
            Text("\(Int(maxNodes))")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Palette.surface)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button(action: zoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Zoom out")
            Button(action: zoomIn) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Zoom in")
            Button(action: resetView) {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Reset zoom & pan")
            Text("\(Int(effectiveZoom * 100))%")
                .font(Typography.monoMicro)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var kindLegend: some View {
        let available = snapshot?.availableTypes ?? []
        let counts = snapshot?.stats.visibleCountsByKind ?? [:]
        let defaults = Set(snapshot?.defaultIncludeTypes ?? available)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(available, id: \.self) { kind in
                    let isOn = enabledKinds.isEmpty
                        ? defaults.contains(kind)
                        : enabledKinds.contains(kind)
                    Button(action: { toggleKind(kind) }) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(color(for: kind))
                                .frame(width: 7, height: 7)
                            Text(kind)
                                .font(Typography.micro)
                            Text("\(counts[kind] ?? 0)")
                                .font(Typography.monoMicro)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isOn ? Palette.surfaceAccent : Palette.surfaceElevated)
                        .foregroundStyle(isOn ? Palette.textPrimary : Palette.textSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isOn ? Palette.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isOn ? "Hide \(kind) nodes" : "Show \(kind) nodes")
                }
                if !enabledKinds.isEmpty {
                    Button("Reset filters") {
                        enabledKinds = []
                        Task { await reload(force: false) }
                    }
                    .buttonStyle(.plain)
                    .font(Typography.micro)
                    .foregroundStyle(Palette.accent)
                    .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .background(Palette.surface)
    }

    private var graphCanvas: some View {
        GeometryReader { proxy in
            let viewport = proxy.size
            let panOffset = CGSize(
                width: dragOffset.width + dragDelta.width,
                height: dragOffset.height + dragDelta.height
            )
            let appliedZoom = zoom * magnifyDelta
            ZStack {
                // Background absorbs taps so clicking empty space
                // clears the selection — matches macOS Finder/Maps idiom.
                Palette.background
                    .contentShape(Rectangle())
                    .onTapGesture { selectedNodeID = nil }

                if let snapshot, !snapshot.nodes.isEmpty {
                    ZStack {
                        Canvas { context, size in
                            drawEdges(
                                context: &context,
                                size: size,
                                snapshot: snapshot,
                                index: nodeIndex
                            )
                        }
                        ForEach(snapshot.nodes) { node in
                            nodeView(for: node, in: snapshot, viewport: viewport, appliedZoom: appliedZoom)
                        }
                    }
                    .frame(width: viewport.width, height: viewport.height)
                    .scaleEffect(appliedZoom, anchor: .center)
                    .offset(panOffset)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .updating($dragDelta) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                dragOffset.width += value.translation.width
                                dragOffset.height += value.translation.height
                            }
                    )
                    .gesture(
                        MagnifyGesture()
                            .updating($magnifyDelta) { value, state, _ in
                                state = value.magnification
                            }
                            .onEnded { value in
                                zoom = clampZoom(zoom * value.magnification)
                            }
                    )
                } else {
                    empty(icon: "point.3.connected.trianglepath.dotted", text: "No graph nodes match.")
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase {
                    hoveringCanvas = true
                } else {
                    hoveringCanvas = false
                }
            }
        }
    }

    @ViewBuilder
    private func nodeView(
        for node: DomeRpcClient.GraphNode,
        in snapshot: DomeRpcClient.GraphSnapshot,
        viewport: CGSize,
        appliedZoom: CGFloat
    ) -> some View {
        let point = graphPoint(for: node, size: viewport, snapshot: snapshot)
        let radius = nodeRadius(for: node, snapshot: snapshot)
        let isSelected = selectedNodeID == node.nodeID
        let isHovered = hoveredNodeID == node.nodeID
        let neighbors = neighborIDs
        let isInFocus = neighbors.isEmpty || neighbors.contains(node.nodeID)
        let rank = snapshot.layout?.nodes[node.nodeID]?.rank ?? 0
        // Show labels for: selection + 1-hop, hovered, hub nodes
        // (rank ≥ 3 = nodes with 3+ connections), and everything once
        // the user has zoomed past 1.4×. Keeps the default fitted view
        // legible — no overlapping label smear.
        let labelVisible = isSelected || isHovered ||
            (isInFocus && (appliedZoom >= 1.4 || rank >= 3))
        Button(action: { selectedNodeID = node.nodeID }) {
            VStack(spacing: 3) {
                Circle()
                    .fill(color(for: node.kind))
                    .frame(width: radius, height: radius)
                    .overlay {
                        Circle()
                            .stroke(
                                isSelected ? Palette.accent :
                                    (isHovered ? Color.white.opacity(0.55) : Color.white.opacity(0.22)),
                                lineWidth: isSelected ? 2 : (isHovered ? 1.5 : 1)
                            )
                    }
                if labelVisible {
                    Text(node.label)
                        .font(Typography.micro)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .frame(width: 110)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(isInFocus ? 1.0 : 0.18)
        .position(point)
        .onHover { hovering in
            if hovering {
                hoveredNodeID = node.nodeID
            } else if hoveredNodeID == node.nodeID {
                hoveredNodeID = nil
            }
        }
        .help("\(node.kind): \(node.label)")
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
                connectionsList(for: node)
                Button(action: {
                    search = node.label
                    Task { await reload(force: false) }
                }) {
                    Label("Pin to search", systemImage: "scope")
                        .font(Typography.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            } else {
                Text("Select a node")
                    .font(Typography.title)
                    .foregroundStyle(Palette.textPrimary)
                Text("Tap a node to inspect it. Drag to pan, pinch or shift+scroll to zoom.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(18)
        .background(Palette.surface)
    }

    @ViewBuilder
    private func connectionsList(for node: DomeRpcClient.GraphNode) -> some View {
        if let snapshot {
            let edges = snapshot.edges.filter {
                $0.sourceID == node.nodeID || $0.targetID == node.nodeID
            }
            if !edges.isEmpty {
                Divider().overlay(Palette.divider)
                Text("Connections (\(edges.count))")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textPrimary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(edges, id: \.edgeID) { edge in
                            let otherID = edge.sourceID == node.nodeID ? edge.targetID : edge.sourceID
                            if let other = nodeIndex[otherID] {
                                Button(action: { selectedNodeID = other.nodeID }) {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(color(for: other.kind))
                                            .frame(width: 7, height: 7)
                                        Text(other.label)
                                            .font(Typography.caption)
                                            .foregroundStyle(Palette.textPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: 6)
                                        Text(edge.kind)
                                            .font(Typography.monoMicro)
                                            .foregroundStyle(Palette.textTertiary)
                                            .lineLimit(1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: - Toolbar actions

    private var effectiveZoom: CGFloat { zoom * magnifyDelta }

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.3), 6.0)
    }

    private func zoomIn() {
        withAnimation(.easeOut(duration: 0.15)) { zoom = clampZoom(zoom * 1.2) }
    }

    private func zoomOut() {
        withAnimation(.easeOut(duration: 0.15)) { zoom = clampZoom(zoom / 1.2) }
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1.0
            dragOffset = .zero
        }
    }

    private func toggleKind(_ kind: String) {
        let defaults = Set(snapshot?.defaultIncludeTypes ?? snapshot?.availableTypes ?? [])
        var current = enabledKinds.isEmpty ? defaults : enabledKinds
        if current.contains(kind) {
            current.remove(kind)
        } else {
            current.insert(kind)
        }
        // Snap back to the sentinel "use defaults" state when the
        // user lands exactly on the default set — keeps the chip
        // strip in sync with future bt-core default changes.
        enabledKinds = (current == defaults) ? [] : current
        Task { await reload(force: false) }
    }

    // MARK: - Scroll-wheel monitor

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            guard self.hoveringCanvas else { return event }
            // Shift / Cmd + scroll = zoom; bare scroll = pan. Mirrors
            // CanvasView.installMonitors so the gesture vocabulary is
            // consistent across the app.
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
                let raw = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    ? event.scrollingDeltaX : event.scrollingDeltaY
                let factor = max(0.5, min(1.0 + CGFloat(raw) * 0.005, 1.5))
                self.zoom = self.clampZoom(self.zoom * factor)
                return nil
            }
            self.dragOffset.width += event.scrollingDeltaX
            self.dragOffset.height += event.scrollingDeltaY
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
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
        let kinds: [String]? = enabledKinds.isEmpty ? nil : Array(enabledKinds).sorted()
        let focus: String? = focusNeighborhood ? selectedNodeID : nil
        let scope = domeScope
        let fetched = await Task.detached { () -> DomeRpcClient.GraphSnapshot? in
            if force { _ = DomeRpcClient.refreshGraph() }
            return DomeRpcClient.graphSnapshot(
                search: query.isEmpty ? nil : query,
                focusNodeID: focus,
                maxNodes: max,
                includeTypes: kinds,
                domeScope: scope
            )
        }.value
        if let fetched {
            snapshot = fetched
            // If a filter / search dropped the previously selected
            // node, fall back to the first visible one so the
            // inspector is never pointing at a ghost.
            if let current = selectedNodeID, !fetched.nodes.contains(where: { $0.nodeID == current }) {
                selectedNodeID = fetched.nodes.first?.nodeID
            } else if selectedNodeID == nil {
                selectedNodeID = fetched.nodes.first?.nodeID
            }
            recomputeFallbackLayout()
        }
    }

    private func drawEdges(
        context: inout GraphicsContext,
        size: CGSize,
        snapshot: DomeRpcClient.GraphSnapshot,
        index: [String: DomeRpcClient.GraphNode]
    ) {
        let focusActive = selectedNodeID != nil
        for edge in snapshot.edges {
            guard let source = index[edge.sourceID],
                  let target = index[edge.targetID] else { continue }
            let inFocus = !focusActive ||
                edge.sourceID == selectedNodeID || edge.targetID == selectedNodeID
            var path = Path()
            path.move(to: graphPoint(for: source, size: size, snapshot: snapshot))
            path.addLine(to: graphPoint(for: target, size: size, snapshot: snapshot))
            let base = edgeColor(for: edge.kind)
            let stroke = base.opacity(inFocus ? 1.0 : 0.10)
            context.stroke(path, with: .color(stroke), lineWidth: edge.kind == "context_pack_contains" ? 1.4 : 0.7)
        }
    }

    private func graphPoint(for node: DomeRpcClient.GraphNode, size: CGSize, snapshot: DomeRpcClient.GraphSnapshot) -> CGPoint {
        if let layout = snapshot.layout?.nodes[node.nodeID], let bounds = layoutBounds(snapshot: snapshot) {
            let padding: CGFloat = 70
            let w = max(size.width - padding * 2, 1)
            let h = max(size.height - padding * 2, 1)
            let x = padding + CGFloat((layout.x - bounds.minX) / max(bounds.width, 1)) * w
            let y = padding + CGFloat((layout.y - bounds.minY) / max(bounds.height, 1)) * h
            return CGPoint(x: x, y: y)
        }
        if let pos = fallbackPositions[node.nodeID],
           let fallbackBounds = fallbackLayoutBounds() {
            let padding: CGFloat = 70
            let w = max(size.width - padding * 2, 1)
            let h = max(size.height - padding * 2, 1)
            let x = padding + CGFloat((pos.x - fallbackBounds.minX) / max(fallbackBounds.width, 1)) * w
            let y = padding + CGFloat((pos.y - fallbackBounds.minY) / max(fallbackBounds.height, 1)) * h
            return CGPoint(x: x, y: y)
        }
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func fallbackLayoutBounds() -> (minX: Double, minY: Double, width: Double, height: Double)? {
        guard let first = fallbackPositions.values.first else { return nil }
        var minX = Double(first.x), maxX = minX
        var minY = Double(first.y), maxY = minY
        for p in fallbackPositions.values.dropFirst() {
            minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
            minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
        }
        return (minX, minY, maxX - minX, maxY - minY)
    }

    /// Run a hand-rolled force-directed layout on the current snapshot.
    /// Called whenever the snapshot's bt-core layout is empty so the
    /// canvas doesn't stack every node at the centre.
    private func recomputeFallbackLayout() {
        guard let snapshot,
              snapshot.layout?.nodes.isEmpty ?? true else {
            fallbackPositions = [:]
            return
        }
        // Seed nodes on a deterministic ring so the layout starts from
        // a useful prior — pure random init can take many more
        // iterations to detangle dense clusters.
        let nodeCount = snapshot.nodes.count
        guard nodeCount > 0 else {
            fallbackPositions = [:]
            return
        }
        var nodes: [ForceLayout.Node] = []
        nodes.reserveCapacity(nodeCount)
        let radius = 200.0
        for (i, node) in snapshot.nodes.enumerated() {
            let theta = 2 * .pi * Double(i) / Double(nodeCount)
            nodes.append(ForceLayout.Node(
                id: node.nodeID,
                position: CGPoint(x: radius * cos(theta), y: radius * sin(theta))
            ))
        }
        let edges = snapshot.edges.map { ForceLayout.Edge(source: $0.sourceID, target: $0.targetID) }
        var config = ForceLayout.Config()
        config.maxIterations = 60
        let outcome = ForceLayout.run(nodes: nodes, edges: edges, config: config)
        var dict: [String: CGPoint] = [:]
        dict.reserveCapacity(outcome.nodes.count)
        for n in outcome.nodes { dict[n.id] = n.position }
        fallbackPositions = dict
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

    /// Phase 2 — recent rows from `retrieval_log`. Refreshed on the
    /// same `reload` tick as the agent-status envelope.
    @State private var retrievalLog: DomeRpcClient.RetrievalLogEnvelope?

    /// Phase 3 — enrichment queue depth for the backfill chip in the
    /// system header. Polled alongside `retrievalLog`; the chip shows
    /// `queued + running` and hides when both are zero.
    @State private var queueDepth: DomeRpcClient.EnrichmentQueueDepth?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surfaceHeader(title: "Agent System", subtitle: "\(systemSubtitle) · \(domeScope.label)", isLoading: isLoading) {
                Task { await reload() }
            }
            Divider().overlay(Palette.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let depth = queueDepth, !depth.idle {
                        backfillChip(depth)
                    }
                    statusSection
                    embeddingsSection
                    contextPackSection
                    retrievalLogSection
                    retrievalSection
                }
                .padding(20)
            }
        }
        .background(Palette.background)
        .task(id: domeScope.id) { await reload() }
        .task { embeddingStats = DomeRpcClient.embeddingStats() }
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

    private var embeddingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Embeddings")
            if let stats = embeddingStats, !stats.modelCounts.isEmpty {
                ForEach(stats.modelCounts.sorted(by: { $0.key < $1.key }), id: \.key) { model, count in
                    HStack {
                        Text(model).font(Typography.monoCaption).foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Text("\(count) chunks").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
                Text("Total chunks: \(stats.total)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            } else {
                Text("No embedded chunks yet — ingest a codebase or write notes.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
            HStack(spacing: 10) {
                Button(bootstrapBusy ? "Re-embedding…" : "Bootstrap vectors") {
                    runBootstrap()
                }
                .buttonStyle(.borderless)
                .disabled(bootstrapBusy || ingestBusy)
                .help("Re-embed every existing note with the live Qwen3 model. Upgrades legacy noop@1 chunks.")

                Button(ingestBusy ? ingestButtonLabel : "Ingest codebase") {
                    runIngest()
                }
                .buttonStyle(.borderless)
                .disabled(bootstrapBusy || ingestBusy)
                .help("Recursively ingest a directory's source files as searchable notes (capped at 5000 files).")

                if ingestBusy {
                    Button("Cancel") {
                        DomeRpcClient.ingestCancel()
                    }
                    .buttonStyle(.borderless)
                    .help("Stop the in-flight ingest at the next file boundary. Files already created are kept.")
                }
            }
            if ingestBusy, let p = ingestProgress, p.total > 0 {
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
            }
            if let r = lastIngest {
                let suffix = r.capped
                    ? " (capped at 5000 files)"
                    : ((r.canceled ?? false) ? " (canceled)" : "")
                Text("Created \(r.created), skipped \(r.skipped)\(suffix)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .task(id: ingestBusy) { await pollIngestProgress() }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ingest"
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
            }
        }
    }

    private var contextPackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Context Packs")
            if let err = packError {
                Text(err)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
            }
            if let packs = envelope?.contextPacks, !packs.isEmpty {
                ForEach(packs) { pack in
                    contextPackRow(pack)
                    if let resolved = packResults[pack.contextID] {
                        citationsList(for: resolved)
                            .padding(.leading, 26)
                            .padding(.bottom, 6)
                    }
                }
            } else {
                Text("No context packs have been compacted yet.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func contextPackRow(_ pack: DomeRpcClient.ContextPackSummary) -> some View {
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
            if packBusy.contains(pack.contextID) {
                ProgressView().controlSize(.small)
            } else {
                Button("Resolve") {
                    Task { await resolvePack(pack) }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Resolve context pack \(pack.contextID)")
                Button("Compact") {
                    Task { await compactPack(pack, force: true) }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Compact context pack \(pack.contextID)")
            }
        }
        .padding(.vertical, 5)
    }

    private func citationsList(for result: ContextPackResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sources = result.sourceReferences, !sources.isEmpty {
                ForEach(sources) { source in
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                        Text(source.title ?? source.sourceRef)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                        if let link = ContextPackDeepLink.sourceLink(for: source) {
                            Button(action: {
                                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                            }) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Jump to \(source.title ?? source.sourceRef)")
                        }
                        Spacer()
                    }
                }
            } else if result.resolved {
                Text("Pack resolved · no citations recorded.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            } else if let next = result.recommendedNextSteps?.first {
                Text(next)
                    .font(Typography.caption)
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
        let fetched = await agentTask
        let log = await logTask
        queueDepth = await queueTask
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

    /// Phase 3 — backfill chip. Visible whenever the enrichment
    /// queue has any queued or running jobs. Hides as soon as the
    /// pipeline is idle (queued+running = 0). Displays raw counts so
    /// users can see the drain progressing without polling logs.
    private func backfillChip(_ depth: DomeRpcClient.EnrichmentQueueDepth) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Enrichment running")
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                let parts = [
                    "\(depth.queued) queued",
                    "\(depth.running) running",
                    "\(depth.done) done",
                    depth.failed > 0 ? "\(depth.failed) failed" : nil,
                ].compactMap { $0 }
                Text(parts.joined(separator: " · "))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surface)
        )
    }

    /// Phase 2 — recent retrieval-log rows. Header carries the
    /// consumption rate (fraction of logged calls whose pack was
    /// actually consumed via an `agent_used_context` event) and mean
    /// latency, the two numbers `dome-eval replay` reports.
    private var retrievalLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Retrieval Log")
            if let log = retrievalLog, !log.rows.isEmpty {
                HStack(spacing: 14) {
                    Text("\(log.n) rows").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    Text("consumed \(Int(log.consumptionRate * 100))%")
                        .font(Typography.caption)
                        .foregroundStyle(log.consumptionRate >= 0.5 ? Palette.success : Palette.textSecondary)
                    Text(String(format: "avg %.1f ms", log.meanLatencyMs))
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.bottom, 4)

                ForEach(log.rows.prefix(20)) { row in
                    retrievalLogRowView(row)
                    Divider().overlay(Palette.divider)
                }
                if log.rows.count > 20 {
                    Text("+ \(log.rows.count - 20) more · run `dome-eval replay --vault <db>` for full window")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            } else {
                Text("No retrieval calls logged yet — every `dome_search` writes one row here once the daemon serves a query with an actor.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func retrievalLogRowView(_ row: DomeRpcClient.RetrievalLogRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.wasConsumed ? "checkmark.circle" : "circle")
                .foregroundStyle(row.wasConsumed ? Palette.success : Palette.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.tool)
                        .font(Typography.monoCaption)
                        .foregroundStyle(Palette.textPrimary)
                    if let q = row.query, !q.isEmpty {
                        Text(q)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(row.actorKind)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text("·")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                    Text("\(row.knowledgeScope)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text("·")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                    Text("\(row.resultIDs.count) hits")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
            Text("\(row.latencyMs) ms")
                .font(Typography.monoCaption)
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.vertical, 5)
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
