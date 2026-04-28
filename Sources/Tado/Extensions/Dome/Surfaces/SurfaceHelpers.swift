import SwiftUI

/// Shared helpers used by every Dome surface (KnowledgeSurface,
/// AutomationSurface, RecipesSurface, etc.). Lifted out of
/// KnowledgeSurface.swift in v0.11 so new top-level surfaces can
/// reuse the same header chrome and empty-state look without
/// re-implementing them.

/// Top bar with title + subtitle + refresh button. Matches the
/// shape every Dome surface has used since v0.7 — keeping the
/// API identical so existing callers don't need rewrites.
@ViewBuilder
func surfaceHeader(title: String, subtitle: String, isLoading: Bool, refresh: @escaping () -> Void) -> some View {
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

/// Centred empty-state placeholder. SF Symbol + secondary-tone
/// label. Use this whenever a list returns zero rows so the user
/// gets a designed empty state instead of a blank pane.
@ViewBuilder
func surfaceEmpty(icon: String, text: String) -> some View {
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
