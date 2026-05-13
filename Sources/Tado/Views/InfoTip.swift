import SwiftUI

/// Shared hover-only info icon.
struct InfoTip: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(Palette.textTertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .help(text)
            .accessibilityLabel("Info")
            .accessibilityHint(text)
    }
}
