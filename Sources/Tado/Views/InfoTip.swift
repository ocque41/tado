import SwiftUI

/// 11pt `info.circle` tinted with `Palette.textTertiary`, carrying a `.help(…)`
/// tooltip. Inline this inside a Toggle/Picker/Stepper label, or next to any
/// control where the meaning isn't obvious from the label alone. Matches the
/// info-icon idiom already used at `EternalInterveneModal.examplesBlurb`.
struct InfoTip: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(Palette.textTertiary)
            .help(text)
    }
}
