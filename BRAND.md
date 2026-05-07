# Tado — Brand

Tado inherits from the master Cumulus brand spec at
`/Users/miguel/Documents/cumulus/CUMULUS-BRAND.md`. The master spec
wins on any disagreement.

## Tado-specific deviations

1. **SF Mono in the terminal cell grid** — the Metal renderer requires
   `NSFont.monospacedSystemFont` for cell metric stability. The cell
   grid is the one place a true monospace font is non-negotiable.

2. **Single-family typography** — Tado uses **Plus Jakarta Sans only**
   for every UI surface. The full 7-weight × 2-style family is
   bundled in `Sources/Tado/Resources/Fonts/`. The Relay brief calls
   for a JetBrains Mono companion; Tado deviates by rendering every
   "mono" callsite (kicker / brand mark / kbd pill / table head /
   status meta / palette item meta) in Plus Jakarta Sans with strong
   tracking + small size + uppercase. This makes the design even more
   single-typeface than the brief literally specifies, which sharpens
   the editorial feel further. Concrete mappings live in
   `Sources/Tado/Design/RelayType.swift`.

3. **No tile shadow** — the canvas tile (`TerminalTileView`) used to
   keep an 8px-blur drop shadow as the one allowed exception to the
   no-card-shadow rule. The Relay redesign removed it; tiles now use
   a hairline border + terracotta focus ring as the affordance. The
   only place a shadow appears app-wide is the modal shadow definition
   in `RelayShadow.modalColor` (palette card, focused-tile modal,
   toast banner).

## Relay redesign tokens (post-redesign)

The Relay token system at `Sources/Tado/Design/RelayTokens.swift` is
the post-redesign authoritative set. Foundation:

- **Colors** — two foundation (`#1a1a1a` ink, `#f5f5f5` paper) + one
  accent (`#A44718` terracotta, ≤10% of any composition). Ink and
  paper alpha scales (2/3/4/5) carry every secondary text + hairline.
- **Radius** — `RelayRadius.standard = 5.5pt` only. The 999 pill
  exception applies to the 6×6 brand-mark dot and 7px live status
  dots.
- **Shadow** — `RelayShadow.modalColor` (rgba(26,26,26,0.18)) at
  18px blur, 18px Y-offset. **Modals only.** Cards, rows, inputs,
  panels, tiles, sidebars, palette rows: hairlines, no shadow.
- **Motion** — durations + bezier curves in `RelayMotionTokens`,
  routed through `RelayAnim.standard / easeOut / overlay / drawer`
  helpers that read `accessibilityReduceMotion` and degrade to
  instant transitions when set.
- **Theme** — paper/ink toggle stored in `@AppStorage("relay.theme")`,
  default `.ink`. Propagated through every WindowGroup root via
  `.relayTheme(_:)` env modifier. Six historical
  `.preferredColorScheme(.dark)` calls were replaced by this
  AppStorage binding so the user can flip paper/ink at runtime
  without a relaunch.

## Deprecated tokens

The legacy `Palette.success` / `Palette.warning` / `Palette.green` /
`Palette.greenSoft` / `Palette.bgPage` / `Palette.bgElev` /
`Palette.bgRow` / `Palette.bgRowHi` tokens are kept as `let` aliases
so existing call sites in non-redesigned legacy surfaces continue to
compile. Their values resolve to ink-tier neutrals (or terracotta for
`danger`) per the Cumulus master brand. New code should reach for the
Relay-prefixed primitives + `RelayPalette.*` getters instead.

## Status

Aligned to CUMULUS-BRAND.md v1.0 — color (terracotta accent,
monochrome foundation), radius (5.5px), focus ring (terracotta),
brand mark (terracotta dot + mono lockup). Relay redesign landed
across all five WindowGroups with the Relay token system, theme
env, page-anatomy primitives, command palette, Explore left panel,
focused-tile modal, onboarding flow, toast host, and ⌘1–9 menu-bar
shortcuts.
