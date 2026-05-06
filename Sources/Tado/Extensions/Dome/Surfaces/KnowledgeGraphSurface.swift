import AppKit
import Foundation
import SwiftUI

// MARK: - KnowledgeGraphSurface
//
// Knowledge → Graph: a tri-modal editorial surface for the bt-core
// vault graph. Three modes share focus + pin + path + search state
// and render the same `DomeRpcClient.graphSnapshot()` payload:
//
// - **Index** — typographic landing. Letter-bucket alphabetical
//   index of every visible node. Click an entry → Orbital opens
//   focused on that node.
// - **Graph** (orbital) — radial focus mode. Selected node sits at
//   the center; rings = hop distance via BFS, capped at 3 hops.
//   Hover previews neighbors, Shift+click pins, click recenters.
// - **Ledger** — adjacency matrix. Sortable by cluster / alpha /
//   degree / recency. Click a filled cell → Orbital recenters on
//   the row's node.
//
// The structure is ported from the v0.18 Knowledge Graph design
// system's three hi-fi pages (`The Index.html`, `Orbital.jsx`,
// `Ledger.jsx`). The paper-and-ink editorial palette (cream paper,
// ink, accent red, viridian, highlight) is rebranded to Tado's
// dark + ember:
//
// - paper / paper-2 / paper-3 → `bgPage` / `bgElev` / `bgRow` / `bgRowHi`
// - ink / ink-2 / ink-3 / ink-4 → `ink` / `ink2` / `ink3` / `ink4`
// - rule / hair → `ruleStrong` / `rule`
// - accent (red ink) → `accent` (Tado ember)
// - accent-2 (viridian) → `green` (Tado green)
// - highlight (yellow) → `warning` (Tado gold)
//
// Editorial cues from the source — italic emphasis on accent
// words, large italic letter buckets, dotted leaders between
// entry names and metadata, mono micro mast/foot rows — are
// preserved. Body type is rendered with the system serif design
// (resolves to New York / SF Pro Display Serif on macOS) so
// reading the index feels like reading a printed back-of-book
// page.
//
// Keyboard shortcuts (when this surface is on screen):
// - `I` / `G` / `L` — switch modes
// - `/` — focus search
// - `Escape` — clear path / clear search focus
struct KnowledgeGraphSurface: View {
    let domeScope: DomeScopeSelection

    enum Mode: String, CaseIterable, Identifiable {
        case index, orbital, ledger
        var id: String { rawValue }
        var label: String {
            switch self {
            case .index: return "Index"
            case .orbital: return "Graph"
            case .ledger: return "Ledger"
            }
        }
        var shortcutKey: KeyEquivalent {
            switch self {
            case .index: return "i"
            case .orbital: return "g"
            case .ledger: return "l"
            }
        }
    }

    @State private var mode: Mode = .index
    @State private var snapshot: DomeRpcClient.GraphSnapshot?
    @State private var isLoading = false

    // Search & focus / interaction
    @State private var search = ""
    @State private var liveSearch = ""
    @State private var searchOpen = false
    @FocusState private var searchFocused: Bool
    @State private var focusID: String?
    @State private var hoveredID: String?
    @State private var pinned: Set<String> = []
    @State private var pathStart: String?
    @State private var pathEnd: String?
    @State private var maxNodes: Double = 250

    // Local NSEvent monitor for keyboard shortcuts on this surface
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            appbar
            content
        }
        .background(Palette.bgPage)
        .task(id: domeScope.id) { await reload(force: false) }
        .task(id: search) { await reload(force: false) }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Appbar (mode picker + search + meta)

    private var appbar: some View {
        HStack(spacing: 14) {
            // Editorial brand block: "The Index" reads as a back-of-book
            // page header. Serif design + italic accent on the second
            // word is the editorial cue carried straight from the source
            // (the design's `.appbar-brand em`).
            HStack(spacing: 6) {
                Text("The")
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.ink2)
                Text("Index")
                    .font(.system(size: 16, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Palette.accent)
            }

            modePicker

            searchBox
                .frame(width: 280)

            Spacer(minLength: 12)

            // Live snapshot meta — mono micro caption with new ink tokens.
            // Three states: Index shows entry count, Orbital/Ledger show
            // either the focus name (when set) or visible totals.
            Group {
                if mode == .index {
                    Text("\(snapshot?.stats.visibleNodes ?? 0) entries")
                        .font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Palette.ink4)
                } else if let id = focusID, let n = snapshot?.nodes.first(where: { $0.nodeID == id }) {
                    HStack(spacing: 6) {
                        OverlineLabel("Focus", tint: Palette.ink4)
                        Text(displayName(n))
                            .font(.system(size: 13, weight: .regular, design: .serif).italic())
                            .foregroundStyle(Palette.ink)
                    }
                } else {
                    Text("\(snapshot?.stats.visibleNodes ?? 0) nodes · \(snapshot?.stats.visibleEdges ?? 0) ties")
                        .font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Palette.ink4)
                }
            }

            OutlineButton(
                icon: isLoading ? "hourglass" : "arrow.clockwise",
                size: .small,
                variant: .standard,
                action: { Task { await reload(force: true) } }
            )
            .disabled(isLoading)
            .help("Rebuild & refresh graph")
        }
        .padding(.horizontal, DK.pageGutter)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    /// Tri-modal segmented strip — three small OutlineButtons,
    /// active one in `.accent` variant. Keyboard shortcuts (i/g/l)
    /// preserved.
    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(Mode.allCases) { m in
                OutlineButton(
                    m.label,
                    size: .small,
                    variant: mode == m ? .accent : .standard,
                    action: { mode = m }
                )
                .keyboardShortcut(m.shortcutKey, modifiers: [])
            }
        }
    }

    private var searchBox: some View {
        HStack(spacing: 8) {
            Text("/")
                .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
            TextField("search docs, agents, projects, tags…", text: $liveSearch)
                .textFieldStyle(.plain)
                .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .focused($searchFocused)
                .onSubmit {
                    search = liveSearch
                    searchOpen = false
                    if let first = filteredSearch.first {
                        openFocus(first.nodeID)
                    }
                }
                .onChange(of: liveSearch) { _, _ in
                    searchOpen = !liveSearch.isEmpty
                }
                .overlay(alignment: .topLeading) {
                    if searchOpen && !filteredSearch.isEmpty {
                        searchResults
                            .offset(x: -10, y: 28)
                            .frame(width: 282)
                            .zIndex(50)
                    }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Palette.bgPage)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(searchFocused ? Palette.ruleStrong : Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    private var filteredSearch: [DomeRpcClient.GraphNode] {
        guard let snap = snapshot, !liveSearch.isEmpty else { return [] }
        let q = liveSearch.lowercased()
        return snap.nodes
            .filter {
                $0.label.lowercased().contains(q) || ($0.secondaryLabel?.lowercased().contains(q) ?? false)
            }
            .prefix(8)
            .map { $0 }
    }

    /// Type-ahead dropdown. Editorial: serif name with kind-class
    /// styling (italic for person, underline for tag, bold for project),
    /// trailing mono kind label.
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredSearch, id: \.nodeID) { node in
                Button(action: {
                    openFocus(node.nodeID)
                    liveSearch = ""
                    searchOpen = false
                    searchFocused = false
                }) {
                    let style = KnowledgeNodeStyle.from(node.kind)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(style.dotColor)
                            .frame(width: 6, height: 6)
                        Text(displayName(node))
                            .font(style.entryFont)
                            .foregroundStyle(Palette.ink)
                            .underline(style == .tag)
                        Spacer(minLength: 8)
                        Text(style.label)
                            .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(Palette.ink4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(hoveredID == node.nodeID ? Palette.bgRowHi : Color.clear)
                }
                .buttonStyle(.plain)
                .onHover { hovered in
                    if hovered { hoveredID = node.nodeID }
                    else if hoveredID == node.nodeID { hoveredID = nil }
                }
            }
        }
        .padding(.vertical, 4)
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.ruleStrong, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        .shadow(color: .black.opacity(0.45), radius: 8, x: 0, y: 4)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if let snap = snapshot, !snap.nodes.isEmpty {
            switch mode {
            case .index:
                KnowledgeIndexCover(
                    snapshot: snap,
                    onOpen: { openFocus($0) },
                    domeScope: domeScope
                )
            case .orbital:
                graphSplit(snap: snap, body: AnyView(
                    KnowledgeOrbital(
                        snapshot: snap,
                        focusID: focusID ?? snap.nodes.first?.nodeID ?? "",
                        pinned: pinned,
                        hoveredID: hoveredID,
                        pathTo: pathTo,
                        onFocus: { openFocus($0) },
                        onTogglePin: togglePin,
                        onHover: { hoveredID = $0 }
                    )
                ))
            case .ledger:
                graphSplit(snap: snap, body: AnyView(
                    KnowledgeLedger(
                        snapshot: snap,
                        focusID: focusID,
                        hoveredID: hoveredID,
                        onFocus: { openFocus($0) },
                        onHover: { hoveredID = $0 }
                    )
                ))
            }
        } else if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(Palette.accent)
                Text("Loading graph…")
                    .font(.system(size: 13, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Editorial empty state — large serif title + caption + dashed
            // top-rule help line. Mirrors the v0.18 page-empty pattern.
            VStack(spacing: 10) {
                Text("No entries yet")
                    .font(.system(size: 22, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Palette.ink)
                Text("Ingest a project or write a note to seed the graph.")
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func graphSplit(snap: DomeRpcClient.GraphSnapshot, body: AnyView) -> some View {
        HStack(spacing: 0) {
            body
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.bgPage)
            Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
            KnowledgeDetailPanel(
                snapshot: snap,
                focusID: focusID ?? snap.nodes.first?.nodeID ?? "",
                pinned: pinned,
                pathStart: pathStart,
                pathEnd: pathEnd,
                pathTo: pathTo,
                onFocus: { openFocus($0) },
                onTogglePin: togglePin,
                onSetPathStart: { pathStart = $0 },
                onSetPathEnd: { pathEnd = $0 },
                onClearPath: { pathStart = nil; pathEnd = nil }
            )
            .frame(width: 320)
        }
    }

    // MARK: - State actions

    private func openFocus(_ id: String) {
        focusID = id
        if mode == .index { mode = .orbital }
    }

    private func togglePin(_ id: String) {
        if pinned.contains(id) {
            pinned.remove(id)
        } else {
            pinned.insert(id)
        }
    }

    private var pathTo: [String]? {
        guard let start = pathStart, let end = pathEnd, let snap = snapshot else { return nil }
        return KnowledgeGraphMath.bfsPath(
            from: start,
            to: end,
            neighbors: KnowledgeGraphMath.neighborMap(snap.edges)
        ) ?? []
    }

    // MARK: - Reload

    private func reload(force: Bool) async {
        isLoading = true
        defer { isLoading = false }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = Int(maxNodes)
        let scope = domeScope
        let fetched = await Task.detached { () -> DomeRpcClient.GraphSnapshot? in
            if force { _ = DomeRpcClient.refreshGraph() }
            return DomeRpcClient.graphSnapshot(
                search: q.isEmpty ? nil : q,
                focusNodeID: nil,
                maxNodes: cap,
                includeTypes: nil,
                domeScope: scope
            )
        }.value
        guard let snap = fetched else { return }
        snapshot = snap
        // If focus drifted off-graph, reset
        if let fid = focusID, !snap.nodes.contains(where: { $0.nodeID == fid }) {
            focusID = snap.nodes.first?.nodeID
        }
        if focusID == nil {
            focusID = snap.nodes.first?.nodeID
        }
        // Clear path endpoints that fell out of the snapshot
        if let s = pathStart, !snap.nodes.contains(where: { $0.nodeID == s }) { pathStart = nil }
        if let e = pathEnd, !snap.nodes.contains(where: { $0.nodeID == e }) { pathEnd = nil }
    }

    // MARK: - Display helpers

    private func displayName(_ n: DomeRpcClient.GraphNode) -> String {
        n.label.isEmpty ? n.nodeID : n.label
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't intercept while typing in a text field
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder.isKind(of: NSText.self) {
                if event.keyCode == 53 { // Esc
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    return nil
                }
                return event
            }
            switch event.charactersIgnoringModifiers {
            case "/":
                searchFocused = true
                return nil
            case "i", "I":
                mode = .index
                return nil
            case "g", "G":
                mode = .orbital
                return nil
            case "l", "L":
                mode = .ledger
                return nil
            default:
                break
            }
            if event.keyCode == 53 { // Esc clears path
                pathStart = nil
                pathEnd = nil
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Index Cover (typographic landing)

/// Typographic landing reminiscent of the back-of-book index. Every
/// visible node is bucketed by first letter and laid into 4 columns
/// that flow alphabetically. Click any entry → focus + open Orbital.
///
/// Anatomy (top → bottom):
///
///   ┌────────────────────────────────────────────────┐
///   │  VAULT · 2026         X ENTRIES · Y TIES       │   masthead row 1
///   │                                                 │
///   │              The   *Index*                      │   serif title
///   │      A back-of-book to everything we know …     │   serif subtitle
///   │                                                 │
///   │  CURATED · APR 2026   PRESS / TO SEARCH · G FOR GRAPH   masthead row 2
///   ├─────────────────────────────────────────────────┤
///   │  A          F          K          P             │   4 col grid
///   │  …          …          …          …             │
///   │  E          J          O          T             │
///   ├─────────────────────────────────────────────────┤
///   │  FRONTISPIECE   SEE ALSO ↦  Orbital · Ledger   P. i  │ footer
///   └─────────────────────────────────────────────────┘
private struct KnowledgeIndexCover: View {
    let snapshot: DomeRpcClient.GraphSnapshot
    let onOpen: (String) -> Void
    let domeScope: DomeScopeSelection

    private var degrees: [String: Int] {
        KnowledgeGraphMath.degreeMap(snapshot.edges)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                masthead
                cols
                footer
            }
            .padding(.horizontal, 56)
            .padding(.top, 40)
            .padding(.bottom, 60)
            // Fill the full viewport — the LazyVGrid below uses an
            // adaptive column policy, so wider windows auto-grow to
            // 4-5+ columns and narrow ones collapse to 1-2. The
            // previous 1,280 px cap was leaving most of the page empty
            // on standard macOS windows.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bgPage)
    }

    // MARK: Masthead

    private var masthead: some View {
        VStack(spacing: 0) {
            // Top row — vault + counts. Strong rule above to anchor.
            HStack {
                Text(volumeLabel)
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Palette.ink3)
                Spacer()
                Text("\(snapshot.stats.totalNodes) ENTRIES · \(snapshot.stats.totalEdges) TIES")
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.ruleStrong).frame(height: 1.4)
            }

            // Title — "The Index" — serif, italic accent on the noun.
            HStack(spacing: 8) {
                Text("The")
                    .font(.system(size: 84, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.ink)
                Text("Index")
                    .font(.system(size: 84, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Palette.accent)
            }
            .padding(.top, 20)
            .padding(.bottom, 6)

            // Subtitle — italic accent words emphasise the kinds.
            (Text("A back-of-book to everything we know — ")
                + Text("docs").italic()
                + Text(", ")
                + Text("agents").italic()
                + Text(", ")
                + Text("projects").italic()
                + Text(", ")
                + Text("tags").italic()
                + Text(". Choose any line to drop into the graph."))
                .font(.system(size: 15, weight: .regular, design: .serif))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 18)

            // Bottom mast row — curated date + kbd hints.
            HStack {
                Text("CURATED · \(curatedDateLabel)")
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Palette.ink3)
                Spacer()
                HStack(spacing: 6) {
                    Text("PRESS")
                        .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Palette.ink3)
                    KbdKey(label: "/")
                    Text("TO SEARCH ·")
                        .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Palette.ink3)
                    KbdKey(label: "G")
                    Text("FOR GRAPH")
                        .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Palette.ink3)
                }
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.rule).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.ruleStrong).frame(height: 1.4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 28)
    }

    /// Vault scope label — replaces the source's "VOL. I · 2026"
    /// printer's mark with one that reads native to Tado.
    private var volumeLabel: String {
        let year = Calendar.current.component(.year, from: Date())
        switch domeScope {
        case .global: return "VAULT · GLOBAL · \(year)"
        case .project: return "VAULT · PROJECT · \(year)"
        }
    }

    private var curatedDateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: Date()).uppercased()
    }

    // MARK: Columns
    //
    // Responsive multi-column flow. Uses `LazyVGrid` with an adaptive
    // column policy — the grid computes column count from the
    // viewport width (`min 280pt` per column with 36pt gutters), so
    // narrow windows / zoomed-in views see fewer columns and wide
    // ones see more, automatically. Each letter gets a `Section`
    // with a header that spans the full row; entries flow into
    // adaptive columns within the section.
    //
    // The previous fixed-4-column allocator failed badly on
    // unbalanced data (one mega-bucket like "T" with 1,500 entries
    // would push everything into column 0) and didn't respond to
    // window size at all.

    private var cols: some View {
        let groups = letterGroups()
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 36, alignment: .topLeading)],
            alignment: .leading,
            spacing: 6,
            pinnedViews: []
        ) {
            ForEach(groups, id: \.letter) { bucket in
                Section {
                    ForEach(bucket.nodes, id: \.nodeID) { n in
                        EntryRow(
                            node: n,
                            degree: degrees[n.nodeID] ?? 0,
                            onOpen: onOpen
                        )
                    }
                } header: {
                    bucketHeader(bucket.letter)
                }
            }
        }
        .padding(.top, 24)
    }

    /// Letter divider — renders as the section header in the
    /// adaptive grid, where it naturally spans every column on its
    /// row. Kept large + italic so the page reads as an editorial
    /// back-of-book index.
    private func bucketHeader(_ letter: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Some breathing room above each new letter section so the
            // grid doesn't crowd the previous bucket's last entry.
            Spacer().frame(height: 18)
            Text(letter)
                .font(.system(size: 40, weight: .regular, design: .serif).italic())
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Palette.ruleStrong).frame(height: 1.25)
                }
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgPage)
    }

    /// Single flat list of letter buckets in alphabetical order. The
    /// LazyVGrid above takes care of distributing entries into
    /// columns; we no longer pre-allocate columns ourselves.
    private func letterGroups() -> [LetterBucket] {
        let sorted = snapshot.nodes.sorted {
            indexKey($0.label).localizedCaseInsensitiveCompare(indexKey($1.label)) == .orderedAscending
        }
        var byLetter: [String: [DomeRpcClient.GraphNode]] = [:]
        for n in sorted {
            let key = String(indexKey(n.label).prefix(1)).uppercased()
            let bucket = key.isEmpty ? "·" : key
            byLetter[bucket, default: []].append(n)
        }
        return byLetter.keys.sorted().map { L in
            LetterBucket(letter: L, nodes: byLetter[L] ?? [])
        }
    }

    private func indexKey(_ s: String) -> String {
        // Strip leading # / · / @ so #design groups under D, etc.
        var t = s
        while let first = t.first, first == "#" || first == "·" || first == "@" {
            t.removeFirst()
        }
        return t
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.ruleStrong).frame(height: 1)
            HStack {
                Text("FRONTISPIECE")
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Palette.ink4)
                Spacer()
                HStack(spacing: 6) {
                    Text("SEE ALSO ↦")
                        .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(Palette.ink4)
                    Text("Orbital · Ledger")
                        .font(.system(size: 12, weight: .regular, design: .serif).italic())
                        .foregroundStyle(Palette.ink2)
                }
                Spacer()
                Text("P. i")
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Palette.ink4)
            }
            .padding(.vertical, 10)
        }
        .padding(.top, 36)
    }

    // MARK: Bucket types

    private struct LetterBucket {
        let letter: String
        let nodes: [DomeRpcClient.GraphNode]
    }

    /// One line of the index — name (kind-styled) + dotted leader +
    /// kind label + degree count box. The kind label picks up the
    /// kind's editorial tint (green / accent / gold / ink2) so the
    /// reader can scan a column for "where are the projects" without
    /// reading every line.
    private struct EntryRow: View {
        let node: DomeRpcClient.GraphNode
        let degree: Int
        let onOpen: (String) -> Void
        @State private var hovered = false

        var body: some View {
            let style = KnowledgeNodeStyle.from(node.kind)
            Button(action: { onOpen(node.nodeID) }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(node.label)
                        .font(style.entryFont)
                        .foregroundStyle(hovered ? Palette.accent : Palette.ink)
                        .underline(style == .tag)
                        .lineLimit(1)
                        .layoutPriority(1)
                    DottedLeader()
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Palette.rule)
                        .padding(.bottom, 4)
                    HStack(spacing: 6) {
                        Text(style.label)
                            .font(Font.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(style.dotColor.opacity(0.85))
                        Text("\(degree)")
                            .font(Font.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.4)
                            .foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: DK.radius)
                                    .stroke(Palette.rule, lineWidth: DK.ruleW)
                            )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? Palette.bgRowHi.opacity(0.45) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }
}

// MARK: - DottedLeader

/// Editorial dotted-line leader between an entry name and its trailing
/// metadata. Renders 1 px round dots every 3 px so the leader reads
/// like a printed back-of-book index instead of a UI separator.
private struct DottedLeader: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.midY
        let dot: CGFloat = 1.0
        let step: CGFloat = 3.0
        var x: CGFloat = 0
        while x < rect.width {
            p.addEllipse(in: CGRect(x: x, y: y - dot / 2, width: dot, height: dot))
            x += step
        }
        return p
    }
}

// MARK: - Orbital (radial graph)

/// Radial graph with hop rings. The focused node sits at the center;
/// every other node is placed on one of 3 rings keyed to its BFS hop
/// distance from focus. The backing geometry is a unit-100 SVG drawn
/// into a SwiftUI `Canvas` so the layout stays vector-crisp at any
/// zoom / window size.
///
/// Rendering layers (bottom → top):
///   1. radial spokes (24, evenly spaced)
///   2. hop rings (ring 1 solid, rings 2 + 3 dashed)
///   3. ring labels ("1 HOP" / "2 HOPS" / "3 HOPS")
///   4. edges
///   5. nodes (ring 3 → ring 2 → ring 1 → focus, so focus draws last)
/// Network-style graph view. **Renders every node in the snapshot by
/// default**, positioned via the bt-core layout (or a deterministic
/// sunflower-spiral fallback when the daemon hasn't computed coords).
/// Pan with drag or trackpad scroll, zoom with pinch or shift+scroll.
/// Filter by kind via the chip strip; flip "Neighbours of focus" on
/// when you want the old BFS-3-hop view back.
///
/// Why the rebuild from BFS-orbital → all-nodes-network: the v0.18
/// orbital filtered to focus + 3 hops, which made vaults with 1,000+
/// disconnected components look like "the graph has one node".
/// Showing all by default + filtering as you work matches how every
/// other graph tool the user has touched behaves, and the shipped
/// `snapshot.layout` already provides force-directed-quality coords.
private struct KnowledgeOrbital: View {
    let snapshot: DomeRpcClient.GraphSnapshot
    let focusID: String
    let pinned: Set<String>
    let hoveredID: String?
    let pathTo: [String]?
    let onFocus: (String) -> Void
    let onTogglePin: (String) -> Void
    let onHover: (String?) -> Void

    /// Empty = every kind is shown. Adding a style here hides nodes
    /// of that style (4 chips on the toolbar toggle membership).
    @State private var disabledStyles: Set<KnowledgeNodeStyle> = []
    /// Opt-in BFS-3-hop filter — restores the v0.18 "orbital around
    /// focus" view when the user wants to drill in.
    @State private var neighborhoodOnly = false

    // Pan / zoom state
    @State private var zoom: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero
    @GestureState private var magnifyDelta: CGFloat = 1.0
    @State private var hoveringCanvas = false
    @State private var scrollMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .topLeading) {
                graphCanvas
                statusOverlay
                kindLegend
            }
        }
        .onAppear { installScrollMonitor() }
        .onDisappear { removeScrollMonitor() }
    }

    // MARK: - Filtering

    /// All snapshot nodes after kind + neighbourhood filters.
    private var visibleNodes: [DomeRpcClient.GraphNode] {
        var nodes = snapshot.nodes
        if !disabledStyles.isEmpty {
            nodes = nodes.filter {
                !disabledStyles.contains(KnowledgeNodeStyle.from($0.kind))
            }
        }
        if neighborhoodOnly, !focusID.isEmpty {
            let neighbors = KnowledgeGraphMath.neighborMap(snapshot.edges)
            let levels = KnowledgeGraphMath.bfsLevels(from: focusID, neighbors: neighbors, cap: 3)
            let allowed = Set(levels.keys)
            nodes = nodes.filter { allowed.contains($0.nodeID) }
        }
        return nodes
    }

    /// Edges between visible nodes only — keeps the canvas honest
    /// (no dangling edges to hidden endpoints).
    private var visibleEdges: [DomeRpcClient.GraphEdge] {
        let visibleIDs = Set(visibleNodes.map(\.nodeID))
        return snapshot.edges.filter {
            visibleIDs.contains($0.sourceID) && visibleIDs.contains($0.targetID)
        }
    }

    // MARK: - Toolbar (filters + zoom)

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                OverlineLabel("Show", tint: Palette.ink4)
                ForEach(KnowledgeNodeStyle.allCases, id: \.self) { style in
                    let on = !disabledStyles.contains(style)
                    Button(action: { toggleStyle(style) }) {
                        HStack(spacing: 5) {
                            Circle().fill(style.dotColor).frame(width: 6, height: 6)
                            Text(style.pluralLabel)
                                .font(Font.system(size: 10, weight: .medium, design: .monospaced))
                                .tracking(0.5)
                                .foregroundStyle(on ? Palette.ink : Palette.ink4)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(on ? Palette.bgRowHi : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: DK.radius)
                                .stroke(on ? Palette.rule : Palette.rule.opacity(0.5), lineWidth: DK.ruleW)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
                        .opacity(on ? 1.0 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Hide \(style.pluralLabel)" : "Show \(style.pluralLabel)")
                }
            }

            Spacer()

            OutlineButton(
                neighborhoodOnly ? "Focus 3-hop" : "All nodes",
                size: .small,
                variant: neighborhoodOnly ? .accent : .standard,
                action: { neighborhoodOnly.toggle() }
            )
            .help("Off (default): show every node. On: BFS-3-hop neighbourhood of the focused node only.")

            HStack(spacing: 4) {
                OutlineButton(
                    icon: "minus.magnifyingglass",
                    size: .small,
                    variant: .standard,
                    action: { withAnimation(.easeOut(duration: 0.15)) { zoom = clampZoom(zoom / 1.2) } }
                )
                Text("\(Int((zoom * magnifyDelta) * 100))%")
                    .font(Font.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
                    .frame(width: 42, alignment: .center)
                OutlineButton(
                    icon: "plus.magnifyingglass",
                    size: .small,
                    variant: .standard,
                    action: { withAnimation(.easeOut(duration: 0.15)) { zoom = clampZoom(zoom * 1.2) } }
                )
                OutlineButton(
                    icon: "arrow.up.left.and.down.right.magnifyingglass",
                    size: .small,
                    variant: .standard,
                    action: { resetView() }
                )
                .help("Reset zoom and pan")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private func toggleStyle(_ s: KnowledgeNodeStyle) {
        if disabledStyles.contains(s) {
            disabledStyles.remove(s)
        } else {
            disabledStyles.insert(s)
        }
    }

    private func clampZoom(_ v: CGFloat) -> CGFloat { min(max(v, 0.2), 8.0) }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1.0
            dragOffset = .zero
        }
    }

    // MARK: - Status overlay (top-left)

    private var statusOverlay: some View {
        let visible = visibleNodes.count
        let total = snapshot.stats.totalNodes
        let edges = visibleEdges.count
        return HStack(spacing: 8) {
            OverlineLabel("Graph", tint: Palette.ink4)
            Text("\(visible) of \(total) nodes · \(edges) ties")
                .font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(Palette.ink3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
        .padding(.top, 14)
        .padding(.leading, 14)
    }

    // MARK: - Kind legend (bottom)

    private var kindLegend: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                legendChip(.project, label: "project")
                legendChip(.person, label: "agent")
                legendChip(.doc, label: "doc")
                legendChip(.tag, label: "tag")
                Spacer()
                Text("drag to pan · pinch or ⇧-scroll to zoom · ⇧-click to pin")
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Palette.ink4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Palette.bgElev.opacity(0.85))
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }
        }
    }

    private func legendChip(_ style: KnowledgeNodeStyle, label: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                miniShape(style)
                    .fill(style.fillColor(focused: false))
                    .frame(width: 10, height: 10)
                miniShape(style)
                    .stroke(style.dotColor, lineWidth: 1.2)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 14, height: 14)
            Text(label)
                .font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(Palette.ink3)
        }
    }

    private func miniShape(_ style: KnowledgeNodeStyle) -> AnyShape {
        switch style {
        case .project: return AnyShape(Rectangle())
        case .tag: return AnyShape(Capsule())
        case .person: return AnyShape(Circle())
        case .doc: return AnyShape(DiamondShape())
        }
    }

    // MARK: - Canvas

    private var graphCanvas: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let nodes = visibleNodes
            let edges = visibleEdges
            let degrees = KnowledgeGraphMath.degreeMap(snapshot.edges)
            let layoutMap = computeLayoutMap(nodes: nodes)
            let positions = computeViewPositions(layout: layoutMap, viewport: viewport, padding: 60)
            let appliedZoom = zoom * magnifyDelta
            let panOffset = CGSize(
                width: dragOffset.width + dragDelta.width,
                height: dragOffset.height + dragDelta.height
            )
            let pathSet = Set(pathTo ?? [])

            ZStack {
                Palette.bgPage
                    .contentShape(Rectangle())
                    .onTapGesture { /* deselect could go here later */ }

                ZStack {
                    // Edge layer — all in one Canvas pass for speed at
                    // the 1k-edge scale Tado vaults regularly hit.
                    Canvas { ctx, _ in
                        for edge in edges {
                            guard let pa = positions[edge.sourceID],
                                  let pb = positions[edge.targetID] else { continue }
                            let isPath = pathSet.contains(edge.sourceID) && pathSet.contains(edge.targetID)
                            let incidentFocus = edge.sourceID == focusID || edge.targetID == focusID
                            let incidentHover = edge.sourceID == (hoveredID ?? "") || edge.targetID == (hoveredID ?? "")

                            // Ambient floor lifted from 0.5 / 0.6 → 1.2 / 0.85
                            // so connections read as solid lines, not whisper hints.
                            // Focus + hover ramps stay strictly above the floor.
                            var color = Palette.rule.opacity(0.85)
                            var lineWidth: CGFloat = 1.2
                            if isPath { color = Palette.accent; lineWidth = 2.6 }
                            else if incidentFocus { color = Palette.ink2; lineWidth = 2.0 }
                            else if incidentHover { color = Palette.ink3; lineWidth = 1.6 }

                            var p = Path()
                            p.move(to: pa)
                            p.addLine(to: pb)
                            ctx.stroke(p, with: .color(color), lineWidth: lineWidth)

                            // Endpoint dots — visually anchor each edge to its
                            // nodes so connections look attached, not floating.
                            // Radius scales with applied zoom and clamps to
                            // [0.8, 2.5] so dots stay readable at zoom 0.3
                            // without dominating the canvas at zoom 1.6+.
                            let dotRadius: CGFloat = max(0.8, min(2.5, 2.0 * appliedZoom))
                            var dots = Path()
                            dots.addEllipse(in: CGRect(
                                x: pa.x - dotRadius, y: pa.y - dotRadius,
                                width: dotRadius * 2, height: dotRadius * 2
                            ))
                            dots.addEllipse(in: CGRect(
                                x: pb.x - dotRadius, y: pb.y - dotRadius,
                                width: dotRadius * 2, height: dotRadius * 2
                            ))
                            ctx.fill(dots, with: .color(color))
                        }
                    }

                    // Node layer — every visible node, sized by degree.
                    ForEach(nodes, id: \.nodeID) { node in
                        if let pos = positions[node.nodeID] {
                            OrbitalNode(
                                node: node,
                                degree: degrees[node.nodeID] ?? 0,
                                position: pos,
                                isFocus: node.nodeID == focusID,
                                isPinned: pinned.contains(node.nodeID),
                                isHovered: hoveredID == node.nodeID,
                                isInPath: pathSet.contains(node.nodeID),
                                appliedZoom: appliedZoom,
                                onClick: { shift in
                                    if shift { onTogglePin(node.nodeID) }
                                    else { onFocus(node.nodeID) }
                                },
                                onHover: { h in onHover(h ? node.nodeID : nil) }
                            )
                        }
                    }
                }
                .scaleEffect(appliedZoom, anchor: .center)
                .offset(panOffset)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .updating($dragDelta) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            dragOffset.width += value.translation.width
                            dragOffset.height += value.translation.height
                        }
                )
                .gesture(
                    MagnifyGesture()
                        .updating($magnifyDelta) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            zoom = clampZoom(zoom * value.magnification)
                        }
                )
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { hoveringCanvas = true }
                else { hoveringCanvas = false }
            }
        }
    }

    // MARK: - Layout math

    private struct LayoutMap {
        var raw: [String: CGPoint]
        var minX: Double
        var minY: Double
        var width: Double
        var height: Double
    }

    /// Per-node raw coordinates: bt-core layout when available,
    /// sunflower-spiral fallback otherwise. The fallback is
    /// deterministic by index in the sorted-node list, so it stays
    /// stable across re-renders.
    private func computeLayoutMap(nodes: [DomeRpcClient.GraphNode]) -> LayoutMap {
        var raw: [String: CGPoint] = [:]
        let phi = (1.0 + sqrt(5.0)) / 2.0
        let count = max(nodes.count, 1)
        let layout = snapshot.layout

        for (idx, node) in nodes.enumerated() {
            if let p = layout?.nodes[node.nodeID] {
                raw[node.nodeID] = CGPoint(x: p.x, y: p.y)
            } else {
                // Sunflower / golden-angle spiral. sqrt(i/count) gives
                // an even areal density; the golden angle keeps any
                // two nodes from landing on the same radial.
                let i = Double(idx) + 0.5
                let angle = i * 2 * .pi / phi
                let radius = sqrt(i / Double(count)) * 100
                raw[node.nodeID] = CGPoint(
                    x: cos(angle) * radius,
                    y: sin(angle) * radius
                )
            }
        }

        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for (_, p) in raw {
            minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
            minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
        }
        if !minX.isFinite { minX = -50; maxX = 50; minY = -50; maxY = 50 }
        return LayoutMap(
            raw: raw,
            minX: minX,
            minY: minY,
            width: max(maxX - minX, 1),
            height: max(maxY - minY, 1)
        )
    }

    /// Map raw layout coords into viewport coords with `padding` on
    /// every edge. Callers can then apply zoom/pan as a transform on
    /// top.
    private func computeViewPositions(
        layout: LayoutMap,
        viewport: CGSize,
        padding: CGFloat
    ) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        let w = max(viewport.width - padding * 2, 100)
        let h = max(viewport.height - padding * 2, 100)
        for (id, p) in layout.raw {
            let nx = padding + CGFloat((Double(p.x) - layout.minX) / layout.width) * w
            let ny = padding + CGFloat((Double(p.y) - layout.minY) / layout.height) * h
            result[id] = CGPoint(x: nx, y: ny)
        }
        return result
    }

    // MARK: - Scroll-wheel pan / zoom

    /// Trackpad scroll-wheel monitor. Shift- or Cmd-modified scroll =
    /// zoom (matches CanvasView and the original Knowledge Graph
    /// surface); bare scroll = pan.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard self.hoveringCanvas else { return event }
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
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
    }
}

private struct OrbitalNode: View {
    let node: DomeRpcClient.GraphNode
    let degree: Int
    let position: CGPoint
    let isFocus: Bool
    let isPinned: Bool
    let isHovered: Bool
    let isInPath: Bool
    let appliedZoom: CGFloat
    let onClick: (Bool) -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        let style = KnowledgeNodeStyle.from(node.kind)
        // Size scales with degree — high-degree hubs read as
        // important, peripheral leaf nodes stay small. The sqrt
        // damping keeps a degree-1000 hub from being a 100px disk.
        let degreePart = min(sqrt(Double(degree)) * 2.5, 16)
        let baseSize: CGFloat = isFocus ? 22 : CGFloat(8 + degreePart)
        let ringStroke: Color = {
            if isInPath { return Palette.accent }
            if isFocus { return Palette.accent }
            if isHovered { return Palette.ink }
            return style.dotColor
        }()

        let s = shape
        VStack(spacing: 4) {
            ZStack {
                if isPinned {
                    Circle()
                        .stroke(Palette.accent, lineWidth: 1.5)
                        .frame(width: baseSize * 1.9, height: baseSize * 1.9)
                }
                if isFocus {
                    Circle()
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: baseSize * 2.2, height: baseSize * 2.2)
                }
                s.fill(style.fillColor(focused: isFocus))
                    .frame(width: baseSize, height: baseSize)
                s.stroke(ringStroke, lineWidth: isFocus || isInPath || isHovered ? 2 : 1.2)
                    .frame(width: baseSize, height: baseSize)
            }
            .frame(width: baseSize * 2.4, height: baseSize * 2.4)

            if shouldShowLabel {
                Text(basename(node.label))
                    .font(labelFont)
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .position(position)
        .onTapGesture {
            onClick(NSEvent.modifierFlags.contains(.shift))
        }
        .onHover { onHover($0) }
        .help("\(KnowledgeNodeStyle.from(node.kind).label) · \(node.label)")
    }

    /// Knowledge graph nodes are uniform circles regardless of kind.
    /// Kind is communicated by fill/stroke colour from
    /// `KnowledgeNodeStyle`; the legend chips keep their distinct
    /// shapes so the operator still has a reading aid.
    private var shape: AnyShape { AnyShape(Circle()) }

    /// Per the v0.17.x graph UX brief: every node's basename is
    /// always visible. Hover/zoom-gated labels were too easy to miss
    /// — operators kept asking "which file is this circle?".
    private var shouldShowLabel: Bool { true }

    /// File-path → basename. `Sources/Foo/Bar.swift` → `Bar.swift`.
    /// Plain non-path labels pass through unchanged. Mirrors
    /// `KnowledgeLedger.shortLabel` (which is private to its parent
    /// struct and not reusable from here).
    private func basename(_ label: String) -> String {
        if let last = label.split(separator: "/").last, last.count < label.count {
            return String(last)
        }
        return label
    }

    private var labelFont: Font {
        if isFocus { return .system(size: 14, weight: .semibold, design: .serif) }
        // P5 hover legibility — bump hovered + path-resident labels
        // to 12pt medium so they read clearly when the operator is
        // mousing across the canvas, even at default zoom.
        if isHovered || isInPath { return .system(size: 12, weight: .medium, design: .monospaced) }
        if degree >= 12 { return .system(size: 11, weight: .regular, design: .monospaced) }
        return .system(size: 10, weight: .regular, design: .monospaced)
    }

    private var labelColor: Color {
        if isFocus { return Palette.ink }
        // Full ink on hover / path so the active node + its lineage
        // pop against the muted ambient labels around them.
        if isHovered || isInPath { return Palette.ink }
        if degree >= 12 { return Palette.ink }
        return Palette.ink2
    }
}

/// Diamond glyph used for "doc"-class nodes — rotated square that
/// echoes the design's `M -r 0 L 0 -r L r 0 L 0 r Z` SVG path.
private struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        p.move(to: CGPoint(x: cx, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: cy))
        p.addLine(to: CGPoint(x: cx, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: cy))
        p.closeSubpath()
        return p
    }
}

// MARK: - Ledger (adjacency matrix)

/// Adjacency matrix view. Rows + columns are the same set of nodes
/// in the chosen ordering (cluster / alpha / degree / recency); a
/// filled cell `(i,j)` means there's an edge between `nodes[i]` and
/// `nodes[j]`. Click any filled cell → recenter Orbital on row's
/// node. Hover any cell → readout shows pair + tie state.
///
/// **Hard-set spatial structure** — the matrix has fixed cell sizes
/// (40 px square) and a fixed row-header column (260 px) so the
/// reading rhythm is identical at every dataset size. When the graph
/// has more than `Self.maxNodes` (= 30) nodes the matrix bails to a
/// dedicated empty state and asks the user to narrow with search;
/// past that point the cells are sub-legible and the view stops
/// being a useful overview. This is the ledger's contract: *fewer
/// nodes, fully readable* — not *more nodes, less legible*.
private struct KnowledgeLedger: View {
    let snapshot: DomeRpcClient.GraphSnapshot
    let focusID: String?
    let hoveredID: String?
    let onFocus: (String) -> Void
    let onHover: (String?) -> Void

    enum Order: String, CaseIterable, Identifiable {
        case cluster, alpha, degree, recency
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @State private var order: Order = .cluster
    @State private var hoverCell: (Int, Int)?
    /// Tracks the body pane's current scroll offset so the column-
    /// header pane (X axis) and row-header pane (Y axis) can mirror
    /// it. Reverse direction is intentionally NOT wired — the header
    /// panes are sticky-by-design (see P4 of the v0.17.x ledger UX
    /// brief). Updated via `LedgerScrollOffsetKey` preference reads.
    @State private var bodyOffset: CGPoint = .zero

    /// PreferenceKey for propagating the body ScrollView's content
    /// origin (in its named coordinate space) up to the parent so we
    /// can mirror it onto the header panes via .offset().
    private struct LedgerScrollOffsetKey: PreferenceKey {
        static var defaultValue: CGPoint = .zero
        static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
            value = nextValue()
        }
    }

    /// Soft cap — the matrix renders at most this many nodes regardless
    /// of how big the snapshot is, scrolling internally to handle
    /// everything inside the cap. Raised from 30 → 120 in v0.18.2:
    /// at the new 48px cell stride, 120 nodes is ~5,800 px wide which
    /// the inner ScrollView pans freely. Above the cap we show a
    /// small banner explaining the situation; nothing hard-blocks.
    private static let maxNodes: Int = 120

    /// Fixed cell size — bumped from 40 → 48 so an "on" pip + 4 px
    /// inset padding still leaves a 40-px clickable target. At 120
    /// nodes the full body reaches 5,760 px — comfortably scrollable.
    private static let cellSize: CGFloat = 48
    /// Row-header column width. Bumped to 300 px so long doc paths
    /// like `tado-core/crates/bt-core/src/notes/search.rs` actually
    /// read instead of getting middle-truncated to nothing.
    private static let rowHeaderWidth: CGFloat = 300
    /// Column-header height — increased to give the rotated label a
    /// full 160 px before it bumps into the corner cell.
    private static let colHeaderHeight: CGFloat = 160

    private var orderedNodes: [DomeRpcClient.GraphNode] {
        let degrees = KnowledgeGraphMath.degreeMap(snapshot.edges)
        switch order {
        case .alpha:
            return snapshot.nodes.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        case .degree:
            return snapshot.nodes.sorted { (degrees[$0.nodeID] ?? 0) > (degrees[$1.nodeID] ?? 0) }
        case .recency:
            return snapshot.nodes.sorted { ($0.sortTime ?? .distantPast) > ($1.sortTime ?? .distantPast) }
        case .cluster:
            return snapshot.nodes.sorted { (a, b) in
                let oa = clusterRank(a.kind)
                let ob = clusterRank(b.kind)
                if oa != ob { return oa < ob }
                return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            }
        }
    }

    private func clusterRank(_ kind: String) -> Int {
        switch KnowledgeNodeStyle.from(kind) {
        case .project: return 0
        case .person: return 1
        case .doc: return 2
        case .tag: return 3
        }
    }

    /// Nodes the matrix actually renders — capped at `Self.maxNodes`.
    /// Larger snapshots show a soft banner above the matrix so the
    /// user knows they're looking at a slice, but the matrix is
    /// still rendered (it scrolls).
    private var displayedNodes: [DomeRpcClient.GraphNode] {
        Array(orderedNodes.prefix(Self.maxNodes))
    }

    private var truncated: Bool {
        orderedNodes.count > Self.maxNodes
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            if truncated { truncationBanner }
            matrixArea
            readout
        }
        .background(Palette.bgPage)
    }

    // MARK: Toolbar (order picker + matrix dimensions)

    private var bar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                OverlineLabel("Order", tint: Palette.ink4)
                ForEach(Order.allCases) { o in
                    OutlineButton(
                        o.label,
                        size: .small,
                        variant: order == o ? .accent : .standard,
                        action: { order = o }
                    )
                }
            }
            Spacer()
            // P5 discoverability hint — the three-pane layout looks
            // identical to the old single-ScrollView ledger until you
            // try to scroll, so spell out the new affordance.
            Text("Drag the body — headers follow")
                .font(Font.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(Palette.ink4)
                .help("Drag inside the matrix body; the row and column headers slide in lockstep.")
            Text(matrixDimsLabel)
                .font(Font.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Palette.ink4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    /// Top-bar dimension label — shows shown / total when capped.
    private var matrixDimsLabel: String {
        let shown = displayedNodes.count
        let total = orderedNodes.count
        if truncated {
            return "\(shown) of \(total) nodes · \(snapshot.edges.count) ties"
        }
        return "\(total) nodes · \(snapshot.edges.count) ties"
    }

    /// Soft banner shown above the matrix when the graph is larger
    /// than `Self.maxNodes`. Replaces the previous hard-block empty
    /// state — operators can still see the matrix, they just see it
    /// in chunks.
    private var truncationBanner: some View {
        HStack(spacing: 10) {
            OverlineLabel("Window", tint: Palette.warning)
            (
                Text("Showing the first ")
                + Text("\(Self.maxNodes)").italic().foregroundColor(Palette.ink)
                + Text(" of ")
                + Text("\(orderedNodes.count)").italic().foregroundColor(Palette.ink)
                + Text(" nodes in this order. Narrow with ")
                + Text("/")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.accent)
                + Text(" or change ordering above to see different slices.")
            )
            .font(.system(size: 12, weight: .regular, design: .serif))
            .foregroundColor(Palette.ink2)
            .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.bgElev.opacity(0.7))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    // MARK: Matrix (capped at maxNodes; soft banner for the rest)

    private var matrixArea: some View {
        // Use displayedNodes (capped at maxNodes) — keeps the matrix
        // legible at any vault size; the truncation banner above
        // surfaces the cap to the operator.
        let nodes = displayedNodes
        let N = nodes.count
        let adj = adjacencyMatrix(nodes)
        let degrees = KnowledgeGraphMath.degreeMap(snapshot.edges)
        let cell = Self.cellSize
        let rowH = Self.colHeaderHeight
        let rowW = Self.rowHeaderWidth
        let bodyW = cell * CGFloat(N)
        let bodyH = cell * CGFloat(N)

        // Three-pane sticky-scroll layout (operator brief, v0.17.x):
        //   ┌────────┬───────────────────────┐
        //   │ corner │ colHeaderScroll       │  .horizontal axis only
        //   ├────────┼───────────────────────┤
        //   │ rowHdr │ bodyScroll            │  .horizontal + .vertical
        //   │ Scroll │                       │
        //   │ .vert  │                       │
        //   └────────┴───────────────────────┘
        // P3 lays out the panes; P4 wires their scroll synchronization
        // so dragging the body drives the two header panes in lockstep.
        // Each pane lives in its own helper so the SwiftUI type-checker
        // doesn't time out on a single mega-expression.

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                cornerPane(N: N, rowW: rowW, rowH: rowH)
                colHeaderPane(nodes: nodes, N: N, cell: cell, rowH: rowH, bodyW: bodyW)
            }
            HStack(spacing: 0) {
                rowHeaderPane(nodes: nodes, N: N, degrees: degrees, cell: cell, rowW: rowW, bodyH: bodyH)
                bodyPane(nodes: nodes, N: N, adj: adj, cell: cell, bodyW: bodyW, bodyH: bodyH)
            }
        }
        .background(Palette.bgPage)
    }

    @ViewBuilder
    private func cornerPane(N: Int, rowW: CGFloat, rowH: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Palette.bgElev)
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
                .frame(maxHeight: .infinity, alignment: .bottom)
            Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                OverlineLabel("Adjacency", tint: Palette.ink3)
                Text("\(N) × \(N)")
                    .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(width: rowW, height: rowH)
    }

    @ViewBuilder
    private func colHeaderPane(
        nodes: [DomeRpcClient.GraphNode],
        N: Int,
        cell: CGFloat,
        rowH: CGFloat,
        bodyW: CGFloat
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(0..<N, id: \.self) { c in
                    ColumnHeader(
                        node: nodes[c],
                        isFocus: nodes[c].nodeID == focusID,
                        isHover: hoverCell?.1 == c
                    )
                    .frame(width: cell, height: rowH)
                }
            }
            .frame(width: bodyW, height: rowH)
            .background(Palette.bgElev)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
            }
            // P4 sync: mirror the body pane's horizontal offset onto
            // the column-header strip. bodyOffset.x is the content-
            // origin X in the body's named coord space — it's negative
            // as you scroll right, applied here as a leftward shift.
            .offset(x: bodyOffset.x, y: 0)
        }
        .frame(height: rowH)
        .scrollDisabled(true)
    }

    @ViewBuilder
    private func rowHeaderPane(
        nodes: [DomeRpcClient.GraphNode],
        N: Int,
        degrees: [String: Int],
        cell: CGFloat,
        rowW: CGFloat,
        bodyH: CGFloat
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(0..<N, id: \.self) { r in
                    RowHeader(
                        node: nodes[r],
                        degree: degrees[nodes[r].nodeID] ?? 0,
                        isFocus: nodes[r].nodeID == focusID,
                        isHover: hoverCell?.0 == r,
                        onClick: { onFocus(nodes[r].nodeID) },
                        onHover: { hovered in
                            onHover(hovered ? nodes[r].nodeID : nil)
                        }
                    )
                    .frame(width: rowW, height: cell)
                }
            }
            .frame(width: rowW, height: bodyH)
            .background(Palette.bgElev)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
            }
            // P4 sync: mirror the body pane's vertical offset onto
            // the row-header strip.
            .offset(x: 0, y: bodyOffset.y)
        }
        .frame(width: rowW)
        .scrollDisabled(true)
    }

    @ViewBuilder
    private func bodyPane(
        nodes: [DomeRpcClient.GraphNode],
        N: Int,
        adj: [[Bool]],
        cell: CGFloat,
        bodyW: CGFloat,
        bodyH: CGFloat
    ) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<N, id: \.self) { r in
                    ForEach(0..<N, id: \.self) { c in
                        bodyCell(r: r, c: c, nodes: nodes, adj: adj, cell: cell)
                    }
                }
            }
            .frame(width: bodyW, height: bodyH)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: LedgerScrollOffsetKey.self,
                        value: geo.frame(in: .named("ledgerBody")).origin
                    )
                }
            )
        }
        .coordinateSpace(name: "ledgerBody")
        .onPreferenceChange(LedgerScrollOffsetKey.self) { offset in
            bodyOffset = offset
        }
        .onChange(of: bodyOffset) { _, _ in
            // Header offsets are bound to bodyOffset via the .offset()
            // modifiers in colHeaderPane / rowHeaderPane; this watcher
            // is the explicit propagation hook the spec calls for.
        }
    }

    @ViewBuilder
    private func bodyCell(
        r: Int,
        c: Int,
        nodes: [DomeRpcClient.GraphNode],
        adj: [[Bool]],
        cell: CGFloat
    ) -> some View {
        let focusHere = nodes[r].nodeID == focusID || nodes[c].nodeID == focusID
        let hoverHere = hoverCell?.0 == r || hoverCell?.1 == c
        MatrixCell(on: adj[r][c], diag: r == c, focusRC: focusHere, hover: hoverHere)
            .frame(width: cell, height: cell)
            .position(x: cell * CGFloat(c) + cell / 2, y: cell * CGFloat(r) + cell / 2)
            .onHover { hovered in
                if hovered {
                    hoverCell = (r, c)
                } else if hoverCell?.0 == r && hoverCell?.1 == c {
                    hoverCell = nil
                }
            }
            .onTapGesture {
                if adj[r][c] { onFocus(nodes[r].nodeID) }
            }
    }

    // MARK: Hover readout

    private var readout: some View {
        Group {
            if let h = hoverCell, h.0 < displayedNodes.count, h.1 < displayedNodes.count {
                let r = displayedNodes[h.0]
                let c = displayedNodes[h.1]
                let connected = adjacency(r.nodeID, c.nodeID)
                HStack(spacing: 8) {
                    OverlineLabel("Cell", tint: Palette.ink4)
                    Text(r.label)
                        .font(KnowledgeNodeStyle.from(r.kind).entryFont)
                        .foregroundStyle(Palette.ink)
                    Text("×")
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundStyle(Palette.ink3)
                    Text(c.label)
                        .font(KnowledgeNodeStyle.from(c.kind).entryFont)
                        .foregroundStyle(Palette.ink)
                    Text("·")
                        .foregroundStyle(Palette.ink4)
                    Text(connected ? "connected" : "no tie")
                        .font(.system(size: 12, weight: .regular, design: .serif).italic())
                        .foregroundStyle(connected ? Palette.accent : Palette.ink3)
                    Spacer()
                }
            } else {
                HStack {
                    Text("Hover any cell · click filled to recenter Orbital")
                        .font(Font.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Palette.ink4)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.bgElev)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    // MARK: Adjacency helpers

    private func adjacency(_ a: String, _ b: String) -> Bool {
        snapshot.edges.contains {
            ($0.sourceID == a && $0.targetID == b) || ($0.sourceID == b && $0.targetID == a)
        }
    }

    private func adjacencyMatrix(_ nodes: [DomeRpcClient.GraphNode]) -> [[Bool]] {
        let idx = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.nodeID, $0.offset) })
        var M = Array(repeating: Array(repeating: false, count: nodes.count), count: nodes.count)
        for e in snapshot.edges {
            guard let i = idx[e.sourceID], let j = idx[e.targetID] else { continue }
            M[i][j] = true
            M[j][i] = true
        }
        return M
    }

    // MARK: Header subviews

    /// Shortens a label to its last meaningful segment for display in
    /// row / column headers. For paths like
    /// `fontlus-cli/packages/mcp/src/fontlus_mcp/tools/kerning.py`,
    /// returns `kerning.py`. For non-path labels, returns the input
    /// unchanged.
    private static func shortLabel(_ label: String) -> String {
        if let last = label.split(separator: "/").last, last.count < label.count {
            return String(last)
        }
        return label
    }

    private struct ColumnHeader: View {
        let node: DomeRpcClient.GraphNode
        let isFocus: Bool
        let isHover: Bool

        var body: some View {
            let style = KnowledgeNodeStyle.from(node.kind)
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(isFocus ? Palette.bgRowHi : (isHover ? Palette.bgRow : Palette.bgElev))
                Rectangle()
                    .fill(Palette.rule)
                    .frame(width: DK.ruleW)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(KnowledgeLedger.shortLabel(node.label))
                    .font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(isFocus ? Palette.accent : style.dotColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // pre-rotation: cap text width to the column header
                    // height (minus padding) so post-rotation it fits.
                    .frame(width: 120, alignment: .trailing)
                    .rotationEffect(.degrees(-90))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }
            .help(node.label)
        }
    }

    private struct RowHeader: View {
        let node: DomeRpcClient.GraphNode
        let degree: Int
        let isFocus: Bool
        let isHover: Bool
        let onClick: () -> Void
        let onHover: (Bool) -> Void

        var body: some View {
            let style = KnowledgeNodeStyle.from(node.kind)
            Button(action: onClick) {
                HStack(spacing: 8) {
                    Text(String(node.kind.prefix(1)).uppercased())
                        .font(Font.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(style.dotColor)
                        .frame(width: 12)
                    Text(KnowledgeLedger.shortLabel(node.label))
                        .font(style.entryFont)
                        .foregroundStyle(isFocus ? Palette.accent : Palette.ink)
                        .underline(style == .tag)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(degree)")
                        .font(Font.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(rowFill)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Palette.rule.opacity(0.5)).frame(height: DK.ruleW)
                }
            }
            .buttonStyle(.plain)
            .onHover { onHover($0) }
            .help(node.label)
        }

        private var rowFill: Color {
            if isFocus { return Palette.accentBg }
            if isHover { return Palette.bgRowHi }
            return Color.clear
        }
    }

    /// One adjacency cell. The visible grid is essential to ledger
    /// legibility — without strong borders the matrix collapses into a
    /// scatter of bright "on" dots floating on a dark page with no
    /// row / column rhythm. The base layer is always painted (even
    /// "off" cells get a faint fill so the grid breathes), the rule
    /// stroke is full-opacity `bgPage` against `bgRow` so you can
    /// always count cells, and the diagonal cells get a stronger
    /// hatch so the matrix's identity diagonal reads at a glance.
    private struct MatrixCell: View {
        let on: Bool
        let diag: Bool
        let focusRC: Bool
        let hover: Bool

        var body: some View {
            ZStack {
                // Base — every cell gets a faint elevated fill so the
                // grid is always visible, even when nothing's on.
                Rectangle().fill(baseFill)
                if diag {
                    DiagonalHatch().fill(Palette.ink3.opacity(0.55))
                }
                if on {
                    // The "on" pip is inset from the cell edges so the
                    // grid borders read continuously through the row.
                    RoundedRectangle(cornerRadius: DK.radius)
                        .fill(onFill)
                        .padding(4)
                }
                // Grid — full-opacity bgPage rule. On bgRow that reads
                // as a clean dark hairline between cells.
                Rectangle()
                    .stroke(Palette.bgPage, lineWidth: 1)
            }
        }

        /// Base fill for the cell area (under the "on" pip).
        private var baseFill: Color {
            if focusRC && hover { return Palette.bgRowHi }
            if focusRC { return Palette.accentBg.opacity(0.55) }
            if hover { return Palette.bgRowHi }
            return Palette.bgRow
        }

        /// Fill of the "on" pip — accent in the focused row/col so the
        /// focus's connections pop visually; otherwise plain ink.
        private var onFill: Color {
            focusRC ? Palette.accent : Palette.ink
        }
    }

    /// Diagonal hatch used on the matrix's identity diagonal so
    /// `r == c` cells visibly differ from "no tie" cells. Strokes
    /// every 5px with a clean 1.4px line; readable at the 40px cell
    /// stride this matrix uses.
    private struct DiagonalHatch: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let step: CGFloat = 5
            var x: CGFloat = -rect.height
            while x < rect.width {
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x + rect.height, y: rect.height))
                x += step
            }
            return p.strokedPath(.init(lineWidth: 1.4))
        }
    }
}

// MARK: - Detail panel

/// Right-side editorial inspector. Shows kind / name / role / meta
/// for the focused node, optional path-finder UI, and grouped lists
/// of neighbors. Mirrors the design's `DetailPanel` exactly, on
/// Tado's dark + ember palette.
///
/// Sections (top → bottom):
///
///   ┌────────────────────────┐
///   │ KIND                  │  overline mono
///   │ Node Name (large serif)│
///   │ italic role            │
///   │ N TIES · EST. MM YYYY  │  meta
///   │ ☆ pin · set FROM · TO  │  3 OutlineButton.small
///   ├────────────────────────┤
///   │ PATH (if active)       │
///   │ from ↦ to              │
///   │ 1. step                │
///   │ 2. step                │
///   │ clear path             │
///   ├────────────────────────┤
///   │ AGENTS · 3             │
///   │ → name (italic)        │
///   │ ← name                 │
///   ├────────────────────────┤
///   │ PROJECTS · 2           │
///   │ ...                    │
///   └────────────────────────┘
private struct KnowledgeDetailPanel: View {
    let snapshot: DomeRpcClient.GraphSnapshot
    let focusID: String
    let pinned: Set<String>
    let pathStart: String?
    let pathEnd: String?
    let pathTo: [String]?
    let onFocus: (String) -> Void
    let onTogglePin: (String) -> Void
    let onSetPathStart: (String) -> Void
    let onSetPathEnd: (String) -> Void
    let onClearPath: () -> Void

    private var focus: DomeRpcClient.GraphNode? {
        snapshot.nodes.first { $0.nodeID == focusID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let n = focus {
                    head(n)
                    if pathStart != nil || pathEnd != nil {
                        pathSection
                    }
                    neighborSections(for: n)
                    Spacer(minLength: 24)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select a node")
                            .font(.system(size: 22, weight: .regular, design: .serif).italic())
                            .foregroundStyle(Palette.ink2)
                        Text("Click any entry, ring node, or matrix row to focus.")
                            .font(.system(size: 12, weight: .regular, design: .serif))
                            .foregroundStyle(Palette.ink3)
                    }
                    .padding(20)
                }
            }
        }
        .background(Palette.bgElev)
    }

    // MARK: Head

    private func head(_ n: DomeRpcClient.GraphNode) -> some View {
        let style = KnowledgeNodeStyle.from(n.kind)
        let degree = KnowledgeGraphMath.degreeMap(snapshot.edges)[n.nodeID] ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            OverlineLabel(style.label, tint: Palette.ink3)
            Text(n.label)
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let role = n.secondaryLabel, !role.isEmpty {
                Text(role)
                    .font(.system(size: 13, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Palette.ink2)
            }
            HStack(spacing: 8) {
                Text("\(degree) ties")
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Palette.ink3)
                if let date = n.sortTime {
                    Text("·")
                        .foregroundStyle(Palette.ink4)
                    Text("est. \(monthLabel(date))")
                        .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Palette.ink3)
                }
            }
            HStack(spacing: 6) {
                OutlineButton(
                    pinned.contains(n.nodeID) ? "★ pinned" : "☆ pin",
                    size: .small,
                    variant: pinned.contains(n.nodeID) ? .accent : .standard,
                    action: { onTogglePin(n.nodeID) }
                )
                OutlineButton(
                    "set FROM",
                    size: .small,
                    variant: pathStart == n.nodeID ? .accent : .standard,
                    action: { onSetPathStart(n.nodeID) }
                )
                OutlineButton(
                    "set TO",
                    size: .small,
                    variant: pathEnd == n.nodeID ? .accent : .standard,
                    action: { onSetPathEnd(n.nodeID) }
                )
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    // MARK: Path section

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverlineLabel("Path", tint: Palette.ink3)
            HStack(spacing: 8) {
                pathEndLabel(start: true)
                Text("↦")
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.ink4)
                pathEndLabel(start: false)
            }
            if let p = pathTo, !p.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(p.enumerated()), id: \.offset) { (idx, id) in
                        if let n = snapshot.nodes.first(where: { $0.nodeID == id }) {
                            Button(action: { onFocus(id) }) {
                                HStack(spacing: 10) {
                                    Text("\(idx + 1)")
                                        .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Palette.ink4)
                                        .frame(width: 18, alignment: .leading)
                                    Text(n.label)
                                        .font(KnowledgeNodeStyle.from(n.kind).entryFont)
                                        .foregroundStyle(Palette.ink)
                                        .underline(KnowledgeNodeStyle.from(n.kind) == .tag)
                                    Spacer()
                                    Text(KnowledgeNodeStyle.from(n.kind).label)
                                        .font(Font.system(size: 9, weight: .medium, design: .monospaced))
                                        .tracking(0.6)
                                        .foregroundStyle(Palette.ink4)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Palette.accent).frame(width: 1.5)
                }
            } else if pathStart != nil && pathEnd != nil {
                Text("no path within graph")
                    .font(.system(size: 12, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Palette.ink3)
            }
            Button(action: onClearPath) {
                Text("CLEAR PATH")
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .underline()
                    .foregroundStyle(Palette.ink4)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private func pathEndLabel(start: Bool) -> some View {
        let id = start ? pathStart : pathEnd
        let label: String = id.flatMap { id in
            snapshot.nodes.first(where: { $0.nodeID == id })?.label
        } ?? (start ? "— from —" : "— to —")
        let active = id != nil
        return Text(label)
            .font(Font.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(active ? Palette.accent : Palette.ink3)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(active ? Palette.accentSoft : Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    // MARK: Neighbor sections

    private func neighborSections(for n: DomeRpcClient.GraphNode) -> some View {
        let neighbors = neighbors(of: n.nodeID)
        let grouped = Dictionary(grouping: neighbors) { entry -> KnowledgeNodeStyle in
            guard let other = snapshot.nodes.first(where: { $0.nodeID == entry.id }) else {
                return .doc
            }
            return KnowledgeNodeStyle.from(other.kind)
        }
        let order: [KnowledgeNodeStyle] = [.person, .project, .doc, .tag]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(order, id: \.self) { style in
                if let list = grouped[style], !list.isEmpty {
                    section(style: style, list: list)
                }
            }
        }
    }

    private func section(style: KnowledgeNodeStyle, list: [(id: String, out: Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                OverlineLabel(style.pluralLabel, tint: Palette.ink3)
                Spacer()
                Text("\(list.count)")
                    .font(Font.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list, id: \.id) { entry in
                    if let other = snapshot.nodes.first(where: { $0.nodeID == entry.id }) {
                        NeighborRow(
                            other: other,
                            outbound: entry.out,
                            onFocus: { onFocus(other.nodeID) }
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private struct NeighborRow: View {
        let other: DomeRpcClient.GraphNode
        let outbound: Bool
        let onFocus: () -> Void
        @State private var hovered = false

        var body: some View {
            let style = KnowledgeNodeStyle.from(other.kind)
            Button(action: onFocus) {
                HStack(spacing: 10) {
                    Text(outbound ? "→" : "←")
                        .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink4)
                        .frame(width: 14)
                    Text(other.label)
                        .font(style.entryFont)
                        .foregroundStyle(hovered ? Palette.accent : Palette.ink)
                        .underline(style == .tag)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .background(hovered ? Palette.bgRow : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }

    private func neighbors(of id: String) -> [(id: String, out: Bool)] {
        var out: [(id: String, out: Bool)] = []
        for e in snapshot.edges {
            if e.sourceID == id { out.append((e.targetID, true)) }
            else if e.targetID == id { out.append((e.sourceID, false)) }
        }
        return out
    }

    private func monthLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }
}

// MARK: - Kind style mapping

/// Tado's `graph_nodes.kind` is much richer than the design's
/// 4-class set. We collapse it into 4 visual classes that drive
/// every editorial cue (italic / underline / weight / color):
///
/// - **doc** — `doc`, `note`, `decision`, `intent`, `outcome`, `retro`,
///   `event`, anything unrecognized. Plain ink, serif body.
/// - **person** — `agent`, `brand`. Italic editorial display, green tint.
/// - **project** — `project`, `topic`, `task`, `run`, `context_pack`.
///   Bold serif, ember accent.
/// - **tag** — `tag`. Underlined, gold tint.
enum KnowledgeNodeStyle: CaseIterable, Hashable {
    case doc, person, project, tag

    static func from(_ kind: String) -> KnowledgeNodeStyle {
        switch kind {
        case "agent", "brand": return .person
        case "project", "topic", "task", "run", "context_pack": return .project
        case "tag": return .tag
        default: return .doc
        }
    }

    var label: String {
        switch self {
        case .doc: return "doc"
        case .person: return "agent"
        case .project: return "project"
        case .tag: return "tag"
        }
    }

    var pluralLabel: String {
        switch self {
        case .doc: return "docs"
        case .person: return "agents"
        case .project: return "projects"
        case .tag: return "tags"
        }
    }

    /// Fill color for orbital glyphs (filled shapes when focused).
    func fillColor(focused: Bool) -> Color {
        if focused { return Palette.ink }
        switch self {
        case .doc: return Palette.bgPage
        case .person: return Palette.bgPage
        case .project: return Palette.accent
        case .tag: return Palette.warning.opacity(0.65)
        }
    }

    /// Dot / kind-mark color. Editorial kind tinting:
    ///   doc — plain ink (typographic default)
    ///   person — Tado green
    ///   project — Tado ember accent
    ///   tag — Tado gold (warning)
    var dotColor: Color {
        switch self {
        case .doc: return Palette.ink2
        case .person: return Palette.green
        case .project: return Palette.accent
        case .tag: return Palette.warning
        }
    }

    /// Editorial entry font for index-style listings. All serif so
    /// the index reads as a printed back-of-book page; weight + style
    /// carry the kind cue (italic = person, bold = project, default
    /// = doc / tag).
    var entryFont: Font {
        switch self {
        case .doc: return .system(size: 14, weight: .regular, design: .serif)
        case .person: return .system(size: 14, weight: .regular, design: .serif).italic()
        case .project: return .system(size: 14, weight: .semibold, design: .serif)
        case .tag: return .system(size: 14, weight: .regular, design: .serif)
        }
    }
}

// MARK: - Graph math

/// Pure helpers that read a `GraphSnapshot` and return BFS levels,
/// shortest paths, neighbor maps, and orbital placements. Stateless;
/// safe to call from any thread.
enum KnowledgeGraphMath {
    struct OrbitalPlacement {
        var levels: [String: Int]
        var points: [String: CGPoint]
    }

    static func neighborMap(_ edges: [DomeRpcClient.GraphEdge]) -> [String: [String]] {
        var m: [String: [String]] = [:]
        for e in edges {
            m[e.sourceID, default: []].append(e.targetID)
            m[e.targetID, default: []].append(e.sourceID)
        }
        return m
    }

    static func degreeMap(_ edges: [DomeRpcClient.GraphEdge]) -> [String: Int] {
        var d: [String: Int] = [:]
        for e in edges {
            d[e.sourceID, default: 0] += 1
            d[e.targetID, default: 0] += 1
        }
        return d
    }

    /// Breadth-first levels from `from`, capped at level 3. Anything
    /// further than 3 hops doesn't get placed in the orbital and is
    /// elided from the canvas — matches the design's 3-ring focus.
    static func bfsLevels(from: String, neighbors: [String: [String]], cap: Int = 3) -> [String: Int] {
        var levels: [String: Int] = [from: 0]
        var queue: [String] = [from]
        var i = 0
        while i < queue.count {
            let cur = queue[i]; i += 1
            let lvl = levels[cur] ?? 0
            if lvl >= cap { continue }
            for nb in neighbors[cur] ?? [] {
                if levels[nb] == nil {
                    levels[nb] = lvl + 1
                    queue.append(nb)
                }
            }
        }
        return levels
    }

    /// BFS shortest path. Returns `[from, ..., to]` inclusive, or
    /// `nil` if disconnected.
    static func bfsPath(from: String, to: String, neighbors: [String: [String]]) -> [String]? {
        if from == to { return [from] }
        var queue: [[String]] = [[from]]
        var seen: Set<String> = [from]
        while !queue.isEmpty {
            let path = queue.removeFirst()
            let last = path.last!
            for nb in neighbors[last] ?? [] {
                if seen.contains(nb) { continue }
                seen.insert(nb)
                let np = path + [nb]
                if nb == to { return np }
                queue.append(np)
            }
        }
        return nil
    }

    /// Orbital placement using stable per-id hash for angle so the
    /// graph doesn't reflow on every re-render. Coordinates are in
    /// the unit-100 viewBox space (cx, cy default to 50, 50).
    static func orbitalPlacement(
        snapshot: DomeRpcClient.GraphSnapshot,
        focusID: String,
        cx: Double,
        cy: Double
    ) -> OrbitalPlacement {
        let neighbors = neighborMap(snapshot.edges)
        let levels = bfsLevels(from: focusID, neighbors: neighbors)
        var points: [String: CGPoint] = [:]
        points[focusID] = CGPoint(x: cx, y: cy)
        let radii: [Int: Double] = [1: 18, 2: 32, 3: 44]
        for level in 1...3 {
            let ids = levels.compactMap { (k, v) in v == level ? k : nil }
                .sorted { hash($0) < hash($1) }
            let r = radii[level] ?? 44
            for (i, id) in ids.enumerated() {
                let denom = max(1, ids.count)
                let a = Double(i) / Double(denom) * .pi * 2 - .pi / 2 + Double(hash(id) % 100) / 2000.0
                points[id] = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
            }
        }
        return OrbitalPlacement(levels: levels, points: points)
    }

    private static func hash(_ s: String) -> Int {
        var h = 0
        for u in s.unicodeScalars {
            h = (h &* 31 &+ Int(u.value)) & 0xFFFF
        }
        return h
    }
}
