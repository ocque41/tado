# Tado — Brand

Tado inherits from the master Cumulus brand spec at
`/Users/miguel/Documents/cumulus/CUMULUS-BRAND.md`. The master spec
wins on any disagreement.

## Tado-specific deviations

1. **SF Mono in the terminal cell grid** — the Metal renderer requires
   `NSFont.monospacedSystemFont` for cell metric stability. JetBrains
   Mono is not used in `FontMetrics.swift`.

2. **JetBrains Mono migration deferred** — at this snapshot, the entire
   Tado UI mono stack still uses SF Mono pending a bundle of the
   JetBrains Mono TTFs into `Sources/Tado/Resources/Fonts/`. To
   complete: download the JetBrains Mono Regular/Medium/SemiBold TTFs
   from https://www.jetbrains.com/lp/mono/ , drop them into the
   Resources/Fonts directory, register them in
   `Sources/Tado/Design/Typography.swift::registerFonts()`, and route
   the `Typography.mono*` helpers to PostScript names like
   `JetBrainsMono-Regular`.

3. **Tile shadow** — the canvas tile (`MetalTerminalTileView`) keeps
   its 8px-blur drop shadow. The tile is a window-like floating element
   and is the one allowed exception to the no-card-shadow rule.

## Status

Aligned to CUMULUS-BRAND.md v1.0 — color (terracotta accent, monochrome
foundation), radius (5.5px), focus ring (terracotta), brand mark
(terracotta dot + mono lockup), EditorialCard primitive available.
Mono stack: deferred (see deviation 2).
