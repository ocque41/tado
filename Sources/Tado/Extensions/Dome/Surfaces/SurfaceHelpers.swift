import SwiftUI

/// Shared helpers used by every Dome surface (KnowledgeSurface,
/// AutomationSurface, RecipesSurface, etc.). Lifted out of
/// KnowledgeSurface.swift in v0.11 so new top-level surfaces can
/// reuse the same header chrome and empty-state look without
/// re-implementing them.
///
/// The public helper functions stay tiny so every Dome surface can
/// share Relay chrome without duplicating environment color plumbing.

/// Top bar with title + subtitle + refresh button.
@ViewBuilder
func surfaceHeader(title: String, subtitle: String, isLoading: Bool, refresh: @escaping () -> Void) -> some View {
    DomeSurfaceHeader(title: title, subtitle: subtitle, isLoading: isLoading, refresh: refresh)
}

@ViewBuilder
func surfaceEmpty(icon: String, text: String) -> some View {
    DomeSurfaceEmpty(icon: icon, text: text)
}

private struct DomeSurfaceHeader: View {
    let title: String
    let subtitle: String
    let isLoading: Bool
    let refresh: () -> Void

    @Environment(\.relayTheme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(RelayType.h2(size: 28))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
                Text(subtitle)
                    .font(Typography.sans(size: 11, weight: .regular))
                    .tracking(RelayTracking.meta(11))
                    .foregroundStyle(RelayPalette.foreground3(for: theme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 16)
            RelayButton(label: isLoading ? "Loading" : "Refresh", variant: .standard, icon: isLoading ? "hourglass" : "arrow.clockwise") {
                if !isLoading { refresh() }
            }
            .disabled(isLoading)
            .help("Refresh")
        }
        .padding(.horizontal, RelaySpacing.s32)
        .padding(.top, RelaySpacing.s24)
        .padding(.bottom, 14)
        .background(RelayPalette.background(for: theme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RelayPalette.hair(for: theme))
                .frame(height: 1)
        }
    }
}

/// Centred empty-state placeholder. Adopts the structural design's
/// "headline + subline + dashed-top-border help line" pattern so
/// empty Dome surfaces read like the empty Dispatch / Eternal /
/// Projects sections — clearly intentional, not a blank pane. The
/// caller-supplied SF Symbol is preserved as a leading 22 pt glyph;
/// the `text` becomes the headline.
private struct DomeSurfaceEmpty: View {
    let icon: String
    let text: String

    @Environment(\.relayTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(RelayPalette.foreground4(for: theme))
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RelayPalette.foreground(for: theme))
            }
            Text("Empty surface - once data lands here it will populate automatically.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(RelayPalette.foreground3(for: theme))
                .frame(maxWidth: 540, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("DOME SURFACE  ·  reads through dome-mcp / DomeRpcClient  ·  scope-filtered by the topbar selector")
                .font(Font.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(RelayPalette.foreground4(for: theme))
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(RelayPalette.hair(for: theme))
                        .frame(height: 1)
                        .padding(.horizontal, -2)
                }
            }
        .padding(.horizontal, RelaySpacing.s32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
