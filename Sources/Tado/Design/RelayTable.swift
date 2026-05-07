// Table primitives — `r-table` per brief section 5.3.
//
// Header row: mono-substitute 10px caps tracking 0.20em color
// ink-3 uppercase. Bottom hairline.
// Body rows: 12px vertical padding. Soft hairline between rows.
// Cells: Plus Jakarta Sans 14px ink for body, 11px ink-3 for
// metadata (paths, ids, grid coords).

import SwiftUI

struct RelayTableColumn: Identifiable {
    let id = UUID()
    let label: String
    let alignment: Alignment
    let widthMode: WidthMode

    enum WidthMode {
        case flex(min: CGFloat = 60)
        case fixed(CGFloat)
    }

    init(_ label: String, alignment: Alignment = .leading, width: WidthMode = .flex()) {
        self.label = label
        self.alignment = alignment
        self.widthMode = width
    }
}

struct RelayTableHeader: View {
    let columns: [RelayTableColumn]

    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { col in
                Text(col.label.uppercased())
                    .font(Typography.sans(size: 10, weight: .semibold))
                    .tracking(RelayTracking.caps(10))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                    .frame(maxWidth: width(for: col), alignment: col.alignment)
                    .padding(.horizontal, 12)
            }
        }
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
        }
    }

    private func width(for col: RelayTableColumn) -> CGFloat? {
        switch col.widthMode {
        case .fixed(let w): return w
        case .flex:         return .infinity
        }
    }
}

/// A single body row. Caller supplies cell contents in column
/// order. Soft hairline between rows is rendered by the parent
/// `VStack(spacing: 0)` via per-row bottom overlay.
struct RelayTableRow<RowContent: View>: View {
    let isHovered: Bool
    @ViewBuilder var content: RowContent
    var onClick: (() -> Void)? = nil

    @Environment(\.relayTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hover: Bool = false

    var body: some View {
        let inner = HStack(spacing: 0) {
            content
        }
        .frame(minHeight: 44)
        .background((hover || isHovered) ? RelayPalette.wash(for: theme) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hairSoft(for: theme))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { newValue in
            withAnimation(RelayAnim.standard(reduce: reduce)) {
                hover = newValue
            }
        }

        if let onClick {
            Button(action: onClick) { inner }
                .buttonStyle(.plain)
        } else {
            inner
        }
    }
}

extension RelayTableRow {
    init(@ViewBuilder content: () -> RowContent) {
        self.isHovered = false
        self.content = content()
        self.onClick = nil
    }
}

/// Cell — typed body or metadata variant. Mirrors the column
/// alignment.
struct RelayTableCell: View {
    enum Style { case body, meta, right }
    let text: String
    var style: Style = .body
    var alignment: Alignment = .leading
    var width: CGFloat? = nil

    @Environment(\.relayTheme) private var theme

    var body: some View {
        Text(text)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: width ?? .infinity, alignment: alignment)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private var font: Font {
        switch style {
        case .body:  return Typography.sans(size: 14, weight: .regular)
        case .meta:  return Typography.sans(size: 11, weight: .regular)
        case .right: return Typography.sans(size: 14, weight: .regular)
        }
    }
    private var tracking: CGFloat {
        switch style {
        case .meta: return RelayTracking.meta(11)
        default:    return 0
        }
    }
    private var color: Color {
        switch style {
        case .body, .right: return RelayPalette.foreground(for: theme)
        case .meta:         return RelayPalette.foreground3(for: theme)
        }
    }
}
