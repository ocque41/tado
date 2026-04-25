import SwiftUI

/// The root view for Tado's Extensions tab. Lists every extension
/// registered in ``ExtensionRegistry`` as a card; tapping a card opens
/// the extension's independent window via the SwiftUI `openWindow`
/// environment action.
///
/// Why this exists separately from the sidebar bell
/// - The bell is a quick affordance for one specific extension
///   (Notifications). The Extensions surface is the discovery surface
///   — it tells the user *which* extensions exist at all, what they
///   do, and what version they're on.
/// - As more extensions migrate (Dome second-brain, Eternal control
///   room, Dispatch monitor, etc.), the page is the canonical home for
///   them. The sidebar stays uncluttered.
///
/// Implementation note: we pre-map `ExtensionRegistry.all`
/// (`[any AppExtension.Type]`) into a concrete `Identifiable` struct
/// before the `ForEach`. Iterating existential metatypes directly
/// inside SwiftUI's ViewBuilder triggers a Swift-6 SIL generation bug
/// in some compiler versions; the pre-map sidesteps it.
struct ExtensionsPageView: View {
    @Environment(\.openWindow) private var openWindow

    private let gridColumns: [GridItem] = [
        GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 16, alignment: .topLeading)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                        ForEach(items) { item in
                            ExtensionCard(manifest: item.manifest) {
                                openWindow(id: item.windowID)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extensions")
                .font(Typography.display)
                .foregroundStyle(Palette.textPrimary)
            Text("Bundled features that open in their own windows. No install step — they ship inside the app.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No extensions registered")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)
            Text("Adding an extension means creating a Swift type in `Sources/Tado/Extensions/` that conforms to `AppExtension`, then adding it to `ExtensionRegistry.all`.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.surfaceElevated)
        )
    }
}

/// Concrete, Identifiable shape used to drive the Extensions grid
/// without iterating an existential-metatype collection inside SwiftUI's
/// ViewBuilder. See the page-view doc comment for the rationale.
private struct ExtensionListItem: Identifiable {
    let id: String
    let manifest: ExtensionManifest
    let windowID: String
}

/// One card in the Extensions grid. Whole card is the click target;
/// hover lifts the surface fill so the affordance is obvious without
/// drop shadows or chrome.
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
                        .foregroundStyle(Palette.textPrimary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manifest.displayName)
                            .font(Typography.title)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Text("v\(manifest.version)")
                            .font(Typography.micro)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                }

                Text(manifest.shortDescription)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(Typography.calloutBold)
                            .foregroundStyle(Palette.accent)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Palette.pressedBackground : Palette.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Palette.accent.opacity(0.5) : Palette.divider, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .help(manifest.shortDescription)
    }
}
