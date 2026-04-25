//! NFC (Unicode Normalization Form C) composition for combining-mark
//! sequences. Called by `Grid::compose_combining` to fold a width-0
//! combining character onto the previous cell's character when the
//! pair has a precomposed single-scalar form in Unicode.
//!
//! What NFC catches (the 90% case):
//!   * `'a' + U+0301` (combining acute)     → `'á'` (U+00E1)
//!   * `'e' + U+0308` (combining diaeresis) → `'ë'` (U+00EB)
//!   * `'n' + U+0303` (combining tilde)     → `'ñ'` (U+00F1)
//!   * Any letter + diacritic where Unicode has a precomposed codepoint.
//!
//! What NFC does NOT catch:
//!   * Emoji + skin-tone modifier: `U+1F44B + U+1F3FD` (👋🏽). These
//!     are grapheme-cluster sequences resolved at font-layout time by
//!     CoreText; Unicode has no single precomposed scalar.
//!   * ZWJ emoji families: `man + ZWJ + woman + ZWJ + girl`.
//!   * Combining marks with no precomposed base (`'a' + U+0332`
//!     combining low line).
//!
//! For the non-NFC cases, `compose` returns `None`. The grid then drops
//! the combining mark — a graceful degradation that matches or beats
//! the "drop zero-width codepoints entirely" behavior the grid had
//! before this module. A future packet can add a per-cell combining-mark
//! side table + a renderer overlay pass if those edge cases become
//! blocking.

use unicode_normalization::UnicodeNormalization;

/// Attempt to compose `base + combining` into a single precomposed
/// scalar via Unicode Normalization Form C (NFC). Returns
/// `Some(composed)` when the pair has a precomposed form (one scalar
/// output after NFC), else `None` when NFC would leave them as two or
/// more scalars.
pub fn compose(base: char, combining: char) -> Option<char> {
    let pair: String = [base, combining].iter().collect();
    let mut chars = pair.nfc();
    let first = chars.next()?;
    if chars.next().is_some() {
        // NFC emitted 2+ scalars — no precomposed form exists.
        return None;
    }
    Some(first)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_a_and_combining_acute() {
        assert_eq!(compose('a', '\u{0301}'), Some('\u{00E1}')); // á
    }

    #[test]
    fn compose_e_and_diaeresis() {
        assert_eq!(compose('e', '\u{0308}'), Some('\u{00EB}')); // ë
    }

    #[test]
    fn compose_n_and_tilde() {
        assert_eq!(compose('n', '\u{0303}'), Some('\u{00F1}')); // ñ
    }

    #[test]
    fn compose_capital_letter() {
        assert_eq!(compose('A', '\u{0301}'), Some('\u{00C1}')); // Á
    }

    #[test]
    fn compose_returns_none_for_combining_low_line() {
        // 'a' + U+0332 has no precomposed form.
        assert_eq!(compose('a', '\u{0332}'), None);
    }

    #[test]
    fn compose_returns_none_for_skin_tone_modifier() {
        // Emoji + skin tone is a grapheme cluster, not an NFC composition.
        // CoreText resolves the ligature at font-layout time; NFC leaves
        // the two scalars separate.
        assert_eq!(compose('\u{1F44B}', '\u{1F3FD}'), None); // 👋🏽
    }

    #[test]
    fn compose_returns_none_for_non_combining_second() {
        // If the "combining" char isn't really combining (width > 0),
        // NFC leaves both — signal None so the caller doesn't mangle.
        assert_eq!(compose('a', 'b'), None);
    }
}
