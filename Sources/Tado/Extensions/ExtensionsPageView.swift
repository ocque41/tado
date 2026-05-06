import SwiftUI

/// Extensions tab — the discovery surface for every extension
/// registered in `ExtensionRegistry`. Redesigned in v0.18 to match the
/// projects-page structural grid: `PageHeader` + a single
/// `SectionRail` ("Bundled extensions") hosting the cards grid.
///
/// Why this exists separately from the sidebar bell
/// - The bell is a quick affordance for one specific extension
///   (Notifications). The Extensions surface is the discovery
///   surface — it tells the user *which* extensions exist at all,
///   what they do, and what version they're on.
///
/// Implementation note: we pre-map `ExtensionRegistry.all`
/// (`[any AppExtension.Type]`) into a concrete `Identifiable` struct
/// before the `ForEach`. Iterating existential metatypes directly
/// inside SwiftUI's ViewBuilder triggers a Swift-6 SIL generation bug
/// in some compiler versions; the pre-map sidesteps it.
struct ExtensionsPageView: View {
    @Environment(\.openWindow) private var openWindow

    private let gridColumns: [GridItem] = [
        GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 0, alignment: .topLeading)
    ]

    private var items: [ExtensionListItem] {
        ExtensionRegistry.all.map { ext in
            ExtensionListItem(
                id: ext.manifest.id,
                manifest: ext.manifest,
                windowID: ExtensionWindowID.string(for: ext.manifest.id)
            )
        }
    }

    var body: some View {
        PageContainer {
            PageHeader(title: "Extensions") {
                MetaStrip {
                    MetaCell(
                        key: "Status",
                        value: items.isEmpty ? "○ Empty" : "● Bundled",
                        tint: items.isEmpty ? Palette.ink3 : Palette.green
                    )
                    MetaCell(key: "Total", value: "\(items.count)")
                    MetaCell(key: "Install", value: "in-process", trailingDivider: false)
                }
            }

            SectionRail(
                label: "Bundled",
                count: items.isEmpty ? "No extensions" : "\(items.count) registered",
                bottomDivider: false
            ) {
                if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            ExtensionCard(manifest: item.manifest) {
                                openWindow(id: item.windowID)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No extensions registered")
                .font(Font.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text("Adding an extension means creating a Swift type in `Sources/Tado/Extensions/` that conforms to `AppExtension`, then adding it to `ExtensionRegistry.all`.")
                .font(Font.system(size: 12.5, weight: .regular))
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: 560, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("EXTENSION HOST  ·  AppExtension protocol  ·  windowed surfaces, no install step")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(Palette.ink4)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(Palette.rule).frame(height: 1).padding(.horizontal, -2)
                }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Concrete, Identifiable shape used to drive the Extensions grid
/// without iterating an existential-metatype collection inside
/// SwiftUI's ViewBuilder. See the page-view doc comment for the
/// rationale.
private struct ExtensionListItem: Identifiable {
    let id: String
    let manifest: ExtensionManifest
    let windowID: String
}

/// One card in the Extensions grid. v0.18 design pass: cards drop
/// their rounded corners + shadow and become flat structural cells
/// with a 1 px hairline border on every edge so the grid reads as a
/// table the way the rest of the app does.
private struct ExtensionCard: View {
    let manifest: ExtensionManifest
    let onOpen: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: manifest.iconSystemName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(Palette.ink2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manifest.displayName)
                            .font(Font.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text("v\(manifest.version)")
                            .font(Font.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.ink4)
                    }
                    Spacer(minLength: 0)
                }

                Text(manifest.shortDescription)
                    .font(Font.system(size: 12, weight: .regular))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(Font.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Palette.bgRowHi : Palette.bgElev)
            .overlay(Rectangle().stroke(isHovered ? Palette.accentSoft : Palette.rule, lineWidth: DK.ruleW))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .help(manifest.shortDescription)
    }
}
