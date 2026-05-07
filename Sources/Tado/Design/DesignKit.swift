import SwiftUI
import AppKit

/// Shared structural primitives for the v0.18 "Projects Page" design
/// pass. Every page that wants the new look (Projects detail, Projects
/// list, Todos, Extensions) builds out of these components instead of
/// hand-rolling cards / pills / row tables — the design's grid is too
/// strict to let each surface drift on its own.
///
/// What lives here:
///
/// - **`PageContainer`** — bounded, centred page body (max 1400 px,
///   24 px gutter, 80 px bottom safe-area).
/// - **`PageHeader` + `MetaStrip` + `MetaCell`** — the "title + path
///   + meta-strip" block at the top of every page. Mirrors the
///   `.page-hd` block in the design source, including the bordered
///   key/value cells on the right.
/// - **`SectionRail`** — the 200 px label-rail × 1 fr content grid
///   pattern that replaces every previous "overline + content"
///   stack. The rail carries label / count / actions; the content
///   slot carries the section's body. A single `border-bottom`
///   separates rows.
/// - **`OutlineButton`** + **`IconButton`** — the bordered, low-fill
///   buttons used throughout the design (`.btn` / `.btn-sm` /
///   `.btn-icon` / `.btn-accent` / `.btn-danger` / `.btn-ghost`).
/// - **`StatusPill`** — uppercase mono capsule with the design's
///   `pill-{planning,draft,review,running,ready,done}` variants.
/// - **`KindGlyph`** — the 8 px `○` / `◇` / `□` shape that prefixes
///   every kind tag in the runs table. (Mega = filled circle,
///   Sprint = rotated square, etc.)
/// - **`KbdKey`** — keycap rendering used in composer footers.
/// - **`OverlineLabel`** — uppercase mono label used by section rails
///   and column headers.
/// - **`RuledRow`** + **`Cell`** + **`ColHd`** — primitives for the
///   tabular row layouts (Eternal runs, Todos table). Build a row by
///   composing `Cell(...)`s inside an `HStack(spacing: 0)` whose
///   children are separated by `Cell.divider`.
///
/// Naming: anything from the design's CSS class lives here keeping
/// the same name in PascalCase, so an LLM (or human) can map between
/// the prototype HTML and the Swift code without a translation table.
enum DK {
    // MARK: - Tokens (mirrors :root in the design)

    /// 1 px in the design vocabulary; a single touchpoint so we can
    /// flip thin/regular/thick rules across the whole app the way the
    /// design's `data-rules` attribute does.
    static let ruleW: CGFloat = 1
    /// Tabular row height — 44 px in the design's "comfy" mode (the
    /// app's default).
    static let rowH: CGFloat = 44
    /// Inner table-cell padding (horizontal).
    static let cellPadX: CGFloat = 14
    /// Outer page gutter.
    static let pageGutter: CGFloat = 24
    /// Max page width — the design uses `max-width: 1400px`.
    static let pageMaxWidth: CGFloat = 1400
    /// Section-rail width.
    static let railW: CGFloat = 200
    /// Right-rail width — the v0.20 Agent System / Activity pages use
    /// a sticky right-side rail of contextual actions. Slightly wider
    /// than the section rail because each row carries label + icon +
    /// (occasional) trailing kbd shortcut hint.
    static let rightRailW: CGFloat = 240
    /// Tabs row height — matches the design's `--tabs-h: 44px`.
    static let tabsH: CGFloat = 44
    /// Border radius — the Cumulus master signature is 5.5 px (see
    /// CUMULUS-BRAND.md "Rule 3 — One component"). Every UI primitive
    /// rounds to this number; the only documented exception is the
    /// 6×6 status / brand-mark dot at `999`.
    static let radius: CGFloat = 5.5
    /// Larger radius used on full-section cards (composer body,
    /// dispatch empty state). Held at the same 5.5 px per master spec
    /// so the chrome reads as one family rather than two radii. The
    /// alias is preserved so existing call sites continue to compile.
    static let radiusLg: CGFloat = 5.5
}

// MARK: - PageContainer

/// Centred, bounded page body. Replaces the per-page padding stacks
/// each surface used to declare; every page wraps its top-level
/// content in this so the gutters, max width, and bottom safe-area
/// are consistent.
struct PageContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .frame(maxWidth: DK.pageMaxWidth, alignment: .leading)
                .padding(.horizontal, DK.pageGutter)
                .padding(.bottom, 80)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.bgPage)
    }
}

// MARK: - PageHeader

/// Page header — title (28 pt, -0.02 tracking) + optional path with
/// a copy button + meta strip on the right.
///
/// `path` is rendered in mono-caption tertiary ink; clicking the copy
/// glyph writes it to the pasteboard. Meta cells are 5 max — beyond
/// that the strip wraps below the title on narrow widths.
struct PageHeader<Meta: View>: View {
    let title: String
    var path: String? = nil
    var pathOnCopy: (() -> Void)? = nil
    @ViewBuilder var meta: Meta

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink)
                if let path {
                    HStack(spacing: 8) {
                        Text(path)
                            .font(Typography.monoCaption)
                            .foregroundStyle(Palette.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let pathOnCopy {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                                pathOnCopy()
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Palette.ink3)
                                    .frame(width: 16, height: 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: DK.radius)
                                            .stroke(Palette.rule, lineWidth: DK.ruleW)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Copy path")
                        }
                    }
                }
            }
            Spacer(minLength: 16)
            meta
        }
        .padding(.top, 28)
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.rule)
                .frame(height: DK.ruleW)
        }
    }
}

extension PageHeader where Meta == EmptyView {
    init(title: String, path: String? = nil, pathOnCopy: (() -> Void)? = nil) {
        self.title = title
        self.path = path
        self.pathOnCopy = pathOnCopy
        self.meta = EmptyView()
    }
}

// MARK: - MetaStrip + MetaCell

/// Horizontal strip of `MetaCell`s, hairline-separated, wrapped in a
/// rounded rectangle that draws a single border. Used on the right
/// edge of every `PageHeader`.
///
/// Use `MetaCell.value("3")` for plain numerics, or
/// `MetaCell.value("● Active", tint: Palette.green)` for tinted
/// values with a leading dot glyph.
struct MetaStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .background(Palette.bgPage)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }
}

struct MetaCell: View {
    let key: String
    let value: String
    var tint: Color = Palette.ink
    var trailingDivider: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(key.uppercased())
                    .font(Font.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Palette.ink4)
                Text(value)
                    .font(Font.system(size: 12, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, DK.cellPadX)
            .padding(.vertical, 6)
            if trailingDivider {
                Rectangle()
                    .fill(Palette.rule)
                    .frame(width: DK.ruleW)
            }
        }
        .frame(minHeight: 38)
    }
}

// MARK: - SectionRail

/// The signature layout of the design pass: 200 px label rail on the
/// left (label + count + stack of action buttons), `1fr` content slot
/// on the right, separated by a 1 px hairline. Every section on the
/// project detail page wraps its body in one of these.
///
/// `bottomDivider` paints the section's bottom border (true by
/// default); set false on the last section to avoid doubling with
/// the page's bottom safe area.
struct SectionRail<Actions: View, Content: View>: View {
    let label: String
    var count: String? = nil
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    var bottomDivider: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                OverlineLabel(label)
                if let count {
                    Text(count)
                        .font(Typography.monoMicro)
                        .foregroundStyle(Palette.ink4)
                }
                actions
                    .padding(.top, 4)
            }
            .frame(width: DK.railW, alignment: .leading)
            .padding(.vertical, 20)
            .padding(.trailing, 20)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Palette.rule)
                    .frame(width: DK.ruleW)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if bottomDivider {
                Rectangle()
                    .fill(Palette.rule)
                    .frame(height: DK.ruleW)
            }
        }
    }
}

extension SectionRail where Actions == EmptyView {
    init(
        label: String,
        count: String? = nil,
        bottomDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.count = count
        self.bottomDivider = bottomDivider
        self.actions = EmptyView()
        self.content = content()
    }
}

// MARK: - OverlineLabel

/// Uppercase mono label — section rails, column heads, group titles.
/// 11 pt SemiBold mono with 1 em-ish letter spacing.
struct OverlineLabel: View {
    let text: String
    var tint: Color = Palette.ink2

    init(_ text: String, tint: Color = Palette.ink2) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(Font.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(tint)
    }
}

// MARK: - StatusPill

/// Small uppercase mono capsule, 20 pt tall. The design's
/// `pill-{variant}` classes map to `Variant` cases below.
struct StatusPill: View {
    enum Variant {
        case neutral
        case draft
        case planning
        case review
        case ready
        case running
        case done
        case danger

        fileprivate var fg: Color {
            switch self {
            case .neutral:  return Palette.ink2
            case .draft:    return Palette.ink3
            case .planning: return Palette.accent
            case .review:   return Palette.warning
            case .ready:    return Palette.accent
            case .running:  return Palette.green
            case .done:     return Palette.ink4
            case .danger:   return Palette.danger
            }
        }
        fileprivate var border: Color {
            switch self {
            case .planning, .ready: return Palette.accentSoft
            case .running:          return Palette.greenSoft
            case .review:           return Palette.warning.opacity(0.6)
            case .danger:           return Palette.danger.opacity(0.6)
            default:                return Palette.rule
            }
        }
        fileprivate var bg: Color {
            switch self {
            case .planning, .ready: return Palette.accentBg
            // Per master brand: status hues collapse to ink-tiers.
            // The "running" pill now reads as an accent-tinted neutral
            // rather than the historical green wash.
            case .running:          return Palette.accentBg
            case .review:           return Palette.warning.opacity(0.10)
            case .danger:           return Palette.danger.opacity(0.10)
            default:                return Palette.bgPage
            }
        }
    }

    let label: String
    let variant: Variant

    init(_ label: String, variant: Variant = .neutral) {
        self.label = label
        self.variant = variant
    }

    /// Convenience: map a raw run-state string ("planning" / "ready"
    /// / "running" / "completed" / …) onto the right variant + label.
    static func runState(_ state: String) -> StatusPill {
        switch state {
        case "drafted":         return StatusPill("draft",       variant: .draft)
        case "planning":        return StatusPill("planning",    variant: .planning)
        case "awaitingReview":  return StatusPill("review",      variant: .review)
        case "ready":           return StatusPill("ready",       variant: .ready)
        case "running":         return StatusPill("running",     variant: .running)
        case "dispatching":     return StatusPill("dispatching", variant: .running)
        case "completed":       return StatusPill("done",        variant: .done)
        case "stopped":         return StatusPill("stopped",     variant: .done)
        case "failed":          return StatusPill("failed",      variant: .danger)
        default:                return StatusPill(state,         variant: .neutral)
        }
    }

    var body: some View {
        Text(label.uppercased())
            .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(variant.fg)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(variant.bg)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(variant.border, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }
}

// MARK: - KindGlyph

/// Tiny shape glyph used to prefix kind tags in the runs table. The
/// design defines: filled circle = mega, rotated square = sprint,
/// outlined square = generic. We render via a 1 px stroke on a
/// `Path` so the size lands on a crisp pixel grid at 8 px.
struct KindGlyph: View {
    enum Kind { case mega, sprint, generic }
    let kind: Kind
    var size: CGFloat = 8

    var body: some View {
        let s = size
        Group {
            switch kind {
            case .mega:
                Circle()
                    .stroke(Palette.ink3, lineWidth: 1)
                    .frame(width: s, height: s)
            case .sprint:
                Rectangle()
                    .stroke(Palette.ink3, lineWidth: 1)
                    .frame(width: s, height: s)
                    .rotationEffect(.degrees(45))
            case .generic:
                Rectangle()
                    .stroke(Palette.ink3, lineWidth: 1)
                    .frame(width: s, height: s)
            }
        }
        .frame(width: s + 2, height: s + 2)
    }
}

// MARK: - OutlineButton

/// The design's `.btn` — an outlined, low-fill button. `.sm` flips
/// to the 24 pt height variant; `accent` adopts the warm-amber
/// outline + foreground; `danger` recolours on hover; `ghost` drops
/// the resting border.
struct OutlineButton: View {
    enum Size { case regular, small }
    enum Variant { case standard, accent, danger, ghost }

    let label: String?
    let icon: String?
    var size: Size = .regular
    var variant: Variant = .standard
    var action: () -> Void

    @State private var isHovered: Bool = false

    init(
        _ label: String? = nil,
        icon: String? = nil,
        size: Size = .regular,
        variant: Variant = .standard,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.icon = icon
        self.size = size
        self.variant = variant
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: .semibold))
                }
                if let label {
                    Text(label)
                        .font(Font.system(size: textSize, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(currentFg)
            .padding(.horizontal, label == nil ? 0 : (size == .small ? 8 : 12))
            .frame(width: label == nil ? heightForSize : nil, height: heightForSize)
            .background(currentBg)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(currentBorder, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            .contentShape(RoundedRectangle(cornerRadius: DK.radius))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var heightForSize: CGFloat { size == .small ? 24 : 28 }
    private var textSize: CGFloat { size == .small ? 11.5 : 12 }
    private var iconSize: CGFloat { size == .small ? 10 : 11 }

    private var currentFg: Color {
        switch variant {
        case .standard: return isHovered ? Palette.ink : Palette.ink2
        case .accent:   return Palette.accent
        case .danger:   return isHovered ? Palette.danger : Palette.ink3
        case .ghost:    return isHovered ? Palette.ink : Palette.ink2
        }
    }
    private var currentBorder: Color {
        switch variant {
        case .standard: return isHovered ? Palette.ruleStrong : Palette.rule
        case .accent:   return isHovered ? Palette.accent : Palette.accentSoft
        case .danger:   return isHovered ? Palette.danger : Palette.rule
        case .ghost:    return isHovered ? Palette.rule : .clear
        }
    }
    private var currentBg: Color {
        switch variant {
        case .standard: return isHovered ? Palette.bgRowHi : Color.clear
        case .accent:   return isHovered ? Palette.accentBg : Color.clear
        // Per master brand: destructive hover lands on a soft
        // terracotta wash rather than the historical reddish blackish
        // tint. Same hue as the destructive accent at low alpha.
        case .danger:   return isHovered ? Palette.danger.opacity(0.12) : Color.clear
        case .ghost:    return isHovered ? Palette.bgRowHi : Color.clear
        }
    }
}

// MARK: - KbdKey

/// Small key-cap rendering used in composer footers ("⌘", "⏎",
/// "⇧", "K"). Mono, 10 pt, 1 px outline, rounded-corner box.
struct KbdKey: View {
    let label: String
    var body: some View {
        Text(label)
            .font(Font.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(Palette.ink3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(Palette.rule, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }
}

// MARK: - UserChip

/// Right-side topbar chip with a coloured live dot + mono label.
/// Used to display the current project / vault / agent identity.
struct UserChip: View {
    let label: String
    var dotColor: Color = Palette.green

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Font.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }
}

// MARK: - Tabular row primitives

/// A 1 px hairline divider, the "between cells" rule used inside any
/// row that's drawn out of `Cell(...)` siblings.
struct CellDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.rule)
            .frame(width: DK.ruleW)
    }
}

/// Row used by tabular sections (Eternal runs, Todos table).
/// Children are arranged in an `HStack(spacing: 0)`; insert
/// `CellDivider()` between cells to draw the per-cell vertical rule.
struct RuledRow<Content: View>: View {
    @ViewBuilder var content: Content
    var fill: Color = Palette.bgElev
    var height: CGFloat = DK.rowH
    var bottomDivider: Bool = true

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(fill)
            .overlay(alignment: .bottom) {
                if bottomDivider {
                    Rectangle()
                        .fill(Palette.rule)
                        .frame(height: DK.ruleW)
                }
            }
    }
}

/// Column header row for a table. Pass strings; renders the design's
/// 10 pt uppercase mono labels with the bottom rule.
struct TableHeader: View {
    let labels: [(String, Alignment)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, item in
                Text(item.0.uppercased())
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink4)
                    .frame(maxWidth: .infinity, alignment: item.1)
                    .padding(.horizontal, DK.cellPadX)
                    .padding(.vertical, 10)
                if i < labels.count - 1 {
                    CellDivider()
                }
            }
        }
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.rule)
                .frame(height: DK.ruleW)
        }
    }
}

// MARK: - KpiStrip + KpiTile (v0.20)

/// Auto-fit grid of KPI tiles. Used as the always-visible top strip
/// on the Agent System and Activity pages so the operator can scan
/// "is this thing healthy" in one read. The grid uses a `minimum
/// 180 px` lane so a 1100 px window collapses cleanly to 6 columns
/// → 4 → 3 → 2 → 1 as it narrows.
struct KpiStrip: View {
    let tiles: [KpiTile]

    init(_ tiles: [KpiTile]) { self.tiles = tiles }

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                tile
            }
        }
    }
}

/// One KPI tile. `lead == true` paints the accent-tinted lead
/// gradient + accent-bordered ring, used for the *primary* metric on
/// each page (chunks indexed on System, events today on Activity).
/// `accent == true` colours the value glyph with the warm accent —
/// reserved for the lead tile.
struct KpiTile: View {
    let label: String
    let value: String
    var sub: String? = nil
    var lead: Bool = false
    var accent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Palette.ink4)
            Text(value)
                .font(Font.system(size: 26, weight: .semibold, design: .default))
                .tracking(-0.4)
                .foregroundStyle(accent ? Palette.accent : Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
            if let sub {
                Text(sub)
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 76, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius)
                .stroke(lead ? Palette.accentSoft : Palette.rule, lineWidth: DK.ruleW)
        )
        .clipShape(RoundedRectangle(cornerRadius: DK.radius))
    }

    @ViewBuilder
    private var tileBackground: some View {
        if lead {
            // Accent-tinted lead — linear gradient from a soft accent
            // wash at the top to bgElev at the bottom, mirroring the
            // design's `.kpi.lead` rule.
            LinearGradient(
                colors: [Palette.accentBg, Palette.bgElev],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Palette.bgElev
        }
    }
}

// MARK: - Tabs (v0.20)

/// Horizontal tab strip with optional count badges. 44 px tall,
/// hairline bottom rule, active tab carries a 2 px accent underline.
/// The active tab's count is tinted accent; inactive counts are ink4.
///
/// Generic `Item` is whatever caller-side enum identifies the tab —
/// the strip itself only needs an id, label, and optional count.
struct TabsStrip<Item: Hashable>: View {
    struct Tab: Identifiable {
        let id: Item
        let label: String
        var count: String? = nil
        init(id: Item, label: String, count: String? = nil) {
            self.id = id
            self.label = label
            self.count = count
        }
    }

    let tabs: [Tab]
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DK.pageGutter)
        .frame(height: DK.tabsH)
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }

    private func tabButton(_ tab: Tab) -> some View {
        let active = selection == tab.id
        return Button(action: { selection = tab.id }) {
            HStack(spacing: 8) {
                Text(tab.label)
                    .font(Font.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Palette.ink : Palette.ink3)
                if let count = tab.count {
                    Text(count)
                        .font(Font.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(active ? Palette.accent : Palette.ink4)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? Palette.accent : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ModeTab (v1.1)

/// Compact pill-style segmented control for "view mode" toggles —
/// `Detail | Kanban` on the project page, `Grid | Kanban` in the
/// Dispatch modal, etc. Replaces the native `.pickerStyle(.segmented)`
/// which (a) ignores the rest of the design system's chrome, (b) has
/// no room for icons, and (c) reads as a generic system control on a
/// page full of bespoke ones.
///
/// Visual contract:
/// - Inactive segment: `Palette.bgElev` ground, `Palette.ink2` text,
///   no border (the outer pill provides the boundary).
/// - Active segment: `Palette.accent` ground, `Color.white` text,
///   subtle drop shadow so the active chip lifts off the rail.
/// - Outer pill: `Palette.bgPage` ground with a hairline `Palette.rule`
///   stroke. Same 5.5 px corner radius as every other primitive
///   (`DK.radius`).
/// - Optional eyebrow label rendered to the left in the small all-caps
///   monospace style used by `KanbanColumnHeader` etc.
///
/// Generic on a `Hashable` selection type so it works with any enum
/// (`ProjectPageMode`, the dispatch-mode `String`, future modes).
struct ModeTab<Item: Hashable>: View {
    struct Option: Identifiable {
        let id: Item
        let label: String
        let icon: String?
        init(id: Item, label: String, icon: String? = nil) {
            self.id = id
            self.label = label
            self.icon = icon
        }
    }

    /// Optional eyebrow label rendered to the left of the pill (e.g.
    /// `"VIEW"`, `"LAYOUT"`). Pass `nil` to render the bare pill.
    let eyebrow: String?
    let options: [Option]
    @Binding var selection: Item

    init(
        eyebrow: String? = nil,
        options: [Option],
        selection: Binding<Item>
    ) {
        self.eyebrow = eyebrow
        self.options = options
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 10) {
            if let eyebrow {
                Text(eyebrow)
                    .font(Font.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Palette.ink3)
            }
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: DK.radius + 1, style: .continuous)
                .fill(Palette.bgPage)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DK.radius + 1, style: .continuous)
                .stroke(Palette.rule, lineWidth: DK.ruleW)
        )
    }

    private func segment(_ option: Option) -> some View {
        let active = selection == option.id
        return Button {
            if !active {
                withAnimation(.easeOut(duration: 0.12)) {
                    selection = option.id
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let icon = option.icon {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                }
                Text(option.label)
                    .font(Font.system(
                        size: 11.5,
                        weight: active ? .semibold : .medium,
                        design: .default
                    ))
            }
            .foregroundStyle(active ? Color.white : Palette.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(minWidth: 64)
            .background(
                RoundedRectangle(cornerRadius: DK.radius - 1, style: .continuous)
                    .fill(active ? Palette.accent : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius - 1, style: .continuous)
                    .stroke(active ? Palette.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .shadow(
                color: active ? Color.black.opacity(0.18) : Color.clear,
                radius: active ? 3 : 0,
                x: 0,
                y: active ? 1 : 0
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option.label)
    }
}

// MARK: - SectionHeader (v0.20)

/// Eyebrow + title + optional count + optional sub line + optional
/// trailing slot. Replaces the inline `Text("…").font(Typography.heading)`
/// helpers each surface used to roll its own version of, so every
/// section row uses the exact same vertical rhythm.
struct SectionHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    let count: String?
    let sub: String?
    @ViewBuilder var trailing: Trailing

    init(
        eyebrow: String? = nil,
        title: String,
        count: String? = nil,
        sub: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.count = count
        self.sub = sub
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    OverlineLabel(eyebrow, tint: Palette.ink4)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(Font.system(size: 18, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Palette.ink)
                    if let count {
                        Text(count)
                            .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.ink4)
                            .monospacedDigit()
                    }
                }
                if let sub {
                    Text(sub)
                        .font(Font.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Palette.ink3)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String, count: String? = nil, sub: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.count = count
        self.sub = sub
        self.trailing = EmptyView()
    }
}

// MARK: - RightRail (v0.20)

/// Sticky right-side rail of contextual actions. Each `RailGroup`
/// carries an overline title and a vertical stack of `RailAction`s.
/// The rail itself is 240 px wide, separated from the main content
/// by a 1 px hairline, and stays put as the main content scrolls.
///
/// Caller passes `[RailGroup]`; the rail picks the first group's
/// title for accessibility and renders each row as a
/// height-30 button matching the design's `.btn.sm` shape.
struct RightRail: View {
    let groups: [RailGroup]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    railGroupView(group)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .frame(width: DK.rightRailW)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.bgPage)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.rule).frame(width: DK.ruleW)
        }
    }

    private func railGroupView(_ group: RailGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OverlineLabel(group.title, tint: Palette.ink4)
                .padding(.bottom, 2)
            ForEach(Array(group.actions.enumerated()), id: \.offset) { _, action in
                RailActionRow(action: action)
            }
        }
    }
}

/// One section inside a `RightRail`. Title becomes the overline.
struct RailGroup: Identifiable {
    let id: String
    let title: String
    let actions: [RailAction]

    init(_ title: String, actions: [RailAction]) {
        self.id = title
        self.title = title
        self.actions = actions
    }
}

/// One button inside a `RailGroup`. Distinct from `OutlineButton`
/// because the rail variant has a fixed full-width layout with a
/// leading icon glyph + label and (occasionally) a trailing kbd hint.
struct RailAction: Identifiable {
    enum Variant {
        case standard, primary, danger, ghost
    }

    let id: String
    let label: String
    let icon: String?
    let variant: Variant
    let kbd: String?
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ label: String,
        icon: String? = nil,
        variant: Variant = .standard,
        kbd: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = label
        self.label = label
        self.icon = icon
        self.variant = variant
        self.kbd = kbd
        self.isDisabled = isDisabled
        self.action = action
    }
}

private struct RailActionRow: View {
    let action: RailAction
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action.action) {
            HStack(spacing: 8) {
                if let icon = action.icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                        .foregroundStyle(iconColor)
                }
                Text(action.label)
                    .font(Font.system(size: 12, weight: .regular))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let kbd = action.kbd {
                    KbdKey(label: kbd)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(borderColor, lineWidth: DK.ruleW)
            )
            .clipShape(RoundedRectangle(cornerRadius: DK.radius))
            .contentShape(RoundedRectangle(cornerRadius: DK.radius))
            .opacity(action.isDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(action.isDisabled)
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        if action.isDisabled { return Palette.ink4 }
        switch action.variant {
        case .standard, .ghost: return isHovered ? Palette.ink : Palette.ink2
        case .primary:          return Palette.bgPage
        case .danger:           return isHovered ? Palette.danger : Palette.ink2
        }
    }
    private var iconColor: Color {
        if action.isDisabled { return Palette.ink4 }
        switch action.variant {
        case .danger:  return isHovered ? Palette.danger : Palette.ink3
        case .primary: return Palette.bgPage
        default:       return Palette.ink3
        }
    }
    private var backgroundColor: Color {
        switch action.variant {
        case .standard:
            return isHovered ? Palette.bgRowHi : Color.clear
        case .primary:
            // Per master brand: terracotta is the one chromatic event.
            // Hover stays on the same hue (no second amber tint) — the
            // resting/hover delta lives in border + opacity instead.
            return Palette.accent
        case .danger:
            // See the matching note in OutlineButton.currentBg —
            // destructive hover is a soft terracotta wash.
            return isHovered ? Palette.danger.opacity(0.12) : Color.clear
        case .ghost:
            return isHovered ? Palette.bgRowHi : Color.clear
        }
    }
    private var borderColor: Color {
        switch action.variant {
        case .standard:
            return isHovered ? Palette.ruleStrong : Palette.rule
        case .primary:
            return Palette.accent
        case .danger:
            return isHovered ? Palette.danger : Palette.rule
        case .ghost:
            return isHovered ? Palette.rule : .clear
        }
    }
}

// MARK: - FilterBar (v0.20)

/// Horizontal filter chip row. Each `FilterGroup` is a label + a list
/// of mutually-exclusive `OutlineButton.small` chips that drive a
/// caller-side toggle. The bar uses bgPage with a hairline bottom
/// rule. Currently used by Calendar; the Knowledge → System surface
/// uses a slimmer in-section variant.
struct FilterBar<Trailing: View>: View {
    struct Group: Identifiable {
        let id: String
        let label: String
        let chips: [Chip]

        init(label: String, chips: [Chip]) {
            self.id = label
            self.label = label
            self.chips = chips
        }
    }
    struct Chip: Identifiable {
        let id: String
        let label: String
        let active: Bool
        let action: () -> Void

        init(label: String, active: Bool, action: @escaping () -> Void) {
            self.id = label
            self.label = label
            self.active = active
            self.action = action
        }
    }

    let groups: [Group]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
                    if i > 0 {
                        Rectangle().fill(Palette.rule).frame(width: DK.ruleW, height: 18)
                            .padding(.horizontal, 4)
                    }
                    OverlineLabel(group.label, tint: Palette.ink4)
                    ForEach(group.chips) { chip in
                        OutlineButton(
                            chip.label,
                            size: .small,
                            variant: chip.active ? .accent : .standard,
                            action: chip.action
                        )
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, DK.pageGutter)
            .padding(.vertical, 10)
        }
        .background(Palette.bgPage)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.rule).frame(height: DK.ruleW)
        }
    }
}

extension FilterBar where Trailing == EmptyView {
    init(groups: [Group]) {
        self.groups = groups
        self.trailing = EmptyView()
    }
}

// MARK: - Heatmap24x7 (v0.20)

/// 24-hour × 7-day intensity heatmap. Used by Activity → All
/// activity to answer "what does activity look like by time of day".
/// Renders via `Canvas` (one drawing context) so 168 cells stay
/// inside SwiftUI's per-frame budget.
///
/// Inputs:
///   - `cells`: 168 cells with `(weekday 0–6, hour 0–23, intensity 0…1)`.
///     Missing cells are rendered as a faint base.
///   - `todayWeekday`: highlighted with a 1 px ruleStrong outline on
///     its full row.
///   - `currentHour`: the cell at `(today, currentHour)` gets an
///     accent outline so the operator sees "right now" at a glance.
///
/// Layout: column gutter (40 px, weekday labels) + 24 columns. Hour
/// axis labels render every 6 hours (00 / 06 / 12 / 18). Cell shape
/// is 18 px tall with a small 2 px gap between cells.
struct Heatmap24x7: View {
    struct Cell: Equatable {
        let weekday: Int   // 0 = Mon … 6 = Sun (matches design)
        let hour: Int      // 0…23
        let intensity: Double // 0…1
    }

    let cells: [Cell]
    var todayWeekday: Int? = nil
    var currentHour: Int? = nil

    private static let weekdayLabels = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    private static let hourLabels = (0..<24).map { $0 % 6 == 0 ? String(format: "%02d", $0) : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Hour-of-day axis row
            HStack(spacing: 2) {
                Color.clear.frame(width: 40, height: 12) // gutter
                ForEach(0..<24, id: \.self) { h in
                    Text(Self.hourLabels[h])
                        .font(Font.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(h % 6 == 0 ? Palette.ink2 : Palette.ink4)
                        .frame(maxWidth: .infinity)
                }
            }

            // Body — one row per weekday
            ForEach(0..<7, id: \.self) { wd in
                HStack(spacing: 2) {
                    Text(Self.weekdayLabels[wd])
                        .font(Font.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(wd == (todayWeekday ?? -1) ? Palette.accent : Palette.ink3)
                        .frame(width: 40, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        cellView(weekday: wd, hour: h)
                    }
                }
            }

            // Density legend
            HStack(spacing: 6) {
                OverlineLabel("Density", tint: Palette.ink4)
                ForEach([0.05, 0.25, 0.45, 0.7, 0.95], id: \.self) { intensity in
                    RoundedRectangle(cornerRadius: DK.radius)
                        .fill(Palette.accent.opacity(intensity))
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: DK.radius)
                                .stroke(Palette.rule, lineWidth: 0.5)
                        )
                }
                Text("low → high · today highlighted")
                    .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Palette.ink4)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func cellView(weekday: Int, hour: Int) -> some View {
        let intensity = cellIntensity(weekday: weekday, hour: hour)
        let isToday = weekday == (todayWeekday ?? -1)
        let isNow = isToday && hour == (currentHour ?? -1)
        RoundedRectangle(cornerRadius: DK.radius)
            .fill(intensity < 0.04 ? Palette.bgElev : Palette.accent.opacity(intensity))
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: DK.radius)
                    .stroke(
                        isNow ? Palette.accent
                            : isToday ? Palette.accentSoft
                            : Palette.rule.opacity(0.4),
                        lineWidth: isNow ? 1.5 : 0.5
                    )
            )
            .help(cellTooltip(weekday: weekday, hour: hour, intensity: intensity))
    }

    private func cellIntensity(weekday: Int, hour: Int) -> Double {
        cells.first(where: { $0.weekday == weekday && $0.hour == hour })?.intensity ?? 0
    }

    private func cellTooltip(weekday: Int, hour: Int, intensity: Double) -> String {
        let day = Self.weekdayLabels[weekday]
        let pct = Int(intensity * 100)
        return "\(day) · \(String(format: "%02d", hour)):00 · \(pct)% activity"
    }
}
